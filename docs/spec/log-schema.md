# Log Schema Specification

> **ADR 참조**:
> - [ADR-004 로그/메트릭 데이터 모델 + 관리면 보안](../design/adr/ADR-004-log-metrics-admin-security.md)

## 1. 개요

LuaGate는 세 가지 로그 스트림을 생성한다:

| 로그 파일 | 내용 | 포맷 |
|-----------|------|------|
| `access.log` | HTTP 요청 로그 | JSON (NDJSON) |
| `stream.log` | TCP 세션 로그 | JSON (NDJSON) |
| `audit.log` | 관리면 감사 로그 | JSON (NDJSON) |
| `error.log` | Nginx/Lua 에러 | Nginx 기본 형식 |

모든 로그는 NDJSON(Newline-Delimited JSON) 형식으로 기록된다.

## 2. Null 표현 계약

> **Nullable 필드의 null 직렬화**: Nginx 기본 `-` 대신 JSON `null`로 직렬화한다.
> Lua record table에는 nullable 값을 `cjson.null` 또는 Lua string으로 유지하고,
> `log_by_lua` finalize 시 `cjson.encode(record)`로 최종 NDJSON 한 줄을 생성한다.
> Nginx `access_log`에는 이미 인코딩된 전체 JSON line 변수(`$luagate_log_json`)만 전달하며,
> 이 경우 `log_format`에 `escape=json`을 다시 적용하지 않는다.
>
> **기본값 선할당 전략**: `rewrite_by_lua` (HTTP) 또는 `preread_by_lua` (Stream) 진입 시
> 아래 기본값으로 초기화. `access/preread`에서 실제 판정 결과로 override, `log_by_lua`에서 finalize.
> 이를 통해 nginx_core early short-circuit (malformed request, 400/413/414) 시에도 모든 필드가 채워진다.

| 필드 | 기본값 |
|------|--------|
| `decision_source` | `"nginx_core"` |
| `threat_type` | `null` |
| `request_state` | `"short_circuited"` |
| `rule_name` | `null` |
| `matched_rule_id` | `null` |
| `deny_reason` | `null` |

## 3. HTTP 요청 로그 (`access.log`) — 30개 필드

### 3.1 필드 정의 (ADR-004 §4.1)

