--- Admin API Bearer token authentication module.
-- Implements static token authentication for the admin plane (ADR-004 ss6.2).
--
-- Design rules:
--   - Token loaded once in init() from LUAGATE_ADMIN_TOKEN env var.
--   - Module-level upvalue cache (_admin_token); ngx.ctx MUST NOT store token.
--   - Token MUST NEVER appear in logs or response bodies.
--   - fail-closed: missing/invalid token -> 401 deny.
--   - Minimum 32 bytes entropy enforced at init() (startup-fatal).
--   - constant-time compare: bit.bor + bit.bxor, never == on secrets.
--   - GET /health endpoint exempted from authentication.
--   - OPTIONS preflight exempted from authentication (CORS).
--
-- Implementation: lua/luagate/admin/auth.lua
-- Tests: tests/unit/admin/auth_spec.lua

local cjson = require("cjson.safe")
local bit = require("bit")

local _M = {}

-- ---------------------------------------------------------------------------
-- Module-level upvalue: worker-lifetime token cache.
-- Set once by init(), read by verify(). Never stored in ngx.ctx.
-- ---------------------------------------------------------------------------
local _admin_token = nil

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------
local MIN_TOKEN_LENGTH = 32
local HEALTH_PATH = "/health"
local AUTH_FAILURE_BODY = '{"error":"Unauthorized","message":"Invalid or missing Bearer token"}'

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Constant-time string comparison.
-- Uses bit.bor + bit.bxor to accumulate differences without short-circuiting.
-- Even when lengths differ, both strings are compared up to the longer length
-- to prevent timing leaks on length.
--
-- @param a string  First string (provided token)
-- @param b string  Second string (expected token)
-- @return boolean  true if strings are identical
local function constant_time_compare(a, b)
  local len_a = #a
  local len_b = #b
  -- Use the longer length to iterate; prevents timing leak on length difference.
  local max_len = len_a > len_b and len_a or len_b
  local result = bit.bxor(len_a, len_b) -- non-zero if lengths differ

  for i = 1, max_len do
    -- When index exceeds a string's length, use 0 (guaranteed mismatch against
    -- any real byte, and the length XOR already flagged the difference).
    local byte_a = (i <= len_a) and a:byte(i) or 0
    local byte_b = (i <= len_b) and b:byte(i) or 0
    result = bit.bor(result, bit.bxor(byte_a, byte_b))
  end

  return result == 0
end

--- Send a 401 Unauthorized response and write a structured audit log entry.
-- The token value is NEVER included in the log or response body (ADR-004 ss6.2).
-- Audit output uses the "[luagate:audit]" prefix so that nginx error_log can be
-- split into a dedicated audit.log stream via log routing (ADR-004 ss6.3).
--
-- @param reason string  Short reason token for audit log (e.g. "missing_token")
local function _reject(reason)
  -- Structured audit log: ADR-004 ss6.3 / log-schema.md ss5 auth_failure schema
  local actor_ip = ngx.var.remote_addr or "unknown"
  local path = ngx.var.uri or "unknown"
  local audit_record = cjson.encode({
    timestamp = ngx.utctime(),
    event = "auth_failure",
    actor_ip = actor_ip,
    path = path,
    reason = reason,
  })
  -- ERR level ensures capture in default error_log; "[luagate:audit]" prefix
  -- enables log routing to dedicated audit.log (grep/fluentd filter).
  ngx.log(ngx.ERR, "[luagate:audit] ", audit_record or '{"event":"auth_failure","reason":"' .. reason .. '"}')

  ngx.status = 401
  ngx.header["Content-Type"] = "application/json"
  ngx.header["Cache-Control"] = "no-store"
  ngx.say(AUTH_FAILURE_BODY)
  ngx.exit(401)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Initialise the auth module by loading the admin token from environment.
-- MUST be called from init_by_lua (once per master process start).
-- Fails the nginx startup if the token is missing or too short (fail-closed).
--
-- @return boolean  true on success (never returns false; errors are fatal)
function _M.init()
  local token = os.getenv("LUAGATE_ADMIN_TOKEN")

  if not token or token == "" then
    local msg = "[luagate] LUAGATE_ADMIN_TOKEN not set; refusing to start (fail-closed)"
    ngx.log(ngx.EMERG, msg)
    error(msg)
  end

  if #token < MIN_TOKEN_LENGTH then
    local msg = string.format(
      "[luagate] LUAGATE_ADMIN_TOKEN too short: %d bytes (minimum %d); refusing to start",
      #token,
      MIN_TOKEN_LENGTH
    )
    ngx.log(ngx.EMERG, msg)
    error(msg)
  end

  _admin_token = token
  -- Do NOT log the token value (ADR-004 ss6.2)
  ngx.log(ngx.NOTICE, "[luagate] admin auth initialised (token length: ", #token, ")")
  return true
end

--- Verify the Bearer token on the current request.
-- Called from access_by_lua in the admin server block.
--
-- Flow:
--   0. OPTIONS preflight -> early return true (CORS, admin-auth-contract)
--   1. GET /health path -> early return true (no auth required, admin-api.md ss6.1)
--   2. Parse Authorization header -> missing/malformed -> 401
--   3. Constant-time compare -> mismatch -> 401
--   4. Match -> return true
--
-- @return boolean  true if authenticated (on failure, _reject() calls ngx.exit)
function _M.verify()
  -- 0. OPTIONS preflight: bypass auth (CORS, admin-auth-contract.md)
  if ngx.req.get_method() == "OPTIONS" then
    return true
  end

  -- 1. Health check exemption: GET /health only (admin-api.md ss6.1)
  local uri = ngx.var.uri
  if uri == HEALTH_PATH and ngx.req.get_method() == "GET" then
    return true
  end

  -- Guard: init() must have been called
  if not _admin_token then
    ngx.log(ngx.ERR, "[luagate] admin token not initialised; rejecting request")
    _reject("token_not_initialised")
    return false
  end

  -- 2. Parse Authorization header
  local auth_header = ngx.req.get_headers()["Authorization"]
  if not auth_header then
    _reject("missing_token")
    return false
  end

  if type(auth_header) ~= "string" then
    _reject("malformed_header")
    return false
  end

  -- Must start with "Bearer " (case-sensitive, RFC 6750 ss2.1)
  local provided = auth_header:match("^Bearer (.+)$")
  if not provided then
    _reject("malformed_header")
    return false
  end

  -- 3. Constant-time comparison (security-patterns.md: never use ==)
  if not constant_time_compare(provided, _admin_token) then
    _reject("invalid_token")
    return false
  end

  -- 4. Authenticated
  return true
end

--- Reset the module state (for testing only).
-- Production code should never call this.
function _M.reset()
  _admin_token = nil
end

-- Expose internal for testing (prefixed with underscore convention)
_M._constant_time_compare = constant_time_compare

return _M
