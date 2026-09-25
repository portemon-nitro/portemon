-- Production-composed water and climb traversal: real Surf physics through
-- the composed field runtime, task, world, player, and terrain owners on
-- ROM-backed New Bark water, plus pure-case falls/climb/connection-failure
-- coverage through the same real collaborators with small explicit
-- synthetic terrain plates (no waterfall/climb geography is reachable from
-- the harness boot map). Stops before GPU rendering like every acceptance
-- path. Production menu/party composition is out of scope here: surf admission is
-- driven through the real eligibility policy and runtime queue with a
-- context assembled from live production reads, which is exactly the
-- boundary the field execution owners consume. Follower reconciliation
-- rides the untouched existing owners (followMode policy, revision replay,
-- audio update on committed steps); no follower is active on a fresh boot,
-- and follower behavior itself is owned by the existing following-mon
-- suites this change does not touch.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local RomFs = require("romdump.src.source.RomFs")
local NavigationFacts = require("tests.rom.support.NavigationFacts")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")
local FieldMovePolicy = require("libs.hgss.src.field.FieldMovePolicy")
local FieldMoveRuntime = require("libs.hgss.src.field.FieldMoveRuntime")
local FieldMoveWorld = require("game.hgss.src.field.FieldMoveWorld")
local FieldMoveTask = require("libs.hgss.src.script.tasks.FieldMoveTask")
local PlayerProgression = require("libs.hgss.src.save.PlayerProgression")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

-- Structural port for the traversal runtime under test: names exactly the
-- exercised boundary so helper-built subjects resolve their methods.
---@class TraversalRuntimePort
---@field queue fun(self: TraversalRuntimePort, request: table<string, unknown>): table<string, unknown>
---@field takePending fun(self: TraversalRuntimePort): table<string, unknown>
---@field plan fun(self: TraversalRuntimePort, request: table<string, unknown>): table<string, unknown>
---@field isBusy fun(self: TraversalRuntimePort): boolean

local T = {
  metadata = { capabilities = { "rom_dump", "derived_cache" }, tags = { "field", "traversal", "surf" } },
  tests = {},
}

local DELTAS = {
  north = { x = 0, z = -1 },
  south = { x = 0, z = 1 },
  west = { x = -1, z = 0 },
  east = { x = 1, z = 0 },
}

local OPPOSITE = { north = "south", south = "north", west = "east", east = "west" }

local function freezeAutonomousActors(game)
  local runtime = game.runtime
  for mapId in pairs(runtime.actors.maps) do
    for _, actor in ipairs(runtime.actors:actorsOf(mapId)) do
      runtime.actors:setMovementType(actor.actorId, "stationary")
    end
  end
end

-- Player port over the live owners: every method forwards to production
-- state. This adapter is the only test-only glue in these scenarios; it
-- fakes nothing.
local function livePlayerPort(game)
  local runtime = game.runtime
  local player = assert(runtime.player, "live player required")
  local avatar = assert(runtime.playerAvatar, "live avatar transition owner required")
  local port = {}
  function port:position()
    return { fieldX = player.fieldX, fieldZ = player.fieldZ, worldY = player.worldY }
  end
  function port:facing()
    return player.facing
  end
  function port:beginScriptedAction(action)
    return player:beginScriptedAction(action)
  end
  function port:advanceScriptedAction(progress, duration)
    return player:advanceScriptedAction(progress, duration)
  end
  function port:commitScriptedAction()
    return player:commitScriptedAction()
  end
  function port:cancelScriptedMovement()
    return player:cancelScriptedMovement()
  end
  function port:isScriptedMoving()
    return player:isScriptedMoving()
  end
  function port:queueAvatarTransition(name)
    return avatar:queueTransition(name)
  end
  function port:applyAvatarTransitions()
    return runtime:applyAvatarTransitions()
  end
  return port
end

local function liveWorld(game)
  local runtime = game.runtime
  return FieldMoveWorld.new({
    actors = assert(runtime.actors, "live actor manager required"),
    events = assert(runtime.eventState, "live event state required"),
    maps = {
      current = function()
        local map = runtime.runtimeMap
        return { symbol = map.mapSymbol, id = map.mapId, fieldUse = map.fieldData.fieldUse }
      end,
      runtimeMap = function()
        return runtime.runtimeMap
      end,
    },
    player = livePlayerPort(game),
    profile = assert(runtime.playerData and runtime.playerData.profile, "live profile required"),
    weather = {
      change = function(_, _)
        error("surf acceptance covers no weather change", 2)
      end,
    },
    reactions = {
      dispatch = function(_, _)
        error("surf acceptance covers no reaction dispatch", 2)
      end,
    },
  })
