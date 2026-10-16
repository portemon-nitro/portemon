-- Panel-warp spin/teleport presentation contract (retail Task_WarpPanel in
-- pret/pokeheartgold src/field_warp_tasks.c with the Task_WarpSpinDeparture /
-- Task_WarpSpinArrival pair in src/field/warp_spin.c, via
-- FieldSystem_StartWarpSpin): the MODE_PANEL path must run a 20-frame
-- departure spin -- SEQ_SE_DP_TELE2 once at spin start, a quarter-turn
-- counterclockwise rotation on each odd frame, a rising height arc -- gate the
-- map swap on spin completion, then run the reversed arrival spin and face
-- south exactly once. The follower departure recall and the arrival
-- MoveToPlayer + release-ball-pending rejoin travel through the transition's
-- optional follower collaborator (the selectPreview injection pattern); the
-- ball rendering itself stays a documented boundary until the ball-effect
-- presentation exists, so these tests pin hook invocation only, never pixels.

local Assert = require("tests.support.Assert")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
local FieldTransitionProfile = require("libs.hgss.src.transition.FieldTransitionProfile")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local T = {}

-- Retail WARP_SPIN_FRAMES: the departure spin runs 20 frames and the arrival
-- reverses them (src/field/warp_spin.c).
local SPIN_FRAMES = 20

local function terrain()
  return TerrainSurface.new({
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
  })
end

local function runtimeMap(mapId)
  return {
    mapId = mapId,
    mapSection = "test-section",
    mapSectionNativeId = 7,
    followMode = "ALLOW",
    coordinateOrigin = { x = 0, z = 0 },
    scene = {},
    fieldData = { events = { objects = {}, background = {}, warps = {}, coordinates = {} } },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function()
        return false
      end,
      getLocal = function()
        return { blocked = false, behavior = 0 }
      end,
    },
    terrain = terrain(),
    terrainDependencyHash = "test-terrain",
    fieldRegion = {},
    cameraType = 0,
    mapSymbol = "test-map",
    release = function() end,
    updateAnimated = function() end,
  }
end

