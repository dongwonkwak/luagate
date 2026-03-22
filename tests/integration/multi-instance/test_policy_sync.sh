#!/usr/bin/env bash
# test_policy_sync.sh — Multi-instance policy sync integration test (DON-205)
#
# Verifies ADR-008 §8.3 deployment pattern:
#   1. Deploy policy file to shared volume
#   2. POST /api/v1/policies/reload on each instance
#   3. GET /health → source_version matches on both instances
#
# Prerequisites:
#   - Docker and docker compose available
#   - Run from project root: bash tests/integration/multi-instance/test_policy_sync.sh
#
# Related: ADR-008

set -euo pipefail

COMPOSE_FILE="docker-compose.multi.yml"
PROJECT_NAME="luagate-multi-test"
ADMIN_TOKEN="${LUAGATE_ADMIN_TOKEN:-test-multi-instance-token}"

INSTANCE_1_ADMIN="http://localhost:9090"
INSTANCE_2_ADMIN="http://localhost:9091"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

FAILURES=0

cleanup() {
  info "Cleaning up containers..."
  docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
}

# Always cleanup on exit
trap cleanup EXIT

# ── Step 1: Start 2 instances ─────────────────────────────────────────────
info "Starting 2 LuaGate instances with shared conf volume..."
cleanup  # Ensure clean state

# Init container seeds the shared-conf volume first
LUAGATE_ADMIN_TOKEN="$ADMIN_TOKEN" \
  docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" run --rm conf-init

# Start services
LUAGATE_ADMIN_TOKEN="$ADMIN_TOKEN" \
  docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d luagate-1 luagate-2

# ── Step 2: Wait for health ───────────────────────────────────────────────
info "Waiting for both instances to be healthy..."

wait_healthy() {
  local url="$1"
  local name="$2"
  local max_retries=30
  local i=0
  while [ $i -lt $max_retries ]; do
    if curl -sf -H "Authorization: Bearer $ADMIN_TOKEN" "$url/health" > /dev/null 2>&1; then
      pass "$name is healthy"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  fail "$name did not become healthy within ${max_retries}s"
  return 1
}

wait_healthy "$INSTANCE_1_ADMIN" "Instance 1"
wait_healthy "$INSTANCE_2_ADMIN" "Instance 2"

# ── Step 3: Get initial health versions ───────────────────────────────────
info "Checking initial health versions..."

# Extract source_version from /health response (ADR-008 §8.3 step 5)
get_source_version() {
  local url="$1"
  curl -sf -H "Authorization: Bearer $ADMIN_TOKEN" "$url/health" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('source_version') or 'none')" 2>/dev/null || echo "error"
}

get_http_version() {
  local url="$1"
  curl -sf -H "Authorization: Bearer $ADMIN_TOKEN" "$url/health" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('active_http_version') or 'none')" 2>/dev/null || echo "error"
}

SV1_BEFORE=$(get_source_version "$INSTANCE_1_ADMIN")
SV2_BEFORE=$(get_source_version "$INSTANCE_2_ADMIN")
info "Instance 1 source_version before: $SV1_BEFORE"
info "Instance 2 source_version before: $SV2_BEFORE"

if [ "$SV1_BEFORE" = "$SV2_BEFORE" ] && [ "$SV1_BEFORE" != "none" ] && [ "$SV1_BEFORE" != "error" ]; then
  pass "Initial source_version matches: $SV1_BEFORE"
else
  info "Initial versions differ or not loaded yet (expected on cold start)"
fi

# ── Step 4: Deploy new policy to shared volume (ADR-008 §8.3 step 2) ─────
info "Deploying updated policy to shared volume..."

TEST_POLICY='global:
  default_action: deny
rules:
  - id: multi-instance-sync-test
    priority: 10
    scope:
      path: "/sync-verified"
    action: allow
    enabled: true'

# Write policy to shared volume via container exec
docker exec luagate-multi-1 sh -c "cat > /usr/local/openresty/nginx/conf/policies.yaml" <<< "$TEST_POLICY"
pass "Policy file written to shared volume"

# ── Step 5: Trigger reload on both instances (ADR-008 §8.3 step 3) ───────
info "Triggering POST /api/v1/policies/reload on both instances..."

reload_instance() {
  local url="$1"
  local name="$2"
  local code
  code=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    "$url/api/v1/policies/reload" 2>/dev/null || echo "000")
  if [ "$code" = "200" ] || [ "$code" = "204" ]; then
    pass "$name reload succeeded (HTTP $code)"
  else
    fail "$name reload failed (HTTP $code)"
  fi
}

reload_instance "$INSTANCE_1_ADMIN" "Instance 1"
reload_instance "$INSTANCE_2_ADMIN" "Instance 2"

# Allow reload to propagate
sleep 2

# ── Step 6: Verify versions match (ADR-008 §8.3 step 5) ──────────────────
info "Verifying source_version matches on both instances..."

SV1_AFTER=$(get_source_version "$INSTANCE_1_ADMIN")
SV2_AFTER=$(get_source_version "$INSTANCE_2_ADMIN")
HV1_AFTER=$(get_http_version "$INSTANCE_1_ADMIN")
HV2_AFTER=$(get_http_version "$INSTANCE_2_ADMIN")

info "Instance 1: source=$SV1_AFTER, http=$HV1_AFTER"
info "Instance 2: source=$SV2_AFTER, http=$HV2_AFTER"

# ADR-008 §8.3 step 5: source_version == active_http_version on each instance
if [ "$SV1_AFTER" = "$HV1_AFTER" ] && [ "$SV1_AFTER" != "none" ] && [ "$SV1_AFTER" != "error" ]; then
  pass "Instance 1: source_version == active_http_version ($SV1_AFTER)"
else
  fail "Instance 1: version mismatch (source=$SV1_AFTER, http=$HV1_AFTER)"
fi

if [ "$SV2_AFTER" = "$HV2_AFTER" ] && [ "$SV2_AFTER" != "none" ] && [ "$SV2_AFTER" != "error" ]; then
  pass "Instance 2: source_version == active_http_version ($SV2_AFTER)"
else
  fail "Instance 2: version mismatch (source=$SV2_AFTER, http=$HV2_AFTER)"
fi

# Cross-instance: both should have same version
if [ "$SV1_AFTER" = "$SV2_AFTER" ]; then
  pass "Both instances have matching source_version: $SV1_AFTER"
else
  fail "Cross-instance version mismatch! Instance 1: $SV1_AFTER, Instance 2: $SV2_AFTER"
fi

# Version should have changed from initial
if [ "$SV1_AFTER" != "$SV1_BEFORE" ]; then
  pass "Version changed after policy deploy + reload"
else
  info "Version unchanged (may be expected if policy hash matches initial)"
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "=================================="
if [ "$FAILURES" -eq 0 ]; then
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}$FAILURES test(s) failed${NC}"
  exit 1
fi
