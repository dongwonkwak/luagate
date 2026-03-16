#!/usr/bin/env bash
# Wrapper for detect-secrets-hook — gracefully skips outside nix develop
# See: flake.nix (python3Packages.detect-secrets)
if command -v detect-secrets-hook >/dev/null 2>&1; then
  exec detect-secrets-hook "$@"
fi
exit 0
