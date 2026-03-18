# FFI ABI Contract — 함수별 Ownership, NULLability, Max Length, Error Code Map

> 참조: `docs/spec/rust-ffi-modules.md`, ADR-001

## 공통 패턴: Caller-Allocated Buffer

모든 LuaGate FFI 함수는 **caller-allocated buffer** 모델을 사용한다.
- Rust는 메모리를 할당하여 반환하지 않음 (radix tree 제외)
- Lua가 미리 할당한 버퍼에 결과를 기록
- `free` 함수 불필요 (radix tree 제외)

## luagate_scanner.so

### `luagate_scan_http`

```c
int luagate_scan_http(
    const char *path_raw,         size_t path_raw_len,
    const char *path_normalized,  size_t path_normalized_len,
    const char *query_raw,        size_t query_raw_len,
    const char *query_normalized, size_t query_normalized_len,
    const char *body,             size_t body_len,
    char *threat_type_out,  size_t threat_type_cap,  size_t *threat_type_len,
    char *rule_name_out,    size_t rule_name_cap,     size_t *rule_name_len,
    double *score_out
);
```

| 인수 | Ownership | NULLable | Max Length | 비고 |
|------|----------|---------|-----------|------|
| `path_raw` | Caller (Lua string) | No | 8192 bytes | 원본 경로 |
| `path_normalized` | Caller (Lua string) | No | 8192 bytes | 정규화된 경로 |
| `query_raw` | Caller (Lua string) | Yes (→ len=0) | 65536 bytes | 원본 쿼리 |
| `query_normalized` | Caller (Lua string) | Yes (→ len=0) | 65536 bytes | 정규화된 쿼리 |
| `body` | Caller (Lua string) | Yes (→ len=0) | 8192 bytes | 본문 (8KB 제한) |
| `threat_type_out` | Caller (ffi.new) | No | 64 bytes cap | 결과 버퍼 |
| `rule_name_out` | Caller (ffi.new) | No | 128 bytes cap | 결과 버퍼 |
| `score_out` | Caller (ffi.new) | No | — | double 포인터 |

**반환값**: `int` (에러 코드). 결과는 caller-allocated 버퍼에 기록됨.

**에러 코드 맵**:

| 반환값 | 의미 | Lua 처리 |
|--------|------|---------|
| `0` (threat_type_len=0) | 스캔 완료, 위협 없음 | allow 진행 |
| `0` (threat_type_len>0) | 위협 탐지 | deny |
| `-2` | BUFFER_TOO_SMALL | fail-closed deny |
| `-3` | BUDGET_EXCEEDED | fail-closed deny |
| `-4` | INTERNAL_ERROR | fail-closed deny + ERR 로그 |
| Rust panic | `panic=abort` → 프로세스 abort | Nginx master 재시작 |

---

### `luagate_scanner_init`

```c
int luagate_scanner_init(const char *patterns_path, size_t patterns_path_len);
```

| 반환 | 의미 |
|------|------|
| 0 | 초기화 성공 |
| -1 | 파일 로드 실패 |
| -2 | 패턴 파싱 오류 |

**호출**: `init_by_lua`에서 1회만 호출. 실패 시 서버 시작 거부 (startup-fatal).

---

## luagate_decoder.so

### `luagate_normalize_path`

```c
int luagate_normalize_path(
    const char *path_raw, size_t path_raw_len,
    char *out, size_t out_cap, size_t *out_len
);
```

| 인수 | Ownership | NULLable | Max Length |
|------|----------|---------|-----------|
| `path_raw` | Caller | No | 8192 bytes |
| `out` | Caller (ffi.new) | No | out_cap bytes |
| `out_len` | Caller (ffi.new) | No | — |

### `luagate_normalize_query`

```c
int luagate_normalize_query(
    const char *query_raw, size_t query_raw_len,
    char *out, size_t out_cap, size_t *out_len
);
```

### `luagate_normalize_nfkc`

```c
int luagate_normalize_nfkc(
    const char *input, size_t input_len,
    char *out, size_t out_cap, size_t *out_len
);
```

**에러 코드 맵** (공통):

| 반환값 | 의미 | Lua 처리 |
|--------|------|---------|
| `0` | 정상 | out 버퍼 사용 |
| `-1` | INVALID_INPUT (부분 결과 반환) | partial result 사용 가능 |
| `-2` | BUFFER_TOO_SMALL | 2x 재시도 1회 |
| `-3` | BUDGET_EXCEEDED | fail-closed deny |
| `-4` | INTERNAL_ERROR | fail-closed deny |

---

## luagate_stream.so

### `luagate_detect_protocol`

```c
int luagate_detect_protocol(
    const char *buf, size_t buf_len,
    char *protocol_out, size_t protocol_cap, size_t *protocol_len
);
```

