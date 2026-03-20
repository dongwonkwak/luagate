#!/usr/bin/env bash
# tests/bench/stream-tcp.sh — TCP proxy throughput benchmark
# Measures connection rate and bytes/sec through the stream proxy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

wait_for_luagate
ensure_results_dir

OUTFILE="${RESULTS_DIR}/stream-tcp-$(date +%Y%m%d-%H%M%S).txt"
TCP_CONNECTIONS="${TCP_CONNECTIONS:-100}"
TCP_DURATION="${TCP_DURATION:-10}"
TCP_MSG_SIZE="${TCP_MSG_SIZE:-1024}"

info "==> TCP Proxy Throughput Benchmark"
info "    Host:        ${LUAGATE_STREAM_HOST}:${LUAGATE_STREAM_PORT}"
info "    Connections: ${TCP_CONNECTIONS}"
info "    Duration:    ${TCP_DURATION}s"
info "    Msg Size:    ${TCP_MSG_SIZE} bytes"
echo ""

# Use wrk if available (can test TCP via HTTP upgrade), otherwise use custom approach
if command -v ncat > /dev/null 2>&1 || command -v nc > /dev/null 2>&1; then
    NC_CMD="nc"
    command -v ncat > /dev/null 2>&1 && NC_CMD="ncat"

    info "Using ${NC_CMD} for TCP benchmark..."

    # Generate test payload
    PAYLOAD=$(head -c "${TCP_MSG_SIZE}" /dev/urandom | base64 | head -c "${TCP_MSG_SIZE}")

    # Track metrics
    CONN_SUCCESS=0
    CONN_FAIL=0
    TOTAL_BYTES=0
    START_TIME=$(date +%s%N)

    for i in $(seq 1 "${TCP_CONNECTIONS}"); do
        if echo "${PAYLOAD}" | timeout 5 "${NC_CMD}" -w 2 "${LUAGATE_STREAM_HOST}" "${LUAGATE_STREAM_PORT}" > /dev/null 2>&1; then
            CONN_SUCCESS=$((CONN_SUCCESS + 1))
            TOTAL_BYTES=$((TOTAL_BYTES + TCP_MSG_SIZE))
        else
            CONN_FAIL=$((CONN_FAIL + 1))
        fi

        # Progress every 10 connections
        if [ $((i % 10)) -eq 0 ]; then
            echo -ne "\r  Progress: ${i}/${TCP_CONNECTIONS}"
        fi
    done
    echo ""

    END_TIME=$(date +%s%N)
    ELAPSED_MS=$(( (END_TIME - START_TIME) / 1000000 ))
    ELAPSED_S=$(echo "scale=2; ${ELAPSED_MS} / 1000" | bc 2>/dev/null || echo "0")

    {
        echo "--- TCP Proxy Benchmark Results ---"
        echo "  Connections attempted: ${TCP_CONNECTIONS}"
        echo "  Connections success:   ${CONN_SUCCESS}"
        echo "  Connections failed:    ${CONN_FAIL}"
        echo "  Total bytes sent:      ${TOTAL_BYTES}"
        echo "  Duration:              ${ELAPSED_S}s"
        if [ "${ELAPSED_MS}" -gt 0 ]; then
            CPS=$(echo "scale=2; ${CONN_SUCCESS} * 1000 / ${ELAPSED_MS}" | bc 2>/dev/null || echo "N/A")
            BPS=$(echo "scale=2; ${TOTAL_BYTES} * 1000 / ${ELAPSED_MS} / 1024" | bc 2>/dev/null || echo "N/A")
            echo "  Connections/sec:       ${CPS}"
            echo "  Throughput:            ${BPS} KB/s"
        fi
        echo "--- End Results ---"
    } | tee "${OUTFILE}"
else
    warn "Neither ncat nor nc found. Install nmap (ncat) for TCP benchmarks."
    warn "  nix-shell -p nmap  OR  brew install nmap"
    exit 1
fi

ok "Results saved to: ${OUTFILE}"
