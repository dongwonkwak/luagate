--- Unit tests for lua/luagate/stream/handler.lua
-- Implementation: lua/luagate/stream/handler.lua
-- Tests: tests/unit/stream/handler_spec.lua
--
-- handler.lua는 OpenResty ngx 전역에 강하게 의존하므로
-- 모든 테스트에서 ngx mock을 주입한다.
--
-- Stubs injected before module load:
--   - luagate.policy.evaluator -> 제어 가능한 stub
--   - luagate.stream.ffi       -> 제어 가능한 stub

-- ---------------------------------------------------------------------------
-- evaluator stub
-- ---------------------------------------------------------------------------
local _evaluator_stub = {
  get_policy_result = nil, -- nil = 정책 없음, table = 정책 반환
  evaluate_stream_result = nil, -- evaluate_stream() 반환값 제어
  get_policy_error = nil, -- get_policy() 에러 시뮬레이션
}

package.preload["luagate.policy.evaluator"] = function()
  return {
    get_policy = function()
      if _evaluator_stub.get_policy_error then
        error(_evaluator_stub.get_policy_error)
      end
      return _evaluator_stub.get_policy_result
    end,
    evaluate_stream = function(_rules, _ctx)
      if _evaluator_stub.evaluate_stream_result then
        return _evaluator_stub.evaluate_stream_result
      end
      return { action = "deny", matched_rule = nil, decision_source = "default" }
    end,
  }
end

-- ---------------------------------------------------------------------------
-- stream.ffi stub
-- ---------------------------------------------------------------------------
local _stream_ffi_stub = {
  detect_result = nil, -- { protocol, err, need_more }
  detect_results = nil, -- array of results for retry loop testing
  detect_call_count = 0,
  sni_result = nil, -- { sni, err, need_more }
  radix_build_result = nil, -- { tree, err }
  radix_lookup_result = nil, -- { idx, err }
  radix_free_calls = {},
}

local MOCK_RADIX_TREE = { _type = "mock_radix_tree" }

local _stream_ffi_module = {
  detect_protocol = function(_data)
    _stream_ffi_stub.detect_call_count = _stream_ffi_stub.detect_call_count + 1
    -- Support sequential results for retry loop testing
    if _stream_ffi_stub.detect_results then
      local idx = _stream_ffi_stub.detect_call_count
      local r = _stream_ffi_stub.detect_results[idx]
        or _stream_ffi_stub.detect_results[#_stream_ffi_stub.detect_results]
      return r[1], r[2], r[3]
    end
    if _stream_ffi_stub.detect_result then
      local r = _stream_ffi_stub.detect_result
      return r[1], r[2], r[3]
    end
    return "raw", nil, false
  end,
  extract_sni = function(_data)
    if _stream_ffi_stub.sni_result then
      local r = _stream_ffi_stub.sni_result
      return r[1], r[2], r[3]
    end
    return "", nil, false
  end,
  radix_build = function(_cidr_list)
    if _stream_ffi_stub.radix_build_result then
      return _stream_ffi_stub.radix_build_result[1], _stream_ffi_stub.radix_build_result[2]
    end
    return MOCK_RADIX_TREE, nil
  end,
  radix_lookup = function(_tree, _ip)
    if _stream_ffi_stub.radix_lookup_result then
      return _stream_ffi_stub.radix_lookup_result[1], _stream_ffi_stub.radix_lookup_result[2]
    end
    return nil, nil -- no match
  end,
  radix_free = function(tree)
    table.insert(_stream_ffi_stub.radix_free_calls, { tree = tree })
  end,
}

package.preload["luagate.stream.ffi"] = function()
  return _stream_ffi_module
end

-- ---------------------------------------------------------------------------
-- ngx mock factory (stream context)
-- ---------------------------------------------------------------------------
local function make_ngx(overrides)
  local exited_with = nil
  local logged = {}

  local incr_calls = {}

  local mock = {
    var = {
      connection = "1001",
      remote_addr = "10.0.0.1",
      remote_port = "54321",
      server_port = "443",
      -- luagate_ prefix nginx variables
      luagate_conn_id = "",
      luagate_worker_id = "0",
      luagate_active_version = "none",
      luagate_stream_action = "",
      luagate_request_state = "",
      luagate_protocol = "",
      luagate_sni = "",
      luagate_decision_source = "",
      luagate_matched_rule = "",
      luagate_upstream = "",
    },
    ctx = {},
    shared = {
      luagate_policy = {
        get = function(_, _key)
          return nil
        end,
      },
      luagate_connections = {
        incr = function(_, key, delta, default)
          table.insert(incr_calls, { key = key, delta = delta, default = default })
          return 1, nil
        end,
      },
      luagate_metrics = {
        _data = {},
        incr = function(self, key, delta, default)
          self._data[key] = (self._data[key] or default or 0) + delta
          return self._data[key], nil
        end,
        get = function(self, key)
          return self._data[key]
        end,
      },
    },
    WARN = 5,
    ERR = 4,
    INFO = 6,
    ERROR = -1, -- ngx.ERROR sentinel
    log = function(_, ...)
      local parts = { ... }
      logged[#logged + 1] = table.concat(parts, "")
    end,
    exit = function(code)
      exited_with = code
    end,
    now = function()
      return 1710633600.0
    end,
    worker = {
      id = function()
        return 0
      end,
    },
    req = {
      socket = function()
        -- Default: returns a mock socket with successful non-consuming peek
        return {
          peek = function(_, _bytes)
            return "\x16\x03\x01\x00\x05mock-tls-data"
          end,
        }
      end,
    },
  }

  -- Tracking accessors
  mock._get_exited = function()
    return exited_with
  end
  mock._get_logged = function()
    return logged
  end
  mock._get_incr_calls = function()
    return incr_calls
  end

  -- Override support
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
-- Module load
-- ---------------------------------------------------------------------------
local _saved_ngx = _G.ngx
_G.ngx = make_ngx()

local handler = require("luagate.stream.handler")

-- Cleanup on teardown
teardown(function()
  _G.ngx = _saved_ngx
  package.preload["luagate.policy.evaluator"] = nil
  package.preload["luagate.stream.ffi"] = nil
  package.loaded["luagate.policy.evaluator"] = nil
  package.loaded["luagate.stream.ffi"] = nil
  package.loaded["luagate.stream.handler"] = nil
end)

-- ---------------------------------------------------------------------------
-- Helper: reset stubs
-- ---------------------------------------------------------------------------
local function reset_stubs()
  _evaluator_stub.get_policy_result = nil
  _evaluator_stub.evaluate_stream_result = nil
  _evaluator_stub.get_policy_error = nil
  _stream_ffi_stub.detect_result = nil
  _stream_ffi_stub.detect_results = nil
  _stream_ffi_stub.detect_call_count = 0
  _stream_ffi_stub.sni_result = nil
  _stream_ffi_stub.radix_build_result = nil
  _stream_ffi_stub.radix_lookup_result = nil
  _stream_ffi_stub.radix_free_calls = {}
  package.loaded["luagate.stream.ffi"] = _stream_ffi_module
  package.loaded["luagate.policy.evaluator"] = nil
end

-- ---------------------------------------------------------------------------
-- Helper: make a standard policy for proxy tests
-- ---------------------------------------------------------------------------
local function make_proxy_policy()
  return {
    global = { default_action = "deny" },
    rules = {},
    stream_rules = {},
    _compiled_stream = {},
  }
end

-- ===========================================================================
-- TLS + SNI -> policy proxy -> upstream 설정
-- ===========================================================================

describe("handler.preread - TLS + SNI -> policy proxy", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
  end)

  it("TLS + SNI -> evaluate proxy -> upstream 설정, request_state = 'proxied'", function()
    _stream_ffi_stub.detect_result = { "tls", nil, false }
    _stream_ffi_stub.sni_result = { "example.com", nil, false }
    _evaluator_stub.get_policy_result = make_proxy_policy()
    _evaluator_stub.evaluate_stream_result = {
      action = "proxy",
      matched_rule = "rule-tls-allow",
      decision_source = "rule",
      upstream = "backend-tls:8443",
    }

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.is_not_nil(ctx)
    assert.equals("tls", ctx.detected_protocol)
    assert.equals("example.com", ctx.sni)
    assert.equals("proxy", ctx.action)
    assert.equals("rule-tls-allow", ctx.matched_rule_id)
    assert.equals("backend-tls:8443", ctx.upstream)
    assert.equals("proxied", ctx.request_state)
    assert.equals("backend-tls:8443", ngx_mock.var.luagate_upstream)
    -- Fix 2: decision_source "rule" -> "policy_engine" (stream-pipeline.md §4)
    assert.equals("policy_engine", ctx.decision_source)
    assert.equals("policy_engine", ngx_mock.var.luagate_decision_source)
    assert.is_nil(ngx_mock._get_exited())
  end)
end)

-- ===========================================================================
-- TLS + SNI -> policy deny -> ngx.exit(ERROR)
-- ===========================================================================

describe("handler.preread - TLS + SNI -> policy deny", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
  end)

  it("TLS + SNI -> evaluate deny -> ngx.exit(ERROR)", function()
    _stream_ffi_stub.detect_result = { "tls", nil, false }
    _stream_ffi_stub.sni_result = { "blocked.com", nil, false }
    _evaluator_stub.get_policy_result = make_proxy_policy()
    _evaluator_stub.evaluate_stream_result = {
      action = "deny",
      matched_rule = "rule-block-tls",
      decision_source = "rule",
      upstream = nil,
    }

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("deny", ctx.action)
    assert.equals("denied", ctx.request_state)
    assert.equals("rule-block-tls", ctx.deny_reason)
    assert.equals(ngx_mock.ERROR, ngx_mock._get_exited())
    assert.equals("deny", ngx_mock.var.luagate_stream_action)
    assert.equals("denied", ngx_mock.var.luagate_request_state)
  end)
end)

