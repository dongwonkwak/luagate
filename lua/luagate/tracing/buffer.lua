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
local _head = 1
local _size = 0
local _dropped_total = 0

local function incr_dropped_metric()
  local dict = ngx.shared.luagate_metrics
  if dict then
    dict:incr("luagate_tracing_spans_dropped_total", 1, 0)
  end
end

--- Add a completed span to the buffer.
-- ADR-010 §4: cap at MAX_QUEUE_SIZE, oldest drop on overflow.
-- Increments dropped counter for observability (ADR-010 Consequences).
-- @param span table  Completed span object
function _M.add(span)
  if not span then
    return
  end
  if _size >= MAX_QUEUE_SIZE then
    -- Overwrite the oldest span in-place and advance head for O(1) overflow handling.
    _buffer[_head] = span
    _head = (_head % MAX_QUEUE_SIZE) + 1
    _dropped_total = _dropped_total + 1
    incr_dropped_metric()
    return
  end

  local tail = ((_head + _size - 1) % MAX_QUEUE_SIZE) + 1
  _buffer[tail] = span
  _size = _size + 1
end

--- Get total number of dropped spans (for testing/metrics).
-- @return number
function _M.dropped_total()
  return _dropped_total
end

--- Atomically swap and return the current buffer.
-- Returns spans in FIFO order, then resets the buffer state.
-- @return table  The batch of spans to flush
function _M.swap()
  local batch = {}
  for i = 1, _size do
    local index = ((_head + i - 2) % MAX_QUEUE_SIZE) + 1
    batch[i] = _buffer[index]
  end

  _buffer = {}
  _head = 1
  _size = 0
  return batch
end

--- Get current buffer size (for metrics/monitoring).
-- @return number
function _M.size()
  return _size
end

return _M
