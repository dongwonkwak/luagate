--- Scanner worker module — cross-worker pattern synchronization (ADR-014 §5).
--
-- Registers a 1-second periodic timer in init_worker_by_lua to poll
-- shared dict scanner:active_version changes and trigger per-worker
-- luagate_scanner_reload() via the FFI binding.
--
-- Design rules:
--   - Timer runs in every worker, but only calls reload when version differs
--   - Module-level upvalue _local_scanner_version (not ngx.ctx — invariant)
--   - Uses ngx.worker.id() per AGENTS.md invariant
--   - Fail-closed: reload failure preserves LKG, logs WARN
--   - Blocking I/O: none (FFI reload reads files in Rust, not Lua)
--
-- Implementation: lua/luagate/scanner/worker.lua
-- Tests: tests/unit/scanner/worker_spec.lua

local _M = {}

-- Module-level upvalue: current scanner version for this worker.
-- Compared against shared dict scanner:active_version each timer tick.
local _local_scanner_version = nil

-- Patterns directory path, set during init_worker().
local _patterns_dir = nil

-- Shared dict name for scanner pattern metadata (ADR-014 §4).
local SCANNER_DICT_NAME = "luagate_scanner_patterns"

-- Timer interval in seconds (ADR-014 §5).
local CHECK_INTERVAL = 1

--- Timer callback: check shared dict version and reload if changed.
-- @param premature boolean  true when Nginx is shutting down
local function check_version(premature)
  if premature then
    return
  end

  local dict = ngx.shared[SCANNER_DICT_NAME]
  if not dict then
    return
  end

  local active_version = dict:get("scanner:active_version")
  if not active_version then
    -- No version in shared dict yet (scanner not loaded via Admin API)
    return
  end

  if active_version == _local_scanner_version then
    -- Version unchanged — no reload needed
    return
  end

  -- Version changed — reload patterns in this worker
  local scanner_ffi = require("luagate.scanner.ffi")
  local result, err = scanner_ffi.reload(_patterns_dir)
  if not result then
    ngx.log(
      ngx.WARN,
      "[luagate:scanner:worker] reload failed on worker ",
      ngx.worker.id(),
      ": ",
      tostring(err),
      " (LKG preserved)"
    )
    return
  end

  _local_scanner_version = active_version
  ngx.log(
    ngx.INFO,
    "[luagate:scanner:worker] worker ",
    ngx.worker.id(),
    " reloaded patterns: version=",
    result.version,
    " count=",
    result.pattern_count
  )
end

--- Initialise the scanner worker timer.
-- Must be called from init_worker_by_lua_block.
--
-- @param patterns_dir string  Path to scanner-patterns directory
function _M.init_worker(patterns_dir)
  _patterns_dir = patterns_dir or "conf/scanner-patterns"

  -- Read current version from shared dict to initialise local state.
  -- At this point, luagate_scanner_init() has already completed in
  -- init_by_lua, so no additional reload is needed.
  local dict = ngx.shared[SCANNER_DICT_NAME]
  if dict then
    _local_scanner_version = dict:get("scanner:active_version")
  end

  -- Register periodic timer (ADR-014 §5)
  local ok, err = ngx.timer.every(CHECK_INTERVAL, check_version)
  if not ok then
    ngx.log(ngx.ERR, "[luagate:scanner:worker] failed to create version check timer: ", tostring(err))
  end
end

--- Get the current local scanner version for this worker.
-- Exposed for testing and diagnostics.
-- @return string|nil
function _M.get_local_version()
  return _local_scanner_version
end

--- Set the local version (for testing only).
-- @param version string|nil
function _M._set_local_version(version)
  _local_scanner_version = version
end

return _M
