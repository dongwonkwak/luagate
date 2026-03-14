---
description: "새 ngx.shared.DICT zone 추가 절차. prefix 규칙, safe_set 패턴, fail mode 정의 포함."
---

# Skill: 새 Shared Dict Zone 추가

## 절차

1. **zone 설계**: 이름, 크기, 값 shape, TTL, fail mode 결정
2. **nginx.conf에 zone 선언**:
   ```nginx
   lua_shared_dict luagate_<name> <size>;
   ```
3. **Lua 래퍼 모듈 작성** (`lua/luagate/<name>/store.lua`)
4. **init_by_lua 초기화** 추가
5. **zone-registry.md 업데이트** (`docs/spec/` 또는 `.claude/knowledge/`)
6. **테스트 작성**: zone 초기화, safe_set, 읽기, 만료 테스트

## Zone 명명 규칙

- **필수**: `luagate_` prefix
- kebab-case 금지 (nginx conf 문법): `luagate_my_zone` (underscore 사용)

## 기존 Zone 목록

| Zone | 크기 | 역할 | Fail Mode |
|------|------|------|-----------|
| `luagate_policy` | 10m | 정책 blob + active pointer | fail-closed (LKG) |
| `luagate_metrics` | 5m | 카운터/게이지 | fail-open (warn) |
| `luagate_connections` | 1m | 활성 연결 수 | fail-open (warn) |

## safe_set 패턴 (no-memory 처리 포함)

```lua
-- GOOD: no-memory 에러 경로 처리
local ok, err, forcible = ngx.shared.luagate_<name>:safe_set(key, value, ttl)
if not ok then
    if err == "no memory" then
        -- forcible=true면 다른 키가 삭제됨 (zone 크기 증가 고려)
        ngx.log(ngx.WARN, "shdict no memory: ", key, " forcible=", tostring(forcible))
        -- fail mode에 따라 fail-open (continue) or fail-closed (deny)
        return false, "no-memory"
    end
    ngx.log(ngx.ERR, "shdict error: ", err)
    return false, err
end

-- BAD: 에러 무시
ngx.shared.luagate_x:safe_set(key, value)  -- 에러 미처리
```

## 체크리스트

- [ ] Zone 이름: `luagate_` prefix 필수
- [ ] nginx.conf에 `lua_shared_dict` 선언
- [ ] 크기: 예상 엔트리 수 × 평균 값 크기 × 1.5 (여유)
- [ ] safe_set no-memory 에러 처리
- [ ] TTL 필요 시 명시 (0 = 만료 없음)
- [ ] fail mode 정의: fail-open or fail-closed
- [ ] zone-registry 문서 업데이트
- [ ] 테스트 작성 (정상 경로 + no-memory 에러)

## Zone 문서화 템플릿

```markdown
| `luagate_<name>` | Writer: ... | Reader: ... | Phase: ... |
| Fail Mode: fail-open/closed | HTTP/Stream | Reload 민감도: 높음/낮음 |
```

## 참조

- `.claude/knowledge/architecture.md` — Zone 상세 표
- `.claude/knowledge/openresty-patterns.md` — safe_set 패턴
- `docs/design/adr/ADR-001` — shared dict 설계
