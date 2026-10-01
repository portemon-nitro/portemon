-- Validated deterministic battle membership changes. Every join, whether
-- the initial assembly of a large lineup or a mid-battle reinforcement,
-- stages through preparation and publishes through application: staging
-- validates roster, participant, position, and inventory ownership against
-- content and format policy without touching live state, while application
-- runs exactly once through the session owner at a declared settlement
-- boundary. Combatant and position identities are never reused, entry
-- tokens grow monotonically, and an outstanding decision batch never stays
-- silently valid once the topology changes: applying a join issues a new
-- batch epoch so stale intents cannot retarget a replacement by accident.
-- Joined combatants wait for the next batch; the newcomer gets no action
-- in the batch that was open when the join published.

local BattleErrors = require("libs.battle.src.errors")

---@class Topology
local Topology = {}

Topology.VERSION = 1

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

---@param value unknown
---@return boolean
local function isPositiveInt(value)
  return type(value) == "number"
    and value == value
    and math.abs(value) ~= math.huge
    and value % 1 == 0
    and value >= 1
    and value <= 9007199254740991
end

---@param target unknown join target under inspection
---@return boolean true when the target is a live session
local function isSessionTarget(target)
  return type(target) == "table" and type((target --[[@as table<string, unknown>]]).capture) == "function"
end

---@class TopologyIndex
---@field combatants table<integer, boolean> roster identities already taken
---@field participants table<integer, table<string, unknown>> participant records by identity
---@field positions table<integer, table<string, unknown>> position records by identity
---@field sides table<integer, boolean> declared side identities
---@field inventories table<string, boolean> declared inventory handles
---@field format string? battle format when the target carries one
---@field ruleset string? content ruleset when the target carries one
---@field baseCounter integer batch counter the staging is bound to
---@field settled boolean true when the target rests at a joinable boundary

---@return TopologyIndex an empty membership index
local function newIndex()
  return {
    combatants = {},
    participants = {},
    positions = {},
    sides = {},
    inventories = {},
    format = nil,
    ruleset = nil,
    baseCounter = 0,
    settled = true,
  }
end

---@param index TopologyIndex index under construction
---@param record table<string, unknown> scenario-form sides/participants/positions
local function indexScenarioArrays(index, record)
  for _, entry in
    ipairs(record.sides --[[@as table<integer, unknown>]])
  do
    local side = entry --[[@as table<string, unknown>]]
    index.sides[
      side.id --[[@as integer]]
    ] = true
  end
  for _, entry in
    ipairs(record.participants --[[@as table<integer, unknown>]])
  do
    local participant = entry --[[@as table<string, unknown>]]
    local id = participant.id --[[@as integer]]
    index.participants[id] = participant
    for _, seed in
      ipairs(participant.roster --[[@as table<integer, unknown>]])
    do
      index.combatants[
        (seed --[[@as table<string, unknown>]]).id --[[@as integer]]
      ] = true
    end
  end
  for _, entry in
    ipairs(record.positions --[[@as table<integer, unknown>]])
  do
    local position = entry --[[@as table<string, unknown>]]
    index.positions[
      position.id --[[@as integer]]
    ] = position
  end
  if type(record.inventories) == "table" then
    for _, entry in
      ipairs(record.inventories --[[@as table<integer, unknown>]])
    do
      index.inventories[
        (entry --[[@as table<string, unknown>]]).id --[[@as string]]
      ] = true
    end
  end
  if type(record.format) == "string" then
    index.format = record.format --[[@as string]]
  end
  if type(record.ruleset) == "string" then
    index.ruleset = record.ruleset --[[@as string]]
  end
end

