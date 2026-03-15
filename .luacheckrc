-- LuaGate luacheck configuration
-- LuaJIT / Lua 5.1 semantics — matches OpenResty runtime
std = "luajit"
max_line_length = 120

-- OpenResty globals: ngx/ndk는 필드 쓰기가 허용됨 (ngx.status, ngx.header 등)
globals = {
  "ngx",
  "ndk",
}

read_globals = {
  "require",
  "pcall",
  "xpcall",
  "tostring",
  "tonumber",
  "type",
  "pairs",
  "ipairs",
  "unpack",
  "error",
  "setmetatable",
  "getmetatable",
  "rawget",
  "rawset",
  "select",
  "table",
  "string",
  "math",
  "io",
  "os",
}

-- Ignore generated / vendor files
exclude_files = {
  "frontend/",
  "csrc/build/",
}

files["tests/"] = {
  -- Allow test helpers and globals
  globals = { "describe", "it", "before_each", "after_each", "assert", "spy", "stub", "mock" },
}
