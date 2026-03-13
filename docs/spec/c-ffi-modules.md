# C FFI Modules Specification

> **ADR 참조**:
> - [ADR-001 실행/상태 공유 모델](../design/adr/ADR-001-execution-shared-state-model.md) — C FFI 통합 방식 및 실패 정책

## 1. 개요

LuaGate는 고성능 처리가 필요한 두 모듈을 Rust로 구현하고 LuaJIT FFI를 통해 호출한다.

| 모듈 | 라이브러리 | 소스 | 역할 |
|------|-----------|------|------|
| 보안 스캐너 | `luagate_scanner.so` | `src/scanner/` | 위협 탐지, OWASP 패턴 매칭 |
| URL 디코더 | `luagate_decoder.so` | `src/decoder/` | 멀티레이어 인코딩 디코딩/정규화 |

## 2. FFI 통합 원칙 (ADR-001)

1. **동일 worker 내 동기 호출**: IPC 없음. `ffi.load()` 후 직접 함수 호출
2. **pcall 래핑**: 모든 FFI 호출을 `pcall`로 감싸 Lua 패닉 방지
3. **실패 처리**: FFI 오류 시 deny 처리 후 에러 로그 기록 (ADR-001 §1.2)
4. **타임아웃**: FFI 함수는 < 1ms 완료 보장. worker 이벤트 루프 블로킹 금지

## 3. Rust 빌드 설정

```toml
# src/scanner/Cargo.toml
[package]
name = "luagate-scanner"
version = "0.1.0"
edition = "2021"

[lib]
name = "luagate_scanner"
crate-type = ["cdylib"]

[dependencies]
regex = "1.9"
serde = { version = "1.0", features = ["derive"] }
serde_yaml = "0.9"

[profile.release]
opt-level = 3
lto = true
codegen-units = 1
panic = "abort"  # .so에서 Rust panic이 프로세스를 종료하지 않도록
```

```toml
# src/decoder/Cargo.toml
[package]
name = "luagate-decoder"
version = "0.1.0"

[lib]
name = "luagate_decoder"
crate-type = ["cdylib"]

[dependencies]
percent-encoding = "2.3"
unicode-normalization = "0.1"
```

## 4. C ABI 규칙

모든 Rust 함수는 `#[no_mangle]`과 `extern "C"` 로 선언:

```rust
// src/scanner/src/lib.rs
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_double, c_int};

#[repr(C)]
pub struct ScanResult {
    pub threat_type: *mut c_char,     // NULL if no threat
    pub threat_score: c_double,
    pub matched_pattern: *mut c_char, // NULL if no threat
}

#[no_mangle]
pub extern "C" fn luagate_scan_http(
    path_normalized: *const c_char,
    path_len: usize,
    query_string: *const c_char,
    query_len: usize,
    body: *const c_char,
    body_len: usize,
    user_agent: *const c_char,
) -> *mut ScanResult {
    // ...
}

#[no_mangle]
pub extern "C" fn luagate_scan_result_free(result: *mut ScanResult) {
    if !result.is_null() {
        unsafe { drop(Box::from_raw(result)) }
    }
}
```

## 5. Lua FFI 공통 패턴

### 5.1 라이브러리 로드 (init_by_lua에서 1회)

```lua
-- lua/luagate/init.lua
local ffi = require("ffi")

-- .so 경로는 nginx.conf의 lua_package_cpath에서 설정
local scanner_lib = ffi.load("luagate_scanner")
local decoder_lib = ffi.load("luagate_decoder")

-- 전역 등록 (worker별 캐시)
package.loaded["_luagate_scanner_lib"] = scanner_lib
package.loaded["_luagate_decoder_lib"] = decoder_lib
```

### 5.2 안전한 FFI 호출 래퍼

```lua
-- lua/luagate/ffi_util.lua
local M = {}

function M.safe_call(fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then
        ngx.log(ngx.ERR, "FFI call failed: ", tostring(result))
        return nil, result
    end
    return result, nil
end

return M
```

### 5.3 문자열 변환 유틸리티

```lua
local ffi = require("ffi")

-- Lua string → C char* (NULL-terminated)
local function lua_to_cstr(s)
    return ffi.cast("const char*", s)
end

-- C char* → Lua string (NULL 안전)
local function cstr_to_lua(cptr)
    if cptr == nil or cptr == ffi.null then
        return nil
    end
    return ffi.string(cptr)
end
```

## 6. 메모리 관리

| 규칙 | 내용 |
|------|------|
| Rust가 할당한 메모리 | 반드시 Rust의 `*_free()` 함수로 해제 |
| Lua 문자열 → C | `ffi.cast`로 포인터 전달. Lua GC가 문자열 소유 |
| 구조체 수명 | FFI 함수 반환 후 즉시 Lua 값으로 복사, C 포인터 저장 금지 |

**메모리 누수 방지 패턴:**

```lua
local result = lib.luagate_scan_http(...)
-- 결과를 Lua 테이블로 즉시 복사
local scan_result = {
    threat_type  = cstr_to_lua(result.threat_type),
    threat_score = result.threat_score,
}
-- C 메모리 즉시 해제
lib.luagate_scan_result_free(result)
-- 이후 scan_result만 사용
```

## 7. 빌드 파이프라인

```makefile
# Makefile
.PHONY: build-ffi

build-ffi:
    cd src/scanner && cargo build --release
    cd src/decoder && cargo build --release
    cp src/scanner/target/release/libluagate_scanner.so lib/
    cp src/decoder/target/release/libluagate_decoder.so lib/

# nginx.conf에서 lib/ 디렉토리를 lua_package_cpath에 추가
```

## 8. 테스트

### 8.1 Rust 단위 테스트

```bash
cd src/scanner && cargo test
cd src/decoder && cargo test
```

### 8.2 FFI 통합 테스트

```lua
-- tests/unit/scanner_ffi_test.lua
describe("Scanner FFI", function()
    it("detects SQL injection", function()
        local result = scanner.scan({
            path_normalized = "/search",
            query_string = "id=1' OR '1'='1",
        })
        assert.equals("sqli", result.threat_type)
        assert.truthy(result.threat_score > 0.7)
    end)
end)
```

## 9. 의존성

- [spec/security-scanner.md](./security-scanner.md) — 스캐너 상세
- [spec/http-pipeline.md](./http-pipeline.md) — FFI 호출 컨텍스트
- [ADR-001](../design/adr/ADR-001-execution-shared-state-model.md) — FFI 모델 결정
