-- Semantic respawn and escape-entrance values backing the persisted
-- fieldTravel record. The state owns its value record: captures are fresh
-- copies, and callers can never retain a live pointer. Pure domain module:
-- no love dependency and no I/O.
--
-- The default last-heal spawn is the mother's house spawn (the source
-- Save_LocalFieldData_Init default, GetMomSpawnId ->
-- include/constants/spawns.h SPAWN_NEW_BARK). Numeric source identities
-- stay producer-side; this default is the semantic key.

---@class FieldTravelState
---@field lastHealSpawn string
---@field escapeEntrance table<string, unknown>|nil
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

local function checkSpawn(value)
  assert(type(value) == "string" and value ~= "", "last heal spawn must be a non-empty spawn key")
end

local function checkEntrance(value)
  assert(type(value) == "table", "escape entrance must be a table")
  assert(type(value.map) == "string" and value.map ~= "", "escape entrance map must be a non-empty symbol")
  assert(isNonNegativeInteger(value.fieldX), "escape entrance fieldX must be a non-negative integer")
  assert(isNonNegativeInteger(value.fieldZ), "escape entrance fieldZ must be a non-negative integer")
  assert(FACING[value.facing], "escape entrance facing is invalid")
end

local function copyEntrance(value)
  if value == nil then
    return nil
  end
  return { map = value.map, fieldX = value.fieldX, fieldZ = value.fieldZ, facing = value.facing }
end

---@param travel table<string, unknown> the validated fieldTravel record
---@return FieldTravelState
function FieldTravelState.new(travel)
  assert(type(travel) == "table", "FieldTravelState owns the travel value record")
  checkSpawn(travel.lastHealSpawn)
  if travel.escapeEntrance ~= nil then
    checkEntrance(travel.escapeEntrance)
  end
  return setmetatable({
    lastHealSpawn = travel.lastHealSpawn,
    escapeEntrance = copyEntrance(travel.escapeEntrance),
  }, FieldTravelState)
end

FieldTravelState.__index = FieldTravelState

---@return table<string, unknown> a fresh copy of the travel values
function FieldTravelState:capture()
  return { lastHealSpawn = self.lastHealSpawn, escapeEntrance = copyEntrance(self.escapeEntrance) }
end

---@param spawn string
function FieldTravelState:setLastHealSpawn(spawn)
  checkSpawn(spawn)
  self.lastHealSpawn = spawn
end

---@param entrance table<string, unknown>
function FieldTravelState:setEscapeEntrance(entrance)
  checkEntrance(entrance)
  self.escapeEntrance = copyEntrance(entrance)
end

function FieldTravelState:clearEscapeEntrance()
  self.escapeEntrance = nil
end

return FieldTravelState