-- ===========================================================================
-- HTTP 프로토콜 탐지 -> policy proxy
-- ===========================================================================

describe("handler.preread - HTTP protocol -> policy proxy", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
  end)

  it("HTTP 프로토콜 탐지 -> proxy", function()
    _stream_ffi_stub.detect_result = { "http", nil, false }
    _evaluator_stub.get_policy_result = make_proxy_policy()
    _evaluator_stub.evaluate_stream_result = {
      action = "proxy",
      matched_rule = "rule-http",
      decision_source = "rule",
      upstream = "http-backend:80",
    }

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("http", ctx.detected_protocol)
    assert.is_nil(ctx.sni) -- SNI extraction skipped for non-TLS
    assert.equals("proxy", ctx.action)
    assert.equals("proxied", ctx.request_state)
    assert.equals("http-backend:80", ctx.upstream)
    assert.is_nil(ngx_mock._get_exited())
  end)
end)

-- ===========================================================================
-- raw 프로토콜 -> policy deny (기본 정책)
-- ===========================================================================

describe("handler.preread - raw protocol -> default deny", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
  end)

  it("raw 프로토콜 -> evaluate deny (기본 정책)", function()
    _stream_ffi_stub.detect_result = { "raw", nil, false }
    _evaluator_stub.get_policy_result = make_proxy_policy()
    _evaluator_stub.evaluate_stream_result = {
      action = "deny",
      matched_rule = nil,
      decision_source = "default",
    }

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("raw", ctx.detected_protocol)
    assert.equals("deny", ctx.action)
    assert.equals("denied", ctx.request_state)
    assert.equals(ngx_mock.ERROR, ngx_mock._get_exited())
  end)
end)

-- ===========================================================================
-- peek I/O 실패 -> fail-closed
-- ===========================================================================

describe("handler.preread - peek I/O 실패 -> fail-closed", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
  end)

  it("socket 획득 실패 -> fail-closed (ngx.exit ERROR)", function()
    -- Override ngx.req.socket to fail
    ngx_mock.req.socket = function()
      return nil, "no socket"
    end

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("socket_error", ctx.deny_reason)
    assert.equals("denied", ctx.request_state)
    assert.equals(ngx_mock.ERROR, ngx_mock._get_exited())
  end)

  it("peek 실패 -> fail-closed (peek_io_error)", function()
    -- Override ngx.req.socket to return a socket that fails on peek
    ngx_mock.req.socket = function()
      return {
        peek = function()
          return nil, "connection reset"
        end,
      }
    end

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("peek_io_error", ctx.deny_reason)
    assert.equals("denied", ctx.request_state)
    assert.equals(ngx_mock.ERROR, ngx_mock._get_exited())
  end)
