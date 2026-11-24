-- Special-spawn publication lives exactly on the successful world commit: an
-- outdoor-to-indoor entry records the outdoor warp tile with its entry
-- facing, later indoor moves and outdoor travel retain it, and failed or
-- unrelated swaps never touch the durable travel record.

local Assert = require("tests.support.Assert")
local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
local FieldTravelState = require("libs.hgss.src.field.FieldTravelState")
local FieldWorldSwapCoordinator = require("game.hgss.src.field.FieldWorldSwapCoordinator")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")
local WarpSystem = require("libs.hgss.src.transition.WarpSystem")

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
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
    },
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
    resetEncounterStepCounters = function() end,
    playerAvatar = { durableState = function() return "walking" end },
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

-- A warp trigger record whose destination is the dynamic-warp anchor: the
-- sentinel map header names no map, so the saved destination does.
local function dynamicAnchorTrigger()
  return {
    warp = {
      index = 4,
      x = 5,
      z = 7,
      destinationMapId = 0xFFF,
      destinationWarpId = WarpSystem.DYNAMIC_WARP_SENTINEL,
    },
  }
end

-- An arrival whose own anchor warp is the 0x100 sentinel refreshes the saved
-- dynamic destination with the entrance position (FieldSystem_EnterLocation),
-- so the next warp through that anchor leaves for the map the player entered
-- from. The record is the source map's local tile and the facing the player
-- had when the warp triggered, never the spun player the commit sees.
function T.dynamic_anchor_arrival_records_the_entrance_as_the_destination()
  local travel = travelWith(nil)
  local source = mapDouble("MAP_CELADON_CONDOMINIUMS_1F", "building")
  local destination = mapDouble("MAP_CELADON_DEPARTMENT_STORE_1F", "building")
  local coordinator = setmetatable({}, FieldWorldSwapCoordinator)
  local runtime = runtimeDouble(source, travel, "east")
  coordinator.runtime = runtime
  coordinator:commit({
    sourceMap = source,
    sourceWarp = {
      index = 4,
      x = 5,
      z = 7,
      destinationMapId = 0xFFF,
      destinationWarpId = WarpSystem.DYNAMIC_WARP_SENTINEL,
    },
    destinationMap = destination,
    destinationWarp = {
      index = 0,
      x = 5,
      z = 3,
      destinationMapId = 0xFFF,
      destinationWarpId = WarpSystem.DYNAMIC_WARP_SENTINEL,
    },
    sourceFacing = "south",
    fieldX = 5,
    fieldZ = 3,
    surfaceId = 0,
    worldY = 0,
    facing = "west",
  }, "west", { player = runtime.player, camera = {}, playerVisual = {}, residency = {} })
  Assert.deepEqual(travel:capture().dynamicWarp, {
    map = "MAP_CELADON_CONDOMINIUMS_1F",
    fieldX = 5,
    fieldZ = 7,
    warpId = 4,
    direction = "south",
  }, "the entrance position and the trigger-time facing become the saved dynamic destination")
  Assert.equal(runtime.runtimeMap, destination, "the entrance refresh never blocks the committed swap")
end

-- Only an arrival whose destination warp is itself the dynamic anchor
-- refreshes the record: every ordinary arrival keeps whatever the script set.
function T.ordinary_arrivals_retain_the_saved_dynamic_destination()
  local recorded = { map = "MAP_CELADON_CONDOMINIUMS_1F", fieldX = 5, fieldZ = 3, warpId = 2, direction = "east" }
  local travel = travelWith(nil)
  travel:setDynamicWarp(recorded)
  local source = mapDouble("MAP_CELADON_CONDOMINIUMS_2F", "building")
  local coordinator = setmetatable({}, FieldWorldSwapCoordinator)
  coordinator.runtime = runtimeDouble(source, travel, "south")
  coordinator:commit({
    sourceMap = source,
    sourceWarp = { index = 1, x = 6, z = 8, destinationMapId = 60, destinationWarpId = 0 },
    destinationMap = mapDouble("MAP_CELADON_DEPARTMENT_STORE_2F", "building"),
    destinationWarp = { index = 0, x = 6, z = 8, destinationMapId = 60, destinationWarpId = 0 },
    fieldX = 6,
    fieldZ = 8,
    surfaceId = 0,
    worldY = 0,
  }, "south", { player = {}, camera = {}, playerVisual = {}, residency = {} })
  Assert.deepEqual(travel:capture().dynamicWarp, recorded, "an ordinary arrival keeps the scripted destination")
  Assert.isNil(travel:capture().specialSpawn, "the entrance is not a special spawn")
