--- Worker-local span buffer for LuaGate tracing.
-- ADR-010 §4: worker-level span buffer with atomic swap for flush.
--
-- Design:
--   - Each worker maintains its own buffer (no shared dict needed)
--   - log_by_lua appends completed spans
--   - Timer callback swaps buffer atomically and flushes the old one
--   - Max 4096 spans per worker (oldest dropped on overflow)
--
-- Implementation: lua/luagate/tracing/buffer.lua

local _M = {}

local MAX_QUEUE_SIZE = 4096

local _buffer = {}

--- Add a completed span to the buffer.
-- ADR-010 §4: cap at MAX_QUEUE_SIZE, oldest drop on overflow.
-- @param span table  Completed span object
function _M.add(span)
  if not span then
    return
  end
  if #_buffer >= MAX_QUEUE_SIZE then
    -- Drop oldest span (index 1)
    table.remove(_buffer, 1)
  end
  _buffer[#_buffer + 1] = span
end

--- Atomically swap and return the current buffer.
-- ADR-010 §4: "local batch = buffer; buffer = {}" atomic swap.
-- After swap, new appends go to the fresh buffer.
-- @return table  The batch of spans to flush
function _M.swap()
  local batch = _buffer
  _buffer = {}
  return batch
end

--- Get current buffer size (for metrics/monitoring).
-- @return number
function _M.size()
  return #_buffer
end

return _M
