# Rust FFI Modules Specification

> **ADR 참조**:
>
> - [ADR-001 실행/상태 공유 모델](../design/adr/ADR-001-execution-shared-state-model.md) — Rust FFI 통합 방식 및 실패 정책
> - [ADR-009 FFI 타임아웃 강제](../design/adr/ADR-009-ffi-timeout-enforcement.md) — 3계층 타임아웃 방어, 에러 코드 LUAGATE_TIMEOUT(-5), copy-in/copy-out ABI 안전성

## 1. 개요

LuaGate는 고성능 처리가 필요한 모듈을 Rust로 구현하고 LuaJIT FFI를 통해 호출한다.
이 문서는 **헤더 수준 ABI 계약서**다. Lua 바인딩 작성자와 Rust 구현자가 이 문서를 기준으로 한다.

| 모듈 | 라이브러리 | 소스 | 역할 |
| --- | --- | --- | --- |
| 보안 스캐너 | `luagate_scanner.so` | `src/scanner/` | 위협 탐지, OWASP 패턴 매칭 |
| URL 디코더/정규화 | `luagate_decoder.so` | `src/decoder/` | 멀티레이어 인코딩 디코딩/NFKC 정규화 |
| Stream 파서 | `luagate_stream.so` | `src/stream/` | 프로토콜 탐지, SNI 추출, CIDR radix tree |

## 2. 에러 코드 Enum (공통)

모든 FFI 함수는 `int` 반환값으로 아래 enum을 사용한다.
Lua wrapper가 return code를 해석하여 에러 처리를 수행한다 (pcall 예외 방식 대신).

```c
/* luagate.h — 모든 모듈이 include */
enum luagate_result {
    LUAGATE_OK              =  0,
    LUAGATE_NEED_MORE_DATA  =  1,   /* 더 많은 입력 필요 (stream preread) */
    LUAGATE_INVALID_INPUT   = -1,   /* 유효하지 않은 입력 */
    LUAGATE_BUFFER_TOO_SMALL = -2,  /* out_cap 부족 (caller가 더 큰 버퍼로 재시도) */
    LUAGATE_BUDGET_EXCEEDED = -3,   /* Layer 1 시간 예산 초과 (내부 자발적 종료) */
    LUAGATE_INTERNAL_ERROR  = -4,   /* 내부 오류 */
    LUAGATE_TIMEOUT         = -5    /* Layer 2 watchdog 타임아웃 (외부 강제, ADR-009) */
};
```

**Lua 처리 규칙:**

| return code | Lua 처리 |
| --- | --- |
| `LUAGATE_OK` | 정상 진행 |
| `LUAGATE_NEED_MORE_DATA` | preread buffer 더 읽기 시도. timeout 초과 시 fail-closed |
| `LUAGATE_INVALID_INPUT` | decode_partial 또는 fail-closed (함수별 상이, 아래 참조) |
| `LUAGATE_BUFFER_TOO_SMALL` | 더 큰 caller-allocated buffer로 재시도 (최대 1회) |
| `LUAGATE_BUDGET_EXCEEDED` | fail-closed (403 또는 연결 종료) |
| `LUAGATE_INTERNAL_ERROR` | fail-closed (403 또는 연결 종료) |
| `LUAGATE_TIMEOUT` | fail-closed (403 또는 연결 종료) + per-worker leak 카운터 증가 ([ADR-009](../design/adr/ADR-009-ffi-timeout-enforcement.md)) |

## 3. 메모리 Ownership 원칙

> **caller-allocated output buffer 방식 (기본)**: 일반 변환/스캔 함수는 caller가 제공한 버퍼에 결과를 기록한다.
> Rust가 메모리를 할당하여 반환하지 않는다 (malloc → free 패턴 대신).

```text
caller 책임:
  - out 버퍼 할당 (스택 또는 Lua string.rep() 등)
  - out_cap 크기 제공
  - LUAGATE_BUFFER_TOO_SMALL 시 재할당 후 재시도

Rust 책임:
  - 제공된 버퍼에 결과 기록
  - out_len에 실제 기록 바이트 수 설정
  - 버퍼 초과 시 LUAGATE_BUFFER_TOO_SMALL 반환 (버퍼 내용 미정)
```

