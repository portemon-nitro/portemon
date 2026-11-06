-- Healthy effect-voice completion queries for battle presentation tests.
-- Sound tasks arm on their first unfinished observation and complete on
-- the first finished observation after that, so a voice that never
-- reports alive fails loudly at the bounded wait. A recording double
-- carries no playback clock: each voice parks exactly one query as
-- playing, and completion follows at once because there is no real
-- lifecycle to await. Centralized so the healthy-voice shape stays in
-- lockstep with the sound tasks' arming contract. Test-only fixture.

local M = {}

-- Returns a per-symbol wait query: false on the first query for each
-- voice (the parked observation that arms the voice), true after that.
---@return fun(symbol: string): boolean
function M.healthyWait()
  local armed = {}
  return function(symbol)
    if armed[symbol] ~= true then
      armed[symbol] = true
      return false
    end
    return true
  end
end

return M
