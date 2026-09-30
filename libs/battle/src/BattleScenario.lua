-- Detached battle setup validation. A scenario record carries resolved
-- content identity, every initial mon record, alliance membership, field
-- slots, declared decision producers, per-inventory quantities, the source
-- environment, and the random seed. Validation runs before any session is
-- published and returns a detached copy, so later caller-side mutations can
-- never reach live simulation state. Mon records are checked against the
-- mon domain owner rather than re-described here.

local BattleErrors = require("libs.battle.src.errors")
local Mon = require("libs.mons.src.Mon")

---@class BattleScenario
local BattleScenario = {}

---@param value unknown
---@param bound integer
---@return boolean
local function isPositiveInt(value, bound)
  return type(value) == "number"
    and value == value
    and math.abs(value) ~= math.huge
    and value % 1 == 0
    and value >= 1
    and value <= bound
end

---@param value unknown
---@return boolean
local function isId(value)
  return isPositiveInt(value, 9007199254740991)
end

---@param value unknown
---@param what string
---@return table<integer, unknown>
local function checkSequence(value, what)
  if type(value) ~= "table" then
    error(BattleErrors.input(what .. " must be an ordered array", {}))
  end
  local array = value --[[@as table<integer, unknown>]]
  local count = #array
  for index = 1, count do
    if array[index] == nil then
      error(BattleErrors.input(what .. " must not skip positions", { index = index }))
    end
  end
  for key in pairs(array) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > count then
      error(BattleErrors.input(what .. " must be a dense array", { key = tostring(key) }))
    end
  end
  return array
end

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

---@param record table<string, unknown>
---@param field string
---@param what string
---@return string
local function checkName(record, field, what)
  local value = record[field]
  if type(value) ~= "string" or value == "" then
    error(BattleErrors.input(what .. " must name its " .. field, {}))
  end
  return value --[[@as string]]
end

---@param mon unknown
---@param combatantId integer
local function checkMon(mon, combatantId)
  if type(mon) ~= "table" then
    error(BattleErrors.input("combatant mon records must be records", { combatant = combatantId }))
  end
  local record = mon --[[@as table<string, unknown>]]
  if record.schema ~= Mon.SCHEMA then
    error(BattleErrors.input("combatant mon records must carry the mon domain schema", {
      combatant = combatantId,
      schema = tostring(record.schema),
    }))
  end
  local condition = record.condition
  if type(condition) ~= "table" then
    error(BattleErrors.input("combatant mon records must carry their condition", { combatant = combatantId }))
  end
  local hp = (condition --[[@as table<string, unknown>]]).currentHp
  if type(hp) ~= "number" or hp ~= hp or math.abs(hp) == math.huge or hp % 1 ~= 0 or hp < 0 then
    error(BattleErrors.input("combatant entry health must be a non-negative integer", { combatant = combatantId }))
  end
end

---@param source unknown
---@param combatantId integer
local function checkSource(source, combatantId)
  if source == nil then
    return
  end
  if type(source) ~= "table" then
    error(BattleErrors.input("combatant sources must be records", { combatant = combatantId }))
  end
  local record = source --[[@as table<string, unknown>]]
  for _, field in ipairs({ "kind", "owner", "key" }) do
    if type(record[field]) ~= "string" or record[field] == "" then
      error(BattleErrors.input("combatant sources must name their " .. field, { combatant = combatantId }))
    end
  end
  for _, field in ipairs({ "slot", "revision" }) do
    if record[field] ~= nil and not isPositiveInt(record[field], 9007199254740991) then
      error(BattleErrors.input("combatant source " .. field .. " must be a positive integer", {
        combatant = combatantId,
      }))
    end
  end
end

