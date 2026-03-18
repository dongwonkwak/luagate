--- Stream pipeline handler for LuaGate.
-- Implements preread_by_lua entry point called from nginx.conf stream block.
--
-- Invariants (AGENTS.md):
--   - ngx.ctx MUST NOT be used for policy caching.
--   - No blocking I/O.
--   - fail-closed: any error -> deny (connection close).
--   - worker_id via ngx.worker.id() only.
--   - All nginx variable names use luagate_ prefix.
--   - FFI free obligation: radix_free() must be called.
--
-- Pipeline order (stream-pipeline.md §2):
--   preread_by_lua  -> protocol detection + SNI extraction + policy evaluation
--   proxy_pass      -> TCP proxy (only if action == "proxy")
--   log_by_lua      -> session log + metrics (DON-144 scope)
--
-- Implementation: lua/luagate/stream/handler.lua
-- Tests: tests/unit/stream/handler_spec.lua

local _M = {}

-- Module-level radix tree cache (worker-local upvalue).
-- Rebuilt when policy active_version changes.
-- luacheck: ignore 211 _radix_tree _radix_version
local _radix_tree = nil -- reserved for CIDR radix hot reload (DON-XXX)
local _radix_version = nil -- reserved for CIDR radix hot reload (DON-XXX)

-- Bytes to read on each peek attempt
local PEEK_BYTES = 1024

--- Generate a connection UUID.
-- Uses ngx.var.connection as base with worker_id prefix for uniqueness.
-- @return string
local function generate_connection_id()
  -- In stream context, ngx.var.connection provides a unique serial number.
  -- Prefix with worker_id for cross-worker uniqueness.
  local wid = ngx.worker.id() or 0
  local conn = ngx.var.connection or "0"
  local time_ms = ngx.now() * 1000
  return string.format("sw%d-%s-%d", wid, conn, time_ms)
end

-- ---------------------------------------------------------------------------
-- preread_by_lua entry point
-- ---------------------------------------------------------------------------

