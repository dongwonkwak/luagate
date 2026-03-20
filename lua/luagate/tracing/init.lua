--- Tracing module initialisation for LuaGate.
-- ADR-010: loads config from conf/luagate.yaml, initialises sampler,
-- registers flush timer in init_worker_by_lua.
--
-- Config loading:
--   - init_by_lua: load conf/luagate.yaml, validate, set up sampler
--   - init_worker_by_lua: register ngx.timer.every for periodic flush
--   - If config missing or tracing.enabled=false → no-op mode
--
-- Implementation: lua/luagate/tracing/init.lua

local sampler = require("luagate.tracing.sampler")
local exporter = require("luagate.tracing.exporter")
local context = require("luagate.tracing.context")
local span_mod = require("luagate.tracing.span")
local buffer = require("luagate.tracing.buffer")

local _M = {}

-- Module state
local _enabled = false
local _config = nil

--- Load and validate tracing config from conf/luagate.yaml.
-- Called from init_by_lua. Fail-open: invalid config disables tracing.
-- ADR-010 §5: sample_rate from config or LUAGATE_TRACE_SAMPLE_RATE env var.
-- @param config_path string  Path to luagate.yaml (default: "conf/luagate.yaml")
function _M.init(config_path)
  config_path = config_path or "conf/luagate.yaml"

  -- Try to load YAML config
  local f = io.open(config_path, "r")
  if not f then
    -- No config file → tracing disabled (fail-open)
    ngx.log(ngx.NOTICE, "[luagate:tracing] config not found at ", config_path, ", tracing disabled")
    _enabled = false
    return
  end

  local content = f:read("*all")
  f:close()

  if not content or #content == 0 then
    ngx.log(ngx.NOTICE, "[luagate:tracing] empty config file, tracing disabled")
    _enabled = false
    return
  end

  -- Parse YAML (use lyaml if available, fallback to simple parsing)
  local ok_yaml, yaml = pcall(require, "lyaml")
  if not ok_yaml then
    ngx.log(ngx.ERR, "[luagate:tracing] lyaml not available, tracing disabled")
    _enabled = false
    return
  end

  local ok_parse, parsed = pcall(yaml.load, content)
  if not ok_parse or not parsed then
    ngx.log(ngx.ERR, "[luagate:tracing] YAML parse error, tracing disabled: ", tostring(parsed))
    _enabled = false
    return
  end

  local tracing = parsed.tracing
  if not tracing then
    ngx.log(ngx.NOTICE, "[luagate:tracing] no 'tracing' section in config, tracing disabled")
    _enabled = false
    return
  end

  if tracing.enabled == false then
    ngx.log(ngx.NOTICE, "[luagate:tracing] tracing.enabled=false, tracing disabled")
    _enabled = false
    return
  end

  -- Environment variable override for sample_rate
  local env_rate = os.getenv("LUAGATE_TRACE_SAMPLE_RATE")
  local sample_rate = tracing.sample_rate or 0.01
  if env_rate then
    local rate_num = tonumber(env_rate)
    if rate_num then
      sample_rate = rate_num
    else
      ngx.log(ngx.ERR, "[luagate:tracing] invalid LUAGATE_TRACE_SAMPLE_RATE: ", env_rate)
    end
  end

  -- Configure modules
  sampler.set_rate(sample_rate)

  exporter.configure({
    endpoint = tracing.endpoint or "http://localhost:4318/v1/traces",
    export_timeout_ms = tracing.export_timeout_ms or 10000,
    exporter = tracing.exporter or "otlp_http",
    service_name = tracing.service_name or "luagate",
  })

  _config = {
    sample_rate = sample_rate,
    flush_interval_ms = tracing.flush_interval_ms or 5000,
    batch_size = tracing.batch_size or 1024,
  }

  _enabled = true
  ngx.log(
    ngx.NOTICE,
    "[luagate:tracing] initialised: sample_rate=",
    sample_rate,
    ", exporter=",
    tracing.exporter or "otlp_http",
    ", flush_interval=",
    _config.flush_interval_ms,
    "ms"
  )
end

--- Register periodic flush timer. Called from init_worker_by_lua.
-- ADR-010 §4: worker-level timer, one per worker.
function _M.init_worker()
  if not _enabled then
    return
  end

  local interval_s = (_config.flush_interval_ms or 5000) / 1000

  local ok, err = ngx.timer.every(interval_s, exporter.flush)
  if not ok then
    ngx.log(ngx.ERR, "[luagate:tracing] failed to register flush timer: ", tostring(err))
  else
    ngx.log(ngx.NOTICE, "[luagate:tracing] worker ", ngx.worker.id(), ": flush timer registered (", interval_s, "s)")
  end
end

--- Check if tracing is enabled.
-- @return boolean
function _M.is_enabled()
  return _enabled
end

