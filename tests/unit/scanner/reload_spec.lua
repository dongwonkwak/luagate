-- tests/unit/scanner/reload_spec.lua
--
-- Unit tests for lua/luagate/scanner/ffi.lua reload() function
-- and lua/luagate/scanner/worker.lua cross-worker sync.
--
-- These tests run without a real luagate_scanner.so by injecting stubs.

local ffi_load_count = 0
local reload_calls = {}
local mock_lib = {}
local timer_every_calls = {}
local timer_callbacks = {}
local ngx_log_calls = {}

-- Mock ngx global
_G.ngx = _G.ngx or {}
ngx.ERR = 0
ngx.WARN = 1
ngx.INFO = 2
ngx.log = function(level, ...)
  table.insert(ngx_log_calls, { level = level, args = { ... } })
end
ngx.worker = {
  id = function()
    return 0
  end,
}
ngx.now = function()
  return 1711234567.123
end
ngx.utctime = function()
  return "2026-03-24 10:00:00"
end

-- Mock shared dict for scanner patterns
local mock_scanner_dict = {}
local mock_scanner_dict_impl = {
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

ngx.shared = ngx.shared or {}
ngx.shared.luagate_scanner_patterns = mock_scanner_dict_impl
ngx.shared.luagate_metrics = {
  incr = function(_, _key, _val, _init)
    return true
  end,
}

-- Mock ngx.timer.every
ngx.timer = ngx.timer or {}
ngx.timer.every = function(interval, callback)
  table.insert(timer_every_calls, { interval = interval, callback = callback })
  table.insert(timer_callbacks, callback)
  return true
end

-- FFI stub
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
  reload_calls = {}
  mock_lib = {}
  timer_every_calls = {}
  timer_callbacks = {}
  ngx_log_calls = {}
  mock_scanner_dict = {}
  package.loaded["luagate.scanner.ffi"] = nil
  package.loaded["luagate.scanner.worker"] = nil
  package.loaded["_luagate_scanner_lib"] = nil
end

local function make_reload_stub(opts)
  opts = opts or {}
  return function(path, path_len, version_out, version_out_cap, count_out)
    table.insert(reload_calls, {
      path = path,
      path_len = path_len,
    })

    if opts.reload_error then
      error(opts.reload_error)
    end

    -- Write version to output buffer
    if version_out and version_out_cap >= 65 and opts.version then
      version_out._data = opts.version
    end
    -- Write count to output
    if count_out and opts.pattern_count then
      count_out[0] = opts.pattern_count
    end

    return opts.reload_rc or 0
  end
end

local function load_ffi_with_reload(opts)
  opts = opts or {}
  mock_lib = {
    luagate_scan_http = function()
      return 0
    end,
    luagate_scanner_init = function()
      return 0
    end,
    luagate_scanner_reload = make_reload_stub(opts),
  }
  package.loaded["luagate.scanner.ffi"] = nil
  package.loaded["_luagate_scanner_lib"] = nil
  return require("luagate.scanner.ffi")
end

describe("luagate.scanner.ffi.reload()", function()
  before_each(function()
    reset_state()
  end)

  it("calls luagate_scanner_reload with correct path", function()
    local scanner = load_ffi_with_reload({
      version = "abc123def456" .. string.rep("0", 52),
      pattern_count = 5,
    })

    local result, err = scanner.reload("conf/scanner-patterns")

    assert.is_nil(err)
    assert.is_not_nil(result)
    assert.equals(5, result.pattern_count)
    assert.equals(1, #reload_calls)
    assert.equals("conf/scanner-patterns", reload_calls[1].path)
  end)

  it("returns error on empty path", function()
    local scanner = load_ffi_with_reload()

    local result, err = scanner.reload("")

    assert.is_nil(result)
    assert.truthy(err and err:find("empty_path"))
  end)

  it("returns error on nil path", function()
    local scanner = load_ffi_with_reload()

    local result, err = scanner.reload(nil)

    assert.is_nil(result)
    assert.truthy(err and err:find("empty_path"))
  end)

  it("returns scanner_reload_failed on non-zero rc", function()
    local scanner = load_ffi_with_reload({ reload_rc = -4 })

    local result, err = scanner.reload("conf/scanner-patterns")

    assert.is_nil(result)
    assert.truthy(err and err:find("scanner_reload_failed"))
    assert.truthy(err and err:find("-4"))
  end)

  it("returns scanner_reload_ffi_error when FFI raises", function()
    local scanner = load_ffi_with_reload({ reload_error = "segfault" })

    local result, err = scanner.reload("conf/scanner-patterns")

    assert.is_nil(result)
    assert.truthy(err and err:find("scanner_reload_ffi_error"))
    assert.truthy(err and err:find("segfault"))
  end)
end)

describe("luagate.scanner.worker", function()
  before_each(function()
    reset_state()
    -- Pre-load ffi module with reload stub
    load_ffi_with_reload({
      version = string.rep("a", 64),
      pattern_count = 10,
    })
  end)

  describe("init_worker()", function()
    it("registers a 1-second periodic timer", function()
      local worker = require("luagate.scanner.worker")
      worker.init_worker("conf/scanner-patterns")

      assert.equals(1, #timer_every_calls)
      assert.equals(1, timer_every_calls[1].interval)
    end)

    it("reads initial version from shared dict", function()
      mock_scanner_dict["scanner:active_version"] = "initial_version_hash"

      local worker = require("luagate.scanner.worker")
      worker.init_worker("conf/scanner-patterns")

      assert.equals("initial_version_hash", worker.get_local_version())
    end)

    it("sets local version to nil when no shared dict version", function()
      local worker = require("luagate.scanner.worker")
      worker.init_worker("conf/scanner-patterns")

      assert.is_nil(worker.get_local_version())
    end)
  end)

  describe("check_version timer callback", function()
    it("does not reload when version unchanged", function()
      mock_scanner_dict["scanner:active_version"] = "v1"

      local worker = require("luagate.scanner.worker")
      worker.init_worker("conf/scanner-patterns")

      -- Simulate timer callback
      assert.equals(1, #timer_callbacks)
      timer_callbacks[1](false) -- premature=false

      -- No reload should happen (version matches)
      assert.equals(0, #reload_calls)
    end)

    it("reloads when version changes", function()
      mock_scanner_dict["scanner:active_version"] = "v1"

      local worker = require("luagate.scanner.worker")
      worker.init_worker("conf/scanner-patterns")

      -- Change version in shared dict
      mock_scanner_dict["scanner:active_version"] = "v2_new_version"

      -- Simulate timer callback
      timer_callbacks[1](false)

      -- Should have called reload
      assert.equals(1, #reload_calls)
      assert.equals("v2_new_version", worker.get_local_version())
    end)

    it("skips reload on premature timer (shutdown)", function()
      mock_scanner_dict["scanner:active_version"] = "v1"

      local worker = require("luagate.scanner.worker")
      worker.init_worker("conf/scanner-patterns")

      mock_scanner_dict["scanner:active_version"] = "v2"

      -- premature=true (Nginx shutting down)
      timer_callbacks[1](true)

      -- No reload should happen
      assert.equals(0, #reload_calls)
    end)

    it("preserves LKG on reload failure", function()
      -- Load ffi with failing reload
      mock_lib.luagate_scanner_reload = make_reload_stub({ reload_rc = -4 })

      mock_scanner_dict["scanner:active_version"] = "v1"
      local worker = require("luagate.scanner.worker")
      worker.init_worker("conf/scanner-patterns")

      mock_scanner_dict["scanner:active_version"] = "v2"
      timer_callbacks[1](false)

      -- Version should NOT be updated on failure
      assert.equals("v1", worker.get_local_version())
    end)
  end)
end)