> **예외 — Radix Tree API**: `luagate_radix_build()` / `luagate_radix_lookup()` / `luagate_radix_free()`는 caller-allocated 원칙의 예외다.
> Rust가 tree 객체를 heap에 할당하고 opaque 포인터(`luagate_radix_t *`)를 반환한다.
> caller(Lua wrapper)는 포인터만 저장하며, 사용 완료 후 **반드시 `luagate_radix_free()`를 호출**하여 Rust가 할당한 메모리를 해제해야 한다.
> tree 교체(hot reload) 시에는 구 tree 포인터를 atomic swap 후 즉시 `luagate_radix_free()`로 해제한다 (§6.4 Radix Tree Lifecycle 참조).
>
> | 함수 유형 | 메모리 소유권 | free 의무 |
> |---------|------------|---------|
> | 변환/스캔 함수 (`luagate_normalize_*`, `luagate_scan_*`, `luagate_detect_*`, `luagate_extract_*`) | caller-allocated 버퍼 | 없음 (caller 버퍼는 caller가 관리) |
> | Radix tree 빌드 (`luagate_radix_build`) | Rust가 tree 할당 | **필수**: `luagate_radix_free()` 호출 |

## 4. 보안 스캐너 (`luagate_scanner.so`)

### 4.1 ABI 시그니처 (extern "C")

```c
/* luagate_scanner.h */
#include "luagate.h"

/**
 * HTTP 요청 스캔.
 * 반환: LUAGATE_OK (threat_type_len > 0이면 위협 탐지됨)
 *       LUAGATE_BUDGET_EXCEEDED, LUAGATE_INTERNAL_ERROR
 *
 * threat_type_out: caller-allocated. 위협 없으면 길이 0.
 * rule_name_out:   caller-allocated. 매칭된 내부 rule_name.
 * score_out:       0.0 ~ 1.0.
 */
int luagate_scan_http(
    const char  *path_raw,          size_t path_raw_len,
    const char  *path_normalized,   size_t path_normalized_len,
    const char  *query_raw,         size_t query_raw_len,
    const char  *query_normalized,  size_t query_normalized_len,
    const char  *body,              size_t body_len,         /* NULL 허용 (MVP: body_len=0) */
    char        *threat_type_out,   size_t threat_type_cap,  size_t *threat_type_len,
    char        *rule_name_out,     size_t rule_name_cap,    size_t *rule_name_len,
    double      *score_out
);

/** 초기화 (init_by_lua에서 1회). patterns_path: patterns 디렉토리 경로. */
int luagate_scanner_init(const char *patterns_path, size_t patterns_path_len);
```

### 4.2 Lua FFI 바인딩

```lua
-- lua/luagate/scanner/ffi.lua
local ffi = require("ffi")

ffi.cdef[[
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
int luagate_scanner_init(const char *patterns_path, size_t patterns_path_len);
]]

local lib = ffi.load("luagate_scanner")
local THREAT_BUF_CAP = 64
local RULE_BUF_CAP   = 128

local M = {}

function M.scan(ctx)
    local threat_buf  = ffi.new("char[?]", THREAT_BUF_CAP)
    local rule_buf    = ffi.new("char[?]", RULE_BUF_CAP)
    local threat_len  = ffi.new("size_t[1]")
    local rule_len    = ffi.new("size_t[1]")
    local score       = ffi.new("double[1]")

    local rc = lib.luagate_scan_http(
        ctx.path_raw,         #ctx.path_raw,
        ctx.path_normalized,  #ctx.path_normalized,
        ctx.query_raw or "",  #(ctx.query_raw or ""),
        ctx.query_normalized or "", #(ctx.query_normalized or ""),
        ctx.body or nil,      ctx.body and #ctx.body or 0,
        threat_buf, THREAT_BUF_CAP, threat_len,
        rule_buf,   RULE_BUF_CAP,   rule_len,
        score
    )

    -- Lua wrapper가 return code 해석
    if rc == -3 or rc == -4 then  -- BUDGET_EXCEEDED or INTERNAL_ERROR
        return nil, "scanner_fail:" .. rc
    end

    local threat_type = threat_len[0] > 0 and ffi.string(threat_buf, threat_len[0]) or nil
    local rule_name   = rule_len[0] > 0   and ffi.string(rule_buf,   rule_len[0])   or nil

    return {
        threat_type  = threat_type,
        rule_name    = rule_name,
        threat_score = score[0],
    }, nil
end

return M
```

## 5. URL 디코더/정규화 (`luagate_decoder.so`)

### 5.1 ABI 시그니처 (extern "C")

