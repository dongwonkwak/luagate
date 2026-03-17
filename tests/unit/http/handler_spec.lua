--- Unit tests for lua/luagate/http/handler.lua
-- Implementation: lua/luagate/http/handler.lua
-- Tests: tests/unit/http/handler_spec.lua
--
-- handler.lua는 OpenResty ngx 전역에 강하게 의존하므로
-- 모든 테스트에서 ngx mock을 주입한다.
--
-- Stubs injected before module load:
--   - cjson     → dkjson wrapper
--   - luagate.policy.evaluator → 제어 가능한 stub
--   - luagate.log.http         → 호출 추적 stub
--   - luagate.metrics.collector → 호출 추적 stub

-- ---------------------------------------------------------------------------
-- cjson stub (dkjson wrapper — LuaJIT 없는 busted 환경)
-- ---------------------------------------------------------------------------
package.preload["cjson"] = function()
  local dkjson = require("dkjson")
  return {
    encode = dkjson.encode,
    decode = dkjson.decode,
  }
end

package.preload["cjson.safe"] = function()
  local dkjson = require("dkjson")
  return {
    encode = dkjson.encode,
    decode = dkjson.decode,
    null = {},
    encode_empty_table_as_array = function() end,
  }
end

-- ---------------------------------------------------------------------------
-- evaluator stub — 테스트마다 제어 가능하도록 전역 레지스트리 사용
-- ---------------------------------------------------------------------------
local _evaluator_stub = {
  get_policy_result = nil, -- nil = 정책 없음, table = 정책 반환
  evaluate_result = nil, -- evaluate() 반환값 제어
}

package.preload["luagate.policy.evaluator"] = function()
  return {
    get_policy = function()
      return _evaluator_stub.get_policy_result
    end,
    evaluate = function(_rules, _ctx, _default)
      if _evaluator_stub.evaluate_result then
        return _evaluator_stub.evaluate_result
      end
      return { action = "allow", matched_rule = nil, decision_source = "default" }
    end,
  }
end

-- ---------------------------------------------------------------------------
-- log.http stub — finalize 호출 추적
-- ---------------------------------------------------------------------------
local _log_http_call_count = 0

package.preload["luagate.log.http"] = function()
  return {
    finalize = function()
      _log_http_call_count = _log_http_call_count + 1
    end,
  }
end

-- ---------------------------------------------------------------------------
-- metrics.collector stub — record 호출 추적
-- ---------------------------------------------------------------------------
local _metrics_record_call_count = 0

package.preload["luagate.metrics.collector"] = function()
  return {
    record = function(_ctx)
      _metrics_record_call_count = _metrics_record_call_count + 1
    end,
  }
end

-- ---------------------------------------------------------------------------
-- decoder.ffi stub — normalize_path / normalize_query 결과 제어
-- ---------------------------------------------------------------------------
local _decoder_stub = {
  normalize_path_result = nil, -- {result, err, partial}
  normalize_query_result = nil, -- {result, err, partial}
}

-- Build the decoder stub module table (reused across resets)
local _decoder_stub_module = {
  normalize_path = function(path_raw)
    if _decoder_stub.normalize_path_result then
      local r = _decoder_stub.normalize_path_result
      return r[1], r[2], r[3]
    end
    -- default: pass-through (no normalization)
    return path_raw, nil, false
  end,
  normalize_query = function(query_raw)
    if _decoder_stub.normalize_query_result then
      local r = _decoder_stub.normalize_query_result
      return r[1], r[2], r[3]
    end
    -- default: pass-through
    return query_raw, nil, false
  end,
}

package.preload["luagate.decoder.ffi"] = function()
  return _decoder_stub_module
end

-- ---------------------------------------------------------------------------
-- scanner.ffi stub — scan 결과 제어
-- ---------------------------------------------------------------------------
local _scanner_stub = {
  scan_result = nil, -- {result_table, err_string}
}

-- Build the scanner stub module table (reused across resets)
local _scanner_stub_module = {
  scan = function(_ctx)
    if _scanner_stub.scan_result then
      local r = _scanner_stub.scan_result
      return r[1], r[2]
    end
    -- default: no threat
    return { threat_type = nil, rule_name = nil, threat_score = 0 }, nil
  end,
  init = function(_path)
    return true, nil
  end,
}

package.preload["luagate.scanner.ffi"] = function()
  return _scanner_stub_module
end

