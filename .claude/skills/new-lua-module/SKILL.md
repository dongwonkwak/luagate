---
description: "새 Lua 모듈 생성 시 절차 + 체크리스트. lua/luagate/<subsystem>/<module>.lua 생성."
---

# Skill: 새 Lua 모듈 생성

## 절차

1. **위치 결정**: `lua/luagate/<subsystem>/<module>.lua`
2. **모듈 헤더 작성**:
   ```lua
   -- lua/luagate/<subsystem>/<module>.lua
   local M = {}
   -- module-level upvalue (worker-scoped 캐시용)
   local _cache = nil
   ```
3. **공개 API 정의**: `M.<function_name>` 형식
4. **마지막에 `return M`**
5. **StyLua 포맷**: `stylua --indent-type Spaces --indent-width 4 <file>`
6. **luacheck 통과**: `luacheck <file>`
7. **busted 테스트 파일 생성**: `tests/unit/<subsystem>/<module>_test.lua`

## 체크리스트

- [ ] `local M = {}` 패턴 사용 (전역 변수 없음)
- [ ] blocking I/O 없음 (io.open, os.execute 금지 — init_by_lua 제외)
- [ ] `ngx.ctx` 사용 시 요청 범위 데이터만
- [ ] worker 캐시 시 module-level upvalue 사용 (`_cached_*`)
- [ ] `return M` 마지막 라인
- [ ] 단위 테스트 파일 생성 (`tests/unit/...`)
- [ ] StyLua + luacheck 통과

## 예시

```lua
-- lua/luagate/policy/loader.lua
local M = {}
local lyaml = require("lyaml")

local _loaded_policy = nil
local _policy_version = nil

function M.load(filepath)
    -- io.open은 init_by_lua에서만 허용 (서버 기동 1회)
    local f = assert(io.open(filepath, "r"))
    local content = f:read("*all")
    f:close()
    -- ... 파싱 로직
    return policy
end

return M
-- 참조: docs/spec/policy-engine.md §4
-- 테스트: tests/unit/policy/loader_test.lua
```

## 참조

- `.claude/knowledge/openresty-patterns.md` — 패턴/안티패턴
- `.claude/knowledge/conventions.md` — 코딩 컨벤션
