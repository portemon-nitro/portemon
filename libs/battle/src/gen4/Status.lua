-- Native major status law over canonical mon conditions. One exclusive
-- persistent condition per mon: sleep, poison, burn, freeze, paralysis, or
-- toxic, stored on the mon record itself in the shared native vocabulary.
-- Application, action gating, cures, and replacement resets all operate in
-- place on that record; battle-transient state never enters it. Gates that
-- roll (paralysis, thawing) draw exactly one labeled battle-stream draw so
-- a fixed seed gates identically on replay, while sleep counts down one
-- turn per gate and healthy combatants draw nothing.

local BattleErrors = require("libs.battle.src.errors")
local StatusCodec = require("libs.mons.src.gen4.StatusCodec")

---@class MonConditionView
---@field currentHp integer
---@field effects table<integer, table<string, unknown>>

---@class MonStatusView
---@field condition MonConditionView

---@class StatusGateEvent
---@field key string
---@field outcome "blocked"|"woke"|"thawed"

---@class StatusGateResult
---@field acts boolean
---@field event StatusGateEvent?

---@class StatusBagView
---@field capture fun(self: StatusBagView): table<integer, table<string, unknown>>
---@field remove fun(self: StatusBagView, id: integer): boolean
---@field transfer fun(self: StatusBagView, id: integer, scope: table<string, unknown>): table<string, unknown>?

local Status = {}

local NATIVE_KEYS = {
  sleep = true,
  poison = true,
  burn = true,
  freeze = true,
  paralysis = true,
  toxic = true,
}

---@param mon unknown
---@return MonStatusView
local function checkMon(mon)
  if type(mon) ~= "table" then
    error(BattleErrors.invalidState("status law reads a mon record", {}))
  end
  assert(type(mon) == "table", "mon record validated above")
  local condition = mon.condition
  if type(condition) ~= "table" then
    error(BattleErrors.invalidState("status law reads the canonical condition", {}))
  end
  assert(type(condition) == "table", "mon condition validated above")
  if type(condition.currentHp) ~= "number" then
    error(BattleErrors.invalidState("status law reads canonical health", {}))
  end
  if type(condition.effects) ~= "table" then
    error(BattleErrors.invalidState("status law reads the canonical condition list", {}))
  end
  return mon --[[@as MonStatusView]]
end

---@param key unknown
---@return string
local function checkKey(key)
  if type(key) ~= "string" or NATIVE_KEYS[key] == nil then
    error(BattleErrors.invalidState("status law names a native major condition", { key = key }))
  end
  assert(type(key) == "string", "condition key validated above")
  return key
end

---@param state table<string, unknown> validated record shape
---@param allowed table<string, boolean> permitted field names
---@param key string
local function rejectUnknownFields(state, allowed, key)
  for name in pairs(state) do
    if allowed[name] == nil then
      error(BattleErrors.invalidState("condition " .. key .. " carries an unknown state field", { key = key }))
    end
  end
end

---@param key string
---@param state unknown
---@return table<string, unknown> normalized typed state for the condition
local function normalizeState(key, state)
  if type(state) ~= "table" then
    error(BattleErrors.invalidState("conditions carry typed state records", { key = key }))
  end
  assert(type(state) == "table", "condition state validated above")
  if key == "sleep" then
    rejectUnknownFields(state, { turns = true }, key)
    return { turns = state.turns }
  end
  if key == "toxic" then
    rejectUnknownFields(state, { counter = true }, key)
    local counter = state.counter
    if counter == nil then
      counter = 0
    end
    return { counter = counter }
  end
  rejectUnknownFields(state, {}, key)
  return {}
end

--- Applies a major condition in place. The mon must be alive and healthy;
--- rejection leaves the live record untouched.
---@param mon MonStatusView canonical mon record owning its persistent condition
---@param key string native major condition to apply
---@param source table<string, unknown> causal source of the application
---@param state table<string, unknown> candidate typed state for the condition
---@return boolean true when the condition was applied
function Status.apply(mon, key, source, state)
  local checked = checkMon(mon)
  local conditionKey = checkKey(key)
  assert(type(source) == "table", "condition application carries its causal source")
  if checked.condition.currentHp <= 0 then
    error(BattleErrors.invalidState("the fainted cannot gain a condition", { key = conditionKey }))
  end
  if #checked.condition.effects > 0 then
    error(BattleErrors.invalidState("major conditions are exclusive", {
      key = conditionKey,
      present = checked.condition.effects[1].key,
    }))
  end
  local normalized = normalizeState(conditionKey, state)
  local candidate = { key = conditionKey, version = StatusCodec.VERSION, state = normalized }
  StatusCodec.checkEffect(candidate)
  checked.condition.effects = { { key = conditionKey, version = StatusCodec.VERSION, state = normalized } }
  return true
