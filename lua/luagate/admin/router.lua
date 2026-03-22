--- Admin API router module for LuaGate.
-- Routes method + URI to handler functions within the admin server block (:9090).
-- Called from content_by_lua_block after auth.verify() has validated the request.
--
-- Design rules:
--   - No blocking I/O.
--   - ngx.ctx MUST NOT store policy cache.
--   - cjson.safe for all JSON encoding (pcall-safe).
--   - Error responses follow admin-api.md ss3 shape:
--       {"error":"<code>","stage":"routing","details":["<message>"]}
--   - Threat type allowlist (12 fixed values) for scanner metrics.
--   - All shared dict zone names use luagate_ prefix.
--
-- Implementation: lua/luagate/admin/router.lua
-- Tests: tests/unit/admin/router_spec.lua

local cjson = require("cjson.safe")
local auth = require("luagate.admin.auth")
local ratelimit = require("luagate.admin.ratelimit")
local policies = require("luagate.admin.policies")
local token = require("luagate.admin.token")

local _M = {}
local EMPTY_JSON_ARRAY = cjson.empty_array or setmetatable({}, { __jsontype = "array" })
local LUAGATE_VERSION = "0.1.0"

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

-- ADR-009 Phase 3: per-worker FFI leak threshold for health degradation.
-- If any worker's leak count exceeds this value, /health returns 503.
local FFI_LEAK_THRESHOLD = 10

-- Latency histogram bucket boundaries (must match collector.lua)
local LATENCY_BUCKETS = { 0.1, 0.5, 1, 5, 10, 50, 100, 500, 1000 }

-- Threat type allowlist (ADR-006 ss1.1) — 12 fixed values
local THREAT_TYPES = {
  "sqli",
  "xss",
  "path_traversal",
  "cmd_injection",
  "lfi",
  "rfi",
  "xxe",
  "ssrf",
  "log4shell",
  "scanner",
  "deserialization",
  "other",
}

-- All 6 shared dict zones for capacity/free_space gauges
local SHARED_DICT_ZONES = {
  "luagate_policy",
  "luagate_state",
  "luagate_metrics",
  "luagate_stream_metrics",
  "luagate_connections",
  "luagate_admin_ratelimit",
}

-- Stream protocol types for protocol_detected_total
local STREAM_PROTOCOLS = { "tls", "http", "raw" }

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Send a JSON error response.
-- @param status  number  HTTP status code
-- @param code    string  Error code (e.g. "not_found")
-- @param stage   string  Pipeline stage (admin-api.md ss3)
-- @param message string  Human-readable detail message
local function send_error(status, code, stage, message)
  ngx.status = status
  ngx.header["Content-Type"] = "application/json"
  local body = cjson.encode({
    error = code,
    stage = stage,
    details = { message },
  })
  ngx.say(body or '{"error":"encode_failed","stage":"internal","details":["JSON encode error"]}')
  ngx.exit(status)
end

--- Send a JSON success response.
-- @param status number  HTTP status code
-- @param data   table   Response body table
local function send_json(status, data)
  ngx.status = status
  ngx.header["Content-Type"] = "application/json"
  local body = cjson.encode(data)
  ngx.say(body or '{"error":"encode_failed"}')
  ngx.exit(status)
end

--- Read a counter value from a shared dict, defaulting to 0.
-- @param dict table  ngx.shared.* dict object
-- @param key  string Counter key
-- @return number
local function get_counter(dict, key)
  if not dict then
    return 0
  end
  local val = dict:get(key)
  return tonumber(val) or 0
end

