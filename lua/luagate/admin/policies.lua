--- Admin API policy management handlers for LuaGate.
-- Implements GET/PUT /api/v1/policies, GET /api/v1/policies/version,
-- POST /api/v1/policies/reload per admin-api.md §6.3–6.6.
--
-- Design rules:
--   - No blocking I/O except in PUT (canonical file write) and POST reload
--     (delegated to loader.load_policy which uses io.open).
--   - ngx.ctx MUST NOT store policy cache.
--   - cjson.safe for all JSON encoding (pcall-safe).
--   - Error responses follow admin-api.md §3 shape.
--   - Audit log: all mutations log success/failure via [luagate:audit] prefix.
--     Audit write failure => reject mutation/reload (admin-api.md §3/§7).
--   - fail-closed: any error aborts and returns error response.
--   - PUT canonical file write only when BOTH subsystem swaps succeed (ADR-005 §1).
--   - Worker-unique temp file paths to prevent TOCTOU race (Codex review #1).
--   - conflict_detected → 422 per admin-api.md §3 (Codex review #2).
--
-- Implementation: lua/luagate/admin/policies.lua
-- Tests: tests/unit/admin/policies_spec.lua

local cjson = require("cjson.safe")
local loader = require("luagate.policy.loader")
local parser = require("luagate.policy.parser")
local validator = require("luagate.policy.validator")
local conflict = require("luagate.policy.conflict")

local _M = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local POLICY_FILE = "conf/policies.yaml"
local MAX_BODY_SIZE = 1048576 -- 1MB

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Send a JSON error response (admin-api.md §3).
-- @param status  number  HTTP status code
-- @param code    string  Error code
-- @param stage   string  Pipeline stage
-- @param message string  Detail message
local function send_error(status, code, stage, message)
  ngx.status = status
  ngx.header["Content-Type"] = "application/json"
  local body = cjson.encode({
    error = code,
    stage = stage,
    details = { message },
  })
  ngx.say(body or '{"error":"encode_failed","stage":"internal","details":["JSON encode error"]}')
  ngx.exit(status)
end

--- Send a JSON success response.
-- @param status number  HTTP status code
-- @param data   table   Response body table
local function send_json(status, data)
  ngx.status = status
  ngx.header["Content-Type"] = "application/json"
  local body = cjson.encode(data)
  ngx.say(body or '{"error":"encode_failed"}')
  ngx.exit(status)
end

--- Compute SHA256 hex of a string using resty.sha256.
-- @param s string
-- @return string|nil  64-char lowercase hex
-- @return string|nil  error
local function sha256_hex(s)
  local sha256_mod = require("resty.sha256")
  local str_mod = require("resty.string")

  local sha = sha256_mod:new()
  if not sha then
    return nil, "failed to create resty.sha256 instance"
  end
  sha:update(s)
  local digest = sha:final()
  if not digest then
    return nil, "resty.sha256:final() returned nil"
  end
  return str_mod.to_hex(digest), nil
end

--- Write structured audit log entry.
-- Uses [luagate:audit] prefix for log routing (ADR-004 §6.3).
-- @param event  string  Event name (e.g. "policy_update_success")
-- @param fields table   Additional fields to include
-- @return boolean  true if audit write succeeded
local function audit_log(event, fields)
  fields = fields or {}
  fields.timestamp = ngx.utctime()
  fields.event = event
  fields.actor_ip = ngx.var.remote_addr or "unknown"

  local json = cjson.encode(fields)
  if not json then
    return false
  end

  ngx.log(ngx.ERR, "[luagate:audit] ", json)
  return true
end

--- Audit-or-reject helper: write audit log, send 500 on failure.
-- Returns true if audit succeeded, false if rejected (response already sent).
-- @param event  string  Event name
-- @param fields table   Additional fields
-- @return boolean  true if audit write succeeded
local function audit_or_reject(event, fields)
  local ok = audit_log(event, fields)
  if not ok then
    send_error(500, "audit_write_failed", "audit", "failed to write audit log; mutation rejected")
    return false
  end
  return true
end

--- Read the canonical policy file content.
-- @return string|nil content, string|nil error
local function read_policy_file()
  local f, err = io.open(POLICY_FILE, "r")
  if not f then
    return nil, "cannot open policy file: " .. tostring(err)
  end
  local content = f:read("*all")
  f:close()
  if not content or #content == 0 then
    return nil, "policy file is empty"
  end
  return content, nil
end

--- Generate a worker-unique temp file path to prevent TOCTOU race.
-- Two concurrent PUTs will write to different temp files.
-- @return string  Unique temp file path
local function make_tmp_path()
  local worker_id = (ngx.worker and ngx.worker.id()) or 0
  return POLICY_FILE .. ".tmp." .. tostring(worker_id) .. "." .. tostring(ngx.now())
end

--- Read request body from memory or Nginx temp file.
-- OpenResty returns nil from get_body_data() when the body was buffered to disk.
-- @return string|nil body
-- @return number|nil status
-- @return string|nil code
-- @return string|nil stage
-- @return string|nil message
local function read_request_body()
  ngx.req.read_body()

  local body = ngx.req.get_body_data()
  if body then
    return body, nil, nil, nil, nil
  end

  local body_file = ngx.req.get_body_file and ngx.req.get_body_file()
  if not body_file then
    return nil, 413, "payload_too_large", "request", "body missing or exceeds buffer limit"
  end

  local f, err = io.open(body_file, "r")
  if not f then
    return nil, 500, "internal_error", "internal", "cannot open buffered request body: " .. tostring(err)
  end

  body = f:read("*all")
  f:close()
  if body == nil then
    return nil, 500, "internal_error", "internal", "failed to read buffered request body"
  end

  return body, nil, nil, nil, nil
end

--- Validate PUT If-Match against the current source_version.
-- @param if_match string
-- @return string|nil current_source
-- @return string|nil mismatch message
local function validate_source_if_match(if_match)
  local current_source = loader.get_active_versions().source_version
  if current_source and if_match ~= current_source then
    return current_source, "If-Match version mismatch: expected " .. current_source .. ", got " .. if_match
  end
  return current_source, nil
end

--- Best-effort rollback for PUT commit failures per ADR-005 §1.
-- @param previous_http_version string|nil
-- @param previous_stream_version string|nil
-- @param previous_source_version string|nil
-- @return table rollback result
local function rollback_put_commit(previous_http_version, previous_stream_version, previous_source_version)
  return loader.rollback_active_versions({
    http_version = previous_http_version,
    stream_version = previous_stream_version,
    source_version = previous_source_version,
  })
end

-- ---------------------------------------------------------------------------
-- Endpoint handlers
-- ---------------------------------------------------------------------------

--- GET /api/v1/policies — return canonical YAML + ETag.
function _M.handle_get_policies()
  local content, read_err = read_policy_file()
  if not content then
    send_error(500, "internal_error", "internal", read_err)
    return
  end

  local versions = loader.get_active_versions()
  local etag = versions.source_version

  -- If source_version not yet in shared dict, compute from file content
  if not etag then
    local hex, hash_err = sha256_hex(content)
    if not hex then
      send_error(500, "internal_error", "internal", "SHA256 failed: " .. tostring(hash_err))
      return
    end
    etag = hex
  end

  ngx.status = 200
  ngx.header["Content-Type"] = "application/x-yaml"
  ngx.header["ETag"] = '"' .. etag .. '"'
  ngx.say(content)
  ngx.exit(200)
end

--- GET /api/v1/policies/version — return version triplet.
function _M.handle_get_version()
  local versions = loader.get_active_versions()

  send_json(200, {
    source_version = versions.source_version,
    active_http_version = versions.http_version,
    active_stream_version = versions.stream_version,
    etag = versions.source_version,
  })
end

--- PUT /api/v1/policies — full pipeline: If-Match → parse → validate →
--- conflict → hash → audit → commit + canonical file write.
--- When ?dry_run=true, stops after hash and returns validation results
--- without committing (admin-api.md §6.5.1).
function _M.handle_put_policies()
  -- [0] dry_run flag
  local args = ngx.req.get_uri_args()
  local dry_run = args.dry_run == "true"

  -- [0] Content-Encoding check (compression not allowed)
  local content_encoding = ngx.req.get_headers()["Content-Encoding"]
  if content_encoding then
    send_error(422, "validation_failed", "request", "Content-Encoding not supported")
    return
  end

  -- [0] Read request body
  local body, body_status, body_code, body_stage, body_message = read_request_body()
  if not body then
    send_error(body_status, body_code, body_stage, body_message)
    return
  end
  if #body > MAX_BODY_SIZE then
    send_error(413, "payload_too_large", "request", "body exceeds 1MB limit")
    return
  end

  -- [1] If-Match check (ADR-005: optimistic lock on source_version)
  --     Optional when dry_run=true (no commit, so no lock needed)
  local if_match = ngx.req.get_headers()["If-Match"]
  local current_source
  if not if_match then
    if not dry_run then
      send_error(428, "version_mismatch", "reload", "If-Match header is required")
      return
    end
  else
    -- Strip surrounding quotes if present
    if_match = if_match:gsub('^"', ""):gsub('"$', "")

    local mismatch_msg
    current_source, mismatch_msg = validate_source_if_match(if_match)
    if mismatch_msg then
      send_error(409, "version_mismatch", "reload", mismatch_msg)
      return
    end
  end

  -- [2] Parse
  local policy, parse_err = parser.parse_string(body)
  if not policy then
    send_error(422, "validation_failed", "validate", "parse error: " .. tostring(parse_err))
    return
  end

  -- [3] Validate
  local _, validate_err = validator.validate(policy)
  if validate_err then
    send_error(422, "validation_failed", "validate", tostring(validate_err))
    return
  end

  -- [4] Conflict detection
  local http_enabled = conflict.filter_enabled(policy.rules or {})
  local stream_enabled = conflict.filter_enabled(policy.stream_rules or {})
  local all_enabled = {}
  for _, r in ipairs(http_enabled) do
    all_enabled[#all_enabled + 1] = r
  end
  for _, r in ipairs(stream_enabled) do
    all_enabled[#all_enabled + 1] = r
  end
  local conflicts, shadowed = conflict.detect(all_enabled)

  -- In dry_run mode, conflicts are warnings, not fatal errors
  if #conflicts > 0 and not dry_run then
    local details = {}
    for _, c in ipairs(conflicts) do
      local ids = table.concat(c.rule_ids or {}, ", ")
      details[#details + 1] = ids .. ": " .. (c.message or "conflicting rules detected")
    end
    send_error(422, "conflict_detected", "conflict_detect", table.concat(details, "; "))
    return
  end

  -- [5] Hash
  local new_version, hash_err = sha256_hex(body)
  if not new_version then
    send_error(500, "internal_error", "internal", "SHA256 failed: " .. tostring(hash_err))
    return
  end

  -- [5.1] dry_run: return validation results without committing
  if dry_run then
    local warnings = {}
    for _, c in ipairs(conflicts) do
      warnings[#warnings + 1] = {
        type = "conflict",
        rule_ids = c.rule_ids or {},
        message = c.message or "conflicting rules detected",
      }
    end
    send_json(200, {
      dry_run = true,
      valid = true,
      version_hash = new_version,
      warnings = warnings,
      shadowed = shadowed or {},
      http_rules_count = #(policy.rules or {}),
      stream_rules_count = #(policy.stream_rules or {}),
    })
    return
  end

  -- [6] Write to worker-unique temp file (prevents TOCTOU race between
  -- concurrent PUTs — each request gets its own temp path)
  local tmp_path = make_tmp_path()
  local wf, write_err = io.open(tmp_path, "w")
  if not wf then
    send_error(500, "internal_error", "internal", "cannot write temp policy file: " .. tostring(write_err))
    return
  end
  wf:write(body)
  wf:close()

  -- [7] Audit write (pre-commit — ADR-004 droppable-audit prohibition)
  if
    not audit_or_reject("policy_update_attempt", {
      trigger = "api",
      new_version = new_version,
      previous_version = current_source,
    })
  then
    os.remove(tmp_path)
    return
  end

  -- Load from temp file (stages [1]-[7] of loader pipeline)
  local result = loader.load_policy(tmp_path, {
    on_lock_acquired = function()
      local locked_source, locked_mismatch_msg = validate_source_if_match(if_match)
      if locked_mismatch_msg then
        return false, "version_mismatch", locked_mismatch_msg
      end
      current_source = locked_source
      return true
    end,
  })

  if result.err then
    -- Cleanup temp file
    os.remove(tmp_path)

    -- Determine error type
    if result.err_code == "version_mismatch" then
      local latest_source = loader.get_active_versions().source_version
      if
        not audit_or_reject("policy_update_failure", {
          trigger = "api",
          stage = "reload",
          reason = result.err_detail or result.err,
          current_version = latest_source,
        })
      then
        return
      end
      send_error(409, "version_mismatch", "reload", result.err_detail or result.err)
      return
    end

    if result.err == "reload_in_progress" then
      if
        not audit_or_reject("policy_update_failure", {
          trigger = "api",
          stage = "reload",
          reason = result.err,
          current_version = current_source,
        })
      then
        return
      end
      send_error(409, "reload_in_progress", "reload", "another reload is already in progress")
      return
    end

    if
      not audit_or_reject("policy_update_failure", {
        trigger = "api",
        stage = "commit",
        reason = result.err,
        current_version = current_source,
      })
    then
      return
    end
    send_error(500, "commit_failed", "commit", result.err)
    return
  end

  -- [8] Commit result evaluation + canonical file write
  if result.skipped then
    -- Same hash — no change needed, cleanup temp
    os.remove(tmp_path)

    -- Nginx core also evaluates If-Match preconditions for successful writes.
    -- Echo the validated source-version ETag on the success response so the
    -- application-level optimistic lock does not get overridden with 412.
    ngx.header["ETag"] = '"' .. if_match .. '"'

    if
      not audit_or_reject("policy_update_success", {
        trigger = "api",
        previous_version = current_source,
        new_version = new_version,
      })
    then
      return
    end

    send_json(200, {
      previous_http_version = result.previous_http_version,
      previous_stream_version = result.previous_stream_version,
      new_http_version = new_version,
      new_stream_version = new_version,
      http_result = "committed",
      stream_result = "committed",
      warnings = {},
    })
    return
  end

  -- Check partial commit
  if not result.http_ok or not result.stream_ok then
    -- Partial commit or full failure — do NOT write canonical file (ADR-005 §1)
    os.remove(tmp_path)

    local details = {}
    if result.http_err then
      details[#details + 1] = result.http_err
    end
    if result.stream_err then
      details[#details + 1] = result.stream_err
    end

    local rollback_result =
      rollback_put_commit(result.previous_http_version, result.previous_stream_version, current_source)
    if not rollback_result.ok then
      details[#details + 1] = "rollback failed: " .. table.concat(rollback_result.errors, "; ")
      ngx.log(ngx.CRIT, "[luagate:admin] PUT commit rollback failed: ", table.concat(rollback_result.errors, "; "))
    end

    local cur_versions = loader.get_active_versions()

    if
      not audit_or_reject("policy_update_partial", {
        trigger = "api",
        http_result = result.http_ok and "committed" or "lkg_retained",
        stream_result = result.stream_ok and "committed" or "lkg_retained",
        rollback_result = rollback_result.ok and "restored" or "failed",
      })
    then
      return
    end

    ngx.status = 500
    ngx.header["Content-Type"] = "application/json"
    local err_body = cjson.encode({
      error = "commit_failed",
      stage = "commit",
      details = details,
      current_http_version = cur_versions.http_version,
      current_stream_version = cur_versions.stream_version,
    })
    ngx.say(err_body or '{"error":"commit_failed","stage":"commit","details":["encode error"]}')
    ngx.exit(500)
    return
  end

  -- Both subsystems committed — write canonical file (stage [8c])
  local rename_ok, rename_err = os.rename(tmp_path, POLICY_FILE)
  if not rename_ok then
    -- Rollback: best-effort (pointers already swapped, but canonical file unchanged)
    os.remove(tmp_path)

    local rollback_result =
      rollback_put_commit(result.previous_http_version, result.previous_stream_version, current_source)
    local failure_reason = "canonical file write failed: " .. tostring(rename_err)
    if not rollback_result.ok then
      failure_reason = failure_reason .. "; rollback failed: " .. table.concat(rollback_result.errors, "; ")
      ngx.log(ngx.CRIT, "[luagate:admin] PUT file-write rollback failed: ", table.concat(rollback_result.errors, "; "))
    end

    if
      not audit_or_reject("policy_update_failure", {
        trigger = "api",
        stage = "commit",
        reason = failure_reason,
        current_version = new_version,
      })
    then
      return
    end

    local cur_versions = loader.get_active_versions()
    ngx.status = 500
    ngx.header["Content-Type"] = "application/json"
    local err_body = cjson.encode({
      error = "commit_failed",
      stage = "commit",
      details = {
        "pointer swaps succeeded but canonical file write failed: " .. tostring(rename_err),
      },
      current_http_version = cur_versions.http_version,
      current_stream_version = cur_versions.stream_version,
    })
    if not rollback_result.ok then
      err_body = cjson.encode({
        error = "commit_failed",
        stage = "commit",
        details = {
          "pointer swaps succeeded but canonical file write failed: " .. tostring(rename_err),
          "rollback failed: " .. table.concat(rollback_result.errors, "; "),
          "active versions may be inconsistent with canonical file",
        },
        current_http_version = cur_versions.http_version,
        current_stream_version = cur_versions.stream_version,
      })
    end
    ngx.say(err_body or '{"error":"commit_failed","stage":"commit","details":["file write error"]}')
    ngx.exit(500)
    return
  end

  -- Full success
  if
    not audit_or_reject("policy_update_success", {
      trigger = "api",
      previous_version = result.previous_http_version,
      new_version = new_version,
    })
  then
    return
  end

  -- Preserve the validated precondition token on the response to avoid Nginx
  -- core turning a successful application-level PUT into 412.
  ngx.header["ETag"] = '"' .. if_match .. '"'

  send_json(200, {
    previous_http_version = result.previous_http_version,
    previous_stream_version = result.previous_stream_version,
    new_http_version = new_version,
    new_stream_version = new_version,
    http_result = "committed",
    stream_result = "committed",
    warnings = {},
  })
end

--- POST /api/v1/policies/reload — reload from current canonical file.
function _M.handle_post_reload()
  -- Optional If-Match check against http:active_version
  local if_match = ngx.req.get_headers()["If-Match"]
  if if_match then
    if_match = if_match:gsub('^"', ""):gsub('"$', "")
    local versions = loader.get_active_versions()
    local current_http = versions.http_version
    if current_http and if_match ~= current_http then
      send_error(
        409,
        "version_mismatch",
        "reload",
        "If-Match version mismatch: expected " .. tostring(current_http) .. ", got " .. if_match
      )
      return
    end
  end

  -- Audit pre-reload
  local pre_versions = loader.get_active_versions()
  if
    not audit_or_reject("policy_reload_attempt", {
      trigger = "api",
      current_version = pre_versions.source_version,
    })
  then
    return
  end

  -- Execute 7-stage pipeline
  local result = loader.load_policy(POLICY_FILE)

  if result.err then
    if result.err == "reload_in_progress" then
      if
        not audit_or_reject("policy_reload_failure", {
          trigger = "api",
          stage = "reload",
          reason = result.err,
          current_version = pre_versions.source_version,
        })
      then
        return
      end
      send_error(409, "reload_in_progress", "reload", "another reload is already in progress")
      return
    end

    if
      not audit_or_reject("policy_reload_failure", {
        trigger = "api",
        stage = "reload",
        reason = result.err,
        current_version = pre_versions.source_version,
      })
    then
      return
    end

    local cur_versions = loader.get_active_versions()
    ngx.status = 500
    ngx.header["Content-Type"] = "application/json"
    local err_body = cjson.encode({
      error = "reload_failed",
      stage = "reload",
      details = { result.err },
      current_http_version = cur_versions.http_version,
      current_stream_version = cur_versions.stream_version,
    })
    ngx.say(err_body or '{"error":"reload_failed","stage":"reload","details":["unknown error"]}')
    ngx.exit(500)
    return
  end

  -- Partial commit handling
  local http_result_str = result.http_ok and "committed" or "lkg_retained"
  local stream_result_str = result.stream_ok and "committed" or "lkg_retained"

  if result.http_ok and result.stream_ok then
    if
      not audit_or_reject("policy_reload_success", {
        trigger = "api",
        previous_version = result.previous_http_version,
        new_version = result.new_version,
        subsystem = "all",
      })
    then
      return
    end
  else
    if
      not audit_or_reject("policy_reload_partial", {
        trigger = "api",
        http_result = http_result_str,
        stream_result = stream_result_str,
      })
    then
      return
    end
  end

  -- Build error list for response
  local errors = {}
  if result.http_err then
    errors[#errors + 1] = result.http_err
  end
  if result.stream_err then
    errors[#errors + 1] = result.stream_err
  end

  send_json(200, {
    previous_http_version = result.previous_http_version,
    previous_stream_version = result.previous_stream_version,
    new_http_version = result.new_version,
    new_stream_version = result.new_version,
    http_result = http_result_str,
    stream_result = stream_result_str,
    reloaded_at = ngx.utctime(),
    warnings_count = #(result.conflicts or {}),
    errors = errors,
  })
end

return _M
