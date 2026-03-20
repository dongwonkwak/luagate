#!/usr/bin/env bash
# scripts/check-pending-review.sh — Standalone PENDING_REVIEW marker checker
# Can be called manually or by hooks
set -euo pipefail

PROGRESS_FILE="${1:-PROGRESS.md}"

if [ ! -f "$PROGRESS_FILE" ]; then
  echo "PROGRESS.md not found — skipping check"
  exit 0
fi

if ! grep -q "PENDING_REVIEW" "$PROGRESS_FILE"; then
  echo "PROGRESS.md missing PENDING_REVIEW marker"
  echo "  Update PROGRESS.md before requesting review"
  exit 1
fi

echo "PENDING_REVIEW marker confirmed"
exit 0
