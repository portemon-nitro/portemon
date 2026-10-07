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
---@return table<string, unknown> exact effectiveness rational with ordered per-type factors
local function effectivenessOf(chart, moveType, defenderTypes, immunityContext)
  local resolved = TypeEffectiveness.resolve(
    chart --[[@as table<string, unknown>]],
    moveType --[[@as string]],
    defenderTypes --[[@as string[] ]],
    immunityContext
  )
  return { numerator = resolved.numerator, denominator = resolved.denominator, factors = resolved.factors }
end

-- Strike immunity modifiers beside the chart: magnet rise grounds
-- nothing, identified ghosts lose their normal/fighting immunity, and
-- gravity grounds flying targets and rising ones alike. Source
-- references: the grounded hazard checks and BattleSystem_CheckMoveHit
-- in the native battle sources (flying, magnet rise, and foresight
-- handling).
---@param moveType string executing move type under the strike
---@param defenderTypes string[] semantic defender types under filtering
---@param immunities table<string, unknown>|nil airborne, foresight, and gravity facts for the strike
---@return string[] defender types with identification applied
---@return table<string, unknown> immunity context for the resolution
local function immunityFor(moveType, defenderTypes, immunities)
  local facts = immunities or {}
  local filtered = {}
  for _, defenderType in ipairs(defenderTypes) do
    filtered[#filtered + 1] = defenderType
  end
  if facts.foresight == true and (moveType == "normal" or moveType == "fighting") then
    local identified = {}
    for _, defenderType in ipairs(filtered) do
      if defenderType ~= "ghost" then
        identified[#identified + 1] = defenderType
      end
    end
    filtered = identified
  end
  if facts.gravity == true and moveType == "ground" then
    local grounded = {}
    for _, defenderType in ipairs(filtered) do
      if defenderType ~= "flying" then
        grounded[#grounded + 1] = defenderType
      end
    end
    return grounded, {}
  end
  if facts.airborne == true and moveType == "ground" then
    return filtered, { airborne = true }
  end
  return filtered, {}
end

---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the strike
---@param immunities table<string, unknown>|nil airborne, foresight, and gravity facts for the strike
---@param moveTypeOverride string|nil source-computed move type replacing the compiled one
---@return table<string, integer> exact STAB rational for the staged arithmetic
---@return table<string, unknown> exact effectiveness rational with ordered per-type factors
function StagedTypeModifiers.forStrike(frame, defender, immunities, moveTypeOverride)
  local moveType = moveTypeOf(frame)
  if moveTypeOverride ~= nil then
    if type(moveTypeOverride) ~= "string" or moveTypeOverride == "" then
      local record = frame --[[@as table<string, unknown>]]
      error(BattleErrors.missingBehavior("strikes name their computed move type", {
        key = record.executingMove --[[@as string]],
      }))
    end
    moveType = moveTypeOverride --[[@as string]]
  end
  local attackerTypes, defenderTypes, chart = battleFactsOf(frame, defender)
  local types, context = immunityFor(moveType, defenderTypes, immunities)
  return stabOf(moveType, attackerTypes), effectivenessOf(chart, moveType, types, context)
end

---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the landing
---@return table<string, integer> exact STAB rational for the staged arithmetic
---@return table<string, unknown> exact effectiveness rational with ordered per-type factors
function StagedTypeModifiers.forDelayedImpact(frame, defender)
  local attackerTypes, defenderTypes, chart = battleFactsOf(frame, defender)
  return stabOf("typeless", attackerTypes), effectivenessOf(chart, "typeless", defenderTypes, { typeless = true })
end

return StagedTypeModifiers