end)

-- ===========================================================================
-- detect_protocol 실패 -> fail-closed
-- ===========================================================================

describe("handler.preread - detect_protocol 실패 -> fail-closed", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
  end)

  it("detect_protocol 에러 -> fail-closed", function()
    _stream_ffi_stub.detect_result = { nil, "invalid_input", false }

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.truthy(ctx.deny_reason and ctx.deny_reason:find("detect_error"))
    assert.equals("denied", ctx.request_state)
    assert.equals(ngx_mock.ERROR, ngx_mock._get_exited())
  end)
end)

-- ===========================================================================
-- NEED_MORE_DATA -> retry loop -> fail-closed if still insufficient
-- ===========================================================================

describe("handler.preread - NEED_MORE_DATA retry loop", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
  end)

  it("detect_protocol NEED_MORE_DATA -> retries exhaust -> fail-closed", function()
    -- All calls return NEED_MORE_DATA
    _stream_ffi_stub.detect_result = { nil, nil, true }
    ngx_mock.req.socket = function()
      local responses = {
        "\x16",
        "\x16\x03",
        "\x16\x03\x01",
        "\x16\x03\x01\x00",
      }
      local call_count = 0
      return {
        peek = function(_, _bytes)
          call_count = call_count + 1
          return responses[call_count] or responses[#responses]
        end,
      }
    end

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("detect_need_more_data", ctx.deny_reason)
    assert.equals("denied", ctx.request_state)
    assert.equals(ngx_mock.ERROR, ngx_mock._get_exited())
    -- Should have retried (1 initial + up to 3 retries = 4 total calls)
    assert.is_true(_stream_ffi_stub.detect_call_count > 1)
  end)

  it("detect_protocol NEED_MORE_DATA -> succeeds on retry -> protocol detected", function()
    -- First call: NEED_MORE_DATA, second call: success with "tls"
    _stream_ffi_stub.detect_results = {
      { nil, nil, true },
      { "tls", nil, false },
    }
    _stream_ffi_stub.sni_result = { "example.com", nil, false }
    _evaluator_stub.get_policy_result = make_proxy_policy()
    _evaluator_stub.evaluate_stream_result = {
      action = "proxy",
      matched_rule = "rule-retry-ok",
      decision_source = "rule",
      upstream = "up:443",
    }
    ngx_mock.req.socket = function()
      local responses = {
        "\x16\x03",
        "\x16\x03\x01\x00\x05mock-tls-data",
      }
      local call_count = 0
      return {
        peek = function(_, _bytes)
          call_count = call_count + 1
          return responses[call_count] or responses[#responses]
        end,
      }
    end

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("tls", ctx.detected_protocol)
    assert.equals("proxy", ctx.action)
    assert.equals("proxied", ctx.request_state)
    assert.equals(2, _stream_ffi_stub.detect_call_count)
    assert.is_nil(ngx_mock._get_exited())
  end)

  it("detect_protocol NEED_MORE_DATA + socket timeout on retry -> fail-closed", function()
    _stream_ffi_stub.detect_result = { nil, nil, true }
    -- Socket returns timeout with no data on retry
    ngx_mock.req.socket = function()
      local call_count = 0
      return {
        peek = function(_, _bytes)
          call_count = call_count + 1
          if call_count == 1 then
            return "\x16\x03" -- initial partial data
          end
          return nil, "timeout" -- retry: timeout with no more data
        end,
      }
    end

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("detect_need_more_data", ctx.deny_reason)
    assert.equals("denied", ctx.request_state)
    assert.equals(ngx_mock.ERROR, ngx_mock._get_exited())
  end)
end)

-- ===========================================================================
-- SNI 추출 실패 -> fail-closed (malformed TLS / fragmented ClientHello)
-- ===========================================================================

describe("handler.preread - SNI 추출 실패 -> fail-closed", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
  end)

  it("SNI INVALID_INPUT (malformed TLS) -> fail-closed", function()
    _stream_ffi_stub.detect_result = { "tls", nil, false }
    _stream_ffi_stub.sni_result = { nil, "invalid_input", false }

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("malformed_tls:invalid_input", ctx.deny_reason)
    assert.equals("denied", ctx.request_state)
    assert.equals(ngx_mock.ERROR, ngx_mock._get_exited())
    assert.equals("deny", ngx_mock.var.luagate_stream_action)
  end)

  it("SNI NEED_MORE_DATA (fragmented ClientHello) -> fail-closed", function()
    _stream_ffi_stub.detect_result = { "tls", nil, false }
    _stream_ffi_stub.sni_result = { nil, nil, true }

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("sni_need_more_data", ctx.deny_reason)
    assert.equals("denied", ctx.request_state)
    assert.equals(ngx_mock.ERROR, ngx_mock._get_exited())
    assert.equals("deny", ngx_mock.var.luagate_stream_action)
  end)

  it("SNI empty string (no SNI extension) -> continue normally", function()
    _stream_ffi_stub.detect_result = { "tls", nil, false }
    _stream_ffi_stub.sni_result = { "", nil, false }
    _evaluator_stub.get_policy_result = make_proxy_policy()
    _evaluator_stub.evaluate_stream_result = {
      action = "proxy",
      matched_rule = "rule-no-sni",
      decision_source = "rule",
      upstream = "backend:443",
    }

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.is_nil(ctx.sni) -- empty string -> nil
    assert.equals("tls", ctx.detected_protocol)
    assert.equals("proxy", ctx.action)
    assert.equals("proxied", ctx.request_state)
    assert.is_nil(ngx_mock._get_exited())
  end)
end)

-- ===========================================================================
-- evaluator 없는 경우 -> fail-closed
-- ===========================================================================

describe("handler.preread - evaluator 로드 실패 -> fail-closed", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
  end)

  it("evaluator require 실패 -> fail-closed", function()
    _stream_ffi_stub.detect_result = { "tls", nil, false }
    _stream_ffi_stub.sni_result = { "example.com", nil, false }

    -- Make evaluator load fail
    package.loaded["luagate.policy.evaluator"] = nil
    local saved = package.preload["luagate.policy.evaluator"]
    package.preload["luagate.policy.evaluator"] = function()
      error("evaluator module not found")
    end

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("evaluator_load_error", ctx.deny_reason)
    assert.equals("denied", ctx.request_state)
    assert.equals(ngx_mock.ERROR, ngx_mock._get_exited())

    -- Restore
    package.preload["luagate.policy.evaluator"] = saved
  end)
