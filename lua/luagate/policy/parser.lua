--- Policy YAML parser for LuaGate.
-- Reads and parses a YAML policy file (canonical source: conf/policies.yaml)
-- into the internal Lua table representation defined in
-- docs/spec/policy-engine.md §2 and ADR-003 §3.3.
--
-- Design rules:
--   - File I/O (io.open) is ONLY safe in init_by_lua / admin reload handler
--     context.  Never call parse_file() from access/log phase handlers.
--   - Returns nil, err on any failure (never calls error() / assert())
--   - Does NOT validate — call validator.validate() after parsing.
--   - parse_http_rules() and parse_stream_rules() are exposed separately
--     so callers can process each subsystem independently.
--   - original_index is set to the 1-based source order position of each
--     rule (disabled rules included) so that FFI rule_index can be used as
--     rules[rule_index] directly (policy-engine.md §3.4).
--
-- Implementation: lua/luagate/policy/parser.lua
-- Tests: tests/unit/policy/parser_spec.lua

local _M = {}

-- ---------------------------------------------------------------------------
-- Dependency: lyaml (OpenResty ships lua-resty-core; lyaml is available via
-- opm/luarocks in the Docker image).  We use pcall so the module can be
-- loaded in unit-test environments that stub the library.
-- ---------------------------------------------------------------------------
local lyaml_ok, lyaml = pcall(require, "lyaml")

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Parse a raw YAML string using lyaml.
-- @param yaml_str string  Raw YAML content
-- @return table|nil, string|nil
local function parse_yaml_string(yaml_str)
  if not lyaml_ok then
    return nil, "lyaml library not available: " .. tostring(lyaml)
  end

  local ok, result = pcall(lyaml.load, yaml_str)
  if not ok then
    return nil, "YAML parse error: " .. tostring(result)
  end

  if result == nil then
    return nil, "YAML parsed to nil (empty document?)"
  end

  -- lyaml.load returns the first YAML document; multi-document YAML is not
  -- supported by this parser (single file policy model per ADR-003 §3.3).
  if type(result) ~= "table" then
    return nil, "YAML root must be a mapping, got: " .. type(result)
  end

  return result, nil
end

--- Normalise a single rule entry common fields.
-- Sets enabled default (true) and records the original_index (1-based).
-- @param rule  table   Raw rule table from YAML
-- @param idx   integer 1-based position in the source rule list
local function normalise_rule(rule, idx)
  -- original_index: 1-based, source order (disabled rules included).
  -- policy-engine.md §3.4: FFI rule_index → rules[rule_index] directly.
  rule.original_index = idx

  -- enabled defaults to true when absent
  if rule.enabled == nil then
    rule.enabled = true
  end

  -- tags defaults to empty list when absent
  if rule.tags == nil then
    rule.tags = {}
  end
end

--- Parse and shallow-copy a rule list, guarding against malformed entries.
-- @param raw_rules table
-- @param field_name string
-- @return table|nil, string|nil
local function parse_rule_list(raw_rules, field_name)
  if raw_rules == nil then
    return {}, nil
  end

  if type(raw_rules) ~= "table" then
    return nil, field_name .. " must be a list (got " .. type(raw_rules) .. ")"
  end

  local rules = {}
  for i, rule in ipairs(raw_rules) do
    if type(rule) ~= "table" then
      return nil, field_name .. "[" .. i .. "] must be a mapping (got " .. type(rule) .. ")"
    end

    -- Shallow-copy so we do not mutate the raw parsed table in place.
    local r = {}
    for k, v in pairs(rule) do
      r[k] = v
    end
    normalise_rule(r, i)
    rules[i] = r
  end

  return rules, nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Parse a list of HTTP rules from the top-level "rules" key.
-- Each rule is normalised (enabled default, original_index set).
-- Does NOT validate — call validator.validate_http_rule() separately.
--
-- @param raw_rules table  Value of policy_table["rules"] (may be nil)
-- @return table|nil   List of normalised HTTP rule tables, or nil on error
-- @return string|nil  Error description, or nil on success
function _M.parse_http_rules(raw_rules)
  return parse_rule_list(raw_rules, "rules")
end

--- Parse a list of Stream rules from the top-level "stream_rules" key.
-- Each rule is normalised (enabled default, original_index set).
-- Does NOT validate.
--
-- @param raw_rules table  Value of policy_table["stream_rules"] (may be nil)
-- @return table|nil   List of normalised Stream rule tables, or nil on error
-- @return string|nil  Error description, or nil on success
function _M.parse_stream_rules(raw_rules)
  return parse_rule_list(raw_rules, "stream_rules")
end

--- Parse a YAML string into the internal policy representation.
-- Returns a policy table with the following shape:
--
--   {
--     version       = string | nil,
--     global        = { default_action = string },
--     rules         = list of normalised HTTP rule tables,
--     stream_rules  = list of normalised Stream rule tables,
--   }
--
-- Call validator.validate(policy) on the returned table before use.
--
-- @param  yaml_str  string  Raw YAML content
-- @return table|nil         Parsed policy table, or nil on error
-- @return string|nil        Error description, or nil on success
function _M.parse_string(yaml_str)
  if type(yaml_str) ~= "string" then
    return nil, "yaml_str must be a string"
  end
  if #yaml_str == 0 then
    return nil, "yaml_str is empty"
  end

  local raw, err = parse_yaml_string(yaml_str)
  if not raw then
    return nil, err
  end

  -- Reject legacy nested structure (http.rules / stream.rules).
  -- Only flat top-level keys (rules / stream_rules) are allowed per
  -- policy-engine.md §2.0.
  if type(raw.http) == "table" then
    return nil, "legacy 'http' key not supported; use top-level 'rules' (policy-engine.md §2.0)"
  end
  if type(raw.stream) == "table" then
    return nil, "legacy 'stream' key not supported; use 'stream_rules' (policy-engine.md §2.0)"
  end

  -- Build the canonical policy table.
  local http_rules, http_err = _M.parse_http_rules(raw.rules)
  if not http_rules then
    return nil, http_err
  end

  local stream_rules, stream_err = _M.parse_stream_rules(raw.stream_rules)
  if not stream_rules then
    return nil, stream_err
  end

  local policy = {
    version = raw.version, -- optional string
    global = raw.global or {},
    rules = http_rules,
    stream_rules = stream_rules,
  }

  return policy, nil
end

--- Parse a YAML policy file from the filesystem.
-- IMPORTANT: This function performs blocking file I/O (io.open).
-- It MUST only be called from:
--   - init_by_lua_block (Nginx startup)
--   - Admin API reload handler (worker context, but explicitly allowed for
--     policy reload — see ADR-003 §3.4 and openresty-patterns.md anti-patterns)
-- Never call from access_by_lua, log_by_lua, or any per-request handler.
--
-- @param  filepath  string  Absolute path to the YAML policy file
-- @return table|nil         Parsed policy table, or nil on error
-- @return string|nil        Error description, or nil on success
function _M.parse_file(filepath)
  if type(filepath) ~= "string" or #filepath == 0 then
    return nil, "filepath must be a non-empty string"
  end

  -- Blocking I/O: only safe in init/reload context (see module docstring).
  local f, open_err = io.open(filepath, "r")
  if not f then
    return nil, "cannot open policy file '" .. filepath .. "': " .. tostring(open_err)
  end

  local content, read_err = f:read("*all")
  f:close()

  if content == nil then
    return nil, "cannot read policy file '" .. filepath .. "': " .. tostring(read_err)
  end

  if #content == 0 then
    return nil, "policy file is empty: " .. filepath
  end

  return _M.parse_string(content)
end

return _M
