--- Admin API scanner pattern management handlers for LuaGate.
-- Implements GET/PUT /api/v1/scanner/patterns and
-- POST /api/v1/scanner/patterns/reload per ADR-014 §6.
--
-- Design rules:
--   - Reload lock via shared dict (5s TTL) to prevent concurrent reloads
--   - Audit log on all mutations (pre-commit: reject on failure)
--   - fail-closed: any error aborts and returns error response
--   - PUT: validate -> write tmp -> rename -> reload -> rollback on failure
--   - ngx.ctx MUST NOT store scanner cache
--   - ngx.worker.id() per AGENTS.md invariant
--
-- Implementation: lua/luagate/admin/scanner.lua
-- Tests: tests/unit/admin/scanner_spec.lua

local cjson = require("cjson.safe")
local scanner_ffi = require("luagate.scanner.ffi")

local _M = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local SCANNER_DICT_NAME = "luagate_scanner_patterns"
local PATTERNS_DIR = "conf/scanner-patterns"
local CUSTOM_YAML_PATH = PATTERNS_DIR .. "/custom.yaml"
local RELOAD_LOCK_KEY = "scanner_reload_lock"
local RELOAD_LOCK_TTL = 5 -- seconds (ADR-014 §6)
local MAX_BODY_SIZE = 1048576 -- 1 MB (ADR-014 risk mitigation)

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Send a JSON error response.
-- @param status  number  HTTP status code
-- @param code    string  Error code
-- @param message string  Detail message
local function send_error(status, code, message)
  ngx.status = status
  ngx.header["Content-Type"] = "application/json"
  local body = cjson.encode({
    error = code,
    details = { message },
  })
  ngx.say(body or '{"error":"encode_failed"}')
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

--- Get the scanner shared dict.
-- @return table|nil
local function get_dict()
  if not ngx or not ngx.shared then
    return nil
  end
  return ngx.shared[SCANNER_DICT_NAME]
end

--- Extract MCP metadata from request headers (ADR-011 §8).
local function extract_mcp_metadata()
  local headers = ngx.req.get_headers()
  local mcp_client = headers["X-MCP-Client"]
  if type(mcp_client) == "table" then
    mcp_client = mcp_client[1]
  end

  if not mcp_client then
    return { actor_type = "api" }
  end

  local tool_name = headers["X-MCP-Tool"]
  if type(tool_name) == "table" then
    tool_name = tool_name[1]
  end

  return {
    actor_type = "mcp",
    client_name = mcp_client,
    tool_name = tool_name,
  }
end

--- Write structured audit log entry.
-- @param event  string  Event name
-- @param fields table   Additional fields
-- @return boolean  true if audit write succeeded
local function audit_log(event, fields)
  fields = fields or {}
  fields.timestamp = ngx.utctime()
  fields.event = event
  fields.actor_ip = ngx.var.remote_addr or "unknown"

  local mcp = extract_mcp_metadata()
  for k, v in pairs(mcp) do
    fields[k] = v
  end

  local json = cjson.encode(fields)
  if not json then
    return false
  end

  ngx.log(ngx.ERR, "[luagate:audit] ", json)
  return true
end

--- Audit-or-reject helper.
-- @param event  string
-- @param fields table
-- @return boolean
local function audit_or_reject(event, fields)
  local ok = audit_log(event, fields)
  if not ok then
    send_error(500, "audit_write_failed", "failed to write audit log; mutation rejected")
    return false
  end
  return true
end

--- Acquire the scanner reload lock.
-- @return string|nil owner_id
-- @return string|nil error
local function acquire_reload_lock()
  local dict = get_dict()
  if not dict then
    return nil, "scanner shared dict unavailable"
  end

  local wid = ngx.worker.id()
  local owner_id = tostring(wid) .. ":" .. tostring(ngx.now())

  local ok, err, _ = dict:add(RELOAD_LOCK_KEY, owner_id, RELOAD_LOCK_TTL)
  if not ok then
    if err == "exists" then
      return nil, "ReloadInProgress"
    end
    return nil, "lock add failed: " .. tostring(err)
  end

  return owner_id, nil
