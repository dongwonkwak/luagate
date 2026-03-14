---
name: implement-issue
description: "이슈 전체 워크플로우. 이슈 번호 → 에이전트 순차 호출 → 리뷰 대기 → 완료 처리."
trigger: "implement-issue | 이슈 구현 | DON-\\d+ 진행 | make implement"
---

# implement-issue Skill

## 역할

이슈 번호를 받아 전체 구현 워크플로우를 orchestrate한다.

## 전제 조건

- 이슈 번호 (DON-XXX) 필수
- Linear MCP 접근 가능

## 실행 절차

### 1. 이슈 분석 (시작)

```
get_issue(DON-XXX) → 상세 조회
  - 제목, 설명, Acceptance Criteria 추출
  - labels, dependencies 확인
  - 2회 리뷰 조건 판단
```

### 2. 실행 계획 보고 (사람 확인)

```markdown
## 실행 계획: DON-XXX

**리뷰 계획**: 1회 | 2회 (사유: <조건>)
**에이전트 순서**: architect → implementer → tester → [review] → security-reviewer

진행할까요? (y/n)
```

### 3. 이슈 상태 → In Progress

`linear-update` 스킬 실행: 상태 변경 + 시작 코멘트

### 4. 에이전트 순차 호출

#### 1회 리뷰 플로우

```
architect (필요 시: 설계 판단 필요 여부 확인)
  → implementer (코드 + 문서)
  → tester (테스트 작성 + make test)
  → request-codex-review (코드 리뷰)
  → [대기: 사람이 Codex CLI 실행]
  → 피드백 반영 (implementer/tester 재호출)
  → security-reviewer
  → 완료 처리
```

#### 2회 리뷰 플로우

```
architect (설계 산출물 생성)
  → request-codex-review (설계 리뷰)
  → [대기: 사람이 Codex CLI 실행]
  → 설계 피드백 반영 (architect 재호출)
  → implementer
  → tester
  → request-codex-review (코드 리뷰)
  → [대기: 사람이 Codex CLI 실행]
  → 코드 피드백 반영
  → security-reviewer
  → 완료 처리
```

### 5. 완료 처리

```
linear-update 스킬:
  - 이슈 상태 → Done
  - 코멘트: 구현 파일 경로 + 리뷰 결과 요약

sync-spec 스킬 (스펙 변경 시):
  - docs/spec/ 변경분 → Linear 문서 동기화

PROGRESS.md 갱신
```

## 에러 정책

| 에러 | 정책 |
|------|------|
| 빌드/테스트 실패 | 자체 수정 재시도 (최대 3회) |
| 스펙 모호/충돌 | 즉시 중단 → PROGRESS.md + Linear 코멘트 |
| 의존성 미충족 | 시작 안 함 → 대체 이슈 제안 |
| 컨텍스트 부족 | 자율 탐색 후 재시도 (1회) |

## 완료 후 체크리스트

- [ ] 코드 구현 완료
- [ ] 테스트 추가/통과 (`make test`)
- [ ] 관련 spec/ADR 준수 (AGENTS.md 불변식)
- [ ] 문서 갱신 (same-PR 규칙)
- [ ] Linear 코멘트: 구현 파일 경로 포인터
- [ ] PROGRESS.md append
