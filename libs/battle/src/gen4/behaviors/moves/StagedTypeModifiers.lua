-- Exact type modifiers for staged damage arithmetic. Ordinary strikes
-- resolve same-type attack bonus and the exact session-chart ratio, while
-- delayed impacts land as typeless Generation-IV damage through the
-- explicit typeless contract; missing facts fail before arithmetic instead
-- of falling back to neutral. Both damage bridges share this one owner so
-- sequence strikes can never drift back to neutral modifiers.
-- Source references: src/battle/battle_command.c and
-- src/battle/overlay_12_0224E4FC.c.

local BattleErrors = require("libs.battle.src.errors")
local TypeEffectiveness = require("libs.battle.src.gen4.TypeEffectiveness")

---@class StagedTypeModifiers
local StagedTypeModifiers = {}

---@param frame table<string, unknown> move frame under execution
---@return table<string, unknown> validated move locals carrying the frame facts
local function checkLocals(frame)
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  if type(locals) ~= "table" then
    error(BattleErrors.missingBehavior("damage reads its immutable move facts", {
      key = record.executingMove --[[@as string]],
      fact = "locals",
    }))
  end
  return locals
end

---@param frame table<string, unknown> move frame under execution
---@return string executing move type under the strike
local function moveTypeOf(frame)
  local record = frame --[[@as table<string, unknown>]]
  local key = record.executingMove --[[@as string]]
  local move = checkLocals(frame).move
  if type(move) ~= "table" then
    error(BattleErrors.missingBehavior("damage reads its immutable move facts", { key = key, fact = "move" }))
  end
  local moveType = (move --[[@as table<string, unknown>]]).moveType
  if type(moveType) ~= "string" or moveType == "" then
    error(BattleErrors.missingBehavior("damage reads its immutable move facts", { key = key, fact = "moveType" }))
  end
  return moveType --[[@as string]]
end

---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the strike
---@return string[] semantic attacker types for the strike
---@return string[] semantic defender types for the strike
---@return table<string, unknown> session type chart resolving directed effectiveness
local function battleFactsOf(frame, defender)
  local record = frame --[[@as table<string, unknown>]]
  local key = record.executingMove --[[@as string]]
  local locals = checkLocals(frame)
  local attackerTypes = locals.attackerTypes
  if type(attackerTypes) ~= "table" or #attackerTypes == 0 then
    error(
      BattleErrors.missingBehavior("damage reads its semantic attacker facts", { key = key, fact = "attackerTypes" })
    )
  end
  for _, attackerType in
    ipairs(attackerTypes --[[@as string[] ]])
  do
    if type(attackerType) ~= "string" or attackerType == "" then
      error(
        BattleErrors.missingBehavior("damage reads its semantic attacker facts", { key = key, fact = "attackerTypes" })
      )
    end
  end
  local defenders = locals.defenderTypes
  if type(defenders) ~= "table" then
    error(
      BattleErrors.missingBehavior("damage reads its semantic defender facts", { key = key, fact = "defenderTypes" })
    )
  end
  local defenderTypes = (defenders --[[@as table<integer, unknown>]])[defender]
  if type(defenderTypes) ~= "table" then
    error(
      BattleErrors.missingBehavior("damage reads its semantic defender facts", { key = key, fact = "defenderTypes" })
    )
  end
  local chart = locals.typeChart
  if
    type(chart) ~= "table" or type((chart --[[@as table<string, unknown>]]).effectiveness) ~= "function"
  then
    error(BattleErrors.missingBehavior("damage reads its session type chart", { key = key, fact = "typeChart" }))
  end
  return attackerTypes, --[[@as string[] ]]
    defenderTypes, --[[@as string[] ]]
    chart --[[@as table<string, unknown>]]
end

---@param moveType string executing move type under the strike
---@param attackerTypes string[] semantic attacker types for the strike
---@return table<string, integer> exact STAB rational for the staged arithmetic
local function stabOf(moveType, attackerTypes)
  local stab = { numerator = 1, denominator = 1 }
  if
    TypeEffectiveness.stab(moveType --[[@as string]], attackerTypes --[[@as string[] ]])
  then
    stab = { numerator = 3, denominator = 2 }
  end
  return stab
end

---@param chart table<string, unknown> session type chart resolving directed effectiveness
---@param moveType string executing move type under the strike
---@param defenderTypes string[] semantic defender types for the strike
---@param immunityContext table<string, unknown> immunity context for the resolution
---@return table<string, integer> exact effectiveness rational for the staged arithmetic
local function effectivenessOf(chart, moveType, defenderTypes, immunityContext)
  local resolved = TypeEffectiveness.resolve(
    chart --[[@as table<string, unknown>]],
    moveType --[[@as string]],
    defenderTypes --[[@as string[] ]],
    immunityContext
  )
  return { numerator = resolved.numerator, denominator = resolved.denominator }
end

---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the strike
---@return table<string, integer> exact STAB rational for the staged arithmetic
---@return table<string, integer> exact effectiveness rational for the staged arithmetic
function StagedTypeModifiers.forStrike(frame, defender)
  local moveType = moveTypeOf(frame)
  local attackerTypes, defenderTypes, chart = battleFactsOf(frame, defender)
  return stabOf(moveType, attackerTypes), effectivenessOf(chart, moveType, defenderTypes, {})
end

---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the landing
---@return table<string, integer> exact STAB rational for the staged arithmetic
---@return table<string, integer> exact effectiveness rational for the staged arithmetic
function StagedTypeModifiers.forDelayedImpact(frame, defender)
  local attackerTypes, defenderTypes, chart = battleFactsOf(frame, defender)
  return stabOf("typeless", attackerTypes), effectivenessOf(chart, "typeless", defenderTypes, { typeless = true })
end

return StagedTypeModifiers
