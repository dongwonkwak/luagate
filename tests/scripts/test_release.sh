#!/bin/bash
# tests/scripts/test_release.sh — tests for scripts/release.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/test_helpers.sh"

RELEASE_SCRIPT="$PROJECT_ROOT/scripts/release.sh"

echo "== test_release.sh =="

# ── Test 1: No version argument → exit with usage error ──────────
echo ""
echo "-- Test: no version argument --"
setup_git_sandbox
OUTPUT="$(bash "$RELEASE_SCRIPT" 2>&1)" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_code "no version → non-zero exit" 1 "$EXIT_CODE"
cleanup_git_sandbox

# ── Test 2: Duplicate tag → exit 1 ───────────────────────────────
echo ""
echo "-- Test: duplicate tag --"
setup_git_sandbox
git tag -a "v1.0.0" -m "existing"
OUTPUT="$(bash "$RELEASE_SCRIPT" "1.0.0" 2>&1)" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_code "duplicate tag → exit 1" 1 "$EXIT_CODE"
assert_output_contains "duplicate tag → error message" "already exists" "$OUTPUT"
cleanup_git_sandbox

# ── Test 3: Uncommitted changes → exit 1 ─────────────────────────
echo ""
echo "-- Test: uncommitted changes --"
setup_git_sandbox
echo "dirty" >> README.md
OUTPUT="$(bash "$RELEASE_SCRIPT" "1.0.0" 2>&1)" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_code "dirty tree → exit 1" 1 "$EXIT_CODE"
assert_output_contains "dirty tree → error message" "uncommitted changes" "$OUTPUT"
cleanup_git_sandbox

# ── Test 4: Staged changes → exit 1 ──────────────────────────────
echo ""
echo "-- Test: staged changes --"
setup_git_sandbox
echo "staged" > newfile.txt
git add newfile.txt
OUTPUT="$(bash "$RELEASE_SCRIPT" "1.0.0" 2>&1)" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_code "staged changes → exit 1" 1 "$EXIT_CODE"
assert_output_contains "staged changes → error message" "staging area" "$OUTPUT"
cleanup_git_sandbox

# ── Test 5: Successful release → creates tag + CHANGELOG ─────────
echo ""
echo "-- Test: successful release --"
setup_git_sandbox
# Add a feat commit
echo "feature" > feature.txt
git add feature.txt
git commit -q -m "feat: add feature"
OUTPUT="$(bash "$RELEASE_SCRIPT" "1.0.0" 2>&1)" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_code "successful release → exit 0" 0 "$EXIT_CODE"
assert_output_contains "success → prepared message" "prepared successfully" "$OUTPUT"

# Verify tag exists
TAG_EXISTS=$(git tag -l "v1.0.0")
if [ -n "$TAG_EXISTS" ]; then
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo -e "  ${GREEN}PASS${NC}: tag v1.0.0 created"
else
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo -e "  ${RED}FAIL${NC}: tag v1.0.0 not created"
  FAILURES="$FAILURES    - tag v1.0.0 not created\n"
fi

# Verify CHANGELOG.md exists and has header
if [ -f CHANGELOG.md ] && head -1 CHANGELOG.md | grep -q "# Changelog"; then
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo -e "  ${GREEN}PASS${NC}: CHANGELOG.md created with header"
else
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo -e "  ${RED}FAIL${NC}: CHANGELOG.md missing or no header"
  FAILURES="$FAILURES    - CHANGELOG.md missing or no header\n"
fi
cleanup_git_sandbox

# ── Test 6: Second release preserves CHANGELOG structure ──────────
echo ""
echo "-- Test: second release preserves CHANGELOG header --"
setup_git_sandbox
echo "feature1" > f1.txt && git add f1.txt && git commit -q -m "feat: first feature"
bash "$RELEASE_SCRIPT" "1.0.0" >/dev/null 2>&1
echo "feature2" > f2.txt && git add f2.txt && git commit -q -m "feat: second feature"
OUTPUT="$(bash "$RELEASE_SCRIPT" "2.0.0" 2>&1)" && EXIT_CODE=0 || EXIT_CODE=$?
assert_exit_code "second release → exit 0" 0 "$EXIT_CODE"

# Verify header is still first line
FIRST_LINE=$(head -1 CHANGELOG.md)
if [ "$FIRST_LINE" = "# Changelog" ]; then
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo -e "  ${GREEN}PASS${NC}: CHANGELOG header preserved after second release"
else
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo -e "  ${RED}FAIL${NC}: CHANGELOG header not preserved (first line: '$FIRST_LINE')"
  FAILURES="$FAILURES    - CHANGELOG header not preserved\n"
fi
cleanup_git_sandbox

# ═══════════════════════════════════════════════════════════════════
print_summary "Release Script Tests"
