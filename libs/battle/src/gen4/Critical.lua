-- Native critical checks. Each check consumes exactly one labeled battle
-- draw and tests it against the exact stage divisor of the 16-bit
-- roll: stage 0 crits on multiples of 16, rising through the native
-- stage table to every other draw at the cap. Negative stages behave as
-- stage 0 and stages above the table behave as the cap. Protections
-- negate a successful roll only after it is spent. The result carries
-- the divisor and the raw draw it was tested against plus the native
-- damage multiplier (double, or triple for the sniping ability) so
-- damage-stage exceptions stay independently testable from this roll.

---@class CriticalBlockers
---@field antiCriticalAbility boolean?
---@field luckyChant boolean?

---@class CriticalResult
---@field critical boolean
---@field multiplier integer
---@field stage integer
---@field divisor integer
---@field raw integer
local Critical = {}

Critical.DIVISORS = { [0] = 16, 8, 4, 3, 2 }
Critical.MAX_STAGE = 4

---@param blockers unknown trailing protection facts under validation
local function checkBlockers(blockers)
  if blockers == nil then
    return
  end
  assert(type(blockers) == "table", "critical checks read their blockers as a trailing record")
  for name, value in pairs(blockers) do
    assert(name == "antiCriticalAbility" or name == "luckyChant", "critical blockers name a native protection")
    assert(type(value) == "boolean", "critical blockers carry boolean facts")
  end
end

---@param stage integer critical stage before clamping
---@param stream BattleRng labeled native battle stream
---@param cause table<string, unknown> semantic reason that ordered the draw
---@param sniper boolean? whether the striker carries the triple-damage critical ability
---@param blockers CriticalBlockers? protections negating a successful roll after it is spent
---@return CriticalResult staged critical outcome
function Critical.resolve(stage, stream, cause, sniper, blockers)
  assert(type(stage) == "number" and stage % 1 == 0, "critical checks read an integer stage")
  assert(type(stream) == "table" and type(stream.nextU16) == "function", "critical checks draw from the battle stream")
  assert(type(cause) == "table", "critical checks carry their semantic cause")
  checkBlockers(blockers)
  local clamped = stage
  if clamped < 0 then
    clamped = 0
  elseif clamped > Critical.MAX_STAGE then
    clamped = Critical.MAX_STAGE
  end
  local divisor = Critical.DIVISORS[clamped]
  assert(type(divisor) == "number", "critical stages map to an exact divisor")
  local draw = stream:nextU16("critical_check", cause)
  local critical = (draw % divisor) == 0
  -- Protections never skip the draw: a spent success stays
  -- non-critical while the stream still advances exactly once.
  if critical and blockers ~= nil then
    if blockers.antiCriticalAbility == true or blockers.luckyChant == true then
      critical = false
    end
  end
  -- The ability only replaces the damage multiplier after a surviving
  -- roll: probability and draw count stay identical with or without it.
  if not critical then
    return { critical = false, multiplier = 1, stage = stage, divisor = divisor, raw = draw }
  end
  if sniper == true then
    return { critical = true, multiplier = 3, stage = stage, divisor = divisor, raw = draw }
  end
  return { critical = true, multiplier = 2, stage = stage, divisor = divisor, raw = draw }
end

return Critical
