# Stream Pipeline Specification

> **ADR 참조**:
> - [ADR-001 실행/상태 공유 모델](../design/adr/ADR-001-execution-shared-state-model.md)
> - [ADR-002 정책 평가 규칙](../design/adr/ADR-002-policy-evaluation-conflict-detection.md)
> - [ADR-004 로그/메트릭](../design/adr/ADR-004-log-metrics-admin-security.md)

## 1. 개요

> **HTTP vs Stream 용어 차이**:
> - HTTP 파이프라인의 허용 action: `allow` / 차단 action: `deny`
> - Stream 파이프라인의 허용 action: **`proxy`** / 차단 action: `deny`
>
> Stream에서 `allow` 대신 `proxy`를 사용하는 이유: TCP 스트림은 단순 허용이 아니라 반드시 업스트림으로 **프록시**해야 하기 때문이다. 정책 스키마의 `action` 필드에 `proxy`를 명시함으로써 업스트림 지정(`upstream: ...`)과의 연관성을 명확히 한다.

LuaGate Stream 파이프라인은 TCP/UDP 레벨 스트림 연결을 처리한다.
HTTP와 달리 L4 레벨에서 연결을 수신하여 프로토콜을 탐지하고 정책 기반으로 프록시 또는 차단한다.

Nginx `stream {}` 블록 (`conf/nginx.stream.conf`)에서 구성한다.

## 2. 처리 단계

### 2.1 preread_by_lua (프로토콜 탐지 + 스트림 정책 평가)

**목적**: 첫 N 바이트를 읽어 애플리케이션 프로토콜을 탐지한다.

> **reqsock:peek() 전제**: preread buffer 조회는 `ngx.req.socket()` 기반의 peek 방식으로 수행한다.
> peek 후 데이터는 소비되지 않아 업스트림으로 그대로 전달된다.

```lua
-- preread 단계: ngx.req.socket() 기반으로 preread buffer를 소비하지 않고 조회
local sock = assert(ngx.req.socket())
local data, err = peek_preread_bytes(sock, 16)  -- 의사 코드
if not data then
    -- peek I/O 실패 → fail-closed (연결 종료). §9.1 매트릭스 참조
    -- "raw"로 처리하지 않음: I/O error는 detection miss(raw fallback)와 구분한다
    ngx.log(ngx.ERR, "preread peek failed: ", err)
    return ngx.exit(ngx.ERROR)
end

-- 프로토콜 탐지 순서 (rust-ffi-modules.md detect_protocol 호출)
1. TLS ClientHello 탐지 (0x16 0x03 ...)
   └─ SNI 추출: TLS Extension(server_name) 파싱
   └─ fragmented ClientHello → LUAGATE_NEED_MORE_DATA (최대 preread_timeout까지 재시도)
   └─ malformed TLS → fail-closed (raw와 구분)
2. HTTP 메서드 탐지 (GET/POST/... 으로 시작)
   └─ protocol=http: plaintext HTTP. CONNECT 메서드는 별도 처리 예고 (현재 미지원)
3. 기타 → "raw" (non-TLS, non-HTTP plaintext)
```

**탐지 가능 프로토콜 (MVP):**

| 프로토콜 | 탐지 방법 | SNI 추출 | 설명 |
|---------|---------|---------|------|
| `tls` | TLS ClientHello 레코드 (첫 바이트: 0x16) | ✅ | TLS 1.2/1.3 지원. 1.0/1.1 deprecated |
| `http` | HTTP 메서드 문자열 (GET/POST/PUT/DELETE/HEAD/OPTIONS) | ❌ | plaintext HTTP. CONNECT 미지원(MVP) |
| `raw` | 위 패턴 불일치 | ❌ | non-TLS / non-HTTP |

> **Phase 2**: `mysql`, `redis` 등 추가 프로토콜 탐지 확장 예정.

탐지 결과는 `ngx.ctx.luagate_stream` 컨텍스트에 저장.

> **중요**: stream 파이프라인에는 HTTP 모듈의 `access_by_lua`와 동일한 단계를 가정하지 않는다.
> 탐지와 정책 평가는 모두 `preread_by_lua`에서 수행하고, 판정 결과만 `ngx.ctx.luagate_stream`에 저장한다.

### 2.2 preread 내 정책 판정

```
┌──────────────────────────────────────────┐
│  stream preread_by_lua 처리 순서          │
│                                          │
│  1. 정책 버전 확인 (shared dict L2)       │
│     L1 캐시 active_version 비교          │
│     └─ 변경됨 → L2에서 새 정책 로드     │
│                                          │
│  2. 스트림 정책 매칭 (ADR-002)            │
│     scope 기준:                          │
│       - src_ip_cidr (Lua CIDR 매칭)      │
│       - dst_port (exact/range)           │
│       - detected_protocol (exact)        │
│       - sni (exact/wildcard, TLS인 경우) │
│                                          │
│  3. 판정:                                │
│     ├─ proxy → 연결 계속                 │
│     └─ deny → 연결 종료                 │
│              + luagate_connections 감소  │
└──────────────────────────────────────────┘
```