end

-- The entrance refresh is the return destination the source establishes
-- unconditionally when the arrival anchor qualifies (FieldSystem_EnterLocation),
-- and the runtime always constructs FieldTravelState before field entry. A
-- missing travel owner is therefore a programming fault: the swap never
-- publishes an arrival that left no return destination.
function T.a_qualifying_dynamic_arrival_without_the_travel_owner_raises_and_never_swaps()
  local source = mapDouble("MAP_CELADON_CONDOMINIUMS_1F", "building")
  local destination = mapDouble("MAP_CELADON_DEPARTMENT_STORE_1F", "building")
  local coordinator = setmetatable({}, FieldWorldSwapCoordinator)
  local runtime = runtimeDouble(source, nil, "north")
  runtime.fieldTravel = nil
  coordinator.runtime = runtime
  local err = Assert.throws(function()
    coordinator:commit({
      sourceMap = source,
      sourceWarp = {
        index = 4,
        x = 5,
        z = 7,
        destinationMapId = 0xFFF,
        destinationWarpId = WarpSystem.DYNAMIC_WARP_SENTINEL,
      },
      destinationMap = destination,
      destinationWarp = {
        index = 0,
        x = 5,
        z = 3,
        destinationMapId = 0xFFF,
        destinationWarpId = WarpSystem.DYNAMIC_WARP_SENTINEL,
      },
      sourceFacing = "north",
      fieldX = 5,
      fieldZ = 3,
      surfaceId = 0,
      worldY = 0,
    }, "north", { player = runtime.player, camera = {}, playerVisual = {}, residency = {} })
  end)
  Assert.isTrue(
    type(err) == "string" and err:find("travel owner", 1, true) ~= nil,
    "the invariant failure names the missing travel owner, got " .. tostring(err)
  )
  Assert.equal(runtime.runtimeMap, source, "an incomplete dynamic entrance never swaps the map")
end

