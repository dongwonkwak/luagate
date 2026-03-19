#!/bin/bash
# scripts/conf-change-wrapper.sh — pre-push hook wrapper for conf/ changes
# Prints a warning when conf/ or Dockerfile changes are detected
# Advisory only — never blocks push (always exits 0)
# Git pre-push passes: $1=remote_name $2=remote_url, OIDs on stdin
set -euo pipefail

ZERO_OID="0000000000000000000000000000000000000000"
HAS_PUSH_REFS=0
SHOULD_WARN=0

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

  if git diff --name-only "$base_oid" "$local_oid" 2>/dev/null | grep -qE '^(conf/|Dockerfile)'; then
    SHOULD_WARN=1
    break
  fi
done

if [ "$HAS_PUSH_REFS" -eq 0 ]; then
  exit 0
fi

if [ "$SHOULD_WARN" -eq 1 ]; then
  echo "  WARNING: conf/ or Dockerfile changes detected"
  echo "  Consider running integration tests before merging: make test-docker"
fi

exit 0
