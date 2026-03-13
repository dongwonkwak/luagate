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

**파일 내용:**

```markdown
# Codex Review: DON-XXX — <이슈 제목> (<type>)

## 리뷰 유형
<설계 리뷰 | 코드 리뷰>

## 변경 파일 목록
(git diff main...HEAD --name-only 결과)

## 관련 스펙 문서
- docs/spec/<관련파일>.md
- docs/design/adr/ADR-NNN-*.md (해당 시)

## Acceptance Criteria
(Linear 이슈에서 추출)

## 적용 불변식 (AGENTS.md)
- luagate_ prefix 필수
- fail-closed (에러 → deny)
- ngx.worker.id() 사용 (PID 아님)
- hot reload 7단계 준수
- same-PR 규칙 (코드 + 문서)
- FFI free 함수 호출 의무

## 리뷰 체크리스트
(docs/spec/ 및 .claude/knowledge/review-checklist.md 기준)

### 코드 품질
- [ ] 불변식 위반 없음
- [ ] 에러 핸들링 (fail-closed)
- [ ] 테스트 커버리지 충분

### 보안
- [ ] 인증/인가 처리
- [ ] PII 레독션
- [ ] OWASP 패턴

## 리뷰 관점
<설계 리뷰: 아키텍처 결정의 타당성, 대안 검토, ADR 품질>
<코드 리뷰: 구현 정확성, 보안, 테스트 완전성>

## 결과 파일 출력 경로
.claude/reviews/DON-XXX-{type}-result.md
```

### 3. PROGRESS.md 대기 상태 기록

PROGRESS.md의 `## 현재 대기 중` 섹션에 추가:
```
- DON-XXX: <type> 리뷰 대기 중 (.claude/reviews/DON-XXX-<type>-review.md)
```

### 4. 사람에게 실행 명령 안내

```
리뷰 준비 완료.

실행 명령:
  make review ISSUE=DON-XXX TYPE=<type>

결과 파일 생성 후 "계속 진행해"라고 말씀해주세요.
```

## 참조

- `.claude/knowledge/review-checklist.md` — 리뷰 체크리스트 전체
- `AGENTS.md` — 불변식 목록
