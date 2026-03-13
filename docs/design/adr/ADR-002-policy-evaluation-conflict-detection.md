# ADR-002: 정책 평가 규칙 + 충돌 감지 기준

| 항목 | 내용 |
|------|------|
| **Status** | Accepted |
| **Date** | 2026-03-13 |
| **Deciders** | LuaGate Architects |
| **Issue** | [DON-86](https://linear.app/dongwon/issue/DON-86) |
| **Depends on** | [ADR-001](./ADR-001-execution-shared-state-model.md) |

---

## Status

**Accepted** — Phase 0-A에서 고정.

---

## Context

LuaGate는 YAML로 정의된 정책 규칙을 평가하여 요청을 허용(allow)/차단(deny)한다.
복수의 규칙이 동일 요청에 매칭될 수 있으며, 다음 문제를 해결해야 한다:

1. **우선순위 결정**: 여러 규칙 중 어느 것을 먼저 적용하는가?
2. **기본 정책**: 매칭 규칙이 없을 때 어떻게 처리하는가?
3. **충돌 감지**: 상반된 행동을 갖는 규칙들을 어떻게 탐지하는가?
4. **shadowed rule**: 넓은 범위의 규칙이 좁은 범위를 가리는 상황을 탐지하는가?
5. **충돌 처리 방침**: 충돌 발견 시 차단할 것인가, 경고할 것인가?

---

## Decision

### §3.1 정책 평가 규칙

**결정 사항:**

1. **priority 숫자 기반 우선순위** — 낮은 숫자 = 높은 우선순위.
   예: priority=1이 priority=10보다 먼저 평가.

2. **first match wins** — 규칙 목록을 priority 오름차순으로 정렬 후,
   가장 먼저 매칭되는 규칙의 action(allow/deny)을 즉시 적용. 이후 규칙은 평가하지 않음.

3. **동률(tie) 처리** — 동일 priority인 규칙이 존재할 경우:
   - 정책 로드 시점에 경고(WARN) 로그 발생
   - 평가 순서: YAML 파일 내 선언 순서(declaration order)를 따름
   - 런타임 에러로 처리하지 않음

4. **기본 정책(default)** — 모든 규칙에 매칭되지 않는 요청에 적용.
   설정 키: `global.default_action` (값: `allow` | `deny`, 기본값: `deny`)

**평가 흐름:**

```
요청 수신
    │
    ▼
priority 오름차순 정렬된 규칙 목록 순회
    │
    ├─ 규칙 N 매칭? ──Yes──▶ action 적용 (allow/deny) → 종료
    │       │
    │      No
    │       │
    └───────┘ (다음 규칙)
    │
    ▼ (매칭 규칙 없음)
global.default_action 적용
```

**정책 예시 — 정상 케이스:**

```yaml
global:
  default_action: deny

rules:
  - id: allow-health
    scope:
      path: /health
      method: GET
    priority: 1
    action: allow

  - id: deny-admin
    scope:
      path: /admin/*
    priority: 5
    action: deny

  - id: allow-api
    scope:
      path: /api/v1/*
      src_ip_cidr: 10.0.0.0/8
    priority: 10
    action: allow
```

→ `GET /health`: allow (규칙 `allow-health`)
→ `POST /admin/config`: deny (규칙 `deny-admin`)
→ `GET /api/v1/users` from 10.0.1.5: allow (규칙 `allow-api`)
→ `GET /api/v1/users` from 1.2.3.4: deny (기본 정책)

### §3.2 충돌 감지 기준

**충돌(conflict) 정의:**

동일 scope + 동일 priority + 상반 action을 가진 규칙이 2개 이상 존재하는 경우.

```yaml
# 충돌 케이스 예시
rules:
  - id: rule-a
    scope:
      path: /api/v1/*
    priority: 5
    action: allow          # ← 동일 scope, 동일 priority

  - id: rule-b
    scope:
      path: /api/v1/*
    priority: 5
    action: deny           # ← 상반 action → CONFLICT WARN
```

**shadowed rule(음영 규칙) 정의:**

넓은 scope + 높은 priority(낮은 숫자)가 좁은 scope를 완전히 포함하여,
좁은 scope 규칙이 절대 매칭될 수 없는 상태.

```yaml
# shadowed rule 예시
rules:
  - id: broad-deny
    scope:
      path: /*              # 넓은 scope
    priority: 1             # 높은 우선순위 (낮은 숫자)
    action: deny

  - id: narrow-allow
    scope:
      path: /health         # 좁은 scope ← shadowed
    priority: 10
    action: allow           # 이 규칙은 절대 실행되지 않음 → SHADOW WARN
```

**충돌/음영 감지 시점:** 정책 로드 시(파일 파싱 완료 후, 메모리 적용 전)

**처리 방침:**
- 충돌/음영 감지 → **경고(WARN) 로그만 발생**, 로드는 계속 진행
- 차단(abort)하지 않음 — 운영 중 정책 업데이트가 잠시 불완전할 수 있는 현실 반영
- 감사 로그에도 충돌 정보 기록
- 관리 API(`GET /api/v1/policies/status`)에서 충돌 목록 조회 가능

---

## Consequences

### 긍정적 결과

- **예측 가능성**: first-match-wins + priority 순서가 명확하여 동작 예측이 쉬움
- **운영 안전성**: 충돌 시 차단 대신 경고 → 정책 업데이트 중 서비스 중단 없음
- **관찰 가능성**: 충돌/음영 정보가 로그와 관리 API에 노출되어 운영자가 인지 가능

### 부정적 결과

- **경고 무시 위험**: 차단하지 않으므로 운영자가 충돌 경고를 방치할 수 있음.
  → 모니터링 알림(충돌 카운터 > 0) 권장
- **동률 규칙의 비결정성**: declaration order는 YAML 편집 순서에 의존.
  CI에서 충돌/동률 검증 단계 추가 권장

### 향후 고려

- 정책 검증 CLI 도구(`luagate policy lint`) 개발 시 이 ADR의 규칙을 구현 기준으로 사용
- strict mode(충돌 시 로드 거부) 옵션이 필요하면 별도 ADR로 추가

---

## 관련 문서

- [ADR-001](./ADR-001-execution-shared-state-model.md) — shared dict 기반 정책 저장
- [ADR-003](./ADR-003-policy-storage-hot-reload.md) — 정책 저장소 + Hot Reload (충돌 감지가 reload 과정에 포함)
- [spec/policy-engine.md](../../spec/policy-engine.md) — 정책 엔진 상세 스펙
