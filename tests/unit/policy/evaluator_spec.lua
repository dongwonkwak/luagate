--- Unit tests for lua/luagate/policy/evaluator.lua
-- Implementation: lua/luagate/policy/evaluator.lua
-- Tests: tests/unit/policy/evaluator_spec.lua
--
-- evaluator.lua는 ngx 전역 없이도 동작할 수 있도록 설계되어 있다.
-- get_policy()는 ngx.shared 의존성이 있으므로 단위 테스트에서는 제외하고,
-- compile() / evaluate() / evaluate_stream() / reset_cache()를 집중 검증한다.
--
-- cjson은 LuaJIT 전용 .so이므로 Lua 5.4 busted 환경에서 dkjson으로 stub한다.
package.preload["cjson"] = function()
  local dkjson = require("dkjson")
  return {
    decode = dkjson.decode,
    encode = dkjson.encode,
  }
end

-- ngx 전역 stub (warn 로그 호출 등 방어)
_G.ngx = nil

local evaluator = require("luagate.policy.evaluator")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- 기본 HTTP 규칙 빌더: 최소 필수 필드만 포함.
local function http_rule(overrides)
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

--- 기본 Stream 규칙 빌더.
local function stream_rule(overrides)
  local r = {
    id = "stream-default",
    priority = 10,
    action = "deny",
    enabled = true,
    scope = nil,
    upstream = nil,
  }
  if overrides then
    for k, v in pairs(overrides) do
      r[k] = v
    end
  end
  return r
end

--- compile() 결과를 반환하는 편의 함수.
local function compile(rules)
  return evaluator.compile(rules)
end

-- ---------------------------------------------------------------------------
-- compile() — 기본 동작
-- ---------------------------------------------------------------------------