local function spinWorld(options)
  options = options or {}
  local source = runtimeMap(61)
  local destination = runtimeMap(60)
  local maps = { [61] = source, [60] = destination }
  local player = FieldPlayer.new({
    currentMap = source,
    fieldX = 5,
    fieldZ = 5,
    surfaceId = 0,
    facing = options.facing or "north",
  })
  local groundY = player.worldY
  local sounds = {}
  local panels = {}
  local commits = 0
  local facings = {}
  local heights = {}
  local followerCalls = {}
  local follower = nil
  if options.follower ~= false then
    local present = options.followerPresent
    if present == nil then
      present = true
    end
    follower = {
      isPresent = function()
        return present
      end,
      recall = function()
        followerCalls[#followerCalls + 1] = "recall"
      end,
      rejoin = function(reason)
        followerCalls[#followerCalls + 1] = "rejoin:" .. tostring(reason)
      end,
    }
  end
  local transition
  transition = FieldTransition.new({
    loader = {
      load = function(_, mapId)
        return assert(maps[mapId], "map " .. tostring(mapId))
      end,
      requestWarp = function()
        return true
      end,
      protectMap = function() end,
    },
    player = player,
    follower = follower,
    playSound = function(sound)
      sounds[#sounds + 1] = sound
    end,
    stopSound = function(sound)
      sounds[#sounds + 1] = "stop:" .. sound
    end,
    onPanel = function(phase)
      panels[#panels + 1] = phase
    end,
    prepare = function(resolution, facing)
      return FieldPlayer.new({
        currentMap = resolution.destinationMap,
        fieldX = resolution.fieldX,
        fieldZ = resolution.fieldZ,
        surfaceId = resolution.surfaceId,
        facing = facing,
      })
    end,
    commit = function(_, _, prepared)
      commits = commits + 1
      player = prepared
      transition.player = player
    end,
    resolveDestination = function()
      return {
        destinationMap = destination,
        destinationWarp = { x = 6, z = 6 },
        fieldX = 6,
        fieldZ = 6,
        surfaceId = 0,
        worldY = groundY,
      }
    end,
  })
  transition.player = player
  return {
    transition = transition,
    sounds = sounds,
    panels = panels,
    facings = facings,
    heights = heights,
    followerCalls = followerCalls,
    groundY = groundY,
    getCommits = function()
      return commits
    end,
    getPlayer = function()
      return player
    end,
  }
end

local function startPanelWarp(world)
  world.transition:start({ mapId = 61 }, {
    kind = "generic",
    warp = { index = 0, x = 5, z = 5, destinationMapId = 60, destinationWarpId = 0 },
    transition = FieldTransitionProfile.mode(FieldTransitionProfile.MODE_PANEL),
  }, world.transition.player.facing)
end

-- Drive the full panel warp, sampling the player pose every tick on both
-- sides of the single commit.
local function drivePanelWarp(world, maxTicks)
  startPanelWarp(world)
  local commitTick = nil
  local swapFacings = {}
  local tick = 0
  while world.transition.phase ~= "idle" and world.transition.phase ~= "error" and tick < (maxTicks or 400) do
    tick = tick + 1
    world.transition:updateFixed()
    world.transition:updateSourceFrame()
    local player = world.getPlayer()
    if world.getCommits() == 0 then
      world.facings[#world.facings + 1] = player.facing
      world.heights[#world.heights + 1] = player.worldY - world.groundY
    else
      if commitTick == nil then
        commitTick = tick
      end
      swapFacings[#swapFacings + 1] = player.facing
      world.heights[#world.heights + 1] = player.worldY - world.groundY
    end
  end
  return { ticks = tick, commitTick = commitTick, arrivalFacings = swapFacings }
end

local function distinctInOrder(values)
  local out = {}
  for _, value in ipairs(values) do
    if out[#out] ~= value then
      out[#out + 1] = value
    end
  end
  return out
end

function T.panel_departure_runs_the_twenty_frame_teleport_spin_before_the_swap()
  local world = spinWorld({ facing = "north", follower = false })
  local run = drivePanelWarp(world)

  Assert.equal(world.transition.phase, "idle", "the panel warp completes")
  Assert.equal(world.getCommits(), 1, "the panel warp commits the shared destination once")
  Assert.notNil(run.commitTick, "the run records the commit tick")
  Assert.isTrue(
    run.commitTick >= SPIN_FRAMES,
    "the departure spin runs its 20 retail frames before the swap gates (committed at tick "
      .. tostring(run.commitTick)
      .. ")"
  )

  local teleports = 0
  for _, sound in ipairs(world.sounds) do
    if sound == "SEQ_SE_DP_TELE2" then
      teleports = teleports + 1
    end
  end
  Assert.isTrue(teleports >= 1, "the departure spin plays the teleport sound at spin start")

  Assert.deepEqual(
    distinctInOrder(world.facings),
    { "north", "west", "south", "east" },
    "the departure rotates a quarter turn counterclockwise per spin beat"
  )

  local peak = 0
  for _, height in ipairs(world.heights) do
    peak = math.max(peak, height)
  end
  Assert.isTrue(peak > 0, "the departure spin rises on the quadratic height arc before the swap")
end

function T.panel_arrival_reverses_the_spin_and_faces_south_once()
  local world = spinWorld({ facing = "north", follower = false })
  local run = drivePanelWarp(world)

  Assert.equal(world.transition.phase, "idle", "the panel warp completes")
  Assert.isTrue(
    run.ticks - (run.commitTick or 0) >= SPIN_FRAMES,
    "the arrival spin reverses its 20 frames after the swap before completing"
  )
  Assert.equal(world.getPlayer().facing, "south", "the arrival faces south exactly once at spin end")

  local peak = 0
  for index, height in ipairs(world.heights) do
    if index > #world.facings then
      peak = math.max(peak, height)
    end
  end
  Assert.isTrue(peak > 0, "the arrival descends from the reversed height arc")
  local lastHeight = world.heights[#world.heights]
  Assert.isTrue(math.abs(lastHeight) < 1e-9, "the arrival lands back on the destination ground plane, it never hovers")
end

function T.panel_warp_keeps_the_single_panel_lifecycle_around_the_spin()
  local world = spinWorld({ facing = "south", follower = false })
  drivePanelWarp(world)

  Assert.equal(world.transition.phase, "idle", "the panel warp completes")
  Assert.deepEqual(world.panels, { "exit", "enter" }, "each panel side is still notified exactly once")
  Assert.equal(world.getCommits(), 1, "the spin never duplicates the shared destination commit")
  Assert.notNil(world.transition.completed, "the panel warp records one completion")
end

function T.panel_spin_recalls_and_rejoins_the_follower_through_the_collaborator()
  local world = spinWorld({ facing = "north", followerPresent = true })
  local run = drivePanelWarp(world)

  Assert.equal(world.transition.phase, "idle", "the panel warp completes")
  local recalls, rejoins = 0, 0
  for _, call in ipairs(world.followerCalls) do
    if call == "recall" then
      recalls = recalls + 1
    elseif call == "rejoin:panel" then
      rejoins = rejoins + 1
    end
  end
  Assert.equal(recalls, 1, "the departure recalls the follower into its ball exactly once before the swap")
  Assert.equal(rejoins, 1, "the arrival rejoins the follower onto the player exactly once")
  Assert.isTrue(
    (run.commitTick or 0) > 0 and #world.followerCalls == 2,
    "recall precedes the swap and the panel rejoin follows it"
  )
end

function T.panel_spin_never_touches_an_absent_follower()
  local world = spinWorld({ facing = "north", follower = false })
  drivePanelWarp(world)

  Assert.equal(world.transition.phase, "idle", "the panel warp completes without a follower")
  Assert.deepEqual(world.followerCalls, {}, "no follower collaborator means no recall and no rejoin")
end

function T.panel_spin_skips_recall_and_rejoin_without_a_present_partner()
  local world = spinWorld({ facing = "north", followerPresent = false })
  drivePanelWarp(world)

  Assert.equal(world.transition.phase, "idle", "the panel warp completes")
  Assert.deepEqual(world.followerCalls, {}, "the readiness gate skips recall and rejoin with no partner present")
end

return { tests = T }
