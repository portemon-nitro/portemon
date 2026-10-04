-- Private battle data and reference invariants. The state table is owned
-- here and mutated only through this module and the validated mechanics
-- surface; external callers receive detached copies. A combatant owns one
-- canonical persistent-mon copy plus battle-local health and activation
-- bookkeeping: health persists across entries (roster-local) while entry
-- tokens and stat stages reset per entry (activation-local),
-- so a replacement can never inherit a stale action, effect, or modifier
-- through a reused slot integer.
-- The live random generator object is held outside the serializable shape;
-- interruption captures carry its plain record instead.

local BattleErrors = require("libs.battle.src.errors")
local EffectBag = require("libs.battle.src.EffectBag")
local StatStages = require("libs.battle.src.gen4.StatStages")
local Lcrng = require("libs.mons.src.gen4.Lcrng")

---@class BattleState
local BattleState = {}

-- Interruption captures carrying an older version reject as incompatible:
-- pre-release battle snapshots never migrate, they fail before publication.
-- Version 6 carries the knockout-reward continuation (reward children,
-- per-opponent participation records, and evolution eligibility) alongside
-- the version-2 replacement lifecycle, the session-owned action ledger (escape
-- attempts, capture identities, capture records, and item consumption),
-- and the live battle-local effect records owned by the effect bag.
BattleState.VERSION = 6

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

-- Battle-local stat stages in native stage law. Every combatant starts
-- each activation at all-zero stages; stage mutation clamps through the
-- stage owner, so this module only ever writes zeros and validates the
-- native bounds on restore.
local STAGE_KEYS = { "attack", "defense", "speed", "specialAttack", "specialDefense", "accuracy", "evasion" }

---@return table<string, integer> fresh all-zero stage record
local function zeroStages()
  return {
    attack = 0,
    defense = 0,
    speed = 0,
    specialAttack = 0,
    specialDefense = 0,
    accuracy = 0,
    evasion = 0,
  }
end

---@param hp unknown
---@param combatantId integer
---@return integer
local function checkEntryHp(hp, combatantId)
  if type(hp) ~= "number" or hp ~= hp or hp % 1 ~= 0 or hp < 0 then
    error(BattleErrors.invalidState("combatant entry health must be a non-negative integer", {
      combatant = combatantId,
    }))
  end
  return hp --[[@as integer]]
end

