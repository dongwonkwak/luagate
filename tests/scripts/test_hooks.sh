#!/bin/bash
# tests/scripts/test_hooks.sh — tests for Claude Code hooks
# Tests post-implement-verify.sh and pre-review-check.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/test_helpers.sh"

PRE_REVIEW_HOOK="$PROJECT_ROOT/.claude/hooks/pre-review-check.sh"
# shellcheck disable=SC2034
POST_IMPLEMENT_HOOK="$PROJECT_ROOT/.claude/hooks/post-implement-verify.sh"
CHECK_SCRIPT="$PROJECT_ROOT/scripts/check-pending-review.sh"

echo "== test_hooks.sh =="

# ═══════════════════════════════════════════════════════════════════
# pre-review-check.sh tests
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "-- Test: non-review command → exit 0, no block --"
INPUT='{"tool_name":"Bash","tool_input":{"command":"git status"}}'
OUTPUT="$(echo "$INPUT" | bash "$PRE_REVIEW_HOOK" 2>&1)" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_code "non-review command → exit 0" 0 "$EXIT_CODE"
assert_output_not_contains "non-review → no block" "block" "$OUTPUT"

echo ""
echo "-- Test: empty input → exit 0 --"
OUTPUT="$(echo "" | bash "$PRE_REVIEW_HOOK" 2>&1)" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_code "empty input → exit 0" 0 "$EXIT_CODE"

echo ""
echo "-- Test: codex-review command without PROGRESS.md → exit 0 (skip) --"
setup_git_sandbox
INPUT='{"tool_name":"Bash","tool_input":{"command":"./scripts/codex-review.sh DON-100 code"}}'
OUTPUT="$(echo "$INPUT" | bash "$PRE_REVIEW_HOOK" 2>&1)" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_code "no PROGRESS.md → exit 0" 0 "$EXIT_CODE"
assert_output_contains "no PROGRESS.md → skipping" "skipping" "$OUTPUT"
cleanup_git_sandbox

echo ""
echo "-- Test: codex-review with PROGRESS.md missing marker → block --"
setup_git_sandbox
echo "some content without marker" > PROGRESS.md
git add PROGRESS.md && git commit -q -m "add progress"
INPUT='{"tool_name":"Bash","tool_input":{"command":"./scripts/codex-review.sh DON-100 code"}}'
OUTPUT="$(echo "$INPUT" | bash "$PRE_REVIEW_HOOK" 2>&1)" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_code "missing marker → exit 0 (block output)" 0 "$EXIT_CODE"
assert_output_contains "missing marker → block decision" "block" "$OUTPUT"
cleanup_git_sandbox

echo ""
echo "-- Test: codex-review with PROGRESS.md containing marker → pass --"
setup_git_sandbox
echo "DON-100 | something | Codex 리뷰 대기" > PROGRESS.md
git add PROGRESS.md && git commit -q -m "add progress"
INPUT='{"tool_name":"Bash","tool_input":{"command":"./scripts/codex-review.sh DON-100 code"}}'
OUTPUT="$(echo "$INPUT" | bash "$PRE_REVIEW_HOOK" 2>&1)" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_code "marker present → exit 0" 0 "$EXIT_CODE"
assert_output_not_contains "marker present → no block" "block" "$OUTPUT"
assert_output_contains "marker present → found message" "found" "$OUTPUT"
cleanup_git_sandbox

# ═══════════════════════════════════════════════════════════════════
# check-pending-review.sh tests
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "-- Test: check-pending-review.sh with no file → exit 0 --"
setup_git_sandbox
OUTPUT="$(bash "$CHECK_SCRIPT" nonexistent.md 2>&1)" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_code "no file → exit 0" 0 "$EXIT_CODE"
assert_output_contains "no file → not found message" "not found" "$OUTPUT"
cleanup_git_sandbox

echo ""
echo "-- Test: check-pending-review.sh missing marker → exit 1 --"
setup_git_sandbox
echo "no marker here" > PROGRESS.md
OUTPUT="$(bash "$CHECK_SCRIPT" PROGRESS.md 2>&1)" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_code "missing marker → exit 1" 1 "$EXIT_CODE"
cleanup_git_sandbox

echo ""
echo "-- Test: check-pending-review.sh with marker → exit 0 --"
setup_git_sandbox
echo "Codex 리뷰 대기" > PROGRESS.md
OUTPUT="$(bash "$CHECK_SCRIPT" PROGRESS.md 2>&1)" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_code "marker present → exit 0" 0 "$EXIT_CODE"
assert_output_contains "marker present → confirmed" "confirmed" "$OUTPUT"
cleanup_git_sandbox

# ═══════════════════════════════════════════════════════════════════
print_summary "Claude Code Hooks Tests"
