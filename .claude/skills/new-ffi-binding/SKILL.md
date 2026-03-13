---
description: "새 Rust FFI 바인딩 추가 절차. ABI 규칙, 메모리 관리, Lua 바인딩 작성 포함."
---

# Skill: 새 FFI 바인딩 추가

> ⚠️ FFI는 본질적으로 unsafe. 이 skill 수행 전 `.claude/knowledge/c-ffi-guide.md` 필독.

## 절차

1. **Rust 함수 정의** (`src/<module>/src/lib.rs`)
   - `#[no_mangle]` + `extern "C"` 선언
   - 명명: `luagate_<module>_<action>`
   - 반환 포인터는 `Box::into_raw()` 또는 `CString::into_raw()`

2. **free 함수 구현** (모든 heap 할당 반환에 필수)
   ```rust
   #[no_mangle]
   pub extern "C" fn luagate_<module>_<type>_free(ptr: *mut MyType) {
       if ptr.is_null() { return; }
       unsafe { drop(Box::from_raw(ptr)); }
   }
   ```

3. **Lua ffi.cdef 정의** (`lua/luagate/<module>/ffi.lua`)
   ```lua
   ffi.cdef[[
   typedef struct { ... } MyResult;
   MyResult* luagate_<module>_<action>(...);
   void luagate_<module>_<type>_free(MyResult* ptr);
   ]]
   ```

4. **Lua 래퍼 함수 작성** (pcall 래핑 + 즉시 복사 + free)

5. **init_by_lua에서 라이브러리 로드** 확인 (`lua/luagate/init.lua`)

6. **빌드 검증**: `make build-ffi`

7. **테스트 작성**: Rust `cargo test` + Lua `tests/unit/<module>/ffi_test.lua`

## Rust ABI 체크리스트

- [ ] `#[no_mangle]` + `extern "C"` 선언
- [ ] `[profile.release] panic = "abort"` (`Cargo.toml`)
- [ ] 함수 명명: `luagate_<module>_<action>`
- [ ] 문자열 반환: `CString::into_raw()` (Lua에서 free 필수)
- [ ] NULL 반환 의미 명시 (없음 vs 에러 구분)
- [ ] 최대 길이 명시 (버퍼 오버플로우 방지)
- [ ] free 함수 구현 (모든 heap 할당 반환마다)

## Lua 바인딩 체크리스트

- [ ] `pcall` 래핑 (`safe_ffi_call` 유틸리티 사용)
- [ ] 반환 포인터 즉시 Lua 테이블로 복사
- [ ] `luagate_*_free()` 호출 (복사 직후)
- [ ] C 포인터를 Lua 테이블에 장기 저장 금지
- [ ] NULL 반환 처리 (fail-closed: deny)
- [ ] `ffi.cast` 시 Lua 변수 수명 관리
- [ ] `ffi.gc` 또는 명시적 free 중 하나로 누수 방지

## 예시 패턴

```lua
-- lua/luagate/<module>/ffi.lua
local ffi = require("ffi")

ffi.cdef[[
typedef struct {
    const char* result_str;   -- NULL if none
    double      score;
} MyResult;

MyResult* luagate_mymodule_process(
    const char* input, size_t input_len
);
void luagate_mymodule_result_free(MyResult* result);
]]

local lib = ffi.load("luagate_mymodule")
local M = {}

function M.process(input)
    local result = lib.luagate_mymodule_process(input, #input)

    if result == nil then
        ngx.log(ngx.ERR, "FFI returned NULL, applying fail-closed")
        return nil, "ffi-null"
    end

    -- 즉시 Lua 값으로 복사
    local out = {
        result_str = (result.result_str ~= nil) and ffi.string(result.result_str) or nil,
        score      = result.score,
    }

    -- C 메모리 즉시 해제
    lib.luagate_mymodule_result_free(result)

    return out, nil
end

return M
-- 테스트: tests/unit/<module>/ffi_test.lua
```

## 참조

- `.claude/knowledge/c-ffi-guide.md` — 메모리 관리 + ABI 규칙
- `docs/spec/c-ffi-modules.md` — FFI 통합 원칙
- `docs/design/adr/ADR-001` — FFI 모델 결정
- `lua/luagate/scanner/ffi.lua` — 참조 구현
