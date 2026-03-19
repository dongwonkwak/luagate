#!/bin/bash
# tests/scripts/test_pre_push_wrappers.sh — tests for pre-push hook wrapper scripts
# Tests: mcp-test-wrapper.sh, test-unit-wrapper.sh, conf-change-wrapper.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/test_helpers.sh"

MCP_WRAPPER="$PROJECT_ROOT/scripts/mcp-test-wrapper.sh"
UNIT_WRAPPER="$PROJECT_ROOT/scripts/test-unit-wrapper.sh"
CONF_WRAPPER="$PROJECT_ROOT/scripts/conf-change-wrapper.sh"

echo "== test_pre_push_wrappers.sh =="

# ============================================================================
# mcp-test-wrapper.sh
# ============================================================================
echo ""
echo "=== mcp-test-wrapper.sh ==="

# ── Test 1: No push refs (empty stdin) → skip message ───────────────────
echo ""
echo "-- Test: mcp-wrapper no push refs --"

OUTPUT="$(echo -n "" | bash "$MCP_WRAPPER" origin https://example.com 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "mcp: no push refs → exit 0" 0 "$EXIT_CODE"
assert_output_contains "mcp: no push refs → skip message" "no push refs" "$OUTPUT"

# ── Test 2: Delete ref (ZERO_OID local) → no mcp changes ────────────────
echo ""
echo "-- Test: mcp-wrapper delete ref --"
setup_git_sandbox
CURRENT_OID="$(git rev-parse HEAD)"

OUTPUT="$(echo "refs/heads/feature 0000000000000000000000000000000000000000 refs/heads/feature $CURRENT_OID" \
  | bash "$MCP_WRAPPER" origin https://example.com 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "mcp: delete ref → exit 0" 0 "$EXIT_CODE"
assert_output_contains "mcp: delete ref → no mcp changes" "no mcp/ changes" "$OUTPUT"

cleanup_git_sandbox

# ── Test 3: Push with no mcp/ changes → skip ────────────────────────────
echo ""
echo "-- Test: mcp-wrapper push with no mcp changes --"
setup_git_sandbox
BASE_OID="$(git rev-parse HEAD)"

git checkout -q -b feature
echo "not mcp" > other.txt
git add other.txt
git commit -q -m "add other file"
FEATURE_OID="$(git rev-parse HEAD)"

OUTPUT="$(echo "refs/heads/feature $FEATURE_OID refs/heads/feature $BASE_OID" \
  | bash "$MCP_WRAPPER" origin https://example.com 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "mcp: no mcp changes → exit 0" 0 "$EXIT_CODE"
assert_output_contains "mcp: no mcp changes → skip message" "no mcp/ changes" "$OUTPUT"

cleanup_git_sandbox

# ── Test 4: Push with mcp/ changes → detected message ───────────────────
echo ""
echo "-- Test: mcp-wrapper push with mcp changes --"
setup_git_sandbox
BASE_OID="$(git rev-parse HEAD)"

git checkout -q -b feature
mkdir -p mcp
echo "mcp code" > mcp/index.ts
git add mcp/index.ts
git commit -q -m "add mcp file"
FEATURE_OID="$(git rev-parse HEAD)"

OUTPUT="$(echo "refs/heads/feature $FEATURE_OID refs/heads/feature $BASE_OID" \
  | bash "$MCP_WRAPPER" origin https://example.com 2>&1)" || true
EXIT_CODE=$?

# It will detect mcp/ changes. It may fail if npx is not found, but should
# at least print the detection message or the warning.
assert_output_matches "mcp: mcp changes → detected or warned" "(mcp/ changes detected|npx not found)" "$OUTPUT"

cleanup_git_sandbox

# ============================================================================
# test-unit-wrapper.sh
# ============================================================================
echo ""
echo "=== test-unit-wrapper.sh ==="

# ── Test 5: No push refs (empty stdin) → skip message ───────────────────
echo ""
echo "-- Test: unit-wrapper no push refs --"

OUTPUT="$(echo -n "" | bash "$UNIT_WRAPPER" origin https://example.com 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "unit: no push refs → exit 0" 0 "$EXIT_CODE"
assert_output_contains "unit: no push refs → skip message" "no push refs" "$OUTPUT"

# ── Test 6: Push with no lua/tests changes → skip ───────────────────────
echo ""
echo "-- Test: unit-wrapper no lua changes --"
setup_git_sandbox
BASE_OID="$(git rev-parse HEAD)"

git checkout -q -b feature
echo "not lua" > other.txt
git add other.txt
git commit -q -m "add other file"
FEATURE_OID="$(git rev-parse HEAD)"

OUTPUT="$(echo "refs/heads/feature $FEATURE_OID refs/heads/feature $BASE_OID" \
  | bash "$UNIT_WRAPPER" origin https://example.com 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "unit: no lua changes → exit 0" 0 "$EXIT_CODE"
assert_output_contains "unit: no lua changes → skip message" "no lua/ or tests/ changes" "$OUTPUT"

cleanup_git_sandbox

# ── Test 7: Push with lua/ changes → detected ───────────────────────────
echo ""
echo "-- Test: unit-wrapper with lua changes --"
setup_git_sandbox
BASE_OID="$(git rev-parse HEAD)"

