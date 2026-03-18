-- tests/unit/stream/ffi_spec.lua
--
-- Unit tests for lua/luagate/stream/ffi.lua public API contract.
--
-- These tests run without a real luagate_stream.so by injecting a stub ffi
-- module before requiring the module under test. This verifies the actual
-- Lua binding logic:
--   1. FFI argument wiring and length propagation
--   2. Return-code / pcall error propagation
--   3. package.loaded lib caching
--   4. Radix tree build/lookup/free lifecycle

local ffi_load_count = 0
local detect_calls = {}
local sni_calls = {}
local radix_build_calls = {}
local radix_lookup_calls = {}
local radix_free_calls = {}
local mock_lib = {}
local ngx_log_calls = {}
local ngx_shared_metrics = {}

-- Mock ngx global for timeout leak counter tests
_G.ngx = _G.ngx or {}
ngx.ERR = 0
ngx.log = function(level, ...)
  table.insert(ngx_log_calls, { level = level, args = { ... } })
end
ngx.worker = {
  id = function()
    return 0
  end,
}
ngx.shared = {
  luagate_metrics = {
    incr = function(_, key, val, init)
      ngx_shared_metrics[key] = (ngx_shared_metrics[key] or init or 0) + val
    end,
  },
}

-- Fake radix tree opaque pointer (table acting as userdata stand-in)
local MOCK_TREE_SENTINEL = { _type = "mock_radix_tree" }

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

    if ct == "uint32_t[1]" then
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

    -- luagate_radix_t*[1] — pointer array for radix_build tree_out
    if ct == "luagate_radix_t*[1]" then
      local t = {}
      setmetatable(t, {
        __index = function(_, k)
          if k == 0 then
            return rawget(t, "_v")
          end
        end,
        __newindex = function(_, k, v)
          if k == 0 then
            rawset(t, "_v", v)
          end
        end,
      })
      t[0] = nil
      return t
    end

    -- char[?] buffer
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

  gc = function(obj, _destructor)
    -- In tests, simply return the object without GC registration
    return obj
  end,
}

package.preload["ffi"] = function()
  return ffi_stub
end

-- ---------------------------------------------------------------------------
-- Error code constants (mirror ffi.lua)
-- ---------------------------------------------------------------------------
local LUAGATE_OK = 0
local LUAGATE_NEED_MORE_DATA = 1
local LUAGATE_INVALID_INPUT = -1
local LUAGATE_BUFFER_TOO_SMALL = -2
local NO_MATCH_SENTINEL = 0xFFFFFFFF

local function reset_state()
  ffi_load_count = 0
  detect_calls = {}
  sni_calls = {}
  radix_build_calls = {}
  radix_lookup_calls = {}
  radix_free_calls = {}
  mock_lib = {}
  ngx_log_calls = {}
  ngx_shared_metrics = {}
  package.loaded["luagate.stream.ffi"] = nil
  package.loaded["_luagate_stream_lib"] = nil
end

local function make_stub_lib(opts)
  opts = opts or {}

  return {
    luagate_detect_protocol = function(buf, buf_len, proto_out, _proto_cap, proto_len)
      table.insert(detect_calls, {
        buf = buf,
        buf_len = buf_len,
      })

      if opts.detect_error then
        error(opts.detect_error)
      end

      proto_len[0] = 0
      if opts.detect_protocol then
        proto_out._data = opts.detect_protocol
        proto_len[0] = #opts.detect_protocol
      end

      return opts.detect_rc or LUAGATE_OK
    end,

    luagate_extract_sni = function(buf, buf_len, out, _out_cap, out_len)
      table.insert(sni_calls, {
        buf = buf,
        buf_len = buf_len,
      })

      if opts.sni_error then
        error(opts.sni_error)
      end

      out_len[0] = 0
      if opts.sni_value then
        out._data = opts.sni_value
        out_len[0] = #opts.sni_value
      end

      return opts.sni_rc or LUAGATE_OK
    end,

    luagate_radix_build = function(cidr_list, cidr_list_len, tree_out)
      table.insert(radix_build_calls, {
        cidr_list = cidr_list,
        cidr_list_len = cidr_list_len,
      })

      if opts.radix_build_error then
        error(opts.radix_build_error)
      end

      if (opts.radix_build_rc or LUAGATE_OK) == LUAGATE_OK then
        tree_out[0] = opts.radix_tree or MOCK_TREE_SENTINEL
      end

      return opts.radix_build_rc or LUAGATE_OK
    end,

    luagate_radix_lookup = function(tree, ip_str, ip_str_len, matched_rule_index_out)
      table.insert(radix_lookup_calls, {
        tree = tree,
        ip_str = ip_str,
        ip_str_len = ip_str_len,
      })

      if opts.radix_lookup_error then
        error(opts.radix_lookup_error)
      end

      matched_rule_index_out[0] = opts.radix_lookup_index or NO_MATCH_SENTINEL

      return opts.radix_lookup_rc or LUAGATE_OK
    end,

    luagate_radix_free = function(tree)
      table.insert(radix_free_calls, {
        tree = tree,
      })

      if opts.radix_free_error then
        error(opts.radix_free_error)
      end

      return LUAGATE_OK
    end,
  }
