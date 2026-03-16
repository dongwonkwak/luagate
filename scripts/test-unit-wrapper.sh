#!/usr/bin/env bash
# Wrapper for make test-unit (pre-push) — gracefully skips outside nix develop
# In CI environments, fails hard if busted is not found.
# See: flake.nix (luajit busted)
if command -v busted >/dev/null 2>&1; then
  exec make test-unit
fi
if [ -n "${CI:-}" ]; then
  echo "ERROR: busted not found in CI environment" >&2
  exit 1
fi
echo "WARN: busted not found, skipping test-unit (run: nix develop)" >&2
exit 0
