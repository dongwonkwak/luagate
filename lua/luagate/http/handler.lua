--- HTTP pipeline handler for LuaGate.
-- Implements rewrite / access / log_phase entry points called from nginx.conf.
--
-- Invariants (AGENTS.md):
--   - ngx.ctx MUST NOT be used for policy caching (policy-engine.md §4.4).
--   - No blocking I/O (io.open, os.execute prohibited).
--   - Lua access_log direct write prohibited; use Nginx native log_format.
--   - fail-closed: policy load failure or internal error → deny (403).
--   - worker_id via ngx.worker.id() only.
--   - All nginx variable names use luagate_ prefix.
--
-- Pipeline order (http-pipeline.md §2):
--   rewrite_by_lua  → URL normalisation (decoder) + ngx.ctx init + nginx var defaults
--   access_by_lua   → decoder error check → scanner → policy evaluation
--   log_by_lua      → request_state finalise + metrics update
--
-- Implementation: lua/luagate/http/handler.lua
-- Tests: tests/unit/http/handler_spec.lua

local cjson = require("cjson.safe")

local _M = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Return true if the IP is a private/loopback address (RFC 1918 + loopback).
-- Used to gate X-LuaGate-Block-Reason header: internal clients only.
-- Handles IPv6 loopback (::1) and IPv4-mapped IPv6 (::ffff:<ipv4>).
--
-- @param ip  string  e.g. "10.1.2.3", "::1", "::ffff:192.168.1.1"
-- @return boolean
local function is_internal_ip(ip)
  if not ip then
    return false
  end
  -- IPv6 loopback (L-1)
  if ip == "::1" then
    return true
  end
  -- IPv4-mapped IPv6: ::ffff:<ipv4> — extract the IPv4 part and fall through
  local v4 = ip:match("^::ffff:(%d+%.%d+%.%d+%.%d+)$")
  if v4 then
    ip = v4
  elseif ip:find(":", 1, true) then
    -- Pure IPv6 (not ::1, not ::ffff:...) → treat as external
    return false
  end
  -- IPv4 checks (RFC 1918 + loopback)
  -- 127.x.x.x (loopback)
  if ip:match("^127%.") then
    return true
  end
  -- 10.x.x.x
  if ip:match("^10%.") then
    return true
  end
  -- 172.16.x.x – 172.31.x.x
  local b = ip:match("^172%.(%d+)%.")
  if b then
    local n = tonumber(b)
    if n and n >= 16 and n <= 31 then
      return true
    end
  end
  -- 192.168.x.x
  if ip:match("^192%.168%.") then
    return true
  end
  return false
end

--- Build a 403 JSON deny response and exit.
-- Sets ngx.status, Content-Type, X-Request-ID, X-LuaGate-Block-Reason
-- (internal IPs only), Cache-Control headers, writes body, and calls ngx.exit(403).
--
-- H-1 (OWASP A05): rule id (deny_reason) is only exposed to internal clients.
-- External clients receive the generic "policy_deny" token in the JSON body.
--
-- @param deny_reason  string   Short reason token (policy rule id or "no_policy")
-- @param request_id   string   Request UUID from ngx.ctx or nginx var
local function do_deny(deny_reason, request_id)
  local reason = deny_reason or "policy_deny"
  local rid = request_id or ""
  local client_ip = ngx.var.luagate_src_ip or ngx.var.remote_addr or ""

  -- H-1: external clients receive a generic reason token only (OWASP A05)
  local external_reason = is_internal_ip(client_ip) and reason or "policy_deny"

  -- JSON 인젝션 방지: cjson.encode로 안전하게 직렬화 (http-pipeline.md §6)
  local ok, body = pcall(cjson.encode, {
    error = "Forbidden",
    request_id = rid,
    reason = external_reason,
  })
  if not ok then
    body = '{"error":"Forbidden"}'
  end

  ngx.status = 403
  ngx.header["Content-Type"] = "application/json"
  ngx.header["X-Request-ID"] = rid
  -- X-LuaGate-Block-Reason: 내부망 클라이언트에만 전송 (외부 노출 금지)
  if is_internal_ip(client_ip) then
    ngx.header["X-LuaGate-Block-Reason"] = reason
  end
  ngx.header["Cache-Control"] = "no-store"

  ngx.say(body)
  ngx.exit(403)
end

-- ---------------------------------------------------------------------------
-- rewrite_by_lua entry point
-- ---------------------------------------------------------------------------