end

local function load_module_with(opts)
  mock_lib = make_stub_lib(opts)
  package.loaded["luagate.stream.ffi"] = nil
  package.loaded["_luagate_stream_lib"] = nil
  return require("luagate.stream.ffi")
end

-- ===========================================================================
-- detect_protocol
-- ===========================================================================

describe("luagate.stream.ffi", function()
  before_each(function()
    reset_state()
  end)

  describe("detect_protocol()", function()
    it("TLS 데이터 -> 'tls' 반환", function()
      local m = load_module_with({ detect_protocol = "tls" })
      local proto, err, need_more = m.detect_protocol("\x16\x03\x01\x00\x05")
      assert.is_nil(err)
      assert.is_falsy(need_more)
      assert.equals("tls", proto)
      assert.equals(1, #detect_calls)
      assert.equals(5, detect_calls[1].buf_len)
    end)

    it("HTTP GET -> 'http' 반환", function()
      local m = load_module_with({ detect_protocol = "http" })
      local proto, err, need_more = m.detect_protocol("GET / HTTP/1.1\r\n")
      assert.is_nil(err)
      assert.is_falsy(need_more)
      assert.equals("http", proto)
    end)

    it("unknown bytes -> 'raw' 반환", function()
      local m = load_module_with({ detect_protocol = "raw" })
      local proto, err = m.detect_protocol("\x00\x01\x02\x03")
      assert.is_nil(err)
      assert.equals("raw", proto)
    end)

    it("빈 데이터 -> NEED_MORE_DATA -> nil, nil, true", function()
      local m = load_module_with({ detect_rc = LUAGATE_NEED_MORE_DATA })
      local proto, err, need_more = m.detect_protocol("x")
      assert.is_nil(proto)
      assert.is_nil(err)
      assert.is_true(need_more)
    end)

    it("malformed TLS -> INVALID_INPUT -> nil, 'invalid_input'", function()
      local m = load_module_with({ detect_rc = LUAGATE_INVALID_INPUT })
      local proto, err = m.detect_protocol("\x16\xff")
      assert.is_nil(proto)
      assert.equals("invalid_input", err)
    end)

    it("non-string 입력 -> 'invalid_argument'", function()
      local m = load_module_with()
      local proto, err = m.detect_protocol(nil)
      assert.is_nil(proto)
      assert.equals("invalid_argument", err)
    end)

    it("숫자 입력 -> 'invalid_argument'", function()
      local m = load_module_with()
      local proto, err = m.detect_protocol(42)
      assert.is_nil(proto)
      assert.equals("invalid_argument", err)
    end)

    it("FFI 예외 발생 시 stream_ffi_error 반환", function()
      local m = load_module_with({ detect_error = "segfault simulation" })
      local proto, err = m.detect_protocol("data")
      assert.is_nil(proto)
      assert.truthy(err and err:find("stream_ffi_error"))
      assert.truthy(err and err:find("segfault simulation"))
    end)

    it("unknown 에러 코드 -> stream_fail 반환", function()
      local m = load_module_with({ detect_rc = -99 })
      local proto, err = m.detect_protocol("data")
      assert.is_nil(proto)
      assert.truthy(err and err:find("stream_fail"))
    end)
  end)

  -- ===========================================================================
  -- extract_sni
  -- ===========================================================================

  describe("extract_sni()", function()
    it("유효한 TLS ClientHello + SNI -> SNI 문자열 반환", function()
      local m = load_module_with({ sni_value = "example.com" })
      local sni, err, need_more = m.extract_sni("\x16\x03\x01...")
      assert.is_nil(err)
      assert.is_falsy(need_more)
      assert.equals("example.com", sni)
      assert.equals(1, #sni_calls)
    end)

    it("TLS without SNI -> 빈 문자열 (에러 아님)", function()
      -- sni_value not set -> out_len stays 0 -> returns ""
      local m = load_module_with()
      local sni, err, need_more = m.extract_sni("\x16\x03\x01...")
      assert.is_nil(err)
      assert.is_falsy(need_more)
      assert.equals("", sni)
    end)

    it("non-TLS 데이터 -> INVALID_INPUT -> nil, 'invalid_input'", function()
      local m = load_module_with({ sni_rc = LUAGATE_INVALID_INPUT })
      local sni, err = m.extract_sni("GET / HTTP/1.1")
      assert.is_nil(sni)
      assert.equals("invalid_input", err)
    end)

    it("NEED_MORE_DATA -> nil, nil, true", function()
      local m = load_module_with({ sni_rc = LUAGATE_NEED_MORE_DATA })
      local sni, err, need_more = m.extract_sni("\x16\x03")
      assert.is_nil(sni)
      assert.is_nil(err)
      assert.is_true(need_more)
    end)

    it("BUFFER_TOO_SMALL -> nil, 'sni_buffer_too_small'", function()
      local m = load_module_with({ sni_rc = LUAGATE_BUFFER_TOO_SMALL })
      local sni, err = m.extract_sni("\x16\x03\x01...")
      assert.is_nil(sni)
      assert.equals("sni_buffer_too_small", err)
    end)

    it("non-string 입력 -> 'invalid_argument'", function()
      local m = load_module_with()
      local sni, err = m.extract_sni(nil)
      assert.is_nil(sni)
      assert.equals("invalid_argument", err)
    end)

    it("FFI 예외 발생 시 stream_ffi_error 반환", function()
      local m = load_module_with({ sni_error = "bad ctype" })
      local sni, err = m.extract_sni("data")
      assert.is_nil(sni)
      assert.truthy(err and err:find("stream_ffi_error"))
      assert.truthy(err and err:find("bad ctype"))
    end)

    it("unknown 에러 코드 -> stream_fail 반환", function()
      local m = load_module_with({ sni_rc = -99 })
      local sni, err = m.extract_sni("data")
      assert.is_nil(sni)
      assert.truthy(err and err:find("stream_fail"))
    end)

    it("buf와 buf_len이 정확히 전달된다", function()
      local m = load_module_with({ sni_value = "test.com" })
      local input = "hello-tls-data"
      m.extract_sni(input)
      assert.equals(input, sni_calls[1].buf)
      assert.equals(#input, sni_calls[1].buf_len)
    end)
  end)

  -- ===========================================================================
  -- radix_build / radix_lookup / radix_free
  -- ===========================================================================

  describe("radix_build()", function()
    it("정상 빌드 -> tree 반환 (non-nil)", function()
      local m = load_module_with()
      local tree, err = m.radix_build("10.0.0.0/8,0\n192.168.0.0/16,1\n")
      assert.is_nil(err)
      assert.is_not_nil(tree)
      assert.equals(1, #radix_build_calls)
    end)

    it("cidr_list와 길이가 정확히 전달된다", function()
      local m = load_module_with()
      local cidr = "10.0.0.0/8,0\n"
      m.radix_build(cidr)
      assert.equals(cidr, radix_build_calls[1].cidr_list)
      assert.equals(#cidr, radix_build_calls[1].cidr_list_len)
    end)

    it("빈 CIDR 리스트 -> 빌드 성공", function()
      local m = load_module_with()
      local tree, err = m.radix_build("")
      assert.is_nil(err)
      assert.is_not_nil(tree)
    end)

    it("invalid CIDR -> 빌드 실패", function()
      local m = load_module_with({ radix_build_rc = LUAGATE_INVALID_INPUT })
      local tree, err = m.radix_build("not-a-cidr")
      assert.is_nil(tree)
      assert.truthy(err and err:find("radix_build_fail"))
    end)

    it("non-string 입력 -> 'invalid_argument'", function()
      local m = load_module_with()
      local tree, err = m.radix_build(nil)
      assert.is_nil(tree)
      assert.equals("invalid_argument", err)
    end)

    it("FFI 예외 발생 시 stream_ffi_error 반환", function()
      local m = load_module_with({ radix_build_error = "alloc fail" })
      local tree, err = m.radix_build("10.0.0.0/8,0\n")
      assert.is_nil(tree)
      assert.truthy(err and err:find("stream_ffi_error"))
      assert.truthy(err and err:find("alloc fail"))
    end)
  end)

  describe("radix_lookup()", function()
    it("매칭 lookup -> rule_index 반환", function()
      local m = load_module_with({ radix_lookup_index = 0 })
      -- Build a tree first for the lookup
      local tree = m.radix_build("10.0.0.0/8,0\n")
      assert.is_not_nil(tree)

      -- Reset to configure lookup behavior
      radix_lookup_calls = {}
      local idx, err = m.radix_lookup(tree, "10.1.2.3")
      assert.is_nil(err)
      assert.equals(0, idx)
      assert.equals(1, #radix_lookup_calls)
      assert.equals("10.1.2.3", radix_lookup_calls[1].ip_str)
      assert.equals(8, radix_lookup_calls[1].ip_str_len)
    end)

    it("미매칭 lookup -> nil (에러 아님)", function()
      local m = load_module_with({ radix_lookup_index = NO_MATCH_SENTINEL })
      local tree = m.radix_build("10.0.0.0/8,0\n")
      local idx, err = m.radix_lookup(tree, "172.16.0.1")
      assert.is_nil(idx)
      assert.is_nil(err)
    end)

    it("longest prefix match 동작 확인 (더 구체적인 CIDR의 index 반환)", function()
      -- Simulate: /8 -> index 0, /24 -> index 1; lookup returns index 1
      local m = load_module_with({ radix_lookup_index = 1 })
      local tree = m.radix_build("10.0.0.0/8,0\n10.0.0.0/24,1\n")
      local idx, err = m.radix_lookup(tree, "10.0.0.5")
      assert.is_nil(err)
      assert.equals(1, idx)
    end)

    it("nil tree -> 'invalid_argument'", function()
      local m = load_module_with()
      local idx, err = m.radix_lookup(nil, "10.0.0.1")
      assert.is_nil(idx)
      assert.equals("invalid_argument", err)
    end)

    it("non-string ip -> 'invalid_argument'", function()
      local m = load_module_with()
      local tree = m.radix_build("10.0.0.0/8,0\n")
      local idx, err = m.radix_lookup(tree, 12345)
      assert.is_nil(idx)
      assert.equals("invalid_argument", err)
    end)

    it("FFI 예외 발생 시 stream_ffi_error 반환", function()
      local m = load_module_with({ radix_lookup_error = "lookup crash" })
      local tree = m.radix_build("10.0.0.0/8,0\n")
      local idx, err = m.radix_lookup(tree, "10.0.0.1")
      assert.is_nil(idx)
      assert.truthy(err and err:find("stream_ffi_error"))
    end)

    it("non-OK return code -> radix_lookup_fail", function()
      local m = load_module_with({ radix_lookup_rc = -99 })
      local tree = m.radix_build("10.0.0.0/8,0\n")
      local idx, err = m.radix_lookup(tree, "10.0.0.1")
      assert.is_nil(idx)
      assert.truthy(err and err:find("radix_lookup_fail"))
    end)
  end)

  describe("radix_free()", function()
    it("nil tree -> 안전하게 무시", function()
      local m = load_module_with()
      -- Should not raise
      m.radix_free(nil)
      assert.equals(0, #radix_free_calls)
    end)

    it("유효한 tree -> free 호출", function()
      local m = load_module_with()
      local tree = m.radix_build("10.0.0.0/8,0\n")
      assert.is_not_nil(tree)
      m.radix_free(tree)
      -- pcall wraps both gc(tree, nil) and free call
      assert.is_true(#radix_free_calls >= 1)
    end)

    it("이중 해제 안전성 (두 번 호출해도 에러 없음)", function()
      local m = load_module_with()
      local tree = m.radix_build("10.0.0.0/8,0\n")
      m.radix_free(tree)
      -- Second call should not raise
      m.radix_free(tree)
    end)
  end)

  -- ===========================================================================
  -- LUAGATE_TIMEOUT (-5) — ADR-009 Layer 2
  -- ===========================================================================

  describe("LUAGATE_TIMEOUT (-5)", function()
    it("detect_protocol returns nil + ffi_timeout on timeout", function()
      local m = load_module_with({ detect_rc = -5 })
      local proto, err = m.detect_protocol("data")
      assert.is_nil(proto)
      assert.equals("ffi_timeout", err)
    end)

    it("detect_protocol increments stream_detect leak counter", function()
      local m = load_module_with({ detect_rc = -5 })
      m.detect_protocol("data")
      assert.equals(1, ngx_shared_metrics["ffi:timeout:leak:0"])
      assert.equals(1, ngx_shared_metrics["ffi:timeout:stream_detect:0"])
    end)

    it("extract_sni returns nil + ffi_timeout on timeout", function()
      local m = load_module_with({ sni_rc = -5 })
      local sni, err = m.extract_sni("data")
      assert.is_nil(sni)
      assert.equals("ffi_timeout", err)
    end)

    it("extract_sni increments stream_sni leak counter", function()
      local m = load_module_with({ sni_rc = -5 })
      m.extract_sni("data")
      assert.equals(1, ngx_shared_metrics["ffi:timeout:stream_sni:0"])
    end)

    it("radix_build returns nil + ffi_timeout on timeout", function()
      local m = load_module_with({ radix_build_rc = -5 })
      local tree, err = m.radix_build("10.0.0.0/8,0\n")
      assert.is_nil(tree)
      assert.equals("ffi_timeout", err)
    end)

    it("radix_build increments stream_radix_build leak counter", function()
      local m = load_module_with({ radix_build_rc = -5 })
      m.radix_build("10.0.0.0/8,0\n")
      assert.equals(1, ngx_shared_metrics["ffi:timeout:stream_radix_build:0"])
    end)

    it("radix_lookup returns nil + ffi_timeout on timeout", function()
      local m = load_module_with({ radix_lookup_rc = -5 })
      local tree = m.radix_build("10.0.0.0/8,0\n")
      local idx, err = m.radix_lookup(tree, "10.0.0.1")
      assert.is_nil(idx)
      assert.equals("ffi_timeout", err)
    end)

    it("radix_lookup increments stream_radix_lookup leak counter", function()
      local m = load_module_with({ radix_lookup_rc = -5 })
      local tree = m.radix_build("10.0.0.0/8,0\n")
      m.radix_lookup(tree, "10.0.0.1")
      assert.equals(1, ngx_shared_metrics["ffi:timeout:stream_radix_lookup:0"])
    end)

    it("logs ERR on timeout", function()
      local m = load_module_with({ detect_rc = -5 })
      m.detect_protocol("data")
      assert.is_true(#ngx_log_calls > 0)
      assert.equals(ngx.ERR, ngx_log_calls[1].level)
    end)
  end)

  -- ===========================================================================
  -- package.loaded caching
  -- ===========================================================================

  describe("package.loaded 캐싱", function()
    it("require 후 lib 핸들이 캐시된다", function()
      local m = load_module_with()
      assert.is_not_nil(m)
      assert.equals(mock_lib, package.loaded["_luagate_stream_lib"])
      assert.equals(1, ffi_load_count)
    end)

    it("preloaded lib이 있으면 ffi.load를 호출하지 않는다", function()
      local preloaded = make_stub_lib()
      package.loaded["_luagate_stream_lib"] = preloaded
      package.loaded["luagate.stream.ffi"] = nil

      local m = require("luagate.stream.ffi")
      assert.is_not_nil(m)
      assert.equals(0, ffi_load_count)
      assert.equals(preloaded, package.loaded["_luagate_stream_lib"])
    end)

    it("두 번째 require는 동일한 모듈 테이블을 반환한다", function()
      local first = load_module_with()
      local second = require("luagate.stream.ffi")
      assert.equals(first, second)
      assert.equals(1, ffi_load_count)
    end)
  end)
end)