end)

-- ===========================================================================
-- no policy -> fail-closed
-- ===========================================================================

describe("handler.preread - 정책 없음 -> fail-closed", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
  end)

  it("get_policy() = nil -> fail-closed deny", function()
    _stream_ffi_stub.detect_result = { "tls", nil, false }
    _stream_ffi_stub.sni_result = { "example.com", nil, false }
    _evaluator_stub.get_policy_result = nil

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("no_policy", ctx.deny_reason)
    assert.equals("denied", ctx.request_state)
    assert.equals(ngx_mock.ERROR, ngx_mock._get_exited())
    assert.equals("deny", ngx_mock.var.luagate_stream_action)
  end)

  it("get_policy() 에러 -> fail-closed", function()
    _stream_ffi_stub.detect_result = { "tls", nil, false }
    _stream_ffi_stub.sni_result = { "example.com", nil, false }
    _evaluator_stub.get_policy_error = "db connection failed"

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("policy_load_error", ctx.deny_reason)
    assert.equals("denied", ctx.request_state)
    assert.equals(ngx_mock.ERROR, ngx_mock._get_exited())
  end)
end)

-- ===========================================================================
-- shared dict incr 호출 확인 (active_stream)
-- ===========================================================================

describe("handler.preread - active_stream counter", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
  end)

  it("preread 시 luagate_connections.incr('active_stream', 1, 0) 호출", function()
    _stream_ffi_stub.detect_result = { "tls", nil, false }
    _stream_ffi_stub.sni_result = { "example.com", nil, false }
    _evaluator_stub.get_policy_result = make_proxy_policy()
    _evaluator_stub.evaluate_stream_result = {
      action = "proxy",
      matched_rule = "rule-a",
      decision_source = "rule",
      upstream = "up:443",
    }

    handler.preread()

    local incr_calls = ngx_mock._get_incr_calls()
    assert.is_true(#incr_calls >= 1)

    local found = false
    for _, call in ipairs(incr_calls) do
      if call.key == "active_stream" and call.delta == 1 and call.default == 0 then
        found = true
        break
      end
    end
    assert.is_true(found, "expected incr('active_stream', 1, 0) call")
  end)

  it("luagate_connections가 nil이어도 에러 없이 진행", function()
    ngx_mock.shared.luagate_connections = nil
    _stream_ffi_stub.detect_result = { "tls", nil, false }
    _stream_ffi_stub.sni_result = { "example.com", nil, false }
    _evaluator_stub.get_policy_result = make_proxy_policy()
    _evaluator_stub.evaluate_stream_result = {
      action = "proxy",
      matched_rule = "rule-a",
      decision_source = "rule",
      upstream = "up:443",
    }

    -- Should not error
    handler.preread()
    assert.is_nil(ngx_mock._get_exited())
  end)
end)

-- ===========================================================================
-- ngx.ctx.luagate_stream 컨텍스트 올바른 설정
-- ===========================================================================

describe("handler.preread - ngx.ctx.luagate_stream 컨텍스트", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
  end)

  it("ctx에 connection_id가 설정된다 (sw prefix + worker_id)", function()
    handler.preread()
    local ctx = ngx_mock.ctx.luagate_stream
    assert.is_not_nil(ctx.connection_id)
    assert.truthy(ctx.connection_id:find("^sw0%-"))
  end)

  it("ctx에 src_ip가 ngx.var.remote_addr로 설정된다", function()
    ngx_mock.var.remote_addr = "192.168.1.100"
    handler.preread()
    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("192.168.1.100", ctx.src_ip)
  end)

  it("ctx에 dst_port가 ngx.var.server_port로 설정된다", function()
    ngx_mock.var.server_port = "8443"
    handler.preread()
    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals(8443, ctx.dst_port)
  end)

  it("ctx.action 기본값은 'deny' (fail-closed)", function()
    -- Even before policy evaluation, default is deny
    -- Force early exit by failing socket to see default
    ngx_mock.req.socket = function()
      return nil, "socket error"
    end
    handler.preread()
    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("deny", ctx.action)
  end)

  it("ctx.worker_id가 ngx.worker.id() 값으로 설정된다", function()
    handler.preread()
    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals(0, ctx.worker_id)
  end)

  it("ctx.start_time_ms가 양수로 설정된다", function()
    handler.preread()
    local ctx = ngx_mock.ctx.luagate_stream
    assert.is_number(ctx.start_time_ms)
    assert.is_true(ctx.start_time_ms > 0)
  end)

  it("ctx.active_version이 shared dict에서 읽힌다", function()
    ngx_mock.shared.luagate_policy.get = function(_, key)
      if key == "stream:active_version" then
        return "v2026-03-18"
      end
      return nil
    end
    handler.preread()
    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("v2026-03-18", ctx.active_version)
  end)

  it("shared dict 없으면 active_version = 'none'", function()
    ngx_mock.shared.luagate_policy = nil
    handler.preread()
    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("none", ctx.active_version)
  end)

  it("luagate_conn_id nginx 변수가 설정된다", function()
    handler.preread()
    assert.is_not_nil(ngx_mock.var.luagate_conn_id)
    assert.truthy(ngx_mock.var.luagate_conn_id ~= "")
  end)

  it("luagate_worker_id nginx 변수가 '0'으로 설정된다", function()
    handler.preread()
    assert.equals("0", ngx_mock.var.luagate_worker_id)
  end)
end)

-- ===========================================================================
-- FFI 로드 실패 -> fail-closed
-- ===========================================================================

describe("handler.preread - FFI 로드 실패 -> fail-closed", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
  end)

  it("stream.ffi require 실패 -> ffi_load_error, fail-closed", function()
    package.loaded["luagate.stream.ffi"] = nil
    local saved = package.preload["luagate.stream.ffi"]
    package.preload["luagate.stream.ffi"] = function()
      error("libluagate_stream.so not found")
    end

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("ffi_load_error", ctx.deny_reason)
    assert.equals("denied", ctx.request_state)
    assert.equals(ngx_mock.ERROR, ngx_mock._get_exited())

    -- Restore
    package.preload["luagate.stream.ffi"] = saved
    package.loaded["luagate.stream.ffi"] = _stream_ffi_module
  end)
