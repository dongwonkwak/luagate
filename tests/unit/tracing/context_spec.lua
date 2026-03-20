--- Unit tests for lua/luagate/tracing/context.lua
-- Tests W3C traceparent parsing, trace_id/span_id generation.
-- Implementation: lua/luagate/tracing/context.lua

-- ---------------------------------------------------------------------------
-- Stubs for OpenResty environment
-- ---------------------------------------------------------------------------
_G.ngx = {
  log = function() end,
  ERR = 3,
  WARN = 4,
  INFO = 6,
}

-- ffi stub for non-OpenResty test environment
-- context.lua uses ffi for random generation; we need to stub or skip
-- if not running under LuaJIT

local context

-- Try to load — if ffi is not available, skip FFI-dependent tests
local ok = pcall(function()
  context = require("luagate.tracing.context")
end)

if not ok then
  -- Running under Lua 5.x without ffi — create stub for parse tests only
  describe("tracing.context (no FFI)", function()
    pending("requires LuaJIT for FFI-based random generation")
  end)
  return
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------
describe("tracing.context", function()
  describe("parse_traceparent", function()
    it("parses a valid traceparent with sampled=1", function()
      local result = context.parse_traceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
      assert.is_not_nil(result)
      assert.are.equal("4bf92f3577b34da6a3ce929d0e0e4736", result.trace_id)
      assert.are.equal("00f067aa0ba902b7", result.parent_id)
      assert.is_true(result.sampled)
    end)

    it("parses a valid traceparent with sampled=0", function()
      local result = context.parse_traceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00")
      assert.is_not_nil(result)
      assert.is_false(result.sampled)
    end)

    it("returns nil for nil input", function()
      assert.is_nil(context.parse_traceparent(nil))
    end)

    it("returns nil for empty string", function()
      assert.is_nil(context.parse_traceparent(""))
    end)

    it("returns nil for malformed input", function()
      assert.is_nil(context.parse_traceparent("not-a-traceparent"))
    end)

    it("returns nil for wrong trace_id length", function()
      assert.is_nil(context.parse_traceparent("00-4bf92f3577b34da6-00f067aa0ba902b7-01"))
    end)

    it("returns nil for all-zero trace_id", function()
      assert.is_nil(context.parse_traceparent("00-00000000000000000000000000000000-00f067aa0ba902b7-01"))
    end)

    it("returns nil for all-zero span_id", function()
      assert.is_nil(context.parse_traceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01"))
    end)

    it("lowercases trace_id and parent_id", function()
      local result = context.parse_traceparent("00-4BF92F3577B34DA6A3CE929D0E0E4736-00F067AA0BA902B7-01")
      assert.is_not_nil(result)
      assert.are.equal("4bf92f3577b34da6a3ce929d0e0e4736", result.trace_id)
      assert.are.equal("00f067aa0ba902b7", result.parent_id)
    end)
  end)

  describe("new_trace_id", function()
    it("generates a 32-character hex string", function()
      local tid = context.new_trace_id()
      assert.are.equal(32, #tid)
      assert.truthy(tid:match("^%x+$"))
    end)

    it("generates unique values", function()
      local a = context.new_trace_id()
      local b = context.new_trace_id()
      assert.are_not.equal(a, b)
    end)
  end)

  describe("new_span_id", function()
    it("generates a 16-character hex string", function()
      local sid = context.new_span_id()
      assert.are.equal(16, #sid)
      assert.truthy(sid:match("^%x+$"))
    end)
  end)

  describe("build_traceparent", function()
    it("builds correct format with sampled=true", function()
      local tp = context.build_traceparent("4bf92f3577b34da6a3ce929d0e0e4736", "00f067aa0ba902b7", true)
      assert.are.equal("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", tp)
    end)

    it("builds correct format with sampled=false", function()
      local tp = context.build_traceparent("4bf92f3577b34da6a3ce929d0e0e4736", "00f067aa0ba902b7", false)
      assert.are.equal("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00", tp)
    end)
  end)
end)