-- ---------------------------------------------------------------------------
-- ngx mock 팩토리
-- ---------------------------------------------------------------------------
local function make_ngx(overrides)
  local exited_with = nil
  local logged = {}

  local mock = {
    var = {
      luagate_request_id = "test-req-id-001",
      request_uri = "/api/test?foo=bar",
      uri = "/api/test",
      args = "foo=bar",
      remote_addr = "10.0.0.1",
      remote_port = "54321",
      host = "example.com",
      request_method = "GET",
      server_port = "8080",
      server_protocol = "HTTP/1.1",
      time_iso8601 = "2026-03-17T00:00:00+00:00",
      status = "200",
      request_time = "0.001",
      upstream_response_time = "-",
      content_length = "",
      http_user_agent = "test-agent/1.0",
      bytes_sent = "512",
      -- luagate nginx vars (set in rewrite phase)
      luagate_decision_source = "nginx_core",
      luagate_action = "allow",
      luagate_matched_rule = "null",
      luagate_threat_type = "null",
      luagate_rule_name = "null",
      luagate_request_state = "short_circuited",
      luagate_deny_reason = "null",
      luagate_threat_score = "null",
      luagate_worker_id = "0",
      luagate_path_raw = "",
      luagate_path_normalized = "",
      luagate_query_string = "",
      luagate_src_ip = "10.0.0.1",
      luagate_active_version = "none",
      luagate_log_json = "",
    },
    ctx = {},
    shared = {
      luagate_policy = {
        get = function(_, _key)
          return nil
        end,
      },
      luagate_metrics = {
        incr = function(_, _key, _delta, _default)
          return 1, nil
        end,
      },
    },
    header = {},
    status = 0,
    WARN = 5,
    ERR = 4,
    log = function(_, ...)
      local parts = { ... }
      logged[#logged + 1] = table.concat(parts, "")
    end,
    exit = function(code)
      exited_with = code
      -- ngx.exit()는 실제로는 코루틴을 종료하지만, 테스트에서는 추적만 한다
    end,
    say = function(_s) end,
    now = function()
      return 1710633600.0
    end,
    worker = {
      id = function()
        return 0
      end,
    },
    req = {
      get_uri_args = function()
        return {}
      end,
      get_headers = function()
        return {}
      end,
      get_method = function()
        return "GET"
      end,
    },
  }

  -- exit 추적을 외부에서 확인할 수 있도록 getter 추가
  mock._get_exited = function()
    return exited_with
  end
  mock._get_logged = function()
    return logged
  end

  -- override 적용
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
-- 모듈 로드 전 ngx 전역 초기화
-- (handler.lua는 require 시점에는 ngx에 접근하지 않으므로 안전)
-- ---------------------------------------------------------------------------
local _saved_ngx = _G.ngx
_G.ngx = make_ngx()

-- handler 모듈을 require한 후 각 테스트에서 _G.ngx를 교체하는 방식을 사용
-- (handler.lua 내부 함수들은 ngx를 전역으로 참조하므로 _G.ngx 교체로 제어 가능)
local handler = require("luagate.http.handler")

-- 전체 테스트 완료 후 ngx 전역 및 package.preload 복원 (다른 spec 파일과의 격리 보장)
teardown(function()
  _G.ngx = _saved_ngx
  -- handler_spec에서 등록한 preload stub을 제거하여 다른 spec이 실제 모듈을 로드하도록 한다
  package.preload["luagate.policy.evaluator"] = nil
  package.preload["luagate.log.http"] = nil
  package.preload["luagate.metrics.collector"] = nil
  package.preload["luagate.decoder.ffi"] = nil
  package.preload["luagate.scanner.ffi"] = nil
  -- loaded 캐시도 제거 (evaluator_spec이 자체 ngx=nil 환경에서 fresh require하도록)
  package.loaded["luagate.policy.evaluator"] = nil
  package.loaded["luagate.log.http"] = nil
  package.loaded["luagate.metrics.collector"] = nil
  package.loaded["luagate.decoder.ffi"] = nil
  package.loaded["luagate.scanner.ffi"] = nil
  package.loaded["luagate.http.handler"] = nil
end)

-- ---------------------------------------------------------------------------
-- 헬퍼: 테스트 전 상태 초기화
-- ---------------------------------------------------------------------------
local function reset_stubs()
  _evaluator_stub.get_policy_result = nil
  _evaluator_stub.evaluate_result = nil
  _log_http_call_count = 0
  _metrics_record_call_count = 0
  _decoder_stub.normalize_path_result = nil
  _decoder_stub.normalize_query_result = nil
  _scanner_stub.scan_result = nil
  -- Explicitly set package.loaded with our stub modules to prevent cross-spec
  -- contamination (e.g. decoder/ffi_spec.lua may pollute package.loaded with
  -- the real module). This ensures handler.rewrite()/access() pcall(require,...)
  -- always returns our controlled stubs.
  package.loaded["luagate.decoder.ffi"] = _decoder_stub_module
  package.loaded["luagate.scanner.ffi"] = _scanner_stub_module
  package.loaded["luagate.policy.evaluator"] = nil
end

-- ===========================================================================
-- rewrite() 테스트
-- ===========================================================================

describe("handler.rewrite — ngx.ctx 초기화", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
  end)

  it("rewrite() 호출 후 ngx.ctx.luagate가 테이블로 초기화된다", function()
    handler.rewrite()
    assert.is_table(ngx_mock.ctx.luagate)
  end)

  it("ngx.ctx.luagate.request_id가 ngx.var.luagate_request_id 값을 갖는다", function()
    ngx_mock.var.luagate_request_id = "req-xyz-9876"
    handler.rewrite()
    assert.are.equal("req-xyz-9876", ngx_mock.ctx.luagate.request_id)
  end)

  it("path_raw가 query string을 제외하고 계산된다 (/api/test?foo=bar → /api/test)", function()
    ngx_mock.var.request_uri = "/api/test?foo=bar"
    handler.rewrite()
    assert.are.equal("/api/test", ngx_mock.ctx.luagate.path_raw)
    assert.are.equal("/api/test", ngx_mock.var.luagate_path_raw)
  end)

  it("query string 없는 URI는 path_raw가 그대로 설정된다", function()
    ngx_mock.var.request_uri = "/health"
    ngx_mock.var.args = ""
    handler.rewrite()
    assert.are.equal("/health", ngx_mock.ctx.luagate.path_raw)
  end)

  it("nginx 변수 기본값이 설정된다: luagate_decision_source = 'nginx_core'", function()
    handler.rewrite()
    assert.are.equal("nginx_core", ngx_mock.var.luagate_decision_source)
  end)

  it("nginx 변수 기본값이 설정된다: luagate_action = 'allow'", function()
    handler.rewrite()
    assert.are.equal("allow", ngx_mock.var.luagate_action)
  end)

  it("nginx 변수 기본값이 설정된다: luagate_request_state = 'short_circuited'", function()
    handler.rewrite()
    assert.are.equal("short_circuited", ngx_mock.var.luagate_request_state)
  end)

  it("luagate_worker_id가 ngx.worker.id() 반환값 문자열로 설정된다", function()
    handler.rewrite()
    assert.are.equal("0", ngx_mock.var.luagate_worker_id)
  end)

  it("active_version이 shared dict의 http:active_version 값으로 스냅샷된다", function()
    ngx_mock.shared.luagate_policy.get = function(_, key)
      if key == "http:active_version" then
        return "v2025-03-17"
      end
      return nil
    end
    handler.rewrite()
    assert.are.equal("v2025-03-17", ngx_mock.ctx.luagate.active_version)
    assert.are.equal("v2025-03-17", ngx_mock.var.luagate_active_version)
  end)

  it("shared dict 없으면 active_version = 'none'으로 설정된다", function()
    ngx_mock.shared.luagate_policy = nil
    handler.rewrite()
    assert.are.equal("none", ngx_mock.ctx.luagate.active_version)
  end)

  it("ngx.ctx.luagate.start_time_ms가 숫자로 설정된다", function()
    handler.rewrite()
    assert.is_number(ngx_mock.ctx.luagate.start_time_ms)
    assert.is_true(ngx_mock.ctx.luagate.start_time_ms > 0)
  end)

  it("ngx.ctx.luagate에 policy 객체가 저장되지 않는다 (불변식: ngx.ctx 정책 캐시 금지)", function()
    -- evaluator stub이 정책을 반환하더라도 ctx에 저장해서는 안 된다
    _evaluator_stub.get_policy_result = { global = { default_action = "deny" }, rules = {}, stream_rules = {} }
    handler.rewrite()
    -- rewrite 단계에서 policy를 로드하지 않으므로 ctx에 policy 없음
    assert.is_nil(ngx_mock.ctx.luagate.policy)
  end)

  it("decoder 정상 → path_normalized가 디코딩 결과로 설정된다", function()
    _decoder_stub.normalize_path_result = { "/decoded/path", nil, false }
    _decoder_stub.normalize_query_result = { "decoded=query", nil, false }
    handler.rewrite()
    assert.are.equal("/decoded/path", ngx_mock.ctx.luagate.path_normalized)
    assert.are.equal("/decoded/path", ngx_mock.var.luagate_path_normalized)
    assert.are.equal("decoded=query", ngx_mock.ctx.luagate.query_normalized)
    assert.is_nil(ngx_mock.ctx.luagate.decoder_error)
  end)

  it("decoder path error → path_normalized은 path_raw fallback, decoder_error 설정", function()
    _decoder_stub.normalize_path_result = { nil, "ffi_fail:-3", false }
    handler.rewrite()
    -- path_normalized falls back to path_raw
    assert.are.equal("/api/test", ngx_mock.ctx.luagate.path_normalized)
    assert.are.equal("ffi_fail:-3", ngx_mock.ctx.luagate.decoder_error)
  end)

  it("decoder query error → query_normalized은 query_raw fallback, decoder_error 설정", function()
    _decoder_stub.normalize_query_result = { nil, "ffi_fail:-4", false }
    handler.rewrite()
    assert.are.equal("foo=bar", ngx_mock.ctx.luagate.query_normalized)
    assert.is_not_nil(ngx_mock.ctx.luagate.decoder_error)
  end)

  it("decoder load error → decoder_error = 'decoder_load_error'", function()
    -- Force decoder load to fail by making preload raise an error
    package.loaded["luagate.decoder.ffi"] = nil
    local saved_preload = package.preload["luagate.decoder.ffi"]
    package.preload["luagate.decoder.ffi"] = function()
      error("simulated decoder load failure")
    end
    handler.rewrite()
    assert.are.equal("decoder_load_error", ngx_mock.ctx.luagate.decoder_error)
    -- path_normalized falls back to path_raw
    assert.are.equal("/api/test", ngx_mock.ctx.luagate.path_normalized)
    -- Restore
    package.preload["luagate.decoder.ffi"] = saved_preload
    package.loaded["luagate.decoder.ffi"] = _decoder_stub_module
  end)

  it("decoder path exception → decoder_error = 'decoder_path_exception'", function()
    package.loaded["luagate.decoder.ffi"] = {
      normalize_path = function()
        error("simulated decoder path exception")
      end,
      normalize_query = function(query_raw)
        return query_raw, nil, false
      end,
    }
    handler.rewrite()
    assert.are.equal("decoder_path_exception", ngx_mock.ctx.luagate.decoder_error)
    assert.are.equal("/api/test", ngx_mock.ctx.luagate.path_normalized)
    package.loaded["luagate.decoder.ffi"] = _decoder_stub_module
  end)

  it("decoder query exception → decoder_error = 'decoder_query_exception'", function()
    package.loaded["luagate.decoder.ffi"] = {
      normalize_path = function(path_raw)
        return path_raw, nil, false
      end,
      normalize_query = function()
        error("simulated decoder query exception")
      end,
    }
    handler.rewrite()
    assert.are.equal("decoder_query_exception", ngx_mock.ctx.luagate.decoder_error)
    assert.are.equal("foo=bar", ngx_mock.ctx.luagate.query_normalized)
    package.loaded["luagate.decoder.ffi"] = _decoder_stub_module
  end)

  it("decoder partial decode → decoder_error is nil, path_normalized uses partial result", function()
    _decoder_stub.normalize_path_result = { "/partial/path", nil, true }
    handler.rewrite()
    assert.are.equal("/partial/path", ngx_mock.ctx.luagate.path_normalized)
    assert.is_nil(ngx_mock.ctx.luagate.decoder_error)
  end)
end)

