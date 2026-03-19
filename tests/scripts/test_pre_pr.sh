#!/bin/bash
# tests/scripts/test_pre_pr.sh — tests for scripts/pre-pr.sh
# Tests the pre-PR test gate script using a sandboxed git repo
# with mock make/npx/busted/cargo commands to avoid actual test execution
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/test_helpers.sh"

PRE_PR="$PROJECT_ROOT/scripts/pre-pr.sh"

echo "== test_pre_pr.sh =="

# Create a mock bin directory with fake tools that always succeed
MOCK_BIN="$(mktemp -d)"
for cmd in make npx busted cargo; do
  cat > "$MOCK_BIN/$cmd" <<'SCRIPT'
#!/bin/bash
# Mock command — always succeeds
echo "  [mock] $0 $*" >&2
exit 0
SCRIPT
  chmod +x "$MOCK_BIN/$cmd"
done

# Prepend mock bin to PATH so pre-pr.sh uses our mocks
export PATH="$MOCK_BIN:$PATH"

cleanup_mocks() {
  rm -rf "$MOCK_BIN"
}
trap cleanup_mocks EXIT

# ── Test 1: No changes against main → "nothing to test", exit 0 ─────────
echo ""
echo "-- Test: no changes detected --"
setup_git_sandbox

OUTPUT="$(bash "$PRE_PR" 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "no changes → exit 0" 0 "$EXIT_CODE"
assert_output_contains "no changes → 'nothing to test' message" "nothing to test" "$OUTPUT"

cleanup_git_sandbox

# ── Test 2: lua/ changes only → lua-unit runs, others SKIP ──────────────
echo ""
echo "-- Test: lua/ changes only --"
setup_git_sandbox
git checkout -q -b feature-lua
mkdir -p lua
echo "-- lua code" > lua/test.lua
git add lua/test.lua
git commit -q -m "add lua file"

OUTPUT="$(bash "$PRE_PR" 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "lua change → exit 0" 0 "$EXIT_CODE"
assert_output_contains "lua change → rust-test SKIP" "[rust-test] SKIP" "$OUTPUT"
assert_output_contains "lua change → rust-clippy SKIP" "[rust-clippy] SKIP" "$OUTPUT"
assert_output_contains "lua change → ui-vitest SKIP" "[ui-vitest] SKIP" "$OUTPUT"
assert_output_contains "lua change → ui-tsc SKIP" "[ui-tsc] SKIP" "$OUTPUT"
assert_output_contains "lua change → mcp-test SKIP" "[mcp-test] SKIP" "$OUTPUT"
assert_output_not_contains "lua change → no conf warning" "WARNING: conf/ or Dockerfile" "$OUTPUT"
assert_output_not_contains "lua change → lua-unit not 'no relevant changes' SKIP" "[lua-unit] SKIP (no relevant changes)" "$OUTPUT"
assert_output_contains "lua change → lua-unit PASS" "[lua-unit] PASS" "$OUTPUT"
assert_output_contains "summary present" "pre-PR test gate summary" "$OUTPUT"

cleanup_git_sandbox

# ── Test 3: src/ changes only → rust suites run, others SKIP ────────────
echo ""
echo "-- Test: src/ changes only --"
setup_git_sandbox
git checkout -q -b feature-rust
mkdir -p src
echo "fn main() {}" > src/lib.rs
git add src/lib.rs
git commit -q -m "add rust file"

OUTPUT="$(bash "$PRE_PR" 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "rust change → exit 0" 0 "$EXIT_CODE"
assert_output_contains "rust change → lua-unit SKIP" "[lua-unit] SKIP (no relevant changes)" "$OUTPUT"
assert_output_not_contains "rust change → rust-test not 'no relevant changes' SKIP" "[rust-test] SKIP (no relevant changes)" "$OUTPUT"
assert_output_contains "rust change → ui-vitest SKIP" "[ui-vitest] SKIP" "$OUTPUT"
assert_output_contains "rust change → mcp-test SKIP" "[mcp-test] SKIP" "$OUTPUT"
assert_output_contains "rust change → rust-test PASS" "[rust-test] PASS" "$OUTPUT"

cleanup_git_sandbox

# ── Test 4: ui/ changes only → ui suites run, others SKIP ──────────────
echo ""
echo "-- Test: ui/ changes only --"
setup_git_sandbox
git checkout -q -b feature-ui
mkdir -p ui
echo "export default {}" > ui/App.tsx
git add ui/App.tsx
git commit -q -m "add ui file"

