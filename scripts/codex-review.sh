#!/bin/bash
# scripts/codex-review.sh — Codex CLI 리뷰 실행 래퍼
#
# 사용법:
#   ./scripts/codex-review.sh                  # PROGRESS.md에서 PENDING_REVIEW 자동 감지
#   ./scripts/codex-review.sh DON-97 code      # 이슈/유형 수동 지정
#
# 동작:
#   최초 리뷰: review.md → Codex → result.md 신규 생성
#   재리뷰:   [x] 항목 필터링 → 스킵 프롬프트 주입 → 날짜 헤더 추가 → result.md에 append
#   완료 시:  PROGRESS.md의 PENDING_REVIEW → COMPLETED_REVIEW 마커로 교체

set -euo pipefail

# --- worktree 환경 지원: MAIN_ROOT / WORKTREE_ROOT 분리 ---
WORKTREE_ROOT="$(git rev-parse --show-toplevel)"
MAIN_ROOT="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')"
cd "$WORKTREE_ROOT"

# --- codex CLI 설치 확인 ---
if ! command -v codex &>/dev/null; then
  echo "오류: codex CLI가 설치되어 있지 않습니다." >&2
  echo "설치: npm install -g @openai/codex" >&2
  exit 1
fi

REVIEWS_DIR="${MAIN_ROOT}/.claude/reviews"

# --- 인자 검증 함수 ---
validate_pending() {
  local val="$1"
  # DON-숫자-유형 또는 epic-숫자-식별자-유형 형식만 허용 (경로 조작 방지)
  if ! echo "$val" | grep -qE '^(DON-[0-9]+-[a-z]+|epic-[0-9]+-[a-z0-9-]+-[a-z]+)$'; then
    echo "오류: 잘못된 형식입니다: '$val'" >&2
    echo "올바른 형식: DON-숫자-유형 또는 epic-숫자-식별자-유형 (예: epic-05-feature-design)" >&2
    exit 1
  fi
}

