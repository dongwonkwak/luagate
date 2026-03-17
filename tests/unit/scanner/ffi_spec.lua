-- tests/unit/scanner/ffi_spec.lua
--
-- Unit tests for lua/luagate/scanner/ffi.lua public API contract.
--
-- These tests run without a real luagate_scanner.so by injecting a stub ffi
-- module before requiring the module under test. This verifies the actual
-- Lua binding logic:
--   1. FFI argument wiring and length propagation
--   2. Optional-field defaults and body handling
--   3. Return-code / pcall error propagation
--   4. package.loaded lib caching

local ffi_load_count = 0
local scan_calls = {}
local init_calls = {}
local mock_lib = {}

local ffi_stub = {
  cdef = function() end,

  new = function(ct, n)
    if ct == "size_t[1]" then
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

    if ct == "double[1]" then
      local t = {}
      setmetatable(t, {
        __index = function(_, k)
          if k == 0 then
            return rawget(t, "_v") or 0.0
          end
        end,
        __newindex = function(_, k, v)
          if k == 0 then
            rawset(t, "_v", v)
          end
        end,
      })
      t[0] = 0.0
      return t
    end

    return { _type = "char_buf", _cap = n or 0, _data = nil }
  end,

  string = function(buf, _len)
    if type(buf) == "table" and buf._data then
      return buf._data
    end
    return ""
  end,

  load = function(_name)
    ffi_load_count = ffi_load_count + 1
    return mock_lib
  end,
}

package.preload["ffi"] = function()
  return ffi_stub
end

local function reset_state()
  ffi_load_count = 0
  scan_calls = {}
  init_calls = {}
  mock_lib = {}
  package.loaded["luagate.scanner.ffi"] = nil
  package.loaded["_luagate_scanner_lib"] = nil
end

local function make_stub_lib(opts)
  opts = opts or {}

  return {
    luagate_scan_http = function(
      path_raw,
      path_raw_len,
      path_normalized,
      path_normalized_len,
      query_raw,
      query_raw_len,
      query_normalized,
      query_normalized_len,
      body_ptr,
      body_len,
      threat_type_out,
      _threat_type_cap,
      threat_type_len,
      rule_name_out,
      _rule_name_cap,
      rule_name_len,
      score_out
    )
      table.insert(scan_calls, {
        path_raw = path_raw,
        path_raw_len = path_raw_len,
        path_normalized = path_normalized,
        path_normalized_len = path_normalized_len,
        query_raw = query_raw,
        query_raw_len = query_raw_len,
        query_normalized = query_normalized,
        query_normalized_len = query_normalized_len,
        body_ptr = body_ptr,
        body_len = body_len,
      })

      if opts.scan_error then
        error(opts.scan_error)
      end

      threat_type_len[0] = 0
      rule_name_len[0] = 0
      score_out[0] = opts.score or 0.0

      if opts.threat_type then
        threat_type_out._data = opts.threat_type
        threat_type_len[0] = #opts.threat_type
      end

      if opts.rule_name then
        rule_name_out._data = opts.rule_name
        rule_name_len[0] = #opts.rule_name
      end

      return opts.scan_rc or 0
    end,

    luagate_scanner_init = function(path, len)
      table.insert(init_calls, {
        path = path,
        len = len,
      })

      if opts.init_error then
        error(opts.init_error)
      end

      return opts.init_rc or 0
    end,
  }
end

local function load_module_with(opts)
  mock_lib = make_stub_lib(opts)
  package.loaded["luagate.scanner.ffi"] = nil
  package.loaded["_luagate_scanner_lib"] = nil
  return require("luagate.scanner.ffi")
end

