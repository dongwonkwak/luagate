--- Admin token rotation handler.
-- POST /api/v1/admin/token/rotate — rotates the admin Bearer token.
--
-- Design rules:
--   - Requires current valid token for authentication.
--   - New token stored in luagate_state shared dict (luagate_admin_token key).
--   - Old token remains valid for 30s grace period (luagate_admin_token_old key with TTL).
--   - Token values MUST NEVER appear in logs or response bodies.
--   - Minimum 32 bytes entropy enforced for new token.
--   - fail-closed: shared dict unavailable -> 500.
--
-- Implementation: lua/luagate/admin/token.lua

local cjson = require("cjson.safe")

local _M = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------
local MIN_TOKEN_LENGTH = 32
local GRACE_PERIOD_TTL = 30 -- seconds

-- Shared dict keys (luagate_ prefix convention)
local KEY_ACTIVE_TOKEN = "luagate_admin_token"
local KEY_OLD_TOKEN = "luagate_admin_token_old"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Send a JSON error response.
local function send_error(status, code, message)
  ngx.status = status
  ngx.header["Content-Type"] = "application/json"
  local body = cjson.encode({
    error = code,
    stage = "token_rotation",
    details = { message },
  })
  ngx.say(body or '{"error":"encode_failed"}')
  ngx.exit(status)
end

--- Send a JSON success response.
local function send_json(status, data)
  ngx.status = status
  ngx.header["Content-Type"] = "application/json"
  ngx.say(cjson.encode(data))
  ngx.exit(status)
end

--- Write audit log for token rotation event.
-- Token values are NEVER logged (ADR-004 ss6.2).
local function audit_log(event, actor_ip)
  local record = cjson.encode({
    timestamp = ngx.utctime(),
    event = event,
    actor_ip = actor_ip or ngx.var.remote_addr or "unknown",
    path = "/api/v1/admin/token/rotate",
  })
  ngx.log(ngx.ERR, "[luagate:audit] ", record or '{"event":"' .. event .. '"}')
end

-- ---------------------------------------------------------------------------
-- Handler
-- ---------------------------------------------------------------------------

--- POST /api/v1/admin/token/rotate
-- Request body: {"new_token": "<string>"}
-- Response: {"status": "rotated", "grace_period_seconds": 30}
function _M.handle_post_rotate()
  -- Read request body
  ngx.req.read_body()
  local body = ngx.req.get_body_data()
  if not body or body == "" then
    send_error(400, "bad_request", "Request body is required")
    return
  end

  -- Parse JSON
  local data, err = cjson.decode(body)
  if not data then
    send_error(400, "bad_request", "Invalid JSON: " .. (err or "unknown"))
    return
  end

  -- Validate new_token
  local new_token = data.new_token
  if not new_token or type(new_token) ~= "string" then
    send_error(400, "bad_request", "new_token field is required (string)")
    return
  end

  if #new_token < MIN_TOKEN_LENGTH then
    send_error(400, "bad_request", string.format("new_token too short: minimum %d characters", MIN_TOKEN_LENGTH))
    return
  end

  -- Get shared dict — fail-closed if unavailable
  local state_dict = ngx.shared.luagate_state
  if not state_dict then
    ngx.log(ngx.ERR, "[luagate] luagate_state shared dict unavailable — token rotation denied (fail-closed)")
    send_error(500, "internal_error", "Shared dict unavailable")
    return
  end

  -- Get current active token (from shared dict or env-loaded)
  local current_token = state_dict:get(KEY_ACTIVE_TOKEN)

  -- Store old token with grace period TTL (only if there is one)
  if current_token then
    local ok, set_err = state_dict:set(KEY_OLD_TOKEN, current_token, GRACE_PERIOD_TTL)
    if not ok then
      ngx.log(ngx.ERR, "[luagate] failed to set grace period token: ", tostring(set_err))
      -- Continue anyway — grace period is best-effort
    end
  end

  -- Store new token (no TTL — persists until next rotation or restart)
  local ok, set_err = state_dict:set(KEY_ACTIVE_TOKEN, new_token)
  if not ok then
    ngx.log(ngx.ERR, "[luagate] failed to store rotated token: ", tostring(set_err))
    send_error(500, "internal_error", "Failed to store new token")
    return
  end

  -- Audit log (no token values!)
  audit_log("token_rotated")

  send_json(200, {
    status = "rotated",
    grace_period_seconds = GRACE_PERIOD_TTL,
  })
end

return _M
