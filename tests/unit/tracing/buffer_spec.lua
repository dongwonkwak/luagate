--- Unit tests for lua/luagate/tracing/buffer.lua
-- Tests worker-local span buffer with cap and swap.
-- Implementation: lua/luagate/tracing/buffer.lua

_G.ngx = {
  log = function() end,
  ERR = 3,
  shared = {
    luagate_metrics = {
      incr = function(_, _key, _val, _init)
        return true
      end,
    },
  },
}

-- Force reload each test
local function load_buffer()
  package.loaded["luagate.tracing.buffer"] = nil
  return require("luagate.tracing.buffer")
end

describe("tracing.buffer", function()
  local buffer

  before_each(function()
    buffer = load_buffer()
  end)

  it("starts empty", function()
    assert.are.equal(0, buffer.size())
  end)

  it("adds spans and tracks size", function()
    buffer.add({ trace_id = "a", span_id = "1" })
    buffer.add({ trace_id = "b", span_id = "2" })
    assert.are.equal(2, buffer.size())
  end)

  it("ignores nil spans", function()
    buffer.add(nil)
    assert.are.equal(0, buffer.size())
  end)

  it("swaps and returns batch, leaving empty buffer", function()
    buffer.add({ trace_id = "a", span_id = "1" })
    buffer.add({ trace_id = "b", span_id = "2" })

    local batch = buffer.swap()
    assert.are.equal(2, #batch)
    assert.are.equal(0, buffer.size())
  end)

  it("new adds go to fresh buffer after swap", function()
    buffer.add({ trace_id = "a", span_id = "1" })
    buffer.swap()
    buffer.add({ trace_id = "c", span_id = "3" })
    assert.are.equal(1, buffer.size())
  end)

  it("drops oldest when exceeding max size (4096)", function()
    for i = 1, 4096 do
      buffer.add({ trace_id = tostring(i), span_id = tostring(i) })
    end
    assert.are.equal(4096, buffer.size())

    -- Add one more — should drop oldest
    buffer.add({ trace_id = "overflow", span_id = "overflow" })
    assert.are.equal(4096, buffer.size())

    local batch = buffer.swap()
    -- First item should be "2" (1 was dropped)
    assert.are.equal("2", batch[1].trace_id)
    -- Last item should be "overflow"
    assert.are.equal("overflow", batch[#batch].trace_id)
  end)

  it("preserves FIFO order across repeated overflows", function()
    for i = 1, 4100 do
      buffer.add({ trace_id = tostring(i), span_id = tostring(i) })
    end

    assert.are.equal(4096, buffer.size())
    assert.are.equal(4, buffer.dropped_total())

    local batch = buffer.swap()
    assert.are.equal("5", batch[1].trace_id)
    assert.are.equal("4100", batch[#batch].trace_id)
  end)
end)
