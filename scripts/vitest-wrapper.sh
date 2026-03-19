#!/bin/bash
# scripts/vitest-wrapper.sh — pre-push hook wrapper for vitest
# Runs vitest only when ui/ files have changed
set -euo pipefail

REMOTE_SHA="${2:-HEAD}"

if git diff --name-only "$REMOTE_SHA" HEAD 2>/dev/null | grep -q '^ui/'; then
  echo "  ui/ changes detected — running vitest..."
  cd ui && npx vitest run
else
  echo "  no ui/ changes — skipping vitest"
fi
