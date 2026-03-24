-- luacheck: ignore 122
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
local mock_dict_set_fail_key = nil -- when set, dict:set() for this key returns false
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
    if mock_dict_set_fail_key and key == mock_dict_set_fail_key then
      return false, "no memory"
    end
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
  mock_dict_set_fail_key = nil
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
      mock_scanner_dict["scanner:loaded_at"] = "2026-03-24T09:00:00Z"
      mock_scanner_dict["scanner:pattern_count"] = 24

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_get_patterns()

      assert.equals(200, ngx.status)
      assert.equals(1, #ngx_body_parts)
      local body = cjson.decode(ngx_body_parts[1])
      assert.equals("abc123", body.active_version)
      assert.equals("2026-03-24T09:00:00Z", body.loaded_at)
      assert.equals(24, body.pattern_count)
      assert.is_table(body.patterns)
    end)

    it("returns 0 pattern_count when not set", function()
      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_get_patterns()

      assert.equals(200, ngx.status)
      local body = cjson.decode(ngx_body_parts[1])
      assert.equals(0, body.pattern_count)
      assert.is_table(body.patterns)
    end)

    it("returns pattern metadata from shared dict when available", function()
      local patterns_data = {
        { threat_type = "sqli", rule_name = "sqli_union", score = 0.9 },
      }
      mock_scanner_dict["scanner:active_version"] = "abc123"
      mock_scanner_dict["scanner:pattern_count"] = 1
      mock_scanner_dict["scanner:pattern_metadata"] = cjson.encode(patterns_data)

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_get_patterns()

      assert.equals(200, ngx.status)
      local body = cjson.decode(ngx_body_parts[1])
      assert.equals(1, #body.patterns)
      assert.equals("sqli", body.patterns[1].threat_type)
      assert.equals("sqli_union", body.patterns[1].rule_name)
    end)

    it("returns 503 when shared dict unavailable", function()
      ngx.shared.luagate_scanner_patterns = nil

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_get_patterns()

      assert.equals(503, ngx.status)

      -- Restore for other tests
      ngx.shared.luagate_scanner_patterns = mock_dict_mt
    end)
  end)

  describe("handle_post_reload()", function()
    it("reloads successfully and updates shared dict metadata", function()
      scanner_reload_result = {
        version = string.rep("b", 64),
        pattern_count = 15,
      }
      -- Set initial version to verify previous_version in response
      mock_scanner_dict["scanner:active_version"] = "old_version"

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_post_reload()

      assert.equals(200, ngx.status)
      local body = cjson.decode(ngx_body_parts[1])
      assert.equals(string.rep("b", 64), body.new_version)
      assert.equals(15, body.pattern_count)
      assert.equals("old_version", body.previous_version)
      -- reloaded_at should be ISO-8601 format
      assert.is_string(body.reloaded_at)
      assert.truthy(body.reloaded_at:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"))

      -- Verify shared dict updated
      assert.equals(string.rep("b", 64), mock_scanner_dict["scanner:active_version"])
      assert.equals(15, mock_scanner_dict["scanner:pattern_count"])
      -- loaded_at should be ISO-8601
      assert.truthy(mock_scanner_dict["scanner:loaded_at"]:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"))
    end)

    it("returns 409 when reload lock is held", function()
      mock_scanner_dict["scanner_reload_lock"] = "other_worker"

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_post_reload()

      assert.equals(409, ngx.status)
      local body = cjson.decode(ngx_body_parts[1])
      assert.equals("reload_in_progress", body.error)
      assert.equals("scanner", body.stage)
    end)

    it("returns 500 on internal reload failure", function()
      scanner_reload_error = "scanner_reload_failed:internal_error:-4"

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_post_reload()

      assert.equals(500, ngx.status)
      local body = cjson.decode(ngx_body_parts[1])
      assert.equals("reload_failed", body.error)
      assert.equals("scanner", body.stage)
    end)

    it("returns 500 on rc=-12 reload failure classified as internal", function()
      scanner_reload_error = "scanner_reload_failed:internal_error:-12"

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_post_reload()

      assert.equals(500, ngx.status)
      local body = cjson.decode(ngx_body_parts[1])
      assert.equals("reload_failed", body.error)
      assert.equals("scanner", body.stage)
    end)

    it("returns 400 on validation reload failure", function()
      scanner_reload_error = "scanner_reload_failed:validation_error:-11"

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_post_reload()

      assert.equals(400, ngx.status)
      local body = cjson.decode(ngx_body_parts[1])
      assert.equals("validation_failed", body.error)
      assert.equals("scanner", body.stage)
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

    it("populates scanner:pattern_metadata in shared dict on successful reload", function()
      -- Stub io.popen and io.open for collect_pattern_metadata
      local orig_io_open = io.open
      local orig_io_popen = io.popen

      -- io.popen returns a list of yaml filenames
      io.popen = function()
        local lines = { "sqli.yaml" }
        local idx = 0
        return {
          lines = function()
            return function()
              idx = idx + 1
              return lines[idx]
            end
          end,
          close = function() end,
        }
      end

      -- io.open for the yaml file returns pattern content with quoted values
      -- to verify quote stripping in collect_pattern_metadata().
      io.open = function(path, mode)
        if path and path:find("sqli%.yaml") and (not mode or mode == "r") then
          local content = 'patterns:\n  - threat_type: "sqli"\n'
            .. '    rule_name: "sqli_union"\n    pattern: test\n    score: 0.9\n'
          return {
            read = function(_, fmt)
              if fmt == "*all" or fmt == "*a" then
                return content
              end
              return nil
            end,
            close = function() end,
          }
        end
        -- Return nil for other yaml files so collect_pattern_metadata skips them
        if path and path:find("%.ya?ml") then
          return nil, "no such file"
        end
        return orig_io_open(path, mode)
      end

      scanner_reload_result = {
        version = string.rep("h", 64),
        pattern_count = 1,
      }

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_post_reload()

      assert.equals(200, ngx.status)

      -- Verify scanner:pattern_metadata was written to shared dict
      local meta_json = mock_scanner_dict["scanner:pattern_metadata"]
      assert.is_truthy(meta_json, "scanner:pattern_metadata should be set")
      local meta = cjson.decode(meta_json)
      assert.is_table(meta)
      assert.equals(1, #meta)
      assert.equals("sqli", meta[1].threat_type)
      assert.equals("sqli_union", meta[1].rule_name)
      assert.equals(0.9, meta[1].score)

      -- Restore
      io.open = orig_io_open
      io.popen = orig_io_popen
    end)

    it("returns 500 when metadata update fails (dict:set failure)", function()
      scanner_reload_result = {
        version = string.rep("d", 64),
        pattern_count = 5,
      }
      mock_dict_set_fail_key = "scanner:active_version"

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_post_reload()

      assert.equals(500, ngx.status)
      local body = cjson.decode(ngx_body_parts[1])
      assert.equals("metadata_update_failed", body.error)
      assert.equals("scanner", body.stage)

      -- Lock should be released even on metadata failure
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
      assert.equals("scanner", body.stage)
    end)

    it("returns 413 on oversized body", function()
      request_body = string.rep("x", 1048577) -- > 1MB

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_put_patterns()

      assert.equals(413, ngx.status)
      local body = cjson.decode(ngx_body_parts[1])
      assert.equals("scanner", body.stage)
    end)

    it("returns 409 when reload lock is held", function()
      request_body = "- threat_type: sqli\n  rule_name: test\n  pattern: test\n  score: 0.9"
      mock_scanner_dict["scanner_reload_lock"] = "other_worker"

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_put_patterns()

      assert.equals(409, ngx.status)
      local body = cjson.decode(ngx_body_parts[1])
      assert.equals("reload_in_progress", body.error)
      assert.equals("scanner", body.stage)
    end)

    it("does not write the shared temp file when reload lock is already held", function()
      local orig_io_open = io.open
      local write_attempted = false

      io.open = function(path, mode)
        if path == "conf/scanner-patterns/custom.yaml.tmp" and mode == "w" then
          write_attempted = true
        end
        return orig_io_open(path, mode)
      end

      request_body = "- threat_type: sqli\n  rule_name: test\n  pattern: test\n  score: 0.9"
      mock_scanner_dict["scanner_reload_lock"] = "other_worker"

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_put_patterns()

      assert.equals(409, ngx.status)
      assert.is_false(write_attempted)

      io.open = orig_io_open
    end)

    it("returns reloaded_at in ISO-8601 format on success", function()
      -- This test requires io.open/os.rename stubs which are complex.
      -- The PUT handler writes temp files. For this test we stub io.open
      -- and os.rename at the global level.
      local orig_io_open = io.open
      local orig_os_rename = os.rename
      local orig_os_remove = os.remove

      -- Stub io.open to return a mock file handle
      io.open = function(path, mode)
        if mode == "w" then
          return {
            write = function(_, _content) end,
            close = function() end,
          }
        elseif mode == "r" then
          -- custom.yaml does not exist (new file case)
          return nil, "no such file"
        end
        return orig_io_open(path, mode)
      end
      os.rename = function()
        return true
      end
      os.remove = function()
        return true
      end

      request_body = "patterns:\n  - threat_type: sqli\n    rule_name: test\n    pattern: test\n    score: 0.9"
      scanner_reload_result = {
        version = string.rep("e", 64),
        pattern_count = 1,
      }

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_put_patterns()

      assert.equals(200, ngx.status)
      local body = cjson.decode(ngx_body_parts[1])
      assert.is_string(body.reloaded_at)
      assert.truthy(body.reloaded_at:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"))
      -- Should NOT have 'message' field (replaced by reloaded_at)
      assert.is_nil(body.message)

      -- Restore
      io.open = orig_io_open
      os.rename = orig_os_rename
      os.remove = orig_os_remove
    end)

    it("aborts before rename when backup creation fails for existing custom.yaml", function()
      local orig_io_open = io.open
      local orig_os_rename = os.rename
      local orig_os_remove = os.remove
      local rename_attempted = false
      local removed_paths = {}

      io.open = function(path, mode)
        if path == "conf/scanner-patterns/custom.yaml.tmp" and mode == "w" then
          return {
            write = function() end,
            close = function() end,
          }
        end
        if path == "conf/scanner-patterns/custom.yaml" and mode == "r" then
          return {
            read = function()
              return "old content"
            end,
            close = function() end,
          }
        end
        if path == "conf/scanner-patterns/custom.yaml.bak" and mode == "w" then
          return nil, "permission denied"
        end
        return orig_io_open(path, mode)
      end
      os.rename = function()
        rename_attempted = true
        return true
      end
      os.remove = function(path)
        removed_paths[#removed_paths + 1] = path
        return true
      end

      request_body = "patterns:\n  - threat_type: sqli\n    rule_name: test\n    pattern: test\n    score: 0.9"

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_put_patterns()

      assert.equals(500, ngx.status)
      local body = cjson.decode(ngx_body_parts[1])
      assert.equals("internal_error", body.error)
      assert.equals("scanner", body.stage)
      assert.equals("cannot create backup file", body.details[1])
      assert.is_false(rename_attempted)
      assert.same({ "conf/scanner-patterns/custom.yaml.tmp" }, removed_paths)
      assert.is_nil(mock_scanner_dict["scanner_reload_lock"])

      io.open = orig_io_open
      os.rename = orig_os_rename
      os.remove = orig_os_remove
    end)

    it("returns 200 with metadata_warning when metadata update fails after successful reload", function()
      local orig_io_open = io.open
      local orig_os_rename = os.rename
      local orig_os_remove = os.remove

      io.open = function(path, mode)
        if mode == "w" then
          return {
            write = function() end,
            close = function() end,
          }
        elseif mode == "r" then
          return nil, "no such file"
        end
        return orig_io_open(path, mode)
      end
      os.rename = function()
        return true
      end
      os.remove = function()
        return true
      end

      request_body = "patterns:\n  - threat_type: sqli\n    rule_name: test\n    pattern: test\n    score: 0.9"
      scanner_reload_result = {
        version = string.rep("f", 64),
        pattern_count = 1,
      }
      mock_dict_set_fail_key = "scanner:active_version"

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_put_patterns()

      -- Metadata failure in PUT returns 200 (not 500) because Rust scanner
      -- already holds valid new patterns.  Response includes warning field.
      assert.equals(200, ngx.status)
      local body = cjson.decode(ngx_body_parts[1])
      assert.equals(string.rep("f", 64), body.new_version)
      assert.equals(1, body.pattern_count)
      assert.is_string(body.metadata_warning)
      assert.truthy(body.metadata_warning:find("shared dict update failed"))

      -- Lock should be released
      assert.is_nil(mock_scanner_dict["scanner_reload_lock"])

      -- CRIT log should have been emitted
      local found_crit = false
      for _, entry in ipairs(ngx_log_calls) do
        if entry.level == ngx.CRIT then
          local msg = table.concat(entry.args, "")
          if msg:find("metadata update failed") then
            found_crit = true
            break
          end
        end
      end
      assert.is_true(found_crit, "should log CRIT on metadata failure in PUT")

      -- Restore
      io.open = orig_io_open
      os.rename = orig_os_rename
      os.remove = orig_os_remove
    end)

    it("includes rollback failure detail in error response when reload and rollback both fail", function()
      local orig_io_open = io.open
      local orig_os_rename = os.rename
      local orig_os_remove = os.remove

      io.open = function(path, mode)
        if mode == "w" then
          return {
            write = function() end,
            close = function() end,
          }
        elseif mode == "r" then
          -- custom.yaml exists (had_existing=true)
          return {
            read = function()
              return "old content"
            end,
            close = function() end,
          }
        end
        return orig_io_open(path, mode)
      end
      -- First rename succeeds (tmp -> canonical), rollback rename fails
      local rename_count = 0
      os.rename = function()
        rename_count = rename_count + 1
        if rename_count == 1 then
          return true -- tmp -> canonical
        end
        return false, "disk full" -- bak -> canonical rollback fails
      end
      os.remove = function()
        return true
      end

      request_body = "patterns:\n  - threat_type: sqli\n    rule_name: test\n    pattern: test\n    score: 0.9"
      scanner_reload_error = "scanner_reload_failed:internal_error:-4"

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_put_patterns()

      assert.equals(500, ngx.status)
      local body = cjson.decode(ngx_body_parts[1])
      assert.equals("reload_failed", body.error)
      -- Error detail should mention rollback failure
      assert.truthy(body.details[1]:find("rollback also failed"))

      -- Restore
      io.open = orig_io_open
      os.rename = orig_os_rename
      os.remove = orig_os_remove
    end)
  end)

  describe("audit_log timestamps", function()
    it("uses ISO-8601 format in audit log entries", function()
      scanner_reload_result = {
        version = string.rep("g", 64),
        pattern_count = 3,
      }

      local scanner_admin = require("luagate.admin.scanner")
      scanner_admin.handle_post_reload()

      -- Check that audit log entries contain ISO-8601 timestamps
      local found_iso = false
      for _, entry in ipairs(ngx_log_calls) do
        local msg = table.concat(entry.args, "")
        -- ISO-8601 pattern: YYYY-MM-DDTHH:MM:SSZ
        if msg:match("%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ") then
          found_iso = true
          break
        end
      end
      assert.is_true(found_iso, "audit log should contain ISO-8601 timestamp")
    end)
  end)
end)