| 필드 | 타입 | JSON Nullability | log_format 토큰 | Producer Phase | Source Semantics |
|------|------|-----------------|----------------|----------------|-----------------|
| `timestamp` | string (ISO-8601 UTC) | NOT NULL | `$time_iso8601` | log_by_lua | 요청 수신 시각 (ngx.req.start_time() 기반) |
| `request_id` | string | NOT NULL | `$luagate_request_id` | Nginx map | 요청 고유 ID. 클라이언트 `X-Request-ID` 헤더 우선, 없으면 Nginx `$request_id` fallback. `X-Request-ID` 응답/업스트림 헤더로도 전달. [ADR-010](../design/adr/ADR-010-opentelemetry-tracing.md) |
| `src_ip` | string | NOT NULL | `$luagate_src_ip` | rewrite_by_lua | PROXY Protocol > XFF (trusted proxy 내) > $remote_addr |
| `src_port` | integer | NOT NULL | `$remote_port` | rewrite_by_lua | 클라이언트 원본 포트 |
| `dst_port` | integer | NOT NULL | `$server_port` | rewrite_by_lua | LuaGate 수신 포트 |
| `method` | string | NOT NULL | `$request_method` | rewrite_by_lua | HTTP 메서드 (대문자) |
| `host` | string | NOT NULL | `$host` | rewrite_by_lua | HTTP Host 헤더값 |
| `path_raw` | string | NOT NULL | `$luagate_path_raw` | rewrite_by_lua | **`?` 이전만** 잘라낸 Lua 계산값 (query 미포함, 디코딩 전) |
| `path_normalized` | string | NOT NULL | `$luagate_path_normalized` | rewrite_by_lua | 정규화된 경로 |
| `query_string` | string | NOT NULL | `$luagate_query_string` | rewrite_by_lua | redaction 적용된 raw 쿼리 (없으면 `""`) |
| `http_version` | string | NOT NULL | `$server_protocol` | rewrite_by_lua | `"HTTP/1.0"`, `"HTTP/1.1"`, `"HTTP/2.0"` |
| `user_agent` | string | NULLABLE | `$http_user_agent` | rewrite_by_lua | User-Agent 헤더값. 없으면 null |
| `content_length` | integer | NULLABLE | `$content_length` | rewrite_by_lua | 요청 본문 크기. 없으면 null |
| `action` | string (enum) | NOT NULL | `$luagate_action` | access_by_lua | `"allow"` \| `"deny"` |
| `matched_rule_id` | string | NULLABLE | `$luagate_matched_rule` | access_by_lua | 매칭 규칙 ID. 기본 정책 적용 시 null |
| `deny_reason` | string | NULLABLE | `$luagate_deny_reason` | access_by_lua | 차단 이유. action=allow 시 null |
| `decision_source` | string (enum) | NOT NULL | `$luagate_decision_source` | access_by_lua | 아래 enum 참조 |
| `threat_type` | string (enum) | NULLABLE | `$luagate_threat_type` | access_by_lua | 탐지된 위협 유형. 없으면 null |
| `threat_score` | number (0.0~1.0) | NULLABLE | `$luagate_threat_score` | access_by_lua | 위협 점수. 스캐너 미실행 시 null |
| `rule_name` | string | NULLABLE | `$luagate_rule_name` | access_by_lua | 스캐너 매칭 내부 rule_name. null if no match |
| `request_state` | string (enum) | NOT NULL | `$luagate_request_state` | log_by_lua | 아래 enum 참조 |
| `latency_ms` | float | NOT NULL | `$request_time` * 1000 | log_by_lua | 요청 수신~응답 전송 완료까지 (ms) |
| `upstream_latency_ms` | float | NULLABLE | `$upstream_response_time` * 1000 | log_by_lua | 업스트림 응답 시간. deny 시 null |
| `response_status` | integer | NOT NULL | `$status` | log_by_lua | HTTP 응답 코드 |
| `bytes_sent` | integer | NOT NULL | `$bytes_sent` | log_by_lua | 헤더 포함 total bytes (클라이언트로 전송) |
| `active_version` | string | NOT NULL | `$luagate_active_version` | rewrite_by_lua | **요청 시작 시 스냅샷** (decision 시점 아님) |
| `worker_id` | integer | NOT NULL | `$luagate_worker_id` | rewrite_by_lua | ngx.worker.id() |
| `ffi_timeout` | boolean | NOT NULL | ctx.ffi_timeout | access_by_lua | FFI Layer 2 watchdog timeout 여부. [ADR-009](../design/adr/ADR-009-ffi-timeout-enforcement.md). 기본값 `false` |
| `trace_id` | string (32-hex) | NULLABLE | `$luagate_trace_id` | rewrite_by_lua | W3C TraceContext trace ID. 트레이싱 비활성화 또는 pre-Lua rejection 시 null. 활성화 시 항상 기록 (sampled 여부 무관). [ADR-010](../design/adr/ADR-010-opentelemetry-tracing.md) |
| `span_id` | string (16-hex) | NULLABLE | `$luagate_span_id` | rewrite_by_lua | 루트 span ID. 트레이싱 비활성화 또는 pre-Lua rejection 시 null. 활성화 시 항상 기록. [ADR-010](../design/adr/ADR-010-opentelemetry-tracing.md) |

> **path_raw 정의**: `$request_uri`(query 포함)가 아니라, `?` 이전만 잘라낸 Lua 계산값.
> ```lua
> local uri = ngx.var.request_uri
> local path_raw = uri:match("^([^?]*)") or uri
> ```

### 3.2 decision_source 값 정의표 (HTTP)

