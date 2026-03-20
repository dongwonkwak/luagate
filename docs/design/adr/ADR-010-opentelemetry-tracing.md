# ADR-010: OpenTelemetry 분산 트레이싱 도입

> [← ADR 인덱스로 돌아가기](./README.md)

| 항목 | 내용 |
|------|------|
| **Status** | Accepted |
| **Date** | 2026-03-20 |
| **Deciders** | LuaGate Architects |
| **Issue** | [DON-179](https://linear.app/dongwon/issue/DON-179) |
| **Depends on** | [ADR-001](./ADR-001-execution-shared-state-model.md), [ADR-004](./ADR-004-log-metrics-admin-security.md) |
| **Resolves** | 분산 환경에서 요청 추적 불가 문제; 기존 `request_id` 필드의 외부 트레이싱 시스템 연동 부재 |

---

## Status

**Accepted** — OpenTelemetry 기반 분산 트레이싱을 도입하여 HTTP 요청의 end-to-end 추적을 가능하게 한다.

---

## Context

현재 LuaGate는 `request_id` (opaque string — 클라이언트 `X-Request-ID` 또는 Nginx `$request_id`) 필드를 access.log에 기록하고 `X-Request-ID` 응답/업스트림 헤더로 전달한다 (log-schema.md §3.1). 그러나 이 값은 단일 인스턴스 내 요청 추적에만 유용하며, 외부 트레이싱 시스템(Jaeger, Tempo, Zipkin 등)과의 연동 메커니즘이 없다.

### 현재 상태

1. `request_id`: Nginx `map` 지시자로 결정 — 클라이언트 `X-Request-ID` 헤더가 있으면 그대로 채택, 없으면 Nginx `$request_id` fallback (`conf/nginx.conf:54-57`). 형식이 보장되지 않는다 (클라이언트가 임의 값을 보낼 수 있음)
2. 외부 트레이싱 시스템 연동: 없음 (OTLP exporter 미존재)
3. upstream 전파: `X-Request-ID` 헤더만 전달, W3C Trace Context 미지원
4. 내부 단계별 소요 시간 측정: 없음

### 요구 사항

- 프로덕션 환경에서 성능 영향 최소화 (샘플링 기반)
- OpenResty 이벤트 루프 블로킹 방지
- 기존 `request_id` 필드와의 호환성 유지
- W3C Trace Context 표준 준수

### 검토된 대안

| 대안 | 장점 | 단점 |
|------|------|------|
| `opentelemetry-lua` 라이브러리 | 커뮤니티 유지보수, 표준 준수 | cosocket 제약 (log_by_lua 불가), 코루틴 모델 충돌, 의존성 무거움 |
| Nginx OpenTelemetry 모듈 (C) | 성능 최적, Nginx 네이티브 | OpenResty fork 호환성 불확실, Lua 레벨 span 생성 불가 |
| **커스텀 경량 OTLP HTTP 모듈** | OpenResty 제약 정확히 대응, 최소 의존성, 필요 기능만 구현 | 직접 유지보수 필요 |
| Jaeger thrift export | 검증된 프로토콜 | OTLP이 사실상 표준, thrift 의존성 추가 |

---

## Decision

### 1. 커스텀 경량 OTLP HTTP 모듈 채택

`opentelemetry-lua` 라이브러리 대신 커스텀 경량 모듈을 `lua/luagate/tracing/` 아래에 구현한다.

**이유**: OpenResty의 cosocket 제약 때문이다. `log_by_lua` phase에서는 cosocket 사용이 불가하므로, 트레이싱 데이터 export는 `ngx.timer.at` 기반 비동기 배치로 처리해야 한다. `opentelemetry-lua`는 이 제약을 처리하지 못하며, 코루틴 모델과 충돌한다.

### 2. 트레이싱 수준: HTTP 요청 루트 span + 내부 단계 child spans

```
[root] HTTP Request (rewrite → log)
├── [child] normalize       (rewrite_by_lua, decoder FFI)
├── [child] policy_eval     (access_by_lua)
├── [child] security_scan   (access_by_lua, scanner FFI)
└── [child] proxy           (access_by_lua 종료 ~ upstream 응답 완료)
```

- **루트 span**: `rewrite_by_lua`에서 생성하되 시작 시각을 `ngx.req.start_time()`으로 backdate한다 (요청 수신 시각). `log_by_lua`에서 종료. 이를 통해 루트 span duration이 `latency_ms` (`$request_time` = 요청 수신 ~ 응답 전송 완료)와 일치한다.
- **child span**: 주요 내부 단계별 생성 (normalize, policy_eval, security_scan, proxy)
- **normalize child span**: `rewrite_by_lua`에서 생성. decoder FFI (path/query 정규화) 호출을 포함한다. http-pipeline.md §2.2의 rewrite 정규화 단계에 해당
- **security_scan child span**: `access_by_lua`에서 생성. scanner FFI 호출만 포함 (decoder는 rewrite에서 이미 실행됨)
- **pre-Lua rejection**: Nginx가 malformed request를 Lua phase 진입 전에 거부하는 경우 (400/413/414), 트레이싱 span은 생성되지 않는다. `trace_id`/`span_id` 로그 필드는 기본값 null로 기록된다. 이는 의도된 동작이며, inbound `traceparent`가 있어도 Lua가 실행되지 않으므로 파싱 자체가 불가하다
- **proxy child span**: `access_by_lua` 종료 시점에 `ngx.now()`로 시작 시각(`proxy_start_ts`)을 기록한다. `log_by_lua`에서 `ngx.now()`로 종료 시각을 기록하고, duration = 종료 시각 - `proxy_start_ts`로 계산한다. 이를 통해 proxy span은 `access_by_lua` 종료부터 Nginx가 upstream 응답 수신 + 클라이언트 전송 완료까지의 전체 구간을 반영하며, retry/failover가 발생해도 단일 span으로 총 소요 시간을 정확히 기록한다. `$upstream_response_time`은 span attribute `luagate.upstream_response_time`으로 별도 보존한다 (attempt별 디버깅 용도).
- **upstream retry/failover**: Nginx가 retry/failover를 수행하면 `$upstream_response_time`이 쉼표 구분 다중 값이 될 수 있다 (예: `"0.5, 1.2"`). 이 경우 **단일 proxy span으로 합산**한다 — 전체 upstream 소요 시간(마지막 값의 종료 시점)을 proxy span duration으로 기록하고, attempt 횟수를 span attribute `luagate.upstream_attempts`로 남긴다. attempt별 개별 span 생성은 Phase 2 이후 범위로 둔다. outbound `traceparent`의 `span_id`는 최초 attempt 시점에 생성한 proxy span의 ID를 사용하며, retry 시에도 동일한 `span_id`를 전달한다 (upstream 관점에서 같은 parent).
- **upstream 실패 (connect/DNS 등)**: `$upstream_response_time`이 빈 문자열 또는 nil인 경우 (connect 실패, DNS 해석 실패 등), proxy span을 `log_by_lua` 시점에서 즉시 종료한다. 이때 span에 `otel.status_code=ERROR`, `error.type=upstream_connect_failure`, `http.response.status_code=502` 등 에러 attribute를 설정한다. duration은 proxy span 시작 ~ log_by_lua 시점으로 기록한다 (실제 대기 시간 반영).
- **outbound traceparent 주입**: `access_by_lua` 단계에서 proxy child span을 생성한 뒤, 해당 span의 `span_id`를 parent로 하여 `ngx.req.set_header("traceparent", "00-<trace_id>-<proxy_span_id>-<flags>")`를 설정한다. 이렇게 하면 업스트림 서비스의 span이 proxy child의 자식으로 올바르게 연결된다.

### 3. Export 방식: OTLP/HTTP (JSON)

| 항목 | 선택 |
|------|------|
| **프로토콜** | OTLP/HTTP (JSON encoding) |
| **엔드포인트** | 설정 가능 (기본: `http://localhost:4318/v1/traces`) |
| **전송** | `ngx.timer.at` 기반 비동기 배치 |
| **dev 모드** | stdout (JSON) export 지원 |
| **gRPC** | 미채택 (OpenResty에 안정적 gRPC 클라이언트 없음) |

### 4. Export 메커니즘: worker 레벨 span 버퍼 + 타이머 flush

```
[init_worker_by_lua] → worker당 1회: 주기적 flush 타이머 등록
                              │
[log_by_lua]         → span 완료 → worker-local 버퍼에 추가
                              │
[ngx.timer.every 주기적 (5초)] ↓
                              버퍼 drain → cosocket으로 OTLP/HTTP POST
```

- **타이머 등록**: `init_worker_by_lua`에서 `ngx.timer.every(flush_interval, flush_fn)`으로 worker당 1회 등록. 요청 경로에서 타이머를 생성하지 않는다 (타이머 중복 생성 방지).
- 각 worker는 독립적인 span 버퍼를 유지 (shared dict 불필요)
- `ngx.timer.every` 콜백에서 cosocket 사용 가능 → OTLP endpoint로 배치 전송
- 버퍼 크기 제한: worker당 최대 4096 spans (초과 시 oldest drop). 산출 근거: SLO 10,000 req/s ÷ 4 workers = 2,500 req/s/worker × 1% 샘플링 = 25 req/s × 5 spans/req × 5초 flush = 625 spans. 버스트/배압 여유 6.5배 포함 4096으로 설정
- flush 주기: 5초 (설정 가능)
- **버퍼 동시 접근 제어**: `log_by_lua`의 span append와 timer 콜백의 flush는 같은 worker에서 실행되지만, timer 콜백이 cosocket I/O 중 yield하면 그 사이에 `log_by_lua`가 실행될 수 있다. 이를 방지하기 위해 flush 시작 시 현재 버퍼를 새 빈 테이블로 **atomic swap**한다: `local batch = buffer; buffer = {}`. swap 후 `log_by_lua`는 새 빈 버퍼에 append하고, timer는 swap된 batch를 전송한다. Lua table 할당은 원자적이므로 lock이 필요 없다

### 5. 샘플링 전략: Head-based 확률적 샘플링

| 환경 | 기본 샘플 비율 |
|------|---------------|
| Production | 1% (0.01) |
| Staging | 10% (0.1) |
| Development | 100% (1.0) |

- **Head-based**: `rewrite_by_lua`에서 샘플링 결정, 이후 모든 child span에 전파
- **설정**: `conf/luagate.yaml`의 `tracing.sample_rate` 필드

**Inbound sampled 플래그별 동작**:

| inbound traceparent | sampled 플래그 | LuaGate 동작 | trace_id/span_id 로그 | span export |
|---------------------|---------------|-------------|---------------------|-------------|
| 있음 | `sampled=1` | parent-based: 강제 샘플링 (로컬 rate 무시) | 기록 | O |
| 있음 | `sampled=0` | parent-based: 샘플링 안 함 (상위 결정 존중) | **항상 기록** (상관관계 유지) | X |
| 없음 | — | 새 trace_id 생성 + 로컬 rate 적용 | 샘플링 시 기록, 미샘플 시 null | 샘플링 시만 |

> **inbound 없음 + locally unsampled**: 새 trace_id를 생성하고 `sampled=0`으로 outbound `traceparent`를 **전파한다**. W3C Trace Context 표준에 따라, originator는 샘플링 여부와 무관하게 trace context를 downstream에 전파해야 한다. downstream hop이 독자적으로 재샘플링하여 trace를 이어받을 수 있기 때문이다. 단, LuaGate 자체는 span을 export하지 않으며 `trace_id`/`span_id` 로그 필드도 null로 기록한다 (로컬 비용 최소화).
>
> **핵심 결정 — parent-based 샘플링**: inbound `traceparent`가 있으면 sampled 플래그를 그대로 존중한다 (parent-based). LuaGate가 독자적으로 재샘플링하지 않는다. 이를 통해 partial trace (상위 hop은 export 안 했는데 LuaGate만 export) 문제를 방지하고, 분산 환경에서 일관된 end-to-end 트레이스를 보장한다.
> **로그 기록**: inbound trace가 있으면 sampled 플래그와 무관하게 `trace_id`/`span_id`를 항상 access.log에 기록한다. 외부 트레이싱 시스템에서 LuaGate 로그와의 상관관계가 끊기지 않도록 한다.
> **outbound 전파**: inbound sampled 플래그를 그대로 outbound `traceparent`에 전달한다.

```yaml
# conf/luagate.yaml
tracing:
  enabled: true
  sample_rate: 0.01          # 1% (production default)
  exporter: otlp_http        # otlp_http | stdout
  endpoint: "http://localhost:4318/v1/traces"
  batch_size: 1024           # flush 시 최대 span 수 (정상 부하 625 + 여유)
  flush_interval_ms: 5000    # flush 주기 (ms)
```

**설정 로드 계약**:

- **로드 시점**: `init_by_lua`에서 1회 로드. `conf/luagate.yaml`이 없거나 `tracing.enabled`가 `false`이면 트레이싱 모듈 전체를 no-op으로 초기화한다.
- **HUP/Hot Reload와의 관계**: 트레이싱 설정은 정책 Hot Reload (ADR-003) 대상이 **아니다**. 샘플링 비율, exporter endpoint 등 트레이싱 설정 변경은 Nginx reload (`nginx -s reload` 또는 SIGHUP)로만 반영되며, 이때 worker가 교체되면서 `init_by_lua` → `init_worker_by_lua`가 다시 실행된다.
- **Validation**: `init_by_lua`에서 YAML 파싱 + 스키마 검증 (필수 필드, 타입, 범위). 검증 실패 시 트레이싱을 비활성화하고 `ngx.log(ngx.ERR, ...)` 로그만 남긴다 (서버 기동을 차단하지 않음 — fail-open 원칙).
- **기존 설정과의 관계**: `conf/nginx.conf`는 Nginx 지시자, `conf/policies.yaml`은 정책 규칙을 담는다. `conf/luagate.yaml`은 트레이싱/관측성 등 **애플리케이션 레벨 설정**을 담는 새 파일이다. 향후 다른 애플리케이션 설정도 이 파일에 추가할 수 있다.

### 6. `request_id`와 `trace_id` 관계: 별도 유지 + 매핑

| 필드 | 형식 | 생성 시점 | 용도 |
|------|------|----------|------|
| `request_id` | string (클라이언트 `X-Request-ID` 또는 Nginx `$request_id`) | Nginx `map` 지시자 (conf/nginx.conf) | 내부 로그 상관, `X-Request-ID` 업스트림/응답 헤더 |
| `trace_id` | W3C 32자 hex | `rewrite_by_lua` (inbound 없을 때 생성) | 분산 트레이싱 |

- `request_id`를 `trace_id`로 **승격하지 않는다**. `request_id`는 클라이언트가 전달한 임의 값일 수 있어 형식이 보장되지 않으며 (opaque string), `trace_id`는 반드시 W3C 128-bit hex (32자) 형식이어야 한다. 생성 경로와 의미가 다르므로 별도 유지한다.

> **request_id 타입 재정의**: 기존 log-schema.md는 `request_id`를 "UUID v4"로 기술했으나, 실제 런타임 계약은 클라이언트 `X-Request-ID` 헤더를 그대로 채택한다 (`conf/nginx.conf:54-57` map). 따라서 `request_id`의 타입을 **opaque string**으로 재정의한다. 클라이언트가 UUID v4를 보내면 UUID v4이고, 임의 문자열을 보내면 그대로 기록된다. 이 ADR과 함께 log-schema.md의 `request_id` 타입 설명을 동기화한다.
- span attribute `luagate.request_id`로 매핑하여 로그-트레이스 상관을 지원한다.
- access.log에 `trace_id`, `span_id` 필드를 NULLABLE로 추가한다 (트레이싱 비활성화 또는 미샘플 시 null).

### Span Attribute Redaction (ADR-007 연동)

트레이스 백엔드로 전송되는 span attribute에도 ADR-007의 PII redaction 규칙을 동일하게 적용한다. access.log가 안전해도 trace 경로로 raw 데이터가 우회 유출되는 것을 방지한다.

| span attribute | redaction 규칙 |
|---------------|---------------|
| `http.url` | query_string에 ADR-007 §2 민감 파라미터 마스킹 적용 (`token=***` 등) |
| `http.request.header.authorization` | **수집 금지** — span attribute에 포함하지 않음 |
| `http.request.header.cookie` | **수집 금지** — span attribute에 포함하지 않음 |
| `http.request.header.x-api-key` | **수집 금지** — span attribute에 포함하지 않음 |
| `luagate.deny_reason` | 그대로 포함 (PII 아님, 정책 판정 사유) |

> **원칙**: span attribute 화이트리스트 방식 — §2에 정의된 attribute만 수집하며, 임의의 HTTP 헤더를 span에 포함하지 않는다. 이를 통해 redaction 누락으로 인한 데이터 유출을 구조적으로 방지한다.

### 7. W3C Trace Context 전파

```
[inbound]  traceparent: 00-<trace_id>-<parent_span_id>-<flags>
                              │
[LuaGate]  rewrite_by_lua: parse traceparent → 루트 span 생성
           access_by_lua:   child spans 생성 → proxy child span의 span_id로
                            ngx.req.set_header("traceparent", "00-<trace_id>-<proxy_span_id>-<flags>")
           proxy_pass:      Nginx가 설정된 traceparent 헤더를 upstream에 전달
                              │
[upstream] traceparent: 00-<trace_id>-<proxy_span_id>-<flags>
           → upstream span은 proxy child의 자식으로 연결됨
```

- inbound `traceparent` 없으면 새 trace_id 생성
- outbound `traceparent`는 **proxy child span의 `span_id`**를 parent로 설정. 루트 `span_id`가 아닌 proxy span을 사용하여, 업스트림 서비스의 span이 트리 상에서 proxy의 자식으로 올바르게 위치한다
- `access_by_lua`에서 `ngx.req.set_header()`로 주입 (proxy_pass 전에 실행되므로 Nginx가 자동 전달)
- **`tracestate` 헤더 처리**:
  - inbound `traceparent`가 **유효하게 있는** 경우: inbound `tracestate`를 수정 없이 pass-through (기존 trace 연속)
  - inbound `traceparent`가 **없는** 경우 (새 trace 생성): outbound `tracestate` 헤더를 **설정하지 않는다** (`ngx.req.clear_header("tracestate")`로 제거). stale state 전파 방지
- **malformed `traceparent` 처리** (W3C Trace Context Level 1 §2.2.5 준수):
  - 파싱 실패 (잘못된 형식, 미지원 version, 유효하지 않은 trace-id/span-id): inbound 헤더를 **무시**하고 새 trace를 시작한다. 에러 로그를 남기지 않는다 (외부 클라이언트가 임의 값을 보낼 수 있으므로 노이즈 방지)
  - all-zero trace-id (`00000000000000000000000000000000`) 또는 all-zero span-id (`0000000000000000`): W3C 스펙상 무효 — 새 trace를 시작한다
  - duplicate `traceparent`: 첫 번째 값만 사용 (HTTP 표준에 따라)
  - malformed/invalid `tracestate`: 해당 헤더를 **드롭**하고 outbound에 전달하지 않는다
- `X-Request-ID` 헤더는 기존대로 유지 (별도)

---

## File Structure

```
lua/luagate/tracing/
├── init.lua          # 모듈 초기화, 설정 로드, timer 등록
├── context.lua       # trace context 생성/전파/파싱
├── span.lua          # span 생성/종료/attribute 설정
├── sampler.lua       # 샘플링 결정 로직
├── exporter.lua      # OTLP/HTTP batch exporter
└── buffer.lua        # worker-local span 버퍼
```

---

## Log Schema Changes

access.log에 2개 NULLABLE 필드 추가:

| 필드 | 타입 | JSON Nullability | 설명 |
|------|------|-----------------|------|
| `trace_id` | string (32-hex) | NULLABLE | W3C TraceContext trace ID. 트레이싱 비활성화 시 null. inbound `traceparent` 존재 시 sampled 플래그와 무관하게 항상 기록. inbound 없고 locally unsampled 시 null |
| `span_id` | string (16-hex) | NULLABLE | 루트 span ID. 트레이싱 비활성화 시 null. inbound `traceparent` 존재 시 sampled 플래그와 무관하게 항상 기록. inbound 없고 locally unsampled 시 null |

> 기존 `request_id` 필드는 변경 없음. `trace_id`와 `request_id`의 상관은 span attribute를 통해 제공.

---

## Consequences

### 긍정적

- 프로덕션 환경에서 end-to-end 요청 추적 가능
- Jaeger, Grafana Tempo 등 표준 트레이싱 백엔드와 즉시 연동
- 샘플링 기반으로 성능 영향 최소화 (1% 샘플 시 무시할 수준)
- 기존 `request_id` 호환성 유지

### 부정적

- 커스텀 모듈 유지보수 부담 (opentelemetry-lua 대비)
- worker 메모리 사용량 소폭 증가 (span 버퍼)
- 설정 복잡도 증가 (`tracing` 섹션 추가)

### 리스크

| 리스크 | 완화 |
|--------|------|
| span 버퍼 메모리 압박 | worker당 4096 span 하드 캡 + oldest drop |
| OTLP endpoint 장애 시 버퍼 누적 | flush 실패 시 버퍼 강제 drain (drop) + 메트릭 카운터 |
| 높은 샘플 비율로 인한 성능 저하 + 버퍼 초과 | production 기본 1%. dev(100%)/staging(10%) 환경에서는 트래픽이 낮으므로 (개발 환경 SLO 없음) 버퍼 초과는 허용 가능. 고부하 staging에서는 `sample_rate`를 낮추거나 `batch_size`/`max_queue_size`를 조정한다 |
| `ngx.timer.at` 타이머 고갈 | pending timer 수 모니터링, max 제한 |
| worker 종료/교체 시 span 유실 | 아래 Worker Shutdown 정책 참조 |

**Worker Shutdown 정책**: Nginx worker가 종료(graceful shutdown, hot reload에 의한 교체)될 때 `ngx.timer.every` 콜백은 `premature=true`로 호출된다. 이 시점에서 best-effort final flush를 수행한다:

1. `premature=true` 감지 시 버퍼에 남은 span을 즉시 OTLP/HTTP POST 시도
2. flush 실패 시 span을 드롭하고 `luagate_tracing_spans_dropped_total` 메트릭을 증가
3. 손실 범위: 마지막 flush 이후 ~ shutdown 사이의 최대 `flush_interval_ms` (5초) 분량. 1% 샘플링 기준 무시할 수준

**premature 콜백에서 cosocket 사용 가능성**: OpenResty `ngx.timer.at`/`ngx.timer.every`의 premature 콜백에서도 cosocket(TCP/UDP)은 사용 가능하다. OpenResty 문서에 따르면 timer 콜백은 "가벼운 스레드(light thread)" 컨텍스트에서 실행되며 cosocket API가 완전히 지원된다. `premature=true`는 worker 종료 신호일 뿐 API 제약을 추가하지 않는다. 단, worker shutdown timeout(`worker_shutdown_timeout` 지시자) 내에 완료해야 하므로 `export_timeout_ms`를 이 값보다 짧게 설정해야 한다.

**검증 계획** (DON-180 구현 시 수행):
1. Test::Nginx 통합 테스트: `init_worker_by_lua`에서 premature timer 등록 → `nginx -s quit` 후 OTLP mock endpoint에 span 도착 확인
2. 실패 경로 테스트: OTLP endpoint 중단 상태에서 shutdown → drop 메트릭 증가 확인 + worker 정상 종료 확인 (hang 없음)
3. `worker_shutdown_timeout` 초과 테스트: export_timeout_ms를 의도적으로 크게 설정 → worker가 timeout 내 종료되는지 확인

이는 의도된 trade-off이다. 트레이싱은 관측성 기능이므로 완전한 무손실을 보장하지 않는다 (fail-open 원칙).

---

## Implementation Plan

1. **DON-180**: `lua/luagate/tracing/` 모듈 구현 (context, span, sampler, exporter, buffer)
2. log-schema.md에 `trace_id`, `span_id` 필드 추가
3. `init_worker_by_lua`에서 exporter 초기화 + `ngx.timer.every` flush 타이머 등록
4. `rewrite_by_lua`에서 trace context 초기화 + 루트 span 시작
5. `access_by_lua`에서 child span 생성 (policy_eval, security_scan, proxy) + proxy span_id로 outbound `traceparent` 헤더 주입
6. `log_by_lua`에서 루트 span 종료 (latency_ms = $request_time과 일치) + 완료된 span을 worker-local 버퍼에 추가
7. docker-compose.yml에 Jaeger/OTLP collector 개발용 서비스 추가