-- ===========================================================================
-- access() 테스트
-- ===========================================================================

describe("handler.access — fail-closed: 정책 없음 → 403", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    -- rewrite 먼저 실행하여 ctx 초기화
    handler.rewrite()
  end)

  it("get_policy()가 nil 반환 시 403 deny (fail-closed)", function()
    _evaluator_stub.get_policy_result = nil
    handler.access()
    assert.are.equal(403, ngx_mock.status)
    assert.are.equal(403, ngx_mock._get_exited())
  end)

  it("get_policy()가 nil이면 X-LuaGate-Block-Reason = 'no_policy' 설정", function()
    _evaluator_stub.get_policy_result = nil
    handler.access()
    assert.are.equal("no_policy", ngx_mock.header["X-LuaGate-Block-Reason"])
  end)

  it("get_policy()가 nil이면 luagate_decision_source = 'policy_engine' 설정", function()
    _evaluator_stub.get_policy_result = nil
    handler.access()
    assert.are.equal("policy_engine", ngx_mock.var.luagate_decision_source)
  end)
end)

describe("handler.access — allow path", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    handler.rewrite()
  end)

  it("evaluate() allow 결과 → ctx.action = 'allow'", function()
    _evaluator_stub.get_policy_result = {
      global = { default_action = "deny" },
      rules = {},
      stream_rules = {},
      _compiled_http = {},
    }
    _evaluator_stub.evaluate_result = { action = "allow", matched_rule = "rule-health", decision_source = "rule" }
    handler.access()
    assert.are.equal("allow", ngx_mock.ctx.luagate.action)
  end)

  it("evaluate() allow 결과 → ctx.request_state = 'completed'", function()
    _evaluator_stub.get_policy_result = {
      global = { default_action = "deny" },
      rules = {},
      stream_rules = {},
      _compiled_http = {},
    }
    _evaluator_stub.evaluate_result = { action = "allow", matched_rule = "rule-api", decision_source = "rule" }
    handler.access()
    assert.are.equal("completed", ngx_mock.ctx.luagate.request_state)
  end)

  it("evaluate() allow 결과 → ngx.var.luagate_action = 'allow'", function()
    _evaluator_stub.get_policy_result = {
      global = { default_action = "deny" },
      rules = {},
      stream_rules = {},
      _compiled_http = {},
    }
    _evaluator_stub.evaluate_result = { action = "allow", matched_rule = nil, decision_source = "default" }
    handler.access()
    assert.are.equal("allow", ngx_mock.var.luagate_action)
  end)

  it("allow 후 ngx.exit()가 호출되지 않는다", function()
    _evaluator_stub.get_policy_result = {
      global = { default_action = "allow" },
      rules = {},
      stream_rules = {},
      _compiled_http = {},
    }
    _evaluator_stub.evaluate_result = { action = "allow", matched_rule = nil, decision_source = "default" }
    handler.access()
    -- exit가 호출되지 않아야 함
    assert.is_nil(ngx_mock._get_exited())
  end)

  it("access() 후 ngx.ctx에 policy 객체가 저장되지 않는다 (불변식)", function()
    local policy_obj = {
      global = { default_action = "allow" },
      rules = {},
      stream_rules = {},
      _compiled_http = {},
    }
    _evaluator_stub.get_policy_result = policy_obj
    _evaluator_stub.evaluate_result = { action = "allow", matched_rule = nil, decision_source = "default" }
    handler.access()
    -- ctx에 policy 테이블이 직접 저장되어서는 안 된다
    assert.is_nil(ngx_mock.ctx.luagate.policy)
    -- ctx 자체가 policy_obj와 동일하지 않음을 확인
    assert.are_not.equal(ngx_mock.ctx.luagate, policy_obj)
  end)

  it("luagate_decision_source = 'policy_engine' 설정된다", function()
    _evaluator_stub.get_policy_result = {
      global = { default_action = "allow" },
      rules = {},
      stream_rules = {},
      _compiled_http = {},
    }
    _evaluator_stub.evaluate_result = { action = "allow", matched_rule = nil, decision_source = "rule" }
    handler.access()
    assert.are.equal("policy_engine", ngx_mock.var.luagate_decision_source)
  end)
end)

