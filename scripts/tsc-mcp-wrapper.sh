#!/bin/bash
# scripts/tsc-mcp-wrapper.sh — pre-push hook wrapper for tsc (mcp/)
# Runs tsc --noEmit only when mcp/ files have changed
# Git pre-push passes: $1=remote_name $2=remote_url, OIDs on stdin
set -euo pipefail

REMOTE_OID=""
LOCAL_OID=""
while IFS=' ' read -r _local_ref local_oid _remote_ref remote_oid; do
  LOCAL_OID="$local_oid"
  if [ "$remote_oid" = "0000000000000000000000000000000000000000" ]; then
    REMOTE_OID="$(git merge-base HEAD main 2>/dev/null || echo HEAD)"
  else
    REMOTE_OID="$remote_oid"
  fi
done

if [ -z "$REMOTE_OID" ] || [ -z "$LOCAL_OID" ]; then
  echo "  no push refs — skipping tsc (mcp/)"
  exit 0
fi

if git diff --name-only "$REMOTE_OID" "$LOCAL_OID" 2>/dev/null | grep -q '^mcp/'; then
  echo "  mcp/ changes detected — running tsc --noEmit..."
  cd mcp && npx tsc --noEmit
else
  echo "  no mcp/ changes — skipping tsc (mcp/)"
fi
