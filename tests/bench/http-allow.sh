#!/usr/bin/env bash
# tests/bench/http-allow.sh — HTTP allow throughput benchmark (wrk)
# Measures RPS and latency for requests that pass policy evaluation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_tool wrk
wait_for_luagate
ensure_results_dir

OUTFILE="${RESULTS_DIR}/http-allow-$(date +%Y%m%d-%H%M%S).txt"

info "==> HTTP Allow Throughput Benchmark"
info "    URL:         ${LUAGATE_HTTP_URL}/health"
info "    Threads:     ${WRK_THREADS}"
info "    Connections: ${WRK_CONNECTIONS}"
info "    Duration:    ${WRK_DURATION}"
echo ""

wrk -t"${WRK_THREADS}" -c"${WRK_CONNECTIONS}" -d"${WRK_DURATION}" \
    -s "${SCRIPT_DIR}/wrk/report.lua" \
    "${LUAGATE_HTTP_URL}/health" \
    2>&1 | tee "${OUTFILE}"

ok "Results saved to: ${OUTFILE}"
