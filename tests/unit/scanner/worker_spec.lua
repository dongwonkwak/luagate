-- tests/unit/scanner/worker_spec.lua
--
-- Unit tests for lua/luagate/scanner/worker.lua cross-worker sync timer.
-- Validates timing measurement, version polling, and reload behavior.

local ngx_log_calls = {}
local ngx_timer_callbacks = {}
local mock_scanner_dict = {}
local scanner_reload_result = nil
local scanner_reload_error = nil
local mock_now_value = 1000.000

-- Mock ngx
_G.ngx = {
  ERR = 0,
  WARN = 1,
  INFO = 2,
  CRIT = 3,
  log = function(level, ...)
    table.insert(ngx_log_calls, { level = level, args = { ... } })
  end,
  worker = {
    id = function()
      return 0
    end,
  },
  now = function()
    return mock_now_value
  end,
  timer = {
    every = function(_interval, callback)
      table.insert(ngx_timer_callbacks, callback)
      return true, nil
    end,
  },
  shared = {},
}

-- Mock shared dict
local mock_dict_mt = {
  get = function(_, key)
    return mock_scanner_dict[key]
  end,
  set = function(_, key, value)
    mock_scanner_dict[key] = value
    return true
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
  ngx_log_calls = {}
  ngx_timer_callbacks = {}
  mock_scanner_dict = {}
  scanner_reload_result = { version = "abc123", pattern_count = 10 }
  scanner_reload_error = nil
  mock_now_value = 1000.000

  -- Clear module cache to reset module-level upvalues
  package.loaded["luagate.scanner.worker"] = nil
end

describe("luagate.scanner.worker", function()
  before_each(function()
    reset_state()
  end)

  describe("init_worker()", function()
    it("registers a periodic timer", function()
      local worker = require("luagate.scanner.worker")
      worker.init_worker("conf/scanner-patterns")

      assert.equals(1, #ngx_timer_callbacks)
    end)

    it("reads initial version from shared dict", function()
      mock_scanner_dict["scanner:active_version"] = "initial_v1"

      local worker = require("luagate.scanner.worker")
      worker.init_worker("conf/scanner-patterns")

      assert.equals("initial_v1", worker.get_local_version())
    end)

    it("sets local version to nil when shared dict has no version", function()
      local worker = require("luagate.scanner.worker")
      worker.init_worker("conf/scanner-patterns")

      assert.is_nil(worker.get_local_version())
    end)
  end)

  describe("check_version timer callback", function()
    it("reloads when shared dict version differs from local", function()
      local worker = require("luagate.scanner.worker")
      worker.init_worker("conf/scanner-patterns")

      -- Set shared dict to new version
      mock_scanner_dict["scanner:active_version"] = "new_v2"
      scanner_reload_result = { version = "new_v2", pattern_count = 15 }

      -- Invoke the timer callback (not premature)
      assert.equals(1, #ngx_timer_callbacks)
      ngx_timer_callbacks[1](false)

      -- Should have updated local version
      assert.equals("new_v2", worker.get_local_version())
    end)

    it("does not reload when version unchanged", function()
      mock_scanner_dict["scanner:active_version"] = "same_v1"

      local worker = require("luagate.scanner.worker")
      worker.init_worker("conf/scanner-patterns")

      -- Same version, no reload needed
      ngx_timer_callbacks[1](false)

      -- No WARN or INFO logs about reload
      local reload_logs = 0
      for _, entry in ipairs(ngx_log_calls) do
        local msg = table.concat(entry.args, "")
        if msg:find("reloaded patterns") then
          reload_logs = reload_logs + 1
        end
      end
      assert.equals(0, reload_logs)
    end)

    it("preserves LKG and logs WARN on reload failure", function()
      local worker = require("luagate.scanner.worker")
      worker.init_worker("conf/scanner-patterns")
      worker._set_local_version("old_v1")

      mock_scanner_dict["scanner:active_version"] = "new_v2"
      scanner_reload_error = "scanner_reload_failed:io_error:-10"

      ngx_timer_callbacks[1](false)

      -- Local version should NOT change (LKG preserved)
      assert.equals("old_v1", worker.get_local_version())

      -- Should log WARN with elapsed time
      local found_warn = false
      for _, entry in ipairs(ngx_log_calls) do
        if entry.level == ngx.WARN then
          local msg = table.concat(entry.args, "")
          if msg:find("reload failed") and msg:find("elapsed=") then
            found_warn = true
          end
        end
      end
      assert.is_true(found_warn, "should log WARN with elapsed time on failure")
    end)

    it("skips on premature timer call (shutdown)", function()
      local worker = require("luagate.scanner.worker")
      worker.init_worker("conf/scanner-patterns")
      worker._set_local_version("old_v1")

      mock_scanner_dict["scanner:active_version"] = "new_v2"

      -- premature=true means shutdown
      ngx_timer_callbacks[1](true)

      -- Should not reload
      assert.equals("old_v1", worker.get_local_version())
    end)

    it("logs CRIT when reload exceeds threshold", function()
      local worker = require("luagate.scanner.worker")
      worker.init_worker("conf/scanner-patterns")

      mock_scanner_dict["scanner:active_version"] = "new_v2"
      scanner_reload_result = { version = "new_v2", pattern_count = 5 }

      -- Simulate slow reload by advancing ngx.now() during the FFI call
      local call_count = 0
      local orig_now = ngx.now
      ngx.now = function()
        call_count = call_count + 1
        if call_count <= 1 then
          return 1000.000 -- t0
        else
          return 1006.000 -- elapsed = 6s > 5s threshold
        end
      end

      ngx_timer_callbacks[1](false)

      -- Should log CRIT about threshold exceeded
      local found_crit = false
      for _, entry in ipairs(ngx_log_calls) do
        if entry.level == ngx.CRIT then
          local msg = table.concat(entry.args, "")
          if msg:find("threshold") and msg:find("watchdog") then
            found_crit = true
          end
        end
      end
      assert.is_true(found_crit, "should log CRIT when reload exceeds threshold")

      -- Restore
      ngx.now = orig_now
    end)

    it("includes elapsed time in success log", function()
      local worker = require("luagate.scanner.worker")
      worker.init_worker("conf/scanner-patterns")

      mock_scanner_dict["scanner:active_version"] = "new_v3"
      scanner_reload_result = { version = "new_v3", pattern_count = 8 }

      ngx_timer_callbacks[1](false)

      local found_elapsed = false
      for _, entry in ipairs(ngx_log_calls) do
        if entry.level == ngx.INFO then
          local msg = table.concat(entry.args, "")
          if msg:find("elapsed=") and msg:find("reloaded patterns") then
            found_elapsed = true
          end
        end
      end
      assert.is_true(found_elapsed, "success log should include elapsed time")
    end)
  end)
end)
