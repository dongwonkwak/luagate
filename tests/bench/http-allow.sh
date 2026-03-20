#!/usr/bin/env bash
# tests/bench/http-allow.sh — HTTP allow throughput benchmark (wrk)
# Measures RPS and latency for requests that pass through policy evaluation.
# NOTE: This measures end-to-end gateway overhead (policy eval + proxy_pass).
# If upstream is unreachable, wrk will report status errors (502) but RPS/latency
# still reflect the gateway processing cost. For pure gateway-only overhead
# without proxy_pass, use BENCH_PATH=/health (skips policy evaluation).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_tool wrk
wait_for_luagate
ensure_results_dir

OUTFILE="${RESULTS_DIR}/http-allow-$(date +%Y%m%d-%H%M%S).txt"

# Target a path that passes through policy evaluation (not /health which skips it)
BENCH_PATH="${BENCH_PATH:-/api/v1/users}"

info "==> HTTP Allow Throughput Benchmark"
info "    URL:         ${LUAGATE_HTTP_URL}${BENCH_PATH}"
info "    Threads:     ${WRK_THREADS}"
info "    Connections: ${WRK_CONNECTIONS}"
info "    Duration:    ${WRK_DURATION}"
echo ""

wrk -t"${WRK_THREADS}" -c"${WRK_CONNECTIONS}" -d"${WRK_DURATION}" \
    -s "${SCRIPT_DIR}/wrk/report.lua" \
    "${LUAGATE_HTTP_URL}${BENCH_PATH}" \
    2>&1 | tee "${OUTFILE}"

ok "Results saved to: ${OUTFILE}"