describe("handler.access — deny path", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    handler.rewrite()
  end)

  it("evaluate() deny 결과 → 403 반환", function()
    _evaluator_stub.get_policy_result = {
      global = { default_action = "deny" },
      rules = {},
      stream_rules = {},
      _compiled_http = {},
    }
    _evaluator_stub.evaluate_result = { action = "deny", matched_rule = "rule-block", decision_source = "rule" }
    handler.access()
    assert.are.equal(403, ngx_mock.status)
    assert.are.equal(403, ngx_mock._get_exited())
  end)

  it("evaluate() deny 결과 → X-LuaGate-Block-Reason 헤더 설정", function()
    _evaluator_stub.get_policy_result = {
      global = { default_action = "deny" },
      rules = {},
      stream_rules = {},
      _compiled_http = {},
    }
    _evaluator_stub.evaluate_result = { action = "deny", matched_rule = "rule-block", decision_source = "rule" }
    handler.access()
    assert.are.equal("rule-block", ngx_mock.header["X-LuaGate-Block-Reason"])
  end)

  it("matched_rule이 nil인 deny → X-LuaGate-Block-Reason = 'default_deny'", function()
    _evaluator_stub.get_policy_result = {
      global = { default_action = "deny" },
      rules = {},
      stream_rules = {},
      _compiled_http = {},
    }
    _evaluator_stub.evaluate_result = { action = "deny", matched_rule = nil, decision_source = "default" }
    handler.access()
    assert.are.equal("default_deny", ngx_mock.header["X-LuaGate-Block-Reason"])
  end)

  it("deny 후 ctx.request_state = 'policy_denied'", function()
    _evaluator_stub.get_policy_result = {
      global = { default_action = "deny" },
      rules = {},
      stream_rules = {},
      _compiled_http = {},
    }
    _evaluator_stub.evaluate_result = { action = "deny", matched_rule = "rule-x", decision_source = "rule" }
    handler.access()
    assert.are.equal("policy_denied", ngx_mock.ctx.luagate.request_state)
  end)
end)

describe("handler.access — admin plane guard (server_port 9090)", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx({ var = { server_port = "9090" } })
    _G.ngx = ngx_mock
    handler.rewrite()
  end)

  it("server_port=9090이면 policy 평가 없이 즉시 return", function()
    -- get_policy가 호출되면 테스트 실패를 유도할 수 있도록 설정
    -- evaluator stub 재정의: get_policy가 호출되면 안 됨
    local get_policy_call_count = 0
    package.loaded["luagate.policy.evaluator"] = {
      get_policy = function()
        get_policy_call_count = get_policy_call_count + 1
        return nil
      end,
      evaluate = function()
        return { action = "allow", matched_rule = nil, decision_source = "default" }
      end,
    }
    handler.access()
    -- exit 호출 없음
    assert.is_nil(ngx_mock._get_exited())
    -- get_policy가 호출되지 않음 (admin guard에서 early return)
    assert.are.equal(0, get_policy_call_count)
    -- 모듈 캐시 복원
    package.loaded["luagate.policy.evaluator"] = nil
  end)
end)

describe("handler.access — ctx 없음 (rewrite 미실행) → fail-closed", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    -- rewrite 미실행 → ctx.luagate = nil
    ngx_mock.ctx = {}
  end)

  it("ctx 없으면 403 deny (fail-closed)", function()
    handler.access()
    assert.are.equal(403, ngx_mock.status)
    assert.are.equal(403, ngx_mock._get_exited())
  end)

  it("ctx 없으면 X-LuaGate-Block-Reason = 'no_context'", function()
    handler.access()
    assert.are.equal("no_context", ngx_mock.header["X-LuaGate-Block-Reason"])
  end)

  it("ctx 없으면 luagate_action = 'deny' 설정 (로그 정확성)", function()
    handler.access()
    assert.are.equal("deny", ngx_mock.var.luagate_action)
  end)

  it("ctx 없으면 luagate_request_state = 'policy_denied' 설정 (로그 정확성)", function()
    handler.access()
    assert.are.equal("policy_denied", ngx_mock.var.luagate_request_state)
  end)
end)

describe("handler.access — fail-closed: nginx var 업데이트 검증", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    handler.rewrite()
  end)

  it("get_policy() nil → luagate_action = 'deny' 설정", function()
    _evaluator_stub.get_policy_result = nil
    handler.access()
    assert.are.equal("deny", ngx_mock.var.luagate_action)
  end)

  it("get_policy() nil → luagate_request_state = 'policy_denied' 설정", function()
    _evaluator_stub.get_policy_result = nil
    handler.access()
    assert.are.equal("policy_denied", ngx_mock.var.luagate_request_state)
  end)

  it("get_policy() nil → ctx.action = 'deny' 설정", function()
    _evaluator_stub.get_policy_result = nil
    handler.access()
    assert.are.equal("deny", ngx_mock.ctx.luagate.action)
  end)

  it("get_policy() nil → ctx.request_state = 'policy_denied' 설정", function()
    _evaluator_stub.get_policy_result = nil
    handler.access()
    assert.are.equal("policy_denied", ngx_mock.ctx.luagate.request_state)
  end)
end)

describe("handler.access — X-LuaGate-Block-Reason IP 노출 제어", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    _evaluator_stub.get_policy_result = {
      global = { default_action = "deny" },
      rules = {},
      stream_rules = {},
      _compiled_http = {},
    }
    _evaluator_stub.evaluate_result = { action = "deny", matched_rule = "rule-block", decision_source = "rule" }
  end)

  it("내부 IP(10.x) 클라이언트에는 X-LuaGate-Block-Reason 헤더를 전송한다", function()
    ngx_mock = make_ngx({ var = { remote_addr = "10.1.2.3" } })
    _G.ngx = ngx_mock
    handler.rewrite()
    handler.access()
    assert.are.equal("rule-block", ngx_mock.header["X-LuaGate-Block-Reason"])
  end)

  it("내부 IP(192.168.x.x) 클라이언트에는 X-LuaGate-Block-Reason 헤더를 전송한다", function()
    ngx_mock = make_ngx({ var = { remote_addr = "192.168.1.100" } })
    _G.ngx = ngx_mock
    handler.rewrite()
    handler.access()
    assert.are.equal("rule-block", ngx_mock.header["X-LuaGate-Block-Reason"])
  end)

  it("내부 IP(172.16.x.x) 클라이언트에는 X-LuaGate-Block-Reason 헤더를 전송한다", function()
    ngx_mock = make_ngx({ var = { remote_addr = "172.16.0.1" } })
    _G.ngx = ngx_mock
    handler.rewrite()
    handler.access()
    assert.are.equal("rule-block", ngx_mock.header["X-LuaGate-Block-Reason"])
  end)

  it("루프백(127.x.x.x) 클라이언트에는 X-LuaGate-Block-Reason 헤더를 전송한다", function()
    ngx_mock = make_ngx({ var = { remote_addr = "127.0.0.1" } })
    _G.ngx = ngx_mock
    handler.rewrite()
    handler.access()
    assert.are.equal("rule-block", ngx_mock.header["X-LuaGate-Block-Reason"])
  end)

  it("외부 IP(203.0.113.1) 클라이언트에는 X-LuaGate-Block-Reason 헤더를 전송하지 않는다", function()
    ngx_mock = make_ngx({ var = { remote_addr = "203.0.113.1" } })
    _G.ngx = ngx_mock
    handler.rewrite()
    handler.access()
    assert.is_nil(ngx_mock.header["X-LuaGate-Block-Reason"])
  end)

  it("외부 IP(8.8.8.8) 클라이언트에는 X-LuaGate-Block-Reason 헤더를 전송하지 않는다", function()
    ngx_mock = make_ngx({ var = { remote_addr = "8.8.8.8" } })
    _G.ngx = ngx_mock
    handler.rewrite()
    handler.access()
    assert.is_nil(ngx_mock.header["X-LuaGate-Block-Reason"])
  end)

  it("remote_addr가 내부망이어도 luagate_src_ip가 외부 IP면 헤더를 전송하지 않는다", function()
    ngx_mock = make_ngx({
      var = {
        remote_addr = "10.0.0.10",
        luagate_src_ip = "203.0.113.10",
      },
    })
    _G.ngx = ngx_mock
    handler.rewrite()
    ngx_mock.var.luagate_src_ip = "203.0.113.10"
    handler.access()
    assert.is_nil(ngx_mock.header["X-LuaGate-Block-Reason"])
  end)

  it("172.32.x.x 는 외부 IP로 판정하여 헤더를 전송하지 않는다", function()
    ngx_mock = make_ngx({ var = { remote_addr = "172.32.0.1" } })
    _G.ngx = ngx_mock
    handler.rewrite()
    handler.access()
    assert.is_nil(ngx_mock.header["X-LuaGate-Block-Reason"])
  end)