end

---@param stream unknown
---@param cause unknown
---@param label string call-site identity recorded with the draw
---@return integer raw battle-stream draw for the gate
local function drawGate(stream, cause, label)
  if type(stream) ~= "table" or type(stream.nextU16) ~= "function" then
    error(BattleErrors.invalidState("status gates draw from the battle stream", {}))
  end
  assert(type(cause) == "table", "status gates carry their semantic cause")
  return stream.nextU16(stream, label, cause)
end

--- Gates one action through the live condition. Sleep consumes exactly one
--- turn per gate and wakes at zero; paralysis and freeze roll one labeled
--- draw; every other condition and full health act untouched.
---@param mon MonStatusView canonical mon record owning its persistent condition
---@param stream table<string, unknown> labeled battle stream for rolled gates
---@param cause table<string, unknown> semantic reason ordering the gate
---@return StatusGateResult action permission with its gate event
function Status.beforeAction(mon, stream, cause)
  local checked = checkMon(mon)
  assert(type(cause) == "table", "status gates carry their semantic cause")
  local current = checked.condition.effects[1]
  if current == nil then
    return { acts = true, event = nil }
  end
  local key = checkKey(current.key)
  if key == "sleep" then
    local state = current.state
    if type(state) ~= "table" or type(state.turns) ~= "number" then
      error(BattleErrors.invalidState("sleep carries its remaining turns", {}))
    end
    assert(type(state) == "table", "sleep state validated above")
    local remaining = state.turns - 1
    if remaining <= 0 then
      checked.condition.effects = {}
      return { acts = true, event = { key = "sleep", outcome = "woke" } }
    end
    current.state = { turns = remaining }
    return { acts = false, event = { key = "sleep", outcome = "blocked" } }
  end
  if key == "paralysis" then
    local draw = drawGate(stream, cause, "paralysis_check")
    if draw % 4 == 0 then
      return { acts = false, event = { key = "paralysis", outcome = "blocked" } }
    end
    return { acts = true, event = nil }
  end
  if key == "freeze" then
    local draw = drawGate(stream, cause, "freeze_thaw")
    if draw % 5 == 0 then
      checked.condition.effects = {}
      return { acts = true, event = { key = "freeze", outcome = "thawed" } }
    end
    return { acts = false, event = { key = "freeze", outcome = "blocked" } }
  end
  return { acts = true, event = nil }
end

--- Removes the matching condition; curing an absent condition changes
--- nothing and reports no work.
---@param mon MonStatusView canonical mon record owning its persistent condition
---@param key string native major condition to remove
---@return boolean true when a condition was cured
function Status.cure(mon, key)
  local checked = checkMon(mon)
  local conditionKey = checkKey(key)
  for index, effect in ipairs(checked.condition.effects) do
    if effect.key == conditionKey then
      table.remove(checked.condition.effects, index)
      return true
    end
  end
  return false
end

--- Resets battle-local attachment for a replacement entry: the departing
--- activation loses its volatile instances except carry-policy state,
--- which is re-anchored onto the incoming token, while wider scopes and
--- the canonical condition survive untouched. The toxic counter restarts
--- without curing; every other condition stays byte-identical.
---@param mon MonStatusView canonical mon record owning its persistent condition
---@param bag StatusBagView scoped instance owner carrying the battle state
---@param combatant integer combatant identity being replaced
---@param newActivation integer entry token of the incoming occupant
---@return boolean true when the reset completed
function Status.switchReset(mon, bag, combatant, newActivation)
  local checked = checkMon(mon)
  assert(type(bag) == "table", "replacement resets clear battle state through the bag")
  assert(type(combatant) == "number", "replacement resets name their combatant")
  assert(type(newActivation) == "number", "replacement resets name the incoming entry token")
  for _, record in ipairs(bag:capture()) do
    local scope = record.scope
    if type(scope) == "table" and scope.kind == "active" and scope.combatant == combatant then
      local transfer = nil
      if type(record.lifecycle) == "table" then
        transfer = record.lifecycle.transfer
      end
      if transfer == "carry" then
        bag:transfer(record.id, { kind = "active", combatant = combatant, activation = newActivation })
      else
        bag:remove(record.id)
      end
    end
  end
  for _, effect in ipairs(checked.condition.effects) do
    if effect.key == "toxic" then
      local restarted = { key = "toxic", version = StatusCodec.VERSION, state = { counter = 0 } }
      StatusCodec.checkEffect(restarted)
      effect.state = { counter = 0 }
    end
  end
  return true
end

return Status
