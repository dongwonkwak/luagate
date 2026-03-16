--- Unit tests for lua/luagate/policy/validator.lua
-- Implementation: lua/luagate/policy/validator.lua
-- Tests: tests/unit/policy/validator_spec.lua

local validator = require("luagate.policy.validator")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Build a minimal valid policy table.
local function minimal_policy()
  return {
    global = { default_action = "deny" },
    rules = {},
    stream_rules = {},
  }
end

-- Sentinel used to explicitly set a key to nil in rule builder helpers.
-- Lua tables cannot distinguish "key set to nil" from "key absent" when using
-- pairs(), so callers pass REMOVE to mean "delete this key from the result".
local REMOVE = {}

--- Build a valid HTTP rule with required fields only.
-- Pass REMOVE as a value to explicitly remove a field from the result.
local function http_rule(overrides)
  local r = {
    id = "test-http-rule",
    priority = 10,
    action = "allow",
    enabled = true,
    original_index = 1,
    tags = {},
  }
  if overrides then
    for k, v in pairs(overrides) do
      if v == REMOVE then
        r[k] = nil
      else
        r[k] = v
      end
    end
  end
  return r
end

--- Build a valid Stream rule with required fields only.
-- Pass REMOVE as a value to explicitly remove a field from the result.
local function stream_rule(overrides)
  local r = {
    id = "test-stream-rule",
    priority = 10,
    action = "deny",
    enabled = true,
    original_index = 1,
    tags = {},
  }
  if overrides then
    for k, v in pairs(overrides) do
      if v == REMOVE then
        r[k] = nil
      else
        r[k] = v
      end
    end
  end
  return r
end

-- ---------------------------------------------------------------------------
-- Tests: global section
-- ---------------------------------------------------------------------------

describe("validator.validate — global section", function()
  it("accepts valid policy with default_action = deny", function()
    local p = minimal_policy()
    local _, err = validator.validate(p)
    assert.is_nil(err)
    assert.are.equal(_, p)
  end)

  it("accepts valid policy with default_action = allow", function()
    local p = minimal_policy()
    p.global.default_action = "allow"
    local _, err = validator.validate(p)
    assert.is_nil(err)
    assert.are.equal(_, p)
  end)

  it("rejects policy missing 'global' section", function()
    local p = { rules = {}, stream_rules = {} }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("global", err)
  end)

  it("rejects policy with global.default_action missing", function()
    local p = minimal_policy()
    p.global.default_action = nil
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("default_action", err)
  end)

  it("rejects policy with invalid default_action value", function()
    local p = minimal_policy()
    p.global.default_action = "pass"
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("default_action", err)
  end)

  it("rejects non-table input", function()
    local _, err = validator.validate("not a table")
    assert.is_nil(_)
    assert.is_string(err)
  end)

  it("rejects nil input", function()
    local _, err = validator.validate(nil)
    assert.is_nil(_)
    assert.is_string(err)
  end)
end)

-- ---------------------------------------------------------------------------
-- Tests: HTTP rule validation
-- ---------------------------------------------------------------------------

