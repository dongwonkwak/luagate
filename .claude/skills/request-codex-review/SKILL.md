---
name: request-codex-review
description: "review.md 파일 생성 + PROGRESS.md PENDING_REVIEW 마커 기입 + 사람에게 실행 명령 안내. codex 자체는 실행하지 않음."
trigger: "request-codex-review | codex 리뷰 파일 생성 | 리뷰 프롬프트 생성"
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
./scripts/review-changed-files.sh
```

### 2. 생성 전 확인

파일을 생성하기 전에 반드시 사람에게 확인을 받는다.

**최초 리뷰 시:**
```
다음 파일을 생성합니다:

  📄 리뷰 파일: .claude/reviews/DON-XXX-{type}-review.md
  📄 결과 파일: .claude/reviews/DON-XXX-{type}-result.md  ← codex 실행 후 생성됨

생성할까요? (변경 파일 목록: N개)
```

**재리뷰 시** (review.md 또는 result.md가 이미 존재하는 경우):
```
재리뷰를 준비합니다:

  📄 리뷰 파일: .claude/reviews/DON-XXX-{type}-review.md  ← 이미 존재 (덮어쓰지 않음)
  📄 결과 파일: .claude/reviews/DON-XXX-{type}-result.md  ← 이미 존재 (append됨)

진행할까요?
```

사람이 승인하면 3단계로 진행. 거부하면 중단.

### 3. 리뷰 프롬프트 파일 생성

출력 경로: `.claude/reviews/DON-XXX-{type}-review.md`

`review-template.md`를 기반으로 아래 항목을 채워 생성한다:

- `{{ISSUE}}` → 이슈 번호 (예: `DON-97`)
- `{{TYPE}}` → 리뷰 유형 (`code` | `design`)
- `{{TYPE_LABEL}}` → 리뷰 유형 한국어 설명
  - `code` → `코드 리뷰 — 구현 정확성, 보안, 테스트 완전성 검토`
  - `design` → `설계 리뷰 — 아키텍처 결정의 타당성, 대안 검토, ADR 품질 검토`
- `{{TITLE}}` → Linear 이슈 제목
- `{{CHANGED_FILES}}` → `./scripts/review-changed-files.sh` 결과
- `{{SPEC_DOCS}}` → 관련 spec/ADR 경로
- `{{ACCEPTANCE_CRITERIA}}` → Linear 이슈 AC 항목
- `{{RESULT_PATH}}` → `.claude/reviews/DON-XXX-{type}-result.md`

### 4. 사람에게 실행 명령 안내

```
리뷰 준비 완료.

리뷰 파일: .claude/reviews/DON-XXX-{type}-review.md
결과 파일: .claude/reviews/DON-XXX-{type}-result.md

실행 명령 (스크립트 사용 — 권장):
  ./scripts/codex-review.sh

⚠️ 직접 실행은 최초 리뷰에만 사용. 재리뷰에서 사용하면 기존 result.md 이력이 덮어씌워집니다:
  codex exec - < .claude/reviews/DON-XXX-{type}-review.md > .claude/reviews/DON-XXX-{type}-result.md

결과 파일 생성 후 "계속 진행해"라고 말씀해주세요.
```

## 참조

- `.claude/skills/request-codex-review/review-template.md` — 리뷰 프롬프트 템플릿
- `.claude/skills/request-codex-review/result-template.md` — 결과 파일 포맷 템플릿
- `.claude/knowledge/review-checklist.md` — 리뷰 체크리스트 전체
- `AGENTS.md` — 불변식 목록 (리뷰 관련 불변식 포함)