| 값 | 설명 |
|----|------|
| `policy_engine` | 정책 엔진이 판정 (allow 또는 policy deny) |
| `security_scanner` | 보안 스캐너가 탐지하여 deny |
| `rate_limiter` | 레이트 리밋으로 deny ([ADR-012](../design/adr/ADR-012-http-data-plane-rate-limiting.md)) |
| `nginx_core` | nginx core early short-circuit (400/413/414/502 등) |

### 3.3 request_state 값 정의표 (HTTP)

| 값 | 조건 |
|----|------|
| `allowed` | 정책 allow + 업스트림 응답 성공 |
| `policy_denied` | 정책 엔진 deny |
| `scanner_denied` | 보안 스캐너 차단 |
| `rate_limited` | 레이트 리밋 초과 ([ADR-012](../design/adr/ADR-012-http-data-plane-rate-limiting.md)) |
| `upstream_error` | allow 판정이었으나 업스트림 502 |
| `short_circuited` | nginx_core early termination (400/413/414 등) — 기본값 |
| `internal_error` | 내부 오류로 인한 fail-closed (예: shared dict 미선언 503) ([ADR-012](../design/adr/ADR-012-http-data-plane-rate-limiting.md)) |

### 3.4 예시 JSON — HTTP allow

```json
{
  "timestamp": "2026-03-14T07:00:00.000Z",
  "request_id": "550e8400-e29b-41d4-a716-446655440000",
  "src_ip": "203.0.113.42",
  "src_port": 54321,
  "dst_port": 80,
  "method": "GET",
  "host": "api.example.com",
  "path_raw": "/api/v1/users",
  "path_normalized": "/api/v1/users",
  "query_string": "page=1",
  "http_version": "HTTP/1.1",
  "user_agent": "curl/8.0.0",
  "content_length": null,
  "action": "allow",
  "matched_rule_id": "allow-api",
  "deny_reason": null,
  "decision_source": "policy_engine",
  "threat_type": null,
  "threat_score": null,
  "rule_name": null,
  "request_state": "allowed",
  "latency_ms": 12.5,
  "upstream_latency_ms": 10.2,
  "response_status": 200,
  "bytes_sent": 1024,
  "active_version": "a3f9c2d1e8b4071f6a5d39c0e7b12345e8b4071f6a5d39c0e7b12345abcd1234",
  "worker_id": 2
}
```

### 3.5 예시 JSON — HTTP policy deny

```json
{
  "timestamp": "2026-03-14T07:00:01.000Z",
  "request_id": "660e8400-e29b-41d4-a716-446655440001",
  "src_ip": "198.51.100.1",
  "src_port": 61234,
  "dst_port": 80,
  "method": "GET",
  "host": "api.example.com",
  "path_raw": "/admin/config",
  "path_normalized": "/admin/config",
  "query_string": "",
  "http_version": "HTTP/1.1",
  "user_agent": "python-requests/2.28.0",
  "content_length": null,
  "action": "deny",
  "matched_rule_id": "block-admin-from-public",
  "deny_reason": "policy: block-admin-from-public",
  "decision_source": "policy_engine",
  "threat_type": null,
  "threat_score": null,
  "rule_name": null,
  "request_state": "policy_denied",
  "latency_ms": 0.3,
  "upstream_latency_ms": null,
  "response_status": 403,
  "bytes_sent": 89,
  "active_version": "a3f9c2d1e8b4071f6a5d39c0e7b12345e8b4071f6a5d39c0e7b12345abcd1234",
  "worker_id": 0
}
```

### 3.6 예시 JSON — HTTP scanner deny

