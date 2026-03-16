#!/usr/bin/env bash
# Wrapper for markdownlint — gracefully skips outside nix develop
# In CI environments, fails hard if markdownlint is not found.
# See: flake.nix (nodePackages.markdownlint-cli)
if command -v markdownlint >/dev/null 2>&1; then
  exec markdownlint "$@"
fi
if [ -n "${CI:-}" ]; then
  echo "ERROR: markdownlint not found in CI environment" >&2
  exit 1
fi
echo "WARN: markdownlint not found, skipping (run: nix develop)" >&2
exit 0
