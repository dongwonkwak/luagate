--- Unit tests for lua/luagate/admin/ratelimit.lua
-- Implementation: lua/luagate/admin/ratelimit.lua
-- Tests: tests/unit/admin/ratelimit_spec.lua
--
-- ratelimit.lua는 OpenResty ngx 전역에 의존하므로
-- busted (Lua 5.4) 환경에서 stub을 주입한다.

-- ---------------------------------------------------------------------------
-- cjson.safe stub (dkjson wrapper — LuaJIT 없는 busted 환경)
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
-- Shared dict mock with incr + TTL support
-- ---------------------------------------------------------------------------
local function make_ratelimit_dict(data)
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
    set = function(_, key, value)
      data[key] = value
      return true
    end,
    capacity = function()
      return 1048576
    end,
    free_space = function()
      return 838860
    end,
    -- Expose internal data for assertions
    _data = data,
  }
end

-- ---------------------------------------------------------------------------
-- ngx mock factory
-- ---------------------------------------------------------------------------
local function make_ngx(overrides)
  local exited_with = nil
  local logged = {}
  local said = {}
  local current_method = "GET" -- default method

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
      luagate_admin_ratelimit = make_ratelimit_dict(),
    },
    worker = {
      id = function()
        return 0
      end,
    },
    req = {
      get_method = function()
        return current_method
      end,
    },
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
    now = function()
      return 1700000100.5 -- fixed time for deterministic tests
    end,
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
  mock._set_method = function(m)
    current_method = m
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
-- Module load helper
-- ---------------------------------------------------------------------------
local _saved_ngx = _G.ngx
_G.ngx = make_ngx()

local ratelimit

local function load_ratelimit()
  package.loaded["luagate.admin.ratelimit"] = nil
  return require("luagate.admin.ratelimit")
end

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------
teardown(function()
  _G.ngx = _saved_ngx
  package.preload["cjson.safe"] = nil
  package.loaded["cjson.safe"] = nil
  package.loaded["luagate.admin.ratelimit"] = nil
end)

