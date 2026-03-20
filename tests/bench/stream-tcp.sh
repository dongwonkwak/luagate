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
TCP_CONCURRENCY="${TCP_CONCURRENCY:-10}"
TCP_DURATION="${TCP_DURATION:-10}"
TCP_MSG_SIZE="${TCP_MSG_SIZE:-1024}"

info "==> TCP Proxy Throughput Benchmark"
info "    Host:        ${LUAGATE_STREAM_HOST}:${LUAGATE_STREAM_PORT}"
info "    Concurrency: ${TCP_CONCURRENCY}"
info "    Duration:    ${TCP_DURATION}s"
info "    Msg Size:    ${TCP_MSG_SIZE} bytes"
echo ""

if command -v ncat > /dev/null 2>&1 || command -v nc > /dev/null 2>&1; then
    NC_CMD="nc"
    command -v ncat > /dev/null 2>&1 && NC_CMD="ncat"

    info "Using ${NC_CMD} for TCP benchmark..."

    # Generate test payload
    PAYLOAD=$(head -c "${TCP_MSG_SIZE}" /dev/urandom | base64 | head -c "${TCP_MSG_SIZE}")

    # Counters (written by subshells via temp files)
    COUNTER_DIR=$(mktemp -d)
    trap 'rm -rf "${COUNTER_DIR}"' EXIT

    # Worker: send messages in a loop for TCP_DURATION seconds
    tcp_worker() {
        local id="$1"
        local success=0
        local fail=0
        local bytes=0
        local end_time=$(( $(date +%s) + TCP_DURATION ))

        while [ "$(date +%s)" -lt "$end_time" ]; do
            if echo "${PAYLOAD}" | timeout 5 "${NC_CMD}" -w 2 "${LUAGATE_STREAM_HOST}" "${LUAGATE_STREAM_PORT}" > /dev/null 2>&1; then
                success=$((success + 1))
                bytes=$((bytes + TCP_MSG_SIZE))
            else
                fail=$((fail + 1))
            fi
        done
        echo "${success} ${fail} ${bytes}" > "${COUNTER_DIR}/worker_${id}"
    }

    START_TIME=$(date +%s%N)

    # Launch concurrent workers
    for i in $(seq 1 "${TCP_CONCURRENCY}"); do
        tcp_worker "$i" &
    done
    wait

    END_TIME=$(date +%s%N)
    ELAPSED_MS=$(( (END_TIME - START_TIME) / 1000000 ))
    ELAPSED_S=$(echo "scale=2; ${ELAPSED_MS} / 1000" | bc 2>/dev/null || echo "0")

    # Aggregate results
    TOTAL_SUCCESS=0
    TOTAL_FAIL=0
    TOTAL_BYTES=0
    for f in "${COUNTER_DIR}"/worker_*; do
        read -r s fl b < "$f"
        TOTAL_SUCCESS=$((TOTAL_SUCCESS + s))
        TOTAL_FAIL=$((TOTAL_FAIL + fl))
        TOTAL_BYTES=$((TOTAL_BYTES + b))
    done

    {
        echo "--- TCP Proxy Benchmark Results ---"
        echo "  Concurrency:           ${TCP_CONCURRENCY}"
        echo "  Duration:              ${ELAPSED_S}s"
        echo "  Connections success:   ${TOTAL_SUCCESS}"
        echo "  Connections failed:    ${TOTAL_FAIL}"
        echo "  Total bytes sent:      ${TOTAL_BYTES}"
        if [ "${ELAPSED_MS}" -gt 0 ]; then
            CPS=$(echo "scale=2; ${TOTAL_SUCCESS} * 1000 / ${ELAPSED_MS}" | bc 2>/dev/null || echo "N/A")
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
