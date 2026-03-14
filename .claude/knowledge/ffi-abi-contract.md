# FFI ABI Contract — 함수별 Ownership, NULLability, Max Length, Error Code Map

> 참조: `docs/spec/c-ffi-modules.md`, ADR-001

## luagate_scanner.so

### `luagate_scan_http`

```c
ScanResult* luagate_scan_http(
    const char* path_raw,         size_t path_raw_len,
    const char* path_normalized,  size_t path_len,
    const char* query_string,     size_t query_len,
    const char* body,             size_t body_len,  // NULL 허용
    const char* user_agent
);
```

| 인수 | Ownership | NULLable | Max Length | 비고 |
|------|----------|---------|-----------|------|
| `path_raw` | Caller (Lua string) | No | 8192 bytes | 원본 경로 |
| `path_normalized` | Caller (Lua string) | No | 8192 bytes | 정규화된 경로 |
| `query_string` | Caller (Lua string) | Yes (→ len=0) | 65536 bytes | 쿼리 스트링 |
| `body` | Caller (Lua string) | Yes (→ len=0) | 16384 bytes | 본문 (16KB 제한) |
| `user_agent` | Caller (Lua string) | Yes (→ "") | 2048 bytes | User-Agent |

**반환값 Ownership**: Rust가 할당. 반드시 `luagate_scan_result_free()` 로 해제.

**반환값 NULLability**:
- 반환 포인터 `NULL`: 초기화 실패 또는 내부 오류 → fail-closed (deny)
- `ScanResult.threat_type == NULL`: 위협 없음 → allow 진행
- `ScanResult.matched_pattern == NULL`: 패턴 정보 없음 (정상)

**에러 코드 맵**:

| 반환 상태 | 의미 | Lua 처리 |
|---------|------|---------|
| 포인터 != NULL, threat_type == NULL | 스캔 완료, 위협 없음 | allow 진행 |
| 포인터 != NULL, threat_type != NULL | 위협 탐지 | deny |
| 포인터 == NULL | 초기화 실패/OOM | fail-closed deny + ERR 로그 |
| Rust panic | `panic=abort` → 프로세스 abort | Nginx master 재시작 |

---

### `luagate_scan_result_free`

```c
void luagate_scan_result_free(ScanResult* result);
```

| 인수 | Ownership | NULLable |
|------|----------|---------|
| `result` | 이 함수가 소유권 획득 후 해제 | Yes (NULL이면 noop) |

**해제 순서**: 1) `threat_type` CString free, 2) `matched_pattern` CString free, 3) ScanResult Box free

---

### `luagate_scanner_init`

```c
int luagate_scanner_init(const char* patterns_path);
```

| 반환 | 의미 |
|------|------|
| 0 | 초기화 성공 |
| -1 | 파일 로드 실패 |
| -2 | 패턴 파싱 오류 |

**호출**: `init_by_lua`에서 1회만 호출. 재호출 시 undefined behavior.

---

## luagate_decoder.so

### `luagate_decoder_normalize`

```c
DecoderResult* luagate_decoder_normalize(
    const char* path_raw,   size_t path_raw_len,
    const char* query_raw,  size_t query_raw_len
);
```

| 인수 | Ownership | NULLable | Max Length |
|------|----------|---------|-----------|
| `path_raw` | Caller | No | 8192 bytes |
| `query_raw` | Caller | Yes (→ len=0) | 65536 bytes |

**반환값**:
```c
typedef struct {
    char*  path_normalized;        // NULL if error
    size_t path_normalized_len;
    char*  query_normalized;       // NULL if no query
    size_t query_normalized_len;
    int    encoding_layers_detected; // 탐지된 인코딩 레이어 수 (0~5)
    int    error_code;             // 0 = 성공, <0 = 에러
} DecoderResult;
```

**에러 코드 맵**:

| error_code | 의미 | Lua 처리 |
|-----------|------|---------|
| 0 | 정상 | path_normalized 사용 |
| -1 | malformed encoding (디코딩 실패) | fail-closed deny |
| -2 | 경로 too long (max 8192 초과) | fail-closed deny |
| -3 | null byte 감지 | fail-closed deny |

---

### `luagate_decoder_result_free`

```c
void luagate_decoder_result_free(DecoderResult* result);
```

NULL 안전. 반드시 호출.

---

## 공통 ABI 규칙

1. **인수 길이 명시**: 모든 `char*` 인수에 대응하는 `size_t len` 인수 필수 (NULL-terminated에 의존하지 않음)
2. **함수 명명**: `luagate_<module>_<action>`, free 함수는 `luagate_<module>_<type>_free`
3. **`#[no_mangle]` + `extern "C"`**: 모든 export 함수에 필수
4. **`panic = "abort"`**: Cargo.toml `[profile.release]`에 설정 (Rust panic → worker abort)
5. **Thread safety**: 각 worker는 단일 스레드이므로 mutex 불필요

## Lua 호출 시 안전 패턴

```lua
-- 모든 FFI 호출에 적용하는 표준 패턴
local function call_scanner(ctx)
    -- 인수 변수 명시 (GC 방지)
    local path_raw = ctx.path_raw or ""
    local path_norm = ctx.path_normalized or ""
    local query = ctx.query_string or ""
    local body = ctx.body  -- nil 가능
    local ua = ctx.user_agent or ""

    local result = lib.luagate_scan_http(
        path_raw, #path_raw,
        path_norm, #path_norm,
        query, #query,
        body or nil, body and #body or 0,
        ua
    )

    if result == nil then
        ngx.log(ngx.ERR, "scanner: NULL returned")
        return nil, "ffi-null"
    end

    -- 즉시 복사 후 free
    local out = {
        threat_type  = result.threat_type ~= nil and ffi.string(result.threat_type) or nil,
        threat_score = result.threat_score,
    }
    lib.luagate_scan_result_free(result)

    return out, nil
end
```

## 참조

- `docs/spec/c-ffi-modules.md` — FFI 통합 원칙 + 공통 패턴
- `docs/spec/security-scanner.md §3` — scanner C ABI 원본
- `docs/design/adr/ADR-001` — FFI 결정
- `.claude/knowledge/c-ffi-guide.md` — 메모리 관리 가이드
- `lua/luagate/scanner/ffi.lua` — 스캐너 바인딩 구현
- `lua/luagate/decoder/ffi.lua` — 디코더 바인딩 구현