OUTPUT="$(bash "$PRE_PR" 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "ui change → exit 0" 0 "$EXIT_CODE"
assert_output_contains "ui change → lua-unit SKIP" "[lua-unit] SKIP (no relevant changes)" "$OUTPUT"
assert_output_contains "ui change → rust-test SKIP" "[rust-test] SKIP (no relevant changes)" "$OUTPUT"
assert_output_contains "ui change → mcp-test SKIP" "[mcp-test] SKIP" "$OUTPUT"
assert_output_not_contains "ui change → ui-vitest not 'no relevant changes' SKIP" "[ui-vitest] SKIP (no relevant changes)" "$OUTPUT"

cleanup_git_sandbox

# ── Test 5: mcp/ changes only → mcp suite runs, others SKIP ─────────────
echo ""
echo "-- Test: mcp/ changes only --"
setup_git_sandbox
git checkout -q -b feature-mcp
mkdir -p mcp
echo "console.log('mcp')" > mcp/index.ts
git add mcp/index.ts
git commit -q -m "add mcp file"

OUTPUT="$(bash "$PRE_PR" 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "mcp change → exit 0" 0 "$EXIT_CODE"
assert_output_contains "mcp change → lua-unit SKIP" "[lua-unit] SKIP (no relevant changes)" "$OUTPUT"
assert_output_contains "mcp change → rust-test SKIP" "[rust-test] SKIP (no relevant changes)" "$OUTPUT"
assert_output_contains "mcp change → ui-vitest SKIP" "[ui-vitest] SKIP (no relevant changes)" "$OUTPUT"
assert_output_not_contains "mcp change → mcp-test not 'no relevant changes' SKIP" "[mcp-test] SKIP (no relevant changes)" "$OUTPUT"

cleanup_git_sandbox

# ── Test 6: conf/ changes → WARNING message ─────────────────────────────
echo ""
echo "-- Test: conf/ changes only --"
setup_git_sandbox
git checkout -q -b feature-conf
mkdir -p conf
echo "worker_processes 1;" > conf/nginx.conf
git add conf/nginx.conf
git commit -q -m "add conf file"

OUTPUT="$(bash "$PRE_PR" 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "conf change → exit 0" 0 "$EXIT_CODE"
assert_output_contains "conf change → WARNING present" "WARNING: conf/ or Dockerfile" "$OUTPUT"
assert_output_contains "conf change → integration test suggestion" "make test-docker" "$OUTPUT"
assert_output_contains "conf change → lua-unit SKIP" "[lua-unit] SKIP" "$OUTPUT"
assert_output_contains "conf change → rust-test SKIP" "[rust-test] SKIP" "$OUTPUT"

cleanup_git_sandbox

# ── Test 7: Dockerfile changes → WARNING message ────────────────────────
echo ""
echo "-- Test: Dockerfile changes --"
setup_git_sandbox
git checkout -q -b feature-docker
echo "FROM nginx" > Dockerfile
git add Dockerfile
git commit -q -m "add Dockerfile"

OUTPUT="$(bash "$PRE_PR" 2>&1)" || true

assert_output_contains "Dockerfile change → WARNING present" "WARNING: conf/ or Dockerfile" "$OUTPUT"

cleanup_git_sandbox

# ── Test 8: Multiple areas changed → multiple suites detected ───────────
echo ""
echo "-- Test: lua/ + ui/ changes --"
setup_git_sandbox
git checkout -q -b feature-multi
mkdir -p lua ui
echo "-- lua" > lua/mod.lua
echo "export {}" > ui/Comp.tsx
git add lua/mod.lua ui/Comp.tsx
git commit -q -m "add lua and ui files"

OUTPUT="$(bash "$PRE_PR" 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "multi change → exit 0" 0 "$EXIT_CODE"
assert_output_not_contains "multi change → lua-unit detected" "[lua-unit] SKIP (no relevant changes)" "$OUTPUT"
assert_output_not_contains "multi change → ui-vitest detected" "[ui-vitest] SKIP (no relevant changes)" "$OUTPUT"
assert_output_contains "multi change → rust-test SKIP" "[rust-test] SKIP (no relevant changes)" "$OUTPUT"
assert_output_contains "multi change → mcp-test SKIP" "[mcp-test] SKIP" "$OUTPUT"

cleanup_git_sandbox

