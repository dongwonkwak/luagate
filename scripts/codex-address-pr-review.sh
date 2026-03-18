#!/bin/bash
# scripts/codex-address-pr-review.sh — PR 후 Codex review thread 후속 처리
#
# 사용법:
#   ./scripts/codex-address-pr-review.sh
#   ./scripts/codex-address-pr-review.sh --resume
#   ./scripts/codex-address-pr-review.sh --thread-url <thread-url>
#   ./scripts/codex-address-pr-review.sh --pr 23
#
# 동작:
#   1. 현재 브랜치의 연결 PR 자동 탐지 (또는 --pr/--url 수동 지정)
#   2. chatgpt-codex-connector 의 unresolved review thread 수집
#   3. 항목별로 codex exec 호출 → 수정 → 검증
#   4. 항목별 git commit / git push
#   5. 원인/수정/검증 형식으로 review thread 답글 게시

set -euo pipefail

REVIEW_AUTHOR="chatgpt-codex-connector"
REVIEWS_DIR=".claude/reviews"
SCRIPT_NAME="$(basename "$0")"

usage() {
  cat <<EOF
사용법:
  $SCRIPT_NAME
  $SCRIPT_NAME --thread-url <thread-url>
  $SCRIPT_NAME --pr <number>
  $SCRIPT_NAME --url <pr-url>
  $SCRIPT_NAME --dry-run
  $SCRIPT_NAME --no-push

옵션:
  --resume                자동 판단 대신 명시적으로 resume 모드 사용
  --thread-url <url>      특정 review thread 하나만 처리
  --pr <number>           현재 브랜치 PR 자동 탐지 실패 시 수동 지정
  --url <pr-url>          현재 브랜치 PR 자동 탐지 실패 시 수동 지정
  --dry-run               PR/thread 조회만 수행하고 수정하지 않음
  --no-push               로컬 커밋까지만 수행하고 push/reply는 생략
  -h, --help              도움말 출력
EOF
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "오류: '$cmd' 명령을 찾을 수 없습니다." >&2
    exit 1
  fi
}

sanitize_field() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | sed 's/  */ /g'
}

trim_field() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

state_checkbox() {
  local status="$1"
  case "$status" in
    done)
      printf 'x'
      ;;
    *)
      printf ' '
      ;;
  esac
}

state_file_has_history() {
  [ -f "$STATE_FILE" ] && grep -q '^STATE	' "$STATE_FILE" 2>/dev/null
}

append_state() {
  local status="$1"
  local thread_url="$2"
  local comment_id="$3"
  local commit_sha="$4"
  local title="$5"
  local note="$6"
  local checkbox

  checkbox="$(state_checkbox "$status")"

  {
    echo ""
    printf -- "- [%s] %s\n" "$checkbox" "$title"
    echo "      → thread: $thread_url"
    echo "      → 상태: $status"
    if [ "$commit_sha" != "-" ]; then
      echo "      → commit: $commit_sha"
    fi
    echo "      → 결과: $(sanitize_field "$note")"
  } >>"$STATE_FILE"

  printf 'STATE\t%s\t%s\t%s\t%s\t%s\n' \
    "$status" \
    "$thread_url" \
    "$comment_id" \
    "$commit_sha" \
    "$(sanitize_field "$note")" >>"$STATE_FILE"
}

latest_state() {
  local thread_url="$1"
  if [ ! -f "$STATE_FILE" ]; then
    return 0
  fi

  awk -F '\t' -v thread_url="$thread_url" '
    $1 == "STATE" && $3 == thread_url { state = $2 }
    END { if (state != "") print state }
  ' "$STATE_FILE"
}

ensure_state_file() {
  mkdir -p "$REVIEWS_DIR"
  if [ -f "$STATE_FILE" ] && [ -s "$STATE_FILE" ]; then
    return 0
  fi

  cat >"$STATE_FILE" <<EOF
# PR Codex Follow-up: #$PR_NUMBER
PR_URL: $PR_URL
BRANCH: $CURRENT_BRANCH
CREATED_AT: $(date '+%Y-%m-%d %H:%M:%S %z')

# 아래 체크마크 항목은 사람이 읽는 진행 기록이다.
# 이어지는 STATE<TAB>... 라인은 resume 판단용 내부 상태 로그다.
EOF
}

