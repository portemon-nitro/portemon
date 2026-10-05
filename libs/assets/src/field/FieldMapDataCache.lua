-- Defines paths and readiness for lightweight generated field map records.
-- Event changes stay independent from heavy map geometry caches.

local FieldMapDataCache = {}

---@class FieldMapDataCache.Field
---@field schema string
---@field mapId integer
---@field events table<string, unknown>
---@field transitionEnvironment string

local Validate = require("libs.assets.src.Validate")
local Contract = require("libs.assets.src.DerivedAssetContract")
local FieldObjectMovement = require("libs.assets.src.field.FieldObjectMovement")
local Errors = require("libs.errors.src.Errors")

local SPAWN_INDEX_INVALID = "FIELD_MAP_DATA_SPAWN_INDEX_INVALID"

FieldMapDataCache.FORMAT = Contract.fieldMapData.cacheFormat
FieldMapDataCache.FIELD_SCHEMA = Contract.fieldMapData.fieldSchema
FieldMapDataCache.SPAWN_INDEX_SCHEMA = Contract.fieldMapData.spawnIndexSchema
FieldMapDataCache.TRANSITION_ENVIRONMENTS = { cave = true, outdoors = true, building = true }

-- The event collections the current field-map schema always carries.
local EVENT_COLLECTIONS = { "background", "objects", "warps", "coordinates" }

---@param value unknown
---@return boolean
function FieldMapDataCache.isTransitionEnvironment(value)
  return type(value) == "string" and FieldMapDataCache.TRANSITION_ENVIRONMENTS[value] == true
end

local function hasString(value)
  return type(value) == "string" and #value > 0
end

local function hasOnlyKeys(value, allowed)
  for key in pairs(value) do
    if not allowed[key] then
      return false
    end
  end
  return true
end