end)

-- ===========================================================================
-- empty preread data -> fail-closed
-- ===========================================================================

describe("handler.preread - empty preread data -> fail-closed", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
  end)

  it("빈 preread 데이터 -> empty_preread deny", function()
    ngx_mock.req.socket = function()
      return {
        peek = function()
          return nil, "timeout"
        end,
      }
    end

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("empty_preread", ctx.deny_reason)
    assert.equals("denied", ctx.request_state)
    assert.equals(ngx_mock.ERROR, ngx_mock._get_exited())
  end)
end)

-- ===========================================================================
-- ngx.ctx에 policy 객체가 저장되지 않는다 (불변식)
-- ===========================================================================

describe("handler.preread - 불변식: ngx.ctx 정책 캐시 금지", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
  end)

  it("preread 후 ngx.ctx에 policy 객체가 저장되지 않는다", function()
    local policy_obj = make_proxy_policy()
    _stream_ffi_stub.detect_result = { "tls", nil, false }
    _stream_ffi_stub.sni_result = { "example.com", nil, false }
    _evaluator_stub.get_policy_result = policy_obj
    _evaluator_stub.evaluate_stream_result = {
      action = "proxy",
      matched_rule = "rule-a",
      decision_source = "rule",
      upstream = "up:443",
    }

    handler.preread()

    assert.is_nil(ngx_mock.ctx.luagate_stream.policy)
    assert.are_not.equal(ngx_mock.ctx.luagate_stream, policy_obj)
  end)
end)

-- ===========================================================================
-- Non-TLS protocol does not call extract_sni
-- ===========================================================================

describe("handler.preread - non-TLS protocol skips SNI extraction", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
  end)

  it("HTTP protocol -> extract_sni 호출하지 않고 sni = nil", function()
    local sni_called = false
    package.loaded["luagate.stream.ffi"] = {
      detect_protocol = function()
        return "http", nil, false
      end,
      extract_sni = function()
        sni_called = true
        return "should-not-be-called", nil, false
      end,
      radix_build = _stream_ffi_module.radix_build,
      radix_lookup = _stream_ffi_module.radix_lookup,
      radix_free = _stream_ffi_module.radix_free,
    }

    _evaluator_stub.get_policy_result = make_proxy_policy()
    _evaluator_stub.evaluate_stream_result = {
      action = "proxy",
      matched_rule = "rule-http",
      decision_source = "rule",
      upstream = "http:80",
    }

    handler.preread()

    assert.is_false(sni_called)
    assert.is_nil(ngx_mock.ctx.luagate_stream.sni)

    -- Restore
    package.loaded["luagate.stream.ffi"] = _stream_ffi_module
  end)
end)

-- ===========================================================================
-- Radix tree rebuild on version change (Fix 3)
-- ===========================================================================