```json
{
  "timestamp": "2026-03-14T07:00:02.000Z",
  "request_id": "770e8400-e29b-41d4-a716-446655440002",
  "src_ip": "10.0.0.99",
  "src_port": 55555,
  "dst_port": 80,
  "method": "GET",
  "host": "api.example.com",
  "path_raw": "/api/v1/search",
  "path_normalized": "/api/v1/search",
  "query_string": "q=1%27+OR+%271%27%3D%271",
  "http_version": "HTTP/1.1",
  "user_agent": "sqlmap/1.7",
  "content_length": null,
  "action": "deny",
  "matched_rule_id": null,
  "deny_reason": "scanner: sqli",
  "decision_source": "security_scanner",
  "threat_type": "sqli",
  "threat_score": 0.98,
  "rule_name": "sqli-union-select",
  "request_state": "scanner_denied",
  "latency_ms": 1.1,
  "upstream_latency_ms": null,
  "response_status": 403,
  "bytes_sent": 91,
  "active_version": "a3f9c2d1e8b4071f6a5d39c0e7b12345e8b4071f6a5d39c0e7b12345abcd1234",
  "worker_id": 1
}
```

### 3.7 예시 JSON — nginx_core early short-circuit (413)

```json
{
  "timestamp": "2026-03-14T07:00:03.000Z",
  "request_id": "880e8400-e29b-41d4-a716-446655440003",
  "src_ip": "203.0.113.10",
  "src_port": 60001,
  "dst_port": 80,
  "method": "POST",
  "host": "api.example.com",
  "path_raw": "/api/v1/upload",
  "path_normalized": "/api/v1/upload",
  "query_string": "",
  "http_version": "HTTP/1.1",
  "user_agent": "curl/8.0.0",
  "content_length": 104857600,
  "action": "deny",
  "matched_rule_id": null,
  "deny_reason": null,
  "decision_source": "nginx_core",
  "threat_type": null,
  "threat_score": null,
  "rule_name": null,
  "request_state": "short_circuited",
  "latency_ms": 0.1,
  "upstream_latency_ms": null,
  "response_status": 413,
  "bytes_sent": 171,
  "active_version": "a3f9c2d1e8b4071f6a5d39c0e7b12345e8b4071f6a5d39c0e7b12345abcd1234",
  "worker_id": 3
}
```

## 4. TCP 세션 로그 (`stream.log`) — 18개 필드

### 4.1 필드 정의 (ADR-004 §4.2)

