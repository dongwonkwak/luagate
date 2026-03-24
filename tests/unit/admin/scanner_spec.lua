-- tests/unit/admin/scanner_spec.lua
--
-- Unit tests for lua/luagate/admin/scanner.lua Admin API handlers.
-- Uses stubs for ngx, scanner FFI, and shared dict.

-- Stub cjson before anything else
local cjson_stub = {
  null = nil, -- json null sentinel
  encode = function(t)
    -- Minimal JSON encode for testing: use dkjson if available, else manual
    local ok, dkjson = pcall(require, "dkjson")
    if ok then
      return dkjson.encode(t)
    end
    -- Fallback: just use tostring for simple cases
    return tostring(t)
  end,
  decode = function(s)
    local ok, dkjson = pcall(require, "dkjson")
    if ok then
      return dkjson.decode(s)
    end
    return nil, "no json decoder"
  end,
}

-- Try to use dkjson for testing
local ok_dkjson, dkjson = pcall(require, "dkjson")
if ok_dkjson then
  cjson_stub.encode = dkjson.encode
  cjson_stub.decode = dkjson.decode
end

package.preload["cjson.safe"] = function()
  return cjson_stub
end
package.preload["cjson"] = function()
  return cjson_stub
end

local cjson = cjson_stub

-- Track state
local ngx_body_parts = {}
local ngx_log_calls = {}
local mock_scanner_dict = {}
local scanner_reload_result = nil
local scanner_reload_error = nil
local request_body = nil
local request_headers = {}
local request_uri_args = {}

-- Mock ngx
_G.ngx = {
  ERR = 0,
  WARN = 1,
  INFO = 2,
  CRIT = 3,
  status = nil,
  header = {},
  var = {
    remote_addr = "127.0.0.1",
    uri = "/api/v1/scanner/patterns",
  },
  log = function(level, ...)
    table.insert(ngx_log_calls, { level = level, args = { ... } })
  end,
  say = function(s)
    table.insert(ngx_body_parts, s)
  end,
  exit = function(_status)
    -- Simulate OpenResty ngx.exit behavior (no-op in unit tests)
  end,
  worker = {
    id = function()
      return 0
    end,
  },
  now = function()
    return 1711234567.123
  end,
  utctime = function()
    return "2026-03-24 10:00:00"
  end,
  req = {
    read_body = function() end,
    get_body_data = function()
      return request_body
    end,
    get_body_file = function()
      return nil
    end,
    get_headers = function()
      return request_headers
    end,
    get_uri_args = function()
      return request_uri_args
    end,
  },
  shared = {},
}

-- Mock scanner shared dict
local mock_dict_mt = {
  get = function(_, key)
    return mock_scanner_dict[key]
  end,
  set = function(_, key, value)
    mock_scanner_dict[key] = value
    return true
  end,
  add = function(_, key, value, _ttl)
    if mock_scanner_dict[key] then
      return false, "exists"
    end
    mock_scanner_dict[key] = value
    return true
  end,
  delete = function(_, key)
    mock_scanner_dict[key] = nil
  end,
}
ngx.shared.luagate_scanner_patterns = mock_dict_mt

-- Mock scanner FFI
package.loaded["luagate.scanner.ffi"] = {
  reload = function(_path)
    if scanner_reload_error then
      return nil, scanner_reload_error
    end
    return scanner_reload_result, nil
  end,
}

local function reset_state()
  ngx.status = nil
  ngx.header = {}
  ngx_body_parts = {}
  ngx_log_calls = {}
  mock_scanner_dict = {}
  scanner_reload_result = { version = string.rep("a", 64), pattern_count = 24 }
  scanner_reload_error = nil
  request_body = nil
  request_headers = {}
  request_uri_args = {}

  -- Clear module cache
  package.loaded["luagate.admin.scanner"] = nil
end

describe("luagate.admin.scanner", function()
  before_each(function()
    reset_state()
  end)

  describe("handle_get_patterns()", function()
    it("returns current pattern metadata from shared dict", function()
      mock_scanner_dict["scanner:active_version"] = "abc123"
      mock_scanner_dict["scanner:loaded_at"] = "2026-03-24 09:00:00"
      mock_scanner_dict["scanner:pattern_count"] = 24

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_get_patterns()

      assert.equals(200, ngx.status)
      assert.equals(1, #ngx_body_parts)
      local body = cjson.decode(ngx_body_parts[1])
      assert.equals("abc123", body.active_version)
      assert.equals("2026-03-24 09:00:00", body.loaded_at)
      assert.equals(24, body.pattern_count)
    end)

    it("returns 0 pattern_count when not set", function()
      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_get_patterns()

      assert.equals(200, ngx.status)
      local body = cjson.decode(ngx_body_parts[1])
      assert.equals(0, body.pattern_count)
    end)
  end)

  describe("handle_post_reload()", function()
    it("reloads successfully and updates shared dict metadata", function()
      scanner_reload_result = {
        version = string.rep("b", 64),
        pattern_count = 15,
      }

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_post_reload()

      assert.equals(200, ngx.status)
      local body = cjson.decode(ngx_body_parts[1])
      assert.equals(string.rep("b", 64), body.version)
      assert.equals(15, body.pattern_count)

      -- Verify shared dict updated
      assert.equals(string.rep("b", 64), mock_scanner_dict["scanner:active_version"])
      assert.equals(15, mock_scanner_dict["scanner:pattern_count"])
    end)

    it("returns 409 when reload lock is held", function()
      mock_scanner_dict["scanner_reload_lock"] = "other_worker"

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_post_reload()

      assert.equals(409, ngx.status)
      local body = cjson.decode(ngx_body_parts[1])
      assert.equals("ReloadInProgress", body.error)
    end)

    it("returns 500 on reload failure", function()
      scanner_reload_error = "scanner_reload_failed:-4"

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_post_reload()

      assert.equals(500, ngx.status)
      local body = cjson.decode(ngx_body_parts[1])
      assert.equals("reload_failed", body.error)
    end)

    it("releases reload lock after success", function()
      scanner_reload_result = {
        version = string.rep("c", 64),
        pattern_count = 10,
      }

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_post_reload()

      -- Lock should be released
      assert.is_nil(mock_scanner_dict["scanner_reload_lock"])
    end)

    it("releases reload lock after failure", function()
      scanner_reload_error = "scanner_reload_failed:-4"

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_post_reload()

      -- Lock should be released
      assert.is_nil(mock_scanner_dict["scanner_reload_lock"])
    end)
  end)

  describe("handle_put_patterns()", function()
    it("returns 400 on empty body", function()
      request_body = nil

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_put_patterns()

      assert.equals(400, ngx.status)
      local body = cjson.decode(ngx_body_parts[1])
      assert.equals("empty_body", body.error)
    end)

    it("returns 413 on oversized body", function()
      request_body = string.rep("x", 1048577) -- > 1MB

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_put_patterns()

      assert.equals(413, ngx.status)
    end)

    it("returns 409 when reload lock is held", function()
      request_body = "- threat_type: sqli\n  rule_name: test\n  pattern: test\n  score: 0.9"
      mock_scanner_dict["scanner_reload_lock"] = "other_worker"

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_put_patterns()

      assert.equals(409, ngx.status)
    end)
  end)
end)
