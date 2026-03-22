--- Unit tests for lua/luagate/admin/router.lua
-- Implementation: lua/luagate/admin/router.lua
-- Tests: tests/unit/admin/router_spec.lua
--
-- router.lua는 OpenResty ngx 전역 + cjson.safe + luagate.admin.auth에 의존하므로
-- busted (Lua 5.4) 환경에서 stub을 주입한다.

-- ---------------------------------------------------------------------------
-- cjson.safe stub (dkjson wrapper — LuaJIT 없는 busted 환경)
-- ---------------------------------------------------------------------------
package.preload["cjson.safe"] = function()
  local dkjson = require("dkjson")
  return {
    encode = dkjson.encode,
    decode = dkjson.decode,
    null = dkjson.null,
    empty_array = setmetatable({}, { __jsontype = "array" }),
  }
end

-- ---------------------------------------------------------------------------
-- Shared dict mock 팩토리
-- ---------------------------------------------------------------------------
local function make_shared_dict(data)
  data = data or {}
  return {
    get = function(_, key)
      return data[key]
    end,
    incr = function(_, key, value, init, _ttl)
      if data[key] then
        data[key] = data[key] + value
      else
        data[key] = (init or 0) + value
      end
      return data[key], nil
    end,
    capacity = function()
      return 10485760
    end, -- 10MB
    free_space = function()
      return 8388608
    end, -- 8MB
    -- Expose internal data for direct manipulation in tests
    _data = data,
  }
end

