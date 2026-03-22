--- Policy Loader for LuaGate — Hot Reload 7-stage pipeline.
-- Implements ADR-003 §3.4 and policy-engine.md §4.1.
--
-- 7-stage pipeline:
--   [1] read   — io.open(filepath) + f:read("*all")
--   [2] parse  — parser.parse_string(content)
--   [3] validate — validator.validate(policy)
--   [4] conflict — conflict.detect() on enabled rules (WARN only)
--   [5] hash   — SHA256 of raw file content → new_version
--   [6] blob store — safe_set("policy:<sha256>:blob", json)
--                    safe_set("policy:<sha256>:meta", json)
--   [7] commit — set("http:active_version", new_version)
--                set("stream:active_version", new_version)
--              → subsystem-independent: each pointer swap is atomic per key.
--
-- Design rules enforced here:
--   - File I/O (io.open) is ONLY called in load_policy().  This function
--     MUST only be invoked from init_by_lua_block or the admin reload handler
--     (ADR-003 §3.4 / openresty-patterns.md anti-pattern note).
--   - fail-closed: any error in [1]-[6] aborts the pipeline; active pointers
--     are NOT updated → last-known-good is preserved.
--   - cold start (init_by_lua) failure is fatal: the caller must ngx.log +
--     error() to abort worker startup.
--   - Same-hash skip: if new_version == http:active_version AND
--     new_version == stream:active_version, no-op (idempotent reload).
--   - reload_lock: acquired via ngx.shared.luagate_policy:add() at entry,
--     released at exit (success or failure).  Only applies when called in
--     an ngx worker context (i.e. shared dict is available).
--   - ngx.ctx MUST NOT be used for policy caching (AGENTS.md invariant).
--   - All public functions return (result_table, err_string|nil).
--
-- Dependencies:
--   - lua/luagate/policy/parser.lua
--   - lua/luagate/policy/validator.lua
--   - lua/luagate/policy/conflict.lua
--   - resty.sha256  (OpenResty built-in) or fallback stub in tests
--   - resty.string  (OpenResty built-in, toHex)
--   - cjson         (LuaJIT built-in)
--
-- Implementation: lua/luagate/policy/loader.lua
-- Tests: tests/unit/policy/loader_spec.lua

local _M = {}

-- ---------------------------------------------------------------------------
-- Dependencies (pcall so test stubs can be injected via package.preload)
-- ---------------------------------------------------------------------------

local parser = require("luagate.policy.parser")
local validator = require("luagate.policy.validator")
local conflict = require("luagate.policy.conflict")

-- resty.sha256 / resty.string are OpenResty-only.
-- In unit tests, package.preload["resty.sha256"] / ["resty.string"] are
-- replaced with lightweight stubs.
local sha256_ok, resty_sha256 = pcall(require, "resty.sha256")
local str_ok, resty_str = pcall(require, "resty.string")
local cjson_ok, cjson = pcall(require, "cjson")

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local POLICY_DICT_NAME = "luagate_policy"
local RELOAD_LOCK_KEY = "reload_lock"
local RELOAD_LOCK_TTL = 5 -- seconds (ADR-005 §2)

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Emit an ERR log when ngx is available.
-- @param msg string
local function log_err(msg)
  if ngx and ngx.log then
    ngx.log(ngx.ERR, "[luagate:loader] ", msg)
  end
end

--- Emit a WARN log when ngx is available.
-- @param msg string
local function log_warn(msg)
  if ngx and ngx.log then
    ngx.log(ngx.WARN, "[luagate:loader] ", msg)
  end
end

--- Emit an INFO log when ngx is available.
-- @param msg string
local function log_info(msg)
  if ngx and ngx.log then
    ngx.log(ngx.INFO, "[luagate:loader] ", msg)
  end
end

--- Compute SHA256 of a string and return lowercase hex.
-- Uses resty.sha256 + resty.string when available (OpenResty).
-- Falls back to a stub (for unit tests).
-- @param  s  string
-- @return string  64-char lowercase hex, or nil on error
-- @return string|nil  error description
local function sha256_hex(s)
  if not sha256_ok or not str_ok then
    return nil, "resty.sha256 or resty.string not available"
  end

  -- resty.sha256 API: new() → update(s) → final() → bytes
  -- resty.string: to_hex(bytes) → lowercase hex
  local sha = resty_sha256:new()
  if not sha then
    return nil, "failed to create resty.sha256 instance"
  end
  sha:update(s)
  local digest = sha:final()
  if not digest then
    return nil, "resty.sha256:final() returned nil"
  end
  local hex = resty_str.to_hex(digest)
  if not hex then
    return nil, "resty.string.to_hex() returned nil"
  end
  return hex, nil
