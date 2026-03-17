--- HTTP access log record builder for LuaGate.
-- Builds a 27-field JSON record (log-schema.md §3) and assigns the result
-- to ngx.var.luagate_log_json so Nginx native access_log can write it.
--
-- Design rules:
--   - No blocking I/O (io.open / io.write prohibited — log-schema.md §8).
--   - Nullable fields use cjson.null for proper JSON null serialisation
--     (log-schema.md §2).
--   - Redaction applied here: sensitive query params and auth headers
--     are masked before the record is serialised (ADR-004 §4.2b, ADR-007).
--   - $luagate_log_json receives the already-encoded JSON string; the
--     log_format MUST NOT add escape=json (would double-escape).
--
-- Implementation: lua/luagate/log/http.lua
-- Tests: tests/unit/log/http_spec.lua

local _M = {}

-- cjson.safe returns nil on error rather than raising (safe for log phase)
local cjson = require("cjson.safe")

-- Ensure empty tables encode as objects, not arrays
cjson.encode_empty_table_as_array(false)

local NULL = cjson.null

-- ---------------------------------------------------------------------------
-- Internal: redaction helpers (ADR-004 §4.2b + ADR-007)
-- ---------------------------------------------------------------------------

-- Sensitive query parameter names (lower-case for comparison)
local SENSITIVE_QUERY_PARAMS = {
  token = true,
  api_key = true,
  apikey = true,
  password = true,
  passwd = true,
  secret = true,
}

--- Redact sensitive values from a raw query string.
-- Keeps parameter keys; replaces sensitive values with "***".
-- Input/output: raw query string (e.g. "page=1&token=abc").
-- @param qs string  Raw query string (may be empty)
-- @return  string   Redacted query string
local function redact_query_string(qs)
  if not qs or qs == "" then
    return ""
  end
  -- Replace key=value pairs where key is sensitive
  return (
    qs:gsub("([^&=?]+)=([^&]*)", function(key, _value)
      if SENSITIVE_QUERY_PARAMS[key:lower()] then
        return key .. "=***"
      end
      -- Return nil to keep original match unchanged
      return nil
    end)
  )
end

--- Convert a nullable nginx variable string to cjson.null or number.
-- Nginx returns empty string "" or "-" for absent variables.
-- @param val string|nil  Raw nginx variable value
-- @return  number|userdata  Parsed number or cjson.null
local function nullable_number(val)
  if val == nil or val == "" or val == "-" then
    return NULL
  end
  local n = tonumber(val)
  if n == nil then
    return NULL
  end
  return n
end

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

--- Build the 27-field log record and set ngx.var.luagate_log_json.
-- Called from log_by_lua (via handler.log_phase).
-- Errors are silently caught by the caller (pcall in handler.log_phase).
function _M.finalize()
  local ctx = ngx.ctx.luagate or {}

  -- latency_ms: total request time in milliseconds (log-schema.md §3.1)
  local request_time_s = tonumber(ngx.var.request_time) or 0
  local latency_ms = request_time_s * 1000

  -- upstream_latency_ms: nil when deny (no upstream call)
  local upstream_rt = ngx.var.upstream_response_time
  local upstream_latency_ms
  if upstream_rt == nil or upstream_rt == "" or upstream_rt == "-" then
    upstream_latency_ms = NULL
  else
    local n = tonumber(upstream_rt)
    upstream_latency_ms = n and (n * 1000) or NULL
  end

  -- content_length: nullable (many requests have no body)
  local content_length = nullable_number(ngx.var.content_length)

  -- user_agent: nullable
  local user_agent = nullable_string(ngx.var.http_user_agent)

  -- matched_rule_id: from ctx (set by access phase) or nginx var
  local matched_rule_id
  if ctx.matched_rule_id ~= nil then
    matched_rule_id = ctx.matched_rule_id
  else
    matched_rule_id = nullable_string(ngx.var.luagate_matched_rule)
  end

  -- deny_reason: nullable
  local deny_reason
  if ctx.deny_reason ~= nil then
    deny_reason = ctx.deny_reason
  else
    deny_reason = nullable_string(ngx.var.luagate_deny_reason)
  end

  -- threat_type: nullable
  local threat_type
  if ctx.threat_type ~= nil then
    threat_type = ctx.threat_type
  else
    threat_type = nullable_string(ngx.var.luagate_threat_type)
  end

  -- threat_score: nullable number
  local threat_score
  if ctx.threat_score ~= nil then
    threat_score = ctx.threat_score
  else
    threat_score = nullable_number(ngx.var.luagate_threat_score)
  end

  -- rule_name: nullable
  local rule_name
  if ctx.rule_name ~= nil then
    rule_name = ctx.rule_name
  else
    rule_name = nullable_string(ngx.var.luagate_rule_name)
  end

  -- query_string: redact sensitive parameters (ADR-007)
  local raw_qs = ctx.query_raw or ngx.var.luagate_query_string or ""
  local query_string = redact_query_string(raw_qs)

  -- Build 27-field record (log-schema.md §3.1 + ADR-004 §4.1)
  local record = {
    -- Fields 1-13: request metadata (produced in rewrite phase)
    timestamp = ngx.var.time_iso8601,
    request_id = ngx.var.luagate_request_id or ctx.request_id or "",
    src_ip = ngx.var.luagate_src_ip or ngx.var.remote_addr,
    src_port = tonumber(ngx.var.remote_port),
    dst_port = tonumber(ngx.var.server_port),
    method = ngx.req.get_method(),
    host = ngx.var.host,
    path_raw = ctx.path_raw or ngx.var.luagate_path_raw or "",
    path_normalized = ctx.path_normalized or ngx.var.luagate_path_normalized or "",
    query_string = query_string,
    http_version = ngx.var.server_protocol,
    user_agent = user_agent,
    content_length = content_length,
    -- Fields 14-20: access phase decision
    action = ngx.var.luagate_action or ctx.action or "allow",
    matched_rule_id = matched_rule_id,
    deny_reason = deny_reason,
    decision_source = ctx.decision_source or ngx.var.luagate_decision_source or "nginx_core",
    threat_type = threat_type,
    threat_score = threat_score,
    rule_name = rule_name,
    -- Fields 21-27: log phase fields
    request_state = ngx.var.luagate_request_state or "short_circuited",
    latency_ms = latency_ms,
    upstream_latency_ms = upstream_latency_ms,
    response_status = tonumber(ngx.var.status) or 0,
    bytes_sent = tonumber(ngx.var.bytes_sent) or 0,
    active_version = ngx.var.luagate_active_version or ctx.active_version or "none",
    worker_id = tonumber(ngx.var.luagate_worker_id) or ngx.worker.id(),
  }

  local json, err = cjson.encode(record)
  if not json then
    ngx.log(ngx.ERR, "[luagate] cjson.encode failed in log.http: ", tostring(err))
    -- Fallback: minimal valid JSON to avoid empty log line
    ngx.var.luagate_log_json = '{"error":"log_encode_failed"}'
    return
  end

  ngx.var.luagate_log_json = json
end

return _M
