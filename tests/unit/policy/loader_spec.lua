--- Unit tests for lua/luagate/policy/loader.lua
-- Implementation: lua/luagate/policy/loader.lua
-- Tests: tests/unit/policy/loader_spec.lua
--
-- Stubs injected before module load:
--   - cjson       → dkjson wrapper
--   - resty.sha256 → deterministic stub (sha256 of input = "<input>_sha256")
--   - resty.string → stub (to_hex returns input unchanged)
--   - lyaml       → registry-based stub (controlled per test)
--
-- The loader uses blocking io.open.  Tests supply a filepath that maps to a
-- _file_registry entry so no real filesystem access is needed (io.open is
-- monkey-patched per-test-suite setup).
--
-- ngx global is stubbed with a minimal shared dict and logging.

-- ---------------------------------------------------------------------------
-- cjson stub (dkjson wrapper)
-- ---------------------------------------------------------------------------
package.preload["cjson"] = function()
  local dkjson = require("dkjson")
  return {
    encode = dkjson.encode,
    decode = dkjson.decode,
  }
end

-- ---------------------------------------------------------------------------
-- resty.sha256 stub — deterministic fake hash
-- ---------------------------------------------------------------------------
local _sha256_error = false
package.preload["resty.sha256"] = function()
  return {
    new = function()
      local buf = {}
      return {
        update = function(_, s)
          buf[#buf + 1] = s
        end,
        final = function(_)
          if _sha256_error then
            return nil
          end
          -- Return a fake "digest" — we just use the concatenated input string.
          -- resty.string.to_hex will pass it through unchanged (see stub below).
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
      if s == nil then
        return nil
      end
      return s
    end,
  }
end

-- ---------------------------------------------------------------------------
-- lyaml stub — registry-based
-- ---------------------------------------------------------------------------
local _lyaml_registry = {}
local _lyaml_error_on_next = nil

package.preload["lyaml"] = function()
  return {
    load = function(str)
      if _lyaml_error_on_next then
        local msg = _lyaml_error_on_next
        _lyaml_error_on_next = nil
        error(msg)
      end
      local result = _lyaml_registry[str]
      if result == nil then
        error("lyaml stub: no mapping for input: " .. tostring(str):sub(1, 60))
      end
      return result
    end,
  }
end

-- ---------------------------------------------------------------------------
-- ngx global stub
-- ---------------------------------------------------------------------------
local _log_lines = {}
local _ngx_now_value = 1742000000.0

local function make_shared_dict()
  local store = {}
  return {
    _store = store,
    get = function(self, key)
      return self._store[key]
    end,
    set = function(self, key, value)
      self._store[key] = value
      return true, nil
    end,
    safe_set = function(self, key, value)
      self._store[key] = value
      return true, nil
    end,
    add = function(self, key, value, _ttl)
      if self._store[key] ~= nil then
        return false, "exists"
      end
      self._store[key] = value
      return true, nil
    end,
    delete = function(self, key)
      self._store[key] = nil
    end,
  }
end

local _shared_dict_instance = make_shared_dict()

_G.ngx = {
  log = function(level, ...)
    local msg = table.concat({ ... })
    _log_lines[#_log_lines + 1] = { level = level, msg = msg }
  end,
  now = function()
    return _ngx_now_value
  end,
  worker = {
    id = function()
      return 0
    end,
  },
  shared = setmetatable({}, {
    __index = function(_, key)
      if key == "luagate_policy" then
        return _shared_dict_instance
      end
      return nil
    end,
  }),
  ERR = 1,
  WARN = 2,
  INFO = 3,
}

-- ---------------------------------------------------------------------------
-- io.open monkey-patch
-- ---------------------------------------------------------------------------
local _file_registry = {} -- filepath → content string
local _file_errors = {} -- filepath → open error string

local _original_io_open = io.open

local function setup_io_open_stub()
  io.open = function(filepath, _mode) -- luacheck: ignore 122
    if _file_errors[filepath] then
      return nil, _file_errors[filepath]
    end
    local content = _file_registry[filepath]
    if content == nil then
      return nil, "No such file or directory"
    end
    local f = {
      read = function(_, fmt)
        if fmt == "*all" then
          return content
        end
        return nil
      end,
      close = function(_) end,
    }
    return f, nil
  end
end

local function teardown_io_open_stub()
  io.open = _original_io_open -- luacheck: ignore 122
end

-- ---------------------------------------------------------------------------
-- Reset helpers
-- ---------------------------------------------------------------------------
local function reset_shared_dict()
  _shared_dict_instance = make_shared_dict()
end

local function reset_logs()
  _log_lines = {}
end

-- ---------------------------------------------------------------------------
-- Load loader module (after all stubs are in place)
-- ---------------------------------------------------------------------------
local loader = require("luagate.policy.loader")

-- ---------------------------------------------------------------------------
-- Minimal valid policy YAML content and lyaml mapping
-- ---------------------------------------------------------------------------

local VALID_YAML = [[
version: "1.0"
global:
  default_action: deny
rules:
  - id: allow-health
    priority: 10
    action: allow
    enabled: true
    scope:
      path: /health
stream_rules:
  - id: allow-tls-443
    priority: 10
    action: proxy
    upstream: "backend:8443"
    enabled: true
    scope:
      dst_port: 443
]]

local VALID_POLICY_TABLE = {
  version = "1.0",
  global = { default_action = "deny" },
  rules = {
    {
      id = "allow-health",
      priority = 10,
      action = "allow",
      enabled = true,
      scope = { path = "/health" },
    },
  },
  stream_rules = {
    {
      id = "allow-tls-443",
      priority = 10,
      action = "proxy",
      upstream = "backend:8443",
      enabled = true,
      scope = { dst_port = 443 },
    },
  },
}

local VALID_PATH = "/etc/luagate/policies.yaml"

local function register_valid_policy()
  _file_registry[VALID_PATH] = VALID_YAML
  _lyaml_registry[VALID_YAML] = VALID_POLICY_TABLE
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("loader.load_policy — 파일 읽기 [1단계]", function()
  before_each(function()
    setup_io_open_stub()
    reset_shared_dict()
    reset_logs()
    _file_registry = {}
    _file_errors = {}
    _sha256_error = false
    _lyaml_error_on_next = nil
    _lyaml_registry = {}
  end)

  after_each(function()
    teardown_io_open_stub()
  end)

  it("파일을 열 수 없으면 err 반환, ok=false", function()
    _file_errors[VALID_PATH] = "permission denied"
    local result = loader.load_policy(VALID_PATH)
    assert.is_false(result.ok)
    assert.is_string(result.err)
    assert.is_truthy(result.err:find("cannot open"))
  end)

  it("파일이 비어 있으면 err 반환", function()
    _file_registry[VALID_PATH] = ""
    local result = loader.load_policy(VALID_PATH)
    assert.is_false(result.ok)
    assert.is_truthy(result.err:find("empty"))
  end)
end)

describe("loader.load_policy — YAML 파싱 [2단계]", function()
  before_each(function()
    setup_io_open_stub()
    reset_shared_dict()
    reset_logs()
    _file_registry = {}
    _file_errors = {}
    _sha256_error = false
    _lyaml_error_on_next = nil
    _lyaml_registry = {}
  end)

  after_each(function()
    teardown_io_open_stub()
  end)

  it("YAML 파싱 오류 시 err 반환, ok=false", function()
    _file_registry[VALID_PATH] = "bad: yaml: content"
    _lyaml_error_on_next = "YAML parse error: bad input"
    local result = loader.load_policy(VALID_PATH)
    assert.is_false(result.ok)
    assert.is_truthy(result.err:find("parse"))
  end)
end)

describe("loader.load_policy — Schema 검증 [3단계]", function()
  before_each(function()
    setup_io_open_stub()
    reset_shared_dict()
    reset_logs()
    _file_registry = {}
    _file_errors = {}
    _sha256_error = false
    _lyaml_error_on_next = nil
    _lyaml_registry = {}
  end)

  after_each(function()
    teardown_io_open_stub()
  end)

  it("global.default_action 누락 시 validation 실패 → ok=false", function()
    local bad_content = "bad_global_content"
    _file_registry[VALID_PATH] = bad_content
    _lyaml_registry[bad_content] = {
      -- global 섹션 없음
      rules = {},
      stream_rules = {},
    }
    local result = loader.load_policy(VALID_PATH)
    assert.is_false(result.ok)
    assert.is_truthy(result.err:find("validation"))
  end)

  it("HTTP rule id 누락 시 validation 실패 → ok=false", function()
    local bad_content = "missing_rule_id_content"
    _file_registry[VALID_PATH] = bad_content
    _lyaml_registry[bad_content] = {
      global = { default_action = "deny" },
      rules = {
        { priority = 10, action = "allow" }, -- id 없음
      },
      stream_rules = {},
    }
    local result = loader.load_policy(VALID_PATH)
    assert.is_false(result.ok)
    assert.is_truthy(result.err:find("validation"))
  end)
end)

describe("loader.load_policy — conflict 감지 [4단계]", function()
  before_each(function()
    setup_io_open_stub()
    reset_shared_dict()
    reset_logs()
    _file_registry = {}
    _file_errors = {}
    _sha256_error = false
    _lyaml_error_on_next = nil
    _lyaml_registry = {}
  end)

  after_each(function()
    teardown_io_open_stub()
  end)

  it("conflict 있어도 로드는 성공 (WARN only)", function()
    local content = "conflict_rules_content"
    _file_registry[VALID_PATH] = content
    _lyaml_registry[content] = {
      global = { default_action = "deny" },
      rules = {
        {
          id = "rule-a",
          priority = 5,
          action = "allow",
          enabled = true,
          scope = { path = "/api" },
        },
        {
          id = "rule-b",
          priority = 5,
          action = "deny",
          enabled = true,
          scope = { path = "/api" },
        },
      },
      stream_rules = {},
    }
    local result = loader.load_policy(VALID_PATH)
    -- conflict는 WARN이지만 로드는 계속
    assert.is_true(result.ok)
    assert.are.equal(1, #result.conflicts)
    assert.are.equal("exact", result.conflicts[1].overlap_type)
  end)

  it("conflict 없으면 result.conflicts는 빈 목록", function()
    register_valid_policy()
    local result = loader.load_policy(VALID_PATH)
    assert.is_true(result.ok)
    assert.are.equal(0, #result.conflicts)
  end)
end)

describe("loader.load_policy — SHA256 해시 [5단계]", function()
  before_each(function()
    setup_io_open_stub()
    reset_shared_dict()
    reset_logs()
    _file_registry = {}
    _file_errors = {}
    _sha256_error = false
    _lyaml_error_on_next = nil
    _lyaml_registry = {}
  end)

  after_each(function()
    teardown_io_open_stub()
  end)

  it("SHA256 계산 실패 시 err 반환", function()
    register_valid_policy()
    _sha256_error = true
    local result = loader.load_policy(VALID_PATH)
    assert.is_false(result.ok)
    assert.is_truthy(result.err:find("SHA256"))
  end)

  it("new_version은 파일 내용의 hash이다", function()
    register_valid_policy()
    local result = loader.load_policy(VALID_PATH)
    assert.is_true(result.ok)
    -- resty.sha256 stub: final()은 입력 내용을 그대로 반환,
    -- resty.string stub: to_hex()는 입력을 그대로 반환.
    -- 따라서 new_version == VALID_YAML
    assert.are.equal(VALID_YAML, result.new_version)
  end)
end)

describe("loader.load_policy — blob store [6단계]", function()
  before_each(function()
    setup_io_open_stub()
    reset_shared_dict()
    reset_logs()
    _file_registry = {}
    _file_errors = {}
    _sha256_error = false
    _lyaml_error_on_next = nil
    _lyaml_registry = {}
  end)

  after_each(function()
    teardown_io_open_stub()
  end)

  it("성공 시 shared dict에 blob 키가 저장된다", function()
    register_valid_policy()
    local result = loader.load_policy(VALID_PATH)
    assert.is_true(result.ok)
    local blob_key = "policy:" .. result.new_version .. ":blob"
    local stored = _shared_dict_instance._store[blob_key]
    assert.is_string(stored)
    assert.is_truthy(#stored > 0)
  end)

  it("성공 시 shared dict에 meta 키가 저장된다", function()
    register_valid_policy()
    local result = loader.load_policy(VALID_PATH)
    assert.is_true(result.ok)
    local meta_key = "policy:" .. result.new_version .. ":meta"
    local stored = _shared_dict_instance._store[meta_key]
    assert.is_string(stored)
    assert.is_truthy(#stored > 0)
  end)

  it("safe_set 실패 시 ok=false, err 포함", function()
    register_valid_policy()
    -- safe_set을 항상 실패하도록 override
    _shared_dict_instance.safe_set = function(_, _, _)
      return false, "no memory"
    end
    local result = loader.load_policy(VALID_PATH)
    assert.is_false(result.ok)
    assert.is_truthy(result.err:find("blob store"))
  end)

  it("blob 성공 + meta 실패 시 blob 키가 롤백(삭제)된다", function()
    register_valid_policy()
    -- blob safe_set은 성공, meta safe_set은 실패하도록 override
    local call_count = 0
    _shared_dict_instance.safe_set = function(self, key, value)
      call_count = call_count + 1
      if call_count == 1 then
        -- 첫 번째 호출(blob): 성공
        self._store[key] = value
        return true, nil
      else
        -- 두 번째 호출(meta): 실패
        return false, "no memory"
      end
    end
    local deleted_keys = {}
    local original_delete = _shared_dict_instance.delete
    _shared_dict_instance.delete = function(self, key)
      deleted_keys[#deleted_keys + 1] = key
      return original_delete(self, key)
    end
    local result = loader.load_policy(VALID_PATH)
    assert.is_false(result.ok)
    assert.is_truthy(result.err:find("blob store"))
    -- 롤백: blob 키가 delete 호출 목록에 포함되어야 함
    local blob_key_found = false
    for _, k in ipairs(deleted_keys) do
      if k:find(":blob$") then
        blob_key_found = true
        break
      end
    end
    assert.is_true(blob_key_found, "blob 키가 롤백되지 않음")
  end)
end)

describe("loader.load_policy — commit (pointer swap) [7단계]", function()
  before_each(function()
    setup_io_open_stub()
    reset_shared_dict()
    reset_logs()
    _file_registry = {}
    _file_errors = {}
    _sha256_error = false
    _lyaml_error_on_next = nil
    _lyaml_registry = {}
  end)

  after_each(function()
    teardown_io_open_stub()
  end)

  it("성공 시 http:active_version, stream:active_version 모두 갱신된다", function()
    register_valid_policy()
    local result = loader.load_policy(VALID_PATH)
    assert.is_true(result.ok)
    assert.is_true(result.http_ok)
    assert.is_true(result.stream_ok)
    assert.are.equal(result.new_version, _shared_dict_instance._store["http:active_version"])
    assert.are.equal(result.new_version, _shared_dict_instance._store["stream:active_version"])
  end)

  it("양쪽 성공 시 source_version도 갱신된다", function()
    register_valid_policy()
    local result = loader.load_policy(VALID_PATH)
    assert.is_true(result.ok)
    assert.are.equal(result.new_version, _shared_dict_instance._store["source_version"])
  end)

  it("policy_loaded_at 기록 실패는 로그를 남기고 reload 성공은 유지한다", function()
    register_valid_policy()
    local original_safe_set = _shared_dict_instance.safe_set
    _shared_dict_instance.safe_set = function(self, key, value)
      if key == "policy_loaded_at" then
        return false, "no memory"
      end
      return original_safe_set(self, key, value)
    end

    local result = loader.load_policy(VALID_PATH)

    assert.is_true(result.ok)
    assert.is_true(result.http_ok)
    assert.is_true(result.stream_ok)
    assert.are.equal(result.new_version, _shared_dict_instance._store["source_version"])
    assert.is_nil(_shared_dict_instance._store["policy_loaded_at"])

    local warn_found = false
    for _, entry in ipairs(_log_lines) do
      if entry.level == ngx.WARN and entry.msg:find("policy_loaded_at") then
        warn_found = true
        break
      end
    end
    assert.is_true(warn_found)
  end)

  it("http pointer swap 실패 시 http_ok=false, stream_ok은 독립 판정", function()
    register_valid_policy()
    -- http set만 실패하도록
    local original_set = _shared_dict_instance.set
    local call_count = 0
    _shared_dict_instance.set = function(self, key, value)
      call_count = call_count + 1
      if key == "http:active_version" then
        return false, "write error"
      end
      return original_set(self, key, value)
    end
    local result = loader.load_policy(VALID_PATH)
    assert.is_false(result.http_ok)
    assert.is_true(result.stream_ok)
    -- ok=true because at least one subsystem succeeded (partial commit)
    assert.is_true(result.ok)
  end)

  it("양쪽 pointer swap 모두 실패 시 ok=false", function()
    register_valid_policy()
    _shared_dict_instance.set = function(self, key, value)
      if key == "http:active_version" or key == "stream:active_version" then
        return false, "write error"
      end
      self._store[key] = value
      return true, nil
    end
    local result = loader.load_policy(VALID_PATH)
    assert.is_false(result.ok)
    assert.is_false(result.http_ok)
    assert.is_false(result.stream_ok)
    assert.is_truthy(result.err:find("failed"))
  end)
end)

describe("loader.load_policy — same-hash skip", function()
  before_each(function()
    setup_io_open_stub()
    reset_shared_dict()
    reset_logs()
    _file_registry = {}
    _file_errors = {}
    _sha256_error = false
    _lyaml_error_on_next = nil
    _lyaml_registry = {}
  end)

  after_each(function()
    teardown_io_open_stub()
  end)

  it("hash 동일 시 skipped=true, ok=true, pointer swap 없음", function()
    register_valid_policy()
    -- 첫 로드
    local r1 = loader.load_policy(VALID_PATH)
    assert.is_true(r1.ok)

    -- shared dict에 동일 버전이 이미 활성 상태로 설정됨
    -- 두 번째 로드 — hash 동일
    _lyaml_registry[VALID_YAML] = VALID_POLICY_TABLE -- re-register (same table ref)
    local r2 = loader.load_policy(VALID_PATH)
    assert.is_true(r2.ok)
    assert.is_true(r2.skipped)
  end)

  it("hash 다르면 reload 수행", function()
    register_valid_policy()
    -- 첫 로드
    loader.load_policy(VALID_PATH)

    -- 파일 내용 변경 (다른 hash를 유발)
    local new_content = VALID_YAML .. "\n# updated"
    _file_registry[VALID_PATH] = new_content
    _lyaml_registry[new_content] = VALID_POLICY_TABLE

    local r2 = loader.load_policy(VALID_PATH)
    assert.is_true(r2.ok)
    assert.is_false(r2.skipped)
  end)
end)

describe("loader.load_policy — reload lock (동시성)", function()
  before_each(function()
    setup_io_open_stub()
    reset_shared_dict()
    reset_logs()
    _file_registry = {}
    _file_errors = {}
    _sha256_error = false
    _lyaml_error_on_next = nil
    _lyaml_registry = {}
  end)

  after_each(function()
    teardown_io_open_stub()
  end)

  it("reload_lock이 이미 존재하면 reload_in_progress 에러 반환", function()
    -- lock을 미리 설정
    _shared_dict_instance._store["reload_lock"] = "another-worker:12345"
    local result = loader.load_policy(VALID_PATH)
    assert.is_false(result.ok)
    assert.are.equal("reload_in_progress", result.err)
  end)

  it("정상 완료 후 reload_lock이 해제된다", function()
    register_valid_policy()
    local result = loader.load_policy(VALID_PATH)
    assert.is_true(result.ok)
    assert.is_nil(_shared_dict_instance._store["reload_lock"])
  end)

  it("파이프라인 실패 후에도 reload_lock이 해제된다", function()
    -- 파일 오픈 실패 → 파이프라인 중단
    _file_errors[VALID_PATH] = "permission denied"
    local result = loader.load_policy(VALID_PATH)
    assert.is_false(result.ok)
    assert.is_nil(_shared_dict_instance._store["reload_lock"])
  end)
end)

describe("loader.init_load — cold start fatal error", function()
  before_each(function()
    setup_io_open_stub()
    reset_shared_dict()
    reset_logs()
    _file_registry = {}
    _file_errors = {}
    _sha256_error = false
    _lyaml_error_on_next = nil
    _lyaml_registry = {}
  end)

  after_each(function()
    teardown_io_open_stub()
  end)

  it("로드 실패 시 error()를 발생시킨다 (fail-closed)", function()
    _file_errors[VALID_PATH] = "not found"
    local ok, err = pcall(loader.init_load, VALID_PATH)
    assert.is_false(ok)
    assert.is_truthy(err:find("cold start"))
  end)

  it("로드 성공 시 result 반환, error 없음", function()
    register_valid_policy()
    local ok, result = pcall(loader.init_load, VALID_PATH)
    assert.is_true(ok)
    assert.is_true(result.ok)
  end)

  it("partial commit (http 실패, stream 성공) 시 cold start fatal — error() 발생", function()
    register_valid_policy()
    -- http pointer swap만 실패하도록 설정
    local original_set = _shared_dict_instance.set
    _shared_dict_instance.set = function(self, key, value)
      if key == "http:active_version" then
        return false, "write error"
      end
      return original_set(self, key, value)
    end
    local ok, err = pcall(loader.init_load, VALID_PATH)
    assert.is_false(ok)
    assert.is_truthy(err:find("cold start"))
  end)

  it("partial commit (http 성공, stream 실패) 시 cold start fatal — error() 발생", function()
    register_valid_policy()
    -- stream pointer swap만 실패하도록 설정
    local original_set = _shared_dict_instance.set
    _shared_dict_instance.set = function(self, key, value)
      if key == "stream:active_version" then
        return false, "write error"
      end
      return original_set(self, key, value)
    end
    local ok, err = pcall(loader.init_load, VALID_PATH)
    assert.is_false(ok)
    assert.is_truthy(err:find("cold start"))
  end)

  it("same-hash skip 시 성공으로 처리 (error 미발생)", function()
    register_valid_policy()
    -- 첫 로드로 버전 설정
    loader.load_policy(VALID_PATH)
    -- hash 동일 상태에서 init_load 호출
    _lyaml_registry[VALID_YAML] = VALID_POLICY_TABLE
    local ok, result = pcall(loader.init_load, VALID_PATH)
    assert.is_true(ok)
    assert.is_true(result.skipped)
  end)
end)

describe("loader.get_active_versions", function()
  before_each(function()
    reset_shared_dict()
  end)

  it("shared dict에 버전 없으면 모두 nil", function()
    local v = loader.get_active_versions()
    assert.is_nil(v.http_version)
    assert.is_nil(v.stream_version)
    assert.is_nil(v.source_version)
  end)

  it("버전 기록 후 올바른 값 반환", function()
    _shared_dict_instance._store["http:active_version"] = "abc123"
    _shared_dict_instance._store["stream:active_version"] = "def456"
    _shared_dict_instance._store["source_version"] = "abc123"
    local v = loader.get_active_versions()
    assert.are.equal("abc123", v.http_version)
    assert.are.equal("def456", v.stream_version)
    assert.are.equal("abc123", v.source_version)
  end)
end)

describe("loader.set_source_version", function()
  before_each(function()
    reset_shared_dict()
  end)

  it("source_version이 nil일 때 backfill 성공", function()
    assert.is_nil(loader.get_active_versions().source_version)
    local ok, err = loader.set_source_version("abc123")
    assert.is_true(ok)
    assert.is_nil(err)
    assert.are.equal("abc123", loader.get_active_versions().source_version)
  end)

  it("이미 존재하는 source_version은 덮어쓰지 않음", function()
    _shared_dict_instance._store["source_version"] = "old_hash"
    local ok, err = loader.set_source_version("new_hash")
    assert.is_true(ok)
    assert.is_nil(err)
    -- value must remain unchanged — no overwrite
    assert.are.equal("old_hash", loader.get_active_versions().source_version)
  end)
end)

describe("loader.is_reload_in_progress", function()
  before_each(function()
    reset_shared_dict()
  end)

  it("lock 없으면 false", function()
    assert.is_false(loader.is_reload_in_progress())
  end)

  it("lock 있으면 true", function()
    _shared_dict_instance._store["reload_lock"] = "worker:12345"
    assert.is_true(loader.is_reload_in_progress())
  end)
end)

describe("loader.load_policy — previous_version 필드", function()
  before_each(function()
    setup_io_open_stub()
    reset_shared_dict()
    reset_logs()
    _file_registry = {}
    _file_errors = {}
    _sha256_error = false
    _lyaml_error_on_next = nil
    _lyaml_registry = {}
  end)

  after_each(function()
    teardown_io_open_stub()
  end)

  it("이전 버전이 없으면 previous_*_version은 nil", function()
    register_valid_policy()
    local result = loader.load_policy(VALID_PATH)
    assert.is_true(result.ok)
    assert.is_nil(result.previous_http_version)
    assert.is_nil(result.previous_stream_version)
  end)

  it("이전 버전이 있으면 previous_*_version에 기록", function()
    -- 이전 버전을 shared dict에 미리 설정
    _shared_dict_instance._store["http:active_version"] = "old-http-ver"
    _shared_dict_instance._store["stream:active_version"] = "old-stream-ver"

    register_valid_policy()
    local result = loader.load_policy(VALID_PATH)
    assert.is_true(result.ok)
    assert.are.equal("old-http-ver", result.previous_http_version)
    assert.are.equal("old-stream-ver", result.previous_stream_version)
  end)
end)

describe("loader.load_policy — 기본 filepath", function()
  before_each(function()
    setup_io_open_stub()
    reset_shared_dict()
    reset_logs()
    _file_registry = {}
    _file_errors = {}
    _sha256_error = false
    _lyaml_error_on_next = nil
    _lyaml_registry = {}
  end)

  after_each(function()
    teardown_io_open_stub()
  end)

  it("filepath 인자 없으면 conf/policies.yaml 사용", function()
    _file_errors["conf/policies.yaml"] = "not found"
    local result = loader.load_policy()
    assert.is_false(result.ok)
    assert.is_truthy(result.err:find("conf/policies.yaml"))
  end)
end)

describe("loader.load_policy — stream pointer swap 실패 (partial commit 대칭)", function()
  before_each(function()
    setup_io_open_stub()
    reset_shared_dict()
    reset_logs()
    _file_registry = {}
    _file_errors = {}
    _sha256_error = false
    _lyaml_error_on_next = nil
    _lyaml_registry = {}
  end)

  after_each(function()
    teardown_io_open_stub()
  end)

  it("stream pointer swap 실패 시 stream_ok=false, http_ok=true, ok=true", function()
    register_valid_policy()
    local original_set = _shared_dict_instance.set
    _shared_dict_instance.set = function(self, key, value)
      if key == "stream:active_version" then
        return false, "write error"
      end
      return original_set(self, key, value)
    end
    local result = loader.load_policy(VALID_PATH)
    assert.is_true(result.http_ok)
    assert.is_false(result.stream_ok)
    assert.is_true(result.ok)
    -- http 포인터는 갱신되었어야 함
    assert.are.equal(result.new_version, _shared_dict_instance._store["http:active_version"])
    -- stream 포인터는 갱신 안 됨 (LKG 유지)
    assert.is_nil(_shared_dict_instance._store["stream:active_version"])
  end)

  it("http 실패 시 source_version은 기록되지 않는다 (ADR-005 §1 불변식)", function()
    register_valid_policy()
    local original_set = _shared_dict_instance.set
    _shared_dict_instance.set = function(self, key, value)
      if key == "http:active_version" then
        return false, "write error"
      end
      return original_set(self, key, value)
    end
    local result = loader.load_policy(VALID_PATH)
    assert.is_false(result.http_ok)
    assert.is_true(result.stream_ok)
    -- partial commit: 한쪽 실패 → source_version 미기록
    assert.is_nil(_shared_dict_instance._store["source_version"])
  end)
end)

describe("loader.load_policy — same-hash skip + lock 해제", function()
  before_each(function()
    setup_io_open_stub()
    reset_shared_dict()
    reset_logs()
    _file_registry = {}
    _file_errors = {}
    _sha256_error = false
    _lyaml_error_on_next = nil
    _lyaml_registry = {}
  end)

  after_each(function()
    teardown_io_open_stub()
  end)

  it("same-hash skip 경로에서도 reload_lock이 해제된다", function()
    register_valid_policy()
    -- 첫 로드
    loader.load_policy(VALID_PATH)
    -- hash 동일 상태로 재로드
    _lyaml_registry[VALID_YAML] = VALID_POLICY_TABLE
    local r2 = loader.load_policy(VALID_PATH)
    assert.is_true(r2.skipped)
    -- lock이 해제되었어야 함
    assert.is_nil(_shared_dict_instance._store["reload_lock"])
  end)

  it("hash 동일 조건: http_ver만 같고 stream_ver가 다르면 reload 수행", function()
    register_valid_policy()
    -- 첫 로드 수행하여 new_version 확인
    local r1 = loader.load_policy(VALID_PATH)
    assert.is_true(r1.ok)
    local ver = r1.new_version

    -- http는 일치하지만 stream은 다른 버전으로 설정
    _shared_dict_instance._store["http:active_version"] = ver
    _shared_dict_instance._store["stream:active_version"] = "different-version"

    _lyaml_registry[VALID_YAML] = VALID_POLICY_TABLE
    local r2 = loader.load_policy(VALID_PATH)
    assert.is_true(r2.ok)
    assert.is_false(r2.skipped)
  end)
end)

describe("loader.load_policy — result 구조 완전성", function()
  before_each(function()
    setup_io_open_stub()
    reset_shared_dict()
    reset_logs()
    _file_registry = {}
    _file_errors = {}
    _sha256_error = false
    _lyaml_error_on_next = nil
    _lyaml_registry = {}
  end)

  after_each(function()
    teardown_io_open_stub()
  end)

  it("성공 결과에 shadowed 필드가 포함된다", function()
    register_valid_policy()
    local result = loader.load_policy(VALID_PATH)
    assert.is_true(result.ok)
    assert.is_table(result.shadowed)
  end)

  it("성공 결과에 conflicts 필드가 포함된다", function()
    register_valid_policy()
    local result = loader.load_policy(VALID_PATH)
    assert.is_true(result.ok)
    assert.is_table(result.conflicts)
  end)
end)
