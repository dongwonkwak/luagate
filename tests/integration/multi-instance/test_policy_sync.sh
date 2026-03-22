#!/usr/bin/env bash
# test_policy_sync.sh — Multi-instance policy sync integration test (DON-205)
#
# Verifies ADR-008 §8.3 deployment pattern:
#   1. Deploy policy file to shared volume
#   2. POST /api/v1/policies/reload on each instance
#   3. GET /health → source_version == active_http_version
#      == active_stream_version == target_version (SHA256 of deployed file)
#
# Prerequisites:
#   - Docker and docker compose available
#   - Run from project root: bash tests/integration/multi-instance/test_policy_sync.sh
#
# Related: ADR-008

set -euo pipefail

COMPOSE_FILE="docker-compose.multi.yml"
PROJECT_NAME="luagate-multi-test"
ADMIN_TOKEN="${LUAGATE_ADMIN_TOKEN:-test-multi-instance-token-32bytes}"

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

# Start all services (conf-init runs first via depends_on)
LUAGATE_ADMIN_TOKEN="$ADMIN_TOKEN" \
  docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d --build

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

# ── Step 3: /health field extraction helpers ──────────────────────────────
# ADR-008 §8.3 step 5: source_version == active_http_version == active_stream_version

get_health_field() {
  local url="$1"
  local field="$2"
  curl -sf -H "Authorization: Bearer $ADMIN_TOKEN" "$url/health" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$field') or 'none')" 2>/dev/null || echo "error"
}

# ── Step 4: Check initial state ───────────────────────────────────────────
info "Checking initial health versions..."

SV1_BEFORE=$(get_health_field "$INSTANCE_1_ADMIN" "source_version")
SV2_BEFORE=$(get_health_field "$INSTANCE_2_ADMIN" "source_version")
info "Instance 1 source_version before: $SV1_BEFORE"
info "Instance 2 source_version before: $SV2_BEFORE"

# ── Step 5: Deploy new policy to shared volume (ADR-008 §8.3 step 2) ─────
info "Deploying updated policy to shared volume..."

# Write policy to shared volume via container exec (simulates CI/CD file deploy)
# Use printf to avoid trailing newline from heredoc/herestring
docker exec -i luagate-multi-1 sh -c "cat > /conf/policies.yaml" <<'POLICY_EOF'
global:
  default_action: deny
rules:
  - id: multi-instance-sync-test
    priority: 10
    scope:
      path: "/sync-verified"
    action: allow
    enabled: true
POLICY_EOF

# Compute target_version from actual deployed file bytes (ADR-008 §8.3 step 1)
TARGET_VERSION=$(docker exec luagate-multi-1 sha256sum /conf/policies.yaml | awk '{print $1}')
info "Target version (SHA256 of deployed file): $TARGET_VERSION"
pass "Policy file written to shared volume"

# ── Step 6: Trigger reload on both instances (ADR-008 §8.3 step 3) ───────
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

# ── Step 7: Verify all 4 version fields match (ADR-008 §8.3 step 5) ──────
# Condition: source_version == active_http_version == active_stream_version == target_version
info "Verifying version consistency on both instances..."

verify_instance() {
  local url="$1"
  local name="$2"
  local target="$3"

  local sv hv stv
  sv=$(get_health_field "$url" "source_version")
  hv=$(get_health_field "$url" "active_http_version")
  stv=$(get_health_field "$url" "active_stream_version")

  info "$name: source=$sv, http=$hv, stream=$stv"

  # source_version == active_http_version
  if [ "$sv" = "$hv" ] && [ "$sv" != "none" ] && [ "$sv" != "error" ]; then
    pass "$name: source_version == active_http_version ($sv)"
  else
    fail "$name: source/http mismatch (source=$sv, http=$hv)"
  fi

  # ADR-008 §8.3 step 5: active_stream_version == target_version
  if [ "$stv" = "$target" ]; then
    pass "$name: active_stream_version == target_version"
  else
    fail "$name: active_stream_version ($stv) != target_version ($target)"
  fi

  # source_version should match target_version (SHA256 of deployed file)
  # ADR-008 §8.3 step 5: source_version == target_version
  if [ "$sv" = "$target" ]; then
    pass "$name: source_version == target_version"
  else
    fail "$name: source_version ($sv) != target_version ($target)"
  fi
}

verify_instance "$INSTANCE_1_ADMIN" "Instance 1" "$TARGET_VERSION"
verify_instance "$INSTANCE_2_ADMIN" "Instance 2" "$TARGET_VERSION"

# Cross-instance consistency: both must have same source_version
SV1_AFTER=$(get_health_field "$INSTANCE_1_ADMIN" "source_version")
SV2_AFTER=$(get_health_field "$INSTANCE_2_ADMIN" "source_version")

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