end

--- Encode a Lua table to JSON.
-- @param  t  table
-- @return string|nil, string|nil
local function json_encode(t)
  if not cjson_ok then
    return nil, "cjson not available"
  end
  local ok, result = pcall(cjson.encode, t)
  if not ok then
    return nil, "cjson.encode failed: " .. tostring(result)
  end
  return result, nil
end

--- Get the luagate_policy shared dict.
-- Returns nil when not in an ngx context (unit test environments).
-- @return table|nil  ngx.shared.luagate_policy or nil
local function get_dict()
  if not ngx or not ngx.shared then
    return nil
  end
  return ngx.shared[POLICY_DICT_NAME]
end

--- Acquire the reload lock (ADR-005 §2).
-- Returns (owner_id, nil) on success, (nil, err) on failure.
-- When the shared dict is not available (init_by_lua on some versions,
-- or unit tests), lock acquisition is skipped and (true, nil) is returned.
--
-- @return string|boolean  owner_id string or true when lock skipped
-- @return string|nil      error description or nil
local function acquire_reload_lock()
  local dict = get_dict()
  if not dict then
    -- init context or test — skip lock
    return true, nil
  end

  -- ADR-005 §2: owner_id = "<worker_id>:<now>"
  local worker_id = (ngx and ngx.worker and ngx.worker.id()) or 0
  local owner_id = tostring(worker_id) .. ":" .. tostring(ngx.now())

  -- ngx.shared.DICT:add() returns false when key already exists.
  local ok, err, _ = dict:add(RELOAD_LOCK_KEY, owner_id, RELOAD_LOCK_TTL)
  if not ok then
    if err == "exists" then
      return nil, "reload_in_progress"
    end
    return nil, "reload_lock add failed: " .. tostring(err)
  end

  return owner_id, nil
end

--- Release the reload lock.  Verifies owner_id before deleting to avoid the
-- race window described in ADR-005 §2.
-- @param owner_id  string|boolean  Value returned by acquire_reload_lock()
local function release_reload_lock(owner_id)
  if owner_id == true then
    -- lock was skipped (no shared dict context)
    return
  end

  local dict = get_dict()
  if not dict then
    return
  end

  local current = dict:get(RELOAD_LOCK_KEY)
  if current == owner_id then
    -- ADR-005 §2 Known Limitation: get+delete is not atomic (acceptable per ADR)
    dict:delete(RELOAD_LOCK_KEY)
  end
end

--- Store blob + meta in shared dict using safe_set.
-- "no memory" is treated as a hard error (fail-closed).
--
-- @param dict       table   ngx.shared dict
-- @param version    string  SHA256 hex
-- @param blob_json  string  JSON-encoded compiled policy blob
-- @param meta_json  string  JSON-encoded metadata
-- @return boolean, string|nil  ok, err
local function store_blob(dict, version, blob_json, meta_json)
  local blob_key = "policy:" .. version .. ":blob"
  local meta_key = "policy:" .. version .. ":meta"

  local ok, err, _ = dict:safe_set(blob_key, blob_json)
  if not ok then
    return false, "safe_set blob failed (" .. blob_key .. "): " .. tostring(err)
  end

  ok, err, _ = dict:safe_set(meta_key, meta_json)
  if not ok then
    -- rollback: delete the orphaned blob key to avoid memory leak
    dict:delete(blob_key)
    return false, "safe_set meta failed (" .. meta_key .. "): " .. tostring(err)
  end

  return true, nil
end

