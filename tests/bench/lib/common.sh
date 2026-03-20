#!/usr/bin/env bash
# tests/bench/lib/common.sh — Shared utilities for benchmark scripts
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────
LUAGATE_HTTP_URL="${LUAGATE_HTTP_URL:-http://localhost:8080}"
LUAGATE_STREAM_HOST="${LUAGATE_STREAM_HOST:-localhost}"
LUAGATE_STREAM_PORT="${LUAGATE_STREAM_PORT:-8443}"
LUAGATE_ADMIN_URL="${LUAGATE_ADMIN_URL:-http://localhost:9090}"
LUAGATE_ADMIN_TOKEN="${LUAGATE_ADMIN_TOKEN:-}"

WRK_THREADS="${WRK_THREADS:-4}"
WRK_CONNECTIONS="${WRK_CONNECTIONS:-100}"
WRK_DURATION="${WRK_DURATION:-30s}"

VEGETA_RATE="${VEGETA_RATE:-500}"
VEGETA_DURATION="${VEGETA_DURATION:-30s}"

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="${BENCH_DIR}/results"

# ── Colors ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; }

# ── Health Check ──────────────────────────────────────────────────────────
wait_for_luagate() {
    local url="${1:-${LUAGATE_HTTP_URL}/health}"
    local max_wait="${2:-30}"
    info "Waiting for LuaGate at ${url} (max ${max_wait}s)..."
    local i=0
    while [ "$i" -lt "$max_wait" ]; do
        if curl -sf "$url" > /dev/null 2>&1; then
            ok "LuaGate is ready"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    fail "LuaGate not ready after ${max_wait}s"
    return 1
}

# ── Tool Checks ───────────────────────────────────────────────────────────
require_tool() {
    local tool="$1"
    if ! command -v "$tool" > /dev/null 2>&1; then
        fail "Required tool not found: $tool"
        echo "  Install with: nix-shell -p $tool  OR  brew install $tool"
        return 1
    fi
}

# ── Results Directory ─────────────────────────────────────────────────────
ensure_results_dir() {
    mkdir -p "${RESULTS_DIR}"
}

# ── Timestamp ─────────────────────────────────────────────────────────────
timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# ── Admin API Helper ──────────────────────────────────────────────────────
admin_reload() {
    if [ -z "$LUAGATE_ADMIN_TOKEN" ]; then
        warn "LUAGATE_ADMIN_TOKEN not set — cannot trigger reload"
        return 1
    fi
    curl -sf -X POST "${LUAGATE_ADMIN_URL}/api/v1/policies/reload" \
        -H "Authorization: Bearer ${LUAGATE_ADMIN_TOKEN}" \
        -H "Content-Type: application/json"
}

admin_policy_version() {
    curl -sf "${LUAGATE_HTTP_URL}/health" | grep -o '"policy_version":"[^"]*"' | cut -d'"' -f4
}