end

local function awardBadge(game, key)
  local profile = assert(game.runtime.playerData and game.runtime.playerData.profile, "live profile required")
  PlayerProgression.new(profile):awardBadge(key)
  Assert.isTrue(PlayerProgression.new(profile):hasBadge(key), "badge award must persist on the live profile")
end

local function avatarMode(game)
  return game.runtime.playerAvatar:status().durableState
end

-- Facing-tile behavior through the live collision owner, mirroring the
-- production step query without duplicating its rule.
local function facingBehavior(game)
  local runtime = game.runtime
  local player = runtime.player
  local delta = assert(DELTAS[player.facing], "live facing required")
  local map = runtime.runtimeMap
  local localX, localZ = FieldCoordinates.fieldToLocal(map, player.fieldX + delta.x, player.fieldZ + delta.z)
  local cell = map.collision:getLocal(localX, localZ)
  return cell and cell.behavior
end

local function surfContext(game)
  local runtime = game.runtime
  local profile = assert(runtime.playerData and runtime.playerData.profile, "live profile required")
  return {
    badges = assert(profile.badges, "live badge mask required"),
    mapSymbol = runtime.runtimeMap.mapSymbol,
    mapId = runtime.runtimeMap.mapId,
    fieldUse = runtime.runtimeMap.fieldData.fieldUse,
    avatarMode = avatarMode(game),
    humanFollower = false,
    followingMon = false,
    rocketCostume = false,
    safari = false,
    palPark = false,
    surfEdge = MetatileBehavior.isSurfableWater(facingBehavior(game)),
    facingWaterfall = false,
    facingWhirlpool = false,
    climbTile = false,
    headbuttTree = false,
    foggy = false,
    chatterOpen = false,
  }
end

