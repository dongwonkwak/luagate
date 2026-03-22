-- Unit tests for lua/luagate/admin/token.lua — token rotation handler.
-- Uses busted framework with OpenResty mocks.

local function make_shared_dict()
  local store = {}
  local ttls = {}
  return {
    get = function(_, key)
      -- Check TTL expiry (simulated)
      if ttls[key] and ttls[key] < os.time() then
        store[key] = nil
        ttls[key] = nil
        return nil
      end
      return store[key]
    end,
    set = function(_, key, val, ttl)
      store[key] = val
      if ttl and ttl > 0 then
        ttls[key] = os.time() + ttl
      else
        ttls[key] = nil
      end
      return true
    end,
    safe_set = function(self, key, val, ttl)
      return self:set(key, val, ttl)
    end,
    delete = function(_, key)
      store[key] = nil
      ttls[key] = nil
    end,
    _store = store,
    _ttls = ttls,
  }
end

local function setup_ngx()
  local response_status = 200
  local response_body = nil
  local response_headers = {}
  local request_body = nil
  local log_messages = {}

  _G.ngx = {
    status = 200,
    var = { remote_addr = "127.0.0.1", uri = "/api/v1/admin/token/rotate" },
    header = setmetatable({}, {
      __newindex = function(t, k, v)
        response_headers[k] = v
        rawset(t, k, v)
      end,
    }),
    shared = {
      luagate_state = make_shared_dict(),
    },
    req = {
      read_body = function() end,
      get_body_data = function()
        return request_body
      end,
      get_headers = function()
        -- Return active token from shared dict if rotation occurred, else default
        local active = _G.ngx.shared.luagate_state and _G.ngx.shared.luagate_state:get("luagate_admin_token")
        local token_val = active or string.rep("x", 32)
        return { Authorization = "Bearer " .. token_val }
      end,
    },
    say = function(body)
      response_body = body
    end,
    exit = function(status)
      response_status = status
      -- In tests, do NOT throw — just record
    end,
    log = function(level, ...)
      local parts = {}
      for _, v in ipairs({ ... }) do
        parts[#parts + 1] = tostring(v)
      end
      log_messages[#log_messages + 1] = {
        level = level,
        msg = table.concat(parts),
      }
    end,
    ERR = 4,
    EMERG = 0,
    utctime = function()
      return "2026-03-19 00:00:00"
    end,
  }

  return {
    set_body = function(body)
      request_body = body
    end,
    get_status = function()
      return response_status
    end,
    get_body = function()
      return response_body
    end,
    get_headers = function()
      return response_headers
    end,
    get_logs = function()
      return log_messages
    end,
    get_dict = function()
      return _G.ngx.shared.luagate_state
    end,
  }
end

describe("token rotation handler", function()
  local token_mod
  local ctx

  before_each(function()
    package.loaded["luagate.admin.token"] = nil
    package.loaded["cjson.safe"] = nil

    -- Mock cjson.safe
    package.preload["cjson.safe"] = function()
      local cjson = {}
      function cjson.decode(str)
        -- Simple JSON parser for tests
        if not str or str == "" then
          return nil, "empty"
        end
        -- Try to extract new_token from {"new_token": "value"}
        local val = str:match('"new_token"%s*:%s*"([^"]*)"')
        if val then
          return { new_token = val }
        end
        -- Check if it's valid JSON-ish
        if str:sub(1, 1) ~= "{" then
          return nil, "invalid json"
        end
        return {}
      end
      function cjson.encode(tbl)
        if not tbl then
          return nil
        end
        local parts = {}
        for k, v in pairs(tbl) do
          if type(v) == "string" then
            parts[#parts + 1] = '"' .. k .. '":"' .. v .. '"'
          elseif type(v) == "number" then
            parts[#parts + 1] = '"' .. k .. '":' .. v
          elseif type(v) == "table" then
            local arr = {}
            for _, item in ipairs(v) do
              arr[#arr + 1] = '"' .. tostring(item) .. '"'
            end
            parts[#parts + 1] = '"' .. k .. '":[' .. table.concat(arr, ",") .. "]"
          end
        end
        return "{" .. table.concat(parts, ",") .. "}"
      end
      return cjson
    end

    ctx = setup_ngx()
    token_mod = require("luagate.admin.token")
  end)

  it("rotates token with valid new_token", function()
    local new_token = string.rep("a", 32)
    ctx.set_body('{"new_token": "' .. new_token .. '"}')

    token_mod.handle_post_rotate()

    local dict = ctx.get_dict()
    assert.are.equal(new_token, dict:get("luagate_admin_token"))
  end)

  it("rejects empty request body", function()
    ctx.set_body(nil)
    token_mod.handle_post_rotate()

    local body = ctx.get_body()
    assert.truthy(body)
    assert.truthy(body:find("bad_request"))
  end)

  it("rejects invalid JSON", function()
    ctx.set_body("not json")
    token_mod.handle_post_rotate()

    local body = ctx.get_body()
    assert.truthy(body)
    assert.truthy(body:find("bad_request"))
  end)

  it("rejects missing new_token field", function()
    ctx.set_body("{}")
    token_mod.handle_post_rotate()

    local body = ctx.get_body()
    assert.truthy(body)
    assert.truthy(body:find("new_token"))
  end)

  it("rejects token shorter than 32 characters", function()
    ctx.set_body('{"new_token": "short"}')
    token_mod.handle_post_rotate()

    local body = ctx.get_body()
    assert.truthy(body)
    assert.truthy(body:find("too short"))
  end)

  it("stores old token with grace period TTL", function()
    local dict = ctx.get_dict()
    local old_token = string.rep("b", 32)
    dict:set("luagate_admin_token", old_token)

    local new_token = string.rep("c", 32)
    ctx.set_body('{"new_token": "' .. new_token .. '"}')

    token_mod.handle_post_rotate()

    assert.are.equal(new_token, dict:get("luagate_admin_token"))
    assert.are.equal(old_token, dict:get("luagate_admin_token_old"))
  end)

  it("fails closed when safe_set returns no memory during grace token write", function()
    local dict = ctx.get_dict()
    local old_token = string.rep("b", 32)
    local new_token = string.rep("c", 32)
    local original_safe_set = dict.safe_set
    dict:set("luagate_admin_token", old_token)
    dict.safe_set = function(_, key, val, ttl)
      if key == "luagate_admin_token_old" then
        return nil, "no memory"
      end
      return original_safe_set(dict, key, val, ttl)
    end

    ctx.set_body('{"new_token": "' .. new_token .. '"}')
    token_mod.handle_post_rotate()

    local body = ctx.get_body()
    assert.are.equal(500, ctx.get_status())
    assert.truthy(body)
    assert.truthy(body:find("internal_error"))
    assert.are.equal(old_token, dict:get("luagate_admin_token"))
    assert.is_nil(dict:get("luagate_admin_token_old"))
  end)

  it("writes audit log without token values", function()
    local new_token = string.rep("d", 32)
    ctx.set_body('{"new_token": "' .. new_token .. '"}')

    token_mod.handle_post_rotate()

    local logs = ctx.get_logs()
    local found_audit = false
    for _, entry in ipairs(logs) do
      if entry.msg:find("token_rotated") then
        found_audit = true
        -- Token value must NOT appear in log
        assert.falsy(entry.msg:find(new_token))
      end
    end
    assert.is_true(found_audit)
  end)

  it("fails closed when shared dict is unavailable", function()
    _G.ngx.shared.luagate_state = nil

    local new_token = string.rep("e", 32)
    ctx.set_body('{"new_token": "' .. new_token .. '"}')

    token_mod.handle_post_rotate()

    local body = ctx.get_body()
    assert.truthy(body)
    assert.truthy(body:find("internal_error"))
  end)

  -- -----------------------------------------------------------------------
  -- Audit log guarantee boundary (DON-223)
  -- -----------------------------------------------------------------------
  describe("감사 로그 보장 범위", function()
    it("audit_log는 cjson.encode 실패 시 false를 반환하고 mutation을 롤백한다", function()
      local dict = ctx.get_dict()
      local old_token = string.rep("f", 32)
      dict:set("luagate_admin_token", old_token)

      -- Make cjson.encode return nil (simulate serialization failure)
      local cjson_mod = package.loaded["cjson.safe"]
      local original_encode = cjson_mod.encode
      cjson_mod.encode = function(tbl)
        -- Fail on audit log data (has "event" field)
        if type(tbl) == "table" and tbl.event then
          return nil
        end
        return original_encode(tbl)
      end

      local new_token = string.rep("g", 32)
      ctx.set_body('{"new_token": "' .. new_token .. '"}')

      token_mod.handle_post_rotate()

      -- Should respond with 500 audit_write_failed
      local body = ctx.get_body()
      assert.truthy(body, "should have a response body")
      assert.truthy(body:find("audit_write_failed"), "should return audit_write_failed error")

      -- Mutation should be rolled back: old token restored
      assert.are.equal(old_token, dict:get("luagate_admin_token"), "active token should be rolled back to old value")

      -- Restore
      cjson_mod.encode = original_encode
    end)

    it("audit_log는 정상 encode 시 true를 반환하고 rotation이 완료된다", function()
      local new_token = string.rep("h", 32)
      ctx.set_body('{"new_token": "' .. new_token .. '"}')

      token_mod.handle_post_rotate()

      -- Rotation succeeds
      local dict = ctx.get_dict()
      assert.are.equal(new_token, dict:get("luagate_admin_token"))

      -- Audit log is written
      local logs = ctx.get_logs()
      local found_audit = false
      for _, entry in ipairs(logs) do
        if entry.msg:find("token_rotated") then
          found_audit = true
          break
        end
      end
      assert.is_true(found_audit, "audit log should be written on successful rotation")
    end)

    it("cjson.encode 실패 시 old token이 없으면 active token을 삭제한다", function()
      -- No pre-existing token in shared dict, env fallback also nil
      local original_getenv = os.getenv
      os.getenv = function(key) -- luacheck: ignore 122
        if key == "LUAGATE_ADMIN_TOKEN" then
          return nil
        end
        return original_getenv(key)
      end

      local cjson_mod = package.loaded["cjson.safe"]
      local original_encode = cjson_mod.encode
      cjson_mod.encode = function(tbl)
        if type(tbl) == "table" and tbl.event then
          return nil
        end
        return original_encode(tbl)
      end

      local new_token = string.rep("i", 32)
      ctx.set_body('{"new_token": "' .. new_token .. '"}')

      token_mod.handle_post_rotate()

      local body = ctx.get_body()
      assert.truthy(body:find("audit_write_failed"), "should return audit_write_failed")

      -- When there was no old token, rollback deletes the active token key
      local dict = ctx.get_dict()
      assert.is_nil(
        dict:get("luagate_admin_token"),
        "active token should be deleted on rollback when no previous token existed"
      )

      -- Restore
      cjson_mod.encode = original_encode
      os.getenv = original_getenv -- luacheck: ignore 122
    end)
  end)
end)
