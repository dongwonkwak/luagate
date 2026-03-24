--- Data plane sliding window rate limiter for LuaGate.
-- Implements per-rule rate limiting for the HTTP data plane (:8080).
-- Uses shared dict `luagate_ratelimit` with a sliding window counter algorithm.
--
-- Design rules (ADR-012):
--   - shared dict zone: `luagate_ratelimit` (luagate_ prefix required)
--   - Sliding window counter: per-rule requests/window, scope=client_ip (MVP)
--   - Key schema: `rl:<rule_id>:<scope_key>:<slot>`
--   - IPv6 scope_key: bracketed `[addr]` (ADR-012 §2)
--   - Increment-then-check: atomic incr before weighted count (race-safe)
--   - fail-closed: shared dict nil → 503
--   - fail-open: eviction (incr auto-creates new key)
--   - incr() failure → fail-closed 503 (ADR-012 §2)
--   - No blocking I/O
--   - ngx.ctx MUST NOT store rate limit state long-term
--   - ngx.worker.id() in logs (not PID)
--
-- Implementation: lua/luagate/http/ratelimit.lua
-- Tests: tests/unit/http/ratelimit_spec.lua

local _M = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------
local DICT_NAME = "luagate_ratelimit"

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Build the shared dict key for a given rule, scope key, and window slot.
-- Key schema: `rl:<rule_id>:<scope_key>:<slot>` (ADR-012 §2).
-- @param rule_id   string  Rule identifier ([a-z0-9-]+, no `:`)
-- @param scope_key string  Scope key (IPv4 or bracketed IPv6)
-- @param slot      number  Window slot (floor of now / window)
-- @return string
local function make_key(rule_id, scope_key, slot)
  return "rl:" .. rule_id .. ":" .. scope_key .. ":" .. tostring(slot)
end

--- Format the scope key for an IP address.
-- IPv6 addresses (containing `:`) are bracketed to delimit them from the
-- key separator. IPv4 addresses are used as-is.
-- @param ip string  Client IP address
-- @return string
local function format_scope_key(ip)
  if ip and ip:find(":", 1, true) then
    return "[" .. ip .. "]"
  end
  return ip or ""
end