| 인수 | Ownership | NULLable | Max Length |
|------|----------|---------|-----------|
| `buf` | Caller | No | 65536 bytes (64KB cap) |
| `protocol_out` | Caller (ffi.new) | No | protocol_cap bytes |

### `luagate_extract_sni`

```c
int luagate_extract_sni(
    const char *buf, size_t buf_len,
    char *out, size_t out_cap, size_t *out_len
);
```

**에러 코드 맵** (detect_protocol, extract_sni 공통):

| 반환값 | 의미 | Lua 처리 |
|--------|------|---------|
| `0` | 성공 | out 버퍼 사용 |
| `1` | NEED_MORE_DATA | 재시도 (preread 재수집) |
| `-1` | INVALID_INPUT | fail-closed (malformed TLS/non-TLS) |
| `-2` | BUFFER_TOO_SMALL | fail-closed |
| `-4` | INTERNAL_ERROR | fail-closed |

### `luagate_radix_build` / `luagate_radix_lookup` / `luagate_radix_free`

```c
typedef struct LuagateRadix luagate_radix_t;

int luagate_radix_build(
    const char *cidr_list, size_t cidr_list_len,
    luagate_radix_t **tree_out
);
int luagate_radix_lookup(
    const luagate_radix_t *tree,
    const char *ip_str, size_t ip_str_len,
    uint32_t *matched_rule_index_out
);
int luagate_radix_free(luagate_radix_t *tree);
```

**메모리 관리**: radix tree는 **Rust가 할당**하며, `luagate_radix_free()` 호출 필수.
`ffi.gc`로 자동 해제를 등록하는 것이 권장 패턴.

| 반환값 | 의미 | Lua 처리 |
|--------|------|---------|
| `0` | 성공 | tree_out 포인터 사용 |
| `-1` | INVALID_INPUT (잘못된 CIDR) | fail-closed |
| `-4` | INTERNAL_ERROR | fail-closed |

---

## 공통 ABI 규칙

1. **caller-allocated buffer**: 모든 출력은 caller가 미리 할당한 버퍼에 기록. `*_len` out 파라미터로 실제 길이 반환
2. **인수 길이 명시**: 모든 `char*` 인수에 대응하는 `size_t len` 인수 필수 (NULL-terminated에 의존하지 않음)
3. **함수 명명**: `luagate_<module>_<action>`
4. **`#[no_mangle]` + `extern "C"`**: 모든 export 함수에 필수
5. **`panic = "abort"`**: Cargo.toml `[profile.release]`에 설정 (Rust panic → worker abort)
6. **Thread safety**: 각 worker는 단일 스레드이므로 mutex 불필요
7. **장기 리소스** (radix tree): Rust가 할당, 대응 `luagate_radix_free` 함수 제공

## Lua 호출 시 안전 패턴

```lua
-- 모든 FFI 호출에 적용하는 표준 패턴 (scanner 예시)
local function call_scanner(ctx)
    local threat_buf = ffi.new("char[?]", 64)
    local rule_buf = ffi.new("char[?]", 128)
    local threat_len = ffi.new("size_t[1]")
    local rule_len = ffi.new("size_t[1]")
    local score = ffi.new("double[1]")

    local path_raw = ctx.path_raw or ""
    local path_norm = ctx.path_normalized or ""
    local query_raw = ctx.query_raw or ""
    local query_norm = ctx.query_normalized or ""

    local ok, rc = pcall(function()
        return lib.luagate_scan_http(
            path_raw, #path_raw,
            path_norm, #path_norm,
            query_raw, #query_raw,
            query_norm, #query_norm,
            ctx.body or nil, ctx.body and #ctx.body or 0,
            threat_buf, 64, threat_len,
            rule_buf, 128, rule_len,
            score
        )
    end)

    if not ok then
        return nil, "ffi-error:" .. tostring(rc)
    end

    if rc ~= 0 then
        return nil, "scanner_fail:" .. rc
    end

    return {
        threat_type = threat_len[0] > 0 and ffi.string(threat_buf, threat_len[0]) or nil,
        rule_name = rule_len[0] > 0 and ffi.string(rule_buf, rule_len[0]) or nil,
        threat_score = score[0],
    }, nil
end
```

## 참조

- `docs/spec/rust-ffi-modules.md` — FFI 통합 원칙 + 공통 패턴
- `docs/spec/security-scanner.md §3` — scanner ABI 원본
- `docs/design/adr/ADR-001` — FFI 결정
- `.claude/knowledge/rust-ffi-guide.md` — 메모리 관리 가이드
- `lua/luagate/scanner/ffi.lua` — 스캐너 바인딩 구현
- `lua/luagate/decoder/ffi.lua` — 디코더 바인딩 구현
- `lua/luagate/stream/ffi.lua` — 스트림 바인딩 구현
