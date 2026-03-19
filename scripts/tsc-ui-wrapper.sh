#!/bin/bash
# scripts/tsc-ui-wrapper.sh — pre-push hook wrapper for tsc (ui/)
# Runs tsc -b only when ui/ files have changed
set -euo pipefail

REMOTE_SHA="${2:-HEAD}"

if git diff --name-only "$REMOTE_SHA" HEAD 2>/dev/null | grep -q '^ui/'; then
  echo "  ui/ changes detected — running tsc -b..."
  cd ui && npx tsc -b
else
  echo "  no ui/ changes — skipping tsc (ui/)"
fi