describe("validator.validate — HTTP rules", function()
  it("accepts a valid HTTP rule", function()
    local p = minimal_policy()
    p.rules = { http_rule() }
    local _, err = validator.validate(p)
    assert.is_nil(err)
    assert.is_table(_)
  end)

  it("rejects HTTP rule with missing id", function()
    local p = minimal_policy()
    p.rules = { http_rule({ id = REMOVE }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("id", err)
  end)

  it("rejects HTTP rule with empty string id", function()
    local p = minimal_policy()
    p.rules = { http_rule({ id = "" }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
  end)

  it("rejects HTTP rule with missing priority", function()
    local p = minimal_policy()
    p.rules = { http_rule({ priority = REMOVE }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("priority", err)
  end)

  it("rejects HTTP rule with non-integer priority", function()
    local p = minimal_policy()
    p.rules = { http_rule({ priority = 1.5 }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("priority", err)
  end)

  it("rejects HTTP rule with invalid action", function()
    local p = minimal_policy()
    p.rules = { http_rule({ action = "proxy" }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("action", err)
  end)

  it("accepts HTTP rule with action = deny", function()
    local p = minimal_policy()
    p.rules = { http_rule({ action = "deny" }) }
    local _, err = validator.validate(p)
    assert.is_nil(err)
  end)

  it("accepts HTTP rule with enabled = false (schema validation still runs)", function()
    local p = minimal_policy()
    p.rules = { http_rule({ enabled = false }) }
    local _, err = validator.validate(p)
    assert.is_nil(err)
  end)

  it("rejects HTTP rule with enabled as non-boolean", function()
    local p = minimal_policy()
    p.rules = { http_rule({ enabled = "yes" }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("enabled", err)
  end)

  it("accepts HTTP rule with full valid scope", function()
    local p = minimal_policy()
    p.rules = {
      http_rule({
        scope = {
          path = "/api/v1/*",
          host = "api.example.com",
          method = "GET",
          src_ip_cidr = "10.0.0.0/8",
          query_param = { q = "test" },
          header = { ["X-Role"] = "admin" },
        },
      }),
    }
    local _, err = validator.validate(p)
    assert.is_nil(err)
  end)

  it("rejects HTTP rule with malformed src_ip_cidr (no prefix)", function()
    local p = minimal_policy()
    p.rules = { http_rule({ scope = { src_ip_cidr = "10.0.0.0" } }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("src_ip_cidr", err)
  end)

  it("rejects HTTP rule with malformed src_ip_cidr (not-a-cidr)", function()
    local p = minimal_policy()
    p.rules = { http_rule({ scope = { src_ip_cidr = "not-a-cidr" } }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("src_ip_cidr", err)
  end)

  it("accepts HTTP rule with valid src_ip_cidr", function()
    local p = minimal_policy()
    p.rules = { http_rule({ scope = { src_ip_cidr = "192.168.0.0/16" } }) }
    local _, err = validator.validate(p)
    assert.is_nil(err)
  end)

  it("accepts HTTP rule with method as list", function()
    local p = minimal_policy()
    p.rules = { http_rule({ scope = { method = { "GET", "POST" } } }) }
    local _, err = validator.validate(p)
    assert.is_nil(err)
  end)

  it("rejects HTTP rule with invalid scope.method type", function()
    local p = minimal_policy()
    p.rules = { http_rule({ scope = { method = 42 } }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("method", err)
  end)

  it("rejects HTTP rule with non-table scope", function()
    local p = minimal_policy()
    p.rules = { http_rule({ scope = "invalid" }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("scope", err)
  end)

  it("accepts HTTP rule with nil scope (catch-all)", function()
    local p = minimal_policy()
    p.rules = { http_rule({ scope = nil }) }
    local _, err = validator.validate(p)
    assert.is_nil(err)
  end)

  it("rejects HTTP rule with non-string description", function()
    local p = minimal_policy()
    p.rules = { http_rule({ description = 42 }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("description", err)
  end)

  it("rejects HTTP rule with non-list tags", function()
    local p = minimal_policy()
    p.rules = { http_rule({ tags = "security" }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("tags", err)
  end)

  it("rejects HTTP rule with non-string element in tags list", function()
    local p = minimal_policy()
    p.rules = { http_rule({ tags = { "valid", 42 } }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("tags", err)
  end)

  it("rejects HTTP rule with non-string scope.src_ip_cidr", function()
    local p = minimal_policy()
    p.rules = { http_rule({ scope = { src_ip_cidr = 12345 } }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("src_ip_cidr", err)
  end)

  it("rejects HTTP rule with non-string scope.host", function()
    local p = minimal_policy()
    p.rules = { http_rule({ scope = { host = true } }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("host", err)
  end)

  it("rejects HTTP rule with non-string scope.path", function()
    local p = minimal_policy()
    p.rules = { http_rule({ scope = { path = 123 } }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("path", err)
  end)

  it("rejects HTTP rule with non-string element in scope.method list", function()
    local p = minimal_policy()
    p.rules = { http_rule({ scope = { method = { "GET", 99 } } }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("method", err)
  end)

  it("rejects HTTP rule with non-map scope.query_param", function()
    local p = minimal_policy()
    p.rules = { http_rule({ scope = { query_param = "not-a-map" } }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("query_param", err)
  end)

  it("rejects HTTP rule with non-map scope.header", function()
    local p = minimal_policy()
    p.rules = { http_rule({ scope = { header = 123 } }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("header", err)
  end)

  it("rejects policy.rules when it is not a list", function()
    local p = minimal_policy()
    p.rules = "not-a-list"
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("rules", err)
  end)
end)

-- ---------------------------------------------------------------------------
-- Tests: Stream rule validation
-- ---------------------------------------------------------------------------

describe("validator.validate — Stream rules", function()
  it("accepts a valid Stream deny rule", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule() }
    local _, err = validator.validate(p)
    assert.is_nil(err)
  end)

  it("accepts a valid Stream proxy rule with upstream", function()
    local p = minimal_policy()
    p.stream_rules = {
      stream_rule({ action = "proxy", upstream = "backend:8443" }),
    }
    local _, err = validator.validate(p)
    assert.is_nil(err)
  end)

  it("rejects Stream proxy rule without upstream", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ action = "proxy", upstream = REMOVE }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("upstream", err)
  end)

  it("rejects Stream proxy rule with empty upstream", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ action = "proxy", upstream = "" }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("upstream", err)
  end)

  it("rejects Stream proxy rule with upstream missing port (no colon)", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ action = "proxy", upstream = "backend" }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("upstream", err)
  end)

  it("rejects Stream proxy rule with upstream having empty port (trailing colon)", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ action = "proxy", upstream = "host:" }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("upstream", err)
  end)

  it("rejects Stream proxy rule with upstream having empty host (leading colon)", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ action = "proxy", upstream = ":8080" }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("upstream", err)
  end)

  it("accepts Stream proxy rule with valid upstream 'host:port'", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ action = "proxy", upstream = "backend:9000" }) }
    local _, err = validator.validate(p)
    assert.is_nil(err)
  end)

  it("accepts Stream proxy rule with valid upstream IP:port", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ action = "proxy", upstream = "192.168.1.1:443" }) }
    local _, err = validator.validate(p)
    assert.is_nil(err)
  end)

  it("rejects Stream rule with invalid action", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ action = "allow" }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("action", err)
  end)

  it("rejects Stream rule with missing id", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ id = REMOVE }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("id", err)
  end)

  it("rejects Stream rule with missing priority", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ priority = REMOVE }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("priority", err)
  end)

  it("accepts Stream rule with enabled = false", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ enabled = false }) }
    local _, err = validator.validate(p)
    assert.is_nil(err)
  end)

  it("accepts Stream rule with integer dst_port", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ scope = { dst_port = 443 } }) }
    local _, err = validator.validate(p)
    assert.is_nil(err)
  end)

  it("accepts Stream rule with range dst_port string", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ scope = { dst_port = "1024-65535" } }) }
    local _, err = validator.validate(p)
    assert.is_nil(err)
  end)

  it("rejects Stream rule with invalid dst_port type", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ scope = { dst_port = true } }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("dst_port", err)
  end)

  it("rejects Stream rule with dst_port range missing dash (bare string)", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ scope = { dst_port = "abc" } }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("dst_port", err)
  end)

  it("rejects Stream rule with dst_port range in reverse order (lo > hi)", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ scope = { dst_port = "100-50" } }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("dst_port", err)
  end)

  it("accepts Stream rule with equal lo and hi in dst_port range", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ scope = { dst_port = "443-443" } }) }
    local _, err = validator.validate(p)
    assert.is_nil(err)
  end)

  it("rejects Stream rule with malformed src_ip_cidr (no prefix)", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ scope = { src_ip_cidr = "10.0.0.1" } }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("src_ip_cidr", err)
  end)

  it("rejects Stream rule with malformed src_ip_cidr (not-a-cidr)", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ scope = { src_ip_cidr = "not-a-cidr" } }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("src_ip_cidr", err)
  end)

  it("accepts Stream rule with valid src_ip_cidr", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ scope = { src_ip_cidr = "10.0.0.0/8" } }) }
    local _, err = validator.validate(p)
    assert.is_nil(err)
  end)

  it("accepts Stream rule with valid detected_protocol", function()
    local protocols = { "tls", "http", "raw" }
    for _, proto in ipairs(protocols) do
      local p = minimal_policy()
      p.stream_rules = { stream_rule({ scope = { detected_protocol = proto } }) }
      local _, err = validator.validate(p)
      assert.is_nil(err, "expected no error for protocol: " .. proto)
    end
  end)

  it("rejects Stream rule with invalid detected_protocol", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ scope = { detected_protocol = "grpc" } }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("detected_protocol", err)
  end)

  it("rejects Stream rule with non-boolean enabled", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ enabled = "true" }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("enabled", err)
  end)

  it("rejects Stream rule with non-string description", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ description = 99 }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("description", err)
  end)

  it("rejects Stream rule with non-list tags", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ tags = "security" }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("tags", err)
  end)

  it("rejects Stream rule with non-string element in tags list", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ tags = { "valid", false } }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("tags", err)
  end)

  it("rejects Stream rule with non-table scope", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ scope = "invalid-scope" }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("scope", err)
  end)

  it("rejects Stream rule with non-string scope.src_ip_cidr", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ scope = { src_ip_cidr = 123 } }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("src_ip_cidr", err)
  end)

  it("rejects Stream rule with non-string scope.sni", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ scope = { sni = 443 } }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("sni", err)
  end)

  it("rejects Stream rule with non-integer float dst_port", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ scope = { dst_port = 443.5 } }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("dst_port", err)
  end)

  it("rejects policy.stream_rules when it is not a list", function()
    local p = minimal_policy()
    p.stream_rules = "not-a-list"
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("stream_rules", err)
  end)

  it("accepts Stream deny rule without upstream (upstream not required for deny)", function()
    local p = minimal_policy()
    p.stream_rules = { stream_rule({ action = "deny", upstream = REMOVE }) }
    local _, err = validator.validate(p)
    assert.is_nil(err)
  end)
