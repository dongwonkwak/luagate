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

set -euo pipefail

REVIEWS_DIR=".claude/reviews"

# --- 인자 처리 ---
if [ $# -eq 2 ]; then
  ISSUE="$1"
  TYPE="$2"
  PENDING="${ISSUE}-${TYPE}"
elif [ $# -eq 0 ]; then
  PENDING=$(grep '^PENDING_REVIEW:' PROGRESS.md 2>/dev/null | tail -1 | awk '{print $2}')
  if [ -z "$PENDING" ]; then
    echo "오류: PROGRESS.md에 PENDING_REVIEW 마커가 없습니다." >&2
    echo "직접 지정: ./scripts/codex-review.sh <ISSUE> <TYPE>" >&2
    echo "예시: ./scripts/codex-review.sh DON-97 code" >&2
    exit 1
  fi
else
  echo "사용법: $0 [ISSUE TYPE]" >&2
  echo "예시:   $0 DON-97 code" >&2
  exit 1
fi

REVIEW="${REVIEWS_DIR}/${PENDING}-review.md"
RESULT="${REVIEWS_DIR}/${PENDING}-result.md"

# --- review 파일 존재 확인 ---
if [ ! -f "$REVIEW" ]; then
  echo "오류: 리뷰 파일이 없습니다: $REVIEW" >&2
  echo "request-codex-review 스킬을 먼저 실행하세요." >&2
  exit 1
fi

mkdir -p "$REVIEWS_DIR"

# --- 최초 리뷰 vs 재리뷰 분기 ---
RESOLVED=$(grep '^\- \[x\]' "$RESULT" 2>/dev/null | sed 's/^- \[x\] //' || true)

if [ -n "$RESOLVED" ]; then
  # 재리뷰: 기해결 항목 스킵 프롬프트 + 날짜 헤더 추가
  SKIP_PROMPT="다음 항목은 이미 해결되었으니 재지적하지 마세요:\n${RESOLVED}\n\n---\n"
  echo "" >> "$RESULT"
  echo "---" >> "$RESULT"
  echo "" >> "$RESULT"
  echo "## 재리뷰 ($(date '+%Y-%m-%d'))" >> "$RESULT"
  echo "" >> "$RESULT"
  (printf "%b" "$SKIP_PROMPT"; cat "$REVIEW") | codex exec - >> "$RESULT"
  echo "재리뷰 완료: $RESULT"
else
  # 최초 리뷰: review.md → Codex → result.md 신규 생성
  codex exec - < "$REVIEW" > "$RESULT"
  echo "리뷰 완료: $RESULT"
fi