---@param index TopologyIndex index under construction
---@param snapshot table<string, unknown> plain interruption capture from the session owner
local function indexSnapshotMaps(index, snapshot)
  for _, id in
    ipairs(snapshot.sideOrder --[[@as table<integer, unknown>]])
  do
    index.sides[
      id --[[@as integer]]
    ] = true
  end
  local participants = snapshot.participants --[[@as table<integer, table<string, unknown>>]]
  for _, id in
    ipairs(snapshot.participantOrder --[[@as table<integer, unknown>]])
  do
    local participantId = id --[[@as integer]]
    index.participants[participantId] = participants[participantId]
  end
  local combatants = snapshot.combatants --[[@as table<integer, table<string, unknown>>]]
  for _, id in
    ipairs(snapshot.combatantOrder --[[@as table<integer, unknown>]])
  do
    index.combatants[
      id --[[@as integer]]
    ] = true
    assert(combatants[
      id --[[@as integer]]
    ] ~= nil, "snapshot order references its combatant map")
  end
  local positions = snapshot.positions --[[@as table<integer, table<string, unknown>>]]
  for _, id in
    ipairs(snapshot.positionOrder --[[@as table<integer, unknown>]])
  do
    index.positions[
      id --[[@as integer]]
    ] = positions[
      id --[[@as integer]]
    ]
  end
  local inventories = snapshot.inventories --[[@as table<string, table<string, unknown>>]]
  for id in pairs(inventories) do
    index.inventories[
      id --[[@as string]]
    ] = true
  end
  index.format = snapshot.format --[[@as string]]
  index.ruleset = snapshot.ruleset --[[@as string]]
  index.baseCounter = snapshot.batchCounter --[[@as integer]]
  index.settled = snapshot.status == "waiting" or snapshot.status == "ended"
end

---@param target unknown join target, either a live session or a detached scenario record
---@return TopologyIndex membership index describing the target
---@return boolean true when the target is a live session
local function indexTarget(target)
  if type(target) ~= "table" then
    error(BattleErrors.input("joins target a session or a scenario record", {}))
  end
  if isSessionTarget(target) then
    local session = target --[[@as table<string, unknown>]]
    local capture = session.capture --[[@as fun(self: unknown): table<string, unknown>]]
    local snapshot = capture(session)
    if type(snapshot) ~= "table" then
      error(BattleErrors.input("session joins capture plain state first", {}))
    end
    local index = newIndex()
    indexSnapshotMaps(index, snapshot)
    return index, true
  end
  local record = target --[[@as table<string, unknown>]]
  if type(record.sides) ~= "table" or type(record.participants) ~= "table" or type(record.positions) ~= "table" then
    error(BattleErrors.input("scenario joins target a scenario record", {}))
  end
  local index = newIndex()
  indexScenarioArrays(index, record)
  return index, false
end

---@param request unknown join request under validation
---@return table<string, unknown> the request as a record
local function checkRequest(request)
  if type(request) ~= "table" then
    error(BattleErrors.input("joins carry a request record", {}))
  end
  local record = request --[[@as table<string, unknown>]]
  if type(record.reason) ~= "string" or record.reason == "" then
    error(BattleErrors.input("joins must name their reason", {}))
  end
  if type(record.settlementBoundary) ~= "string" or record.settlementBoundary == "" then
    error(BattleErrors.input("joins must declare their settlement boundary", {}))
  end
  for _, field in ipairs({ "combatants", "positions" }) do
    if record[field] == nil then
      record[field] = {}
    end
    if type(record[field]) ~= "table" then
      error(BattleErrors.input("joins carry " .. field .. " as an array", {}))
    end
  end
  if record.inventories == nil then
    record.inventories = {}
  end
  if type(record.inventories) ~= "table" then
    error(BattleErrors.input("joins carry inventories as an array", {}))
  end
  return record
end

---@param mon unknown persistent mon record under validation
---@param combatantId integer roster identity reporting the violation
local function checkJoinMon(mon, combatantId)
  if type(mon) ~= "table" then
    error(BattleErrors.input("joined combatants must carry their mon record", { combatant = combatantId }))
  end
  local condition = (mon --[[@as table<string, unknown>]]).condition
  if type(condition) ~= "table" then
    error(BattleErrors.input("joined combatants must carry their condition", { combatant = combatantId }))
  end
  local hp = (condition --[[@as table<string, unknown>]]).currentHp
  if type(hp) ~= "number" or hp ~= hp or math.abs(hp) == math.huge or hp % 1 ~= 0 or hp < 0 then
    error(BattleErrors.input("joined entry health must be a non-negative integer", { combatant = combatantId }))
  end
end

