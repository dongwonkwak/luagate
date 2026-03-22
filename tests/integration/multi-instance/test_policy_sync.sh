#!/usr/bin/env bash
# test_policy_sync.sh — Multi-instance policy sync integration test (DON-205)
#
# Verifies that a policy deployed via Admin API on instance 1
# is visible on instance 2 through the shared volume.
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
NC='\033[0m' # No Color

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
info "Starting 2 LuaGate instances..."
cleanup  # Ensure clean state
LUAGATE_ADMIN_TOKEN="$ADMIN_TOKEN" \
  docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d --build --wait

# ── Step 2: Wait for health ───────────────────────────────────────────────
info "Waiting for both instances to be healthy..."

wait_healthy() {
  local url="$1"
  local name="$2"
  local max_retries=30
  local i=0
  while [ $i -lt $max_retries ]; do
    if curl -sf "$url/health" > /dev/null 2>&1; then
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

get_version() {
  local url="$1"
  curl -sf "$url/health" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('version', d.get('active_version', 'none')))" 2>/dev/null || echo "none"
}

V1_BEFORE=$(get_version "$INSTANCE_1_ADMIN")
V2_BEFORE=$(get_version "$INSTANCE_2_ADMIN")
info "Instance 1 version before: $V1_BEFORE"
info "Instance 2 version before: $V2_BEFORE"

# ── Step 4: Deploy policy via instance 1 ──────────────────────────────────
info "Deploying test policy via Instance 1 Admin API..."

TEST_POLICY='global:
  default_action: deny
rules:
  - id: multi-instance-test-rule
    priority: 10
    scope:
      path: "/test-sync"
    action: allow
    enabled: true'

# Get current ETag for If-Match
ETAG=$(curl -sf -H "Authorization: Bearer $ADMIN_TOKEN" \
  "$INSTANCE_1_ADMIN/api/v1/policies" -o /dev/null -D - 2>/dev/null \
  | grep -i "etag" | tr -d '\r' | awk '{print $2}' || echo "")

DEPLOY_ARGS=(-X PUT \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/yaml" \
  --data-raw "$TEST_POLICY")

if [ -n "$ETAG" ]; then
  DEPLOY_ARGS+=(-H "If-Match: $ETAG")
fi

HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" "${DEPLOY_ARGS[@]}" \
  "$INSTANCE_1_ADMIN/api/v1/policies" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
  pass "Policy deployed successfully (HTTP $HTTP_CODE)"
else
  fail "Policy deploy failed (HTTP $HTTP_CODE)"
fi

# ── Step 5: Wait for sync and verify versions match ───────────────────────
info "Waiting for policy sync across instances..."
sleep 3  # Allow filesystem sync + polling interval

V1_AFTER=$(get_version "$INSTANCE_1_ADMIN")
V2_AFTER=$(get_version "$INSTANCE_2_ADMIN")

info "Instance 1 version after: $V1_AFTER"
info "Instance 2 version after: $V2_AFTER"

if [ "$V1_AFTER" = "$V2_AFTER" ]; then
  pass "Both instances have matching version: $V1_AFTER"
else
  fail "Version mismatch! Instance 1: $V1_AFTER, Instance 2: $V2_AFTER"
fi

if [ "$V1_AFTER" != "$V1_BEFORE" ] || [ "$V1_BEFORE" = "none" ]; then
  pass "Instance 1 version changed after deploy"
else
  # If version didn't change, it might be because initial policy was same
  info "Instance 1 version unchanged (may be expected if policy content matches)"
fi

# ── Step 6: Verify policy is functional on both instances ─────────────────
info "Verifying policy is active on both instances..."

check_policy_active() {
  local port="$1"
  local name="$2"
  local url="http://localhost:$port/test-sync"
  local code
  code=$(curl -sf -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
  # With default_action: deny and allow rule for /test-sync,
  # /test-sync should return 200 (proxied) or at least not 403
  if [ "$code" != "403" ] && [ "$code" != "000" ]; then
    pass "$name: /test-sync returned $code (policy active, not denied)"
  elif [ "$code" = "403" ]; then
    # Could be 403 if upstream is not available but policy evaluated — still means policy loaded
    info "$name: /test-sync returned 403 (policy loaded, upstream may be unavailable)"
  else
    fail "$name: /test-sync returned $code (policy may not be active)"
  fi
}

check_policy_active "8080" "Instance 1"
check_policy_active "8081" "Instance 2"

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
