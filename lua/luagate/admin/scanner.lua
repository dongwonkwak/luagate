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
--   - Admin plane: blocking I/O (io.open, os.rename, os.remove) permitted
--     in content_by_lua (same pattern as policies.lua — admin port 9090 only,
--     not data-plane hot path)
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

--- Send a JSON error response (admin-api.md §3 shape with stage field).
-- @param status  number  HTTP status code
-- @param code    string  Error code (snake_case)
-- @param stage   string  Pipeline stage (e.g. "scanner", "internal")
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
  fields.timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
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
    send_error(500, "audit_write_failed", "scanner", "failed to write audit log; mutation rejected")
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

--- Build per-pattern metadata array by reading YAML files from the patterns
--- directory.  Admin plane only (blocking I/O permitted on port 9090).
--- Returns a Lua array of {threat_type, rule_name, score} tables, or an
--- empty table if the directory cannot be read.
--- @param patterns_dir string  Path to scanner-patterns directory
--- @return table  Array of pattern metadata entries
local function collect_pattern_metadata(patterns_dir)
  if not patterns_dir then
    return {}
  end

  -- Use lfs (LuaFileSystem) for directory listing if available; fall back
  -- to io.popen when lfs is absent (OpenResty bundles neither by default,
  -- but admin plane can use either).
  local ok_lfs, lfs = pcall(require, "lfs")
  local filenames = {}

  if ok_lfs then
    local ok_iter, iter, dir_obj = pcall(lfs.dir, patterns_dir)
    if ok_iter then
      for name in iter, dir_obj do
        if name:match("%.ya?ml$") then
          filenames[#filenames + 1] = name
        end
      end
    end
  else
    -- Fallback: plain Lua directory listing via io.popen (admin plane only)
    local cmd = 'ls -1 "' .. patterns_dir .. '"/ 2>/dev/null'
    local pipe = io.popen(cmd)
    if pipe then
      for line in pipe:lines() do
        if line:match("%.ya?ml$") then
          filenames[#filenames + 1] = line
        end
      end
      pipe:close()
    end
  end

  table.sort(filenames)

  -- Parse each YAML file to extract per-pattern metadata.  We only need
  -- threat_type, rule_name, and score for the GET response.  Use a simple
  -- line-based parser to avoid adding a YAML dependency in Lua (the Rust
  -- side has already validated these files during reload).
  local patterns = {}
  for _, fname in ipairs(filenames) do
    local fpath = patterns_dir .. "/" .. fname
    local fh = io.open(fpath, "r")
    if fh then
      local content = fh:read("*all")
      fh:close()
      -- Simple line parser: extract threat_type, rule_name, score fields
      -- from YAML entries.  Each pattern block starts with "- threat_type:"
      -- or "  - threat_type:" (under patterns: key).
      local current = nil
      for line in content:gmatch("[^\r\n]+") do
        local tt = line:match("threat_type:%s*(.+)")
        if tt then
          current = { threat_type = tt:gsub("^%s+", ""):gsub("%s+$", "") }
        end
        if current then
          local rn = line:match("rule_name:%s*(.+)")
          if rn then
            current.rule_name = rn:gsub("^%s+", ""):gsub("%s+$", "")
          end
          local sc = line:match("score:%s*([%d%.]+)")
          if sc then
            current.score = tonumber(sc)
            patterns[#patterns + 1] = current
            current = nil
          end
        end
      end
    end
  end

  return patterns
end

--- Update shared dict scanner metadata after successful reload.
-- [5] Verify stage of ADR-014 pipeline.
-- @param version       string  SHA256 hex
-- @param pattern_count number
-- @param patterns_dir  string|nil  Path to scanner-patterns directory (for metadata collection)
-- @return boolean  true on success, false if any set() failed
-- @return string|nil  error message on failure
local function update_scanner_metadata(version, pattern_count, patterns_dir)
  local dict = get_dict()
  if not dict then
    return false, "scanner shared dict unavailable"
  end

  local ok, err = dict:set("scanner:active_version", version)
  if not ok then
    ngx.log(ngx.ERR, "[luagate:admin:scanner] dict:set scanner:active_version failed: ", tostring(err))
    return false, "metadata update failed: scanner:active_version: " .. tostring(err)
  end

  local ok2, err2 = dict:set("scanner:loaded_at", os.date("!%Y-%m-%dT%H:%M:%SZ"))
  if not ok2 then
    ngx.log(ngx.ERR, "[luagate:admin:scanner] dict:set scanner:loaded_at failed: ", tostring(err2))
    return false, "metadata update failed: scanner:loaded_at: " .. tostring(err2)
  end

  local ok3, err3 = dict:set("scanner:pattern_count", pattern_count)
  if not ok3 then
    ngx.log(ngx.ERR, "[luagate:admin:scanner] dict:set scanner:pattern_count failed: ", tostring(err3))
    return false, "metadata update failed: scanner:pattern_count: " .. tostring(err3)
  end

  -- Collect per-pattern metadata from YAML files and store as JSON in shared
  -- dict.  This populates the GET /api/v1/scanner/patterns response.
  -- Best-effort: metadata collection failure does not fail the overall update.
  if patterns_dir then
    local patterns_meta = collect_pattern_metadata(patterns_dir)
    local meta_json = cjson.encode(patterns_meta)
    if meta_json then
      local ok4, err4 = dict:set("scanner:pattern_metadata", meta_json)
      if not ok4 then
        ngx.log(ngx.WARN, "[luagate:admin:scanner] dict:set scanner:pattern_metadata failed: ", tostring(err4))
        -- Non-fatal: GET will return empty patterns array
      end
    end
  end

  return true, nil
end

-- ---------------------------------------------------------------------------
-- Endpoint handlers
-- ---------------------------------------------------------------------------

--- GET /api/v1/scanner/patterns — return current pattern status.
-- Returns metadata from shared dict (no filesystem I/O in GET).
function _M.handle_get_patterns()
  local dict = get_dict()
  if not dict then
    send_error(503, "scanner_unavailable", "scanner", "scanner shared dict not available")
    return
  end

  local active_version = dict:get("scanner:active_version") or cjson.null
  local loaded_at = dict:get("scanner:loaded_at") or cjson.null
  local pattern_count = tonumber(dict:get("scanner:pattern_count")) or 0

  -- Retrieve per-pattern metadata from shared dict (populated at reload time).
  -- Stored as JSON-encoded array under scanner:pattern_metadata key.
  local patterns = {}
  local meta_json = dict:get("scanner:pattern_metadata")
  if meta_json then
    local decoded = cjson.decode(meta_json)
    if decoded then
      patterns = decoded
    end
  end

  send_json(200, {
    active_version = active_version,
    loaded_at = loaded_at,
    pattern_count = pattern_count,
    patterns = patterns,
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
    send_error(400, "empty_body", "scanner", "request body is empty")
    return
  end

  if #body > MAX_BODY_SIZE then
    send_error(413, "payload_too_large", "scanner", "body exceeds 1MB limit")
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
    send_error(500, "internal_error", "scanner", "cannot write temp file: " .. tostring(write_err))
    return
  end
  wf:write(yaml_body)
  wf:close()

  -- [3] Acquire reload lock
  local owner_id, lock_err = acquire_reload_lock()
  if not owner_id then
    os.remove(tmp_path)
    if lock_err == "ReloadInProgress" then
      send_error(409, "reload_in_progress", "scanner", "another reload is already in progress")
    else
      send_error(500, "internal_error", "scanner", lock_err or "lock acquisition failed")
    end
    return
  end

  -- [4] Pre-commit audit
  if not audit_or_reject("scanner_pattern_update_attempt", { trigger = "api" }) then
    os.remove(tmp_path)
    release_reload_lock(owner_id)
    return
  end

  -- [5] Backup existing custom.yaml (may not exist for new files)
  local bak_path = CUSTOM_YAML_PATH .. ".bak"
  local had_existing = false
  local existing_f = io.open(CUSTOM_YAML_PATH, "r")
  if existing_f then
    had_existing = true
    local existing_content = existing_f:read("*all")
    existing_f:close()
    local bak_f = io.open(bak_path, "w")
    if bak_f then
      bak_f:write(existing_content)
      bak_f:close()
    end
  end

  -- Capture previous version before reload
  local dict = get_dict()
  local previous_version = dict and dict:get("scanner:active_version") or nil

  -- [6] Atomic rename: tmp -> custom.yaml
  -- NOTE: rename MUST happen before reload because luagate_scanner_reload()
  -- reads the entire conf/scanner-patterns/ directory. The file must be in
  -- canonical position for reload to see it. Rollback in [7] restores from
  -- .bak (had_existing=true) or removes canonical (had_existing=false).
  local rename_ok, rename_err = os.rename(tmp_path, CUSTOM_YAML_PATH)
  if not rename_ok then
    os.remove(tmp_path)
    release_reload_lock(owner_id)
    send_error(500, "internal_error", "scanner", "cannot rename temp file: " .. tostring(rename_err))
    return
  end

  -- [7] Reload all patterns (entire conf/scanner-patterns/ directory).
  -- rename-before-validate is required because luagate_scanner_reload()
  -- reads the entire conf/scanner-patterns/ directory; the file must be in
  -- canonical position for reload to see it.  Rollback guarantees restoration.
  local result, reload_err = scanner_ffi.reload(PATTERNS_DIR)
  if not result then
    -- Rollback: restore from .bak if existed, otherwise remove canonical
    -- (Codex feedback: when custom.yaml didn't exist before, .bak is absent
    -- and rollback must delete the newly created canonical file)
    local rollback_failed = false
    if had_existing then
      local rollback_ok = os.rename(bak_path, CUSTOM_YAML_PATH)
      if not rollback_ok then
        rollback_failed = true
        ngx.log(ngx.CRIT, "[luagate:admin:scanner] rollback failed: cannot restore custom.yaml from .bak")
      end
    else
      local remove_ok = os.remove(CUSTOM_YAML_PATH)
      if not remove_ok then
        rollback_failed = true
        ngx.log(ngx.CRIT, "[luagate:admin:scanner] rollback failed: cannot remove newly created custom.yaml")
      end
    end

    release_reload_lock(owner_id)

    -- Classify error by ffi error code pattern (Codex feedback: use error
    -- code category from ffi.reload instead of substring matching)
    local is_validation = reload_err and reload_err:find("validation_error")
    local detail = tostring(reload_err)
    if rollback_failed then
      detail = detail .. " (WARNING: rollback also failed — manual intervention required)"
    end
    if is_validation then
      audit_log("scanner_pattern_update_failure", {
        trigger = "api",
        reason = reload_err,
        rollback_failed = rollback_failed,
      })
      send_error(400, "validation_failed", "scanner", detail)
    else
      audit_log("scanner_pattern_update_failure", {
        trigger = "api",
        reason = reload_err or "unknown",
        rollback_failed = rollback_failed,
      })
      send_error(500, "reload_failed", "scanner", detail)
    end
    return
  end

  -- [8] Success: update shared dict metadata.
  -- Metadata failure does NOT warrant rollback because the Rust scanner already
  -- holds valid new patterns and the YAML file on disk is correct.  The next
  -- POST /reload (or worker timer) will re-sync metadata.  Returning 200 with
  -- a warning avoids a split-brain where we roll back the file while Rust keeps
  -- the new patterns.
  local meta_ok, meta_err = update_scanner_metadata(result.version, result.pattern_count, PATTERNS_DIR)
  local metadata_warning = nil
  if not meta_ok then
    ngx.log(
      ngx.CRIT,
      "[luagate:admin:scanner] metadata update failed after successful reload: ",
      tostring(meta_err),
      " — other workers may lag until next reload"
    )
    metadata_warning = "shared dict update failed, other workers may lag"
  end

  -- Remove backup
  os.remove(bak_path)

  release_reload_lock(owner_id)

  local reloaded_at = os.date("!%Y-%m-%dT%H:%M:%SZ")

  -- Post-commit audit (best-effort)
  audit_log("scanner_pattern_update_success", {
    trigger = "api",
    new_version = result.version,
    pattern_count = result.pattern_count,
  })

  local response = {
    previous_version = previous_version,
    new_version = result.version,
    pattern_count = result.pattern_count,
    reloaded_at = reloaded_at,
  }
  if metadata_warning then
    response.metadata_warning = metadata_warning
  end
  send_json(200, response)
end

--- POST /api/v1/scanner/patterns/reload — reload patterns from filesystem.
function _M.handle_post_reload()
  -- [1] Acquire reload lock
  local owner_id, lock_err = acquire_reload_lock()
  if not owner_id then
    if lock_err == "ReloadInProgress" then
      send_error(409, "reload_in_progress", "scanner", "another reload is already in progress")
    else
      send_error(500, "internal_error", "scanner", lock_err or "lock acquisition failed")
    end
    return
  end

  -- [2] Pre-commit audit
  if not audit_or_reject("scanner_pattern_reload_attempt", { trigger = "api" }) then
    release_reload_lock(owner_id)
    return
  end

  -- Capture previous version before reload
  local dict = get_dict()
  local previous_version = dict and dict:get("scanner:active_version") or nil

  -- [3] Reload
  local result, reload_err = scanner_ffi.reload(PATTERNS_DIR)
  if not result then
    release_reload_lock(owner_id)

    audit_log("scanner_pattern_reload_failure", {
      trigger = "api",
      reason = reload_err or "unknown",
    })

    -- Classify error by ffi error code category
    local is_validation = reload_err and reload_err:find("validation_error")
    if is_validation then
      send_error(400, "validation_failed", "scanner", tostring(reload_err))
    else
      send_error(500, "reload_failed", "scanner", tostring(reload_err))
    end
    return
  end

  -- [4] Update shared dict metadata
  local meta_ok, meta_err = update_scanner_metadata(result.version, result.pattern_count, PATTERNS_DIR)
  if not meta_ok then
    release_reload_lock(owner_id)
    ngx.log(ngx.ERR, "[luagate:admin:scanner] POST reload metadata update failed: ", tostring(meta_err))
    send_error(500, "metadata_update_failed", "scanner", tostring(meta_err))
    return
  end

  release_reload_lock(owner_id)

  local reloaded_at = os.date("!%Y-%m-%dT%H:%M:%SZ")

  -- Post-commit audit
  audit_log("scanner_pattern_reload_success", {
    trigger = "api",
    new_version = result.version,
    pattern_count = result.pattern_count,
  })

  send_json(200, {
    previous_version = previous_version,
    new_version = result.version,
    pattern_count = result.pattern_count,
    reloaded_at = reloaded_at,
  })
end

return _M
