#!/usr/bin/env bash
# tests/bench/http-sqli.sh — SQLi scanner load benchmark (vegeta)
# Measures scanner throughput when processing SQLi payloads.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_tool vegeta
require_tool python3
wait_for_luagate
ensure_results_dir

OUTFILE="${RESULTS_DIR}/http-sqli-$(date +%Y%m%d-%H%M%S).txt"
TARGETS_FILE="${RESULTS_DIR}/_sqli_targets.txt"

info "==> HTTP SQLi Scanner Load Benchmark (vegeta)"
info "    Rate:     ${VEGETA_RATE} req/s"
info "    Duration: ${VEGETA_DURATION}"
echo ""

# SQLi payloads
PAYLOADS=(
    "1' OR '1'='1"
    "1; DROP TABLE users--"
    "' UNION SELECT * FROM passwords--"
    "1' AND SLEEP(5)--"
    "admin'--"
    "1' OR 1=1 LIMIT 1--"
    "'; EXEC xp_cmdshell('dir')--"
    "1' HAVING 1=1--"
    "' OR ''='"
    "1' ORDER BY 1--"
)

# Generate vegeta targets file
: > "${TARGETS_FILE}"
for payload in "${PAYLOADS[@]}"; do
    encoded=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$payload")
    echo "GET ${LUAGATE_HTTP_URL}/api/v1/users?id=${encoded}" >> "${TARGETS_FILE}"
done

vegeta attack \
    -targets="${TARGETS_FILE}" \
    -rate="${VEGETA_RATE}/s" \
    -duration="${VEGETA_DURATION}" \
    -timeout=10s \
    | vegeta report \
    | tee "${OUTFILE}"

echo ""
info "Generating latency histogram..."
vegeta attack \
    -targets="${TARGETS_FILE}" \
    -rate="${VEGETA_RATE}/s" \
    -duration="5s" \
    -timeout=10s \
    | vegeta report -type='hist[0,1ms,5ms,10ms,50ms,100ms]'

rm -f "${TARGETS_FILE}"
ok "Results saved to: ${OUTFILE}"
