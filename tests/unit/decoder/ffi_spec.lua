--- tests/unit/decoder/ffi_spec.lua
--
-- Unit tests for lua/luagate/decoder/ffi.lua public API contract.
--
-- These tests run without a real luagate_decoder.so by injecting a stub
-- implementation via package.preload.  The tests verify:
--   1. Return-value shape (string, nil-err, bool partial)
--   2. Error propagation for hard failures (ffi_fail:*)
--   3. Partial-decode semantics (rc == INVALID_INPUT → result + partial=true)
--   4. Invalid-argument guard (non-string input)
--
-- Integration tests that exercise the real .so live in tests/integration/.

-- ── Stub ffi module ──────────────────────────────────────────────────────────
-- We override package.preload["ffi"] before requiring the module under test so
-- that ffi.load() returns our controlled stub library table.

local ffi_stub

-- Track what the module called
local calls = {}

-- Mock library with controllable behaviour per test
local mock_lib = {}

-- Stub ffi cdef, new, string, load
ffi_stub = {
  cdef = function() end,

  -- ffi.new returns a plain Lua table acting as a buffer stub.
  -- We encode the "written content" as a special field.
  new = function(ct, n)
    if ct == "size_t[1]" then
      -- out_len slot: behaves as an array with [0]
      local t = {}
      setmetatable(t, {
        __index = function(_, k)
          if k == 0 then
            return rawget(t, "_v") or 0
          end
        end,
        __newindex = function(_, k, v)
          if k == 0 then
            rawset(t, "_v", v)
          end
        end,
      })
      t[0] = 0
      return t
    end
    -- char[?] buffer stub
    return { _type = "char_buf", _cap = n or 0, _data = nil }
  end,

  -- ffi.string(buf, len) → return the _data stored by the mock fn
  string = function(buf, _len)
    if type(buf) == "table" and buf._data then
      return buf._data
    end
    return ""
  end,

  load = function(_name)
    return mock_lib
  end,
}

-- Install the ffi stub before the module is loaded
package.preload["ffi"] = function()
  return ffi_stub
end

-- Clear any cached module state between test runs
package.loaded["luagate.decoder.ffi"] = nil

-- ── Helper to build a mock FFI function ─────────────────────────────────────

--- Create a mock FFI function that writes `output` into the out buffer and
--- returns `rc`.
--
-- @param output  string   bytes to "write"
-- @param rc      number   return code
local function make_mock_fn(output, rc)
  return function(_input, _input_len, out_buf, _out_cap, out_len_slot)
    table.insert(calls, { output = output, rc = rc })
    -- Simulate writing output into the buffer
    if out_buf and type(out_buf) == "table" then
      out_buf._data = output
    end
    if out_len_slot then
      out_len_slot[0] = #output
    end
    return rc
  end
end

-- ── Tests ────────────────────────────────────────────────────────────────────