--- Initialise trace context for an HTTP request (rewrite_by_lua).
-- ADR-010 §2, §5, §7: parse inbound traceparent, make sampling decision,
-- generate trace_id/span_id, create root span.
-- @return table|nil  trace_ctx stored in ngx.ctx.luagate.trace
function _M.start_request_trace()
  if not _enabled then
    return nil
  end

  -- Parse inbound traceparent
  local tp_header = ngx.req.get_headers()["traceparent"]
  local parsed = context.parse_traceparent(tp_header)

  -- Determine trace_id
  local trace_id
  local parent_span_id = ""
  if parsed then
    trace_id = parsed.trace_id
    parent_span_id = parsed.parent_id
  else
    trace_id = context.new_trace_id()
  end

  -- Sampling decision (ADR-010 §5)
  local sampled = sampler.should_sample(parsed)

  -- Create root span (SpanKind=SERVER)
  -- ADR-010 §2: start time backdated to ngx.req.start_time()
  local start_time_ns = ngx.req.start_time() * 1e9
  local root_span = span_mod.new({
    trace_id = trace_id,
    parent_span_id = parent_span_id,
    name = "HTTP " .. (ngx.req.get_method() or "UNKNOWN"),
    kind = span_mod.SPAN_KIND_SERVER,
    start_time_ns = start_time_ns,
  })

  -- Set semantic convention attributes (OTel v1.25+)
  span_mod.set_attribute(root_span, "http.request.method", ngx.req.get_method())
  span_mod.set_attribute(root_span, "url.scheme", ngx.var.scheme or "http")
  span_mod.set_attribute(root_span, "url.path", ngx.var.uri)
  span_mod.set_attribute(root_span, "server.address", ngx.var.host or "")
  span_mod.set_attribute(root_span, "server.port", tonumber(ngx.var.server_port) or 0)
  span_mod.set_attribute(root_span, "luagate.request_id", ngx.var.luagate_request_id or "")

  local trace_ctx = {
    trace_id = trace_id,
    root_span = root_span,
    sampled = sampled,
    has_inbound = parsed ~= nil,
    child_spans = {},
  }

  return trace_ctx
end

--- Create a child span within the current trace.
-- @param trace_ctx table  From start_request_trace()
-- @param name string  Span name (e.g. "normalize", "policy_eval")
-- @param kind string|nil  SpanKind (default: INTERNAL)
-- @return table|nil  child span
function _M.start_child_span(trace_ctx, name, kind)
  if not trace_ctx then
    return nil
  end

  local child = span_mod.new({
    trace_id = trace_ctx.trace_id,
    parent_span_id = trace_ctx.root_span.span_id,
    name = name,
    kind = kind or span_mod.SPAN_KIND_INTERNAL,
  })

  trace_ctx.child_spans[#trace_ctx.child_spans + 1] = child
  return child
end

--- Inject outbound traceparent header for upstream.
-- ADR-010 §7: proxy child span's span_id as parent in outbound header.
-- @param trace_ctx table
-- @param proxy_span table  The proxy child span
function _M.inject_outbound(trace_ctx, proxy_span)
  if not trace_ctx or not proxy_span then
    return
  end

  local tp = context.build_traceparent(trace_ctx.trace_id, proxy_span.span_id, trace_ctx.sampled)
  ngx.req.set_header("traceparent", tp)

  -- ADR-010 §7: tracestate handling
  -- Inbound trace: pass-through existing tracestate (no action needed)
  -- New trace: clear any stale tracestate
  if not trace_ctx.has_inbound then
    ngx.req.clear_header("tracestate")
  end
end

--- Finish the request trace (log_by_lua).
-- Completes root span, adds all spans to buffer if sampled.
-- @param trace_ctx table
function _M.finish_request_trace(trace_ctx)
  if not trace_ctx then
    return
  end

  -- Finish root span
  local root = trace_ctx.root_span
  span_mod.finish(root)

  -- Set response attributes
  local status = tonumber(ngx.var.status) or 0
  span_mod.set_attribute(root, "http.response.status_code", status)

  if status >= 500 then
    span_mod.set_error(root, tostring(status))
  elseif status >= 400 then
    -- 4xx are not errors from server perspective in OTel
    span_mod.set_ok(root)
  else
    span_mod.set_ok(root)
  end

  -- Only export if sampled
  if not trace_ctx.sampled then
    return
  end

  -- Add all spans to buffer
  buffer.add(root)
  for _, child in ipairs(trace_ctx.child_spans) do
    if not child.end_time_ns then
      span_mod.finish(child)
    end
    buffer.add(child)
  end
end

--- Get trace_id and span_id for log fields.
-- Always returns values when tracing enabled (regardless of sampling).
-- ADR-010 §5: trace_id/span_id logged even when not sampled.
-- @param trace_ctx table|nil
-- @return string|nil trace_id, string|nil span_id
function _M.get_log_fields(trace_ctx)
  if not trace_ctx then
    return nil, nil
  end
  return trace_ctx.trace_id, trace_ctx.root_span.span_id
end

return _M
