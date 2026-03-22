--- OTLP/HTTP batch exporter for LuaGate tracing.
-- ADR-010 §3-4: OTLP/HTTP (JSON) export via ngx.timer.every.
--
-- Transport: lua-resty-http (ADR-010 §4 exporter HTTP transport contract)
-- Single-flight flush: worker-local boolean flag prevents concurrent flushes.
-- Worker shutdown: premature=true → best-effort final flush.
--
-- Implementation: lua/luagate/tracing/exporter.lua

local buffer = require("luagate.tracing.buffer")
local cjson = require("cjson.safe")

local _M = {}

-- Module-level config (set via configure())
local _config = {
  endpoint = "http://localhost:4318/v1/traces",
  export_timeout_ms = 10000,
  exporter = "otlp_http", -- "otlp_http" | "stdout"
  service_name = "luagate",
}

local _flushing = false -- single-flight guard

--- Configure the exporter.
-- @param opts table  { endpoint, export_timeout_ms, exporter, service_name }
function _M.configure(opts)
  if opts.endpoint then
    _config.endpoint = opts.endpoint
  end
  if opts.export_timeout_ms then
    _config.export_timeout_ms = opts.export_timeout_ms
  end
  if opts.exporter then
    _config.exporter = opts.exporter
  end
  if opts.service_name then
    _config.service_name = opts.service_name
  end
  if opts.batch_size then
    _config.batch_size = opts.batch_size
  end
end

--- Convert spans to OTLP JSON format.
-- @param spans table  Array of span objects
-- @return string  JSON encoded OTLP trace data
local function spans_to_otlp_json(spans)
  local otlp_spans = {}
  for _, s in ipairs(spans) do
    local attrs = {}
    for k, v in pairs(s.attributes or {}) do
      local attr = { key = k }
      if type(v) == "number" then
        attr.value = { intValue = tostring(math.floor(v)) }
      elseif type(v) == "boolean" then
        attr.value = { boolValue = v }
      else
        attr.value = { stringValue = tostring(v) }
      end
      attrs[#attrs + 1] = attr
    end

    otlp_spans[#otlp_spans + 1] = {
      traceId = s.trace_id,
      spanId = s.span_id,
      parentSpanId = (s.parent_span_id ~= "") and s.parent_span_id or nil,
      name = s.name,
      kind = s.kind,
      startTimeUnixNano = tostring(math.floor(s.start_time_ns)),
      endTimeUnixNano = tostring(math.floor(s.end_time_ns or s.start_time_ns)),
      status = {
        code = s.status_code,
        message = s.status_message,
      },
      attributes = attrs,
    }
  end

  local payload = {
    resourceSpans = {
      {
        resource = {
          attributes = {
            { key = "service.name", value = { stringValue = _config.service_name } },
          },
        },
        scopeSpans = {
          {
            scope = { name = "luagate.tracing", version = "1.0.0" },
            spans = otlp_spans,
          },
        },
      },
    },
  }

  return cjson.encode(payload)
end

--- Export spans via stdout (development mode).
-- @param spans table  Array of span objects
local function export_stdout(spans)
  local json = spans_to_otlp_json(spans)
  if json then
    ngx.log(ngx.INFO, "[luagate:tracing:stdout] ", json)
  end
end

--- Export spans via OTLP/HTTP POST.
-- ADR-010 §4: lua-resty-http with keepalive.
-- @param spans table  Array of span objects
--- Increment spans_dropped_total metric on export failure.
-- @param count number  Number of spans dropped
local function incr_dropped(count)
  local dict = ngx.shared.luagate_metrics
  if dict then
    dict:incr("luagate_tracing_spans_dropped_total", count, 0)
  end
end

local function export_otlp_http(spans)
  local json = spans_to_otlp_json(spans)
  if not json then
    ngx.log(ngx.ERR, "[luagate:tracing] failed to encode spans to OTLP JSON")
    incr_dropped(#spans)
    return
  end

  local ok_http, http = pcall(require, "resty.http")
  if not ok_http then
    ngx.log(ngx.ERR, "[luagate:tracing] lua-resty-http not available: ", tostring(http))
    return
  end

  local httpc = http.new()
  if not httpc then
    ngx.log(ngx.ERR, "[luagate:tracing] failed to create HTTP client")
    return
  end

  local timeout = _config.export_timeout_ms
  httpc:set_timeouts(5000, timeout, timeout) -- connect, send, read

  local res, err = httpc:request_uri(_config.endpoint, {
    method = "POST",
    body = json,
    headers = {
      ["Content-Type"] = "application/json",
    },
  })

  if not res then
    ngx.log(ngx.ERR, "[luagate:tracing] OTLP export failed: ", tostring(err))
    incr_dropped(#spans)
    return
  end

  if res.status >= 400 then
    ngx.log(ngx.ERR, "[luagate:tracing] OTLP export HTTP ", res.status, ": ", tostring(res.body))
  end
end

--- Export a single chunk of spans.
-- @param chunk table  Array of span objects
local function export_chunk(chunk)
  if _config.exporter == "stdout" then
    export_stdout(chunk)
  else
    export_otlp_http(chunk)
  end
end

--- Flush buffered spans.
-- ADR-010 §4: single-flight guard + atomic buffer swap.
-- Splits into batch_size chunks to respect OTLP payload limits.
-- @param premature boolean  true if called during worker shutdown
function _M.flush(premature)
  -- Single-flight: skip if another flush is in progress
  if _flushing then
    return
  end
  _flushing = true

  local batch = buffer.swap()

  if #batch == 0 then
    _flushing = false
    return
  end

  -- Split into batch_size chunks (ADR-010 §5 config)
  local batch_size = _config.batch_size or 1024
  if #batch <= batch_size then
    export_chunk(batch)
  else
    for i = 1, #batch, batch_size do
      local chunk = {}
      for j = i, math.min(i + batch_size - 1, #batch) do
        chunk[#chunk + 1] = batch[j]
      end
      export_chunk(chunk)
    end
  end

  _flushing = false

  -- Worker shutdown: log span count for observability
  if premature then
    ngx.log(ngx.NOTICE, "[luagate:tracing] premature flush: exported ", #batch, " spans")
  end
end

--- Get the current exporter config (for testing).
-- @return table
function _M.get_config()
  return _config
end

return _M
