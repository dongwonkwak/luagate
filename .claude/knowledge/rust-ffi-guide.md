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

LuaGate FFI는 **caller-allocated buffer** 모델을 사용한다.
Rust는 메모리를 할당하여 반환하지 않고, Lua가 미리 할당한 버퍼에 결과를 기록한다.
따라서 `free` 함수가 필요 없다.

### 규칙 1: Caller-allocated buffer 패턴

```lua
-- GOOD: Lua가 버퍼를 할당하고 Rust가 결과를 기록
local threat_type_buf = ffi.new("char[?]", 64)
local rule_name_buf   = ffi.new("char[?]", 128)
local threat_type_len = ffi.new("size_t[1]")
local rule_name_len   = ffi.new("size_t[1]")
local score           = ffi.new("double[1]")

local rc = lib.luagate_scan_http(
    path_raw, #path_raw,
    path_normalized, #path_normalized,
    query_raw, #query_raw,
    query_normalized, #query_normalized,
    body, body_len,
    threat_type_buf, 64, threat_type_len,
    rule_name_buf, 128, rule_name_len,
    score
)
-- rc가 int 반환 → 버퍼에서 Lua 문자열로 복사
if rc == 0 and threat_type_len[0] > 0 then
    local threat_type = ffi.string(threat_type_buf, threat_type_len[0])
end
```

### 규칙 2: Lua 문자열 → C 포인터 수명 관리

```lua
-- ffi.cast는 Lua 문자열을 복사하지 않음 — GC 전까지 참조 유지 필수
local path = ngx.ctx.luagate.path_raw  -- Lua 변수로 참조 유지
local rc = lib.luagate_scan_http(
    ffi.cast("const char*", path), #path,  -- path 변수가 GC되지 않도록
    ...
)
-- FFI 호출 완료 후 path 참조 소멸 가능
```

### 규칙 3: Rust 할당 리소스는 Rust free 함수로 해제

radix tree 등 Rust가 소유하는 장기 리소스는 반드시 대응하는 free 함수로 해제한다.

```lua
-- radix tree: Rust가 할당, Lua가 포인터를 보관
local tree = lib.luagate_radix_build(...)
-- 사용 완료 후 반드시 해제
lib.luagate_radix_free(tree)
```

### 규칙 4: C 포인터를 Lua 테이블에 장기 저장 주의

```lua
-- BAD: ngx.ctx에 FFI 포인터 저장 (요청 종료 시 dangling)
ngx.ctx.scan_ptr = result  -- 절대 금지

-- GOOD: 즉시 Lua 값으로 변환
ngx.ctx.luagate.threat_type = ffi.string(threat_type_buf, threat_type_len[0])
```

## Return Code 처리 vs Native Crash 경계

| 상황 | 반환값 (int) | Lua 처리 |
|------|-------------|---------|
| 정상, 위협 없음 | `0` (threat_type_len=0) | allow 진행 |
| 위협 탐지 | `0` (threat_type_len>0) | deny 또는 정책 판정 |
| 예산 초과 | `LUAGATE_BUDGET_EXCEEDED(-3)` | fail-closed |
| 타임아웃 | `LUAGATE_TIMEOUT(-5)` | fail-closed |
| 에러 | 음수 에러 코드 | fail-closed: deny + ERR 로그 |
| Rust panic (`panic=abort`) | 프로세스 abort | Nginx master가 재시작 (복구 불가) |

```lua
local rc = lib.luagate_scan_http(...)
if rc ~= 0 then
    ngx.log(ngx.ERR, "scanner failed with rc=", rc, ", applying fail-closed")
    return "deny", "scanner-error"
end
```

## Rust ABI 규칙

모든 FFI export 함수:
- `#[no_mangle]` + `extern "C"` 선언
- 함수 명명: `luagate_<module>_<action>`
- **caller-allocated buffer 패턴**: 결과는 caller가 미리 할당한 버퍼에 기록, `*_len` out 파라미터로 실제 길이 반환
- 장기 리소스 (radix tree 등): Rust가 할당, 대응 `free` 함수 제공
- 최대 길이 계약: `path_raw_len`, `query_len` 등 명시적 길이 인수 전달 (NULL-terminated에 의존하지 않음)

## 에러 코드 맵

| 반환값 | 의미 | Lua 처리 |
|--------|------|---------|
| `0` | 성공 | threat_type_len 확인 후 allow/deny |
| `LUAGATE_BUDGET_EXCEEDED(-3)` | 시간 예산 초과 | fail-closed |
| `LUAGATE_TIMEOUT(-5)` | 하드 타임아웃 | fail-closed |
| 기타 음수 | 내부 에러 | fail-closed |
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
