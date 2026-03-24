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

-- Known legacy rule fields that indicate the old nested policy format.
-- These fields were used in the pre-spec format (http.rules with match/path_prefix/etc.)
-- and must be rejected to prevent silent catch-all fallback.
local LEGACY_RULE_FIELDS = {
  match = true,
  path_prefix = true,
  source_cidrs = true,
  port = true,
  status = true,
  rate = true,
}

--- Check for legacy rule fields and return error if found.
-- @param rule table  Rule table
-- @param rule_type string  "http" or "stream"
-- @return string|nil  Error message, or nil if no legacy fields
local function check_legacy_fields(rule, rule_type)
  for field in pairs(LEGACY_RULE_FIELDS) do
    if rule[field] ~= nil then
      return rule_type
        .. " rule '"
        .. tostring(rule.id or "?")
        .. "': legacy field '"
        .. field
        .. "' is not supported; use 'scope' with canonical field names instead (see policy-engine.md §2.0)"
    end
  end
  return nil
end

--- Check that `value` is a non-empty string.
local function is_nonempty_string(value)
  return type(value) == "string" and #value > 0
end

--- Check that `value` is an integer (number with no fractional part).
local function is_integer(value)
  return type(value) == "number" and value == math.floor(value)
end

--- Check that `value` is a dense array table with 1-based consecutive indexes.
local function is_dense_array_table(value)
  if type(value) ~= "table" then
    return false
  end

  local count = 0
  local max_index = 0
  for k, _ in pairs(value) do
    if not is_integer(k) or k < 1 then
      return false
    end
    count = count + 1
    if k > max_index then
      max_index = k
    end
  end

  return max_index == count
end

--- Validate an IPv4 CIDR string "a.b.c.d/prefix".
-- Returns true if valid, false otherwise.
-- Rules: each octet 0-255, prefix 0-32.
local function validate_cidr(cidr)
  local a, b, c, d, prefix = cidr:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)/(%d+)$")
  if not a then
    return false
  end
  a, b, c, d, prefix = tonumber(a), tonumber(b), tonumber(c), tonumber(d), tonumber(prefix)
  return a <= 255 and b <= 255 and c <= 255 and d <= 255 and prefix <= 32
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

  -- src_ip_cidr: string, must be a valid IPv4 CIDR "a.b.c.d/prefix"
  -- Octets: 0-255, prefix: 0-32
  if scope.src_ip_cidr ~= nil then
    if type(scope.src_ip_cidr) ~= "string" then
      return "rule '" .. rule_id .. "': scope.src_ip_cidr must be a string"
    end
    if not validate_cidr(scope.src_ip_cidr) then
      return "rule '"
        .. rule_id
        .. "': scope.src_ip_cidr must be a valid IPv4 CIDR (e.g. '1.2.3.0/24'), got: '"
        .. scope.src_ip_cidr
        .. "'"
    end
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

  -- src_ip_cidr: string, must be a valid IPv4 CIDR "a.b.c.d/prefix"
  -- Octets: 0-255, prefix: 0-32
  if scope.src_ip_cidr ~= nil then
    if type(scope.src_ip_cidr) ~= "string" then
      return "rule '" .. rule_id .. "': scope.src_ip_cidr must be a string"
    end
    if not validate_cidr(scope.src_ip_cidr) then
      return "rule '"
        .. rule_id
        .. "': scope.src_ip_cidr must be a valid IPv4 CIDR (e.g. '1.2.3.0/24'), got: '"
        .. scope.src_ip_cidr
        .. "'"
    end
  end

  -- dst_port: string ("lo-hi" range) or integer (exact), valid port range 1-65535
  if scope.dst_port ~= nil then
    local dt = type(scope.dst_port)
    if dt == "number" then
      if not is_integer(scope.dst_port) then
        return "rule '" .. rule_id .. "': scope.dst_port must be an integer"
      end
      -- R-3: integer port must be in 1-65535
      if scope.dst_port < 1 or scope.dst_port > 65535 then
        return "rule '" .. rule_id .. "': scope.dst_port must be in range 1-65535, got: " .. tostring(scope.dst_port)
      end
    elseif dt == "string" then
      -- Must match "lo-hi" range format with lo <= hi
      local lo_str, hi_str = string.match(scope.dst_port, "^(%d+)-(%d+)$")
      if not lo_str then
        return "rule '"
          .. rule_id
          .. "': scope.dst_port range must be in 'lo-hi' format (e.g. '1024-65535'), got: '"
          .. scope.dst_port
          .. "'"
      end
      local lo, hi = tonumber(lo_str), tonumber(hi_str)
      if lo > hi then
        return "rule '" .. rule_id .. "': scope.dst_port range lo must be <= hi, got: '" .. scope.dst_port .. "'"
      end
      -- R-2: range lo/hi must be in 1-65535
      if lo < 1 or hi > 65535 then
        return "rule '"
          .. rule_id
          .. "': scope.dst_port range values must be in 1-65535, got: '"
          .. scope.dst_port
          .. "'"
      end
    else
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
  -- legacy field check (must precede id check for better error messages)
  local legacy_err = check_legacy_fields(rule, "http")
  if legacy_err then
    return legacy_err
  end

  -- id: required, non-empty string matching [a-z0-9-]+ (no colon, no underscore — policy-engine.md §2, ADR-012 §2)
  if not is_nonempty_string(rule.id) then
    return "http rule is missing required field 'id' (must be a non-empty string)"
  end
  if rule.id:find("[^a-z0-9%-]") then
    return "http rule '"
      .. rule.id
      .. "': 'id' must match [a-z0-9-]+ (underscores, colons and special chars are forbidden for key safety)"
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

  -- rate_limit: optional map (ADR-012)
  -- Only valid on action=allow rules. When present, requests/window/scope are all required.
  if rule.rate_limit ~= nil then
    if type(rule.rate_limit) ~= "table" then
      return "http rule '" .. rule.id .. "': 'rate_limit' must be a map"
    end

    -- rate_limit is only valid on allow rules (ADR-012 §3)
    if rule.action ~= "allow" then
      return "http rule '" .. rule.id .. "': 'rate_limit' is only valid on action='allow' rules"
    end

    -- requests: required positive integer
    if not is_integer(rule.rate_limit.requests) or rule.rate_limit.requests <= 0 then
      return "http rule '" .. rule.id .. "': 'rate_limit.requests' must be a positive integer"
    end

    -- window: required positive integer
    if not is_integer(rule.rate_limit.window) or rule.rate_limit.window <= 0 then
      return "http rule '" .. rule.id .. "': 'rate_limit.window' must be a positive integer"
    end

    -- scope: required, MVP only supports "client_ip"
    if rule.rate_limit.scope ~= "client_ip" then
      return "http rule '"
        .. rule.id
        .. "': 'rate_limit.scope' must be 'client_ip', got: "
        .. tostring(rule.rate_limit.scope)
    end
  end

  return nil