describe("luagate.decoder.ffi", function()
  local decoder

  before_each(function()
    -- Reset call log and module cache
    calls = {}
    package.loaded["luagate.decoder.ffi"] = nil
    decoder = require("luagate.decoder.ffi")
  end)

  -- ── normalize_path ───────────────────────────────────────────────────────

  describe("normalize_path", function()
    it("returns a string and nil error on LUAGATE_OK", function()
      mock_lib.luagate_normalize_path = make_mock_fn("/foo/bar", 0)
      local result, err, partial = decoder.normalize_path("/foo%2Fbar")
      assert.is_string(result)
      assert.is_nil(err)
      assert.is_false(partial or false)
    end)

    it("returns partial=true on LUAGATE_INVALID_INPUT (-1)", function()
      mock_lib.luagate_normalize_path = make_mock_fn("/foo_bar", -1)
      local result, err, partial = decoder.normalize_path("/foo%GGbar")
      assert.is_string(result)
      assert.is_nil(err)
      assert.is_true(partial)
    end)

    it("retries once on LUAGATE_BUFFER_TOO_SMALL (-2) then succeeds", function()
      local call_count = 0
      mock_lib.luagate_normalize_path = function(_i, _il, out_buf, _cap, out_len_slot)
        call_count = call_count + 1
        if call_count == 1 then
          -- first call: signal too small
          return -2
        end
        -- second call: succeed
        if out_buf and type(out_buf) == "table" then
          out_buf._data = "/foo/bar"
        end
        if out_len_slot then
          out_len_slot[0] = 8
        end
        return 0
      end
      local result, err = decoder.normalize_path("/foo%2Fbar")
      assert.equals(2, call_count)
      assert.is_nil(err)
      assert.is_string(result)
    end)

    it("returns nil + ffi_fail error on LUAGATE_BUDGET_EXCEEDED (-3)", function()
      mock_lib.luagate_normalize_path = make_mock_fn("", -3)
      local result, err = decoder.normalize_path("/slow")
      assert.is_nil(result)
      assert.is_string(err)
      assert.truthy(err:find("ffi_fail"))
    end)

    it("returns nil + ffi_fail error on LUAGATE_INTERNAL_ERROR (-4)", function()
      mock_lib.luagate_normalize_path = make_mock_fn("", -4)
      local result, err = decoder.normalize_path("/bad")
      assert.is_nil(result)
      assert.is_string(err)
      assert.truthy(err:find("ffi_fail"))
    end)

    it("returns nil + invalid_argument for non-string input", function()
      local result, err = decoder.normalize_path(nil)
      assert.is_nil(result)
      assert.equals("invalid_argument", err)
    end)

    it("returns nil + invalid_argument for number input", function()
      local result, err = decoder.normalize_path(123)
      assert.is_nil(result)
      assert.equals("invalid_argument", err)
    end)
  end)

  -- ── normalize_query ──────────────────────────────────────────────────────

  describe("normalize_query", function()
    it("returns string and nil error for simple key=value pair", function()
      mock_lib.luagate_normalize_query = make_mock_fn("a=1&b=hello world", 0)
      local result, err = decoder.normalize_query("a=1&b=hello%20world")
      assert.is_string(result)
      assert.is_nil(err)
    end)

    it("returns partial=true on LUAGATE_INVALID_INPUT", function()
      mock_lib.luagate_normalize_query = make_mock_fn("q=partial", -1)
      local result, err, partial = decoder.normalize_query("q=%GG")
      assert.is_string(result)
      assert.is_nil(err)
      assert.is_true(partial)
    end)

    it("returns nil + ffi_fail on LUAGATE_BUDGET_EXCEEDED", function()
      mock_lib.luagate_normalize_query = make_mock_fn("", -3)
      local result, err = decoder.normalize_query("a=1")
      assert.is_nil(result)
      assert.truthy(err and err:find("ffi_fail"))
    end)

    it("returns nil + invalid_argument for non-string input", function()
      local result, err = decoder.normalize_query(false)
      assert.is_nil(result)
      assert.equals("invalid_argument", err)
    end)

    it("handles empty string input", function()
      mock_lib.luagate_normalize_query = make_mock_fn("", 0)
      local result, err = decoder.normalize_query("")
      assert.is_string(result)
      assert.is_nil(err)
    end)
  end)

  -- ── normalize_nfkc ───────────────────────────────────────────────────────

  describe("normalize_nfkc", function()
    it("returns string and nil error on valid UTF-8", function()
      mock_lib.luagate_normalize_nfkc = make_mock_fn("A", 0)
      local result, err = decoder.normalize_nfkc("\xef\xbc\xa1") -- U+FF21 full-width A
      assert.is_string(result)
      assert.is_nil(err)
    end)

    it("returns partial=true on invalid UTF-8 bytes", function()
      mock_lib.luagate_normalize_nfkc = make_mock_fn("partial", -1)
      local result, err, partial = decoder.normalize_nfkc("\xff\xfe invalid")
      assert.is_string(result)
      assert.is_nil(err)
      assert.is_true(partial)
    end)

    it("returns nil + ffi_fail on LUAGATE_INTERNAL_ERROR", function()
      mock_lib.luagate_normalize_nfkc = make_mock_fn("", -4)
      local result, err = decoder.normalize_nfkc("test")
      assert.is_nil(result)
      assert.truthy(err and err:find("ffi_fail"))
    end)

    it("returns nil + invalid_argument for non-string input", function()
      local result, err = decoder.normalize_nfkc(42)
      assert.is_nil(result)
      assert.equals("invalid_argument", err)
    end)

    it("handles empty string", function()
      mock_lib.luagate_normalize_nfkc = make_mock_fn("", 0)
      local result, err = decoder.normalize_nfkc("")
      assert.is_string(result)
      assert.is_nil(err)
    end)
  end)

  -- ── pcall safety ─────────────────────────────────────────────────────────

  describe("pcall safety", function()
    it("returns ffi_panic if FFI function raises a Lua error", function()
      mock_lib.luagate_normalize_path = function()
        error("simulated FFI crash")
      end
      local result, err = decoder.normalize_path("/test")
      assert.is_nil(result)
      assert.is_string(err)
      assert.truthy(err:find("ffi_panic"))
    end)
  end)
end)
