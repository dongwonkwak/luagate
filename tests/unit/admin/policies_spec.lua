--- Unit tests for lua/luagate/admin/policies.lua
-- Implementation: lua/luagate/admin/policies.lua
-- Tests: tests/unit/admin/policies_spec.lua
--
-- policies.lua depends on: cjson.safe, luagate.policy.loader,
-- luagate.policy.parser, luagate.policy.validator, luagate.policy.conflict,
-- resty.sha256, resty.string, and the ngx global.
-- All are stubbed for busted (Lua 5.4) environment.

-- ---------------------------------------------------------------------------
-- cjson.safe stub (dkjson wrapper)
-- ---------------------------------------------------------------------------
package.preload["cjson.safe"] = function()
  local dkjson = require("dkjson")
  return {
    encode = dkjson.encode,
    decode = dkjson.decode,
    null = {},
  }
end

-- ---------------------------------------------------------------------------
-- resty.sha256 stub — deterministic fake hash
-- ---------------------------------------------------------------------------
package.preload["resty.sha256"] = function()
  return {
    new = function()
      local buf = {}
      return {
        update = function(_, s)
          buf[#buf + 1] = s
        end,
        final = function(_)
          return table.concat(buf)
        end,
      }
    end,
  }
end

-- ---------------------------------------------------------------------------
-- resty.string stub — to_hex returns input unchanged
-- ---------------------------------------------------------------------------
package.preload["resty.string"] = function()
  return {
    to_hex = function(s)
      return s
    end,
  }
end

-- ---------------------------------------------------------------------------
-- Configurable stubs for policy modules
-- ---------------------------------------------------------------------------
local _loader_result = {}
local _loader_versions = { http_version = nil, stream_version = nil, source_version = nil }
local _loader_before_lock_hook = nil
local _loader_rollback_result = nil
local _loader_rollback_calls = {}
local _parser_result = nil
local _parser_err = nil
local _validator_ok = true
local _validator_err = nil
local _conflict_conflicts = {}
local _conflict_shadowed = {}

package.preload["luagate.policy.loader"] = function()
  return {
    load_policy = function(_filepath, opts)
      if _loader_before_lock_hook then
        _loader_before_lock_hook()
      end
      if opts and opts.on_lock_acquired then
        local ok, err_code, err_detail = opts.on_lock_acquired()
        if ok == false then
          return {
            ok = false,
            skipped = false,
            new_version = nil,
            previous_http_version = nil,
            previous_stream_version = nil,
            http_ok = false,
            stream_ok = false,
            http_err = nil,
            stream_err = nil,
            conflicts = {},
            shadowed = {},
            err = err_detail or err_code,
            err_code = err_code,
            err_detail = err_detail,
          }
        end
      end
      if _loader_result.ok and not _loader_result.skipped and _loader_result.new_version then
        if _loader_result.http_ok then
          _loader_versions.http_version = _loader_result.new_version
        end
        if _loader_result.stream_ok then
          _loader_versions.stream_version = _loader_result.new_version
        end
        if _loader_result.http_ok and _loader_result.stream_ok then
          _loader_versions.source_version = _loader_result.new_version
        end
      end
      return _loader_result
    end,
    rollback_active_versions = function(versions)
      _loader_rollback_calls[#_loader_rollback_calls + 1] = versions
      _loader_versions.http_version = versions.http_version
      _loader_versions.stream_version = versions.stream_version
      _loader_versions.source_version = versions.source_version
      return _loader_rollback_result
        or {
          ok = true,
          http_ok = true,
          stream_ok = true,
          source_ok = true,
          errors = {},
        }
    end,
    get_active_versions = function()
      return _loader_versions
    end,
    is_reload_in_progress = function()
      return false
    end,
    set_source_version = function(version)
      _loader_versions.source_version = version
      return true, nil
    end,
  }
end

package.preload["luagate.policy.parser"] = function()
  return {
    parse_string = function(_content)
      return _parser_result, _parser_err
    end,
  }
end

package.preload["luagate.policy.validator"] = function()
  return {
    validate = function(_policy)
      return _validator_ok, _validator_err
    end,
  }
end

package.preload["luagate.policy.conflict"] = function()
  return {
    filter_enabled = function(rules)
      return rules
    end,
    detect = function(_rules)
      return _conflict_conflicts, _conflict_shadowed
    end,
  }
end

-- ---------------------------------------------------------------------------
-- Auth mock (always passes)
-- ---------------------------------------------------------------------------
package.preload["luagate.admin.auth"] = function()
  return {
    verify = function()
      return true
    end,
    init = function()
      return true
    end,
  }
end

-- ---------------------------------------------------------------------------
-- io.open monkey-patch
-- ---------------------------------------------------------------------------
local _file_registry = {}
local _file_write_captures = {} -- luacheck: ignore 241
local _file_rename_result = true
local _file_rename_err = nil

local _original_io_open = io.open
local _original_os_rename = os.rename
local _original_os_remove = os.remove

local function setup_io_stubs()
  io.open = function(filepath, mode) -- luacheck: ignore 122
    if mode == "w" then
      -- Capture write operations
      return {
        write = function(_, content)
          _file_write_captures[filepath] = content
        end,
        close = function(_) end,
      },
        nil
    end
    -- Read mode
    local content = _file_registry[filepath]
    if content == nil then
      return nil, "No such file or directory"
    end
    return {
      read = function(_, fmt)
        if fmt == "*all" then
          return content
        end
        return nil
      end,
      close = function(_) end,
    },
      nil
  end

  os.rename = function(_src, _dst) -- luacheck: ignore 122
    return _file_rename_result, _file_rename_err
  end

  os.remove = function(_path) -- luacheck: ignore 122
    return true
  end
end

local function teardown_io_stubs()
  io.open = _original_io_open -- luacheck: ignore 122
  os.rename = _original_os_rename -- luacheck: ignore 122
  os.remove = _original_os_remove -- luacheck: ignore 122
end

-- ---------------------------------------------------------------------------
-- ngx mock factory
-- ---------------------------------------------------------------------------
local function make_ngx(overrides)
  local exited_with = nil
  local logged = {}
  local said = {}

  local mock = {
    var = {
      remote_addr = "127.0.0.1",
      uri = "/api/v1/policies",
    },
    ctx = {},
    header = {},
    status = 0,
    EMERG = 0,
    ALERT = 1,
    CRIT = 2,
    ERR = 3,
    WARN = 4,
    NOTICE = 5,
    INFO = 6,
    DEBUG = 7,
    shared = {
      luagate_policy = {
        get = function(_, _key)
          return nil
        end,
      },
    },
    log = function(_level, ...)
      local parts = {}
      for _, v in ipairs({ ... }) do
        parts[#parts + 1] = tostring(v)
      end
      logged[#logged + 1] = table.concat(parts, "")
    end,
    exit = function(code)
      exited_with = code
    end,
    say = function(s)
      said[#said + 1] = s
    end,
    print = function(_s) end,
    utctime = function()
      return "2026-03-18 06:00:00"
    end,
    now = function()
      return 1742284800.0
    end,
    worker = {
      id = function()
        return 0
      end,
    },
    req = {
      get_headers = function()
        return {}
      end,
      get_method = function()
        return "GET"
      end,
      get_uri_args = function()
        return {}
      end,
      read_body = function() end,
      get_body_data = function()
        return nil
      end,
      get_body_file = function()
        return nil
      end,
    },
  }

  mock._get_exited = function()
    return exited_with
  end
  mock._get_logged = function()
    return logged
  end
  mock._get_said = function()
    return said
  end
  mock._reset_tracking = function()
    exited_with = nil
    for i = 1, #logged do
      logged[i] = nil
    end
    for i = 1, #said do
      said[i] = nil
    end
    mock.status = 0
    mock.header = {}
  end

  if overrides then
    for k, v in pairs(overrides) do
      if type(v) == "table" and type(mock[k]) == "table" then
        for k2, v2 in pairs(v) do
          mock[k][k2] = v2
        end
      else
        mock[k] = v
      end
    end
  end

  return mock
end

-- ---------------------------------------------------------------------------
-- Module loading helper
-- ---------------------------------------------------------------------------
local _saved_ngx = _G.ngx
_G.ngx = make_ngx()

local policies

local function load_policies()
  package.loaded["luagate.admin.policies"] = nil
  package.loaded["luagate.policy.loader"] = nil
  package.loaded["luagate.policy.parser"] = nil
  package.loaded["luagate.policy.validator"] = nil
  package.loaded["luagate.policy.conflict"] = nil
  return require("luagate.admin.policies")
end

-- ---------------------------------------------------------------------------
-- Reset stubs to defaults
-- ---------------------------------------------------------------------------
local function reset_stubs()
  _loader_result = {
    ok = true,
    skipped = false,
    new_version = "new_sha256_hash",
    previous_http_version = "old_sha256_hash",
    previous_stream_version = "old_sha256_hash",
    http_ok = true,
    stream_ok = true,
    http_err = nil,
    stream_err = nil,
    conflicts = {},
    shadowed = {},
    err = nil,
  }
  _loader_versions = {
    http_version = "abc123",
    stream_version = "abc123",
    source_version = "abc123",
  }
  _parser_result = { rules = {}, stream_rules = {}, global = { default_action = "deny" } }
  _parser_err = nil
  _validator_ok = true
  _validator_err = nil
  _loader_before_lock_hook = nil
  _loader_rollback_result = nil
  _loader_rollback_calls = {}
  _conflict_conflicts = {}
  _conflict_shadowed = {}
  _file_registry = {}
  _file_write_captures = {}
  _file_rename_result = true
  _file_rename_err = nil
end

-- ---------------------------------------------------------------------------
-- Teardown
-- ---------------------------------------------------------------------------
teardown(function()
  _G.ngx = _saved_ngx
  teardown_io_stubs()
  package.preload["cjson.safe"] = nil
  package.preload["resty.sha256"] = nil
  package.preload["resty.string"] = nil
  package.preload["luagate.policy.loader"] = nil
  package.preload["luagate.policy.parser"] = nil
  package.preload["luagate.policy.validator"] = nil
  package.preload["luagate.policy.conflict"] = nil
  package.preload["luagate.admin.auth"] = nil
end)

-- ===========================================================================
-- GET /api/v1/policies
-- ===========================================================================
describe("GET /api/v1/policies", function()
  before_each(function()
    reset_stubs()
    setup_io_stubs()
    _file_registry["conf/policies.yaml"] = "version: '1.0'\nrules: []\n"
    _G.ngx = make_ngx({ var = { uri = "/api/v1/policies", remote_addr = "127.0.0.1" } })
    policies = load_policies()
  end)

  after_each(function()
    teardown_io_stubs()
  end)

  it("returns 200 with YAML content and ETag header", function()
    policies.handle_get_policies()

    assert.are.equal(200, _G.ngx.status)
    assert.are.equal("application/x-yaml", _G.ngx.header["Content-Type"])
    assert.truthy(_G.ngx.header["ETag"], "ETag header must be present")
    assert.truthy(_G.ngx.header["ETag"]:find("abc123"), "ETag should contain source_version")
    local said = _G.ngx._get_said()
    assert.is_true(#said >= 1)
    assert.truthy(said[1]:find("version"), "response body should contain YAML content")
  end)

  it("computes ETag from file content when source_version is nil", function()
    _loader_versions.source_version = nil
    _G.ngx = make_ngx({ var = { uri = "/api/v1/policies", remote_addr = "127.0.0.1" } })
    policies = load_policies()

    policies.handle_get_policies()

    assert.are.equal(200, _G.ngx.status)
    assert.truthy(_G.ngx.header["ETag"], "ETag should be computed from file content")
  end)

  it("returns 500 when policy file cannot be read", function()
    _file_registry["conf/policies.yaml"] = nil -- file not found
    _G.ngx = make_ngx({ var = { uri = "/api/v1/policies", remote_addr = "127.0.0.1" } })
    policies = load_policies()

    policies.handle_get_policies()

    assert.are.equal(500, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("internal_error", body.error)
  end)
end)

-- ===========================================================================
-- GET /api/v1/policies/version
-- ===========================================================================
describe("GET /api/v1/policies/version", function()
  before_each(function()
    reset_stubs()
    _G.ngx = make_ngx({ var = { uri = "/api/v1/policies/version", remote_addr = "127.0.0.1" } })
    policies = load_policies()
  end)

  it("returns 200 with version triplet", function()
    policies.handle_get_version()

    assert.are.equal(200, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("abc123", body.source_version)
    assert.are.equal("abc123", body.active_http_version)
    assert.are.equal("abc123", body.active_stream_version)
    assert.are.equal("abc123", body.etag)
  end)
end)

-- ===========================================================================
-- PUT /api/v1/policies
-- ===========================================================================
describe("PUT /api/v1/policies", function()
  local yaml_body = "version: '1.0'\nrules: []\nstream_rules: []\n"

  before_each(function()
    reset_stubs()
    setup_io_stubs()
    _file_registry["conf/policies.yaml"] = yaml_body
    _G.ngx = make_ngx({
      var = { uri = "/api/v1/policies", remote_addr = "127.0.0.1" },
    })
    _G.ngx.req.get_headers = function()
      return {
        ["If-Match"] = '"abc123"',
        Authorization = "Bearer valid-test-token",
      }
    end
    _G.ngx.req.get_method = function()
      return "PUT"
    end
    _G.ngx.req.get_body_data = function()
      return yaml_body
    end
    policies = load_policies()
  end)

  after_each(function()
    teardown_io_stubs()
  end)

  it("returns 200 on successful update", function()
    policies.handle_put_policies()

    assert.are.equal(200, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("committed", body.http_result)
    assert.are.equal("committed", body.stream_result)
    assert.truthy(body.new_http_version)
    assert.truthy(body.new_stream_version)
    assert.is_table(body.warnings)
  end)

  it("returns 428 when If-Match header is missing", function()
    _G.ngx.req.get_headers = function()
      return { Authorization = "Bearer valid-test-token" }
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(428, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("version_mismatch", body.error)
  end)

  it("returns 409 when If-Match does not match source_version", function()
    _G.ngx.req.get_headers = function()
      return {
        ["If-Match"] = '"wrong_version"',
        Authorization = "Bearer valid-test-token",
      }
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(409, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("version_mismatch", body.error)
    assert.are.equal("reload", body.stage)
  end)

  it("passes If-Match when source_version is nil and file SHA256 matches", function()
    _loader_versions.source_version = nil
    -- stub sha256: to_hex(final()) returns raw content, so If-Match must equal file content
    _G.ngx.req.get_headers = function()
      return {
        ["If-Match"] = '"' .. yaml_body .. '"',
        Authorization = "Bearer valid-test-token",
      }
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(200, _G.ngx.status)
  end)

  it("returns 409 when source_version is nil and If-Match does not match file SHA256", function()
    _loader_versions.source_version = nil
    _G.ngx.req.get_headers = function()
      return {
        ["If-Match"] = '"wrong_version"',
        Authorization = "Bearer valid-test-token",
      }
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(409, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("version_mismatch", body.error)
  end)

  it("returns 500 when source_version is nil and policy file is unreadable (fail-closed)", function()
    _loader_versions.source_version = nil
    _file_registry["conf/policies.yaml"] = nil -- simulate unreadable file
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(500, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("internal_error", body.error)
  end)

  it("returns 409 when source_version changes after the initial If-Match check", function()
    _loader_before_lock_hook = function()
      _loader_versions.source_version = "def456"
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(409, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("version_mismatch", body.error)
    assert.are.equal("reload", body.stage)
    assert.truthy(body.details[1]:find("expected def456"))
  end)

  it("returns 500 when source_version becomes nil after lock and file is unreadable (fail-closed)", function()
    -- Initial check passes with source_version set
    -- After lock acquired, source_version becomes nil and file is removed
    _loader_before_lock_hook = function()
      _loader_versions.source_version = nil
      _file_registry["conf/policies.yaml"] = nil
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(500, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("internal_error", body.error)
    assert.are.equal("reload", body.stage)
  end)

  it("returns 413 when body is missing", function()
    _G.ngx.req.get_body_data = function()
      return nil
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(413, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("payload_too_large", body.error)
  end)

  it("accepts request bodies buffered to a temp file", function()
    _file_registry["/tmp/client-body-buffered.yaml"] = yaml_body
    _G.ngx.req.get_body_data = function()
      return nil
    end
    _G.ngx.req.get_body_file = function()
      return "/tmp/client-body-buffered.yaml"
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(200, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("committed", body.http_result)
    assert.are.equal("committed", body.stream_result)
  end)

  it("returns 413 when a buffered temp file exceeds 1MB", function()
    _file_registry["/tmp/client-body-too-large.yaml"] = string.rep("a", 1048577)
    _G.ngx.req.get_body_data = function()
      return nil
    end
    _G.ngx.req.get_body_file = function()
      return "/tmp/client-body-too-large.yaml"
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(413, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("payload_too_large", body.error)
    assert.are.equal("request", body.stage)
  end)

  it("returns 422 when parse fails", function()
    _parser_result = nil
    _parser_err = "YAML syntax error at line 42"
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(422, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("validation_failed", body.error)
    assert.are.equal("validate", body.stage)
    assert.truthy(body.details[1]:find("parse error"))
  end)

  it("returns 422 when validation fails", function()
    _validator_ok = nil
    _validator_err = "rule 'my-rule': action must be 'allow' or 'deny'"
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(422, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("validation_failed", body.error)
    assert.are.equal("validate", body.stage)
  end)

  it("returns 409 when reload_in_progress", function()
    _loader_result = {
      ok = false,
      skipped = false,
      err = "reload_in_progress",
      conflicts = {},
      shadowed = {},
      http_ok = false,
      stream_ok = false,
    }
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(409, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("reload_in_progress", body.error)
  end)

  it("returns 500 on partial commit (stream fails)", function()
    _loader_result = {
      ok = true,
      skipped = false,
      new_version = "new_sha",
      previous_http_version = "old_sha",
      previous_stream_version = "old_sha",
      http_ok = true,
      stream_ok = false,
      http_err = nil,
      stream_err = "stream pointer swap failed",
      conflicts = {},
      shadowed = {},
      err = nil,
    }
    _loader_versions.http_version = "new_sha"
    _loader_versions.stream_version = "old_sha"
    _loader_versions.source_version = "abc123"
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(500, _G.ngx.status)
    assert.are.equal(1, #_loader_rollback_calls)
    assert.are.same({
      http_version = "old_sha",
      stream_version = "old_sha",
      source_version = "abc123",
    }, _loader_rollback_calls[1])
    assert.are.equal("old_sha", _loader_versions.http_version)
    assert.are.equal("old_sha", _loader_versions.stream_version)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("commit_failed", body.error)
    assert.are.equal("commit", body.stage)
    assert.truthy(body.details[1]:find("stream"))
    assert.are.equal("old_sha", body.current_http_version)
    assert.are.equal("old_sha", body.current_stream_version)
  end)

  it("returns 500 when canonical file rename fails", function()
    _file_rename_result = nil
    _file_rename_err = "permission denied"
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(500, _G.ngx.status)
    assert.are.equal(1, #_loader_rollback_calls)
    assert.are.same({
      http_version = "old_sha256_hash",
      stream_version = "old_sha256_hash",
      source_version = "abc123",
    }, _loader_rollback_calls[1])
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("commit_failed", body.error)
    assert.truthy(body.details[1]:find("canonical file write failed"))
    assert.falsy(body.details[2], "successful rollback should not report active/canonical inconsistency")
    assert.are.equal("old_sha256_hash", body.current_http_version)
    assert.are.equal("old_sha256_hash", body.current_stream_version)
  end)

  it("returns 422 conflict_detected when conflicts found (admin-api.md §3)", function()
    _conflict_conflicts = {
      { rule_ids = { "rule-a", "rule-b" }, message = "same scope, priority, opposing action" },
    }
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(422, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("conflict_detected", body.error)
    assert.are.equal("conflict_detect", body.stage)
    assert.truthy(body.details[1]:find("rule%-a"))
  end)

  it("writes policy_update_success audit log on success", function()
    policies.handle_put_policies()

    local logged = _G.ngx._get_logged()
    local has_audit = false
    for _, entry in ipairs(logged) do
      if entry:find("%[luagate:audit%]") and entry:find("policy_update_success") then
        has_audit = true
        break
      end
    end
    assert.is_true(has_audit, "audit log for policy_update_success should be written")
  end)

  it("writes policy_update_failure audit log on failure", function()
    _loader_result = {
      ok = false,
      skipped = false,
      err = "blob store failed",
      conflicts = {},
      shadowed = {},
      http_ok = false,
      stream_ok = false,
    }
    policies = load_policies()

    policies.handle_put_policies()

    local logged = _G.ngx._get_logged()
    local has_audit = false
    for _, entry in ipairs(logged) do
      if entry:find("%[luagate:audit%]") and entry:find("policy_update_failure") then
        has_audit = true
        break
      end
    end
    assert.is_true(has_audit, "audit log for policy_update_failure should be written")
  end)

  it("returns 200 and backfills source_version when result.skipped and source_version is nil", function()
    -- Simulate: hash unchanged (skipped), but source_version never committed
    _loader_versions.source_version = nil
    _loader_result = {
      ok = true,
      skipped = true,
      new_version = nil,
      previous_http_version = "abc123",
      previous_stream_version = "abc123",
      http_ok = true,
      stream_ok = true,
      http_err = nil,
      stream_err = nil,
      conflicts = {},
      shadowed = {},
      err = nil,
    }
    -- If-Match must equal the computed SHA256 of the file content (stub: content itself)
    _G.ngx.req.get_headers = function()
      return {
        ["If-Match"] = '"' .. yaml_body .. '"',
        Authorization = "Bearer valid-test-token",
      }
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(200, _G.ngx.status)
    -- source_version should now be backfilled with the computed SHA256 (= yaml_body in stub)
    assert.are.equal(yaml_body, _loader_versions.source_version)
  end)

  it("returns 200 and logs WARN when set_source_version fails during backfill", function()
    -- Simulate: hash unchanged (skipped), source_version nil triggers backfill
    _loader_versions.source_version = nil
    _loader_result = {
      ok = true,
      skipped = true,
      new_version = nil,
      previous_http_version = "abc123",
      previous_stream_version = "abc123",
      http_ok = true,
      stream_ok = true,
      http_err = nil,
      stream_err = nil,
      conflicts = {},
      shadowed = {},
      err = nil,
    }
    _G.ngx.req.get_headers = function()
      return {
        ["If-Match"] = '"' .. yaml_body .. '"',
        Authorization = "Bearer valid-test-token",
      }
    end
    policies = load_policies()

    -- Override set_source_version on the cached loader to simulate failure
    local loader = package.loaded["luagate.policy.loader"]
    loader.set_source_version = function(_version)
      return false, "shdict full"
    end

    policies.handle_put_policies()

    -- Should still return 200 (non-fatal failure)
    assert.are.equal(200, _G.ngx.status)
    -- source_version should remain nil (backfill failed)
    assert.is_nil(_loader_versions.source_version)
    -- WARN log should contain the failure message
    local logged = _G.ngx._get_logged()
    local has_warn = false
    for _, entry in ipairs(logged) do
      if entry:find("source_version backfill failed") and entry:find("shdict full") then
        has_warn = true
        break
      end
    end
    assert.is_true(has_warn, "WARN log for source_version backfill failure should be written")
  end)

  it("returns 200 and does NOT overwrite source_version when result.skipped and source_version exists", function()
    -- Simulate: hash unchanged (skipped), source_version already present
    _loader_versions.source_version = "existing_hash"
    _loader_result = {
      ok = true,
      skipped = true,
      new_version = nil,
      previous_http_version = "abc123",
      previous_stream_version = "abc123",
      http_ok = true,
      stream_ok = true,
      http_err = nil,
      stream_err = nil,
      conflicts = {},
      shadowed = {},
      err = nil,
    }
    _G.ngx.req.get_headers = function()
      return {
        ["If-Match"] = '"existing_hash"',
        Authorization = "Bearer valid-test-token",
      }
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(200, _G.ngx.status)
    -- source_version should remain unchanged (no overwrite)
    assert.are.equal("existing_hash", _loader_versions.source_version)
  end)

  it("rejects Content-Encoding header", function()
    _G.ngx.req.get_headers = function()
      return {
        ["If-Match"] = '"abc123"',
        ["Content-Encoding"] = "gzip",
        Authorization = "Bearer valid-test-token",
      }
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(422, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("validation_failed", body.error)
  end)

  it("rejects body with UTF-8 BOM", function()
    local bom_body = string.char(0xEF, 0xBB, 0xBF) .. "version: '1.0'\nrules: []\n"
    _G.ngx.req.get_body_data = function()
      return bom_body
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(422, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("validation_failed", body.error)
    assert.are.equal("request", body.stage)
    assert.truthy(body.details[1]:find("BOM"))
  end)

  it("rejects body with UTF-16 LE BOM", function()
    local bom_body = string.char(0xFF, 0xFE) .. "version: '1.0'\nrules: []\n"
    _G.ngx.req.get_body_data = function()
      return bom_body
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(422, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("validation_failed", body.error)
    assert.truthy(body.details[1]:find("BOM"))
    assert.truthy(body.details[1]:find("UTF%-16 LE"))
  end)

  it("rejects body with UTF-16 BE BOM", function()
    local bom_body = string.char(0xFE, 0xFF) .. "version: '1.0'\nrules: []\n"
    _G.ngx.req.get_body_data = function()
      return bom_body
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(422, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("validation_failed", body.error)
    assert.truthy(body.details[1]:find("BOM"))
    assert.truthy(body.details[1]:find("UTF%-16 BE"))
  end)

  it("rejects body with UTF-32 LE BOM", function()
    local bom_body = string.char(0xFF, 0xFE, 0x00, 0x00) .. "version: '1.0'\nrules: []\n"
    _G.ngx.req.get_body_data = function()
      return bom_body
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(422, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("validation_failed", body.error)
    assert.truthy(body.details[1]:find("BOM"))
    assert.truthy(body.details[1]:find("UTF%-32 LE"))
  end)

  it("rejects body with UTF-32 BE BOM", function()
    local bom_body = string.char(0x00, 0x00, 0xFE, 0xFF) .. "version: '1.0'\nrules: []\n"
    _G.ngx.req.get_body_data = function()
      return bom_body
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(422, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("validation_failed", body.error)
    assert.truthy(body.details[1]:find("BOM"))
    assert.truthy(body.details[1]:find("UTF%-32 BE"))
  end)

  it("rejects non-UTF-8 charset in Content-Type", function()
    _G.ngx.req.get_headers = function()
      return {
        ["If-Match"] = '"abc123"',
        ["Content-Type"] = "application/x-yaml; charset=iso-8859-1",
        Authorization = "Bearer valid-test-token",
      }
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(422, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("validation_failed", body.error)
    assert.are.equal("request", body.stage)
    assert.truthy(body.details[1]:find("UTF%-8"))
  end)

  it("rejects repeated Content-Type headers with non-UTF-8 charset without 500", function()
    _G.ngx.req.get_headers = function()
      return {
        ["If-Match"] = '"abc123"',
        ["Content-Type"] = {
          "application/x-yaml; charset=iso-8859-1",
          "application/x-yaml; charset=utf-8",
        },
        Authorization = "Bearer valid-test-token",
      }
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(422, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("validation_failed", body.error)
    assert.are.equal("request", body.stage)
    assert.truthy(body.details[1]:find("UTF%-8"))
  end)

  it("accepts charset=UTF-8 (case insensitive) in Content-Type", function()
    _G.ngx.req.get_headers = function()
      return {
        ["If-Match"] = '"abc123"',
        ["Content-Type"] = "application/x-yaml; charset=UTF-8",
        Authorization = "Bearer valid-test-token",
      }
    end
    policies = load_policies()

    policies.handle_put_policies()

    -- Should pass charset check and proceed to later stages (200 success)
    assert.are.equal(200, _G.ngx.status)
  end)

  it("accepts charset=utf-8 (lowercase) in Content-Type", function()
    _G.ngx.req.get_headers = function()
      return {
        ["If-Match"] = '"abc123"',
        ["Content-Type"] = "application/x-yaml; charset=utf-8",
        Authorization = "Bearer valid-test-token",
      }
    end
    policies = load_policies()

    policies.handle_put_policies()

    -- lowercase utf-8 should also pass charset check
    assert.are.equal(200, _G.ngx.status)
  end)

  it("rejects non-UTF-8 charset with uppercase key (Charset=)", function()
    _G.ngx.req.get_headers = function()
      return {
        ["If-Match"] = '"abc123"',
        ["Content-Type"] = "application/x-yaml; Charset=iso-8859-1",
        Authorization = "Bearer valid-test-token",
      }
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(422, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("validation_failed", body.error)
    assert.truthy(body.details[1]:find("UTF%-8"))
  end)

  it("rejects non-UTF-8 charset with spaces around '='", function()
    _G.ngx.req.get_headers = function()
      return {
        ["If-Match"] = '"abc123"',
        ["Content-Type"] = "application/x-yaml; charset = iso-8859-1",
        Authorization = "Bearer valid-test-token",
      }
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(422, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("validation_failed", body.error)
    assert.truthy(body.details[1]:find("UTF%-8"))
  end)

  it('accepts quoted charset="utf-8"', function()
    _G.ngx.req.get_headers = function()
      return {
        ["If-Match"] = '"abc123"',
        ["Content-Type"] = 'application/x-yaml; charset="utf-8"',
        Authorization = "Bearer valid-test-token",
      }
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(200, _G.ngx.status)
  end)

  it("accepts Content-Type without charset (assumes UTF-8)", function()
    _G.ngx.req.get_headers = function()
      return {
        ["If-Match"] = '"abc123"',
        ["Content-Type"] = "application/x-yaml",
        Authorization = "Bearer valid-test-token",
      }
    end
    policies = load_policies()

    policies.handle_put_policies()

    -- Should pass charset check and proceed to later stages (200 success)
    assert.are.equal(200, _G.ngx.status)
  end)
end)

-- ===========================================================================
-- PUT /api/v1/policies?dry_run=true
-- ===========================================================================
describe("PUT /api/v1/policies?dry_run=true", function()
  local yaml_body = "version: '1.0'\nrules: []\nstream_rules: []\n"

  before_each(function()
    reset_stubs()
    setup_io_stubs()
    _file_registry["conf/policies.yaml"] = yaml_body
    _G.ngx = make_ngx({
      var = { uri = "/api/v1/policies", remote_addr = "127.0.0.1" },
    })
    _G.ngx.req.get_headers = function()
      return {
        Authorization = "Bearer valid-test-token",
      }
    end
    _G.ngx.req.get_method = function()
      return "PUT"
    end
    _G.ngx.req.get_body_data = function()
      return yaml_body
    end
    _G.ngx.req.get_uri_args = function()
      return { dry_run = "true" }
    end
    policies = load_policies()
  end)

  after_each(function()
    teardown_io_stubs()
  end)

  it("returns 200 with validation results (no commit)", function()
    policies.handle_put_policies()

    assert.are.equal(200, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.is_true(body.dry_run)
    assert.is_true(body.valid)
    assert.truthy(body.version_hash)
    assert.is_table(body.warnings)
    assert.are.equal(0, #body.warnings)
    assert.is_table(body.shadowed)
    assert.is_number(body.http_rules_count)
    assert.is_number(body.stream_rules_count)
  end)

  it("does not require If-Match header", function()
    -- No If-Match provided, should still succeed
    policies.handle_put_policies()

    assert.are.equal(200, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.is_true(body.dry_run)
  end)

  it("echoes ETag when If-Match is provided and valid", function()
    _G.ngx.req.get_headers = function()
      return {
        ["If-Match"] = '"abc123"',
        Authorization = "Bearer valid-test-token",
      }
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(200, _G.ngx.status)
    assert.are.equal('"abc123"', _G.ngx.header["ETag"])
  end)

  it("returns 409 when If-Match header mismatches", function()
    _G.ngx.req.get_headers = function()
      return {
        ["If-Match"] = '"wrong_version"',
        Authorization = "Bearer valid-test-token",
      }
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(409, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("version_mismatch", body.error)
  end)

  it("returns 422 on parse failure with details", function()
    _parser_result = nil
    _parser_err = "YAML syntax error at line 42"
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(422, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("validation_failed", body.error)
    assert.are.equal("validate", body.stage)
    assert.is_table(body.details)
    assert.truthy(body.details[1]:find("parse error"))
  end)

  it("returns 422 on validation failure with details", function()
    _validator_ok = nil
    _validator_err = "rule 'my-rule': action must be 'allow' or 'deny'"
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(422, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("validation_failed", body.error)
    assert.is_table(body.details)
    assert.truthy(body.details[1]:find("action must be"))
  end)

  it("reports conflicts as warnings (not 422)", function()
    _conflict_conflicts = {
      { rule_a = "rule-a", rule_b = "rule-b", overlap_type = "exact" },
    }
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(200, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.is_true(body.dry_run)
    assert.are.equal(1, #body.warnings)
    assert.are.equal("conflict", body.warnings[1].type)
    assert.are.same({ "rule-a", "rule-b" }, body.warnings[1].rule_ids)
    assert.are.equal("same scope, priority, opposing action", body.warnings[1].message)
  end)

  it("does not write audit log", function()
    policies.handle_put_policies()

    local logged = _G.ngx._get_logged()
    for _, entry in ipairs(logged) do
      assert.falsy(entry:find("%[luagate:audit%]"), "dry_run should not produce audit log entries")
    end
  end)

  it("rejects body with UTF-8 BOM even in dry_run mode", function()
    local bom_body = string.char(0xEF, 0xBB, 0xBF) .. "version: '1.0'\nrules: []\n"
    _G.ngx.req.get_body_data = function()
      return bom_body
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(422, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("validation_failed", body.error)
    assert.are.equal("request", body.stage)
    assert.truthy(body.details[1]:find("BOM"))
  end)

  it("rejects non-UTF-8 charset even in dry_run mode", function()
    _G.ngx.req.get_headers = function()
      return {
        ["Content-Type"] = "application/x-yaml; charset=iso-8859-1",
        Authorization = "Bearer valid-test-token",
      }
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(422, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("validation_failed", body.error)
    assert.are.equal("request", body.stage)
    assert.truthy(body.details[1]:find("UTF%-8"))
  end)

  it("rejects repeated Content-Type headers in dry_run mode without 500", function()
    _G.ngx.req.get_headers = function()
      return {
        ["Content-Type"] = {
          "application/x-yaml; charset=iso-8859-1",
          "application/x-yaml; charset=utf-8",
        },
        Authorization = "Bearer valid-test-token",
      }
    end
    policies = load_policies()

    policies.handle_put_policies()

    assert.are.equal(422, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("validation_failed", body.error)
    assert.are.equal("request", body.stage)
    assert.truthy(body.details[1]:find("UTF%-8"))
  end)

  it("does not call loader.load_policy", function()
    local load_policy_called = false
    local loader_mod = require("luagate.policy.loader")
    local original_load = loader_mod.load_policy
    loader_mod.load_policy = function(...)
      load_policy_called = true
      return original_load(...)
    end

    policies.handle_put_policies()

    loader_mod.load_policy = original_load
    assert.are.equal(200, _G.ngx.status)
    assert.is_false(load_policy_called, "loader.load_policy must not be called during dry_run")
  end)
end)

-- ===========================================================================
-- POST /api/v1/policies/reload
-- ===========================================================================
describe("POST /api/v1/policies/reload", function()
  before_each(function()
    reset_stubs()
    setup_io_stubs()
    _G.ngx = make_ngx({
      var = { uri = "/api/v1/policies/reload", remote_addr = "127.0.0.1" },
    })
    _G.ngx.req.get_method = function()
      return "POST"
    end
    policies = load_policies()
  end)

  after_each(function()
    teardown_io_stubs()
  end)

  it("returns 200 on successful reload", function()
    policies.handle_post_reload()

    assert.are.equal(200, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("committed", body.http_result)
    assert.are.equal("committed", body.stream_result)
    assert.truthy(body.reloaded_at)
    assert.are.equal(0, body.warnings_count)
    assert.is_table(body.errors)
    assert.are.equal(0, #body.errors)
  end)

  it("returns 409 when If-Match does not match http:active_version", function()
    _G.ngx.req.get_headers = function()
      return {
        ["If-Match"] = '"wrong_version"',
        Authorization = "Bearer valid-test-token",
      }
    end
    policies = load_policies()

    policies.handle_post_reload()

    assert.are.equal(409, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("version_mismatch", body.error)
  end)

  it("succeeds when If-Match matches http:active_version", function()
    _G.ngx.req.get_headers = function()
      return {
        ["If-Match"] = '"abc123"',
        Authorization = "Bearer valid-test-token",
      }
    end
    policies = load_policies()

    policies.handle_post_reload()

    assert.are.equal(200, _G.ngx.status)
  end)

  it("succeeds when If-Match is not provided (optional)", function()
    _G.ngx.req.get_headers = function()
      return { Authorization = "Bearer valid-test-token" }
    end
    policies = load_policies()

    policies.handle_post_reload()

    assert.are.equal(200, _G.ngx.status)
  end)

  it("returns 409 when reload_in_progress", function()
    _loader_result = {
      ok = false,
      skipped = false,
      err = "reload_in_progress",
      conflicts = {},
      shadowed = {},
      http_ok = false,
      stream_ok = false,
    }
    policies = load_policies()

    policies.handle_post_reload()

    assert.are.equal(409, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("reload_in_progress", body.error)
    assert.are.equal("reload", body.stage)
  end)

  it("returns 500 on reload failure (LKG retained)", function()
    _loader_result = {
      ok = false,
      skipped = false,
      err = "parse error at line 42: unexpected token",
      conflicts = {},
      shadowed = {},
      http_ok = false,
      stream_ok = false,
    }
    policies = load_policies()

    policies.handle_post_reload()

    assert.are.equal(500, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("reload_failed", body.error)
    assert.are.equal("reload", body.stage)
    assert.truthy(body.details[1]:find("parse error"))
  end)

  it("handles partial commit (HTTP ok, stream fail)", function()
    _loader_result = {
      ok = true,
      skipped = false,
      new_version = "new_sha",
      previous_http_version = "old_sha",
      previous_stream_version = "old_sha",
      http_ok = true,
      stream_ok = false,
      http_err = nil,
      stream_err = "stream pointer swap failed",
      conflicts = {},
      shadowed = {},
      err = nil,
    }
    policies = load_policies()

    policies.handle_post_reload()

    assert.are.equal(200, _G.ngx.status)
    local said = _G.ngx._get_said()
    local dkjson = require("dkjson")
    local body = dkjson.decode(said[1])
    assert.are.equal("committed", body.http_result)
    assert.are.equal("lkg_retained", body.stream_result)
    assert.are.equal(1, #body.errors)
    assert.truthy(body.errors[1]:find("stream"))
  end)

  it("writes audit log with subsystem on reload success", function()
    policies.handle_post_reload()

    local logged = _G.ngx._get_logged()
    local has_audit = false
    local has_subsystem = false
    for _, entry in ipairs(logged) do
      if entry:find("%[luagate:audit%]") and entry:find("policy_reload_success") then
        has_audit = true
        if entry:find('"subsystem"') then
          has_subsystem = true
        end
        break
      end
    end
    assert.is_true(has_audit, "audit log for reload success should be written")
    assert.is_true(has_subsystem, "reload success audit must include subsystem field")
  end)

  it("writes audit log on reload failure", function()
    _loader_result = {
      ok = false,
      skipped = false,
      err = "file read error",
      conflicts = {},
      shadowed = {},
      http_ok = false,
      stream_ok = false,
    }
    policies = load_policies()

    policies.handle_post_reload()

    local logged = _G.ngx._get_logged()
    local has_audit = false
    for _, entry in ipairs(logged) do
      if entry:find("%[luagate:audit%]") and entry:find("policy_reload_failure") then
        has_audit = true
        break
      end
    end
    assert.is_true(has_audit, "audit log for reload failure should be written")
  end)
end)

-- ---------------------------------------------------------------------------
-- MCP metadata in audit logs (ADR-011 §8)
-- ---------------------------------------------------------------------------
describe("MCP metadata in audit logs", function()
  before_each(function()
    reset_stubs()
    setup_io_stubs()
  end)

  after_each(function()
    teardown_io_stubs()
  end)

  it("includes actor_type='mcp' and MCP fields when X-MCP-Client header is present", function()
    _file_registry["conf/policies.yaml"] = "global:\n  default_action: allow\nrules: []\nstream_rules: []"
    _loader_versions = { http_version = "abc123", stream_version = "abc123", source_version = "abc123" }
    _loader_result = {
      ok = true,
      skipped = false,
      new_version = "new_hash",
      previous_http_version = "abc123",
      previous_stream_version = "abc123",
      http_ok = true,
      stream_ok = true,
      conflicts = {},
      shadowed = {},
    }
    _parser_result = { global = { default_action = "allow" }, rules = {}, stream_rules = {} }

    _G.ngx = make_ngx({
      var = { uri = "/api/v1/policies", remote_addr = "127.0.0.1" },
    })
    _G.ngx.req.get_headers = function()
      return {
        ["Content-Type"] = "application/x-yaml",
        ["If-Match"] = "abc123",
        ["X-MCP-Client"] = "claude-desktop",
        ["X-MCP-Tool"] = "luagate_update_policies",
        ["X-MCP-Session-Id"] = "sess-abc123",
        ["X-Request-ID"] = "req-xyz789",
      }
    end
    _G.ngx.req.get_method = function()
      return "PUT"
    end
    _G.ngx.req.get_body_data = function()
      return "global:\n  default_action: allow\nrules: []\nstream_rules: []"
    end

    policies = load_policies()
    policies.handle_put_policies()

    local logged = _G.ngx._get_logged()
    local found_mcp = false
    for _, entry in ipairs(logged) do
      if entry:find("%[luagate:audit%]") and entry:find('"actor_type":"mcp"') then
        found_mcp = true
        assert.truthy(entry:find('"client_name":"claude%-desktop"'), "should include client_name")
        assert.truthy(entry:find('"tool_name":"luagate_update_policies"'), "should include tool_name")
        assert.truthy(entry:find('"session_id":"sess%-abc123"'), "should include session_id")
        assert.truthy(entry:find('"request_id":"req%-xyz789"'), "should include request_id")
        break
      end
    end
    assert.is_true(found_mcp, "audit log should contain actor_type='mcp' with MCP metadata")
  end)

  it("normalizes duplicate MCP headers to scalar audit fields", function()
    _file_registry["conf/policies.yaml"] = "global:\n  default_action: allow\nrules: []\nstream_rules: []"
    _loader_versions = { http_version = "abc123", stream_version = "abc123", source_version = "abc123" }
    _loader_result = {
      ok = true,
      skipped = false,
      new_version = "new_hash",
      previous_http_version = "abc123",
      previous_stream_version = "abc123",
      http_ok = true,
      stream_ok = true,
      conflicts = {},
      shadowed = {},
    }
    _parser_result = { global = { default_action = "allow" }, rules = {}, stream_rules = {} }

    _G.ngx = make_ngx({
      var = { uri = "/api/v1/policies", remote_addr = "127.0.0.1" },
    })
    _G.ngx.req.get_headers = function()
      return {
        ["Content-Type"] = "application/x-yaml",
        ["If-Match"] = "abc123",
        ["X-MCP-Client"] = { "claude-desktop", "duplicate-client" },
        ["X-MCP-Tool"] = { "luagate_update_policies", "duplicate-tool" },
        ["X-MCP-Session-Id"] = { "sess-abc123", "duplicate-session" },
        ["X-Request-ID"] = { "req-xyz789", "duplicate-request" },
      }
    end
    _G.ngx.req.get_method = function()
      return "PUT"
    end
    _G.ngx.req.get_body_data = function()
      return "global:\n  default_action: allow\nrules: []\nstream_rules: []"
    end

    policies = load_policies()
    policies.handle_put_policies()

    local logged = _G.ngx._get_logged()
    local found_mcp = false
    for _, entry in ipairs(logged) do
      if entry:find("%[luagate:audit%]") and entry:find('"actor_type":"mcp"') then
        found_mcp = true
        assert.truthy(entry:find('"client_name":"claude%-desktop"'), "should normalize client_name to string")
        assert.truthy(entry:find('"tool_name":"luagate_update_policies"'), "should normalize tool_name to string")
        assert.truthy(entry:find('"session_id":"sess%-abc123"'), "should normalize session_id to string")
        assert.truthy(entry:find('"request_id":"req%-xyz789"'), "should normalize request_id to string")
        assert.falsy(entry:find('"client_name"%s*:%s*%['), "client_name must not be encoded as array")
        assert.falsy(entry:find('"tool_name"%s*:%s*%['), "tool_name must not be encoded as array")
        assert.falsy(entry:find('"session_id"%s*:%s*%['), "session_id must not be encoded as array")
        assert.falsy(entry:find('"request_id"%s*:%s*%['), "request_id must not be encoded as array")
        break
      end
    end
    assert.is_true(found_mcp, "audit log should contain scalar MCP metadata when headers are repeated")
  end)

  it("includes actor_type='api' when no MCP headers are present (backward compatible)", function()
    _file_registry["conf/policies.yaml"] = "global:\n  default_action: allow\nrules: []\nstream_rules: []"
    _loader_versions = { http_version = "abc123", stream_version = "abc123", source_version = "abc123" }
    _loader_result = {
      ok = true,
      skipped = false,
      new_version = "new_hash",
      previous_http_version = "abc123",
      previous_stream_version = "abc123",
      http_ok = true,
      stream_ok = true,
      conflicts = {},
      shadowed = {},
    }
    _parser_result = { global = { default_action = "allow" }, rules = {}, stream_rules = {} }

    _G.ngx = make_ngx({
      var = { uri = "/api/v1/policies", remote_addr = "127.0.0.1" },
    })
    _G.ngx.req.get_headers = function()
      return {
        ["Content-Type"] = "application/x-yaml",
        ["If-Match"] = "abc123",
      }
    end
    _G.ngx.req.get_method = function()
      return "PUT"
    end
    _G.ngx.req.get_body_data = function()
      return "global:\n  default_action: allow\nrules: []\nstream_rules: []"
    end

    policies = load_policies()
    policies.handle_put_policies()

    local logged = _G.ngx._get_logged()
    local found_api = false
    local found_mcp_fields = false
    for _, entry in ipairs(logged) do
      if entry:find("%[luagate:audit%]") and entry:find('"actor_type":"api"') then
        found_api = true
        if entry:find('"client_name"') then
          found_mcp_fields = true
        end
        break
      end
    end
    assert.is_true(found_api, "audit log should contain actor_type='api'")
    assert.is_false(found_mcp_fields, "MCP-specific fields should not be present for plain API calls")
  end)

  it("includes actor_type in reload audit logs with MCP headers", function()
    _file_registry["conf/policies.yaml"] = "global:\n  default_action: allow\nrules: []\nstream_rules: []"
    _loader_versions = { http_version = "abc123", stream_version = "abc123", source_version = "abc123" }
    _loader_result = {
      ok = true,
      skipped = false,
      new_version = "abc123",
      previous_http_version = "abc123",
      previous_stream_version = "abc123",
      http_ok = true,
      stream_ok = true,
      conflicts = {},
      shadowed = {},
    }

    _G.ngx = make_ngx({
      var = { uri = "/api/v1/policies/reload", remote_addr = "127.0.0.1" },
    })
    _G.ngx.req.get_headers = function()
      return {
        ["X-MCP-Client"] = "vscode-mcp",
        ["X-MCP-Tool"] = "luagate_reload",
      }
    end
    _G.ngx.req.get_method = function()
      return "POST"
    end

    policies = load_policies()
    policies.handle_post_reload()

    local logged = _G.ngx._get_logged()
    local found_mcp = false
    for _, entry in ipairs(logged) do
      if entry:find("%[luagate:audit%]") and entry:find('"actor_type":"mcp"') then
        found_mcp = true
        assert.truthy(entry:find('"client_name":"vscode%-mcp"'), "should include client_name")
        assert.truthy(entry:find('"tool_name":"luagate_reload"'), "should include tool_name")
        break
      end
    end
    assert.is_true(found_mcp, "reload audit log should contain MCP metadata")
  end)
end)

-- ===========================================================================
-- Audit log guarantee boundary (DON-223)
-- ===========================================================================
describe("감사 로그 보장 범위", function()
  local yaml_body = "version: '1.0'\nrules: []\nstream_rules: []\n"
  local original_encode

  before_each(function()
    reset_stubs()
    setup_io_stubs()
    _file_registry["conf/policies.yaml"] = yaml_body
    _G.ngx = make_ngx({
      var = { uri = "/api/v1/policies", remote_addr = "127.0.0.1" },
    })
    _G.ngx.req.get_headers = function()
      return {
        ["If-Match"] = '"abc123"',
        Authorization = "Bearer valid-test-token",
      }
    end
    _G.ngx.req.get_method = function()
      return "PUT"
    end
    _G.ngx.req.get_body_data = function()
      return yaml_body
    end
    policies = load_policies()
    original_encode = package.loaded["cjson.safe"].encode
  end)

  after_each(function()
    package.loaded["cjson.safe"].encode = original_encode
    teardown_io_stubs()
  end)

  describe("audit_log 직렬화 실패", function()
    it("audit_or_reject는 cjson.encode 실패 시 500 audit_write_failed를 반환한다 (PUT)", function()
      -- Make encode fail only for audit log entries (contains "event" field)
      local call_count = 0
      package.loaded["cjson.safe"].encode = function(tbl)
        call_count = call_count + 1
        -- Fail on the audit log encode (the first encode call with event field)
        if type(tbl) == "table" and tbl.event then
          return nil
        end
        return original_encode(tbl)
      end

      policies.handle_put_policies()

      assert.are.equal(500, _G.ngx.status)
      local said = _G.ngx._get_said()
      assert.is_true(#said >= 1, "should have a response body")
      -- The send_error body may also fail to encode, falling back to hardcoded JSON
      -- Either way, status must be 500
      local found_audit_failed = false
      for _, s in ipairs(said) do
        if s:find("audit_write_failed") then
          found_audit_failed = true
          break
        end
      end
      assert.is_true(found_audit_failed, "response should contain audit_write_failed error code")
    end)

    it("audit_log는 cjson.encode 실패 시 false를 반환한다 (PUT pre-commit)", function()
      local audit_encode_called = false
      package.loaded["cjson.safe"].encode = function(tbl)
        if type(tbl) == "table" and tbl.event then
          audit_encode_called = true
          return nil
        end
        return original_encode(tbl)
      end

      policies.handle_put_policies()

      assert.is_true(audit_encode_called, "audit_log encode should have been called")
      -- The mutation should be rejected (500), not proceed
      assert.are.equal(500, _G.ngx.status)
    end)

    it("정상 encode 시 audit_log는 true를 반환하고 성공 경로를 탄다 (PUT)", function()
      -- Default encode works fine — normal success path
      policies.handle_put_policies()

      assert.are.equal(200, _G.ngx.status)
      local logged = _G.ngx._get_logged()
      local has_audit = false
      for _, entry in ipairs(logged) do
        if entry:find("%[luagate:audit%]") and entry:find("policy_update") then
          has_audit = true
          break
        end
      end
      assert.is_true(has_audit, "audit log should be written on success")
    end)
  end)

  describe("POST reload audit_or_reject", function()
    before_each(function()
      _G.ngx.req.get_headers = function()
        return {}
      end
      _G.ngx.req.get_method = function()
        return "POST"
      end
      policies = load_policies()
      original_encode = package.loaded["cjson.safe"].encode
    end)

    it("audit_or_reject는 cjson.encode 실패 시 500 audit_write_failed를 반환한다 (reload)", function()
      package.loaded["cjson.safe"].encode = function(tbl)
        if type(tbl) == "table" and tbl.event then
          return nil
        end
        return original_encode(tbl)
      end

      policies.handle_post_reload()

      assert.are.equal(500, _G.ngx.status)
      local said = _G.ngx._get_said()
      local found_audit_failed = false
      for _, s in ipairs(said) do
        if s:find("audit_write_failed") then
          found_audit_failed = true
          break
        end
      end
      assert.is_true(found_audit_failed, "reload should reject with audit_write_failed on encode failure")
    end)

    it("정상 encode 시 reload 성공 경로를 탄다", function()
      policies.handle_post_reload()

      assert.are.equal(200, _G.ngx.status)
      local logged = _G.ngx._get_logged()
      local has_audit = false
      for _, entry in ipairs(logged) do
        if entry:find("%[luagate:audit%]") and entry:find("policy_reload") then
          has_audit = true
          break
        end
      end
      assert.is_true(has_audit, "audit log should be written on reload success")
    end)
  end)
end)
