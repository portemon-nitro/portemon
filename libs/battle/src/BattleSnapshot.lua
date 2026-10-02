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

---@param value unknown interruption data under inspection
---@param active table<table, boolean> tables on the current traversal path
local function checkPlain(value, active)
  local kind = type(value)
  if kind == "function" or kind == "thread" or kind == "userdata" then
    error(BattleErrors.incompatibleSnapshot("battle snapshots carry plain data only", { kind = kind }))
  end
  if kind ~= "table" then
    return
  end
  local node = value --[[@as table<unknown, unknown>]]
  if active[node] == true then
    error(BattleErrors.incompatibleSnapshot("battle snapshots must not loop back on themselves", {}))
  end
  active[node] = true
  for key, item in pairs(node) do
    checkPlain(key, active)
    checkPlain(item, active)
  end
  active[node] = nil
end

--- Validates an interruption capture without publishing anything: the
--- record must be plain data (no functions, coroutines, userdata, or
--- cycles) and must carry the current snapshot shape. Throws on any
--- foreign or live state; returns true for a well-formed capture.
---@param data unknown interruption capture under validation
---@return boolean true when the capture is well-formed plain snapshot data
function BattleSnapshot.validate(data)
  if type(data) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("battle snapshots must be records", {}))
  end
  checkPlain(data, {})
  BattleState.validateSnapshot(data --[[@as table<string, unknown>]])
  return true
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
    escapeAttempts = state.escapeAttempts,
    captureSeq = state.captureSeq,
    captures = copyValue(state.captures),
    ledger = copyValue(state.ledger),
    environment = copyValue(state.environment),
    formatState = copyValue(state.formatState),
    frames = copyValue(state.frames),
    pending = copyValue(state.pending),
    outbox = copyValue(state.outbox),
    status = state.status,
    outcome = copyValue(state.outcome),
  }
  local owned = snapshot --[[@as table<string, unknown>]]
  BattleSnapshot.validate(owned)
  return owned
end

---@param data unknown interruption capture under validation
---@return table<string, unknown> live-ready battle state (generator still a plain record)
function BattleSnapshot.restore(data)
  BattleSnapshot.validate(data)
  local snapshot = copyValue(data) --[[@as table<string, unknown>]]
  BattleState.validateSnapshot(snapshot)
  return snapshot
end

return BattleSnapshot
