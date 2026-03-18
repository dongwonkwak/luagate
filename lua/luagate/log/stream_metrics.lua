--- Stream metrics collector for LuaGate.
-- Updates counters in luagate_stream_metrics shared dict during log phase.
--
-- Metric keys (ADR-006 §key mapping):
--   stream:metrics:connections_total          — all connections
--   stream:metrics:connections_denied_total   — denied connections
--   stream:metrics:bytes_sent_total           — proxy connections only
--   stream:metrics:bytes_received_total       — proxy connections only
--   stream:metrics:protocol_detected_total:<proto> — per-protocol
--
-- Implementation: lua/luagate/log/stream_metrics.lua
-- Tests: tests/unit/log/stream_metrics_spec.lua

local _M = {}

--- Collect stream metrics from the current session context.
-- Called from log_by_lua (via pcall in nginx.conf stream block).
function _M.collect()
  local dict = ngx.shared.luagate_stream_metrics
  if not dict then
    return
  end

  local ctx = ngx.ctx.luagate_stream or {}

  -- 1. Total connections counter (all connections)
  dict:incr("stream:metrics:connections_total", 1, 0)

  -- 2. Denied connections counter
  local action = ctx.action or ngx.var.luagate_stream_action or "deny"
  if action == "deny" then
    dict:incr("stream:metrics:connections_denied_total", 1, 0)
  end

  -- 3. Bytes counters (proxy connections only)
  if action == "proxy" then
    local bytes_sent = tonumber(ngx.var.bytes_sent) or 0
    if bytes_sent > 0 then
      dict:incr("stream:metrics:bytes_sent_total", bytes_sent, 0)
    end

    local bytes_received = tonumber(ngx.var.upstream_bytes_received) or 0
    if bytes_received > 0 then
      dict:incr("stream:metrics:bytes_received_total", bytes_received, 0)
    end
  end

  -- 4. Protocol detection counter
  local protocol = ctx.detected_protocol or ngx.var.luagate_protocol or "raw"
  dict:incr("stream:metrics:protocol_detected_total:" .. protocol, 1, 0)
end

return _M
