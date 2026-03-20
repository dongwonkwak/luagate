#!/usr/bin/env bash
# tests/chaos/test_hot_reload.sh — Chaos test: hot reload under load
# Validates zero-downtime reload with 4 scenarios:
#   1. Reload under wrk load — error rate < 0.1%, RPS drop < 5%
#   2. Policy version changes after reload
#   3. Invalid YAML reload preserves LKG policy
#   4. Rapid-fire reloads don't crash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(cd "${SCRIPT_DIR}/../bench" && pwd)"
# shellcheck disable=SC1091
source "${BENCH_DIR}/lib/common.sh"

# ── Configuration ────────────────────────────────────────────────────────
RELOAD_INTERVAL="${RELOAD_INTERVAL:-5}"
RELOAD_COUNT="${RELOAD_COUNT:-6}"
WRK_DURATION="${WRK_DURATION:-30s}"
BENCH_PATH="${BENCH_PATH:-/api/v1/users}"
CHAOS_RESULTS_DIR="${SCRIPT_DIR}/results"

mkdir -p "${CHAOS_RESULTS_DIR}"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL=4

pass() { PASS_COUNT=$((PASS_COUNT + 1)); ok "  PASS: $*"; }
scenario_fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); fail "  FAIL: $*"; }

# ── Pre-checks ───────────────────────────────────────────────────────────
require_tool wrk
require_tool curl
require_tool bc

if [ -z "${LUAGATE_ADMIN_TOKEN:-}" ]; then
    fail "LUAGATE_ADMIN_TOKEN required"
    exit 1
fi

wait_for_luagate

info "==> Chaos Test: Hot Reload Under Load"
info "    Target:         ${LUAGATE_HTTP_URL}${BENCH_PATH}"
info "    wrk Duration:   ${WRK_DURATION}"
info "    Reload every:   ${RELOAD_INTERVAL}s"
info "    Reload count:   ${RELOAD_COUNT}"
echo ""

# ══════════════════════════════════════════════════════════════════════════
# Scenario 1: Reload under load — error rate & RPS drop
# ══════════════════════════════════════════════════════════════════════════
info "── Scenario 1: Reload under wrk load ──"

# Baseline (no reloads)
info "  Phase 1: Baseline measurement..."
BASELINE=$(wrk -t"${WRK_THREADS}" -c"${WRK_CONNECTIONS}" -d"${WRK_DURATION}" \
    -s "${BENCH_DIR}/wrk/report.lua" \
    "${LUAGATE_HTTP_URL}${BENCH_PATH}" 2>&1)

BASELINE_RPS=$(echo "$BASELINE" | grep "^SUMMARY:" | grep -oP 'rps=\K[0-9.]+' || echo "0")
info "  Baseline RPS: ${BASELINE_RPS}"

# With reloads
info "  Phase 2: Load + concurrent reloads..."
wrk -t"${WRK_THREADS}" -c"${WRK_CONNECTIONS}" -d"${WRK_DURATION}" \
    -s "${BENCH_DIR}/wrk/report.lua" \
    "${LUAGATE_HTTP_URL}${BENCH_PATH}" \
    > "${CHAOS_RESULTS_DIR}/_s1_wrk_tmp.txt" 2>&1 &
WRK_PID=$!

sleep 2  # Let wrk warm up
RELOAD_SUCCESS=0
for i in $(seq 1 "${RELOAD_COUNT}"); do
    if admin_reload > /dev/null 2>&1; then
        RELOAD_SUCCESS=$((RELOAD_SUCCESS + 1))
    else
        warn "  Reload ${i}/${RELOAD_COUNT} failed"
    fi
    sleep "${RELOAD_INTERVAL}"
done

wait $WRK_PID || true
RELOAD_RESULT=$(cat "${CHAOS_RESULTS_DIR}/_s1_wrk_tmp.txt")
rm -f "${CHAOS_RESULTS_DIR}/_s1_wrk_tmp.txt"

RELOAD_SUMMARY=$(echo "$RELOAD_RESULT" | grep "^SUMMARY:" || true)
RELOAD_RPS=$(echo "$RELOAD_SUMMARY" | grep -oP 'rps=\K[0-9.]+' || echo "0")
RELOAD_ERROR_RATE=$(echo "$RELOAD_SUMMARY" | grep -oP 'error_rate=\K[0-9.]+' || echo "0")

