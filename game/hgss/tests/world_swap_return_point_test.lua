-- Escape-entrance publication lives exactly on the successful world
-- commit: an outside-to-escapable-cave entry records the outside return
-- point, inner-cave moves retain it, leaving a cave clears it, and failed
-- or unrelated swaps never touch the durable travel record.

local Assert = require("tests.support.Assert")
local FieldTravelState = require("libs.hgss.src.field.FieldTravelState")
local FieldWorldSwapCoordinator = require("game.hgss.src.field.FieldWorldSwapCoordinator")
local MapProjection = require("game.hgss.src.pokegear.MapProjection")

local T = {}

local function travelWith(entrance)
  local record = { lastHealSpawn = FieldTravelState.DEFAULT_LAST_HEAL_SPAWN }
  if entrance ~= nil then
    record.escapeEntrance = entrance
  end
  return FieldTravelState.new(record)
end

local function travelWithExterior(exterior)
  local record = {
    lastHealSpawn = FieldTravelState.DEFAULT_LAST_HEAL_SPAWN,
    lastExterior = exterior,
  }
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

local function commitMapSwap(sourceMap, travel, destinationMap, commitTransition)
  local runtime = runtimeDouble(sourceMap, travel)
  runtime.pokegearCatalog = {
    locations = {
      { fieldMap = "MAP_ROUTE_46", matrix = { x = 1, y = 2 } },
    },
  }
  runtime.session.currentMap = sourceMap
  runtime.session.beginMapEntry = function() end
  runtime.zoneController.currentMap = sourceMap
  runtime.fieldTerrainEffectController.clear = function() end
  runtime.residency.commitTransition = commitTransition or function()
    return true
  end
  runtime.residency.discardTransition = function()
    return true
  end
  runtime.scripts.onMapSwap = function() end

  local coordinator = FieldWorldSwapCoordinator.new(runtime)
  coordinator:commit({ destinationMap = destinationMap }, "north", {
    player = { fieldX = 9, fieldZ = 41, facing = "north" },
    camera = {},
    playerVisual = {},
    residency = {},
  })
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

function T.committed_outdoors_to_indoor_swap_publishes_exterior_world_cell()
  local travel = travelWithExterior(nil)
  commitMapSwap(
    mapDouble("MAP_ROUTE_46", "outdoors", false, false),
    travel,
    mapDouble("MAP_POKEMON_LEAGUE_ENTRANCE_WIFI_ROOM", "building", false, false)
  )
  Assert.deepEqual(travel:capture().lastExterior, { x = 3, y = 6 })
end

function T.interior_and_unqualified_swaps_preserve_last_exterior()
  local exterior = { x = 4, y = 7 }
  local travel = travelWithExterior(exterior)
  commitMapSwap(
    mapDouble("MAP_DARK_CAVE_ROUTE_31_SIDE", "cave", true, true),
    travel,
    mapDouble("MAP_DARK_CAVE_ROUTE_45_SIDE", "cave", true, true)
  )
  Assert.deepEqual(travel:capture().lastExterior, exterior, "interior travel retains the outdoor cell")

  commitMapSwap(
    mapDouble("MAP_ROUTE_45", "outdoors", false, false),
    travel,
    mapDouble("MAP_POKEMON_LEAGUE_ENTRANCE_WIFI_ROOM", "building", false, false)
  )
  Assert.deepEqual(
    travel:capture().lastExterior,
    { x = 4, y = 7 },
    "a source absent from the catalog cannot replace the known cell"
  )
end

function T.failed_commit_and_abort_do_not_publish_last_exterior()
  local exterior = { x = 4, y = 7 }
  local travel = travelWithExterior(exterior)
  local source = mapDouble("MAP_ROUTE_46", "outdoors", false, false)
  local destination = mapDouble("MAP_POKEMON_LEAGUE_ENTRANCE_WIFI_ROOM", "building", false, false)

  Assert.throws(function()
    commitMapSwap(source, travel, destination, function()
      error("residency commit failed")
    end)
  end, "a failed residency commit must propagate")
  Assert.deepEqual(travel:capture().lastExterior, exterior, "failed commits preserve prior travel state")

  local coordinator = FieldWorldSwapCoordinator.new({
    residency = {
      discardTransition = function()
        return true
      end,
    },
  })
  coordinator:abort({ destinationMap = destination }, { residency = {} })
  Assert.deepEqual(travel:capture().lastExterior, exterior, "aborting a prepared swap publishes nothing")
end

function T.zero_header_projection_prefers_last_exterior_then_special_spawn()
  Assert.deepEqual(
    MapProjection.contextCell({
      explicitX = 0,
      explicitY = 0,
      lastExterior = { x = 3, y = 8 },
      specialSpawn = { x = 5, y = 9 },
    }),
    { x = 3, y = 8 },
    "the persisted exterior precedes the special-spawn fallback"
  )
  Assert.deepEqual(
    MapProjection.contextCell({ explicitX = 12, explicitY = 13, lastExterior = { x = 3, y = 8 } }),
    { x = 12, y = 13 },
    "explicit header coordinates precede either fallback"
  )
end

return { tests = T }