end)

describe("handler.access — H-1: JSON body reason 외부 노출 방지", function()
  local ngx_mock
  local said_body

  before_each(function()
    reset_stubs()
    _evaluator_stub.get_policy_result = {
      global = { default_action = "deny" },
      rules = {},
      stream_rules = {},
      _compiled_http = {},
    }
    _evaluator_stub.evaluate_result = { action = "deny", matched_rule = "rule-secret-id", decision_source = "rule" }
    said_body = nil
  end)

  it("외부 IP(8.8.8.8) deny 시 JSON body.reason은 generic 'policy_deny'", function()
    ngx_mock = make_ngx({ var = { remote_addr = "8.8.8.8" } })
    ngx_mock.say = function(s)
      said_body = s
    end
    _G.ngx = ngx_mock
    handler.rewrite()
    handler.access()
    local dkjson = require("dkjson")
    local parsed = dkjson.decode(said_body)
    assert.is_table(parsed)
    assert.are.equal("policy_deny", parsed.reason)
  end)

  it("내부 IP(10.x) deny 시 JSON body.reason은 실제 rule id", function()
    ngx_mock = make_ngx({ var = { remote_addr = "10.1.2.3" } })
    ngx_mock.say = function(s)
      said_body = s
    end
    _G.ngx = ngx_mock
    handler.rewrite()
    handler.access()
    local dkjson = require("dkjson")
    local parsed = dkjson.decode(said_body)
    assert.is_table(parsed)
    assert.are.equal("rule-secret-id", parsed.reason)
  end)

  it(
    "remote_addr가 내부망이어도 luagate_src_ip가 외부 IP면 JSON body.reason은 generic 'policy_deny'",
    function()
      ngx_mock = make_ngx({
        var = {
          remote_addr = "10.1.2.3",
          luagate_src_ip = "198.51.100.7",
        },
      })
      ngx_mock.say = function(s)
        said_body = s
      end
      _G.ngx = ngx_mock
      handler.rewrite()
      ngx_mock.var.luagate_src_ip = "198.51.100.7"
      handler.access()
      local dkjson = require("dkjson")
      local parsed = dkjson.decode(said_body)
      assert.is_table(parsed)
      assert.are.equal("policy_deny", parsed.reason)
    end
  )
end)

describe("handler.access — M-1: get_policy() 예외 fail-closed", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    handler.rewrite()
  end)

  it("get_policy()에서 예외 발생 시 403 deny (fail-closed)", function()
    -- evaluator stub을 직접 교체하여 get_policy()가 예외를 발생시키도록 함
    package.loaded["luagate.policy.evaluator"] = {
      get_policy = function()
        error("simulated get_policy exception")
      end,
      evaluate = function()
        return { action = "allow", matched_rule = nil, decision_source = "default" }
      end,
    }
    handler.access()
    assert.are.equal(403, ngx_mock.status)
    assert.are.equal(403, ngx_mock._get_exited())
    -- 모듈 캐시 복원
    package.loaded["luagate.policy.evaluator"] = nil
  end)

  it("get_policy() 예외 시 deny_reason = 'policy_load_error'", function()
    package.loaded["luagate.policy.evaluator"] = {
      get_policy = function()
        error("simulated get_policy exception")
      end,
      evaluate = function()
        return { action = "allow", matched_rule = nil, decision_source = "default" }
      end,
    }
    handler.access()
    assert.are.equal("policy_load_error", ngx_mock.ctx.luagate.deny_reason)
    -- 모듈 캐시 복원
    package.loaded["luagate.policy.evaluator"] = nil
  end)

  it("get_policy() 예외 시 luagate_action = 'deny' 설정", function()
    package.loaded["luagate.policy.evaluator"] = {
      get_policy = function()
        error("simulated get_policy exception")
      end,
      evaluate = function()
        return { action = "allow", matched_rule = nil, decision_source = "default" }
      end,
    }
    handler.access()
    assert.are.equal("deny", ngx_mock.var.luagate_action)
    package.loaded["luagate.policy.evaluator"] = nil
  end)
end)

describe("handler.access — L-1: is_internal_ip IPv6 지원", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    _evaluator_stub.get_policy_result = {
      global = { default_action = "deny" },
      rules = {},
      stream_rules = {},
      _compiled_http = {},
    }
    _evaluator_stub.evaluate_result = { action = "deny", matched_rule = "rule-v6", decision_source = "rule" }
  end)

  it("IPv6 loopback(::1)은 내부 IP로 판정 → X-LuaGate-Block-Reason 헤더 전송", function()
    ngx_mock = make_ngx({ var = { remote_addr = "::1" } })
    _G.ngx = ngx_mock
    handler.rewrite()
    handler.access()
    assert.are.equal("rule-v6", ngx_mock.header["X-LuaGate-Block-Reason"])
  end)

  it("IPv4-mapped IPv6(::ffff:10.0.0.1)은 내부 IP로 판정 → 헤더 전송", function()
    ngx_mock = make_ngx({ var = { remote_addr = "::ffff:10.0.0.1" } })
    _G.ngx = ngx_mock
    handler.rewrite()
    handler.access()
    assert.are.equal("rule-v6", ngx_mock.header["X-LuaGate-Block-Reason"])
  end)

  it("순수 IPv6 외부 주소(2001:db8::1)는 외부 IP로 판정 → 헤더 미전송", function()
    ngx_mock = make_ngx({ var = { remote_addr = "2001:db8::1" } })
    _G.ngx = ngx_mock
    handler.rewrite()
    handler.access()
    assert.is_nil(ngx_mock.header["X-LuaGate-Block-Reason"])
  end)
end)