--- Validates roster, participant, position, and inventory ownership for a
--- join without touching live state. New combatant and position identities
--- must never collide with taken ones; an existing position joined into
--- must be vacant; every joined position must stand on the owning side
--- and list its owner among the eligible participants.
---@param target unknown join target, either a live session or a detached scenario record
---@param request JoinRequest join request under validation
---@return boolean true when the join stages cleanly
function Topology.validateOwnership(target, request)
  local record = checkRequest(request)
  local index, _ = indexTarget(target)
  local newcomers = record.combatants --[[@as table<integer, unknown>]]
  local seats = record.positions --[[@as table<integer, unknown>]]
  if #newcomers == 0 and #seats > 0 then
    error(BattleErrors.input("joins stage seats alongside their combatants", {}))
  end
  local joining = #newcomers > 0 or #seats > 0
  local ownerId = nil
  local ownerSide = nil
  if joining and #newcomers > 0 then
    local participant = record.participant
    if type(participant) ~= "table" then
      error(BattleErrors.input("joined combatants must name their participant", {}))
    end
    local owner = participant --[[@as table<string, unknown>]]
    if not isPositiveInt(owner.id) then
      error(BattleErrors.input("joined participants carry positive identities", {}))
    end
    ownerId = owner.id --[[@as integer]]
    local known = index.participants[ownerId]
    if known == nil then
      if type(owner.side) ~= "number" then
        error(BattleErrors.input("new join participants must declare their side", { participant = ownerId }))
      end
      if
        index.sides[
          owner.side --[[@as integer]]
        ] == nil
      then
        error(BattleErrors.input("new join participants must join a declared side", { participant = ownerId }))
      end
      if type(owner.controller) ~= "string" or owner.controller == "" then
        error(BattleErrors.input("new join participants must declare their controller", { participant = ownerId }))
      end
      if type(owner.context) ~= "table" then
        error(BattleErrors.input("new join participants must carry their context record", { participant = ownerId }))
      end
      if owner.roster ~= nil then
        if type(owner.roster) ~= "table" then
          error(BattleErrors.input("new join participants carry rosters as arrays", { participant = ownerId }))
        end
        local listed = {}
        for _, seed in
          ipairs(owner.roster --[[@as table<integer, unknown>]])
        do
          local seedRecord = seed --[[@as table<string, unknown>]]
          listed[
            seedRecord.id --[[@as integer]]
          ] = true
        end
        for _, entry in ipairs(newcomers) do
          local combatant = entry --[[@as table<string, unknown>]]
          if
            listed[
              combatant.id --[[@as integer]]
            ] == nil
          then
            error(BattleErrors.input("new join rosters must list every joined combatant", { participant = ownerId }))
          end
        end
      end
      ownerSide = owner.side --[[@as integer]]
    else
      ownerSide = (known --[[@as table<string, unknown>]]).side --[[@as integer]]
    end
    local inventoryId = (owner --[[@as table<string, unknown>]]).inventoryId
    if
      inventoryId ~= nil and index.inventories[
        inventoryId --[[@as string]]
      ] == nil
    then
      local supplied = false
      for _, entry in
        ipairs(record.inventories --[[@as table<integer, unknown>]])
      do
        if
          (entry --[[@as table<string, unknown>]]).id == inventoryId
        then
          supplied = true
        end
      end
      if not supplied then
        error(BattleErrors.input("joined participants cannot draw on unknown inventories", {
          inventory = tostring(inventoryId),
        }))
      end
    end
  end
  local seenCombatants = {}
  for _, entry in ipairs(newcomers) do
    if type(entry) ~= "table" then
      error(BattleErrors.input("joined combatants must be records", {}))
    end
    local combatant = entry --[[@as table<string, unknown>]]
    if not isPositiveInt(combatant.id) then
      error(BattleErrors.input("joined combatant identities stay positive", {}))
    end
    local id = combatant.id --[[@as integer]]
    if index.combatants[id] ~= nil then
      error(BattleErrors.input("combatant identities are never reused", { combatant = id }))
    end
    if seenCombatants[id] ~= nil then
      error(BattleErrors.input("joined combatants must not repeat identities", { combatant = id }))
    end
    seenCombatants[id] = true
    checkJoinMon(combatant.mon, id)
  end
  local seenPositions = {}
  for _, entry in ipairs(seats) do
    if type(entry) ~= "table" then
      error(BattleErrors.input("joined positions must be records", {}))
    end
    local position = entry --[[@as table<string, unknown>]]
    if not isPositiveInt(position.id) then
      error(BattleErrors.input("joined position identities stay positive", {}))
    end
    local id = position.id --[[@as integer]]
    if seenPositions[id] ~= nil then
      error(BattleErrors.input("joined positions must not repeat identities", { position = id }))
    end
    seenPositions[id] = true
    local known = index.positions[id]
    if known ~= nil then
      if
        (known --[[@as table<string, unknown>]]).occupant ~= nil
      then
        error(BattleErrors.input("joins require a vacant position", { position = id }))
      end
    else
      if ownerId == nil then
        error(BattleErrors.input("new join positions require joined combatants", { position = id }))
      end
      if position.side ~= ownerSide then
        error(BattleErrors.input("joined positions must stand on the owner side", { position = id }))
      end
    end
    local effective = known or position
    if
      (effective --[[@as table<string, unknown>]]).side ~= ownerSide
    then
      error(BattleErrors.input("joined positions must stand on the owner side", { position = id }))
    end
    local eligible = (effective --[[@as table<string, unknown>]]).eligibleParticipants
      or (effective --[[@as table<string, unknown>]]).eligible
    if type(eligible) ~= "table" then
      error(BattleErrors.input("joined positions must name eligible participants", { position = id }))
    end
    local allowed = false
    for _, pid in
      ipairs(eligible --[[@as table<integer, unknown>]])
    do
      if pid == ownerId then
        allowed = true
      end
    end
    if not allowed then
      error(
        BattleErrors.input("joined occupants must belong to a participant eligible for the slot", { position = id })
      )
    end
    if position.occupant ~= nil then
      if
        seenCombatants[
          position.occupant --[[@as integer]]
        ] == nil
      then
        error(BattleErrors.input("joined positions seat only joined combatants", {
          position = id,
          combatant = position.occupant,
        }))
      end
    end
  end
  for _, entry in
    ipairs(record.inventories --[[@as table<integer, unknown>]])
  do
    if type(entry) ~= "table" then
      error(BattleErrors.input("joined inventories must be records", {}))
    end
    local inventory = entry --[[@as table<string, unknown>]]
    if type(inventory.id) ~= "string" or inventory.id == "" then
      error(BattleErrors.input("joined inventories must be named", {}))
    end
    if
      index.inventories[
        inventory.id --[[@as string]]
      ] ~= nil
    then
      error(BattleErrors.input("inventory identities are never reused", { inventory = inventory.id }))
    end
    if type(inventory.owners) ~= "table" or type(inventory.quantities) ~= "table" then
      error(BattleErrors.input("joined inventories must carry owners and quantities", { inventory = inventory.id }))
    end
  end
  return true
