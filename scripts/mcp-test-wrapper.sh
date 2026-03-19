#!/bin/bash
# scripts/mcp-test-wrapper.sh — pre-push hook wrapper for MCP tests
# Runs npm test only when mcp/ files have changed
# NOTE: tsc --noEmit is handled by tsc-mcp-wrapper.sh (no duplication)
# Git pre-push passes: $1=remote_name $2=remote_url, OIDs on stdin
set -euo pipefail

ZERO_OID="0000000000000000000000000000000000000000"
HAS_PUSH_REFS=0
SHOULD_RUN=0

while IFS=' ' read -r _local_ref local_oid _remote_ref remote_oid; do
  HAS_PUSH_REFS=1

  if [ "$local_oid" = "$ZERO_OID" ]; then
    continue
  fi

  if [ "$remote_oid" = "$ZERO_OID" ]; then
    base_oid="$(git merge-base "$local_oid" main 2>/dev/null || echo "$local_oid")"
  else
    base_oid="$remote_oid"
  fi

  if git diff --name-only "$base_oid" "$local_oid" 2>/dev/null | grep -q '^mcp/'; then
    SHOULD_RUN=1
    break
  fi
done

if [ "$HAS_PUSH_REFS" -eq 0 ]; then
  echo "  no push refs — skipping MCP tests"
  exit 0
fi

if [ "$SHOULD_RUN" -eq 1 ]; then
  if ! command -v npx >/dev/null 2>&1; then
    if [ -n "${CI:-}" ]; then
      echo "ERROR: npx not found in CI environment" >&2
      exit 1
    fi
    echo "WARN: npx not found, skipping MCP tests (install Node.js)" >&2
    exit 0
  fi
  echo "  mcp/ changes detected — running MCP tests (npm test)..."
  cd mcp && npm test
else
  echo "  no mcp/ changes — skipping MCP tests"
fi
