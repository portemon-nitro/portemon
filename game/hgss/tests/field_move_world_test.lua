-- FieldMoveWorld: the task-facing bind from executable plans to existing
-- world owners. Uses real occupancy, event state, and motion owners;
-- weather/reactions/maps/player/profile enter as complete injected ports.
-- Removal changes presence and collision together through the actor owner;
-- pushes validate both destinations before touching motion; Flash runs
-- through weather (or the chamber reaction); commit-time revalidation turns
-- drift into reported failure, never retargeting.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldMoveWorld = require("game.hgss.src.field.FieldMoveWorld")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local T = {}

local CUT_FLAG = 100
local FLASH_FLAG = 2419

local POLICY = {
  variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
}

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

local function objectEvent(overrides)
  local event = {
    index = 0,
    objectEventId = 0,
    spriteId = 99,
    movementType = "stationary",
    type = 0,
    eventFlag = 0,
    scriptId = 1,
    facingDirection = "south",
    facingDirectionRaw = 1,
    param0 = 0,
    param1 = 0,
    param2 = 0,
    xRange = 0,
    yRange = 0,
    x = 2,
    z = 3,
    y = 0,
  } --[[@as table<string, unknown>]]
  for key, value in pairs(overrides or {}) do
    rawset(event, key, value)
  end
  return event --[[@as FieldActorEvent]]
end

local function runtimeMap(objects, mapId)
  return {
    mapId = mapId or 61,
    mapSection = "test-section",
    mapSectionNativeId = 7,
    followMode = "ALLOW",
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 40 and z >= 0 and z < 32
      end,
    },
    terrain = terrain(),
    mapSymbol = "test-map",
    sceneRuntime = nil,
    scene = {},
    terrainDependencyHash = "test-terrain",
    fieldRegion = {},
    cameraType = 4,
    fieldData = { events = { objects = objects, background = {}, warps = {}, coordinates = {} } },
    release = function() end,
    updateAnimated = function() end,
  } --[[@as RuntimeFieldMap]]
end

local function fakeAssets(known)
  return {
    references = {},
    knows = function(_, spriteId)
      return known[spriteId] == true
    end,
    acquire = function(self, spriteId)
      self.references[spriteId] = (self.references[spriteId] or 0) + 1
      return { spriteId = spriteId, visual = FieldActorFixture.visual(spriteId) }
    end,
    release = function(self, spriteId)
      local count = self.references[spriteId] or 0
      assert(count > 0, "unbalanced release of spriteId " .. spriteId)
      self.references[spriteId] = count - 1
    end,
  }
end

local function fieldObjects()
  return {
    objectEvent({ objectEventId = 0, spriteId = 86, eventFlag = CUT_FLAG, x = 6, z = 3, obstacleKind = "cut_tree" }),
    objectEvent({ objectEventId = 1, spriteId = 85, eventFlag = 101, x = 9, z = 3, obstacleKind = "smash_rock" }),
    objectEvent({ objectEventId = 2, spriteId = 84, eventFlag = 0, x = 4, z = 6, obstacleKind = "strength_boulder" }),
    objectEvent({ objectEventId = 3, spriteId = 99, eventFlag = 0, x = 12, z = 10 }),
  }
end

