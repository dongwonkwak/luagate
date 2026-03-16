--- Policy schema validator for LuaGate.
-- Validates parsed YAML tables against the canonical schema defined in
-- docs/spec/policy-engine.md §2 and ADR-002.
--
-- Design rules (all enforced here):
--   - Returns nil, err on any validation failure (never calls error())
--   - All-or-nothing: one failure → whole policy rejected
--   - id uniqueness is checked across http rules + stream_rules combined
--   - enabled=false rules ARE validated (but excluded from conflict detection)
--   - action enum is subsystem-specific (HTTP: allow|deny, Stream: proxy|deny)
--   - stream proxy rules MUST have an upstream field
--
-- Implementation: lua/luagate/policy/validator.lua
-- Tests: tests/unit/policy/validator_spec.lua

local _M = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Check that `value` is a non-empty string.
local function is_nonempty_string(value)
  return type(value) == "string" and #value > 0
end

--- Check that `value` is an integer (number with no fractional part).
local function is_integer(value)
  return type(value) == "number" and value == math.floor(value)
end

--- Validate the `scope` table for an HTTP rule.
-- All scope keys are optional (omitted = wildcard).
-- Returns nil on success, error string on failure.
local function validate_http_scope(scope, rule_id)
  if scope == nil then
    return nil -- catch-all, valid
  end
  if type(scope) ~= "table" then
    return "rule '" .. rule_id .. "': scope must be a map"
  end

  -- path: string
  if scope.path ~= nil and type(scope.path) ~= "string" then
    return "rule '" .. rule_id .. "': scope.path must be a string"
  end

  -- host: string
  if scope.host ~= nil and type(scope.host) ~= "string" then
    return "rule '" .. rule_id .. "': scope.host must be a string"
  end

  -- method: string or list of strings
  if scope.method ~= nil then
    local mt = type(scope.method)
    if mt == "table" then
      for i, m in ipairs(scope.method) do
        if type(m) ~= "string" then
          return "rule '" .. rule_id .. "': scope.method[" .. i .. "] must be a string"
        end
      end
    elseif mt ~= "string" then
      return "rule '" .. rule_id .. "': scope.method must be a string or list"
    end
  end

  -- src_ip_cidr: string
  if scope.src_ip_cidr ~= nil and type(scope.src_ip_cidr) ~= "string" then
    return "rule '" .. rule_id .. "': scope.src_ip_cidr must be a string"
  end

  -- query_param: map (string → string)
  if scope.query_param ~= nil then
    if type(scope.query_param) ~= "table" then
      return "rule '" .. rule_id .. "': scope.query_param must be a map"
    end
    for k, v in pairs(scope.query_param) do
      if type(k) ~= "string" or type(v) ~= "string" then
        return "rule '" .. rule_id .. "': scope.query_param keys and values must be strings"
      end
    end
  end

  -- header: map (string → string)
  if scope.header ~= nil then
    if type(scope.header) ~= "table" then
      return "rule '" .. rule_id .. "': scope.header must be a map"
    end
    for k, v in pairs(scope.header) do
      if type(k) ~= "string" or type(v) ~= "string" then
        return "rule '" .. rule_id .. "': scope.header keys and values must be strings"
      end
    end
  end

  return nil
end

--- Validate the `scope` table for a Stream rule.
-- Returns nil on success, error string on failure.
local function validate_stream_scope(scope, rule_id)
  if scope == nil then
    return nil -- catch-all, valid
  end
  if type(scope) ~= "table" then
    return "rule '" .. rule_id .. "': scope must be a map"
  end

  -- src_ip_cidr: string
  if scope.src_ip_cidr ~= nil and type(scope.src_ip_cidr) ~= "string" then
    return "rule '" .. rule_id .. "': scope.src_ip_cidr must be a string"
  end

  -- dst_port: string ("lo-hi" range) or integer (exact)
  if scope.dst_port ~= nil then
    local dt = type(scope.dst_port)
    if dt == "number" then
      if not is_integer(scope.dst_port) then
        return "rule '" .. rule_id .. "': scope.dst_port must be an integer"
      end
    elseif dt ~= "string" then
      -- "string" accepts "lo-hi" range format — content validated at evaluation time
      return "rule '" .. rule_id .. "': scope.dst_port must be a string or integer"
    end
  end

  -- detected_protocol: string enum (tls | http | raw)
  if scope.detected_protocol ~= nil then
    if type(scope.detected_protocol) ~= "string" then
      return "rule '" .. rule_id .. "': scope.detected_protocol must be a string"
    end
    local valid_protocols = { tls = true, http = true, raw = true }
    if not valid_protocols[scope.detected_protocol] then
      return "rule '" .. rule_id .. "': scope.detected_protocol must be one of: tls, http, raw"
    end
  end

  -- sni: string
  if scope.sni ~= nil and type(scope.sni) ~= "string" then
    return "rule '" .. rule_id .. "': scope.sni must be a string"
  end

  return nil
end