extract_issue_key() {
  local issue_key
  issue_key=$(printf '%s' "$PR_TITLE" | sed -n 's/.*\[\(DON-[0-9][0-9]*\)\].*/\1/p')
  if [ -n "$issue_key" ]; then
    printf '%s' "$issue_key"
    return 0
  fi

  issue_key=$(printf '%s' "$CURRENT_BRANCH" | sed -n 's#.*\(DON-[0-9][0-9]*\).*#\1#p')
  if [ -n "$issue_key" ]; then
    printf '%s' "$issue_key"
    return 0
  fi

  printf 'REVIEW'
}

commit_message_for() {
  local thread_path="$1"
  local issue_key="$2"
  local base_name
  base_name="$(basename "$thread_path")"
  printf 'fix(review): address Codex feedback in %s [%s]' "$base_name" "$issue_key"
}

extract_title_from_body() {
  local body="$1"
  local title
  title=$(printf '%s\n' "$body" | sed -E 's/^\*\*.*  (.*)\*\*$/\1/' | head -1)
  if [ -n "$title" ]; then
    printf '%s' "$title"
    return 0
  fi

  printf 'Codex review feedback'
}

require_clean_worktree() {
  if [ -n "$(git status --porcelain)" ]; then
    echo "오류: 작업 트리가 깨끗하지 않습니다." >&2
    echo "이 스크립트는 항목별 커밋/푸시를 수행하므로, 먼저 변경 사항을 정리하세요." >&2
    exit 1
  fi
}

load_pr_metadata() {
  local selector=()
  local pr_view_err="$TMP_DIR/gh-pr-view.err"
  if [ -n "$PR_NUMBER_OVERRIDE" ]; then
    selector=("$PR_NUMBER_OVERRIDE")
  elif [ -n "$PR_URL_OVERRIDE" ]; then
    selector=("$PR_URL_OVERRIDE")
  fi

  if ! PR_JSON=$(gh pr view "${selector[@]}" --json number,url,title,headRefName,baseRefName 2>"$pr_view_err"); then
    echo "오류: 현재 브랜치에 연결된 PR을 찾지 못했습니다." >&2
    if [ -s "$pr_view_err" ]; then
      cat "$pr_view_err" >&2
    fi
    echo "필요하면 '--pr <number>' 또는 '--url <pr-url>' 로 수동 지정하세요." >&2
    exit 1
  fi

  if [ -z "$PR_JSON" ]; then
    echo "오류: gh pr view 결과가 비어 있습니다." >&2
    exit 1
  fi

  PR_NUMBER=$(printf '%s' "$PR_JSON" | jq -r '.number')
  PR_URL=$(printf '%s' "$PR_JSON" | jq -r '.url')
  PR_TITLE=$(printf '%s' "$PR_JSON" | jq -r '.title')
  PR_HEAD_REF=$(printf '%s' "$PR_JSON" | jq -r '.headRefName')
}

# shellcheck disable=SC2016  # GraphQL 변수, shell 확장 아님
fetch_threads_json() {
  gh api graphql \
    -F owner='{owner}' \
    -F name='{repo}' \
    -F number="$PR_NUMBER" \
    -f query='
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            reviewThreads(first: 100) {
              nodes {
                id
                isResolved
                comments(first: 20) {
                  nodes {
                    databaseId
                    url
                    path
                    line
                    body
                    author {
                      login
                    }
                  }
                }
              }
            }
          }
        }
      }
    '
}

