--- W3C Trace Context parsing and propagation for LuaGate.
-- Implements W3C Trace Context Level 1 traceparent header parsing,
-- trace_id/span_id generation, and outbound header injection.
--
-- ADR-010 §7: W3C Trace Context propagation
--   - Malformed traceparent → ignore, start new trace (no error log)
--   - All-zero trace_id or span_id → invalid, start new trace
--   - tracestate: pass-through when inbound traceparent valid, drop otherwise
--
-- Implementation: lua/luagate/tracing/context.lua

local _M = {}

-- Random hex generation: use OpenSSL RAND_bytes via FFI when available,
-- fallback to math.random for non-OpenResty test environments.
local random_hex

local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then
  local cdef_ok = pcall(
    ffi.cdef,
    [[
        int RAND_bytes(unsigned char *buf, int num);
    ]]
  )

  if cdef_ok then
    local rand_buf = ffi.new("unsigned char[16]")
    local C = ffi.C

    -- Test if RAND_bytes is actually callable
    local call_ok = pcall(function()
      C.RAND_bytes(rand_buf, 1)
    end)

    if call_ok then
      random_hex = function(num_bytes)
        local buf = (num_bytes == 16) and rand_buf or ffi.new("unsigned char[?]", num_bytes)
        C.RAND_bytes(buf, num_bytes)
        local hex = {}
        for i = 0, num_bytes - 1 do
          hex[i + 1] = string.format("%02x", buf[i])
        end
        return table.concat(hex)
      end
    end
  end
end

if not random_hex then
  -- Fallback: math.random (not cryptographically secure, for dev/test only)
  random_hex = function(num_bytes)
    local hex = {}
    for i = 1, num_bytes do
      hex[i] = string.format("%02x", math.random(0, 255))
    end
    return table.concat(hex)
  end
end

local ALL_ZERO_TRACE_ID = string.rep("0", 32)
local ALL_ZERO_SPAN_ID = string.rep("0", 16)

--- Parse a W3C traceparent header value.
-- Format: version-trace_id-parent_id-trace_flags (e.g. "00-<32hex>-<16hex>-01")
-- ADR-010 §7: malformed → return nil (caller starts new trace)
-- @param header string|nil  Raw traceparent header value
-- @return table|nil  { trace_id, parent_id, sampled } or nil if invalid
function _M.parse_traceparent(header)
  if not header then
    return nil
  end

  -- Duplicate headers: use first value (HTTP standard)
  if type(header) == "table" then
    header = header[1]
    if not header then
      return nil
    end
  end

  if type(header) ~= "string" then
    return nil
  end

  -- Match: version(2hex)-trace_id(32hex)-parent_id(16hex)-flags(2hex)
  local version, trace_id, parent_id, flags = header:match("^(%x%x)%-(%x+)%-(%x+)%-(%x%x)$")

  if not version then
    return nil
  end

  -- W3C Trace Context Level 1: only version "00" is supported.
  -- Unknown/future versions (e.g. "ff") must be rejected per spec.
  if version ~= "00" then
    return nil
  end

  -- Validate lengths
  if #trace_id ~= 32 or #parent_id ~= 16 then
    return nil
  end

  -- All-zero trace_id or span_id → invalid (W3C spec)
  trace_id = trace_id:lower()
  parent_id = parent_id:lower()

  if trace_id == ALL_ZERO_TRACE_ID or parent_id == ALL_ZERO_SPAN_ID then
    return nil
  end

  -- Parse sampled flag (bit 0 of flags)
  local flags_num = tonumber(flags, 16)
  local sampled = (flags_num % 2) == 1

  return {
    trace_id = trace_id,
    parent_id = parent_id,
    sampled = sampled,
  }
end

--- Generate a new trace_id (128-bit / 32 hex chars).
-- @return string  32-char lowercase hex
function _M.new_trace_id()
  return random_hex(16)
end

--- Generate a new span_id (64-bit / 16 hex chars).
-- @return string  16-char lowercase hex
function _M.new_span_id()
  return random_hex(8)
end

--- Build a traceparent header value.
-- @param trace_id string  32-char hex
-- @param span_id  string  16-char hex
-- @param sampled  boolean
-- @return string  e.g. "00-<trace_id>-<span_id>-01"
function _M.build_traceparent(trace_id, span_id, sampled)
  local flags = sampled and "01" or "00"
  return "00-" .. trace_id .. "-" .. span_id .. "-" .. flags
end

return _M
