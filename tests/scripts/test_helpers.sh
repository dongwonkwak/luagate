#!/bin/bash
# tests/scripts/test_helpers.sh — shared test utilities for shell script tests
# Source this file from test scripts.

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILURES=""

# Colors (only if terminal supports it)
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  NC='\033[0m'
else
  GREEN=''
  RED=''
  NC=''
fi

# assert_exit_code <description> <expected_code> <actual_code>
assert_exit_code() {
  local desc="$1" expected="$2" actual="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$expected" -eq "$actual" ]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected exit $expected, got $actual)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILURES="$FAILURES    - $desc\n"
  fi
}

# assert_output_contains <description> <substring> <output>
assert_output_contains() {
  local desc="$1" substring="$2" output="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if echo "$output" | grep -qF "$substring"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (output does not contain '$substring')"
    echo "    actual output: $(echo "$output" | head -5)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILURES="$FAILURES    - $desc\n"
  fi
}

# assert_output_not_contains <description> <substring> <output>
assert_output_not_contains() {
  local desc="$1" substring="$2" output="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if ! echo "$output" | grep -qF "$substring"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (output unexpectedly contains '$substring')"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILURES="$FAILURES    - $desc\n"
  fi
}

# assert_output_matches <description> <regex> <output>
assert_output_matches() {
  local desc="$1" regex="$2" output="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if echo "$output" | grep -qE "$regex"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (output does not match regex '$regex')"
    echo "    actual output: $(echo "$output" | head -5)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILURES="$FAILURES    - $desc\n"
  fi
}

# print_summary — call at the end of each test file
print_summary() {
  local test_name="${1:-tests}"
  echo ""
  echo "========================================"
  echo "  $test_name"
  echo "========================================"
  echo "  TOTAL: $TESTS_RUN  PASS: $TESTS_PASSED  FAIL: $TESTS_FAILED"
  if [ "$TESTS_FAILED" -gt 0 ]; then
    echo ""
    echo "  Failed:"
    echo -e "$FAILURES"
    echo "========================================"
    return 1
  fi
  echo "========================================"
  return 0
}

# setup_git_sandbox — creates a temporary git repo for testing
# Sets SANDBOX_DIR and exports it
setup_git_sandbox() {
  SANDBOX_DIR="$(mktemp -d)"
  cd "$SANDBOX_DIR" || exit 1
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  # Create an initial commit on main
  echo "init" > README.md
  git add README.md
  git commit -q -m "initial"
  git branch -M main
}

# cleanup_git_sandbox — removes the temporary directory
cleanup_git_sandbox() {
  if [ -n "${SANDBOX_DIR:-}" ] && [ -d "$SANDBOX_DIR" ]; then
    rm -rf "$SANDBOX_DIR"
  fi
}