local function withGame(fn)
  local harness = AcceptanceHarness.new()
  local versionId = AcceptanceHarness.defaultVersion()
  local romFs, err = RomFs.open(versionId)
  assert(romFs, tostring(err))
  local facts = NavigationFacts.discover(CacheFs.forVersion(versionId), romFs)
  romFs:close()
  local game = harness:boot({ versionId = versionId, map = "MAP_NEW_BARK", save = "fresh" })
  OpeningLifecycle.seedNewBarkWestExitScene(game)
  OpeningLifecycle.settleNewBarkFriendScene(game)
  freezeAutonomousActors(game)
  local ok, failure = xpcall(function()
    fn(game, facts)
    Assert.equal(game:renderAttempts(), 0, "traversal acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(failure, 0)
  end
end

local function moveTo(game, point)
  return game:moveTo({ fieldX = point.fieldX, fieldZ = point.fieldZ })
end

local function driveTask(game, runtime, state)
  local ctx = { services = { fieldMoves = runtime } }
  local result = nil
  game:advanceUntil("field task settles", function()
    local outcome = FieldMoveTask.poll(state, ctx)
    if outcome.complete then
      result = outcome.result
      return true
    end
    game:step()
    return false
  end, 600)
  return assert(result, "field task must report a result")
end

local function runSurfPlan(game, runtime, context)
  local queued = runtime:queue({ move = "surf", slot = 0, context = context })
  Assert.equal(queued.kind, "accepted", "surf admission must accept at a valid shore")
  local state = FieldMoveTask.create({ source = "pending" }, { services = { fieldMoves = runtime } })
  Assert.isNil(state.refused, "surf planning must produce an executable plan")
  local result = driveTask(game, runtime, state)
  Assert.equal(result.kind, "field_move_done", "surf entry must run to done")
end

-- Shore exit is session-arbitrated in production (the live boot session has
-- no field port of its own yet), so acceptance performs the
-- arbitration role explicitly: face the shore, request the planned
-- disembark, claim the entry script exactly as the session would, and run
-- the real task to done.
local function runDisembarkPlan(game, runtime)
  local player = game.runtime.player
  Assert.equal(player.motion, "idle", "disembark arbitration needs an idle player")
  local requested = runtime:requestDisembark({ mapId = game.runtime.runtimeMap.mapId })
  Assert.equal(requested.kind, "accepted", "disembark admission must accept facing a valid shore")
  local state = FieldMoveTask.create({ source = "pending" }, { services = { fieldMoves = runtime } })
  Assert.isNil(state.refused, "disembark planning must produce an executable plan")
  local result = driveTask(game, runtime, state)
  Assert.equal(result.kind, "field_move_done", "disembark must run to done")
end

function T.tests.surf_swims_and_disembarks_with_real_physics()
  withGame(function(game, facts)
    awardBadge(game, "fog")
    moveTo(game, facts.water.approach)
    game:face(facts.water.direction)
    Assert.equal(avatarMode(game), "walking", "shore approach starts walking")
    local context = surfContext(game)
    Assert.isTrue(context.surfEdge, "facing tile must be surfable water")
    local runtime = FieldMoveRuntime.new({
      policy = FieldMovePolicy,
      context = context,
      world = liveWorld(game),
    }) --[[@as TraversalRuntimePort]]
    runSurfPlan(game, runtime, context)
    local water = facts.water
    local settled = game:snapshot()
    Assert.equal(settled.player.fieldX, water.fieldX, "surf entry must commit the water tile")
    Assert.equal(settled.player.fieldZ, water.fieldZ, "surf entry must commit the water tile")
    Assert.equal(settled.player.motion, "idle", "surf entry must settle")
    Assert.equal(avatarMode(game), "surfing", "avatar must reconcile to surfing once")
    -- Ordinary water traversal while surfing: a real committed step, not an
    -- avatar swap. Step onward and prove the tile changed with valid
    -- collision and height.
    local before = game:snapshot().player
    game:move(water.direction)
    local swimming = game:advanceUntil("swim step settles", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 120)
    local moved = swimming.player.fieldX ~= before.fieldX or swimming.player.fieldZ ~= before.fieldZ
    Assert.isTrue(moved, "surfing must traverse water with real steps")
    Assert.equal(avatarMode(game), "surfing", "swimming must not disturb the avatar")
    -- Swim back to the entry tile (shore tiles are not routable while
    -- surfing: leaving the water takes the planned transition, not a
    -- step), then out through the planned disembark.
    game:moveTo({ fieldX = water.fieldX, fieldZ = water.fieldZ })
    local back = game:snapshot()
    Assert.equal(back.player.fieldX, water.fieldX, "return swim must commit the entry tile")
    Assert.equal(back.player.fieldZ, water.fieldZ, "return swim must commit the entry tile")
    game:face(OPPOSITE[water.direction])
    runDisembarkPlan(game, runtime)
    local ashore = game:snapshot()
    Assert.equal(ashore.player.motion, "idle", "disembark must settle")
    Assert.equal(ashore.player.fieldX, water.approach.fieldX, "disembark must commit the shore tile")
    Assert.equal(ashore.player.fieldZ, water.approach.fieldZ, "disembark must commit the shore tile")
    Assert.equal(avatarMode(game), "walking", "walking permissions must return on shore")
    -- Walking into water is a field action again, never a step: the
    -- position must not change.
    game:face(water.direction)
    game:move(water.direction)
    game:advanceUntil("shore step settles", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 120)
    local stayed = game:snapshot()
    Assert.equal(stayed.player.fieldX, ashore.player.fieldX, "walking must not step into water")
    Assert.equal(stayed.player.fieldZ, ashore.player.fieldZ, "walking must not step into water")
  end)
end

function T.tests.settled_water_save_restores_usable_surf()
  withGame(function(game, facts)
    awardBadge(game, "fog")
    moveTo(game, facts.water.approach)
    game:face(facts.water.direction)
    local context = surfContext(game)
    local runtime = FieldMoveRuntime.new({
      policy = FieldMovePolicy,
      context = context,
      world = liveWorld(game),
    }) --[[@as TraversalRuntimePort]]
    runSurfPlan(game, runtime, context)
    local water = facts.water
    -- Saves during active motion are denied by the existing motion gate:
    -- begin a scripted motion step, then capture must refuse while live.
    game:face(OPPOSITE[water.direction])
    game.runtime.player:beginScriptedAction({ action = "walk", direction = OPPOSITE[water.direction], speed = "normal" })
    Assert.isNil(game.runtime:captureGameSave(), "save during live motion must be denied")
    game.runtime.player:cancelScriptedMovement()
    game:save()
    game:restart()
    local reloaded = game:snapshot()
    Assert.equal(reloaded.player.fieldX, water.fieldX, "reload must restore the water tile")
    Assert.equal(reloaded.player.fieldZ, water.fieldZ, "reload must restore the water tile")
    Assert.equal(avatarMode(game), "surfing", "reload must restore the surfing mode")
    game:face(water.direction)
    game:move(water.direction)
    game:advanceUntil("post-reload swim settles", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 120)
    -- Reload rebuilds the whole composition: plan the disembark through a
    -- runtime and world bound to the fresh owners, like production does.
    local fresh = FieldMoveRuntime.new({
      policy = FieldMovePolicy,
      context = surfContext(game),
      world = liveWorld(game),
    }) --[[@as TraversalRuntimePort]]
    game:moveTo({ fieldX = water.fieldX, fieldZ = water.fieldZ })
    game:face(OPPOSITE[water.direction])
    runDisembarkPlan(game, fresh)
    Assert.equal(avatarMode(game), "walking", "post-reload disembark must restore walking")
  end)
end

-- Pure-case rig below: the real scheduler task, runtime, world, player,
-- resolver, and policy over small explicit asymmetric terrain plates. Only
-- the terrain/collision geography is synthetic; no production algorithm is
-- duplicated.

local function plateTerrain(plates)
  return TerrainSurface.new({ plates = plates })
end

local function flatPlate(id, minX, minZ, maxX, maxZ, height)
  return {
    id = id,
    minX = minX,
    minZ = minZ,
    maxX = maxX,
    maxZ = maxZ,
    normal = { x = 0, y = 1, z = 0 },
    distance = height or 0,
    slopeClass = "flat",
  }
end

local function rigMap(behaviorAt, plates)
  local terrain = plateTerrain(plates)
  return {
    mapId = 61,
    mapSymbol = "test-water",
    mapSection = "test-section",
    mapSectionNativeId = 7,
    followMode = "ALLOW",
    coordinateOrigin = { x = 0, z = 0 },
    scene = {},
    fieldData = {},
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function()
        return false
      end,
      getLocal = function(_, x, z)
        return { blocked = false, behavior = behaviorAt[x .. ":" .. z] }
      end,
    },
    terrain = terrain,
    terrainDependencyHash = "test-terrain",
    fieldRegion = {},
    cameraType = 0,
    release = function() end,
    updateAnimated = function() end,
  }
end

local function rigPlayer(map, fieldX, fieldZ, surfaceId)
  local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
  return FieldPlayer.new({
    currentMap = map,
    fieldX = fieldX,
    fieldZ = fieldZ,
    surfaceId = surfaceId,
    facing = "south",
  })
end

local function rigAvatar(mode)
  local FieldPlayerAvatarState = require("libs.hgss.src.actors.FieldPlayerAvatarState")
  local states = {}
  for _, name in ipairs({
    "walking",
    "cycling",
    "surfing",
    "watering",
    "fishing",
    "poketch",
    "saving",
    "heal",
    "ladder",
    "rocket",
    "rocket_heal",
    "pokeathlon",
    "apricorn_shake",
    "rocket_saving",
  }) do
    states[name] = 10
  end
  local offsets = { x = 0, y = 0, z = 0 }
  return FieldPlayerAvatarState.new({
    capability = { id = "rig", gender = 0, states = states },
    surfPresentation = {
      initialPlayerOffset = offsets,
      playerBaseOffset = offsets,
      attachmentBaseOffset = offsets,
      oscillator = { initialY = 0, minY = -1, maxY = 1, stepY = 0.5 },
      yawDegrees = { north = 0, south = 180, west = 90, east = 270 },
    },
    initialState = mode,
  })
end

local function rigWorld(player, avatar, map, applied)
  local FieldEventState = require("libs.hgss.src.field.FieldEventState")
  local events = FieldEventState.new()
  local world = FieldMoveWorld.new({
    actors = {
      getActor = function()
        return nil
      end,
      actorsOf = function()
        return {}
      end,
      getPosition = function()
        return nil
      end,
      getCollisionAt = function()
        return nil
      end,
      beginScriptedAction = function() end,
      advanceScriptedAction = function() end,
      commitScriptedAction = function() end,
      cancelScriptedMovement = function() end,
      isScriptedMoving = function()
        return false
      end,
      removePresence = function()
        error("pure traversal rig covers no presence removal", 2)
      end,
      syncEventStateChanges = function() end,
    },
    events = events,
    maps = {
      current = function()
        return { symbol = "test-water", id = 61, fieldUse = {} }
      end,
      runtimeMap = function()
        return map
      end,
    },
    player = {
      position = function()
        return { fieldX = player.fieldX, fieldZ = player.fieldZ, worldY = player.worldY }
      end,
      facing = function()
        return player.facing
      end,
      beginScriptedAction = function(_, action)
        return player:beginScriptedAction(action)
      end,
      advanceScriptedAction = function(_, progress, duration)
        return player:advanceScriptedAction(progress, duration)
      end,
      commitScriptedAction = function()
        return player:commitScriptedAction()
      end,
      cancelScriptedMovement = function()
        return player:cancelScriptedMovement()
      end,
      isScriptedMoving = function()
        return player:isScriptedMoving()
      end,
      queueAvatarTransition = function(_, name)
        return avatar:queueTransition(name)
      end,
      applyAvatarTransitions = function()
        applied.count = applied.count + 1
        return avatar:applyTransitions()
      end,
    },
    profile = { badges = 0xFFFF },
    weather = {
      change = function()
        error("pure traversal rig covers no weather change", 2)
      end,
    },
    reactions = {
      dispatch = function()
        error("pure traversal rig covers no reaction dispatch", 2)
      end,
    },
  })
  return world, events
end

local function rigContext(overrides)
  local context = {
    badges = 0xFFFF,
    mapSymbol = "test-water",
    mapId = 61,
    fieldUse = {},
    avatarMode = "surfing",
    humanFollower = false,
    followingMon = false,
    rocketCostume = false,
    safari = false,
    palPark = false,
    surfEdge = false,
    facingWaterfall = false,
    facingWhirlpool = false,
    climbTile = false,
    headbuttTree = false,
    foggy = false,
    chatterOpen = false,
  }
  for key, value in pairs(overrides or {}) do
    context[key] = value
  end
  return context
end

local function driveToDone(runtime, player, maxTicks)
  local ctx = { services = { fieldMoves = runtime } }
  local state = FieldMoveTask.create({ source = "pending" }, ctx)
  Assert.isNil(state.refused, "traversal planning must produce an executable plan")
  for _ = 1, maxTicks or 600 do
    local outcome = FieldMoveTask.poll(state, ctx)
    if outcome.complete then
      return outcome.result
    end
    player:updateFixed({})
  end
  error("traversal task did not settle", 2)
end

-- Waterfall column at x=5 (tiles z=3..5) draining south into a pool:
-- approach ledge at z=2 rides high ground, the pool sits at height 0.
local function waterfallRig()
  local behaviorAt = {}
  for z = 3, 5 do
    behaviorAt["5:" .. z] = 19
  end
  behaviorAt["5:6"] = 21
  local map = rigMap(behaviorAt, {
    flatPlate(0, 0, 0, 32, 3, 4),
    flatPlate(1, 0, 3, 32, 6, 2),
    flatPlate(2, 0, 6, 32, 32, 0),
  })
  local player = rigPlayer(map, 5, 2, 0)
  player:turn("south")
  local avatar = rigAvatar("surfing")
  local applied = { count = 0 }
  local world, _ = rigWorld(player, avatar, map, applied)
  local runtime = FieldMoveRuntime.new({ policy = FieldMovePolicy, context = rigContext(), world = world }) --[[@as TraversalRuntimePort]]
  return {
    map = map,
    player = player,
    avatar = avatar,
    world = world,
    runtime = runtime,
    applied = applied,
    behaviorAt = behaviorAt,
  }
end

function T.tests.waterfall_uses_a_contiguous_validated_path()
  local rig = waterfallRig()
  local queued = rig.runtime:queue({ move = "waterfall", slot = 0, context = rigContext({ facingWaterfall = true }) })
  Assert.equal(queued.kind, "accepted", "waterfall admission must accept facing falls while surfing")
  local result = driveToDone(rig.runtime, rig.player)
  Assert.equal(result.kind, "field_move_done", "a valid falls route must run to done")
  Assert.equal(rig.player.fieldX, 5, "falls route must keep its column")
  Assert.equal(rig.player.fieldZ, 6, "falls route must land on the exact terminal pool tile")
  Assert.equal(rig.player.worldY, 0, "falls landing height must come from terrain, never a constant")
  Assert.equal(rig.avatar:status().durableState, "surfing", "falls travel must stay surfing")
end

function T.tests.broken_falls_begin_no_motion_and_guess_no_height()
  local rig = waterfallRig()
  local queued = rig.runtime:queue({ move = "waterfall", slot = 0, context = rigContext({ facingWaterfall = true }) })
  Assert.equal(queued.kind, "accepted", "admission checks facing, not the full route")
  -- Corrupt only the terminal pool tile into unwalkable blockage: the
  -- falls column itself stays intact, but the route has no validated
  -- landing, so planning must refuse before any motion.
  local fallsBehaviors = rig.behaviorAt
  rig.map.collision.getLocal = function(_, x, z)
    if x == 5 and z == 6 then
      return { blocked = true }
    end
    return { blocked = false, behavior = fallsBehaviors[x .. ":" .. z] }
  end
  local request = rig.runtime:takePending()
  local plan = rig.runtime:plan(request)
  Assert.equal(plan.kind, "not_here", "a falls route without a validated landing must refuse")
  Assert.isFalse(rig.player:isScriptedMoving(), "a refused route must begin no motion")
  Assert.isFalse(rig.runtime:isBusy(), "a refused plan must release the runtime")
end

function T.tests.rock_climb_honors_orientation_and_landing()
  -- East-facing climb wall at (5,3) with a walkable landing at (6,3)
  -- resolved at height 2 from terrain.
  local behaviorAt = { ["5:3"] = 76 }
  local map = rigMap(behaviorAt, {
    flatPlate(0, 0, 0, 32, 32, 0),
    flatPlate(1, 6, 3, 7, 4, 2),
  })
  local player = rigPlayer(map, 4, 3, 0)
  player:turn("east")
  local avatar = rigAvatar("walking")
  local applied = { count = 0 }
  local world, _ = rigWorld(player, avatar, map, applied)
  local context = rigContext({ avatarMode = "walking" })
  local runtime = FieldMoveRuntime.new({ policy = FieldMovePolicy, context = context, world = world }) --[[@as TraversalRuntimePort]]
  local queued =
    runtime:queue({ move = "rock_climb", slot = 0, context = rigContext({ avatarMode = "walking", climbTile = true }) })
  Assert.equal(queued.kind, "accepted", "climb admission must accept a faced wall while walking")
  local result = driveToDone(runtime, player)
  Assert.equal(result.kind, "field_move_done", "a valid climb must run to done")
  Assert.equal(player.fieldX, 6, "climb must commit the validated landing column")
  Assert.equal(player.fieldZ, 3, "climb must commit the validated landing row")
  Assert.equal(player.worldY, 2, "climb must resolve the landing elevation from terrain, never a constant")
end

function T.tests.connection_failure_preserves_the_source()
  local rig = waterfallRig()
  local queued = rig.runtime:queue({ move = "waterfall", slot = 0, context = rigContext({ facingWaterfall = true }) })
  Assert.equal(queued.kind, "accepted", "admission checks facing, not the full route")
  -- Fail connected-coverage preparation past the source row: tiles south
  -- of z=2 leave residency, so preflight must refuse before crossing with
  -- no side effects.
  rig.map.collision.containsLocal = function(_, _, z)
    return z <= 2
  end
  local request = rig.runtime:takePending()
  local plan = rig.runtime:plan(request)
  Assert.equal(plan.kind, "not_here", "an unpreparable connection must refuse before crossing")
  Assert.isFalse(rig.player:isScriptedMoving(), "a refused route must begin no motion")
  Assert.equal(rig.player.fieldX, 5, "the source tile must be untouched")
  Assert.equal(rig.player.fieldZ, 2, "the source tile must be untouched")
  Assert.isFalse(rig.runtime:isBusy(), "a refused plan must release the runtime")
end

return T
