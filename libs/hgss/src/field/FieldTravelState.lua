-- Semantic respawn and special-spawn values backing the persisted
-- fieldTravel record. The state owns its value record: captures are fresh
-- copies, and callers can never retain a live pointer. Pure domain module:
-- no love dependency and no I/O.
--
-- The default last-heal spawn is the mother's house spawn (the source
-- Save_LocalFieldData_Init default, GetMomSpawnId ->
-- include/constants/spawns.h SPAWN_NEW_BARK). Numeric source identities
-- stay producer-side; this default is the semantic key.
--
-- The special spawn is the source LocalFieldData.specialSpawn equivalent:
-- the setter-written relocation record, distinct from the last-heal spawn.
-- It starts unestablished (nil); only an explicit validated write
-- establishes it.

---@class FieldTravelState
---@field lastHealSpawn string
---@field private _specialSpawn table<string, unknown>|nil
local FieldTravelState = {}

-- The source default respawn, as a semantic spawn key.
FieldTravelState.DEFAULT_LAST_HEAL_SPAWN = "SPAWN_NEW_BARK"

local FACING = { north = true, south = true, west = true, east = true }

local function isNonNegativeInteger(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value % 1 == 0
    and value >= 0
end

local function isInteger(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value % 1 == 0
end

local function checkSpawn(value)
  assert(type(value) == "string" and value ~= "", "last heal spawn must be a non-empty spawn key")
end

local function checkSpecialSpawn(value)
  assert(type(value) == "table", "special spawn must be a table")
  assert(type(value.map) == "string" and value.map ~= "", "special spawn map must be a non-empty symbol")
  assert(isNonNegativeInteger(value.fieldX), "special spawn fieldX must be a non-negative integer")
  assert(isNonNegativeInteger(value.fieldZ), "special spawn fieldZ must be a non-negative integer")
  assert(isInteger(value.warpId), "special spawn warpId must be an integer")
  assert(FACING[value.direction], "special spawn direction is invalid")
end

local function copySpecialSpawn(value)
  if value == nil then
    return nil
  end
  return {
    map = value.map,
    fieldX = value.fieldX,
    fieldZ = value.fieldZ,
    warpId = value.warpId,
    direction = value.direction,
  }
end

---@param travel table<string, unknown> the validated fieldTravel record
---@return FieldTravelState
function FieldTravelState.new(travel)
  assert(type(travel) == "table", "FieldTravelState owns the travel value record")
  checkSpawn(travel.lastHealSpawn)
  if travel.specialSpawn ~= nil then
    checkSpecialSpawn(travel.specialSpawn)
  end
  return setmetatable({
    lastHealSpawn = travel.lastHealSpawn,
    _specialSpawn = copySpecialSpawn(travel.specialSpawn),
  }, FieldTravelState)
end

FieldTravelState.__index = FieldTravelState

---@return table<string, unknown> a fresh copy of the travel values
function FieldTravelState:capture()
  local snapshot = { lastHealSpawn = self.lastHealSpawn }
  local specialSpawn = copySpecialSpawn(self._specialSpawn)
  if specialSpawn ~= nil then
    snapshot.specialSpawn = specialSpawn
  end
  return snapshot
end

---@param spawn string
function FieldTravelState:setLastHealSpawn(spawn)
  checkSpawn(spawn)
  self.lastHealSpawn = spawn
end

-- Record the setter-written relocation destination. The record is validated
-- before mutation and copied in, so a malformed write leaves the prior
-- value (or the unestablished nil) unchanged.
---@param spawn table<string, unknown> { map, fieldX, fieldZ, warpId, direction }
function FieldTravelState:setSpecialSpawn(spawn)
  checkSpecialSpawn(spawn)
  self._specialSpawn = copySpecialSpawn(spawn)
end

-- The established special-spawn record as a fresh copy, or nil before any
-- validated write established one.
---@return table<string, unknown>|nil
function FieldTravelState:specialSpawn()
  return copySpecialSpawn(self._specialSpawn)
end

return FieldTravelState