-- ===========================================================================
-- Tests
-- ===========================================================================
describe("ratelimit.check", function()
  before_each(function()
    _G.ngx = make_ngx()
    ratelimit = load_ratelimit()
  end)

  describe("/health exemption", function()
    it("GET /health 요청은 rate limit 미적용", function()
      _G.ngx.var.uri = "/health"
      _G.ngx._set_method("GET")

      local result = ratelimit.check()

      assert.is_true(result)
      assert.is_nil(_G.ngx._get_exited())
    end)

    it("POST /health 요청은 rate limit 적용 (GET만 면제)", function()
      _G.ngx.var.uri = "/health"
      _G.ngx._set_method("POST")

      -- Pre-populate to exceed limit so we can verify rate limit kicks in
      local now = _G.ngx.now()
      local current_slot = math.floor(now / 60)
      local key = "rl:127.0.0.1:" .. tostring(current_slot)
      _G.ngx.shared.luagate_admin_ratelimit._data[key] = 30

      ratelimit = load_ratelimit()
      local result = ratelimit.check()

      assert.is_false(result)
      assert.are.equal(429, _G.ngx.status)
    end)

    it("DELETE /health 요청은 rate limit 적용 (GET만 면제)", function()
      _G.ngx.var.uri = "/health"
      _G.ngx._set_method("DELETE")

      local now = _G.ngx.now()
      local current_slot = math.floor(now / 60)
      local key = "rl:127.0.0.1:" .. tostring(current_slot)
      _G.ngx.shared.luagate_admin_ratelimit._data[key] = 30

      ratelimit = load_ratelimit()
      local result = ratelimit.check()

      assert.is_false(result)
      assert.are.equal(429, _G.ngx.status)
    end)
  end)

  describe("shared dict unavailable", function()
    it("dict가 nil이면 503 반환 (fail-closed)", function()
      _G.ngx.shared.luagate_admin_ratelimit = nil
      ratelimit = load_ratelimit()

      local result = ratelimit.check()

      assert.is_false(result)
      assert.are.equal(503, _G.ngx.status)
      assert.are.equal(503, _G.ngx._get_exited())
    end)
  end)

  describe("normal operation (under limit)", function()
    it("첫 번째 요청은 허용된다", function()
      local result = ratelimit.check()

      assert.is_true(result)
      assert.is_nil(_G.ngx._get_exited())
    end)

    it("30번째 요청도 허용된다 (limit=30, incr-then-check: 30 > 30 = false)", function()
      -- Pre-populate current window with 29 requests
      -- After incr: new_val = 30, weighted = 30, 30 > 30 = false -> allow
      local now = _G.ngx.now()
      local current_slot = math.floor(now / 60)
      local key = "rl:127.0.0.1:" .. tostring(current_slot)
      _G.ngx.shared.luagate_admin_ratelimit._data[key] = 29

      ratelimit = load_ratelimit()
      local result = ratelimit.check()

      assert.is_true(result)
      -- Counter should be incremented to 30
      assert.are.equal(30, _G.ngx.shared.luagate_admin_ratelimit._data[key])
    end)

    it("29번째 요청도 허용된다", function()
      -- Pre-populate current window with 28 requests
      local now = _G.ngx.now()
      local current_slot = math.floor(now / 60)
      local key = "rl:127.0.0.1:" .. tostring(current_slot)
      _G.ngx.shared.luagate_admin_ratelimit._data[key] = 28

      ratelimit = load_ratelimit()
      local result = ratelimit.check()

      assert.is_true(result)
      -- Counter should be incremented to 29
      assert.are.equal(29, _G.ngx.shared.luagate_admin_ratelimit._data[key])
    end)
  end)

  describe("rate limit exceeded", function()
    it("31번째 요청에서 429 반환 (incr-then-check: 30+1=31 > 30)", function()
      -- Pre-populate: 30 requests in current window
      -- After incr: new_val = 31, 31 > 30 -> deny
      local now = _G.ngx.now()
      local current_slot = math.floor(now / 60)
      local key = "rl:127.0.0.1:" .. tostring(current_slot)
      _G.ngx.shared.luagate_admin_ratelimit._data[key] = 30

      ratelimit = load_ratelimit()
      local result = ratelimit.check()

      assert.is_false(result)
      assert.are.equal(429, _G.ngx.status)
      assert.are.equal(429, _G.ngx._get_exited())
    end)

    it("off-by-one 경계: 정확히 30개일 때 허용, 31개일 때 거부", function()
      local now = _G.ngx.now()
      local current_slot = math.floor(now / 60)
      local key = "rl:127.0.0.1:" .. tostring(current_slot)

      -- 29 pre-populated -> incr to 30, 30 > 30 = false -> allow
      _G.ngx.shared.luagate_admin_ratelimit._data[key] = 29
      ratelimit = load_ratelimit()
      local result1 = ratelimit.check()
      assert.is_true(result1, "30th request (weighted=30) should be allowed")
      assert.are.equal(30, _G.ngx.shared.luagate_admin_ratelimit._data[key])

      -- Now counter is 30 -> incr to 31, 31 > 30 = true -> deny
      _G.ngx._reset_tracking()
      ratelimit = load_ratelimit()
      local result2 = ratelimit.check()
      assert.is_false(result2, "31st request (weighted=31) should be denied")
      assert.are.equal(429, _G.ngx.status)
    end)

    it("현재 window 초과 시 Retry-After가 다음 weighted-window 회복 시점까지 반영", function()
      local now = _G.ngx.now()
      local current_slot = math.floor(now / 60)
      local key = "rl:127.0.0.1:" .. tostring(current_slot)
      _G.ngx.shared.luagate_admin_ratelimit._data[key] = 30

      ratelimit = load_ratelimit()
      ratelimit.check()

      assert.is_not_nil(_G.ngx.header["Retry-After"])
      local retry = tonumber(_G.ngx.header["Retry-After"])
      assert.are.equal(64, retry)
    end)

    it("429 응답 body에 rate_limited 에러 포함", function()
      local now = _G.ngx.now()
      local current_slot = math.floor(now / 60)
      local key = "rl:127.0.0.1:" .. tostring(current_slot)
      _G.ngx.shared.luagate_admin_ratelimit._data[key] = 30

      ratelimit = load_ratelimit()
      ratelimit.check()

      local said = _G.ngx._get_said()
      assert.is_true(#said >= 1)
      local dkjson = require("dkjson")
      local body = dkjson.decode(said[1])
      assert.are.equal("rate_limited", body.error)
    end)
  end)

  describe("sliding window calculation", function()
    it("이전 window 카운터도 가중치 반영 (incr-then-check)", function()
      -- now = 1700000100.5
      -- current_slot = floor(1700000100.5 / 60) = 28333335
      -- window_start = 28333335 * 60 = 1700000100
      -- elapsed = 0.5s, elapsed_fraction = 0.5/60 = 0.00833...
      -- After incr: curr becomes 10+1=11
      -- weighted = prev * (1 - 0.00833) + new_curr = 20 * 0.99167 + 11 = 30.83 > 30 -> deny
      -- So we use lower counts to test allow case
      local now = _G.ngx.now()
      local current_slot = math.floor(now / 60)
      local previous_slot = current_slot - 1

      local curr_key = "rl:127.0.0.1:" .. tostring(current_slot)
      local prev_key = "rl:127.0.0.1:" .. tostring(previous_slot)

      -- 20 in previous window + 9 in current
      -- After incr: new_val = 10
      -- weighted ~= 20 * 0.99167 + 10 = 29.83 < 30 -> allow
      _G.ngx.shared.luagate_admin_ratelimit._data[prev_key] = 20
      _G.ngx.shared.luagate_admin_ratelimit._data[curr_key] = 9

      ratelimit = load_ratelimit()
      local result = ratelimit.check()

      assert.is_true(result, "weighted count ~29.83 should be under limit 30")
    end)

    it("이전 window 높은 카운터 + 현재 window로 초과 (incr-then-check)", function()
      local now = _G.ngx.now()
      local current_slot = math.floor(now / 60)
      local previous_slot = current_slot - 1

      local curr_key = "rl:127.0.0.1:" .. tostring(current_slot)
      local prev_key = "rl:127.0.0.1:" .. tostring(previous_slot)

      -- 25 in previous + 5 in current
      -- After incr: new_val = 6
      -- weighted ~= 25 * 0.99167 + 6 = 30.79 > 30 -> deny
      _G.ngx.shared.luagate_admin_ratelimit._data[prev_key] = 25
      _G.ngx.shared.luagate_admin_ratelimit._data[curr_key] = 5

      ratelimit = load_ratelimit()
      local result = ratelimit.check()

      assert.is_false(result, "weighted count ~30.79 should exceed limit 30")
      assert.are.equal(429, _G.ngx.status)
      assert.are.equal("5", _G.ngx.header["Retry-After"])
    end)
  end)

  describe("IP isolation", function()
    it("다른 IP의 카운터는 서로 영향 없음", function()
      local now = _G.ngx.now()
      local current_slot = math.floor(now / 60)

      -- IP 10.0.0.1 has 30 requests (rate limited)
      _G.ngx.shared.luagate_admin_ratelimit._data["rl:10.0.0.1:" .. tostring(current_slot)] = 30

      -- But our IP (127.0.0.1) has 0 requests
      _G.ngx.var.remote_addr = "127.0.0.1"

      ratelimit = load_ratelimit()
      local result = ratelimit.check()

      assert.is_true(result, "다른 IP의 rate limit은 영향 없어야 한다")
    end)
  end)

  describe("incr failure", function()
    it("incr 실패 시 503 반환 (fail-closed)", function()
      -- Override dict with failing incr
      _G.ngx.shared.luagate_admin_ratelimit = {
        get = function()
          return nil
        end,
        incr = function()
          return nil, "no memory"
        end,
        capacity = function()
          return 1048576
        end,
        free_space = function()
          return 0
        end,
      }

      ratelimit = load_ratelimit()
      local result = ratelimit.check()

      assert.is_false(result)
      assert.are.equal(503, _G.ngx.status)
      assert.are.equal(503, _G.ngx._get_exited())
    end)
  end)
end)

describe("ratelimit.get_status", function()
  before_each(function()
    _G.ngx = make_ngx()
    ratelimit = load_ratelimit()
  end)

  it("현재 상태 정보 반환", function()
    local now = _G.ngx.now()
    local current_slot = math.floor(now / 60)
    local key = "rl:127.0.0.1:" .. tostring(current_slot)
    _G.ngx.shared.luagate_admin_ratelimit._data[key] = 10

    local status = ratelimit.get_status("127.0.0.1")

    assert.are.equal(10, status.current_count)
    assert.are.equal(0, status.previous_count)
    assert.are.equal(60, status.window_size)
    assert.are.equal(30, status.max_requests)
    assert.is_true(status.remaining > 0)
  end)

  it("dict 없으면 error 반환", function()
    _G.ngx.shared.luagate_admin_ratelimit = nil
    ratelimit = load_ratelimit()

    local status = ratelimit.get_status("127.0.0.1")

    assert.are.equal("shared dict unavailable", status.error)
  end)
end)

describe("ratelimit constants", function()
  before_each(function()
    _G.ngx = make_ngx()
    ratelimit = load_ratelimit()
  end)

  it("WINDOW_SIZE = 60", function()
    assert.are.equal(60, ratelimit._WINDOW_SIZE)
  end)

  it("MAX_REQUESTS = 30", function()
    assert.are.equal(30, ratelimit._MAX_REQUESTS)
  end)

  it("DICT_NAME은 luagate_ prefix 사용", function()
    assert.truthy(ratelimit._DICT_NAME:find("^luagate_"), "zone 이름은 luagate_ prefix 필수")
  end)

  it("HEALTH_PATH = /health", function()
    assert.are.equal("/health", ratelimit._HEALTH_PATH)
  end)
end)
