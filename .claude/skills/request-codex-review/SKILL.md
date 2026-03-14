---
name: request-codex-review
description: "Codex CLI 리뷰 프롬프트 파일 생성 + PROGRESS.md 대기 상태 기록 + 사람에게 실행 명령 안내."
trigger: "request-codex-review | codex 리뷰 | 리뷰 요청"
---

# request-codex-review Skill

## 역할

Codex CLI 리뷰를 위한 프롬프트 파일을 생성하고, 사람에게 실행 명령을 안내한다.

## 리뷰 유형

- `code` — 코드 구현 리뷰 (implementer + tester 완료 후)
- `design` — 설계 리뷰 (architect 완료 후, 2회 리뷰 이슈만)

## 실행 절차

### 1. 변경 파일 수집

```bash
git diff main...HEAD --name-only
```

### 2. 리뷰 프롬프트 파일 생성

출력 경로: `.claude/reviews/DON-XXX-{type}-review.md`

`review-template.md`를 기반으로 아래 항목을 채워 생성한다:

- `{{ISSUE}}` → 이슈 번호 (예: `DON-97`)
- `{{TYPE}}` → 리뷰 유형 (`code` | `design`)
- `{{TITLE}}` → Linear 이슈 제목
- `{{CHANGED_FILES}}` → `git diff main...HEAD --name-only` 결과
- `{{SPEC_DOCS}}` → 관련 spec/ADR 경로
- `{{ACCEPTANCE_CRITERIA}}` → Linear 이슈 AC 항목
- `{{RESULT_PATH}}` → `.claude/reviews/DON-XXX-{type}-result.md`

### 3. PROGRESS.md PENDING_REVIEW 마커 기입

PROGRESS.md 끝에 아래 형식으로 추가한다:

```
PENDING_REVIEW: DON-XXX-{type}
```

스크립트(`scripts/codex-review.sh`)가 이 마커를 읽어 리뷰 파일 경로를 자동으로 결정한다.

### 4. 사람에게 실행 명령 안내

```
리뷰 준비 완료.

리뷰 파일: .claude/reviews/DON-XXX-{type}-review.md
결과 파일: .claude/reviews/DON-XXX-{type}-result.md

실행 명령 (스크립트 사용):
  ./scripts/codex-review.sh

또는 직접 실행:
  codex exec - < .claude/reviews/DON-XXX-{type}-review.md > .claude/reviews/DON-XXX-{type}-result.md

결과 파일 생성 후 "계속 진행해"라고 말씀해주세요.
```

## 참조

- `.claude/skills/request-codex-review/review-template.md` — 리뷰 프롬프트 템플릿
- `.claude/skills/request-codex-review/result-template.md` — 결과 파일 포맷 템플릿
- `.claude/knowledge/review-checklist.md` — 리뷰 체크리스트 전체
- `AGENTS.md` — 불변식 목록 (리뷰 관련 불변식 포함)
