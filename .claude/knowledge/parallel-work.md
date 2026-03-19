# 병렬 작업 가이드

## 배경

Subagents 구조에서 여러 이슈를 동시에 작업하면 단일 working directory에서 git 충돌이 발생한다.
git worktree를 사용하면 각 이슈를 별도 디렉토리에서 독립적으로 진행할 수 있다.

## 병렬 작업 원칙

1. **의존성 없는 이슈만 병렬 가능** — `blockedBy` 관계가 있으면 순차 처리
2. **파일 충돌 회피** — 같은 파일을 수정하는 이슈는 병렬 작업 금지
3. **worktree 생명주기 관리** — 이슈 완료 후 반드시 worktree 제거
4. **메인 저장소 보호** — 메인 저장소에서 worktree 브랜치를 checkout하면 안 됨
5. **PROGRESS.md 자동 갱신** — PR 머지 시 GitHub Action이 자동 append. PR body에 `<!-- PROGRESS -->` 블록만 포함하면 됨

6. **node_modules 심링크** — worktree 생성 후 루트 `node_modules/`는 메인 저장소에서 심링크, 하위 패키지는 필요 시 `npm ci`

## 구체적 절차

`parallel-work` 스킬 참조: `.claude/skills/parallel-work/SKILL.md`