end

--- Stages a validated join without touching live state. Returns a detached
--- staging record the session owner applies exactly once at the declared
--- settlement boundary.
---@param target unknown join target, either a live session or a detached scenario record
---@param request JoinRequest join request under staging
---@return table<string, unknown> detached staging record for the session owner
function Topology.prepareJoin(target, request)
  Topology.validateOwnership(target, request)
  local record = checkRequest(request)
  local index, isSession = indexTarget(target)
  if isSession and not index.settled then
    error(BattleErrors.input("joins stage only at a settled mechanics boundary", {}))
  end
  return {
    version = Topology.VERSION,
    targetKind = isSession and "session" or "scenario",
    format = index.format,
    ruleset = index.ruleset,
    baseCounter = index.baseCounter,
    reason = record.reason,
    settlementBoundary = record.settlementBoundary,
    participant = copyValue(record.participant),
    combatants = copyValue(record.combatants),
    positions = copyValue(record.positions),
    inventories = copyValue(record.inventories),
  }
end

--- Publishes a staged join through the session owner. The staging must
--- still match the session format, ruleset, and batch counter; any
--- intervening round closes the staging as stale instead of applying it
--- onto moved state.
---@param session unknown live headless session owning the battle state
---@param staged table<string, unknown> staging record from prepareJoin
---@return table<string, unknown> join receipt carrying the published identities
function Topology.applyJoin(session, staged)
  if
    type(session) ~= "table" or type((session --[[@as table<string, unknown>]]).applyJoin) ~= "function"
  then
    error(BattleErrors.input("joins publish through the session owner", {}))
  end
  if type(staged) ~= "table" then
    error(BattleErrors.input("joins apply a staged record", {}))
  end
  if
    (staged --[[@as table<string, unknown>]]).version ~= Topology.VERSION
  then
    error(BattleErrors.input("staged joins carry the current version", {}))
  end
  if
    (staged --[[@as table<string, unknown>]]).targetKind ~= "session"
  then
    error(BattleErrors.input("scenario assemblies apply at construction, not mid-battle", {}))
  end
  local apply = (session --[[@as table<string, unknown>]]).applyJoin --[[@as fun(self: unknown, staged: unknown): table<string, unknown>]]
  return apply(session, staged)
end

return Topology
