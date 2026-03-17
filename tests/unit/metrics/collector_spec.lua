--- Unit tests for lua/luagate/metrics/collector.lua
-- Implementation: lua/luagate/metrics/collector.lua
-- Tests: tests/unit/metrics/collector_spec.lua
--
-- collector.lua는 ngx.shared.luagate_metrics와 ngx.var에 의존하므로
-- 두 가지를 모두 mock한다.

-- ---------------------------------------------------------------------------
-- ngx mock 팩토리 (shared dict 카운터 추적 포함)
-- ---------------------------------------------------------------------------
local function make_ngx(overrides)
  local logged = {}
  -- 카운터 저장소: key → value
  local counter_store = {}

  local metrics_dict = {
    incr = function(_, key, delta, default)
      local d = delta or 1
      local init = default or 0
      if counter_store[key] == nil then
        counter_store[key] = init
      end
      counter_store[key] = counter_store[key] + d
      return counter_store[key], nil
    end,
    get = function(_, key)
      return counter_store[key]
    end,
    _store = counter_store,
  }

  local mock = {
    var = {
      luagate_action = "allow",
      status = "200",
      request_time = "0.001",
    },
    ctx = {},
    shared = {
      luagate_metrics = metrics_dict,
    },
    header = {},
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
  mock._get_counter = function(key)
    return counter_store[key]
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
-- 모듈 로드 헬퍼 (각 테스트마다 새 ngx로 실행)
-- package.preload도 제거하여 다른 spec 파일의 stub이 간섭하지 않도록 한다
-- ---------------------------------------------------------------------------
local function load_collector()
  package.loaded["luagate.metrics.collector"] = nil
  package.preload["luagate.metrics.collector"] = nil
  return require("luagate.metrics.collector")
end

-- ===========================================================================
-- total 카운터
-- ===========================================================================

describe("metrics.collector.record — total 카운터 증가", function()
  it("record() 호출 시 metrics:http:requests:total 카운터가 증가한다", function()
    local ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    local collector = load_collector()

    collector.record({ action = "allow" })

    assert.are.equal(1, ngx_mock._get_counter("metrics:http:requests:total"))
  end)

  it("record()를 3번 호출하면 total = 3", function()
    local ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    local collector = load_collector()

    collector.record({ action = "allow" })
    collector.record({ action = "allow" })
    collector.record({ action = "allow" })

    assert.are.equal(3, ngx_mock._get_counter("metrics:http:requests:total"))
  end)
end)

-- ===========================================================================
-- action 카운터 (allow / deny)
-- ===========================================================================

describe("metrics.collector.record — action 카운터", function()
  it("action='deny' → metrics:http:requests:deny 카운터 증가", function()
    local ngx_mock = make_ngx({ var = { status = "403", request_time = "0.001" } })
    _G.ngx = ngx_mock
    local collector = load_collector()

    collector.record({ action = "deny" })

    assert.are.equal(1, ngx_mock._get_counter("metrics:http:requests:deny"))
    assert.is_nil(ngx_mock._get_counter("metrics:http:requests:allow"))
  end)

  it("action='allow' → metrics:http:requests:allow 카운터 증가", function()
    local ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    local collector = load_collector()

    collector.record({ action = "allow" })

    assert.are.equal(1, ngx_mock._get_counter("metrics:http:requests:allow"))
    assert.is_nil(ngx_mock._get_counter("metrics:http:requests:deny"))
  end)

  it("ctx가 nil이면 ngx.var.luagate_action fallback 사용", function()
    local ngx_mock = make_ngx({ var = { luagate_action = "deny", status = "403", request_time = "0.001" } })
    _G.ngx = ngx_mock
    local collector = load_collector()

    -- ctx=nil로 호출
    collector.record(nil)

    assert.are.equal(1, ngx_mock._get_counter("metrics:http:requests:deny"))
  end)

  it("ctx.action도 없고 ngx.var.luagate_action도 없으면 allow로 처리된다", function()
    local ngx_mock = make_ngx()
    ngx_mock.var.luagate_action = nil
    _G.ngx = ngx_mock
    local collector = load_collector()

    collector.record({}) -- action 필드 없음

    assert.are.equal(1, ngx_mock._get_counter("metrics:http:requests:allow"))
  end)
end)

-- ===========================================================================
-- upstream error 카운터
-- ===========================================================================

describe("metrics.collector.record — upstream error 카운터", function()
  it("status=500 + action=allow → metrics:http:upstream_errors:total 증가", function()
    local ngx_mock = make_ngx({ var = { status = "500", request_time = "0.001" } })
    _G.ngx = ngx_mock
    local collector = load_collector()

    collector.record({ action = "allow" })

    assert.are.equal(1, ngx_mock._get_counter("metrics:http:upstream_errors:total"))
  end)

  it("status=502 + action=allow → upstream_errors:total 증가", function()
    local ngx_mock = make_ngx({ var = { status = "502", request_time = "0.001" } })
    _G.ngx = ngx_mock
    local collector = load_collector()

    collector.record({ action = "allow" })

    assert.are.equal(1, ngx_mock._get_counter("metrics:http:upstream_errors:total"))
  end)

  it("status=500 + action=deny → upstream_errors:total 증가 안 함 (deny는 upstream 없음)", function()
    local ngx_mock = make_ngx({ var = { status = "500", request_time = "0.001" } })
    _G.ngx = ngx_mock
    local collector = load_collector()

    collector.record({ action = "deny" })

    assert.is_nil(ngx_mock._get_counter("metrics:http:upstream_errors:total"))
  end)

  it("status=200 + action=allow → upstream_errors:total 증가 안 함", function()
    local ngx_mock = make_ngx({ var = { status = "200", request_time = "0.001" } })
    _G.ngx = ngx_mock
    local collector = load_collector()

    collector.record({ action = "allow" })

    assert.is_nil(ngx_mock._get_counter("metrics:http:upstream_errors:total"))
  end)
end)

-- ===========================================================================
-- 상태 코드 카운터
-- ===========================================================================

describe("metrics.collector.record — per-status-code 카운터", function()
  it("status=200 → metrics:http:status:200 증가", function()
    local ngx_mock = make_ngx({ var = { status = "200", request_time = "0.001" } })
    _G.ngx = ngx_mock
    local collector = load_collector()

    collector.record({ action = "allow" })

    assert.are.equal(1, ngx_mock._get_counter("metrics:http:status:200"))
  end)

  it("status=403 → metrics:http:status:403 증가", function()
    local ngx_mock = make_ngx({ var = { status = "403", request_time = "0.001" } })
    _G.ngx = ngx_mock
    local collector = load_collector()

    collector.record({ action = "deny" })

    assert.are.equal(1, ngx_mock._get_counter("metrics:http:status:403"))
  end)
end)

-- ===========================================================================
-- latency histogram bucket
-- ===========================================================================

describe("metrics.collector.record — latency histogram bucket", function()
  it("request_time='0.0001' (0.1ms) → bucket key 'metrics:http:latency:bucket:0.1' (L-2)", function()
    local ngx_mock = make_ngx({ var = { status = "200", request_time = "0.0001" } })
    _G.ngx = ngx_mock
    local collector = load_collector()

    collector.record({ action = "allow" })

    assert.are.equal(1, ngx_mock._get_counter("metrics:http:latency:bucket:0.1"))
    -- 이전 prefix는 사용하지 않음 (L-2 수정 확인)
    assert.is_nil(ngx_mock._get_counter("latency:bucket:0.1"))
  end)

  it("request_time='0.010' (10ms) → bucket 'metrics:http:latency:bucket:10'", function()
    local ngx_mock = make_ngx({ var = { status = "200", request_time = "0.010" } })
    _G.ngx = ngx_mock
    local collector = load_collector()

    collector.record({ action = "allow" })

    assert.are.equal(1, ngx_mock._get_counter("metrics:http:latency:bucket:10"))
  end)

  it("request_time='2.000' (2000ms) → bucket 'metrics:http:latency:bucket:inf' (모든 bucket 초과)", function()
    local ngx_mock = make_ngx({ var = { status = "200", request_time = "2.000" } })
    _G.ngx = ngx_mock
    local collector = load_collector()

    collector.record({ action = "allow" })

    assert.are.equal(1, ngx_mock._get_counter("metrics:http:latency:bucket:inf"))
  end)

  it("request_time='0.001' (1ms) → bucket 'metrics:http:latency:bucket:1'", function()
    local ngx_mock = make_ngx({ var = { status = "200", request_time = "0.001" } })
    _G.ngx = ngx_mock
    local collector = load_collector()

    collector.record({ action = "allow" })

    assert.are.equal(1, ngx_mock._get_counter("metrics:http:latency:bucket:1"))
  end)

  it("request_time='0.050' (50ms) → bucket 'metrics:http:latency:bucket:50'", function()
    local ngx_mock = make_ngx({ var = { status = "200", request_time = "0.050" } })
    _G.ngx = ngx_mock
    local collector = load_collector()

    collector.record({ action = "allow" })

    assert.are.equal(1, ngx_mock._get_counter("metrics:http:latency:bucket:50"))
  end)

  it("request_time='0.100' (100ms) → bucket 'metrics:http:latency:bucket:100'", function()
    local ngx_mock = make_ngx({ var = { status = "200", request_time = "0.100" } })
    _G.ngx = ngx_mock
    local collector = load_collector()

    collector.record({ action = "allow" })

    assert.are.equal(1, ngx_mock._get_counter("metrics:http:latency:bucket:100"))
  end)

  it("request_time='1.000' (1000ms) → bucket 'metrics:http:latency:bucket:1000'", function()
    local ngx_mock = make_ngx({ var = { status = "200", request_time = "1.000" } })
    _G.ngx = ngx_mock
    local collector = load_collector()

    collector.record({ action = "allow" })

    assert.are.equal(1, ngx_mock._get_counter("metrics:http:latency:bucket:1000"))
  end)
end)

-- ===========================================================================
-- shared dict 없을 때 안전 처리
-- ===========================================================================

describe("metrics.collector.record — shared dict 없을 때 안전 처리", function()
  it("luagate_metrics dict가 nil이면 에러 없이 return한다", function()
    local ngx_mock = make_ngx()
    ngx_mock.shared.luagate_metrics = nil
    _G.ngx = ngx_mock
    local collector = load_collector()

    assert.has_no.errors(function()
      collector.record({ action = "allow" })
    end)
  end)

  it("ngx.shared.luagate_metrics가 nil이면 에러 없이 return한다 (dict key missing)", function()
    -- collector.lua는 ngx.shared.luagate_metrics를 조회하므로
    -- ngx.shared는 존재하지만 luagate_metrics 키가 nil인 경우를 검증
    local ngx_mock = make_ngx()
    ngx_mock.shared = { luagate_metrics = nil }
    _G.ngx = ngx_mock
    local collector = load_collector()

    assert.has_no.errors(function()
      collector.record({ action = "allow" })
    end)
  end)

  it("ctx=nil + dict=nil → 에러 없이 처리된다", function()
    local ngx_mock = make_ngx()
    ngx_mock.shared.luagate_metrics = nil
    _G.ngx = ngx_mock
    local collector = load_collector()

    assert.has_no.errors(function()
      collector.record(nil)
    end)
  end)
end)

-- ===========================================================================
-- incr 오류 처리 (ADR-001 §1.2: 메트릭 손실 허용)
-- ===========================================================================

describe("metrics.collector.record — incr 오류 처리 (non-fatal)", function()
  it("dict:incr이 에러를 반환해도 record()는 계속 실행된다", function()
    local logged = {}
    local ngx_mock = make_ngx()
    ngx_mock.shared.luagate_metrics = {
      incr = function(_, _key, _delta, _default)
        return nil, "incr error simulation"
      end,
    }
    ngx_mock.log = function(_, ...)
      local parts = { ... }
      logged[#logged + 1] = table.concat(parts, "")
    end
    _G.ngx = ngx_mock
    local collector = load_collector()

    -- 에러가 전파되지 않아야 한다
    assert.has_no.errors(function()
      collector.record({ action = "allow" })
    end)

    -- WARN 로그가 기록되어야 한다
    local found_warn = false
    for _, msg in ipairs(logged) do
      if msg:find("metrics incr failed") then
        found_warn = true
        break
      end
    end
    assert.is_true(found_warn, "incr 실패 시 WARN 로그가 기록되어야 한다")
  end)
end)

-- ===========================================================================
-- scanner threat 카운터 (ADR-006 §3: per-threat_type counter)
-- ===========================================================================

describe("metrics.collector.record — scanner threat 카운터 (ADR-006 §3)", function()
  it("ctx.threat_type 설정 시 scanner_threats 카운터 증가 (ADR-006 key format)", function()
    local ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    local collector = load_collector()

    collector.record({ action = "deny", threat_type = "sqli" })
    assert.are.equal(1, ngx_mock._get_counter("metrics:http_scanner_threats_total:threat:sqli"))
    -- 이전 key format은 사용하지 않음
    assert.is_nil(ngx_mock._get_counter("metrics:http:scanner_threats:total:sqli"))
  end)

  it("ctx.threat_type = nil 시 scanner_threats 카운터 미증가", function()
    local ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    local collector = load_collector()

    collector.record({ action = "allow" })
    assert.is_nil(ngx_mock._get_counter("metrics:http_scanner_threats_total:threat:sqli"))
  end)

  it("다양한 threat_type은 별도 카운터로 기록된다", function()
    local ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    local collector = load_collector()

    collector.record({ action = "deny", threat_type = "sqli" })
    collector.record({ action = "deny", threat_type = "xss" })
    collector.record({ action = "deny", threat_type = "sqli" })
    assert.are.equal(2, ngx_mock._get_counter("metrics:http_scanner_threats_total:threat:sqli"))
    assert.are.equal(1, ngx_mock._get_counter("metrics:http_scanner_threats_total:threat:xss"))
  end)

  it("unknown threat_type은 'other'로 정규화된다 (ADR-006 §1.1 allowlist)", function()
    local ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    local collector = load_collector()

    collector.record({ action = "deny", threat_type = "unknown_attack" })
    assert.are.equal(1, ngx_mock._get_counter("metrics:http_scanner_threats_total:threat:other"))
    assert.is_nil(ngx_mock._get_counter("metrics:http_scanner_threats_total:threat:unknown_attack"))
  end)

  it("allowlist에 포함된 threat_type은 그대로 사용된다", function()
    local ngx_mock = make_ngx()
    _G.ngx = ngx_mock
    local collector = load_collector()

    local allowlisted = {
      "sqli",
      "xss",
      "path_traversal",
      "cmd_injection",
      "lfi",
      "rfi",
      "xxe",
      "ssrf",
      "log4shell",
      "scanner",
      "deserialization",
      "other",
    }
    for _, tt in ipairs(allowlisted) do
      collector.record({ action = "deny", threat_type = tt })
      assert.are.equal(
        1,
        ngx_mock._get_counter("metrics:http_scanner_threats_total:threat:" .. tt),
        "allowlisted threat_type '" .. tt .. "' should use its own key"
      )
    end
  end)
end)
