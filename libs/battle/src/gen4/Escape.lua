-- Leaving battle. Trapping holds the combatant without spending the odds
-- roll, guaranteed conditions leave without rolling, trainer refusal is a
-- failed action that ends nothing, failed wild odds record exactly one
-- attempt per spent roll with improving odds afterwards, and forced exits
-- record which side left for the result selector. Native anchor:
-- BattleTryRun (battle commands and materialization overlay): the byte odds
-- are player speed times 128 over enemy speed plus thirty per attempt,
-- escape succeeds when the single labeled roll falls under the odds, and
-- faster combatants leave outright without a roll.

---@class Escape
local Escape = {}

---@param value unknown
---@return boolean
local function isPositiveInt(value)
  return type(value) == "number" and value == value and value % 1 == 0 and value >= 1 and value <= 9007199254740991
end

---@param query table<string, unknown>
---@return boolean
local function isTrapped(query)
  if query.trapped == true then
    return true
  end
  return type(query.trapped) == "table" and query.trapped.held == true
end

--- Judges whether flight may be attempted. Trapping and trainer battles
--- refuse before any roll is spent.
---@param query table<string, unknown> flight inputs under test
---@return table<string, unknown> flight gate carrying ok and, on refusal, reason
function Escape.canRun(query)
  assert(type(query) == "table", "flight reads a query record")
  if isTrapped(query) then
    return { ok = false, reason = "trapped" }
  end
  if query.battleKind == "trainer" then
    return { ok = false, reason = "refused" }
  end
  return { ok = true }
end

--- Attempts flight. Trapped runs, trainer refusal, and guaranteed
--- conditions spend no roll and record no attempt. Wild odds spend exactly
--- one labeled roll: failures advance the attempt counter by one while
--- successes leave it alone.
---@param inputs table<string, unknown> flight inputs carrying kind, gates, speeds, counter, and stream
---@return table<string, unknown> flight outcome carrying escaped, reason, and attempts
function Escape.attempt(inputs)
  assert(type(inputs) == "table", "flight attempts carry their attempt inputs")
  assert(
    type(inputs.attempts) == "number" and inputs.attempts % 1 == 0 and inputs.attempts >= 0,
    "flight attempts count prior spent rolls"
  )
  if isTrapped(inputs) then
    return { escaped = false, reason = "trapped", attempts = inputs.attempts }
  end
  if inputs.battleKind == "trainer" then
    return { escaped = false, reason = "refused", attempts = inputs.attempts }
  end
  if inputs.guaranteed == true then
    return { escaped = true, reason = "guaranteed", attempts = inputs.attempts }
  end
  local speeds = inputs.speeds
  assert(type(speeds) == "table", "wild odds compare both combatant speeds")
  assert(type(speeds.player) == "number" and speeds.player > 0, "wild odds read a positive player speed")
  assert(type(speeds.enemy) == "number" and speeds.enemy > 0, "wild odds read a positive enemy speed")
  if speeds.player >= speeds.enemy then
    return { escaped = true, reason = "guaranteed", attempts = inputs.attempts }
  end
  local stream = inputs.stream
  assert(type(stream) == "table" and type(stream.nextU16) == "function", "wild odds spend one labeled roll")
  local odds = (math.floor((speeds.player * 128) / speeds.enemy) + 30 * inputs.attempts) % 256
  local roll = stream:nextU16("escape:odds", { battleKind = inputs.battleKind, attempts = inputs.attempts }) % 256
  if roll < odds then
    return { escaped = true, reason = "odds", attempts = inputs.attempts }
  end
  return { escaped = false, reason = "odds", attempts = inputs.attempts + 1 }
end

--- Records a forced exit for the result selector.
---@param params table<string, unknown> exit inputs naming the side that left
---@return table<string, unknown> exit record carrying the fled side
function Escape.forceExit(params)
  assert(type(params) == "table", "forced exits name the side that left")
  assert(isPositiveInt(params.side), "forced exits name a positive side")
  local cause = params.cause
  if cause == nil then
    cause = "fled"
  end
  assert(type(cause) == "string" and cause ~= "", "forced exits name their cause")
  return { fledSide = params.side, cause = cause }
end

return Escape
