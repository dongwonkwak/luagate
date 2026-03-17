--- Policy evaluator for LuaGate.
-- Implements priority first-match-wins evaluation (ADR-002 §3.1).
--
-- Design rules:
--   - Module-level upvalue cache (_cached_policy, _cached_version).
--     ngx.ctx MUST NOT be used for policy caching (policy-engine.md §4.4).
--   - evaluate() accepts a pre-sorted rules list and a request_ctx table,
--     returning {action, matched_rule, decision_source}.
--   - fail-closed: any internal error → deny.
--   - No blocking I/O in any code path.
--   - Admin plane requests are NOT evaluated here; the caller (access_by_lua)
--     is responsible for routing admin-plane traffic to the admin server block
--     (ADR-004 §3).
--
-- Implementation: lua/luagate/policy/evaluator.lua
-- Tests: tests/unit/policy/evaluator_spec.lua

local _M = {}

-- ---------------------------------------------------------------------------
-- Worker-level policy cache (module-level upvalue).
-- These variables live for the lifetime of the worker process.
-- They are updated when the shared-dict active version changes.
-- ---------------------------------------------------------------------------
local _cached_policy = nil -- last successfully loaded policy table
local _cached_version = nil -- active_version string corresponding to the cache

-- ---------------------------------------------------------------------------
-- Internal: scope matching helpers
-- ---------------------------------------------------------------------------

