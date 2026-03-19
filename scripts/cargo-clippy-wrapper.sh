#!/bin/bash
# scripts/cargo-clippy-wrapper.sh — pre-push hook wrapper for cargo clippy
# Runs cargo clippy only when src/ (Rust) files have changed
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
  echo "  no push refs — skipping cargo clippy"
  exit 0
fi

if git diff --name-only "$REMOTE_OID" "$local_oid" 2>/dev/null | grep -q '^src/'; then
  echo "  src/ (Rust) changes detected — running cargo clippy..."
  for crate_dir in src/decoder src/scanner src/stream; do
    if [ -f "$crate_dir/Cargo.toml" ]; then
      echo "    -> $crate_dir"
      (cd "$crate_dir" && cargo clippy -- -D warnings) || exit 1
    fi
  done
else
  echo "  no src/ changes — skipping cargo clippy"
fi