--- Commit: swap active version pointers for each subsystem independently.
-- Returns a result table per ADR-003 partial-commit semantics.
--
-- @param dict        table   ngx.shared dict
-- @param new_version string  SHA256 hex
-- @return table  {
--     http_ok     = boolean,
--     stream_ok   = boolean,
--     http_err    = string|nil,
--     stream_err  = string|nil,
--   }
local function commit_pointers(dict, new_version)
  local result = {
    http_ok = false,
    stream_ok = false,
    http_err = nil,
    stream_err = nil,
  }

  local ok, err = dict:set("http:active_version", new_version)
  if ok then
    result.http_ok = true
  else
    result.http_err = "set http:active_version failed: " .. tostring(err)
    log_err(result.http_err)
  end

  ok, err = dict:set("stream:active_version", new_version)
  if ok then
    result.stream_ok = true
  else
    result.stream_err = "set stream:active_version failed: " .. tostring(err)
    log_err(result.stream_err)
  end

  return result
end

--- Restore active/source version pointers to their previous values.
-- Used by PUT /api/v1/policies best-effort rollback on commit failure.
--
-- @param versions table {
--   http_version = string|nil,
--   stream_version = string|nil,
--   source_version = string|nil,
-- }
-- @return table {
--   ok = boolean,
--   http_ok = boolean,
--   stream_ok = boolean,
--   source_ok = boolean,
--   errors = string[],
-- }
function _M.rollback_active_versions(versions)
  local dict = get_dict()
  local result = {
    ok = true,
    http_ok = false,
    stream_ok = false,
    source_ok = false,
    errors = {},
  }

  if not dict then
    result.ok = false
    result.errors[#result.errors + 1] = "policy shared dict unavailable during rollback"
    log_err(result.errors[#result.errors])
    return result
  end

  local function restore(key, value, result_key)
    if value == nil then
      if not dict.delete then
        result.ok = false
        result.errors[#result.errors + 1] = "delete " .. key .. " failed: delete not supported"
        return
      end
      dict:delete(key)
      result[result_key] = true
      return
    end

    local ok, err = dict:set(key, value)
    if ok then
      result[result_key] = true
      return
    end

    result.ok = false
    result.errors[#result.errors + 1] = "set " .. key .. " rollback failed: " .. tostring(err)
  end

  restore("http:active_version", versions.http_version, "http_ok")
  restore("stream:active_version", versions.stream_version, "stream_ok")
  restore("source_version", versions.source_version, "source_ok")

  -- DON-218: Restore stream:configured flag to pre-rollback state.
  -- versions.stream_configured can be true, false/nil.
  if versions.stream_configured then
    local cfg_ok, cfg_err = dict:safe_set("stream:configured", true)
    if not cfg_ok then
      result.ok = false
      result.errors[#result.errors + 1] = "safe_set stream:configured rollback failed: " .. tostring(cfg_err)
    end
  else
    dict:delete("stream:configured")
  end

  if not result.ok then
    log_err("rollback failed: " .. table.concat(result.errors, "; "))
  end

  return result
end

--- Build the compiled blob table that will be JSON-serialised and stored in
-- shared dict.  The blob stores both http and stream compiled rule lists so
-- workers can decode a single key and get a ready-to-use policy.
--
-- Fields stored:
--   rules         — original full http rule list (for re-compile on worker)
--   stream_rules  — original full stream rule list
--   global        — { default_action }
--   version       — optional YAML version field
--
-- Note: we store the raw (pre-compile) rules so the worker-side evaluator can
-- call compile() itself after decoding.  Storing pre-sorted compiled lists
-- would require custom JSON marshalling for function closures, which cjson
-- cannot handle.  The evaluator.get_policy() call takes care of compile().
--
-- @param policy  table  Validated policy table (from parser + validator)
-- @return table
local function build_blob(policy)
  return {
    rules = policy.rules or {},
    stream_rules = policy.stream_rules or {},
    global = policy.global,
    version = policy.version,
  }
end

--- Build the metadata table stored alongside the blob.
-- @param version    string  SHA256 hex
-- @param policy     table   Validated policy table
-- @param conflicts  table   Conflict list from conflict.detect()
-- @param shadowed   table   Shadowed rule ids from conflict.detect()
-- @return table
local function build_meta(version, policy, conflicts, shadowed)
  local http_count = 0
  local stream_count = 0
  for _, rule in ipairs(policy.rules or {}) do
    if rule.enabled ~= false then
      http_count = http_count + 1
    end
  end
  for _, rule in ipairs(policy.stream_rules or {}) do
    if rule.enabled ~= false then
      stream_count = stream_count + 1
    end
  end

  local loaded_at = (ngx and ngx.now and ngx.now()) or 0

  return {
    version = version,
    loaded_at = loaded_at,
    http_rule_count = http_count,
    stream_rule_count = stream_count,
    conflicts = conflicts,
    shadowed = shadowed,
  }
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Execute the full 7-stage Hot Reload pipeline.
--
-- This function MAY be called from:
--   - init_by_lua_block  (cold start, no lock management)
--   - admin reload handler (worker context, lock management active)
--
-- MUST NOT be called from access_by_lua, log_by_lua, preread_by_lua or any
-- per-request handler (blocking io.open is used in stage [1]).
--
-- Partial commit semantics (POST /reload):
--   - If http pointer swap succeeds but stream fails → http is updated,
--     stream keeps last-known-good.  This is ADR-003 §3.4 partial-commit.
--   - The caller (admin handler) should inspect result.http_ok /
--     result.stream_ok to distinguish partial vs full success.
--
-- @param  filepath  string  Absolute path to the YAML policy file.
--                           Defaults to "conf/policies.yaml" (relative to
--                           nginx prefix) when nil.
-- @param  opts      table|nil  Optional hooks. opts.on_lock_acquired() runs
--                              after the reload lock is acquired and before
--                              stage [1]. Return false, err_code, err_detail
--                              to abort while holding the lock.
-- @return table  {
--     ok              = boolean,  -- true if at least one subsystem was updated (or
--                                 --   no reload needed due to same hash)
--     skipped         = boolean,  -- true when hash unchanged (idempotent reload)
--     new_version     = string|nil,
--     previous_http_version  = string|nil,
--     previous_stream_version = string|nil,
--     http_ok         = boolean,
--     stream_ok       = boolean,
--     http_err        = string|nil,
--     stream_err      = string|nil,
--     conflicts       = table,
--     shadowed        = table,
--     err             = string|nil,  -- top-level abort error (stages [1]-[6])
--     err_code        = string|nil,
--     err_detail      = string|nil,
--   }
function _M.load_policy(filepath, opts)
  filepath = filepath or "conf/policies.yaml"
  opts = opts or {}

  local result = {
    ok = false,
    skipped = false,
    new_version = nil,
    previous_http_version = nil,
    previous_stream_version = nil,
    http_ok = false,
    stream_ok = false,
    http_err = nil,
    stream_err = nil,
    conflicts = {},
    shadowed = {},
    err = nil,
    err_code = nil,
    err_detail = nil,
  }

  -- -------------------------------------------------------------------------
  -- Reload lock (ADR-005 §2) — only in worker context
  -- -------------------------------------------------------------------------
  local owner_id, lock_err = acquire_reload_lock()
  if not owner_id then
    result.err = lock_err or "reload_in_progress"
    return result
  end

  if opts.on_lock_acquired then
    local hook_ok, proceed, err_code, err_detail = pcall(opts.on_lock_acquired)
    if not hook_ok then
      result.err = "on_lock_acquired hook failed: " .. tostring(proceed)
      log_err(result.err)
      release_reload_lock(owner_id)
      return result
    end
    if proceed == false then
      result.err = err_detail or err_code or "preflight_failed"
      result.err_code = err_code or "preflight_failed"
      result.err_detail = err_detail or result.err
      release_reload_lock(owner_id)
      return result
    end
  end

  -- -------------------------------------------------------------------------
  -- [1] Read
  -- -------------------------------------------------------------------------
  local f, open_err = io.open(filepath, "r")
  if not f then
    result.err = "cannot open policy file '" .. filepath .. "': " .. tostring(open_err)
    log_err(result.err)
    release_reload_lock(owner_id)
    return result
  end

  local content = f:read("*all")
  f:close()

  if not content or #content == 0 then
    result.err = "policy file is empty: " .. filepath
    log_err(result.err)
    release_reload_lock(owner_id)
    return result
  end

  -- -------------------------------------------------------------------------
  -- [2] Parse
  -- -------------------------------------------------------------------------
  local policy, parse_err = parser.parse_string(content)
  if not policy then
    result.err = "policy parse failed: " .. tostring(parse_err)
    log_err(result.err)
    release_reload_lock(owner_id)
    return result
  end

  -- -------------------------------------------------------------------------
  -- [3] Validate (all-or-nothing)
  -- -------------------------------------------------------------------------
  local _, validate_err = validator.validate(policy)
  if validate_err then
    result.err = "policy validation failed: " .. tostring(validate_err)
    log_err(result.err)
    release_reload_lock(owner_id)
    return result
  end

  -- -------------------------------------------------------------------------
  -- [4] Conflict detection (WARN only — does not abort)
  -- -------------------------------------------------------------------------
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
  result.conflicts = conflicts
  result.shadowed = shadowed

  if #conflicts > 0 then
    log_warn("policy loaded with " .. #conflicts .. " conflict(s) and " .. #shadowed .. " shadowed rule(s)")
  end

  -- -------------------------------------------------------------------------
  -- [5] Hash — SHA256 of raw file content (policy-engine.md §4.3)
  -- -------------------------------------------------------------------------
  local new_version, hash_err = sha256_hex(content)
  if not new_version then
    result.err = "SHA256 computation failed: " .. tostring(hash_err)
    log_err(result.err)
    release_reload_lock(owner_id)
    return result
  end
  result.new_version = new_version

  -- -------------------------------------------------------------------------
  -- Same-hash skip: idempotent reload (ADR-003 §3.4)
  -- -------------------------------------------------------------------------
  local dict = get_dict()

  if dict then
    result.previous_http_version = dict:get("http:active_version")
    result.previous_stream_version = dict:get("stream:active_version")

    if result.previous_http_version == new_version and result.previous_stream_version == new_version then
      log_info("policy unchanged (version: " .. new_version .. "), reload skipped")
      result.ok = true
      result.skipped = true
      result.http_ok = true
      result.stream_ok = true

      -- DON-218: Backfill stream:configured on same-hash skip.
      -- Handles upgrade path where flag didn't exist before DON-218.
      if policy.stream_rules and #policy.stream_rules > 0 then
        local cfg_ok, cfg_err = dict:safe_set("stream:configured", true)
        if not cfg_ok then
          log_warn("safe_set stream:configured backfill failed: " .. tostring(cfg_err))
        end
      else
        dict:delete("stream:configured")
      end

      release_reload_lock(owner_id)
      return result
    end
  end

  -- -------------------------------------------------------------------------
  -- [6] Blob store
  -- -------------------------------------------------------------------------
  local blob = build_blob(policy)
  local blob_json, blob_encode_err = json_encode(blob)
  if not blob_json then
    result.err = "blob JSON encode failed: " .. tostring(blob_encode_err)
    log_err(result.err)
    release_reload_lock(owner_id)
    return result
  end

  local meta = build_meta(new_version, policy, conflicts, shadowed)
  local meta_json, meta_encode_err = json_encode(meta)
  if not meta_json then
    result.err = "meta JSON encode failed: " .. tostring(meta_encode_err)
    log_err(result.err)
    release_reload_lock(owner_id)
    return result
  end

  if dict then
    local store_ok, store_err = store_blob(dict, new_version, blob_json, meta_json)
    if not store_ok then
      result.err = "blob store failed: " .. tostring(store_err)
      log_err(result.err)
      release_reload_lock(owner_id)
      return result
    end
  end

  -- -------------------------------------------------------------------------
  -- [7] Commit — HTTP and Stream pointer swap (subsystem-independent)
  -- -------------------------------------------------------------------------
  if dict then
    local commit_result = commit_pointers(dict, new_version)
    result.http_ok = commit_result.http_ok
    result.stream_ok = commit_result.stream_ok
    result.http_err = commit_result.http_err
    result.stream_err = commit_result.stream_err

    if commit_result.http_ok or commit_result.stream_ok then
      result.ok = true
    else
      result.err = "all subsystem pointer swaps failed"
      log_err(result.err)
    end

    -- Record source_version (canonical source SHA256 — ADR-003 §3.3, policy-engine.md §4.3)
    -- Only when BOTH subsystems committed successfully (ADR-005 §1 invariant:
    -- source_version == http_version == stream_version at all times).
    -- Partial commit (one subsystem failed) must NOT update source_version to
    -- prevent ETag / If-Match mismatch on subsequent PUT requests.
    if commit_result.http_ok and commit_result.stream_ok then
      local _, _ = dict:set("source_version", new_version)
      -- ADR-008 §8.2: record policy load timestamp for /health version reporting
      local loaded_at_ok, loaded_at_err = dict:safe_set("policy_loaded_at", ngx.now())
      if not loaded_at_ok then
        log_warn("safe_set policy_loaded_at failed: " .. tostring(loaded_at_err))
      end
    end

    -- DON-218: Update stream:configured flag based on policy declaration.
    -- Setting true: allowed on partial commit (stream is declared in policy).
    -- Clearing: only on full commit (both subsystems ok), because partial
    -- commit means stream LKG may still be active and needs monitoring.
    if commit_result.http_ok or commit_result.stream_ok then
      if policy.stream_rules and #policy.stream_rules > 0 then
        local cfg_ok, cfg_err = dict:safe_set("stream:configured", true)
        if not cfg_ok then
          log_warn("safe_set stream:configured failed: " .. tostring(cfg_err))
        end
      elseif commit_result.http_ok and commit_result.stream_ok then
        dict:delete("stream:configured")
      end
    end
  else
    -- No shared dict (init context without dict, or unit tests without dict stub).
    -- Mark both subsystems as "committed" so callers can proceed.
    result.ok = true
    result.http_ok = true
    result.stream_ok = true
    log_info("no shared dict available, blob not persisted (init/test context)")
  end

  if result.ok then
    log_info(
      "policy reload complete: version="
        .. new_version
        .. " http="
        .. tostring(result.http_ok)
        .. " stream="
        .. tostring(result.stream_ok)
    )
  end

  release_reload_lock(owner_id)
  return result
end

--- Cold-start loader: to be called from init_by_lua_block.
--
-- Wraps load_policy() with fatal error semantics: on failure, logs and
-- re-raises as an error() to abort worker startup (fail-closed).
--
-- Usage in nginx.conf:
--   init_by_lua_block {
--     require("luagate.policy.loader").init_load("conf/policies.yaml")
--   }
--
-- @param  filepath  string  Absolute path to the YAML policy file.
function _M.init_load(filepath)
  local result = _M.load_policy(filepath)

  -- Cold start requires both subsystems to commit successfully.
  -- Unlike POST /reload (which allows partial commit because a last-known-good
  -- exists), init_by_lua has no LKG fallback: partial commit is fatal.
  -- same-hash skip (result.skipped) is treated as success because both
  -- subsystem pointers were already valid before this call.
  local success = result.skipped or (result.http_ok and result.stream_ok)

  if not success then
    local detail = result.err or ("http_ok=" .. tostring(result.http_ok) .. " stream_ok=" .. tostring(result.stream_ok))
    local msg = "[luagate:loader] cold start policy load failed: " .. detail
    -- In init_by_lua context ngx.log is available
    if ngx and ngx.log then
      ngx.log(ngx.ERR, msg)
    end
    error(msg)
  end
  return result
end

--- Check whether a reload is currently in progress.
-- Returns true if the reload_lock key exists in the shared dict.
-- @return boolean
function _M.is_reload_in_progress()
  local dict = get_dict()
  if not dict then
    return false
  end
  return dict:get(RELOAD_LOCK_KEY) ~= nil
end

--- Return the current active versions from the shared dict.
-- @return table  { http_version=string|nil, stream_version=string|nil,
--                  source_version=string|nil }
function _M.get_active_versions()
  local dict = get_dict()
  if not dict then
    return { http_version = nil, stream_version = nil, source_version = nil }
  end
  return {
    http_version = dict:get("http:active_version"),
    stream_version = dict:get("stream:active_version"),
    source_version = dict:get("source_version"),
  }
end

--- Backfill source_version in shared dict when it is nil.
-- Used by the admin PUT handler to fix the source_version gap when
-- result.skipped is true but source_version was never committed
-- (e.g. before the first hot-reload cycle).
-- @param version string  SHA256 hex digest to store
-- @return boolean ok
-- @return string|nil err
function _M.set_source_version(version)
  local dict = get_dict()
  if not dict then
    return false, "no shared dict"
  end
  -- Atomic backfill: dict:add() writes only when key does not exist.
  -- This eliminates the TOCTOU race between get() and safe_set() —
  -- if a concurrent PUT committed a newer source_version between our
  -- reload lock release and this call, add() returns false/"exists"
  -- and the stale hash is never written.
  local ok, err = dict:add("source_version", version)
  if not ok then
    if err == "exists" then
      -- Key already present — another request committed first; no-op.
      return true, nil
    end
    return false, err
  end
  return true, nil
end

return _M
