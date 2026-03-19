#!/bin/bash
# scripts/tsc-ui-wrapper.sh — pre-push hook wrapper for tsc (ui/)
# Runs tsc -b only when ui/ files have changed
# Git pre-push passes: $1=remote_name $2=remote_url, OIDs on stdin
set -euo pipefail

REMOTE_OID=""
while IFS=' ' read -r _local_ref local_oid _remote_ref remote_oid; do
  if [ "$remote_oid" = "0000000000000000000000000000000000000000" ]; then
    REMOTE_OID="$(git merge-base HEAD main 2>/dev/null || echo HEAD)"
  else
    REMOTE_OID="$remote_oid"
  fi
done

if [ -z "$REMOTE_OID" ]; then
  echo "  no push refs — skipping tsc (ui/)"
  exit 0
fi

if git diff --name-only "$REMOTE_OID" "$local_oid" 2>/dev/null | grep -q '^ui/'; then
  echo "  ui/ changes detected — running tsc -b..."
  cd ui && npx tsc -b
else
  echo "  no ui/ changes — skipping tsc (ui/)"
fi
