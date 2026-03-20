--- Head-based probabilistic sampler for LuaGate tracing.
-- ADR-010 §5: Head-based sampling with parent-based override.
--
-- Sampling decision matrix:
--   inbound traceparent + sampled=1 → force sample (parent-based)
--   inbound traceparent + sampled=0 → no sample (parent-based)
--   no inbound → local rate applies
--
-- Implementation: lua/luagate/tracing/sampler.lua

local _M = {}

local _sample_rate = 0.01 -- production default (1%)

--- Configure the sample rate.
-- @param rate number  0.0 to 1.0
function _M.set_rate(rate)
  if type(rate) ~= "number" or rate < 0 or rate > 1 then
    ngx.log(ngx.ERR, "[luagate:tracing] invalid sample_rate: ", tostring(rate), ", using default 0.01")
    _sample_rate = 0.01
    return
  end
  _sample_rate = rate
end

--- Get the current sample rate.
-- @return number
function _M.get_rate()
  return _sample_rate
end

--- Determine whether to sample this request.
-- ADR-010 §5: parent-based when inbound traceparent exists.
-- @param parsed_ctx table|nil  Parsed traceparent (from context.parse_traceparent)
-- @return boolean  true if this trace should be sampled (exported)
function _M.should_sample(parsed_ctx)
  -- Parent-based: if inbound traceparent exists, respect its sampled flag
  if parsed_ctx then
    return parsed_ctx.sampled
  end

  -- No inbound: local rate-based sampling
  if _sample_rate >= 1.0 then
    return true
  end
  if _sample_rate <= 0.0 then
    return false
  end

  return math.random() < _sample_rate
end

return _M