describe("handler.access — JSON 인젝션 방지", function()
  local ngx_mock
  local said_body

  before_each(function()
    reset_stubs()
    _evaluator_stub.get_policy_result = nil
    ngx_mock = make_ngx()
    said_body = nil
    ngx_mock.say = function(s)
      said_body = s
    end
    _G.ngx = ngx_mock
    handler.rewrite()
  end)

  it("request_id에 따옴표가 포함되어도 JSON 바디가 파싱 가능하다", function()
    ngx_mock.var.luagate_request_id = 'id-with-"quotes"'
    ngx_mock.ctx.luagate = nil
    ngx_mock.ctx = {}
    handler.access()
    -- said_body는 유효한 JSON이어야 한다
    local dkjson = require("dkjson")
    local parsed, _, err = dkjson.decode(said_body)
    assert.is_nil(err, "JSON parse error: " .. tostring(err))
    assert.is_table(parsed)
  end)

  it("request_id에 닫는 중괄호가 포함되어도 JSON 구조가 유지된다", function()
    -- deny 경로를 통해 cjson.encode 사용 여부를 검증
    ngx_mock.var.luagate_request_id = "id}malicious"
    ngx_mock.ctx.luagate = nil
    ngx_mock.ctx = {}
    handler.access()
    local dkjson = require("dkjson")
    local parsed, _, err = dkjson.decode(said_body)
    assert.is_nil(err, "JSON parse error: " .. tostring(err))
    assert.is_table(parsed)
    assert.are.equal("Forbidden", parsed.error)
  end)
end)

-- ===========================================================================
-- access() — scanner integration (DON-142) 테스트
-- ===========================================================================

describe("handler.access — scanner: threat 탐지 시 deny + 정책 평가 스킵", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    handler.rewrite()
    _evaluator_stub.get_policy_result = {
      global = { default_action = "allow" },
      rules = {},
      stream_rules = {},
      _compiled_http = {},
    }
    _evaluator_stub.evaluate_result = { action = "allow", matched_rule = nil, decision_source = "default" }
  end)

  it("scanner threat 탐지 → 403 deny", function()
    _scanner_stub.scan_result = {
      { threat_type = "sqli", rule_name = "sqli_union_select", threat_score = 0.95 },
      nil,
    }
    handler.access()
    assert.are.equal(403, ngx_mock.status)
    assert.are.equal(403, ngx_mock._get_exited())
  end)

  it("scanner threat 탐지 → decision_source = 'security_scanner'", function()
    _scanner_stub.scan_result = {
      { threat_type = "xss", rule_name = "xss_script_tag", threat_score = 0.9 },
      nil,
    }
    handler.access()
    assert.are.equal("security_scanner", ngx_mock.var.luagate_decision_source)
    assert.are.equal("security_scanner", ngx_mock.ctx.luagate.decision_source)
  end)

  it("scanner threat 탐지 → request_state = 'scanner_denied'", function()
    _scanner_stub.scan_result = {
      { threat_type = "sqli", rule_name = "sqli_tautology", threat_score = 0.85 },
      nil,
    }
    handler.access()
    assert.are.equal("scanner_denied", ngx_mock.var.luagate_request_state)
    assert.are.equal("scanner_denied", ngx_mock.ctx.luagate.request_state)
  end)

  it("scanner threat 탐지 → threat_type, rule_name, threat_score가 ctx + ngx.var에 설정", function()
    _scanner_stub.scan_result = {
      { threat_type = "path_traversal", rule_name = "path_dotdot", threat_score = 0.7 },
      nil,
    }
    handler.access()
    assert.are.equal("path_traversal", ngx_mock.ctx.luagate.threat_type)
    assert.are.equal("path_dotdot", ngx_mock.ctx.luagate.rule_name)
    assert.are.equal(0.7, ngx_mock.ctx.luagate.threat_score)
    assert.are.equal("path_traversal", ngx_mock.var.luagate_threat_type)
    assert.are.equal("path_dotdot", ngx_mock.var.luagate_rule_name)
    assert.are.equal("0.7", ngx_mock.var.luagate_threat_score)
  end)

  it("scanner threat 탐지 → deny_reason = 'scanner: <threat_type>'", function()
    _scanner_stub.scan_result = {
      { threat_type = "cmd_injection", rule_name = "cmd_semicolon", threat_score = 0.8 },
      nil,
    }
    handler.access()
    assert.are.equal("scanner: cmd_injection", ngx_mock.ctx.luagate.deny_reason)
    assert.are.equal("scanner: cmd_injection", ngx_mock.var.luagate_deny_reason)
  end)

  it("scanner threat 탐지 시 정책 평가가 스킵된다 (evaluate 호출 안 됨)", function()
    local evaluate_called = false
    package.loaded["luagate.policy.evaluator"] = {
      get_policy = function()
        return {
          global = { default_action = "allow" },
          rules = {},
          _compiled_http = {},
        }
      end,
      evaluate = function()
        evaluate_called = true
        return { action = "allow", matched_rule = nil, decision_source = "default" }
      end,
    }
    _scanner_stub.scan_result = {
      { threat_type = "sqli", rule_name = "sqli_union", threat_score = 0.9 },
      nil,
    }
    handler.access()
    assert.is_false(evaluate_called)
    package.loaded["luagate.policy.evaluator"] = nil
  end)
end)

describe("handler.access — scanner: no threat → 정책 평가 진행", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    handler.rewrite()
    _evaluator_stub.get_policy_result = {
      global = { default_action = "allow" },
      rules = {},
      stream_rules = {},
      _compiled_http = {},
    }
    _evaluator_stub.evaluate_result = { action = "allow", matched_rule = nil, decision_source = "default" }
  end)

  it("scanner no threat → 정책 평가 진행, allow", function()
    _scanner_stub.scan_result = {
      { threat_type = nil, rule_name = nil, threat_score = 0 },
      nil,
    }
    handler.access()
    assert.are.equal("allow", ngx_mock.ctx.luagate.action)
    assert.are.equal("completed", ngx_mock.ctx.luagate.request_state)
  end)

  it("scanner no threat + informational score → threat_score가 ctx에 기록", function()
    _scanner_stub.scan_result = {
      { threat_type = nil, rule_name = nil, threat_score = 0.15 },
      nil,
    }
    handler.access()
    assert.are.equal(0.15, ngx_mock.ctx.luagate.threat_score)
    assert.are.equal("0.15", ngx_mock.var.luagate_threat_score)
    assert.are.equal("allow", ngx_mock.ctx.luagate.action)
  end)

  it("scanner no threat + zero score → threat_score는 기본값 유지", function()
    _scanner_stub.scan_result = {
      { threat_type = nil, rule_name = nil, threat_score = 0 },
      nil,
    }
    handler.access()
    -- threat_score stays at default "null" from rewrite
    assert.are.equal("null", ngx_mock.var.luagate_threat_score)
  end)
end)

