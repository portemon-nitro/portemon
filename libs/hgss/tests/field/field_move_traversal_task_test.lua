-- FieldMoveRuntime traversal: surf/disembark/falls/climb plans run
-- segment-by-segment through the real world and player owners over small
-- explicit fixtures. Only the geography is synthetic.

local Assert = require("tests.support.Assert")
local FieldMovePolicy = require("libs.hgss.src.field.FieldMovePolicy")
local FieldMoveRuntime = require("libs.hgss.src.field.FieldMoveRuntime")
local FieldMoveWorld = require("game.hgss.src.field.FieldMoveWorld")
local FieldMoveTask = require("libs.hgss.src.script.tasks.FieldMoveTask")
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

-- Structural port for the traversal runtime under test: names exactly the
-- exercised boundary so helper-built subjects resolve their methods.
---@class TraversalTaskRuntimePort
---@field queue fun(self: TraversalTaskRuntimePort, request: table<string, unknown>): table<string, unknown>
---@field takePending fun(self: TraversalTaskRuntimePort): table<string, unknown>
---@field plan fun(self: TraversalTaskRuntimePort, request: table<string, unknown>): table<string, unknown>
---@field advance fun(self: TraversalTaskRuntimePort, plan: table<string, unknown>): table<string, unknown>
---@field cancel fun(self: TraversalTaskRuntimePort, plan: table<string, unknown>)
---@field discardPending fun(self: TraversalTaskRuntimePort)
---@field isBusy fun(self: TraversalTaskRuntimePort): boolean
---@field requestDisembark fun(self: TraversalTaskRuntimePort): table<string, unknown>

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

local function setup(map, player, avatar, context)
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
        error("traversal runtime tests cover no presence removal", 2)
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
        return avatar:applyTransitions()
      end,
    },
    profile = { badges = 0xFFFF },
    weather = {
      change = function()
        error("traversal runtime tests cover no weather change", 2)
      end,
    },
    reactions = {
      dispatch = function()
        error("traversal runtime tests cover no reaction dispatch", 2)
      end,
    },
  })
  local runtime = FieldMoveRuntime.new({ policy = FieldMovePolicy, context = context, world = world }) --[[@as TraversalTaskRuntimePort]]
  return { world = world, runtime = runtime, player = player, avatar = avatar, map = map }
end

local function shoreRig()
  local behaviorAt = {}
  for z = 4, 10 do
    for x = 0, 10 do
      behaviorAt[x .. ":" .. z] = 16
    end
  end
  local map = rigMap(behaviorAt, {
    flatPlate(0, 0, 0, 32, 4, 0),
    flatPlate(1, 0, 4, 32, 32, -0.5),
  })
  local player = FieldPlayer.new({ currentMap = map, fieldX = 2, fieldZ = 3, surfaceId = 0, facing = "south" })
  local avatar = rigAvatar("walking")
  local context = {
    badges = 0xFFFF,
    mapSymbol = "test-water",
    mapId = 61,
    fieldUse = {},
    avatarMode = "walking",
    humanFollower = false,
    followingMon = false,
    rocketCostume = false,
    safari = false,
    palPark = false,
    surfEdge = true,
    facingWaterfall = false,
    facingWhirlpool = false,
    climbTile = false,
    headbuttTree = false,
    foggy = false,
    chatterOpen = false,
  }
  local rig = setup(map, player, avatar, context)
  rig.context = context
  rig.behaviorAt = behaviorAt
  return rig
end

local function driveToDone(rig, plan)
  local active = plan
  for _ = 1, 600 do
    local outcome = rig.runtime:advance(active)
    if outcome.kind == "done" then
      return outcome
    end
    Assert.equal(outcome.kind, "running")
    rig.player:updateFixed({})
  end
  error("traversal plan did not settle", 2)
end

