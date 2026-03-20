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

현재 LuaGate는 `request_id` (UUID v4) 필드를 access.log에 기록하고 `X-Request-ID` 응답 헤더로 전달한다 (log-schema.md §3.1). 그러나 이 값은 단일 인스턴스 내 요청 추적에만 유용하며, 외부 트레이싱 시스템(Jaeger, Tempo, Zipkin 등)과의 연동 메커니즘이 없다.

### 현재 상태

1. `request_id`: UUID v4, `rewrite_by_lua`에서 생성, access.log에 기록
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
├── [child] policy_eval     (access_by_lua)
├── [child] security_scan   (access_by_lua, FFI)
├── [child] proxy           (content_by_lua → upstream)
└── [child] log_finalize    (log_by_lua)
```

- **루트 span**: `rewrite_by_lua`에서 시작, `log_by_lua`에서 종료
- **child span**: 주요 내부 단계별 생성 (policy_eval, security_scan, proxy, log_finalize)
- **FFI 호출 span**: security_scan child 내에 scanner/decoder FFI 호출 span 포함

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
[access/log_by_lua] → span 완료 → worker-local 버퍼에 추가
                                         │
[ngx.timer.at 주기적 (5초)]              ↓
                              버퍼 drain → cosocket으로 OTLP/HTTP POST
```

- 각 worker는 독립적인 span 버퍼를 유지 (shared dict 불필요)
- `ngx.timer.at` 콜백에서 cosocket 사용 가능 → OTLP endpoint로 배치 전송
- 버퍼 크기 제한: worker당 최대 1000 spans (초과 시 oldest drop)
- flush 주기: 5초 (설정 가능)

### 5. 샘플링 전략: Head-based 확률적 샘플링

| 환경 | 기본 샘플 비율 |
|------|---------------|
| Production | 1% (0.01) |
| Staging | 10% (0.1) |
| Development | 100% (1.0) |

- **Head-based**: `rewrite_by_lua`에서 샘플링 결정, 이후 모든 child span에 전파
- **inbound `traceparent` 존중**: 외부에서 sampled=1로 들어오면 무조건 트레이싱
- **설정**: `conf/luagate.yaml`의 `tracing.sample_rate` 필드

```yaml
# conf/luagate.yaml
tracing:
  enabled: true
  sample_rate: 0.01          # 1% (production default)
  exporter: otlp_http        # otlp_http | stdout
  endpoint: "http://localhost:4318/v1/traces"
  batch_size: 100            # flush 시 최대 span 수
  flush_interval_ms: 5000    # flush 주기 (ms)
```

### 6. `request_id`와 `trace_id` 관계: 별도 유지 + 매핑

| 필드 | 형식 | 생성 시점 | 용도 |
|------|------|----------|------|
| `request_id` | UUID v4 (36자) | `rewrite_by_lua` | 내부 로그 상관, `X-Request-ID` 헤더 |
| `trace_id` | W3C 32자 hex | `rewrite_by_lua` (inbound 없을 때 생성) | 분산 트레이싱 |

- `request_id`를 `trace_id`로 **승격하지 않는다**. 형식이 다르고 (UUID v4 vs 32-hex), 기존 로그 소비자와의 호환성을 유지해야 한다.
- span attribute `luagate.request_id`로 매핑하여 로그-트레이스 상관을 지원한다.
- access.log에 `trace_id`, `span_id` 필드를 NULLABLE로 추가한다 (트레이싱 비활성화 또는 미샘플 시 null).

### 7. W3C Trace Context 전파

```
[inbound]  traceparent: 00-<trace_id>-<parent_span_id>-<flags>
                              │
[LuaGate]  rewrite_by_lua: parse traceparent → 루트 span 생성
           access_by_lua:   child spans
           proxy:           outbound traceparent 헤더 생성
                              │
[upstream] traceparent: 00-<trace_id>-<luagate_span_id>-<flags>
```

- inbound `traceparent` 없으면 새 trace_id 생성
- `tracestate` 헤더는 pass-through (수정 없이 전달)
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
| `trace_id` | string (32-hex) | NULLABLE | W3C TraceContext trace ID. 트레이싱 비활성화 또는 미샘플 시 null |
| `span_id` | string (16-hex) | NULLABLE | 루트 span ID. 트레이싱 비활성화 또는 미샘플 시 null |

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
| span 버퍼 메모리 압박 | worker당 1000 span 하드 캡 + oldest drop |
| OTLP endpoint 장애 시 버퍼 누적 | flush 실패 시 버퍼 강제 drain (drop) + 메트릭 카운터 |
| 높은 샘플 비율로 인한 성능 저하 | production 기본 1%, 설정 검증으로 100% 방지 |
| `ngx.timer.at` 타이머 고갈 | pending timer 수 모니터링, max 제한 |

---

## Implementation Plan

1. **DON-180**: `lua/luagate/tracing/` 모듈 구현 (context, span, sampler, exporter, buffer)
2. log-schema.md에 `trace_id`, `span_id` 필드 추가
3. `rewrite_by_lua`에서 trace context 초기화
4. `access_by_lua`에서 child span 생성
5. `log_by_lua`에서 루트 span 종료 + 버퍼 추가
6. docker-compose.yml에 Jaeger/OTLP collector 개발용 서비스 추가