**스트림 정책 예시:**

```yaml
stream_rules:
  - id: deny-raw-non-22
    scope:
      detected_protocol: raw
      dst_port: "23-65535"
    priority: 1
    action: deny

  - id: allow-tls-api
    scope:
      detected_protocol: tls
      sni: "api.example.com"
      dst_port: 443
    priority: 10
    action: proxy
    upstream: "backend:443"
```

### 2.3 proxy_pass (TCP 프록시)

- `preread_by_lua`에서 `proxy` 판정된 연결만 도달
- Nginx stream `proxy_pass` 지시자로 업스트림 TCP 서버에 연결
- 양방향 트래픽 투명 전달
- `bytes_tx`, `bytes_rx` 추적: `$bytes_sent`, `$upstream_bytes_received` 변수 활용

### 2.4 log_by_lua (세션 종료 후 로그)

- TCP 연결 종료 시 트리거
- **18개 필드** JSON 레코드 생성 — 상세 필드 목록: [log-schema.md](./log-schema.md)
- `luagate_stream_metrics` shared dict 카운터 업데이트
- `luagate_connections` shared dict 활성 연결 수 감소

## 3. TCP 세션 로그 필드 (18개)

| 필드 | 타입 | JSON Nullability | log_format 토큰 | Producer Phase | Source Semantics |
|------|------|-----------------|----------------|----------------|-----------------|
| `timestamp` | string | NOT NULL | `$time_iso8601` | log_by_lua | 연결 종료 시각 |
| `connection_id` | string | NOT NULL | `$luagate_conn_id` | preread_by_lua | UUID |
| `src_ip` | string | NOT NULL | `$remote_addr` | preread_by_lua | PROXY Protocol > $remote_addr |
| `src_port` | integer | NOT NULL | `$remote_port` | preread_by_lua | |
| `dst_port` | integer | NOT NULL | `$server_port` | preread_by_lua | |
| `detected_protocol` | string | NOT NULL | `$luagate_protocol` | preread_by_lua | `tls`/`http`/`raw` |
| `sni` | string | NULLABLE | `$luagate_sni` | preread_by_lua | TLS only, else null |
| `action` | string | NOT NULL | `$luagate_stream_action` | preread_by_lua | `proxy`/`deny` |
| `matched_rule_id` | string | NULLABLE | `$luagate_matched_rule` | preread_by_lua | null if default deny |
| `decision_source` | string | NOT NULL | `$luagate_decision_source` | preread_by_lua | 아래 enum 참조 |
| `active_version` | string | NOT NULL | `$luagate_active_version` | preread_by_lua | 연결 시작 시 스냅샷 |
| `upstream` | string | NULLABLE | `$luagate_upstream` | preread_by_lua | proxy 시만 non-null |
| `session_duration_ms` | float | NOT NULL | `$session_time` 기반 | log_by_lua | 단위: ms |
| `bytes_sent` | integer | NOT NULL | `$bytes_sent` | log_by_lua | 헤더 포함 total bytes |
| `bytes_received` | integer | NOT NULL | `$upstream_bytes_received` | log_by_lua | upstream에서 수신 |
| `upstream_connect_time_ms` | float | NULLABLE | `$upstream_connect_time` | log_by_lua | deny 시 null |
| `request_state` | string | NOT NULL | `$luagate_request_state` | log_by_lua | 아래 enum 참조 |
| `worker_id` | integer | NOT NULL | `$luagate_worker_id` | preread_by_lua | ngx.worker.id() |

> **timestamp**: Stream에서는 `ngx.now()`(preread 진입 시)를 기준으로 한다. `ngx.req.start_time()`은 HTTP 전용 함수.

## 4. decision_source 값 체계 (Stream)

| 값 | 설명 |
|----|------|
| `policy_engine` | 스트림 정책 엔진이 판정 (proxy 또는 policy deny) |
| `nginx_core` | nginx core가 early short-circuit (preread 타임아웃 등) |

> **Stream Rate Limiting**: **MVP 비범위**. 추후 별도 ADR로 정의.
> `rate_limiter` decision_source는 MVP에서 사용하지 않는다.

## 5. request_state 값 체계 (Stream)

| 값 | 조건 |
|----|------|
| `proxied` | proxy 판정 + upstream 연결 성공 |
| `denied` | deny 판정 |
| `upstream_error` | proxy 판정이었으나 upstream 연결 실패 |
| `short_circuited` | nginx_core early termination (preread 타임아웃 등) |

## 6. Stream Metrics

`luagate_stream_metrics` zone (architecture.md §3.1 참조):

