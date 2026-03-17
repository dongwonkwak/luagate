--- LuaGate scanner FFI binding.
-- Wraps luagate_scanner.so (src/scanner/) for threat detection.
--
-- ABI contract: docs/spec/c-ffi-modules.md §4
-- Caller-allocated buffer pattern — no Rust-owned memory is returned, so
-- there is no free function to call (unlike the decoder module).
--
-- Usage:
--   local scanner = require("luagate.scanner.ffi")
--   local ok, err = scanner.init("/etc/luagate/scanner-patterns")
--   local result, err = scanner.scan({
--       path_raw        = ngx.var.request_uri,
--       path_normalized = ngx.ctx.luagate.path_normalized,
--       query_raw       = ngx.var.query_string or "",
--       query_normalized = ngx.ctx.luagate.query_normalized or "",
--   })

local ffi = require("ffi")

ffi.cdef([[
int luagate_scan_http(
    const char *path_raw,         size_t path_raw_len,
    const char *path_normalized,  size_t path_normalized_len,
    const char *query_raw,        size_t query_raw_len,
    const char *query_normalized, size_t query_normalized_len,
    const char *body,             size_t body_len,
    char *threat_type_out,  size_t threat_type_cap,  size_t *threat_type_len,
    char *rule_name_out,    size_t rule_name_cap,     size_t *rule_name_len,
    double *score_out
);
int luagate_scanner_init(const char *patterns_path, size_t patterns_path_len);
]])

-- Load the shared library.  ffi.load resolves via LD_LIBRARY_PATH / RPATH.
-- This module-level load happens once per worker (LuaJIT module cache).
local lib = ffi.load("luagate_scanner")

-- Caller-allocated output buffer capacities (bytes).
-- Must be >= the longest possible threat_type / rule_name string in lib.rs.
local THREAT_BUF_CAP = 64
local RULE_BUF_CAP = 128

local M = {}

--- Scan an HTTP request for threats.
--
-- @param ctx table with fields:
--   path_raw        (string, required)
--   path_normalized (string, required)
--   query_raw       (string, optional — defaults to "")
--   query_normalized(string, optional — defaults to "")
--   body            (string, optional — MVP: body scanning skipped when nil)
--
-- @return result table { threat_type, rule_name, threat_score } on success,
--         or nil + error string on failure.
--         result.threat_type is nil when no threat is detected.
function M.scan(ctx)
  -- Allocate caller-owned buffers on each call (stack-like, short-lived).
  local threat_buf = ffi.new("char[?]", THREAT_BUF_CAP)
  local rule_buf = ffi.new("char[?]", RULE_BUF_CAP)
  local threat_len = ffi.new("size_t[1]")
  local rule_len = ffi.new("size_t[1]")
  local score = ffi.new("double[1]")

  -- Resolve optional fields to safe defaults before passing to C.
  local path_raw = ctx.path_raw or ""
  local path_norm = ctx.path_normalized or ""
  local query_raw = ctx.query_raw or ""
  local query_norm = ctx.query_normalized or ""
  -- body: pass NULL pointer when not provided (MVP: body_len=0 skips body).
  local body_ptr = ctx.body or nil
  local body_len = ctx.body and #ctx.body or 0

  local ok, rc = pcall(function()
    return lib.luagate_scan_http(
      path_raw,
      #path_raw,
      path_norm,
      #path_norm,
      query_raw,
      #query_raw,
      query_norm,
      #query_norm,
      body_ptr,
      body_len,
      threat_buf,
      THREAT_BUF_CAP,
      threat_len,
      rule_buf,
      RULE_BUF_CAP,
      rule_len,
      score
    )
  end)

  if not ok then
    -- pcall caught a LuaJIT FFI exception (e.g. bad ctype).
    -- Fail-closed per security policy.
    return nil, "scanner_ffi_error:" .. tostring(rc)
  end

  -- rc == -2: LUAGATE_BUFFER_TOO_SMALL  (threat detected but output buffer too small)
  -- rc == -3: LUAGATE_BUDGET_EXCEEDED
  -- rc == -4: LUAGATE_INTERNAL_ERROR
  if rc == -2 or rc == -3 or rc == -4 then
    return nil, "scanner_fail:" .. rc
  end

  -- Decode caller-allocated buffers into Lua strings immediately so the
  -- cdata buffers can be reclaimed by the GC.
  local threat_type = (threat_len[0] > 0) and ffi.string(threat_buf, threat_len[0]) or nil
  local rule_name = (rule_len[0] > 0) and ffi.string(rule_buf, rule_len[0]) or nil

  return {
    threat_type = threat_type,
    rule_name = rule_name,
    threat_score = score[0],
  }, nil
end

--- Initialise the scanner with optional pattern directory.
--
-- Must be called once from init_by_lua before any scan() calls.
-- Calling with patterns_path = nil or "" uses built-in hardcoded patterns.
--
-- @param patterns_path string|nil  Path to YAML pattern directory.
-- @return true on success, or false + error string on failure.
function M.init(patterns_path)
  local path = patterns_path or ""
  local ok, rc = pcall(function()
    return lib.luagate_scanner_init(path, #path)
  end)
  if not ok then
    return false, "scanner_init_ffi_error:" .. tostring(rc)
  end
  if rc ~= 0 then
    return false, "scanner_init_failed:" .. rc
  end
  return true, nil
end

return M
