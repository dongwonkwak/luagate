#!/bin/bash
# .claude/hooks/pre-review-check.sh — Claude Code PreToolUse hook
# Intercepts pre-PR codex review commands and validates review-pending marker in PROGRESS.md
set -euo pipefail

INPUT="$(cat)"
REVIEW_PATTERN='codex-review\.sh|request-codex-review'
REVIEW_MARKER="리뷰 대기"

# Require jq for JSON parsing
if ! command -v jq >/dev/null 2>&1; then
  if echo "$INPUT" | grep -Eq "$REVIEW_PATTERN"; then
    echo "  pre-review: review command detected (jq unavailable, using fallback)" >&2
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
    if [ -f "$repo_root/PROGRESS.md" ] && ! grep -q "$REVIEW_MARKER" "$repo_root/PROGRESS.md"; then
      echo "{\"decision\":\"block\",\"reason\":\"PROGRESS.md missing review-pending marker (${REVIEW_MARKER}) — update before requesting review\"}"
      exit 0
    fi
  fi
  exit 0
fi

COMMAND="$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)" || COMMAND=""

if echo "$COMMAND" | grep -Eq "$REVIEW_PATTERN"; then
  echo "  pre-review: review command detected — checking review-pending marker..." >&2
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0

  if [ ! -f "$repo_root/PROGRESS.md" ]; then
    echo "  pre-review: PROGRESS.md not found — skipping check" >&2
    exit 0
  fi

  if ! grep -q "$REVIEW_MARKER" "$repo_root/PROGRESS.md"; then
    jq -n --arg reason "PROGRESS.md missing review-pending marker (${REVIEW_MARKER}) — update before requesting review" \
      '{"decision":"block","reason":$reason}'
    exit 0
  fi

  echo "  pre-review: review-pending marker found" >&2
fi

exit 0