describe("handler.access — scanner: error → fail-closed", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    handler.rewrite()
    _evaluator_stub.get_policy_result = {
      global = { default_action = "allow" },
      rules = {},
      stream_rules = {},
      _compiled_http = {},
    }
  end)

  it("scanner error → 403 deny (fail-closed)", function()
    _scanner_stub.scan_result = { nil, "scanner_fail:-4" }
    handler.access()
    assert.are.equal(403, ngx_mock.status)
    assert.are.equal(403, ngx_mock._get_exited())
    assert.are.equal("scanner_denied", ngx_mock.var.luagate_request_state)
  end)

  it("scanner budget_exceeded → 403 deny", function()
    _scanner_stub.scan_result = { nil, "scanner_fail:-3" }
    handler.access()
    assert.are.equal(403, ngx_mock.status)
    assert.are.equal("security_scanner", ngx_mock.var.luagate_decision_source)
  end)

  it("scanner internal error → deny_reason = 'scanner_internal_error'", function()
    _scanner_stub.scan_result = { nil, "scanner_fail:-4" }
    handler.access()
    assert.are.equal("scanner_internal_error", ngx_mock.ctx.luagate.deny_reason)
    assert.are.equal("scanner_internal_error", ngx_mock.var.luagate_deny_reason)
  end)

  it("scanner budget_exceeded → deny_reason = 'budget_exceeded'", function()
    _scanner_stub.scan_result = { nil, "scanner_fail:-3" }
    handler.access()
    assert.are.equal("budget_exceeded", ngx_mock.ctx.luagate.deny_reason)
    assert.are.equal("budget_exceeded", ngx_mock.var.luagate_deny_reason)
  end)

  it("scanner error → ngx.var.threat_type = 'scanner_error' but ctx.threat_type is nil", function()
    _scanner_stub.scan_result = { nil, "scanner_fail:-4" }
    handler.access()
    -- ctx.threat_type NOT set for operational failures (ADR-006 metric purity)
    assert.is_nil(ngx_mock.ctx.luagate.threat_type)
    -- ngx.var IS set for log distinguishability
    assert.are.equal("scanner_error", ngx_mock.var.luagate_threat_type)
  end)

  it("scanner exception → 403 deny with 'scanner_internal_error'", function()
    package.loaded["luagate.scanner.ffi"] = {
      scan = function()
        error("simulated scanner exception")
      end,
    }
    handler.access()
    assert.are.equal(403, ngx_mock.status)
    assert.are.equal(403, ngx_mock._get_exited())
    assert.are.equal("scanner_internal_error", ngx_mock.ctx.luagate.deny_reason)
    assert.are.equal("scanner_internal_error", ngx_mock.var.luagate_deny_reason)
    assert.are.equal("scanner_error", ngx_mock.var.luagate_threat_type)
    package.loaded["luagate.scanner.ffi"] = _scanner_stub_module
  end)
end)

describe("handler.access — decoder error (from rewrite) → fail-closed", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    _evaluator_stub.get_policy_result = {
      global = { default_action = "allow" },
      rules = {},
      stream_rules = {},
      _compiled_http = {},
    }
  end)

  it("ctx.decoder_error set → 403 deny (fail-closed)", function()
    handler.rewrite()
    ngx_mock.ctx.luagate.decoder_error = "ffi_fail:-3"
    handler.access()
    assert.are.equal(403, ngx_mock.status)
    assert.are.equal(403, ngx_mock._get_exited())
    assert.are.equal("scanner_denied", ngx_mock.var.luagate_request_state)
  end)

  it("ctx.decoder_error set → deny_reason = decoder error string", function()
    handler.rewrite()
    ngx_mock.ctx.luagate.decoder_error = "ffi_fail:-3"
    handler.access()
    assert.are.equal("ffi_fail:-3", ngx_mock.ctx.luagate.deny_reason)
    assert.are.equal("ffi_fail:-3", ngx_mock.var.luagate_deny_reason)
  end)

  it("ctx.decoder_error → ngx.var.threat_type = 'decode_error' but ctx.threat_type is nil", function()
    handler.rewrite()
    ngx_mock.ctx.luagate.decoder_error = "ffi_fail:-3"
    handler.access()
    -- ctx.threat_type NOT set for operational failures (ADR-006 metric purity)
    assert.is_nil(ngx_mock.ctx.luagate.threat_type)
    -- ngx.var IS set for log distinguishability
    assert.are.equal("decode_error", ngx_mock.var.luagate_threat_type)
  end)

  it("decoder_load_error from rewrite → fail-closed in access with decode_error in var", function()
    package.loaded["luagate.decoder.ffi"] = nil
    local saved_preload = package.preload["luagate.decoder.ffi"]
    package.preload["luagate.decoder.ffi"] = function()
      error("simulated decoder load failure")
    end
    handler.rewrite()
    package.preload["luagate.decoder.ffi"] = saved_preload
    package.loaded["luagate.decoder.ffi"] = _decoder_stub_module
    handler.access()
    assert.are.equal(403, ngx_mock.status)
    assert.is_nil(ngx_mock.ctx.luagate.threat_type)
    assert.are.equal("decode_error", ngx_mock.var.luagate_threat_type)
    assert.are.equal("decoder_load_error", ngx_mock.ctx.luagate.deny_reason)
  end)

  it("decoder path exception from rewrite → access에서 403 fail-closed", function()
    package.loaded["luagate.decoder.ffi"] = {
      normalize_path = function()
        error("simulated decoder path exception")
      end,
      normalize_query = function(query_raw)
        return query_raw, nil, false
      end,
    }
    handler.rewrite()
    package.loaded["luagate.decoder.ffi"] = _decoder_stub_module
    handler.access()
    assert.are.equal(403, ngx_mock.status)
    assert.are.equal(403, ngx_mock._get_exited())
    assert.are.equal("decoder_path_exception", ngx_mock.ctx.luagate.deny_reason)
    assert.are.equal("decode_error", ngx_mock.var.luagate_threat_type)
  end)

  it("decoder partial decode → no decoder_error → 스캔 + 정책 평가 계속", function()
    _decoder_stub.normalize_path_result = { "/partial/path", nil, true }
    handler.rewrite()
    handler.access()
    -- partial decode는 에러가 아님 → 스캔 + 정책 평가 계속
    assert.are.equal("/partial/path", ngx_mock.ctx.luagate.path_normalized)
    assert.are.equal("completed", ngx_mock.ctx.luagate.request_state)
  end)
end)

describe("handler.access — input size limit (8KB)", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
  end)

  it("path > 8KB → 403 deny (fail-closed)", function()
    ngx_mock.var.request_uri = "/" .. string.rep("a", 8193)
    handler.rewrite()
    _evaluator_stub.get_policy_result = {
      global = { default_action = "allow" },
      rules = {},
      _compiled_http = {},
    }
    handler.access()
    assert.are.equal(403, ngx_mock.status)
    assert.are.equal("input_size_exceeded", ngx_mock.ctx.luagate.deny_reason)
    assert.are.equal("security_scanner", ngx_mock.var.luagate_decision_source)
    assert.is_nil(ngx_mock.ctx.luagate.threat_type)
    assert.are.equal("scanner_error", ngx_mock.var.luagate_threat_type)
  end)

  it("query > 8KB → 403 deny (fail-closed)", function()
    ngx_mock.var.args = string.rep("x", 8193)
    handler.rewrite()
    _evaluator_stub.get_policy_result = {
      global = { default_action = "allow" },
      rules = {},
      _compiled_http = {},
    }
    handler.access()
    assert.are.equal(403, ngx_mock.status)
    assert.are.equal("input_size_exceeded", ngx_mock.ctx.luagate.deny_reason)
    assert.is_nil(ngx_mock.ctx.luagate.threat_type)
    assert.are.equal("scanner_error", ngx_mock.var.luagate_threat_type)
  end)

  it("path + query 각각 8KB 이하 → 정상 진행", function()
    ngx_mock.var.request_uri = "/" .. string.rep("a", 100)
    ngx_mock.var.args = string.rep("b", 100)
    handler.rewrite()
    _evaluator_stub.get_policy_result = {
      global = { default_action = "allow" },
      rules = {},
      _compiled_http = {},
    }
    _evaluator_stub.evaluate_result = { action = "allow", matched_rule = nil, decision_source = "default" }
    handler.access()
    assert.are.equal("completed", ngx_mock.ctx.luagate.request_state)
  end)
