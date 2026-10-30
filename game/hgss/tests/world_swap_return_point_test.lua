-- Special-spawn publication lives exactly on the successful world commit: an
-- outdoor-to-indoor entry records the outdoor warp tile with its entry
-- facing, later indoor moves and outdoor travel retain it, and failed or
-- unrelated swaps never touch the durable travel record.

local Assert = require("tests.support.Assert")
local FieldTravelState = require("libs.hgss.src.field.FieldTravelState")
local FieldWorldSwapCoordinator = require("game.hgss.src.field.FieldWorldSwapCoordinator")

local T = {}

local function travelWith(special)
  local record = { lastHealSpawn = FieldTravelState.DEFAULT_LAST_HEAL_SPAWN }
  if special ~= nil then
    record.specialSpawn = special
  end
  return FieldTravelState.new(record)
end

local function mapDouble(symbol, environment)
  return {
    mapSymbol = symbol,
    mapId = 1,
    fieldData = { transitionEnvironment = environment },
  }
end

local function runtimeDouble(sourceMap, travel, facing)
  local runtime = {
    fieldTravel = travel,
    runtimeMap = sourceMap,
    player = { fieldX = 100, fieldZ = 200, facing = facing or "south" },
    transition = {},
    session = {
      beginMapEntry = function() end,
    },
    zoneController = {},
    fieldTerrainEffectController = {
      clear = function() end,
    },
    scripts = {
      onMapSwap = function() end,
    },
    followingMon = nil,
    followingMonTransition = nil,
    audio = nil,
    playerVisual = nil,
    camera = nil,
    residency = {
      commitTransition = function()
        return true
      end,
      discardTransition = function()
        return true
      end,
    },
  }
  return runtime
end

local function publishTo(sourceMap, travel, destinationMap, facing)
  local coordinator = setmetatable({}, FieldWorldSwapCoordinator)
  local runtime = runtimeDouble(sourceMap, travel, facing)
  coordinator:publishSpecialSpawn(runtime, { destinationMap = destinationMap })
  return runtime
end

function T.outdoor_to_cave_records_the_warp_tile_and_entry_facing()
  local travel = travelWith(nil)
  publishTo(mapDouble("MAP_ROUTE_46", "outdoors"), travel, mapDouble("MAP_DARK_CAVE_ROUTE_31_SIDE", "cave"), "south")
  Assert.deepEqual(travel:capture().specialSpawn, {
    map = "MAP_ROUTE_46",
    fieldX = 100,
    fieldZ = 200,
    warpId = -1,
    direction = "south",
  }, "the recorded spawn is the outside source tile, not the destination")
end

function T.a_northward_entrance_records_the_tile_south_of_the_warp()
  local travel = travelWith(nil)
  publishTo(mapDouble("MAP_VIOLET", "outdoors"), travel, mapDouble("MAP_VIOLET_GYM", "building"), "north")
  local special = travel:capture().specialSpawn
  Assert.equal(special.fieldZ, 201, "a northward entrance records the tile below the warp")
  Assert.equal(special.direction, "north", "the entry facing is kept")
end

function T.indoor_moves_and_outdoor_travel_retain_the_recorded_spawn()
  local recorded = { map = "MAP_ROUTE_46", fieldX = 100, fieldZ = 200, warpId = -1, direction = "south" }
  local travel = travelWith(recorded)
  publishTo(mapDouble("MAP_DARK_CAVE_ROUTE_31_SIDE", "cave"), travel, mapDouble("MAP_DARK_CAVE_ROUTE_45_SIDE", "cave"))
  publishTo(mapDouble("MAP_DARK_CAVE_ROUTE_31_SIDE", "cave"), travel, mapDouble("MAP_ROUTE_31", "outdoors"))
  publishTo(mapDouble("MAP_NEW_BARK", "outdoors"), travel, mapDouble("MAP_ROUTE_29", "outdoors"))
  Assert.deepEqual(travel:capture().specialSpawn, recorded, "nothing but an outdoor entry rewrites the spawn")
end

function T.aborted_swaps_leave_travel_untouched()
  local travel = travelWith(nil)
  local coordinator = setmetatable({ runtime = {} }, FieldWorldSwapCoordinator)
  coordinator:abort({ destinationMap = mapDouble("MAP_DARK_CAVE_ROUTE_31_SIDE", "cave") }, {})
  Assert.isNil(travel:capture().specialSpawn, "an aborted entry must not record")
end

return { tests = T }
