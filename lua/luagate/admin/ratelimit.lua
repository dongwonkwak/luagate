--- Admin API sliding window rate limiter for LuaGate.
-- Implements IP-based rate limiting for the admin server block (:9090).
-- Uses shared dict `luagate_admin_ratelimit` with a sliding window algorithm.
--
-- Design rules:
--   - shared dict zone: `luagate_admin_ratelimit` (luagate_ prefix required)
--   - Sliding window: 60s window, max 30 requests per IP
--   - Exceeded -> 429 Too Many Requests + Retry-After header
--   - GET /health endpoint is exempt (health check probes, method+path check)
--   - fail-closed: if shared dict unavailable, deny request
--   - No blocking I/O
--   - ngx.ctx MUST NOT store rate limit state
--   - ngx.worker.id() used in logs (not PID)
--
-- Implementation: lua/luagate/admin/ratelimit.lua
-- Tests: tests/unit/admin/ratelimit_spec.lua

local _M = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------
local WINDOW_SIZE = 60 -- seconds
local MAX_REQUESTS = 30 -- per IP per window
local HEALTH_PATH = "/health"
local DICT_NAME = "luagate_admin_ratelimit"

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Build the shared dict key for a given IP and window slot.
-- Uses a floor-aligned window start timestamp as part of the key.
-- @param ip   string  Client IP address
-- @param slot number  Window slot (floor of now / WINDOW_SIZE)
-- @return string
local function make_key(ip, slot)
  return "rl:" .. ip .. ":" .. tostring(slot)
end

--- Send a 429 Too Many Requests response.
-- @param retry_after number  Seconds until the current window expires
local function reject_rate_limited(retry_after)
  ngx.status = 429
  ngx.header["Content-Type"] = "application/json"
  ngx.header["Retry-After"] = tostring(retry_after)
  ngx.say('{"error":"rate_limited","message":"Too many requests. Try again later."}')
  ngx.exit(429)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Check rate limit for the current request.
-- Must be called early in the admin request pipeline (before auth).
-- Uses a sliding window counter approach with increment-then-check:
--   - Current window slot: floor(now / WINDOW_SIZE)
--   - Previous window slot: current - 1
--   - Atomically increment current counter first (race-safe)
--   - Weighted count: prev_count * (1 - elapsed_fraction) + new_curr_count
--   - If weighted count > MAX_REQUESTS -> 429
--
-- @return boolean  true if request is allowed, false if rejected (response sent)
function _M.check()
  -- Only GET /health is exempt from rate limiting (method + path check)
  local uri = ngx.var.uri
  local method = ngx.req and ngx.req.get_method and ngx.req.get_method()
  if uri == HEALTH_PATH and method == "GET" then
    return true
  end

  -- fail-closed: if shared dict is unavailable, deny
  local dict = ngx.shared[DICT_NAME]
  if not dict then
    ngx.log(
      ngx.ERR,
      "[luagate:ratelimit] shared dict ",
      DICT_NAME,
      " not available, denying request (fail-closed)",
      " worker_id=",
      (ngx.worker and ngx.worker.id()) or 0
    )
    ngx.status = 503
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"service_unavailable","message":"Rate limiter unavailable"}')
    ngx.exit(503)
    return false
  end

  local now = ngx.now()
  local current_slot = math.floor(now / WINDOW_SIZE)
  local previous_slot = current_slot - 1

  local current_key = make_key(ngx.var.remote_addr, current_slot)
  local previous_key = make_key(ngx.var.remote_addr, previous_slot)

  -- Increment-then-check: atomically increment first to avoid worker race condition.
  -- ngx.shared.DICT:incr() is atomic, so concurrent workers cannot all observe
  -- the same pre-increment snapshot.
  -- TTL = 2 * WINDOW_SIZE to keep the previous window available
  local new_val, err = dict:incr(current_key, 1, 0, WINDOW_SIZE * 2)
  if not new_val then
    -- fail-closed on counter update failure
    ngx.log(
      ngx.ERR,
      "[luagate:ratelimit] incr failed: ",
      tostring(err),
      " ip=",
      ngx.var.remote_addr,
      " worker_id=",
      (ngx.worker and ngx.worker.id()) or 0
    )
    ngx.status = 503
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"service_unavailable","message":"Rate limiter error"}')
    ngx.exit(503)
    return false
  end

  -- Read previous window counter (read-only, no race concern)
  local previous_count = tonumber(dict:get(previous_key)) or 0

  -- Calculate elapsed fraction within the current window
  local window_start = current_slot * WINDOW_SIZE
  local elapsed = now - window_start
  local elapsed_fraction = elapsed / WINDOW_SIZE

  -- Sliding window weighted count (uses post-increment new_val)
  local weighted_count = previous_count * (1 - elapsed_fraction) + new_val

  if weighted_count > MAX_REQUESTS then
    -- Calculate retry-after: time until current window expires
    local retry_after = math.ceil(WINDOW_SIZE - elapsed)
    if retry_after < 1 then
      retry_after = 1
    end

    ngx.log(
      ngx.WARN,
      "[luagate:ratelimit] rate limit exceeded",
      " ip=",
      ngx.var.remote_addr,
      " weighted=",
      string.format("%.1f", weighted_count),
      " limit=",
      MAX_REQUESTS,
      " worker_id=",
      (ngx.worker and ngx.worker.id()) or 0
    )

    reject_rate_limited(retry_after)
    return false
  end

  return true
end

--- Get current rate limit status for an IP (for testing/debugging).
-- @param ip string  Client IP address
-- @return table  { current_count, previous_count, weighted_count, remaining }
function _M.get_status(ip)
  local dict = ngx.shared[DICT_NAME]
  if not dict then
    return { error = "shared dict unavailable" }
  end

  local now = ngx.now()
  local current_slot = math.floor(now / WINDOW_SIZE)
  local previous_slot = current_slot - 1

  local current_count = tonumber(dict:get(make_key(ip, current_slot))) or 0
  local previous_count = tonumber(dict:get(make_key(ip, previous_slot))) or 0

  local window_start = current_slot * WINDOW_SIZE
  local elapsed_fraction = (now - window_start) / WINDOW_SIZE

  local weighted_count = previous_count * (1 - elapsed_fraction) + current_count
  local remaining = MAX_REQUESTS - math.ceil(weighted_count)
  if remaining < 0 then
    remaining = 0
  end

  return {
    current_count = current_count,
    previous_count = previous_count,
    weighted_count = weighted_count,
    remaining = remaining,
    window_size = WINDOW_SIZE,
    max_requests = MAX_REQUESTS,
  }
end

-- Expose constants for testing
_M._WINDOW_SIZE = WINDOW_SIZE
_M._MAX_REQUESTS = MAX_REQUESTS
_M._DICT_NAME = DICT_NAME
_M._HEALTH_PATH = HEALTH_PATH

return _M
