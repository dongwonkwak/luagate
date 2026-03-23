# ADR 인덱스

> LuaGate 아키텍처 결정 기록 (Architecture Decision Records)

## ADR 목록

| ADR | 제목 | 상태 | 날짜 | 핵심 결정 |
|-----|------|------|------|----------|
| [ADR-001](./ADR-001-execution-shared-state-model.md) | 실행/상태 공유 모델 | Accepted | 2026-03-13 | OpenResty workers + shared dict mmap |
| [ADR-002](./ADR-002-policy-evaluation-conflict-detection.md) | 정책 평가 규칙 + 충돌 감지 | Accepted | 2026-03-13 | priority first-match-wins |
| [ADR-003](./ADR-003-policy-storage-hot-reload.md) | 정책 저장소 + Hot Reload | Accepted | 2026-03-13 | YAML file-backed + pointer swap |
| [ADR-004](./ADR-004-log-metrics-admin-security.md) | 로그/메트릭 + 관리면 보안 | Accepted | 2026-03-13 | 구조화 JSON 로그 + Bearer token |
| [ADR-005](./ADR-005-policy-activation-concurrency.md) | 정책 활성화 모델 + 동시성 제어 | Accepted | 2026-03-16 | 저장+활성화 1-step 파이프라인 |
| [ADR-006](./ADR-006-metrics-cardinality-export-model.md) | 메트릭 Cardinality 제어 | Accepted | 2026-03-15 | low-cardinality labels only |
| [ADR-007](./ADR-007-log-redaction-and-retention.md) | 로그 Redaction + 보존/파기 | Accepted | 2026-03-15 | /16 IP 마스킹 + 필드별 규칙 |
| [ADR-008](./ADR-008-multi-instance-policy-sync.md) | 멀티 인스턴스 정책 동기화 | Accepted | 2026-03-18 | CI/CD push + /health 검증 |
| [ADR-009](./ADR-009-ffi-timeout-enforcement.md) | FFI 타임아웃 강제 | Accepted | 2026-03-18 | detached thread + watchdog |
| [ADR-010](./ADR-010-opentelemetry-tracing.md) | OpenTelemetry 분산 트레이싱 도입 | Accepted | 2026-03-20 | 커스텀 OTLP/HTTP 모듈 + head-based 샘플링 |
| [ADR-011](./ADR-011-mcp-server.md) | MCP 서버 설계 | Accepted | 2026-03-19 | Admin API → MCP tool 노출 |
| [ADR-012](./ADR-012-http-data-plane-rate-limiting.md) | HTTP Data Plane Rate Limiting | Accepted | 2026-03-23 | Sliding Window Counter + 정책 규칙별 rate_limit 필드 |
| [ADR-014](./ADR-014-scanner-pattern-hot-update.md) | Scanner Pattern Hot Update | Accepted | 2026-03-23 | RwLock + 5단계 reload 파이프라인 + Admin API |

## 의존성 관계

```
ADR-001 (실행 모델)
├── ADR-002 (정책 평가) → ADR-003 (저장/Reload) → ADR-005 (활성화/동시성)
├── ADR-004 (로그/메트릭/보안) → ADR-006 (메트릭 Cardinality; +ADR-001)
│                              → ADR-007 (로그 Redaction)
│                              → ADR-010 (OpenTelemetry 트레이싱; +ADR-001)
├── ADR-008 (멀티 인스턴스; +ADR-003)
├── ADR-009 (FFI 타임아웃; +ADR-003)
├── ADR-011 (MCP 서버; ADR-004 + ADR-005)
├── ADR-012 (HTTP Rate Limiting; +ADR-001 + ADR-003 + ADR-006)
└── ADR-014 (Scanner 핫 업데이트; +ADR-003 + ADR-009)
```

> 각 ADR의 정확한 `Depends on`은 해당 문서의 front matter를 참조하세요.

## 연관 스펙 문서 매핑

| ADR | 영향받는 스펙 |
|-----|-------------|
| ADR-001 | [architecture.md](../../spec/architecture.md) |
| ADR-002 | [policy-engine.md](../../spec/policy-engine.md) |
| ADR-003 | [policy-engine.md](../../spec/policy-engine.md), [admin-api.md](../../spec/admin-api.md) |
| ADR-004 | [log-schema.md](../../spec/log-schema.md), [admin-api.md](../../spec/admin-api.md) |
| ADR-005 | [admin-api.md](../../spec/admin-api.md), [http-pipeline.md](../../spec/http-pipeline.md), [stream-pipeline.md](../../spec/stream-pipeline.md) |
| ADR-006 | [admin-api.md](../../spec/admin-api.md), [log-schema.md](../../spec/log-schema.md), [architecture.md](../../spec/architecture.md) |
| ADR-007 | [log-schema.md](../../spec/log-schema.md) |
| ADR-008 | [architecture.md](../../spec/architecture.md), [admin-api.md](../../spec/admin-api.md), [log-schema.md](../../spec/log-schema.md) |
| ADR-009 | [rust-ffi-modules.md](../../spec/rust-ffi-modules.md), [http-pipeline.md](../../spec/http-pipeline.md), [stream-pipeline.md](../../spec/stream-pipeline.md), [architecture.md](../../spec/architecture.md) |
| ADR-010 | [log-schema.md](../../spec/log-schema.md), [http-pipeline.md](../../spec/http-pipeline.md) |
| ADR-011 | [admin-api.md](../../spec/admin-api.md), [log-schema.md](../../spec/log-schema.md) |
| ADR-012 | [http-pipeline.md](../../spec/http-pipeline.md), [policy-engine.md](../../spec/policy-engine.md) |
| ADR-014 | [security-scanner.md](../../spec/security-scanner.md), [rust-ffi-modules.md](../../spec/rust-ffi-modules.md), [admin-api.md](../../spec/admin-api.md) |

## ADR 작성 가이드

### 언제 ADR을 작성하는가

- 2개 이상의 설계 대안이 존재할 때
- 기존 ADR 범위를 벗어나는 새 패턴 도입 시
- 코드에 `<!-- ADR 필요 -->` 마커가 있을 때

### 상태 정의

| 상태 | 의미 |
|------|------|
| **Proposed** | 초안 작성, 리뷰 대기 |
| **Accepted** | 승인됨, 구현 진행 |
| **Deprecated** | 더 이상 유효하지 않음 (새 ADR로 대체 전) |
| **Superseded** | 다른 ADR에 의해 대체됨 |

### 포맷

```markdown
# ADR-NNN: 제목

| 항목 | 내용 |
|------|------|
| **Status** | Proposed / Accepted / Deprecated / Superseded |
| **Date** | YYYY-MM-DD |
| **Deciders** | LuaGate Architects |
| **Issue** | [DON-XX](link) |
| **Depends on** | [ADR-NNN](link) |

## Status
## Context
## Decision
## Consequences
```
