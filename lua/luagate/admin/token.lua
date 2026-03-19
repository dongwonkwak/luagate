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
local function send_error(status, code, message, stage)
  ngx.status = status
  ngx.header["Content-Type"] = "application/json"
  local body = cjson.encode({
    error = code,
    stage = stage or "token_rotation",
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
-- Returns true on success, false on failure (audit-first: failure = reject mutation).
local function audit_log(event, actor_ip)
  local record = cjson.encode({
    timestamp = ngx.utctime(),
    event = event,
    actor_ip = actor_ip or ngx.var.remote_addr or "unknown",
    path = "/api/v1/admin/token/rotate",
  })
  if not record then
    ngx.log(ngx.ERR, "[luagate] audit log encode failed for event: ", event)
    return false
  end
  ngx.log(ngx.ERR, "[luagate:audit] ", record)
  return true
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

  -- Security: reject rotation using grace period (old) token.
  -- If the caller authenticated with the old token (grace period),
  -- they must not be allowed to rotate again (prevents stolen token re-rotation).
  local rotated_token = state_dict:get(KEY_ACTIVE_TOKEN)
  if rotated_token then
    local auth_header = ngx.req.get_headers()["Authorization"]
    local provided = auth_header and auth_header:match("^Bearer (.+)$")
    if provided and provided ~= rotated_token then
      -- Caller used a non-active token (grace period) — deny rotation
      send_error(403, "forbidden", "Rotation not allowed with grace period token")
      return
    end
  end

  -- Get current active token: shared dict first, then env-loaded fallback
  local current_token = state_dict:get(KEY_ACTIVE_TOKEN)
  if not current_token then
    -- First rotation: env-loaded token is the current one
    current_token = os.getenv("LUAGATE_ADMIN_TOKEN")
  end

  -- Store old token with grace period TTL — fail-closed on write error
  if current_token then
    local ok, set_err = state_dict:safe_set(KEY_OLD_TOKEN, current_token, GRACE_PERIOD_TTL)
    if not ok then
      ngx.log(ngx.ERR, "[luagate] failed to safe_set grace period token: ", tostring(set_err))
      send_error(500, "internal_error", "Failed to store grace period token")
      return
    end
  end

  -- Store new token (no TTL — persists until next rotation or restart)
  local ok, set_err = state_dict:safe_set(KEY_ACTIVE_TOKEN, new_token)
  if not ok then
    ngx.log(ngx.ERR, "[luagate] failed to safe_set rotated token: ", tostring(set_err))
    send_error(500, "internal_error", "Failed to store new token")
    return
  end

  -- Audit after successful mutation (audit drop = rollback + reject)
  local audit_ok = audit_log("token_rotated")
  if not audit_ok then
    -- Rollback: restore previous active token
    if current_token then
      state_dict:set(KEY_ACTIVE_TOKEN, current_token)
    else
      state_dict:delete(KEY_ACTIVE_TOKEN)
    end
    state_dict:delete(KEY_OLD_TOKEN)
    send_error(500, "audit_write_failed", "Audit log failed — mutation rolled back", "audit")
    return
  end

  send_json(200, {
    status = "rotated",
    grace_period_seconds = GRACE_PERIOD_TTL,
  })
end

return _M