```c
/* luagate_decoder.h */
#include "luagate.h"

/**
 * path_raw를 정규화하여 out에 기록.
 * decode 순서: percent-decode → path normalize (..) → NFKC → null/control 제거
 * 반환: LUAGATE_OK, LUAGATE_BUFFER_TOO_SMALL, LUAGATE_INVALID_INPUT (decode_partial)
 *       LUAGATE_INVALID_INPUT 시에도 out에 부분 결과 기록 (decode_partial semantics)
 */
int luagate_normalize_path(
    const char  *path_raw,  size_t path_raw_len,
    char        *out,       size_t out_cap,  size_t *out_len
);

/**
 * query_raw를 name/value 컴포넌트 단위로 정규화.
 * 쌍의 수: pair_count_out에 기록.
 * 반환: LUAGATE_OK, LUAGATE_BUFFER_TOO_SMALL, LUAGATE_INVALID_INPUT
 */
int luagate_normalize_query(
    const char  *query_raw,  size_t query_raw_len,
    char        *out,        size_t out_cap,  size_t *out_len
);

/**
 * NFKC 유니코드 정규화 (utf8proc 사용).
 * utf8proc 버전: 2.9.0 (flake.nix에 고정).
 */
int luagate_normalize_nfkc(
    const char  *input,  size_t input_len,
    char        *out,    size_t out_cap,  size_t *out_len
);
```

> **normalize_nfkc 의존성**: `utf8proc` 채택 (ICU 대비 경량, CDylib에 정적 링크).
> 버전: `2.9.0`. `flake.nix`에 `buildInputs`로 고정.
> ICU 대신 utf8proc을 선택한 이유: 바이너리 크기 (~100KB vs ~30MB), 단일 목적 라이브러리.

## 6. Stream 파서 (`luagate_stream.so`)

### 6.1 native ssl_preread 검토 결정

**결정**: `ngx_stream_ssl_preread_module`은 **기본 SNI 추출에 충분**하나, 다음 이유로 custom parser를 유지한다:

- Fragmented ClientHello (여러 TLS record에 걸친 경우) 미지원
- non-TLS 프로토콜 탐지 (`http`, `raw`) 불가
- LUAGATE_NEED_MORE_DATA 상태 관리 필요

→ `extract_sni`는 Rust FFI custom parser 유지. non-TLS 프로토콜 파싱 포함.

### 6.2 TLS Parser 범위 (MVP)

- **지원**: TLS 1.2, TLS 1.3 ClientHello
- **미지원(deprecated)**: TLS 1.0, 1.1
- **Fragmented ClientHello**: MVP 미지원. `LUAGATE_NEED_MORE_DATA`로 최대 preread_timeout까지 재시도
- **GREASE 값**: 무시 (RFC 8701 — 탐지 로직에 영향 없음)
- **ECH (Encrypted Client Hello)**: 무시 (outer SNI만 사용)

### 6.3 ABI 시그니처 (extern "C")

```c
/* luagate_stream.h */
#include "luagate.h"

/**
 * 프로토콜 탐지 (preread buffer에서).
 *
 * protocol_out: "tls", "http", "raw" 중 하나 (null-terminated, caller-allocated)
 * 반환:
 *   LUAGATE_OK              — 탐지 완료 (protocol_out 참조)
 *   LUAGATE_NEED_MORE_DATA  — 더 많은 bytes 필요 (peek 재시도)
 *   LUAGATE_INVALID_INPUT   — malformed (malformed TLS 포함) → fail-closed
 *   LUAGATE_INTERNAL_ERROR  — 내부 오류 → fail-closed
 *
 * 전제: preread_by_lua*의 reqsock:peek() 기반으로 buf가 소비되지 않음.
 */
int luagate_detect_protocol(
    const char  *buf,          size_t buf_len,
    char        *protocol_out, size_t protocol_cap, size_t *protocol_len
);

/**
 * TLS ClientHello에서 SNI 추출.
 * caller-allocated output buffer 방식.
 * 반환: LUAGATE_OK, LUAGATE_BUFFER_TOO_SMALL, LUAGATE_INVALID_INPUT, LUAGATE_NEED_MORE_DATA
 *
 * LUAGATE_NEED_MORE_DATA: ClientHello가 아직 완전히 도착하지 않음 (fragmented).
 */
int luagate_extract_sni(
    const char  *buf,     size_t buf_len,
    char        *out,     size_t out_cap,  size_t *out_len
);

/* Radix Tree — CIDR 기반 IP 조회 */

/** 새 radix tree 생성. cidr_list: newline-separated CIDR 문자열. */
int luagate_radix_build(
    const char          *cidr_list,  size_t cidr_list_len,
    luagate_radix_t    **tree_out    /* caller는 tree_out 포인터만 저장 */
);

/** IP 주소 조회. matched_rule_index: 매칭된 rule의 original_index. */
int luagate_radix_lookup(
    const luagate_radix_t  *tree,
    const char              *ip_str,  size_t ip_str_len,
    uint32_t               *matched_rule_index_out  /* 미매칭 시 UINT32_MAX */
);

/**
 * 이전 tree 해제 (atomic swap 후 구 tree 폐기 시 호출).
 * 반환: LUAGATE_OK
 */
int luagate_radix_free(luagate_radix_t *tree);
```

