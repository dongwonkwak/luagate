#!/usr/bin/env bash
# Wrapper for shellcheck — gracefully skips outside nix develop
# In CI environments, fails hard if shellcheck is not found.
# See: flake.nix (shellcheck)
if command -v shellcheck >/dev/null 2>&1; then
  exec shellcheck "$@"
fi
if [ -n "${CI:-}" ]; then
  echo "ERROR: shellcheck not found in CI environment" >&2
  exit 1
fi
echo "WARN: shellcheck not found, skipping (run: nix develop)" >&2
exit 0
