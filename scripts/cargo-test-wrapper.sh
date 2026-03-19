#!/bin/bash
# scripts/cargo-test-wrapper.sh — pre-push hook wrapper for cargo test
# Runs cargo test only when src/ (Rust) files have changed
set -euo pipefail

REMOTE_SHA="${2:-HEAD}"

if git diff --name-only "$REMOTE_SHA" HEAD 2>/dev/null | grep -q '^src/'; then
  echo "  src/ (Rust) changes detected — running cargo test..."
  for crate_dir in src/decoder src/scanner src/stream; do
    if [ -f "$crate_dir/Cargo.toml" ]; then
      echo "    -> $crate_dir"
      if [ "$crate_dir" = "src/scanner" ]; then
        (cd "$crate_dir" && cargo test -- --test-threads=1) || exit 1
      else
        (cd "$crate_dir" && cargo test) || exit 1
      fi
    fi
  done
else
  echo "  no src/ changes — skipping cargo test"
fi
