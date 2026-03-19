#!/bin/bash
# .claude/hooks/pre-pr-test-gate.sh — Claude Code PreToolUse hook
# Intercepts `gh pr create` commands and runs `make pre-pr` first
set -euo pipefail

# Read the PreToolUse JSON from stdin
INPUT="$(cat)"

# Extract the command field from the Bash tool input
COMMAND="$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"

# Check if this is a `gh pr create` command
if echo "$COMMAND" | grep -q 'gh pr create'; then
  echo "  pre-PR test gate: gh pr create detected — running make pre-pr..." >&2
  if make pre-pr >&2; then
    # All tests passed — allow the command
    exit 0
  else
    # Tests failed — block the command
    jq -n '{decision: "block", reason: "make pre-pr failed — fix test failures before creating PR"}'
    exit 0
  fi
fi

# Not a gh pr create command — allow
exit 0