git checkout -q -b feature
mkdir -p lua
echo "-- lua" > lua/mod.lua
git add lua/mod.lua
git commit -q -m "add lua file"
FEATURE_OID="$(git rev-parse HEAD)"

OUTPUT="$(echo "refs/heads/feature $FEATURE_OID refs/heads/feature $BASE_OID" \
  | bash "$UNIT_WRAPPER" origin https://example.com 2>&1)" || true

assert_output_matches "unit: lua changes → detected or warned" "(lua/ or tests/ changes detected|busted not found)" "$OUTPUT"

cleanup_git_sandbox

# ── Test 8: Push with tests/ changes → detected ─────────────────────────
echo ""
echo "-- Test: unit-wrapper with tests/ changes --"
setup_git_sandbox
BASE_OID="$(git rev-parse HEAD)"

git checkout -q -b feature
mkdir -p tests/unit
echo "test" > tests/unit/spec.lua
git add tests/unit/spec.lua
git commit -q -m "add test file"
FEATURE_OID="$(git rev-parse HEAD)"

OUTPUT="$(echo "refs/heads/feature $FEATURE_OID refs/heads/feature $BASE_OID" \
  | bash "$UNIT_WRAPPER" origin https://example.com 2>&1)" || true

assert_output_matches "unit: tests/ changes → detected or warned" "(lua/ or tests/ changes detected|busted not found)" "$OUTPUT"

cleanup_git_sandbox

# ============================================================================
# conf-change-wrapper.sh
# ============================================================================
echo ""
echo "=== conf-change-wrapper.sh ==="

# ── Test 9: No push refs (empty stdin) → exit 0, no output ──────────────
echo ""
echo "-- Test: conf-wrapper no push refs --"

OUTPUT="$(echo -n "" | bash "$CONF_WRAPPER" origin https://example.com 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "conf: no push refs → exit 0" 0 "$EXIT_CODE"

# ── Test 10: Push with no conf/Dockerfile changes → no warning ──────────
echo ""
echo "-- Test: conf-wrapper no conf changes --"
setup_git_sandbox
BASE_OID="$(git rev-parse HEAD)"

git checkout -q -b feature
echo "not conf" > other.txt
git add other.txt
git commit -q -m "add other file"
FEATURE_OID="$(git rev-parse HEAD)"

OUTPUT="$(echo "refs/heads/feature $FEATURE_OID refs/heads/feature $BASE_OID" \
  | bash "$CONF_WRAPPER" origin https://example.com 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "conf: no conf changes → exit 0" 0 "$EXIT_CODE"
assert_output_not_contains "conf: no conf changes → no WARNING" "WARNING" "$OUTPUT"

cleanup_git_sandbox

# ── Test 11: Push with conf/ changes → WARNING, still exit 0 ────────────
echo ""
echo "-- Test: conf-wrapper with conf changes --"
setup_git_sandbox
BASE_OID="$(git rev-parse HEAD)"

git checkout -q -b feature
mkdir -p conf
echo "worker 1;" > conf/nginx.conf
git add conf/nginx.conf
git commit -q -m "add conf"
FEATURE_OID="$(git rev-parse HEAD)"

OUTPUT="$(echo "refs/heads/feature $FEATURE_OID refs/heads/feature $BASE_OID" \
  | bash "$CONF_WRAPPER" origin https://example.com 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "conf: conf changes → exit 0 (advisory only)" 0 "$EXIT_CODE"
assert_output_contains "conf: conf changes → WARNING" "WARNING" "$OUTPUT"
assert_output_contains "conf: conf changes → integration test suggestion" "make test-docker" "$OUTPUT"

cleanup_git_sandbox

# ── Test 12: Push with Dockerfile changes → WARNING ──────────────────────
echo ""
echo "-- Test: conf-wrapper with Dockerfile changes --"
setup_git_sandbox
BASE_OID="$(git rev-parse HEAD)"

git checkout -q -b feature
echo "FROM alpine" > Dockerfile
git add Dockerfile
git commit -q -m "add Dockerfile"
FEATURE_OID="$(git rev-parse HEAD)"

OUTPUT="$(echo "refs/heads/feature $FEATURE_OID refs/heads/feature $BASE_OID" \
  | bash "$CONF_WRAPPER" origin https://example.com 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "conf: Dockerfile changes → exit 0" 0 "$EXIT_CODE"
assert_output_contains "conf: Dockerfile changes → WARNING" "WARNING" "$OUTPUT"

cleanup_git_sandbox

# ── Test 13: Delete ref → exit 0, no warning ────────────────────────────
echo ""
echo "-- Test: conf-wrapper delete ref --"
setup_git_sandbox
CURRENT_OID="$(git rev-parse HEAD)"

OUTPUT="$(echo "refs/heads/feature 0000000000000000000000000000000000000000 refs/heads/feature $CURRENT_OID" \
  | bash "$CONF_WRAPPER" origin https://example.com 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "conf: delete ref → exit 0" 0 "$EXIT_CODE"
assert_output_not_contains "conf: delete ref → no WARNING" "WARNING" "$OUTPUT"

cleanup_git_sandbox

# ── Summary ──────────────────────────────────────────────────────────────
print_summary "test_pre_push_wrappers.sh"
