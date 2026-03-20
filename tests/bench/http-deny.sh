#!/usr/bin/env bash
# tests/bench/http-deny.sh — HTTP deny throughput benchmark (wrk)
# Measures policy evaluation overhead for requests that get denied.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_tool wrk
wait_for_luagate
ensure_results_dir

OUTFILE="${RESULTS_DIR}/http-deny-$(date +%Y%m%d-%H%M%S).txt"

# Use a path that matches a deny rule in the benchmark policy
DENY_PATH="/admin/secret"

info "==> HTTP Deny Policy Evaluation Benchmark"
info "    URL:         ${LUAGATE_HTTP_URL}${DENY_PATH}"
info "    Threads:     ${WRK_THREADS}"
info "    Connections: ${WRK_CONNECTIONS}"
info "    Duration:    ${WRK_DURATION}"
echo ""

wrk -t"${WRK_THREADS}" -c"${WRK_CONNECTIONS}" -d"${WRK_DURATION}" \
    -s "${SCRIPT_DIR}/wrk/report.lua" \
    "${LUAGATE_HTTP_URL}${DENY_PATH}" \
    2>&1 | tee "${OUTFILE}"

ok "Results saved to: ${OUTFILE}"
