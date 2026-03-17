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
--   rewrite_by_lua  → URL normalisation + ngx.ctx init + nginx var defaults
--   access_by_lua   → policy evaluation + optional scanner (MVP stub)
--   log_by_lua      → request_state finalise + metrics update
--
-- Implementation: lua/luagate/http/handler.lua
-- Tests: tests/unit/http/handler_spec.lua

local _M = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Build a 403 JSON deny response and exit.
-- Sets ngx.status, Content-Type, X-Request-ID, X-LuaGate-Block-Reason,
-- Cache-Control headers, writes body, and calls ngx.exit(403).
--
-- @param deny_reason  string   Short reason token (policy rule id or "no_policy")
-- @param request_id   string   Request UUID from ngx.ctx or nginx var
local function do_deny(deny_reason, request_id)
  local reason = deny_reason or "policy_deny"
  local rid = request_id or ""

  ngx.status = 403
  ngx.header["Content-Type"] = "application/json"
  ngx.header["X-Request-ID"] = rid
  -- X-LuaGate-Block-Reason: internal network response header (DON-140 AC)
  ngx.header["X-LuaGate-Block-Reason"] = reason
  ngx.header["Cache-Control"] = "no-store"

  -- http-pipeline.md §6: JSON error body
  ngx.say('{"error":"Forbidden","request_id":"' .. rid .. '","reason":"' .. reason .. '"}')
  ngx.exit(403)
end

-- ---------------------------------------------------------------------------
-- rewrite_by_lua entry point
-- ---------------------------------------------------------------------------

--- Phase 1: URL normalisation + ngx.ctx initialisation.
-- Called from rewrite_by_lua_block in nginx.conf.
--
-- Responsibilities (http-pipeline.md §2.2 + §9):
--   1. Initialise ngx.ctx.luagate with request metadata.
--   2. Pre-assign nginx variable defaults (http-pipeline.md §3).
--   3. Compute path_raw (query-stripped request_uri).
--   4. path_normalized: decoder FFI is a future issue; use path_raw as stub.
--   5. Snapshot active_version from shared dict at request start.
--   6. Determine src_ip (MVP: remote_addr only; full logic in future issue).
--   7. Record start_time_ms.
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

  -- 3. path_normalized stub (decoder FFI is a future issue — DON-98+)
  --    decoder stub: full normalization in future FFI issue
  local path_normalized = path_raw
  ngx.var.luagate_path_normalized = path_normalized

  -- 4. query_string: raw args (redaction applied in log/http.lua finalize)
  local query_raw = ngx.var.args or ""
  ngx.var.luagate_query_string = query_raw

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
    -- decoder stub: full normalization in future FFI issue
    path_normalized = path_normalized,
    query_raw = query_raw,
    query_normalized = query_raw, -- stub: same as raw until decoder FFI
    action = "allow",
    decision_source = "nginx_core",
    active_version = ver,
    start_time_ms = ngx.now() * 1000,
  }
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
--   3. Build request_ctx from ngx.ctx and nginx vars.
--   4. evaluate() with compiled HTTP rules and global default_action.
--   5. Update ngx.ctx + nginx vars with result.
--   6. deny action → send 403 response + ngx.exit(403).
--   7. allow → set request_state = "completed" for log phase.
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
    -- fail-closed
    do_deny("no_context", ngx.var.luagate_request_id or "")
    return
  end

  -- 1. Load policy (worker-level L1 cache; no ngx.ctx storage)
  local ok_ev, evaluator = pcall(require, "luagate.policy.evaluator")
  if not ok_ev then
    ngx.log(ngx.ERR, "[luagate] failed to load evaluator: ", tostring(evaluator))
    ctx.decision_source = "policy_engine"
    ctx.deny_reason = "evaluator_load_error"
    ngx.var.luagate_decision_source = "policy_engine"
    ngx.var.luagate_deny_reason = "evaluator_load_error"
    do_deny("evaluator_load_error", ctx.request_id or "")
    return
  end

  local policy = evaluator.get_policy()
  if not policy then
    -- fail-closed: no active policy → deny all (http-pipeline.md §10)
    ngx.log(ngx.WARN, "[luagate] no active policy, fail-closed deny")
    ctx.decision_source = "policy_engine"
    ctx.deny_reason = "no_policy"
    ngx.var.luagate_decision_source = "policy_engine"
    ngx.var.luagate_deny_reason = "no_policy"
    do_deny("no_policy", ctx.request_id or "")
    return
  end

  -- 2. Build request context for policy evaluation (http-pipeline.md §2.3)
  --    path_normalized from rewrite phase only; no re-normalisation here
  --    (http-pipeline.md §2.2 invariant).
  local request_ctx = {
    path = ctx.path_normalized,
    host = ngx.var.host,
    method = ngx.var.request_method,
    src_ip = ngx.var.remote_addr,
    query_param = ngx.req.get_uri_args(),
    header = ngx.req.get_headers(),
  }

  -- 3. Determine default action from policy global config
  local default_action = (policy.global and policy.global.default_action) or "deny"

  -- 4. Evaluate against compiled HTTP rules (ADR-002 §3.1 first-match-wins)
  local result = evaluator.evaluate(policy._compiled_http or {}, request_ctx, default_action)

  -- 5. Update ngx.ctx with evaluation result
  ctx.action = result.action
  ctx.matched_rule_id = result.matched_rule
  ctx.decision_source = "policy_engine"

  -- 6. Propagate to nginx variables (used by log_format)
  ngx.var.luagate_action = result.action
  ngx.var.luagate_decision_source = "policy_engine"
  ngx.var.luagate_matched_rule = result.matched_rule or "null"

  -- 7. Scanner stub: MVP — scanner FFI not yet integrated (future issue)
  --    threat_type, rule_name, threat_score remain at default "null".
  --    When scanner is integrated, it will set these vars and ctx fields.

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
end

return _M
