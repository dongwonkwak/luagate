# scripts/

LuaGate 프로젝트 보조 스크립트 모음.

---

## codex-review.sh

Codex CLI를 사용한 코드/설계 리뷰 자동화 스크립트.

### 사용법

```bash
# 1. PROGRESS.md의 PENDING_REVIEW 마커를 자동 감지하여 실행
./scripts/codex-review.sh

# 2. 이슈/유형을 수동으로 지정하여 실행
./scripts/codex-review.sh DON-97 code
./scripts/codex-review.sh DON-97 design
```

### PENDING_REVIEW 마커 포맷

`request-codex-review` 스킬이 PROGRESS.md 끝에 아래 형식으로 마커를 기입한다:

```
PENDING_REVIEW: DON-97-code
```

스크립트는 이 마커를 읽어 다음 경로를 자동으로 결정한다:

- 리뷰 파일: `.claude/reviews/DON-97-code-review.md`
- 결과 파일: `.claude/reviews/DON-97-code-result.md`

**재리뷰 시**: 이전 `COMPLETED_REVIEW` 라인이 이미 있더라도 그 아래에 `PENDING_REVIEW`를 추가한다.
스크립트는 `tail -1`로 마지막 마커를 읽으므로 정상 동작한다.

```
# 재리뷰 시 PROGRESS.md 예시
COMPLETED_REVIEW: DON-97-code (2026-03-14)
PENDING_REVIEW: DON-97-code          ← 스킬이 재기입
```

### 최초 리뷰 vs 재리뷰

| 상황 | 동작 |
|------|------|
| result.md가 없거나 `[x]` 항목 없음 | 최초 리뷰: review.md → Codex → result.md 신규 생성 |
| result.md에 `[x]` 항목 있음 | 재리뷰: 기해결 항목 스킵 프롬프트 + 날짜 헤더 추가 → result.md에 append |

재리뷰 시 기존 `[x]` 항목은 Codex에게 스킵 지시가 전달된다 (AGENTS.md 불변식).

### 마커 자동 정리

리뷰 실행 완료 후 스크립트가 PROGRESS.md의 마커를 자동으로 갱신한다:

```
# 실행 전
PENDING_REVIEW: DON-97-code

# 실행 후
COMPLETED_REVIEW: DON-97-code (2026-03-14)
```

### 전제 조건

- `codex` CLI가 PATH에 설치되어 있어야 한다.
- 리뷰 파일(`.claude/reviews/DON-XXX-{type}-review.md`)이 사전 생성되어 있어야 한다.
  → `request-codex-review` 스킬로 생성.

---

## codex-address-pr-review.sh

PR에 `chatgpt-codex-connector` 가 남긴 unresolved review thread 를 읽어,
Codex CLI로 항목별 수정/검증을 수행한 뒤 GitHub thread 에 답글을 남기고
conversation 을 resolve 하는 스크립트.

### 사용법

```bash
# 현재 브랜치의 연결 PR을 자동 탐지해 처리
./scripts/codex-address-pr-review.sh

# 이전 실행 상태를 읽어 미완료 항목만 재개
./scripts/codex-address-pr-review.sh --resume

# 특정 thread 하나만 처리
./scripts/codex-address-pr-review.sh --thread-url https://github.com/<owner>/<repo>/pull/<n>#discussion_r<id>

# 실제 수정 없이 대상 thread만 확인
./scripts/codex-address-pr-review.sh --dry-run
```

### 동작 요약

1. `gh pr view` 로 현재 브랜치의 연결 PR 자동 탐지
2. `chatgpt-codex-connector` 작성 + unresolved 상태인 review thread 만 수집
3. 항목별로 `codex exec` 실행
4. 수정 사항이 있으면 항목별 커밋 생성
5. `git push origin HEAD`
6. 해당 review thread 에 `원인 / 수정 / 검증` 형식 답글 게시
7. reply 성공 후 `Resolve conversation` 처리

### 옵션

| 옵션 | 설명 |
|------|------|
| `--resume` | `.claude/reviews/pr-<number>-codex-followup.md` 상태 파일을 읽어 완료된 항목은 건너뜀 |
| `--thread-url <url>` | 특정 review thread 하나만 처리 |
| `--pr <number>` | 현재 브랜치 PR 자동 탐지 실패 시 수동 지정 |
| `--url <pr-url>` | 현재 브랜치 PR 자동 탐지 실패 시 수동 지정 |
| `--dry-run` | PR/thread 조회만 수행, 수정/커밋/답글 없음 |
| `--no-push` | 로컬 커밋까지만 수행하고 push/reply 생략 |

### 전제 조건

- 작업 트리가 깨끗해야 한다. 스크립트가 항목별 커밋을 만들기 때문이다.
- `gh`, `jq`, `git`, `codex` CLI 가 PATH 에 있어야 한다.
- `gh auth login` 이 완료되어 있어야 한다.
- 현재 체크아웃한 브랜치가 PR head 브랜치와 같아야 한다.

### 상태 파일

실행 상태는 아래 파일에 기록된다:

```text
.claude/reviews/pr-<number>-codex-followup.md
```

- 항목별 진행 상태, commit SHA, reply/resolve 여부를 append 형식으로 기록
- 중단 후 `--resume` 으로 재개 가능

### 주의 사항

- 이 스크립트는 기존 `codex-review.sh` 와 목적이 다르다.
  - `codex-review.sh`: PR 전 내부 리뷰 프롬프트 실행
  - `codex-address-pr-review.sh`: PR 후 GitHub review thread 후속 수정/답글
- `--no-push` 는 로컬 커밋은 만들 수 있지만 원격 push, GitHub reply, conversation resolve 는 생략한다.

---

## 향후 추가 예정 스크립트

| 스크립트 | 설명 |
|---------|------|
| `lint-all.sh` | StyLua + luacheck + cargo clippy 일괄 실행 |
| `gen-metrics-doc.sh` | Prometheus 메트릭 목록 자동 생성 |