end)

-- ---------------------------------------------------------------------------
-- Tests: id uniqueness (HTTP + Stream combined)
-- ---------------------------------------------------------------------------

describe("validator.validate — id uniqueness", function()
  it("rejects duplicate id within HTTP rules", function()
    local p = minimal_policy()
    p.rules = {
      http_rule({ id = "dup-id" }),
      http_rule({ id = "dup-id" }),
    }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("duplicate", err)
    assert.matches("dup%-id", err)
  end)

  it("rejects duplicate id within Stream rules", function()
    local p = minimal_policy()
    p.stream_rules = {
      stream_rule({ id = "dup-id" }),
      stream_rule({ id = "dup-id" }),
    }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("duplicate", err)
  end)

  it("rejects duplicate id across HTTP and Stream rules", function()
    local p = minimal_policy()
    p.rules = { http_rule({ id = "shared-id" }) }
    p.stream_rules = { stream_rule({ id = "shared-id" }) }
    local _, err = validator.validate(p)
    assert.is_nil(_)
    assert.is_string(err)
    assert.matches("duplicate", err)
    assert.matches("shared%-id", err)
  end)

  it("accepts distinct ids across HTTP and Stream rules", function()
    local p = minimal_policy()
    p.rules = { http_rule({ id = "http-1" }), http_rule({ id = "http-2" }) }
    p.stream_rules = { stream_rule({ id = "stream-1" }) }
    local _, err = validator.validate(p)
    assert.is_nil(err)
  end)
end)

-- ---------------------------------------------------------------------------
-- Tests: pass-through behaviour
-- ---------------------------------------------------------------------------

describe("validator.validate — pass-through", function()
  it("returns the same table reference on success", function()
    local p = minimal_policy()
    local _, err = validator.validate(p)
    assert.is_nil(err)
    assert.are.equal(_, p)
  end)

  it("accepts policy with no rules or stream_rules keys", function()
    local p = { global = { default_action = "deny" } }
    local _, err = validator.validate(p)
    assert.is_nil(err)
    assert.is_table(_)
  end)
end)
