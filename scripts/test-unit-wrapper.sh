#!/bin/bash
# scripts/test-unit-wrapper.sh — pre-push hook wrapper for busted unit tests
# Runs make test-unit only when lua/ or tests/ files have changed
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

  if git diff --name-only "$base_oid" "$local_oid" 2>/dev/null | grep -qE '^(lua/|tests/)'; then
    SHOULD_RUN=1
    break
  fi
done

if [ "$HAS_PUSH_REFS" -eq 0 ]; then
  echo "  no push refs — skipping test-unit"
  exit 0
fi

if [ "$SHOULD_RUN" -eq 1 ]; then
  if command -v busted >/dev/null 2>&1; then
    echo "  lua/ or tests/ changes detected — running test-unit..."
    exec make test-unit
  fi
  if [ -n "${CI:-}" ]; then
    echo "ERROR: busted not found in CI environment" >&2
    exit 1
  fi
  echo "WARN: busted not found, skipping test-unit (run: nix develop)" >&2
  exit 0
else
  echo "  no lua/ or tests/ changes — skipping test-unit"
fi