describe("evaluator.compile — 기본 동작", function()
  it("빈 목록을 입력하면 빈 목록을 반환한다", function()
    local result = compile({})
    assert.is_table(result)
    assert.are.equal(0, #result)
  end)

  it("enabled=false 규칙을 필터링한다", function()
    local rules = {
      http_rule({ id = "enabled-rule", enabled = true }),
      http_rule({ id = "disabled-rule", enabled = false }),
    }
    local result = compile(rules)
    assert.are.equal(1, #result)
    assert.are.equal("enabled-rule", result[1].id)
  end)

  it("enabled 필드가 없으면(nil) 활성으로 취급한다", function()
    local r = http_rule({ id = "no-enabled-field" })
    r.enabled = nil
    local result = compile({ r })
    assert.are.equal(1, #result)
    assert.are.equal("no-enabled-field", result[1].id)
  end)

  it("priority 오름차순으로 정렬한다", function()
    local rules = {
      http_rule({ id = "rule-b", priority = 20 }),
      http_rule({ id = "rule-a", priority = 10 }),
      http_rule({ id = "rule-c", priority = 30 }),
    }
    local result = compile(rules)
    assert.are.equal("rule-a", result[1].id)
    assert.are.equal("rule-b", result[2].id)
    assert.are.equal("rule-c", result[3].id)
  end)

  it("동순위 priority에서는 id 오름차순으로 정렬한다 (stable)", function()
    local rules = {
      http_rule({ id = "rule-z", priority = 10 }),
      http_rule({ id = "rule-a", priority = 10 }),
      http_rule({ id = "rule-m", priority = 10 }),
    }
    local result = compile(rules)
    assert.are.equal("rule-a", result[1].id)
    assert.are.equal("rule-m", result[2].id)
    assert.are.equal("rule-z", result[3].id)
  end)

  it("원본 목록을 변경하지 않는다 (compile은 새 목록 반환)", function()
    local r1 = http_rule({ id = "first", priority = 20 })
    local r2 = http_rule({ id = "second", priority = 10 })
    local original = { r1, r2 }
    compile(original)
    -- 원본 순서 유지 검증
    assert.are.equal("first", original[1].id)
    assert.are.equal("second", original[2].id)
  end)

  it("compile() 후 규칙에 _sort_idx가 남지 않는다", function()
    local rules = { http_rule({ id = "r1" }), http_rule({ id = "r2" }) }
    local result = compile(rules)
    for _, rule in ipairs(result) do
      assert.is_nil(rule._sort_idx)
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- evaluate() — 기본 allow/deny 반환
-- ---------------------------------------------------------------------------

describe("evaluator.evaluate — 기본 allow/deny 반환", function()
  it("매칭 규칙이 allow이면 action=allow를 반환한다", function()
    local rules = compile({ http_rule({ id = "allow-all", action = "allow" }) })
    local result = evaluator.evaluate(rules, {}, "deny")
    assert.are.equal("allow", result.action)
    assert.are.equal("allow-all", result.matched_rule)
    assert.are.equal("rule", result.decision_source)
  end)

  it("매칭 규칙이 deny이면 action=deny를 반환한다", function()
    local rules = compile({ http_rule({ id = "deny-all", action = "deny" }) })
    local result = evaluator.evaluate(rules, {}, "allow")
    assert.are.equal("deny", result.action)
    assert.are.equal("deny-all", result.matched_rule)
    assert.are.equal("rule", result.decision_source)
  end)

  it("반환 구조에 action, matched_rule, decision_source 세 필드가 존재한다", function()
    local rules = compile({ http_rule() })
    local result = evaluator.evaluate(rules, {}, "deny")
    assert.is_string(result.action)
    -- matched_rule은 string 또는 nil
    assert.is_string(result.decision_source)
  end)
end)

-- ---------------------------------------------------------------------------
-- evaluate() — priority first-match-wins
-- ---------------------------------------------------------------------------

describe("evaluator.evaluate — priority first-match-wins", function()
  it("priority 낮은 숫자의 규칙이 먼저 매칭된다", function()
    local rules = compile({
      http_rule({ id = "rule-high-pri", priority = 1, action = "allow" }),
      http_rule({ id = "rule-low-pri", priority = 10, action = "deny" }),
    })
    local result = evaluator.evaluate(rules, {}, "deny")
    assert.are.equal("allow", result.action)
    assert.are.equal("rule-high-pri", result.matched_rule)
  end)

  it("첫 번째 매칭 규칙에서 평가를 중단하고 나머지 규칙을 무시한다", function()
    -- 두 규칙이 모두 catch-all scope이지만 priority 1이 먼저 매칭되어야 한다
    local rules = compile({
      http_rule({ id = "first", priority = 1, action = "deny" }),
      http_rule({ id = "second", priority = 2, action = "allow" }),
    })
    local result = evaluator.evaluate(rules, {}, "allow")
    assert.are.equal("first", result.matched_rule)
    assert.are.equal("deny", result.action)
  end)

  it("path 매칭: /health는 /health 규칙에만 매칭된다", function()
    local rules = compile({
      http_rule({ id = "health-allow", priority = 1, action = "allow", scope = { path = "/health" } }),
      http_rule({ id = "deny-all", priority = 2, action = "deny" }),
    })
    local result = evaluator.evaluate(rules, { path = "/health" }, "deny")
    assert.are.equal("allow", result.action)
    assert.are.equal("health-allow", result.matched_rule)
  end)

  it("path 매칭: /other는 /health 규칙을 건너뛰고 다음 규칙에 매칭된다", function()
    local rules = compile({
      http_rule({ id = "health-allow", priority = 1, action = "allow", scope = { path = "/health" } }),
      http_rule({ id = "deny-all", priority = 2, action = "deny" }),
    })
    local result = evaluator.evaluate(rules, { path = "/other" }, "deny")
    assert.are.equal("deny", result.action)
    assert.are.equal("deny-all", result.matched_rule)
  end)
end)

-- ---------------------------------------------------------------------------
-- evaluate() — stable sort: 동순위 priority에서 id 오름차순
-- ---------------------------------------------------------------------------

describe("evaluator.evaluate — stable sort (동순위 priority)", function()
  it("동순위 priority에서 id 오름차순의 규칙이 먼저 매칭된다", function()
    -- 두 규칙 모두 priority=10, catch-all scope — id 오름차순 "rule-a" < "rule-z"
    local rules = compile({
      http_rule({ id = "rule-z", priority = 10, action = "deny" }),
      http_rule({ id = "rule-a", priority = 10, action = "allow" }),
    })
    local result = evaluator.evaluate(rules, {}, "deny")
    assert.are.equal("rule-a", result.matched_rule)
    assert.are.equal("allow", result.action)
  end)

  it("우선순위 상위 그룹이 동순위 하위 그룹보다 먼저 평가된다", function()
    local rules = compile({
      http_rule({ id = "low-z", priority = 20, action = "allow", scope = { path = "/api/*" } }),
      http_rule({ id = "high-a", priority = 5, action = "deny", scope = { path = "/api/*" } }),
      http_rule({ id = "high-b", priority = 5, action = "allow", scope = { path = "/other" } }),
    })
    local result = evaluator.evaluate(rules, { path = "/api/v1" }, "allow")
    -- priority=5 그룹 중 path=/api/* 에 매칭되는 "high-a"가 먼저 실행
    assert.are.equal("high-a", result.matched_rule)
    assert.are.equal("deny", result.action)
  end)
end)

-- ---------------------------------------------------------------------------
-- evaluate() — 매칭 없을 때 default_action 적용
-- ---------------------------------------------------------------------------

describe("evaluator.evaluate — 매칭 없을 때 default_action 적용", function()
  it("규칙 목록이 비어 있으면 default_action=deny가 적용된다", function()
    local result = evaluator.evaluate({}, {}, "deny")
    assert.are.equal("deny", result.action)
    assert.is_nil(result.matched_rule)
    assert.are.equal("default", result.decision_source)
  end)

  it("규칙 목록이 비어 있으면 default_action=allow가 적용된다", function()
    local result = evaluator.evaluate({}, {}, "allow")
    assert.are.equal("allow", result.action)
    assert.is_nil(result.matched_rule)
    assert.are.equal("default", result.decision_source)
  end)

  it("모든 규칙이 scope 불일치하면 default_action이 적용된다", function()
    local rules = compile({
      http_rule({ id = "health-only", action = "allow", scope = { path = "/health" } }),
    })
    local result = evaluator.evaluate(rules, { path = "/unknown" }, "deny")
    assert.are.equal("deny", result.action)
    assert.is_nil(result.matched_rule)
    assert.are.equal("default", result.decision_source)
  end)
end)

-- ---------------------------------------------------------------------------
-- evaluate() — fail-closed: 내부 에러 시 deny 반환
-- ---------------------------------------------------------------------------

describe("evaluator.evaluate — fail-closed (잘못된 인자)", function()
  it("rules가 nil이면 deny를 반환한다", function()
    local result = evaluator.evaluate(nil, {}, "deny")
    assert.are.equal("deny", result.action)
    assert.are.equal("error", result.decision_source)
  end)

  it("rules가 string이면 deny를 반환한다", function()
    local result = evaluator.evaluate("bad", {}, "deny")
    assert.are.equal("deny", result.action)
    assert.are.equal("error", result.decision_source)
  end)

  it("request_ctx가 nil이면 deny를 반환한다", function()
    local rules = compile({ http_rule() })
    local result = evaluator.evaluate(rules, nil, "deny")
    assert.are.equal("deny", result.action)
    assert.are.equal("error", result.decision_source)
  end)

  it("default_action이 nil이면 fail-closed deny를 반환한다", function()
    local result = evaluator.evaluate({}, {}, nil)
    assert.are.equal("deny", result.action)
    assert.are.equal("error", result.decision_source)
  end)

  it("default_action이 'allow'/'deny' 이외 값이면 deny를 반환한다", function()
    local result = evaluator.evaluate({}, {}, "pass")
    assert.are.equal("deny", result.action)
    assert.are.equal("error", result.decision_source)
  end)

  it("반환값은 항상 테이블이며 nil이 아니다", function()
    local result = evaluator.evaluate(nil, nil, nil)
    assert.is_table(result)
    assert.is_not_nil(result)
  end)
end)

-- ---------------------------------------------------------------------------
-- evaluate() — scope 매칭 상세 검증 (HTTP)
-- ---------------------------------------------------------------------------

describe("evaluator.evaluate — HTTP scope 매칭", function()
  it("nil scope(catch-all) 규칙은 모든 요청에 매칭된다", function()
    local rules = compile({ http_rule({ id = "catch-all", scope = nil }) })
    local result = evaluator.evaluate(rules, { path = "/anything", method = "DELETE" }, "deny")
    assert.are.equal("catch-all", result.matched_rule)
  end)

  it("path prefix '/*' 매칭: /api/v1/users는 /api/* 에 매칭된다", function()
    local rules = compile({
      http_rule({ id = "api-rule", action = "allow", scope = { path = "/api/*" } }),
    })
    local result = evaluator.evaluate(rules, { path = "/api/v1/users" }, "deny")
    assert.are.equal("allow", result.action)
    assert.are.equal("api-rule", result.matched_rule)
  end)

  it("path prefix '/*' 매칭: /other는 /api/* 에 매칭되지 않는다", function()
    local rules = compile({
      http_rule({ id = "api-rule", action = "allow", scope = { path = "/api/*" } }),
    })
    local result = evaluator.evaluate(rules, { path = "/other" }, "deny")
    assert.are.equal("deny", result.action)
    assert.is_nil(result.matched_rule)
  end)

  it("method 매칭: GET만 허용하는 규칙에 POST는 매칭되지 않는다", function()
    local rules = compile({
      http_rule({ id = "get-only", action = "allow", scope = { method = "GET" } }),
    })
    local result = evaluator.evaluate(rules, { method = "POST" }, "deny")
    assert.are.equal("deny", result.action)
  end)

  it("method 목록 매칭: GET, POST 중 하나이면 매칭된다", function()
    local rules = compile({
      http_rule({ id = "get-post", action = "allow", scope = { method = { "GET", "POST" } } }),
    })
    local result = evaluator.evaluate(rules, { method = "POST" }, "deny")
    assert.are.equal("allow", result.action)
  end)

  it("method 비교는 대소문자를 무시한다", function()
    local rules = compile({
      http_rule({ id = "lower-get", action = "allow", scope = { method = "get" } }),
    })
    local result = evaluator.evaluate(rules, { method = "GET" }, "deny")
    assert.are.equal("allow", result.action)
  end)

  it("src_ip_cidr 매칭: 10.0.1.5는 10.0.0.0/8에 매칭된다", function()
    local rules = compile({
      http_rule({ id = "internal", action = "allow", scope = { src_ip_cidr = "10.0.0.0/8" } }),
    })
    local result = evaluator.evaluate(rules, { src_ip = "10.0.1.5" }, "deny")
    assert.are.equal("allow", result.action)
  end)

  it("src_ip_cidr 매칭: 192.168.1.1은 10.0.0.0/8에 매칭되지 않는다", function()
    local rules = compile({
      http_rule({ id = "internal", action = "allow", scope = { src_ip_cidr = "10.0.0.0/8" } }),
    })
    local result = evaluator.evaluate(rules, { src_ip = "192.168.1.1" }, "deny")
    assert.are.equal("deny", result.action)
  end)

  -- [ESCALATION] match_host() 구현 버그 의심 — architect 에스컬레이션 필요
  -- 현재 구현:
  --   suffix = scope_host:sub(2)  → ".example.com"
  --   조건: req_host:sub(-n) == suffix
  --         AND req_host:sub(#req_host - n, #req_host - n) == "."
  -- suffix가 이미 "."으로 시작하므로 두 번째 조건의 "."은 suffix 직전 문자를 가리키는데,
  -- "sub.example.com"(15자)에서 index 3 = "b" 이므로 항상 false가 된다.
  it("host 매칭: 와일드카드 *.example.com은 sub.example.com에 매칭된다", function()
    local rules = compile({
      http_rule({ id = "wildcard-host", action = "allow", scope = { host = "*.example.com" } }),
    })
    local result = evaluator.evaluate(rules, { host = "sub.example.com" }, "deny")
    assert.are.equal("allow", result.action)
  end)

  it("host 매칭: *.example.com은 베어 도메인 example.com에 매칭되지 않는다", function()
    local rules = compile({
      http_rule({ id = "wildcard-host", action = "allow", scope = { host = "*.example.com" } }),
    })
    local result = evaluator.evaluate(rules, { host = "example.com" }, "deny")
    assert.are.equal("deny", result.action)
  end)

  it("query_param 매칭: 요청 파라미터에 scope 파라미터가 포함되어야 매칭된다", function()
    local rules = compile({
      http_rule({ id = "qp-rule", action = "allow", scope = { query_param = { debug = "true" } } }),
    })
    local result = evaluator.evaluate(rules, { query_param = { debug = "true", other = "val" } }, "deny")
    assert.are.equal("allow", result.action)
  end)

  it("query_param 매칭: 파라미터 값이 다르면 매칭되지 않는다", function()
    local rules = compile({
      http_rule({ id = "qp-rule", action = "allow", scope = { query_param = { debug = "true" } } }),
    })
    local result = evaluator.evaluate(rules, { query_param = { debug = "false" } }, "deny")
    assert.are.equal("deny", result.action)
  end)

  it("header 매칭: X-Role:admin이 있으면 매칭된다", function()
    local rules = compile({
      http_rule({
        id = "admin-header",
        action = "allow",
        scope = { header = { ["x-role"] = "admin" } },
      }),
    })
    local result = evaluator.evaluate(rules, { header = { ["x-role"] = "admin" } }, "deny")
    assert.are.equal("allow", result.action)
  end)

  it("scope 필드가 AND 조건: path와 method 모두 일치해야 매칭된다", function()
    local rules = compile({
      http_rule({ id = "and-rule", action = "allow", scope = { path = "/api/*", method = "GET" } }),
    })
    -- path 일치, method 불일치 → 매칭 실패
    local result = evaluator.evaluate(rules, { path = "/api/v1", method = "POST" }, "deny")
    assert.are.equal("deny", result.action)
    assert.is_nil(result.matched_rule)
  end)
end)

-- ---------------------------------------------------------------------------
-- evaluate_stream() — Stream 독립 평가
-- ---------------------------------------------------------------------------

describe("evaluator.evaluate_stream — Stream 독립 평가", function()
  it("매칭 규칙이 proxy이면 action=proxy와 upstream을 반환한다", function()
    local rules = compile({
      stream_rule({ id = "tls-proxy", action = "proxy", upstream = "backend:8443" }),
    })
    local result = evaluator.evaluate_stream(rules, {})
    assert.are.equal("proxy", result.action)
    assert.are.equal("tls-proxy", result.matched_rule)
    assert.are.equal("backend:8443", result.upstream)
    assert.are.equal("rule", result.decision_source)
  end)

  it("매칭 규칙이 deny이면 action=deny를 반환한다", function()
    local rules = compile({
      stream_rule({ id = "deny-ssh", action = "deny", scope = { detected_protocol = "ssh" } }),
    })
    local result = evaluator.evaluate_stream(rules, { detected_protocol = "ssh" })
    assert.are.equal("deny", result.action)
    assert.are.equal("deny-ssh", result.matched_rule)
  end)

  it("매칭 없으면 Stream은 항상 fail-closed deny (default action 없음)", function()
    local result = evaluator.evaluate_stream({}, {})
    assert.are.equal("deny", result.action)
    assert.is_nil(result.matched_rule)
    assert.are.equal("default", result.decision_source)
    assert.is_nil(result.upstream)
  end)

  it("반환 구조에 action, matched_rule, decision_source, upstream 네 필드가 있다", function()
    local result = evaluator.evaluate_stream({}, {})
    assert.is_string(result.action)
    assert.is_string(result.decision_source)
    -- matched_rule, upstream은 nil 허용
  end)

  it("dst_port 매칭: 443 포트는 443 규칙에 매칭된다", function()
    local rules = compile({
      stream_rule({
        id = "port-443",
        action = "proxy",
        upstream = "tls-backend:443",
        scope = { dst_port = 443 },
      }),
    })
    local result = evaluator.evaluate_stream(rules, { dst_port = 443 })
    assert.are.equal("proxy", result.action)
    assert.are.equal("port-443", result.matched_rule)
  end)

  it("dst_port 범위 매칭: 8080은 '1024-65535'에 매칭된다", function()
    local rules = compile({
      stream_rule({
        id = "high-ports",
        action = "proxy",
        upstream = "backend:9000",
        scope = { dst_port = "1024-65535" },
      }),
    })
    local result = evaluator.evaluate_stream(rules, { dst_port = 8080 })
    assert.are.equal("proxy", result.action)
    assert.are.equal("high-ports", result.matched_rule)
  end)

  it("dst_port 범위 매칭: 80은 '1024-65535'에 매칭되지 않는다", function()
    local rules = compile({
      stream_rule({ id = "high-ports", action = "deny", scope = { dst_port = "1024-65535" } }),
    })
    local result = evaluator.evaluate_stream(rules, { dst_port = 80 })
    assert.are.equal("deny", result.action) -- default fail-closed
    assert.is_nil(result.matched_rule)
  end)

  it("detected_protocol 매칭: tls는 tls 규칙에만 매칭된다", function()
    local rules = compile({
      stream_rule({
        id = "tls-rule",
        action = "proxy",
        upstream = "tls:443",
        scope = { detected_protocol = "tls" },
      }),
      stream_rule({ id = "deny-all", action = "deny", priority = 100 }),
    })
    local result = evaluator.evaluate_stream(rules, { detected_protocol = "http" })
    -- tls 규칙 불일치, deny-all catch-all 매칭
    assert.are.equal("deny", result.action)
    assert.are.equal("deny-all", result.matched_rule)
  end)

  it("sni 매칭: api.example.com은 api.example.com 규칙에 매칭된다", function()
    local rules = compile({
      stream_rule({
        id = "sni-rule",
        action = "proxy",
        upstream = "api-backend:443",
        scope = { sni = "api.example.com" },
      }),
    })
    local result = evaluator.evaluate_stream(rules, { sni = "api.example.com" })
    assert.are.equal("proxy", result.action)
    assert.are.equal("sni-rule", result.matched_rule)
  end)

  it("fail-closed: rules가 nil이면 deny를 반환한다", function()
    local result = evaluator.evaluate_stream(nil, {})
    assert.are.equal("deny", result.action)
    assert.are.equal("error", result.decision_source)
  end)

  it("fail-closed: request_ctx가 nil이면 deny를 반환한다", function()
    local rules = compile({ stream_rule() })
    local result = evaluator.evaluate_stream(rules, nil)
    assert.are.equal("deny", result.action)
    assert.are.equal("error", result.decision_source)
  end)
end)

-- ---------------------------------------------------------------------------
-- evaluate() vs evaluate_stream() — HTTP/Stream 독립성
-- ---------------------------------------------------------------------------

describe("evaluator — HTTP와 Stream 평가 독립성", function()
  it("compile()은 HTTP 규칙과 Stream 규칙을 동일 방식으로 필터/정렬한다", function()
    local http_rules = compile({
      http_rule({ id = "h-b", priority = 20, enabled = true }),
      http_rule({ id = "h-a", priority = 10, enabled = true }),
      http_rule({ id = "h-c", priority = 10, enabled = false }),
    })
    local stream_rules = compile({
      stream_rule({ id = "s-b", priority = 20, enabled = true }),
      stream_rule({ id = "s-a", priority = 10, enabled = true }),
      stream_rule({ id = "s-c", priority = 10, enabled = false }),
    })
    -- 양쪽 모두 enabled=false 제거, priority 오름차순
    assert.are.equal(2, #http_rules)
    assert.are.equal(2, #stream_rules)
    assert.are.equal("h-a", http_rules[1].id)
    assert.are.equal("s-a", stream_rules[1].id)
  end)

  it("evaluate()는 Stream 규칙을 올바르게 처리하지 못해도 HTTP 결과에 영향 없다", function()
    -- HTTP 평가는 evaluate()로, Stream 평가는 evaluate_stream()으로 독립 실행
    local h_rules = compile({ http_rule({ id = "allow-all", action = "allow" }) })
    local s_rules = compile({ stream_rule({ id = "deny-all", action = "deny" }) })

    local h_result = evaluator.evaluate(h_rules, {}, "deny")
    local s_result = evaluator.evaluate_stream(s_rules, {})

    assert.are.equal("allow", h_result.action)
    assert.are.equal("deny", s_result.action)
  end)
end)

-- ---------------------------------------------------------------------------
-- reset_cache() — 캐시 초기화
-- ---------------------------------------------------------------------------

describe("evaluator.reset_cache — 캐시 초기화", function()
  it("reset_cache()를 호출해도 오류가 발생하지 않는다", function()
    assert.has_no.errors(function()
      evaluator.reset_cache()
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- get_policy() — 복합 버전 키 + 서브시스템별 blob 로드
-- ---------------------------------------------------------------------------

describe("evaluator.get_policy — 복합 버전 키 동작", function()
  -- get_policy()는 ngx.shared 의존성이 있으므로 ngx mock을 구성하여 검증한다.
  -- 복합 키 형식: (http_ver or "") .. "|" .. (stream_ver or "")

  local saved_ngx

  before_each(function()
    saved_ngx = _G.ngx
    evaluator.reset_cache()
  end)

  after_each(function()
    _G.ngx = saved_ngx
    evaluator.reset_cache()
  end)

  it("ngx가 nil이면 get_policy()는 nil을 반환한다 (캐시 없음)", function()
    _G.ngx = nil
    local result = evaluator.get_policy()
    assert.is_nil(result)
  end)

  it("ngx.shared가 nil이면 get_policy()는 nil을 반환한다", function()
    _G.ngx = { shared = nil }
    local result = evaluator.get_policy()
    assert.is_nil(result)
  end)

  it("luagate_policy dict가 없으면 get_policy()는 nil을 반환한다", function()
    _G.ngx = { shared = {}, log = function() end }
    local result = evaluator.get_policy()
    assert.is_nil(result)
  end)

  it("http_ver와 stream_ver 둘 다 nil이면 정책을 로드하지 않는다", function()
    -- cold start: 아직 어떤 버전도 등록되지 않은 상태
    local dict = {}
    dict.get = function(_, _key)
      return nil
    end
    _G.ngx = { shared = { luagate_policy = dict }, log = function() end }

    local result = evaluator.get_policy()
    -- 버전 없음 → nil 반환 (기존 캐시 없음)
    assert.is_nil(result)
  end)

  it("복합 버전 키: http_ver만 있을 때 '|' 구분자가 포함된 키를 사용한다", function()
    -- http_ver=v1, stream_ver=nil → composite key = "v1|"
    -- blob이 없으면 nil 반환 (버전 변경 감지 자체가 목적)
    local store = { ["http:active_version"] = "v1" }
    local dict = {}
    dict.get = function(_, key)
      return store[key]
    end
    _G.ngx = { shared = { luagate_policy = dict }, log = function() end, ERR = 4 }

    local result = evaluator.get_policy()
    -- blob 없음 → nil (LKG fallback)
    assert.is_nil(result)
  end)

  it("복합 버전 키: stream_ver만 있을 때도 '|' 구분자가 포함된 키를 사용한다", function()
    -- http_ver=nil, stream_ver=s1 → composite key = "|s1"
    local store = { ["stream:active_version"] = "s1" }
    local dict = {}
    dict.get = function(_, key)
      return store[key]
    end
    _G.ngx = { shared = { luagate_policy = dict }, log = function() end, ERR = 4 }

    local result = evaluator.get_policy()
    -- blob 없음 → nil (LKG fallback)
    assert.is_nil(result)
  end)

  it("버전이 동일하면 캐시를 재사용한다 (shared-dict I/O 없이 캐시 반환)", function()
    -- 첫 번째 호출: blob 포함, 두 번째 호출: dict.get 호출 횟수 확인
    local get_call_count = 0
    local policy_json = '{"global":{"default_action":"deny"},"rules":[],"stream_rules":[]}'
    local store = {
      ["http:active_version"] = "v1",
      ["policy:v1:blob"] = policy_json,
    }
    local dict = {}
    dict.get = function(_, key)
      get_call_count = get_call_count + 1
      return store[key]
    end
    _G.ngx = {
      shared = { luagate_policy = dict },
      log = function() end,
      ERR = 4,
    }

    -- 첫 번째 호출: 버전 확인 + blob 로드
    local result1 = evaluator.get_policy()
    assert.is_table(result1)
    local count_after_first = get_call_count

    -- 두 번째 호출: 버전이 동일 → 캐시 반환 (get 호출이 2번만 더 발생: http/stream 버전 확인)
    local result2 = evaluator.get_policy()
    assert.is_table(result2)
    -- 두 번째 호출에서 blob을 다시 로드하지 않는다
    -- (http:active_version, stream:active_version 각 1회 = 2회 추가)
    local count_after_second = get_call_count
    local delta = count_after_second - count_after_first
    -- blob 재로드 없이 버전 확인(2회)만 발생해야 한다
    assert.is_true(delta <= 2, "캐시 히트 시 blob을 재로드해서는 안 된다 (delta=" .. delta .. ")")
  end)

  it("버전이 변경되면 캐시를 무효화하고 새 정책을 로드한다", function()
    local version = { http = "v1" }
    local policy_v1 = '{"global":{"default_action":"deny"},"rules":[],"stream_rules":[]}'
    local policy_v2 = '{"global":{"default_action":"allow"},"rules":[],"stream_rules":[]}'
    local store = {
      ["http:active_version"] = "v1",
      ["policy:v1:blob"] = policy_v1,
      ["policy:v2:blob"] = policy_v2,
    }
    local dict = {}
    dict.get = function(_, key)
      if key == "http:active_version" then
        return version.http
      end
      return store[key]
    end
    _G.ngx = {
      shared = { luagate_policy = dict },
      log = function() end,
      ERR = 4,
    }

    -- 첫 번째 로드: v1 정책
    local result1 = evaluator.get_policy()
    assert.is_table(result1)
    assert.are.equal("deny", result1.global.default_action)

    -- 버전 변경
    version.http = "v2"
    store["http:active_version"] = "v2"

    -- 두 번째 로드: v2 정책으로 갱신되어야 한다
    local result2 = evaluator.get_policy()
    assert.is_table(result2)
    assert.are.equal("allow", result2.global.default_action)
  end)

  it("stream active_version만 변경되면 stream_rules는 새 stream blob에서 로드한다", function()
    local policy_v1 = '{"global":{"default_action":"deny"},'
      .. '"rules":[{"id":"http-v1","priority":10,"action":"allow","enabled":true}],'
      .. '"stream_rules":[{"id":"stream-old","priority":10,"action":"deny","enabled":true}]}'
    local policy_s2 = '{"global":{"default_action":"allow"},'
      .. '"rules":[{"id":"http-from-stream-blob","priority":5,"action":"deny","enabled":true}],'
      .. '"stream_rules":[{"id":"stream-new","priority":5,"action":"proxy","enabled":true,'
      .. '"upstream":"backend:8443"}]}'
    local store = {
      ["http:active_version"] = "v1",
      ["stream:active_version"] = "s1",
      ["policy:v1:blob"] = policy_v1,
      ["policy:s1:blob"] = policy_v1,
      ["policy:s2:blob"] = policy_s2,
    }
    local dict = {}
    dict.get = function(_, key)
      return store[key]
    end
    _G.ngx = {
      shared = { luagate_policy = dict },
      log = function() end,
      ERR = 4,
    }

    local result1 = evaluator.get_policy()
    assert.are.equal("http-v1", result1.rules[1].id)
    assert.are.equal("stream-old", result1.stream_rules[1].id)

    store["stream:active_version"] = "s2"

    local result2 = evaluator.get_policy()
    assert.is_table(result2)
    assert.are.equal("deny", result2.global.default_action)
    assert.are.equal("http-v1", result2.rules[1].id)
    assert.are.equal("stream-new", result2.stream_rules[1].id)
    assert.are.equal("http-v1", result2._compiled_http[1].id)
    assert.are.equal("stream-new", result2._compiled_stream[1].id)
  end)

  it("stream active_version이 없으면 HTTP blob의 stream_rules 대신 stream LKG를 유지한다", function()
    local policy_v1 = '{"global":{"default_action":"deny"},'
      .. '"rules":[{"id":"http-v1","priority":10,"action":"allow","enabled":true}],'
      .. '"stream_rules":[{"id":"stream-lkg","priority":10,"action":"deny","enabled":true}]}'
    local policy_v2 = '{"global":{"default_action":"allow"},'
      .. '"rules":[{"id":"http-v2","priority":5,"action":"deny","enabled":true}],'
      .. '"stream_rules":[{"id":"stream-from-http-blob","priority":5,"action":"proxy","enabled":true,'
      .. '"upstream":"backend:9443"}]}'
    local store = {
      ["http:active_version"] = "v1",
      ["stream:active_version"] = "s1",
      ["policy:v1:blob"] = policy_v1,
      ["policy:s1:blob"] = policy_v1,
      ["policy:v2:blob"] = policy_v2,
    }
    local dict = {}
    dict.get = function(_, key)
      return store[key]
    end
    _G.ngx = {
      shared = { luagate_policy = dict },
      log = function() end,
      ERR = 4,
    }

    local result1 = evaluator.get_policy()
    assert.are.equal("http-v1", result1.rules[1].id)
    assert.are.equal("stream-lkg", result1.stream_rules[1].id)

    store["http:active_version"] = "v2"
    store["stream:active_version"] = nil

    local result2 = evaluator.get_policy()
    assert.is_table(result2)
    assert.are.equal("allow", result2.global.default_action)
    assert.are.equal("http-v2", result2.rules[1].id)
    assert.are.equal("stream-lkg", result2.stream_rules[1].id)
    assert.are.equal("http-v2", result2._compiled_http[1].id)
    assert.are.equal("stream-lkg", result2._compiled_stream[1].id)
  end)

  it("get_policy() 반환 정책에 _compiled_http, _compiled_stream 필드가 있다", function()
    local policy_json = '{"global":{"default_action":"deny"},"rules":[],"stream_rules":[]}'
    local store = {
      ["http:active_version"] = "v1",
      ["policy:v1:blob"] = policy_json,
    }
    local dict = {}
    dict.get = function(_, key)
      return store[key]
    end
    _G.ngx = {
      shared = { luagate_policy = dict },
      log = function() end,
      ERR = 4,
    }

    local result = evaluator.get_policy()
    assert.is_table(result)
    assert.is_table(result._compiled_http)
    assert.is_table(result._compiled_stream)
  end)

  it("reset_cache() 이후 get_policy()는 캐시 없이 새로 시도한다", function()
    _G.ngx = nil
    evaluator.reset_cache()

    -- ngx 없으므로 nil 반환 (캐시도 nil이므로)
    local result = evaluator.get_policy()
    assert.is_nil(result)
  end)
end)
