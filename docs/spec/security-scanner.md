# Security Scanner Specification

> **ADR 참조**:
> - [ADR-001 실행/상태 공유 모델](../design/adr/ADR-001-execution-shared-state-model.md) — Rust FFI 통합 방식
> - [ADR-014 Scanner Pattern Hot Update](../design/adr/ADR-014-scanner-pattern-hot-update.md) — RwLock 도입, 런타임 패턴 교체

## 1. 개요

보안 스캐너는 HTTP 요청의 경로, 쿼리 스트링, User-Agent, 본문을 검사하여
위협 유형과 위협 점수를 반환하는 Rust 구현 모듈이다.

- **구현**: `src/scanner/` (Rust cdylib)
- **빌드 산출물**: `luagate_scanner.so`
- **Lua 바인딩**: `lua/luagate/scanner/ffi.lua`
- **호출 방식**: Rust FFI (extern "C"), 동일 worker 내 동기 호출 (ADR-001)

### Admin plane 스캐너 대상 제외

Admin plane (server block identity가 `admin`인 요청)은 스캐너 대상에서 제외한다.
ADR-002 정책 평가 제외와 동일 규칙.

## 2. 탐지 위협 유형

| threat_type | 설명 | 기반 |
|-------------|------|------|
| `sqli` | SQL Injection | OWASP CRS, 패턴 매칭 |
| `xss` | Cross-Site Scripting | OWASP CRS, DOM 패턴 |
| `path_traversal` | 경로 탐색 공격 | `../`, `%2e%2e` 등 |
| `cmd_injection` | OS 커맨드 인젝션 | 셸 메타문자 패턴 |
| `ssrf` | Server-Side Request Forgery | IP/도메인 패턴 |
| `xxe` | XML External Entity | XML DTD 패턴 |
| `log4shell` | Log4j RCE (CVE-2021-44228) | `${jndi:...}` 패턴 |
| `scanner` | 자동화 스캐너 탐지 | User-Agent, 탐색 패턴 |

> **enum 표기 원칙**: `threat_type` 값은 underscore(`_`) 구분자를 사용한다. hyphen(`-`) 표기는 사용하지 않는다. http-pipeline.md §5 및 log-schema.md §3의 `threat_type` 열거값과 동일 기준이다.

### threat_type 동시 탐지 규칙

- **Primary threat_type**: evaluation order 기준 먼저 매칭된 것
- 내부적으로 `matched_rules[]` 유지 (Phase 2에서 노출 예정)
- MVP: log-schema의 `rule_name`에 primary threat의 내부 rule_name 기록

### match_target / evidence_snippet

- MVP: 미지원
- 탐지 근거 최소 표현: `rule_name` + `threat_type` (log-schema.md 참조)
- Phase 2: `match_target`, `evidence_snippet` 노출 예정

## 2b. 에러 3계층 분류

| 에러 유형 | 의미 | 처리 |
|---------|------|------|
| `decode_partial` | transform 일부 실패. raw/partial-decoded 값으로 검사 계속. fail-open 아님 — 검사는 반드시 실행 | 계속 진행 (partial 값으로 스캔) |
| `scanner_internal_error` | 스캐너 자체 실패. Lua wrapper exception, `require()` load failure, FFI wrapper 예외 포함 | fail-closed (403) |
| `budget_exceeded` | 5ms 초과 | fail-closed (403) |

## 2c. 입력 크기 상한

- **path**: 최대 8KB. 초과 시 fail-closed (403)
- **query string**: 최대 8KB. 초과 시 fail-closed (403)
- **body**: MVP 비범위. Phase 2에서 `application/json`, `application/x-www-form-urlencoded`만 지원. `multipart`/binary 제외

## 2d. 대상별 스캔 계약표

| 대상 | 입력 원천 | 최대 바이트 | Decode 순서 | On-Error |
|------|---------|-----------|-----------|---------|
| path | path_raw (Lua 계산, query 미포함) | 8KB | percent-decode → path normalize → NFKC | decode_partial → 계속, 크기 초과 → fail-closed |
| query.key | query_raw에서 `&`로 분리 후 `=` 앞 부분 | name 4KB | percent-decode (name/value 컴포넌트 단위) | decode_partial → 계속 |
| query.value | query_raw에서 `&`로 분리 후 `=` 뒤 부분 | value 4KB | percent-decode (name/value 컴포넌트 단위) | decode_partial → 계속 |
| body | MVP 비범위 | — | — | — |

## 2e. 누락 처리 규칙

- `+` → space (`application/x-www-form-urlencoded` 컨텍스트)
- invalid `%XX` (XX가 hex가 아님) → `decode_partial`, 원본 유지
- invalid UTF-8 → `decode_partial`, byte sequence 유지
- duplicate params → 각각 독립 검사 (첫 번째만 취하지 않음)
- path separator decode (`%2F` → `/`) → path normalize 단계에서 처리

## 3. Rust FFI 인터페이스