describe("handler.preread - radix tree CIDR integration", function()
  local ngx_mock
  -- Use unique version strings per test to force radix rebuild
  -- (module-level _radix_version persists across tests)
  local test_version_counter = 100

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    -- Each test gets a unique version to trigger radix rebuild
    test_version_counter = test_version_counter + 1
    local ver = "v-radix-" .. test_version_counter
    ngx_mock.shared.luagate_policy.get = function(_, key)
      if key == "stream:active_version" then
        return ver
      end
      return nil
    end
  end)

  it("정책에 src_ip_cidr 규칙이 있으면 radix_build 호출", function()
    local build_called = false
    local build_cidr = nil
    package.loaded["luagate.stream.ffi"] = {
      detect_protocol = _stream_ffi_module.detect_protocol,
      extract_sni = _stream_ffi_module.extract_sni,
      radix_build = function(cidr_list)
        build_called = true
        build_cidr = cidr_list
        return MOCK_RADIX_TREE, nil
      end,
      radix_lookup = function()
        return nil, nil
      end,
      radix_free = _stream_ffi_module.radix_free,
    }

    _stream_ffi_stub.detect_result = { "raw", nil, false }
    _evaluator_stub.get_policy_result = {
      global = { default_action = "deny" },
      rules = {},
      stream_rules = {
        { id = "allow-internal", scope = { src_ip_cidr = "10.0.0.0/8" }, action = "proxy" },
        { id = "allow-vpn", scope = { src_ip_cidr = "172.16.0.0/12" }, action = "proxy" },
      },
      _compiled_stream = {},
    }
    _evaluator_stub.evaluate_stream_result = {
      action = "deny",
      matched_rule = nil,
      decision_source = "default",
    }

    handler.preread()

    assert.is_true(build_called)
    assert.truthy(build_cidr and build_cidr:find("10.0.0.0/8"))
    assert.truthy(build_cidr and build_cidr:find("172.16.0.0/12"))

    -- Restore
    package.loaded["luagate.stream.ffi"] = _stream_ffi_module
  end)

  it("radix_lookup 결과가 request_ctx.radix_match_index에 전달된다", function()
    local captured_ctx = nil
    local saved_preload = package.preload["luagate.policy.evaluator"]
    package.preload["luagate.policy.evaluator"] = function()
      return {
        get_policy = function()
          return {
            global = { default_action = "deny" },
            rules = {},
            stream_rules = {
              { id = "allow-cidr", scope = { src_ip_cidr = "10.0.0.0/8" }, action = "proxy" },
            },
            _compiled_stream = {},
          }
        end,
        evaluate_stream = function(_rules, rctx)
          captured_ctx = rctx
          return { action = "proxy", matched_rule = "allow-cidr", decision_source = "rule", upstream = "up:80" }
        end,
      }
    end
    package.loaded["luagate.policy.evaluator"] = nil

    package.loaded["luagate.stream.ffi"] = {
      detect_protocol = function()
        return "raw", nil, false
      end,
      extract_sni = _stream_ffi_module.extract_sni,
      radix_build = function()
        return MOCK_RADIX_TREE, nil
      end,
      radix_lookup = function()
        return 0, nil
      end, -- matched rule index 0
      radix_free = _stream_ffi_module.radix_free,
    }

    handler.preread()

    assert.is_not_nil(captured_ctx)
    assert.equals(0, captured_ctx.radix_match_index)

    -- Restore
    package.loaded["luagate.stream.ffi"] = _stream_ffi_module
    package.preload["luagate.policy.evaluator"] = saved_preload
    package.loaded["luagate.policy.evaluator"] = nil
  end)

  it("radix_build CIDR list uses 1-based rule index (Fix 3)", function()
    local captured_cidr = nil
    package.loaded["luagate.stream.ffi"] = {
      detect_protocol = _stream_ffi_module.detect_protocol,
      extract_sni = _stream_ffi_module.extract_sni,
      radix_build = function(cidr_list)
        captured_cidr = cidr_list
        return MOCK_RADIX_TREE, nil
      end,
      radix_lookup = function()
        return nil, nil
      end,
      radix_free = _stream_ffi_module.radix_free,
    }

    _stream_ffi_stub.detect_result = { "raw", nil, false }
    _evaluator_stub.get_policy_result = {
      global = { default_action = "deny" },
      rules = {},
      stream_rules = {
        { id = "rule-a", scope = { src_ip_cidr = "10.0.0.0/8" }, action = "proxy" },
        { id = "rule-b", scope = { src_ip_cidr = "172.16.0.0/12" }, action = "proxy" },
      },
      _compiled_stream = {},
    }
    _evaluator_stub.evaluate_stream_result = {
      action = "deny",
      matched_rule = nil,
      decision_source = "default",
    }

    handler.preread()

    assert.is_not_nil(captured_cidr)
    -- 1-based: first rule at index 1, second at index 2 (not 0, 1)
    assert.truthy(captured_cidr:find("10.0.0.0/8,1"))
    assert.truthy(captured_cidr:find("172.16.0.0/12,2"))

    -- Restore
    package.loaded["luagate.stream.ffi"] = _stream_ffi_module
  end)

  it("radix_build 실패 시 LKG 유지, version 미갱신 (ADR-009)", function()
    -- First call: build succeeds -> tree exists
    local first_tree = { _type = "first_tree" }
    local free_calls = {}

    package.loaded["luagate.stream.ffi"] = {
      detect_protocol = function()
        return "raw", nil, false
      end,
      extract_sni = _stream_ffi_module.extract_sni,
      radix_build = function()
        return first_tree, nil
      end,
      radix_lookup = function()
        return nil, nil
      end,
      radix_free = function(tree)
        table.insert(free_calls, tree)
      end,
    }

    _evaluator_stub.get_policy_result = {
      global = { default_action = "deny" },
      rules = {},
      stream_rules = {
        { id = "rule-a", scope = { src_ip_cidr = "10.0.0.0/8" }, action = "proxy" },
      },
      _compiled_stream = {},
    }
    _evaluator_stub.evaluate_stream_result = {
      action = "deny",
      matched_rule = nil,
      decision_source = "default",
    }

    handler.preread()

    -- First call succeeded, tree was built (may have freed a prior test's tree)
    local free_count_after_first = #free_calls

    -- Second call: new version, radix_build fails
    test_version_counter = test_version_counter + 100
    local ver2 = "v-radix-lkg-" .. test_version_counter
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    ngx_mock.shared.luagate_policy.get = function(_, key)
      if key == "stream:active_version" then
        return ver2
      end
      return nil
    end

    package.loaded["luagate.stream.ffi"] = {
      detect_protocol = function()
        return "raw", nil, false
      end,
      extract_sni = _stream_ffi_module.extract_sni,
      radix_build = function()
        return nil, "radix_build_fail:-1"
      end,
      radix_lookup = function()
        return nil, nil
      end,
      radix_free = function(tree)
        table.insert(free_calls, tree)
      end,
    }

    handler.preread()

    -- LKG: old tree should NOT be freed after the second call
    assert.equals(free_count_after_first, #free_calls)

    -- Should have continued to evaluation
    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("deny", ctx.action)
    assert.equals("denied", ctx.request_state)

    -- Restore
    package.loaded["luagate.stream.ffi"] = _stream_ffi_module
  end)

  it("radix_build timeout 시 per-worker leak 카운터 증가 (ADR-009)", function()
    -- First: build a tree so we have LKG
    local first_tree = { _type = "leak_test_tree" }

    package.loaded["luagate.stream.ffi"] = {
      detect_protocol = function()
        return "raw", nil, false
      end,
      extract_sni = _stream_ffi_module.extract_sni,
      radix_build = function()
        return first_tree, nil
      end,
      radix_lookup = function()
        return nil, nil
      end,
      radix_free = _stream_ffi_module.radix_free,
    }

    _evaluator_stub.get_policy_result = {
      global = { default_action = "deny" },
      rules = {},
      stream_rules = {
        { id = "rule-a", scope = { src_ip_cidr = "10.0.0.0/8" }, action = "proxy" },
      },
      _compiled_stream = {},
    }
    _evaluator_stub.evaluate_stream_result = {
      action = "deny",
      matched_rule = nil,
      decision_source = "default",
    }

    handler.preread()

    -- Now: new version with timeout error (-5)
    test_version_counter = test_version_counter + 1
    local ver2 = "v-radix-leak-" .. test_version_counter
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    ngx_mock.shared.luagate_policy.get = function(_, key)
      if key == "stream:active_version" then
        return ver2
      end
      return nil
    end

    package.loaded["luagate.stream.ffi"] = {
      detect_protocol = function()
        return "raw", nil, false
      end,
      extract_sni = _stream_ffi_module.extract_sni,
      radix_build = function()
        return nil, "timeout:-5"
      end,
      radix_lookup = function()
        return nil, nil
      end,
      radix_free = _stream_ffi_module.radix_free,
    }

    handler.preread()

    -- Per-worker leak counter should have been incremented
    local leak_count = ngx_mock.shared.luagate_metrics:get("ffi:timeout:leak:0")
    assert.equals(1, leak_count)

    -- Restore
    package.loaded["luagate.stream.ffi"] = _stream_ffi_module
  end)

  it("radix_build 실패 후 다음 요청에서 rebuild 재시도 (ADR-009)", function()
    -- Call 1: build fails
    local fail_ver = "v-radix-retry-" .. (test_version_counter + 200)
    test_version_counter = test_version_counter + 200

    local build_call_count = 0
    local retry_tree = { _type = "retry_tree" }

    local current_build_fn = function()
      build_call_count = build_call_count + 1
      if build_call_count == 1 then
        return nil, "radix_build_fail:-1"
      end
      return retry_tree, nil
    end

    package.loaded["luagate.stream.ffi"] = {
      detect_protocol = function()
        return "raw", nil, false
      end,
      extract_sni = _stream_ffi_module.extract_sni,
      radix_build = function()
        return current_build_fn()
      end,
      radix_lookup = function()
        return nil, nil
      end,
      radix_free = _stream_ffi_module.radix_free,
    }

    ngx_mock.shared.luagate_policy.get = function(_, key)
      if key == "stream:active_version" then
        return fail_ver
      end
      return nil
    end

    _evaluator_stub.get_policy_result = {
      global = { default_action = "deny" },
      rules = {},
      stream_rules = {
        { id = "rule-a", scope = { src_ip_cidr = "10.0.0.0/8" }, action = "proxy" },
      },
      _compiled_stream = {},
    }
    _evaluator_stub.evaluate_stream_result = {
      action = "deny",
      matched_rule = nil,
      decision_source = "default",
    }

    -- First request: build fails
    handler.preread()
    assert.equals(1, build_call_count)

    -- Second request: same version -> should retry since version wasn't updated
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    ngx_mock.shared.luagate_policy.get = function(_, key)
      if key == "stream:active_version" then
        return fail_ver
      end
      return nil
    end

    handler.preread()
    assert.equals(2, build_call_count) -- Retried!

    -- Restore
    package.loaded["luagate.stream.ffi"] = _stream_ffi_module
  end)

  it("cold start radix_build 실패 시 non-CIDR proxy 규칙은 evaluator가 처리 (ADR-009)", function()
    -- Simulate cold start: first clear any existing radix tree by loading
    -- a policy with no CIDR rules (this sets _radix_tree = nil in module).
    test_version_counter = test_version_counter + 1
    local clear_ver = "v-clear-tree-" .. test_version_counter
    ngx_mock.shared.luagate_policy.get = function(_, key)
      if key == "stream:active_version" then
        return clear_ver
      end
      return nil
    end
    _evaluator_stub.get_policy_result = {
      global = { default_action = "deny" },
      rules = {},
      stream_rules = {}, -- no CIDR rules -> clears _radix_tree
      _compiled_stream = {},
    }
    _evaluator_stub.evaluate_stream_result = {
      action = "deny",
      matched_rule = nil,
      decision_source = "default",
    }
    handler.preread() -- clears _radix_tree to nil

    -- Now simulate cold start: radix_build fails with no LKG tree
    local build_err_logged = false
    local logged_messages = {}
    ngx_mock.log = function(level, ...)
      local parts = { ... }
      local msg = table.concat(parts, "")
      logged_messages[#logged_messages + 1] = { level = level, msg = msg }
      if msg:find("radix_build failed") then
        build_err_logged = true
      end
    end

    -- Force a fresh version to trigger rebuild
    test_version_counter = test_version_counter + 1
    local cold_ver = "v-cold-start-" .. test_version_counter
    ngx_mock.shared.luagate_policy.get = function(_, key)
      if key == "stream:active_version" then
        return cold_ver
      end
      return nil
    end
    -- Reset ctx for next preread call
    ngx_mock.ctx = {}

    package.loaded["luagate.stream.ffi"] = {
      detect_protocol = function()
        return "raw", nil, false
      end,
      extract_sni = _stream_ffi_module.extract_sni,
      radix_build = function()
        return nil, "timeout:-5"
      end,
      radix_lookup = function()
        return nil, nil
      end,
      radix_free = _stream_ffi_module.radix_free,
    }

    _evaluator_stub.get_policy_result = {
      global = { default_action = "deny" },
      rules = {},
      stream_rules = {
        { id = "rule-a", scope = { src_ip_cidr = "10.0.0.0/8" }, action = "proxy" },
      },
      _compiled_stream = { { id = "compiled-non-cidr" } },
    }
    -- Evaluator returns proxy for a non-CIDR rule match —
    -- proves evaluator decision is respected even when radix_build fails
    _evaluator_stub.evaluate_stream_result = {
      action = "proxy",
      matched_rule = "compiled-non-cidr",
      decision_source = "rule",
      upstream = "backend:8080",
    }

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    -- Non-CIDR proxy rule is respected even when radix_build fails
    assert.equals("proxy", ctx.action)
    assert.equals("proxied", ctx.request_state)
    assert.equals("backend:8080", ctx.upstream)
    assert.is_true(build_err_logged, "radix_build failure should be logged")

    -- Verify ERR-level log for cold start (no LKG tree)
    local found_err_log = false
    for _, entry in ipairs(logged_messages) do
      if entry.msg:find("no LKG tree available") and entry.level == ngx_mock.ERR then
        found_err_log = true
      end
    end
    assert.is_true(found_err_log, "cold start radix_build failure should log at ERR level")

    -- Restore
    package.loaded["luagate.stream.ffi"] = _stream_ffi_module
  end)

  it("cold start radix_build 실패 + CIDR-only 규칙 -> evaluator default deny (ADR-009)", function()
    -- First clear any existing radix tree
    test_version_counter = test_version_counter + 1
    local clear_ver = "v-clear-tree2-" .. test_version_counter
    ngx_mock.shared.luagate_policy.get = function(_, key)
      if key == "stream:active_version" then
        return clear_ver
      end
      return nil
    end
    _evaluator_stub.get_policy_result = {
      global = { default_action = "deny" },
      rules = {},
      stream_rules = {}, -- no CIDR rules -> clears _radix_tree
      _compiled_stream = {},
    }
    _evaluator_stub.evaluate_stream_result = {
      action = "deny",
      matched_rule = nil,
      decision_source = "default",
    }
    handler.preread() -- clears _radix_tree to nil

    -- Now cold start: radix_build fails, all rules are CIDR-based
    test_version_counter = test_version_counter + 1
    local cold_ver = "v-cold-cidr-" .. test_version_counter
    ngx_mock.shared.luagate_policy.get = function(_, key)
      if key == "stream:active_version" then
        return cold_ver
      end
      return nil
    end
    ngx_mock.ctx = {}

    local captured_request_ctx = nil
    -- Override evaluator to capture request_ctx and verify radix_match_index
    package.loaded["luagate.policy.evaluator"] = {
      get_policy = function()
        return {
          global = { default_action = "deny" },
          rules = {},
          stream_rules = {
            { id = "cidr-rule-1", scope = { src_ip_cidr = "192.168.0.0/16" }, action = "proxy" },
            { id = "cidr-rule-2", scope = { src_ip_cidr = "172.16.0.0/12" }, action = "proxy" },
          },
          _compiled_stream = { { id = "cidr-compiled-1" }, { id = "cidr-compiled-2" } },
        }
      end,
      evaluate_stream = function(_rules, req_ctx)
        captured_request_ctx = req_ctx
        -- No radix_match_index -> no CIDR rule matches -> default deny
        return { action = "deny", matched_rule = nil, decision_source = "default" }
      end,
    }

    package.loaded["luagate.stream.ffi"] = {
      detect_protocol = function()
        return "raw", nil, false
      end,
      extract_sni = _stream_ffi_module.extract_sni,
      radix_build = function()
        return nil, "build_error"
      end,
      radix_lookup = function()
        error("radix_lookup should not be called when tree is nil")
      end,
      radix_free = _stream_ffi_module.radix_free,
    }

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("deny", ctx.action)
    assert.equals("denied", ctx.request_state)
    -- Verify evaluator received nil radix_match_index (no tree -> no lookup)
    assert.is_not_nil(captured_request_ctx, "evaluator should have been called")
    assert.is_nil(
      captured_request_ctx.radix_match_index,
      "radix_match_index should be nil when radix_build fails on cold start"
    )

    -- Restore
    package.loaded["luagate.stream.ffi"] = _stream_ffi_module
    package.loaded["luagate.policy.evaluator"] = nil
  end)

  it("radix_lookup 에러 시 fail-closed deny (불변식)", function()
    -- Build a tree successfully first
    local lookup_tree = { _type = "lookup_fail_tree" }
    test_version_counter = test_version_counter + 1
    local ver = "v-lookup-fail-" .. test_version_counter
    ngx_mock.shared.luagate_policy.get = function(_, key)
      if key == "stream:active_version" then
        return ver
      end
      return nil
    end

    package.loaded["luagate.stream.ffi"] = {
      detect_protocol = function()
        return "raw", nil, false
      end,
      extract_sni = _stream_ffi_module.extract_sni,
      radix_build = function()
        return lookup_tree, nil
      end,
      radix_lookup = function()
        return nil, "ffi_timeout:-5"
      end,
      radix_free = _stream_ffi_module.radix_free,
    }

    _evaluator_stub.get_policy_result = {
      global = { default_action = "deny" },
      rules = {},
      stream_rules = {
        { id = "rule-a", scope = { src_ip_cidr = "10.0.0.0/8" }, action = "proxy" },
      },
      _compiled_stream = {},
    }

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("radix_lookup_error", ctx.deny_reason)
    assert.equals("denied", ctx.request_state)
    assert.equals(ngx_mock.ERROR, ngx_mock._get_exited())
    assert.equals("deny", ngx_mock.var.luagate_stream_action)

    -- Restore
    package.loaded["luagate.stream.ffi"] = _stream_ffi_module
  end)
end)

-- ===========================================================================
-- decision_source 값 spec 준수 (Fix 2: stream-pipeline.md §4)
-- ===========================================================================

describe("handler.preread - decision_source spec compliance (Fix 2)", function()
  local ngx_mock
  local test_ver_counter = 200

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    test_ver_counter = test_ver_counter + 1
    local ver = "v-ds-" .. test_ver_counter
    ngx_mock.shared.luagate_policy.get = function(_, key)
      if key == "stream:active_version" then
        return ver
      end
      return nil
    end
  end)

  it("evaluator decision_source 'rule' -> 'policy_engine'", function()
    _stream_ffi_stub.detect_result = { "tls", nil, false }
    _stream_ffi_stub.sni_result = { "example.com", nil, false }
    _evaluator_stub.get_policy_result = make_proxy_policy()
    _evaluator_stub.evaluate_stream_result = {
      action = "proxy",
      matched_rule = "rule-a",
      decision_source = "rule",
      upstream = "up:443",
    }

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("policy_engine", ctx.decision_source)
    assert.equals("policy_engine", ngx_mock.var.luagate_decision_source)
  end)

  it("evaluator decision_source 'default' -> 'policy_engine'", function()
    _stream_ffi_stub.detect_result = { "raw", nil, false }
    _evaluator_stub.get_policy_result = make_proxy_policy()
    _evaluator_stub.evaluate_stream_result = {
      action = "deny",
      matched_rule = nil,
      decision_source = "default",
    }

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("policy_engine", ctx.decision_source)
    assert.equals("policy_engine", ngx_mock.var.luagate_decision_source)
  end)

  it("evaluator decision_source 'error' -> 'policy_engine'", function()
    _stream_ffi_stub.detect_result = { "raw", nil, false }
    _evaluator_stub.get_policy_result = make_proxy_policy()
    _evaluator_stub.evaluate_stream_result = {
      action = "deny",
      matched_rule = nil,
      decision_source = "error",
    }

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("policy_engine", ctx.decision_source)
    assert.equals("policy_engine", ngx_mock.var.luagate_decision_source)
  end)

  it("evaluator decision_source nil -> 'policy_engine' (default)", function()
    _stream_ffi_stub.detect_result = { "raw", nil, false }
    _evaluator_stub.get_policy_result = make_proxy_policy()
    _evaluator_stub.evaluate_stream_result = {
      action = "deny",
      matched_rule = nil,
      decision_source = nil,
    }

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("policy_engine", ctx.decision_source)
  end)

  it("fail-closed paths use 'nginx_core' (socket error)", function()
    ngx_mock.req.socket = function()
      return nil, "no socket"
    end

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("nginx_core", ctx.decision_source)
  end)

  it("fail-closed paths use 'policy_engine' (no_policy)", function()
    _stream_ffi_stub.detect_result = { "tls", nil, false }
    _stream_ffi_stub.sni_result = { "example.com", nil, false }
    _evaluator_stub.get_policy_result = nil

    handler.preread()

    local ctx = ngx_mock.ctx.luagate_stream
    assert.equals("policy_engine", ctx.decision_source)
  end)
end)
