---
description: "새 Rust FFI 바인딩 추가 절차. ABI 규칙, 메모리 관리, Lua 바인딩 작성 포함."
---

# Skill: 새 FFI 바인딩 추가

> ⚠️ FFI는 본질적으로 unsafe. 이 skill 수행 전 `.claude/knowledge/rust-ffi-guide.md` 필독.

## 절차

1. **Rust 함수 정의** (`src/<module>/src/lib.rs`)
   - `#[no_mangle]` + `extern "C"` 선언
   - 명명: `luagate_<module>_<action>`
   - 기본 패턴은 **caller-allocated output buffer** (`char *out`, `size_t out_cap`, `size_t *out_len`)
   - Rust가 heap 메모리를 반환하는 API는 radix tree 같은 장기 리소스 예외에만 허용

2. **free 함수 구현** (Rust가 장기 리소스를 할당하는 예외 API에만)
   ```rust
   #[no_mangle]
   pub extern "C" fn luagate_<module>_<type>_free(ptr: *mut MyType) -> i32 {
       if ptr.is_null() { return 0; }
       unsafe { drop(Box::from_raw(ptr)); }
       0
   }
   ```

3. **Lua ffi.cdef 정의** (`lua/luagate/<module>/ffi.lua`)
   ```lua
   ffi.cdef[[
   int luagate_<module>_<action>(
       const char *input, size_t input_len,
       char *out, size_t out_cap, size_t *out_len
   );
   ]]
   ```

4. **Lua 래퍼 함수 작성** (pcall 래핑 + return code 해석 + 버퍼를 Lua 문자열로 즉시 복사)

5. **init_by_lua에서 라이브러리 로드** 확인 (`lua/luagate/init.lua`)

6. **빌드 검증**: `make build-ffi`

7. **테스트 작성**: Rust `cargo test` + Lua `tests/unit/<module>/ffi_spec.lua`

## Rust ABI 체크리스트

- [ ] `#[no_mangle]` + `extern "C"` 선언
- [ ] `[profile.release] panic = "abort"` (`Cargo.toml`)
- [ ] 함수 명명: `luagate_<module>_<action>`
- [ ] 출력은 caller-allocated buffer로 기록 (`out`, `out_cap`, `out_len`)
- [ ] return code enum 의미 명시 (`0`, `1`, 음수 에러 코드)
- [ ] 최대 길이 명시 (버퍼 오버플로우 방지)
- [ ] free 함수는 Rust 소유 장기 리소스 예외에만 추가

## Lua 바인딩 체크리스트

- [ ] `pcall` 래핑 또는 동등한 보호 로직으로 LuaJIT FFI 예외 처리
- [ ] caller-allocated 버퍼를 `ffi.string()`으로 즉시 Lua 값으로 복사
- [ ] `LUAGATE_BUFFER_TOO_SMALL(-2)` 재시도 여부를 ABI 계약대로 구현
- [ ] C 포인터를 Lua 테이블에 장기 저장 금지
- [ ] `LUAGATE_NEED_MORE_DATA(1)` / `LUAGATE_INVALID_INPUT(-1)` 등 함수별 return code semantics 반영
- [ ] `ffi.cast` 시 Lua 변수 수명 관리
- [ ] Rust 소유 리소스 예외만 `ffi.gc` 또는 명시적 free 적용

## 예시 패턴

```lua
-- lua/luagate/<module>/ffi.lua
local ffi = require("ffi")

ffi.cdef[[
int luagate_mymodule_process(
    const char *input, size_t input_len,
    char *out, size_t out_cap, size_t *out_len
);
]]

local lib = ffi.load("luagate_mymodule")
local M = {}
local OUT_CAP = 256

function M.process(input)
    local out_buf = ffi.new("char[?]", OUT_CAP)
    local out_len = ffi.new("size_t[1]")

    local ok, rc = pcall(function()
        return lib.luagate_mymodule_process(input, #input, out_buf, OUT_CAP, out_len)
    end)

    if not ok then
        return nil, "ffi_error:" .. tostring(rc)
    end

    if rc == 1 then
        return nil, nil, true
    end

    if rc ~= 0 then
        return nil, "ffi_fail:" .. rc
    end

    return ffi.string(out_buf, out_len[0]), nil
end

return M
-- 테스트: tests/unit/<module>/ffi_spec.lua
```

### 예외 패턴: Rust 소유 장기 리소스

`luagate_radix_build()` 같은 장기 리소스 API만 Rust가 포인터를 할당해 반환한다. 이 경우에만 대응 `luagate_*_free()`를 정의하고 Lua에서 `ffi.gc()` 또는 명시적 free를 사용한다.

## 참조

- `.claude/knowledge/rust-ffi-guide.md` — 메모리 관리 + ABI 규칙
- `docs/spec/rust-ffi-modules.md` — FFI 통합 원칙
- `docs/design/adr/ADR-001` — FFI 모델 결정
- `lua/luagate/scanner/ffi.lua` — 참조 구현