-- ---------------------------------------------------------------------------
-- ngx mock 팩토리
-- ---------------------------------------------------------------------------
local function make_ngx(overrides)
  local exited_with = nil
  local logged = {}
  local said = {}
  local printed = {}

  local mock = {
    var = {
      remote_addr = "10.0.0.1",
      uri = "/health",
    },
    ctx = {},
    header = {},
    headers_sent = false,
    status = 0,
    -- Log levels (match OpenResty constants)
    EMERG = 0,
    ALERT = 1,
    CRIT = 2,
    ERR = 3,
    WARN = 4,
    NOTICE = 5,
    INFO = 6,
    DEBUG = 7,
    HTTP_OK = 200,
    HTTP_NOT_FOUND = 404,
    shared = {
      luagate_policy = make_shared_dict({ ["http:active_version"] = "abc123" }),
      luagate_state = make_shared_dict(),
      luagate_metrics = make_shared_dict(),
      luagate_stream_metrics = make_shared_dict(),
      luagate_connections = make_shared_dict(),
      luagate_admin_ratelimit = make_shared_dict(),
    },
    worker = {
      id = function()
        return 0
      end,
      count = function()
        return 1
      end,
    },
    now = function()
      return 1700000100.5
    end,
    log = function(level, ...)
      local parts = {}
      for _, v in ipairs({ ... }) do
        parts[#parts + 1] = tostring(v)
      end
      logged[#logged + 1] = { level = level, msg = table.concat(parts, "") }
    end,
    exit = function(code)
      exited_with = code
    end,
    say = function(s)
      said[#said + 1] = s
    end,
    print = function(s)
      printed[#printed + 1] = s
    end,
    req = {
      get_headers = function()
        return { Authorization = "Bearer valid-test-token" }
      end,
      get_method = function()
        return "GET"
      end,
    },
  }

  -- 추적용 getter
  mock._get_exited = function()
    return exited_with
  end
  mock._get_logged = function()
    return logged
  end
  mock._get_said = function()
    return said
  end
  mock._get_printed = function()
    return printed
  end
  mock._reset_tracking = function()
    exited_with = nil
    for i = 1, #logged do
      logged[i] = nil
    end
    for i = 1, #said do
      said[i] = nil
    end
    for i = 1, #printed do
      printed[i] = nil
    end
    mock.status = 0
    mock.header = {}
    mock.headers_sent = false
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
-- Auth mock 팩토리
-- ---------------------------------------------------------------------------

--- auth mock: verify()가 항상 성공하는 버전
local function make_auth_pass()
  return {
    verify = function()
      return true
    end,
    init = function()
      return true
    end,
  }
end

--- auth mock: verify()가 401을 설정하고 coroutine abort를 시뮬레이션하는 버전.
-- 실제 OpenResty에서 ngx.exit()는 coroutine yield로 실행을 중단한다.
-- mock에서는 error()를 throw하여 동일한 abort 동작을 재현한다.
local function make_auth_fail()
  return {
    verify = function()
      ngx.status = 401
      ngx.header["Content-Type"] = "application/json"
      ngx.say('{"error":"Unauthorized","message":"Invalid or missing Bearer token"}')
      error("ngx.exit(401)")
    end,
    init = function()
      return true
    end,
  }
end

-- ---------------------------------------------------------------------------
-- 모듈 로드 헬퍼
-- ---------------------------------------------------------------------------
local _saved_ngx = _G.ngx
_G.ngx = make_ngx()

local router -- 테스트마다 fresh require

--- router 모듈을 fresh require하는 헬퍼.
-- auth mock을 preload한 뒤 router를 로드한다.
local function load_router(auth_mock)
  package.loaded["luagate.admin.router"] = nil
  package.loaded["luagate.admin.auth"] = nil
  package.loaded["luagate.admin.ratelimit"] = nil
  package.preload["luagate.admin.auth"] = function()
    return auth_mock or make_auth_pass()
  end
  return require("luagate.admin.router")
end

-- ---------------------------------------------------------------------------
-- 전체 테스트 완료 후 정리
-- ---------------------------------------------------------------------------
teardown(function()
  _G.ngx = _saved_ngx
  package.preload["cjson.safe"] = nil
  package.preload["luagate.admin.auth"] = nil
  package.loaded["cjson.safe"] = nil
  package.loaded["luagate.admin.auth"] = nil
  package.loaded["luagate.admin.ratelimit"] = nil
  package.loaded["luagate.admin.router"] = nil
end)

-- ===========================================================================
-- 라우팅 테스트
-- ===========================================================================
describe("router.dispatch", function()
  describe("라우팅", function()
    before_each(function()
      _G.ngx = make_ngx()
      router = load_router(make_auth_pass())
    end)

    it("GET /health -> 200 + {status:ok} (정책 로드 상태)", function()
      _G.ngx.var.uri = "/health"
      _G.ngx.req.get_method = function()
        return "GET"
      end

      router.dispatch()

      assert.are.equal(200, _G.ngx.status)
      local said = _G.ngx._get_said()
      assert.is_true(#said >= 1, "ngx.say가 호출되어야 한다")
      local dkjson = require("dkjson")
      local body = dkjson.decode(said[1])
      assert.are.equal("ok", body.status)
    end)

    it("GET /health -> 200 with ADR-008 version fields + per-worker leak array", function()
      _G.ngx.var.uri = "/health"
      _G.ngx.shared.luagate_policy = make_shared_dict({
        ["http:active_version"] = "abc123",
        ["stream:active_version"] = "abc123",
        ["source_version"] = "abc123",
        ["policy_loaded_at"] = 1700000100,
      })
      _G.ngx.req.get_method = function()
        return "GET"
      end

      router.dispatch()

      assert.are.equal(200, _G.ngx.status)
      local said = _G.ngx._get_said()
      local dkjson = require("dkjson")
      local body = dkjson.decode(said[1])
      assert.are.equal("ok", body.status)
      assert.are.equal("abc123", body.source_version)
      assert.are.equal("abc123", body.active_http_version)
      assert.are.equal("abc123", body.active_stream_version)
      assert.is_string(body.policy_loaded_at)
      assert.is_table(body.ffi_watchdog_leak_count)
      assert.are.equal(0, body.ffi_watchdog_timeouts)
    end)

    it("GET /api/v1/status -> 200 + detailed status payload", function()
      _G.ngx.var.uri = "/api/v1/status"
      _G.ngx.shared.luagate_policy = make_shared_dict({
        ["http:active_version"] = "abc123",
        ["stream:active_version"] = "def456",
        ["policy_loaded_at"] = 1700000000,
      })
      _G.ngx.worker.count = function()
        return 4
      end
      _G.ngx.req.get_method = function()
        return "GET"
      end

      router.dispatch()

      assert.are.equal(200, _G.ngx.status)
      local said = _G.ngx._get_said()
      local dkjson = require("dkjson")
      local body = dkjson.decode(said[1])
      assert.are.equal("0.1.0", body.luagate_version)
      assert.are.equal(4, body.worker_count)
      assert.are.equal("abc123", body.active_http_version)
      assert.are.equal("def456", body.active_stream_version)
      assert.are.equal("success", body.last_reload_status)
      assert.is_number(body.uptime_seconds)
      assert.is_string(body.last_reload_at)
    end)

    it("GET /health -> 200 with per-worker ffi_watchdog_leak_count array", function()
      _G.ngx.var.uri = "/health"
      _G.ngx.shared.luagate_metrics = make_shared_dict({
        ["ffi:timeout:leak:0"] = 3,
      })
      _G.ngx.worker.count = function()
        return 1
      end
      _G.ngx.req.get_method = function()
        return "GET"
      end

      router.dispatch()

      assert.are.equal(200, _G.ngx.status)
      local said = _G.ngx._get_said()
      local dkjson = require("dkjson")
      local body = dkjson.decode(said[1])
      assert.is_table(body.ffi_watchdog_leak_count)
      assert.are.equal(3, body.ffi_watchdog_leak_count[1])
      assert.are.equal(3, body.ffi_watchdog_timeouts)
    end)

    it("GET /health -> 200 with multi-worker leak counts below threshold", function()
      _G.ngx.var.uri = "/health"
      _G.ngx.shared.luagate_metrics = make_shared_dict({
        ["ffi:timeout:leak:0"] = 2,
        ["ffi:timeout:leak:1"] = 5,
        ["ffi:timeout:leak:2"] = 0,
        ["ffi:timeout:leak:3"] = 3,
      })
      _G.ngx.worker.count = function()
        return 4
      end
      _G.ngx.req.get_method = function()
        return "GET"
      end

      router.dispatch()

      assert.are.equal(200, _G.ngx.status)
      local said = _G.ngx._get_said()
      local dkjson = require("dkjson")
      local body = dkjson.decode(said[1])
      assert.are.equal("ok", body.status)
      assert.is_table(body.ffi_watchdog_leak_count)
      assert.are.equal(4, #body.ffi_watchdog_leak_count)
      assert.are.equal(2, body.ffi_watchdog_leak_count[1])
      assert.are.equal(5, body.ffi_watchdog_leak_count[2])
      assert.are.equal(0, body.ffi_watchdog_leak_count[3])
      assert.are.equal(3, body.ffi_watchdog_leak_count[4])
      assert.are.equal(10, body.ffi_watchdog_timeouts)
    end)

    it("GET /health -> 503 when any worker exceeds FFI leak threshold", function()
      _G.ngx.var.uri = "/health"
      _G.ngx.shared.luagate_metrics = make_shared_dict({
        ["ffi:timeout:leak:0"] = 2,
        ["ffi:timeout:leak:1"] = 11, -- exceeds threshold of 10
        ["ffi:timeout:leak:2"] = 0,
      })
      _G.ngx.worker.count = function()
        return 3
      end
      _G.ngx.req.get_method = function()
        return "GET"
      end

      router.dispatch()

      assert.are.equal(503, _G.ngx.status)
      local said = _G.ngx._get_said()
      local dkjson = require("dkjson")
      local body = dkjson.decode(said[1])
      assert.are.equal("unhealthy", body.status)
      assert.are.equal("ffi_thread_leak_threshold_exceeded", body.reason)
      assert.are.equal(13, body.ffi_watchdog_timeouts)
      assert.are.equal(11, body.ffi_watchdog_leak_count[2])
    end)

    it("GET /health -> 503 FFI leak takes priority over policy-not-loaded", function()
      _G.ngx.var.uri = "/health"
      _G.ngx.shared.luagate_policy = make_shared_dict({}) -- no policy
      _G.ngx.shared.luagate_metrics = make_shared_dict({
        ["ffi:timeout:leak:0"] = 15,
      })
      _G.ngx.worker.count = function()
        return 1
      end
      _G.ngx.req.get_method = function()
        return "GET"
      end

      router.dispatch()

      assert.are.equal(503, _G.ngx.status)
      local said = _G.ngx._get_said()
      local dkjson = require("dkjson")
      local body = dkjson.decode(said[1])
      assert.are.equal("ffi_thread_leak_threshold_exceeded", body.reason)
    end)

    it("GET /health -> graceful degradation when metrics dict is nil", function()
      _G.ngx.var.uri = "/health"
      _G.ngx.shared.luagate_metrics = nil
      _G.ngx.req.get_method = function()
        return "GET"
      end

      router.dispatch()

      assert.are.equal(200, _G.ngx.status)
      local said = _G.ngx._get_said()
      assert.truthy(said[1]:find('"ffi_watchdog_leak_count"%s*:%s*%[%]'))
      local dkjson = require("dkjson")
      local body = dkjson.decode(said[1])
      assert.are.equal("ok", body.status)
      assert.is_table(body.ffi_watchdog_leak_count)
      assert.are.equal(0, #body.ffi_watchdog_leak_count)
      assert.are.equal(0, body.ffi_watchdog_timeouts)
    end)

    it("GET /health -> graceful degradation when worker.count fails (wid=0)", function()
      _G.ngx.var.uri = "/health"
      _G.ngx.shared.luagate_metrics = make_shared_dict({
        ["ffi:timeout:leak:0"] = 5,
      })
      _G.ngx.worker.count = function()
        error("not available in init phase")
      end
      _G.ngx.req.get_method = function()
        return "GET"
      end

      router.dispatch()

      assert.are.equal(200, _G.ngx.status)
      local said = _G.ngx._get_said()
      local dkjson = require("dkjson")
      local body = dkjson.decode(said[1])
      assert.are.equal("ok", body.status)
      -- Falls back to current worker only, index = worker id contract preserved
      assert.is_table(body.ffi_watchdog_leak_count)
      assert.are.equal(1, #body.ffi_watchdog_leak_count)
      assert.are.equal(5, body.ffi_watchdog_leak_count[1])
      assert.are.equal(5, body.ffi_watchdog_timeouts)
    end)

    it("GET /health -> graceful degradation when worker.count fails (wid=2)", function()
      _G.ngx.var.uri = "/health"
      _G.ngx.shared.luagate_metrics = make_shared_dict({
        ["ffi:timeout:leak:2"] = 7,
      })
      _G.ngx.worker.id = function()
        return 2
      end
      _G.ngx.worker.count = function()
        error("not available in init phase")
      end
      _G.ngx.req.get_method = function()
        return "GET"
      end

      router.dispatch()

      assert.are.equal(200, _G.ngx.status)
      local said = _G.ngx._get_said()
      local dkjson = require("dkjson")
      local body = dkjson.decode(said[1])
      assert.are.equal("ok", body.status)
      -- Array padded with 0s: [0, 0, 7] — preserves "index = worker id" contract
      assert.is_table(body.ffi_watchdog_leak_count)
      assert.are.equal(3, #body.ffi_watchdog_leak_count)
      assert.are.equal(0, body.ffi_watchdog_leak_count[1])
      assert.are.equal(0, body.ffi_watchdog_leak_count[2])
      assert.are.equal(7, body.ffi_watchdog_leak_count[3])
      assert.are.equal(7, body.ffi_watchdog_timeouts)
    end)

    it("GET /health -> 503 + {status:unhealthy} (정책 미로드 상태)", function()
      _G.ngx.var.uri = "/health"
      _G.ngx.shared.luagate_policy = make_shared_dict({}) -- http:active_version 없음
      _G.ngx.req.get_method = function()
        return "GET"
      end

      router.dispatch()

      assert.are.equal(503, _G.ngx.status)
      local said = _G.ngx._get_said()
      local dkjson = require("dkjson")
      local body = dkjson.decode(said[1])
      assert.are.equal("unhealthy", body.status)
      assert.are.equal("policy not loaded", body.reason)
    end)

    it("GET /health -> 503 (active_version이 'none'인 경우)", function()
      _G.ngx.var.uri = "/health"
      _G.ngx.shared.luagate_policy = make_shared_dict({ ["http:active_version"] = "none" })
      _G.ngx.req.get_method = function()
        return "GET"
      end

      router.dispatch()

      assert.are.equal(503, _G.ngx.status)
    end)

    it("GET /health -> HTTP-only: nil stream/source fields serialize as JSON null", function()
      _G.ngx.var.uri = "/health"
      -- HTTP-only: only http:active_version is set, no stream or source_version
      _G.ngx.shared.luagate_policy = make_shared_dict({
        ["http:active_version"] = "http-only-v1",
      })
      _G.ngx.req.get_method = function()
        return "GET"
      end

      router.dispatch()

      assert.are.equal(200, _G.ngx.status)
      local said = _G.ngx._get_said()
      local dkjson = require("dkjson")
      local body = dkjson.decode(said[1])
      assert.are.equal("ok", body.status)
      assert.are.equal("http-only-v1", body.active_http_version)
      -- nil fields must be present as JSON null, not missing from the output
      local raw_json = said[1]
      assert.is_truthy(raw_json:find('"active_stream_version":null'), "active_stream_version must be null in JSON")
      assert.is_truthy(raw_json:find('"source_version":null'), "source_version must be null in JSON")
      assert.is_truthy(raw_json:find('"policy_loaded_at":null'), "policy_loaded_at must be null in JSON")
    end)

    it("GET /metrics -> 200 + Content-Type: text/plain Prometheus 형식", function()
      _G.ngx.var.uri = "/metrics"
      _G.ngx.req.get_method = function()
        return "GET"
      end

      router.dispatch()

      assert.are.equal(200, _G.ngx.status)
      assert.are.equal("text/plain; version=0.0.4; charset=utf-8", _G.ngx.header["Content-Type"])
      local printed = _G.ngx._get_printed()
      assert.is_true(#printed >= 1, "ngx.print가 호출되어야 한다")
    end)

    it("알 수 없는 경로 -> 404 + 에러 응답 형식", function()
      _G.ngx.var.uri = "/unknown/path"
      _G.ngx.req.get_method = function()
        return "GET"
      end

      router.dispatch()

      assert.are.equal(404, _G.ngx.status)
      assert.are.equal(404, _G.ngx._get_exited())
      local said = _G.ngx._get_said()
      local dkjson = require("dkjson")
      local body = dkjson.decode(said[1])
      assert.are.equal("not_found", body.error)
      assert.are.equal("routing", body.stage)
      assert.is_table(body.details)
      assert.is_true(#body.details >= 1)
    end)

    it("잘못된 메서드 (POST /health) -> 405 + 에러 응답 형식", function()
      _G.ngx.var.uri = "/health"
      _G.ngx.req.get_method = function()
        return "POST"
      end

      router.dispatch()

      assert.are.equal(405, _G.ngx.status)
      assert.are.equal(405, _G.ngx._get_exited())
      local said = _G.ngx._get_said()
      local dkjson = require("dkjson")
      local body = dkjson.decode(said[1])
      assert.are.equal("method_not_allowed", body.error)
      assert.are.equal("routing", body.stage)
    end)

    it("POST /health은 rate limit 면제 아님 (GET만 면제)", function()
      _G.ngx = make_ngx()
      -- Pre-populate rate limit to exceed limit
      local now = _G.ngx.now()
      local current_slot = math.floor(now / 60)
      local key = "rl:10.0.0.1:" .. tostring(current_slot)
      _G.ngx.shared.luagate_admin_ratelimit._data[key] = 30

      _G.ngx.var.uri = "/health"
      _G.ngx.req.get_method = function()
        return "POST"
      end
      -- Simulate OpenResty coroutine abort: ngx.exit() throws to stop execution
      local saved_exit = _G.ngx.exit
      _G.ngx.exit = function(code)
        saved_exit(code)
        error("ngx.exit(" .. tostring(code) .. ")")
      end

      router = load_router(make_auth_pass())
      local ok, _ = pcall(router.dispatch)
      assert.is_false(ok, "rate limit 초과 시 ngx.exit로 coroutine abort되어야 한다")

      -- Should get 429 (rate limited), not 405 (method not allowed)
      assert.are.equal(429, _G.ngx.status)
    end)

    it("잘못된 메서드 (DELETE /metrics) -> 405", function()
      _G.ngx.var.uri = "/metrics"
      _G.ngx.req.get_method = function()
        return "DELETE"
      end

      router.dispatch()

      assert.are.equal(405, _G.ngx.status)
      assert.are.equal(405, _G.ngx._get_exited())
    end)

    it("인증 실패 (토큰 없음) -> 401 (auth.verify에 위임)", function()
      _G.ngx = make_ngx()
      _G.ngx.var.uri = "/metrics"
      _G.ngx.req.get_method = function()
        return "GET"
      end
      router = load_router(make_auth_fail())

      -- auth.verify()가 error()로 coroutine abort를 시뮬레이션하므로
      -- dispatch()에서 에러가 전파된다 (실제 OpenResty에서는 ngx.exit가 yield)
      local ok, _ = pcall(router.dispatch)
      assert.is_false(ok, "auth 실패 시 coroutine abort(error)가 전파되어야 한다")

      -- auth가 설정한 401 상태와 JSON 에러 본문 확인
      assert.are.equal(401, _G.ngx.status)
      local said = _G.ngx._get_said()
      assert.is_true(#said >= 1, "auth 에러 응답이 전송되어야 한다")
      assert.truthy(said[1]:find("Unauthorized"), "401 응답에 Unauthorized가 포함되어야 한다")
    end)

    it("OPTIONS 요청 -> 204 (CORS preflight)", function()
      _G.ngx = make_ngx()
      _G.ngx.var.uri = "/metrics"
      _G.ngx.req.get_method = function()
        return "OPTIONS"
      end
      router = load_router(make_auth_pass())

      router.dispatch()

      assert.are.equal(204, _G.ngx.status)
    end)

    it("OPTIONS 요청도 rate limit 적용 후 204 처리", function()
      _G.ngx = make_ngx()
      local now = _G.ngx.now()
      local current_slot = math.floor(now / 60)
      local key = "rl:10.0.0.1:" .. tostring(current_slot)
      _G.ngx.shared.luagate_admin_ratelimit._data[key] = 30

      _G.ngx.var.uri = "/metrics"
      _G.ngx.req.get_method = function()
        return "OPTIONS"
      end

      local saved_exit = _G.ngx.exit
      _G.ngx.exit = function(code)
        saved_exit(code)
        error("ngx.exit(" .. tostring(code) .. ")")
      end

      router = load_router(make_auth_pass())
      local ok, _ = pcall(router.dispatch)
      assert.is_false(ok, "rate limit 초과 시 OPTIONS도 coroutine abort되어야 한다")
      assert.are.equal(429, _G.ngx.status)
    end)
  end)

  -- =========================================================================
  -- 메트릭스 출력 테스트
  -- =========================================================================
  describe("GET /metrics 출력", function()
    local output

    --- 메트릭스 출력을 캡처하는 헬퍼
    local function get_metrics_output(metrics_data, stream_data, connections_data)
      _G.ngx = make_ngx({
        var = { uri = "/metrics" },
        shared = {
          luagate_policy = make_shared_dict({
            ["http:active_version"] = "v1",
            ["stream:active_version"] = "v1",
          }),
          luagate_state = make_shared_dict(),
          luagate_metrics = make_shared_dict(metrics_data or {}),
          luagate_stream_metrics = make_shared_dict(stream_data or {}),
          luagate_connections = make_shared_dict(connections_data or {}),
          luagate_admin_ratelimit = make_shared_dict(),
        },
      })
      _G.ngx.req.get_method = function()
        return "GET"
      end
      router = load_router(make_auth_pass())

      router.dispatch()

      local printed = _G.ngx._get_printed()
      return table.concat(printed, "")
    end

    before_each(function()
      output = nil
    end)

    it("HTTP request counters (luagate_http_requests_total) 포함", function()
      output = get_metrics_output({
        ["metrics:http_requests_total:allow"] = 100,
        ["metrics:http_requests_total:deny"] = 5,
      })

      assert.truthy(
        output:find("luagate_http_requests_total"),
        "luagate_http_requests_total 메트릭이 있어야 한다"
      )
      assert.truthy(
        output:find('luagate_http_requests_total{action="allow"} 100'),
        "allow 카운터가 100이어야 한다"
      )
      assert.truthy(output:find('luagate_http_requests_total{action="deny"} 5'), "deny 카운터가 5여야 한다")
    end)

    it("luagate_http_requests_denied_total 포함", function()
      output = get_metrics_output({
        ["metrics:http_requests_denied_total"] = 42,
      })

      assert.truthy(output:find("luagate_http_requests_denied_total"), "denied total 메트릭이 있어야 한다")
      assert.truthy(output:find("luagate_http_requests_denied_total 42"), "denied total이 42여야 한다")
    end)

    it("latency histogram bucket 포함", function()
      output = get_metrics_output({
        ["latency:bucket:0.1"] = 10,
        ["latency:bucket:1"] = 50,
        ["latency:bucket:+Inf"] = 100,
        ["latency:sum"] = 5000,
        ["latency:count"] = 100,
      })

      assert.truthy(output:find("luagate_http_response_time_ms"), "histogram 메트릭이 있어야 한다")
      assert.truthy(
        output:find('luagate_http_response_time_ms_bucket{le="0.1"} 10'),
        "0.1 bucket이 10이어야 한다"
      )
      assert.truthy(output:find('luagate_http_response_time_ms_bucket{le="1"} 50'), "1 bucket이 50이어야 한다")
      assert.truthy(output:find('le="%+Inf"} 100'), "+Inf bucket이 100이어야 한다")
      assert.truthy(output:find("luagate_http_response_time_ms_sum 5000"), "sum이 5000이어야 한다")
      assert.truthy(output:find("luagate_http_response_time_ms_count 100"), "count가 100이어야 한다")
    end)

    it("stream counters 포함", function()
      output = get_metrics_output(nil, {
        ["stream:metrics:connections_total"] = 200,
        ["stream:metrics:connections_denied_total"] = 3,
        ["stream:metrics:bytes_sent_total"] = 1048576,
        ["stream:metrics:bytes_received_total"] = 524288,
      })

      assert.truthy(output:find("luagate_stream_connections_total"), "stream connections total이 있어야 한다")
      assert.truthy(output:find("luagate_stream_connections_total 200"), "stream connections이 200이어야 한다")
      assert.truthy(output:find("luagate_stream_connections_denied_total 3"), "denied가 3이어야 한다")
      assert.truthy(output:find("luagate_stream_bytes_sent_total 1048576"), "bytes sent가 맞아야 한다")
      assert.truthy(output:find("luagate_stream_bytes_received_total 524288"), "bytes received가 맞아야 한다")
    end)

    it("stream protocol detected counters 포함", function()
      output = get_metrics_output(nil, {
        ["stream:metrics:protocol_detected_total:tls"] = 50,
        ["stream:metrics:protocol_detected_total:http"] = 30,
        ["stream:metrics:protocol_detected_total:raw"] = 10,
      })

      assert.truthy(output:find("luagate_stream_protocol_detected_total"), "protocol detected가 있어야 한다")
      assert.truthy(output:find('luagate_stream_protocol_detected_total{protocol="tls"} 50'))
      assert.truthy(output:find('luagate_stream_protocol_detected_total{protocol="http"} 30'))
      assert.truthy(output:find('luagate_stream_protocol_detected_total{protocol="raw"} 10'))
    end)

    it("active connections gauge 포함", function()
      output = get_metrics_output(nil, nil, {
        ["active_http"] = 15,
        ["active_stream"] = 8,
      })

      assert.truthy(output:find("luagate_active_connections"), "active connections 메트릭이 있어야 한다")
      assert.truthy(output:find('luagate_active_connections{type="http"} 15'), "http active가 15여야 한다")
      assert.truthy(output:find('luagate_active_connections{type="stream"} 8'), "stream active가 8이어야 한다")
    end)

    it("shared dict capacity/free gauges 포함 (6개 zone)", function()
      output = get_metrics_output()

      assert.truthy(output:find("luagate_shared_dict_capacity_bytes"), "capacity 메트릭이 있어야 한다")
      assert.truthy(output:find("luagate_shared_dict_free_bytes"), "free 메트릭이 있어야 한다")
      -- 6개 zone 모두 존재 확인
      local zones = {
        "luagate_policy",
        "luagate_state",
        "luagate_metrics",
        "luagate_stream_metrics",
        "luagate_connections",
        "luagate_admin_ratelimit",
      }
      for _, zone in ipairs(zones) do
        assert.truthy(
          output:find('luagate_shared_dict_capacity_bytes{zone="' .. zone .. '"}'),
          zone .. " capacity가 있어야 한다"
        )
        assert.truthy(
          output:find('luagate_shared_dict_free_bytes{zone="' .. zone .. '"}'),
          zone .. " free가 있어야 한다"
        )
      end
    end)

    it("scanner threat counters: 0이 아닌 값만 출력", function()
      output = get_metrics_output({
        ["metrics:http_scanner_threats_total:threat:sqli"] = 7,
        ["metrics:http_scanner_threats_total:threat:xss"] = 3,
        -- 나머지 threat type은 0 (기본)
      })

      assert.truthy(output:find("luagate_http_scanner_threats_total"), "scanner threats 메트릭이 있어야 한다")
      assert.truthy(
        output:find('luagate_http_scanner_threats_total{threat_type="sqli"} 7'),
        "sqli가 7이어야 한다"
      )
      assert.truthy(output:find('luagate_http_scanner_threats_total{threat_type="xss"} 3'), "xss가 3이어야 한다")
      -- 0인 threat type은 출력되지 않아야 한다
      assert.is_nil(output:find('threat_type="path_traversal"'), "0인 path_traversal은 출력되지 않아야 한다")
      assert.is_nil(output:find('threat_type="cmd_injection"'), "0인 cmd_injection은 출력되지 않아야 한다")
    end)

    it("scanner threat counters: 모든 값이 0이면 threat line 없음", function()
      output = get_metrics_output({}) -- 모든 threat 0

      -- HELP/TYPE 헤더는 있지만 실제 값 라인은 없어야 한다
      assert.truthy(output:find("# HELP luagate_http_scanner_threats_total"))
      assert.truthy(output:find("# TYPE luagate_http_scanner_threats_total"))
      assert.is_nil(output:find("threat_type="), "0인 threat type은 출력되지 않아야 한다")
    end)

    it("policy reload counters 포함", function()
      output = get_metrics_output({
        ["metrics:policy_reload_total"] = 10,
        ["metrics:policy_reload_failures_total"] = 2,
      })

      assert.truthy(output:find("luagate_policy_reload_total"), "reload total이 있어야 한다")
      assert.truthy(output:find("luagate_policy_reload_total 10"), "reload total이 10이어야 한다")
      assert.truthy(output:find("luagate_policy_reload_failures_total 2"), "failures가 2여야 한다")
    end)

    it("policy loaded gauge: HTTP+Stream 모두 로드 시 각각 1 (ADR-008, DON-213)", function()
      output = get_metrics_output({})

      assert.truthy(output:find("luagate_policy_loaded"), "policy loaded gauge가 있어야 한다")
      assert.truthy(
        output:find('luagate_policy_loaded{subsystem="http"} 1'),
        "HTTP subsystem이 로드되면 1이어야 한다"
      )
      assert.truthy(
        output:find('luagate_policy_loaded{subsystem="stream"} 1'),
        "Stream subsystem이 로드되면 1이어야 한다"
      )
      -- ADR-006: version hash 라벨이 없어야 한다
      assert.is_nil(output:find("luagate_policy_version_info"), "version_info 메트릭은 없어야 한다 (ADR-006)")
    end)

    it("policy loaded gauge: HTTP-only 배포 시 stream 시계열 미출력 (DON-213 Codex 5차)", function()
      _G.ngx = make_ngx({
        var = { uri = "/metrics" },
        shared = {
          luagate_policy = make_shared_dict({ ["http:active_version"] = "v1" }),
          luagate_state = make_shared_dict(),
          luagate_metrics = make_shared_dict(),
          luagate_stream_metrics = make_shared_dict(),
          luagate_connections = make_shared_dict(),
          luagate_admin_ratelimit = make_shared_dict(),
        },
      })
      _G.ngx.req.get_method = function()
        return "GET"
      end
      router = load_router(make_auth_pass())

      router.dispatch()

      local printed = _G.ngx._get_printed()
      local out = table.concat(printed, "")
      assert.truthy(
        out:find('luagate_policy_loaded{subsystem="http"} 1'),
        "HTTP-only: http subsystem은 1이어야 한다"
      )
      assert.is_nil(
        out:find('luagate_policy_loaded{subsystem="stream"}'),
        "HTTP-only: stream 시계열이 출력되지 않아야 한다"
      )
    end)

    it("policy loaded gauge: HTTP-only 배포 시 http=1, stream 시계열 없음 (DON-213)", function()
      _G.ngx = make_ngx({
        var = { uri = "/metrics" },
        shared = {
          luagate_policy = make_shared_dict({ ["http:active_version"] = "v1" }),
          luagate_state = make_shared_dict(),
          luagate_metrics = make_shared_dict(),
          luagate_stream_metrics = make_shared_dict(),
          luagate_connections = make_shared_dict(),
          luagate_admin_ratelimit = make_shared_dict(),
        },
      })
      _G.ngx.req.get_method = function()
        return "GET"
      end
      router = load_router(make_auth_pass())

      router.dispatch()

      local printed = _G.ngx._get_printed()
      output = table.concat(printed, "")
      assert.truthy(
        output:find('luagate_policy_loaded{subsystem="http"} 1'),
        "HTTP-only 배포에서 http subsystem은 1이어야 한다"
      )
      assert.is_nil(
        output:find('luagate_policy_loaded{subsystem="stream"}'),
        "HTTP-only 배포에서 stream 시계열이 출력되지 않아야 한다"
      )
    end)

    it("policy loaded gauge: 둘 다 미로드 시 http=0, stream 시계열 없음 (DON-213)", function()
      _G.ngx = make_ngx({
        var = { uri = "/metrics" },
        shared = {
          luagate_policy = make_shared_dict({}),
          luagate_state = make_shared_dict(),
          luagate_metrics = make_shared_dict(),
          luagate_stream_metrics = make_shared_dict(),
          luagate_connections = make_shared_dict(),
          luagate_admin_ratelimit = make_shared_dict(),
        },
      })
      _G.ngx.req.get_method = function()
        return "GET"
      end
      router = load_router(make_auth_pass())

      router.dispatch()

      local printed = _G.ngx._get_printed()
      output = table.concat(printed, "")
      assert.truthy(
        output:find('luagate_policy_loaded{subsystem="http"} 0'),
        "미로드 시 http subsystem은 0이어야 한다"
      )
      assert.is_nil(
        output:find('luagate_policy_loaded{subsystem="stream"}'),
        "미로드 시 stream 시계열이 출력되지 않아야 한다"
      )
    end)

    it("policy loaded gauge: version='none'이면 http=0, stream 시계열 없음 (DON-213)", function()
      _G.ngx = make_ngx({
        var = { uri = "/metrics" },
        shared = {
          luagate_policy = make_shared_dict({
            ["http:active_version"] = "none",
            ["stream:active_version"] = "none",
          }),
          luagate_state = make_shared_dict(),
          luagate_metrics = make_shared_dict(),
          luagate_stream_metrics = make_shared_dict(),
          luagate_connections = make_shared_dict(),
          luagate_admin_ratelimit = make_shared_dict(),
        },
      })
      _G.ngx.req.get_method = function()
        return "GET"
      end
      router = load_router(make_auth_pass())

      router.dispatch()

      local printed = _G.ngx._get_printed()
      output = table.concat(printed, "")
      assert.truthy(
        output:find('luagate_policy_loaded{subsystem="http"} 0'),
        "version=none이면 http는 0이어야 한다"
      )
      assert.is_nil(
        output:find('luagate_policy_loaded{subsystem="stream"}'),
        "version=none이면 stream 시계열이 출력되지 않아야 한다"
      )
    end)

    it("upstream error counter 포함", function()
      output = get_metrics_output({
        ["metrics:http_upstream_errors_total"] = 17,
      })

      assert.truthy(output:find("luagate_http_upstream_errors_total"), "upstream errors가 있어야 한다")
      assert.truthy(output:find("luagate_http_upstream_errors_total 17"), "upstream errors가 17이어야 한다")
    end)

    it("모든 카운터 0일 때도 올바른 출력 (dict 비어있음)", function()
      output = get_metrics_output({}, {}, {})

      -- 기본 카운터는 0으로 출력
      assert.truthy(output:find('luagate_http_requests_total{action="allow"} 0'))
      assert.truthy(output:find('luagate_http_requests_total{action="deny"} 0'))
      assert.truthy(output:find("luagate_http_requests_denied_total 0"))
      assert.truthy(output:find("luagate_stream_connections_total 0"))
      assert.truthy(output:find('luagate_active_connections{type="http"} 0'))
    end)

    it("shared dict zone이 nil이어도 안전 처리", function()
      _G.ngx = make_ngx({
        var = { uri = "/metrics" },
        shared = {
          luagate_policy = nil,
          luagate_state = nil,
          luagate_metrics = nil,
          luagate_stream_metrics = nil,
          luagate_connections = nil,
          luagate_admin_ratelimit = make_shared_dict(),
        },
      })
      _G.ngx.req.get_method = function()
        return "GET"
      end
      router = load_router(make_auth_pass())

      -- nil dict여도 에러 없이 실행
      router.dispatch()

      assert.are.equal(200, _G.ngx.status)
      local printed = _G.ngx._get_printed()
      assert.is_true(#printed >= 1, "출력이 있어야 한다")
    end)

    it("HELP/TYPE 헤더가 Prometheus 표준 형식", function()
      output = get_metrics_output()

      -- 몇 가지 대표 메트릭의 HELP/TYPE 확인
      assert.truthy(output:find("# HELP luagate_http_requests_total"))
      assert.truthy(output:find("# TYPE luagate_http_requests_total counter"))
      assert.truthy(output:find("# HELP luagate_http_response_time_ms"))
      assert.truthy(output:find("# TYPE luagate_http_response_time_ms histogram"))
      assert.truthy(output:find("# HELP luagate_active_connections"))
      assert.truthy(output:find("# TYPE luagate_active_connections gauge"))
      assert.truthy(output:find("# HELP luagate_shared_dict_capacity_bytes"))
      assert.truthy(output:find("# TYPE luagate_shared_dict_capacity_bytes gauge"))
    end)

    it("모든 9개 latency bucket boundary 존재", function()
      output = get_metrics_output()

      local buckets = { "0.1", "0.5", "1", "5", "10", "50", "100", "500", "1000" }
      for _, b in ipairs(buckets) do
        assert.truthy(
          output:find('luagate_http_response_time_ms_bucket{le="' .. b .. '"}'),
          "bucket le=" .. b .. "가 있어야 한다"
        )
      end
      assert.truthy(output:find('le="%+Inf"'), "+Inf bucket이 있어야 한다")
    end)
  end)

  -- =========================================================================
  -- 핸들러 에러 전파 테스트
  -- =========================================================================
  describe("핸들러 에러 전파", function()
    it("핸들러 내부 에러는 nginx error handler로 전파된다 (pcall 없음)", function()
      _G.ngx = make_ngx()
      _G.ngx.var.uri = "/health"
      _G.ngx.req.get_method = function()
        return "GET"
      end
      -- ngx.say에서 에러 발생 시뮬레이션
      _G.ngx.say = function()
        error("say failed: broken pipe")
      end
      router = load_router(make_auth_pass())

      -- pcall 없이 에러가 전파됨 (실제 OpenResty에서는 nginx가 500 반환)
      local ok, err = pcall(router.dispatch)
      assert.is_false(ok, "핸들러 에러가 전파되어야 한다")
      assert.truthy(tostring(err):find("broken pipe"), "원본 에러 메시지가 보존되어야 한다")
    end)
  end)
end)
