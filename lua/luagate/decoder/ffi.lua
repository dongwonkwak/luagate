--- luagate.decoder.ffi — LuaJIT FFI binding for luagate_decoder.so
--
-- ABI contract (docs/spec/rust-ffi-modules.md §5):
--   - caller-allocated output buffers (no Rust malloc returned)
--   - pcall wrapping at call site (rust-ffi-guide.md)
--   - fail semantics: BUDGET_EXCEEDED / INTERNAL_ERROR → nil, "ffi_fail:<rc>"
--   - INVALID_INPUT (-1): decode_partial — partial result returned, no error
--   - 1 buffer-too-small retry (2x capacity)
--
-- Memory management:
--   ffi.new("char[?]", cap) buffers are GC-managed by LuaJIT.
--   No Rust-allocated memory is returned to the caller; no free() call needed.
--
-- Usage:
--   local decoder = require("luagate.decoder.ffi")
--   local path, err, partial = decoder.normalize_path(ngx.var.luagate_path_raw)
--   local query, err = decoder.normalize_query(ngx.var.args or "")
--   local nfkc, err = decoder.normalize_nfkc(some_string)

local ffi = require("ffi")

ffi.cdef([[
int luagate_normalize_path(
    const char *path_raw, size_t path_raw_len,
    char *out, size_t out_cap, size_t *out_len
);
int luagate_normalize_query(
    const char *query_raw, size_t query_raw_len,
    char *out, size_t out_cap, size_t *out_len
);
int luagate_normalize_nfkc(
    const char *input, size_t input_len,
    char *out, size_t out_cap, size_t *out_len
);
]])

-- Library handle: loaded once per worker and cached in package.loaded.
--
-- Design rationale (ADR-001): .so load failure must be startup-fatal.
-- By checking package.loaded["_luagate_decoder_lib"] first we support two
-- patterns:
--   1. init_by_lua calls require("luagate.decoder.ffi") early → ffi.load
--      executes at server-start time; failure aborts nginx startup.
--   2. Subsequent require() calls in workers reuse the cached handle without
--      a second ffi.load.
--
-- ffi.load raises a Lua error on failure, which propagates through require()
-- and, if called from init_by_lua, causes Nginx to refuse to start.
local lib = package.loaded["_luagate_decoder_lib"]
if not lib then
  lib = ffi.load("luagate_decoder") -- error() on failure → startup-fatal
  package.loaded["_luagate_decoder_lib"] = lib
end

-- ── Error code constants ────────────────────────────────────────────────────
local LUAGATE_OK = 0
local LUAGATE_BUFFER_TOO_SMALL = -2
local LUAGATE_BUDGET_EXCEEDED = -3
local LUAGATE_INTERNAL_ERROR = -4
local LUAGATE_TIMEOUT = -5

--- Increment per-worker FFI timeout leak counter in shared dict.
-- ADR-009 Layer 2: tracks detached watchdog threads per worker.
-- Uses ngx.worker.id() per AGENTS.md invariant.
local function incr_timeout_leak(module_name)
  local dict = ngx.shared.luagate_metrics
  if dict then
    local wid = ngx.worker.id()
    dict:incr("ffi:timeout:leak:" .. wid, 1, 0)
    dict:incr("ffi:timeout:" .. module_name .. ":" .. wid, 1, 0)
  end
end

-- Initial output buffer capacity (4 KB).
-- Most URLs fit within this; the retry path doubles it once.
local INIT_BUF_CAP = 4096

-- ── Internal helper ──────────────────────────────────────────────────────────

--- Call a decoder FFI function with caller-allocated buffer and 1-retry logic.
--
-- @param fn          FFI function pointer (lib.luagate_normalize_*)
-- @param input       Lua string — kept alive until after fn() returns
-- @param input_len   #input (pre-computed by callers)
-- @return result     string | nil   decoded output (partial on INVALID_INPUT)
-- @return err        nil | string   "ffi_fail:<rc>" on hard errors
-- @return partial    bool           true when rc == LUAGATE_INVALID_INPUT
local function call_with_retry(fn, input, input_len)
  local cap = math.max(INIT_BUF_CAP, input_len * 2)
  local buf = ffi.new("char[?]", cap)
  local out_len = ffi.new("size_t[1]")

  local rc = fn(input, input_len, buf, cap, out_len)

  if rc == LUAGATE_BUFFER_TOO_SMALL then
    -- One retry with doubled buffer
    cap = cap * 2
    buf = ffi.new("char[?]", cap)
    out_len[0] = 0
    rc = fn(input, input_len, buf, cap, out_len)
  end

  -- ADR-009 Layer 2: hard timeout from watchdog thread
  if rc == LUAGATE_TIMEOUT then
    ngx.log(ngx.ERR, "decoder FFI hard timeout exceeded (Layer 2 watchdog)")
    incr_timeout_leak("decoder")
    return nil, "ffi_timeout"
  end

  -- Hard failures: budget exceeded, internal error, or buffer still too small after retry
  if rc == LUAGATE_BUDGET_EXCEEDED or rc == LUAGATE_INTERNAL_ERROR or rc == LUAGATE_BUFFER_TOO_SMALL then
    return nil, "ffi_fail:" .. rc
  end

  -- rc == LUAGATE_OK (0)             → full success
  -- rc == LUAGATE_INVALID_INPUT (-1) → partial/decode_partial success
  local result = ffi.string(buf, out_len[0])
  local partial = (rc ~= LUAGATE_OK)
  return result, nil, partial
end

-- ── Public API ───────────────────────────────────────────────────────────────

local M = {}

--- Normalize a URL path.
--
-- Applies: percent-decode → segment normalization (.. / .) → NFKC → control removal.
--
-- @param  path_raw  string  raw URL path (e.g. ngx.var.luagate_path_raw)
-- @return result    string | nil   normalized path; nil on hard FFI error
-- @return err       nil | string   error token (e.g. "ffi_fail:-3")
-- @return partial   bool           true if input had invalid percent-sequences
function M.normalize_path(path_raw)
  if type(path_raw) ~= "string" then
    return nil, "invalid_argument"
  end
  local ok, result, err, partial = pcall(call_with_retry, lib.luagate_normalize_path, path_raw, #path_raw)
  if not ok then
    -- pcall caught a Lua-level error from the FFI call
    return nil, "ffi_panic:" .. tostring(result)
  end
  return result, err, partial
end

--- Normalize a query string.
--
-- Applies: split on '&' → per-pair key/value percent-decode (+ → space) → reassemble.
--
-- @param  query_raw  string  raw query string (e.g. ngx.var.args or "")
-- @return result     string | nil
-- @return err        nil | string
-- @return partial    bool
function M.normalize_query(query_raw)
  if type(query_raw) ~= "string" then
    return nil, "invalid_argument"
  end
  local ok, result, err, partial = pcall(call_with_retry, lib.luagate_normalize_query, query_raw, #query_raw)
  if not ok then
    return nil, "ffi_panic:" .. tostring(result)
  end
  return result, err, partial
end

--- Apply NFKC Unicode normalization to an arbitrary string.
--
-- @param  input   string  UTF-8 input
-- @return result  string | nil
-- @return err     nil | string
-- @return partial bool   true if input contained invalid UTF-8 sequences
function M.normalize_nfkc(input)
  if type(input) ~= "string" then
    return nil, "invalid_argument"
  end
  local ok, result, err, partial = pcall(call_with_retry, lib.luagate_normalize_nfkc, input, #input)
  if not ok then
    return nil, "ffi_panic:" .. tostring(result)
  end
  return result, err, partial
end

return M
