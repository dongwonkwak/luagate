#!/bin/bash
# .claude/hooks/post-implement-verify.sh — Claude Code Stop hook
# Runs lint + unit tests after agent completes if code files were changed
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0

FILE_PATTERN='\.(lua|rs|conf|yaml|yml|sh|json|ts|tsx)$'

# Check if there are uncommitted code changes worth verifying
CODE_CHANGES=$(cd "$repo_root" && git diff --name-only HEAD 2>/dev/null | grep -E "$FILE_PATTERN" || true)

if [ -z "$CODE_CHANGES" ]; then
  # Also check staged changes
  CODE_CHANGES=$(cd "$repo_root" && git diff --cached --name-only 2>/dev/null | grep -E "$FILE_PATTERN" || true)
fi

if [ -z "$CODE_CHANGES" ]; then
  # Also check untracked new files
  CODE_CHANGES=$(cd "$repo_root" && git ls-files --others --exclude-standard 2>/dev/null | grep -E "$FILE_PATTERN" || true)
fi

if [ -z "$CODE_CHANGES" ]; then
  exit 0
fi

echo "  post-implement: code changes detected — running lint + test-unit..." >&2
LINT_OK=0
TEST_OK=0
if (cd "$repo_root" && make lint 2>&1 | tail -5 >&2); then
  LINT_OK=1
else
  echo "  post-implement: lint failed" >&2
fi
if (cd "$repo_root" && make test-unit 2>&1 | tail -10 >&2); then
  TEST_OK=1
else
  echo "  post-implement: test-unit failed" >&2
fi
if [ "$LINT_OK" -eq 0 ] || [ "$TEST_OK" -eq 0 ]; then
  echo "  post-implement: lint or test-unit failed — please fix before proceeding" >&2
  exit 0
fi
echo "  post-implement: lint + test-unit passed" >&2
exit 0