### 6.4 Radix Tree Lifecycle (Hot Reload 연동)

```text
[reload trigger]
        │
        ▼
[1] luagate_radix_build(new_cidr_list) → new_tree
        │
        ▼
[2] stage new_tree (worker-local upvalue에 임시 저장)
        │
        ▼
[3] atomic pointer swap: current_tree = new_tree
    (Lua upvalue 교체 — LuaJIT table/pointer 업데이트)
        │
        ▼
[4] luagate_radix_free(old_tree) — 구 tree 명시 해제
    (다음 GC 사이클 또는 swap 직후 즉시)
```

> **worker-local lrucache**: lookup 결과(IP → rule_index) 캐시만 저장.
> tree 객체 포인터 자체는 module-level upvalue로 관리. lrucache에 포인터 저장 금지.
>
> **active_version 변경 시**: worker-local radix tree rebuild 트리거.
> 각 worker가 독립적으로 rebuild. shared dict 경유 불필요.

### 6.5 Radix Tree Data Payload

```c
/* tree의 각 노드에 저장되는 payload */
typedef struct {
    uint32_t rule_index;  /* original_index (policy-engine.md §3.4 기준, uint32_t) */
                          /* action은 Lua 레벨에서 rules[rule_index].action으로 해석 */
} luagate_radix_payload_t;
```

> **action 해석 위치**: Lua wrapper가 `rule_index`로 rules 배열을 조회하여 action 결정.
> Rust radix tree는 action 값을 모른다.

## 7. FFI 통합 원칙 (ADR-001, ADR-009)

1. **동일 worker 내 동기 호출**: IPC 없음. `ffi.load()` 후 직접 함수 호출
2. **return code 해석**: Lua wrapper가 return code를 확인하여 에러 처리. `pcall`은 Lua-level 예외(잘못된 인수 타입 등)에만 유효하며, native crash(segfault/abort)는 포착할 수 없다 (ADR-001 §1.2 참조)
3. **실패 처리**: `LUAGATE_BUDGET_EXCEEDED`, `LUAGATE_INTERNAL_ERROR`, `LUAGATE_TIMEOUT` → fail-closed (403 또는 연결 종료)
4. **3계층 타임아웃 방어** ([ADR-009](../design/adr/ADR-009-ffi-timeout-enforcement.md)):

| 모듈 | Layer 1 budget (내부) | Layer 2 hard timeout (watchdog) |
|------|----------------------|-------------------------------|
| `luagate_scanner.so` | 5ms | 50ms |
| `luagate_decoder.so` | 2ms | 20ms |
| `luagate_stream.so` (detect/sni) | 1ms | 10ms |
| `luagate_stream.so` (radix_build) | 100ms | 1000ms |

> Layer 2 watchdog는 copy-in/copy-out 전략으로 caller-owned 버퍼의 ABI 안전성을 보장한다. 상세: ADR-009.