build_reply_prompt() {
  local prompt_file="$1"
  local thread_url="$2"
  local thread_path="$3"
  local thread_line="$4"
  local review_title="$5"
  local review_body="$6"

  cat >"$prompt_file" <<EOF
현재 저장소의 GitHub PR review thread 하나를 처리하세요.

목표:
1. 아래 review feedback을 기준으로 필요한 최소 수정만 수행합니다.
2. 관련 테스트/검증을 가능한 좁은 범위로 직접 실행합니다.
3. git commit / git push 는 하지 않습니다.
4. 최종 응답은 GitHub thread reply 본문만 출력합니다.

PR 정보:
- PR: #$PR_NUMBER
- 제목: $PR_TITLE
- URL: $PR_URL
- 브랜치: $CURRENT_BRANCH

Review thread 정보:
- URL: $thread_url
- 파일: $thread_path
- 라인: $thread_line
- 제목: $review_title

Review 본문:
$review_body

제약:
- 이번 thread 하나만 처리하고, 다른 review thread 는 건드리지 마세요.
- 변경은 최소 범위로 제한하세요.
- 관련 없는 파일은 수정하지 마세요.
- 최종 응답은 반드시 아래 형식만 사용하세요. 다른 설명, 인사, 코드펜스, 헤더는 금지합니다.

원인:
- ...

수정:
- ...

검증:
- \`<command>\` — <결과>

이미 현재 브랜치에 반영된 내용이라 코드 변경이 필요 없다면, 수정 섹션에 "현재 브랜치에 이미 반영되어 코드 변경 없음"이라고 명시하고 검증 결과만 남기세요.
EOF
}

post_reply() {
  local comment_id="$1"
  local reply_file="$2"

  gh api "repos/{owner}/{repo}/pulls/$PR_NUMBER/comments" \
    --method POST \
    -F "body=@$reply_file" \
    -F "in_reply_to=$comment_id" \
    --silent
}

# shellcheck disable=SC2016  # GraphQL 변수, shell 확장 아님
resolve_thread() {
  local thread_id="$1"

  gh api graphql \
    -F threadId="$thread_id" \
    -f query='
      mutation($threadId: ID!) {
        resolveReviewThread(input: { threadId: $threadId }) {
          thread {
            isResolved
          }
        }
      }
    ' \
    --silent
}

DRY_RUN=0
NO_PUSH=0
RESUME=0
THREAD_URL_FILTER=""
PR_NUMBER_OVERRIDE=""
PR_URL_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --resume)
      RESUME=1
      shift
      ;;
    --thread-url)
      THREAD_URL_FILTER="${2:-}"
      shift 2
      ;;
    --pr)
      PR_NUMBER_OVERRIDE="${2:-}"
      shift 2
      ;;
    --url)
      PR_URL_OVERRIDE="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-push)
      NO_PUSH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "오류: 알 수 없는 옵션 '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

THREAD_URL_FILTER="$(trim_field "$THREAD_URL_FILTER")"

require_command gh
require_command jq
require_command git
require_command codex

CURRENT_BRANCH="$(git branch --show-current)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
MAIN_ROOT="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')"
REVIEWS_DIR="${MAIN_ROOT}/.claude/reviews"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

load_pr_metadata

if [ "$CURRENT_BRANCH" != "$PR_HEAD_REF" ]; then
  echo "오류: 현재 브랜치가 PR head 와 다릅니다." >&2
  echo "현재 브랜치: $CURRENT_BRANCH" >&2
  echo "PR head:      $PR_HEAD_REF" >&2
  echo "PR 브랜치를 checkout 한 뒤 다시 실행하세요." >&2
  exit 1
fi

STATE_FILE="${REVIEWS_DIR}/pr-${PR_NUMBER}-codex-followup.md"
if [ "$DRY_RUN" -ne 1 ] && state_file_has_history; then
  if [ "$RESUME" -eq 1 ]; then
    echo "resume 모드: 기존 상태 파일을 사용합니다."
  else
    echo "기존 상태 파일 감지: 자동으로 resume 모드로 전환합니다."
    RESUME=1
  fi
fi

THREADS_JSON="$(fetch_threads_json)"
THREADS="$(printf '%s' "$THREADS_JSON" | jq -c \
  --arg author "$REVIEW_AUTHOR" \
  --arg thread_url "$THREAD_URL_FILTER" '
    .data.repository.pullRequest.reviewThreads.nodes
    | map(select(.isResolved == false))
    | map({
        thread_id: .id,
        comment: .comments.nodes[0]
      })
    | map(select(.comment != null))
    | map(.comment + { thread_id: .thread_id })
    | map(select(. != null))
    | map(select(.author.login == $author))
    | map(select($thread_url == "" or .url == $thread_url))
    | sort_by(.databaseId)
    | .[]
  ')"

if [ -z "$THREADS" ]; then
  echo "처리할 Codex review thread 가 없습니다." >&2
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "PR #$PR_NUMBER — $PR_TITLE"
  echo "대상 thread:"
  printf '%s\n' "$THREADS" | while IFS= read -r thread; do
    [ -n "$thread" ] || continue
    printf '  - %s:%s %s\n' \
      "$(printf '%s' "$thread" | jq -r '.path')" \
      "$(printf '%s' "$thread" | jq -r '.line // 0')" \
      "$(printf '%s' "$thread" | jq -r '.url')"
  done
  exit 0
fi

require_clean_worktree
ensure_state_file
ISSUE_KEY="$(extract_issue_key)"

printf '%s\n' "$THREADS" | while IFS= read -r thread; do
  [ -n "$thread" ] || continue

  THREAD_URL="$(printf '%s' "$thread" | jq -r '.url')"
  THREAD_ID="$(printf '%s' "$thread" | jq -r '.thread_id')"
  COMMENT_ID="$(printf '%s' "$thread" | jq -r '.databaseId')"
  THREAD_PATH="$(printf '%s' "$thread" | jq -r '.path')"
  THREAD_LINE="$(printf '%s' "$thread" | jq -r '.line // 0')"
  REVIEW_BODY="$(printf '%s' "$thread" | jq -r '.body')"
  REVIEW_TITLE="$(extract_title_from_body "$REVIEW_BODY")"
  CURRENT_STATE="$(latest_state "$THREAD_URL")"

  if [ "$RESUME" -eq 1 ] && [ "$CURRENT_STATE" = "done" ]; then
    echo "건너뜀: 이미 완료된 thread — $THREAD_URL"
    continue
  fi

  require_clean_worktree
  append_state "in_progress" "$THREAD_URL" "$COMMENT_ID" "-" "$REVIEW_TITLE" "처리를 시작합니다."

  PROMPT_FILE="$TMP_DIR/prompt-${COMMENT_ID}.md"
  REPLY_FILE="$TMP_DIR/reply-${COMMENT_ID}.md"
  build_reply_prompt "$PROMPT_FILE" "$THREAD_URL" "$THREAD_PATH" "$THREAD_LINE" "$REVIEW_TITLE" "$REVIEW_BODY"

  if ! codex exec --full-auto --color never -C "$REPO_ROOT" -o "$REPLY_FILE" - <"$PROMPT_FILE"; then
    append_state "failed" "$THREAD_URL" "$COMMENT_ID" "-" "$REVIEW_TITLE" "codex exec 실패"
    echo "실패: Codex 실행 실패 — $THREAD_URL" >&2
    exit 1
  fi

  if [ ! -s "$REPLY_FILE" ]; then
    append_state "failed" "$THREAD_URL" "$COMMENT_ID" "-" "$REVIEW_TITLE" "reply 본문 없음"
    echo "실패: reply 본문이 비어 있습니다 — $THREAD_URL" >&2
    exit 1
  fi

  COMMIT_SHA="-"
  if [ -n "$(git status --porcelain)" ]; then
    COMMIT_MSG="$(commit_message_for "$THREAD_PATH" "$ISSUE_KEY")"
    MAX_RETRIES=3
    for attempt in $(seq 1 "$MAX_RETRIES"); do
      git add -A
      if git commit -m "$COMMIT_MSG"; then
        COMMIT_SHA="$(git rev-parse --short HEAD)"
        break
      fi
      echo "커밋 실패 (시도 $attempt/$MAX_RETRIES): pre-commit hook 오류 — codex로 자동 수정 시도..." >&2
      if [ "$attempt" -eq "$MAX_RETRIES" ]; then
        append_state "failed" "$THREAD_URL" "$COMMENT_ID" "-" "$REVIEW_TITLE" "pre-commit hook 수정 $MAX_RETRIES회 실패"
        echo "실패: pre-commit hook 오류를 $MAX_RETRIES회 시도 후에도 수정하지 못했습니다 — $THREAD_URL" >&2
        exit 1
      fi
      FIX_PROMPT_FILE="$TMP_DIR/fix-commit-${COMMENT_ID}-${attempt}.md"
      cat >"$FIX_PROMPT_FILE" <<FIXEOF
pre-commit hook이 실패하여 커밋이 되지 않았습니다.
아래 규칙에 맞게 코드를 수정하세요.

규칙:
- stylua: Lua 코드 포매팅
- luacheck: Lua 린트 경고/오류
- clang-format: C 코드 포매팅
- shellcheck: 쉘 스크립트 린트
- markdownlint: 마크다운 린트

git status --porcelain 으로 변경된 파일만 확인하고, 해당 파일의 pre-commit hook 오류만 수정하세요.
git commit / git push 는 하지 마세요.
FIXEOF
      codex exec --full-auto --color never -C "$REPO_ROOT" - <"$FIX_PROMPT_FILE" || true
    done
  fi

  if [ "$NO_PUSH" -eq 1 ]; then
    append_state "local_only" "$THREAD_URL" "$COMMENT_ID" "$COMMIT_SHA" "$REVIEW_TITLE" "local commit only; push/reply skipped"
    echo "완료(로컬): $THREAD_URL"
    continue
  fi

  if [ "$COMMIT_SHA" != "-" ]; then
    MAX_PUSH_RETRIES=3
    for push_attempt in $(seq 1 "$MAX_PUSH_RETRIES"); do
      if git push origin HEAD; then
        break
      fi
      echo "푸시 실패 (시도 $push_attempt/$MAX_PUSH_RETRIES): pre-push hook 오류 — codex로 자동 수정 시도..." >&2
      if [ "$push_attempt" -eq "$MAX_PUSH_RETRIES" ]; then
        append_state "failed" "$THREAD_URL" "$COMMENT_ID" "$COMMIT_SHA" "$REVIEW_TITLE" "pre-push hook 수정 ${MAX_PUSH_RETRIES}회 실패"
        echo "실패: pre-push hook 오류를 ${MAX_PUSH_RETRIES}회 시도 후에도 수정하지 못했습니다 — $THREAD_URL" >&2
        exit 1
      fi
      FIX_PUSH_PROMPT="$TMP_DIR/fix-push-${COMMENT_ID}-${push_attempt}.md"
      cat >"$FIX_PUSH_PROMPT" <<FIXEOF
pre-push hook이 실패하여 push가 되지 않았습니다.
아래 규칙에 맞게 코드를 수정하세요.

규칙:
- make test-unit: Lua 단위 테스트 통과
- clang-tidy: C 코드 정적 분석
- luacheck: Lua 린트 전체

최근 커밋에서 변경된 파일만 확인하고, 해당 파일의 pre-push hook 오류만 수정하세요.
수정 후 git add + git commit 으로 fix 커밋을 만드세요. git push 는 하지 마세요.
FIXEOF
      codex exec --full-auto --color never -C "$REPO_ROOT" - <"$FIX_PUSH_PROMPT" || true
    done
  fi

  if ! post_reply "$COMMENT_ID" "$REPLY_FILE"; then
    append_state "failed" "$THREAD_URL" "$COMMENT_ID" "$COMMIT_SHA" "$REVIEW_TITLE" "reply 게시 실패"
    echo "실패: GitHub reply 게시 실패 — $THREAD_URL" >&2
    exit 1
  fi

  if ! resolve_thread "$THREAD_ID"; then
    append_state "failed" "$THREAD_URL" "$COMMENT_ID" "$COMMIT_SHA" "$REVIEW_TITLE" "reply posted; thread resolve 실패"
    echo "실패: GitHub thread resolve 실패 — $THREAD_URL" >&2
    exit 1
  fi

  append_state "done" "$THREAD_URL" "$COMMENT_ID" "$COMMIT_SHA" "$REVIEW_TITLE" "reply posted; thread resolved"
  echo "완료: $THREAD_URL"
done