end)

describe("handler.access — scanner load error → fail-closed with threat_type", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    handler.rewrite()
    _evaluator_stub.get_policy_result = {
      global = { default_action = "allow" },
      rules = {},
      _compiled_http = {},
    }
  end)

  it("scanner load failure → 403 deny with threat_type = 'scanner_error'", function()
    -- Force scanner load to fail by making preload raise an error
    package.loaded["luagate.scanner.ffi"] = nil
    local saved_preload = package.preload["luagate.scanner.ffi"]
    package.preload["luagate.scanner.ffi"] = function()
      error("simulated scanner load failure")
    end
    handler.access()
    assert.are.equal(403, ngx_mock.status)
    assert.is_nil(ngx_mock.ctx.luagate.threat_type)
    assert.are.equal("scanner_error", ngx_mock.var.luagate_threat_type)
    assert.are.equal("scanner_load_error", ngx_mock.ctx.luagate.deny_reason)
    -- Restore
    package.preload["luagate.scanner.ffi"] = saved_preload
    package.loaded["luagate.scanner.ffi"] = _scanner_stub_module
  end)
end)

describe("handler.access — admin plane: scanner 제외 확인", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx({ var = { server_port = "9090" } })
    _G.ngx = ngx_mock
    handler.rewrite()
  end)

  it("server_port=9090 → scanner 호출 없이 return", function()
    local scanner_called = false
    package.loaded["luagate.scanner.ffi"] = {
      scan = function()
        scanner_called = true
        return { threat_type = nil, rule_name = nil, threat_score = 0 }, nil
      end,
    }
    handler.access()
    assert.is_false(scanner_called)
    package.loaded["luagate.scanner.ffi"] = nil
  end)
end)

describe("handler.access — rewrite decoder → access scanner 순서 보장", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    _evaluator_stub.get_policy_result = {
      global = { default_action = "allow" },
      rules = {},
      stream_rules = {},
      _compiled_http = {},
    }
    _evaluator_stub.evaluate_result = { action = "allow", matched_rule = nil, decision_source = "default" }
  end)

  it("rewrite decoder 결과가 access scanner에 전달된다 (path_normalized)", function()
    local scanner_received_ctx = nil
    _decoder_stub.normalize_path_result = { "/decoded/path", nil, false }
    _decoder_stub.normalize_query_result = { "decoded=query", nil, false }
    -- rewrite phase: decoder runs, sets ctx.path_normalized/query_normalized
    handler.rewrite()
    package.loaded["luagate.scanner.ffi"] = {
      scan = function(ctx)
        scanner_received_ctx = ctx
        return { threat_type = nil, rule_name = nil, threat_score = 0 }, nil
      end,
    }
    -- access phase: scanner reads from ctx
    handler.access()
    assert.is_not_nil(scanner_received_ctx)
    assert.are.equal("/decoded/path", scanner_received_ctx.path_normalized)
    assert.are.equal("decoded=query", scanner_received_ctx.query_normalized)
    package.loaded["luagate.scanner.ffi"] = nil
  end)
end)

-- ===========================================================================
-- log_phase() 테스트
-- ===========================================================================

describe("handler.log_phase — request_state 최종화", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
  end)

  it("allow + status 200 → request_state = 'allowed'", function()
    ngx_mock.ctx.luagate = { request_state = "completed", action = "allow" }
    ngx_mock.var.status = "200"
    handler.log_phase()
    assert.are.equal("allowed", ngx_mock.ctx.luagate.request_state)
    assert.are.equal("allowed", ngx_mock.var.luagate_request_state)
  end)

  it("allow + status 500 → request_state = 'upstream_error'", function()
    ngx_mock.ctx.luagate = { request_state = "completed", action = "allow" }
    ngx_mock.var.status = "500"
    handler.log_phase()
    assert.are.equal("upstream_error", ngx_mock.ctx.luagate.request_state)
    assert.are.equal("upstream_error", ngx_mock.var.luagate_request_state)
  end)

  it("allow + status 502 → request_state = 'upstream_error'", function()
    ngx_mock.ctx.luagate = { request_state = "completed", action = "allow" }
    ngx_mock.var.status = "502"
    handler.log_phase()
    assert.are.equal("upstream_error", ngx_mock.ctx.luagate.request_state)
  end)

  it("ctx 없음(nil) → short_circuited 유지 (ctx 오류 없이 처리)", function()
    ngx_mock.ctx = {} -- luagate 없음
    ngx_mock.var.luagate_request_state = "short_circuited"
    -- 에러 없이 통과해야 한다
    assert.has_no.errors(function()
      handler.log_phase()
    end)
    -- ctx가 nil이면 ngx.var.luagate_request_state는 변경되지 않는다
    assert.are.equal("short_circuited", ngx_mock.var.luagate_request_state)
  end)

  it("policy_denied 상태는 log_phase에서 변경되지 않는다", function()
    ngx_mock.ctx.luagate = { request_state = "policy_denied", action = "deny" }
    ngx_mock.var.status = "403"
    handler.log_phase()
    -- policy_denied는 "completed"가 아니므로 upstream_error 체크를 건너뜀
    assert.are.equal("policy_denied", ngx_mock.ctx.luagate.request_state)
  end)
end)

describe("handler.log_phase — metrics.collector.record 호출", function()
  local ngx_mock

  before_each(function()
    reset_stubs()
    ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    -- 모듈 캐시 초기화하여 stub이 다시 로드되도록 함
    package.loaded["luagate.log.http"] = nil
    package.loaded["luagate.metrics.collector"] = nil
  end)

  after_each(function()
    package.loaded["luagate.log.http"] = nil
    package.loaded["luagate.metrics.collector"] = nil
  end)

  it("log_phase()는 에러 없이 완료된다", function()
    ngx_mock.ctx.luagate = { request_state = "completed", action = "allow" }
    ngx_mock.var.status = "200"
    assert.has_no.errors(function()
      handler.log_phase()
    end)
  end)

  it("log_phase()는 log/http 모듈 오류가 있어도 크래시하지 않는다 (pcall)", function()
    -- log/http stub이 에러를 발생시키도록 override
    package.loaded["luagate.log.http"] = {
      finalize = function()
        error("log error test")
      end,
    }
    ngx_mock.ctx.luagate = { request_state = "completed", action = "allow" }
    ngx_mock.var.status = "200"
    -- pcall로 감싸져 있으므로 에러가 전파되지 않아야 한다
    assert.has_no.errors(function()
      handler.log_phase()
    end)
  end)

  it("log_phase()는 metrics.collector 모듈 오류가 있어도 크래시하지 않는다 (pcall)", function()
    -- metrics.collector stub이 에러를 발생시키도록 override
    package.loaded["luagate.metrics.collector"] = {
      record = function(_ctx)
        error("metrics error test")
      end,
    }
    ngx_mock.ctx.luagate = { request_state = "completed", action = "allow" }
    ngx_mock.var.status = "200"
    assert.has_no.errors(function()
      handler.log_phase()
    end)
  end)
end)