상세 필드 테이블: [stream-pipeline.md §3](./stream-pipeline.md#3-tcp-세션-로그-필드-18개)

| 필드 | 타입 | JSON Nullability | log_format 토큰 | Producer Phase | Source Semantics |
|------|------|-----------------|----------------|----------------|-----------------|
| `timestamp` | string (ISO-8601 UTC) | NOT NULL | `$time_iso8601` | log_by_lua | 연결 종료 시각 |
| `connection_id` | string (UUID v4) | NOT NULL | `$luagate_conn_id` | preread_by_lua | 세션 고유 ID |
| `src_ip` | string | NOT NULL | `$remote_addr` | preread_by_lua | PROXY Protocol > $remote_addr |
| `src_port` | integer | NOT NULL | `$remote_port` | preread_by_lua | 클라이언트 포트 |
| `dst_port` | integer | NOT NULL | `$server_port` | preread_by_lua | LuaGate 수신 포트 |
| `detected_protocol` | string (enum) | NOT NULL | `$luagate_protocol` | preread_by_lua | `"tls"` \| `"http"` \| `"raw"` |
| `sni` | string | NULLABLE | `$luagate_sni` | preread_by_lua | TLS only. 그 외 null |
| `action` | string (enum) | NOT NULL | `$luagate_stream_action` | preread_by_lua | `"proxy"` \| `"deny"` |
| `matched_rule_id` | string | NULLABLE | `$luagate_matched_rule` | preread_by_lua | null if default deny |
| `decision_source` | string (enum) | NOT NULL | `$luagate_decision_source` | preread_by_lua | `"policy_engine"` \| `"nginx_core"` |
| `active_version` | string | NOT NULL | `$luagate_active_version` | preread_by_lua | 연결 시작 시 스냅샷 |
| `upstream` | string | NULLABLE | `$luagate_upstream` | preread_by_lua | `"host:port"`. deny 시 null |
| `session_duration_ms` | float | NOT NULL | `$session_time` * 1000 | log_by_lua | 세션 지속 시간 (ms) |
| `bytes_sent` | integer | NOT NULL | `$bytes_sent` | log_by_lua | 헤더 포함 total bytes |
| `bytes_received` | integer | NOT NULL | `$upstream_bytes_received` | log_by_lua | upstream에서 수신 bytes |
| `upstream_connect_time_ms` | float | NULLABLE | `$upstream_connect_time` * 1000 | log_by_lua | deny 시 null |
| `request_state` | string (enum) | NOT NULL | `$luagate_request_state` | log_by_lua | `proxied`/`denied`/`upstream_error`/`short_circuited` |
| `worker_id` | integer | NOT NULL | `$luagate_worker_id` | preread_by_lua | ngx.worker.id() |

> **Stream timestamp**: `ngx.now()` (preread 진입 시) 기준. `ngx.req.start_time()`은 HTTP 전용.
> **detected_protocol enum (MVP)**: `tls` / `http` / `raw`. Phase 2에서 `mysql`, `redis` 등 확장 예정.

### 4.2 예시 JSON — Stream proxy (allow)

```json
{
  "timestamp": "2026-03-14T07:00:10.000Z",
  "connection_id": "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
  "src_ip": "10.0.1.5",
  "src_port": 12345,
  "dst_port": 443,
  "detected_protocol": "tls",
  "sni": "api.example.com",
  "action": "proxy",
  "matched_rule_id": "allow-tls-api",
  "decision_source": "policy_engine",
  "active_version": "a3f9c2d1e8b4071f6a5d39c0e7b12345e8b4071f6a5d39c0e7b12345abcd1234",
  "upstream": "backend:8443",
  "session_duration_ms": 15234.0,
  "bytes_sent": 2048,
  "bytes_received": 8192,
  "upstream_connect_time_ms": 1.2,
  "request_state": "proxied",
  "worker_id": 1
}
```

### 4.3 예시 JSON — Stream deny

```json
{
  "timestamp": "2026-03-14T07:00:11.000Z",
  "connection_id": "7ba7b810-9dad-11d1-80b4-00c04fd430c9",
  "src_ip": "198.51.100.5",
  "src_port": 61111,
  "dst_port": 2222,
  "detected_protocol": "raw",
  "sni": null,
  "action": "deny",
  "matched_rule_id": "block-raw-non-22",
  "decision_source": "policy_engine",
  "active_version": "a3f9c2d1e8b4071f6a5d39c0e7b12345e8b4071f6a5d39c0e7b12345abcd1234",
  "upstream": null,
  "session_duration_ms": 0.5,
  "bytes_sent": 0,
  "bytes_received": 0,
  "upstream_connect_time_ms": null,
  "request_state": "denied",
  "worker_id": 0
}
```

## 5. 감사 로그 (`audit.log`) (ADR-004 §6.3)

> **감사 로그 보장 범위 (pre-commit vs post-commit)**:
>
> - **Pre-commit audit**: 직렬화(`cjson.encode`) 실패 시 mutation/reload를 **거부**한다 (코드 불변식, 설정 우회 불가).
> - **Post-mutation audit with rollback** (`token_rotated`): 실패 시 mutation rollback 후 거부.
> - **Post-commit audit** (`*_success`, `*_partial`): 실패 시 경고 로그만 남김 (mutation 이미 적용됨).
>
> 디스크 I/O 계층(Nginx `error_log`)의 기록 보장은 운영 모니터링에 위임한다 — `ngx.log()`는
> fire-and-forget이므로 디스크 full/I/O error는 Lua 코드에서 감지할 수 없다.

### 5.1 이벤트별 스키마

**정책 reload 성공 (`policy_reload_success`):**
```json
{
  "timestamp": "2026-03-14T07:00:00Z",
  "event": "policy_reload_success",
  "actor_ip": "127.0.0.1",
  "trigger": "api",
  "previous_version": "a3f2c1d4...",
  "new_version": "b4e3f2a1...",
  "subsystem": "http"
}
```

> `trigger`: `"api"` (POST /reload) 또는 `"hup"` (SIGHUP).

**정책 reload 실패 (`policy_reload_failure`):**
```json
{
  "timestamp": "2026-03-14T07:00:01Z",
  "event": "policy_reload_failure",
  "actor_ip": "127.0.0.1",
  "trigger": "api",
  "stage": "conflict_detect",
  "reason": "duplicate rule id: allow-health",
  "current_version": "a3f2c1d4..."
}
```

**정책 reload partial (`policy_reload_partial`):**
```json
{
  "timestamp": "2026-03-14T07:00:00Z",
  "event": "policy_reload_partial",
  "actor_ip": "127.0.0.1",
  "http_result": "committed",
  "stream_result": "lkg_retained"
}
```

**정책 변경 시도 (`policy_update_attempt`):**
```json
{
  "timestamp": "2026-03-14T07:00:02Z",
  "event": "policy_update_attempt",
  "actor_ip": "127.0.0.1",
  "trigger": "api",
  "new_version": "b4e3f2a1...",
  "previous_version": "a3f2c1d4..."
}
```

**정책 변경 성공 (`policy_update_success`):**
```json
{
  "timestamp": "2026-03-14T07:00:02Z",
  "event": "policy_update_success",
  "actor_ip": "127.0.0.1",
  "trigger": "api",
  "previous_version": "a3f2c1d4...",
  "new_version": "b4e3f2a1..."
}
```

**정책 변경 실패 (`policy_update_failure`):**
```json
{
  "timestamp": "2026-03-14T07:00:02Z",
  "event": "policy_update_failure",
  "actor_ip": "127.0.0.1",
  "trigger": "api",
  "stage": "commit",
  "reason": "http subsystem swap failed",
  "current_version": "a3f2c1d4..."
}
```

**인증 실패 (`auth_failure`):**
```json
{
  "timestamp": "2026-03-14T07:00:03Z",
  "event": "auth_failure",
  "actor_ip": "127.0.0.1",
  "path": "/api/v1/policies",
  "reason": "missing_token"
}
```

**토큰 교체 (`token_rotated`):**
```json
{
  "timestamp": "2026-03-19T12:00:00Z",
  "event": "token_rotated",
  "actor_ip": "127.0.0.1",
  "path": "/api/v1/admin/token/rotate"
}
```

> 토큰 값은 절대 로그에 포함하지 않음 (ADR-004 §6.2).

**서버 기동/종료 (`startup` / `shutdown`):**
```json
{
  "timestamp": "2026-03-14T07:00:04Z",
  "event": "startup",
  "active_http_version": "a3f2c1d4...",
  "active_stream_version": "a3f2c1d4...",
  "version": "luagate/0.1.0"
}
```

### 5.2 MCP 메타데이터 필드 (ADR-011 §8)

MCP 서버를 통한 Admin API 호출 시, 모든 감사 로그 이벤트에 아래 필드가 추가된다.

| 필드 | 타입 | JSON Nullability | 조건 | 설명 |
|------|------|-----------------|------|------|
| `actor_type` | string | NOT NULL | 항상 | `"mcp"` (X-MCP-Client 헤더 존재 시) 또는 `"api"` (기본값) |
| `client_name` | string | NULLABLE | MCP only | `X-MCP-Client` 헤더값. 일반 API 호출 시 필드 생략 |
| `tool_name` | string | NULLABLE | MCP only | `X-MCP-Tool` 헤더값. 일반 API 호출 시 필드 생략 |
| `session_id` | string | NULLABLE | MCP only | `X-MCP-Session-Id` 헤더값. 일반 API 호출 시 필드 생략 |
| `request_id` | string | NULLABLE | MCP only | `X-Request-ID` 헤더값. 일반 API 호출 시 필드 생략 |

> **하위 호환성**: `X-MCP-Client` 헤더가 없는 기존 API 호출은 `actor_type: "api"`만 추가되며,
> MCP 전용 필드는 생략된다.

## 6. src_ip 우선순위 (HTTP + Stream 공통)

| 우선순위 | 소스 | 조건 |
|---------|------|------|
| 1 | PROXY Protocol (`$proxy_protocol_addr`) | nginx `proxy_protocol on` 설정 시 |
| 2 | X-Forwarded-For (최우측 non-trusted valid IPv4) | trusted proxy 범위 내 $remote_addr 시. 오른쪽→왼쪽 순회, 스푸핑 방어. |
| 3 | `$remote_addr` | fallback (직접 연결) |

> **Trusted proxy**: `conf/luagate.yaml`의 `trusted_proxies` 배열 (개별 IP + CIDR 범위).
> 빈 배열(기본값) 시 XFF 무시, `$remote_addr` 사용.
> 구현: `lua/luagate/http/client_ip.lua`.

## 7. 메트릭 목록

`luagate_metrics` (HTTP) + `luagate_stream_metrics` (Stream) zone. 레이블 허용 목록 및 키 스키마 상세: [ADR-006](../design/adr/ADR-006-metrics-cardinality-export-model.md) 참조.

| 메트릭 | 타입 | 레이블 | 설명 |
|--------|------|--------|------|
| `luagate_http_requests_total` | counter | `action` | HTTP 전체 요청 수 |
| `luagate_http_requests_denied_total` | counter | — | deny된 요청 수 (정책 + 스캐너 모두) |
| `luagate_http_scanner_threats_total` | counter | `threat_type` | 스캐너 deny 시 위협 유형별 카운터 (ADR-006 §1.2) |
| `luagate_http_response_time_ms` | histogram | — | 응답 시간 분포 |
| `luagate_http_upstream_errors_total` | counter | — | upstream 502 수 |
| `luagate_active_connections` | gauge | `type` (`http`/`stream`) | 현재 활성 연결 |
| `luagate_stream_connections_total` | counter | — | 전체 스트림 연결 수 |
| `luagate_stream_connections_denied_total` | counter | — | deny된 연결 수 |
| `luagate_stream_bytes_sent_total` | counter | — | 총 송신 바이트 |
| `luagate_stream_bytes_received_total` | counter | — | 총 수신 바이트 |
| `luagate_stream_protocol_detected_total` | counter | `protocol` | 탐지된 프로토콜별 카운터 |
| `luagate_policy_reload_total` | counter | — | reload 시도 횟수 |
| `luagate_policy_reload_failures_total` | counter | — | reload 실패 횟수 |
| `luagate_policy_loaded` | gauge | `subsystem` | 서브시스템별 정책 로드 상태 (1=로드됨, 0=미로드). `subsystem="http"`는 항상 노출. `subsystem="stream"`은 정책에 `stream_rules`가 존재하는 배포에서만 노출되며 (`stream:configured` 플래그 기반), HTTP-only 배포에서는 해당 시계열 자체가 생략된다. stream이 설정되었으나 첫 로드가 실패한 경우 `{subsystem="stream"} 0`을 출력하여 alert 발화가 가능하다. [ADR-008](../design/adr/ADR-008-multi-instance-policy-sync.md) §8.2. 버전 해시는 `/health`에서만 노출 (ADR-006 카디널리티 규칙) |
| `luagate_shared_dict_capacity_bytes` | gauge | `zone` | shared_dict 용량 (zone별) |
| `luagate_shared_dict_free_bytes` | gauge | `zone` | shared_dict 여유 공간 (zone별) |

> **shared_dict 메트릭**: `capacity`와 `free`를 별도 gauge로 분리. zone 레이블로 구분. 모든 5개 zone(`luagate_policy`, `luagate_state`, `luagate_metrics`, `luagate_stream_metrics`, `luagate_connections`)에서 노출.

## 8. Nginx 로그 설정

```nginx
# Nginx-managed logging 방식 (권장):
# log_by_lua에서 Lua table을 cjson.encode()로 한 줄 JSON으로 인코딩하고,
# nginx log_format + access_log 지시자로 그 결과를 그대로 파일에 기록한다.
# 이 방식은 Nginx의 log buffering, rotation 시그널(USR1) 처리를 활용한다.
#
# `$luagate_log_json`은 이미 cjson.encode(record) 결과이므로
# log_format에서 escape=json을 다시 걸지 않는다. 중복 escape 시 NDJSON이 깨진다.

log_format luagate_access_json '$luagate_log_json';

log_by_lua_block {
    local cjson = require("cjson.safe")

    local record = {
        timestamp = ngx.var.time_iso8601,
        request_id = ngx.var.luagate_request_id,
        src_ip = ngx.var.luagate_src_ip,
        src_port = tonumber(ngx.var.remote_port),
        dst_port = tonumber(ngx.var.server_port),
        method = ngx.req.get_method(),
        host = ngx.var.host,
        path_raw = ngx.var.luagate_path_raw,
        path_normalized = ngx.var.luagate_path_normalized,
        query_string = ngx.var.luagate_query_string,
        action = ngx.var.luagate_action,
        matched_rule_id = ngx.ctx.luagate.matched_rule_id or cjson.null,
        deny_reason = ngx.ctx.luagate.deny_reason or cjson.null,
        decision_source = ngx.ctx.luagate.decision_source or "nginx_core",
        threat_type = ngx.ctx.luagate.threat_type or cjson.null,
        request_state = ngx.var.luagate_request_state,
        response_status = tonumber(ngx.var.status),
        bytes_sent = tonumber(ngx.var.bytes_sent),
        active_version = ngx.var.luagate_active_version,
        worker_id = tonumber(ngx.var.luagate_worker_id),
    }

    ngx.var.luagate_log_json = assert(cjson.encode(record))
}

access_log /var/log/luagate/access.log luagate_access_json buffer=64k flush=5s;
```

> **Lua 직접 파일 쓰기(`io.open`/`io.write`) 사용 금지**:
> - Lua에서 `io.open`으로 직접 파일에 쓰면 Nginx의 non-blocking I/O 모델을 우회하여 worker 이벤트 루프를 블로킹할 수 있다.
> - 파일 rotate 시 `kill -USR1` 시그널이 Nginx 관리 파일 핸들에만 작용하므로, Lua가 직접 연 파일 핸들은 rotate 후에도 구 파일에 계속 쓰게 된다.
> - **대안**: Nginx `access_log`(위 설정), 또는 non-blocking socket logger(syslog/UDP), 또는 per-worker in-memory buffer + 주기적 flush 방식을 사용한다.

## 9. 로그 로테이션 권장 설정

```
# /etc/logrotate.d/luagate
# 보존 기간은 ADR-007 §4.2 확정 정책 기준
/var/log/luagate/access.log
/var/log/luagate/stream.log {
    daily
    rotate 90
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        kill -USR1 $(cat /var/run/nginx.pid)
    endscript
}

/var/log/luagate/audit.log {
    daily
    rotate 365
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        kill -USR1 $(cat /var/run/nginx.pid)
    endscript
}

/var/log/luagate/error.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        kill -USR1 $(cat /var/run/nginx.pid)
    endscript
}
```

> **Redaction 및 보존 정책**: [ADR-007 로그 Redaction 정책 + 보존/파기 기간](../design/adr/ADR-007-log-redaction-and-retention.md) 참조.
> 민감 헤더(Authorization, Cookie, X-API-Key, X-Auth-Token) 전체 마스킹, query_string 패턴 기반 부분 마스킹,
> access.log 90일 / audit.log 365일 보존, redaction 실패 시 fail-closed(전체 마스킹) 확정.

## 10. 의존성

- [ADR-004](../design/adr/ADR-004-log-metrics-admin-security.md) — 스키마 원본 정의
- [ADR-007](../design/adr/ADR-007-log-redaction-and-retention.md) — Redaction 정책 + 보존/파기 기간
- [spec/http-pipeline.md](./http-pipeline.md) — access.log 생성 단계 (27필드)
- [spec/stream-pipeline.md](./stream-pipeline.md) — stream.log 생성 단계 (18필드)
- [spec/admin-api.md](./admin-api.md) — audit.log 생성 단계
