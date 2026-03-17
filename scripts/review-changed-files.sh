#!/usr/bin/env bash
# scripts/review-changed-files.sh — Determine the correct diff base and list changed files
#
# Priority:
#   1. PR base branch (if a PR is open for the current branch)
#   2. Fallback: main
#
# Output: changed file paths, one per line (git diff --name-only)

set -euo pipefail

get_diff_base() {
  # 1. Try PR base branch
  local pr_base
  pr_base=$(gh pr view --json baseRefName --jq '.baseRefName' 2>/dev/null || true)
  if [ -n "$pr_base" ]; then
    echo "$pr_base"
    return
  fi

  # 2. Fallback
  echo "main"
}

BASE=$(get_diff_base)
git diff "${BASE}...HEAD" --name-only
