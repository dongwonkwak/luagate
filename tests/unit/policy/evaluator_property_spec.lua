--- Property-based tests for lua/luagate/policy/evaluator.lua
-- DON-177: first-match-wins 불변식 랜덤 검증.
--
-- 각 불변식을 1100회 이상 랜덤 반복하며 검증한다.
-- LUAGATE_PBT_SEED 환경변수로 시드를 지정하면 실패 재현 가능.
--
-- cjson은 LuaJIT 전용 .so이므로 Lua 5.4 busted 환경에서 dkjson으로 stub한다.
package.preload["cjson"] = function()
  local dkjson = require("dkjson")
  return {
    decode = dkjson.decode,
    encode = dkjson.encode,
  }
end

-- ngx 전역 stub
_G.ngx = nil

local evaluator = require("luagate.policy.evaluator")
local conflict = require("luagate.policy.conflict")

-- ---------------------------------------------------------------------------
-- Portable xorshift32 PRNG (works on Lua 5.1/5.4/LuaJIT)
-- ---------------------------------------------------------------------------
local RNG = {}
RNG.__index = RNG

function RNG.new(seed)
  local self = setmetatable({}, RNG)
  self.state = seed % (2 ^ 32)
  if self.state == 0 then
    self.state = 1
  end
  return self
end

--- Return a pseudo-random integer in [0, 2^32 - 1].
function RNG:next_u32()
  local s = self.state
  -- xorshift32 algorithm using multiplication-based bit shifting
  -- (Lua 5.1 compatible — no bitwise operators)
  s = (s * 8 + s) % (2 ^ 32) -- approximate xor-shift via multiply
  -- Use a different LCG-style mixing for portability
  s = (s * 1103515245 + 12345) % (2 ^ 32)
  self.state = s
  return s
end

--- Return a pseudo-random integer in [lo, hi].
function RNG:int(lo, hi)
  return lo + (self:next_u32() % (hi - lo + 1))
end

--- Return true with probability p (0..1).
function RNG:chance(p)
  return (self:next_u32() / (2 ^ 32)) < p
end

