#!/bin/bash
# scripts/tsc-mcp-wrapper.sh — pre-push hook wrapper for tsc (mcp/)
# Runs tsc --noEmit only when mcp/ files have changed
set -euo pipefail

REMOTE_SHA="${2:-HEAD}"

if git diff --name-only "$REMOTE_SHA" HEAD 2>/dev/null | grep -q '^mcp/'; then
  echo "  mcp/ changes detected — running tsc --noEmit..."
  cd mcp && npx tsc --noEmit
else
  echo "  no mcp/ changes — skipping tsc (mcp/)"
fi