---@param validated table<string, unknown> detached scenario copy from scenario validation
---@return table<string, unknown> live battle state
function BattleState.create(validated)
  assert(type(validated) == "table", "battle state requires its validated scenario")
  local state = {
    version = BattleState.VERSION,
    ruleset = validated.ruleset,
    format = validated.format,
    rng = Lcrng.new(validated
      .random --[[@as table<string, unknown>]]
      .seed --[[@as integer]]),
    round = 1,
    batchCounter = 0,
    requestCounter = 0,
    sequence = 0,
    activationCounter = 0,
    sideOrder = {},
    sides = {},
    participantOrder = {},
    participants = {},
    combatantOrder = {},
    combatants = {},
    positionOrder = {},
    positions = {},
    inventories = {},
    escapeAttempts = 0,
    captureSeq = 0,
    captures = {},
    ledger = {},
    environment = copyValue(validated.environment),
    formatState = copyValue(validated.formatState),
    frames = {},
    pending = nil,
    outbox = {},
    status = "running",
    outcome = nil,
    -- The live scoped-instance owner for battle-local effects. Like the
    -- running generator, the live bag object stays out of the
    -- serializable shape: interruption captures carry its plain records
    -- instead, and restoration rebuilds the owner from those records.
    effectBag = EffectBag.new(),
  }
  local owned = state --[[@as table<string, unknown>]]
  local sideOrder = owned.sideOrder --[[@as integer[] ]]
  local sides = owned.sides --[[@as table<integer, table<string, unknown>> ]]
  local participantOrder = owned.participantOrder --[[@as integer[] ]]
  local participants = owned.participants --[[@as table<integer, table<string, unknown>> ]]
  local combatantOrder = owned.combatantOrder --[[@as integer[] ]]
  local combatants = owned.combatants --[[@as table<integer, table<string, unknown>> ]]
  local positionOrder = owned.positionOrder --[[@as integer[] ]]
  local positions = owned.positions --[[@as table<integer, table<string, unknown>> ]]
  local inventories = owned.inventories --[[@as table<string, table<string, unknown>> ]]
  for _, entry in
    ipairs(validated.sides --[[@as table<integer, unknown>]])
  do
    local side = entry --[[@as table<string, unknown>]]
    local id = side.id --[[@as integer]]
    sideOrder[#sideOrder + 1] = id
    sides[id] = { id = id, participants = copyValue(side.participants) }
  end
  for _, entry in
    ipairs(validated.participants --[[@as table<integer, unknown>]])
  do
    local participant = entry --[[@as table<string, unknown>]]
    local id = participant.id --[[@as integer]]
    participantOrder[#participantOrder + 1] = id
    local roster = {}
    for _, seed in
      ipairs(participant.roster --[[@as table<integer, unknown>]])
    do
      local seedRecord = seed --[[@as table<string, unknown>]]
      local combatantId = seedRecord.id --[[@as integer]]
      roster[#roster + 1] = combatantId
      combatantOrder[#combatantOrder + 1] = combatantId
      local mon = seedRecord.mon --[[@as table<string, unknown>]]
      local condition = mon.condition --[[@as table<string, unknown>]]
      local hp = checkEntryHp(condition.currentHp, combatantId)
      combatants[combatantId] = {
        id = combatantId,
        participant = id,
        mon = copyValue(mon),
        source = copyValue(seedRecord.source),
        hp = hp,
        entryHp = hp,
        active = nil,
        stages = zeroStages(),
        materialized = {},
      }
    end
    participants[id] = {
      id = id,
      side = participant.side,
      controller = participant.controller,
      inventoryId = participant.inventoryId,
      roster = roster,
      context = copyValue(participant.context),
    }
  end
  for _, entry in
    ipairs(validated.positions --[[@as table<integer, unknown>]])
  do
    local position = entry --[[@as table<string, unknown>]]
    local id = position.id --[[@as integer]]
    positionOrder[#positionOrder + 1] = id
    positions[id] = {
      id = id,
      side = position.side,
      eligible = copyValue(position.eligibleParticipants),
      occupant = nil,
      activation = nil,
    }
  end
  if validated.inventories ~= nil then
    for _, entry in
      ipairs(validated.inventories --[[@as table<integer, unknown>]])
    do
      local inventory = entry --[[@as table<string, unknown>]]
      local id = inventory.id --[[@as string]]
      inventories[id] = {
        id = id,
        owners = copyValue(inventory.owners),
        quantities = copyValue(inventory.quantities),
      }
    end
  end
  for _, entry in
    ipairs(validated.positions --[[@as table<integer, unknown>]])
  do
    local position = entry --[[@as table<string, unknown>]]
    if position.occupant ~= nil then
      BattleState.enter(owned, position.occupant --[[@as integer]], position.id --[[@as integer]])
    end
  end
  return owned
end

---@param state table<string, unknown> live battle state
---@param id integer
---@return table<string, unknown>
function BattleState.combatant(state, id)
  local found = (state.combatants --[[@as table<integer, table<string, unknown>>]])[id]
  if found == nil then
    error(BattleErrors.invalidState("unknown combatant", { combatant = id }))
  end
  return found
end

---@param state table<string, unknown> live battle state
---@param id integer
---@return table<string, unknown>
function BattleState.position(state, id)
  local found = (state.positions --[[@as table<integer, table<string, unknown>>]])[id]
  if found == nil then
    error(BattleErrors.invalidState("unknown position", { position = id }))
  end
  return found
end

---@param state table<string, unknown> live battle state
---@param id integer
---@return table<string, unknown>
function BattleState.participant(state, id)
  local found = (state.participants --[[@as table<integer, table<string, unknown>>]])[id]
  if found == nil then
    error(BattleErrors.invalidState("unknown participant", { participant = id }))
  end
  return found
end

---@param state table<string, unknown> live battle state
---@param combatantId integer
---@param positionId integer
---@return integer the fresh activation token for this entry
function BattleState.enter(state, combatantId, positionId)
  local combatant = BattleState.combatant(state, combatantId)
  local position = BattleState.position(state, positionId)
  if combatant.active ~= nil then
    error(BattleErrors.invalidState("entering combatants must start benched", { combatant = combatantId }))
  end
  if position.occupant ~= nil then
    error(BattleErrors.invalidState("entries require a vacant position", { position = positionId }))
  end
  local owner = BattleState.participant(state, combatant.participant --[[@as integer]])
  if owner.side ~= position.side then
    error(BattleErrors.invalidState("entries must stay on the owner side", {
      combatant = combatantId,
      position = positionId,
    }))
  end
  local allowed = false
  for _, pid in
    ipairs(position.eligible --[[@as integer[] ]])
  do
    if pid == owner.id then
      allowed = true
    end
  end
  if not allowed then
    error(BattleErrors.invalidState("entries require an eligible participant", {
      combatant = combatantId,
      position = positionId,
    }))
  end
  local counter = state.activationCounter --[[@as integer]] + 1
  state.activationCounter = counter
  -- Health is roster-local: entering seats the combatant with its
  -- current battle health and original baseline untouched, so damage
  -- taken before leaving is still there when it returns. Only the
  -- activation-local entry token and stages reset here.
  combatant.active = { position = positionId, activation = counter }
  combatant.stages = zeroStages()
  position.occupant = combatantId
  position.activation = counter
  return counter
end

---@param state table<string, unknown> live battle state
---@param positionId integer
---@return integer the departing combatant identity
function BattleState.leave(state, positionId)
  local position = BattleState.position(state, positionId)
  if position.occupant == nil then
    error(BattleErrors.invalidState("departures require an occupied position", { position = positionId }))
  end
  local combatantId = position.occupant --[[@as integer]]
  local combatant = BattleState.combatant(state, combatantId)
  combatant.active = nil
  position.occupant = nil
  position.activation = nil
  return combatantId
end

---@param data unknown
---@param what string
---@return table<integer, unknown>
local function checkSnapshotSequence(data, what)
  if type(data) ~= "table" then
    error(BattleErrors.incompatibleSnapshot(what .. " must be an ordered array", {}))
  end
  local array = data --[[@as table<integer, unknown>]]
  for index = 1, #array do
    if array[index] == nil then
      error(BattleErrors.incompatibleSnapshot(what .. " must not skip positions", { index = index }))
    end
  end
  return array
end

---@param snapshot table<string, unknown> interruption capture under validation
function BattleState.validateSnapshot(snapshot)
  if type(snapshot) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("battle snapshots must be records", {}))
  end
  if snapshot.version ~= BattleState.VERSION then
    error(BattleErrors.incompatibleSnapshot("battle snapshots must carry the current version", {
      version = tostring(snapshot.version),
    }))
  end
  if type(snapshot.ruleset) ~= "string" or snapshot.ruleset == "" then
    error(BattleErrors.incompatibleSnapshot("battle snapshots must name their ruleset", {}))
  end
  if type(snapshot.format) ~= "string" or snapshot.format == "" then
    error(BattleErrors.incompatibleSnapshot("battle snapshots must name their format", {}))
  end
  local rngOk = pcall(Lcrng.validate, snapshot.rng)
  if not rngOk then
    error(BattleErrors.incompatibleSnapshot("battle snapshots must carry a valid generator record", {}))
  end
  for _, field in ipairs({ "round", "batchCounter", "requestCounter", "sequence", "activationCounter" }) do
    local value = snapshot[field]
    if type(value) ~= "number" or value ~= value or value % 1 ~= 0 or value < 0 then
      error(BattleErrors.incompatibleSnapshot("battle snapshots must carry integral counters", { field = field }))
    end
  end
  if
    snapshot.round --[[@as integer]]
    < 1
  then
    error(BattleErrors.incompatibleSnapshot("battle snapshots must carry a positive round", {}))
  end
  local sideOrder = checkSnapshotSequence(snapshot.sideOrder, "snapshot sides")
  local participantOrder = checkSnapshotSequence(snapshot.participantOrder, "snapshot participants")
  local combatantOrder = checkSnapshotSequence(snapshot.combatantOrder, "snapshot combatants")
  local positionOrder = checkSnapshotSequence(snapshot.positionOrder, "snapshot positions")
  if type(snapshot.sides) ~= "table" or type(snapshot.participants) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("battle snapshots must carry alliance maps", {}))
  end
  if type(snapshot.combatants) ~= "table" or type(snapshot.positions) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("battle snapshots must carry roster maps", {}))
  end
  local combatants = snapshot.combatants --[[@as table<integer, table<string, unknown>>]]
  local positions = snapshot.positions --[[@as table<integer, table<string, unknown>>]]
  local seenCombatants = {}
  for _, id in ipairs(combatantOrder) do
    assert(type(id) == "number" and id % 1 == 0, "snapshot combatant order carries identities")
    local combatantId = id --[[@as integer]]
    if seenCombatants[combatantId] ~= nil then
      error(BattleErrors.incompatibleSnapshot("snapshot combatant order must list identities once", {}))
    end
    seenCombatants[combatantId] = true
    local combatant = combatants[combatantId]
    if type(combatant) ~= "table" then
      error(BattleErrors.incompatibleSnapshot("snapshot combatants must be records", { combatant = combatantId }))
    end
    checkEntryHp(combatant.hp, combatantId)
    checkEntryHp(combatant.entryHp, combatantId)
    local stages = combatant.stages
    if type(stages) ~= "table" then
      error(BattleErrors.incompatibleSnapshot("snapshot combatants must carry their stat stages", {
        combatant = combatantId,
      }))
    end
    for _, key in ipairs(STAGE_KEYS) do
      local stage = (stages --[[@as table<string, unknown>]])[key]
      if type(stage) ~= "number" or stage % 1 ~= 0 or stage < StatStages.MIN or stage > StatStages.MAX then
        error(BattleErrors.incompatibleSnapshot("snapshot stages stay clamped integer stages", {
          combatant = combatantId,
        }))
      end
    end
    if combatant.active ~= nil then
      if type(combatant.active) ~= "table" then
        error(BattleErrors.incompatibleSnapshot("snapshot entries must be records", {}))
      end
      local active = combatant.active --[[@as table<string, unknown>]]
      if type(active.position) ~= "number" or type(active.activation) ~= "number" then
        error(BattleErrors.incompatibleSnapshot("snapshot entries must name position and token", {}))
      end
    end
    if type(combatant.materialized) ~= "table" then
      error(BattleErrors.incompatibleSnapshot("snapshot combatants must carry materialized state", {}))
    end
  end
  for _, id in ipairs(positionOrder) do
    local position = positions[id]
    if type(position) ~= "table" then
      error(BattleErrors.incompatibleSnapshot("snapshot positions must be records", {}))
    end
    local record = position --[[@as table<string, unknown>]]
    if record.occupant ~= nil then
      if
        seenCombatants[
          record.occupant --[[@as integer]]
        ] == nil
      then
        error(BattleErrors.incompatibleSnapshot("snapshot occupants must reference roster combatants", {}))
      end
      local combatant = combatants[
        record.occupant --[[@as integer]]
      ]
      local active = combatant.active --[[@as table<string, unknown>]]
      if active == nil or active.position ~= id or active.activation ~= record.activation then
        error(BattleErrors.incompatibleSnapshot("snapshot occupancy must match entry tokens", {}))
      end
    elseif record.activation ~= nil then
      error(BattleErrors.incompatibleSnapshot("vacant snapshot positions carry no token", {}))
    end
  end
  if snapshot.pending ~= nil then
    if type(snapshot.pending) ~= "table" then
      error(BattleErrors.incompatibleSnapshot("snapshot pending batches must be records", {}))
    end
    local pending = snapshot.pending --[[@as table<string, unknown>]]
    local batch = pending.batch
    if type(batch) ~= "table" then
      error(BattleErrors.incompatibleSnapshot("snapshot pending batches must carry their batch", {}))
    end
    checkSnapshotSequence((batch --[[@as table<string, unknown>]]).requests, "snapshot requests")
    if type(pending.submitted) ~= "table" or type(pending.reserved) ~= "table" then
      error(BattleErrors.incompatibleSnapshot("snapshot pending batches must carry replies", {}))
    end
  end
  checkSnapshotSequence(snapshot.frames, "snapshot continuation frames")
  for _, entry in
    ipairs(snapshot.frames --[[@as table<integer, unknown>]])
  do
    if type(entry) ~= "table" then
      error(BattleErrors.incompatibleSnapshot("continuation frames must be records", {}))
    end
    local frame = entry --[[@as table<string, unknown>]]
    if type(frame.kind) ~= "string" or frame.kind == "" then
      error(BattleErrors.incompatibleSnapshot("continuation frames must name their kind", {}))
    end
    if type(frame.version) ~= "number" or frame.version % 1 ~= 0 or frame.version < 1 then
      error(BattleErrors.incompatibleSnapshot("continuation frames must carry a positive version", {}))
    end
    if type(frame.cursor) ~= "string" or frame.cursor == "" then
      error(BattleErrors.incompatibleSnapshot("continuation frames must name their cursor", {}))
    end
    if type(frame.state) ~= "table" then
      error(BattleErrors.incompatibleSnapshot("continuation frames must carry plain state", {}))
    end
  end
  if type(snapshot.inventories) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("battle snapshots must carry inventories", {}))
  end
  if
    type(snapshot.escapeAttempts) ~= "number"
    or snapshot.escapeAttempts --[[@as integer]]
      % 1 ~= 0
    or snapshot.escapeAttempts --[[@as integer]]
      < 0
  then
    error(BattleErrors.incompatibleSnapshot("battle snapshots must count their escape attempts", {}))
  end
  if
    type(snapshot.captureSeq) ~= "number"
    or snapshot.captureSeq --[[@as integer]]
      % 1 ~= 0
    or snapshot.captureSeq --[[@as integer]]
      < 0
  then
    error(BattleErrors.incompatibleSnapshot("battle snapshots must count their capture identities", {}))
  end
  if type(snapshot.captures) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("battle snapshots must carry their capture ledger", {}))
  end
  checkSnapshotSequence(snapshot.captures --[[@as table<integer, unknown>]], "snapshot captures")
  for _, entry in
    ipairs(snapshot.captures --[[@as table<integer, unknown>]])
  do
    if type(entry) ~= "table" then
      error(BattleErrors.incompatibleSnapshot("snapshot captures must be records", {}))
    end
  end
  if type(snapshot.ledger) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("battle snapshots must carry their consumption ledger", {}))
  end
  checkSnapshotSequence(snapshot.ledger --[[@as table<integer, unknown>]], "snapshot consumption")
  -- Turn interaction ledgers travel with the capture: revenge damage and
  -- acted marks reset every turn while distinct-move history accumulates
  -- per entry, so replayed and restored sessions keep the same strike law.
  for _, field in ipairs({ "turnStrikes", "turnActed", "usedMoves" }) do
    if type(snapshot[field]) ~= "table" then
      error(BattleErrors.incompatibleSnapshot("battle snapshots must carry their turn ledgers", { field = field }))
    end
  end
  if type(snapshot.effects) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("battle snapshots must carry their live effect records", {}))
  end
  -- Rebuilding the owner validates every record shape, so malformed
  -- effect state rejects before restore instead of publishing half-live
  -- instances. The rebuilt owner is discarded; restoration rebuilds its
  -- own from the same records.
  EffectBag.new(snapshot.effects --[[@as table<integer, unknown>]])
  if type(snapshot.environment) ~= "table" or type(snapshot.formatState) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("battle snapshots must carry environment records", {}))
  end
  if snapshot.status ~= "running" and snapshot.status ~= "waiting" and snapshot.status ~= "ended" then
    error(BattleErrors.incompatibleSnapshot("battle snapshots must carry a known status", {}))
  end
  if snapshot.status == "ended" and type(snapshot.outcome) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("ended snapshots must carry their outcome", {}))
  end
  if type(snapshot.outbox) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("battle snapshots must carry their event outbox", {}))
  end
  local sides = snapshot.sides --[[@as table<integer, table<string, unknown>>]]
  for _, id in ipairs(sideOrder) do
    if sides[id] == nil then
      error(BattleErrors.incompatibleSnapshot("snapshot side order must reference side maps", {}))
    end
  end
  local participants = snapshot.participants --[[@as table<integer, table<string, unknown>>]]
  for _, id in ipairs(participantOrder) do
    if participants[id] == nil then
      error(BattleErrors.incompatibleSnapshot("snapshot participant order must reference participant maps", {}))
    end
  end
end

return BattleState
