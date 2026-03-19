#!/bin/bash
# .claude/hooks/pre-pr-test-gate.sh — Claude Code PreToolUse hook
# Intercepts `gh pr create` commands and runs `make pre-pr` first
set -euo pipefail

run_pre_pr_gate() {
  local repo_root

  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  (
    cd "$repo_root"
    make pre-pr
  ) >&2
}

# Read the PreToolUse JSON from stdin
INPUT="$(cat)"
GH_PR_CREATE_PATTERN='gh[[:space:]]+pr[[:space:]]+create'

# Require jq for JSON parsing — block if unavailable
if ! command -v jq >/dev/null 2>&1; then
  # Fallback: use grep to detect gh pr create in raw input
  if echo "$INPUT" | grep -Eq "$GH_PR_CREATE_PATTERN"; then
    echo "  pre-PR test gate: gh pr create detected (jq unavailable, using fallback) — running make pre-pr..." >&2
    if run_pre_pr_gate; then
      exit 0
    else
      echo '{"decision":"block","reason":"make pre-pr failed — fix test failures before creating PR"}'
      exit 0
    fi
  fi
  exit 0
fi

# Extract the command field from the Bash tool input
COMMAND="$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)" || COMMAND=""

# Check if this is a `gh pr create` command
if echo "$COMMAND" | grep -Eq "$GH_PR_CREATE_PATTERN"; then
  echo "  pre-PR test gate: gh pr create detected — running make pre-pr..." >&2
  if run_pre_pr_gate; then
    # All tests passed — allow the command
    exit 0
  else
    # Tests failed — block the command
    jq -n '{"decision":"block","reason":"make pre-pr failed — fix test failures before creating PR"}'
    exit 0
  fi
fi

# Not a gh pr create command — allow
exit 0
