# Codex 리뷰 워크플로우

Claude Code + Codex CLI를 사용한 코드/설계 리뷰 워크플로우 개요.

---

## 개요

LuaGate는 중요한 이슈 구현 완료 후, Codex CLI를 통해 독립적인 리뷰를 수행한다.
Claude Code가 리뷰 프롬프트 파일을 생성하고, 사람이 Codex를 실행하며, Claude Code가 피드백을 반영한다.

---

## 역할 분담

| 주체 | 역할 |
|------|------|
| Claude Code | `review.md` 생성, 피드백 수정 |
| Codex CLI | 리뷰(찾기)만 — 코드 수정 없음 |
| 사람 | Codex 실행, 테스트 실행, 수정 지시 |

> **AGENTS.md 불변식**: Codex 역할은 리뷰(찾기)만. 수정은 사람의 별도 지시로만 수행.

---

## 파일 구조

```
.claude/reviews/
├── DON-97-code-review.md    ← Claude Code가 생성한 리뷰 프롬프트
└── DON-97-code-result.md    ← Codex가 출력한 리뷰 결과

.claude/skills/request-codex-review/
├── SKILL.md                 ← 스킬 동작 정의
├── review-template.md       ← review.md 생성 템플릿
└── result-template.md       ← result.md 포맷 템플릿

scripts/
└── codex-review.sh          ← Codex 실행 래퍼 스크립트
```

---

## 전체 흐름

### 1회 리뷰 (최초)

```
1. 구현 완료
   └─ implementer + tester 완료 후 리뷰 포인트 도달

2. Claude Code: request-codex-review 스킬 실행
   └─ .claude/reviews/DON-XXX-{type}-review.md 생성
   └─ PROGRESS.md에 PENDING_REVIEW: DON-XXX-{type} 마커 기입
   └─ 사람에게 실행 명령 안내

3. 사람: Codex 실행
   └─ ./scripts/codex-review.sh
   └─ 결과: .claude/reviews/DON-XXX-{type}-result.md 생성

4. 사람: 피드백 검토 후 Claude Code에 수정 지시
   └─ "result.md를 보고 피드백 반영해줘"

5. Claude Code: 피드백 반영 + result.md에 완료 표시
   └─ - [x] 피드백 내용
         → 해결자: Claude Code
         → 해결 방식: (한 줄 요약)

6. 사람: 테스트 실행 확인
   └─ make test
```

### 재리뷰

```
1. 수정 완료 후 사람이 재리뷰 요청

2. 스크립트가 result.md의 [x] 항목을 자동 감지
   └─ 기해결 항목은 Codex에 스킵 지시 전달
   └─ result.md에 "## 재리뷰 (YYYY-MM-DD)" 헤더 추가 후 append

3. 미해결 항목만 재검토
```

---

## 스크립트 사용법

자세한 사용법은 [`scripts/README.md`](../../scripts/README.md) 참조.

```bash
# PROGRESS.md의 PENDING_REVIEW 자동 감지
./scripts/codex-review.sh

# 수동 지정
./scripts/codex-review.sh DON-97 code
./scripts/codex-review.sh DON-97 design
```

---

## result.md 포맷

포맷 규칙은 `.claude/skills/request-codex-review/result-template.md` 참조.

```markdown
# 리뷰 결과: DON-97-code

## 1차 리뷰 (2026-03-14)

- [ ] 미해결 피드백

- [x] 완료된 피드백
      → 해결자: Claude Code
      → 해결 방식: 한 줄 요약

---

## 재리뷰 (2026-03-15)

- [ ] 남은 미해결 항목
```

---

## AGENTS.md 불변식 참조

리뷰 워크플로우 관련 전체 불변식은 [`AGENTS.md` — 리뷰 관련 불변식](../../AGENTS.md) 섹션 참조:

- result-template.md 경로 명시 의무
- Codex 역할: 리뷰(찾기)만, 수정 없음
- 완료 항목 기입 형식 (`[x]` + 해결자 + 해결 방식)
- 재리뷰 시 기해결 항목 재지적 금지
- 테스트 실행은 사람이 수동으로 요청
