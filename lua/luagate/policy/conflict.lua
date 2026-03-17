--- Conflict and shadow detection for LuaGate policy rules.
-- Implements ADR-002 §3.2 conflict detection (best-effort WARN).
--
-- Design rules:
--   - Operates on enabled=true rules only (spec §5, ADR-002 §3.2).
--   - Returns conflict/shadow lists; does NOT abort loading (WARN only).
--   - detect() is the main public entry point — returns both conflict and
--     shadowed rule lists.  Each conflict entry carries an overlap_type field:
--     "exact" (scopes are equal) or "overlap" (one scope contains the other).
--   - detect_and_fail() is the fail-closed variant: raises error() when any
--     conflicts are found.  Shadowed rules do NOT cause an error.
--   - Scope comparison is best-effort: ambiguous containment → false.
--   - No blocking I/O, no ngx.shared access.
--   - ngx.log(ngx.WARN) is called for each detected pair/rule.
--     In environments where ngx is unavailable (unit tests), logging is
--     skipped silently.
--
-- Implementation: lua/luagate/policy/conflict.lua
-- Tests: tests/unit/policy/conflict_spec.lua

local _M = {}

-- ---------------------------------------------------------------------------
-- Internal: scope equality and containment helpers
-- ---------------------------------------------------------------------------

--- Normalise method value to an uppercase set (table with boolean values).
-- Accepts a single string or a list of strings.
-- @param method string|table|nil
-- @return table  e.g. { GET=true, POST=true }
local function method_set(method)
  if method == nil then
    return nil -- wildcard — any method
  end
  local s = {}
  if type(method) == "string" then
    s[method:upper()] = true
  elseif type(method) == "table" then
    for _, m in ipairs(method) do
      s[m:upper()] = true
    end
  end
  return s
end

--- Return true if set_a and set_b contain the same keys.
-- @param a table  boolean-valued set
-- @param b table  boolean-valued set
-- @return boolean
local function sets_equal(a, b)
  for k in pairs(a) do
    if not b[k] then
      return false
    end
  end
  for k in pairs(b) do
    if not a[k] then
      return false
    end
  end
  return true
end

--- Return true if set_a is a superset of set_b (every element of b is in a).
-- @param a table  boolean-valued set (potential superset)
-- @param b table  boolean-valued set
-- @return boolean
local function set_superset(a, b)
  for k in pairs(b) do
    if not a[k] then
      return false
    end
  end
  return true
end

--- Parse an IPv4 CIDR string into { net_int, prefix }.
-- Returns nil on parse failure.
-- @param cidr string
-- @return table|nil  { net=number, prefix=number }
local function parse_cidr(cidr)
  local net_str, prefix_str = cidr:match("^(.+)/(%d+)$")
  if not net_str then
    return nil
  end
  local a, b, c, d = net_str:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then
    return nil
  end
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if a > 255 or b > 255 or c > 255 or d > 255 then
    return nil
  end
  local net = a * 16777216 + b * 65536 + c * 256 + d
  local prefix = tonumber(prefix_str)
  if not prefix or prefix < 0 or prefix > 32 then
    return nil
  end
  return { net = net, prefix = prefix }
end

--- Return true if cidr_a contains cidr_b (a is a supernet of or equal to b).
-- That is, every IP in b is also in a.
-- @param cidr_a string  broader CIDR
-- @param cidr_b string  narrower CIDR
-- @return boolean
local function cidr_contains(cidr_a, cidr_b)
  local pa = parse_cidr(cidr_a)
  local pb = parse_cidr(cidr_b)
  if not pa or not pb then
    return false
  end
  -- a contains b iff pa.prefix <= pb.prefix AND same network bits up to pa.prefix
  if pa.prefix > pb.prefix then
    return false
  end
  if pa.prefix == 0 then
    return true -- 0.0.0.0/0 contains everything
  end
  local shift = 32 - pa.prefix
  local divisor = 2 ^ shift
  return math.floor(pa.net / divisor) == math.floor(pb.net / divisor)
