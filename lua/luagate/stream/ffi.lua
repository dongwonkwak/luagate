--- LuaGate stream FFI binding.
-- Wraps luagate_stream.so (src/stream/) for protocol detection, SNI
-- extraction, and CIDR radix tree operations.
--
-- ABI contract: docs/spec/rust-ffi-modules.md §6
--
-- Memory management:
--   - detect_protocol / extract_sni: caller-allocated buffers (GC-managed).
--     No free function needed.
--   - radix_build / radix_lookup / radix_free: Rust-allocated opaque pointer.
--     Caller MUST call radix_free() when the tree is no longer needed.
--     ffi.gc is used for automatic cleanup as a safety net.
--
-- Usage:
--   local stream_ffi = require("luagate.stream.ffi")
--   local proto, err = stream_ffi.detect_protocol(preread_data)
--   local sni, err = stream_ffi.extract_sni(preread_data)
--   local tree, err = stream_ffi.radix_build("10.0.0.0/8,0\n192.168.0.0/16,1\n")
--   local rule_idx, err = stream_ffi.radix_lookup(tree, "10.1.2.3")
--   stream_ffi.radix_free(tree)

local ffi = require("ffi")

ffi.cdef([[
typedef struct LuagateRadix luagate_radix_t;

int luagate_detect_protocol(
    const char *buf, size_t buf_len,
    char *protocol_out, size_t protocol_cap, size_t *protocol_len
);

int luagate_extract_sni(
    const char *buf, size_t buf_len,
    char *out, size_t out_cap, size_t *out_len
);

int luagate_radix_build(
    const char *cidr_list, size_t cidr_list_len,
    luagate_radix_t **tree_out
);

int luagate_radix_lookup(
    const luagate_radix_t *tree,
    const char *ip_str, size_t ip_str_len,
    uint32_t *matched_rule_index_out
);

int luagate_radix_free(luagate_radix_t *tree);
]])

-- Load the shared library with package.loaded caching.
-- Same pattern as scanner/ffi.lua and decoder/ffi.lua.
local lib = package.loaded["_luagate_stream_lib"]
if not lib then
  lib = ffi.load("luagate_stream") -- error() on failure -> startup-fatal
  package.loaded["_luagate_stream_lib"] = lib
end

-- Error code constants
local LUAGATE_OK = 0
local LUAGATE_NEED_MORE_DATA = 1
local LUAGATE_INVALID_INPUT = -1
local LUAGATE_BUFFER_TOO_SMALL = -2

-- Output buffer capacities
local PROTOCOL_BUF_CAP = 16
local SNI_BUF_CAP = 256

local M = {}

--- Detect protocol from preread buffer data.
--
-- @param data  string  Raw bytes from preread buffer
-- @return protocol  string|nil  "tls", "http", or "raw" on success; nil on error
-- @return err       nil|string  Error token or nil
-- @return need_more boolean     true if NEED_MORE_DATA (caller should retry after reading more)
function M.detect_protocol(data)
  if type(data) ~= "string" then
    return nil, "invalid_argument"
  end

  local proto_buf = ffi.new("char[?]", PROTOCOL_BUF_CAP)
  local proto_len = ffi.new("size_t[1]")

  local ok, rc = pcall(function()
    return lib.luagate_detect_protocol(data, #data, proto_buf, PROTOCOL_BUF_CAP, proto_len)
  end)

  if not ok then
    return nil, "stream_ffi_error:" .. tostring(rc)
  end

  if rc == LUAGATE_NEED_MORE_DATA then
    return nil, nil, true
  end

  if rc == LUAGATE_INVALID_INPUT then
    return nil, "invalid_input"
  end

  if rc ~= LUAGATE_OK then
    return nil, "stream_fail:" .. rc
  end

  local protocol = ffi.string(proto_buf, proto_len[0])
  return protocol, nil, false
end

--- Extract SNI from TLS ClientHello in preread buffer.
--
-- @param data  string  Raw bytes (must start with TLS record header)
-- @return sni       string|nil  Server name or "" if no SNI; nil on error
-- @return err       nil|string  Error token or nil
-- @return need_more boolean     true if NEED_MORE_DATA
function M.extract_sni(data)
  if type(data) ~= "string" then
    return nil, "invalid_argument"
  end

  local sni_buf = ffi.new("char[?]", SNI_BUF_CAP)
  local sni_len = ffi.new("size_t[1]")

  local ok, rc = pcall(function()
    return lib.luagate_extract_sni(data, #data, sni_buf, SNI_BUF_CAP, sni_len)
  end)

  if not ok then
    return nil, "stream_ffi_error:" .. tostring(rc)
  end

  if rc == LUAGATE_NEED_MORE_DATA then
    return nil, nil, true
  end

  if rc == LUAGATE_INVALID_INPUT then
    return nil, "invalid_input"
  end

  if rc == LUAGATE_BUFFER_TOO_SMALL then
    return nil, "sni_buffer_too_small"
  end

  if rc ~= LUAGATE_OK then
    return nil, "stream_fail:" .. rc
  end

  local sni = (sni_len[0] > 0) and ffi.string(sni_buf, sni_len[0]) or ""
  return sni, nil, false
end

--- Build a CIDR radix tree for IP lookups.
--
-- @param cidr_list  string  Newline-separated "CIDR,rule_index" entries
-- @return tree      cdata|nil  Opaque tree pointer (must call radix_free when done)
-- @return err       nil|string  Error token
function M.radix_build(cidr_list)
  if type(cidr_list) ~= "string" then
    return nil, "invalid_argument"
  end

  local tree_ptr = ffi.new("luagate_radix_t*[1]")

  local ok, rc = pcall(function()
    return lib.luagate_radix_build(cidr_list, #cidr_list, tree_ptr)
  end)

  if not ok then
    return nil, "stream_ffi_error:" .. tostring(rc)
  end

  if rc ~= LUAGATE_OK then
    return nil, "radix_build_fail:" .. rc
  end

  -- Register automatic GC cleanup as safety net (FFI free obligation).
  -- Caller should still call radix_free() explicitly for deterministic cleanup.
  local tree = ffi.gc(tree_ptr[0], lib.luagate_radix_free)
  return tree, nil
end

--- Look up an IP address in a radix tree.
--
-- @param tree   cdata   Opaque tree pointer from radix_build()
-- @param ip_str string  IPv4 address string (e.g. "10.1.2.3")
-- @return rule_index  number|nil  Matched rule index, or nil if no match
-- @return err         nil|string  Error token
function M.radix_lookup(tree, ip_str)
  if tree == nil or type(ip_str) ~= "string" then
    return nil, "invalid_argument"
  end

  local rule_idx = ffi.new("uint32_t[1]")

  local ok, rc = pcall(function()
    return lib.luagate_radix_lookup(tree, ip_str, #ip_str, rule_idx)
  end)

  if not ok then
    return nil, "stream_ffi_error:" .. tostring(rc)
  end

  if rc ~= LUAGATE_OK then
    return nil, "radix_lookup_fail:" .. rc
  end

  local idx = rule_idx[0]
  if idx == 0xFFFFFFFF then
    return nil, nil -- no match (not an error)
  end

  return tonumber(idx), nil
end

--- Free a radix tree.
-- After calling this, the tree pointer must not be used.
-- Safe to call with nil.
--
-- @param tree  cdata|nil  Opaque tree pointer
function M.radix_free(tree)
  if tree == nil then
    return
  end
  -- Detach GC so we don't double-free, then explicitly free
  pcall(function()
    ffi.gc(tree, nil) -- remove GC destructor
    lib.luagate_radix_free(tree)
  end)
end

return M
