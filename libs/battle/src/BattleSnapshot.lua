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

---@param value unknown value under detachment
---@param active table<table, boolean> tables on the current traversal path
---@return unknown detached plain copy of the value
local function copyPlain(value, active)
  local kind = type(value)
  if kind == "function" or kind == "thread" or kind == "userdata" then
    error(BattleErrors.incompatibleSnapshot("battle snapshots carry plain data only", { kind = kind }))
  end
  if kind ~= "table" then
    return value
  end
  local node = value --[[@as table<unknown, unknown>]]
  if active[node] == true then
    error(BattleErrors.incompatibleSnapshot("battle snapshots must not loop back on themselves", {}))
  end
  active[node] = true
  local out = {}
  for key, item in pairs(node) do
    out[copyPlain(key, active)] = copyPlain(item, active)
  end
  active[node] = nil
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
---@param extensions table<string, unknown>? caller-owned extra fields assembled before validation
---@return table<string, unknown> detached plain interruption capture
function BattleSnapshot.capture(state, extensions)
  assert(type(state) == "table", "capture requires its live battle state")
  if state.version ~= BattleState.VERSION then
    error(BattleErrors.invalidState("capture requires current battle state", {}))
  end
  if extensions ~= nil and type(extensions) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("capture extensions must be records", {}))
  end
  local generator = state.rng
  assert(type(generator) == "table" and type(generator.capture) == "function", "live state carries its generator")
  local effectRecords = {}
  local bag = state.effectBag
  if type(bag) == "table" and type(bag.capture) == "function" then
    effectRecords = bag:capture(bag)
  end
  local active = {}
  local snapshot = {
    version = BattleState.VERSION,
    ruleset = state.ruleset,
    format = state.format,
    rng = copyPlain(generator.capture(generator), active),
    round = state.round,
    batchCounter = state.batchCounter,
    requestCounter = state.requestCounter,
    sequence = state.sequence,
    activationCounter = state.activationCounter,
    sideOrder = copyPlain(state.sideOrder, active),
    sides = copyPlain(state.sides, active),
    participantOrder = copyPlain(state.participantOrder, active),
    participants = copyPlain(state.participants, active),
    combatantOrder = copyPlain(state.combatantOrder, active),
    combatants = copyPlain(state.combatants, active),
    positionOrder = copyPlain(state.positionOrder, active),
    positions = copyPlain(state.positions, active),
    inventories = copyPlain(state.inventories, active),
    escapeAttempts = state.escapeAttempts,
    captureSeq = state.captureSeq,
    captures = copyPlain(state.captures, active),
    ledger = copyPlain(state.ledger, active),
    environment = copyPlain(state.environment, active),
    formatState = copyPlain(state.formatState, active),
    frames = copyPlain(state.frames, active),
    effects = copyPlain(effectRecords, active),
    pending = copyPlain(state.pending, active),
    outbox = copyPlain(state.outbox, active),
    turnStrikes = copyPlain(state.turnStrikes or {}, active),
    turnActed = copyPlain(state.turnActed or {}, active),
    usedMoves = copyPlain(state.usedMoves or {}, active),
    lastHits = copyPlain(state.lastHits or {}, active),
    status = state.status,
    outcome = copyPlain(state.outcome, active),
  }
  if extensions ~= nil then
    for key, value in
      pairs(extensions --[[@as table<string, unknown>]])
    do
      if snapshot[key] ~= nil then
        error(BattleErrors.incompatibleSnapshot("capture extensions must not overwrite base fields", {
          field = tostring(key),
        }))
      end
      snapshot[key] = copyPlain(value, active)
    end
  end
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
  local snapshot = copyPlain(data, {}) --[[@as table<string, unknown>]]
  BattleState.validateSnapshot(snapshot)
  return snapshot
end

return BattleSnapshot
