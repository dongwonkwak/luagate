#!/bin/bash
# tests/scripts/run_all.sh — runs all shell script tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OVERALL_EXIT=0

echo "================================================================"
echo "  Shell Script Tests"
echo "================================================================"

for test_file in "$SCRIPT_DIR"/test_*.sh; do
  echo ""
  echo "----------------------------------------------------------------"
  echo "  Running: $(basename "$test_file")"
  echo "----------------------------------------------------------------"
  if bash "$test_file"; then
    :
  else
    OVERALL_EXIT=1
  fi
done

echo ""
if [ "$OVERALL_EXIT" -eq 0 ]; then
  echo "All shell script test suites passed."
else
  echo "Some shell script test suites FAILED." >&2
fi

exit "$OVERALL_EXIT"
