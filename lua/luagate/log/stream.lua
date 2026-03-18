--- Stream session log record builder for LuaGate.
-- Builds an 18-field JSON record (log-schema.md §4) and assigns the result
-- to ngx.var.luagate_stream_log_json so Nginx native access_log can write it.
--
-- Design rules:
--   - No blocking I/O (io.open / io.write prohibited — log-schema.md §8).
--   - Nullable fields use cjson.null for proper JSON null serialisation
--     (log-schema.md §2).
--   - src_ip: original preserved, no masking (spec: raw preservation).
--   - $luagate_stream_log_json receives the already-encoded JSON string; the
--     log_format MUST NOT add escape=json (would double-escape).
--
-- Implementation: lua/luagate/log/stream.lua
-- Tests: tests/unit/log/stream_spec.lua

local _M = {}

-- cjson.safe returns nil on error rather than raising (safe for log phase)
local cjson = require("cjson.safe")

-- Ensure empty tables encode as objects, not arrays
cjson.encode_empty_table_as_array(false)

local NULL = cjson.null

--- Convert a nullable nginx variable string to cjson.null or string.
-- @param val string|nil
-- @return  string|userdata
local function nullable_string(val)
  if val == nil or val == "" or val == "-" or val == "null" then
    return NULL
  end
  return val
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Build the 18-field log record and set ngx.var.luagate_stream_log_json.
-- Called from log_by_lua (via pcall in nginx.conf stream block).
-- Errors are silently caught by the caller (pcall wrapper).
function _M.finalize()
  local ctx = ngx.ctx.luagate_stream or {}

  -- session_duration_ms: total session time in milliseconds (log-schema.md §4.1)
  local session_time_s = tonumber(ngx.var.session_time) or 0
  local session_duration_ms = session_time_s * 1000

  -- upstream_connect_time_ms: nil when deny (no upstream call)
  local upstream_ct = ngx.var.upstream_connect_time
  local upstream_connect_time_ms
  if upstream_ct == nil or upstream_ct == "" or upstream_ct == "-" then
    upstream_connect_time_ms = NULL
  else
    local n = tonumber(upstream_ct)
    upstream_connect_time_ms = n and (n * 1000) or NULL
  end

  -- bytes_received: from upstream
  local bytes_received = tonumber(ngx.var.upstream_bytes_received) or 0

  -- Nullable fields from ctx
  local sni = ctx.sni
  if sni == nil or sni == "" then
    sni = NULL
  end

  local matched_rule_id = ctx.matched_rule_id
  if matched_rule_id == nil or matched_rule_id == "" then
    matched_rule_id = nullable_string(ngx.var.luagate_matched_rule)
  end

  local upstream = ctx.upstream
  if upstream == nil or upstream == "" then
    upstream = NULL
  end

  -- Build 18-field record (log-schema.md §4.1 + ADR-004 §4.2)
  local record = {
    -- Fields from log phase
    timestamp = ngx.var.time_iso8601,
    -- Fields from preread phase (ctx)
    connection_id = ctx.connection_id or ngx.var.luagate_conn_id or "",
    src_ip = ctx.src_ip or ngx.var.remote_addr or "",
    src_port = ctx.src_port or tonumber(ngx.var.remote_port) or 0,
    dst_port = ctx.dst_port or tonumber(ngx.var.server_port) or 0,
    detected_protocol = ctx.detected_protocol or ngx.var.luagate_protocol or "raw",
    sni = sni,
    action = ctx.action or ngx.var.luagate_stream_action or "deny",
    matched_rule_id = matched_rule_id,
    decision_source = ctx.decision_source or ngx.var.luagate_decision_source or "nginx_core",
    active_version = ctx.active_version or ngx.var.luagate_active_version or "none",
    upstream = upstream,
    -- Fields from log phase (nginx vars)
    session_duration_ms = session_duration_ms,
    bytes_sent = tonumber(ngx.var.bytes_sent) or 0,
    bytes_received = bytes_received,
    upstream_connect_time_ms = upstream_connect_time_ms,
    request_state = ctx.request_state or ngx.var.luagate_request_state or "short_circuited",
    worker_id = ctx.worker_id or tonumber(ngx.var.luagate_worker_id) or ngx.worker.id(),
  }

  local json, err = cjson.encode(record)
  if not json then
    ngx.log(ngx.ERR, "[luagate-stream] cjson.encode failed in log.stream: ", tostring(err))
    -- Fallback: minimal valid JSON to avoid empty log line
    ngx.var.luagate_stream_log_json = '{"error":"stream_log_encode_failed"}'
    return
  end

  ngx.var.luagate_stream_log_json = json
end

return _M
