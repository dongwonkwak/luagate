# Documentation Strategy Specification

## 1. 개요

LuaGate 문서화 전략은 세 가지 원칙을 따른다:

1. **코드와 동기화**: 문서는 구현과 함께 PR에서 검토되고 업데이트된다 (same-PR 규칙)
2. **ADR로 결정 추적**: 중요 아키텍처 결정은 ADR로 기록한다
3. **단일 진실의 원천**: 설계는 `docs/spec/`에, 결정은 `docs/design/adr/`에

### Source of Truth 우선순위

```
git (로컬 파일) > Linear 문서 > PROGRESS.md 기록
```

git과 Linear 문서가 충돌하면 **git을 기준**으로 하고 Linear를 재동기화한다.
`sync-spec` 스킬로 Linear 문서를 `docs/spec/` 변경 후 자동 반영한다.

## 2. 신규 기여자 읽기 순서

```
README.md
  → AGENTS.md (코딩 컨벤션, 불변식)
  → docs/spec/architecture.md (전체 구조)
  → docs/design/adr/ (결정 배경)
  → 관련 spec (작업 영역별)
  → CLAUDE.md (Claude Code 워크플로우)
```

## 3. 문서 계층 구조

```
docs/
├── design/
│   └── adr/                       # Architecture Decision Records
│       ├── ADR-001-*.md            # Phase 0-A 고정 결정
│       ├── ADR-002-*.md
│       ├── ADR-003-*.md
│       └── ADR-004-*.md
└── spec/                           # 기술 스펙 문서 (Source of Truth)
    ├── architecture.md             # 전체 아키텍처
    ├── http-pipeline.md            # HTTP 파이프라인
    ├── stream-pipeline.md          # TCP 스트림 파이프라인
    ├── policy-engine.md            # 정책 엔진
    ├── security-scanner.md         # 보안 스캐너
    ├── rust-ffi-modules.md          # Rust FFI 모듈
    ├── admin-api.md                # Admin API (canonical reference)
    ├── log-schema.md               # 로그 스키마
    ├── test-strategy.md            # 테스트 전략
    └── doc-strategy.md             # 문서화 전략 (이 파일)
```

> **Admin API canonical source**: `docs/spec/admin-api.md`가 API 명세의 단일 진실의 원천.
> 개발 가이드나 튜토리얼은 별도 `docs/guides/` 아래에 작성하고 spec을 참조한다.

## 4. 문서 변경 유형별 의무 업데이트 매트릭스

| 변경 유형 | 필수 업데이트 문서 | sync-spec 필요 |
|----------|-----------------|--------------|
| HTTP 파이프라인 변경 | `http-pipeline.md` | Yes |
| Stream 파이프라인 변경 | `stream-pipeline.md` | Yes |
| 정책 평가 로직 변경 | `policy-engine.md` | Yes |
| Admin API 엔드포인트 추가/변경 | `admin-api.md` | Yes |
| 로그 필드 추가/제거 | `log-schema.md` | Yes |
| FFI 함수 추가/변경 | `rust-ffi-modules.md` | Yes |
| 보안 스캐너 변경 | `security-scanner.md` | Yes |
| 아키텍처 결정 (새 패턴) | ADR 작성 + 관련 spec | Yes |
| 테스트 전략 변경 | `test-strategy.md` | Yes |
| 문서 전략 변경 | `doc-strategy.md` | Yes |

## 5. ADR 작성 가이드

### 5.1 ADR 작성 시점

다음 상황에서 ADR을 작성한다:

- 여러 구현 방식이 존재하고 하나를 선택하는 경우
- 이전 결정을 번복(supersede)하는 경우
- 중요한 트레이드오프가 있는 경우
- 미래 팀원이 "왜 이렇게 했지?"라고 물을 수 있는 경우

스펙 문서의 `<!-- ADR 필요 -->` 마커를 통해 추적된다.

### 5.2 ADR 포맷

```markdown
# ADR-NNN: 제목

| 항목 | 내용 |
|------|------|
| **Status** | Proposed \| Accepted \| Deprecated \| Superseded by ADR-NNN |
| **Date** | YYYY-MM-DD |
| **Deciders** | 관련자 |
| **Issue** | Linear 이슈 링크 |
| **Depends on** | ADR-NNN (해당 없으면 생략) |
| **Supersedes** | ADR-NNN (해당 없으면 생략) |

## Status
현재 상태 설명.

## Context
왜 이 결정이 필요한가? 배경과 제약 조건.

## Decision
무엇을 결정했는가? 구체적이고 명확하게.

## Consequences
이 결정의 결과는? 긍정적/부정적 결과 모두 포함.

## 관련 문서
연관 ADR, 스펙 문서 링크.
```

### 5.3 ADR 번호 체계

- `ADR-001` ~ `ADR-004`: Phase 0-A 고정 결정 (완료)
- `ADR-005` ~: 이후 구현 이슈에서 architect 역할이 필요 시 생성

