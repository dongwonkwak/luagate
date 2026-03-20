#!/bin/bash
# .claude/hooks/pre-review-check.sh — Claude Code PreToolUse hook
# Intercepts codex-review commands and validates PENDING_REVIEW marker in PROGRESS.md
set -euo pipefail

INPUT="$(cat)"
REVIEW_PATTERN='codex-review\.sh|codex-address-pr-review\.sh|request-codex-review'

# Require jq for JSON parsing
if ! command -v jq >/dev/null 2>&1; then
  if echo "$INPUT" | grep -Eq "$REVIEW_PATTERN"; then
    echo "  pre-review: review command detected (jq unavailable, using fallback)" >&2
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
    if [ -f "$repo_root/PROGRESS.md" ] && ! grep -q "PENDING_REVIEW" "$repo_root/PROGRESS.md"; then
      echo '{"decision":"block","reason":"PROGRESS.md missing PENDING_REVIEW marker — update before requesting review"}'
      exit 0
    fi
  fi
  exit 0
fi

COMMAND="$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)" || COMMAND=""

if echo "$COMMAND" | grep -Eq "$REVIEW_PATTERN"; then
  echo "  pre-review: review command detected — checking PENDING_REVIEW marker..." >&2
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0

  if [ ! -f "$repo_root/PROGRESS.md" ]; then
    echo "  pre-review: PROGRESS.md not found — skipping check" >&2
    exit 0
  fi

  if ! grep -q "PENDING_REVIEW" "$repo_root/PROGRESS.md"; then
    jq -n '{"decision":"block","reason":"PROGRESS.md missing PENDING_REVIEW marker — update before requesting review"}'
    exit 0
  fi

  echo "  pre-review: PENDING_REVIEW marker found" >&2
fi

exit 0
