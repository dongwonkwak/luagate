#!/usr/bin/env bash
# Wrapper for luacheck full project lint (pre-push) — gracefully skips outside nix develop
# In CI environments, fails hard if luacheck is not found.
# See: flake.nix (luaPackages.luacheck)
if command -v luacheck >/dev/null 2>&1; then
  exec luacheck lua/ tests/
fi
if [ -n "${CI:-}" ]; then
  echo "ERROR: luacheck not found in CI environment" >&2
  exit 1
fi
echo "WARN: luacheck not found, skipping full lint (run: nix develop)" >&2
exit 0
