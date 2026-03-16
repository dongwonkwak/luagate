--- Unit tests for lua/luagate/policy/parser.lua
-- Implementation: lua/luagate/policy/parser.lua
-- Tests: tests/unit/policy/parser_spec.lua
--
-- lyaml is stubbed with a minimal pure-Lua table so these tests can run
-- in busted without an OpenResty environment.  Only the interface that
-- parser.lua uses is provided: lyaml.load(str) → table.

-- ---------------------------------------------------------------------------
-- Stub lyaml before the module is loaded.
-- We intercept package.preload so that require("lyaml") returns our stub.
-- ---------------------------------------------------------------------------

-- We store the raw YAML → table mapping in this registry so individual tests
-- can control what "lyaml.load" returns for a given input string.
local _lyaml_registry = {}
local _lyaml_error_on_next = nil

package.preload["lyaml"] = function()
  return {
    load = function(str)
      if _lyaml_error_on_next then
        local msg = _lyaml_error_on_next
        _lyaml_error_on_next = nil
        error(msg)
      end
      local result = _lyaml_registry[str]
      if result == nil then
        error("lyaml stub: no mapping for input string")
      end
      return result
    end,
  }
end

local parser = require("luagate.policy.parser")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Register a (yaml_string → table) mapping for the stub.
local function register(yaml_str, tbl)
  _lyaml_registry[yaml_str] = tbl
end

--- Make the stub throw on the next lyaml.load call.
local function lyaml_will_error(msg)
  _lyaml_error_on_next = msg or "stub parse error"
end

--- Build the canonical raw YAML table that lyaml.load would return
--- for a minimal valid policy.
local function raw_minimal()
  return {
    version = "1.0",
    global = { default_action = "deny" },
    rules = {},
    stream_rules = {},
  }
end

-- ---------------------------------------------------------------------------
-- Tests: parse_string — basic behaviour
-- ---------------------------------------------------------------------------

describe("parser.parse_string — input validation", function()
  it("rejects nil input", function()
    local result, err = parser.parse_string(nil)
    assert.is_nil(result)
    assert.is_string(err)
  end)

  it("rejects non-string input", function()
    local result, err = parser.parse_string(42)
    assert.is_nil(result)
    assert.is_string(err)
  end)

  it("rejects empty string", function()
    local result, err = parser.parse_string("")
    assert.is_nil(result)
    assert.is_string(err)
  end)
end)

describe("parser.parse_string — lyaml error handling", function()
  it("returns nil, err when lyaml.load throws", function()
    local yaml = "bad: yaml: !!!"
    lyaml_will_error("scanner error at line 1")
    local result, err = parser.parse_string(yaml)
    assert.is_nil(result)
    assert.is_string(err)
    assert.matches("YAML parse error", err)
  end)
end)

