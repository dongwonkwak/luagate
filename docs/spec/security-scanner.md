# Security Scanner Specification

> **ADR 참조**:
> - [ADR-001 실행/상태 공유 모델](../design/adr/ADR-001-execution-shared-state-model.md) — C FFI 통합 방식

## 1. 개요

보안 스캐너는 HTTP 요청의 경로, 쿼리 스트링, User-Agent, 본문을 검사하여
위협 유형과 위협 점수를 반환하는 Rust 구현 모듈이다.

- **구현**: `src/scanner/` (Rust cdylib)
- **빌드 산출물**: `luagate_scanner.so`
- **Lua 바인딩**: `lua/luagate/scanner/ffi.lua`
- **호출 방식**: C FFI, 동일 worker 내 동기 호출 (ADR-001)

### Admin plane 스캐너 대상 제외

Admin plane (server block identity가 `admin`인 요청)은 스캐너 대상에서 제외한다.
ADR-002 정책 평가 제외와 동일 규칙.

## 2. 탐지 위협 유형

| threat_type | 설명 | 기반 |
|-------------|------|------|
| `sqli` | SQL Injection | OWASP CRS, 패턴 매칭 |
| `xss` | Cross-Site Scripting | OWASP CRS, DOM 패턴 |
| `path-traversal` | 경로 탐색 공격 | `../`, `%2e%2e` 등 |
| `cmd-injection` | OS 커맨드 인젝션 | 셸 메타문자 패턴 |
| `ssrf` | Server-Side Request Forgery | IP/도메인 패턴 |
| `xxe` | XML External Entity | XML DTD 패턴 |
| `log4shell` | Log4j RCE (CVE-2021-44228) | `${jndi:...}` 패턴 |
| `scanner` | 자동화 스캐너 탐지 | User-Agent, 탐색 패턴 |

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
| `scanner_internal_error` | 스캐너 자체 실패 | fail-closed (403) |
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

## 3. C FFI 인터페이스

### 3.1 C 함수 시그니처

```c
// luagate_scanner.h

typedef struct {
    const char* threat_type;  // null-terminated string, NULL if no threat
    double      threat_score; // 0.0 ~ 1.0
    const char* matched_pattern; // 매칭된 패턴 식별자
} ScanResult;

// 주요 스캔 함수
// path_raw: 디코딩 전 원본 경로 (raw 인코딩 우회 탐지용)
// path_normalized: 정규화된 경로 (정책 평가 기준)
// raw 검사 책임: 디코더가 path_raw를 먼저 처리하여 인코딩 우회 패턴을 탐지하고,
//               스캐너는 path_normalized 기준으로 위협을 확인한다.
//               단, 스캐너도 path_raw를 수신하여 디코더가 놓친 raw 패턴을 이중 검사한다.
ScanResult* luagate_scan_http(
    const char* path_raw,         // 원본 요청 경로 (디코딩 전)
    size_t      path_raw_len,
    const char* path_normalized,  // 정규화된 경로
    size_t      path_len,
    const char* query_string,     // 쿼리 스트링
    size_t      query_len,
    const char* body,             // 요청 본문 (NULL 허용)
    size_t      body_len,
    const char* user_agent        // User-Agent 헤더
);

// 결과 메모리 해제
void luagate_scan_result_free(ScanResult* result);

// 초기화 (init_by_lua에서 1회 호출)
int luagate_scanner_init(const char* patterns_path);
```

### 3.2 Lua FFI 바인딩

```lua
-- lua/luagate/scanner/ffi.lua
local ffi = require("ffi")

ffi.cdef[[
typedef struct {
    const char* threat_type;
    double      threat_score;
    const char* matched_pattern;
} ScanResult;

ScanResult* luagate_scan_http(
    const char* path_raw, size_t path_raw_len,
    const char* path_normalized, size_t path_len,
    const char* query_string, size_t query_len,
    const char* body, size_t body_len,
    const char* user_agent
);
void luagate_scan_result_free(ScanResult* result);
int luagate_scanner_init(const char* patterns_path);
]]

local lib = ffi.load("luagate_scanner")

local M = {}

function M.scan(ctx)
    local result = lib.luagate_scan_http(
        ctx.path_raw, #ctx.path_raw,
        ctx.path_normalized, #ctx.path_normalized,
        ctx.query_string or "", #(ctx.query_string or ""),
        ctx.body or nil, ctx.body and #ctx.body or 0,
        ctx.user_agent or ""
    )

    if result == nil then
        return { threat_type = nil, threat_score = 0.0 }
    end

    local scan_result = {
        threat_type     = result.threat_type ~= nil and
                          ffi.string(result.threat_type) or nil,
        threat_score    = result.threat_score,
        matched_pattern = result.matched_pattern ~= nil and
                          ffi.string(result.matched_pattern) or nil,
    }

    lib.luagate_scan_result_free(result)
    return scan_result
end

return M
```

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

<!-- ADR 필요 -->
> **TODO**: 패턴 핫 업데이트(서버 재시작 없이 패턴 갱신) 구현 시 ADR 필요

## 7. 성능 요구사항

- 스캔 완료 시간: < 5ms (`budget_exceeded` threshold)
- `budget_exceeded` 초과 시 → fail-closed (403)
- 메모리: 패턴 로딩 후 정적 메모리 사용 (worker당 추가 할당 최소화)
- 스레드 안전성: 동일 worker 내 단일 스레드이므로 mutex 불필요

## 8. 의존성

- [spec/http-pipeline.md](./http-pipeline.md) — 스캐너 호출 컨텍스트
- [spec/c-ffi-modules.md](./c-ffi-modules.md) — FFI 공통 패턴
- [ADR-001](../design/adr/ADR-001-execution-shared-state-model.md) — FFI 호출 모델
