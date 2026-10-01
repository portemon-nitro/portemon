-- Native critical checks. Each check consumes exactly one labeled battle
-- draw and compares it against the exact stage threshold of the 16-bit
-- roll: stage 0 crits below 4096 (one in sixteen), rising through the
-- native stage table to a coin flip at the cap. Negative stages behave as
-- stage 0 and stages above the table behave as the cap. The result carries
-- the threshold it was tested against so damage-stage exceptions stay
-- independently testable from this roll.

---@class CriticalResult
---@field critical boolean
---@field stage integer
---@field threshold integer
local Critical = {}

Critical.THRESHOLDS = { [0] = 4096, 8192, 16384, 21845, 32768 }
Critical.MAX_STAGE = 4

---@param stage integer critical stage before clamping
---@param stream BattleRng labeled native battle stream
---@param cause table<string, unknown> semantic reason that ordered the draw
---@return CriticalResult staged critical outcome
function Critical.resolve(stage, stream, cause)
  assert(type(stage) == "number" and stage % 1 == 0, "critical checks read an integer stage")
  assert(type(stream) == "table" and type(stream.nextU16) == "function", "critical checks draw from the battle stream")
  assert(type(cause) == "table", "critical checks carry their semantic cause")
  local clamped = stage
  if clamped < 0 then
    clamped = 0
  elseif clamped > Critical.MAX_STAGE then
    clamped = Critical.MAX_STAGE
  end
  local threshold = Critical.THRESHOLDS[clamped]
  assert(type(threshold) == "number", "critical stages map to an exact threshold")
  local draw = stream:nextU16("critical_check", cause)
  return { critical = draw < threshold, stage = stage, threshold = threshold }
end

return Critical