| 메트릭 | 타입 | 설명 |
|--------|------|------|
| `luagate_stream_connections_total` | counter | 전체 스트림 연결 수 |
| `luagate_stream_connections_denied_total` | counter | deny된 연결 수 |
| `luagate_stream_bytes_sent_total` | counter | 총 송신 바이트 |
| `luagate_stream_bytes_received_total` | counter | 총 수신 바이트 |
| `luagate_active_connections{type="stream"}` | gauge | 현재 활성 연결 수 (log-schema.md §7, admin-api.md §6.8과 동일 이름) |
| `luagate_stream_protocol_detected_total` | counter | 탐지된 프로토콜별 카운터 (label: protocol) |

## 7. 스트림 컨텍스트 객체

```lua
ngx.ctx.luagate_stream = {
  connection_id        = "UUID",
  src_ip               = string,
  src_port             = number,
  dst_port             = number,
  detected_protocol    = "tls" | "http" | "raw",
  sni                  = string | nil,
  action               = "proxy" | "deny",
  matched_rule_id      = string | nil,
  deny_reason          = string | nil,
  decision_source      = "policy_engine" | "nginx_core",
  active_version       = string,   -- 연결 시작 시 스냅샷
  request_state        = string,
  start_time_ms        = number,
  upstream             = string | nil,
  worker_id            = number,   -- ngx.worker.id()
}
```

## 8. 활성 연결 추적

```lua
-- 연결 수락 시
ngx.shared.luagate_connections:incr("active_stream", 1, 0)

-- 연결 종료 시 (log_by_lua)
ngx.shared.luagate_connections:incr("active_stream", -1, 0)
```

Prometheus 메트릭: `luagate_active_connections{type="stream"}`

## 9. Failure Taxonomy (Stream)

Stream 파이프라인 에러 분류 통일 표:

| 실패 유형 | 실패 모드 | 비고 |
|---------|---------|------|
| decode error | fail-closed | 연결 종료 |
| parser error (stream) | fail-closed | malformed packet, 연결 종료 |
| detection miss (non-TLS, non-HTTP) | raw fallback | `detected_protocol=raw`, 정책으로 판정 |
| malformed TLS | fail-closed | parser error와 구분. raw fallback 아님 |
| upstream fail | 연결 종료 | upstream 502에 해당 |
| rate limit counter eviction | fail-open | shared_dict 용량 초과 (MVP 비범위) |
| logging 실패 (감사 로그 직렬화) | fail-closed | ADR-004: audit 직렬화 실패 → 거부. 디스크 I/O는 Nginx에 위임 |
| native crash (worker) | process failure | nginx master가 재기동 |

> **Hook 순서**: `preread_by_lua*` → `proxy_pass(upstream)` → `log_by_lua*`
> `log_by_lua`는 항상 upstream 이후에 실행된다.

### 9.1 detection miss vs parser error 매트릭스

| 상황 | 분류 | detected_protocol | 처리 |
|------|------|-----------------|------|
| 첫 바이트가 TLS 레코드 헤더 (0x16)이지만 ClientHello 파싱 실패 | parser error (malformed TLS) | — | fail-closed (연결 종료) |
| 첫 바이트가 HTTP 메서드이지만 파싱 불가 | parser error | — | fail-closed (연결 종료) |
| 첫 바이트가 TLS/HTTP 패턴과 무관한 임의 바이트 | detection miss | `raw` | raw fallback (정책 평가) |
| LUAGATE_NEED_MORE_DATA → preread_timeout 초과 | timeout | `raw` | fail-closed (연결 종료) |
| peek 자체 실패 (I/O error) | I/O error | — | fail-closed (연결 종료) |

> **malformed TLS vs raw 구분**: TLS 레코드 헤더(0x16)가 확인된 후 파싱에 실패하면 malformed-TLS(fail-closed).
> 헤더 자체가 TLS 패턴이 아니면 raw(detection miss).

## 10. TLS 패스스루 vs 터미네이션

LuaGate Stream 파이프라인은 기본적으로 **TLS 패스스루** 모드다:
- TLS 연결을 복호화하지 않음
- SNI만 탐지하여 라우팅/차단 결정에 사용
- 실제 TLS 핸드쉐이크는 업스트림이 처리

<!-- ADR 필요 -->
> **TODO**: TLS 터미네이션 지원(LuaGate에서 인증서 처리) 필요 시 ADR 필요

## 10. 타임아웃 설정

| 설정 | 값 | 설명 |
|------|----|------|
| `preread_timeout` | 5s | preread 데이터 수신 대기 |
| `proxy_connect_timeout` | 5s | 업스트림 연결 대기 |
| `proxy_timeout` | 300s | 세션 유휴 타임아웃 |

## 11. 의존성

- [spec/policy-engine.md](./policy-engine.md) — 스트림 정책 평가
- [spec/log-schema.md](./log-schema.md) — TCP 세션 로그 스키마 (18필드)
- [spec/architecture.md](./architecture.md) — 전체 프로세스 모델, zone 목록
- [spec/rust-ffi-modules.md](./rust-ffi-modules.md) — detect_protocol, SNI 추출 (radix FFI 바인딩 유지, handler에서는 미사용)