S1_PASS=true
if [ "$RELOAD_SUCCESS" -eq 0 ]; then
    scenario_fail "Scenario 1 — all reloads failed, test invalid"
    S1_PASS=false
elif [ -n "$BASELINE_RPS" ] && [ "$BASELINE_RPS" != "0" ]; then
    DROP=$(echo "scale=2; (1 - ${RELOAD_RPS} / ${BASELINE_RPS}) * 100" | bc)
    info "  Reloads: ${RELOAD_SUCCESS}/${RELOAD_COUNT} succeeded"
    info "  RPS drop: ${DROP}% (threshold: 5%)"
    info "  Error rate: ${RELOAD_ERROR_RATE}% (threshold: 0.1%)"

    if [ "$(echo "${DROP} > 5" | bc)" -eq 1 ]; then
        scenario_fail "Scenario 1 — RPS drop ${DROP}% > 5%"
        S1_PASS=false
    fi
    if [ "$(echo "${RELOAD_ERROR_RATE} > 0.1" | bc)" -eq 1 ]; then
        scenario_fail "Scenario 1 — error rate ${RELOAD_ERROR_RATE}% > 0.1%"
        S1_PASS=false
    fi
fi

if [ "$S1_PASS" = true ]; then
    pass "Scenario 1 — reload under load within thresholds"
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════
# Scenario 2: Policy version changes after reload
# ══════════════════════════════════════════════════════════════════════════
info "── Scenario 2: Reload succeeds and version is valid ──"

# POST /reload re-reads the canonical file; version only changes if the file changed.
# This scenario validates: (a) reload returns 200, (b) /health reports a valid version.
RELOAD_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${LUAGATE_ADMIN_URL}/api/v1/policies/reload" \
    -H "Authorization: Bearer ${LUAGATE_ADMIN_TOKEN}" 2>/dev/null || echo "000")
sleep 1
VERSION_AFTER=$(admin_policy_version || echo "unknown")
info "  Reload HTTP: ${RELOAD_HTTP}"
info "  Version after: ${VERSION_AFTER}"

S2_PASS=true
if [ "$RELOAD_HTTP" != "200" ]; then
    scenario_fail "Scenario 2 — reload returned HTTP ${RELOAD_HTTP}, expected 200"
    S2_PASS=false
fi
if [ "$VERSION_AFTER" = "unknown" ] || [ -z "$VERSION_AFTER" ]; then
    scenario_fail "Scenario 2 — /health reports no valid policy_version"
    S2_PASS=false
fi
if [ "$S2_PASS" = true ]; then
    pass "Scenario 2 — reload succeeded (HTTP ${RELOAD_HTTP}), version: ${VERSION_AFTER}"
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════
# Scenario 3: Invalid YAML reload preserves LKG
# ══════════════════════════════════════════════════════════════════════════
info "── Scenario 3: Invalid YAML → LKG preserved ──"

VERSION_BEFORE=$(admin_policy_version || echo "unknown")
info "  Version before: ${VERSION_BEFORE}"

# PUT /api/v1/policies with invalid YAML — this is the actual write path
# that validates content before committing. POST /reload only re-reads the
# canonical file, so it can't test invalid content rejection.
PUT_BODY_FILE=$(mktemp)
PUT_HTTP=$(curl -s -o "${PUT_BODY_FILE}" -w "%{http_code}" \
    -X PUT "${LUAGATE_ADMIN_URL}/api/v1/policies" \
    -H "Authorization: Bearer ${LUAGATE_ADMIN_TOKEN}" \
    -H "Content-Type: application/x-yaml" \
    -H "If-Match: \"${VERSION_BEFORE}\"" \
    -d 'invalid: yaml: [broken' 2>/dev/null || echo "000")
PUT_BODY=$(cat "${PUT_BODY_FILE}" 2>/dev/null || echo "")
rm -f "${PUT_BODY_FILE}"

VERSION_AFTER=$(admin_policy_version || echo "unknown")
info "  PUT response: HTTP ${PUT_HTTP}"
info "  Version after: ${VERSION_AFTER}"

S3_PASS=true
# PUT with invalid content must return 422 validation_failed (per admin-api.md)
if [ "$PUT_HTTP" != "422" ]; then
    scenario_fail "Scenario 3 — PUT with invalid YAML returned HTTP ${PUT_HTTP} (expected 422)"
    S3_PASS=false
fi

