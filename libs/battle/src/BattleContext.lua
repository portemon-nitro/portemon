-- Validated mechanics mutation surface. Rule and behavior execution
-- receives a context instead of the state table, so every write passes one
-- checked endpoint and carries its semantic cause. The context never escapes
-- execution: callers keep snapshots, views, and events, never this writer.

local BattleErrors = require("libs.battle.src.errors")
local BattleProtocol = require("libs.battle.src.BattleProtocol")
local BattleState = require("libs.battle.src.BattleState")

---@class BattleContext
---@field private _state table<string, unknown>
local BattleContext = {}
BattleContext.__index = BattleContext

---@param value unknown
---@return unknown
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local input = value --[[@as table<unknown, unknown>]]
  local out = {}
  for key, item in pairs(input) do
    out[key] = copyValue(item)
  end
  return out
end

---@param state table<string, unknown> live battle state, held for one execution only
---@return BattleContext
function BattleContext.wrap(state)
  assert(type(state) == "table", "mechanics execution requires its battle state")
  return setmetatable({ _state = state }, BattleContext)
end

---@param kind string
---@param cause table<string, unknown>
---@param payload table<string, unknown>
---@param audience string?
---@return table<string, unknown> the emitted event
function BattleContext:emit(kind, cause, payload, audience)
  assert(type(kind) == "string" and kind ~= "", "emitted events require their kind")
  assert(type(cause) == "table", "emitted events require their cause")
  assert(type(payload) == "table", "emitted events require their payload record")
  local sequence = self._state.sequence --[[@as integer]] + 1
  self._state.sequence = sequence
  local event = {
    sequence = sequence,
    kind = kind,
    cause = copyValue(cause),
    audience = audience or "public",
    payload = copyValue(payload),
  }
  BattleProtocol.validateEvent(event)
  local outbox = self._state.outbox --[[@as table<integer, table<string, unknown>>]]
  outbox[#outbox + 1] = event
  return event
end

---@param combatantId integer
---@param amount integer
---@param cause table<string, unknown>
---@return table<string, integer> before/after health around the strike
function BattleContext:damage(combatantId, amount, cause)
  assert(type(combatantId) == "number", "damage requires its combatant")
  assert(type(amount) == "number" and amount % 1 == 0 and amount >= 0, "damage amounts stay integral")
  assert(type(cause) == "table", "damage requires its cause")
  local combatant = BattleState.combatant(self._state, combatantId)
  if combatant.active == nil then
    error(BattleErrors.invalidState("strikes land only on active combatants", { combatant = combatantId }))
  end
  local before = combatant.hp --[[@as integer]]
  local after = before - amount --[[@as integer]]
  if after < 0 then
    after = 0
  end
  combatant.hp = after
  return { before = before, after = after }
end

---@param combatantId integer
---@param amount integer
---@param cause table<string, unknown>
---@return table<string, integer> before/after health around the recovery
function BattleContext:heal(combatantId, amount, cause)
  assert(type(combatantId) == "number", "recovery requires its combatant")
  assert(type(amount) == "number" and amount % 1 == 0 and amount >= 0, "recovery amounts stay integral")
  assert(type(cause) == "table", "recovery requires its cause")
  local combatant = BattleState.combatant(self._state, combatantId)
  local before = combatant.hp --[[@as integer]]
  local after = before + amount --[[@as integer]]
  if
    after > combatant.entryHp --[[@as integer]]
  then
    after = combatant.entryHp --[[@as integer]]
  end
  combatant.hp = after
  return { before = before, after = after }
end

---@param combatantId integer
---@param effect table<string, unknown>
function BattleContext:addEffect(combatantId, effect)
  assert(type(combatantId) == "number", "effect writes require their combatant")
  assert(type(effect) == "table", "effect writes require their effect record")
  if type(effect.key) ~= "string" or effect.key == "" then
    error(BattleErrors.invalidState("effects must name their key", { combatant = combatantId }))
  end
  if type(effect.scope) ~= "string" or effect.scope == "" then
    error(BattleErrors.invalidState("effects must name their scope", { combatant = combatantId }))
  end
  local combatant = BattleState.combatant(self._state, combatantId)
  local volatiles = combatant.volatiles --[[@as table<integer, table<string, unknown>>]]
  for _, held in ipairs(volatiles) do
    if held.key == effect.key then
      error(BattleErrors.invalidState("effects never stack under one key", {
        combatant = combatantId,
        effect = effect.key,
      }))
    end
  end
  volatiles[#volatiles + 1] = copyValue(effect) --[[@as table<string, unknown>]]
end

---@param combatantId integer
---@param key string
---@return boolean true when a held instance was removed
function BattleContext:removeEffect(combatantId, key)
  assert(type(combatantId) == "number", "effect removal requires its combatant")
  assert(type(key) == "string" and key ~= "", "effect removal requires its key")
  local combatant = BattleState.combatant(self._state, combatantId)
  local volatiles = combatant.volatiles --[[@as table<integer, table<string, unknown>>]]
  for index, held in ipairs(volatiles) do
    if held.key == key then
      table.remove(volatiles, index)
      return true
    end
  end
  return false
end

---@param combatantId integer
---@param patch table<string, unknown> battle-local projection overrides
function BattleContext:updateMon(combatantId, patch)
  assert(type(combatantId) == "number", "projection writes require their combatant")
  assert(type(patch) == "table", "projection writes require their patch record")
  local combatant = BattleState.combatant(self._state, combatantId)
  local materialized = combatant.materialized --[[@as table<string, unknown>]]
  for key, value in pairs(patch) do
    if type(key) ~= "string" or key == "" then
      error(BattleErrors.invalidState("projection overrides must be named", { combatant = combatantId }))
    end
    materialized[key] = copyValue(value)
  end
end

---@param frame table<string, unknown> plain continuation frame
function BattleContext:pushFrame(frame)
  assert(type(frame) == "table", "continuation frames must be records")
  if type(frame.kind) ~= "string" or frame.kind == "" then
    error(BattleErrors.invalidState("continuation frames must name their kind", {}))
  end
  if type(frame.version) ~= "number" or frame.version % 1 ~= 0 or frame.version < 1 then
    error(BattleErrors.invalidState("continuation frames must carry a positive version", {}))
  end
  if type(frame.cursor) ~= "string" or frame.cursor == "" then
    error(BattleErrors.invalidState("continuation frames must name their cursor", {}))
  end
  if type(frame.state) ~= "table" then
    error(BattleErrors.invalidState("continuation frames must carry plain state", {}))
  end
  local frames = self._state.frames --[[@as table<integer, table<string, unknown>>]]
  frames[#frames + 1] = copyValue(frame) --[[@as table<string, unknown>]]
end

---@param spec table<string, unknown> decision request under construction
---@return table<string, unknown> the appended request
function BattleContext:requestDecision(spec)
  assert(type(spec) == "table", "decision requests must be records")
  if type(spec.controller) ~= "string" or spec.controller == "" then
    error(BattleErrors.invalidState("decision requests must name their controller", {}))
  end
  if
    type(spec.kind) ~= "string" or not BattleProtocol.isDecisionKind(spec.kind --[[@as string]])
  then
    error(BattleErrors.missingBehavior("decision requests require a registered kind", {
      kind = tostring(spec.kind),
    }))
  end
  if
    type(spec.actors) ~= "table"
    or #spec.actors --[[@as table<integer, unknown>]]
      == 0
  then
    error(BattleErrors.invalidState("decision requests must address at least one actor", {}))
  end
  for _, actor in
    ipairs(spec.actors --[[@as table<integer, unknown>]])
  do
    if type(actor) ~= "table" then
      error(BattleErrors.invalidState("decision requests must address combatant records", {}))
    end
    local record = actor --[[@as table<string, unknown>]]
    if type(record.combatant) ~= "number" or type(record.activation) ~= "number" then
      error(BattleErrors.invalidState("decision actors must carry combatant and token", {}))
    end
    BattleState.combatant(self._state, record.combatant --[[@as integer]])
  end
  if type(spec.legalChoices) ~= "table" then
    error(BattleErrors.invalidState("decision requests must freeze their legal choice view", {}))
  end
  local pending = self._state.pending --[[@as table<string, unknown>]]
  if pending == nil then
    error(BattleErrors.invalidState("decision requests require an open batch", {}))
  end
  local counter = self._state.requestCounter --[[@as integer]] + 1
  self._state.requestCounter = counter
  local request = {
    requestId = counter,
    epoch = (pending.batch --[[@as table<string, unknown>]]).epoch,
    controller = spec.controller,
    kind = spec.kind,
    actors = copyValue(spec.actors),
    legalChoices = copyValue(spec.legalChoices),
  }
  local batch = pending.batch --[[@as table<string, unknown>]]
  local requests = batch.requests --[[@as table<integer, table<string, unknown>>]]
  requests[#requests + 1] = request
  return request
end

return BattleContext
