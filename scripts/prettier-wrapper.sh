#!/bin/bash
# scripts/prettier-wrapper.sh — pre-commit hook wrapper for prettier
# Runs prettier --check on staged TypeScript/React/CSS files in ui/ and mcp/
set -euo pipefail

filtered=()
for f in "$@"; do
  case "$f" in
    ui/src/*.ts|ui/src/*.tsx|ui/src/*.css|mcp/src/*.ts)
      filtered+=("$f")
      ;;
  esac
done

if [ ${#filtered[@]} -eq 0 ]; then
  exit 0
fi

npx prettier --check "${filtered[@]}"
