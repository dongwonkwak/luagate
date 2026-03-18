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
local _radix_tree = nil -- CIDR radix tree (FFI opaque pointer)
local _radix_version = nil -- active_version at which _radix_tree was built

-- Bytes to read on each peek attempt
local PEEK_BYTES = 1024

-- Maximum retry attempts for NEED_MORE_DATA from detect_protocol
local MAX_DETECT_RETRIES = 3

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
  -- In stream preread_by_lua, data read via ngx.req.socket(true) is automatically
  -- preserved in the Nginx stream preread buffer. proxy_pass forwards this data
  -- to upstream — the read does NOT consume data from the client stream.
  local ok_sock, sock = pcall(ngx.req.socket, true)
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

  -- NEED_MORE_DATA retry loop (stream-pipeline.md §2.1, c-ffi-modules.md §2):
  -- If detect_protocol returns NEED_MORE_DATA, read more bytes from the socket
  -- and retry up to MAX_DETECT_RETRIES times (within preread_timeout).
  local protocol, detect_err, need_more = stream_ffi.detect_protocol(preread_data)
  local retry_count = 0

  while need_more and retry_count < MAX_DETECT_RETRIES do
    retry_count = retry_count + 1
    local ok_more, more_data, more_err = pcall(sock.receive, sock, PEEK_BYTES)
    if ok_more and more_data then
      preread_data = preread_data .. more_data
    elseif ok_more and more_err == "timeout" then
      if more_data then
        preread_data = preread_data .. more_data
      end
      -- timeout with no new data -> break and fail-closed below
      if not more_data or #more_data == 0 then
        break
      end
    else
      -- I/O error during retry -> break and fail-closed below
      break
    end
    protocol, detect_err, need_more = stream_ffi.detect_protocol(preread_data)
  end

  if need_more then
    ngx.log(ngx.ERR, "[luagate-stream] protocol detection needs more data after ", retry_count, " retries, fail-closed")
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
  -- Failure taxonomy (stream-pipeline.md §9.1):
  --   INVALID_INPUT = malformed TLS -> fail-closed (not raw fallback)
  --   NEED_MORE_DATA = fragmented ClientHello -> fail-closed (timeout assumed)
  --   empty SNI (no SNI extension) = valid TLS without SNI -> continue normally
  if ctx.detected_protocol == "tls" then
    local sni, sni_err, sni_need_more = stream_ffi.extract_sni(preread_data)

    if sni_need_more then
      -- Fragmented ClientHello — fail-closed (stream-pipeline.md §9.1)
      ngx.log(ngx.ERR, "[luagate-stream] SNI extraction needs more data (fragmented ClientHello), fail-closed")
      ctx.deny_reason = "sni_need_more_data"
      ctx.request_state = "denied"
      ngx.var.luagate_stream_action = "deny"
      ngx.var.luagate_request_state = "denied"
      return ngx.exit(ngx.ERROR)
    elseif sni_err then
      -- malformed TLS -> fail-closed (not raw fallback)
      ngx.log(ngx.ERR, "[luagate-stream] SNI extraction error (malformed TLS): ", sni_err, ", fail-closed")
      ctx.deny_reason = "malformed_tls:" .. sni_err
      ctx.request_state = "denied"
      ngx.var.luagate_stream_action = "deny"
      ngx.var.luagate_request_state = "denied"
      return ngx.exit(ngx.ERROR)
    else
      -- Valid TLS: SNI may be empty (no SNI extension) or a hostname
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

  -- Radix tree rebuild on version change (c-ffi-modules.md §6.4)
  -- Each worker independently rebuilds when active_version changes.
  local stream_rules = policy._compiled_stream or {}
  if stream_ver ~= _radix_version then
    -- Build CIDR list from stream_rules that have src_ip_cidr scope
    local cidr_lines = {}
    for i, rule in ipairs(policy.stream_rules or {}) do
      if rule.scope and rule.scope.src_ip_cidr then
        cidr_lines[#cidr_lines + 1] = rule.scope.src_ip_cidr .. "," .. i
      end
    end

    local old_tree = _radix_tree

    if #cidr_lines > 0 then
      local cidr_str = table.concat(cidr_lines, "\n") .. "\n"
      local new_tree, build_err = stream_ffi.radix_build(cidr_str)
      if new_tree then
        _radix_tree = new_tree
      else
        ngx.log(ngx.WARN, "[luagate-stream] radix_build failed: ", tostring(build_err), ", clearing radix tree")
        _radix_tree = nil
      end
    else
      _radix_tree = nil
    end

    -- Free old tree after swap (FFI free obligation)
    if old_tree then
      stream_ffi.radix_free(old_tree)
    end

    _radix_version = stream_ver
  end

  -- Radix lookup: pre-filter by src_ip if tree is available
  local radix_match_index = nil
  if _radix_tree then
    local idx, lookup_err = stream_ffi.radix_lookup(_radix_tree, ctx.src_ip)
    if lookup_err then
      ngx.log(ngx.WARN, "[luagate-stream] radix_lookup error: ", lookup_err)
    else
      radix_match_index = idx -- nil if no match, number if matched
    end
  end

  -- Build stream request context for evaluator
  local request_ctx = {
    src_ip = ctx.src_ip,
    dst_port = ctx.dst_port,
    detected_protocol = ctx.detected_protocol,
    sni = ctx.sni,
    radix_match_index = radix_match_index,
  }

  -- Evaluate against compiled stream rules (ADR-002 first-match-wins)
  local result = evaluator.evaluate_stream(stream_rules, request_ctx)

  ctx.action = result.action
  ctx.matched_rule_id = result.matched_rule
  ctx.upstream = result.upstream

  -- Map evaluator decision_source to spec-compliant values (stream-pipeline.md §4).
  -- Spec allows only "policy_engine" | "nginx_core".
  -- evaluator may return "rule", "default", or "error" — all are policy_engine decisions.
  local raw_source = result.decision_source or "policy_engine"
  if raw_source == "rule" or raw_source == "default" or raw_source == "error" then
    ctx.decision_source = "policy_engine"
  else
    ctx.decision_source = raw_source
  end

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
