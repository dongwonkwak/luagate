#!/bin/bash
# scripts/tsc-ui-wrapper.sh — pre-push hook wrapper for tsc (ui/)
# Runs tsc -b only when ui/ files have changed
# Git pre-push passes: $1=remote_name $2=remote_url, OIDs on stdin
set -euo pipefail

REMOTE_OID=""
LOCAL_OID=""
while IFS=' ' read -r _local_ref local_oid _remote_ref remote_oid; do
  LOCAL_OID="$local_oid"
  if [ "$remote_oid" = "0000000000000000000000000000000000000000" ]; then
    REMOTE_OID="$(git merge-base "$local_oid" main 2>/dev/null || echo "$local_oid")"
  else
    REMOTE_OID="$remote_oid"
  fi
done

if [ -z "$REMOTE_OID" ] || [ -z "$LOCAL_OID" ]; then
  echo "  no push refs — skipping tsc (ui/)"
  exit 0
fi

if git diff --name-only "$REMOTE_OID" "$LOCAL_OID" 2>/dev/null | grep -q '^ui/'; then
  echo "  ui/ changes detected — running tsc -b..."
  cd ui && npx tsc -b
else
  echo "  no ui/ changes — skipping tsc (ui/)"
fi
