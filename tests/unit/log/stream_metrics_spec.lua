--- Unit tests for lua/luagate/log/stream_metrics.lua
-- Implementation: lua/luagate/log/stream_metrics.lua
-- Tests: tests/unit/log/stream_metrics_spec.lua

-- ---------------------------------------------------------------------------
-- shared dict mock
-- ---------------------------------------------------------------------------
local function make_shared_dict()
  local data = {}
  return {
    incr = function(_, key, value, init)
      if data[key] == nil then
        data[key] = init or 0
      end
      data[key] = data[key] + value
      return data[key], nil
    end,
    get = function(_, key)
      return data[key]
    end,
    _data = data,
  }
end

-- ---------------------------------------------------------------------------
-- ngx mock 팩토리
-- ---------------------------------------------------------------------------
local function make_ngx(overrides)
  local logged = {}
  local stream_metrics_dict = make_shared_dict()

  local mock = {
    var = {
      luagate_stream_action = "proxy",
      luagate_protocol = "tls",
      bytes_sent = "2048",
      upstream_bytes_received = "8192",
    },
    ctx = {
      luagate_stream = {
        action = "proxy",
        detected_protocol = "tls",
      },
    },
    shared = {
      luagate_stream_metrics = stream_metrics_dict,
    },
    WARN = 5,
    ERR = 4,
    log = function(_, ...)
      local parts = { ... }
      logged[#logged + 1] = table.concat(parts, "")
    end,
    worker = {
      id = function()
        return 0
      end,
    },
  }
  mock._get_logged = function()
    return logged
  end
  mock._get_stream_metrics = function()
    return stream_metrics_dict._data
  end

  if overrides then
    for k, v in pairs(overrides) do
      if type(v) == "table" and type(mock[k]) == "table" and k ~= "ctx" and k ~= "shared" then
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
local function load_stream_metrics()
  package.loaded["luagate.log.stream_metrics"] = nil
  package.preload["luagate.log.stream_metrics"] = nil
  return require("luagate.log.stream_metrics")
end

-- ===========================================================================
-- proxy 시나리오 메트릭
-- ===========================================================================

describe("log/stream_metrics.collect — proxy 시나리오", function()
  it("connections_total이 1 증가한다", function()
    local ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    local metrics = load_stream_metrics()

    metrics.collect()

    local data = ngx_mock._get_stream_metrics()
    assert.are.equal(1, data["stream:metrics:connections_total"])
  end)

  it("connections_denied_total은 증가하지 않는다", function()
    local ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    local metrics = load_stream_metrics()

    metrics.collect()

    local data = ngx_mock._get_stream_metrics()
    assert.is_nil(data["stream:metrics:connections_denied_total"])
  end)

  it("bytes_sent_total이 bytes_sent만큼 증가한다", function()
    local ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    local metrics = load_stream_metrics()

    metrics.collect()

    local data = ngx_mock._get_stream_metrics()
    assert.are.equal(2048, data["stream:metrics:bytes_sent_total"])
  end)

  it("bytes_received_total이 upstream_bytes_received만큼 증가한다", function()
    local ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    local metrics = load_stream_metrics()

    metrics.collect()

    local data = ngx_mock._get_stream_metrics()
    assert.are.equal(8192, data["stream:metrics:bytes_received_total"])
  end)

  it("프로토콜별 카운터가 증가한다 (tls)", function()
    local ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    local metrics = load_stream_metrics()

    metrics.collect()

    local data = ngx_mock._get_stream_metrics()
    assert.are.equal(1, data["stream:metrics:protocol_detected_total:tls"])
  end)
end)

-- ===========================================================================
-- deny 시나리오 메트릭
-- ===========================================================================

describe("log/stream_metrics.collect — deny 시나리오", function()
  it("connections_denied_total이 1 증가한다", function()
    local ngx_mock = make_ngx()
    ngx_mock.ctx.luagate_stream.action = "deny"
    _G.ngx = ngx_mock
    local metrics = load_stream_metrics()

    metrics.collect()

    local data = ngx_mock._get_stream_metrics()
    assert.are.equal(1, data["stream:metrics:connections_denied_total"])
  end)

  it("connections_total도 1 증가한다", function()
    local ngx_mock = make_ngx()
    ngx_mock.ctx.luagate_stream.action = "deny"
    _G.ngx = ngx_mock
    local metrics = load_stream_metrics()

    metrics.collect()

    local data = ngx_mock._get_stream_metrics()
    assert.are.equal(1, data["stream:metrics:connections_total"])
  end)

  it("deny 시 bytes_sent_total은 증가하지 않는다", function()
    local ngx_mock = make_ngx()
    ngx_mock.ctx.luagate_stream.action = "deny"
    _G.ngx = ngx_mock
    local metrics = load_stream_metrics()

    metrics.collect()

    local data = ngx_mock._get_stream_metrics()
    assert.is_nil(data["stream:metrics:bytes_sent_total"])
  end)

  it("deny 시 bytes_received_total은 증가하지 않는다", function()
    local ngx_mock = make_ngx()
    ngx_mock.ctx.luagate_stream.action = "deny"
    _G.ngx = ngx_mock
    local metrics = load_stream_metrics()

    metrics.collect()

    local data = ngx_mock._get_stream_metrics()
    assert.is_nil(data["stream:metrics:bytes_received_total"])
  end)
end)

-- ===========================================================================
-- 프로토콜별 카운터
-- ===========================================================================

describe("log/stream_metrics.collect — 프로토콜별 카운터", function()
  it("http 프로토콜 카운터 증가", function()
    local ngx_mock = make_ngx()
    ngx_mock.ctx.luagate_stream.detected_protocol = "http"
    _G.ngx = ngx_mock
    local metrics = load_stream_metrics()

    metrics.collect()

    local data = ngx_mock._get_stream_metrics()
    assert.are.equal(1, data["stream:metrics:protocol_detected_total:http"])
    assert.is_nil(data["stream:metrics:protocol_detected_total:tls"])
  end)

  it("raw 프로토콜 카운터 증가", function()
    local ngx_mock = make_ngx()
    ngx_mock.ctx.luagate_stream.detected_protocol = "raw"
    _G.ngx = ngx_mock
    local metrics = load_stream_metrics()

    metrics.collect()

    local data = ngx_mock._get_stream_metrics()
    assert.are.equal(1, data["stream:metrics:protocol_detected_total:raw"])
  end)

  it("알 수 없는 프로토콜은 raw로 정규화된다", function()
    local ngx_mock = make_ngx()
    ngx_mock.ctx.luagate_stream.detected_protocol = "ssh"
    _G.ngx = ngx_mock
    local metrics = load_stream_metrics()

    metrics.collect()

    local data = ngx_mock._get_stream_metrics()
    assert.are.equal(1, data["stream:metrics:protocol_detected_total:raw"])
    assert.is_nil(data["stream:metrics:protocol_detected_total:ssh"])
  end)
end)

-- ===========================================================================
-- shared dict 없는 경우
-- ===========================================================================

describe("log/stream_metrics.collect — shared dict 없음", function()
  it("luagate_stream_metrics가 nil이어도 에러 없이 동작한다", function()
    local ngx_mock = make_ngx()
    ngx_mock.shared = {}
    _G.ngx = ngx_mock
    local metrics = load_stream_metrics()

    assert.has_no.errors(function()
      metrics.collect()
    end)
  end)
end)

-- ===========================================================================
-- ctx 없을 때 fallback
-- ===========================================================================

describe("log/stream_metrics.collect — ctx 없음 fallback", function()
  it("ctx 없을 때 ngx.var에서 action/protocol을 읽어 동작한다", function()
    local ngx_mock = make_ngx()
    ngx_mock.ctx = {} -- luagate_stream 없음
    ngx_mock.var.luagate_stream_action = "deny"
    ngx_mock.var.luagate_protocol = "raw"
    _G.ngx = ngx_mock
    local metrics = load_stream_metrics()

    metrics.collect()

    local data = ngx_mock._get_stream_metrics()
    assert.are.equal(1, data["stream:metrics:connections_total"])
    assert.are.equal(1, data["stream:metrics:connections_denied_total"])
    assert.are.equal(1, data["stream:metrics:protocol_detected_total:raw"])
  end)
end)
