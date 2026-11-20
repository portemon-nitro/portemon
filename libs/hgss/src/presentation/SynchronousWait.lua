-- The one wait for explicitly synchronous owners that block on worker-owned
-- assets. A staged build has a frame checkpoint to yield, so it never reaches
-- this; an explicitly blocking entry has none, and sleeping hands the CPU to the
-- worker that has to produce the payload instead of hot-polling it. The sleep
-- stays short because the wait is bounded by the worker, not by this module.

local SynchronousWait = {}

local SLEEP_SECONDS = 0.001

function SynchronousWait.block()
  local timer = love and love.timer
  if timer ~= nil and timer.sleep ~= nil then
    timer.sleep(SLEEP_SECONDS)
  end
end

return SynchronousWait