# ── Test 9: tests/ changes trigger lua-unit ──────────────────────────────
echo ""
echo "-- Test: tests/ changes trigger lua-unit --"
setup_git_sandbox
git checkout -q -b feature-tests
mkdir -p tests/unit
echo "describe('test', function() end)" > tests/unit/new_spec.lua
git add tests/unit/new_spec.lua
git commit -q -m "add test file"

OUTPUT="$(bash "$PRE_PR" 2>&1)" || true

assert_output_not_contains "tests/ change → lua-unit detected" "[lua-unit] SKIP (no relevant changes)" "$OUTPUT"
assert_output_contains "tests/ change → lua-unit PASS" "[lua-unit] PASS" "$OUTPUT"

cleanup_git_sandbox

# ── Test 10: Summary format includes PASS/FAIL/SKIP counts ──────────────
echo ""
echo "-- Test: summary format --"
setup_git_sandbox
git checkout -q -b feature-summary
mkdir -p lua
echo "-- test" > lua/summary.lua
git add lua/summary.lua
git commit -q -m "add file for summary test"

OUTPUT="$(bash "$PRE_PR" 2>&1)" || true

assert_output_matches "summary has PASS/FAIL/SKIP" "PASS:.*FAIL:.*SKIP:" "$OUTPUT"

cleanup_git_sandbox

# ── Test 11: Suite failure → exit 1 + FAIL count ────────────────────────
echo ""
echo "-- Test: suite failure --"

# Create a mock 'make' that fails for test-unit-lua
FAIL_BIN="$(mktemp -d)"
cat > "$FAIL_BIN/make" <<'SCRIPT'
#!/bin/bash
if [[ "$*" == *"test-unit-lua"* ]]; then
  exit 1
fi
exit 0
SCRIPT
chmod +x "$FAIL_BIN/make"
for cmd in npx busted cargo; do
  cat > "$FAIL_BIN/$cmd" <<'SCRIPT2'
#!/bin/bash
exit 0
SCRIPT2
  chmod +x "$FAIL_BIN/$cmd"
done

setup_git_sandbox
git checkout -q -b feature-fail
mkdir -p lua
echo "-- fail" > lua/fail.lua
git add lua/fail.lua
git commit -q -m "add failing lua file"

# Replace MOCK_BIN with FAIL_BIN at the front of PATH
SAVED_PATH="$PATH"
CLEAN_PATH="${PATH//$MOCK_BIN:/}"
export PATH="$FAIL_BIN:$CLEAN_PATH"
OUTPUT="$(bash "$PRE_PR" 2>&1)" && EXIT_CODE=0 || EXIT_CODE=$?
export PATH="$SAVED_PATH"

assert_exit_code "suite failure → exit 1" 1 "$EXIT_CODE"
assert_output_contains "suite failure → FAIL count" "FAIL: 1" "$OUTPUT"
assert_output_contains "suite failure → Failed suites listed" "Failed suites:" "$OUTPUT"
assert_output_contains "suite failure → lua-unit in failures" "lua-unit" "$OUTPUT"

cleanup_git_sandbox
rm -rf "$FAIL_BIN"

# ── Test 12: All areas changed → all suites detected ────────────────────
echo ""
echo "-- Test: all areas changed --"
setup_git_sandbox
git checkout -q -b feature-all
mkdir -p lua src ui mcp conf
echo "-- lua" > lua/mod.lua
echo "fn x(){}" > src/lib.rs
echo "export {}" > ui/App.tsx
echo "console.log('x')" > mcp/index.ts
echo "worker 1;" > conf/nginx.conf
git add lua/mod.lua src/lib.rs ui/App.tsx mcp/index.ts conf/nginx.conf
git commit -q -m "add all"

OUTPUT="$(bash "$PRE_PR" 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "all areas → exit 0" 0 "$EXIT_CODE"
assert_output_not_contains "all areas → lua-unit not skipped" "[lua-unit] SKIP (no relevant changes)" "$OUTPUT"
assert_output_not_contains "all areas → rust-test not skipped" "[rust-test] SKIP (no relevant changes)" "$OUTPUT"
assert_output_not_contains "all areas → ui-vitest not skipped" "[ui-vitest] SKIP (no relevant changes)" "$OUTPUT"
assert_output_not_contains "all areas → mcp-test not skipped" "[mcp-test] SKIP (no relevant changes)" "$OUTPUT"
assert_output_contains "all areas → conf WARNING" "WARNING: conf/ or Dockerfile" "$OUTPUT"

cleanup_git_sandbox

# ── Summary ──────────────────────────────────────────────────────────────
print_summary "test_pre_pr.sh"
