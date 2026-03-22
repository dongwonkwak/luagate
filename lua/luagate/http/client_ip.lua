--- Real client IP resolution module.
-- Resolves the actual client IP behind proxies/load balancers.
-- Priority: PROXY protocol → XFF (rightmost non-trusted) → remote_addr
--
-- Fail-safe: on any error, falls back to ngx.var.remote_addr.
--
-- @module luagate.http.client_ip

local _M = {}

--- Default empty trusted proxy set.
local _trusted_proxies = {}
local _trusted_cidrs = {}

--- Validate that a string is a well-formed IPv4 address.
-- @param addr string candidate IP address
-- @return boolean
local function is_valid_ipv4(addr)
  if type(addr) ~= "string" then
    return false
  end
  local a, b, c, d = addr:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then
    return false
  end
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  return a <= 255 and b <= 255 and c <= 255 and d <= 255
end

--- Convert IPv4 address string to a 32-bit numeric value.
-- @param addr string IPv4 address
-- @return number|nil numeric value, or nil if invalid
local function ip_to_num(addr)
  local a, b, c, d = addr:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then
    return nil
  end
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if a > 255 or b > 255 or c > 255 or d > 255 then
    return nil
  end
  -- Use multiplication to avoid potential overflow with bit shifts in plain Lua
  return a * 16777216 + b * 65536 + c * 256 + d
end

--- Check if an IP matches a CIDR range.
-- @param cidr string CIDR notation (e.g. "10.0.0.0/8")
-- @param ip string IP address to check
-- @return boolean
local function match_cidr(cidr, ip)
  local network, mask_str = cidr:match("^([^/]+)/(%d+)$")
  if not network then
    -- Treat as exact match if no mask
    return cidr == ip
  end

  local mask = tonumber(mask_str)
  if not mask then
    return false
  end

  local net_num = ip_to_num(network)
  local ip_num = ip_to_num(ip)
  if not net_num or not ip_num then
    return false
  end

  if mask == 0 then
    return true
  end
  if mask == 32 then
    return net_num == ip_num
  end

  -- Create bitmask: shift right then shift left to zero out host bits
  local shift = 32 - mask
  -- Integer division to simulate right shift, then multiply back
  local divisor = 2 ^ shift
  local net_masked = math.floor(net_num / divisor)
  local ip_masked = math.floor(ip_num / divisor)
  return net_masked == ip_masked
end

--- Check if an IP is in the trusted proxy list.
-- @param ip string IP address
-- @return boolean
local function is_trusted(ip)
  if _trusted_proxies[ip] then
    return true
  end
  for _, cidr in ipairs(_trusted_cidrs) do
    if match_cidr(cidr, ip) then
      return true
    end
  end
  return false
end

--- Configure trusted proxy list.
-- Call this during init or when configuration changes.
-- @param proxies table Array of IP addresses or CIDR ranges
function _M.configure(proxies)
  _trusted_proxies = {}
  _trusted_cidrs = {}
  if not proxies then
    return
  end
  for _, entry in ipairs(proxies) do
    if type(entry) == "string" then
      if entry:find("/") then
        _trusted_cidrs[#_trusted_cidrs + 1] = entry
      else
        _trusted_proxies[entry] = true
      end
    end
  end
end

--- Parse X-Forwarded-For header and return the rightmost non-trusted IP.
-- XFF format: "client, proxy1, proxy2"
-- Walk from right to left, skip trusted proxies, return first non-trusted.
-- This is the secure approach: entries added by trusted proxies (on the right)
-- are skipped, and the first untrusted entry is the real client boundary.
-- Walking left-to-right would be vulnerable to client-injected spoofed IPs.
-- @param xff_header string X-Forwarded-For header value
-- @return string|nil resolved IP, or nil if no valid non-trusted IP found
function _M.parse_xff(xff_header)
  if not xff_header or xff_header == "" then
    return nil
  end

  -- Split by comma, trim whitespace
  local ips = {}
  for part in xff_header:gmatch("[^,]+") do
    local trimmed = part:match("^%s*(.-)%s*$")
    if trimmed and trimmed ~= "" then
      ips[#ips + 1] = trimmed
    end
  end

  if #ips == 0 then
    return nil
  end

  -- Walk from right to left (closest to server first).
  -- Skip trusted proxies, then inspect only the first untrusted boundary.
  -- If that token is not a valid IPv4, stop and let the caller fall back.
  for i = #ips, 1, -1 do
    local ip = ips[i]
    if not is_trusted(ip) then
      if is_valid_ipv4(ip) then
        return ip
      end
      return nil
    end
  end

  -- All XFF entries are trusted or invalid — return nil (caller falls back to remote_addr)
  return nil
end

--- Resolve real client IP for the current request.
-- Priority:
--   1. PROXY protocol (ngx.var.proxy_protocol_addr if available and valid IPv4)
--   2. XFF header (rightmost non-trusted valid IP, only if remote_addr is trusted)
--   3. remote_addr (direct connection fallback)
-- @return string resolved client IP
function _M.resolve()
  local remote_addr = ngx.var.remote_addr or "0.0.0.0"

  -- 1. PROXY protocol: if proxy_protocol_addr is set, non-empty, and valid IPv4
  -- Requires nginx `listen ... proxy_protocol;` to be enabled.
  local pp_addr = ngx.var.proxy_protocol_addr
  if pp_addr and pp_addr ~= "" then
    if is_valid_ipv4(pp_addr) then
      return pp_addr
    end
    -- Invalid PROXY protocol address — log and fall through
    ngx.log(ngx.WARN, "[luagate] invalid PROXY protocol addr, ignoring: ", pp_addr)
  end

  -- 2. XFF: only parse if direct connection is from a trusted proxy
  if is_trusted(remote_addr) then
    local xff = ngx.var.http_x_forwarded_for
    if xff then
      local resolved = _M.parse_xff(xff)
      if resolved then
        return resolved
      end
    end
  end

  -- 3. Fallback: direct connection IP
  return remote_addr
end

-- Expose for testing
_M._match_cidr = match_cidr
_M._is_trusted = is_trusted
_M._is_valid_ipv4 = is_valid_ipv4

return _M
