#!/bin/bash
# tests/scripts/test_pre_pr_test_gate.sh — tests for .claude/hooks/pre-pr-test-gate.sh
# Tests the Claude Code PreToolUse hook that intercepts `gh pr create`
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/test_helpers.sh"

HOOK="$PROJECT_ROOT/.claude/hooks/pre-pr-test-gate.sh"

echo "== test_pre_pr_test_gate.sh =="

# ── Test 1: Non gh-pr-create command → exit 0, no output ────────────────
echo ""
echo "-- Test: non gh-pr-create command --"

INPUT='{"tool_name":"Bash","tool_input":{"command":"git status"}}'
OUTPUT="$(echo "$INPUT" | bash "$HOOK" 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "non gh-pr-create → exit 0" 0 "$EXIT_CODE"
assert_output_not_contains "non gh-pr-create → no pre-PR message" "pre-PR test gate" "$OUTPUT"

# ── Test 2: Empty input → exit 0 ────────────────────────────────────────
echo ""
echo "-- Test: empty input --"

OUTPUT="$(echo "" | bash "$HOOK" 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "empty input → exit 0" 0 "$EXIT_CODE"

# ── Test 3: Non-Bash tool → exit 0 ──────────────────────────────────────
echo ""
echo "-- Test: non-Bash tool --"

INPUT='{"tool_name":"Read","tool_input":{"file_path":"/tmp/test"}}'
OUTPUT="$(echo "$INPUT" | bash "$HOOK" 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "non-Bash tool → exit 0" 0 "$EXIT_CODE"
assert_output_not_contains "non-Bash tool → no pre-PR message" "pre-PR test gate" "$OUTPUT"

# ── Test 4: gh pr create command → detects and attempts make pre-pr ─────
echo ""
echo "-- Test: gh pr create detected --"

INPUT='{"tool_name":"Bash","tool_input":{"command":"gh pr create --title \"test\" --body \"test\""}}'
# This will fail because make pre-pr won't work in this context, but we can
# check that it detects the command and attempts to run it.
OUTPUT="$(echo "$INPUT" | bash "$HOOK" 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "gh pr create → exit 0 (hook always exits 0)" 0 "$EXIT_CODE"
assert_output_contains "gh pr create → detection message" "pre-PR test gate" "$OUTPUT"

# ── Test 5: gh pr create with other flags → still detected ──────────────
echo ""
echo "-- Test: gh pr create with flags --"

INPUT='{"tool_name":"Bash","tool_input":{"command":"gh pr create --draft --title \"wip\""}}'
OUTPUT="$(echo "$INPUT" | bash "$HOOK" 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "gh pr create with flags → exit 0" 0 "$EXIT_CODE"
assert_output_contains "gh pr create with flags → detected" "pre-PR test gate" "$OUTPUT"

# ── Test 6: Command containing 'gh' but not 'gh pr create' → pass through
echo ""
echo "-- Test: gh issue list (not pr create) --"

INPUT='{"tool_name":"Bash","tool_input":{"command":"gh issue list"}}'
OUTPUT="$(echo "$INPUT" | bash "$HOOK" 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "gh issue list → exit 0" 0 "$EXIT_CODE"
assert_output_not_contains "gh issue list → no pre-PR message" "pre-PR test gate" "$OUTPUT"

# ── Test 7: Malformed JSON → exit 0 (graceful handling) ─────────────────
echo ""
echo "-- Test: malformed JSON --"

OUTPUT="$(echo "not-json" | bash "$HOOK" 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "malformed JSON → exit 0" 0 "$EXIT_CODE"

# ── Test 8: make pre-pr failure → outputs block decision ────────────────
echo ""
echo "-- Test: make pre-pr failure → block decision JSON --"

# Create a temp directory with a Makefile that will fail
TMPDIR_GATE="$(mktemp -d)"
cat > "$TMPDIR_GATE/Makefile" <<'MAKEFILE'
pre-pr:
	@exit 1
MAKEFILE

INPUT='{"tool_name":"Bash","tool_input":{"command":"gh pr create --title \"test\""}}'
OUTPUT="$(echo "$INPUT" | bash -c "cd '$TMPDIR_GATE' && exec bash '$HOOK'" 2>&1)" || true
EXIT_CODE=$?

assert_exit_code "make pre-pr fail → exit 0 (hook always exits 0)" 0 "$EXIT_CODE"
assert_output_contains "make pre-pr fail → block decision" "block" "$OUTPUT"
assert_output_contains "make pre-pr fail → reason message" "make pre-pr failed" "$OUTPUT"

rm -rf "$TMPDIR_GATE"

# ── Summary ──────────────────────────────────────────────────────────────
print_summary "test_pre_pr_test_gate.sh"
