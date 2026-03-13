-- LuaGate luacheck configuration
-- LuaJIT / Lua 5.1 semantics — matches OpenResty runtime
std = "luajit"
max_line_length = 120

-- OpenResty read-only globals (write access is an error, not a feature)
read_globals = {
  "ngx",
  "ndk",
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

globals = {}

-- Ignore generated / vendor files
exclude_files = {
  "frontend/",
  "csrc/build/",
}

files["tests/"] = {
  -- Allow test helpers and globals
  globals = { "describe", "it", "before_each", "after_each", "assert", "spy", "stub", "mock" },
}
