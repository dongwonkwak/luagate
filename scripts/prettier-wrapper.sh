#!/bin/bash
# scripts/prettier-wrapper.sh — pre-commit hook wrapper for prettier
# Runs prettier --check on staged TypeScript/React/CSS files in ui/ and mcp/
# prettier is installed per-package (ui/node_modules, mcp/node_modules)
set -euo pipefail

ui_files=()
mcp_files=()
for f in "$@"; do
  case "$f" in
    ui/src/*.ts|ui/src/*.tsx|ui/src/*.css)
      ui_files+=("${f#ui/}")
      ;;
    mcp/src/*.ts)
      mcp_files+=("${f#mcp/}")
      ;;
  esac
done

status=0

if [ ${#ui_files[@]} -gt 0 ]; then
  (cd ui && npx prettier --check "${ui_files[@]}") || status=1
fi

if [ ${#mcp_files[@]} -gt 0 ]; then
  (cd mcp && npx prettier --check "${mcp_files[@]}") || status=1
fi

exit $status
