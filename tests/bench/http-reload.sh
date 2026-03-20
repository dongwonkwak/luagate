#!/usr/bin/env bash
# tests/bench/http-reload.sh — Hot reload zero-downtime benchmark
# Runs wrk in background while triggering policy reloads.
# Validates: error rate < 0.1%, RPS drop < 5%.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_tool wrk
wait_for_luagate
ensure_results_dir

if [ -z "${LUAGATE_ADMIN_TOKEN:-}" ]; then
    fail "LUAGATE_ADMIN_TOKEN required for reload benchmark"
    exit 1
fi

OUTFILE="${RESULTS_DIR}/http-reload-$(date +%Y%m%d-%H%M%S).txt"
RELOAD_INTERVAL="${RELOAD_INTERVAL:-5}"
RELOAD_COUNT="${RELOAD_COUNT:-6}"

info "==> Hot Reload Zero-Downtime Benchmark"
info "    URL:            ${LUAGATE_HTTP_URL}/health"
info "    Duration:       ${WRK_DURATION}"
info "    Reload every:   ${RELOAD_INTERVAL}s"
info "    Reload count:   ${RELOAD_COUNT}"
echo ""

# Phase 1: Baseline (no reloads)
info "Phase 1: Baseline measurement (no reloads)..."
BASELINE=$(wrk -t"${WRK_THREADS}" -c"${WRK_CONNECTIONS}" -d"${WRK_DURATION}" \
    -s "${SCRIPT_DIR}/wrk/report.lua" \
    "${LUAGATE_HTTP_URL}/health" 2>&1)
echo "$BASELINE" | tee -a "${OUTFILE}"

BASELINE_RPS=$(echo "$BASELINE" | grep "^SUMMARY:" | grep -oP 'rps=\K[0-9.]+')
info "Baseline RPS: ${BASELINE_RPS}"
echo ""

# Phase 2: With reloads
info "Phase 2: Measurement with concurrent reloads..."

# Start wrk in background
wrk -t"${WRK_THREADS}" -c"${WRK_CONNECTIONS}" -d"${WRK_DURATION}" \
    -s "${SCRIPT_DIR}/wrk/report.lua" \
    "${LUAGATE_HTTP_URL}/health" \
    > "${RESULTS_DIR}/_reload_wrk_tmp.txt" 2>&1 &
WRK_PID=$!

# Trigger reloads while wrk is running
sleep 2  # Let wrk warm up
for i in $(seq 1 "${RELOAD_COUNT}"); do
    info "  Triggering reload ${i}/${RELOAD_COUNT}..."
    admin_reload || warn "  Reload ${i} failed"
    sleep "${RELOAD_INTERVAL}"
done

# Wait for wrk to finish
wait $WRK_PID || true
RELOAD_RESULT=$(cat "${RESULTS_DIR}/_reload_wrk_tmp.txt")
echo "$RELOAD_RESULT" | tee -a "${OUTFILE}"
rm -f "${RESULTS_DIR}/_reload_wrk_tmp.txt"

RELOAD_RPS=$(echo "$RELOAD_RESULT" | grep "^SUMMARY:" | grep -oP 'rps=\K[0-9.]+')
RELOAD_ERRORS=$(echo "$RELOAD_RESULT" | grep "^SUMMARY:" | grep -oP 'errors=\K[0-9]+')
RELOAD_ERROR_RATE=$(echo "$RELOAD_RESULT" | grep "^SUMMARY:" | grep -oP 'error_rate=\K[0-9.]+')

echo "" | tee -a "${OUTFILE}"
info "=== Comparison ===" | tee -a "${OUTFILE}"
info "  Baseline RPS:    ${BASELINE_RPS}" | tee -a "${OUTFILE}"
info "  With-Reload RPS: ${RELOAD_RPS}" | tee -a "${OUTFILE}"
info "  Errors:          ${RELOAD_ERRORS}" | tee -a "${OUTFILE}"
info "  Error Rate:      ${RELOAD_ERROR_RATE}%" | tee -a "${OUTFILE}"

# Calculate RPS drop
if command -v bc > /dev/null 2>&1 && [ -n "${BASELINE_RPS}" ] && [ -n "${RELOAD_RPS}" ]; then
    DROP=$(echo "scale=2; (1 - ${RELOAD_RPS} / ${BASELINE_RPS}) * 100" | bc)
    info "  RPS Drop:        ${DROP}%" | tee -a "${OUTFILE}"

    # Validate thresholds
    PASS=true
    if [ "$(echo "${DROP} > 5" | bc)" -eq 1 ]; then
        fail "  RPS drop ${DROP}% exceeds 5% threshold"
        PASS=false
    fi
    if [ "$(echo "${RELOAD_ERROR_RATE} > 0.1" | bc)" -eq 1 ]; then
        fail "  Error rate ${RELOAD_ERROR_RATE}% exceeds 0.1% threshold"
        PASS=false
    fi

    if [ "$PASS" = true ]; then
        ok "  Hot reload zero-downtime: PASS"
    else
        fail "  Hot reload zero-downtime: FAIL"
        exit 1
    fi
fi

ok "Results saved to: ${OUTFILE}"
