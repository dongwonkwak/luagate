# HTTP Pipeline Specification

> **ADR 참조**:
> - [ADR-001 실행/상태 공유 모델](../design/adr/ADR-001-execution-shared-state-model.md)
> - [ADR-002 정책 평가 규칙](../design/adr/ADR-002-policy-evaluation-conflict-detection.md)
> - [ADR-004 로그/메트릭](../design/adr/ADR-004-log-metrics-admin-security.md)
> - [ADR-009 FFI 타임아웃 강제](../design/adr/ADR-009-ffi-timeout-enforcement.md) — 3계층 타임아웃 방어, LUAGATE_TIMEOUT(-5)

## 1. 개요

LuaGate HTTP 파이프라인은 클라이언트 HTTP 요청을 수신하여 정책 평가, 위협 탐지, 업스트림 프록시, 로그 기록까지의 전체 처리 흐름을 정의한다.

## 2. 처리 단계

### 2.1 init_by_lua (서버 기동 시 1회)

```lua
-- 초기화 순서
1. C/Rust .so 로드 (ffi.load)
   - luagate_scanner.so  (보안 스캐너)
   - luagate_decoder.so  (URL/인코딩 디코더)
2. 정책 파일 파싱 및 로드 (conf/policies.yaml)
3. 정책 버전(SHA256) → luagate_policy shared dict
4. 초기화 실패 시: nginx 시작 중단 (fatal)
```

### 2.2 rewrite_by_lua (URL 정규화)

**목적**: `path_raw` → `path_normalized` 변환

**정규화 단계 (§5 멀티레이어 디코딩):**

```
입력: path_raw = "/api/v1/%2e%2e/admin?id=1%27OR%271%27%3D%271"
                          │
                          ▼
1단계: URL 디코딩 (percent-encoding)
       /api/v1/../admin?id=1'OR'1'='1
                          │
                          ▼
2단계: 경로 정규화 (.. 제거, 중복 슬래시 등)
       /admin?id=1'OR'1'='1
                          │
                          ▼
3단계: 유니코드 정규화 (NFKC — rust-ffi-modules.md의 normalize_nfkc)
       /admin?id=1'OR'1'='1
                          │
                          ▼
4단계: null byte, 제어문자 제거
       /admin?id=1'OR'1'='1
                          │
                          ▼
출력: path_normalized = "/admin"
      query_normalized = "id=1'OR'1'='1"
```

