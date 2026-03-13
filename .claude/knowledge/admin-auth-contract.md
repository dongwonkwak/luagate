# Admin Auth Contract — 인증 헤더, Timing-Safe Compare, 401 Body, Rate Limit

> 참조: `docs/spec/admin-api.md §2`, ADR-004 §6

## 인증 헤더 스펙

```
Authorization: Bearer <token>
```

- 토큰 소스: 환경변수 `LUAGATE_ADMIN_TOKEN` (서버 기동 시 로드)
- 모든 엔드포인트 필수 (예외: `GET /health`)
- OPTIONS preflight: 인증 없이 204 반환 (CORS)

## Timing-Safe Compare (constant-time 비교)

Bearer 토큰 비교는 반드시 constant-time compare를 사용해야 한다.
단순 `==` 비교는 타이밍 공격(timing attack)에 취약하다.

```lua
-- lua/luagate/admin/auth.lua

-- GOOD: constant-time compare
local function constant_time_compare(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then
        return false
    end
    if #a ~= #b then
        -- 길이 차이도 노출하지 않으려면 dummy compare를 수행하지만
        -- LuaGate에서는 길이 노출을 허용 (토큰 길이는 고정값)
        return false
    end
    local result = 0
    for i = 1, #a do
        result = bit.bor(result, bit.bxor(string.byte(a, i), string.byte(b, i)))
    end
    return result == 0
end

-- BAD: 단순 비교 (타이밍 공격 가능)
if provided_token == env_token then  -- 금지
```

## 인증 검증 흐름

```lua
function M.verify()
    -- 1. OPTIONS preflight: 인증 없이 통과
    if ngx.req.get_method() == "OPTIONS" then
        return true
    end

    -- 2. Authorization 헤더 추출
    local auth_header = ngx.req.get_headers()["Authorization"]
    if not auth_header then
        M._reject("missing_token")
        return false
    end

    -- 3. Bearer prefix 확인
    local prefix = "Bearer "
    if auth_header:sub(1, #prefix) ~= prefix then
        M._reject("invalid_format")
        return false
    end

    -- 4. constant-time 토큰 비교
    local provided = auth_header:sub(#prefix + 1)
    local expected = os.getenv("LUAGATE_ADMIN_TOKEN") or ""

    if not constant_time_compare(provided, expected) then
        M._reject("invalid_token")
        return false
    end

    return true
end

function M._reject(reason)
    -- 감사 로그 (인증 실패는 항상 기록)
    local audit = require("luagate.log.audit")
    audit.log("auth_failure", {
        src_ip = ngx.var.remote_addr,
        path   = ngx.var.request_uri,
        reason = reason,
    })

    ngx.status = 401
    ngx.header["Content-Type"] = "application/json"
    ngx.say(require("cjson").encode({
        error   = "Unauthorized",
        message = "Invalid or missing Bearer token",
    }))
    ngx.exit(401)
end
```

## 401 응답 Body

```json
{
  "error": "Unauthorized",
  "message": "Invalid or missing Bearer token"
}
```

- `WWW-Authenticate` 헤더: 포함하지 않음 (Bearer realm 노출 불필요)
- Response body는 위 형식 고정 — 상세 이유(`reason`) 미포함 (정보 노출 방지)
- 감사 로그에는 `reason` 포함 (`missing_token`, `invalid_token`, `invalid_format`)

## Rate Limit Scope

- **단위**: Admin 서버 접속 IP 기준
- **적용**: 인증 실패 누적 시 rate limit 고려 (현재 MVP: 미구현)
- **scope**: Admin 서버 전체 (`127.0.0.1:8080`), 개별 엔드포인트 단위 아님
- TODO: 인증 실패 rate limit 구현 시 ADR 필요

## 감사 로그 필드 (인증 실패 시)

```json
{
  "timestamp": "2026-03-13T12:34:56Z",
  "event": "auth_failure",
  "src_ip": "127.0.0.1",
  "path": "/api/v1/policies",
  "reason": "missing_token | invalid_token | invalid_format"
}
```

## 환경 변수 보안

- `LUAGATE_ADMIN_TOKEN`: Docker secret 또는 환경변수로 주입
- nginx.conf의 `env` 지시자로 Lua에서 접근 가능:
  ```nginx
  env LUAGATE_ADMIN_TOKEN;
  ```
- 로그에 토큰값 절대 미포함 (audit_log에서도 토큰 필드 없음)

## 참조

- `docs/spec/admin-api.md §2` — 인증 스펙
- `docs/design/adr/ADR-004 §6` — 관리면 보안
- `lua/luagate/admin/auth.lua` — 구현 위치
- `.claude/knowledge/security-patterns.md` — Admin 보안 패턴
