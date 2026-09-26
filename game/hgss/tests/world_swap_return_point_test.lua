-- Escape-entrance publication lives exactly on the successful world
-- commit: an outside-to-escapable-cave entry records the outside return
-- point, inner-cave moves retain it, leaving a cave clears it, and failed
-- or unrelated swaps never touch the durable travel record.

local Assert = require("tests.support.Assert")
local FieldTravelState = require("libs.hgss.src.field.FieldTravelState")
local FieldWorldSwapCoordinator = require("game.hgss.src.field.FieldWorldSwapCoordinator")

local T = {}

local function travelWith(entrance)
  local record = { lastHealSpawn = FieldTravelState.DEFAULT_LAST_HEAL_SPAWN }
  if entrance ~= nil then
    record.escapeEntrance = entrance
  end
  return FieldTravelState.new(record)
end

local function mapDouble(symbol, environment, cave, escapeAllowed)
  return {
    mapSymbol = symbol,
    mapId = 1,
    fieldData = {
      transitionEnvironment = environment,
      fieldUse = { cave = cave, escapeAllowed = escapeAllowed },
    },
  }
end

local function runtimeDouble(sourceMap, travel)
  local runtime = {
    fieldTravel = travel,
    runtimeMap = sourceMap,
    player = { fieldX = 100, fieldZ = 200, facing = "north" },
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

local function publishTo(sourceMap, travel, destinationMap)
  local coordinator = setmetatable({}, FieldWorldSwapCoordinator)
  local runtime = runtimeDouble(sourceMap, travel)
  coordinator:publishEscapeEntrance(runtime, { destinationMap = destinationMap })
  return runtime
end

function T.outside_to_escape_cave_records_the_outside_return_point()
  local travel = travelWith(nil)
  publishTo(
    mapDouble("MAP_ROUTE_46", "outdoors", false, false),
    travel,
    mapDouble("MAP_DARK_CAVE_ROUTE_31_SIDE", "cave", true, true)
  )
  local entrance = travel:capture().escapeEntrance
  Assert.notNil(entrance, "a successful outside cave entry must record the entrance")
  Assert.deepEqual(entrance, {
    map = "MAP_ROUTE_46",
    fieldX = 100,
    fieldZ = 200,
    facing = "north",
  }, "the recorded entrance is the outside source tile, not the destination")
end

function T.inner_cave_moves_retain_the_recorded_entrance()
  local recorded = { map = "MAP_ROUTE_46", fieldX = 100, fieldZ = 200, facing = "north" }
  local travel = travelWith(recorded)
  publishTo(
    mapDouble("MAP_DARK_CAVE_ROUTE_31_SIDE", "cave", true, true),
    travel,
    mapDouble("MAP_DARK_CAVE_ROUTE_45_SIDE", "cave", true, true)
  )
  Assert.deepEqual(
    travel:capture().escapeEntrance,
    recorded,
    "an inner-cave floor change must not replace the entrance"
  )
end

function T.leaving_a_cave_clears_the_stale_entrance()
  local travel = travelWith({ map = "MAP_ROUTE_46", fieldX = 100, fieldZ = 200, facing = "north" })
  publishTo(
    mapDouble("MAP_DARK_CAVE_ROUTE_31_SIDE", "cave", true, true),
    travel,
    mapDouble("MAP_ROUTE_31", "outdoors", false, false)
  )
  Assert.isNil(travel:capture().escapeEntrance, "exiting the cave must clear the stale entrance")
end

function T.outside_to_ordinary_map_leaves_travel_untouched()
  local travel = travelWith(nil)
  publishTo(
    mapDouble("MAP_NEW_BARK", "outdoors", false, false),
    travel,
    mapDouble("MAP_ROUTE_29", "outdoors", false, false)
  )
  Assert.isNil(travel:capture().escapeEntrance, "ordinary travel must not invent an entrance")
  Assert.equal(travel:capture().lastHealSpawn, FieldTravelState.DEFAULT_LAST_HEAL_SPAWN, "ordinary travel keeps spawn")
end

function T.aborted_swaps_leave_travel_untouched()
  local travel = travelWith(nil)
  local coordinator = setmetatable({ runtime = {} }, FieldWorldSwapCoordinator)
  coordinator:abort({ destinationMap = mapDouble("MAP_DARK_CAVE_ROUTE_31_SIDE", "cave", true, true) }, {})
  Assert.isNil(travel:capture().escapeEntrance, "an aborted entry must not record")
end

return { tests = T }