**중요**:
- `path_raw`는 항상 원본 그대로 보존 (로그 기록 목적, ADR-004). **정의**: query를 제외한 `?` 이전 경로만 (Lua 계산값, 디코딩 전). `$request_uri` 전체가 아님. 상세: [log-schema.md §3.1](./log-schema.md#31-필드-정의-adr-004-41)의 path_raw 정의 참조
- URL 정규화는 **`rewrite_by_lua` 단계에서만** 수행한다. `access_by_lua` 이후 단계에서는 정규화 로직을 중복 실행하지 않는다.
- `rewrite_by_lua` 완료 후 결과는 `ngx.ctx.luagate.path_normalized`에 저장된다. 이후 모든 단계(`access_by_lua`, `log_by_lua`)는 이 값만 읽고 재정규화하지 않는다.
- **정규화 책임**: policy-engine.md §2.2 매칭 연산자 정의가 source of truth. 여기는 파이프라인 흐름만 기술한다.

### 2.3 access_by_lua (핵심 처리 — 정책 평가 + 위협 탐지)

**정책 매칭 입력 vs 스캐너 입력 분리:**

| 단계 | 사용 입력 | 설명 |
|------|---------|------|
| 정책 매칭 (ADR-002) | `path_normalized`, `method`, `src_ip`, `host`, `header` 등 | 정규화된 값 기준 |
| 보안 스캐너 | `path_raw`, `path_normalized`, `query_raw`, `query_normalized` | 원본 + 정규화 모두 전달 |

```
┌─────────────────────────────────────────────┐
│  access_by_lua 처리 순서                     │
│                                             │
│  1. 정책 버전 확인 (shared dict L2)          │
│     L1 캐시 active_version 비교             │
│     └─ 변경됨 → L2에서 새 정책 로드         │
│                                             │
│  2. Rust FFI: 보안 스캐너 (§5)               │
│     입력: path_raw, path_normalized,        │
│           query_raw, query_normalized       │
│     출력: { threat_type, rule_name }        │
│     실패: scanner_internal_error → 403      │
│           budget_exceeded → 403             │
│     예외: Lua wrapper exception도 500으로    │
│           새지 않고 fail-closed로 흡수      │
│                                             │
│  3. 정책 평가 (ADR-002)                     │
│     priority 정렬 → first-match-wins        │
│     ├─ allow → 통과                        │
│     └─ deny  → 403 반환                    │
│                │                            │
│                ▼                            │
│  4. deny 처리:                              │
│     - ngx.status = 403                     │
│     - ngx.say(JSON 에러 응답)               │
│     - ngx.exit(403)                        │
│     - 로그: action=deny 기록 예약           │
└─────────────────────────────────────────────┘
```

**Body 검사 계약:**

| 항목 | 계약 |
|------|------|
| `ngx.req.read_body()` | access_by_lua 진입 전 Nginx 설정(`lua_need_request_body on`)으로 자동 읽기. 또는 body 검사가 필요한 경우에만 명시적으로 `ngx.req.read_body()` 호출 |
| Body 검사 범위 | **MVP 비범위** (security-scanner.md §2c 참조). body 검사는 Phase 2에서 지원. MVP에서는 `body_len = 0`으로 스캐너를 호출한다 |
| Large body (spill to file) | 본문이 `client_body_buffer_size` 초과 시 임시 파일로 spill — MVP에서 body 검사 미지원이므로 동작 무변화. 검사 생략 사유를 WARN 로그에 기록 |
| Chunked / streaming body | `Transfer-Encoding: chunked` 요청은 Nginx가 버퍼링 후 Lua에 전달. 청크 단위 스트리밍 검사는 Phase 2 이후 범위 |
| Body 없는 요청 (GET 등) | `body`는 `nil`로 전달. 스캐너에 `body_len = 0`으로 호출 |

**예외 흡수 계약:**
- `rewrite_by_lua`의 decoder wrapper(`normalize_path`, `normalize_query`)와 `access_by_lua`의 scanner wrapper(`scan`)는 호출 지점에서 `pcall`로 감싼다.
- Lua-level exception, FFI wrapper panic, `require()` load failure는 모두 fail-closed로 흡수한다.
- 결과적으로 보안 경로 예외는 `500`으로 표면화하지 않고 `403 deny` + taxonomy token(`decoder_*`, `scanner_internal_error`, `budget_exceeded`)으로 기록한다.

### 2.4 proxy_pass (업스트림 프록시)

- `access_by_lua`에서 allow 판정된 요청만 도달
- Nginx `proxy_pass` 지시자로 업스트림 서버에 프록시
- 업스트림 latency 측정: `$upstream_response_time`
- 헤더 전달: `Host`, `X-Request-ID`, `X-Forwarded-For`, `X-Real-IP` (`conf/nginx.conf`의 `proxy_set_header` 기준)

### 2.5 log_by_lua (요청 완료 후 비동기 로그)

- Nginx 응답 후 처리 (클라이언트 응답에 영향 없음)
- **30개 필드** JSON 레코드 생성 — 상세 필드 목록: [log-schema.md](./log-schema.md) (ADR-010에서 `trace_id`, `span_id` 2개 추가)
- `luagate_metrics` shared dict 카운터 증가 (ADR-001)
- `luagate_connections` active count 갱신
- **active_version 기록 규칙**: 요청 시작 시 스냅샷한 active_version만 기록. log 시점의 버전 변경은 반영하지 않는다.

## 3. ngx.var.luagate_* 변수 목록

`log_format`에서 native Nginx 변수로 접근 가능한 luagate 커스텀 변수:

| 변수 | 타입 | 설명 | Producer 단계 |
|------|------|------|-------------|
| `$luagate_request_id` | string | 요청 ID (opaque string — 클라이언트 X-Request-ID 또는 Nginx $request_id). [ADR-010](../design/adr/ADR-010-opentelemetry-tracing.md) | Nginx map |
| `$luagate_action` | string | `allow` \| `deny` | access_by_lua |
| `$luagate_matched_rule` | string \| null | 매칭된 규칙 ID. 없으면 null | access_by_lua |
| `$luagate_decision_source` | string | decision_source enum | access_by_lua |
| `$luagate_threat_type` | string \| null | threat_type enum. 없으면 null | access_by_lua |
| `$luagate_rule_name` | string \| null | 스캐너 매칭 rule_name. 없으면 null | access_by_lua |
| `$luagate_active_version` | string | 요청 시점 active_version | rewrite_by_lua |
| `$luagate_request_state` | string | request_state enum | log_by_lua |
| `$luagate_trace_id` | string \| null | W3C trace ID (32-hex). 트레이싱 활성화 시 항상 기록 (sampled 여부 무관). 비활성화/pre-Lua rejection 시 null. [ADR-010](../design/adr/ADR-010-opentelemetry-tracing.md) | rewrite_by_lua |
| `$luagate_span_id` | string \| null | 루트 span ID (16-hex). 트레이싱 활성화 시 항상 기록. 비활성화/pre-Lua rejection 시 null. [ADR-010](../design/adr/ADR-010-opentelemetry-tracing.md) | rewrite_by_lua |

> **기본값 선할당**: `rewrite_by_lua` 진입 시 아래 기본값으로 초기화.
> `access_by_lua`에서 실제 판정 결과로 override, `log_by_lua`에서 finalize.
> 이를 통해 nginx_core early short-circuit(malformed request, 400/413/414) 시에도 30필드가 채워진다.
> **Null 표현**: Nginx 기본 `-` 대신 JSON `null`을 사용한다 (log-schema.md §2 참조).

| 변수 | 기본값 |
|------|--------|
| `$luagate_decision_source` | `nginx_core` |
| `$luagate_threat_type` | `null` (JSON null — log-schema.md §2 참조) |
| `$luagate_request_state` | `short_circuited` |
| `$luagate_rule_name` | `null` (JSON null) |
| `$luagate_matched_rule` | `null` (JSON null) |
| `$luagate_deny_reason` | `null` (JSON null) |

## 4. decision_source 값 체계

| 값 | 설명 |
|----|------|
| `policy_engine` | 정책 엔진이 판정 (allow 또는 policy deny) |
| `security_scanner` | 스캐너가 탐지하여 deny |
| `rate_limiter` | 레이트 리밋으로 deny (MVP 비범위) |
| `nginx_core` | nginx core가 early short-circuit (400/413/414/502 등) |

## 5. threat_type 값 체계

위협이 없으면 `threat_type`은 JSON `null`로 직렬화한다 (log-schema.md §2 참조). `"none"` 문자열은 사용하지 않는다.

| 값 | 설명 |
|----|------|
| `null` | 위협 없음 (정상 요청) |
| `sqli` | SQL Injection |
| `xss` | Cross-Site Scripting |
| `path_traversal` | 경로 탐색 공격 |
| `cmd_injection` | 명령어 주입 |
| `decode_error` | URL 디코딩 오류 (fail-closed 처리) |
| `scanner_error` | 스캐너 내부 오류 |

## 6. 응답 바디/헤더 정책

| 상태 코드 | 트리거 | 응답 Content-Type | 응답 바디 |
|---------|--------|-----------------|---------|
| 403 | 정책 deny 또는 스캐너 차단 | `application/json` | `{"error":"Forbidden","request_id":"...","reason":"<rule_id 또는 threat_type>"}` |
| 429 | Rate limit 초과 (MVP 비범위) | `application/json` | `{"error":"Too Many Requests","request_id":"...","retry_after":<seconds>}` |
| 502 | 업스트림 연결 실패 | `application/json` | `{"error":"Bad Gateway","request_id":"..."}` |

**공통 응답 헤더** (deny/error 응답 시):
- `X-Request-ID: <request_id>` — 항상 포함
- `Content-Type: application/json` — 위 표에 따라
- `Cache-Control: no-store` — deny 응답에 캐시 금지

## 7. Client IP 결정 (src_ip)

우선순위 (높은 순):

1. **PROXY Protocol** — nginx `proxy_protocol on` 설정 시 `$proxy_protocol_addr`
2. **X-Forwarded-For** (최우측 non-trusted IP) — `$remote_addr`이 trusted proxy CIDR 범위 내일 때만 신뢰. XFF 헤더를 오른쪽부터 왼쪽으로 순회하며 첫 번째 non-trusted valid IPv4를 추출한다. 이 방식은 클라이언트가 XFF 왼쪽에 스푸핑 IP를 주입하는 공격을 방어한다.
3. **`$remote_addr`** — fallback (직접 연결 IP)

> **Trusted proxy**: `conf/luagate.yaml`의 `trusted_proxies` 배열로 설정 (개별 IP + CIDR 범위).
> 빈 배열(기본값) 시 XFF 헤더 무시, `$remote_addr` 사용.
> 구현: `lua/luagate/http/client_ip.lua`.
> "최우측 non-trusted IP" 기준은 log-schema.md §6과 동일하다.

## 8. 멀티레이어 디코딩 (§5)

보안 우회 기법에 대응하기 위해 다음 인코딩 레이어를 순차 디코딩한다:

| 레이어 | 기법 | 예시 |
|--------|------|------|
| 1 | URL percent-encoding | `%2e%2e` → `..` |
| 2 | 이중 URL 인코딩 | `%252e` → `%2e` → `.` |
| 3 | 유니코드 정규화 (NFKC) | 호환성 분해 후 정규 합성 |
| 4 | HTML 엔티티 | `&#46;` → `.` |
| 5 | Base64 (본문) | 바이너리 데이터 검사 |

**구현**: `src/decoder/` Rust 모듈이 처리. Lua에서 `ffi.lua` 바인딩으로 호출.

```lua
-- decoder/ffi.lua 인터페이스 예시
local decoder = require("luagate.decoder.ffi")
local result = decoder.normalize(path_raw, query_raw)
-- result.path_normalized
-- result.query_normalized
-- result.encoding_layers_detected (int)
```

## 9. 요청 컨텍스트 객체

`access_by_lua`에서 `log_by_lua`까지 공유되는 요청 컨텍스트:

```lua
ngx.ctx.luagate = {
  request_id        = "string",  -- opaque: X-Request-ID 또는 $request_id (ADR-010)
  path_raw          = string,
  path_normalized   = string,
  query_raw         = string,   -- raw query string (원본)
  query_normalized  = string,
  action            = "allow" | "deny",
  matched_rule_id   = string | nil,
  deny_reason       = string | nil,
  decision_source   = "policy_engine" | "security_scanner" | "rate_limiter" | "nginx_core",  -- rate_limiter: MVP 비범위
  threat_type       = string | nil,
  rule_name         = string | nil,   -- 스캐너 매칭 rule_name
  active_version    = string,         -- 요청 시작 시 스냅샷
  request_state     = string,         -- request_state enum
  start_time_ms     = number,         -- ngx.now() * 1000
}
```

## 10. Failure Taxonomy (HTTP)

HTTP 파이프라인 에러 분류 통일 표:

| 실패 유형 | 실패 모드 | HTTP 응답 | 비고 |
|---------|---------|---------|------|
| URL decode hard error / wrapper exception | fail-closed | 403 | 예: `decoder_path_exception`, `decoder_query_exception`, `decoder_load_error`, `ffi_fail:*` |
| scanner_internal_error | fail-closed | 403 | 스캐너 자체 오류 |
| budget_exceeded (Layer 1, >5ms) | fail-closed | 403 | 스캐너/디코더 내부 budget 초과 |
| ffi_timeout (Layer 2 watchdog) | fail-closed | 403 | Layer 2 hard timeout 초과 (ADR-009). per-worker leak 카운터 증가 |
| policy deny | — | 403 | 정책 매칭 deny |
| upstream fail | — | 502 | proxy_pass 연결 실패 |
| rate limit counter eviction | fail-open | — | shared_dict 용량 초과 (MVP 비범위) |
| logging 실패 (감사 로그 직렬화) | pre-commit: fail-closed, post-commit: warn-only | — | ADR-004: pre-commit audit 실패 → 거부. post-commit → 경고. 디스크 I/O는 Nginx에 위임 |
| native crash (worker) | process failure | — | nginx master가 재기동 |

> **Hook 순서**: `access_by_lua*` → `proxy_pass(upstream)` → `log_by_lua*`
> `log_by_lua`는 항상 upstream 응답 이후에 실행된다. 요청 처리 실패 시에도 log 단계는 도달한다.

## 11. Rate Limiting

> **ADR 참조**: [ADR-012: HTTP Data Plane Rate Limiting](../design/adr/ADR-012-http-data-plane-rate-limiting.md) — Sliding Window Counter + 정책 규칙별 `rate_limit` 필드

## 11. 타임아웃 설정

> **ADR 참조**: [ADR-009 FFI 타임아웃 강제](../design/adr/ADR-009-ffi-timeout-enforcement.md) — 3계층 방어 전략 확정

| 단계 | Layer 1 budget (내부) | Layer 2 hard timeout (watchdog) | 설명 |
|------|----------------------|-------------------------------|------|
| Rust FFI 디코더 | 2ms | 20ms | Layer 1 초과 시 `LUAGATE_BUDGET_EXCEEDED(-3)`, Layer 2 초과 시 `LUAGATE_TIMEOUT(-5)` → fail-closed |
| Rust FFI 스캐너 | 5ms | 50ms | 동일 |
| 업스트림 연결 | — | — | 5s (`proxy_connect_timeout`) |
| 업스트림 읽기 | — | — | 30s (`proxy_read_timeout`) |
| 업스트림 쓰기 | — | — | 30s (`proxy_send_timeout`) |

> **Layer 2 watchdog 동작**: Rust 내부에서 작업 thread를 spawn하고 `recv_timeout`으로 hard timeout을 강제한다. copy-in/copy-out 전략으로 caller-owned 버퍼의 ABI 안전성을 보장한다. 상세: ADR-009.
>
> **Layer 2 timeout 시 부수효과**: per-worker leak 카운터(`ffi:timeout:leak:<worker_id>`) 증가. 누적 임곗값(10) 초과 시 admin `/health` (`127.0.0.1:9090/health`)가 503으로 전환된다 (`reason: "ffi_thread_leak_threshold_exceeded"`). data plane `:8080/health`에는 적용되지 않는다. [ADR-009](../design/adr/ADR-009-ffi-timeout-enforcement.md) Phase 3, [admin-api.md](admin-api.md) §6.1 참조.

## 12. 헬스체크

- 경로: `GET /health`
- 정책 평가 없이 즉시 응답
- 응답: `200 OK` + `{"status": "ok", "policy_version": "..."}`
- Nginx `location /health` 별도 처리 블록

## 13. 의존성

- [spec/security-scanner.md](./security-scanner.md) — 보안 스캐너 상세
- [spec/policy-engine.md](./policy-engine.md) — 정책 평가 엔진 상세
- [spec/log-schema.md](./log-schema.md) — 로그 스키마 상세 (HTTP 30필드)
- [spec/rust-ffi-modules.md](./rust-ffi-modules.md) — Rust FFI 모듈 인터페이스
