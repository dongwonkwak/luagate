# ADR-004: 로그/메트릭 데이터 모델 + 관리면 보안

> [← ADR 인덱스로 돌아가기](./README.md)

| 항목 | 내용 |
|------|------|
| **Status** | Accepted |
| **Date** | 2026-03-13 |
| **Deciders** | LuaGate Architects |
| **Issue** | [DON-88](https://linear.app/dongwon/issue/DON-88) |
| **Depends on** | [ADR-001](./ADR-001-execution-shared-state-model.md) |

---

## Status

**Accepted** — Phase 0-A에서 고정.

---

## Context

LuaGate는 API 게이트웨이이자 보안 게이트웨이로서 두 가지 관찰 가능성 요구가 있다:

1. **로그/메트릭**: 요청별 상세 로그와 집계 메트릭을 어떤 스키마로 기록하는가?
   - 보안 분석을 위해 원본(raw)과 정규화(normalized) 경로 모두 보존해야 한다.
2. **관리면 보안**: Admin API 엔드포인트를 어떻게 보호하는가?
   - 관리 인터페이스 노출은 공격 표면이 되므로 최소 권한 원칙을 적용해야 한다.

---

## Decision

### §4 로그/메트릭 데이터 모델

#### 4.1 HTTP 요청 로그 스키마 (28개 필드)

각 HTTP 요청 처리 완료 시 아래 JSON 레코드를 `access.log`에 기록한다.
상세 필드 정의 및 예시: [spec/log-schema.md §3](../../spec/log-schema.md#3-http-요청-로그-accesslog--28개-필드)

| # | 필드명 | 타입 | 설명 |
|---|--------|------|------|
| 1 | `timestamp` | ISO-8601 string | 요청 수신 시각 (UTC) |
| 2 | `request_id` | string | 요청별 고유 식별자 (클라이언트 `X-Request-ID` 또는 Nginx `$request_id` — [ADR-010](./ADR-010-opentelemetry-tracing.md)) |
| 3 | `src_ip` | string | 클라이언트 원본 IP (PROXY Protocol > XFF 최우측 non-trusted > `$remote_addr`) |
| 4 | `src_port` | number | 클라이언트 원본 포트 |
| 5 | `dst_port` | number | 서버 리슨 포트 |
| 6 | `method` | string | HTTP 메서드 (GET, POST 등) |
| 7 | `host` | string | HTTP Host 헤더값 |
| 8 | `path_raw` | string | 원본 요청 경로 (`?` 이전 Lua 계산값, 디코딩 전) |
| 9 | `path_normalized` | string | 정규화된 경로 (URL 디코딩, 경로 정규화 후) |
| 10 | `query_string` | string | redaction 적용된 raw 쿼리 (없으면 `""`) |
| 11 | `http_version` | string | HTTP 버전 (`"HTTP/1.0"`, `"HTTP/1.1"`, `"HTTP/2.0"`) |
| 12 | `user_agent` | string \| null | User-Agent 헤더값. 없으면 null |
| 13 | `content_length` | number \| null | 요청 본문 크기 (바이트). 없으면 null |
| 14 | `action` | enum | `allow` \| `deny` |
| 15 | `matched_rule_id` | string \| null | 매칭된 규칙 ID (기본 정책 적용 시 null) |
| 16 | `deny_reason` | string \| null | 차단 이유 (action=allow 시 null) |
| 17 | `decision_source` | enum | `policy_engine` \| `security_scanner` \| `rate_limiter` \| `nginx_core` |
| 18 | `threat_type` | string \| null | 탐지된 위협 유형 (`sqli`/`xss`/`path_traversal` 등). 없으면 null |
| 19 | `threat_score` | number \| null | 위협 점수 (0.0 ~ 1.0). 스캐너 미실행 시 null |
| 20 | `rule_name` | string \| null | 스캐너 매칭 내부 rule_name. null if no match |
| 21 | `request_state` | enum | `allowed` \| `policy_denied` \| `scanner_denied` \| `rate_limited` \| `upstream_error` \| `short_circuited` |
| 22 | `latency_ms` | number | 총 처리 시간 (밀리초) |
| 23 | `upstream_latency_ms` | number \| null | 업스트림 응답 시간. deny 시 null |
| 24 | `response_status` | number | HTTP 응답 상태 코드 |
| 25 | `bytes_sent` | number | 헤더 포함 total bytes (클라이언트로 전송) |
| 26 | `active_version` | string | 요청 시작 시 스냅샷한 HTTP 활성 정책 SHA256 |
| 27 | `worker_id` | number | 처리한 Nginx worker ID (`ngx.worker.id()`) |
| 28 | `ffi_timeout` | boolean | FFI Layer 2 watchdog timeout 여부. 기본값 `false` |

**로그 예시:**

```json
{
  "timestamp": "2026-03-13T12:34:56.789Z",
  "request_id": "550e8400-e29b-41d4-a716-446655440000",
  "src_ip": "203.0.113.42",
  "src_port": 54321,
  "dst_port": 80,
  "method": "GET",
  "host": "api.example.com",
  "path_raw": "/api/v1/%2e%2e/admin",
  "path_normalized": "/admin",
  "query_string": "id=1%27OR%271%27%3D%271",
  "http_version": "HTTP/1.1",
  "user_agent": "Mozilla/5.0 ...",
  "content_length": null,
  "action": "deny",
  "matched_rule_id": "deny-path-traversal",
  "deny_reason": "path traversal detected",
  "decision_source": "security_scanner",
  "threat_type": "path_traversal",
  "threat_score": 0.95,
  "rule_name": "path-traversal-dotdot",
  "request_state": "scanner_denied",
  "latency_ms": 0.8,
  "upstream_latency_ms": null,
  "response_status": 403,
  "bytes_sent": 91,
  "active_version": "a3f2c1d4e5b6789012345678901234567890abcd",
  "worker_id": 2,
  "ffi_timeout": false
}
```

#### 4.2 TCP 세션 로그 스키마 (18개 필드)

TCP 스트림 프록시 세션 종료 시 아래 레코드를 `stream.log`에 기록한다.
상세 필드 정의 및 예시: [spec/log-schema.md §4](../../spec/log-schema.md#4-tcp-세션-로그-streamlog--18개-필드)

| # | 필드명 | 타입 | 설명 |
|---|--------|------|------|
| 1 | `timestamp` | ISO-8601 string | 연결 종료 시각 (UTC) |
| 2 | `connection_id` | UUID string | 세션별 고유 식별자 |
| 3 | `src_ip` | string | 클라이언트 IP (PROXY Protocol > `$remote_addr`) |
| 4 | `src_port` | number | 클라이언트 포트 |
| 5 | `dst_port` | number | 서버 리슨 포트 |
| 6 | `detected_protocol` | string | 탐지된 프로토콜 (`tls` \| `http` \| `raw`) |
| 7 | `sni` | string \| null | TLS SNI 값 (TLS 세션인 경우). 그 외 null |
| 8 | `action` | enum | `proxy` \| `deny` |
| 9 | `matched_rule_id` | string \| null | 매칭된 규칙 ID. default deny 시 null |
| 10 | `decision_source` | enum | `policy_engine` \| `nginx_core` |
| 11 | `active_version` | string | 연결 시작 시 스냅샷한 Stream 활성 정책 SHA256 |
| 12 | `upstream` | string \| null | `"host:port"`. deny 시 null |
| 13 | `session_duration_ms` | number | 세션 지속 시간 (밀리초) |
| 14 | `bytes_sent` | number | 헤더 포함 total bytes |
| 15 | `bytes_received` | number | upstream에서 수신 bytes |
| 16 | `upstream_connect_time_ms` | number \| null | deny 시 null |
| 17 | `request_state` | enum | `proxied` \| `denied` \| `upstream_error` \| `short_circuited` |
| 18 | `worker_id` | number | 처리한 Nginx worker ID (`ngx.worker.id()`) |

#### 4.2b 로그 Redaction 정책

> **[ADR-007에 의해 부분 대체]** 이 조항의 일부 결정은 [ADR-007](./ADR-007-log-redaction-and-retention.md)에 의해 갱신되었다:
> - `X-API-Key`, `X-Auth-Token` 헤더: P2(권장) → **P1(필수)** 격상
> - `query_string` redaction 수행 시점: `log_by_lua` → **`rewrite_by_lua`** 변경
> - 민감 query 파라미터 목록 확장 및 패턴 매칭 규칙 구체화
>
> 현행 정책은 [ADR-007 §1~§3](./ADR-007-log-redaction-and-retention.md)을 따른다.

보안/개인정보 보호를 위해 다음 헤더/필드의 값을 로그에 기록하기 전에 마스킹한다.

**마스킹 대상 (우선순위 순):**

| 우선순위 | 대상 | 마스킹 방법 | 예시 |
|----------|------|-------------|------|
| P1 (필수) | `Authorization` 헤더 | 전체 마스킹 `"***"` | `Bearer abc123` → `"***"` |
| P1 (필수) | `Cookie` 헤더 | 전체 마스킹 `"***"` | `session=xyz` → `"***"` |
| P1 (필수) | `token`, `api_key`, `apikey` 쿼리 파라미터 | 값만 마스킹 `"***"` | `?token=secret` → `?token=***` |
| P1 (필수) | `password`, `passwd`, `secret` 쿼리 파라미터 | 값만 마스킹 `"***"` | `?password=abc` → `?password=***` |
| P2 (권장) | `X-API-Key`, `X-Auth-Token` 헤더 | 전체 마스킹 `"***"` | — |
| P2 (권장) | JWT payload (Authorization: Bearer) | 전체 마스킹, 타입만 보존 | `Bearer <jwt>` → `"***"` |

**Redaction 적용 시점:**
- `log_by_lua` 단계에서 JSON 레코드 생성 시 적용
- 원본 데이터는 Lua 메모리에서만 처리하며 파일에 기록하지 않음
- `query_string` 필드: 민감 파라미터 값만 마스킹, 파라미터 키는 유지

**Redaction 미적용 필드:**
- `path_raw`, `path_normalized`: 경로 자체는 보안 분석 필수 → 마스킹 없음
- `user_agent`: 스캐너 탐지용 → 마스킹 없음

#### 4.3 메트릭 스키마

Prometheus 형식으로 `/metrics` 엔드포인트(관리면)에서 노출.
집계 기준: 경로 정규화(`path_normalized` 계산)는 로그 목적으로 `rewrite_by_lua`에서 수행한다. **메트릭 레이블에 경로를 사용하지 않는다** (ADR-006 §2 참조).

**Cardinality 원칙**: 메트릭 레이블은 cardinality 폭발을 방지하기 위해 **low-cardinality** 값만 허용한다.
- `path_normalized`: **메트릭 레이블 사용 금지** (ADR-006 §1.3). cardinality 폭발 위험. 로그 필드(`path_normalized`)로만 사용하며, 메트릭 집계 차원으로 사용하지 않는다.
- `active_version`: cardinality 위험 있음. **메트릭 레이블에서 제거**, 정책 버전 추적은 `GET /api/v1/policies/status`로 조회
- `deny_reason`: low-cardinality enum으로 제한 (최대 20개 고정값). 임의 문자열 허용 금지

| 메트릭 이름 | 타입 | 레이블 | 설명 |
|------------|------|--------|------|
| `luagate_http_requests_total` | Counter | `action` | HTTP 전체 요청 수 |
| `luagate_http_requests_denied_total` | Counter | — | deny된 요청 수 |
| `luagate_http_response_time_ms` | Histogram | — | 응답 시간 분포. 버킷: 0.1/0.5/1/5/10/50/100/500/1000ms |
| `luagate_http_upstream_errors_total` | Counter | — | upstream 502 수 |
| `luagate_active_connections` | Gauge | `type` (`http`/`stream`) | 현재 활성 연결 수 |
| `luagate_stream_connections_total` | Counter | — | 전체 스트림 연결 수 |
| `luagate_stream_connections_denied_total` | Counter | — | deny된 연결 수 |
| `luagate_stream_bytes_sent_total` | Counter | — | 총 송신 바이트 |
| `luagate_stream_bytes_received_total` | Counter | — | 총 수신 바이트 |
| `luagate_stream_protocol_detected_total` | Counter | `protocol` | 탐지된 프로토콜별 카운터 |
| `luagate_policy_reload_total` | Counter | — | reload 시도 횟수 |
| `luagate_policy_reload_failures_total` | Counter | — | reload 실패 횟수 |
| `luagate_shared_dict_capacity_bytes` | Gauge | `zone` | shared_dict 용량 (zone별) |
| `luagate_shared_dict_free_bytes` | Gauge | `zone` | shared_dict 여유 공간 (zone별) |

> **저장소 분리**: HTTP 메트릭은 `luagate_metrics` zone(`metrics:*` 키), Stream 메트릭은 `luagate_stream_metrics` zone(`stream:metrics:*` 키)에 저장한다 (architecture.md §3.1 참조).
> **active_version 레이블 제거**: cardinality 폭발 방지. 정책 버전 추적은 `GET /api/v1/policies/status`로 조회한다.

**저장 방식:**
- HTTP 카운터는 `luagate_metrics` shared dict에 원자적으로 증가
- Stream 카운터는 **`luagate_stream_metrics`** shared dict에 원자적으로 증가 (HTTP metrics zone과 분리)
  - 분리 이유: stream 파이프라인과 HTTP 파이프라인은 Nginx에서 독립적인 context를 사용하므로, zone을 분리하여 write 충돌 최소화 및 디버깅 용이성 확보
  - `luagate_stream_metrics` 키 prefix: `stream:metrics:*`
- Histogram 버킷은 `latency:bucket:<ms>` 키로 shared dict에 저장 (ADR-001 §1.1 참조)
- 메트릭 읽기는 `/metrics` 요청 시 `luagate_metrics` + `luagate_stream_metrics` 두 zone에서 집계

> **ADR-006 보완**: 레이블 허용 목록, Histogram 키 스키마, export 모델, shared dict 용량 계획은 [ADR-006](./ADR-006-metrics-cardinality-export-model.md)에서 확정한다.

### §6 관리면 보안

#### 6.1 네트워크 바인딩

- Admin API 서버: `127.0.0.1:9090` (localhost만 바인딩)
- 외부 네트워크 노출 금지 (방화벽/Nginx listen 설정으로 강제)
- 외부 대시보드 접근: 역방향 프록시 또는 SSH 터널링을 통해야 함

#### 6.2 인증

- **Static Bearer Token** 방식:
  - 환경 변수 `LUAGATE_ADMIN_TOKEN`으로 설정
  - 모든 Admin API 요청에 `Authorization: Bearer <token>` 헤더 필수
  - 토큰 불일치 또는 누락: `401 Unauthorized`
- 토큰 최소 길이: 32자 (서버 시작 시 검증)
- HTTPS는 역방향 프록시가 처리하며 Admin API 자체는 HTTP (localhost 한정)

#### 6.3 감사 로그

아래 이벤트 발생 시 `audit.log`에 별도 기록:

| 이벤트 | 기록 필드 |
|--------|----------|
| 정책 변경 (`PUT /api/v1/policies`) | `timestamp`, `event=policy_update`, `actor_ip`, `staged_version`, `active_version` (현재 source_version), `warnings_count` |
| 정책 리로드 성공 (`POST /api/v1/policies/reload`) | `timestamp`, `event=policy_reload_success`, `actor_ip`, `previous_version`, `new_version`, `subsystem` |
| 정책 리로드 실패 | `timestamp`, `event=policy_reload_failure`, `actor_ip`, `stage`, `reason`, `current_version` |
| 정책 리로드 부분 성공 | `timestamp`, `event=policy_reload_partial`, `actor_ip`, `http_result`, `stream_result` |
| 인증 실패 | `timestamp`, `event=auth_failure`, `actor_ip`, `path`, `reason` |
| 서버 기동/종료 | `timestamp`, `event=startup\|shutdown`, `active_version` (기동 시 활성 버전), `version` (luagate 버전) |

> **active_version 분리**: reload 이벤트에서 HTTP와 Stream의 active_version은 `subsystem` 필드로 구분한다. `active_http_version`/`active_stream_version`을 한 레코드에 나란히 기록해야 하는 경우(partial 등)는 `http_result`/`stream_result`로 표현한다. 상세 스키마: [spec/log-schema.md §5](../../spec/log-schema.md#5-감사-로그-auditlog-adr-004-63) 참조.

#### 6.3b 위협 모델

Admin API에 대한 주요 위협과 완화 방안:

| 위협 | 공격 시나리오 | 완화 방안 |
|------|-------------|-----------|
| **SSRF-to-loopback** | 외부 서비스를 경유하여 `127.0.0.1:9090`에 요청 전달 | localhost 바인딩 + 방화벽으로 외부 직접 접근 차단. 역방향 프록시에서 Admin 포트 노출 금지 |
| **Container breakout** | 컨테이너 탈출 후 호스트 네트워크에서 Admin API 접근 | UDS(Unix Domain Socket) 바인딩 또는 mTLS를 통한 mutual authentication 검토 (별도 ADR) |
| **Token 탈취** | 로그/환경변수에서 `LUAGATE_ADMIN_TOKEN` 노출 | 토큰을 로그에 기록하지 않음. 최소 32자 엔트로피 요구. 시크릿 관리 시스템(Vault 등) 연동 권장 |
| **Brute force** | Bearer token 추측 시도 | 연속 인증 실패 시 IP 기반 일시 차단 (임계값: 10회/분) 구현 권장 |
| **IP allowlist 우회** | X-Forwarded-For 헤더 조작 | Admin API 요청에서 XFF 헤더 무시. `$remote_addr`만 신뢰 |

**강화 옵션 (우선순위):**
1. **UDS 바인딩**: `unix:/var/run/luagate/admin.sock` — 파일시스템 권한으로 접근 제어. 컨테이너 환경에서 소켓 파일을 명시적으로 마운트해야 접근 가능
2. **IP Allowlist**: `allow 127.0.0.1; deny all;` — Nginx 레벨에서 적용. 컨테이너 오케스트레이터 IP 범위 추가 가능
3. **mTLS**: 클라이언트 인증서 검증 — 엔터프라이즈 환경에서 토큰 방식 대체 (별도 ADR 필요)

#### 6.4 CORS

- `Access-Control-Allow-Origin`: 환경 변수 `LUAGATE_DASHBOARD_ORIGIN`에 설정된 단일 origin만 허용
- Preflight(`OPTIONS`) 요청에 올바른 CORS 헤더 응답
- `Access-Control-Allow-Methods`: GET, POST, PUT, DELETE, OPTIONS
- `Access-Control-Allow-Headers`: Authorization, Content-Type
- `Vary: Origin` 헤더를 항상 추가하여 캐시 오염 방지
- Preflight(`OPTIONS`)는 인증 헤더가 없으므로 auth 예외 처리 필요

---

## Consequences

### 긍정적 결과

- **보안 분석**: raw + normalized 경로 모두 저장으로 우회 시도 탐지 가능
- **관찰 가능성**: 27개 HTTP 로그 필드 + 18개 Stream 로그 필드 + 메트릭으로 풍부한 분석 환경
- **관리면 보호**: localhost 바인딩 + Bearer token으로 최소 공격 표면
- **감사 추적**: 정책 변경 이력이 audit.log에 기록됨

### 부정적 결과

- **로그 볼륨**: 요청마다 27개 HTTP 필드 / 18개 Stream 필드 → 고트래픽 환경에서 디스크 I/O 주의 필요.
  로그 로테이션 정책과 외부 로그 집계(ELK 등) 설정 권장
- **Static Token 한계**: 토큰 교체 시 재시작 필요.
  토큰 교체 무중단화는 별도 ADR에서 결정
- **메트릭 경계**: 인스턴스별 메트릭이므로 전체 집계는 Prometheus 등 외부 도구 필요

### 향후 고려

- 로그 샘플링(고트래픽 시 비율 조절) 기능 추가 검토
- Admin API mTLS 지원 검토 (엔터프라이즈 요구 시)

---

## 관련 문서

- [ADR-001](./ADR-001-execution-shared-state-model.md) — shared dict 기반 메트릭 저장
- [spec/log-schema.md](../../spec/log-schema.md) — 로그 스키마 상세 스펙
- [spec/admin-api.md](../../spec/admin-api.md) — Admin API 전체 엔드포인트 스펙