--- Phase 1: URL normalisation + ngx.ctx initialisation.
-- Called from rewrite_by_lua_block in nginx.conf.
--
-- Responsibilities (http-pipeline.md §2.2 + §9):
--   1. Pre-assign nginx variable defaults (http-pipeline.md §3).
--   2. Compute path_raw (query-stripped request_uri).
--   3. URL normalization via decoder FFI (path + query).
--      Errors stored in ctx.decoder_error for access phase fail-closed.
--   4. Snapshot active_version from shared dict at request start.
--   5. Determine src_ip (MVP: remote_addr only; full logic in future issue).
--   6. Record start_time_ms.
--   7. Initialise ngx.ctx.luagate with request metadata.
function _M.rewrite()
  -- 1. Nginx variable defaults (http-pipeline.md §3, log-schema.md §2)
  --    These ensure all 27 log fields are populated even on nginx_core
  --    early short-circuit (400/413/414).
  ngx.var.luagate_decision_source = "nginx_core"
  ngx.var.luagate_action = "allow"
  ngx.var.luagate_matched_rule = "null"
  ngx.var.luagate_threat_type = "null"
  ngx.var.luagate_rule_name = "null"
  ngx.var.luagate_request_state = "short_circuited"
  ngx.var.luagate_deny_reason = "null"
  ngx.var.luagate_threat_score = "null"
  -- worker_id: always ngx.worker.id() (AGENTS.md invariant)
  ngx.var.luagate_worker_id = tostring(ngx.worker.id())

  -- 2. path_raw: query string excluded (log-schema.md §3.1)
  local request_uri = ngx.var.request_uri or ngx.var.uri
  local path_raw = request_uri:match("^([^?]*)") or ngx.var.uri
  ngx.var.luagate_path_raw = path_raw

  -- 3. query_string: raw args (redaction applied in log/http.lua finalize)
  local query_raw = ngx.var.args or ""
  ngx.var.luagate_query_string = query_raw

  -- 4. URL normalization (http-pipeline.md §2.2: rewrite에서만 수행)
  --    Decoder errors are stored in ctx.decoder_error for access phase fail-closed.
  local path_normalized = path_raw
  local query_normalized = query_raw
  local decoder_error = nil
  local decoder_ffi_timeout = false

  local ok_dec, decoder = pcall(require, "luagate.decoder.ffi")
  if ok_dec then
    -- pcall wrapping: catch Lua-level FFI exceptions (ADR-001 §1.2 fail-closed)
    local ok_np, pn, perr, pp = pcall(decoder.normalize_path, path_raw)
    if not ok_np then
      ngx.log(ngx.ERR, "[luagate] decoder path exception: ", tostring(pn))
      decoder_error = "decoder_path_exception"
    elseif perr then
      ngx.log(ngx.ERR, "[luagate] decoder path error: ", perr)
      decoder_ffi_timeout = decoder_ffi_timeout or (perr == "ffi_timeout")
      decoder_error = perr
    else
      path_normalized = pn or path_raw
      if pp then
        ngx.log(ngx.WARN, "[luagate] decoder: path partial decode")
      end
    end

    local ok_nq, qn, qerr, qp = pcall(decoder.normalize_query, query_raw)
    if not ok_nq then
      ngx.log(ngx.ERR, "[luagate] decoder query exception: ", tostring(qn))
      decoder_error = decoder_error or "decoder_query_exception"
    elseif qerr then
      ngx.log(ngx.ERR, "[luagate] decoder query error: ", qerr)
      decoder_ffi_timeout = decoder_ffi_timeout or (qerr == "ffi_timeout")
      decoder_error = decoder_error or qerr
    else
      query_normalized = qn or query_raw
      if qp then
        ngx.log(ngx.WARN, "[luagate] decoder: query partial decode")
      end
    end
  else
    ngx.log(ngx.ERR, "[luagate] failed to load decoder: ", tostring(decoder))
    decoder_error = "decoder_load_error"
  end
  ngx.var.luagate_path_normalized = path_normalized

  -- 5. src_ip: MVP uses remote_addr directly.
  --    Full PROXY Protocol / XFF trusted-proxy logic is a future issue.
  ngx.var.luagate_src_ip = ngx.var.remote_addr

  -- 6. active_version snapshot at request start (http-pipeline.md §2.5)
  --    log_by_lua MUST use this snapshot, not re-read from shared dict.
  local dict = ngx.shared.luagate_policy
  local ver = (dict and dict:get("http:active_version")) or "none"
  ngx.var.luagate_active_version = ver

  -- 7. Initialise per-request context (http-pipeline.md §9)
  --    IMPORTANT: policy cache MUST NOT be stored in ngx.ctx (AGENTS.md).
  ngx.ctx.luagate = {
    request_id = ngx.var.luagate_request_id,
    path_raw = path_raw,
    path_normalized = path_normalized,
    query_raw = query_raw,
    query_normalized = query_normalized,
    action = "allow",
    decision_source = "nginx_core",
    active_version = ver,
    start_time_ms = ngx.now() * 1000,
    -- decoder error flag: non-nil triggers fail-closed in access phase
    decoder_error = decoder_error,
    decoder_ffi_timeout = decoder_ffi_timeout,
  }

  -- 8. Tracing: init trace context + root span (ADR-010 §2)
  local ok_tracing, tracing = pcall(require, "luagate.tracing.init")
  if ok_tracing and tracing.is_enabled() then
    local trace_ctx = tracing.start_request_trace()
    if trace_ctx then
      ngx.ctx.luagate.trace = trace_ctx
      -- Set nginx vars for log fields (always, regardless of sampling)
      ngx.var.luagate_trace_id = trace_ctx.trace_id
      ngx.var.luagate_span_id = trace_ctx.root_span.span_id
    end
  end