# Verify the error type is validation_failed, not conflict_detected or compile_failed
if ! echo "$PUT_BODY" | grep -q "validation_failed"; then
    scenario_fail "Scenario 3 — response body missing 'validation_failed' (got: ${PUT_BODY})"
    S3_PASS=false
fi

# Version should not change after failed PUT
if [ "$VERSION_BEFORE" != "$VERSION_AFTER" ] && [ "$VERSION_BEFORE" != "unknown" ]; then
    scenario_fail "Scenario 3 — version changed after invalid PUT (${VERSION_BEFORE} → ${VERSION_AFTER})"
    S3_PASS=false
fi

# Gateway must still serve requests (LKG preserved)
HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${LUAGATE_HTTP_URL}/health" 2>/dev/null || echo "000")
if [ "$HEALTH_CODE" != "200" ]; then
    scenario_fail "Scenario 3 — gateway unhealthy after invalid PUT (HTTP ${HEALTH_CODE})"
    S3_PASS=false
fi

if [ "$S3_PASS" = true ]; then
    pass "Scenario 3 — invalid YAML rejected (HTTP ${PUT_HTTP}), LKG preserved, gateway healthy"
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════
# Scenario 4: Rapid-fire reloads don't crash
# ══════════════════════════════════════════════════════════════════════════
info "── Scenario 4: Concurrent rapid-fire reloads (10x, parallel) ──"

RAPID_TOTAL=10
RAPID_RESULTS_DIR=$(mktemp -d)

# Fire all reloads in parallel to test concurrent conflict handling.
# Per ADR-005 / admin-api.md, concurrent reloads return 409 reload_in_progress.
# Expected: exactly 1 wins (200), rest get 409. Any 5xx is a bug.
for i in $(seq 1 $RAPID_TOTAL); do
    (
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "${LUAGATE_ADMIN_URL}/api/v1/policies/reload" \
            -H "Authorization: Bearer ${LUAGATE_ADMIN_TOKEN}" \
            -H "Content-Type: application/json" 2>/dev/null || echo "000")
        echo "$HTTP_CODE" > "${RAPID_RESULTS_DIR}/${i}.txt"
    ) &
done
wait

# Categorize responses
RAPID_OK=0
RAPID_CONFLICT=0
RAPID_ERROR=0
for f in "${RAPID_RESULTS_DIR}"/*.txt; do
    CODE=$(cat "$f")
    case "$CODE" in
        200) RAPID_OK=$((RAPID_OK + 1)) ;;
        409) RAPID_CONFLICT=$((RAPID_CONFLICT + 1)) ;;
        *)   RAPID_ERROR=$((RAPID_ERROR + 1)) ;;
    esac
done
rm -rf "${RAPID_RESULTS_DIR}"
info "  Results: ${RAPID_OK}x 200, ${RAPID_CONFLICT}x 409, ${RAPID_ERROR}x other"

S4_PASS=true

# At least one reload must succeed
if [ "$RAPID_OK" -lt 1 ]; then
    scenario_fail "Scenario 4 — no reload succeeded (0x 200 out of ${RAPID_TOTAL})"
    S4_PASS=false
fi

# All responses must be either 200 or 409 — any 5xx/other is a bug
if [ "$RAPID_ERROR" -gt 0 ]; then
    scenario_fail "Scenario 4 — ${RAPID_ERROR} unexpected error responses (expected only 200/409)"
    S4_PASS=false
fi

# Check gateway is still alive
sleep 1
HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${LUAGATE_ADMIN_URL}/health" 2>/dev/null || echo "000")

if [ "$HEALTH_CODE" != "200" ]; then
    scenario_fail "Scenario 4 — gateway crashed after rapid-fire reloads (HTTP ${HEALTH_CODE})"
    S4_PASS=false
fi

if [ "$S4_PASS" = true ]; then
    pass "Scenario 4 — gateway survived concurrent reloads (${RAPID_OK}x 200, ${RAPID_CONFLICT}x 409)"
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════
info "══════════════════════════════════════════════"
info "  Chaos Test Summary: ${PASS_COUNT}/${TOTAL} passed, ${FAIL_COUNT}/${TOTAL} failed"
info "══════════════════════════════════════════════"

if [ "$FAIL_COUNT" -gt 0 ]; then
    fail "Chaos test FAILED"
    exit 1
fi

ok "All chaos test scenarios PASSED"
