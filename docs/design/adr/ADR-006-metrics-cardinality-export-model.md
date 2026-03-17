# ADR-006: 메트릭 Cardinality 제어 + Export 모델

| 항목 | 내용 |
|------|------|
| **Status** | Accepted |
| **Date** | 2026-03-15 |
| **Deciders** | LuaGate Architects |
| **Issue** | [DON-123](https://linear.app/dongwon/issue/DON-123) |
| **Depends on** | [ADR-004](./ADR-004-log-metrics-admin-security.md), [ADR-001](./ADR-001-execution-shared-state-model.md) |

---

## Status

**Accepted** — ADR-004 §4.3을 보완/구체화하는 ADR. ADR-004와 상충하지 않음.

---

## Context

ADR-004 §4.3은 메트릭 이름 목록, Cardinality 원칙(레이블 제한, `active_version` 제거, `deny_reason` 최대 20개), shared dict 저장 방식을 결정했다. 그러나 다음 사항이 미결정 상태로 남아 있어 구현 단계에서 판단이 필요하다:

1. **레이블 허용 목록이 불완전**: `rule_name`, `threat_type` 등 신규 후보 레이블에 대한 명시적 허용/금지 판정이 없다.
2. **Route 정규화 규칙이 미명시**: `path_normalized`를 메트릭 레이블로 사용하지 않기로 했으나(ADR-004), 메트릭 집계 시 경로 정규화 처리 지점이 명확하지 않다.
3. **Histogram 키 스키마가 불완전**: ADR-001 §1.1에서 `latency:bucket:<ms>` 형식을 암시했으나, 버킷 목록, sum/count 키 이름, 구체적 스키마가 확정되지 않았다.
4. **Export 모델 미결정**: `/metrics` Prometheus scrape(Pull)와 statsd Push 중 어느 방식을 쓸지 명시되지 않았다.
5. **Shared dict 용량 계획 미수립**: zone별 추천 크기와 eviction 시 fail mode가 결정되지 않았다.

---

## Decision

### §1 레이블 허용 목록 (Label Allowlist)

#### 1.1 허용 레이블

아래 레이블만 메트릭에 사용할 수 있다. 이 목록에 없는 레이블은 명시적으로 금지된다.

| 레이블 | 허용 값 | 사용 메트릭 | 근거 |
|--------|---------|-------------|------|
| `action` | `allow`, `deny` | `luagate_http_requests_total` | ADR-004 §4.3 결정. 고정 2개 값, cardinality = 2 |
| `type` | `http`, `stream` | `luagate_active_connections` | ADR-004 §4.3 결정. 고정 2개 값, cardinality = 2 |
| `zone` | `luagate_metrics`, `luagate_stream_metrics`, `luagate_connections`, `luagate_policy`, `luagate_state` | `luagate_shared_dict_capacity_bytes`, `luagate_shared_dict_free_bytes` | ADR-004 §4.3 결정. 고정 zone 이름, cardinality = 5 이하 |
| `protocol` | `tls`, `http`, `raw` | `luagate_stream_protocol_detected_total` | ADR-004 §4.3 결정. 고정 3개 값, cardinality = 3 |
| `threat_type` | `sqli`, `xss`, `path_traversal`, `cmd_injection`, `lfi`, `rfi`, `xxe`, `ssrf`, `log4shell`, `scanner`, `deserialization`, `other` | `luagate_http_scanner_threats_total` | 고정 enum 최대 12개. 보안 분석 용도. 스캐너 deny 시에만 기록 |

#### 1.2 `threat_type` 레이블 및 신규 메트릭 결정

`luagate_http_requests_denied_total`은 **레이블 없는 전체 deny 카운터**로 유지한다(정책 규칙 + 스캐너 deny 모두 포함). 위협 유형별 breakdown을 위해 **신규 메트릭 `luagate_http_scanner_threats_total{threat_type}`을 추가**한다. 이 메트릭은 보안 스캐너에 의한 deny 시에만 증가한다.

**이중 집계 방지 설계:**
- `luagate_http_requests_denied_total`: 모든 deny(정책 + 스캐너)를 레이블 없이 카운트. `sum(luagate_http_requests_denied_total)` 쿼리 시 이중 계산 없음.
- `luagate_http_scanner_threats_total{threat_type}`: 스캐너 deny 시에만, `threat_type` 레이블과 함께 별도로 카운트. 두 메트릭은 독립 집계이므로 중복 합산 위험 없음.

**근거:**
- 값이 고정 enum(최대 12개)으로 cardinality가 통제된다.
- 위협 유형별 deny 분포를 Prometheus에서 직접 집계할 수 있어 보안 대시보드 구성에 유용하다.
- ADR-004 §4.1에서 로그 필드 `threat_type`이 이미 정의되어 있으므로 메트릭 레이블과 의미가 일치한다.

**`threat_type` 허용 값 (12개 고정):** `sqli`, `xss`, `path_traversal`, `cmd_injection`, `lfi`, `rfi`, `xxe`, `ssrf`, `log4shell`, `scanner`, `deserialization`, `other`

- `other`는 위 11개에 해당하지 않는 모든 위협 유형의 폴백 값이다.
- 새 위협 유형 추가는 이 ADR을 개정하여 목록에 명시적으로 등록해야 한다. 구현 코드가 목록에 없는 값을 받으면 `other`로 정규화한다.

> **구현 제약 (보안)**: `luagate_http_scanner_threats_total` incr 시, shared dict 키 조합 **직전**에 `threat_type` 값을 위 허용 목록으로 검증하고 미등록 값은 `other`로 정규화한 뒤 키를 조합해야 한다. `/metrics` 응답 생성 단계로 정규화를 늦춰서는 안 된다. 정규화 누락 시 임의 문자열이 shared dict 키로 삽입되어 cardinality 폭발 → 메모리 고갈 DoS로 이어질 수 있다.

**결과: 업데이트된 메트릭 레이블 표 (총 15개):**

| 메트릭 이름 | 타입 | 레이블 (변경 후) |
|------------|------|----------------|
| `luagate_http_requests_total` | Counter | `action` |
| `luagate_http_requests_denied_total` | Counter | — |
| `luagate_http_scanner_threats_total` | Counter | `threat_type` |
| `luagate_http_response_time_ms` | Histogram | — |
| `luagate_http_upstream_errors_total` | Counter | — |
| `luagate_active_connections` | Gauge | `type` |
| `luagate_stream_connections_total` | Counter | — |
| `luagate_stream_connections_denied_total` | Counter | — |
| `luagate_stream_bytes_sent_total` | Counter | — |
| `luagate_stream_bytes_received_total` | Counter | — |
| `luagate_stream_protocol_detected_total` | Counter | `protocol` |
| `luagate_policy_reload_total` | Counter | — |
| `luagate_policy_reload_failures_total` | Counter | — |
| `luagate_shared_dict_capacity_bytes` | Gauge | `zone` |
| `luagate_shared_dict_free_bytes` | Gauge | `zone` |

> **메트릭 이름 불변**: ADR-004 §4.3에서 확정된 14개 이름은 변경하지 않는다. `luagate_http_scanner_threats_total`은 이 ADR에서 추가된 15번째 메트릭이다.

#### 1.3 금지 레이블

다음 레이블은 cardinality 폭발 위험 또는 ADR-004 결정에 의해 사용을 금지한다.

| 레이블 | 금지 이유 |
|--------|---------|
| `path_normalized` | ADR-004 §4.3 결정. 경로 값이 다양해 cardinality 폭발 위험. 로그 필드로만 사용. |
| `active_version` | ADR-004 §4.3 결정. 버전 해시 = unbounded cardinality. 정책 버전 조회는 `GET /api/v1/policies/status` 사용. |
| `request_id` | UUID 단위 → cardinality = 전체 요청 수. 메트릭 집계 목적에 부적합. |
| `src_ip` | IP 주소 단위 → unbounded cardinality. 보안 분석은 로그 활용. |
| `rule_name` | 사용자 정의 문자열 값 → unbounded cardinality. |
| `deny_reason` | ADR-004 §4.3: 최대 20개 고정값으로만 허용. 단, 현재 사용 메트릭에 레이블로 포함하지 않음. |

---

### §2 Route 정규화 전략

메트릭에 경로를 레이블로 사용하지 않으므로(§1.3 `path_normalized` 금지), route 정규화는 메트릭 레이블 목적이 아니라 **로그 필드(`path_normalized`) 계산** 목적으로만 수행된다.

이 사실을 명시적으로 확인한다: **메트릭에는 어떠한 경로 레이블도 사용하지 않는다.**

정규화 규칙(로그 목적, `rewrite_by_lua` 단계 수행):

| 패턴 | 변환 규칙 | 예시 |
|------|---------|------|
| 숫자 전용 segment | `:id`로 치환 | `/api/v1/users/12345` → `/api/v1/users/:id` |
| UUID segment | `:uuid`로 치환 | `/api/v1/orders/550e8400-e29b-41d4-a716-446655440000` → `/api/v1/orders/:uuid` |
| UUID 패턴: `[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}` | `:uuid` | — |
| 숫자 패턴: `^[0-9]+$` | `:id` | — |

정규화는 `path_raw`에 URL 디코딩 및 경로 정규화를 적용한 결과를 대상으로 한다. 메트릭 집계 경로에서는 이 정규화 결과를 사용하지 않는다.

---

### §3 Histogram 키 스키마 확정

ADR-001 §1.1에서 `latency:bucket:<ms>` 형식이 암시되었으나, 전체 키 목록과 sum/count 키가 미정의 상태였다. 이를 확정한다.

#### 3.1 HTTP 응답 시간 Histogram (`luagate_metrics` zone)

버킷 구분값은 ADR-004 §4.3에서 확정된 `0.1/0.5/1/5/10/50/100/500/1000ms`를 사용한다.

```
luagate_metrics["latency:bucket:0.1"]   = <count>   -- 0.1ms 이하 요청 수
luagate_metrics["latency:bucket:0.5"]   = <count>   -- 0.5ms 이하 누적 요청 수
luagate_metrics["latency:bucket:1"]     = <count>   -- 1ms 이하 누적 요청 수
luagate_metrics["latency:bucket:5"]     = <count>   -- 5ms 이하 누적 요청 수
luagate_metrics["latency:bucket:10"]    = <count>   -- 10ms 이하 누적 요청 수
luagate_metrics["latency:bucket:50"]    = <count>   -- 50ms 이하 누적 요청 수
luagate_metrics["latency:bucket:100"]   = <count>   -- 100ms 이하 누적 요청 수
luagate_metrics["latency:bucket:500"]   = <count>   -- 500ms 이하 누적 요청 수
luagate_metrics["latency:bucket:1000"]  = <count>   -- 1000ms 이하 누적 요청 수
luagate_metrics["latency:bucket:+Inf"]  = <count>   -- 전체 요청 수 (+Inf 버킷, Prometheus 규약)
luagate_metrics["latency:sum"]          = <total_ms> -- 누적 응답 시간 합계 (ms)
luagate_metrics["latency:count"]        = <total>    -- 전체 요청 수 (latency:bucket:+Inf와 동일)
```

**버킷 의미**: 각 버킷은 누적(cumulative)이다. `latency:bucket:5`는 "5ms 이하" 요청 수이며, 더 낮은 버킷을 모두 포함한다. Prometheus Histogram 규약을 따른다.

**`+Inf` 버킷**: Prometheus exposition format에서 `_bucket{le="+Inf"}`는 필수이며 `_count`와 동일한 값이다. `latency:bucket:+Inf`와 `latency:count`를 모두 유지하여 `/metrics` 응답 생성 시 양쪽에서 읽는다.

**업데이트 시점**: `log_by_lua` 단계에서 `latency_ms` 계산 직후, 해당 요청이 속하는 모든 버킷(`latency_ms <= bucket_upper_bound`)에 원자적 `incr`을 수행한다. `latency:sum`에는 `latency_ms` 값을 더한다.

#### 3.2 전체 키 스키마 (luagate_metrics zone)

architecture.md §3.2의 `metrics:*` prefix 규칙에 따라 전체 키를 다음과 같이 확정한다.

| 키 | 타입 | 대응 메트릭 |
|----|------|-----------|
| `metrics:http_requests_total:allow` | number | `luagate_http_requests_total{action="allow"}` |
| `metrics:http_requests_total:deny` | number | `luagate_http_requests_total{action="deny"}` |
| `metrics:http_requests_denied_total` | number | `luagate_http_requests_denied_total` |
| `metrics:http_scanner_threats_total:threat:<threat_type>` | number | `luagate_http_scanner_threats_total{threat_type="<v>"}` |
| `metrics:http_upstream_errors_total` | number | `luagate_http_upstream_errors_total` |
| `metrics:policy_reload_total` | number | `luagate_policy_reload_total` |
| `metrics:policy_reload_failures_total` | number | `luagate_policy_reload_failures_total` |
| `latency:bucket:0.1` | number | `luagate_http_response_time_ms_bucket{le="0.1"}` |
| `latency:bucket:0.5` | number | `luagate_http_response_time_ms_bucket{le="0.5"}` |
| `latency:bucket:1` | number | `luagate_http_response_time_ms_bucket{le="1"}` |
| `latency:bucket:5` | number | `luagate_http_response_time_ms_bucket{le="5"}` |
| `latency:bucket:10` | number | `luagate_http_response_time_ms_bucket{le="10"}` |
| `latency:bucket:50` | number | `luagate_http_response_time_ms_bucket{le="50"}` |
| `latency:bucket:100` | number | `luagate_http_response_time_ms_bucket{le="100"}` |
| `latency:bucket:500` | number | `luagate_http_response_time_ms_bucket{le="500"}` |
| `latency:bucket:1000` | number | `luagate_http_response_time_ms_bucket{le="1000"}` |
| `latency:bucket:+Inf` | number | `luagate_http_response_time_ms_bucket{le="+Inf"}` |
| `latency:sum` | number | `luagate_http_response_time_ms_sum` |
| `latency:count` | number | `luagate_http_response_time_ms_count` |

> **키 prefix 비일관성 참고**: ADR-001 §1.1에서 `latency:bucket:<ms>` (prefix 없음)를 암시했고 architecture.md §3.2에서 `metrics:*` prefix를 명시했다. 이 ADR에서는 ADR-001과의 하위 호환을 위해 `latency:*` 키는 prefix 없이 유지하고, 카운터 메트릭은 `metrics:` prefix를 사용하는 혼합 방식으로 확정한다. 향후 리팩토링 시 통합 가능.

#### 3.3 Stream 메트릭 키 스키마 (luagate_stream_metrics zone)

| 키 | 타입 | 대응 메트릭 |
|----|------|-----------|
| `stream:metrics:connections_total` | number | `luagate_stream_connections_total` |
| `stream:metrics:connections_denied_total` | number | `luagate_stream_connections_denied_total` |
| `stream:metrics:bytes_sent_total` | number | `luagate_stream_bytes_sent_total` |
| `stream:metrics:bytes_received_total` | number | `luagate_stream_bytes_received_total` |
| `stream:metrics:protocol_detected_total:tls` | number | `luagate_stream_protocol_detected_total{protocol="tls"}` |
| `stream:metrics:protocol_detected_total:http` | number | `luagate_stream_protocol_detected_total{protocol="http"}` |
| `stream:metrics:protocol_detected_total:raw` | number | `luagate_stream_protocol_detected_total{protocol="raw"}` |

`luagate_active_connections` (Gauge)는 `luagate_connections` zone의 `active_http` / `active_stream` 키에서 읽는다 (ADR-001 §1.1, architecture.md §3.2 기준선 유지).

---

### §4 Export 모델: Prometheus Scrape (Pull 방식)

**결정**: `/metrics` 엔드포인트를 통한 Prometheus scrape(Pull) 방식을 사용한다. Admin API spec (admin-api.md §6.8)에 이미 정의된 엔드포인트를 그대로 사용한다.

statsd Push 방식은 채택하지 않는다.

#### 4.1 Pull 방식 채택 근거

| 비교 항목 | Prometheus Scrape (Pull) | statsd Push |
|----------|--------------------------|-------------|
| 외부 의존성 | 없음. `/metrics` 응답만 생성 | 외부 statsd 서버 필수 |
| 네트워크 I/O | scrape 요청 처리(수동적) | 매 메트릭 이벤트마다 UDP 송신 |
| OpenResty 영향 | cosocket 또는 blocking 없음 (읽기 전용 shared dict 집계) | cosocket 사용 또는 blocking UDP → 이벤트 루프 위험 |
| 수평 확장 시 | Prometheus가 각 인스턴스 scrape | 각 인스턴스가 push → 집계 복잡 |
| 생태계 호환 | Prometheus, Grafana, AlertManager 직접 호환 | 별도 변환 레이어 필요 |
| 단일 인스턴스 모델 적합성 | ADR-001 §1.1의 단일 인스턴스 모델에 자연스럽게 부합 | 과잉 인프라 |

**OpenResty blocking I/O 금지 불변식** (AGENTS.md): 핸들러 내에서 blocking I/O는 금지된다. statsd Push는 매 요청마다 UDP 소켓 쓰기를 유발할 수 있어 이 불변식에 위반될 위험이 있다. Prometheus scrape는 `/metrics` 요청 시 shared dict를 읽어 응답을 생성하는 것으로, 이벤트 루프를 블로킹하지 않는다.

#### 4.2 `/metrics` 엔드포인트 동작

- 경로: `GET /metrics` (admin-api.md §6.8)
- 바인딩: `127.0.0.1:8080` (Admin API와 동일한 localhost 한정, ADR-004 §6.1)
- 인증: Bearer token 필수 (ADR-004 §6.2)
- Content-Type: `text/plain; version=0.0.4; charset=utf-8` (Prometheus exposition format)
- 집계: `luagate_metrics` + `luagate_stream_metrics` + `luagate_connections` zone에서 카운터/히스토그램 읽기; `luagate_shared_dict_capacity_bytes`/`luagate_shared_dict_free_bytes`는 모든 zone(`luagate_policy`, `luagate_state`, `luagate_metrics`, `luagate_stream_metrics`, `luagate_connections`)에서 `ngx.shared.DICT:capacity()`/`free_space()` 호출

응답 생성 시 모든 worker가 공유하는 shared dict에서 직접 읽으므로, 단일 scrape 요청이 전체 인스턴스의 집계 값을 반영한다.

---

### §5 Shared Dict 용량 계획 및 Eviction 정책

#### 5.1 용량 추천

| Zone | 추천 용량 | 산정 근거 |
|------|---------|---------|
| `luagate_metrics` | 1 MB | HTTP 카운터 키 ~20개(`metrics:*` prefix) + histogram 버킷 12개(`latency:*`) = ~32개 키. 키당 평균 ~128 bytes(키 이름 + number 값) → 4KB 미만. 1MB는 충분한 여유. 향후 `threat_type` 레이블 조합 10개 추가 시에도 여유 유지. |
| `luagate_stream_metrics` | 512 KB | Stream 카운터 키 ~10개 = ~1.3KB. 512KB는 충분한 여유. |
| `luagate_connections` | 256 KB | 2개 키(`active_http`, `active_stream`) = 수십 bytes. 현재 스펙 유지(ADR-001: 1m → 이 ADR에서 하향 추천). |

> **nginx.conf 기본값**: ADR-001 §1.1의 `luagate_metrics 5m`, `luagate_connections 1m`은 기존 설정이다. 이 ADR의 추천값은 최솟값 기준이며, 운영 환경에서 여유를 두어 ADR-001 기본값을 그대로 사용해도 무방하다.

#### 5.2 Eviction 시 Fail Mode: Fail-Open (메트릭 손실 허용)

**결정**: shared dict 쓰기 실패(용량 초과로 인한 eviction 또는 set 실패) 시 **fail-open**을 적용한다. 메트릭 손실을 허용하고 요청 처리를 계속한다.

**근거:**
- 메트릭은 관찰(observability) 목적이다. 일부 손실은 시스템 운영에 영향을 주지 않는다.
- 정책 평가는 fail-closed(ADR-001 §1.2)이지만, 메트릭 기록은 정책 평가와 별개의 코드 경로다. 메트릭 손실이 보안 결정에 영향을 주지 않는다.
- fail-closed(메트릭 쓰기 실패 시 요청 거부)는 관찰 목적의 데이터로 인해 서비스 가용성을 저하시키므로 부적절하다.

**구현 규칙:**

```lua
-- 메트릭 incr 실패 시 처리 예시
local ok, err = ngx.shared.luagate_metrics:incr(key, 1, 0)
if not ok then
    ngx.log(ngx.WARN, "metrics incr failed for key=", key, ": ", err)
    -- 요청 처리 계속 (fail-open)
end
```

- `ngx.shared.luagate_metrics:set()` 또는 `incr()` 실패 시: `ngx.log(ngx.WARN, ...)` 기록 후 계속 진행
- `ngx.log(ngx.ERR, ...)` 레벨은 사용하지 않음. WARN 레벨로 기록하여 알림 임계값 오염 방지
- 메트릭 쓰기 실패는 요청의 `action` 결정에 영향을 주지 않음

#### 5.3 Zone별 eviction 우선순위

`ngx.shared.DICT`는 LRU eviction을 사용한다. 메트릭 카운터는 자주 갱신되므로 최근 갱신 키가 유지될 가능성이 높다. histogram 버킷 키도 자주 갱신되므로 eviction 대상이 될 가능성은 낮다. 별도 eviction 우선순위 제어는 하지 않는다.

---

## Consequences

### 긍정적 결과

- **Cardinality 통제**: 레이블 허용 목록(§1.1)으로 메트릭 폭발을 방지한다. `luagate_http_scanner_threats_total{threat_type}` 신규 메트릭으로 보안 분석 대시보드 구성이 가능해지며, `luagate_http_requests_denied_total`의 이중 집계 문제를 해결한다.
- **Histogram 완전성**: `sum`, `count`, `+Inf` 버킷이 명확히 정의되어 Prometheus `histogram_quantile()` 함수를 사용할 수 있다.
- **Export 단순성**: Prometheus scrape 방식으로 외부 인프라 의존성이 없다. OpenResty 이벤트 루프에 영향을 주지 않는다.
- **서비스 가용성 우선**: fail-open eviction 정책으로 메트릭 zone 문제가 요청 처리 장애로 전파되지 않는다.
- **구현 명확성**: 전체 키 스키마(§3.2, §3.3)가 확정되어 `log_by_lua`, `content_by_lua` 구현 시 판단 없이 따를 수 있다.

### 부정적 결과

- **`threat_type` 레이블 관리 부담**: `luagate_http_scanner_threats_total`에 새 위협 유형 추가는 이 ADR 개정이 필요하다. 미등록 값은 `other`로 폴백되어 세분화 분석이 불가하다.
- **키 prefix 비일관성**: `latency:*` 키와 `metrics:*` 키가 혼재한다(§3.2 참고). 향후 통합 리팩토링이 필요할 수 있다.
- **용량 고정**: ADR-001과 동일하게 shared dict 용량은 nginx.conf에서 정적으로 결정되며 런타임 변경이 불가하다. 메트릭 구조 변경 시 재기동이 필요하다.
- **scrape 인증 필요**: `/metrics` 엔드포인트가 Admin API Bearer token으로 보호되므로 Prometheus scrape config에 인증 설정이 필요하다.

### 향후 고려

- `latency:*` 와 `metrics:*` 키 prefix를 통합하는 리팩토링 ADR 검토 (Phase 0-B 이후)
- `threat_type` enum 값이 10개를 초과할 경우 이 ADR 개정 또는 supersede
- 멀티 인스턴스 배포 시 Prometheus federation 또는 remote_write 도입 (별도 ADR, architecture.md `<!-- ADR 필요 -->` 마커 참조)

---

## 관련 문서

- [ADR-001](./ADR-001-execution-shared-state-model.md) — shared dict 기반 상태 공유, 키 스키마 기준선, eviction fail mode 원칙
- [ADR-004](./ADR-004-log-metrics-admin-security.md) — 메트릭 이름 목록, cardinality 원칙, export 방식(§4.3), 관리면 보안
- [spec/architecture.md §3.2](../../spec/architecture.md#32-zone-목록-및-역할) — Zone 목록 및 키 prefix 규칙
- [spec/admin-api.md §6.8](../../spec/admin-api.md) — `/metrics` 엔드포인트 스펙
- [spec/log-schema.md](../../spec/log-schema.md) — `threat_type` 로그 필드 정의 (§3 필드 #18)