local function playerFacade(overrides)
  local player = {
    positionValue = { fieldX = 5, fieldZ = 3, worldY = 0 },
    facingValue = "east",
    position = function(self)
      return { fieldX = self.positionValue.fieldX, fieldZ = self.positionValue.fieldZ }
    end,
    facing = function(self)
      return self.facingValue
    end,
    began = {},
    commits = 0,
    cancelled = 0,
    moving = false,
    beginScriptedAction = function(self, action)
      self.began[#self.began + 1] = action
      self.progress = 0
      self.duration = 16
      self.moving = true
    end,
    advanceScriptedAction = function(self, progress, duration)
      self.progress = progress or 0
      self.duration = duration or 16
      if self.progress >= self.duration then
        self.moving = false
      end
    end,
    commitScriptedAction = function(self)
      self.commits = self.commits + 1
      self.moving = false
    end,
    cancelScriptedMovement = function(self)
      self.cancelled = self.cancelled + 1
      self.moving = false
    end,
    isScriptedMoving = function(self)
      return self.moving == true
    end,
    avatarTransitions = {},
    avatarApplies = 0,
    queueAvatarTransition = function(self, name)
      self.avatarTransitions[#self.avatarTransitions + 1] = name
    end,
    applyAvatarTransitions = function(self)
      self.avatarApplies = self.avatarApplies + 1
      return nil
    end,
  }
  for key, value in pairs(overrides or {}) do
    player[key] = value
  end
  return player
end

local function ports(manager, eventState, map, overrides)
  local weatherChanged = {}
  local reactions = {}
  local base = {
    actors = manager,
    events = eventState,
    maps = {
      current = function()
        return { symbol = "test-map", id = 61, fieldUse = { flashUsable = true, alphChamber = false } }
      end,
      runtimeMap = function()
        return map
      end,
    },
    player = playerFacade(),
    profile = { badges = 0xFFFF },
    weather = {
      change = function(_, weatherId)
        weatherChanged[#weatherChanged + 1] = weatherId
      end,
    },
    reactions = {
      dispatch = function(_, kind)
        reactions[#reactions + 1] = kind
        return true
      end,
    },
    weatherChanged = weatherChanged,
    reactionsFired = reactions,
  }
  for key, value in pairs(overrides or {}) do
    base[key] = value
  end
  return base
end

local function setup(overrides)
  overrides = overrides or {}
  local objects = overrides.objects or fieldObjects()
  local map = runtimeMap(objects, 61)
  local eventState = FieldEventState.new()
  local manager = FieldActorManager.new({
    assets = fakeAssets({ [86] = true, [85] = true, [84] = true, [99] = true }),
    policy = POLICY,
  })
  manager:enterMap(map, eventState, nil)
  local mapPorts = {
    current = function()
      return { symbol = "test-map", id = 61, fieldUse = { flashUsable = true, alphChamber = false } }
    end,
    runtimeMap = function()
      return map
    end,
  }
  local portOverrides = { maps = mapPorts }
  for key, value in pairs(overrides.ports or {}) do
    portOverrides[key] = value
  end
  local worldPorts = ports(manager, eventState, map, portOverrides)
  return {
    manager = manager,
    eventState = eventState,
    map = map,
    objects = objects,
    worldPorts = worldPorts,
    world = FieldMoveWorld.new(worldPorts),
  }
end

local function cutPlan()
  return {
    kind = "cut",
    move = "cut",
    slot = 0,
    partyRevision = 4,
    mapId = 61,
    target = { actorId = "map:61:object:0", obstacleKind = "cut_tree", mapId = 61 },
    phase = "commit",
    committed = false,
  }
end

function T.construction_fails_without_complete_ports()
  local filled = setup()
  for _, missing in ipairs({ "actors", "events", "maps", "player", "profile", "weather", "reactions" }) do
    local incomplete = {}
    for key, value in pairs(filled.worldPorts) do
      if key ~= missing and key ~= "weatherChanged" and key ~= "reactionsFired" then
        incomplete[key] = value
      end
    end
    local err = Assert.throws(function()
      FieldMoveWorld.new(incomplete)
    end)
    Assert.notNil(tostring(err):find(missing), "construction must name the missing port, got " .. tostring(err))
  end
  filled.manager:dispose()
end

function T.remove_obstacle_cuts_through_the_flag_path()
  local filled = setup()
  filled.world:removeObstacle({ actorId = "map:61:object:0", obstacleKind = "cut_tree", mapId = 61 })
  Assert.isNil(filled.manager:getById("map:61:object:0"), "tree presence is gone")
  Assert.isNil(
    filled.manager:getCollisionAt(61, { fieldX = 6, fieldZ = 3, surfaceId = 0 }),
    "tree collision is gone with presence"
  )
  Assert.isTrue(filled.eventState:isFlagSet(CUT_FLAG), "flag path persists the removal")
  filled.manager:dispose()
end

function T.remove_obstacle_records_the_override_for_flagless_targets()
  local filled = setup()
  filled.world:removeObstacle({ actorId = "map:61:object:2", obstacleKind = "strength_boulder", mapId = 61 })
  Assert.isNil(filled.manager:getById("map:61:object:2"), "flagless presence is gone")
  local captured = filled.manager:captureObjects()
  local removed = assert(captured.removed, "capture carries the sparse removal override")
  Assert.equal(#removed, 1, "exactly one removal override")
  Assert.equal(removed[1].mapId, 61)
  Assert.equal(removed[1].objectEventId, 2)
  filled.manager:dispose()
end

function T.remove_obstacle_on_a_missing_actor_raises_loudly()
  local filled = setup()
  local err = Assert.throws(function()
    filled.world:removeObstacle({ actorId = "map:61:object:99", obstacleKind = "cut_tree", mapId = 61 })
  end)
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.notNil(filled.manager:getById("map:61:object:0"), "no live actor is touched by the failure")
  filled.manager:dispose()
end

function T.validate_target_accepts_the_live_target()
  local filled = setup()
  Assert.isNil(filled.world:validateTarget(cutPlan()), "live target validates clean")
  filled.manager:dispose()
end

function T.validate_target_reports_a_removed_actor()
  local filled = setup()
  filled.manager:removePresence("map:61:object:0", false)
  local decision = filled.world:validateTarget(cutPlan())
  decision = assert(decision, "a removed actor must not validate")
  Assert.equal(decision.kind, "stale")
  filled.manager:dispose()
end

function T.validate_target_reports_a_map_change()
  local filled = setup()
  local moved = ports(filled.manager, filled.eventState, filled.map, {
    maps = {
      current = function()
        return { symbol = "other-map", id = 77, fieldUse = {} }
      end,
      runtimeMap = function()
        return filled.map
      end,
    },
  })
  local elsewhere = FieldMoveWorld.new(moved)
  local decision = elsewhere:validateTarget(cutPlan())
  decision = assert(decision, "a map change must not validate")
  Assert.equal(decision.kind, "stale")
  filled.manager:dispose()
end

function T.resolve_facing_target_names_the_tree_ahead()
  local filled = setup()
  local target = assert(filled.world:resolveFacingTarget(), "the tree ahead must resolve")
  Assert.equal(target.actorId, "map:61:object:0")
  Assert.equal(target.obstacleKind, "cut_tree")
  filled.manager:dispose()
end

function T.resolve_facing_target_is_nil_without_an_obstacle()
  local filled = setup()
  filled.worldPorts.player.facingValue = "west"
  local target = filled.world:resolveFacingTarget()
  Assert.isNil(target, "empty tiles resolve to nothing")
  filled.manager:dispose()
end

function T.validate_push_accepts_a_free_destination()
  local filled = setup()
  filled.worldPorts.player.positionValue = { fieldX = 4, fieldZ = 5, worldY = 0 }
  filled.worldPorts.player.facingValue = "south"
  local plan = {
    kind = "push_strength",
    mapId = 61,
    target = { actorId = "map:61:object:2", obstacleKind = "strength_boulder", mapId = 61 },
    direction = "south",
  }
  Assert.isNil(filled.world:validatePush(plan), "a free same-level tile validates")
  filled.manager:dispose()
end

function T.validate_push_rejects_an_occupied_destination()
  local objects = {
    objectEvent({ objectEventId = 0, spriteId = 84, eventFlag = 0, x = 4, z = 6, obstacleKind = "strength_boulder" }),
    objectEvent({ objectEventId = 1, spriteId = 99, eventFlag = 0, x = 4, z = 7 }),
  }
  local map = runtimeMap(objects, 61)
  local eventState = FieldEventState.new()
  local manager = FieldActorManager.new({
    assets = fakeAssets({ [84] = true, [99] = true }),
    policy = POLICY,
  })
  manager:enterMap(map, eventState, nil)
  local worldPorts = ports(manager, eventState, map, {
    maps = {
      current = function()
        return { symbol = "test-map", id = 61, fieldUse = {} }
      end,
      runtimeMap = function()
        return map
      end,
    },
  })
  worldPorts.player.positionValue = { fieldX = 4, fieldZ = 5, worldY = 0 }
  local world = FieldMoveWorld.new(worldPorts)
  local decision = world:validatePush({
    kind = "push_strength",
    mapId = 61,
    target = { actorId = "map:61:object:0", obstacleKind = "strength_boulder", mapId = 61 },
    direction = "south",
  })
  decision = assert(decision, "pushing into an actor must refuse")
  Assert.equal(decision.reason, "push_blocked")
  manager:dispose()
end

function T.validate_push_rejects_uncovered_destinations()
  local plates = {
    {
      id = 0,
      minX = 0,
      minZ = 0,
      maxX = 6,
      maxZ = 32,
      normal = { x = 0, y = 1, z = 0 },
      distance = 0,
      slopeClass = "flat",
    },
  }
  local clippedTerrain = TerrainSurface.new({ plates = plates })
  local objects = {
    objectEvent({ objectEventId = 0, spriteId = 84, eventFlag = 0, x = 5, z = 6, obstacleKind = "strength_boulder" }),
  }
  local map = runtimeMap(objects, 61)
  map.terrain = clippedTerrain
  local eventState = FieldEventState.new()
  local manager = FieldActorManager.new({
    assets = fakeAssets({ [84] = true }),
    policy = POLICY,
  })
  manager:enterMap(map, eventState, nil)
  local worldPorts = ports(manager, eventState, map, {
    maps = {
      current = function()
        return { symbol = "test-map", id = 61, fieldUse = {} }
      end,
      runtimeMap = function()
        return map
      end,
    },
  })
  worldPorts.player.positionValue = { fieldX = 4, fieldZ = 6, worldY = 0 }
  local world = FieldMoveWorld.new(worldPorts)
  local decision = world:validatePush({
    kind = "push_strength",
    mapId = 61,
    target = { actorId = "map:61:object:0", obstacleKind = "strength_boulder", mapId = 61 },
    direction = "east",
  })
  decision = assert(decision, "pushing past terrain coverage must refuse")
  Assert.equal(decision.reason, "push_blocked")
  manager:dispose()
end

function T.push_moves_boulder_and_player_through_motion_owners()
  local filled = setup()
  filled.worldPorts.player.positionValue = { fieldX = 4, fieldZ = 5, worldY = 0 }
  filled.worldPorts.player.facingValue = "south"
  local plan = {
    kind = "push_strength",
    mapId = 61,
    target = { actorId = "map:61:object:2", obstacleKind = "strength_boulder", mapId = 61 },
    direction = "south",
    phase = "begin",
    committed = false,
  }
  Assert.isNil(filled.world:validatePush(plan))
  filled.world:beginPush(plan)
  Assert.isTrue(filled.manager:isScriptedMoving("map:61:object:2"), "boulder motion begins")
  local settled = false
  local guard = 0
  while not settled and guard < 200 do
    guard = guard + 1
    settled = filled.world:advancePush(plan)
  end
  Assert.isTrue(settled, "boulder motion settles on the calibrated cadence")
  filled.world:commitPush(plan)
  local position = assert(filled.manager:getPosition("map:61:object:2"), "pushed boulder reports its tile")
  Assert.equal(position.fieldX, 4)
  Assert.equal(position.fieldZ, 7, "boulder commits one tile south")
  Assert.equal(#filled.worldPorts.player.began, 1, "player motion begins exactly once")
  Assert.equal(filled.worldPorts.player.commits, 1, "player motion commits exactly once")
  filled.manager:dispose()
end

function T.apply_flash_uses_weather_and_sets_the_flag()
  local filled = setup()
  filled.world:applyFlash({ kind = "flash", mapId = 61, alphChamber = false })
  Assert.isTrue(filled.eventState:isFlagSet(FLASH_FLAG), "flash persists through its flag")
  Assert.deepEqual(filled.worldPorts.weatherChanged, { 12 }, "illumination runs through weather")
  Assert.equal(#filled.worldPorts.reactionsFired, 0, "no special reaction outside the chamber")
  filled.manager:dispose()
end

function T.apply_flash_in_the_chamber_dispatches_the_reaction()
  local filled = setup()
  filled.world:applyFlash({ kind = "flash", mapId = 61, alphChamber = true })
  Assert.deepEqual(filled.worldPorts.reactionsFired, { "alph_flash" }, "chamber dispatches its reaction")
  Assert.equal(#filled.worldPorts.weatherChanged, 0, "chamber skips brightening")
  Assert.isFalse(filled.eventState:isFlagSet(FLASH_FLAG), "chamber sets no illumination flag")
  filled.manager:dispose()
end

function T.activate_strength_confirms_the_enablement()
  local filled = setup()
  Assert.isTrue(filled.world:activateStrength({ kind = "enable_strength", mapId = 61 }), "enablement commits")
  filled.manager:dispose()
end

function T.capture_context_validates_sources_loudly()
  local filled = setup()
  local sources = {
    badges = 0xFFFF,
    mapSymbol = "test-map",
    mapId = 61,
    fieldUse = {
      flyAllowed = false,
      teleportAllowed = false,
      escapeAllowed = false,
      flashUsable = true,
      alphChamber = false,
      icePathB2F = false,
      cave = true,
      unionOrColosseum = false,
    },
    avatarMode = "walking",
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
  local captured = filled.world:captureContext(sources)
  Assert.equal(captured.mapId, 61)
  local err = Assert.throws(function()
    local broken = {}
    for key, value in pairs(sources) do
      broken[key] = value
    end
    broken.badges = "many"
    filled.world:captureContext(broken)
  end)
  Assert.notNil(err, "malformed sources fail loudly")
  filled.manager:dispose()
end

return { tests = T }
