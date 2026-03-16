#!/usr/bin/env bash
# Wrapper for detect-secrets-hook — gracefully skips outside nix develop
# In CI environments, fails hard if detect-secrets-hook is not found.
# See: flake.nix (python3Packages.detect-secrets)
if command -v detect-secrets-hook >/dev/null 2>&1; then
  exec detect-secrets-hook "$@"
fi
if [ -n "${CI:-}" ]; then
  echo "ERROR: detect-secrets-hook not found in CI environment" >&2
  exit 1
fi
echo "WARN: detect-secrets-hook not found, skipping (run: nix develop)" >&2
exit 0