## 8. Rust 빌드 설정

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
panic = "abort"  # Crash-fail-fast 전략: Rust panic 시 worker를 즉시 abort.
                 # C stack에서 Rust panic unwinding은 UB 유발 가능 → abort가 안전함.
                 # worker abort 시 Nginx master가 자동 재시작 (ADR-001 §1.2 참조).
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
# utf8proc은 C 라이브러리. flake.nix buildInputs에 utf8proc-2.9.0 고정.
# Rust에서 utf8proc-sys crate 또는 bindgen으로 바인딩.
```

## 9. Fuzzing 요구사항

> **빌드 섹션 필수 항목**: protocol parser + decoder를 대상으로 fuzz 테스트를 수행한다.

### 9.1 대상

| 대상 | 도구 | Corpus |
| --- | --- | --- |
| `luagate_detect_protocol` | AFL++ 또는 libFuzzer | TLS ClientHello, HTTP request fragments, raw bytes |
| `luagate_extract_sni` | libFuzzer | TLS record 변형 corpus |
| `luagate_normalize_path` | libFuzzer | percent-encoded paths, Unicode bypass corpus |
| `luagate_normalize_query` | libFuzzer | RFC 3986 query variations |

### 9.2 빌드 타겟

```bash
# ASan/UBSan fuzz 빌드
cargo +nightly build --release -Z sanitizer=address,undefined \
    --target x86_64-unknown-linux-gnu

# libFuzzer 타겟
cargo +nightly fuzz run fuzz_detect_protocol
cargo +nightly fuzz run fuzz_normalize_path
```

### 9.3 CI 통합

- `make fuzz-regression`: CI에서 corpus 기반 regression fuzz 실행 (10초, 단기 버전)
- fuzz crash → CI 실패. 수정 후 crash 재현 test case를 corpus에 추가

## 10. Lua FFI 공통 패턴

### 10.1 라이브러리 로드 (init_by_lua에서 1회)

```lua
-- lua/luagate/init.lua
local ffi = require("ffi")

-- .so 경로는 nginx.conf의 lua_package_cpath에서 설정
local scanner_lib = ffi.load("luagate_scanner")
local decoder_lib = ffi.load("luagate_decoder")
local stream_lib  = ffi.load("luagate_stream")

-- 전역 등록 (worker별 캐시)
package.loaded["_luagate_scanner_lib"] = scanner_lib
package.loaded["_luagate_decoder_lib"] = decoder_lib
package.loaded["_luagate_stream_lib"]  = stream_lib
```

### 10.2 안전한 FFI 호출 래퍼

```lua
-- lua/luagate/ffi_util.lua
local M = {}

-- pcall은 Lua-level 예외(잘못된 인수 타입 등) 대비용.
-- native crash(segfault, Rust abort)는 pcall로 포착 불가 — worker 재시작으로만 복구 (ADR-001 §1.2).
-- return code는 wrapper 내부에서 직접 확인하며, pcall은 보조 방어선으로만 사용한다.
function M.safe_call(fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then
        ngx.log(ngx.ERR, "FFI call failed (Lua-level): ", tostring(result))
        return nil, result
    end
    return result, nil
end

return M
```

### 10.3 문자열 변환 유틸리티

```lua
local ffi = require("ffi")

-- Lua string → C char* (NULL-terminated)
local function lua_to_cstr(s)
    return ffi.cast("const char*", s)
end

-- C char* → Lua string (NULL 안전)
local function cstr_to_lua(cptr, len)
    if cptr == nil or cptr == ffi.null then
        return nil
    end
    return ffi.string(cptr, len)
end
```

## 11. 빌드 파이프라인

```makefile
# Makefile
# 아래 예시의 <TAB>은 실제 탭 문자 1개를 의미한다.
.PHONY: build-ffi fuzz-regression

build-ffi:
<TAB>cd src/scanner && cargo build --release
<TAB>cd src/decoder && cargo build --release
<TAB>cd src/stream  && cargo build --release
<TAB>cp src/scanner/target/release/libluagate_scanner.so lib/
<TAB>cp src/decoder/target/release/libluagate_decoder.so lib/
<TAB>cp src/stream/target/release/libluagate_stream.so   lib/

fuzz-regression:
<TAB>cd src/stream  && cargo +nightly fuzz run fuzz_detect_protocol -- -max_total_time=10
<TAB>cd src/decoder && cargo +nightly fuzz run fuzz_normalize_path  -- -max_total_time=10

# nginx.conf에서 lib/ 디렉토리를 lua_package_cpath에 추가
```

## 12. 의존성

- [spec/security-scanner.md](./security-scanner.md) — 스캐너 상세
- [spec/http-pipeline.md](./http-pipeline.md) — FFI 호출 컨텍스트
- [spec/stream-pipeline.md](./stream-pipeline.md) — detect_protocol, radix tree lifecycle
- [ADR-001](../design/adr/ADR-001-execution-shared-state-model.md) — FFI 모델 결정
- [ADR-009](../design/adr/ADR-009-ffi-timeout-enforcement.md) — FFI 타임아웃 강제 메커니즘
