--- Unit tests for lua/luagate/policy/conflict.lua
-- Implementation: lua/luagate/policy/conflict.lua
-- Tests: tests/unit/policy/conflict_spec.lua
--
-- conflict.lua는 ngx.log를 사용하지만, ngx가 없을 때는 조용히 건너뛴다.
-- 단위 테스트에서는 ngx를 nil로 유지한다.

_G.ngx = nil

local conflict = require("luagate.policy.conflict")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- 최소 HTTP 규칙 빌더 (enabled=true 기본).
local function rule(overrides)
  local r = {
    id = "rule-default",
    priority = 10,
    action = "allow",
    enabled = true,
    scope = nil,
  }
  if overrides then
    for k, v in pairs(overrides) do
      r[k] = v
    end
  end
  return r
end

--- detect() 결과에서 conflicts id 추출 편의 함수.
local function conflict_ids(conflicts) -- luacheck: ignore
  local pairs_list = {}
  for _, c in ipairs(conflicts) do
    pairs_list[#pairs_list + 1] = c.rule_a .. ":" .. c.rule_b
  end
  return pairs_list
end

--- shadowed 목록에 특정 id가 있는지 확인.
local function contains(list, id)
  for _, v in ipairs(list) do
    if v == id then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- filter_enabled() 기본 동작
-- ---------------------------------------------------------------------------

describe("conflict.filter_enabled", function()
  it("enabled=true 규칙만 반환한다", function()
    local rules = {
      rule({ id = "r1", enabled = true }),
      rule({ id = "r2", enabled = false }),
      rule({ id = "r3", enabled = true }),
    }
    local result = conflict.filter_enabled(rules)
    assert.are.equal(2, #result)
    assert.are.equal("r1", result[1].id)
    assert.are.equal("r3", result[2].id)
  end)

  it("enabled 필드 없으면(nil) 활성으로 취급한다", function()
    local r = rule({ id = "no-flag" })
    r.enabled = nil
    local result = conflict.filter_enabled({ r })
    assert.are.equal(1, #result)
    assert.are.equal("no-flag", result[1].id)
  end)

  it("빈 목록 입력 시 빈 목록을 반환한다", function()
    local result = conflict.filter_enabled({})
    assert.is_table(result)
    assert.are.equal(0, #result)
  end)

  it("전체 비활성화 시 빈 목록을 반환한다", function()
    local rules = {
      rule({ id = "r1", enabled = false }),
      rule({ id = "r2", enabled = false }),
    }
    local result = conflict.filter_enabled(rules)
    assert.are.equal(0, #result)
  end)
end)

-- ---------------------------------------------------------------------------
-- detect() — 충돌 없는 경우
-- ---------------------------------------------------------------------------

describe("conflict.detect — 충돌 없음", function()
  it("규칙이 하나뿐이면 충돌도 shadow도 없다", function()
    local conflicts, shadowed = conflict.detect({ rule({ id = "only-one" }) })
    assert.are.equal(0, #conflicts)
    assert.are.equal(0, #shadowed)
  end)

  it("빈 목록이면 빈 결과를 반환한다", function()
    local conflicts, shadowed = conflict.detect({})
    assert.are.equal(0, #conflicts)
    assert.are.equal(0, #shadowed)
  end)

  it("동순위 + 동일 scope + 동일 action → 충돌 아님 (action이 같으므로)", function()
    local rules = {
      rule({ id = "a", priority = 10, action = "allow", scope = { path = "/health" } }),
      rule({ id = "b", priority = 10, action = "allow", scope = { path = "/health" } }),
    }
    local conflicts, _ = conflict.detect(rules)
    assert.are.equal(0, #conflicts)
  end)

  it("다른 scope이면 같은 priority라도 충돌 아님", function()
    local rules = {
      rule({ id = "a", priority = 10, action = "allow", scope = { path = "/health" } }),
      rule({ id = "b", priority = 10, action = "deny", scope = { path = "/metrics" } }),
    }
    local conflicts, _ = conflict.detect(rules)
    assert.are.equal(0, #conflicts)
  end)

  it("다른 priority이면 같은 scope + 반대 action이어도 충돌이 아닌 shadow 후보", function()
    local rules = {
      rule({ id = "high", priority = 1, action = "allow", scope = nil }),
      rule({ id = "low", priority = 10, action = "deny", scope = nil }),
    }
    local conflicts, _ = conflict.detect(rules)
    -- conflicts는 없어야 한다
    assert.are.equal(0, #conflicts)
  end)
end)

-- ---------------------------------------------------------------------------
-- detect() — 충돌(conflict) 감지
-- ---------------------------------------------------------------------------

describe("conflict.detect — 충돌(conflict) 감지", function()
  it("동순위 + exact scope 일치 + 반대 action → 충돌 감지", function()
    local rules = {
      rule({ id = "r-allow", priority = 10, action = "allow", scope = { path = "/api/*" } }),
      rule({ id = "r-deny", priority = 10, action = "deny", scope = { path = "/api/*" } }),
    }
    local conflicts, _ = conflict.detect(rules)
    assert.are.equal(1, #conflicts)
    assert.are.equal("r-allow", conflicts[1].rule_a)
    assert.are.equal("r-deny", conflicts[1].rule_b)
  end)

  it("nil scope(catch-all) + 동순위 + 반대 action → 충돌 감지", function()
    local rules = {
      rule({ id = "allow-all", priority = 5, action = "allow", scope = nil }),
      rule({ id = "deny-all", priority = 5, action = "deny", scope = nil }),
    }
    local conflicts, _ = conflict.detect(rules)
    assert.are.equal(1, #conflicts)
  end)

  it("충돌 쌍의 rule_a, rule_b는 문자열 id다", function()
    local rules = {
      rule({ id = "x", priority = 10, action = "allow", scope = { path = "/test" } }),
      rule({ id = "y", priority = 10, action = "deny", scope = { path = "/test" } }),
    }
    local conflicts, _ = conflict.detect(rules)
    assert.is_string(conflicts[1].rule_a)
    assert.is_string(conflicts[1].rule_b)
  end)

  it("method 목록이 같고 동순위이면 충돌 감지된다", function()
    local rules = {
      rule({ id = "a", priority = 10, action = "allow", scope = { method = { "GET", "POST" } } }),
      rule({ id = "b", priority = 10, action = "deny", scope = { method = { "POST", "GET" } } }),
    }
    local conflicts, _ = conflict.detect(rules)
    assert.are.equal(1, #conflicts)
  end)

  it("src_ip_cidr가 같고 동순위 + 반대 action → 충돌 감지", function()
    local rules = {
      rule({ id = "a", priority = 10, action = "allow", scope = { src_ip_cidr = "10.0.0.0/8" } }),
      rule({ id = "b", priority = 10, action = "deny", scope = { src_ip_cidr = "10.0.0.0/8" } }),
    }
    local conflicts, _ = conflict.detect(rules)
    assert.are.equal(1, #conflicts)
  end)
end)

-- ---------------------------------------------------------------------------
-- detect() — shadow 감지
-- ---------------------------------------------------------------------------

describe("conflict.detect — shadow(음영) 감지", function()
  it("high priority + broad scope가 low priority를 완전히 덮으면 shadow 감지", function()
    -- rule-broad: priority=1, scope=nil (catch-all) → rule-narrow: priority=10, scope={path="/health"}
    local rules = {
      rule({ id = "rule-broad", priority = 1, action = "allow", scope = nil }),
      rule({ id = "rule-narrow", priority = 10, action = "deny", scope = { path = "/health" } }),
    }
    local _, shadowed = conflict.detect(rules)
    assert.is_true(contains(shadowed, "rule-narrow"))
  end)

  it("shadowed 목록에 shadow된 규칙 id가 문자열로 포함된다", function()
    local rules = {
      rule({ id = "broad", priority = 1, scope = nil }),
      rule({ id = "narrow", priority = 10, scope = { path = "/api/*" } }),
    }
    local _, shadowed = conflict.detect(rules)
    for _, id in ipairs(shadowed) do
      assert.is_string(id)
    end
  end)

  it("path prefix '/*'가 하위 path를 shadow한다", function()
    local rules = {
      rule({ id = "api-wide", priority = 1, action = "allow", scope = { path = "/api/*" } }),
      rule({ id = "api-narrow", priority = 10, action = "deny", scope = { path = "/api/v1/*" } }),
    }
    local _, shadowed = conflict.detect(rules)
    assert.is_true(contains(shadowed, "api-narrow"))
  end)

  it("좁은 scope이 넓은 scope을 shadow하지 않는다", function()
    local rules = {
      rule({ id = "narrow", priority = 1, scope = { path = "/api/v1/*" } }),
      rule({ id = "broad", priority = 10, scope = { path = "/api/*" } }),
    }
    local _, shadowed = conflict.detect(rules)
    -- "broad"는 shadow되어서는 안 된다: narrow.priority < broad.priority이고
    -- narrow.scope은 broad.scope보다 좁으므로 broad를 완전히 커버하지 못한다
    assert.is_false(contains(shadowed, "broad"))
  end)

  it("동일 scope + 동일 priority → shadow 아님 (conflict만)", function()
    local rules = {
      rule({ id = "same-a", priority = 10, action = "allow", scope = { path = "/test" } }),
      rule({ id = "same-b", priority = 10, action = "deny", scope = { path = "/test" } }),
    }
    local _, shadowed = conflict.detect(rules)
    -- shadow는 priority가 달라야 발생한다
    assert.are.equal(0, #shadowed)
  end)

  it("shadow된 규칙이 여럿이어도 중복 없이 각 id가 한 번만 나온다", function()
    local rules = {
      rule({ id = "broad", priority = 1, scope = nil }),
      rule({ id = "narrow-1", priority = 10, scope = { path = "/a" } }),
      rule({ id = "narrow-2", priority = 20, scope = { path = "/b" } }),
    }
    local _, shadowed = conflict.detect(rules)
    -- 중복 검사: 각 id가 최대 1번
    local seen = {}
    for _, id in ipairs(shadowed) do
      assert.is_nil(seen[id], "중복 shadow id: " .. id)
      seen[id] = true
    end
    assert.is_true(contains(shadowed, "narrow-1"))
    assert.is_true(contains(shadowed, "narrow-2"))
  end)
end)

-- ---------------------------------------------------------------------------
-- detect() — enabled=false 규칙 제외 (filter_enabled 후 detect 호출)
-- ---------------------------------------------------------------------------

describe("conflict.detect — enabled=false 규칙은 detect에 포함되지 않아야 함", function()
  it("disabled 규칙을 filter_enabled로 제거한 후 detect하면 충돌 감지되지 않는다", function()
    -- 비활성 규칙과의 충돌은 감지되지 않아야 한다
    local all_rules = {
      rule({ id = "active", priority = 10, action = "allow", scope = { path = "/api" }, enabled = true }),
      rule({ id = "inactive", priority = 10, action = "deny", scope = { path = "/api" }, enabled = false }),
    }
    local enabled = conflict.filter_enabled(all_rules)
    local conflicts, shadowed = conflict.detect(enabled)
    assert.are.equal(0, #conflicts)
    assert.are.equal(0, #shadowed)
  end)

  it("disabled 규칙을 필터 후 detect: 남은 규칙 간 충돌만 감지된다", function()
    local all_rules = {
      rule({
        id = "active-allow",
        priority = 10,
        action = "allow",
        scope = { path = "/test" },
        enabled = true,
      }),
      rule({
        id = "active-deny",
        priority = 10,
        action = "deny",
        scope = { path = "/test" },
        enabled = true,
      }),
      rule({
        id = "disabled",
        priority = 10,
        action = "deny",
        scope = { path = "/test" },
        enabled = false,
      }),
    }
    local enabled = conflict.filter_enabled(all_rules)
    local conflicts, _ = conflict.detect(enabled)
    -- active-allow vs active-deny 충돌 1건만
    assert.are.equal(1, #conflicts)
  end)
end)

-- ---------------------------------------------------------------------------
-- detect() — Stream 규칙 충돌/shadow
-- ---------------------------------------------------------------------------

describe("conflict.detect — Stream 규칙 충돌 및 shadow", function()
  it("Stream 규칙: dst_port 동일 + 동순위 + 반대 action → 충돌 감지", function()
    local rules = {
      rule({ id = "proxy-443", priority = 10, action = "proxy", scope = { dst_port = 443 } }),
      rule({ id = "deny-443", priority = 10, action = "deny", scope = { dst_port = 443 } }),
    }
    local conflicts, _ = conflict.detect(rules)
    assert.are.equal(1, #conflicts)
  end)

  it("Stream 규칙: catch-all scope이 좁은 scope을 shadow한다", function()
    local rules = {
      rule({ id = "catch-all", priority = 1, action = "deny", scope = nil }),
      rule({ id = "tls-only", priority = 10, action = "proxy", scope = { detected_protocol = "tls" } }),
    }
    local _, shadowed = conflict.detect(rules)
    assert.is_true(contains(shadowed, "tls-only"))
  end)

  it("Stream 규칙: dst_port 범위가 단일 포트를 포함하면 shadow 감지", function()
    local rules = {
      rule({ id = "range-rule", priority = 1, action = "deny", scope = { dst_port = "1024-65535" } }),
      rule({ id = "single-port", priority = 10, action = "proxy", scope = { dst_port = 8080 } }),
    }
    local _, shadowed = conflict.detect(rules)
    assert.is_true(contains(shadowed, "single-port"))
  end)

  it("sni 동일 + 동순위 + 반대 action → 충돌 감지", function()
    local rules = {
      rule({ id = "sni-proxy", priority = 5, action = "proxy", scope = { sni = "api.example.com" } }),
      rule({ id = "sni-deny", priority = 5, action = "deny", scope = { sni = "api.example.com" } }),
    }
    local conflicts, _ = conflict.detect(rules)
    assert.are.equal(1, #conflicts)
  end)
end)

-- ---------------------------------------------------------------------------
-- detect() — overlap conflict 감지 (코드리뷰 피드백 반영)
-- ---------------------------------------------------------------------------

describe("conflict.detect — overlap conflict 감지", function()
  it("/api/* allow vs /api/admin/* deny (동순위, 포함 관계) → overlap conflict 감지", function()
    -- /api/* 가 /api/admin/* 을 포함하므로 scope_contains(a, b) = true
    -- 동순위 + 반대 action → overlap conflict
    local rules = {
      rule({ id = "api-allow", priority = 10, action = "allow", scope = { path = "/api/*" } }),
      rule({ id = "api-admin-deny", priority = 10, action = "deny", scope = { path = "/api/admin/*" } }),
    }
    local conflicts, _ = conflict.detect(rules)
    assert.are.equal(1, #conflicts)
    assert.are.equal("api-allow", conflicts[1].rule_a)
    assert.are.equal("api-admin-deny", conflicts[1].rule_b)
  end)

  it("overlap conflict 엔트리의 overlap_type은 'overlap'이다", function()
    local rules = {
      rule({ id = "broad-allow", priority = 10, action = "allow", scope = { path = "/api/*" } }),
      rule({ id = "narrow-deny", priority = 10, action = "deny", scope = { path = "/api/v1/*" } }),
    }
    local conflicts, _ = conflict.detect(rules)
    assert.are.equal(1, #conflicts)
    assert.are.equal("overlap", conflicts[1].overlap_type)
  end)

  it("exact conflict 엔트리의 overlap_type은 'exact'이다", function()
    local rules = {
      rule({ id = "r-allow", priority = 10, action = "allow", scope = { path = "/api/*" } }),
      rule({ id = "r-deny", priority = 10, action = "deny", scope = { path = "/api/*" } }),
    }
    local conflicts, _ = conflict.detect(rules)
    assert.are.equal(1, #conflicts)
    assert.are.equal("exact", conflicts[1].overlap_type)
  end)

  it("동순위 + 동일 action인 포함 관계는 conflict가 아니다 (action 동일)", function()
    -- scope_contains가 성립해도 action이 같으면 충돌 아님
    local rules = {
      rule({ id = "api-allow", priority = 10, action = "allow", scope = { path = "/api/*" } }),
      rule({ id = "api-admin-allow", priority = 10, action = "allow", scope = { path = "/api/admin/*" } }),
    }
    local conflicts, _ = conflict.detect(rules)
    assert.are.equal(0, #conflicts)
  end)

  it("다른 priority의 포함 관계는 conflict가 아닌 shadow 후보다", function()
    -- priority가 다르면 conflict 조건(동순위) 불충족 → shadow로만 처리
    local rules = {
      rule({ id = "broad", priority = 1, action = "allow", scope = { path = "/api/*" } }),
      rule({ id = "narrow", priority = 10, action = "deny", scope = { path = "/api/v1/*" } }),
    }
    local conflicts, shadowed = conflict.detect(rules)
    -- conflict는 없어야 한다
    assert.are.equal(0, #conflicts)
    -- shadow는 발생해야 한다
    assert.is_true(contains(shadowed, "narrow"))
  end)

  it("역방향 포함 관계도 overlap conflict로 감지된다 (b contains a)", function()
    -- b의 scope이 a의 scope을 포함해도 overlap conflict
    local rules = {
      rule({ id = "narrow-allow", priority = 10, action = "allow", scope = { path = "/api/v1/*" } }),
      rule({ id = "broad-deny", priority = 10, action = "deny", scope = { path = "/api/*" } }),
    }
    local conflicts, _ = conflict.detect(rules)
    assert.are.equal(1, #conflicts)
    assert.are.equal("overlap", conflicts[1].overlap_type)
  end)

  it("catch-all scope(nil) + 동순위 + 반대 action인 비nil scope → overlap conflict 감지", function()
    -- scope_contains(nil, non-nil) = true → overlap conflict
    local rules = {
      rule({ id = "catch-all-allow", priority = 5, action = "allow", scope = nil }),
      rule({ id = "path-deny", priority = 5, action = "deny", scope = { path = "/secret" } }),
    }
    local conflicts, _ = conflict.detect(rules)
    -- nil scope은 scopes_equal(nil, non-nil)=false, scope_contains(nil, non-nil)=true → overlap
    assert.are.equal(1, #conflicts)
    assert.are.equal("overlap", conflicts[1].overlap_type)
  end)
end)

-- ---------------------------------------------------------------------------
-- detect_and_fail() — fail-closed 변형 (코드리뷰 피드백 반영)
-- ---------------------------------------------------------------------------

describe("conflict.detect_and_fail — fail-closed 변형", function()
  it("conflict 없으면 정상 반환하며 error를 발생시키지 않는다", function()
    local rules = {
      rule({ id = "r1", priority = 10, action = "allow", scope = { path = "/health" } }),
      rule({ id = "r2", priority = 20, action = "deny", scope = { path = "/metrics" } }),
    }
    assert.has_no.errors(function()
      local conflicts, shadowed = conflict.detect_and_fail(rules)
      assert.is_table(conflicts)
      assert.is_table(shadowed)
      assert.are.equal(0, #conflicts)
    end)
  end)

  it("shadow만 있고 conflict가 없으면 error를 발생시키지 않는다", function()
    local rules = {
      rule({ id = "broad", priority = 1, action = "allow", scope = nil }),
      rule({ id = "narrow", priority = 10, action = "allow", scope = { path = "/health" } }),
    }
    assert.has_no.errors(function()
      local _, shadowed = conflict.detect_and_fail(rules)
      -- shadow는 반환되지만 error는 없다
      assert.is_true(contains(shadowed, "narrow"))
    end)
  end)

  it("exact conflict 존재 시 error()를 발생시킨다", function()
    local rules = {
      rule({ id = "exact-allow", priority = 10, action = "allow", scope = { path = "/api/*" } }),
      rule({ id = "exact-deny", priority = 10, action = "deny", scope = { path = "/api/*" } }),
    }
    assert.has_error(function()
      conflict.detect_and_fail(rules)
    end)
  end)

  it("exact conflict 에러 메시지에 충돌 규칙 id가 포함된다", function()
    local rules = {
      rule({ id = "a-allow", priority = 10, action = "allow", scope = { path = "/test" } }),
      rule({ id = "b-deny", priority = 10, action = "deny", scope = { path = "/test" } }),
    }
    local ok, err = pcall(conflict.detect_and_fail, rules)
    assert.is_false(ok)
    assert.is_string(err)
    -- 에러 메시지에 rule id 포함 확인
    assert.is_truthy(err:find("a-allow") or err:find("b-deny"))
  end)

  it("overlap conflict 존재 시 error()를 발생시킨다", function()
    local rules = {
      rule({ id = "api-allow", priority = 10, action = "allow", scope = { path = "/api/*" } }),
      rule({ id = "api-admin-deny", priority = 10, action = "deny", scope = { path = "/api/admin/*" } }),
    }
    assert.has_error(function()
      conflict.detect_and_fail(rules)
    end)
  end)

  it("overlap conflict 에러 메시지에 'overlap' 타입이 명시된다", function()
    local rules = {
      rule({ id = "broad-allow", priority = 10, action = "allow", scope = { path = "/api/*" } }),
      rule({ id = "narrow-deny", priority = 10, action = "deny", scope = { path = "/api/v1/*" } }),
    }
    local ok, err = pcall(conflict.detect_and_fail, rules)
    assert.is_false(ok)
    assert.is_string(err)
    assert.is_truthy(err:find("overlap"))
  end)

  it("빈 목록이면 정상 반환한다", function()
    assert.has_no.errors(function()
      local conflicts, shadowed = conflict.detect_and_fail({})
      assert.are.equal(0, #conflicts)
      assert.are.equal(0, #shadowed)
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- detect() — 반환 타입 보장
-- ---------------------------------------------------------------------------

describe("conflict.detect — 반환 타입 보장", function()
  it("항상 두 개의 테이블을 반환한다 (conflicts, shadowed)", function()
    local conflicts, shadowed = conflict.detect({})
    assert.is_table(conflicts)
    assert.is_table(shadowed)
  end)

  it("규칙이 있어도 항상 두 개의 테이블을 반환한다", function()
    local rules = {
      rule({ id = "r1" }),
      rule({ id = "r2" }),
    }
    local conflicts, shadowed = conflict.detect(rules)
    assert.is_table(conflicts)
    assert.is_table(shadowed)
  end)
end)