# --- 인자 처리 ---
if [ $# -eq 2 ]; then
  ISSUE="$1"
  TYPE="$2"
  PENDING="${ISSUE}-${TYPE}"
  validate_pending "$PENDING"
elif [ $# -eq 0 ]; then
  # worktree 환경에서는 PENDING_REVIEW 마커가 여러 개일 수 있어 자동 감지 불가
  if [ "$WORKTREE_ROOT" != "$MAIN_ROOT" ]; then
    echo "오류: worktree 환경에서는 이슈/유형을 수동 지정해야 합니다." >&2
    echo "직접 지정: ./scripts/codex-review.sh <ISSUE> <TYPE>" >&2
    echo "예시: ./scripts/codex-review.sh DON-97 code" >&2
    exit 1
  fi
  # Fix #1: pipefail로 인한 무출력 종료 방지 — || true로 grep 실패를 무시
  PENDING=$(grep '^PENDING_REVIEW:' "${MAIN_ROOT}/PROGRESS.md" 2>/dev/null | tail -1 | awk '{print $2}' || true)
  if [ -z "$PENDING" ]; then
    echo "오류: PROGRESS.md에 PENDING_REVIEW 마커가 없습니다." >&2
    echo "직접 지정: ./scripts/codex-review.sh <ISSUE> <TYPE>" >&2
    echo "예시: ./scripts/codex-review.sh DON-97 code" >&2
    exit 1
  fi
  validate_pending "$PENDING"
else
  echo "사용법: $0 [ISSUE TYPE]" >&2
  echo "예시:   $0 DON-97 code" >&2
  exit 1
fi

REVIEW="${REVIEWS_DIR}/${PENDING}-review.md"
RESULT="${REVIEWS_DIR}/${PENDING}-result.md"

# --- worktree 리뷰 파일 탐색: worktree 먼저 확인, 없으면 MAIN_ROOT fallback ---
WORKTREE_REVIEW="${WORKTREE_ROOT}/.claude/reviews/${PENDING}-review.md"
if [ "$WORKTREE_ROOT" != "$MAIN_ROOT" ] && [ -f "$WORKTREE_REVIEW" ]; then
  REVIEW="$WORKTREE_REVIEW"
  RESULT="${WORKTREE_ROOT}/.claude/reviews/${PENDING}-result.md"
  REVIEWS_DIR="${WORKTREE_ROOT}/.claude/reviews"
fi

# --- reviews 디렉토리 생성 (review 파일 존재 확인 전에 수행) ---
mkdir -p "$REVIEWS_DIR"

# --- review 파일 존재 확인 ---
if [ ! -f "$REVIEW" ]; then
  echo "오류: 리뷰 파일이 없습니다: $REVIEW" >&2
  echo "request-codex-review 스킬을 먼저 실행하세요." >&2
  exit 1
fi

# --- 최초 리뷰 vs 재리뷰 분기 ---
RESOLVED=$(grep '^\- \[x\]' "$RESULT" 2>/dev/null | sed 's/^- \[x\] //' || true)

if [ -n "$RESOLVED" ]; then
  # Fix #2: tmpfile trap 추가 + codex 성공 시에만 result.md에 append
  REOPEN=$(grep '^\- \[ \]' "$RESULT" 2>/dev/null | sed 's/^- \[ \] //' || true)
  REREVIEW_PROMPT=$(mktemp)
  REREVIEW_OUTPUT=$(mktemp)
  # shellcheck disable=SC2064  # 즉시 확장이 의도된 동작
  trap "rm -f '$REREVIEW_PROMPT' '$REREVIEW_OUTPUT'" EXIT

  {
    echo "아래 항목은 이미 해결되었으니 재지적하지 마세요:"
    printf "%b" "$RESOLVED" | sed 's/^/  - /'
    echo ""
    echo "아직 미해결된 항목만 검토하세요:"
    if [ -n "$REOPEN" ]; then
      printf "%b" "$REOPEN" | sed 's/^/  - /'
    else
      echo "  (없음 — 모든 항목이 해결된 경우 '미해결 항목 없음'이라고만 출력)"
    fi
    echo ""
    echo "---"
    echo ""
    echo "출력 형식: 미해결 항목만 '- [ ] 내용' 형식으로 나열. 헤더(#)나 전체 result 문서를 다시 출력하지 말 것."
    echo ""
    echo "원본 리뷰 컨텍스트:"
    cat "$REVIEW"
  } > "$REREVIEW_PROMPT"

  # codex 성공 시에만 result.md에 헤더 + 출력 append (실패 시 result.md 오염 방지)
  if codex exec - < "$REREVIEW_PROMPT" > "$REREVIEW_OUTPUT"; then
    {
      echo ""
      echo "---"
      echo ""
      echo "## 재리뷰 ($(date '+%Y-%m-%d'))"
      echo ""
      cat "$REREVIEW_OUTPUT"
    } >> "$RESULT"
    echo "재리뷰 완료: $RESULT"
  else
    echo "오류: Codex 실행 실패. result.md는 수정되지 않았습니다." >&2
    exit 1
  fi
else
  # 최초 리뷰: review.md → Codex → result.md 신규 생성
  # tmpfile 패턴: codex 성공 시에만 result.md 생성 (실패 시 빈 파일 잔존 방지)
  FIRST_OUTPUT=$(mktemp)
  # shellcheck disable=SC2064  # 즉시 확장이 의도된 동작
  trap "rm -f '$FIRST_OUTPUT'" EXIT
  if codex exec - < "$REVIEW" > "$FIRST_OUTPUT"; then
    cp "$FIRST_OUTPUT" "$RESULT"
    echo "리뷰 완료: $RESULT"
  else
    echo "오류: Codex 실행 실패. result.md는 생성되지 않았습니다." >&2
    exit 1
  fi
fi

# --- PROGRESS.md 마커 정리: PENDING_REVIEW → COMPLETED_REVIEW ---
# worktree 환경에서는 worktree의 PROGRESS.md를 우선 갱신
PROGRESS_FILE="${MAIN_ROOT}/PROGRESS.md"
if [ "$WORKTREE_ROOT" != "$MAIN_ROOT" ] && [ -f "${WORKTREE_ROOT}/PROGRESS.md" ]; then
  PROGRESS_FILE="${WORKTREE_ROOT}/PROGRESS.md"
fi
if grep -q "^PENDING_REVIEW: ${PENDING}$" "$PROGRESS_FILE" 2>/dev/null; then
  sed "s/^PENDING_REVIEW: ${PENDING}$/COMPLETED_REVIEW: ${PENDING} ($(date '+%Y-%m-%d'))/" "$PROGRESS_FILE" > "${PROGRESS_FILE}.tmp" && mv "${PROGRESS_FILE}.tmp" "$PROGRESS_FILE"
  echo "PROGRESS.md 마커 갱신: PENDING_REVIEW → COMPLETED_REVIEW"
fi