-- The transition start demands the saved destination map and pre-fades the
-- saved map's music: the anchor's own 0xFFF header names no map.
function T.transition_start_demands_the_saved_destination_map()
  local travel = travelWith(nil)
  travel:setDynamicWarp({
    map = "MAP_CELADON_CONDOMINIUMS_1F",
    fieldX = 5,
    fieldZ = 3,
    warpId = 2,
    direction = "west",
  })
  local source = mapDouble("MAP_CELADON_CONDOMINIUMS_1F", "building")
  local warpDemands, warpAudio = {}, {}
  local runtime = runtimeDouble(source, travel, "south")
  runtime.mapLoader = {
    requestWarp = function(_, demandSource, warp, dynamicWarp)
      warpDemands[#warpDemands + 1] = { sourceMap = demandSource, warp = warp, dynamicWarp = dynamicWarp }
      return true
    end,
  }
  runtime.audio = {
    beginWarp = function(_, destinationMap)
      warpAudio[#warpAudio + 1] = destinationMap
    end,
  }
  local coordinator = FieldWorldSwapCoordinator.new(runtime)
  local transition = coordinator:createTransition(runtime, nil, nil, function() end)
  runtime.transition = transition
  transition:start(source, dynamicAnchorTrigger(), "south")
  Assert.equal(#warpDemands, 1, "the transition start demands its destination once")
  Assert.equal(warpDemands[1].warp.index, 4)
  Assert.deepEqual(warpDemands[1].dynamicWarp, travel:dynamicWarp(), "the demand carries the saved destination")
  Assert.deepEqual(warpAudio, { "MAP_CELADON_CONDOMINIUMS_1F" }, "the saved map symbol pre-fades its music")
end
local function cacheFsWithDeathMaps(deathEntries, eligibleEntries)
  local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
  local blackoutSpawns = {}
  for spawnKey, map in pairs(deathEntries) do
    blackoutSpawns[spawnKey] = { map = map, fieldX = 8, fieldZ = 13, facing = "north" }
  end
  local deathWarpByMap = {}
  for spawnKey, map in pairs(eligibleEntries or deathEntries) do
    deathWarpByMap[map] = spawnKey
  end
  return {
    loadLua = function(_, path)
      assert(path == FieldMapDataCache.spawnIndexPath(), "blackout publication reads the spawn index")
      return {
        schema = FieldMapDataCache.SPAWN_INDEX_SCHEMA,
        spawns = { SPAWN_NEW_BARK = { map = "MAP_NEW_BARK", fieldX = 695, fieldZ = 397 } },
        blackoutSpawns = blackoutSpawns,
        specialSpawns = {
          SPAWN_NEW_BARK = { map = "MAP_NEW_BARK", fieldX = 695, fieldZ = 397, warpId = -1, direction = "south" },
        },
        deathWarpByMap = deathWarpByMap,
      }
    end,
  }
end

-- Blackout publication refreshes the heal spawn only on eligible death
-- interiors: a center entry records, routes and ineligible death maps
-- keep the recorded spawn, and the scripted Route 30 Cherrygrove spawn
-- survives outdoor travel until a center overwrites it.
function T.blackout_publication_refreshes_only_on_eligible_death_interiors()
  local eligible = {
    SPAWN_NEW_BARK = "MAP_NEW_BARK_PLAYER_HOUSE_1F",
    SPAWN_CHERRYGROVE = "MAP_CHERRYGROVE_POKECENTER_1F",
  }
  local function coordinatorWith(travel, sourceMap)
    local coordinator = setmetatable({}, FieldWorldSwapCoordinator)
    local runtime = runtimeDouble(sourceMap, travel)
    runtime.cacheFs = cacheFsWithDeathMaps(eligible)
    return coordinator, runtime
  end

  do
    local travel = travelWith(nil)
    local coordinator, runtime = coordinatorWith(travel, mapDouble("MAP_ROUTE_29", "outdoors"))
    coordinator:publishBlackoutSpawn(
      runtime,
      { destinationMap = mapDouble("MAP_CHERRYGROVE_POKECENTER_1F", "building") }
    )
    Assert.equal(travel:capture().lastHealSpawn, "SPAWN_CHERRYGROVE", "the center entry names its heal spawn")
  end

  do
    local travel = travelWith(nil)
    local coordinator, runtime = coordinatorWith(travel, mapDouble("MAP_CHERRYGROVE_POKECENTER_1F", "building"))
    coordinator:publishBlackoutSpawn(runtime, { destinationMap = mapDouble("MAP_ROUTE_29", "outdoors") })
    Assert.equal(
      travel:capture().lastHealSpawn,
      FieldTravelState.DEFAULT_LAST_HEAL_SPAWN,
      "a route entry keeps the recorded spawn"
    )
  end

  do
    -- The Route 30 Oak exception: ScrCmd_SetSpawn writes SPAWN_CHERRYGROVE
    -- while the player stands outdoors, so walking Routes 29-31 afterwards
    -- must keep it until a center entry overwrites it.
    local travel = travelWith(nil)
    travel:setLastHealSpawn("SPAWN_CHERRYGROVE")
    local coordinator, runtime = coordinatorWith(travel, mapDouble("MAP_ROUTE_30", "outdoors"))
    coordinator:publishBlackoutSpawn(runtime, { destinationMap = mapDouble("MAP_ROUTE_31", "outdoors") })
    Assert.equal(
      travel:capture().lastHealSpawn,
      "SPAWN_CHERRYGROVE",
      "outdoor travel after the scripted spawn keeps Cherrygrove"
    )
  end

  do
    -- Retail sSpawnMaps clears isBlackoutSpawn for the Cinnabar interior:
    -- whiteout still relocates there, but entry never refreshes the spawn.
    local travel = travelWith(nil)
    travel:setLastHealSpawn("SPAWN_CHERRYGROVE")
    local coordinator = setmetatable({}, FieldWorldSwapCoordinator)
    local runtime = runtimeDouble(mapDouble("MAP_CHERRYGROVE_POKECENTER_1F", "building"), travel)
    runtime.cacheFs = cacheFsWithDeathMaps({
      SPAWN_CHERRYGROVE = "MAP_CHERRYGROVE_POKECENTER_1F",
      SPAWN_CINNABAR = "MAP_CINNABAR_ISLAND_POKECENTER_1F",
    }, {
      SPAWN_CHERRYGROVE = "MAP_CHERRYGROVE_POKECENTER_1F",
    })
    coordinator:publishBlackoutSpawn(
      runtime,
      { destinationMap = mapDouble("MAP_CINNABAR_ISLAND_POKECENTER_1F", "building") }
    )
    Assert.equal(
      travel:capture().lastHealSpawn,
      "SPAWN_CHERRYGROVE",
      "an ineligible death entry keeps the recorded spawn"
    )
  end
end

-- The posed player the panel spin drives: the spin needs facing, a numeric
-- height, and the quarter-turn it applies.
local function posedPlayer(facing)
  return {
    facing = facing,
    worldY = 0,
    turn = function(self, direction)
      self.facing = direction
    end,
  }
end

-- A journey map: identity, origin, its warp events, and walkable ground over
-- the tile range the journey uses.
local function journeyMap(mapId, mapSymbol, origin, warps)
  return {
    mapId = mapId,
    mapSymbol = mapSymbol,
    coordinateOrigin = origin,
    fieldData = { events = { warps = warps } },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
    },
    terrain = TerrainSurface.new({
      plates = {
        {
          id = 0,
          minX = 0,
          minZ = 0,
          maxX = 32,
          maxZ = 32,
          normal = { x = 0, y = 1, z = 0 },
          distance = 0,
          slopeClass = "flat",
        },
      },
    }),
  }
end

-- The complete dynamic-anchor journey: a panel warp into a map whose own anchor
-- warp is 0x100 records the trigger-time entrance as the saved destination
-- while the departure spin turns the live player, and resolving that anchor
-- afterwards returns to the entrance tile facing the entrance direction.
function T.a_panel_warp_into_a_dynamic_anchor_records_the_entrance_and_returns_through_it()
  local entryWarp = {
    index = 1,
    x = 4,
    z = 14,
    destinationMapId = 0xFFF,
    destinationWarpId = WarpSystem.DYNAMIC_WARP_SENTINEL,
    y = 0,
  }
  local anchorWarp = {
    index = 0,
    x = 700,
    z = 400,
    destinationMapId = 0xFFF,
    destinationWarpId = WarpSystem.DYNAMIC_WARP_SENTINEL,
    y = 0,
  }
  local source = journeyMap(61, "MAP_CELADON_CONDOMINIUMS_2F", { x = 0, z = 0 }, {
    { index = 0, x = 16, z = 16, destinationMapId = 0xFFF, destinationWarpId = 0, y = 0 },
    entryWarp,
  })
  local destination = journeyMap(60, "MAP_CELADON_CONDOMINIUMS_1F", { x = 672, z = 384 }, { anchorWarp })
  local maps = { [source.mapSymbol] = source, [destination.mapSymbol] = destination }
  local loader = {
    load = function(_, requested)
      return assert(maps[requested], "unknown journey map " .. tostring(requested))
    end,
    requestWarp = function()
      return true
    end,
  }
  -- The destination the anchor already pointed at before this trip.
  local travel = travelWith(nil)
  travel:setDynamicWarp({ map = destination.mapSymbol, fieldX = 5, fieldZ = 3, warpId = 0, direction = "west" })
  local runtime = { fieldTravel = travel }
  local coordinator = FieldWorldSwapCoordinator.new(runtime)
  local entryFacing = "north"
  local player = posedPlayer(entryFacing)
  local commits = {}
  local transition
  transition = FieldTransition.new({
    loader = loader,
    player = player,
    resolveDestination = WarpSystem.resolveDestination,
    dynamicWarp = function()
      return travel:dynamicWarp()
    end,
    prepare = function(resolution, facing)
      return { player = posedPlayer(facing), fieldX = resolution.fieldX, fieldZ = resolution.fieldZ }
    end,
    commit = function(resolution, facing, prepared)
      commits[#commits + 1] = { facing = facing, spunFacing = player.facing, sourceFacing = resolution.sourceFacing }
      coordinator:publishDynamicWarpEntrance(runtime, resolution)
      transition.player = prepared.player
    end,
  })
  transition:start(source, { warp = entryWarp }, entryFacing)
  local ticks = 0
  while transition.phase ~= "idle" and ticks < 200 do
    transition:updateFixed()
    transition:updateSourceFrame()
    ticks = ticks + 1
  end
  Assert.equal(transition.phase, "idle", "the panel journey completes")
  Assert.equal(#commits, 1, "the journey commits its single destination")
  Assert.equal(commits[1].sourceFacing, entryFacing, "the resolution keeps the trigger-time source facing")
  Assert.equal(commits[1].spunFacing, "east", "the departure spin turned the live player away from the entry facing")
  Assert.equal(commits[1].facing, "west", "the arrival uses the saved destination direction")
  local saved = travel:dynamicWarp()
  Assert.deepEqual(saved, {
    map = source.mapSymbol,
    fieldX = entryWarp.x,
    fieldZ = entryWarp.z,
    warpId = entryWarp.index,
    direction = entryFacing,
  }, "the arrival records the entrance tile and the trigger-time entrance facing after the spins")
  local returned = WarpSystem.resolveDestination(loader, destination, anchorWarp, saved)
  Assert.equal(returned.facing, saved.direction, "the return arrival faces the recorded entrance direction")
  Assert.equal(returned.fieldX, entryWarp.x, "the return arrival lands on the saved warp record tile")
  Assert.equal(returned.fieldZ, entryWarp.z, "the return arrival lands on the saved warp record tile")
end

return { tests = T }