end

--- Release the scanner reload lock.
-- @param owner_id string
local function release_reload_lock(owner_id)
  if not owner_id then
    return
  end
  local dict = get_dict()
  if not dict then
    return
  end
  local current = dict:get(RELOAD_LOCK_KEY)
  if current == owner_id then
    dict:delete(RELOAD_LOCK_KEY)
  end
end

--- Update shared dict scanner metadata after successful reload.
-- [5] Verify stage of ADR-014 pipeline.
-- @param version       string  SHA256 hex
-- @param pattern_count number
local function update_scanner_metadata(version, pattern_count)
  local dict = get_dict()
  if not dict then
    return
  end

  dict:set("scanner:active_version", version)
  dict:set("scanner:loaded_at", ngx.utctime())
  dict:set("scanner:pattern_count", pattern_count)
end

-- ---------------------------------------------------------------------------
-- Endpoint handlers
-- ---------------------------------------------------------------------------

--- GET /api/v1/scanner/patterns — return current pattern status.
function _M.handle_get_patterns()
  local dict = get_dict()
  if not dict then
    send_error(503, "scanner_unavailable", "scanner shared dict not available")
    return
  end

  local active_version = dict:get("scanner:active_version") or cjson.null
  local loaded_at = dict:get("scanner:loaded_at") or cjson.null
  local pattern_count = tonumber(dict:get("scanner:pattern_count")) or 0

  send_json(200, {
    active_version = active_version,
    loaded_at = loaded_at,
    pattern_count = pattern_count,
  })
end

--- PUT /api/v1/scanner/patterns — upload custom patterns.
-- Body: YAML (bare array or patterns: key).
-- Validates, writes to custom.yaml, reloads all patterns.
function _M.handle_put_patterns()
  -- [0] Read request body
  ngx.req.read_body()
  local body = ngx.req.get_body_data()
  if not body then
    -- Check temp file
    local body_file = ngx.req.get_body_file and ngx.req.get_body_file()
    if body_file then
      local f = io.open(body_file, "r")
      if f then
        body = f:read("*all")
        f:close()
      end
    end
  end

  if not body or #body == 0 then
    send_error(400, "empty_body", "request body is empty")
    return
  end

  if #body > MAX_BODY_SIZE then
    send_error(413, "payload_too_large", "body exceeds 1MB limit")
    return
  end

  -- [1] Wrap bare array if needed: if body starts with "- " it's a bare array
  local yaml_body = body
  if body:sub(1, 2) == "- " then
    yaml_body = "patterns:\n" .. body:gsub("([^\n]+)", "  %1")
  end

  -- [2] Write to temp file for validation
  local tmp_path = CUSTOM_YAML_PATH .. ".tmp"
  local wf, write_err = io.open(tmp_path, "w")
  if not wf then
    send_error(500, "internal_error", "cannot write temp file: " .. tostring(write_err))
    return
  end
  wf:write(yaml_body)
  wf:close()

  -- [3] Acquire reload lock
  local owner_id, lock_err = acquire_reload_lock()
  if not owner_id then
    os.remove(tmp_path)
    if lock_err == "ReloadInProgress" then
      send_error(409, "ReloadInProgress", "another reload is already in progress")
    else
      send_error(500, "internal_error", lock_err or "lock acquisition failed")
    end
    return
  end

  -- [4] Pre-commit audit
  if not audit_or_reject("scanner_pattern_update_attempt", { trigger = "api" }) then
    os.remove(tmp_path)
    release_reload_lock(owner_id)
    return
  end

  -- [5] Backup existing custom.yaml
  local bak_path = CUSTOM_YAML_PATH .. ".bak"
  local existing_f = io.open(CUSTOM_YAML_PATH, "r")
  if existing_f then
    local existing_content = existing_f:read("*all")
    existing_f:close()
    local bak_f = io.open(bak_path, "w")
    if bak_f then
      bak_f:write(existing_content)
      bak_f:close()
    end
  end

  -- [6] Atomic rename: tmp -> custom.yaml
  local rename_ok, rename_err = os.rename(tmp_path, CUSTOM_YAML_PATH)
  if not rename_ok then
    os.remove(tmp_path)
    release_reload_lock(owner_id)
    send_error(500, "internal_error", "cannot rename temp file: " .. tostring(rename_err))
    return
  end

  -- [7] Reload all patterns (entire conf/scanner-patterns/ directory)
  local result, reload_err = scanner_ffi.reload(PATTERNS_DIR)
  if not result then
    -- Rollback: restore from .bak
    local rollback_ok = os.rename(bak_path, CUSTOM_YAML_PATH)
    if not rollback_ok then
      ngx.log(ngx.CRIT, "[luagate:admin:scanner] rollback failed: cannot restore custom.yaml from .bak")
    end

    release_reload_lock(owner_id)

    -- Distinguish parse/compile failure (400) from other errors
    local is_validation = reload_err
      and (
        reload_err:find("YAML parse")
        or reload_err:find("regex compile")
        or reload_err:find("duplicate rule_name")
        or reload_err:find("score")
      )
    if is_validation then
      audit_log("scanner_pattern_update_failure", {
        trigger = "api",
        reason = reload_err,
      })
      send_error(400, "validation_failed", tostring(reload_err))
    else
      audit_log("scanner_pattern_update_failure", {
        trigger = "api",
        reason = reload_err or "unknown",
      })
      send_error(500, "reload_failed", tostring(reload_err))
    end
    return
  end

  -- [8] Success: update shared dict metadata
  update_scanner_metadata(result.version, result.pattern_count)

  -- Remove backup
  os.remove(bak_path)

  release_reload_lock(owner_id)

  -- Post-commit audit (best-effort)
  audit_log("scanner_pattern_update_success", {
    trigger = "api",
    new_version = result.version,
    pattern_count = result.pattern_count,
  })

  send_json(200, {
    version = result.version,
    pattern_count = result.pattern_count,
    message = "patterns updated and reloaded",
  })