--- Validate a single HTTP rule table.
-- Returns nil on success, error string on failure.
local function validate_http_rule(rule)
  -- id: required, non-empty string
  if not is_nonempty_string(rule.id) then
    return "http rule is missing required field 'id' (must be a non-empty string)"
  end

  -- priority: required, integer
  if not is_integer(rule.priority) then
    return "http rule '" .. tostring(rule.id) .. "': 'priority' must be an integer"
  end

  -- action: required, allow | deny
  if rule.action ~= "allow" and rule.action ~= "deny" then
    return "http rule '" .. rule.id .. "': 'action' must be 'allow' or 'deny', got: " .. tostring(rule.action)
  end

  -- enabled: boolean (default true — absence is allowed)
  if rule.enabled ~= nil and type(rule.enabled) ~= "boolean" then
    return "http rule '" .. rule.id .. "': 'enabled' must be a boolean"
  end

  -- description: optional string
  if rule.description ~= nil and type(rule.description) ~= "string" then
    return "http rule '" .. rule.id .. "': 'description' must be a string"
  end

  -- tags: optional list of strings
  if rule.tags ~= nil then
    if type(rule.tags) ~= "table" then
      return "http rule '" .. rule.id .. "': 'tags' must be a list"
    end
    for i, tag in ipairs(rule.tags) do
      if type(tag) ~= "string" then
        return "http rule '" .. rule.id .. "': tags[" .. i .. "] must be a string"
      end
    end
  end

  -- scope: optional map
  local scope_err = validate_http_scope(rule.scope, rule.id)
  if scope_err then
    return scope_err
  end

  return nil
end

--- Validate a single Stream rule table.
-- Returns nil on success, error string on failure.
local function validate_stream_rule(rule)
  -- id: required, non-empty string
  if not is_nonempty_string(rule.id) then
    return "stream rule is missing required field 'id' (must be a non-empty string)"
  end

  -- priority: required, integer
  if not is_integer(rule.priority) then
    return "stream rule '" .. tostring(rule.id) .. "': 'priority' must be an integer"
  end

  -- action: required, proxy | deny
  if rule.action ~= "proxy" and rule.action ~= "deny" then
    return "stream rule '" .. rule.id .. "': 'action' must be 'proxy' or 'deny', got: " .. tostring(rule.action)
  end

  -- upstream: required when action == proxy
  if rule.action == "proxy" then
    if not is_nonempty_string(rule.upstream) then
      return "stream rule '" .. rule.id .. "': 'upstream' is required when action is 'proxy' (must be 'host:port')"
    end
  end

  -- enabled: boolean (default true — absence is allowed)
  if rule.enabled ~= nil and type(rule.enabled) ~= "boolean" then
    return "stream rule '" .. rule.id .. "': 'enabled' must be a boolean"
  end

  -- description: optional string
  if rule.description ~= nil and type(rule.description) ~= "string" then
    return "stream rule '" .. rule.id .. "': 'description' must be a string"
  end

  -- tags: optional list of strings
  if rule.tags ~= nil then
    if type(rule.tags) ~= "table" then
      return "stream rule '" .. rule.id .. "': 'tags' must be a list"
    end
    for i, tag in ipairs(rule.tags) do
      if type(tag) ~= "string" then
        return "stream rule '" .. rule.id .. "': tags[" .. i .. "] must be a string"
      end
    end
  end

  -- scope: optional map
  local scope_err = validate_stream_scope(rule.scope, rule.id)
  if scope_err then
    return scope_err
  end

  return nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Validate a complete parsed policy document.
-- Performs all-or-nothing validation:
--   1. global.default_action required
--   2. Each HTTP rule validated (including enabled=false)
--   3. Each Stream rule validated (including enabled=false)
--   4. id uniqueness across HTTP + Stream rules combined
--
-- @param policy table  Parsed policy table (output of parser.parse_file or parse_string)
-- @return table|nil    Returns the same policy table on success (pass-through)
-- @return string|nil   Returns an error string on failure, nil on success
function _M.validate(policy)
  if type(policy) ~= "table" then
    return nil, "policy must be a table"
  end

  -- ---------------------------------------------------------------------------
  -- 1. global section
  -- ---------------------------------------------------------------------------
  if type(policy.global) ~= "table" then
    return nil, "policy is missing required 'global' section"
  end

  local default_action = policy.global.default_action
  if default_action ~= "allow" and default_action ~= "deny" then
    return nil,
      "policy.global.default_action is required and must be 'allow' or 'deny', got: " .. tostring(default_action)
  end

  -- ---------------------------------------------------------------------------
  -- 2. HTTP rules (policy.rules) — optional section, but each entry validated
  -- ---------------------------------------------------------------------------
  local http_rules = policy.rules or {}
  if type(http_rules) ~= "table" then
    return nil, "policy.rules must be a list"
  end

  for i, rule in ipairs(http_rules) do
    if type(rule) ~= "table" then
      return nil, "policy.rules[" .. i .. "] must be a map"
    end
    local err = validate_http_rule(rule)
    if err then
      return nil, err
    end
  end

  -- ---------------------------------------------------------------------------
  -- 3. Stream rules (policy.stream_rules) — optional section
  -- ---------------------------------------------------------------------------
  local stream_rules = policy.stream_rules or {}
  if type(stream_rules) ~= "table" then
    return nil, "policy.stream_rules must be a list"
  end

  for i, rule in ipairs(stream_rules) do
    if type(rule) ~= "table" then
      return nil, "policy.stream_rules[" .. i .. "] must be a map"
    end
    local err = validate_stream_rule(rule)
    if err then
      return nil, err
    end
  end

  -- ---------------------------------------------------------------------------
  -- 4. id uniqueness: HTTP rules + stream_rules combined (spec §4.2)
  -- ---------------------------------------------------------------------------
  local seen_ids = {}
  for _, rule in ipairs(http_rules) do
    if seen_ids[rule.id] then
      return nil, "duplicate rule id across http rules and stream_rules: '" .. rule.id .. "'"
    end
    seen_ids[rule.id] = true
  end
  for _, rule in ipairs(stream_rules) do
    if seen_ids[rule.id] then
      return nil, "duplicate rule id across http rules and stream_rules: '" .. rule.id .. "'"
    end
    seen_ids[rule.id] = true
  end

  return policy, nil
end

return _M
