#!/bin/bash
# scripts/eslint-wrapper.sh — pre-commit hook wrapper for eslint
# Runs eslint on staged TypeScript/React files in ui/
set -euo pipefail

filtered=()
for f in "$@"; do
  case "$f" in
    ui/src/*.ts|ui/src/*.tsx)
      filtered+=("$f")
      ;;
  esac
done

if [ ${#filtered[@]} -eq 0 ]; then
  exit 0
fi

cd ui && npx eslint "${filtered[@]/#ui\//}"
