---
name: parallel-work
description: "여러 이슈를 병렬로 작업할 때 git worktree 설정 및 관리"
trigger: "parallel-work | 병렬 작업 | 동시 작업 | worktree | 여러 이슈"
---

# parallel-work Skill

## 역할

여러 이슈를 동시에 작업할 때 git worktree를 사용해 독립적인 작업 환경을 구성한다.

## 전제 조건

- 병렬로 진행할 이슈 목록 (DON-XXX, DON-YYY, ...)
- Linear MCP 접근 가능

## 실행 절차

### 1. 병렬 작업 대상 확인

- Linear MCP로 각 이슈 조회
- `blockedBy` 확인 → 의존성 있으면 병렬 불가
- 파일 충돌 가능성 검토 (같은 파일 수정 여부)

> **NOTE**: PROGRESS.md는 PR 머지 시 GitHub Action이 자동 갱신한다.
> PR body에 `<!-- PROGRESS -->` 블록만 포함하면 된다.

### 2. 작업 계획 보고 (사람 확인)

```markdown
| 이슈 | worktree 경로 | 브랜치 | 충돌 위험 |
|-----|--------------|-------|---------|
| DON-XXX | ../luagate-don-xxx | <branch-1> | 없음 |
| DON-YYY | ../luagate-don-yyy | <branch-2> | 없음 |

진행할까요? (y/n)
```

### 3. worktree 생성 (새 브랜치 포함)

```bash
# Linear get_issue 응답의 gitBranchName 필드 사용
# 한글이 포함된 경우 제거 후 연속 하이픈(--)을 단일 하이픈(-)으로 정리
# -b 플래그로 새 브랜치를 생성하면서 worktree 추가
git worktree add -b <sanitized-linear-gitBranchName-1> ../luagate-don-xxx <integration-base>
git worktree add -b <sanitized-linear-gitBranchName-2> ../luagate-don-yyy <integration-base>
```

> `git worktree add <path> <branch>`는 기존 브랜치만 가능.
> 새 이슈 브랜치는 반드시 `-b` 플래그를 사용한다.
> `<integration-base>`는 현재 작업을 머지할 대상 브랜치의 최신 head를 사용한다 (예: 활성 epic 브랜치).
> 각 브랜치명은 AGENTS 불변식대로 Linear `gitBranchName`을 사용하고, 한글이 있으면 제거 후 연속 하이픈을 정리한다.

### 3.5. node_modules 심링크 및 설치

worktree에는 `.gitignore`된 `node_modules/`가 복사되지 않는다.
메인 저장소의 `node_modules/`를 심링크하여 중복 설치를 피한다.

```bash
# 루트 node_modules — 심링크 (commitlint 등 pre-commit hook용)
ln -s "$(git rev-parse --show-toplevel)/node_modules" ../luagate-don-xxx/node_modules

# ui/, mcp/ 등 하위 패키지 — 독립 설치 (의존성이 다를 수 있음)
# 해당 worktree에서 수정하는 패키지만 설치
cd ../luagate-don-xxx/mcp && npm ci   # mcp 수정 시
cd ../luagate-don-xxx/ui && npm ci    # ui 수정 시
```

> **규칙**:
> - 루트 `node_modules/`는 항상 심링크 (pre-commit hook이 의존)
> - 하위 패키지(`ui/`, `mcp/`, `e2e/`)는 해당 이슈에서 수정할 때만 `npm ci`
> - 심링크 대상이 존재하지 않으면 `npm ci`로 fallback

### 4. 각 worktree에서 implement-issue 실행

- 각 디렉토리에서 독립적으로 작업
- Linear 상태는 각각 "In Progress"
- **implement-issue의 브랜치 생성 단계(3.5)는 건너뛴다** — worktree 생성 시 이미 브랜치가 만들어져 있으므로

### 5. 완료 후 정리

```bash
git worktree remove ../luagate-don-xxx
git worktree remove ../luagate-don-yyy
```

## worktree 관리 명령어 참조

```bash
# 목록 확인
git worktree list

# 새 브랜치로 생성
git worktree add -b <new-branch> <path> <start-point>

# 기존 브랜치로 생성
git worktree add <path> <existing-branch>

# 제거
git worktree remove <path>
```

## 주의사항

- 같은 파일을 수정하는 이슈는 병렬 작업 금지
- **PROGRESS.md는 PR 머지 시 자동 갱신** — PR body에 `<!-- PROGRESS -->` 블록 포함
- worktree 간 브랜치 전환 주의 — 한 worktree에서 다른 worktree의 브랜치를 checkout 불가
- 메인 저장소에서 worktree 브랜치 checkout 금지
- 완료 후 worktree 정리 필수
- **Codex 리뷰 파일은 worktree 내 `.claude/reviews/`에 생성** — `codex-review.sh`가 worktree 경로를 우선 탐색함
