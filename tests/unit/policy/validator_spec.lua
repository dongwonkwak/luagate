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
