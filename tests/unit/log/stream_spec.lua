--- Unit tests for lua/luagate/log/stream.lua
-- Implementation: lua/luagate/log/stream.lua
-- Tests: tests/unit/log/stream_spec.lua
--
-- log/stream.lua는 ngx 전역과 cjson에 의존하므로 두 가지를 mock한다.
-- cjson.safe는 LuaJIT 전용이므로 dkjson을 사용하는 stub으로 교체한다.

-- ---------------------------------------------------------------------------
-- cjson.safe stub (dkjson wrapper)
-- ---------------------------------------------------------------------------
local dkjson = require("dkjson")
local _cjson_encode_error = nil -- nil이면 정상, 문자열이면 encode에서 에러 반환

local cjson_safe_stub = {
  null = dkjson.null,
  encode_empty_table_as_array = function() end,
  encode = function(v)
    if _cjson_encode_error then
      return nil, _cjson_encode_error
    end
    return dkjson.encode(v), nil
  end,
  decode = function(s)
    return dkjson.decode(s)
  end,
}

package.preload["cjson.safe"] = function()
  return cjson_safe_stub
end

-- ---------------------------------------------------------------------------
-- ngx mock 팩토리
-- ---------------------------------------------------------------------------
local function make_ngx(overrides)
  local logged = {}
  local mock = {
    var = {
      luagate_conn_id = "sw0-42-1710633600000",
      luagate_protocol = "tls",
      luagate_sni = "api.example.com",
      luagate_stream_action = "proxy",
      luagate_matched_rule = "allow-tls-api",
      luagate_decision_source = "policy_engine",
      luagate_active_version = "v2025-stream",
      luagate_upstream = "backend:8443",
      luagate_request_state = "proxied",
      luagate_worker_id = "1",
      luagate_stream_log_json = "",
      time_iso8601 = "2026-03-17T00:00:00+00:00",
      remote_addr = "10.0.1.5",
      remote_port = "12345",
      server_port = "8443",
      session_time = "15.234",
      bytes_sent = "2048",
      upstream_bytes_received = "8192",
      upstream_connect_time = "0.0012",
    },
    ctx = {
      luagate_stream = {
        connection_id = "sw0-42-1710633600000",
        src_ip = "10.0.1.5",
        src_port = 12345,
        dst_port = 8443,
        detected_protocol = "tls",
        sni = "api.example.com",
        action = "proxy",
        matched_rule_id = "allow-tls-api",
        decision_source = "policy_engine",
        active_version = "v2025-stream",
        upstream = "backend:8443",
        request_state = "proxied",
        worker_id = 1,
      },
    },
    WARN = 5,
    ERR = 4,
    log = function(_, ...)
      local parts = { ... }
      logged[#logged + 1] = table.concat(parts, "")
    end,
    now = function()
      return 1710633600.0
    end,
    worker = {
      id = function()
        return 1
      end,
    },
  }
  mock._get_logged = function()
    return logged
  end

  if overrides then
    for k, v in pairs(overrides) do
      if type(v) == "table" and type(mock[k]) == "table" and k ~= "ctx" then
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
-- 모듈 캐시 초기화
-- ---------------------------------------------------------------------------
local function load_log_stream()
  package.loaded["luagate.log.stream"] = nil
  package.preload["luagate.log.stream"] = nil
  return require("luagate.log.stream")
end

-- ===========================================================================
-- 18 필드 완전성 검증
-- ===========================================================================

describe("log/stream.finalize — 18필드 완전성", function()
  local EXPECTED_FIELDS = {
    "timestamp",
    "connection_id",
    "src_ip",
    "src_port",
    "dst_port",
    "detected_protocol",
    "sni",
    "action",
    "matched_rule_id",
    "decision_source",
    "active_version",
    "upstream",
    "session_duration_ms",
    "bytes_sent",
    "bytes_received",
    "upstream_connect_time_ms",
    "request_state",
    "worker_id",
  }

  it("finalize() 후 luagate_stream_log_json이 18개 필드를 모두 포함한다", function()
    local ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    local log_stream = load_log_stream()

    log_stream.finalize()

    local json_str = ngx_mock.var.luagate_stream_log_json
    assert.is_string(json_str)
    assert.is_true(#json_str > 0)

    local record = dkjson.decode(json_str)
    assert.is_table(record)

    for _, field in ipairs(EXPECTED_FIELDS) do
      local has_field = (record[field] ~= nil) or json_str:find('"' .. field .. '"', 1, true) ~= nil
      assert.is_true(has_field, "필드 누락: " .. field)
    end
  end)

  it("전체 18개 필드 수 검증", function()
    local ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    local log_stream = load_log_stream()

    log_stream.finalize()

    local json_str = ngx_mock.var.luagate_stream_log_json
    assert.is_string(json_str)

    local count = 0
    for _ in json_str:gmatch('"[^"]+":') do
      count = count + 1
    end
    assert.is_true(count >= 18, "필드 수 부족: " .. count .. " (최소 18개 필요)")
  end)
end)

-- ===========================================================================
-- Nullable 필드 처리
-- ===========================================================================

describe("log/stream.finalize — nullable 필드 처리", function()
  it("sni=nil → JSON null", function()
    local ngx_mock = make_ngx()
    ngx_mock.ctx.luagate_stream.sni = nil
    _G.ngx = ngx_mock
    local log_stream = load_log_stream()

    log_stream.finalize()

    local json_str = ngx_mock.var.luagate_stream_log_json
    assert.is_truthy(json_str:find('"sni":null', 1, true))
  end)

  it("matched_rule_id=nil → JSON null", function()
    local ngx_mock = make_ngx()
    ngx_mock.ctx.luagate_stream.matched_rule_id = nil
    ngx_mock.var.luagate_matched_rule = ""
    _G.ngx = ngx_mock
    local log_stream = load_log_stream()

    log_stream.finalize()

    local json_str = ngx_mock.var.luagate_stream_log_json
    assert.is_truthy(json_str:find('"matched_rule_id":null', 1, true))
  end)

  it("upstream=nil (deny) → JSON null", function()
    local ngx_mock = make_ngx()
    ngx_mock.ctx.luagate_stream.upstream = nil
    ngx_mock.ctx.luagate_stream.action = "deny"
    _G.ngx = ngx_mock
    local log_stream = load_log_stream()

    log_stream.finalize()

    local json_str = ngx_mock.var.luagate_stream_log_json
    assert.is_truthy(json_str:find('"upstream":null', 1, true))
  end)

  it("upstream_connect_time = '-' → upstream_connect_time_ms는 JSON null", function()
    local ngx_mock = make_ngx()
    ngx_mock.var.upstream_connect_time = "-"
    _G.ngx = ngx_mock
    local log_stream = load_log_stream()

    log_stream.finalize()

    local json_str = ngx_mock.var.luagate_stream_log_json
    assert.is_truthy(json_str:find('"upstream_connect_time_ms":null', 1, true))
  end)

  it("upstream_connect_time = nil → upstream_connect_time_ms는 JSON null", function()
    local ngx_mock = make_ngx()
    ngx_mock.var.upstream_connect_time = nil
    _G.ngx = ngx_mock
    local log_stream = load_log_stream()

    log_stream.finalize()

    local json_str = ngx_mock.var.luagate_stream_log_json
    assert.is_truthy(json_str:find('"upstream_connect_time_ms":null', 1, true))
  end)

  it("upstream_connect_time = '' → upstream_connect_time_ms는 JSON null", function()
    local ngx_mock = make_ngx()
    ngx_mock.var.upstream_connect_time = ""
    _G.ngx = ngx_mock
    local log_stream = load_log_stream()

    log_stream.finalize()

    local json_str = ngx_mock.var.luagate_stream_log_json
    assert.is_truthy(json_str:find('"upstream_connect_time_ms":null', 1, true))
  end)
end)

-- ===========================================================================
-- session_duration_ms 계산
-- ===========================================================================

describe("log/stream.finalize — session_duration_ms 계산", function()
  it("session_time = '15.234' → session_duration_ms = 15234.0", function()
    local ngx_mock = make_ngx()
    ngx_mock.var.session_time = "15.234"
    _G.ngx = ngx_mock
    local log_stream = load_log_stream()

    log_stream.finalize()

    local json_str = ngx_mock.var.luagate_stream_log_json
    local record = dkjson.decode(json_str)
    assert.are.equal(15234.0, record.session_duration_ms)
  end)

  it("session_time = nil → session_duration_ms = 0", function()
    local ngx_mock = make_ngx()
    ngx_mock.var.session_time = nil
    _G.ngx = ngx_mock
    local log_stream = load_log_stream()

    log_stream.finalize()

    local json_str = ngx_mock.var.luagate_stream_log_json
    local record = dkjson.decode(json_str)
    assert.are.equal(0, record.session_duration_ms)
  end)

  it("session_time = '0.001' → session_duration_ms = 1.0", function()
    local ngx_mock = make_ngx()
    ngx_mock.var.session_time = "0.001"
    _G.ngx = ngx_mock
    local log_stream = load_log_stream()

    log_stream.finalize()

    local json_str = ngx_mock.var.luagate_stream_log_json
    local record = dkjson.decode(json_str)
    assert.are.equal(1.0, record.session_duration_ms)
  end)
end)

-- ===========================================================================
-- upstream_connect_time_ms 변환
-- ===========================================================================

describe("log/stream.finalize — upstream_connect_time_ms 변환", function()
  it("upstream_connect_time = '0.0012' → upstream_connect_time_ms = 1.2", function()
    local ngx_mock = make_ngx()
    ngx_mock.var.upstream_connect_time = "0.0012"
    _G.ngx = ngx_mock
    local log_stream = load_log_stream()

    log_stream.finalize()

    local json_str = ngx_mock.var.luagate_stream_log_json
    local record = dkjson.decode(json_str)
    assert.are.equal(1.2, record.upstream_connect_time_ms)
  end)
end)

-- ===========================================================================
-- ctx 없음 처리
-- ===========================================================================

describe("log/stream.finalize — ctx 없음", function()
  it("ngx.ctx.luagate_stream이 nil이어도 에러 없이 처리된다", function()
    local ngx_mock = make_ngx()
    ngx_mock.ctx = {} -- luagate_stream 없음
    _G.ngx = ngx_mock
    local log_stream = load_log_stream()

    assert.has_no.errors(function()
      log_stream.finalize()
    end)
  end)

  it("ctx 없을 때도 luagate_stream_log_json이 유효한 JSON 문자열로 설정된다", function()
    local ngx_mock = make_ngx()
    ngx_mock.ctx = {}
    _G.ngx = ngx_mock
    local log_stream = load_log_stream()

    log_stream.finalize()

    local json_str = ngx_mock.var.luagate_stream_log_json
    assert.is_string(json_str)
    local parsed = dkjson.decode(json_str)
    assert.is_table(parsed)
  end)
end)

-- ===========================================================================
-- cjson.encode 실패 fallback
-- ===========================================================================

describe("log/stream.finalize — cjson.encode 실패 fallback", function()
  it('encode 실패 시 luagate_stream_log_json = \'{"error":"stream_log_encode_failed"}\'', function()
    _cjson_encode_error = "simulated encode error"

    local ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    package.loaded["luagate.log.stream"] = nil
    local log_stream = require("luagate.log.stream")

    log_stream.finalize()

    _cjson_encode_error = nil

    assert.are.equal('{"error":"stream_log_encode_failed"}', ngx_mock.var.luagate_stream_log_json)
  end)
end)

-- ===========================================================================
-- proxy 시나리오 전체 검증
-- ===========================================================================

describe("log/stream.finalize — proxy 시나리오", function()
  it("proxy 연결의 모든 필드가 올바르게 설정된다", function()
    local ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    local log_stream = load_log_stream()

    log_stream.finalize()

    local json_str = ngx_mock.var.luagate_stream_log_json
    local record = dkjson.decode(json_str)

    assert.are.equal("2026-03-17T00:00:00+00:00", record.timestamp)
    assert.are.equal("sw0-42-1710633600000", record.connection_id)
    assert.are.equal("10.0.1.5", record.src_ip)
    assert.are.equal(12345, record.src_port)
    assert.are.equal(8443, record.dst_port)
    assert.are.equal("tls", record.detected_protocol)
    assert.are.equal("api.example.com", record.sni)
    assert.are.equal("proxy", record.action)
    assert.are.equal("allow-tls-api", record.matched_rule_id)
    assert.are.equal("policy_engine", record.decision_source)
    assert.are.equal("v2025-stream", record.active_version)
    assert.are.equal("backend:8443", record.upstream)
    assert.are.equal(2048, record.bytes_sent)
    assert.are.equal(8192, record.bytes_received)
    assert.are.equal("proxied", record.request_state)
    assert.are.equal(1, record.worker_id)
  end)
end)

-- ===========================================================================
-- deny 시나리오 전체 검증
-- ===========================================================================

describe("log/stream.finalize — deny 시나리오", function()
  it("deny 연결의 nullable 필드가 null이다", function()
    local ngx_mock = make_ngx()
    ngx_mock.ctx.luagate_stream = {
      connection_id = "sw0-99-1710633601000",
      src_ip = "198.51.100.5",
      src_port = 61111,
      dst_port = 2222,
      detected_protocol = "raw",
      sni = nil,
      action = "deny",
      matched_rule_id = "block-raw",
      decision_source = "policy_engine",
      active_version = "v2025-stream",
      upstream = nil,
      request_state = "denied",
      worker_id = 0,
    }
    ngx_mock.var.session_time = "0.0005"
    ngx_mock.var.bytes_sent = "0"
    ngx_mock.var.upstream_bytes_received = "0"
    ngx_mock.var.upstream_connect_time = "-"
    _G.ngx = ngx_mock
    local log_stream = load_log_stream()

    log_stream.finalize()

    local json_str = ngx_mock.var.luagate_stream_log_json
    local record = dkjson.decode(json_str)

    assert.are.equal("deny", record.action)
    assert.are.equal("denied", record.request_state)
    assert.is_truthy(json_str:find('"sni":null', 1, true))
    assert.is_truthy(json_str:find('"upstream":null', 1, true))
    assert.is_truthy(json_str:find('"upstream_connect_time_ms":null', 1, true))
    assert.are.equal(0, record.bytes_sent)
    assert.are.equal(0, record.bytes_received)
  end)
end)