--- Calculate Retry-After seconds accounting for weighted count decay.
-- When the weighted count greatly exceeds the limit, the simple "wait until
-- current slot ends" estimate is too optimistic because the next slot may
-- still be over-limit. This calculation mirrors admin/ratelimit.lua logic:
-- it considers how much the previous slot weight must decay before the
-- weighted count drops below the limit.
-- @param previous_count number  Previous slot counter
-- @param current_count  number  Current slot counter (post-increment)
-- @param limit          number  Rate limit (requests per window)
-- @param window         number  Window size in seconds
-- @param now            number  Current timestamp (ngx.now())
-- @param current_slot   number  Current window slot number
-- @return number  Seconds to wait (minimum 1)
local function calculate_retry_after(previous_count, current_count, limit, window, now, current_slot)
  local window_start = current_slot * window
  local elapsed = now - window_start
  local remaining = window - elapsed

  -- Case 1: previous slot weight is decaying; check if within this slot
  -- the weighted count can drop below the limit.
  if previous_count > 0 and current_count < limit then
    -- We need: previous_count * (1 - elapsed'/window) + current_count <= limit
    -- Solve for elapsed': elapsed' >= window * (1 - (limit - current_count) / previous_count)
    local allowed_previous_weight = limit - current_count
    local same_slot_retry_after = (window * (1 - (allowed_previous_weight / previous_count))) - elapsed

    if same_slot_retry_after > 0 and same_slot_retry_after < remaining then
      return math.max(1, math.ceil(same_slot_retry_after))
    end
  end

  -- Case 2: must wait until the next slot. In the next slot, the current
  -- slot becomes "previous" and its weight decays. Calculate how far into
  -- the next slot the client must wait for weighted count to drop below limit.
  local next_slot_elapsed = 0
  if current_count > (limit - 1) then
    -- In next slot: current_count * (1 - t/window) + 0 <= limit - 1
    -- t >= window * (1 - (limit - 1) / current_count)
    next_slot_elapsed = window * (1 - ((limit - 1) / current_count))
  end

  return math.max(1, math.ceil(remaining + next_slot_elapsed))
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Check rate limit for a request against a matched rule's rate_limit config.
-- Uses increment-then-check sliding window counter (ADR-012 §1).
--
-- @param rule_id    string  Matched rule ID
-- @param src_ip     string  Client IP address
-- @param rate_limit table   { requests = number, window = number, scope = string }
-- @param now        number  Current timestamp (ngx.now()), injectable for testing
-- @return table  Result table:
--   { allowed = boolean, status = number|nil, remaining = number|nil,
--     limit = number|nil, reset = number|nil, retry_after = number|nil,
--     err = string|nil, weighted_count = number|nil }
function _M.check(rule_id, src_ip, rate_limit, now)
  now = now or ngx.now()
  local requests = rate_limit.requests
  local window = rate_limit.window

  -- fail-closed: shared dict nil → 503 (ADR-012 §2)
  local dict = ngx.shared[DICT_NAME]
  if not dict then
    ngx.log(
      ngx.ERR,
      "[luagate:ratelimit] shared dict ",
      DICT_NAME,
      " not available (fail-closed)",
      " worker_id=",
      (ngx.worker and ngx.worker.id()) or 0
    )
    return {
      allowed = false,
      status = 503,
      err = "ratelimit_unavailable",
    }
  end

  local scope_key = format_scope_key(src_ip)
  local current_slot = math.floor(now / window)
  local previous_slot = current_slot - 1

  local current_key = make_key(rule_id, scope_key, current_slot)
  local previous_key = make_key(rule_id, scope_key, previous_slot)

  -- Increment-then-check: atomically increment current slot first (ADR-012 §1).
  -- TTL = 2 * window to keep previous slot available for weighted count.
  local new_val, err = dict:incr(current_key, 1, 0, window * 2)
  if not new_val then
    -- fail-closed on incr failure (ADR-012 §2)
    ngx.log(
      ngx.ERR,
      "[luagate:ratelimit] incr failed: ",
      tostring(err),
      " key=",
      current_key,
      " worker_id=",
      (ngx.worker and ngx.worker.id()) or 0
    )
    return {
      allowed = false,
      status = 503,
      err = "ratelimit_incr_failed",
    }
  end

  -- Read previous window counter (read-only, no race concern)
  local previous_count = tonumber(dict:get(previous_key)) or 0

  -- Calculate elapsed fraction within the current window
  local window_start = current_slot * window
  local elapsed = now - window_start
  local elapsed_fraction = elapsed / window

  -- Sliding window weighted count (uses post-increment new_val)
  local weighted_count = previous_count * (1 - elapsed_fraction) + new_val

  -- Compute quota headers (ADR-012 §5)
  local remaining = math.max(0, requests - math.ceil(weighted_count))
  local reset = (current_slot + 1) * window

  if weighted_count > requests then
    local retry_after = calculate_retry_after(previous_count, new_val, requests, window, now, current_slot)

    ngx.log(
      ngx.WARN,
      "[luagate:ratelimit] rate limit exceeded",
      " rule=",
      rule_id,
      " ip=",
      src_ip,
      " weighted=",
      string.format("%.1f", weighted_count),
      " limit=",
      requests,
      " worker_id=",
      (ngx.worker and ngx.worker.id()) or 0
    )

    return {
      allowed = false,
      status = 429,
      remaining = 0,
      limit = requests,
      reset = reset,
      retry_after = retry_after,
      weighted_count = weighted_count,
    }
  end

  return {
    allowed = true,
    remaining = remaining,
    limit = requests,
    reset = reset,
    weighted_count = weighted_count,
  }
end

-- Expose internals for testing
_M._DICT_NAME = DICT_NAME
_M._make_key = make_key
_M._format_scope_key = format_scope_key

return _M
