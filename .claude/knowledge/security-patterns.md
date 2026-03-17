# 보안 패턴 & OWASP 모듈 작성 기준

> 참조: `docs/spec/security-scanner.md`, `docs/spec/http-pipeline.md`, ADR-004

## 요청 처리 보안 결정 행렬 (Precedence Matrix)

모든 보안 결정은 아래 우선순위 순서로 처리된다.

| 우선순위 | 조건 | 결과 |
|---------|------|------|
| 1 (최고) | 디코딩 에러 (malformed encoding) | **block** — decode error는 무조건 차단 |
| 2 | 스캐너 hit (threat_type != nil) | **block** — 스캐너 탐지는 정책 무관 차단 |
| 3 | 정책 allow + 스캐너 hit | **block** — 정책이 allow여도 스캐너 hit이면 차단 |
| 4 | 메트릭 카운터 에러 | **allow + warn** — 메트릭 실패는 요청을 막지 않음 |
| 5 (최저) | 스캐너 optional 미구성 | **allow** — 스캐너 없으면 정책만으로 판정 |

```lua
-- access_by_lua 판정 흐름
local decode_result, decode_err = safe_ffi_call(decoder.normalize, path_raw, query_raw)
if decode_err then
    return deny("decode-error")  -- 우선순위 1: 무조건 차단
end

local scan_result = nil
if scanner_available then
    scan_result, scan_err = safe_ffi_call(scanner.scan, ctx)
    if scan_result and scan_result.threat_type ~= nil then
        return deny("scanner:" .. scan_result.threat_type)  -- 우선순위 2, 3
    end
end

local policy_action = policy.evaluate(ctx)  -- 스캐너 통과 후 정책 판정
```

### 스캐너가 optional feature인 경우

```lua
-- scanner_available: init_by_lua에서 .so 로드 성공 여부로 설정
local scanner_available = pcall(function()
    ffi.load("luagate_scanner")
end)

if not scanner_available then
    ngx.log(ngx.WARN, "scanner not available, policy-only mode")
    -- 스캐너 없이 정책 판정만 수행 (우선순위 5)
end
```

## 보안 경로: Fail-Closed 원칙

```lua
-- 모든 보안 경로는 fail-closed: 에러 시 deny
local ok, result = pcall(scanner.scan, ctx)
if not ok then
    ngx.log(ngx.ERR, "scanner error: ", result)
    return deny("scanner-unavailable")  -- 에러 → deny (fail-closed)
end
```

예외: 메트릭 카운터 실패는 fail-open (위 행렬 우선순위 4).

## Admin API 보안 계약

- **바인딩**: `127.0.0.1:8080` 전용 (외부 노출 금지)
- **인증**: `Authorization: Bearer <token>` (환경변수 `LUAGATE_ADMIN_TOKEN`)
- **타이밍 안전 비교**: 토큰 비교 시 `string.len` 기반 단순 비교 금지, constant-time compare 사용

```lua
-- lua/luagate/admin/auth.lua
-- NOTE: 길이 불일치 시 조기 반환 금지 — 타이밍 유출 위험.
-- max(#a, #b)까지 반복하고, 길이 XOR을 누적값 초기값으로 사용한다.
local function constant_time_compare(a, b)
    local len_a = #a
    local len_b = #b
    local max_len = len_a > len_b and len_a or len_b
    local result = bit.bxor(len_a, len_b) -- non-zero if lengths differ
    for i = 1, max_len do
        local byte_a = (i <= len_a) and a:byte(i) or 0
        local byte_b = (i <= len_b) and b:byte(i) or 0
        result = bit.bor(result, bit.bxor(byte_a, byte_b))
    end
    return result == 0
end

local token = ngx.req.get_headers()["Authorization"]
if not token or not token:match("^Bearer ") then
    ngx.status = 401
    ngx.say('{"error":"Unauthorized"}')
    audit_log("auth_failure", { reason = "missing_token" })
    return ngx.exit(401)
end

local provided = token:sub(8)  -- "Bearer " 이후
if not constant_time_compare(provided, env_token) then
    -- 401 응답은 timing 공격 방지 위해 일정 시간 후 반환
    audit_log("auth_failure", { reason = "invalid_token" })
    ngx.status = 401
    return ngx.exit(401)
end
```

- **401 응답 body**: `{"error": "Unauthorized", "message": "Invalid or missing Bearer token"}`
- **Rate limit scope**: Admin IP 기준 (rate limit은 admin 서버 전체, 개별 엔드포인트 아님)
- **감사 필드**: timestamp, event, src_ip, path, reason (인증 실패 시)

## OWASP 패턴 작성 기준

### 스캐너 패턴 파일 위치

```
conf/scanner-patterns/
├── sqli.yaml          # SQL Injection (OWASP CRS 기반)
├── xss.yaml           # XSS
├── path-traversal.yaml
├── cmd-injection.yaml
└── custom.yaml        # 사이트별 커스텀
```

### 패턴 작성 원칙

1. **False Positive 최소화**: 정상 트래픽 차단 없이 OWASP 위협만 탐지
2. **멀티레이어 디코딩 후 검사**: URL 디코더(rewrite 단계) 완료 후 path_normalized 기준
3. **raw + normalized 이중 검사**: 디코더가 놓친 raw 패턴도 스캐너가 재검사
4. **threat_score 기준**: 0.7+ = deny 권장, 0.9+ = deny 확정
5. **커스텀 패턴 분리**: OWASP CRS 패턴과 프로젝트별 패턴을 separate 파일로 관리

### 위협 유형별 핵심 패턴

| threat_type | 기반 | 주요 패턴 |
|------------|------|---------|
| `sqli` | OWASP CRS | `UNION SELECT`, `OR 1=1`, `; DROP TABLE`, `xp_cmdshell` |
| `xss` | OWASP CRS | `<script>`, `javascript:`, `on*=`, `document.cookie` |
| `path-traversal` | custom | `../`, `/etc/passwd`, `%2e%2e%2f`, `..%c0%af` |
| `cmd-injection` | custom | 셸 메타문자: `;`, `\|`, `&&`, `$(`, `` ` `` |
| `ssrf` | custom | 내부 IP 패턴: `169.254.`, `10.`, `127.` |
| `log4shell` | CVE-2021-44228 | `${jndi:`, `${lower:j}` |

## zone prefix 규칙

모든 shared dict zone 이름은 `luagate_` prefix 필수:
- ✅ `luagate_policy`, `luagate_metrics`, `luagate_connections`
- ❌ `policy`, `metrics`, `cache`

이유: Nginx shared dict 네임스페이스 충돌 방지.

## 보안 헤더 규칙

```nginx
# Admin 서버 응답 헤더
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "DENY" always;
add_header Cache-Control "no-store" always;
```

## 로그 Redaction 정책 (ADR-007 후보)

```lua
-- PII 필드 마스킹 대상
local REDACT_FIELDS = {
    "Authorization",  -- Bearer 토큰
    "Cookie",         -- 세션 쿠키
    "X-Api-Key",      -- API 키
}

-- query_string에서 민감 파라미터 마스킹
local REDACT_QUERY_PARAMS = { "password", "token", "secret", "api_key" }

local function redact_query(query)
    return (query:gsub("(%w+)=([^&]+)", function(k, v)
        for _, rk in ipairs(REDACT_QUERY_PARAMS) do
            if k:lower() == rk then return k .. "=[REDACTED]" end
        end
        return k .. "=" .. v
    end))
end
```

> TODO: 로그 redaction 정책 확정 시 ADR-007 작성 필요 (log-schema.md 마커 참조)