function T.surf_entry_advances_one_committed_segment_to_done()
  local rig = shoreRig()
  local queued = rig.runtime:queue({ move = "surf", slot = 0, context = rig.context })
  Assert.equal(queued.kind, "accepted")
  local request = rig.runtime:takePending()
  local plan = rig.runtime:plan(request)
  Assert.equal(plan.kind, "surf_enter")
  Assert.equal(plan.phase, "traverse")
  Assert.equal(plan.segmentIndex, 0)
  Assert.equal(plan.mapId, 61)
  Assert.equal(#plan.segments, 1)
  driveToDone(rig, plan)
  Assert.equal(rig.player.fieldX, 2)
  Assert.equal(rig.player.fieldZ, 4)
  Assert.equal(rig.player.surfaceId, 1)
  Assert.equal(rig.avatar:status().durableState, "surfing")
  Assert.isFalse(rig.runtime:isBusy())
end

function T.explicit_surf_without_context_plans_from_live_state()
  local rig = shoreRig()
  local request = { move = "surf", slot = 0 }
  local admitted = rig.runtime:queue(request)
  Assert.equal(admitted.kind, "accepted")
  local taken = rig.runtime:takePending()
  local plan = rig.runtime:plan(taken)
  Assert.equal(plan.kind, "surf_enter")
end

function T.disembark_round_trip_returns_to_walking()
  local rig = shoreRig()
  local queued = rig.runtime:queue({ move = "surf", slot = 0, context = rig.context })
  Assert.equal(queued.kind, "accepted")
  driveToDone(rig, rig.runtime:plan(rig.runtime:takePending()))
  rig.player:turn("north")
  rig.player:setTraversalMode("surfing")
  local requested = rig.runtime:requestDisembark()
  Assert.equal(requested.kind, "accepted")
  local taken = rig.runtime:takePending()
  local plan = rig.runtime:plan(taken)
  Assert.equal(plan.kind, "disembark")
  driveToDone(rig, plan)
  Assert.equal(rig.player.fieldX, 2)
  Assert.equal(rig.player.fieldZ, 3)
  Assert.equal(rig.avatar:status().durableState, "walking")
  Assert.isFalse(rig.runtime:isBusy())
end

function T.second_request_while_busy_is_denied_without_mutation()
  local rig = shoreRig()
  local queued = rig.runtime:queue({ move = "surf", slot = 0, context = rig.context })
  Assert.equal(queued.kind, "accepted")
  local busy = rig.runtime:requestDisembark()
  Assert.equal(busy.kind, "busy")
  rig.runtime:discardPending()
  Assert.isFalse(rig.runtime:isBusy())
end

function T.broken_route_fails_before_motion_and_releases()
  local rig = shoreRig()
  rig.behaviorAt["2:4"] = nil
  local queued = rig.runtime:queue({ move = "surf", slot = 0, context = rig.context })
  Assert.equal(queued.kind, "accepted", "admission checks the edge, not the full route")
  local plan = rig.runtime:plan(rig.runtime:takePending())
  Assert.equal(plan.kind, "not_here")
  Assert.isFalse(rig.player:isScriptedMoving())
  Assert.isFalse(rig.runtime:isBusy())
end

function T.cancel_mid_traversal_restores_the_committed_tile()
  local rig = shoreRig()
  local queued = rig.runtime:queue({ move = "surf", slot = 0, context = rig.context })
  Assert.equal(queued.kind, "accepted")
  local plan = rig.runtime:plan(rig.runtime:takePending())
  local first = rig.runtime:advance(plan)
  Assert.equal(first.kind, "running")
  Assert.isTrue(rig.player:isScriptedMoving())
  for _ = 1, 3 do
    rig.player:updateFixed({})
  end
  rig.runtime:cancel(plan)
  Assert.equal(rig.player.motion, "idle")
  Assert.equal(rig.player.fieldX, 2)
  Assert.equal(rig.player.fieldZ, 3)
  Assert.equal(rig.avatar:status().durableState, "walking")
  Assert.isFalse(rig.runtime:isBusy())
end

function T.traversal_plans_pass_the_scheduler_task_gate()
  local rig = shoreRig()
  local queued = rig.runtime:queue({ move = "surf", slot = 0, context = rig.context })
  Assert.equal(queued.kind, "accepted")
  local state = FieldMoveTask.create({ source = "pending" }, { services = { fieldMoves = rig.runtime } })
  Assert.isNil(state.refused, "traversal plans must pass the task gate")
  local valid = FieldMoveTask.validate(state)
  Assert.isNil(valid, "traversal task state must validate")
end

return { tests = T }
