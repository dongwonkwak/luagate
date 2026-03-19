#!/bin/bash
# scripts/cargo-clippy-wrapper.sh — pre-push hook wrapper for cargo clippy
# Runs cargo clippy only when src/ (Rust) files have changed
set -euo pipefail

REMOTE_SHA="${2:-HEAD}"

if git diff --name-only "$REMOTE_SHA" HEAD 2>/dev/null | grep -q '^src/'; then
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
