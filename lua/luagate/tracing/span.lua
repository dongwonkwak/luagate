--- Span creation and lifecycle for LuaGate tracing.
-- ADR-010 §2: HTTP request root span + internal child spans.
--
-- Span kinds (OTel Semantic Conventions v1.25+):
--   root span: SpanKind=SERVER
--   proxy child: SpanKind=CLIENT
--   normalize/policy_eval/security_scan: SpanKind=INTERNAL
--
-- Implementation: lua/luagate/tracing/span.lua

local context = require("luagate.tracing.context")

local _M = {}

local SPAN_KIND_INTERNAL = "SPAN_KIND_INTERNAL"
local SPAN_KIND_SERVER = "SPAN_KIND_SERVER"
local SPAN_KIND_CLIENT = "SPAN_KIND_CLIENT"

_M.SPAN_KIND_INTERNAL = SPAN_KIND_INTERNAL
_M.SPAN_KIND_SERVER = SPAN_KIND_SERVER
_M.SPAN_KIND_CLIENT = SPAN_KIND_CLIENT

--- Create a new span.
-- @param opts table  { trace_id, parent_span_id, name, kind, start_time_ns }
-- @return table  span object
function _M.new(opts)
  local span_id = context.new_span_id()
  local now_ns = opts.start_time_ns or (ngx.now() * 1e9)

  return {
    trace_id = opts.trace_id,
    span_id = span_id,
    parent_span_id = opts.parent_span_id or "",
    name = opts.name or "unknown",
    kind = opts.kind or SPAN_KIND_INTERNAL,
    start_time_ns = now_ns,
    end_time_ns = nil,
    status_code = "STATUS_CODE_UNSET", -- UNSET | OK | ERROR
    status_message = nil,
    attributes = {},
  }
end

--- Set an attribute on a span.
-- @param span table
-- @param key  string
-- @param value string|number|boolean
function _M.set_attribute(span, key, value)
  if span and key then
    span.attributes[key] = value
  end
end

--- Mark a span as finished.
-- @param span table
-- @param end_time_ns number|nil  End time in nanoseconds (default: now)
function _M.finish(span, end_time_ns)
  if span then
    span.end_time_ns = end_time_ns or (ngx.now() * 1e9)
  end
end

--- Set span status to ERROR.
-- @param span table
-- @param error_type string  Error type description
function _M.set_error(span, error_type)
  if span then
    span.status_code = "STATUS_CODE_ERROR"
    span.attributes["error.type"] = error_type
  end
end

--- Set span status to OK.
-- @param span table
function _M.set_ok(span)
  if span then
    span.status_code = "STATUS_CODE_OK"
  end
end

return _M
