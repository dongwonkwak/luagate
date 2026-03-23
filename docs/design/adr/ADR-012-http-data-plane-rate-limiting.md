# ADR-012: HTTP Data Plane Rate Limiting

> [← ADR 인덱스로 돌아가기](./README.md)

| 항목 | 내용 |
|------|------|
| **Status** | Accepted |
| **Date** | 2026-03-23 |
| **Deciders** | LuaGate Architects |
| **Issue** | [DON-224](https://linear.app/dongwon/issue/DON-224) |
| **Depends on** | [ADR-001](./ADR-001-execution-shared-state-model.md), [ADR-003](./ADR-003-policy-storage-hot-reload.md), [ADR-006](./ADR-006-metrics-cardinality-export-model.md) |
| **Resolves** | Data plane HTTP 요청에 대한 rate limiting 부재; 정책 규칙별 요청 속도 제한 메커니즘 필요 |

---

## Status

**Accepted** -- 정책 규칙 단위의 Sliding Window Counter 기반 rate limiting을 HTTP data plane에 도입한다.

---

## Context

현재 LuaGate는 Admin API(`:9090`)에 대해서만 IP 기반 rate limiting을 적용한다 (`lua/luagate/admin/ratelimit.lua`, shared dict `luagate_admin_ratelimit`). Data plane(`:8080`)에는 rate limiting이 없어, 정책으로 allow된 요청이라도 과도한 트래픽에 대한 보호가 불가하다.

### 현재 상태

1. **Admin rate limiting**: Sliding Window Counter 알고리즘, `luagate_admin_ratelimit` shared dict, IP당 60초/30회 고정. `ngx.shared.DICT:incr()` 원자적 증분으로 멀티 worker 안전
2. **Data plane rate limiting**: 없음. http-pipeline.md §10에 `<!-- ADR 필요 -->` 마커로 표기
3. **정책 규칙 구조**: `policies.yaml`의 `rules[]`에 `rate_limit` 필드 없음. 규칙별 속도 제한 불가

### 요구 사항

- 정책 규칙 단위로 rate limit 설정 가능 (규칙별 `requests`/`window`/`scope`)
- 멀티 worker 환경에서 원자적 카운터 (race condition 방지)
- 성능 영향 최소화 (shared dict 접근만, 외부 I/O 없음)
- 기존 Admin rate limiter와 알고리즘 일관성 유지
- fail-open/fail-closed 정책 명확화

### 검토된 대안

| 대안 | 장점 | 단점 |
|------|------|------|
| **Fixed Window Counter** | 구현 단순, shared dict 1키 | 윈도우 경계 burst 문제 (2x spike) |
| **Sliding Window Log** | 정확한 윈도우 | 요청당 타임스탬프 저장, shared dict 메모리 과다 |
| **Token Bucket** | burst 허용, 유연 | shared dict에 부동소수점 시간 연산 필요, 복잡 |
| **Sliding Window Counter** | burst 완화, 메모리 효율, Admin과 동일 | 근사 계산 (최대 오차 ~1 요청) |
| **External store (Redis)** | 분산 카운터 | 외부 의존성, 장애 시 전체 영향, latency 추가 |

---

## Decision

### 1. 알고리즘: Sliding Window Counter

Admin rate limiter와 동일한 Sliding Window Counter 알고리즘을 채택한다.

**이유**: `ngx.shared.DICT:incr(key, 1, 0, ttl)` 원자적 증분으로 멀티 worker race condition을 방지하며, 2개 키(현재 slot + 이전 slot)만으로 근사 sliding window를 구현할 수 있다. 이미 Admin rate limiter에서 검증된 패턴이므로 유지보수 비용이 낮다.

**카운터 계산**:
```
current_slot  = floor(now / window)
previous_slot = current_slot - 1
elapsed_fraction = (now - current_slot * window) / window

weighted_count = prev_count * (1 - elapsed_fraction) + curr_count
```

**Increment-then-check**: 현재 slot 카운터를 먼저 원자적으로 증분한 뒤 weighted count를 계산한다. 이를 통해 여러 worker가 동시에 동일 스냅샷을 읽어 모두 통과하는 race condition을 방지한다.

### 2. 카운터 Zone: `luagate_ratelimit` (8 MB)

| 항목 | 값 |
|------|-----|
| **Zone 이름** | `luagate_ratelimit` |
| **크기** | 8 MB |
| **키 스키마** | `rl:<rule_id>:<scope_key>:<slot>` |
| **TTL** | `window * 2` (이전 slot 보존) |
| **Eviction 정책** | LRU (ngx.shared.DICT 기본) |

- `<rule_id>`: 매칭된 규칙의 `id` 필드. 서로 다른 규칙이 동일한 scope_key와 window를 사용하더라도 카운터가 독립적으로 유지된다. **문자 제한**: `[a-z0-9-]+` (소문자 영숫자와 하이픈만 허용, `:` 금지). 구분자 `:`와의 충돌을 방지한다. 정책 로드 시 검증하며, 위반 시 로드 거부 (ADR-003 startup-fatal)
- `<scope_key>`: scope에 따른 식별자 (MVP: client IP). **IPv6 주소는 bracket으로 감싸서** 구분자 `:`와의 충돌을 방지한다. 예: IPv4 `rl:api-rate-limit:192.168.1.1:42371`, IPv6 `rl:api-rate-limit:[::1]:42371`, IPv6 `rl:api-rate-limit:[2001:db8::1]:42371`
- `<slot>`: `floor(now / window)` 정수값

**구분자 안전성 규칙**:
- 키 구분자는 `:`를 사용한다
- `rule_id`에 `:`를 금지하여 구분자 충돌을 원천 차단한다
- IPv6 주소는 `[addr]` 형태로 감싸서 주소 내 `:`가 구분자로 오인되지 않도록 한다
- `<slot>`은 정수값이므로 `:`를 포함하지 않는다
- 이를 통해 키의 각 필드를 `:`로 안전하게 분할(split)할 수 있다

**Eviction 시 동작**:
- **카운터 키 eviction (fail-open)**: shared dict 용량 부족으로 카운터 키가 eviction되면 `incr(key, 1, 0, ttl)`이 새 키를 생성한다. 기존 카운트가 유실되므로 일시적으로 제한이 풀린다 (fail-open). 이는 의도된 trade-off이다 -- 트래픽이 극히 높을 때 일부 요청이 제한을 우회하는 것이 전체 서비스를 차단하는 것보다 낫다.
- **shared dict 자체 불가 (fail-closed)**: `ngx.shared.luagate_ratelimit`이 nil인 경우 (nginx.conf 설정 누락 등), **503 Service Unavailable**을 반환한다. 이는 구성 오류이므로 fail-closed가 적절하다.
  - **503 경로 메타데이터**:
    - `decision_source`: `rate_limiter`
    - `deny_reason`: `ratelimit_unavailable`
    - `request_state`: `internal_error`
    - `action`: `deny`
  - **503 응답 body**: `{"error":"Service Unavailable","request_id":"<request_id>"}`
  - **응답 헤더**: `Content-Type: application/json`, `Cache-Control: no-store`, `X-Request-ID: <request_id>`
- **`incr()` 실패 (fail-closed)**: `incr()` 호출이 nil을 반환하는 경우 (예상치 못한 shared dict 오류), ERR 로그를 남기고 **503 Service Unavailable**을 반환한다. rate limiter는 data plane 보안 강제 경로의 일부이므로, 카운터 갱신 실패 시 요청을 통과시키지 않는다.

**Data plane/Admin plane 공통 fail-closed 정책**:
Data plane rate limiter와 Admin rate limiter(`lua/luagate/admin/ratelimit.lua`)는 모두 `incr()` 실패를 fail-closed(503)로 처리한다. 이는 `AGENTS.md`의 보안 경로 불변식과 일치한다.
- **Rate limiter enforcement**: 요청 허용/차단에 직접 관여하므로, 카운터 갱신 실패 시 throttling 우회를 허용하지 않는다.
- **Metrics만 예외적 fail-open**: `luagate_metrics` 갱신 실패처럼 보안 판정에 영향을 주지 않는 경로에서만 WARN 로그 후 계속 진행할 수 있다.

**용량 산정**: `ngx.shared.DICT` 키당 약 50 bytes 오버헤드 + `rl:<20-char-rule-id>:<15-char-ip>:<8-digit-slot>` = ~50 bytes 키 + 8 bytes 값 = 108 bytes/키. 규칙 R개, scope가 `client_ip`이고 규칙당 활성 IP가 N개이면 총 키 수 = R x N x 2 (현재 slot + 이전 slot). 예: 5개 규칙, 규칙당 5,000 활성 IP = 50,000 키 x 108 bytes = 5.4 MB. 8 MB로 설정하면 약 74,000개 키를 수용 가능하여 50,000 키 기준 충분한 여유를 확보한다.

### 3. 정책 규칙 `rate_limit` 필드 (선택적)

```yaml
rules:
  - id: api-rate-limit
    priority: 15
    scope:
      path: /api/v1/*
    action: allow
    rate_limit:                   # 선택적 필드. 없으면 rate limiting 미적용
      requests: 100              # 윈도우 내 최대 요청 수 (양의 정수)
      window: 60                 # 윈도우 크기 (초, 양의 정수)
      scope: client_ip           # 카운터 scope (MVP: client_ip만 지원)
```

**필드 정의**:

| 필드 | 타입 | 필수 | 설명 |
|------|------|------|------|
| `rate_limit.requests` | integer (> 0) | Y (rate_limit 존재 시) | 윈도우 내 최대 허용 요청 수 |
| `rate_limit.window` | integer (> 0) | Y (rate_limit 존재 시) | 윈도우 크기 (초) |
| `rate_limit.scope` | enum | Y (rate_limit 존재 시) | 카운터 키 scope. MVP: `client_ip`만 지원 |

**Scope 키 생성 규칙** (MVP):

| `scope` 값 | 키 생성 | 예시 |
|------------|---------|------|
| `client_ip` | `rl:<rule_id>:<src_ip>:<slot>` (IPv6는 `[addr]`로 감싸기) | IPv4: `rl:api-rate-limit:192.168.1.1:42371`, IPv6: `rl:api-rate-limit:[::1]:42371` |

> **향후 확장**: `scope`에 `path`, `header:<name>`, `api_key` 등을 추가할 수 있다. 키 스키마는 `rl:<rule_id>:<scope_type>:<scope_value>:<slot>` 형태로 확장 가능하나, MVP에서는 `client_ip`만 지원하므로 `scope_type` prefix를 생략한다.

**검증 규칙** (정책 로드 시):
- `rate_limit` 필드가 있으면 `requests`, `window`, `scope` 모두 필수
- `requests`와 `window`는 양의 정수
- `scope`는 `"client_ip"` 값만 허용 (MVP)
- `rate_limit`은 `action: allow` 규칙에서만 유효 (`action: deny` 규칙에는 rate limiting 불필요)
- 검증 실패 시 정책 로드 자체를 거부 (ADR-003 startup-fatal 계약)

### 4. 파이프라인 위치: access_by_lua, 정책 평가 후

```
access_by_lua 처리 순서:
  1. 정책 버전 확인 (shared dict L2)
  2. Rust FFI: 보안 스캐너
  3. 정책 평가 (ADR-002)
     ├── deny  → 403 반환 (rate limit 미검사)
     └── allow → 4번으로
  4. Rate limit 검사 (매칭된 규칙에 rate_limit 필드 있을 때만)
     ├── 초과 → 429 반환
     └── 통과 → proxy_pass
```

**이유**: 정책 평가 후에 rate limit을 검사하는 이유는 두 가지이다.

1. **deny된 요청을 카운트하지 않음**: 정책에 의해 차단된 요청까지 rate limit 카운터에 포함하면 공격자가 deny 대상 요청을 대량 전송하여 정상 사용자의 quota를 소진시킬 수 있다.
2. **규칙별 rate_limit 필드 참조**: rate limit 설정이 매칭된 규칙에 내장되어 있으므로, 어떤 규칙이 매칭되었는지 먼저 알아야 rate limit 파라미터를 결정할 수 있다.

**스캐너 비용 trade-off**: 이 순서에서 rate limit 초과 요청도 보안 스캐너(Rust FFI)를 먼저 통과한다. 이는 의도된 trade-off이다:
- 스캐너를 건너뛰면 rate limit 이내의 악성 요청이 탐지되지 않는다. 보안 검사는 항상 rate limit보다 우선해야 한다.
- 스캐너 FFI 호출은 budget 5ms 이내로 제한되어 있어 ([ADR-009](./ADR-009-ffi-timeout-enforcement.md), [rust-ffi-modules.md §7](../../spec/rust-ffi-modules.md)) 성능 영향이 제한적이다.
- rate limit 초과 요청에 대한 스캐너 비용은 429 응답 생성 비용 대비 미미하며, deny 요청 카운트 방지와 규칙별 파라미터 참조라는 정확성 이점이 이를 정당화한다.

> **향후 개선**: 매우 높은 트래픽 환경에서 스캐너 비용이 문제될 경우, 규칙 매칭 전에 적용되는 "global rate limit" (단일 threshold, 전체 요청 대상) 옵션을 도입할 수 있다. 이는 정책 규칙과 독립적이므로 스캐너 이전에 배치 가능하다.

**`evaluate_http()` 반환 확장**: 매칭된 규칙의 rate_limit 파라미터를 호출자(`handler.lua`)에게 전달하기 위해 반환값을 확장한다.

```text
-- 기존 반환: (action, rule_id, deny_reason)
-- 확장 반환: (action, rule_id, deny_reason, rate_limit)

function evaluate_http(request):
    rules = get_active_http_rules()
    for rule in rules:
        if matches(rule.scope, request):
            return rule.action, rule.id, nil, rule.rate_limit  -- rate_limit은 nil 가능
    return global.default_action, nil, nil, nil
```

- `rate_limit`: 매칭된 규칙의 `rate_limit` 테이블 (`{requests, window, scope}`) 또는 `nil` (rate_limit 미설정 규칙)
- `handler.lua`의 `access()`는 `action == "allow"` AND `rate_limit ~= nil`일 때만 rate limit 검사를 수행한다
- `deny` 판정 시 4번째 반환값은 무시된다 (deny 규칙에는 rate_limit 필드가 없으므로 항상 nil)

### 5. 응답: 429 + Rate Limit 헤더

**Rate limit 초과 시 응답**:

| 항목 | 값 |
|------|-----|
| **Status Code** | 429 Too Many Requests |
| **Content-Type** | `application/json` |
| **Cache-Control** | `no-store` |

```json
{
  "error": "Too Many Requests",
  "request_id": "<request_id>",
  "retry_after": <seconds>
}
```

**응답 헤더** (429 및 정상 응답 모두):

| 헤더 | 설명 | 포함 조건 |
|------|------|---------|
| `Retry-After` | 다음 요청 가능 시점까지 대기 시간 (초) | 429 응답 시만 |
| `X-RateLimit-Limit` | 윈도우 내 최대 허용 요청 수 | rate_limit 규칙 매칭 시 항상 |
| `X-RateLimit-Remaining` | 현재 윈도우 잔여 허용 요청 수 | rate_limit 규칙 매칭 시 항상 |
| `X-RateLimit-Reset` | 현재 윈도우 종료 Unix timestamp (초) | rate_limit 규칙 매칭 시 항상 |
| `X-Request-ID` | 요청 ID | 항상 |

**Remaining 계산**: `max(0, requests - ceil(weighted_count))`. 근사값이므로 0 이하로 내려갈 수 있으나 음수는 0으로 clamp한다.

**Reset 계산**: `(current_slot + 1) * window`. 현재 윈도우 slot의 종료 시점이다. 정확한 sliding window 만료 시점은 아니지만, 클라이언트에게 유용한 근사값이다.

### 6. 의사결정 메타데이터

Rate limit에 의한 차단은 기존 http-pipeline.md의 decision 체계에 통합된다.

| 항목 | 값 |
|------|-----|
| `decision_source` | `rate_limiter` |
| `deny_reason` | `rate_limit_exceeded` |
| `action` | `deny` |
| `request_state` | `rate_limited` |
| `matched_rule_id` | 매칭된 규칙의 `id` (rate_limit을 트리거한 규칙) |

> `decision_source` 값 `rate_limiter`는 http-pipeline.md §4에 예약되어 있으며, 이 ADR로 활성화된다.

### 7. 메트릭

| 메트릭 | 타입 | 설명 |
|--------|------|------|
| `luagate_ratelimit_rejected_total` | Counter | Rate limit에 의해 거부된 총 요청 수 |

- shared dict `luagate_metrics`에 저장 (ADR-006 카디널리티 제어 준수)
- 레이블 없음 (ADR-006: low-cardinality 원칙. 규칙별/IP별 레이블은 고카디널리티이므로 제외)
- `safe_incr()` 패턴 사용 (실패 시 WARN 로그만, 요청 처리 계속)
- 기존 `metrics:http_requests_total:deny` 카운터에도 포함 (rate limit deny도 deny의 일종, ADR-006 §3.2 키 스키마 준수)

---

## File Structure

```
lua/luagate/http/
├── handler.lua            # access() 함수에 rate limit 검사 로직 추가
└── ratelimit.lua          # data plane rate limiter 모듈 (신규)

conf/
└── nginx.conf             # lua_shared_dict luagate_ratelimit 8m; 추가
```

> `lua/luagate/http/ratelimit.lua`는 `lua/luagate/admin/ratelimit.lua`의 구조를 따르되, data plane 전용으로 설계한다. 정책 규칙에서 `requests`/`window`를 동적으로 받는 점이 Admin rate limiter(고정 30req/60s)와 다르다.

---

## Log Schema Changes

access.log 필드 변경 없음. 기존 30필드 체계를 그대로 사용한다.

- `action`: `deny` (rate limit 차단 시)
- `decision_source`: `rate_limiter`
- `deny_reason`: `rate_limit_exceeded`
- `matched_rule`: 매칭된 규칙 ID
- `status`: `429`

> 신규 필드 추가 없이 기존 필드의 값 범위만 확장한다 (`decision_source`에 `rate_limiter` 값 활성화).

---

## Consequences

### 긍정적

- 정책 규칙 단위로 유연한 rate limiting 설정 가능
- Admin rate limiter와 동일 알고리즘으로 일관성 유지 및 유지보수 비용 절감
- shared dict 기반으로 외부 의존성 없이 멀티 worker 안전
- 정상 응답에도 quota 헤더를 포함하여 클라이언트가 자체적으로 속도 조절 가능
- 기존 decision_source/deny_reason 체계에 자연스럽게 통합

### 부정적

- shared dict 8 MB 추가 메모리 사용
- Sliding Window Counter의 근사 오차 (~1 요청)
- 정책 YAML 스키마 복잡도 증가 (`rate_limit` 필드 추가)

### 리스크

| 리스크 | 완화 |
|--------|------|
| shared dict eviction으로 rate limit 우회 | fail-open 허용 (가용성 우선). 8 MB로 ~74,000 키 수용. 용량 부족 시 WARN 로그 |
| 멀티 인스턴스 배포 시 인스턴스별 카운터 분리 | shared dict는 프로세스 로컬. 인스턴스 N대일 때 실질 limit = N * requests. 분산 카운터는 Phase 2 (Redis 또는 외부 store) |
| window가 매우 짧을 때 (예: 1초) 정밀도 저하 | 최소 window 권장값 문서화 (10초 이상). 검증에서 최소값 강제는 하지 않음 |
| rate_limit이 있는 규칙이 많을 때 shared dict 접근 증가 | 매칭된 단일 규칙에 대해서만 2회 접근 (incr + get). O(1) 연산이므로 규칙 수와 무관 |

---

## Implementation Plan

1. **정책 스키마 확장**: `conf/policies.yaml` 및 policy loader에 `rate_limit` 필드 추가 + 검증 로직
2. **`lua/luagate/http/ratelimit.lua`**: data plane rate limiter 모듈 구현 (check 함수: 규칙의 rate_limit 설정 + src_ip 입력 → allow/deny 판정)
3. **`lua/luagate/http/handler.lua`**: `access()` 함수에서 정책 allow 판정 후 rate limit 검사 호출 추가
4. **`conf/nginx.conf`**: `lua_shared_dict luagate_ratelimit 8m;` 추가
5. **429 응답 처리**: `do_rate_limit_deny()` 함수 구현 (JSON body + 헤더)
6. **quota 헤더 주입**: 정상 응답(allow + rate_limit 규칙 매칭)에도 `X-RateLimit-*` 헤더 추가. **`header_filter_by_lua`에서 `ngx.header` 설정** — access_by_lua에서 설정하면 proxy_pass 이전에 설정되어 upstream 응답 헤더와 충돌할 수 있으므로, upstream 응답 후 게이트웨이가 헤더를 추가/덮어쓰는 header_filter_by_lua가 적절하다. access_by_lua에서 계산한 quota 정보(`remaining`, `limit`, `reset`)를 `ngx.ctx.luagate`에 저장하고, header_filter_by_lua에서 읽어 `ngx.header`에 설정한다
7. **메트릭**: `luagate_ratelimit_rejected_total` 카운터 추가
8. **테스트**: unit test + integration test