end

-- ---------------------------------------------------------------------------
-- access_by_lua entry point
-- ---------------------------------------------------------------------------

--- Phase 2: Policy evaluation.
-- Called from access_by_lua_block in nginx.conf.
--
-- Processing order (http-pipeline.md §2.3):
--   1. Admin plane guard (server_port 9090 → skip — handled by separate block).
--   2. get_policy() from evaluator (L1 cache + L2 reload).
--   3. Decoder error check (set in rewrite phase) → fail-closed.
--   4. Input size limit check (8KB) → fail-closed.
--   5. Scanner scan → fail-closed on error, deny on threat.
--   6. Build request_ctx from ngx.ctx and nginx vars.
--   7. evaluate() with compiled HTTP rules and global default_action.
--   8. Update ngx.ctx + nginx vars with result.
--   9. deny action → send 403 response + ngx.exit(403).
--  10. allow → set request_state = "completed" for log phase.
--
-- fail-closed invariant: any error path returns deny (403).
function _M.access()
  -- Admin plane guard: the admin server block (127.0.0.1:9090) runs its own
  -- content_by_lua; the data-plane access_by_lua should not evaluate policies
  -- for admin traffic. Defensive check in case of misconfiguration.
  local port = tonumber(ngx.var.server_port)
  if port == 9090 then
    return
  end

  local ctx = ngx.ctx.luagate
  if not ctx then
    -- rewrite phase did not run (should not happen in normal flow)
    -- fail-closed: update nginx vars before deny so log records accurate state
    ngx.var.luagate_action = "deny"
    ngx.var.luagate_decision_source = "policy_engine"
    ngx.var.luagate_request_state = "policy_denied"
    do_deny("no_context", ngx.var.luagate_request_id or "")
    return
  end

  -- 1. Load policy (worker-level L1 cache; no ngx.ctx storage)
  local ok_ev, evaluator = pcall(require, "luagate.policy.evaluator")
  if not ok_ev then
    ngx.log(ngx.ERR, "[luagate] failed to load evaluator: ", tostring(evaluator))
    ctx.action = "deny"
    ctx.request_state = "policy_denied"
    ctx.decision_source = "policy_engine"
    ctx.deny_reason = "evaluator_load_error"
    ngx.var.luagate_action = "deny"
    ngx.var.luagate_decision_source = "policy_engine"
    ngx.var.luagate_request_state = "policy_denied"
    ngx.var.luagate_deny_reason = "evaluator_load_error"
    do_deny("evaluator_load_error", ctx.request_id or "")
    return
  end

  -- M-1: wrap get_policy() in pcall to prevent unhandled exceptions from
  -- bypassing fail-closed logic and causing nginx to return 500.
  local ok_gp, policy = pcall(evaluator.get_policy)
  if not ok_gp then
    ngx.log(ngx.ERR, "[luagate] get_policy() raised: ", tostring(policy))
    ctx.action = "deny"
    ctx.request_state = "policy_denied"
    ctx.decision_source = "policy_engine"
    ctx.deny_reason = "policy_load_error"
    ngx.var.luagate_action = "deny"
    ngx.var.luagate_decision_source = "policy_engine"
    ngx.var.luagate_request_state = "policy_denied"
    ngx.var.luagate_deny_reason = "policy_load_error"
    do_deny("policy_load_error", ctx.request_id or "")
    return
  end
  if not policy then
    -- fail-closed: no active policy → deny all (http-pipeline.md §10)
    ngx.log(ngx.WARN, "[luagate] no active policy, fail-closed deny")
    ctx.action = "deny"
    ctx.request_state = "policy_denied"
    ctx.decision_source = "policy_engine"
    ctx.deny_reason = "no_policy"
    ngx.var.luagate_action = "deny"
    ngx.var.luagate_decision_source = "policy_engine"
    ngx.var.luagate_request_state = "policy_denied"
    ngx.var.luagate_deny_reason = "no_policy"
    do_deny("no_policy", ctx.request_id or "")
    return
  end

  -- 2. Decoder error check + Scanner integration (http-pipeline.md §2.3)
  --    Decoder runs in rewrite phase; access checks ctx.decoder_error for fail-closed.
  --    Order: decoder error check → size check → scanner scan → policy evaluation

  local path_raw = ctx.path_raw or ""
  local query_raw = ctx.query_raw or ""

  -- 2a. Decoder error check (set in rewrite phase; http-pipeline.md §5 threat_type enum)
  --     NOTE: ctx.threat_type is NOT set for operational failures — only ngx.var
  --     is set for log distinguishability. ctx.threat_type drives the scanner
  --     threat metric (ADR-006) and must only reflect actual threat detections.
  if ctx.decoder_error then
    ngx.log(ngx.ERR, "[luagate] decoder error from rewrite: ", ctx.decoder_error)
    ctx.action = "deny"
    ctx.request_state = "scanner_denied"
    ctx.decision_source = "security_scanner"
    ctx.deny_reason = ctx.decoder_error
    -- ADR-009: propagate ffi_timeout flag for decoder Layer 2 timeout
    ctx.ffi_timeout = ctx.decoder_ffi_timeout or (ctx.decoder_error == "ffi_timeout")
    local log_threat_type = ctx.ffi_timeout and "ffi_timeout" or "decode_error"
    ngx.var.luagate_action = "deny"
    ngx.var.luagate_decision_source = "security_scanner"
    ngx.var.luagate_request_state = "scanner_denied"
    ngx.var.luagate_deny_reason = ctx.decoder_error
    ngx.var.luagate_threat_type = log_threat_type
    do_deny(ctx.decoder_error, ctx.request_id or "")
    return
  end

  -- 2b. Size limit check: 8KB per input (security-scanner.md §2)
  local INPUT_SIZE_LIMIT = 8192
  if #path_raw > INPUT_SIZE_LIMIT or #query_raw > INPUT_SIZE_LIMIT then
    ngx.log(ngx.ERR, "[luagate] input size exceeded: path=", #path_raw, " query=", #query_raw)
    ctx.action = "deny"
    ctx.request_state = "scanner_denied"
    ctx.decision_source = "security_scanner"
    ctx.deny_reason = "input_size_exceeded"
    ngx.var.luagate_action = "deny"
    ngx.var.luagate_decision_source = "security_scanner"
    ngx.var.luagate_request_state = "scanner_denied"
    ngx.var.luagate_deny_reason = "input_size_exceeded"
    ngx.var.luagate_threat_type = "scanner_error"
    do_deny("input_size_exceeded", ctx.request_id or "")
    return
  end

  -- 2c. Scanner scan (security-scanner.md §2)
  --     pcall wrapping: catch Lua-level exceptions from scanner FFI (ADR-001 §1.2)
  local ok_sc, scanner = pcall(require, "luagate.scanner.ffi")
  if not ok_sc then
    ngx.log(ngx.ERR, "[luagate] failed to load scanner: ", tostring(scanner))
    ctx.action = "deny"
    ctx.request_state = "scanner_denied"
    ctx.decision_source = "security_scanner"
    ctx.deny_reason = "scanner_load_error"
    ngx.var.luagate_action = "deny"
    ngx.var.luagate_decision_source = "security_scanner"
    ngx.var.luagate_request_state = "scanner_denied"
    ngx.var.luagate_deny_reason = "scanner_load_error"
    ngx.var.luagate_threat_type = "scanner_error"
    do_deny("scanner_load_error", ctx.request_id or "")
    return
  end

  local ok_scan, scan_result, scan_err = pcall(scanner.scan, {
    path_raw = path_raw,
    path_normalized = ctx.path_normalized,
    query_raw = query_raw,
    query_normalized = ctx.query_normalized,
  })

  if not ok_scan then
    -- pcall caught a Lua-level exception from scanner.scan()
    ngx.log(ngx.ERR, "[luagate] scanner exception: ", tostring(scan_result))
    scan_err = "scanner_exception:" .. tostring(scan_result)
    scan_result = nil
  end

  if scan_err then
    -- ADR-009: ffi_timeout is an operational timeout, not a threat detection.
    -- Use distinct deny_reason and threat_type so it does not pollute scanner
    -- threat metrics (ADR-006). Log ffi_timeout field for observability.
    local deny_reason = "scanner_internal_error"
    local log_threat_type = "scanner_error"
    if scan_err == "ffi_timeout" then
      deny_reason = "ffi_timeout"
      log_threat_type = "ffi_timeout"
    elseif scan_err:find("%-3") then
      deny_reason = "budget_exceeded"
    end
    ngx.log(ngx.ERR, "[luagate] scanner error: ", scan_err)
    ctx.action = "deny"
    ctx.request_state = "scanner_denied"
    ctx.decision_source = "security_scanner"
    ctx.deny_reason = deny_reason
    ctx.ffi_timeout = (scan_err == "ffi_timeout")
    ngx.var.luagate_action = "deny"
    ngx.var.luagate_decision_source = "security_scanner"
    ngx.var.luagate_request_state = "scanner_denied"
    ngx.var.luagate_deny_reason = deny_reason
    ngx.var.luagate_threat_type = log_threat_type
    do_deny(deny_reason, ctx.request_id or "")
    return
  end

  if scan_result and scan_result.threat_type then
    -- Threat detected → deny, skip policy evaluation
    ctx.action = "deny"
    ctx.threat_type = scan_result.threat_type
    ctx.rule_name = scan_result.rule_name
    ctx.threat_score = scan_result.threat_score
    ctx.decision_source = "security_scanner"
    ctx.deny_reason = "scanner: " .. scan_result.threat_type
    ctx.request_state = "scanner_denied"
    ngx.var.luagate_action = "deny"
    ngx.var.luagate_decision_source = "security_scanner"
    ngx.var.luagate_threat_type = scan_result.threat_type
    ngx.var.luagate_rule_name = scan_result.rule_name or "null"
    ngx.var.luagate_threat_score = tostring(scan_result.threat_score)
    ngx.var.luagate_deny_reason = "scanner: " .. scan_result.threat_type
    ngx.var.luagate_request_state = "scanner_denied"
    do_deny("scanner: " .. scan_result.threat_type, ctx.request_id or "")
    return
  end

  -- No threat: record informational threat_score if present
  if scan_result and scan_result.threat_score and scan_result.threat_score > 0 then
    ctx.threat_score = scan_result.threat_score
    ngx.var.luagate_threat_score = tostring(scan_result.threat_score)
  end

  -- 3. Build request context for policy evaluation (http-pipeline.md §2.3)
  --    path_normalized and query_normalized set in rewrite phase.
  local request_ctx = {
    path = ctx.path_normalized,
    host = ngx.var.host,
    method = ngx.var.request_method,
    src_ip = ngx.var.luagate_src_ip or ngx.var.remote_addr,
    query_param = ngx.req.get_uri_args(),
    header = ngx.req.get_headers(),
  }

  -- 4. Determine default action from policy global config
  local default_action = (policy.global and policy.global.default_action) or "deny"

  -- 5. Evaluate against compiled HTTP rules (ADR-002 §3.1 first-match-wins)
  local result = evaluator.evaluate(policy._compiled_http or {}, request_ctx, default_action)

  -- 6. Update ngx.ctx with evaluation result
  ctx.action = result.action
  ctx.matched_rule_id = result.matched_rule
  ctx.decision_source = "policy_engine"

  -- 7. Propagate to nginx variables (used by log_format)
  ngx.var.luagate_action = result.action
  ngx.var.luagate_decision_source = "policy_engine"
  ngx.var.luagate_matched_rule = result.matched_rule or "null"

  -- 8. Handle deny
  if result.action == "deny" then
    local deny_reason = result.matched_rule or "default_deny"
    ctx.deny_reason = deny_reason
    ctx.request_state = "policy_denied"
    ngx.var.luagate_deny_reason = deny_reason
    ngx.var.luagate_request_state = "policy_denied"
    do_deny(deny_reason, ctx.request_id or "")
    return
  end

  -- 9. Allow: mark as completed; log phase will finalise request_state
  ctx.request_state = "completed"

  -- 10. Tracing: create proxy child span + inject outbound traceparent (ADR-010 §2, §7)
  local trace_ctx = ctx.trace
  if trace_ctx then
    local ok_tracing, tracing = pcall(require, "luagate.tracing.init")
    if ok_tracing then
      local proxy_span = tracing.start_child_span(trace_ctx, "proxy", "SPAN_KIND_CLIENT")
      if proxy_span then
        ctx.proxy_span = proxy_span
        ctx.proxy_start_ts = ngx.now()
        tracing.inject_outbound(trace_ctx, proxy_span)
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- log_by_lua entry point
-- ---------------------------------------------------------------------------

--- Phase 3: Post-response log finalisation + metrics update.
-- Called from log_by_lua_block in nginx.conf.
-- This phase runs AFTER the upstream response is sent to the client.
-- Errors here MUST NOT affect the client response.
--
-- Responsibilities:
--   1. Finalise $luagate_request_state based on upstream response.
--   2. Build 27-field JSON log record via log/http.lua.
--   3. Update luagate_metrics shared dict counters via metrics/collector.lua.
function _M.log_phase()
  local ctx = ngx.ctx.luagate

  -- 1. Finalise request_state (log-schema.md §3.3)
  --    The value set in access phase may be overridden here based on
  --    actual upstream response status.
  if ctx then
    local state = ctx.request_state or "short_circuited"

    -- If allow decision but upstream returned 5xx, mark as upstream_error
    if state == "completed" then
      local status = tonumber(ngx.var.status) or 0
      if status >= 500 then
        state = "upstream_error"
      else
        state = "allowed"
      end
    end

    ngx.var.luagate_request_state = state
    ctx.request_state = state
  end

  -- 2. Build and set $luagate_log_json (27-field NDJSON record)
  --    log/http.lua calls cjson.encode and assigns ngx.var.luagate_log_json.
  --    Errors are non-fatal: Nginx will fall back to empty log line.
  local ok_log, log_mod = pcall(require, "luagate.log.http")
  if ok_log then
    local ok_fin, fin_err = pcall(log_mod.finalize)
    if not ok_fin then
      ngx.log(ngx.ERR, "[luagate] log finalize error: ", tostring(fin_err))
    end
  else
    ngx.log(ngx.ERR, "[luagate] failed to load log.http: ", tostring(log_mod))
  end

  -- 3. Update metrics counters (errors are non-fatal per ADR-001 §1.2)
  local ok_col, collector = pcall(require, "luagate.metrics.collector")
  if ok_col then
    local ok_rec, rec_err = pcall(collector.record, ctx)
    if not ok_rec then
      ngx.log(ngx.ERR, "[luagate] metrics record error: ", tostring(rec_err))
    end
  else
    ngx.log(ngx.ERR, "[luagate] failed to load metrics.collector: ", tostring(collector))
  end

  -- 4. Tracing: finish proxy span + root span, add to buffer (ADR-010 §2, §4)
  if ctx then
    local trace_ctx = ctx.trace
    if trace_ctx then
      local ok_tracing, tracing = pcall(require, "luagate.tracing.init")
      if ok_tracing then
        -- Finish proxy child span with upstream_response_time
        local proxy_span = ctx.proxy_span
        if proxy_span then
          local upstream_rt = ngx.var.upstream_response_time
          if upstream_rt and upstream_rt ~= "" and upstream_rt ~= "-" then
            -- ADR-010 §2: handle comma-separated retry values
            local total = 0
            for val in upstream_rt:gmatch("[^,%s]+") do
              total = total + (tonumber(val) or 0)
            end
            local span_mod = require("luagate.tracing.span")
            span_mod.set_attribute(proxy_span, "luagate.upstream_response_time", upstream_rt)
            local proxy_end_ns = (ctx.proxy_start_ts + total) * 1e9
            span_mod.finish(proxy_span, proxy_end_ns)

            -- Response status on proxy span
            local proxy_status = tonumber(ngx.var.status) or 0
            span_mod.set_attribute(proxy_span, "http.response.status_code", proxy_status)
            if proxy_status >= 500 then
              span_mod.set_error(proxy_span, tostring(proxy_status))
            end
          else
            -- No upstream response (connect failure)
            local span_mod = require("luagate.tracing.span")
            span_mod.finish(proxy_span)
            span_mod.set_error(proxy_span, "upstream_connect_failure")
          end
        end

        -- Finish the entire request trace
        tracing.finish_request_trace(trace_ctx)
      end
    end
  end
end

return _M
