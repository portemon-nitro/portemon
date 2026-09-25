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
      beginScriptedAction = function() end,
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
  }
  return { world = FieldMoveWorld.new(ports), applied = applied, events = events }
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

function T.waterfall_chains_contiguous_falls_to_a_validated_pool()
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
  local avatar = rigAvatar("surfing")
  local rig = setup(map, player, avatar)
  local plan = rig.world:planTraversal({ move = "waterfall" })
  Assert.equal(plan.kind, "waterfall")
  Assert.equal(#plan.segments, 4)
  Assert.equal(plan.segments[4].fieldZ, 6)
  Assert.equal(plan.segments[4].worldY, 0)
  Assert.equal(plan.segments[4].surfaceId, 2)
end

function T.waterfall_refuses_a_missing_landing_before_motion()
  local behaviorAt = {}
  for z = 3, 5 do
    behaviorAt["5:" .. z] = 19
  end
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

return { tests = T }
