--- Unit tests for lua/luagate/tracing/sampler.lua
-- Tests head-based probabilistic sampling with parent-based override.
-- Implementation: lua/luagate/tracing/sampler.lua

_G.ngx = {
  log = function() end,
  ERR = 3,
  WARN = 4,
  INFO = 6,
}

local sampler = require("luagate.tracing.sampler")

describe("tracing.sampler", function()
  before_each(function()
    sampler.set_rate(0.5)
  end)

  describe("set_rate / get_rate", function()
    it("sets and gets sample rate", function()
      sampler.set_rate(0.42)
      assert.are.equal(0.42, sampler.get_rate())
    end)

    it("rejects negative rate and falls back to default", function()
      sampler.set_rate(-0.1)
      assert.are.equal(0.01, sampler.get_rate())
    end)

    it("rejects rate > 1 and falls back to default", function()
      sampler.set_rate(1.5)
      assert.are.equal(0.01, sampler.get_rate())
    end)

    it("rejects non-number and falls back to default", function()
      sampler.set_rate("abc")
      assert.are.equal(0.01, sampler.get_rate())
    end)
  end)

  describe("should_sample", function()
    it("respects parent sampled=true (parent-based)", function()
      sampler.set_rate(0.0) -- local rate = 0, but parent says sample
      assert.is_true(sampler.should_sample({ sampled = true }))
    end)

    it("respects parent sampled=false (parent-based)", function()
      sampler.set_rate(1.0) -- local rate = 100%, but parent says no
      assert.is_false(sampler.should_sample({ sampled = false }))
    end)

    it("always samples when rate=1.0 and no parent", function()
      sampler.set_rate(1.0)
      for _ = 1, 100 do
        assert.is_true(sampler.should_sample(nil))
      end
    end)

    it("never samples when rate=0.0 and no parent", function()
      sampler.set_rate(0.0)
      for _ = 1, 100 do
        assert.is_false(sampler.should_sample(nil))
      end
    end)

    it("samples approximately at configured rate", function()
      sampler.set_rate(0.5)
      local sampled_count = 0
      local total = 10000
      for _ = 1, total do
        if sampler.should_sample(nil) then
          sampled_count = sampled_count + 1
        end
      end
      -- Should be roughly 50% ± 5%
      local ratio = sampled_count / total
      assert.is_true(ratio > 0.4 and ratio < 0.6, "expected ~50% sampling, got " .. (ratio * 100) .. "%")
    end)
  end)
end)
