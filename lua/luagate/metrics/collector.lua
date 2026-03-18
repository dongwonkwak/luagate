--- HTTP metrics collector for LuaGate.
-- Updates luagate_metrics shared dict counters after each HTTP request.
-- Called from log_by_lua (via handler.log_phase) — after upstream response.
--
-- Counter key schema (ADR-006 §3.2):
--   metrics:http_requests_total:allow       — allow decisions
--   metrics:http_requests_total:deny        — deny decisions
--   metrics:http_requests_denied_total      — total deny count (label-less)
--   metrics:http_upstream_errors_total      — upstream 5xx responses
--   metrics:http:status:<code>              — per-status-code counter
--   latency:bucket:<ms>                     — latency histogram bucket
--   latency:bucket:+Inf                     — +Inf bucket
--
-- Design rules:
--   - No blocking I/O.
--   - ngx.ctx MUST NOT cache policy (policy never accessed here).
--   - shared dict write failures are non-fatal: log error, continue
--     (ADR-001 §1.2: shared dict write failure → metric loss acceptable).
--   - luagate_ prefix on all dict key prefixes (AGENTS.md invariant).
--
-- Implementation: lua/luagate/metrics/collector.lua
-- Tests: tests/unit/metrics/collector_spec.lua

local _M = {}

-- Latency histogram bucket boundaries in milliseconds (ADR-004 §4.3)
local LATENCY_BUCKETS = { 0.1, 0.5, 1, 5, 10, 50, 100, 500, 1000 }

-- Threat type allowlist (ADR-006 §1.1).
-- Unknown values are normalized to "other" before key composition.
local THREAT_TYPE_ALLOWLIST = {
  sqli = true,
  xss = true,
  path_traversal = true,
  cmd_injection = true,
  lfi = true,
  rfi = true,
  xxe = true,
  ssrf = true,
  log4shell = true,
  scanner = true,
  deserialization = true,
  other = true,
}

--- Increment a counter in a shared dict.
-- Errors are logged but not propagated (metric loss acceptable per ADR-001).
-- @param dict  table   ngx.shared.* dict object
-- @param key   string  Counter key
-- @param delta number  Increment amount (default 1)
local function safe_incr(dict, key, delta)
  local d = delta or 1
  local _, err = dict:incr(key, d, 0)
  if err then
    -- incr with default 0 should not fail unless the key has a non-numeric
    -- value; log and continue (ADR-001 §1.2)
    ngx.log(ngx.WARN, "[luagate] metrics incr failed for key=", key, ": ", tostring(err))
  end
end

--- Find the smallest histogram bucket >= latency_ms.
-- Returns the bucket boundary string or "+Inf" if all buckets exceeded.
-- ADR-006 ss3.1: +Inf bucket key is "latency:bucket:+Inf"
-- @param latency_ms number
-- @return string
local function latency_bucket(latency_ms)
  for _, b in ipairs(LATENCY_BUCKETS) do
    if latency_ms <= b then
      return tostring(b)
    end
  end
  return "+Inf"
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Record metrics for the completed HTTP request.
-- @param ctx table|nil  ngx.ctx.luagate (may be nil for short-circuited reqs)
function _M.record(ctx)
  local dict = ngx.shared.luagate_metrics
  if not dict then
    -- No metrics zone configured; skip silently
    return
  end

  -- Action counter (allow / deny) — ADR-006 ss3.2 key schema
  local action = (ctx and ctx.action) or ngx.var.luagate_action or "allow"
  if action == "deny" then
    safe_incr(dict, "metrics:http_requests_total:deny")
    safe_incr(dict, "metrics:http_requests_denied_total")
  else
    safe_incr(dict, "metrics:http_requests_total:allow")
  end

  -- Per-status-code counter
  local status = tonumber(ngx.var.status) or 0
  safe_incr(dict, "metrics:http:status:" .. tostring(status))

  -- Upstream error counter (5xx responses on allow-path)
  if status >= 500 and action ~= "deny" then
    safe_incr(dict, "metrics:http_upstream_errors_total")
  end

  -- Scanner threat counter (ADR-006 §3: per-threat_type counter)
  -- Validate against allowlist; unknown values normalized to "other".
  local threat_type = ctx and ctx.threat_type
  if threat_type then
    local normalized = THREAT_TYPE_ALLOWLIST[threat_type] and threat_type or "other"
    safe_incr(dict, "metrics:http_scanner_threats_total:threat:" .. normalized)
  end

  -- Latency histogram bucket
  local request_time_s = tonumber(ngx.var.request_time) or 0
  local latency_ms = request_time_s * 1000
  local bucket = latency_bucket(latency_ms)
  safe_incr(dict, "latency:bucket:" .. bucket)
end

return _M