--- Append a Prometheus metric line to the output buffer.
-- @param buf     table   String buffer (array of strings)
-- @param name    string  Metric name
-- @param labels  string  Label string (e.g. '{action="allow"}') or ""
-- @param value   number  Metric value
local function prom_line(buf, name, labels, value)
  buf[#buf + 1] = name .. labels .. " " .. tostring(value) .. "\n"
end

--- Append a HELP + TYPE header for a Prometheus metric.
-- @param buf      table   String buffer
-- @param name     string  Metric name
-- @param mtype    string  Prometheus type (counter, gauge, histogram)
-- @param help_txt string  Help text
local function prom_header(buf, name, mtype, help_txt)
  buf[#buf + 1] = "# HELP " .. name .. " " .. help_txt .. "\n"
  buf[#buf + 1] = "# TYPE " .. name .. " " .. mtype .. "\n"
end

-- ---------------------------------------------------------------------------
-- Endpoint handlers
-- ---------------------------------------------------------------------------

--- Format epoch timestamp as ISO-8601 UTC string.
-- @param epoch number  ngx.now() epoch seconds
-- @return string ISO-8601 formatted datetime
local function format_iso8601(epoch)
  if not epoch or epoch == 0 then
    return nil
  end
  return os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(epoch))
end

--- Collect per-worker FFI leak counts from shared dict.
-- Reads ffi:timeout:leak:<wid> for each worker (0..worker_count-1).
-- @return table  per-worker leak count array (1-indexed, index = wid + 1)
-- @return number total sum of all leak counts
-- @return number max leak count across all workers
local function collect_ffi_leak_counts()
  local metrics_dict = ngx.shared.luagate_metrics
  if not metrics_dict then
    return EMPTY_JSON_ARRAY, 0, 0
  end

  local ok, worker_count = pcall(ngx.worker.count)
  if not ok or not worker_count or worker_count < 1 then
    -- Graceful degradation: fall back to current worker only.
    -- Preserve "index = worker id" contract by padding with 0s.
    local wid = ngx.worker.id()
    local val = tonumber(metrics_dict:get("ffi:timeout:leak:" .. wid)) or 0
    local counts = {}
    for i = 1, wid + 1 do
      counts[i] = 0
    end
    counts[wid + 1] = val
    return counts, val, val
  end

  local counts = {}
  local total = 0
  local max_leak = 0
  for wid = 0, worker_count - 1 do
    local val = tonumber(metrics_dict:get("ffi:timeout:leak:" .. wid)) or 0
    counts[wid + 1] = val
    total = total + val
    if val > max_leak then
      max_leak = val
    end
  end

  return counts, total, max_leak
end

--- GET /health — health check (auth exempted, handled by auth.verify).
-- Returns 200 if policy loaded and no FFI leak threshold exceeded.
-- Returns 503 if FFI leak threshold exceeded or policy not loaded.
-- ADR-008 §8.2: includes source_version, active_http_version,
-- active_stream_version, policy_loaded_at for multi-instance monitoring.
-- ADR-009 Phase 3: per-worker FFI leak array + 503 threshold.
local function handle_health()
  local policy_dict = ngx.shared.luagate_policy
  local http_version = policy_dict and policy_dict:get("http:active_version")
  local stream_version = policy_dict and policy_dict:get("stream:active_version")
  local source_version = policy_dict and policy_dict:get("source_version")
  local loaded_at_epoch = policy_dict and policy_dict:get("policy_loaded_at")

  -- ADR-009 Phase 3: per-worker FFI watchdog leak counts
  local leak_counts, ffi_timeouts, max_leak = collect_ffi_leak_counts()

  local NULL = cjson.null

  local body = {
    source_version = source_version or NULL,
    active_http_version = http_version or NULL,
    active_stream_version = stream_version or NULL,
    policy_loaded_at = format_iso8601(loaded_at_epoch) or NULL,
    ffi_watchdog_leak_count = leak_counts,
    ffi_watchdog_timeouts = ffi_timeouts,
  }

  -- ADR-009: FFI leak threshold check takes priority over policy check
  if max_leak > FFI_LEAK_THRESHOLD then
    body.status = "unhealthy"
    body.reason = "ffi_thread_leak_threshold_exceeded"
    send_json(503, body)
    return
  end

  if http_version and http_version ~= "none" then
    body.status = "ok"
    send_json(200, body)
  else
    body.status = "unhealthy"
    body.reason = "policy not loaded"
    send_json(503, body)
  end
end

--- GET /api/v1/status — detailed server status.
-- Exposes a minimal status snapshot derived from shared dict state.
-- Uptime is approximated from the last successful policy load timestamp when
-- available, which is the earliest startup-time signal currently persisted.
local function handle_status()
  local policy_dict = ngx.shared.luagate_policy
  local http_version = policy_dict and policy_dict:get("http:active_version")
  local stream_version = policy_dict and policy_dict:get("stream:active_version")
  local loaded_at_epoch = policy_dict and policy_dict:get("policy_loaded_at")

  local ok, worker_count = pcall(ngx.worker.count)
  if not ok or not worker_count or worker_count < 1 then
    worker_count = 1
  end

  local uptime_seconds = 0
  if loaded_at_epoch and loaded_at_epoch > 0 then
    uptime_seconds = math.max(0, math.floor(ngx.now() - loaded_at_epoch))
  end

  send_json(200, {
    luagate_version = LUAGATE_VERSION,
    uptime_seconds = uptime_seconds,
    worker_count = worker_count,
    active_http_version = http_version or "none",
    active_stream_version = stream_version or "none",
    last_reload_at = format_iso8601(loaded_at_epoch),
    last_reload_status = loaded_at_epoch and "success" or "unknown",
  })
end

--- GET /metrics — Prometheus text exposition format.
-- Reads from luagate_metrics, luagate_stream_metrics, luagate_connections zones.
-- Also exposes shared dict capacity/free_space for all 5 zones.
local function handle_metrics()
  local metrics = ngx.shared.luagate_metrics
  local stream_metrics = ngx.shared.luagate_stream_metrics
  local connections = ngx.shared.luagate_connections

  local buf = {}

  -- ── HTTP request counters (ADR-006 ss3.2) ────────────────────────
  prom_header(buf, "luagate_http_requests_total", "counter", "Total HTTP requests by action.")
  prom_line(
    buf,
    "luagate_http_requests_total",
    '{action="allow"}',
    get_counter(metrics, "metrics:http_requests_total:allow")
  )
  prom_line(
    buf,
    "luagate_http_requests_total",
    '{action="deny"}',
    get_counter(metrics, "metrics:http_requests_total:deny")
  )

  -- ── HTTP denied counter (label-less, ADR-006 ss1.2) ───────────────
  prom_header(buf, "luagate_http_requests_denied_total", "counter", "Total denied HTTP requests.")
  prom_line(buf, "luagate_http_requests_denied_total", "", get_counter(metrics, "metrics:http_requests_denied_total"))

  -- ── Scanner threat counters ────────────────────────────────────────
  prom_header(buf, "luagate_http_scanner_threats_total", "counter", "Total scanner threat detections by type.")
  for _, ttype in ipairs(THREAT_TYPES) do
    local val = get_counter(metrics, "metrics:http_scanner_threats_total:threat:" .. ttype)
    if val > 0 then
      prom_line(buf, "luagate_http_scanner_threats_total", '{threat_type="' .. ttype .. '"}', val)
    end
  end

  -- ── Upstream error counter ─────────────────────────────────────────
  prom_header(buf, "luagate_http_upstream_errors_total", "counter", "Total upstream 5xx errors.")
  prom_line(buf, "luagate_http_upstream_errors_total", "", get_counter(metrics, "metrics:http_upstream_errors_total"))

  -- ── HTTP latency histogram ─────────────────────────────────────────
  prom_header(buf, "luagate_http_response_time_ms", "histogram", "HTTP response time in milliseconds.")
  local hist_name = "luagate_http_response_time_ms"
  for _, b in ipairs(LATENCY_BUCKETS) do
    local le = tostring(b)
    local val = get_counter(metrics, "latency:bucket:" .. le)
    prom_line(buf, hist_name .. "_bucket", '{le="' .. le .. '"}', val)
  end
  -- +Inf bucket (ADR-006 ss3.1: latency:bucket:+Inf)
  local inf_val = get_counter(metrics, "latency:bucket:+Inf")
  prom_line(buf, hist_name .. "_bucket", '{le="+Inf"}', inf_val)
  prom_line(buf, hist_name .. "_sum", "", get_counter(metrics, "latency:sum"))
  prom_line(buf, hist_name .. "_count", "", get_counter(metrics, "latency:count"))

  -- ── Policy reload counters ─────────────────────────────────────────
  prom_header(buf, "luagate_policy_reload_total", "counter", "Total policy reload attempts.")
  prom_line(buf, "luagate_policy_reload_total", "", get_counter(metrics, "metrics:policy_reload_total"))

  local reload_fail_name = "luagate_policy_reload_failures_total"
  prom_header(buf, reload_fail_name, "counter", "Total policy reload failures.")
  prom_line(buf, reload_fail_name, "", get_counter(metrics, "metrics:policy_reload_failures_total"))

  -- ── Stream counters ────────────────────────────────────────────────
  local s_conn = "luagate_stream_connections_total"
  prom_header(buf, s_conn, "counter", "Total stream connections.")
  prom_line(buf, s_conn, "", get_counter(stream_metrics, "stream:metrics:connections_total"))

  local s_denied = "luagate_stream_connections_denied_total"
  prom_header(buf, s_denied, "counter", "Total denied stream connections.")
  prom_line(buf, s_denied, "", get_counter(stream_metrics, "stream:metrics:connections_denied_total"))

  local s_sent = "luagate_stream_bytes_sent_total"
  prom_header(buf, s_sent, "counter", "Total bytes sent on stream connections.")
  prom_line(buf, s_sent, "", get_counter(stream_metrics, "stream:metrics:bytes_sent_total"))

  local s_recv = "luagate_stream_bytes_received_total"
  prom_header(buf, s_recv, "counter", "Total bytes received on stream connections.")
  prom_line(buf, s_recv, "", get_counter(stream_metrics, "stream:metrics:bytes_received_total"))

  local s_proto = "luagate_stream_protocol_detected_total"
  prom_header(buf, s_proto, "counter", "Stream connections by detected protocol.")
  for _, proto in ipairs(STREAM_PROTOCOLS) do
    local key = "stream:metrics:protocol_detected_total:" .. proto
    prom_line(buf, s_proto, '{protocol="' .. proto .. '"}', get_counter(stream_metrics, key))
  end

  -- ── Active connections gauge ───────────────────────────────────────
  prom_header(buf, "luagate_active_connections", "gauge", "Currently active connections by type.")
  prom_line(buf, "luagate_active_connections", '{type="http"}', get_counter(connections, "active_http"))
  prom_line(buf, "luagate_active_connections", '{type="stream"}', get_counter(connections, "active_stream"))

  -- ── Shared dict capacity/free gauges ───────────────────────────────
  prom_header(buf, "luagate_shared_dict_capacity_bytes", "gauge", "Shared dict total capacity in bytes.")
  prom_header(buf, "luagate_shared_dict_free_bytes", "gauge", "Shared dict free space in bytes.")
  for _, zone_name in ipairs(SHARED_DICT_ZONES) do
    local zone = ngx.shared[zone_name]
    if zone then
      prom_line(buf, "luagate_shared_dict_capacity_bytes", '{zone="' .. zone_name .. '"}', zone:capacity())
      prom_line(buf, "luagate_shared_dict_free_bytes", '{zone="' .. zone_name .. '"}', zone:free_space())
    end
  end

  -- ── Policy loaded gauge (ADR-008 §8.2) ────────────────────────────
  -- Version hashes are exposed only via /health (not as Prometheus labels)
  -- to comply with ADR-006 cardinality rules. This gauge tracks whether
  -- policy is loaded (1) or not (0) per subsystem.
  -- DON-213: subsystem label allows HTTP-only deployments to report loaded=1
  -- without requiring stream active_version.
  prom_header(buf, "luagate_policy_loaded", "gauge", "Whether policy is loaded per subsystem (1=loaded, 0=not loaded).")
  local policy_dict = ngx.shared.luagate_policy
  if policy_dict then
    local http_ver = policy_dict:get("http:active_version")
    local stream_ver = policy_dict:get("stream:active_version")
    local http_loaded = (http_ver and http_ver ~= "none") and 1 or 0
    prom_line(buf, "luagate_policy_loaded", '{subsystem="http"}', http_loaded)
    -- DON-213: Only emit stream subsystem metric when stream is configured.
    -- If stream:active_version was never set (nil) or is "none", stream is
    -- not configured — omit the time series entirely so HTTP-only deployments
    -- do not produce a perpetual 0 that confuses alerting.
    if stream_ver and stream_ver ~= "none" then
      prom_line(buf, "luagate_policy_loaded", '{subsystem="stream"}', 1)
    end
  else
    prom_line(buf, "luagate_policy_loaded", '{subsystem="http"}', 0)
  end

  -- ── Send response ──────────────────────────────────────────────────
  ngx.status = 200
  ngx.header["Content-Type"] = "text/plain; version=0.0.4; charset=utf-8"
  ngx.print(table.concat(buf))
  ngx.exit(200)
end

-- ---------------------------------------------------------------------------
-- Route table
-- ---------------------------------------------------------------------------

-- Maps URI path -> { [method] = handler_function }
-- Only exact-match routes are supported.
local ROUTES = {
  ["/health"] = {
    GET = handle_health,
  },
  ["/metrics"] = {
    GET = handle_metrics,
  },
  ["/api/v1/status"] = {
    GET = handle_status,
  },
  ["/api/v1/policies"] = {
    GET = policies.handle_get_policies,
    PUT = policies.handle_put_policies,
  },
  ["/api/v1/policies/version"] = {
    GET = policies.handle_get_version,
  },
  ["/api/v1/policies/reload"] = {
    POST = policies.handle_post_reload,
  },
  ["/api/v1/admin/token/rotate"] = {
    POST = token.handle_post_rotate,
  },
}

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Dispatch the current request to the appropriate handler.
-- Called from content_by_lua_block in the admin server block.
-- Flow:
--   0. ratelimit.check() — sliding window IP rate limit (/health exempt)
--   1. OPTIONS preflight → 204 (admin-auth-contract.md)
--   2. auth.verify() — handles /health exemption internally
--   3. Route lookup by URI path
--   4. Method check
--   5. Handler invocation
--
-- Note: no pcall around auth.verify() or handlers. In OpenResty,
-- ngx.exit() throws a Lua error to abort the coroutine — wrapping
-- in pcall would intercept that control flow and break 401/200/503
-- responses. Direct call is the correct pattern.
function _M.dispatch()
  local method = ngx.req.get_method()

  -- 0. Rate limiting (check handles /health exemption)
  -- ratelimit.check() calls ngx.exit(429) on exceeded, aborting the coroutine.
  ratelimit.check()

  -- 1. OPTIONS preflight: 204 (CORS, admin-auth-contract.md)
  if method == "OPTIONS" then
    ngx.status = 204
    ngx.exit(204)
    return
  end

  -- 2. Authentication (verify handles /health exemption)
  -- auth.verify() calls ngx.exit(401) on failure, aborting the coroutine.
  auth.verify()

  -- 3. Route lookup
  local uri = ngx.var.uri

  local route = ROUTES[uri]
  if not route then
    send_error(404, "not_found", "routing", method .. " " .. uri .. " not found")
    return
  end

  -- 4. Method check
  local handler = route[method]
  if not handler then
    send_error(405, "method_not_allowed", "routing", method .. " not allowed for " .. uri)
    return
  end

  -- 5. Invoke handler
  handler()
end

return _M