### 5.4 ADR 상태 전이

```
Proposed → Accepted → Deprecated
                   ↓
              Superseded by ADR-NNN
```

ADR을 supersede할 때는:
1. 기존 ADR의 Status를 `Superseded by ADR-NNN`으로 업데이트
2. 새 ADR에 `Supersedes: ADR-NNN` 항목 추가

## 6. 스펙 문서 작성 가이드

### 6.1 ADR 참조 규칙

스펙 문서는 ADR 내용을 중복 기재하지 않고 참조 링크를 사용한다:

```markdown
> **ADR 참조**: [ADR-001 실행/상태 공유 모델](../design/adr/ADR-001-*.md)
```

### 6.2 ADR 필요 마커

향후 ADR이 필요한 구간에 마커를 삽입한다:

```markdown
<!-- ADR 필요 -->
> **TODO**: <기능 설명> 구현 시 ADR 필요
```

이 마커는 구현 이슈 생성 시 참조하여 architect 역할 호출 여부를 결정한다.

### 6.3 코드 예시 포함 기준

스펙 문서의 코드 예시는 다음 목적으로만 포함:
- 인터페이스/API 시그니처 명확화
- 데이터 형식/스키마 예시
- 설계 의도 설명 (의사 코드 수준)

## 7. Linear vs PROGRESS.md 분업

| 항목 | Linear | PROGRESS.md |
|------|--------|-------------|
| 목적 | 상태 추적, 이슈 관리 | 시간순 구현 일지 (append-only) |
| 내용 | 완료 코멘트 (산출물 요약 + 파일 경로) | 날짜/이슈/산출물/비고 |
| 업데이트 시점 | 이슈 Done 전환 시 | 각 이슈 완료 시 append |
| 충돌 시 | git 파일 기준 | git 파일 기준 |

### PROGRESS.md 최소 템플릿

```
| YYYY-MM-DD | DON-XX | <제목> | <산출물 파일 경로> | <비고> |
```

필드:
- **날짜**: ISO 8601 (`YYYY-MM-DD`)
- **이슈**: Linear 이슈 ID
- **제목**: 이슈 제목 요약
- **산출물**: 생성/수정된 주요 파일 경로
- **비고**: 결정 사항, 블로커, 테스트 결과 등

## 8. 문서화 사이클

### 8.1 기능 구현 사이클

```
1. Linear 이슈 생성 (스펙 참조 포함)
      │
      ▼
2. 스펙 문서의 <!-- ADR 필요 --> 마커 확인
   └─ 필요 시 → architect 역할로 ADR 초안 작성
      │
      ▼
3. 코드 구현
      │
      ▼
4. 스펙 문서 업데이트 (구현과 동기화) → sync-spec 스킬
      │
      ▼
5. PR 리뷰: 코드 + 스펙 + ADR 동시 검토
      │
      ▼
6. Linear 이슈 Done, ADR 상태 Accepted
```

### 8.2 스펙 변경 정책

- **하위 호환 변경** (필드 추가, 설명 수정): 스펙 문서 직접 업데이트
- **파괴적 변경** (필드 제거, 동작 변경): 신규 ADR 작성 후 스펙 업데이트

## 9. 문서 검토 기준

PR에서 다음을 확인한다:

| 체크 | 기준 |
|------|------|
| ADR 참조 | 스펙 변경이 기존 ADR과 일치하는가? |
| 마커 처리 | `<!-- ADR 필요 -->` 마커가 처리되었거나 이슈로 등록되었는가? |
| 코드 동기화 | 스펙의 인터페이스가 실제 코드와 일치하는가? |
| 링크 유효성 | 상호 참조 링크가 깨지지 않았는가? |
| sync-spec | Linear 문서가 spec 변경을 반영했는가? |

## 10. 현재 ADR 필요 목록

| 위치 | 기능 | 우선순위 |
|------|------|----------|
| `architecture.md` | 멀티 인스턴스 정책 동기화 | Low |
| `architecture.md` | FFI 타임아웃 강제 메커니즘 | Medium |
| `http-pipeline.md` | FFI 타임아웃 강제 메커니즘 | Medium |
| `security-scanner.md` | threat_score 기반 자동 차단 scope | Medium |
| `security-scanner.md` | 패턴 핫 업데이트 | Low |
| `stream-pipeline.md` | TLS 터미네이션 지원 | Low |
| `test-strategy.md` | 카오스 엔지니어링 테스트 전략 | Medium |
| `adr/` + `log-schema.md` | metrics-cardinality-and-export | High |
| `adr/` + `log-schema.md` | log-redaction-and-retention | High |

## 11. 의존성

- [docs/design/adr/](../design/adr/) — ADR 디렉토리
- [spec/architecture.md](./architecture.md) — 전체 아키텍처
