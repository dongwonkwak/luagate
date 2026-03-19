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
end)