---@param record table<string, unknown>
---@return table<string, unknown> detached validated scenario copy
function BattleScenario.validate(record)
  if type(record) ~= "table" then
    error(BattleErrors.input("battle scenarios must be records", {}))
  end
  checkName(record, "ruleset", "battle scenarios")
  checkName(record, "format", "battle scenarios")

  local sides = checkSequence(record.sides, "battle sides")
  local participants = checkSequence(record.participants, "battle participants")
  local positions = checkSequence(record.positions, "battle positions")

  local sideById = {}
  for _, entry in ipairs(sides) do
    if type(entry) ~= "table" then
      error(BattleErrors.input("battle sides must be records", {}))
    end
    local side = entry --[[@as table<string, unknown>]]
    if not isId(side.id) then
      error(BattleErrors.input("side identities stay positive", {}))
    end
    local id = side.id --[[@as integer]]
    if sideById[id] ~= nil then
      error(BattleErrors.input("side identities are never reused", { side = id }))
    end
    checkSequence(side.participants, "side membership")
    sideById[id] = side
  end

  local participantById = {}
  local combatantOwner = {}
  for _, entry in ipairs(participants) do
    if type(entry) ~= "table" then
      error(BattleErrors.input("battle participants must be records", {}))
    end
    local participant = entry --[[@as table<string, unknown>]]
    if not isId(participant.id) then
      error(BattleErrors.input("participant identities stay positive", {}))
    end
    local id = participant.id --[[@as integer]]
    if participantById[id] ~= nil then
      error(BattleErrors.input("participant identities are never reused", { participant = id }))
    end
    if sideById[participant.side] == nil then
      error(BattleErrors.input("participants must join a declared side", { participant = id }))
    end
    if type(participant.controller) ~= "string" or participant.controller == "" then
      error(BattleErrors.input("participants without a declared controller cannot join a battle", {
        participant = id,
      }))
    end
    if participant.inventoryId ~= nil then
      if type(participant.inventoryId) ~= "string" or participant.inventoryId == "" then
        error(BattleErrors.input("participant inventory handles must be named", { participant = id }))
      end
    end
    if type(participant.context) ~= "table" then
      error(BattleErrors.input("participants must carry their context record", { participant = id }))
    end
    local roster = checkSequence(participant.roster, "participant rosters")
    if #roster == 0 then
      error(BattleErrors.input("participants must declare a roster", { participant = id }))
    end
    for _, seed in ipairs(roster) do
      if type(seed) ~= "table" then
        error(BattleErrors.input("combatant seeds must be records", { participant = id }))
      end
      local seedRecord = seed --[[@as table<string, unknown>]]
      if not isId(seedRecord.id) then
        error(BattleErrors.input("combatant identities stay positive", { participant = id }))
      end
      local combatantId = seedRecord.id --[[@as integer]]
      if combatantOwner[combatantId] ~= nil then
        error(BattleErrors.input("combatant identities are never reused", { combatant = combatantId }))
      end
      combatantOwner[combatantId] = id
      checkMon(seedRecord.mon, combatantId)
      checkSource(seedRecord.source, combatantId)
    end
    participantById[id] = participant
  end

  for sideId, side in pairs(sideById) do
    local listed = side --[[@as table<string, unknown>]].participants --[[@as table<integer, unknown>]]
    for _, pid in ipairs(listed) do
      local owner = participantById[pid]
      if
        owner == nil or (owner --[[@as table<string, unknown>]]).side ~= sideId
      then
        error(BattleErrors.input("side membership must match participant sides", { side = sideId }))
      end
    end
  end
  for participantId, participant in pairs(participantById) do
    local listed = participant --[[@as table<string, unknown>]]
    local side = sideById[listed.side]
    local found = false
    for _, pid in
      ipairs((side --[[@as table<string, unknown>]]).participants --[[@as table<integer, unknown>]])
    do
      if pid == participantId then
        found = true
      end
    end
    if not found then
      error(BattleErrors.input("side membership must list every participant", { participant = participantId }))
    end
  end

  local occupied = {}
  for _, entry in ipairs(positions) do
    if type(entry) ~= "table" then
      error(BattleErrors.input("battle positions must be records", {}))
    end
    local position = entry --[[@as table<string, unknown>]]
    if not isId(position.id) then
      error(BattleErrors.input("position identities stay positive", {}))
    end
    local id = position.id --[[@as integer]]
    if sideById[position.side] == nil then
      error(BattleErrors.input("positions must stand on a declared side", { position = id }))
    end
    local eligible = checkSequence(position.eligibleParticipants, "position eligibility")
    if #eligible == 0 then
      error(BattleErrors.input("positions must name eligible participants", { position = id }))
    end
    for _, pid in ipairs(eligible) do
      local owner = participantById[pid]
      if owner == nil then
        error(BattleErrors.input("positions cannot name unknown participants", { position = id }))
      end
      if
        (owner --[[@as table<string, unknown>]]).side ~= position.side
      then
        error(BattleErrors.input("position eligibility must stay on the position side", { position = id }))
      end
    end
    if position.occupant ~= nil then
      if not isId(position.occupant) then
        error(BattleErrors.input("position occupants must carry combatant identities", { position = id }))
      end
      local occupant = position.occupant --[[@as integer]]
      local owner = combatantOwner[occupant]
      if owner == nil then
        error(BattleErrors.input("positions cannot name combatants outside every declared roster", {
          position = id,
        }))
      end
      local allowed = false
      for _, pid in ipairs(eligible) do
        if pid == owner then
          allowed = true
        end
      end
      if not allowed then
        error(BattleErrors.input("occupants must belong to a participant eligible for the slot", {
          position = id,
          combatant = occupant,
        }))
      end
      if occupied[occupant] ~= nil then
        error(BattleErrors.input("one combatant cannot hold two positions", { combatant = occupant }))
      end
      occupied[occupant] = id
    end
  end

  if record.inventories ~= nil then
    local inventories = checkSequence(record.inventories, "battle inventories")
    local seenInventories = {}
    for _, entry in ipairs(inventories) do
      if type(entry) ~= "table" then
        error(BattleErrors.input("battle inventories must be records", {}))
      end
      local inventory = entry --[[@as table<string, unknown>]]
      if type(inventory.id) ~= "string" or inventory.id == "" then
        error(BattleErrors.input("battle inventories must be named", {}))
      end
      local inventoryId = inventory.id --[[@as string]]
      if seenInventories[inventoryId] ~= nil then
        error(BattleErrors.input("inventory identities are never reused", { inventory = inventoryId }))
      end
      seenInventories[inventoryId] = true
      local owners = checkSequence(inventory.owners, "inventory ownership")
      if #owners == 0 then
        error(BattleErrors.input("inventories must name their owners", { inventory = inventoryId }))
      end
      for _, pid in ipairs(owners) do
        if participantById[pid] == nil then
          error(BattleErrors.input("inventories cannot name unknown participants", { inventory = inventoryId }))
        end
      end
      if type(inventory.quantities) ~= "table" then
        error(BattleErrors.input("inventories must carry quantities", { inventory = inventoryId }))
      end
      for item, count in
        pairs(inventory.quantities --[[@as table<string, unknown>]])
      do
        if type(item) ~= "string" or item == "" then
          error(BattleErrors.input("inventory items must be named", { inventory = inventoryId }))
        end
        if type(count) ~= "number" or count ~= count or count % 1 ~= 0 or count < 0 then
          error(BattleErrors.input("inventory quantities must be non-negative integers", {
            inventory = inventoryId,
            item = item,
          }))
        end
      end
    end
    for _, participant in pairs(participantById) do
      local recordParticipant = participant --[[@as table<string, unknown>]]
      if recordParticipant.inventoryId ~= nil and seenInventories[recordParticipant.inventoryId] == nil then
        error(BattleErrors.input("participants cannot draw on unknown inventories", {
          inventory = tostring(recordParticipant.inventoryId),
        }))
      end
    end
  end

  if type(record.environment) ~= "table" then
    error(BattleErrors.input("battle scenarios must carry their environment", {}))
  end
  if type(record.random) ~= "table" then
    error(BattleErrors.input("battle scenarios must carry their random state", {}))
  end
  local seed = (record.random --[[@as table<string, unknown>]]).seed
  if type(seed) ~= "number" or seed ~= seed or seed % 1 ~= 0 or seed < 0 or seed > 4294967295 then
    error(BattleErrors.input("battle random seeds must be unsigned 32-bit integers", {}))
  end
  if type(record.formatState) ~= "table" then
    error(BattleErrors.input("battle scenarios must carry their format state", {}))
  end

  return copyValue(record) --[[@as table<string, unknown>]]
end

return BattleScenario
