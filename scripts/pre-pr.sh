#!/bin/bash
# scripts/pre-pr.sh — pre-PR test gate
# Analyzes branch diff against main and runs relevant test suites
set -euo pipefail

# Determine base branch (prefer local main, fallback to origin/main)
if git rev-parse --verify main >/dev/null 2>&1; then
  BASE="main"
elif git rev-parse --verify origin/main >/dev/null 2>&1; then
  BASE="origin/main"
else
  echo "ERROR: neither 'main' nor 'origin/main' found" >&2
  exit 1
fi

CHANGED_FILES="$(git diff --name-only "$BASE"...HEAD 2>/dev/null || git diff --name-only "$BASE" HEAD)"

if [ -z "$CHANGED_FILES" ]; then
  echo "  No changes detected against $BASE — nothing to test."
  exit 0
fi

# Detect which areas have changes
HAS_LUA=0
HAS_RUST=0
HAS_UI=0
HAS_MCP=0
HAS_CONF=0

if echo "$CHANGED_FILES" | grep -qE '^(lua/|tests/)'; then HAS_LUA=1; fi
if echo "$CHANGED_FILES" | grep -q '^src/'; then HAS_RUST=1; fi
if echo "$CHANGED_FILES" | grep -q '^ui/'; then HAS_UI=1; fi
if echo "$CHANGED_FILES" | grep -q '^mcp/'; then HAS_MCP=1; fi
if echo "$CHANGED_FILES" | grep -qE '^(conf/|Dockerfile)'; then HAS_CONF=1; fi

# Track results
PASS=0
FAIL=0
SKIP=0
FAILURES=""

run_suite() {
  local name="$1"
  shift
  echo ""
  echo "==> [$name] running..."
  if "$@"; then
    echo "  [$name] PASS"
    PASS=$((PASS + 1))
  else
    echo "  [$name] FAIL" >&2
    FAIL=$((FAIL + 1))
    FAILURES="$FAILURES  - $name\n"
  fi
}

skip_suite() {
  local name="$1"
  echo "  [$name] SKIP (no relevant changes)"
  SKIP=$((SKIP + 1))
}

# ── Lua unit tests ──────────────────────────────────────────────────────────
if [ "$HAS_LUA" -eq 1 ]; then
  if command -v busted >/dev/null 2>&1; then
    run_suite "lua-unit" make test-unit-lua
  else
    echo ""
    echo "  [lua-unit] SKIP (busted not found)"
    SKIP=$((SKIP + 1))
  fi
else
  skip_suite "lua-unit"
fi

# ── Rust tests + clippy ─────────────────────────────────────────────────────
if [ "$HAS_RUST" -eq 1 ]; then
  run_suite "rust-test" make test-unit-rust
  if command -v cargo >/dev/null 2>&1; then
    # shellcheck disable=SC2016
    run_suite "rust-clippy" bash -c 'for d in src/decoder src/scanner src/stream; do [ -f "$d/Cargo.toml" ] && (cd "$d" && cargo clippy -- -D warnings) || exit 1; done'
  else
    echo ""
    echo "  [rust-clippy] SKIP (cargo not found)"
    SKIP=$((SKIP + 1))
  fi
else
  skip_suite "rust-test"
  skip_suite "rust-clippy"
fi

# ── UI tests ────────────────────────────────────────────────────────────────
if [ "$HAS_UI" -eq 1 ]; then
  if command -v npx >/dev/null 2>&1; then
    run_suite "ui-vitest" bash -c 'cd ui && npx vitest run'
    run_suite "ui-tsc" bash -c 'cd ui && npx tsc -b'
  else
    echo ""
    echo "  [ui-vitest] SKIP (npx not found)"
    echo "  [ui-tsc] SKIP (npx not found)"
    SKIP=$((SKIP + 2))
  fi
else
  skip_suite "ui-vitest"
  skip_suite "ui-tsc"
fi

# ── MCP tests ───────────────────────────────────────────────────────────────
if [ "$HAS_MCP" -eq 1 ]; then
  if command -v npx >/dev/null 2>&1; then
    run_suite "mcp-test" bash -c 'cd mcp && npx tsc --noEmit && npm test'
  else
    echo ""
    echo "  [mcp-test] SKIP (npx not found)"
    SKIP=$((SKIP + 1))
  fi
else
  skip_suite "mcp-test"
fi

# ── conf/ warning (advisory) ────────────────────────────────────────────────
if [ "$HAS_CONF" -eq 1 ]; then
  echo ""
  echo "  WARNING: conf/ or Dockerfile changes detected"
  echo "  Consider running integration tests: make test-docker"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "  pre-PR test gate summary"
echo "========================================"
echo "  PASS: $PASS  FAIL: $FAIL  SKIP: $SKIP"
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "  Failed suites:"
  echo -e "$FAILURES"
  echo "========================================"
  exit 1
fi
echo "========================================"
exit 0
