#!/usr/bin/env bash
# scripts/check-pending-review.sh — Standalone review-pending marker checker
# Can be called manually or by hooks
set -euo pipefail

PROGRESS_FILE="${1:-PROGRESS.md}"

# Marker used in PROGRESS.md to indicate pending review
REVIEW_MARKER="리뷰 대기"

if [ ! -f "$PROGRESS_FILE" ]; then
  echo "PROGRESS.md not found — skipping check"
  exit 0
fi

if ! grep -q "$REVIEW_MARKER" "$PROGRESS_FILE"; then
  echo "PROGRESS.md missing review-pending marker (리뷰 대기)"
  echo "  Update PROGRESS.md before requesting review"
  exit 1
fi

echo "review-pending marker confirmed"
exit 0
