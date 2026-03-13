---
description: "access.log 또는 audit.log에 새 필드 추가 절차. log-schema.md, redaction 정책, 메트릭 cardinality 포함."
---

# Skill: 새 보안 로그 필드 추가

## 절차

1. **필드 설계**: 이름, 타입, nullable 여부, PII 여부, redaction 필요성 결정
2. **log-schema.md 갱신**: `docs/spec/log-schema.md`에 필드 정의 추가
3. **Lua 로그 모듈 수정**: `lua/luagate/log/http.lua` 또는 `lua/luagate/log/stream.lua`
4. **Nginx log_format 갱신** (필요 시): `conf/nginx.http.conf`
5. **PII 여부 확인**: redaction 대상이면 마스킹 로직 추가
6. **테스트 작성**: 필드 존재 확인 + redaction 테스트

## 로그 스키마 필드 추가 규칙

```lua
-- lua/luagate/log/http.lua
-- log_by_lua에서 ngx.ctx.luagate 값을 읽어 JSON 레코드 구성

local log_record = {
    timestamp        = ngx.var.time_iso8601,
    request_id       = ngx.ctx.luagate.request_id,
    -- ... 기존 22개 필드 ...
    -- 새 필드 추가:
    new_field        = ngx.ctx.luagate.new_field or ngx.null,
}
```

## PII Redaction 규칙

```lua
-- 민감 필드 목록 (추가 시 security-reviewer 검토 필요)
local REDACT_HEADERS = { "Authorization", "Cookie", "X-Api-Key" }
local REDACT_QUERY_PARAMS = { "password", "token", "secret", "api_key" }

-- query_string redaction
local function redact_query(query)
    return (query:gsub("(%w+)=([^&]+)", function(k, v)
        for _, rk in ipairs(REDACT_QUERY_PARAMS) do
            if k:lower() == rk then return k .. "=[REDACTED]" end
        end
        return k .. "=" .. v
    end))
end
```

## 메트릭 Cardinality 주의사항

새 필드를 메트릭 레이블로 추가할 때:
- **high-cardinality 값** (path_raw, user_agent, src_ip 등) → 레이블로 사용 금지
- **low-cardinality 값** (action, method, route 정규화 버전) → 레이블 허용

```lua
-- BAD: path_raw를 레이블로 사용 (cardinality 폭발)
counter{route=ngx.var.request_uri}:inc()

-- GOOD: 정규화된 route 사용
local route = normalize_route(ngx.ctx.luagate.path_normalized)
counter{route=route}:inc()
```

## 체크리스트

- [ ] log-schema.md에 필드 정의 (타입, nullable, 설명)
- [ ] Lua 로그 모듈에 필드 추가
- [ ] PII 여부 확인 + redaction 로직 (필요 시)
- [ ] Nginx log_format 갱신 (필요 시)
- [ ] 메트릭 레이블로 추가 시 cardinality 검토
- [ ] 감사 로그 필드 추가 시 audit_log 호출 수정
- [ ] 테스트: 필드 존재 + 값 검증 + redaction 검증
- [ ] security-reviewer 검토 (PII/보안 필드 변경 시)

## 로그 파일별 필드 수

| 로그 | 현재 필드 수 | 위치 |
|------|------------|------|
| access.log | 22개 | `lua/luagate/log/http.lua` |
| stream.log | 12개 | `lua/luagate/log/stream.lua` |
| audit.log | 이벤트별 가변 | `lua/luagate/log/audit.lua` |

## 참조

- `docs/spec/log-schema.md` — 전체 필드 정의 + redaction TODO
- `docs/design/adr/ADR-004` — 로그/메트릭 스키마
- `.claude/knowledge/security-patterns.md` — PII redaction 정책
