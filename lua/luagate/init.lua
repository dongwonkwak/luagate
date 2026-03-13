--- LuaGate entry point.
-- Loaded by nginx content_by_lua_block for every proxied request.

local _M = {}
local VERSION = "0.1.0"

--- Main request handler (stub — replaced in HTTP pipeline epic).
function _M.handle()
  ngx.header["X-LuaGate-Version"] = VERSION
  ngx.status = 200
  ngx.say("LuaGate " .. VERSION .. " — OK")
end

return _M
