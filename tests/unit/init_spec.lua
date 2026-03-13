-- Busted spec for lua/luagate/init.lua
-- Verifies the module loads and exposes the expected interface.

-- Stub the OpenResty globals that init.lua touches
_G.ngx = {
  header = {},
  status = 200,
  say    = function(s) _G._last_say = s end,
}

local init = require("luagate.init")

describe("luagate.init", function()
  it("exports a handle function", function()
    assert.is_function(init.handle)
  end)

  it("handle() sets X-LuaGate-Version header", function()
    init.handle()
    assert.is_string(ngx.header["X-LuaGate-Version"])
    assert.matches("^%d+%.%d+%.%d+$", ngx.header["X-LuaGate-Version"])
  end)

  it("handle() writes a non-empty response body", function()
    init.handle()
    assert.is_string(_G._last_say)
    assert.is_true(#_G._last_say > 0)
  end)
end)