--- Match path scope.
-- If scope.path ends with "/*", prefix match (strip trailing "/*").
-- Otherwise exact match.
-- @param scope_path string
-- @param req_path   string  URL path (already normalised by rewrite_by_lua)
-- @return boolean
local function match_path(scope_path, req_path)
  local n = #scope_path
  if n >= 2 and scope_path:sub(n - 1) == "/*" then
    -- prefix match: scope /api/v1/* matches /api/v1 and /api/v1/...
    local prefix = scope_path:sub(1, n - 2) -- strip trailing "/*"
    if req_path == prefix then
      return true
    end
    return req_path:sub(1, #prefix + 1) == prefix .. "/"
  end
  return scope_path == req_path
end

--- Match host scope.
-- "*.example.com" → subdomain wildcard (any label before .example.com).
-- Otherwise exact.
-- @param scope_host string
-- @param req_host   string
-- @return boolean
local function match_host(scope_host, req_host)
  if scope_host:sub(1, 2) == "*." then
    local suffix = scope_host:sub(2) -- ".example.com"
    local n = #suffix
    if req_host == suffix:sub(2) then
      -- bare domain (no subdomain)
      return false
    end
    return req_host:sub(-n) == suffix
  end
  return scope_host == req_host
end

--- Match method scope.
-- Scope may be a single string or a list; comparison is case-insensitive.
-- @param scope_method string|table
-- @param req_method   string
-- @return boolean
local function match_method(scope_method, req_method)
  local upper = req_method:upper()
  if type(scope_method) == "string" then
    return scope_method:upper() == upper
  end
  -- list
  for _, m in ipairs(scope_method) do
    if m:upper() == upper then
      return true
    end
  end
  return false
end

--- Convert a dotted-decimal IP string to a 32-bit integer.
-- Returns nil if the string is not a valid IPv4 address.
-- @param ip string
-- @return number|nil
local function ip_to_uint32(ip)
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

--- Match src_ip_cidr scope.
-- CIDR format "a.b.c.d/prefix".  Returns true if req_ip is inside the CIDR.
-- Uses divisor-based arithmetic for Lua 5.1 / LuaJIT compatibility.
-- @param cidr   string  e.g. "10.0.0.0/8"
-- @param req_ip string  e.g. "10.1.2.3"
-- @return boolean
local function match_src_ip_cidr(cidr, req_ip)
  local net_str, prefix_str = cidr:match("^(.+)/(%d+)$")
  if not net_str then
    return false
  end
  local prefix = tonumber(prefix_str)
  if not prefix or prefix < 0 or prefix > 32 then
    return false
  end
  local net_int = ip_to_uint32(net_str)
  local req_int = ip_to_uint32(req_ip)
  if not net_int or not req_int then
    return false
  end
  if prefix == 0 then
    return true
  end
  -- Build mask: e.g. prefix=24 → mask = 0xFFFFFF00
  local shift = 32 - prefix
  local divisor = 2 ^ shift
  return math.floor(net_int / divisor) == math.floor(req_int / divisor)
end

--- Match dst_port scope (stream).
-- @param scope_port  string|number  e.g. 443 or "1024-65535"
-- @param req_port    number         actual destination port
-- @return boolean
local function match_dst_port(scope_port, req_port)
  if type(scope_port) == "number" then
    return scope_port == req_port
  end
  -- range "lo-hi"
  local lo_str, hi_str = scope_port:match("^(%d+)-(%d+)$")
  if not lo_str then
    return false
  end
  local lo, hi = tonumber(lo_str), tonumber(hi_str)
  return req_port >= lo and req_port <= hi
end

--- Match SNI scope (stream).
-- @param scope_sni string
-- @param req_sni   string
-- @return boolean
local function match_sni(scope_sni, req_sni)
  return match_host(scope_sni, req_sni)
end

--- Evaluate whether a rule's scope matches the given request context.
-- All scope conditions are ANDed; omitted fields are wildcards.
--
-- For HTTP request_ctx:
--   { path, host, method, src_ip, query_param, header }
-- For Stream request_ctx:
--   { src_ip, dst_port, detected_protocol, sni }
--
-- @param scope       table|nil  Rule scope (nil = catch-all)
-- @param request_ctx table      Request or connection context
-- @return boolean
local function scope_matches(scope, request_ctx)
  if scope == nil then
    return true -- catch-all
  end

  -- path (HTTP)
  if scope.path ~= nil then
    local req_path = request_ctx.path
    if req_path == nil or not match_path(scope.path, req_path) then
      return false
    end
  end

  -- host (HTTP)
  if scope.host ~= nil then
    local req_host = request_ctx.host
    if req_host == nil or not match_host(scope.host, req_host) then
      return false
    end
  end

  -- method (HTTP)
  if scope.method ~= nil then
    local req_method = request_ctx.method
    if req_method == nil or not match_method(scope.method, req_method) then
      return false
    end
  end

  -- src_ip_cidr (HTTP + Stream)
  if scope.src_ip_cidr ~= nil then
    local req_ip = request_ctx.src_ip
    if req_ip == nil or not match_src_ip_cidr(scope.src_ip_cidr, req_ip) then
      return false
    end
  end

  -- query_param (HTTP)
  if scope.query_param ~= nil then
    local req_params = request_ctx.query_param or {}
    for k, v in pairs(scope.query_param) do
      if req_params[k] ~= v then
        return false
      end
    end
  end

  -- header (HTTP): key comparison case-insensitive (lowercased at build time)
  if scope.header ~= nil then
    local req_headers = request_ctx.header or {}
    for k, v in pairs(scope.header) do
      -- headers are stored lowercase in request_ctx by convention
      if req_headers[k:lower()] ~= v then
        return false
      end
    end
  end

  -- dst_port (Stream)
  if scope.dst_port ~= nil then
    local req_port = request_ctx.dst_port
    if req_port == nil or not match_dst_port(scope.dst_port, req_port) then
      return false
    end
  end

  -- detected_protocol (Stream)
  if scope.detected_protocol ~= nil then
    if request_ctx.detected_protocol ~= scope.detected_protocol then
      return false
    end
  end

  -- sni (Stream)
  if scope.sni ~= nil then
    local req_sni = request_ctx.sni
    if req_sni == nil or not match_sni(scope.sni, req_sni) then
      return false
    end
  end

  return true
end

-- ---------------------------------------------------------------------------
-- Internal: stable sort helpers
-- ---------------------------------------------------------------------------

--- Stable sort a list of rules by (priority ASC, id ASC).
-- Lua 5.1 table.sort is not guaranteed stable, so we use a Schwartzian
-- transform: attach original list position as a tertiary key.
-- @param rules table  List of rule tables (modified in-place)
local function stable_sort_rules(rules)
  -- Attach sort index for stability
  for i, rule in ipairs(rules) do
    rule._sort_idx = i
  end
  table.sort(rules, function(a, b)
    if a.priority ~= b.priority then
      return a.priority < b.priority
    end
    if a.id ~= b.id then
      return a.id < b.id
    end
    -- same priority + same id is a schema error caught by validator;
    -- fall back to original position for determinism
    return a._sort_idx < b._sort_idx
  end)
  -- Clean up temporary key
  for _, rule in ipairs(rules) do
    rule._sort_idx = nil
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Compile (sort) a rules list in-place for evaluation.
-- Call this once after loading a policy, before calling evaluate().
-- Sorts enabled rules by (priority ASC, id ASC) — stable.
--
-- @param rules table  List of rule tables (normalised by parser)
-- @return table        The same list, sorted (pass-through)
function _M.compile(rules)
  -- Filter to enabled rules only, then stable-sort.
  -- We keep the original list intact and build a sorted view.
  local enabled = {}
  for _, rule in ipairs(rules) do
    if rule.enabled ~= false then
      enabled[#enabled + 1] = rule
    end
  end
  stable_sort_rules(enabled)
  return enabled
end

--- Evaluate a pre-sorted (compiled) list of HTTP rules against a request context.
-- Returns a result table:
--   {
--     action          = "allow" | "deny",
--     matched_rule    = rule.id string or nil (nil when default_action fires),
--     decision_source = "rule" | "default",
--   }
--
-- On internal error the function returns a fail-closed deny result so the
-- caller never receives nil.
--
-- @param rules          table   Compiled (sorted, enabled-only) HTTP rules
-- @param request_ctx    table   Request context: { path, host, method, src_ip,
--                               query_param, header }
-- @param default_action string  "allow" | "deny" — from policy.global.default_action
-- @return table  { action, matched_rule, decision_source }
function _M.evaluate(rules, request_ctx, default_action)
  -- Fail-closed guard: invalid arguments → deny
  if type(rules) ~= "table" or type(request_ctx) ~= "table" then
    return { action = "deny", matched_rule = nil, decision_source = "error" }
  end

  if default_action ~= "allow" and default_action ~= "deny" then
    -- global.default_action is mandatory (validator enforces this);
    -- if somehow missing, fail-closed.
    return { action = "deny", matched_rule = nil, decision_source = "error" }
  end

  local ok, result = pcall(function()
    for _, rule in ipairs(rules) do
      -- rules list is already enabled-only (compile() filtered it)
      if scope_matches(rule.scope, request_ctx) then
        return {
          action = rule.action,
          matched_rule = rule.id,
          decision_source = "rule",
        }
      end
    end
    -- No rule matched → apply default action
    return {
      action = default_action,
      matched_rule = nil,
      decision_source = "default",
    }
  end)

  if not ok then
    -- Unexpected error in matching logic → fail-closed
    return { action = "deny", matched_rule = nil, decision_source = "error" }
  end

  return result
end

--- Evaluate a pre-sorted (compiled) list of Stream rules against a connection context.
-- Returns a result table:
--   {
--     action          = "proxy" | "deny",
--     matched_rule    = rule.id string or nil,
--     decision_source = "rule" | "default",
--     upstream        = string or nil (populated when action == "proxy"),
--   }
--
-- Stream pipelines always fail-closed on no-match (policy-engine.md §3.2).
--
-- @param rules        table   Compiled Stream rules (enabled, sorted)
-- @param request_ctx  table   Connection context: { src_ip, dst_port,
--                             detected_protocol, sni }
-- @return table  { action, matched_rule, decision_source, upstream }
function _M.evaluate_stream(rules, request_ctx)
  if type(rules) ~= "table" or type(request_ctx) ~= "table" then
    return { action = "deny", matched_rule = nil, decision_source = "error", upstream = nil }
  end

  local ok, result = pcall(function()
    for _, rule in ipairs(rules) do
      if scope_matches(rule.scope, request_ctx) then
        return {
          action = rule.action,
          matched_rule = rule.id,
          decision_source = "rule",
          upstream = rule.upstream,
        }
      end
    end
    -- No match → Stream always fail-closed (deny)
    return {
      action = "deny",
      matched_rule = nil,
      decision_source = "default",
      upstream = nil,
    }
  end)

  if not ok then
    return { action = "deny", matched_rule = nil, decision_source = "error", upstream = nil }
  end

  return result
end

--- Load (or return cached) the active policy from the shared dict.
-- This function implements the worker-level L1 cache described in
-- policy-engine.md §4.4.
--
-- IMPORTANT: Must only be called from within an ngx request context
-- (access_by_lua, preread_by_lua, etc.) where ngx.shared is available.
--
-- @return table|nil  Policy table with compiled http_rules / stream_rules,
--                    or nil if no policy has been loaded yet.
function _M.get_policy()
  -- ngx guard: in test environments ngx.shared may not exist
  if not ngx or not ngx.shared then
    return _cached_policy
  end

  local dict = ngx.shared.luagate_policy
  if not dict then
    return _cached_policy
  end

  local http_ver = dict:get("http:active_version")
  local stream_ver = dict:get("stream:active_version")
  local current_version = (http_ver or "") .. "|" .. (stream_ver or "")

  if _cached_version == current_version and _cached_policy ~= nil then
    -- Version unchanged → return cached policy (no shared-dict I/O)
    return _cached_policy
  end

  if not http_ver and not stream_ver then
    -- No active version yet (cold start or no policy loaded)
    return _cached_policy
  end

  -- Use the HTTP version for the blob key (primary policy source).
  -- Stream rules are stored in the same blob under the same version.
  local blob_key = "policy:" .. (http_ver or stream_ver) .. ":blob"
  local policy_json = dict:get(blob_key)
  if not policy_json then
    ngx.log(ngx.ERR, "[luagate] policy blob not found for version: ", current_version)
    return _cached_policy -- last-known-good
  end

  -- Decode JSON blob
  local ok, policy = pcall(require("cjson").decode, policy_json)
  if not ok or type(policy) ~= "table" then
    ngx.log(ngx.ERR, "[luagate] failed to decode policy blob: ", tostring(policy))
    return _cached_policy
  end

  -- Pre-compile sorted rule lists
  policy._compiled_http = _M.compile(policy.rules or {})
  policy._compiled_stream = _M.compile(policy.stream_rules or {})

  _cached_policy = policy
  _cached_version = current_version
  return _cached_policy
end

--- Reset the module-level cache (for testing / forced reload).
-- In production code, rely on get_policy() detecting version changes.
function _M.reset_cache()
  _cached_policy = nil
  _cached_version = nil
end

return _M