describe("parser.parse_string — successful parse", function()
  it("returns a policy table for a minimal valid YAML", function()
    local yaml = "minimal_valid"
    register(yaml, raw_minimal())
    local result, err = parser.parse_string(yaml)
    assert.is_nil(err)
    assert.is_table(result)
  end)

  it("preserves policy version field", function()
    local yaml = "with_version"
    register(yaml, {
      version = "2.0",
      global = { default_action = "allow" },
    })
    local result, err = parser.parse_string(yaml)
    assert.is_nil(err)
    assert.are.equal("2.0", result.version)
  end)

  it("sets global.default_action correctly", function()
    local yaml = "global_allow"
    register(yaml, { global = { default_action = "allow" } })
    local result, err = parser.parse_string(yaml)
    assert.is_nil(err)
    assert.are.equal("allow", result.global.default_action)
  end)

  it("returns empty rules list when 'rules' key is absent", function()
    local yaml = "no_rules"
    register(yaml, { global = { default_action = "deny" } })
    local result, err = parser.parse_string(yaml)
    assert.is_nil(err)
    assert.is_table(result.rules)
    assert.are.equal(0, #result.rules)
  end)

  it("returns empty stream_rules list when 'stream_rules' key is absent", function()
    local yaml = "no_stream_rules"
    register(yaml, { global = { default_action = "deny" } })
    local result, err = parser.parse_string(yaml)
    assert.is_nil(err)
    assert.is_table(result.stream_rules)
    assert.are.equal(0, #result.stream_rules)
  end)
end)

-- ---------------------------------------------------------------------------
-- Tests: parse_http_rules
-- ---------------------------------------------------------------------------

describe("parser.parse_http_rules", function()
  it("returns empty list for nil input", function()
    local rules = parser.parse_http_rules(nil)
    assert.is_table(rules)
    assert.are.equal(0, #rules)
  end)

  it("sets original_index to 1-based source position", function()
    local raw = {
      { id = "r1", priority = 10, action = "allow" },
      { id = "r2", priority = 20, action = "deny" },
    }
    local rules = parser.parse_http_rules(raw)
    assert.are.equal(1, rules[1].original_index)
    assert.are.equal(2, rules[2].original_index)
  end)

  it("sets original_index for disabled rules too", function()
    local raw = {
      { id = "enabled-rule", priority = 10, action = "allow", enabled = true },
      { id = "disabled-rule", priority = 20, action = "deny", enabled = false },
    }
    local rules = parser.parse_http_rules(raw)
    assert.are.equal(1, rules[1].original_index)
    assert.are.equal(2, rules[2].original_index)
  end)

  it("defaults enabled to true when absent", function()
    local raw = { { id = "r1", priority = 10, action = "allow" } }
    local rules = parser.parse_http_rules(raw)
    assert.is_true(rules[1].enabled)
  end)

  it("preserves enabled = false", function()
    local raw = { { id = "r1", priority = 10, action = "allow", enabled = false } }
    local rules = parser.parse_http_rules(raw)
    assert.is_false(rules[1].enabled)
  end)

  it("defaults tags to empty list when absent", function()
    local raw = { { id = "r1", priority = 10, action = "allow" } }
    local rules = parser.parse_http_rules(raw)
    assert.is_table(rules[1].tags)
    assert.are.equal(0, #rules[1].tags)
  end)

  it("preserves all rule fields", function()
    local raw = {
      {
        id = "allow-health",
        description = "health check",
        priority = 10,
        action = "allow",
        tags = { "ops" },
        scope = { path = "/health", method = "GET" },
      },
    }
    local rules = parser.parse_http_rules(raw)
    local r = rules[1]
    assert.are.equal("allow-health", r.id)
    assert.are.equal("health check", r.description)
    assert.are.equal(10, r.priority)
    assert.are.equal("allow", r.action)
    assert.are.equal("ops", r.tags[1])
    assert.are.equal("/health", r.scope.path)
    assert.are.equal("GET", r.scope.method)
  end)

  it("does not mutate the original raw table", function()
    local raw = { { id = "r1", priority = 5, action = "allow" } }
    parser.parse_http_rules(raw)
    -- original_index should NOT be set on the raw input
    assert.is_nil(raw[1].original_index)
  end)
end)

-- ---------------------------------------------------------------------------
-- Tests: parse_stream_rules
-- ---------------------------------------------------------------------------

describe("parser.parse_stream_rules", function()
  it("returns empty list for nil input", function()
    local rules = parser.parse_stream_rules(nil)
    assert.is_table(rules)
    assert.are.equal(0, #rules)
  end)

  it("sets original_index to 1-based source position", function()
    local raw = {
      { id = "s1", priority = 10, action = "deny" },
      { id = "s2", priority = 20, action = "proxy", upstream = "backend:8443" },
    }
    local rules = parser.parse_stream_rules(raw)
    assert.are.equal(1, rules[1].original_index)
    assert.are.equal(2, rules[2].original_index)
  end)

  it("defaults enabled to true when absent", function()
    local raw = { { id = "s1", priority = 10, action = "deny" } }
    local rules = parser.parse_stream_rules(raw)
    assert.is_true(rules[1].enabled)
  end)

  it("preserves upstream field for proxy rules", function()
    local raw = {
      { id = "s1", priority = 10, action = "proxy", upstream = "backend:9000" },
    }
    local rules = parser.parse_stream_rules(raw)
    assert.are.equal("backend:9000", rules[1].upstream)
  end)

  it("preserves scope fields", function()
    local raw = {
      {
        id = "s1",
        priority = 10,
        action = "deny",
        scope = { dst_port = 443, detected_protocol = "tls" },
      },
    }
    local rules = parser.parse_stream_rules(raw)
    assert.are.equal(443, rules[1].scope.dst_port)
    assert.are.equal("tls", rules[1].scope.detected_protocol)
  end)

  it("does not mutate the original raw table", function()
    local raw = { { id = "s1", priority = 5, action = "deny" } }
    parser.parse_stream_rules(raw)
    assert.is_nil(raw[1].original_index)
  end)
end)

-- ---------------------------------------------------------------------------
-- Tests: parse_string — HTTP and Stream rules integration
-- ---------------------------------------------------------------------------

describe("parser.parse_string — rules parsing", function()
  it("parses HTTP and Stream rules correctly", function()
    local yaml = "full_policy"
    register(yaml, {
      version = "1.0",
      global = { default_action = "deny" },
      rules = {
        {
          id = "allow-health",
          priority = 10,
          action = "allow",
          scope = { path = "/health", method = "GET" },
          tags = { "ops" },
        },
        {
          id = "block-admin",
          priority = 20,
          action = "deny",
          scope = { path = "/admin/*" },
          enabled = false,
        },
      },
      stream_rules = {
        {
          id = "allow-tls-443",
          priority = 10,
          action = "proxy",
          upstream = "backend:8443",
          scope = { dst_port = 443, detected_protocol = "tls" },
        },
      },
    })

    local result, err = parser.parse_string(yaml)
    assert.is_nil(err)
    assert.is_table(result)

    -- HTTP rules
    assert.are.equal(2, #result.rules)
    assert.are.equal("allow-health", result.rules[1].id)
    assert.are.equal(1, result.rules[1].original_index)
    assert.is_true(result.rules[1].enabled)
    assert.are.equal("block-admin", result.rules[2].id)
    assert.are.equal(2, result.rules[2].original_index)
    assert.is_false(result.rules[2].enabled)

    -- Stream rules
    assert.are.equal(1, #result.stream_rules)
    assert.are.equal("allow-tls-443", result.stream_rules[1].id)
    assert.are.equal("backend:8443", result.stream_rules[1].upstream)
    assert.are.equal(1, result.stream_rules[1].original_index)
  end)
end)

-- ---------------------------------------------------------------------------
-- Tests: parse_file (filesystem I/O with temporary file)
-- ---------------------------------------------------------------------------

describe("parser.parse_file — error cases", function()
  it("rejects nil filepath", function()
    local result, err = parser.parse_file(nil)
    assert.is_nil(result)
    assert.is_string(err)
  end)

  it("rejects empty filepath", function()
    local result, err = parser.parse_file("")
    assert.is_nil(result)
    assert.is_string(err)
  end)

  it("returns nil, err when file does not exist", function()
    local result, err = parser.parse_file("/nonexistent/path/policy.yaml")
    assert.is_nil(result)
    assert.is_string(err)
    assert.matches("cannot open", err)
  end)
end)

describe("parser.parse_file — successful read", function()
  local tmpfile

  before_each(function()
    -- Write a temp file that lyaml stub will map via parse_string
    tmpfile = os.tmpname()
  end)

  after_each(function()
    os.remove(tmpfile)
  end)

  it("reads file content and delegates to parse_string", function()
    -- Write the sentinel string into the temp file
    local sentinel = "sentinel_yaml_for_file_test"
    local f = io.open(tmpfile, "w")
    f:write(sentinel)
    f:close()

    -- Register the sentinel → table mapping
    register(sentinel, {
      global = { default_action = "deny" },
    })

    local result, err = parser.parse_file(tmpfile)
    assert.is_nil(err)
    assert.is_table(result)
    assert.are.equal("deny", result.global.default_action)
  end)

  it("returns nil, err for an empty file", function()
    local f = io.open(tmpfile, "w")
    f:write("")
    f:close()

    local result, err = parser.parse_file(tmpfile)
    assert.is_nil(result)
    assert.is_string(err)
    assert.matches("empty", err)
  end)
end)
