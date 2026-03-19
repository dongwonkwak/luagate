# ADR-005: 정책 활성화 모델 + 동시성 제어

> [← ADR 인덱스로 돌아가기](./README.md)

| 항목 | 내용 |
|------|------|
| **Status** | Accepted |
| **Date** | 2026-03-16 |
| **Deciders** | LuaGate Architects |
| **Issue** | [DON-122](https://linear.app/dongwon/issue/DON-122) |
| **Depends on** | [ADR-002](./ADR-002-policy-evaluation-conflict-detection.md), [ADR-003](./ADR-003-policy-storage-hot-reload.md) |

---

## Status

**Accepted** — Phase 0-A에서 고정.

---

## Context

ADR-003은 Hot Reload 7단계 순서와 shared dict versioned keyspace 모델을 확정했다.
그러나 다음 질문들은 ADR-003 범위 밖에 있었으며 별도 결정이 필요했다:

1. **저장과 활성화 트랜잭션**: `PUT /api/v1/policies` 하나로 저장 + 활성화까지 완료해야 하는가,
   아니면 별도의 "staged → activate" 2단계 모델이 필요한가?
2. **policy_version 의미**: `PUT /api/v1/policies` 응답의 버전 필드는 staged 버전인가, active 버전인가?
3. **concurrent reload 처리**: 동시에 여러 reload 요청이 들어오면 어떻게 처리하는가?
   queuing, rejection(409), last-writer-wins 중 선택해야 한다.
4. **in-flight 요청의 정책 버전 보장**: reload 중 처리 중인 요청은 어느 버전의 정책으로 완료되어야 하는가?

---

## Decision

### §1 저장 + 활성화 단일 파이프라인 (1-step 모델)

`PUT /api/v1/policies`는 저장(canonical file write)부터 활성화(active pointer swap)까지
**하나의 파이프라인**으로 처리한다. staged 상태를 거치는 2단계 모델은 채택하지 않는다.

처리 순서:

```
[1] If-Match 확인 (source_version 기준)
[2] YAML 파싱
[3] Schema 검증
[4] 충돌/음영 감지 (ADR-002)
[5] SHA256 해시 계산 → new_version
[6] 컴파일 (정책 내부 표현 생성)
[7] audit 로그 기록
[8a] HTTP active pointer swap (shared dict versioned keyspace 기록 + active pointer 교체)
[8b] Stream active pointer swap (shared dict versioned keyspace 기록 + active pointer 교체)
[8c] canonical file write (conf/policies.yaml 덮어쓰기)
```

**commit 단계([8a]-[8c]) 실행 규칙:**

- [8a], [8b]는 독립적으로 수행하되, 한쪽이 실패하면 성공한 쪽도 이전 버전으로 롤백(best-effort)하고 PUT 전체를 실패 반환한다.
- [8c] canonical file write는 **[8a]와 [8b] 양쪽이 모두 성공한 경우에만** 수행한다.
- [8c] 실패 시에는 [8a], [8b]도 이전 버전으로 롤백(best-effort)하고 PUT 전체를 실패 반환한다.
- **rollback 자체가 실패한 경우**: CRITICAL 로그를 기록하고 500을 반환한다.
  이 경우 HTTP/Stream active_version이 서로 불일치한 상태가 될 수 있으며,
  운영자가 강제 재기동(`SIGHUP`) 또는 수동 복구를 통해 일관성을 회복해야 한다.
- 따라서 PUT 성공 응답(200) 시 `source_version == active_http_version == active_stream_version`이 반드시 성립한다.

> **admin-api.md §4 규정 준수**: "실패 시 canonical file을 변경하지 않는다."
> [8c]를 commit 단계의 마지막에 두어 [8a]/[8b] 실패 시 file write 자체가 수행되지 않으므로 이 규정과 일치한다.

**`PUT /api/v1/policies` 응답의 버전 필드는 active 버전을 반환한다:**

```json
{
  "previous_http_version": "a3f2c1d4...",
  "previous_stream_version": "a3f2c1d4...",
  "new_http_version": "b4e3f2a1...",
  "new_stream_version": "b4e3f2a1...",
  "http_result": "committed",
  "stream_result": "committed",
  "warnings": []
}
```

`new_http_version` / `new_stream_version`은 active pointer에 기록된 버전이다.
staged 중간 상태는 존재하지 않으므로 "staged version"이라는 개념은 없다.

> **source_version vs active_version 불변식**: `source_version`은 canonical source 파일(conf/policies.yaml)의 SHA256이다.
> PUT 성공(200) 시 `source_version == new_http_version == new_stream_version`이 반드시 성립한다.
> commit 단계([8a]-[8c])에서 HTTP/Stream 양쪽이 모두 성공해야만 canonical file write([8c])가 수행되므로,
> Partial commit으로 인한 `source_version != active_version` 상황은 발생하지 않는다.
> 한쪽 서브시스템 swap 실패 시 PUT 전체가 실패(500)로 반환되며, 성공한 쪽도 이전 버전으로 롤백(best-effort)된다.

### §2 concurrent reload 처리 — Rejection 모델

동시 reload 요청은 **rejection(409) 모델**을 사용한다. queuing과 last-writer-wins는 채택하지 않는다.

**구현 방식:**

```lua
-- reload 시작 시
local owner_id = tostring(ngx.worker.id()) .. ":" .. ngx.now()
local ok = ngx.shared.luagate_policy:add("reload_lock", owner_id, 5)
--   ok == true:  이 worker가 reload를 독점 진행
--   ok == false: lock 이미 존재 → 즉시 409 반환

-- reload 완료/실패 시 (owner 검증 후 삭제)
local current = ngx.shared.luagate_policy:get("reload_lock")
if current == owner_id then
  ngx.shared.luagate_policy:delete("reload_lock")
end
```

`reload_lock` 값에는 `ngx.worker.id():ngx.now()` 형태의 owner_id를 저장한다.
delete 시 반드시 현재 lock 값이 자신의 owner_id와 일치하는지 검증한 후 삭제한다.
이는 TTL 만료 후 이전 소유자의 `delete()` 호출이 새 소유자의 lock을 지우는 race condition을 방지한다.

> **Known Limitation — 비원자적 lock race window**: `ngx.shared.DICT`는 `compare-and-delete` 원자 연산을 제공하지 않는다.
> 따라서 `get()` → 비교 → `delete()` 사이에 TTL 만료 + 다른 worker의 `add()` 재획득이 동시에 발생하면,
> 이전 소유자의 `delete()`가 새 소유자의 lock을 삭제할 수 있다.
> 현실적 위험도: TTL=5s 내에 reload가 완료되고 `delete()`가 정상 호출되는 경우가 99%+이며,
> single-admin 운영 가정 하에 동시 경쟁 자체가 극히 드물다.
> 완전한 원자적 보장이 필요한 경우 Redis + Lua `EVALSHA`나 별도 mutex 메커니즘 도입이 필요하나,
> 현재 범위에서는 이 trade-off를 수용한다.

`reload_lock`은 TTL 5초를 가진다. worker crash 등으로 lock 해제 없이 worker가 종료되어도
5초 후 자동 만료되어 다음 reload 요청을 처리할 수 있다.

**이 모델이 적용되는 API:**

| API | lock 획득 여부 | 409 조건 |
|-----|--------------|---------|
| `PUT /api/v1/policies` | 필수 | lock 획득 실패 시 409 `reload_in_progress` |
| `POST /api/v1/policies/reload` | 필수 | lock 획득 실패 시 409 `reload_in_progress` |

**409 응답 예시:**

```json
{
  "error": "reload_in_progress",
  "stage": "reload",
  "details": ["another reload is already in progress"]
}
```

**queuing을 채택하지 않은 이유:**

- shared dict 기반 큐 구현은 worker 간 조율 복잡도를 크게 높인다.
- reload 요청이 동시에 여러 개 들어오는 정상 운영 시나리오는 없다 (관리자 단독 조작 가정).
- 409를 받은 클라이언트가 재시도하는 것이 더 명확하다.

**last-writer-wins를 채택하지 않은 이유:**

- 두 번째 writer가 첫 번째 writer의 중간 상태를 덮어쓰면 예측 불가능한 결과를 만든다.
- 운영자 실수로 인한 동시 reload 시 데이터 일관성 보장 불가.

### §3 in-flight 요청/세션의 정책 버전 보장 — request-start snapshot

요청/세션 처리 도중 reload가 발생하더라도, **시작 시점**에 읽은 정책 버전으로
해당 요청/세션이 완료되어야 한다.

#### §3.1 HTTP — rewrite_by_lua 스냅샷

```lua
-- rewrite_by_lua_block 진입 시
local version = policy_store.get_active_version("http")  -- shared dict 조회
local policy  = policy_store.get_or_load(version)        -- worker upvalue 캐시 or shared dict 로드
ngx.ctx.policy_version = version   -- 이 요청의 스냅샷 버전 기록
ngx.ctx.policy         = policy    -- 이 요청 수명 동안 사용할 정책 객체

-- 이후 log_by_lua_block 에서
local active_version = ngx.ctx.policy_version  -- 요청 시작 시 스냅샷한 버전을 로그에 기록
```

`ngx.ctx`는 단일 요청 수명 동안만 유효하다. reload로 shared dict의 active_version이
교체되어도 이미 `ngx.ctx`에 바인딩된 이 요청의 정책은 변경되지 않는다.

> **스냅샷 단계 근거**: `http-pipeline.md` §3 변수 목록 및 `log-schema.md` §3.1 `active_version` Producer Phase 기준,
> `$luagate_active_version`은 `rewrite_by_lua` 단계에서 선할당된다.
> `access_by_lua` 이전에 스냅샷을 잡아야 nginx_core early short-circuit(400/413/414) 시에도
> 27필드가 모두 채워지는 기본값 선할당 전략(`log-schema.md` §2)과 일치한다.

#### §3.2 Stream — preread_by_lua 스냅샷 (TCP 장수명 세션)

TCP 세션은 HTTP 요청과 달리 수명이 길어 reload가 세션 중간에 발생할 가능성이 높다.
세션 시작(`preread_by_lua`) 시점의 버전으로 세션 전체를 처리한다.

```lua
-- preread_by_lua_block 진입 시 (세션 시작)
ngx.ctx.policy_version = policy_store.get_active_version("stream")
ngx.ctx.policy         = policy_store.get_or_load(ngx.ctx.policy_version)

-- 세션 로그 기록 시
local session_version = ngx.ctx.policy_version  -- 세션 시작 시 스냅샷한 버전을 로그에 기록
```

reload 후 **새로 연결된 세션**만 새 버전 정책을 적용받는다.
**기존 TCP 세션**은 세션 시작 시점에 바인딩된 버전을 세션 종료까지 유지한다.

> **긴급 차단 주의사항**: 긴급 IP 차단 등 기존 세션에 즉시 정책 변경을 적용해야 하는 경우,
> `SIGHUP`(HUP reload + worker graceful restart)을 사용한다.
> ngx.ctx 스냅샷은 해당 요청/세션 수명 동안 고정이므로, SIGHUP 없이 PUT /api/v1/policies 만으로는
> 기존 세션에 변경이 소급 적용되지 않는다.

**보장 사항:**

| 시나리오 | HTTP | Stream (TCP) |
|----------|------|-------------|
| reload 전 시작된 요청/세션 | 구 버전 정책으로 완료 (ngx.ctx 스냅샷) | 구 버전 정책으로 세션 종료까지 처리 |
| reload 완료 후 시작된 요청/세션 | 새 버전 정책으로 처리 | 새 버전 정책으로 처리 |
| reload 중 시작된 요청/세션 | 구 버전 또는 새 버전 (둘 다 일관됨) | 구 버전 또는 새 버전 (둘 다 일관됨) |
| 로그 `active_version` 필드 | 해당 요청에 실제 적용된 버전 기록 | 세션 시작 시 적용된 버전 기록 |

> **ngx.ctx 캐시 금지 범위**: 정책 객체 전체(ngx.ctx.policy)는 요청/세션별 스냅샷 용도로 허용한다.
> 단, 여러 요청에 걸쳐 공유되는 상태(shared dict 대체 용도)로 ngx.ctx를 사용하는 것은 금지한다.
> 이는 AGENTS.md 불변식 "ngx.ctx에 정책 캐시 저장 금지"와 충돌하지 않는다 —
> 해당 불변식은 "여러 요청에 걸친 공유 캐시로 ngx.ctx 오용 금지"를 의미하며,
> 단일 요청/세션 내 스냅샷 바인딩은 ADR-005 §3에 의해 명시적으로 허용된다.
>
> **이 패턴은 AGENTS.md 금지 대상이 아니다**: AGENTS.md 금지 불변식("ngx.ctx에 정책 캐시 저장 금지")은
> worker 간 공유 캐시 오용 — 즉 여러 요청에 걸쳐 지속되는 정책 캐시를 ngx.ctx에 보관하는 행위 — 을 금지한다.
> §3의 `ngx.ctx.policy`는 단일 요청/세션 수명에만 존재하며, worker 간에 공유되지 않는다.
>
> **구현자 주의 — 두 캐시 계층을 반드시 분리할 것**:
> - `module-level _cached_policy` (worker upvalue): hot reload용 L1 캐시. worker 수명 동안 유지되며
>   `policy_store.get_or_load()`가 관리한다.
> - `ngx.ctx.policy`: 단일 요청/세션 스냅샷. 요청 종료 시 자동 소멸.
>
> 두 캐시를 혼용하거나(예: ngx.ctx.policy를 worker upvalue로 승격) 오용하면 AGENTS.md 불변식 위반이다.

---

## Alternatives

### 2단계 모델 (staged → activate)

`PUT /api/v1/policies` → staged 저장만, 별도 `POST /api/v1/policies/activate` → 활성화.

**기각 이유:**

- 대부분의 운영 시나리오에서 저장과 활성화를 분리할 이유가 없다.
- staged 상태 관리(staged blob 보관, staged → active 전환 로직) 복잡도가 높다.
- 검토(staged) → 활성화 워크플로우가 필요한 경우, 클라이언트가 GET → 검토 → PUT으로 처리할 수 있다.
- Admin API의 단순성을 우선한다.

### queuing 모델

선착순으로 reload 요청을 큐에 쌓아 순차 처리.

**기각 이유:**

- shared dict 기반 큐 구현 복잡도가 높다.
- 운영 환경에서 동시 reload가 정상 패턴이 아니다 (설계 시 가정: 단독 관리자 조작).
- 클라이언트가 409를 받고 재시도하는 방식이 더 단순하고 명확하다.

### last-writer-wins 모델

두 번째 reload가 첫 번째 reload를 덮어씀.

**기각 이유:**

- 두 요청의 정책 내용이 다를 경우 예측 불가능한 결과를 만든다.
- 첫 번째 reload가 [7] audit write까지 완료한 상태에서 덮어써지면 감사 이력이 불일치한다.
- fail-closed 원칙에 위배된다.

---

## Consequences

### 긍정적 결과

- **단순한 API**: 1-step 모델로 클라이언트 구현이 간단하다.
- **결정론적 동시성**: rejection 모델로 동시 reload의 결과가 예측 가능하다.
- **요청 일관성**: ngx.ctx 스냅샷으로 요청 처리 도중 정책이 바뀌지 않음이 보장된다.
- **로그 정확성**: 각 로그 레코드의 `active_version` 필드가 해당 요청에 실제 적용된 버전을 정확히 반영한다.

### 부정적 결과

- **staged 검토 불가**: 활성화 전 staged 상태에서 정책을 검토하는 워크플로우를 API 레벨에서 지원하지 않는다.
  클라이언트가 직접 GET → 검토 → PUT 흐름을 구현해야 한다.
- **409 재시도 부담**: 동시 reload 요청을 보내는 클라이언트는 retry logic이 필요하다.
- **5초 TTL 한계**: reload가 5초를 초과하면 lock이 만료되어 두 번째 reload가 진입할 수 있다.
  매우 큰 정책 파일(edge case)에서 발생 가능하다 — 모니터링 필요.
- **reload_lock race window 시 일시적 정책 불일치**: §2의 비원자적 lock race window에서
  HTTP active_version과 Stream active_version이 서로 다른 버전을 가리키는 상태가 일시적으로 발생할 수 있다
  (Known Limitation §2 참조).

### 향후 고려

- 정책 규모가 커져 reload가 5초 이상 걸리는 경우 TTL 상향 조정 또는 적응형 TTL ADR 추가
- 관리자 다수 운영 환경에서 staged 검토 워크플로우 요구가 생기면 별도 ADR로 2단계 모델 추가 검토

---

## 관련 문서

- [ADR-002](./ADR-002-policy-evaluation-conflict-detection.md) — 충돌 감지 (reload 파이프라인 [4]단계)
- [ADR-003](./ADR-003-policy-storage-hot-reload.md) — Hot Reload 7단계, versioned keyspace, Partial commit 규칙
- [spec/policy-engine.md](../../spec/policy-engine.md) — 정책 엔진 상세 스펙
- [spec/admin-api.md](../../spec/admin-api.md) — PUT /api/v1/policies, POST /api/v1/policies/reload 엔드포인트 스펙
