-- FieldMoveWorld traversal planning: terrain-valid contiguous water/climb
-- paths with real player motion, resolver, and avatar owners over small
-- explicit asymmetric fixtures. Only the geography is synthetic; every
-- collaborator but the terrain/collision grid is production code.

local Assert = require("tests.support.Assert")
local FieldMoveWorld = require("game.hgss.src.field.FieldMoveWorld")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local FieldPlayerAvatarState = require("libs.hgss.src.actors.FieldPlayerAvatarState")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local T = {}

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
    terrain = TerrainSurface.new({ plates = plates }),
    terrainDependencyHash = "test-terrain",
    fieldRegion = {},
    cameraType = 0,
    release = function() end,
    updateAnimated = function() end,
  } --[[@as RuntimeFieldMap]]
end

local function avatarStates()
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
  return states
end

local function rigAvatar(mode)
  local offsets = { x = 0, y = 0, z = 0 }
  return FieldPlayerAvatarState.new({
    capability = { id = "rig", gender = 0, states = avatarStates() },
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

local function setup(map, player, avatar)
  local events = FieldEventState.new()
  local applied = { count = 0, names = {} }
  local actorActions = {}
  local sounds = {}
  local ports = {
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
      beginScriptedAction = function(_, actorId, action)
        actorActions[#actorActions + 1] = { actorId = actorId, action = action }
      end,
      advanceScriptedAction = function() end,
      commitScriptedAction = function() end,
      cancelScriptedMovement = function() end,
      isScriptedMoving = function()
        return false
      end,
      removePresence = function()
        error("traversal world tests cover no presence removal", 2)
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
        applied.names[#applied.names + 1] = name
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
        error("traversal world tests cover no weather change", 2)
      end,
    },
    reactions = {
      dispatch = function()
        error("traversal world tests cover no reaction dispatch", 2)
      end,
    },
    audio = {
      play = function(_, sequence)
        sounds[#sounds + 1] = sequence
      end,
    },
  }
  return {
    world = FieldMoveWorld.new(ports),
    applied = applied,
    events = events,
    actorActions = actorActions,
    sounds = sounds,
    player = player,
  }
end

local function shoreRig()
  local behaviorAt = {}
  local map = rigMap(behaviorAt, {
    flatPlate(0, 0, 0, 32, 4, 0),
    flatPlate(1, 0, 4, 32, 32, -0.5),
  })
  for z = 4, 10 do
    for x = 0, 10 do
      behaviorAt[x .. ":" .. z] = 16
    end
  end
  local player = FieldPlayer.new({ currentMap = map, fieldX = 2, fieldZ = 3, surfaceId = 0, facing = "south" })
  local avatar = rigAvatar("walking")
  local rig = setup(map, player, avatar)
  rig.map = map
  rig.player = player
  rig.avatar = avatar
  return rig
end

function T.surf_entry_plans_one_validated_water_step()
  local rig = shoreRig()
  local plan = rig.world:planTraversal({ move = "surf" })
  Assert.equal(plan.kind, "surf_enter")
  Assert.equal(#plan.segments, 1)
  local segment = plan.segments[1]
  Assert.equal(segment.fieldX, 2)
  Assert.equal(segment.fieldZ, 4)
  Assert.equal(segment.surfaceId, 1)
  Assert.equal(segment.worldY, -0.5)
  Assert.equal(segment.direction, "south")
  Assert.equal(segment.mode, "surfing")
  Assert.equal(segment.behavior, 16)
  Assert.equal(plan.sourceIdentity.move, "surf")
  Assert.equal(plan.sourceIdentity.mapId, 61)
end

function T.surf_entry_refuses_without_surfable_facing_water()
  local rig = shoreRig()
  rig.player:turn("north")
  local plan = rig.world:planTraversal({ move = "surf" })
  Assert.equal(plan.kind, "not_here")
end

function T.disembark_plans_the_shore_step_and_flips_avatar_at_commit()
  local rig = shoreRig()
  rig.player:turn("south")
  rig.player:setTraversalMode("surfing")
  -- Walk the player onto water through the planned entry first so the
  -- disembark starts from a real swimming position.
  local entry = rig.world:planTraversal({ move = "surf" })
  Assert.equal(entry.kind, "surf_enter")
  rig.player:beginScriptedAction({
    action = "traverse",
    direction = "south",
    speed = "normal",
    mode = "surfing",
    surfaceId = entry.segments[1].surfaceId,
  })
  for _ = 1, 8 do
    rig.player:updateFixed({})
  end
  rig.player:commitScriptedAction()
  rig.world:commitTraversalMode(entry)
  Assert.equal(rig.avatar:status().durableState, "surfing")
  rig.player:turn("north")
  local plan = rig.world:planTraversal({ move = "disembark" })
  Assert.equal(plan.kind, "disembark")
  Assert.equal(#plan.segments, 1)
  Assert.equal(plan.segments[1].fieldZ, 3)
  Assert.equal(plan.segments[1].surfaceId, 0)
  rig.world:commitTraversalMode(plan)
  Assert.equal(rig.avatar:status().durableState, "walking")
  Assert.equal(rig.applied.count, 2)
end

-- Source Task_Waterfall: the avatar crosses exactly two tiles, however tall
-- the fall behavior runs, so the plan is one segment two tiles away.
function T.waterfall_plans_exactly_two_tiles_from_the_facing_fall()
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
  local player = FieldPlayer.new({ currentMap = map, fieldX = 5, fieldZ = 2, surfaceId = 0, facing = "south" })
  player:setTraversalMode("surfing")
  local rig = setup(map, player, rigAvatar("surfing"))
  local plan = rig.world:planTraversal({ move = "waterfall" })
  Assert.equal(plan.kind, "waterfall")
  Assert.equal(#plan.segments, 1)
  Assert.equal(plan.segments[1].fieldZ, 4)
  Assert.equal(plan.segments[1].worldY, 2)
  Assert.equal(plan.segments[1].surfaceId, 1)
  Assert.equal(plan.effect, "SEQ_SE_DP_FW463")
  local automatic = rig.world:planTraversal({ move = "waterfall", auto = true })
  Assert.isNil(automatic.effect, "the unannounced descent plays no effect")
end

function T.waterfall_refuses_a_non_water_far_tile_before_motion()
  local behaviorAt = { ["5:3"] = 19 }
  local map = rigMap(behaviorAt, {
    flatPlate(0, 0, 0, 32, 3, 4),
    flatPlate(1, 0, 3, 32, 32, 2),
  })
  local player = FieldPlayer.new({ currentMap = map, fieldX = 5, fieldZ = 2, surfaceId = 0, facing = "south" })
  player:setTraversalMode("surfing")
  local rig = setup(map, player, rigAvatar("surfing"))
  local plan = rig.world:planTraversal({ move = "waterfall" })
  Assert.equal(plan.kind, "not_here")
  Assert.isFalse(player:isScriptedMoving())
end

function T.waterfall_refuses_sideways_facing()
  local behaviorAt = { ["6:2"] = 19, ["7:2"] = 16 }
  local map = rigMap(behaviorAt, { flatPlate(0, 0, 0, 32, 32, 0) })
  local player = FieldPlayer.new({ currentMap = map, fieldX = 5, fieldZ = 2, surfaceId = 0, facing = "east" })
  player:setTraversalMode("surfing")
  local rig = setup(map, player, rigAvatar("surfing"))
  Assert.equal(rig.world:planTraversal({ move = "waterfall" }).kind, "not_here")
end

-- Drive one planned waterfall through the real player and record each tick.
local function runWaterfall(rig, plan)
  local runtimePlan = { kind = plan.kind, mapId = 61, segments = plan.segments, segmentIndex = 0 }
  Assert.isNil(rig.world:validateTraversalSegment(runtimePlan))
  local player = rig.player
  local samples = { { y = player.worldY, z = player.worldZ } }
  rig.world:beginTraversalSegment(runtimePlan)
  while player:isScriptedMoving() do
    player:updateFixed({})
    samples[#samples + 1] = { y = player.worldY, z = player.worldZ, walking = player:presentationState().locomotionActive }
    Assert.isTrue(#samples <= 200, "the fall must settle")
  end
  rig.world:commitTraversalSegment(runtimePlan)
  return samples
end

function T.waterfall_rise_runs_96_updates_height_first_without_walk_animation()
  local behaviorAt = { ["5:4"] = 19, ["5:3"] = 16 }
  local map = rigMap(behaviorAt, {
    flatPlate(0, 0, 0, 32, 4, 4),
    flatPlate(1, 0, 4, 32, 32, 0),
  })
  local player = FieldPlayer.new({ currentMap = map, fieldX = 5, fieldZ = 5, surfaceId = 1, facing = "north" })
  player:setTraversalMode("surfing")
  local rig = setup(map, player, rigAvatar("surfing"))
  local plan = rig.world:planTraversal({ move = "waterfall" })
  Assert.equal(plan.kind, "waterfall")
  local samples = runWaterfall(rig, plan)
  Assert.equal(#samples - 1, 96, "source cadence is 96 updates")
  local first, last = samples[1], samples[#samples]
  Assert.equal(player.fieldZ, 3)
  Assert.equal(player.surfaceId, 0)
  Assert.equal(last.y, 4)
  -- Updates 1-32 raise height only; ground travel starts afterwards.
  Assert.equal(samples[33].z, first.z, "no ground travel during the first 32 updates")
  Assert.near(samples[33].y, first.y + (last.y - first.y) / 2, 1e-9, "half the height after 32 updates")
  Assert.near(samples[65].y, last.y, 1e-9, "height settles at update 64")
  Assert.near(samples[65].z, first.z + (last.z - first.z) / 2, 1e-9, "half the ground after 64 updates")
  for index = 2, #samples do
    Assert.isFalse(samples[index].walking, "the fall plays no walk animation")
  end
end

function T.waterfall_descent_moves_ground_first()
  local behaviorAt = { ["5:3"] = 19, ["5:4"] = 16 }
  local map = rigMap(behaviorAt, {
    flatPlate(0, 0, 0, 32, 3, 4),
    flatPlate(1, 0, 3, 32, 32, 0),
  })
  local player = FieldPlayer.new({ currentMap = map, fieldX = 5, fieldZ = 2, surfaceId = 0, facing = "south" })
  player:setTraversalMode("surfing")
  local rig = setup(map, player, rigAvatar("surfing"))
  local plan = rig.world:planTraversal({ move = "waterfall" })
  Assert.equal(plan.kind, "waterfall")
  local samples = runWaterfall(rig, plan)
  Assert.equal(#samples - 1, 96)
  local first, last = samples[1], samples[#samples]
  Assert.near(samples[65].z, last.z, 1e-9, "ground travel settles at update 64")
  Assert.near(samples[33].z, first.z + (last.z - first.z) / 2, 1e-9)
  Assert.equal(samples[33].y, first.y, "height holds for the first 32 updates")
  Assert.equal(player.fieldZ, 4)
end

function T.climb_matches_orientation_and_validates_the_landing()
  local behaviorAt = { ["5:3"] = 76 }
  local map = rigMap(behaviorAt, {
    flatPlate(0, 0, 0, 32, 32, 0),
    flatPlate(1, 6, 3, 7, 4, 2),
  })
  local player = FieldPlayer.new({ currentMap = map, fieldX = 4, fieldZ = 3, surfaceId = 0, facing = "east" })
  local rig = setup(map, player, rigAvatar("walking"))
  local plan = rig.world:planTraversal({ move = "rock_climb" })
  Assert.equal(plan.kind, "rock_climb")
  Assert.equal(#plan.segments, 2)
  Assert.equal(plan.segments[2].fieldX, 6)
  Assert.equal(plan.segments[2].worldY, 2)
  Assert.equal(plan.segments[2].surfaceId, 1)
  Assert.equal(plan.segments[1].mode, "walking")
end

-- Count the fixed updates one planned segment takes through the real player.
local function segmentTicks(rig, plan, index)
  local runtimePlan = { kind = plan.kind, mapId = 61, segments = plan.segments, segmentIndex = index - 1 }
  Assert.isNil(rig.world:validateTraversalSegment(runtimePlan))
  rig.world:beginTraversalSegment(runtimePlan)
  local ticks = 0
  while rig.player:isScriptedMoving() do
    rig.player:updateFixed({})
    ticks = ticks + 1
    Assert.isTrue(ticks <= 200, "the segment must settle")
  end
  rig.world:commitTraversalSegment(runtimePlan)
  return ticks
end

-- Source Task_RockClimb: a near hop onto the wall, fast walks between wall
-- tiles, and a near hop off the top; the debris effect sounds once at start.
function T.climb_hops_on_and_off_the_wall_and_walks_fast_between()
  local behaviorAt = { ["5:3"] = 76, ["6:3"] = 76 }
  local map = rigMap(behaviorAt, {
    flatPlate(0, 0, 0, 32, 32, 0),
    flatPlate(1, 7, 3, 8, 4, 2),
  })
  local player = FieldPlayer.new({ currentMap = map, fieldX = 4, fieldZ = 3, surfaceId = 0, facing = "east" })
  local rig = setup(map, player, rigAvatar("walking"))
  local plan = rig.world:planTraversal({ move = "rock_climb" })
  Assert.equal(plan.kind, "rock_climb")
  Assert.equal(plan.effect, "SEQ_SE_DP_UG_023")
  Assert.equal(#plan.segments, 3)
  Assert.equal(segmentTicks(rig, plan, 1), 8, "near fast hop onto the wall")
  Assert.equal(segmentTicks(rig, plan, 2), 4, "fast walk between wall tiles")
  Assert.equal(segmentTicks(rig, plan, 3), 8, "near fast hop onto the landing")
end

-- Source Task_Whirlpool: one slowest-walk step per tile through the swirl.
function T.whirlpool_steps_at_the_slowest_walk_and_sounds_once()
  local behaviorAt = { ["5:3"] = 17, ["6:3"] = 17, ["7:3"] = 16 }
  local map = rigMap(behaviorAt, { flatPlate(0, 0, 0, 32, 32, 0) })
  local player = FieldPlayer.new({ currentMap = map, fieldX = 4, fieldZ = 3, surfaceId = 0, facing = "east" })
  player:setTraversalMode("surfing")
  local rig = setup(map, player, rigAvatar("surfing"))
  local plan = rig.world:planTraversal({ move = "whirlpool" })
  Assert.equal(plan.kind, "whirlpool")
  Assert.equal(plan.effect, "SEQ_SE_DP_FW463")
  Assert.equal(#plan.segments, 3)
  for index = 1, 3 do
    Assert.equal(segmentTicks(rig, plan, index), 32)
  end
end

-- Source Task_Surf / Task_StopSurfing: ten-update waits (11 updates) around
-- the mount, then a near fast hop; dismounting is the hop alone.
function T.surf_mount_waits_then_hops_and_dismount_only_hops()
  local rig = shoreRig()
  local entry = rig.world:planTraversal({ move = "surf" })
  Assert.equal(entry.preTicks, 11)
  Assert.equal(entry.postTicks, 11)
  Assert.isNil(entry.effect)
  Assert.equal(segmentTicks(rig, entry, 1), 8)
  rig.world:commitTraversalMode(entry)
  rig.player:setTraversalMode("surfing")
  rig.player:turn("north")
  local exit = rig.world:planTraversal({ move = "disembark" })
  Assert.equal(exit.kind, "disembark")
  Assert.isNil(exit.preTicks)
  Assert.equal(segmentTicks(rig, exit, 1), 8)
end

function T.climb_refuses_mismatched_orientation()
  local behaviorAt = { ["4:2"] = 75 }
  local map = rigMap(behaviorAt, { flatPlate(0, 0, 0, 32, 32, 0) })
  local player = FieldPlayer.new({ currentMap = map, fieldX = 4, fieldZ = 3, surfaceId = 0, facing = "north" })
  local rig = setup(map, player, rigAvatar("walking"))
  -- An east/west wall never admits a northward climb.
  behaviorAt["4:2"] = 76
  local plan = rig.world:planTraversal({ move = "rock_climb" })
  Assert.equal(plan.kind, "not_here")
end

function T.unreadable_tiles_refuse_as_unprepared_connections()
  local rig = shoreRig()
  rig.map.collision.containsLocal = function(_, _, z)
    return z <= 3
  end
  local plan = rig.world:planTraversal({ move = "surf" })
  Assert.equal(plan.kind, "not_here")
  Assert.equal(plan.reason, "connection_unprepared")
end

function T.segment_validation_rechecks_map_identity_and_occupancy()
  local rig = shoreRig()
  local plan = rig.world:planTraversal({ move = "surf" })
  Assert.equal(plan.kind, "surf_enter")
  local runtimePlan = {
    kind = "surf_enter",
    mapId = 61,
    segments = plan.segments,
    segmentIndex = 0,
  }
  Assert.isNil(rig.world:validateTraversalSegment(runtimePlan))
end

-- Source Task_PushBoulder: the boulder walks one slow tile while the player
-- walks on the spot facing it (no tile move), with the push effect at start.
function T.push_walks_the_boulder_while_the_real_player_stays_on_its_tile()
  local map = rigMap({}, { flatPlate(0, 0, 0, 32, 32, 0) })
  local player = FieldPlayer.new({ currentMap = map, fieldX = 4, fieldZ = 4, surfaceId = 0, facing = "south" })
  local rig = setup(map, player, rigAvatar("walking"))
  local plan = {
    kind = "push_strength",
    mapId = 61,
    target = { actorId = "map:61:object:2", obstacleKind = "strength_boulder", mapId = 61 },
    direction = "south",
    phase = "begin",
    committed = false,
  }
  rig.world:beginPush(plan)
  Assert.equal(#rig.actorActions, 1)
  Assert.equal(rig.actorActions[1].action.action, "walk")
  Assert.equal(rig.actorActions[1].action.speed, "slow")
  Assert.deepEqual(rig.sounds, { "SEQ_SE_DP_UG_023" })
  Assert.isTrue(player:isScriptedMoving(), "the player animates")
  local startZ = player.worldZ
  for _ = 1, 40 do
    if rig.world:advancePush(plan) then
      break
    end
    Assert.equal(player.worldZ, startZ, "the player never leaves its tile while pushing")
  end
  rig.world:commitPush(plan)
  Assert.equal(player.fieldX, 4)
  Assert.equal(player.fieldZ, 4)
  Assert.isFalse(player:isScriptedMoving())
end

return { tests = T }
