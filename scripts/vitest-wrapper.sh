#!/bin/bash
# scripts/vitest-wrapper.sh — pre-push hook wrapper for vitest
# Runs vitest only when ui/ files have changed
# Git pre-push passes: $1=remote_name $2=remote_url, OIDs on stdin
set -euo pipefail

ZERO_OID="0000000000000000000000000000000000000000"
HAS_PUSH_REFS=0
SHOULD_RUN_VITEST=0

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

  if git diff --name-only "$base_oid" "$local_oid" 2>/dev/null | grep -q '^ui/'; then
    SHOULD_RUN_VITEST=1
    break
  fi
done

if [ "$HAS_PUSH_REFS" -eq 0 ]; then
  echo "  no push refs — skipping vitest"
  exit 0
fi

if [ "$SHOULD_RUN_VITEST" -eq 1 ]; then
  echo "  ui/ changes detected — running vitest..."
  cd ui && npx vitest run
else
  echo "  no ui/ changes — skipping vitest"
fi