> **ABI canonical source**: [rust-ffi-modules.md §4](./rust-ffi-modules.md#4-보안-스캐너-luagate_scannerso).
> 이 섹션은 스캐너 동작 설명을 보완하며, 함수 시그니처는 rust-ffi-modules.md가 단일 진실 소스다.
> **caller-allocated output buffer 방식** (rust-ffi-modules.md §3 참조). Rust는 메모리를 할당하여 반환하지 않는다.

### 3.1 ABI 시그니처 (extern "C")

```c
/* luagate_scanner ABI — canonical: rust-ffi-modules.md §4.1 */
#include "luagate.h"

/**
 * HTTP 요청 스캔.
 * 반환: LUAGATE_OK (threat_type_len > 0이면 위협 탐지됨)
 *       LUAGATE_BUDGET_EXCEEDED, LUAGATE_INTERNAL_ERROR
 *
 * threat_type_out: caller-allocated. 위협 없으면 threat_type_len = 0.
 * rule_name_out:   caller-allocated. 매칭된 내부 rule_name.
 * score_out:       0.0 ~ 1.0.
 *
 * path_raw: 디코딩 전 원본 경로 (raw 인코딩 우회 탐지용)
 * path_normalized: 정규화된 경로 (정책 평가 기준)
 */
int luagate_scan_http(
    const char  *path_raw,          size_t path_raw_len,
    const char  *path_normalized,   size_t path_normalized_len,
    const char  *query_raw,         size_t query_raw_len,
    const char  *query_normalized,  size_t query_normalized_len,
    const char  *body,              size_t body_len,         /* NULL 허용 (MVP: body_len=0) */
    char        *threat_type_out,   size_t threat_type_cap,  size_t *threat_type_len,
    char        *rule_name_out,     size_t rule_name_cap,    size_t *rule_name_len,
    double      *score_out
);

/** 초기화 (init_by_lua에서 1회). patterns_path: patterns 디렉토리 경로. */
int luagate_scanner_init(const char *patterns_path, size_t patterns_path_len);
```

### 3.2 Lua FFI 바인딩

```lua
-- lua/luagate/scanner/ffi.lua (canonical: rust-ffi-modules.md §4.2)
local ffi = require("ffi")

ffi.cdef[[
int luagate_scan_http(
    const char *path_raw,         size_t path_raw_len,
    const char *path_normalized,  size_t path_normalized_len,
    const char *query_raw,        size_t query_raw_len,
    const char *query_normalized, size_t query_normalized_len,
    const char *body,             size_t body_len,
    char *threat_type_out,  size_t threat_type_cap,  size_t *threat_type_len,
    char *rule_name_out,    size_t rule_name_cap,     size_t *rule_name_len,
    double *score_out
);
int luagate_scanner_init(const char *patterns_path, size_t patterns_path_len);
]]

local lib = ffi.load("luagate_scanner")
local THREAT_BUF_CAP = 64
local RULE_BUF_CAP   = 128

local M = {}

function M.scan(ctx)
    local threat_buf  = ffi.new("char[?]", THREAT_BUF_CAP)
    local rule_buf    = ffi.new("char[?]", RULE_BUF_CAP)
    local threat_len  = ffi.new("size_t[1]")
    local rule_len    = ffi.new("size_t[1]")
    local score       = ffi.new("double[1]")

    local rc = lib.luagate_scan_http(
        ctx.path_raw,         #ctx.path_raw,
        ctx.path_normalized,  #ctx.path_normalized,
        ctx.query_raw or "",  #(ctx.query_raw or ""),
        ctx.query_normalized or "", #(ctx.query_normalized or ""),
        ctx.body or nil,      ctx.body and #ctx.body or 0,
        threat_buf, THREAT_BUF_CAP, threat_len,
        rule_buf,   RULE_BUF_CAP,   rule_len,
        score
    )

    -- return code 직접 확인 (pcall은 Lua-level 예외 대비용 — ADR-001 §1.2 참조)
    if rc == -3 or rc == -4 then  -- BUDGET_EXCEEDED or INTERNAL_ERROR
        return nil, "scanner_fail:" .. rc
    end

    local threat_type = threat_len[0] > 0 and ffi.string(threat_buf, threat_len[0]) or nil
    local rule_name   = rule_len[0] > 0   and ffi.string(rule_buf,   rule_len[0])   or nil

    return {
        threat_type  = threat_type,
        rule_name    = rule_name,
        threat_score = score[0],
    }, nil
end

return M
```

**호출자 계약:**
- `M.scan(ctx)` 호출자는 반드시 `pcall(M.scan, ctx)`로 Lua-level exception을 흡수해야 한다.
- `scanner_fail:-3`은 `budget_exceeded`, `scanner_fail:-4`와 Lua wrapper exception은 `scanner_internal_error`로 매핑한다.
- 보안 경로에서는 위 예외를 `500`으로 전파하지 않고 `403 fail-closed`로 처리한다.

## 4. OWASP 패턴 (§5)

### 4.1 SQL Injection 패턴

주요 탐지 패턴 (OWASP CRS 기반):

```
- UNION SELECT, UNION ALL SELECT
- OR 1=1, AND 1=1
- ' OR '1'='1
- ; DROP TABLE, ; DELETE FROM
- EXEC(, EXECUTE(
- xp_cmdshell
- information_schema
- @@version, @@datadir
```

### 4.2 XSS 패턴

```
- <script>, </script>
- javascript:, vbscript:
- on* 이벤트 핸들러 (onclick=, onload= 등)
- <img src=x onerror=
- document.cookie, document.write
- eval(, setTimeout(, setInterval(
```

### 4.3 Path Traversal 패턴

멀티레이어 디코딩 후 검사 (디코더와 연계):

```
- ../  (정규화 후)
- /etc/passwd, /etc/shadow
- /proc/self
- C:\Windows\, C:\Windows\System32\
- %2e%2e%2f (디코딩 전 raw 검사도 수행)
- ..%c0%af (유니코드 우회)
```

## 5. 위협 점수 기준

| threat_score 범위 | 의미 | 기본 처리 |
|------------------|------|----------|
| 0.0 - 0.3 | 낮음 (noise) | allow (정책 미매칭 시) |
| 0.3 - 0.7 | 중간 | 정책 매칭 결과 따름 |
| 0.7 - 0.9 | 높음 | deny 권장 |
| 0.9 - 1.0 | 매우 높음 | deny |

> **중요**: 스캐너의 위협 점수는 정책 평가의 **입력값**이 될 수 있지만,
> 최종 판정은 항상 정책 규칙이 결정한다 (ADR-002).

## 5b. 미래 확장 (Future Extension)

다음 기능은 현재 구현 범위 밖이며, 별도 ADR을 통해 결정한다.

### threat_score 기반 자동 차단 scope

`threat_score_min` scope 필드를 통해 스코어 임계값을 정책 규칙에 연결하는 방식:

```yaml
# 미래 예시 — 현재 미구현
rules:
  - id: deny-high-threat-score
    scope:
      threat_score_min: 0.9   # 확장 scope 필드 (ADR 미결)
    priority: 1
    action: deny
```

<!-- ADR 필요 -->
> **TODO**: threat_score 기반 자동 차단 scope 필드 구현 시 ADR 필요 (policy-engine.md §2.1 canonical scope 키 참조)

## 6. 패턴 파일 구조

패턴은 Rust 바이너리에 컴파일 타임 임베딩 또는 런타임 로드 방식을 지원한다.

```
conf/
└── scanner-patterns/
    ├── sqli.yaml       # SQL injection 패턴
    ├── xss.yaml        # XSS 패턴
    ├── path-traversal.yaml
    ├── cmd-injection.yaml
    └── custom.yaml     # 사용자 정의 패턴
```

설계 결정은 [ADR-014: Scanner Pattern Hot Update](../design/adr/ADR-014-scanner-pattern-hot-update.md) 참조.

## 7. 성능 요구사항

- 스캔 완료 시간: < 5ms (`budget_exceeded` threshold)
- `budget_exceeded` 초과 시 → fail-closed (403)
- 메모리: 패턴 로딩 후 정적 메모리 사용 (worker당 추가 할당 최소화)
- 스레드 안전성: `SCANNER` global은 `RwLock<Option<Scanner>>`로 보호된다 ([ADR-014](../design/adr/ADR-014-scanner-pattern-hot-update.md)). `luagate_scan_http()`는 `try_read()`로 접근하여 여러 worker의 동시 읽기를 허용한다. `luagate_scanner_reload()`는 `write()` lock을 Swap 단계(< 1ms)에서만 획득하여 패턴을 원자적으로 교체한다. Reload 중(write lock 보유) `try_read()`가 실패하면 `LUAGATE_INTERNAL_ERROR`를 반환한다 (fail-closed).
- Cross-worker 동기화: `SCANNER`는 worker 프로세스 로컬 상태이므로, Admin API reload는 요청을 처리한 worker만 즉시 갱신한다. 다른 worker는 `init_worker_by_lua`에서 등록한 1초 주기 타이머(`ngx.timer.every`)로 shared dict `scanner:active_version` 변경을 감지하고, 해당 worker 내에서 `luagate_scanner_reload()`를 호출하여 동기화한다 (ADR-014 §5). 최대 전파 지연: 1초.

## 8. 의존성

- [spec/http-pipeline.md](./http-pipeline.md) — 스캐너 호출 컨텍스트
- [spec/rust-ffi-modules.md](./rust-ffi-modules.md) — FFI 공통 패턴
- [ADR-001](../design/adr/ADR-001-execution-shared-state-model.md) — FFI 호출 모델
- [ADR-014](../design/adr/ADR-014-scanner-pattern-hot-update.md) — Scanner Pattern Hot Update (RwLock, reload FFI, shared dict zone)