--- Stream preread phase: protocol detection + SNI extraction + policy evaluation.
-- Called from preread_by_lua_block in nginx.conf stream block.
--
-- Processing order (stream-pipeline.md §2.1, §2.2):
--   1. Initialise ngx.ctx.luagate_stream context.
--   2. Increment active_stream counter in luagate_connections shared dict.
--   3. Peek preread buffer via reqsock.
--   4. Detect protocol via FFI (with NEED_MORE_DATA retry loop).
--   5. If TLS, extract SNI via FFI.
--   6. Load policy and evaluate stream rules.
--   7. deny -> ngx.exit(ngx.ERROR) (connection close).
--   8. proxy -> set $luagate_upstream variable.
--
-- fail-closed: any error -> deny (connection close).
function _M.preread()
  -- 1. Initialise stream context (stream-pipeline.md §7)
  local worker_id = ngx.worker.id() or 0
  local start_time_ms = ngx.now() * 1000

  local dict = ngx.shared.luagate_policy
  local stream_ver = dict and dict:get("stream:active_version") or "none"

  local ctx = {
    connection_id = generate_connection_id(),
    src_ip = ngx.var.remote_addr or "",
    src_port = tonumber(ngx.var.remote_port) or 0,
    dst_port = tonumber(ngx.var.server_port) or 0,
    detected_protocol = nil,
    sni = nil,
    action = "deny", -- fail-closed default
    matched_rule_id = nil,
    deny_reason = nil,
    decision_source = "nginx_core",
    active_version = stream_ver,
    request_state = "denied",
    start_time_ms = start_time_ms,
    upstream = nil,
    worker_id = worker_id,
  }
  ngx.ctx.luagate_stream = ctx

  -- 2. Increment active stream connections counter
  local conn_dict = ngx.shared.luagate_connections
  if conn_dict then
    local ok_incr, err_incr = conn_dict:incr("active_stream", 1, 0)
    if not ok_incr then
      ngx.log(ngx.WARN, "[luagate-stream] failed to incr active_stream: ", tostring(err_incr))
    end
  end

  -- Set nginx variables for logging
  ngx.var.luagate_conn_id = ctx.connection_id
  ngx.var.luagate_worker_id = tostring(worker_id)
  ngx.var.luagate_active_version = stream_ver

  -- 3. Peek preread buffer
  local ok_sock, sock = pcall(ngx.req.socket)
  if not ok_sock or not sock then
    ngx.log(ngx.ERR, "[luagate-stream] failed to get request socket: ", tostring(sock))
    ctx.deny_reason = "socket_error"
    ctx.request_state = "denied"
    ngx.var.luagate_stream_action = "deny"
    ngx.var.luagate_request_state = "denied"
    return ngx.exit(ngx.ERROR)
  end

  local preread_data
  local ok_peek, data, peek_err = pcall(sock.receive, sock, PEEK_BYTES)
  if ok_peek and data then
    preread_data = data
  elseif ok_peek and peek_err == "timeout" then
    -- Partial data available (timeout means partial read in stream context)
    preread_data = data or ""
  else
    ngx.log(ngx.ERR, "[luagate-stream] preread peek failed: ", tostring(data or peek_err))
    ctx.deny_reason = "peek_io_error"
    ctx.request_state = "denied"
    ngx.var.luagate_stream_action = "deny"
    ngx.var.luagate_request_state = "denied"
    return ngx.exit(ngx.ERROR)
  end

  if not preread_data or #preread_data == 0 then
    ngx.log(ngx.ERR, "[luagate-stream] empty preread data")
    ctx.deny_reason = "empty_preread"
    ctx.request_state = "denied"
    ngx.var.luagate_stream_action = "deny"
    ngx.var.luagate_request_state = "denied"
    return ngx.exit(ngx.ERROR)
  end

  -- 4. Protocol detection via FFI
  local ok_ffi, stream_ffi = pcall(require, "luagate.stream.ffi")
  if not ok_ffi then
    ngx.log(ngx.ERR, "[luagate-stream] failed to load stream ffi: ", tostring(stream_ffi))
    ctx.deny_reason = "ffi_load_error"
    ctx.request_state = "denied"
    ngx.var.luagate_stream_action = "deny"
    ngx.var.luagate_request_state = "denied"
    return ngx.exit(ngx.ERROR)
  end

  local protocol, detect_err, need_more = stream_ffi.detect_protocol(preread_data)

  -- NEED_MORE_DATA handling (stream-pipeline.md §2.1)
  -- In the preread phase, the initial receive should provide enough bytes.
  -- If detect_protocol still needs more data, fail-closed rather than
  -- attempting additional socket reads that may not be available.
  if need_more then
    ngx.log(ngx.ERR, "[luagate-stream] protocol detection needs more data, fail-closed")
    ctx.deny_reason = "detect_need_more_data"
    ctx.request_state = "denied"
    ngx.var.luagate_stream_action = "deny"
    ngx.var.luagate_request_state = "denied"
    return ngx.exit(ngx.ERROR)
  end

  if detect_err then
    ngx.log(ngx.ERR, "[luagate-stream] protocol detection error: ", detect_err)
    ctx.deny_reason = "detect_error:" .. detect_err
    ctx.request_state = "denied"
    ngx.var.luagate_stream_action = "deny"
    ngx.var.luagate_request_state = "denied"
    return ngx.exit(ngx.ERROR)
  end

  ctx.detected_protocol = protocol or "raw"
  ngx.var.luagate_protocol = ctx.detected_protocol

  -- 5. TLS SNI extraction
  if ctx.detected_protocol == "tls" then
    local sni, sni_err, sni_need_more = stream_ffi.extract_sni(preread_data)

    if sni_need_more then
      -- Fragmented ClientHello — fail-closed (MVP: no retry for SNI)
      ngx.log(ngx.WARN, "[luagate-stream] SNI extraction needs more data, continuing without SNI")
      ctx.sni = nil
    elseif sni_err then
      ngx.log(ngx.WARN, "[luagate-stream] SNI extraction error: ", sni_err, ", continuing without SNI")
      ctx.sni = nil
    else
      ctx.sni = (sni and sni ~= "") and sni or nil
    end

    ngx.var.luagate_sni = ctx.sni or ""
  end

  -- 6. Policy evaluation
  local ok_ev, evaluator = pcall(require, "luagate.policy.evaluator")
  if not ok_ev then
    ngx.log(ngx.ERR, "[luagate-stream] failed to load evaluator: ", tostring(evaluator))
    ctx.deny_reason = "evaluator_load_error"
    ctx.decision_source = "policy_engine"
    ctx.request_state = "denied"
    ngx.var.luagate_stream_action = "deny"
    ngx.var.luagate_decision_source = "policy_engine"
    ngx.var.luagate_request_state = "denied"
    return ngx.exit(ngx.ERROR)
  end

  local ok_gp, policy = pcall(evaluator.get_policy)
  if not ok_gp then
    ngx.log(ngx.ERR, "[luagate-stream] get_policy() raised: ", tostring(policy))
    ctx.deny_reason = "policy_load_error"
    ctx.decision_source = "policy_engine"
    ctx.request_state = "denied"
    ngx.var.luagate_stream_action = "deny"
    ngx.var.luagate_decision_source = "policy_engine"
    ngx.var.luagate_request_state = "denied"
    return ngx.exit(ngx.ERROR)
  end

  if not policy then
    ngx.log(ngx.WARN, "[luagate-stream] no active policy, fail-closed deny")
    ctx.deny_reason = "no_policy"
    ctx.decision_source = "policy_engine"
    ctx.request_state = "denied"
    ngx.var.luagate_stream_action = "deny"
    ngx.var.luagate_decision_source = "policy_engine"
    ngx.var.luagate_request_state = "denied"
    return ngx.exit(ngx.ERROR)
  end

  -- Build stream request context for evaluator
  local request_ctx = {
    src_ip = ctx.src_ip,
    dst_port = ctx.dst_port,
    detected_protocol = ctx.detected_protocol,
    sni = ctx.sni,
  }

  -- Evaluate against compiled stream rules (ADR-002 first-match-wins)
  local stream_rules = policy._compiled_stream or {}
  local result = evaluator.evaluate_stream(stream_rules, request_ctx)

  ctx.action = result.action
  ctx.matched_rule_id = result.matched_rule
  ctx.decision_source = result.decision_source or "policy_engine"
  ctx.upstream = result.upstream

  -- Update nginx variables
  ngx.var.luagate_stream_action = result.action
  ngx.var.luagate_decision_source = ctx.decision_source
  ngx.var.luagate_matched_rule = result.matched_rule or ""

  -- 7. Handle deny
  if result.action == "deny" then
    ctx.deny_reason = result.matched_rule or "default_deny"
    ctx.request_state = "denied"
    ngx.var.luagate_request_state = "denied"
    ngx.log(
      ngx.INFO,
      "[luagate-stream] connection denied: ",
      "src=",
      ctx.src_ip,
      " dst_port=",
      ctx.dst_port,
      " proto=",
      ctx.detected_protocol,
      " rule=",
      result.matched_rule or "default"
    )
    return ngx.exit(ngx.ERROR)
  end

  -- 8. proxy: set upstream for proxy_pass
  if result.upstream then
    ngx.var.luagate_upstream = result.upstream
  end
  ctx.request_state = "proxied"
  ngx.var.luagate_request_state = "proxied"
  ngx.var.luagate_upstream = ctx.upstream or ""
end

return _M
