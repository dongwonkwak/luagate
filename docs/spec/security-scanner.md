# Security Scanner Specification

> **ADR 참조**:
> - [ADR-001 실행/상태 공유 모델](../design/adr/ADR-001-execution-shared-state-model.md) — C FFI 통합 방식

## 1. 개요

보안 스캐너는 HTTP 요청의 경로, 쿼리 스트링, 헤더, 본문을 검사하여
위협 유형과 위협 점수를 반환하는 Rust 구현 모듈이다.

- **구현**: `src/scanner/` (Rust cdylib)
- **빌드 산출물**: `luagate_scanner.so`
- **Lua 바인딩**: `lua/luagate/scanner/ffi.lua`
- **호출 방식**: C FFI, 동일 worker 내 동기 호출 (ADR-001)

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
ScanResult* luagate_scan_http(
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

**중요**: 스캐너의 위협 점수는 정책 평가의 **입력값**이 될 수 있지만,
최종 판정은 항상 정책 규칙이 결정한다 (ADR-002).

스코어 기반 자동 차단 정책 예시:

```yaml
rules:
  - id: deny-high-threat-score
    scope:
      threat_score_min: 0.9   # 확장 scope 필드
    priority: 1
    action: deny
```

<!-- ADR 필요 -->
> **TODO**: threat_score 기반 자동 차단 scope 필드 구현 시 ADR 필요

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

- 스캔 완료 시간: < 1ms (p99, ADR-001 §1.2 기준)
- 메모리: 패턴 로딩 후 정적 메모리 사용 (worker당 추가 할당 최소화)
- 스레드 안전성: 동일 worker 내 단일 스레드이므로 mutex 불필요

## 8. 의존성

- [spec/http-pipeline.md](./http-pipeline.md) — 스캐너 호출 컨텍스트
- [spec/c-ffi-modules.md](./c-ffi-modules.md) — FFI 공통 패턴
- [ADR-001](../design/adr/ADR-001-execution-shared-state-model.md) — FFI 호출 모델