local function isMovementRange(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value % 1 == 0
    and value >= -1
end

local function hasInitScripts(field)
  if not Validate.isArray(field.initScripts) then
    return false
  end
  for _, descriptor in ipairs(field.initScripts) do
    if type(descriptor) ~= "table" or type(descriptor.type) ~= "string" then
      return false
    end
    if descriptor.type == "on_frame_eq" then
      if not hasOnlyKeys(descriptor, { type = true, rules = true }) or not Validate.isArray(descriptor.rules) then
        return false
      end
      for _, rule in ipairs(descriptor.rules) do
        if
          type(rule) ~= "table"
          or not hasOnlyKeys(rule, { variableId = true, equals = true, scriptId = true })
          or not Validate.isNonNegativeInteger(rule.variableId)
          or rule.variableId > 0xFFFF
          or not Validate.isNonNegativeInteger(rule.equals)
          or rule.equals > 0xFFFF
          or not hasString(rule.scriptId)
        then
          return false
        end
      end
    elseif descriptor.type == "on_transition" or descriptor.type == "on_resume" or descriptor.type == "on_load" then
      if not hasOnlyKeys(descriptor, { type = true, scriptId = true }) or not hasString(descriptor.scriptId) then
        return false
      end
    else
      return false
    end
  end
  return true
end

function FieldMapDataCache.hasRequiredInitScripts(field)
  return type(field) == "table" and hasInitScripts(field)
end

-- The audio policy the current field-map schema always carries: the music
-- record and the soundplates array. Soundplate records are runtime-semantic
-- only (rectangle, sequence, donor-bank flag, derived duck/ambient targets,
-- optional disable flag); raw source selectors live solely in producer data.
---@param field table<string, unknown>
---@return boolean
local function hasAudioPolicy(field)
  return type(field.music) == "table" and Validate.isArray(field.soundplates)
end

-- The field-use policy the current field-map schema always carries: one
-- boolean per permission/exception key. Runtime eligibility reads this
-- record; a record without it is malformed generated data, never an
-- empty feature.
---@param fieldUse unknown
---@return boolean
function FieldMapDataCache.hasFieldUsePolicy(fieldUse)
  if type(fieldUse) ~= "table" then
    return false
  end
  for _, key in ipairs({
    "flyAllowed",
    "teleportAllowed",
    "escapeAllowed",
    "flashUsable",
    "alphChamber",
    "icePathB2F",
    "cave",
    "unionOrColosseum",
  }) do
    if type(fieldUse[key]) ~= "boolean" then
      return false
    end
  end
  return true
end
-- The authoritative event-collection rule of the current field-map record:
-- true only when every required collection is present as an array. Runtime
-- consumers that read field records validate
-- against this single rule; a record that fails it is malformed generated
-- data, never an empty feature.
---@param events unknown
---@return boolean
function FieldMapDataCache.hasRequiredEvents(events)
  if type(events) ~= "table" then
    return false
  end
  for _, key in ipairs(EVENT_COLLECTIONS) do
    if not Validate.isArray(events[key]) then
      return false
    end
  end
  for _, event in ipairs(events.background) do
    if type(event) ~= "table" or type(event.hiddenItem) ~= "boolean" then
      return false
    end
  end
  for _, object in ipairs(events.objects) do
    if
      type(object) ~= "table"
      or object.movement ~= nil
      or not FieldObjectMovement.isType(object.movementType)
      or not isMovementRange(object.xRange)
      or not isMovementRange(object.yRange)
    then
      return false
    end
  end
  return true
end

function FieldMapDataCache.mapDir(mapId)
  assert(type(mapId) == "number" and mapId >= 0, "mapId must be non-negative")
  return string.format("data/generated/field/maps/%04d", mapId)
end

function FieldMapDataCache.fieldPath(mapId)
  return FieldMapDataCache.mapDir(mapId) .. "/field.lua"
end

function FieldMapDataCache.dependenciesPath(mapId)
  return FieldMapDataCache.mapDir(mapId) .. "/dependencies.lua"
end

function FieldMapDataCache.markerPath(mapId)
  return FieldMapDataCache.mapDir(mapId) .. "/complete"
end

-- Family-level teleport landing index: one record for the whole ROM,
-- published beside the per-map directories through the same staged
-- publication discipline. Runtime return planning reads it; producer
-- numeric source identities never reach it.
function FieldMapDataCache.spawnDir()
  return "data/generated/field/spawns"
end

function FieldMapDataCache.spawnIndexPath()
  return FieldMapDataCache.spawnDir() .. "/spawns.lua"
end

function FieldMapDataCache.spawnIndexMarkerPath()
  return FieldMapDataCache.spawnDir() .. "/complete"
end

function FieldMapDataCache.spawnIndexMarker(romSha1, dependencyHash)
  assert(type(romSha1) == "string" and romSha1 ~= "", "spawn index marker needs the ROM identity")
  assert(type(dependencyHash) == "string" and dependencyHash ~= "", "spawn index marker needs its content hash")
  return string.format("%s:%s:%s", FieldMapDataCache.FORMAT, romSha1, dependencyHash)
end

-- The teleport landing index the current schema always carries: spawn
-- keys to outdoor arrival maps plus destination-global tiles. Source
-- carries no arrival facing; the planner stamps the standard arrival
-- facing instead. An index without it is malformed generated data,
-- never an empty feature.
---@param spawns unknown
---@return boolean
function FieldMapDataCache.hasSpawnDestinations(spawns)
  if type(spawns) ~= "table" then
    return false
  end
  local count = 0
  for key, destination in pairs(spawns) do
    if type(key) ~= "string" or key == "" then
      return false
    end
    if
      type(destination) ~= "table"
      or type(destination.map) ~= "string"
      or destination.map == ""
      or type(destination.fieldX) ~= "number"
      or destination.fieldX % 1 ~= 0
      or destination.fieldX < 0
      or type(destination.fieldZ) ~= "number"
      or destination.fieldZ % 1 ~= 0
      or destination.fieldZ < 0
    then
      return false
    end
    count = count + 1
  end
  return count > 0
end

function FieldMapDataCache.hasBlackoutDestinations(spawns)
  if type(spawns) ~= "table" or not FieldMapDataCache.hasSpawnDestinations(spawns) then
    return false
  end
  for _, destination in pairs(spawns) do
    if destination.facing ~= "north" then
      return false
    end
  end
  return true
end

-- True only if the marker is exact and the index loads with the current
-- schema and a valid destination table.
function FieldMapDataCache.isSpawnIndexReady(cacheFs, expectedMarker)
  if cacheFs:read(FieldMapDataCache.spawnIndexMarkerPath()) ~= expectedMarker then
    return false
  end
  local index = cacheFs:loadLua(FieldMapDataCache.spawnIndexPath()) ---@type table?
  if type(index) ~= "table" then
    return false
  end
  return index.schema == FieldMapDataCache.SPAWN_INDEX_SCHEMA
    and FieldMapDataCache.hasSpawnDestinations(index.spawns)
    and FieldMapDataCache.hasBlackoutDestinations(index.blackoutSpawns)
end

function FieldMapDataCache.blackoutDestination(cacheFs, spawnKey)
  assert(type(spawnKey) == "string" and spawnKey ~= "", "blackout resolution needs a spawn key")
  local index = cacheFs:loadLua(FieldMapDataCache.spawnIndexPath()) ---@type table?
  if
    type(index) ~= "table"
    or index.schema ~= FieldMapDataCache.SPAWN_INDEX_SCHEMA
    or not FieldMapDataCache.hasBlackoutDestinations(index.blackoutSpawns)
  then
    Errors.raise(SPAWN_INDEX_INVALID, "blackout destination index is missing or malformed; rebuild the derived cache", {
      spawn = spawnKey,
    })
  end
  local spawnIndex = index --[[@as table<string, unknown>]]
  local blackoutSpawns = spawnIndex.blackoutSpawns --[[@as table<string, table<string, unknown>>]]
  local destination = blackoutSpawns[spawnKey]
  if destination == nil then
    return nil
  end
  return {
    map = destination.map,
    fieldX = destination.fieldX,
    fieldZ = destination.fieldZ,
    facing = destination.facing,
  }
end

-- Resolve one cited landing destination: a fresh record on success, nil
-- for an unknown spawn key (the caller refuses loudly, never a guess).
-- A missing or malformed index is corrupt generated data and raises.
---@param cacheFs CacheFs
---@param spawnKey string
---@return table<string, unknown>? a fresh { map, fieldX, fieldZ } record
function FieldMapDataCache.spawnDestination(cacheFs, spawnKey)
  assert(type(spawnKey) == "string" and spawnKey ~= "", "spawn resolution needs a spawn key")
  local index = cacheFs:loadLua(FieldMapDataCache.spawnIndexPath()) ---@type table?
  if type(index) ~= "table" or index.schema ~= FieldMapDataCache.SPAWN_INDEX_SCHEMA then
    Errors.raise(
      SPAWN_INDEX_INVALID,
      "teleport landing index is missing or malformed; rebuild the derived cache",
      { spawn = spawnKey }
    )
  end
  local spawnIndex = index --[[@as table<string, unknown>]]
  local destinations = spawnIndex.spawns --[[@as table<string, table<string, unknown>>]]
  if
    not FieldMapDataCache.hasSpawnDestinations(destinations)
    or not FieldMapDataCache.hasBlackoutDestinations(spawnIndex.blackoutSpawns)
  then
    Errors.raise(
      SPAWN_INDEX_INVALID,
      "teleport landing index is missing or malformed; rebuild the derived cache",
      { spawn = spawnKey }
    )
  end
  local destination = destinations[spawnKey]
  if destination == nil then
    return nil
  end
  assert(type(destination) == "table", "spawn destinations are records")
  return { map = destination.map, fieldX = destination.fieldX, fieldZ = destination.fieldZ }
end

function FieldMapDataCache.marker(romSha1, mapId, dependencyHash)
  return string.format("%s:%s:%d:%s", FieldMapDataCache.FORMAT, romSha1, mapId, dependencyHash)
end

-- True only if the marker is exact, the record carries the current identity
-- (schema and mapId), dependencies load, and every required event collection
-- and the audio policy (music record, soundplates array) are present.
function FieldMapDataCache.isReady(cacheFs, mapId, expectedMarker)
  if cacheFs:read(FieldMapDataCache.markerPath(mapId)) ~= expectedMarker then
    return false
  end
  local field = cacheFs:loadLua(FieldMapDataCache.fieldPath(mapId)) ---@type table?
  local dependencies = cacheFs:loadLua(FieldMapDataCache.dependenciesPath(mapId)) ---@type table?
  if
    type(field) ~= "table"
    or field.schema ~= FieldMapDataCache.FIELD_SCHEMA
    or field.mapId ~= mapId
    or type(dependencies) ~= "table"
  then
    return false
  end
  local events = field.events
  if
    not FieldMapDataCache.hasRequiredEvents(events)
    or not hasAudioPolicy(field)
    or not hasInitScripts(field)
    or not FieldMapDataCache.hasFieldUsePolicy(field.fieldUse)
    or not FieldMapDataCache.isTransitionEnvironment(field.transitionEnvironment)
  then
    return false
  end
  return true
end

return FieldMapDataCache
