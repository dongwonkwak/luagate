--- Unit tests for lua/luagate/http/ratelimit.lua
-- Implementation: lua/luagate/http/ratelimit.lua
-- Tests: tests/unit/http/ratelimit_spec.lua
--
-- ratelimit.lua depends on OpenResty ngx global, so we inject stubs.

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
    _data = data,
  }
end

--- Make a dict that fails on incr
local function make_failing_dict()
  return {
    get = function()
      return nil
    end,
    incr = function()
      return nil, "no memory"
    end,
  }
end

-- ---------------------------------------------------------------------------
-- ngx mock factory
-- ---------------------------------------------------------------------------
local function make_ngx(overrides)
  overrides = overrides or {}
  local logged = {}

  local mock = {
    var = overrides.var or {},
    shared = overrides.shared or {},
    ERR = 3,
    WARN = 4,
    INFO = 6,
    worker = {
      id = function()
        return 0
      end,
    },
    log = function(level, ...)
      local parts = {}
      for _, v in ipairs({ ... }) do
        parts[#parts + 1] = tostring(v)
      end
      logged[#logged + 1] = { level = level, msg = table.concat(parts, "") }
    end,
    now = function()
      return overrides.now or 1000.5
    end,
    -- expose for assertions
    _logged = logged,
  }

  return mock
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("http/ratelimit.lua", function()
  local ratelimit

  before_each(function()
    -- Reset module state between tests
    package.loaded["luagate.http.ratelimit"] = nil
  end)

  -- -----------------------------------------------------------------------
  -- make_key tests
  -- -----------------------------------------------------------------------
  describe("_make_key", function()
    before_each(function()
      _G.ngx = make_ngx()
      ratelimit = require("luagate.http.ratelimit")
    end)

    after_each(function()
      _G.ngx = nil
    end)

    it("generates correct key for IPv4", function()
      local key = ratelimit._make_key("api-rate-limit", "192.168.1.1", 42371)
      assert.are.equal("rl:api-rate-limit:192.168.1.1:42371", key)
    end)

    it("generates correct key for bracketed IPv6", function()
      local key = ratelimit._make_key("api-rate-limit", "[::1]", 42371)
      assert.are.equal("rl:api-rate-limit:[::1]:42371", key)
    end)
  end)

  -- -----------------------------------------------------------------------
  -- format_scope_key tests
  -- -----------------------------------------------------------------------
  describe("_format_scope_key", function()
    before_each(function()
      _G.ngx = make_ngx()
      ratelimit = require("luagate.http.ratelimit")
    end)

    after_each(function()
      _G.ngx = nil
    end)

    it("returns IPv4 as-is", function()
      assert.are.equal("192.168.1.1", ratelimit._format_scope_key("192.168.1.1"))
    end)

    it("brackets IPv6 loopback", function()
      assert.are.equal("[::1]", ratelimit._format_scope_key("::1"))
    end)

    it("brackets full IPv6 address", function()
      assert.are.equal("[2001:db8::1]", ratelimit._format_scope_key("2001:db8::1"))
    end)

    it("returns empty string for nil", function()
      assert.are.equal("", ratelimit._format_scope_key(nil))
    end)
  end)

  -- -----------------------------------------------------------------------
  -- check() — shared dict unavailable (fail-closed 503)
  -- -----------------------------------------------------------------------
  describe("check — shared dict unavailable", function()
    before_each(function()
      _G.ngx = make_ngx({ shared = {} }) -- no luagate_ratelimit
      ratelimit = require("luagate.http.ratelimit")
    end)

    after_each(function()
      _G.ngx = nil
    end)

    it("returns 503 with ratelimit_unavailable error", function()
      local result = ratelimit.check("rule-1", "10.0.0.1", {
        requests = 10,
        window = 60,
        scope = "client_ip",
      })
      assert.is_false(result.allowed)
      assert.are.equal(503, result.status)
      assert.are.equal("ratelimit_unavailable", result.err)
    end)
  end)

  -- -----------------------------------------------------------------------
  -- check() — incr failure (fail-closed 503)
  -- -----------------------------------------------------------------------
  describe("check — incr failure", function()
    before_each(function()
      _G.ngx = make_ngx({
        shared = { luagate_ratelimit = make_failing_dict() },
      })
      ratelimit = require("luagate.http.ratelimit")
    end)

    after_each(function()
      _G.ngx = nil
    end)

    it("returns 503 with ratelimit_incr_failed error", function()
      local result = ratelimit.check("rule-1", "10.0.0.1", {
        requests = 10,
        window = 60,
        scope = "client_ip",
      }, 1000.0)
      assert.is_false(result.allowed)
      assert.are.equal(503, result.status)
      assert.are.equal("ratelimit_incr_failed", result.err)
    end)
  end)

  -- -----------------------------------------------------------------------
  -- check() — request allowed (under limit)
  -- -----------------------------------------------------------------------
  describe("check — request allowed", function()
    local dict_data, mock_dict

    before_each(function()
      dict_data = {}
      mock_dict = make_ratelimit_dict(dict_data)
      _G.ngx = make_ngx({
        shared = { luagate_ratelimit = mock_dict },
        now = 1000.5,
      })
      ratelimit = require("luagate.http.ratelimit")
    end)

    after_each(function()
      _G.ngx = nil
    end)

    it("allows first request and returns quota info", function()
      local result = ratelimit.check("api-limit", "10.0.0.1", {
        requests = 100,
        window = 60,
        scope = "client_ip",
      }, 1000.5)
      assert.is_true(result.allowed)
      assert.are.equal(100, result.limit)
      assert.are.equal(99, result.remaining) -- 100 - ceil(1) = 99
      assert.is_number(result.reset)
      assert.is_nil(result.err)
    end)

    it("correctly computes remaining after multiple requests", function()
      -- Simulate 5 previous requests in the current slot
      local window = 60
      local now = 1000.5
      local slot = math.floor(now / window)
      local key = "rl:api-limit:10.0.0.1:" .. tostring(slot)
      dict_data[key] = 4 -- 4 existing + 1 from check = 5

      local result = ratelimit.check("api-limit", "10.0.0.1", {
        requests = 100,
        window = window,
        scope = "client_ip",
      }, now)
      assert.is_true(result.allowed)
      assert.are.equal(100, result.limit)
      -- weighted = 0 * (1 - fraction) + 5 = 5, remaining = 100 - ceil(5) = 95
      assert.are.equal(95, result.remaining)
    end)
  end)

  -- -----------------------------------------------------------------------
  -- check() — rate limit exceeded (429)
  -- -----------------------------------------------------------------------
  describe("check — rate limit exceeded", function()
    local dict_data, mock_dict

    before_each(function()
      dict_data = {}
      mock_dict = make_ratelimit_dict(dict_data)
      _G.ngx = make_ngx({
        shared = { luagate_ratelimit = mock_dict },
      })
      ratelimit = require("luagate.http.ratelimit")
    end)

    after_each(function()
      _G.ngx = nil
    end)

    it("rejects when weighted count exceeds limit", function()
      -- Pre-fill current slot to be over limit
      local window = 60
      local now = 1020.0 -- 1/3 into slot
      local slot = math.floor(now / window)
      local key = "rl:my-rule:10.0.0.1:" .. tostring(slot)
      dict_data[key] = 10 -- will become 11 after incr (> 10 limit)

      local result = ratelimit.check("my-rule", "10.0.0.1", {
        requests = 10,
        window = window,
        scope = "client_ip",
      }, now)
      assert.is_false(result.allowed)
      assert.are.equal(429, result.status)
      assert.are.equal(0, result.remaining)
      assert.is_number(result.retry_after)
      assert.is_true(result.retry_after >= 1)
      assert.are.equal(10, result.limit)
    end)

    it("includes previous slot weight in calculation", function()
      local window = 60
      local now = 1020.0 -- 20s into slot
      local slot = math.floor(now / window)
      local prev_slot = slot - 1

      -- Previous slot had 8 requests, current slot has 4 (will be 5 after incr)
      dict_data["rl:my-rule:10.0.0.1:" .. tostring(prev_slot)] = 8
      dict_data["rl:my-rule:10.0.0.1:" .. tostring(slot)] = 4

      -- elapsed_fraction = 20/60 = 1/3
      -- weighted = 8 * (1 - 1/3) + 5 = 8 * 2/3 + 5 = 5.333 + 5 = 10.333
      -- limit = 10 → exceeded

      local result = ratelimit.check("my-rule", "10.0.0.1", {
        requests = 10,
        window = window,
        scope = "client_ip",
      }, now)
      assert.is_false(result.allowed)
      assert.are.equal(429, result.status)
    end)
  end)

  -- -----------------------------------------------------------------------
  -- check() — IPv6 bracketing
  -- -----------------------------------------------------------------------
  describe("check — IPv6 scope key", function()
    local dict_data, mock_dict

    before_each(function()
      dict_data = {}
      mock_dict = make_ratelimit_dict(dict_data)
      _G.ngx = make_ngx({
        shared = { luagate_ratelimit = mock_dict },
        now = 1000.0,
      })
      ratelimit = require("luagate.http.ratelimit")
    end)

    after_each(function()
      _G.ngx = nil
    end)

    it("brackets IPv6 in shared dict key", function()
      local result = ratelimit.check("my-rule", "::1", {
        requests = 100,
        window = 60,
        scope = "client_ip",
      }, 1000.0)

      assert.is_true(result.allowed)
      -- Verify the key was created with brackets
      local slot = math.floor(1000.0 / 60)
      local expected_key = "rl:my-rule:[::1]:" .. tostring(slot)
      assert.is_not_nil(dict_data[expected_key])
    end)

    it("brackets full IPv6 address", function()
      ratelimit.check("my-rule", "2001:db8::1", {
        requests = 100,
        window = 60,
        scope = "client_ip",
      }, 1000.0)

      local slot = math.floor(1000.0 / 60)
      local expected_key = "rl:my-rule:[2001:db8::1]:" .. tostring(slot)
      assert.is_not_nil(dict_data[expected_key])
    end)
  end)

  -- -----------------------------------------------------------------------
  -- check() — Retry-After calculation
  -- -----------------------------------------------------------------------
  describe("check — Retry-After", function()
    local dict_data, mock_dict

    before_each(function()
      dict_data = {}
      mock_dict = make_ratelimit_dict(dict_data)
      _G.ngx = make_ngx({
        shared = { luagate_ratelimit = mock_dict },
      })
      ratelimit = require("luagate.http.ratelimit")
    end)

    after_each(function()
      _G.ngx = nil
    end)

    it("calculates retry_after as ceiling of remaining slot time", function()
      local window = 60
      local now = 1020.5 -- 20.5s into slot, 39.5s remaining
      local slot = math.floor(now / window)
      local key = "rl:r1:10.0.0.1:" .. tostring(slot)
      dict_data[key] = 99 -- will become 100 after incr

      local result = ratelimit.check("r1", "10.0.0.1", {
        requests = 10,
        window = window,
        scope = "client_ip",
      }, now)

      assert.is_false(result.allowed)
      -- slot_end = (slot + 1) * 60
      -- retry_after = ceil(slot_end - now) = ceil(slot_end - 1020.5)
      local expected_slot_end = (slot + 1) * window
      local expected_retry = math.max(1, math.ceil(expected_slot_end - now))
      assert.are.equal(expected_retry, result.retry_after)
    end)

    it("returns minimum 1 second for retry_after", function()
      local window = 60
      -- Place now right at slot boundary so remaining = 0
      local now = 60.0 * 17 -- exact slot boundary
      local slot = math.floor(now / window)
      local key = "rl:r1:10.0.0.1:" .. tostring(slot)
      dict_data[key] = 99

      local result = ratelimit.check("r1", "10.0.0.1", {
        requests = 10,
        window = window,
        scope = "client_ip",
      }, now)

      assert.is_false(result.allowed)
      assert.is_true(result.retry_after >= 1)
    end)
  end)

  -- -----------------------------------------------------------------------
  -- check() — sliding window weighted count accuracy
  -- -----------------------------------------------------------------------
  describe("check — sliding window accuracy", function()
    local dict_data, mock_dict

    before_each(function()
      dict_data = {}
      mock_dict = make_ratelimit_dict(dict_data)
      _G.ngx = make_ngx({
        shared = { luagate_ratelimit = mock_dict },
      })
      ratelimit = require("luagate.http.ratelimit")
    end)

    after_each(function()
      _G.ngx = nil
    end)

    it("previous slot weight decreases as time progresses", function()
      local window = 60
      -- At halfway through the current slot
      local now = 60 * 17 + 30 -- 30s into slot
      local slot = math.floor(now / window)
      local prev_slot = slot - 1

      -- 10 requests in previous slot, 0 in current (will be 1 after incr)
      dict_data["rl:r1:10.0.0.1:" .. tostring(prev_slot)] = 10

      -- weighted = 10 * (1 - 0.5) + 1 = 5 + 1 = 6
      local result = ratelimit.check("r1", "10.0.0.1", {
        requests = 100,
        window = window,
        scope = "client_ip",
      }, now)

      assert.is_true(result.allowed)
      -- remaining = 100 - ceil(6) = 94
      assert.are.equal(94, result.remaining)
    end)

    it("near end of slot, previous slot has almost zero weight", function()
      local window = 60
      -- 59s into slot (almost at the end)
      local now = 60 * 17 + 59
      local slot = math.floor(now / window)
      local prev_slot = slot - 1

      dict_data["rl:r1:10.0.0.1:" .. tostring(prev_slot)] = 100

      -- elapsed_fraction = 59/60 ≈ 0.983
      -- weighted = 100 * (1 - 59/60) + 1 = 100 * 1/60 + 1 ≈ 1.667 + 1 = 2.667
      local result = ratelimit.check("r1", "10.0.0.1", {
        requests = 10,
        window = window,
        scope = "client_ip",
      }, now)

      assert.is_true(result.allowed)
    end)
  end)
end)
