#!/usr/bin/env bash
# Wrapper for shellcheck — gracefully skips outside nix develop
# See: flake.nix (shellcheck)
if command -v shellcheck >/dev/null 2>&1; then
  exec shellcheck "$@"
fi
exit 0
