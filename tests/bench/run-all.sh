#!/usr/bin/env bash
# tests/bench/run-all.sh — Run all benchmark scenarios
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

info "=========================================="
info " LuaGate Benchmark Suite"
info " $(timestamp)"
info "=========================================="
echo ""

wait_for_luagate

FAILED=0

run_bench() {
    local name="$1"
    local script="$2"
    echo ""
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info " ${name}"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if bash "${script}"; then
        ok "${name} — DONE"
    else
        fail "${name} — FAILED"
        FAILED=$((FAILED + 1))
    fi
}

# HTTP benchmarks
run_bench "HTTP Allow Throughput"  "${SCRIPT_DIR}/http-allow.sh"
run_bench "HTTP Deny Evaluation"   "${SCRIPT_DIR}/http-deny.sh"

if command -v vegeta > /dev/null 2>&1; then
    run_bench "HTTP SQLi Scanner"  "${SCRIPT_DIR}/http-sqli.sh"
else
    warn "Skipping SQLi benchmark (vegeta not installed)"
fi

# Stream benchmark
if command -v nc > /dev/null 2>&1 || command -v ncat > /dev/null 2>&1; then
    run_bench "TCP Proxy Throughput" "${SCRIPT_DIR}/stream-tcp.sh"
else
    warn "Skipping TCP benchmark (nc/ncat not installed)"
fi

# Hot reload (requires LUAGATE_ADMIN_TOKEN)
if [ -n "${LUAGATE_ADMIN_TOKEN:-}" ]; then
    run_bench "Hot Reload Zero-Downtime" "${SCRIPT_DIR}/http-reload.sh"
else
    warn "Skipping reload benchmark (LUAGATE_ADMIN_TOKEN not set)"
fi

echo ""
info "=========================================="
if [ "$FAILED" -eq 0 ]; then
    ok "All benchmarks completed successfully"
else
    fail "${FAILED} benchmark(s) failed"
    exit 1
fi
info "Results directory: ${RESULTS_DIR}"