--- Pick a random element from a list.
function RNG:pick(list)
  return list[self:int(1, #list)]
end

-- ---------------------------------------------------------------------------
-- Random generators
-- ---------------------------------------------------------------------------

local PATH_SEGMENTS = { "api", "v1", "v2", "users", "admin", "health", "data", "auth" }
local METHODS = { "GET", "POST", "PUT", "DELETE", "PATCH" }
local ACTIONS = { "allow", "deny" }
local HOSTS = { "example.com", "api.example.com", "admin.example.com", "test.example.com", "cdn.example.com" }
local HOST_WILDCARDS = { "*.example.com", "*.api.example.com", "*.test.example.com" }
local CIDRS = {
  { cidr = "10.0.0.0/8", sample_ip = "10.%d.%d.%d" },
  { cidr = "192.168.1.0/24", sample_ip = "192.168.1.%d" },
  { cidr = "172.16.0.0/12", sample_ip = "172.%d.%d.%d" },
  { cidr = "192.168.0.0/16", sample_ip = "192.168.%d.%d" },
}

--- Generate a random path (exact or prefix wildcard).
local function gen_path(rng)
  local depth = rng:int(1, 3)
  local parts = {}
  for i = 1, depth do
    parts[i] = rng:pick(PATH_SEGMENTS)
  end
  local base = "/" .. table.concat(parts, "/")
  if rng:chance(0.4) then
    return base .. "/*" -- prefix wildcard
  end
  return base
end

--- Generate a random host scope (exact or wildcard).
local function gen_host(rng)
  if rng:chance(0.3) then
    return rng:pick(HOST_WILDCARDS)
  end
  return rng:pick(HOSTS)
end

--- Generate a random CIDR and a sample IP that falls within it.
-- Returns cidr_string, matching_ip_string
local function gen_cidr_and_ip(rng)
  local entry = rng:pick(CIDRS)
  -- Generate octets for sample IP format string
  local ip = entry.sample_ip
  -- Count %d placeholders and fill with random octets
  local filled = ip:gsub("%%d", function()
    return tostring(rng:int(0, 255))
  end)
  -- For 172.16.0.0/12, second octet must be 16-31
  if entry.cidr == "172.16.0.0/12" then
    local parts = {}
    for part in filled:gmatch("[^.]+") do
      parts[#parts + 1] = part
    end
    parts[2] = tostring(rng:int(16, 31))
    filled = table.concat(parts, ".")
  end
  return entry.cidr, filled
end

--- Generate a random HTTP rule.
local function gen_rule(rng, id)
  local rule = {
    id = "rule-" .. id,
    priority = rng:int(1, 10),
    action = rng:pick(ACTIONS),
    enabled = true,
  }

  -- scope: sometimes nil (catch-all), sometimes with path
  if rng:chance(0.85) then
    rule.scope = { path = gen_path(rng) }
    -- optionally add method
    if rng:chance(0.3) then
      rule.scope.method = rng:pick(METHODS)
    end
    -- optionally add host
    if rng:chance(0.25) then
      rule.scope.host = gen_host(rng)
    end
    -- optionally add src_ip_cidr
    if rng:chance(0.2) then
      local cidr, _ = gen_cidr_and_ip(rng)
      rule.scope.src_ip_cidr = cidr
    end
  end

  return rule
end

--- Generate a random request context that could match some rules.
local function gen_request(rng)
  local _, sample_ip = gen_cidr_and_ip(rng)
  return {
    path = gen_path(rng):gsub("/%*$", ""), -- strip trailing wildcard for request
    method = rng:pick(METHODS),
    host = rng:pick(HOSTS),
    src_ip = sample_ip,
  }
end

--- Independent stable sort by (priority ASC, id ASC).
-- Does NOT share code with evaluator.compile() to ensure true independence.
local function independent_stable_sort(rules)
  for i, rule in ipairs(rules) do
    rule._ref_sort_idx = i
  end
  table.sort(rules, function(a, b)
    if a.priority ~= b.priority then
      return a.priority < b.priority
    end
    if a.id ~= b.id then
      return a.id < b.id
    end
    return a._ref_sort_idx < b._ref_sort_idx
  end)
  for _, rule in ipairs(rules) do
    rule._ref_sort_idx = nil
  end
end

--- Reference evaluator: independently filter, sort, and evaluate raw rules.
-- This is an independent implementation to cross-check evaluator.evaluate().
-- Accepts RAW rules (before compile) to avoid sharing compile() regressions.
local function reference_evaluate(raw_rules, request_ctx, default_action)
  -- Step 1: filter enabled rules independently
  local enabled = {}
  for _, rule in ipairs(raw_rules) do
    if rule.enabled ~= false then
      enabled[#enabled + 1] = rule
    end
  end

  -- Step 2: sort by (priority ASC, id ASC) independently
  independent_stable_sort(enabled)

  -- Step 3: first-match evaluation
  for _, rule in ipairs(enabled) do
    local scope = rule.scope
    local matches = true

    if scope ~= nil then
      -- path matching
      if scope.path ~= nil then
        local sp = scope.path
        local rp = request_ctx.path
        if rp == nil then
          matches = false
        else
          local n = #sp
          if n >= 2 and sp:sub(n - 1) == "/*" then
            local prefix = sp:sub(1, n - 2)
            if rp ~= prefix and rp:sub(1, #prefix + 1) ~= prefix .. "/" then
              matches = false
            end
          else
            if sp ~= rp then
              matches = false
            end
          end
        end
      end

      -- method matching
      if matches and scope.method ~= nil then
        local rm = request_ctx.method
        if rm == nil then
          matches = false
        else
          if type(scope.method) == "string" then
            if scope.method:upper() ~= rm:upper() then
              matches = false
            end
          elseif type(scope.method) == "table" then
            local found = false
            for _, m in ipairs(scope.method) do
              if m:upper() == rm:upper() then
                found = true
                break
              end
            end
            if not found then
              matches = false
            end
          end
        end
      end

      -- host matching
      if matches and scope.host ~= nil then
        local rh = request_ctx.host
        if rh == nil then
          matches = false
        else
          if scope.host:sub(1, 2) == "*." then
            local suffix = scope.host:sub(2) -- ".example.com"
            local sn = #suffix
            if rh == suffix:sub(2) then
              matches = false -- bare domain, no subdomain
            elseif rh:sub(-sn) ~= suffix then
              matches = false
            end
          else
            if scope.host ~= rh then
              matches = false
            end
          end
        end
      end

      -- src_ip_cidr matching
      if matches and scope.src_ip_cidr ~= nil then
        local req_ip = request_ctx.src_ip
        if req_ip == nil then
          matches = false
        else
          local net_str, prefix_str = scope.src_ip_cidr:match("^(.+)/(%d+)$")
          if not net_str then
            matches = false
          else
            local prefix = tonumber(prefix_str)
            if not prefix or prefix < 0 or prefix > 32 then
              matches = false
            else
              -- ip_to_uint32 inline
              local function to_u32(ip)
                local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
                if not a then
                  return nil
                end
                a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
                if a > 255 or b > 255 or c > 255 or d > 255 then
                  return nil
                end
                return a * 16777216 + b * 65536 + c * 256 + d
              end
              local net_int = to_u32(net_str)
              local req_int = to_u32(req_ip)
              if not net_int or not req_int then
                matches = false
              elseif prefix ~= 0 then
                local shift = 32 - prefix
                local divisor = 2 ^ shift
                if math.floor(net_int / divisor) ~= math.floor(req_int / divisor) then
                  matches = false
                end
              end
            end
          end
        end
      end
    end

    if matches then
      return { action = rule.action, matched_rule = rule.id, decision_source = "rule" }
    end
  end

  return { action = default_action, matched_rule = nil, decision_source = "default" }
end

-- ---------------------------------------------------------------------------
-- Test configuration
-- ---------------------------------------------------------------------------

local ITERATIONS = 1100
local env_seed = os.getenv("LUAGATE_PBT_SEED")
local BASE_SEED = env_seed and tonumber(env_seed) or os.time()

-- ---------------------------------------------------------------------------
-- Property tests
-- ---------------------------------------------------------------------------

describe("평가기 속성 기반 테스트 (seed=" .. BASE_SEED .. ")", function()
  -- -----------------------------------------------------------------------
  -- 불변식 1: first-match-wins — 평가기가 참조 구현과 일치
  -- -----------------------------------------------------------------------
  describe("first-match-wins 불변식", function()
    it("평가기 결과가 독립 참조 구현과 일치한다 (" .. ITERATIONS .. "회 반복)", function()
      local rng = RNG.new(BASE_SEED + 1)

      for iter = 1, ITERATIONS do
        local num_rules = rng:int(1, 50)
        local rules = {}
        for i = 1, num_rules do
          rules[i] = gen_rule(rng, i)
        end

        local default_action = rng:pick(ACTIONS)
        local compiled = evaluator.compile(rules)
        local request = gen_request(rng)

        local actual = evaluator.evaluate(compiled, request, default_action)
        local expected = reference_evaluate(rules, request, default_action)

        assert.are.equal(
          expected.action,
          actual.action,
          string.format(
            "Iter %d (seed=%d): action mismatch. expected=%s, got=%s, matched_rule: expected=%s, got=%s",
            iter,
            BASE_SEED + 1,
            expected.action,
            actual.action,
            tostring(expected.matched_rule),
            tostring(actual.matched_rule)
          )
        )
        assert.are.equal(
          expected.matched_rule,
          actual.matched_rule,
          string.format(
            "Iter %d (seed=%d): matched_rule mismatch. expected=%s, got=%s",
            iter,
            BASE_SEED + 1,
            tostring(expected.matched_rule),
            tostring(actual.matched_rule)
          )
        )
        assert.are.equal(expected.decision_source, actual.decision_source)
      end
    end)
  end)

  -- -----------------------------------------------------------------------
  -- 불변식 2: default_action — 매칭 없으면 global default_action 반환
  -- -----------------------------------------------------------------------
  describe("default_action 불변식", function()
    it("매칭 규칙 없을 때 default_action을 반환한다 (" .. ITERATIONS .. "회 반복)", function()
      local rng = RNG.new(BASE_SEED + 2)

      for iter = 1, ITERATIONS do
        local default_action = rng:pick(ACTIONS)

        -- Create rules that cannot match: all have an impossible path
        local num_rules = rng:int(1, 10)
        local rules = {}
        for i = 1, num_rules do
          rules[i] = {
            id = "nomatch-" .. i,
            priority = rng:int(1, 10),
            action = rng:pick(ACTIONS),
            enabled = true,
            scope = { path = "/impossible-path-" .. rng:int(10000, 99999) },
          }
        end

        local compiled = evaluator.compile(rules)
        local request = { path = "/definitely-not-matching", method = "GET" }

        local result = evaluator.evaluate(compiled, request, default_action)

        assert.are.equal(
          default_action,
          result.action,
          string.format("Iter %d: expected default_action=%s, got=%s", iter, default_action, result.action)
        )
        assert.is_nil(result.matched_rule)
        assert.are.equal("default", result.decision_source)
      end
    end)
  end)

  -- -----------------------------------------------------------------------
  -- 불변식 3: 충돌 감지 — 동일 priority + 반대 action + 동일 scope
  -- -----------------------------------------------------------------------
  describe("충돌 감지", function()
    it(
      "동일 priority, 반대 action, 동일 scope 규칙에서 충돌을 감지한다 ("
        .. ITERATIONS
        .. "회 반복)",
      function()
        local rng = RNG.new(BASE_SEED + 3)

        for iter = 1, ITERATIONS do
          local priority = rng:int(1, 10)
          local path = gen_path(rng)

          -- Create two rules with identical scope but opposite actions
          local rule_a = {
            id = "conflict-a-" .. iter,
            priority = priority,
            action = "allow",
            enabled = true,
            scope = { path = path },
          }
          local rule_b = {
            id = "conflict-b-" .. iter,
            priority = priority,
            action = "deny",
            enabled = true,
            scope = { path = path },
          }

          local conflicts, _ = conflict.detect({ rule_a, rule_b })

          assert.is_true(
            #conflicts > 0,
            string.format("Iter %d: expected conflict for rules at priority=%d, path=%s", iter, priority, path)
          )
        end
      end
    )
  end)

  -- -----------------------------------------------------------------------
  -- 불변식 4: 와일드카드 vs 구체적 경로 — 높은 priority 구체적 규칙이 승리
  -- -----------------------------------------------------------------------
  describe("와일드카드 vs 구체적 경로", function()
    it(
      "높은 priority의 구체적 규칙이 낮은 priority의 와일드카드를 이긴다 ("
        .. ITERATIONS
        .. "회 반복)",
      function()
        local rng = RNG.new(BASE_SEED + 4)

        for iter = 1, ITERATIONS do
          local base_path = "/" .. rng:pick(PATH_SEGMENTS)
          local sub_path = base_path .. "/" .. rng:pick(PATH_SEGMENTS)

          -- Higher priority = lower number
          local high_priority = rng:int(1, 5)
          local low_priority = high_priority + rng:int(1, 5) -- guaranteed lower priority

          local specific_action = rng:pick(ACTIONS)
          local wildcard_action = specific_action == "allow" and "deny" or "allow"

          local rules = {
            -- Higher priority specific rule
            {
              id = "specific",
              priority = high_priority,
              action = specific_action,
              enabled = true,
              scope = { path = sub_path },
            },
            -- Lower priority wildcard rule
            {
              id = "wildcard",
              priority = low_priority,
              action = wildcard_action,
              enabled = true,
              scope = { path = base_path .. "/*" },
            },
          }

          local compiled = evaluator.compile(rules)
          local request = { path = sub_path, method = "GET" }
          local default_action = "deny"

          local result = evaluator.evaluate(compiled, request, default_action)

          assert.are.equal(
            specific_action,
            result.action,
            string.format(
              "Iter %d: specific(p=%d,action=%s) should beat wildcard(p=%d,action=%s) for path=%s",
              iter,
              high_priority,
              specific_action,
              low_priority,
              wildcard_action,
              sub_path
            )
          )
          assert.are.equal("specific", result.matched_rule)
        end
      end
    )
  end)

  -- -----------------------------------------------------------------------
  -- 불변식 5: compile 정렬 순서 — (priority ASC, id ASC) 정렬
  -- -----------------------------------------------------------------------
  describe("compile 정렬 순서", function()
    it("compile() 출력이 (priority ASC, id ASC) 순서로 정렬된다 (" .. ITERATIONS .. "회 반복)", function()
      local rng = RNG.new(BASE_SEED + 5)

      for iter = 1, ITERATIONS do
        local num_rules = rng:int(2, 50)
        local rules = {}
        for i = 1, num_rules do
          rules[i] = gen_rule(rng, i)
        end

        local compiled = evaluator.compile(rules)

        for i = 2, #compiled do
          local prev = compiled[i - 1]
          local curr = compiled[i]

          local ordered = prev.priority < curr.priority or (prev.priority == curr.priority and prev.id <= curr.id)

          assert.is_true(
            ordered,
            string.format(
              "Iter %d: compile() order violation at index %d: {id=%s,p=%d} should precede {id=%s,p=%d}",
              iter,
              i,
              prev.id,
              prev.priority,
              curr.id,
              curr.priority
            )
          )
        end
      end
    end)
  end)

  -- -----------------------------------------------------------------------
  -- 불변식 6: 결정론적 동작 — 동일 입력은 동일 결과
  -- -----------------------------------------------------------------------
  describe("결정론적 동작", function()
    it("동일 입력은 반복 호출에서 동일 결과를 반환한다 (" .. ITERATIONS .. "회 반복)", function()
      local rng = RNG.new(BASE_SEED + 6)

      for iter = 1, ITERATIONS do
        local num_rules = rng:int(1, 30)
        local rules = {}
        for i = 1, num_rules do
          rules[i] = gen_rule(rng, i)
        end

        local default_action = rng:pick(ACTIONS)
        local request = gen_request(rng)

        -- Run twice with the same inputs
        local compiled1 = evaluator.compile(rules)
        local result1 = evaluator.evaluate(compiled1, request, default_action)

        local compiled2 = evaluator.compile(rules)
        local result2 = evaluator.evaluate(compiled2, request, default_action)

        assert.are.equal(
          result1.action,
          result2.action,
          string.format("Iter %d: determinism violation — action", iter)
        )
        assert.are.equal(
          result1.matched_rule,
          result2.matched_rule,
          string.format("Iter %d: determinism violation — matched_rule", iter)
        )
        assert.are.equal(
          result1.decision_source,
          result2.decision_source,
          string.format("Iter %d: determinism violation — decision_source", iter)
        )
      end
    end)
  end)
end)