end

--- Validate a single Stream rule table.
-- Returns nil on success, error string on failure.
local function validate_stream_rule(rule)
  -- legacy field check
  local legacy_err = check_legacy_fields(rule, "stream")
  if legacy_err then
    return legacy_err
  end

  -- id: required, non-empty string matching [a-z0-9-]+ (no colon, no underscore — policy-engine.md §2, ADR-012 §2)
  if not is_nonempty_string(rule.id) then
    return "stream rule is missing required field 'id' (must be a non-empty string)"
  end
  if rule.id:find("[^a-z0-9%-]") then
    return "stream rule '"
      .. rule.id
      .. "': 'id' must match [a-z0-9-]+ (underscores, colons and special chars are forbidden for key safety)"
  end

  -- priority: required, integer
  if not is_integer(rule.priority) then
    return "stream rule '" .. tostring(rule.id) .. "': 'priority' must be an integer"
  end

  -- action: required, proxy | deny
  if rule.action ~= "proxy" and rule.action ~= "deny" then
    return "stream rule '" .. rule.id .. "': 'action' must be 'proxy' or 'deny', got: " .. tostring(rule.action)
  end

  -- upstream: required when action == proxy, must be "host:port" format
  if rule.action == "proxy" then
    if not is_nonempty_string(rule.upstream) then
      return "stream rule '" .. rule.id .. "': 'upstream' is required when action is 'proxy' (must be 'host:port')"
    end
    -- Verify "host:port" format: host part non-empty, port part numeric
    -- Accepts: "backend:8443", "192.168.1.1:80"
    -- Rejects: "backend" (no colon), "host:" (empty port), ":8080" (empty host)
    local host_part = string.match(rule.upstream, "^(.+):[0-9]+$")
    if not host_part or #host_part == 0 then
      return "stream rule '" .. rule.id .. "': 'upstream' must be in 'host:port' format, got: '" .. rule.upstream .. "'"
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
  -- 0. version field (required, must be a non-empty string)
  -- ---------------------------------------------------------------------------
  if not is_nonempty_string(policy.version) then
    return nil, "policy is missing required 'version' field (must be a non-empty string)"
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
  if not is_dense_array_table(http_rules) then
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
  if not is_dense_array_table(stream_rules) then
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