end

--- Return true if cidr_a and cidr_b are identical.
-- @param cidr_a string
-- @param cidr_b string
-- @return boolean
local function cidr_equal(cidr_a, cidr_b)
  local pa = parse_cidr(cidr_a)
  local pb = parse_cidr(cidr_b)
  if not pa or not pb then
    return cidr_a == cidr_b
  end
  return pa.prefix == pb.prefix and pa.net == pb.net
end

--- Return true if path_a and path_b are equal (normalised glob strings).
-- @param a string
-- @param b string
-- @return boolean
local function path_equal(a, b)
  return a == b
end

--- Return true if path_a contains path_b (broad covers narrow).
-- "/*" suffix indicates prefix match.
-- A path like "/api/*" contains "/api/v1/*" and "/api/v1/users".
-- If the containment relation is ambiguous → return false (best-effort).
-- @param broad  string
-- @param narrow string
-- @return boolean
local function path_contains(broad, narrow)
  -- Exact broad cannot contain anything narrower
  local broad_is_prefix = broad:sub(-2) == "/*"
  local narrow_is_prefix = narrow:sub(-2) == "/*"

  if not broad_is_prefix then
    -- An exact path can only "contain" itself
    return broad == narrow
  end

  -- broad is a prefix pattern, e.g. "/api/*"
  local broad_base = broad:sub(1, #broad - 2) -- strip "/*"

  if narrow_is_prefix then
    local narrow_base = narrow:sub(1, #narrow - 2)
    -- broad "/api/*" contains narrow "/api/v1/*"?
    -- narrow must start with broad_base + "/"
    if narrow_base == broad_base then
      return true
    end
    return narrow_base:sub(1, #broad_base + 1) == broad_base .. "/"
  else
    -- narrow is exact path
    if narrow == broad_base then
      return true
    end
    return narrow:sub(1, #broad_base + 1) == broad_base .. "/"
  end
end

--- Return true if broad_host contains narrow_host using evaluator wildcard
-- semantics. "*.example.com" matches any subdomain of example.com, but not the
-- bare domain itself.
-- @param broad_host string
-- @param narrow_host string
-- @return boolean
local function host_contains(broad_host, narrow_host)
  if broad_host == narrow_host then
    return true
  end

  if broad_host:sub(1, 2) ~= "*." then
    return false
  end

  local suffix = broad_host:sub(2) -- ".example.com"

  if narrow_host:sub(1, 2) == "*." then
    local narrow_suffix = narrow_host:sub(2)
    if narrow_suffix == suffix then
      return true
    end
    return narrow_suffix:sub(-#suffix) == suffix
  end

  if narrow_host == suffix:sub(2) then
    return false
  end

  return narrow_host:sub(-#suffix) == suffix
end

--- Compare two scope tables for equality (all fields must match).
-- Returns true only when every scope field is identical.
-- Omitted (nil) fields are treated as wildcards; both must agree.
-- @param scope_a table|nil
-- @param scope_b table|nil
-- @return boolean
local function scopes_equal(scope_a, scope_b)
  -- Both nil → both catch-all → equal
  if scope_a == nil and scope_b == nil then
    return true
  end
  if scope_a == nil or scope_b == nil then
    -- One wildcard, one not → not strictly equal
    -- (a nil scope is "wider" than any non-nil scope)
    return false
  end

  -- path
  local pa, pb = scope_a.path, scope_b.path
  if pa ~= pb then
    if pa == nil or pb == nil then
      return false
    end
    if not path_equal(pa, pb) then
      return false
    end
  end

  -- host (exact string comparison)
  if scope_a.host ~= scope_b.host then
    return false
  end

  -- method
  local ma = method_set(scope_a.method)
  local mb = method_set(scope_b.method)
  if ma ~= nil or mb ~= nil then
    -- at least one side restricts method
    if ma == nil or mb == nil then
      return false -- one is wildcard, one is not → not equal
    end
    if not sets_equal(ma, mb) then
      return false
    end
  end

  -- src_ip_cidr
  local ca, cb = scope_a.src_ip_cidr, scope_b.src_ip_cidr
  if ca ~= cb then
    if ca == nil or cb == nil then
      return false
    end
    if not cidr_equal(ca, cb) then
      return false
    end
  end

  -- dst_port (stream): compare as strings after normalisation
  if scope_a.dst_port ~= nil or scope_b.dst_port ~= nil then
    -- at least one side specifies dst_port
    if scope_a.dst_port == nil or scope_b.dst_port == nil then
      return false -- one is wildcard, one is not
    end
    if tostring(scope_a.dst_port) ~= tostring(scope_b.dst_port) then
      return false
    end
  end

  -- detected_protocol
  if scope_a.detected_protocol ~= scope_b.detected_protocol then
    return false
  end

  -- sni
  if scope_a.sni ~= scope_b.sni then
    return false
  end

  -- query_param: exact map equality
  local qpa, qpb = scope_a.query_param, scope_b.query_param
  if qpa ~= qpb then
    if qpa == nil or qpb == nil then
      return false
    end
    for k, v in pairs(qpa) do
      if qpb[k] ~= v then
        return false
      end
    end
    for k, v in pairs(qpb) do
      if qpa[k] ~= v then
        return false
      end
    end
  end

  -- header: case-insensitive key, exact value
  local ha, hb = scope_a.header, scope_b.header
  if ha ~= hb then
    if ha == nil or hb == nil then
      return false
    end
    local ha_norm, hb_norm = {}, {}
    for k, v in pairs(ha) do
      ha_norm[k:lower()] = v
    end
    for k, v in pairs(hb) do
      hb_norm[k:lower()] = v
    end
    for k, v in pairs(ha_norm) do
      if hb_norm[k] ~= v then
        return false
      end
    end
    for k, v in pairs(hb_norm) do
      if ha_norm[k] ~= v then
        return false
      end
    end
  end

  return true
end

--- Return true if scope_broad contains scope_narrow (broad is a superset).
-- Best-effort: when containment cannot be determined, returns false.
-- @param scope_broad  table|nil
-- @param scope_narrow table|nil
-- @return boolean
local function scope_contains(scope_broad, scope_narrow)
  -- nil (catch-all) broad contains everything
  if scope_broad == nil then
    return true
  end
  -- non-nil broad cannot contain nil narrow (which is catch-all)
  if scope_narrow == nil then
    return false
  end

  -- path: broad must contain narrow
  local pa, pb = scope_broad.path, scope_narrow.path
  if pa ~= nil then
    if pb == nil then
      return false -- narrow is wildcard for path, broad is not
    end
    if not path_contains(pa, pb) then
      return false
    end
  end
  -- if pa is nil: broad path is wildcard → ok

  -- host: broad exact contains only itself; broad wildcard contains matching
  -- exact/wildcard subdomains using the same semantics as evaluator.match_host
  if scope_broad.host ~= nil then
    if scope_narrow.host == nil then
      return false
    end
    if not host_contains(scope_broad.host, scope_narrow.host) then
      return false
    end
  end

  -- method: broad set must be superset of narrow set
  local ma = method_set(scope_broad.method)
  local mb = method_set(scope_narrow.method)
  if ma ~= nil then
    if mb == nil then
      return false -- broad restricts, narrow is wildcard
    end
    if not set_superset(ma, mb) then
      return false
    end
  end

  -- src_ip_cidr: broad CIDR must contain narrow CIDR
  local ca, cb = scope_broad.src_ip_cidr, scope_narrow.src_ip_cidr
  if ca ~= nil then
    if cb == nil then
      return false
    end
    if not cidr_contains(ca, cb) then
      return false
    end
  end

  -- dst_port: broad must contain narrow
  if scope_broad.dst_port ~= nil then
    if scope_narrow.dst_port == nil then
      return false
    end
    -- Best-effort: only handle simple cases (exact subset of range)
    local da = scope_broad.dst_port
    local db = scope_narrow.dst_port
    if type(da) == "number" and type(db) == "number" then
      if da ~= db then
        return false
      end
    elseif type(da) == "string" and type(db) == "number" then
      local lo_str, hi_str = da:match("^(%d+)-(%d+)$")
      if lo_str then
        local lo, hi = tonumber(lo_str), tonumber(hi_str)
        if db < lo or db > hi then
          return false
        end
      else
        return false
      end
    elseif type(da) == "string" and type(db) == "string" then
      local lo_a_s, hi_a_s = da:match("^(%d+)-(%d+)$")
      local lo_b_s, hi_b_s = db:match("^(%d+)-(%d+)$")
      if lo_a_s and lo_b_s then
        local lo_a, hi_a = tonumber(lo_a_s), tonumber(hi_a_s)
        local lo_b, hi_b = tonumber(lo_b_s), tonumber(hi_b_s)
        if lo_b < lo_a or hi_b > hi_a then
          return false
        end
      else
        return false
      end
    else
      -- Cannot determine containment
      return false
    end
  end

  -- detected_protocol: must match exactly if broad specifies it
  if scope_broad.detected_protocol ~= nil then
    if scope_narrow.detected_protocol ~= scope_broad.detected_protocol then
      return false
    end
  end

  -- sni: must match exactly if broad specifies it
  if scope_broad.sni ~= nil then
    if scope_narrow.sni ~= scope_broad.sni then
      return false
    end
  end

  -- query_param: broad map must be a subset of narrow map (broad is less restrictive)
  if scope_broad.query_param ~= nil then
    if scope_narrow.query_param == nil then
      return false
    end
    for k, v in pairs(scope_broad.query_param) do
      if scope_narrow.query_param[k] ~= v then
        return false
      end
    end
  end

  -- header: broad map must be a subset of narrow map
  if scope_broad.header ~= nil then
    if scope_narrow.header == nil then
      return false
    end
    local broad_norm, narrow_norm = {}, {}
    for k, v in pairs(scope_broad.header) do
      broad_norm[k:lower()] = v
    end
    for k, v in pairs(scope_narrow.header) do
      narrow_norm[k:lower()] = v
    end
    for k, v in pairs(broad_norm) do
      if narrow_norm[k] ~= v then
        return false
      end
    end
  end

  return true
end

-- ---------------------------------------------------------------------------
-- Internal: logging helper
-- ---------------------------------------------------------------------------

--- Emit a WARN log if ngx is available.
-- @param msg string
local function warn(msg)
  if ngx and ngx.log then
    ngx.log(ngx.WARN, "[luagate:conflict] ", msg)
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Detect conflicts and shadowed rules in a list of enabled rules.
--
-- Conflict (ADR-002 §3.2):
--   Two rules with identical scope, identical priority, but opposite actions.
--   (exact conflict)
--
--   Also detects overlap conflicts: same priority, scope A contains scope B
--   or vice-versa (or both contain each other), with opposite actions.
--   These are recorded with overlap_type = "overlap" to distinguish from
--   exact scope matches (overlap_type = "exact").
--
-- Shadowed (ADR-002 §3.2):
--   A rule with higher priority (lower number) and broader scope fully
--   covers a lower-priority rule, making it permanently unreachable.
--
-- Both types emit ngx.WARN logs.  Loading is NOT aborted (WARN only).
--
-- @param rules table  List of normalised rule tables (enabled=true only).
--                     The list need not be pre-sorted.
-- @return table  conflicts  List of { rule_a=id, rule_b=id, overlap_type=string } pairs
-- @return table  shadowed   List of rule id strings
function _M.detect(rules)
  local conflicts = {}
  local shadowed = {}
  local seen_shadowed = {} -- deduplicate shadowed list
  local seen_conflict = {} -- deduplicate conflict pairs

  local n = #rules
  for i = 1, n do
    local rule_a = rules[i]
    for j = i + 1, n do
      local rule_b = rules[j]

      -- ---------------------------------------------------------------
      -- Conflict: same priority + opposite action
      -- ---------------------------------------------------------------
      if rule_a.priority == rule_b.priority and rule_a.action ~= rule_b.action then
        local pair_key = rule_a.id .. "|" .. rule_b.id

        if scopes_equal(rule_a.scope, rule_b.scope) then
          -- Exact conflict: identical scope
          if not seen_conflict[pair_key] then
            seen_conflict[pair_key] = true
            conflicts[#conflicts + 1] = {
              rule_a = rule_a.id,
              rule_b = rule_b.id,
              overlap_type = "exact",
            }
            warn("conflict(exact): " .. rule_a.id .. " vs " .. rule_b.id)
          end
        elseif scope_contains(rule_a.scope, rule_b.scope) or scope_contains(rule_b.scope, rule_a.scope) then
          -- Overlap conflict: one scope contains the other (best-effort)
          if not seen_conflict[pair_key] then
            seen_conflict[pair_key] = true
            conflicts[#conflicts + 1] = {
              rule_a = rule_a.id,
              rule_b = rule_b.id,
              overlap_type = "overlap",
            }
            warn("conflict(overlap): " .. rule_a.id .. " vs " .. rule_b.id)
          end
        end
      end

      -- ---------------------------------------------------------------
      -- Shadowed: rule with lower priority index (higher priority number)
      -- that is fully covered by a rule with higher priority (lower number).
      -- We check both directions because the two loops skip j <= i.
      -- ---------------------------------------------------------------

      -- Case 1: rule_a has higher priority (lower priority number) and
      --         broader scope → rule_b is shadowed
      if rule_a.priority < rule_b.priority then
        if scope_contains(rule_a.scope, rule_b.scope) then
          if not seen_shadowed[rule_b.id] then
            seen_shadowed[rule_b.id] = true
            shadowed[#shadowed + 1] = rule_b.id
            warn("shadowed rule: " .. rule_b.id .. " by " .. rule_a.id)
          end
        end
      end

      -- Case 2: rule_b has higher priority and broader scope → rule_a is shadowed
      if rule_b.priority < rule_a.priority then
        if scope_contains(rule_b.scope, rule_a.scope) then
          if not seen_shadowed[rule_a.id] then
            seen_shadowed[rule_a.id] = true
            shadowed[#shadowed + 1] = rule_a.id
            warn("shadowed rule: " .. rule_a.id .. " by " .. rule_b.id)
          end
        end
      end
    end
  end

  return conflicts, shadowed
end

--- Detect conflicts and raise an error if any are found (fail-closed variant).
-- Intended for use at policy load time when strict conflict rejection is needed.
-- Shadowed rules are returned but do NOT cause an error.
--
-- @param rules table  List of normalised rule tables (enabled=true only).
-- @return table  conflicts  (always empty — error is raised if non-empty)
-- @return table  shadowed   List of rule id strings
-- @raises string  Error message listing all conflicting rule pairs
function _M.detect_and_fail(rules)
  local conflicts, shadowed = _M.detect(rules)
  if #conflicts > 0 then
    local ids = {}
    for _, c in ipairs(conflicts) do
      ids[#ids + 1] = c.rule_a .. "<->" .. c.rule_b .. "(" .. (c.overlap_type or "?") .. ")"
    end
    error("[luagate] policy conflict detected: " .. table.concat(ids, ", "))
  end
  return conflicts, shadowed
end

--- Filter a rules list to enabled=true entries only.
-- Convenience helper — typically called before detect().
-- @param rules table  Full rule list (may include enabled=false rules)
-- @return table        Only enabled=true rules
function _M.filter_enabled(rules)
  local enabled = {}
  for _, rule in ipairs(rules) do
    if rule.enabled ~= false then
      enabled[#enabled + 1] = rule
    end
  end
  return enabled
end

return _M
