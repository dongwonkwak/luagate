--- Unit tests for lua/luagate/http/client_ip.lua
-- Implementation: lua/luagate/http/client_ip.lua
-- Tests: tests/unit/http/client_ip_spec.lua

-- ---------------------------------------------------------------------------
-- ngx mock
-- ---------------------------------------------------------------------------
_G.ngx = _G.ngx or {}
ngx.var = ngx.var or {}
ngx.log = ngx.log or function() end
ngx.ERR = 0
ngx.WARN = 1
ngx.NOTICE = 2

-- ---------------------------------------------------------------------------
-- helper: reset module state between tests
-- ---------------------------------------------------------------------------
local function reload_client_ip()
  package.loaded["luagate.http.client_ip"] = nil
  return require("luagate.http.client_ip")
end

describe("luagate.http.client_ip", function()
  local client_ip

  before_each(function()
    client_ip = reload_client_ip()
    ngx.var = {}
  end)

  -- =======================================================================
  -- _match_cidr
  -- =======================================================================
  describe("_match_cidr", function()
    it("matches exact IP without mask", function()
      assert.is_true(client_ip._match_cidr("10.0.0.1", "10.0.0.1"))
      assert.is_false(client_ip._match_cidr("10.0.0.1", "10.0.0.2"))
    end)

    it("matches /32 exactly", function()
      assert.is_true(client_ip._match_cidr("192.168.1.1/32", "192.168.1.1"))
      assert.is_false(client_ip._match_cidr("192.168.1.1/32", "192.168.1.2"))
    end)

    it("matches /24 network", function()
      assert.is_true(client_ip._match_cidr("10.0.1.0/24", "10.0.1.55"))
      assert.is_true(client_ip._match_cidr("10.0.1.0/24", "10.0.1.255"))
      assert.is_false(client_ip._match_cidr("10.0.1.0/24", "10.0.2.1"))
    end)

    it("matches /16 network", function()
      assert.is_true(client_ip._match_cidr("172.16.0.0/16", "172.16.255.1"))
      assert.is_false(client_ip._match_cidr("172.16.0.0/16", "172.17.0.1"))
    end)

    it("matches /8 network", function()
      assert.is_true(client_ip._match_cidr("10.0.0.0/8", "10.255.255.255"))
      assert.is_false(client_ip._match_cidr("10.0.0.0/8", "11.0.0.1"))
    end)

    it("matches /0 (any IP)", function()
      assert.is_true(client_ip._match_cidr("0.0.0.0/0", "1.2.3.4"))
      assert.is_true(client_ip._match_cidr("0.0.0.0/0", "255.255.255.255"))
    end)

    it("returns false for invalid IP", function()
      assert.is_false(client_ip._match_cidr("10.0.0.0/8", "not-an-ip"))
      assert.is_false(client_ip._match_cidr("not-cidr/8", "10.0.0.1"))
    end)

    it("returns false for out-of-range octets", function()
      assert.is_false(client_ip._match_cidr("10.0.0.0/8", "256.0.0.1"))
    end)
  end)

  -- =======================================================================
  -- configure
  -- =======================================================================
  describe("configure", function()
    it("accepts nil without error", function()
      assert.has_no.errors(function()
        client_ip.configure(nil)
      end)
    end)

    it("accepts empty table", function()
      assert.has_no.errors(function()
        client_ip.configure({})
      end)
    end)

    it("accepts mix of IPs and CIDRs", function()
      assert.has_no.errors(function()
        client_ip.configure({ "127.0.0.1", "10.0.0.0/8", "192.168.0.0/16" })
      end)
    end)
  end)

  -- =======================================================================
  -- _is_trusted
  -- =======================================================================
  describe("_is_trusted", function()
    it("returns false with no trusted proxies configured", function()
      client_ip.configure({})
      assert.is_false(client_ip._is_trusted("10.0.0.1"))
    end)

    it("matches exact IP in trusted list", function()
      client_ip.configure({ "10.0.0.1", "172.16.0.1" })
      assert.is_true(client_ip._is_trusted("10.0.0.1"))
      assert.is_true(client_ip._is_trusted("172.16.0.1"))
      assert.is_false(client_ip._is_trusted("10.0.0.2"))
    end)

    it("matches CIDR in trusted list", function()
      client_ip.configure({ "10.0.0.0/8" })
      assert.is_true(client_ip._is_trusted("10.1.2.3"))
      assert.is_false(client_ip._is_trusted("11.0.0.1"))
    end)
  end)

  -- =======================================================================
  -- parse_xff
  -- =======================================================================
  describe("parse_xff", function()
    it("returns nil for empty/nil header", function()
      client_ip.configure({})
      assert.is_nil(client_ip.parse_xff(nil, "1.2.3.4"))
      assert.is_nil(client_ip.parse_xff("", "1.2.3.4"))
    end)

    it("returns single IP when no trusted proxies", function()
      client_ip.configure({})
      assert.equals("5.6.7.8", client_ip.parse_xff("5.6.7.8", "1.2.3.4"))
    end)

    it("returns rightmost non-trusted IP", function()
      client_ip.configure({ "10.0.0.1", "10.0.0.2" })
      -- XFF: "5.6.7.8, 10.0.0.1, 10.0.0.2"
      -- Walk right to left: 10.0.0.2 (trusted) → 10.0.0.1 (trusted) → 5.6.7.8 (not trusted)
      assert.equals("5.6.7.8", client_ip.parse_xff("5.6.7.8, 10.0.0.1, 10.0.0.2", "1.2.3.4"))
    end)

    it("returns leftmost when all are trusted", function()
      client_ip.configure({ "10.0.0.0/8" })
      assert.equals("10.1.1.1", client_ip.parse_xff("10.1.1.1, 10.2.2.2, 10.3.3.3", "10.4.4.4"))
    end)

    it("handles whitespace around IPs", function()
      client_ip.configure({})
      assert.equals("5.6.7.8", client_ip.parse_xff("  5.6.7.8  ", "1.2.3.4"))
    end)

    it("skips trusted middle hops", function()
      client_ip.configure({ "10.0.0.0/8" })
      -- client → proxy1(10.1.1.1) → proxy2(10.2.2.2) → server
      -- XFF: "203.0.113.50, 10.1.1.1, 10.2.2.2"
      assert.equals("203.0.113.50", client_ip.parse_xff("203.0.113.50, 10.1.1.1, 10.2.2.2", "10.3.3.3"))
    end)
  end)

  -- =======================================================================
  -- resolve
  -- =======================================================================
  describe("resolve", function()
    it("returns remote_addr when no proxy protocol and no trusted proxies", function()
      client_ip.configure({})
      ngx.var.remote_addr = "1.2.3.4"
      ngx.var.proxy_protocol_addr = nil
      ngx.var.http_x_forwarded_for = nil
      assert.equals("1.2.3.4", client_ip.resolve())
    end)

    it("prefers PROXY protocol address when available", function()
      client_ip.configure({})
      ngx.var.remote_addr = "10.0.0.1"
      ngx.var.proxy_protocol_addr = "203.0.113.50"
      ngx.var.http_x_forwarded_for = "5.6.7.8"
      assert.equals("203.0.113.50", client_ip.resolve())
    end)

    it("ignores empty PROXY protocol address", function()
      client_ip.configure({})
      ngx.var.remote_addr = "1.2.3.4"
      ngx.var.proxy_protocol_addr = ""
      ngx.var.http_x_forwarded_for = nil
      assert.equals("1.2.3.4", client_ip.resolve())
    end)

    it("uses XFF when remote_addr is trusted proxy", function()
      client_ip.configure({ "10.0.0.1" })
      ngx.var.remote_addr = "10.0.0.1"
      ngx.var.proxy_protocol_addr = nil
      ngx.var.http_x_forwarded_for = "203.0.113.50"
      assert.equals("203.0.113.50", client_ip.resolve())
    end)

    it("ignores XFF when remote_addr is NOT trusted", function()
      client_ip.configure({ "10.0.0.1" })
      ngx.var.remote_addr = "5.6.7.8"
      ngx.var.proxy_protocol_addr = nil
      ngx.var.http_x_forwarded_for = "spoofed.ip"
      -- remote_addr is not trusted, so XFF is ignored (anti-spoofing)
      assert.equals("5.6.7.8", client_ip.resolve())
    end)

    it("falls back to remote_addr when XFF is empty", function()
      client_ip.configure({ "10.0.0.1" })
      ngx.var.remote_addr = "10.0.0.1"
      ngx.var.proxy_protocol_addr = nil
      ngx.var.http_x_forwarded_for = ""
      assert.equals("10.0.0.1", client_ip.resolve())
    end)

    it("resolves through multi-hop proxy chain", function()
      client_ip.configure({ "10.0.0.0/8" })
      ngx.var.remote_addr = "10.0.0.3"
      ngx.var.proxy_protocol_addr = nil
      -- Real client → CDN(10.0.0.1) → LB(10.0.0.2) → server(10.0.0.3)
      ngx.var.http_x_forwarded_for = "203.0.113.100, 10.0.0.1, 10.0.0.2"
      assert.equals("203.0.113.100", client_ip.resolve())
    end)

    it("returns 0.0.0.0 when remote_addr is nil", function()
      client_ip.configure({})
      ngx.var.remote_addr = nil
      ngx.var.proxy_protocol_addr = nil
      ngx.var.http_x_forwarded_for = nil
      assert.equals("0.0.0.0", client_ip.resolve())
    end)
  end)
end)
