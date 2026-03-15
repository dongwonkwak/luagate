# Logging Contract — Native vs Lua, Decision Fields, PII Redaction, Correlation ID

> 참조: `docs/spec/log-schema.md`, ADR-004

## Native access_log vs Lua 로그 결정

| 방식 | 사용 조건 | 장점 | 단점 |
|------|---------|------|------|
| Nginx native `access_log` | 기본 필드 (상태코드, latency 등) | 버퍼링, rotate(USR1), 성능 | 동적 필드 추가 제한 |
| `log_by_lua` + `ngx.var` 설정 | LuaGate 전용 22개 필드 | 완전한 커스텀 | ngx.ctx 값 직접 접근 |

**LuaGate 방식**: `log_by_lua`에서 전체 레코드를 `cjson.encode()`로 직렬화해
`ngx.var.luagate_log_json`에 넣고, Nginx `log_format`이 이 값을 access.log에 기록.
이미 JSON 한 줄이므로 `escape=json`을 다시 적용하지 않는다.

```nginx
log_format luagate_json '$luagate_log_json';
access_log /var/log/luagate/access.log luagate_json buffer=64k flush=5s;
```

```lua
-- log_by_lua
local cjson = require("cjson.safe")

local record = {
    timestamp = ngx.var.time_iso8601,
    request_id = ngx.ctx.luagate.request_id,
    -- ... 22개 필드
}
ngx.var.luagate_log_json = assert(cjson.encode(record))
```

## Decision Fields (판정 관련 필드)

판정 결과를 포함하는 핵심 필드 — access.log에 항상 포함:

| 필드 | 타입 | Nullable | 설명 |
|------|------|----------|------|
| `action` | string | No | `"allow"` \| `"deny"` |
| `matched_rule_id` | string | Yes | 매칭 규칙 ID. 기본 정책 시 null |
| `deny_reason` | string | Yes | 차단 이유. allow 시 null |
| `threat_type` | string | Yes | 탐지 위협 유형. 없으면 null |
| `threat_score` | number | Yes | 0.0~1.0. 스캐너 미실행 시 null |
| `policy_version` | string | No | SHA256 정책 버전 해시 |

**stream.log 판정 필드:**

| 필드 | 타입 | Nullable | 설명 |
|------|------|----------|------|
| `action` | string | No | `"proxy"` \| `"deny"` |
| `deny_reason` | string | Yes | 차단 이유. proxy 시 null |
| `detected_protocol` | string | No | `tls` \| `http` \| `ssh` \| `unknown` |

## PII Redaction 정책 (ADR-007 후보)

### 필드별 처리

| 필드 | 처리 방식 |
|------|---------|
| `Authorization` 헤더 | 로그 미포함 (Bearer 토큰) |
| `Cookie` 헤더 | 로그 미포함 |
| `X-Api-Key` 헤더 | 로그 미포함 |
| `query_string` | 민감 파라미터 마스킹 (아래 참조) |
| `src_ip` | 마스킹 없음 (보안 분석 필요) |
| `user_agent` | 마스킹 없음 |
| `path_raw` | 마스킹 없음 (포렌식 필요) |

### query_string 마스킹

```lua
-- 민감 파라미터 목록
local REDACT_PARAMS = { "password", "token", "secret", "api_key", "access_token", "private_key" }

local function redact_query(query)
    if not query or query == "" then return query end
    return (query:gsub("([^&=]+)=([^&]*)", function(k, v)
        for _, rp in ipairs(REDACT_PARAMS) do
            if k:lower() == rp then
                return k .. "=[REDACTED]"
            end
        end
        return k .. "=" .. v
    end))
end

-- 적용: access.log query_string 필드
log_record.query_string = redact_query(ngx.ctx.luagate.query_normalized or "")
```

> TODO: 전체 redaction 정책 확정 시 ADR-007 작성 (log-schema.md `<!-- ADR 필요 -->` 마커)

## Correlation ID (request_id)

모든 요청에 UUID v4를 생성하여 end-to-end 추적에 사용.

```lua
-- rewrite_by_lua 또는 access_by_lua 초기화 시
local function generate_uuid()
    -- ngx.var.request_id (Nginx 내장) 또는 Lua 생성
    return string.format("%08x-%04x-4%03x-%04x-%012x",
        math.random(0, 0xffffffff),
        math.random(0, 0xffff),
        math.random(0, 0xfff),
        math.random(0x8000, 0xbfff),
        math.random(0, 0xffffffffffff)
    )
end

ngx.ctx.luagate.request_id = ngx.var.request_id or generate_uuid()
```

**전파**: `X-Request-ID` 응답 헤더로 클라이언트에 전달.
업스트림에도 `X-Request-ID: <id>` 헤더로 전달 → 업스트림 로그와 join 가능.

## 로그 로테이션 요구사항

```
USR1 시그널 → Nginx가 access.log 파일 핸들 재오픈
→ logrotate postrotate에서 `kill -USR1 $(cat /var/run/nginx.pid)` 실행

주의: log_by_lua에서 직접 io.open으로 연 파일은 USR1 영향 없음
     → Nginx native access_log만 사용해야 rotate가 올바르게 작동
```

## 참조

- `docs/spec/log-schema.md` — 전체 필드 정의
- `docs/design/adr/ADR-004` — 로그/메트릭 스키마 원본
- `lua/luagate/log/http.lua` — HTTP 로그 구현
- `lua/luagate/log/stream.lua` — Stream 로그 구현
- `lua/luagate/log/audit.lua` — 감사 로그 구현
