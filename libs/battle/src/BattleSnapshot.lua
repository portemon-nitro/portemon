-- Exact typed transient battle capture for debug and replay. Capture runs
-- only between atomic operations and copies the live state field by field,
-- translating the running generator object into its plain record; restore
-- validates the whole capture against the frozen definitions before the
-- session rebuilds its live generator. No Lua closure, coroutine, thread,
-- or host service crosses this boundary in either direction. This is not
-- an in-game manual-save feature.

local BattleErrors = require("libs.battle.src.errors")
local BattleState = require("libs.battle.src.BattleState")

---@class BattleSnapshot
local BattleSnapshot = {}

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

---@param state table<string, unknown> live battle state at an atomic boundary
---@return table<string, unknown> detached plain interruption capture
function BattleSnapshot.capture(state)
  assert(type(state) == "table", "capture requires its live battle state")
  if state.version ~= BattleState.VERSION then
    error(BattleErrors.invalidState("capture requires current battle state", {}))
  end
  local generator = state.rng
  assert(type(generator) == "table" and type(generator.capture) == "function", "live state carries its generator")
  local snapshot = {
    version = BattleState.VERSION,
    ruleset = state.ruleset,
    format = state.format,
    rng = generator.capture(generator),
    round = state.round,
    maxRounds = state.maxRounds,
    batchCounter = state.batchCounter,
    requestCounter = state.requestCounter,
    sequence = state.sequence,
    activationCounter = state.activationCounter,
    sideOrder = copyValue(state.sideOrder),
    sides = copyValue(state.sides),
    participantOrder = copyValue(state.participantOrder),
    participants = copyValue(state.participants),
    combatantOrder = copyValue(state.combatantOrder),
    combatants = copyValue(state.combatants),
    positionOrder = copyValue(state.positionOrder),
    positions = copyValue(state.positions),
    inventories = copyValue(state.inventories),
    environment = copyValue(state.environment),
    formatState = copyValue(state.formatState),
    frames = copyValue(state.frames),
    pending = copyValue(state.pending),
    outbox = copyValue(state.outbox),
    status = state.status,
    outcome = copyValue(state.outcome),
  }
  local owned = snapshot --[[@as table<string, unknown>]]
  BattleState.validateSnapshot(owned)
  return owned
end

---@param data unknown interruption capture under validation
---@return table<string, unknown> live-ready battle state (generator still a plain record)
function BattleSnapshot.restore(data)
  if type(data) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("battle snapshots must be records", {}))
  end
  local snapshot = copyValue(data) --[[@as table<string, unknown>]]
  BattleState.validateSnapshot(snapshot)
  return snapshot
end

return BattleSnapshot
