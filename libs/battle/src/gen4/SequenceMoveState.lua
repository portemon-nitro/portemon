-- Owns the activation-scoped state shared by native multi-action moves.
local BattleState = require("libs.battle.src.BattleState")

local M = {}

local SEMI_INVULNERABLE = {
  FLY = "fly",
  DIG = "dig",
  DIVE = "dive",
  BOUNCE = "bounce",
  SHADOW_FORCE = "shadowforce",
}

local function validateState(candidate)
  if type(candidate) ~= "table" or candidate.version ~= 1 then
    error("sequence move state carries its version")
  end
  local state = { version = 1 }
  for key, value in pairs(candidate) do
    if key == "chargeMove" then
      if type(value) ~= "string" or value == "" then
        error("sequence charge state names its move")
      end
      state.chargeMove = value
    elseif key == "lock" then
      if
        type(value) ~= "table"
        or type(value.move) ~= "string"
        or value.move == ""
        or type(value.remaining) ~= "number"
        or value.remaining % 1 ~= 0
        or value.remaining < 0
        or value.remaining > 4
      then
        error("sequence lock state names its move and remaining actions")
      end
      state.lock = { move = value.move, remaining = value.remaining }
    elseif key == "ramp" then
      if
        type(value) ~= "table"
        or type(value.move) ~= "string"
        or value.move == ""
        or type(value.count) ~= "number"
        or value.count % 1 ~= 0
        or value.count < 1
        or value.count > 5
        or type(value.turn) ~= "number"
        or value.turn % 1 ~= 0
        or value.turn < 0
      then
        error("sequence ramp state names its move, count, and native turn")
      end
      state.ramp = { move = value.move, count = value.count, turn = value.turn }
    elseif key == "electricBoost" then
      if value ~= true then
        error("Charge state is present only while its boost is available")
      end
      state.electricBoost = true
    elseif key ~= "version" then
      error("sequence move state carries no unknown fields")
    end
  end
  return state
end

local DEFINITION = {
  key = "sequencemove",
  stateVersion = 1,
  validateState = validateState,
  timings = { { timing = "leave", handler = "sequencemove", orderClass = "affliction" } },
  lifecycle = { stacking = "replace", transfer = "clear", persistent = false },
}

---@param state table<string, unknown> live battle state
---@param combatant integer active combatant whose sequence state is read
---@return table<string, unknown>? validated sequence state for the active entry
function M.readLive(state, combatant)
  local bag = state.effectBag --[[@as table<string, unknown>]]
  local active = BattleState.combatant(state, combatant).active
  if active == nil then
    return nil
  end
  for _, record in ipairs(bag:capture()) do
    local scope = record.scope --[[@as table<string, unknown>]]
    if
      record.key == DEFINITION.key
      and scope.kind == "active"
      and scope.combatant == combatant
      and scope.activation == active.activation
    then
      local entry = bag:get(record.id --[[@as integer]])
      assert(entry ~= nil, "sequence state comes from a live effect record")
      return validateState((entry --[[@as table<string, unknown>]]).state)
    end
  end
  return nil
end

---@param state table<string, unknown> live battle state
---@param combatant integer active combatant whose action is under sequencing
---@return string? source move forced by a stored charge or lock
function M.forcedMove(state, combatant)
  local stored = M.readLive(state, combatant)
  if stored == nil then
    return nil
  end
  local lock = stored.lock
  if
    type(lock) == "table"
    and lock.remaining --[[@as integer]]
      > 0
  then
    return lock.move --[[@as string]]
  end
  return stored.chargeMove --[[@as string?]]
end

---@param state table<string, unknown> live battle state
---@param combatant integer active combatant whose charge state is read
---@return string? semi-invulnerable move state, or nil when the entry is hittable
function M.semiInvulnerable(state, combatant)
  local stored = M.readLive(state, combatant)
  if stored == nil or type(stored.chargeMove) ~= "string" then
    return nil
  end
  return SEMI_INVULNERABLE[stored.chargeMove]
end

---@param context BattleContext mechanics context under a sequence transition
---@param combatant integer user whose stored state is read
---@return table<string, unknown>? validated state, nil if absent
function M.read(context, combatant)
  local current = nil
  local function preserveState(state)
    current = state
    return state
  end
  context:updateBattleEffect(combatant, DEFINITION, preserveState)
  return current
end

---@param context BattleContext mechanics context under a sequence transition
---@param combatant integer user owning sequence state
---@param source table<string, unknown> cause of the state transition
---@param transition fun(state: table<string, unknown>): table<string, unknown>? replacement state, nil to remove
function M.update(context, combatant, source, transition)
  local current = M.read(context, combatant) or { version = 1 }
  local nextState = transition(current)
  if nextState == nil then
    context:removeBattleEffect(combatant, DEFINITION.key)
    return
  end
  local validated = validateState(nextState)
  local present = false
  for key in pairs(validated) do
    if key ~= "version" then
      present = true
      break
    end
  end
  if not present then
    context:removeBattleEffect(combatant, DEFINITION.key)
    return
  end
  if M.read(context, combatant) ~= nil then
    local function replaceState(_)
      return validated
    end
    context:updateBattleEffect(combatant, DEFINITION, replaceState)
  else
    local entry = context:entryOf(combatant)
    assert(entry.activation ~= nil, "sequence state scopes to a live entry")
    context:addBattleEffect(
      DEFINITION,
      { kind = "active", combatant = combatant, activation = entry.activation },
      source,
      validated
    )
  end
end

return M
