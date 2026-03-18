# ADR-008: 멀티 인스턴스 정책 동기화 모델

| 항목 | 내용 |
|------|------|
| **Status** | Accepted |
| **Date** | 2026-03-18 |
| **Deciders** | LuaGate Architects |
| **Issue** | [DON-154](https://linear.app/dongwon/issue/DON-154) |
| **Depends on** | [ADR-001](./ADR-001-execution-shared-state-model.md), [ADR-003](./ADR-003-policy-storage-hot-reload.md) |

---

## Status

**Accepted** — 멀티 인스턴스 환경에서의 정책 동기화 전략 확정.

---

## Context

ADR-001은 LuaGate를 "단일 인스턴스 = 1 배포 단위"로 정의하고, 인스턴스 간 상태 동기화는 범위 밖으로 남겨두었다.
ADR-003은 정책의 canonical source를 파일시스템 YAML로 확정하고, 단일 인스턴스 내 Hot Reload 시맨틱스를 정의했다.

프로덕션 환경에서는 로드밸런서 뒤에 복수 LuaGate 인스턴스가 배치된다 (architecture.md §9).
이때 다음 문제가 발생한다:

1. **정책 일관성**: 인스턴스 A는 새 정책, 인스턴스 B는 구 정책을 적용하는 split-brain 상황
2. **동기화 지연**: 정책 변경이 모든 인스턴스에 반영되기까지의 시간 차이
3. **롤백 복잡성**: 일부 인스턴스만 새 정책을 적용한 상태에서 문제 발생 시 복구 전략
4. **운영 복잡도**: 동기화 인프라 추가에 따른 운영 부담 대비 이점

### 현재 상태

현재 멀티 인스턴스 정책 배포는 CI/CD가 전담한다:
- CI/CD 파이프라인이 모든 인스턴스에 동일한 `policies.yaml`을 배포
- 배포 후 각 인스턴스에서 `POST /api/v1/policies/reload` 호출 또는 HUP 시그널 전송
- 배포 순서에 따라 수초~수분의 정책 버전 불일치 발생 가능

---

## Decision

### §8.1 동기화 전략: CI/CD 주도 배포 (현재 방식 유지 + 가드레일 강화)

**LuaGate는 자체 인스턴스 간 동기화 메커니즘을 도입하지 않는다.**
정책 동기화의 책임은 외부 CI/CD 파이프라인에 유지하되, 운영 안전성을 위한 가드레일을 추가한다.

### §8.2 가드레일: 정책 버전 헬스체크 연동

각 인스턴스의 `/health` 엔드포인트에 정책 버전 정보를 포함한다:

```json
{
  "status": "healthy",
  "policy_version": "a3f2c1d4e5b6...",
  "policy_loaded_at": "2026-03-18T10:30:00Z"
}
```

외부 모니터링 시스템(Prometheus, 로드밸런서 헬스체크)이 인스턴스 간 정책 버전 불일치를 감지할 수 있다.

### §8.3 가드레일: 배포 파이프라인 권장 패턴

CI/CD 파이프라인은 다음 순서를 따를 것을 권장한다:

```text
[1] policies.yaml 파일을 모든 인스턴스에 배포 (rsync, ConfigMap, S3 등)
[2] 각 인스턴스에 POST /api/v1/policies/reload 호출 (병렬)
[3] 각 인스턴스의 GET /health 응답에서 policy_version 확인
[4] 모든 인스턴스가 동일 버전 → 배포 완료
[5] 일부 인스턴스 불일치 → 재시도 또는 알림
```

### §8.4 일관성 모델: Eventually Consistent

- 인스턴스 간 정책 일관성은 **eventually consistent**로 정의한다.
- 배포 과정에서 일시적 버전 불일치는 허용한다.
- 불일치 허용 시간은 배포 파이프라인의 SLA로 정의하며, LuaGate 자체가 강제하지 않는다.
- 각 요청 로그에 `policy_version` 필드가 포함되므로 (ADR-004), 불일치 기간 동안 어떤 정책으로 처리되었는지 감사 추적이 가능하다.

### §8.5 롤백 전략

정책 롤백은 CI/CD 파이프라인이 이전 버전의 `policies.yaml`을 재배포하는 방식으로 수행한다:

```text
[1] 이전 정책 파일을 모든 인스턴스에 배포 (git revert 또는 artifact 저장소에서 복원)
[2] 각 인스턴스에 POST /api/v1/policies/reload 호출
[3] GET /health로 롤백 완료 확인
```

- LuaGate 자체에는 "이전 N개 버전 보관" 기능을 두지 않는다.
- shared dict의 versioned keyspace에 이전 버전 blob이 남아 있을 수 있으나, 이를 롤백 메커니즘으로 의존하지 않는다 (ADR-003 §3.5: LKG는 자동 롤백 메커니즘이 아님).

---

## Rationale

### 왜 자체 동기화를 도입하지 않는가

1. **복잡도 대비 이점 부족**: Redis/etcd 등 외부 KV 스토어 도입은 LuaGate의 핵심 가치(단순한 단일 바이너리 게이트웨이)를 훼손한다. 정책 변경 빈도는 일반적으로 낮으므로(일 수회~수십회) CI/CD 배포로 충분하다.

2. **단일 진실의 원천 유지**: ADR-003에서 확정한 "YAML 파일이 canonical source" 원칙을 유지한다. 자체 동기화 도입 시 "누가 canonical source인가" 문제가 발생한다 (파일 vs KV 스토어 vs 마스터 인스턴스).

3. **장애 도메인 격리**: 인스턴스 간 결합이 없으므로, 한 인스턴스의 장애가 다른 인스턴스로 전파되지 않는다. 자체 동기화 도입 시 동기화 인프라 장애가 전체 클러스터에 영향을 줄 수 있다.

4. **운영 도구 재사용**: 대부분의 조직이 이미 CI/CD 파이프라인(ArgoCD, Flux, Ansible 등)을 보유하고 있으며, 정책 배포를 기존 도구에 위임하는 것이 운영 비용을 낮춘다.

---

## Alternatives

### 대안 1: Redis Pub/Sub 기반 실시간 동기화

마스터 인스턴스가 정책 변경을 Redis에 publish하고, 다른 인스턴스가 subscribe하여 실시간 반영.

**기각 이유:**
- Redis 의존성 추가 → 단일 바이너리 배포 원칙 위배
- Redis 장애 시 정책 동기화 불가 → 장애 도메인 확대
- 마스터 선출 로직 필요 → 구현 복잡도 증가
- 정책 변경 빈도 대비 과도한 인프라

### 대안 2: etcd watch 기반 동기화

etcd에 정책을 저장하고, 각 인스턴스가 watch로 변경을 감지.

**기각 이유:**
- etcd 클러스터 운영 부담 (3노드 이상 권장)
- YAML 파일 canonical source 원칙과 충돌 (etcd가 새 canonical source가 됨)
- 소규모 배포 환경에서 과도한 인프라 요구

### 대안 3: 공유 파일시스템 (NFS/EFS) + inotify

모든 인스턴스가 동일한 NFS/EFS 마운트에서 `policies.yaml`을 읽고, `inotify`로 변경 감지.

**기각 이유:**
- NFS/EFS 장애가 모든 인스턴스에 전파
- `inotify`가 NFS에서 안정적으로 동작하지 않는 환경 존재
- 파일 잠금(locking) 문제로 atomic write 보장 어려움
- 클라우드 환경에서 EFS 지연이 수백 ms에 달할 수 있음

### 대안 4: Gossip 프로토콜 기반 P2P 동기화

인스턴스 간 gossip 프로토콜로 정책 버전을 교환하고, 최신 버전을 가진 인스턴스에서 pull.

**기각 이유:**
- 구현 복잡도가 매우 높음 (멤버십 관리, 버전 벡터 등)
- eventually consistent 보장만 가능하며 수렴 시간 예측 어려움
- LuaGate의 단순성 원칙과 정면으로 충돌

---

## Consequences

### 긍정적 결과

- **단순성 유지**: LuaGate에 외부 의존성이나 인스턴스 간 통신 로직을 추가하지 않음
- **장애 격리**: 각 인스턴스가 완전히 독립적으로 동작하므로 장애 전파 없음
- **운영 친화**: 기존 CI/CD 도구와 자연스럽게 통합
- **감사 추적**: 요청별 `policy_version` 로그로 불일치 기간 추적 가능
- **YAML canonical source 원칙 유지**: ADR-003과 완전한 정합성

### 부정적 결과

- **배포 중 일시적 불일치**: 동일 시점에 다른 인스턴스가 다른 정책 버전을 적용할 수 있음. 보안 정책의 경우 새 차단 규칙이 일부 인스턴스에만 적용되는 시간 창(window) 발생
- **CI/CD 의존**: 정책 동기화의 신뢰성이 CI/CD 파이프라인의 안정성에 의존
- **수동 확인 필요**: 배포 후 모든 인스턴스의 정책 버전 일치 여부를 외부에서 확인해야 함
- **실시간 정책 변경 불가**: Admin API를 통한 정책 변경이 해당 인스턴스에만 적용됨. 클러스터 전체 반영을 위해서는 canonical source(YAML 파일)를 수정하고 CI/CD 재배포 필요

### 향후 고려

- 정책 변경 빈도가 높아지거나 불일치 허용 시간이 매우 짧아야 하는 요구사항이 발생하면, 이 ADR을 supersede하는 새 ADR에서 자체 동기화 메커니즘 도입을 검토한다.
- `/health` 엔드포인트의 `policy_version` 필드 구현은 별도 이슈에서 다룬다.
- Prometheus 기반 정책 버전 불일치 알림 규칙(`luagate_policy_version` 메트릭)은 운영 가이드에서 다룬다.

---

## Dependencies

- [ADR-001](./ADR-001-execution-shared-state-model.md) — 단일 인스턴스 실행 모델, 수평 확장 전략
- [ADR-003](./ADR-003-policy-storage-hot-reload.md) — YAML canonical source, Hot Reload 시맨틱스, LKG
- [ADR-004](./ADR-004-log-metrics-admin-security.md) — 요청 로그 `policy_version` 필드
- [spec/architecture.md](../../spec/architecture.md) — §9 수평 확장 전략
