# Rust FFI 가이드 — 메모리 관리 & 안전 규칙

> ⚠️ **FFI는 본질적으로 unsafe하다.** 잘못된 포인터 연산, 이중 해제, 버퍼 오버플로우는
> Lua pcall로도 복구할 수 없는 worker abort를 유발한다.
> 아래 규칙을 엄격히 준수하고, FFI 코드 변경 시 반드시 security-reviewer와 협의한다.

> 참조: `docs/spec/rust-ffi-modules.md`, `docs/design/adr/ADR-001`

## FFI 통합 원칙 (ADR-001)

1. **동일 worker 내 동기 호출**: IPC 없음, `ffi.load()` 후 직접 호출
2. **pcall 래핑**: Lua 레벨 예외는 `pcall`로 감쌈. 단, native abort/segfault는 복구 불가
3. **실패 시 deny**: FFI 오류 → fail-closed (deny 처리 + ERR 로그)
4. **< 1ms 완료**: worker 이벤트 루프 블로킹 금지

## 모듈 목록

| 모듈 | 라이브러리 | 소스 | 역할 |
|------|----------|------|------|
| 보안 스캐너 | `luagate_scanner.so` | `src/scanner/` | 위협 탐지, OWASP 패턴 매칭 |
| URL 디코더 | `luagate_decoder.so` | `src/decoder/` | 멀티레이어 인코딩 디코딩/정규화 |

## 라이브러리 로드 (init_by_lua에서 1회)

```lua
-- lua/luagate/init.lua
local ffi = require("ffi")
local scanner_lib = ffi.load("luagate_scanner")
local decoder_lib = ffi.load("luagate_decoder")

-- worker별 캐시 등록
package.loaded["_luagate_scanner_lib"] = scanner_lib
package.loaded["_luagate_decoder_lib"] = decoder_lib
```

## 안전한 FFI 호출 패턴

```lua
-- lua/luagate/ffi_util.lua
local function safe_ffi_call(fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then
        ngx.log(ngx.ERR, "FFI call failed: ", tostring(result))
        return nil, result
    end
    return result, nil
end
```

## 메모리 관리 규칙 (엄격 준수)

### 규칙 1: Rust 할당 메모리는 Rust free 함수로만 해제

```lua
-- GOOD: 즉시 Lua 값으로 복사 + Rust free
local result = lib.luagate_scan_http(...)
local scan_result = {
    threat_type  = (result.threat_type ~= nil) and ffi.string(result.threat_type) or nil,
    threat_score = result.threat_score,
}
lib.luagate_scan_result_free(result)  -- 반드시 호출
result = nil  -- C 포인터 참조 제거

-- BAD: free 미호출 → 메모리 누수
local result = lib.luagate_scan_http(...)
return result.threat_score  -- result free 안됨
```

### 규칙 2: C 포인터를 Lua 테이블에 장기 저장 금지

```lua
-- BAD: C 포인터 저장 후 나중에 접근 (Rust free 이후 dangling pointer)
ngx.ctx.scan_ptr = result  -- 절대 금지

-- GOOD: 즉시 복사 후 C 포인터 해제
ngx.ctx.luagate.threat_type = ffi.string(result.threat_type)
lib.luagate_scan_result_free(result)
```

### 규칙 3: Lua 문자열 → C 포인터 수명 관리

```lua
-- ffi.cast는 Lua 문자열을 복사하지 않음 — GC 전까지 참조 유지 필수
local path = ngx.ctx.luagate.path_raw  -- Lua 변수로 참조 유지
local result = lib.luagate_scan_http(
    ffi.cast("const char*", path), #path,  -- path 변수가 GC되지 않도록
    ...
)
-- FFI 호출 완료 후 path 참조 소멸 가능
```

### 규칙 4: ffi.gc를 사용한 자동 해제 (권장 패턴)

```lua
-- 자동 해제 등록으로 누수 방지
local result = ffi.gc(lib.luagate_scan_http(...), lib.luagate_scan_result_free)
-- result가 GC되면 자동으로 luagate_scan_result_free 호출
local threat_type = (result.threat_type ~= nil) and ffi.string(result.threat_type) or nil
-- 명시적 해제도 가능: lib.luagate_scan_result_free(ffi.gc(result, nil))
```

## Return Code 처리 vs Native Crash 경계

| 상황 | 반환 | Lua 처리 |
|------|------|---------|
| 정상 처리, 위협 없음 | `ScanResult*` (threat_type=NULL) | threat_score=0.0으로 처리 |
| 패턴 매칭 오류 | `ScanResult*` (threat_score=0.0) | 스캔 생략, warn 로그 |
| NULL 반환 | `NULL` | fail-closed: deny 처리 |
| Rust panic | worker abort | Nginx master가 재시작 (복구 불가) |
| segfault / abort | process abort | Nginx master가 재시작 (복구 불가) |

```lua
local result = lib.luagate_scan_http(...)
if result == nil then
    -- NULL 반환 = 초기화 실패 또는 심각한 에러
    ngx.log(ngx.ERR, "scanner returned NULL, applying fail-closed")
    return "deny", "scanner-error"
end
```

## Rust ABI 규칙

모든 FFI export 함수:
- `#[no_mangle]` + `extern "C"` 선언
- 함수 명명: `luagate_<module>_<action>`
- 문자열 반환: `CString::into_raw()` (Lua에서 반드시 `luagate_*_free()` 호출)
- Nullable 포인터: NULL 의미를 항상 명시 (NULL = 없음 vs NULL = 에러 구분)
- 최대 길이 계약: `path_raw_len`, `query_len` 등 명시적 길이 인수 전달 (NULL-terminated에 의존하지 않음)

## 에러 코드 맵 (scanner)

| 반환값 | 의미 | Lua 처리 |
|--------|------|---------|
| `result != NULL, threat_type == NULL` | 위협 없음 | allow 진행 |
| `result != NULL, threat_type != NULL` | 위협 탐지 | deny 또는 정책 판정 |
| `result == NULL` | 초기화 실패 또는 OOM | fail-closed |
| Rust panic (`panic=abort`) | 프로세스 abort | Nginx master 재시작 |

## 빌드 파이프라인

```bash
make build-ffi
# = cargo build --release (src/scanner, src/decoder)
# + cp *.so lib/
```

```toml
# Cargo.toml 공통 설정
[profile.release]
opt-level = 3
lto = true
panic = "abort"  # UB 방지: Rust panic → worker abort (Nginx master 재시작)
```

## 테스트

```lua
-- tests/unit/scanner_ffi_test.lua
describe("Scanner FFI", function()
    it("SQL injection을 탐지한다", function()
        local result = scanner.scan({
            path_raw = "/search",
            path_normalized = "/search",
            query_string = "id=1' OR '1'='1",
        })
        assert.equals("sqli", result.threat_type)
        assert.truthy(result.threat_score > 0.7)
    end)

    it("NULL body를 안전하게 처리한다", function()
        local result = scanner.scan({ path_raw = "/ok", path_normalized = "/ok" })
        assert.is_nil(result.threat_type)
    end)
end)
-- 참조: lua/luagate/scanner/ffi.lua
```