describe("luagate.scanner.ffi", function()
  before_each(function()
    reset_state()
  end)

  describe("scan()", function()
    it("passes all request fields to luagate_scan_http with correct lengths", function()
      local scanner = load_module_with({
        threat_type = "sqli",
        rule_name = "sqli_union_select",
        score = 0.9,
      })

      local result, err = scanner.scan({
        path_raw = "/api/users",
        path_normalized = "/api/users",
        query_raw = "id=1 UNION SELECT",
        query_normalized = "id=1 UNION SELECT",
        body = '{"id":1}',
      })

      assert.is_nil(err)
      assert.equals("sqli", result.threat_type)
      assert.equals("sqli_union_select", result.rule_name)
      assert.equals(0.9, result.threat_score)
      assert.equals(1, #scan_calls)
      assert.equals("/api/users", scan_calls[1].path_raw)
      assert.equals(10, scan_calls[1].path_raw_len)
      assert.equals("/api/users", scan_calls[1].path_normalized)
      assert.equals(10, scan_calls[1].path_normalized_len)
      assert.equals("id=1 UNION SELECT", scan_calls[1].query_raw)
      assert.equals(17, scan_calls[1].query_raw_len)
      assert.equals("id=1 UNION SELECT", scan_calls[1].query_normalized)
      assert.equals(17, scan_calls[1].query_normalized_len)
      assert.equals('{"id":1}', scan_calls[1].body_ptr)
      assert.equals(8, scan_calls[1].body_len)
    end)

    it("defaults missing optional fields to empty strings and nil body", function()
      local scanner = load_module_with()

      local result, err = scanner.scan({
        path_raw = "/health",
        path_normalized = "/health",
      })

      assert.is_nil(err)
      assert.is_not_nil(result)
      assert.is_nil(result.threat_type)
      assert.is_nil(result.rule_name)
      assert.equals(0.0, result.threat_score)
      assert.equals(1, #scan_calls)
      assert.equals("", scan_calls[1].query_raw)
      assert.equals(0, scan_calls[1].query_raw_len)
      assert.equals("", scan_calls[1].query_normalized)
      assert.equals(0, scan_calls[1].query_normalized_len)
      assert.is_nil(scan_calls[1].body_ptr)
      assert.equals(0, scan_calls[1].body_len)
    end)

    it("returns scanner_fail on LUAGATE_BUFFER_TOO_SMALL (-2)", function()
      local scanner = load_module_with({ scan_rc = -2 })

      local result, err = scanner.scan({
        path_raw = "/ok",
        path_normalized = "/ok",
      })

      assert.is_nil(result)
      assert.truthy(err and err:find("scanner_fail"))
      assert.truthy(err and err:find("-2"))
    end)

    it("returns scanner_fail on LUAGATE_BUDGET_EXCEEDED (-3)", function()
      local scanner = load_module_with({ scan_rc = -3 })

      local result, err = scanner.scan({
        path_raw = "/ok",
        path_normalized = "/ok",
      })

      assert.is_nil(result)
      assert.truthy(err and err:find("scanner_fail"))
      assert.truthy(err and err:find("-3"))
    end)

    it("returns scanner_fail on LUAGATE_INTERNAL_ERROR (-4)", function()
      local scanner = load_module_with({ scan_rc = -4 })

      local result, err = scanner.scan({
        path_raw = "/ok",
        path_normalized = "/ok",
      })

      assert.is_nil(result)
      assert.truthy(err and err:find("scanner_fail"))
      assert.truthy(err and err:find("-4"))
    end)

    it("returns scanner_ffi_error when luagate_scan_http raises", function()
      local scanner = load_module_with({ scan_error = "bad ctype" })

      local result, err = scanner.scan({
        path_raw = "/ok",
        path_normalized = "/ok",
      })

      assert.is_nil(result)
      assert.truthy(err and err:find("scanner_ffi_error"))
      assert.truthy(err and err:find("bad ctype"))
    end)
  end)

  describe("init()", function()
    it("passes empty string when patterns_path is nil", function()
      local scanner = load_module_with()

      local ok, err = scanner.init(nil)

      assert.is_true(ok)
      assert.is_nil(err)
      assert.equals(1, #init_calls)
      assert.equals("", init_calls[1].path)
      assert.equals(0, init_calls[1].len)
    end)

    it("passes the provided patterns_path and its length", function()
      local scanner = load_module_with()
      local path = "/etc/luagate/scanner-patterns"

      local ok, err = scanner.init(path)

      assert.is_true(ok)
      assert.is_nil(err)
      assert.equals(1, #init_calls)
      assert.equals(path, init_calls[1].path)
      assert.equals(#path, init_calls[1].len)
    end)

    it("returns scanner_init_failed on non-zero rc", function()
      local scanner = load_module_with({ init_rc = -4 })

      local ok, err = scanner.init(nil)

      assert.is_false(ok)
      assert.truthy(err and err:find("scanner_init_failed"))
      assert.truthy(err and err:find("-4"))
    end)

    it("returns scanner_init_ffi_error when luagate_scanner_init raises", function()
      local scanner = load_module_with({ init_error = "ffi init crash" })

      local ok, err = scanner.init(nil)

      assert.is_false(ok)
      assert.truthy(err and err:find("scanner_init_ffi_error"))
      assert.truthy(err and err:find("ffi init crash"))
    end)
  end)

  describe("package.loaded caching", function()
    it("caches the lib handle after require", function()
      local scanner = load_module_with()

      assert.is_not_nil(scanner)
      assert.equals(mock_lib, package.loaded["_luagate_scanner_lib"])
      assert.equals(1, ffi_load_count)
    end)

    it("reuses a preloaded lib without calling ffi.load again", function()
      local preloaded = make_stub_lib()
      package.loaded["_luagate_scanner_lib"] = preloaded
      package.loaded["luagate.scanner.ffi"] = nil

      local scanner = require("luagate.scanner.ffi")

      assert.is_not_nil(scanner)
      assert.equals(0, ffi_load_count)
      assert.equals(preloaded, package.loaded["_luagate_scanner_lib"])
    end)

    it("returns the same module table on a second require", function()
      local first = load_module_with()
      local second = require("luagate.scanner.ffi")

      assert.equals(first, second)
      assert.equals(1, ffi_load_count)
    end)
  end)
end)