end

--- POST /api/v1/scanner/patterns/reload — reload patterns from filesystem.
function _M.handle_post_reload()
  -- [1] Acquire reload lock
  local owner_id, lock_err = acquire_reload_lock()
  if not owner_id then
    if lock_err == "ReloadInProgress" then
      send_error(409, "ReloadInProgress", "another reload is already in progress")
    else
      send_error(500, "internal_error", lock_err or "lock acquisition failed")
    end
    return
  end

  -- [2] Pre-commit audit
  if not audit_or_reject("scanner_pattern_reload_attempt", { trigger = "api" }) then
    release_reload_lock(owner_id)
    return
  end

  -- [3] Reload
  local result, reload_err = scanner_ffi.reload(PATTERNS_DIR)
  if not result then
    release_reload_lock(owner_id)

    audit_log("scanner_pattern_reload_failure", {
      trigger = "api",
      reason = reload_err or "unknown",
    })

    local is_validation = reload_err
      and (
        reload_err:find("YAML parse")
        or reload_err:find("regex compile")
        or reload_err:find("duplicate rule_name")
        or reload_err:find("score")
      )
    if is_validation then
      send_error(400, "validation_failed", tostring(reload_err))
    else
      send_error(500, "reload_failed", tostring(reload_err))
    end
    return
  end

  -- [4] Update shared dict metadata
  update_scanner_metadata(result.version, result.pattern_count)

  release_reload_lock(owner_id)

  -- Post-commit audit
  audit_log("scanner_pattern_reload_success", {
    trigger = "api",
    new_version = result.version,
    pattern_count = result.pattern_count,
  })

  send_json(200, {
    version = result.version,
    pattern_count = result.pattern_count,
    reloaded_at = ngx.utctime(),
  })
end

return _M
