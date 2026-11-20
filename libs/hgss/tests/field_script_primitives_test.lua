local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldOverworldLifecycle = require("libs.hgss.src.field.FieldOverworldLifecycle")
local FieldScriptPropAnimations = require("libs.hgss.src.field.FieldScriptPropAnimations")
local MapProps = require("libs.hgss.src.world.MapProps")
local Matrix4 = require("libs.math.src.Matrix4")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local NitroModelFixture = require("tests.support.NitroModelFixture")
local OverworldLifecycleTask = require("libs.hgss.src.script.tasks.OverworldLifecycleTask")
local PropAnimationWaitTask = require("libs.hgss.src.script.tasks.PropAnimationWaitTask")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local ScriptActorWorld = require("libs.hgss.src.script.ScriptActorWorld")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local T = {}

function T.overworld_lifecycle_requires_one_fixed_boundary_per_transition()
  local lifecycle = FieldOverworldLifecycle.new()
  Assert.equal(lifecycle:phase(), "present")
  lifecycle:requestLeave()
  Assert.equal(lifecycle:phase(), "leaving")
  lifecycle:updateFixed()
  Assert.equal(lifecycle:phase(), "absent")
  lifecycle:requestRestore()
  Assert.equal(lifecycle:phase(), "restoring")
  lifecycle:updateFixed()
  Assert.isTrue(lifecycle:isPresent())
end

function T.overworld_lifecycle_rejects_invalid_transitions()
  local lifecycle = FieldOverworldLifecycle.new()
  local ok, err = pcall(lifecycle.requestRestore, lifecycle)
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, FieldErrors.FIELD_OVERWORLD_LIFECYCLE_INVALID)
  lifecycle:requestLeave()
  ok, err = pcall(lifecycle.requestLeave, lifecycle)
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err))
end

function T.prop_animation_slots_retain_playback_and_die_on_map_rebind()
  local owner = FieldScriptPropAnimations.new()
  local complete = false
  local playCount = 0
  local prop = {
    instance = {},
    play = function(_, role, opts)
      playCount = playCount + 1
      Assert.equal(role, "door.open")
      Assert.equal(opts.loopMode, "once")
      return { player = {
        isComplete = function()
          return complete
        end,
      } }
    end,
  }
  local firstMap = {
    mapProps = {
      doorAt = function()
        return nil
      end,
      scriptPropAt = function()
        return prop
      end,
    },
  }
  owner:bindMap(firstMap)
  owner:load(3, 5, 7)
  Assert.equal(playCount, 0, "load must not start playback")
  owner:play(3, "forward")
  Assert.isFalse(owner:isFinished(3))
  complete = true
  Assert.isTrue(owner:isFinished(3), "wait lookup observes the retained playback")
  owner:unload(3)
  local ok = pcall(owner.isFinished, owner, 3)
  Assert.isFalse(ok)

  owner:load(3, 5, 7)
  owner:bindMap({
    mapProps = {
      doorAt = function()
        return nil
      end,
      scriptPropAt = function()
        return prop
      end,
    },
  })
  ok = pcall(owner.play, owner, 3, "forward")
  Assert.isFalse(ok, "map rebinding invalidates loaded slots")
end

function T.prop_animation_slot_replays_only_after_the_previous_playback_finishes()
  local owner = FieldScriptPropAnimations.new()
  local complete = false
  local roles = {}
  local prop = {
    instance = {},
    play = function(_, role)
      roles[#roles + 1] = role
      return { player = {
        isComplete = function()
          return complete
        end,
      } }
    end,
  }
  owner:bindMap({
    mapProps = {
      doorAt = function()
        return nil
      end,
      scriptPropAt = function()
        return prop
      end,
    },
  })
  owner:load(1, 0, 0)
  owner:play(1, "forward")
  Assert.isFalse(pcall(owner.play, owner, 1, "reverse"), "a running playback cannot be replayed")
  complete = true
  owner:play(1, "reverse")
  Assert.deepEqual(roles, { "door.open", "door.close" })
end

function T.prop_animation_slots_resolve_outdoor_props_through_coverage()
  local owner = FieldScriptPropAnimations.new()
  local prop = {
    instance = {},
    play = function()
      return { player = {
        isComplete = function()
          return true
        end,
      } }
    end,
  }
  local runtimeMap
  runtimeMap = {
    coverage = {
      doorAt = function()
        return nil
      end,
      scriptPropAt = function(_, map, x, z)
        Assert.equal(x, 5)
        Assert.equal(z, 7)
        Assert.isTrue(map == runtimeMap)
        return prop
      end,
    },
  }
  owner:bindMap(runtimeMap)
  owner:load(1, 5, 7)
  owner:play(1, "forward")
  Assert.isTrue(owner:isFinished(1))
end

function T.prop_animation_slots_reject_bad_or_duplicate_references()
  local owner = FieldScriptPropAnimations.new()
  local prop = {
    instance = {},
    play = function()
      return { player = {
        isComplete = function()
          return false
        end,
      } }
    end,
  }
  owner:bindMap({
    mapProps = {
      doorAt = function()
        return nil
      end,
      scriptPropAt = function()
        return prop
      end,
    },
  })
  local ok = pcall(owner.load, owner, 256, 0, 0)
  Assert.isFalse(ok, "slot values stay in the source byte domain")
  owner:load(0, 0, 0)
  ok = pcall(owner.load, owner, 0, 0, 0)
  Assert.isFalse(ok, "loaded slot replacement requires an unload")
  ok = pcall(owner.play, owner, 0, "reverse")
  Assert.isTrue(ok)
  ok = pcall(owner.play, owner, 0, "forward")
  Assert.isFalse(ok, "a slot has at most one active playback")
end

function T.blocking_tasks_observe_the_shared_owners()
  local lifecycle = FieldOverworldLifecycle.new()
  local context = { services = { overworld = lifecycle } }
  local state = OverworldLifecycleTask.create({ action = "leave" }, context)
  Assert.isFalse(OverworldLifecycleTask.poll(state, context).complete)
  lifecycle:updateFixed()
  Assert.isTrue(OverworldLifecycleTask.poll(state, context).complete)

  local finished = false
  local waiterContext =
    { services = { propAnimations = {
      isFinished = function()
        return finished
      end,
    } } }
  local waitState = PropAnimationWaitTask.create({ slot = 7 }, waiterContext)
  Assert.isFalse(PropAnimationWaitTask.poll(waitState, waiterContext).complete)
  finished = true
  Assert.isTrue(PropAnimationWaitTask.poll(waitState, waiterContext).complete)
end

-- The source object commands act on the live field actors: ChangeObjectMovement
-- reinitializes the object's own movement, SetObjectFacingAndUpdateDraw turns
-- the drawn orientation immediately, and the two source commands disagree on
-- what an absent object means.
local POLICY = { variableSprites = { first = 101, last = 117, variableBase = 0x4020 } }

local function flatTerrain()
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
    movementType = "look_north",
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
  }
  for key, value in pairs(overrides or {}) do
    event[key] = value
  end
  return event
end

local function liveActorWorld(objects, eventState, restoredObjects)
  local manager = FieldActorManager.new({
    assets = {
      knows = function(_, spriteId)
        return spriteId == 99
      end,
      acquire = function(_, spriteId)
        return { spriteId = spriteId, visual = FieldActorFixture.visual(spriteId), references = 1 }
      end,
      release = function() end,
    },
    policy = POLICY,
  })
  local map = {
    mapId = 61,
    mapSection = "test-section",
    mapSectionNativeId = 7,
    followMode = "ALLOW",
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
    },
    terrain = flatTerrain(),
    mapSymbol = "test-map",
    sceneRuntime = nil,
    scene = {},
    terrainDependencyHash = "test-terrain",
    fieldRegion = {},
    cameraType = 4,
    fieldData = { events = { objects = objects, background = {}, warps = {}, coordinates = {} } },
    release = function() end,
    updateAnimated = function() end,
  }
  manager:enterMap(map --[[@as RuntimeFieldMap]], eventState or FieldEventState.new(), restoredObjects)
  local world = ScriptActorWorld.new(manager, {
    position = function()
      return { fieldX = 0, fieldZ = 0, worldY = 0 }
    end,
    facing = function()
      return "south"
    end,
  })
  return manager, world
end

-- The map-scoped prop owner also carries the source elevator one-shot: the
-- commands drive it through the existing prop playback surface, and a map
-- without the elevator prop refuses to claim an animation. The fixture is the
-- generated placement identity ("indoor:<member>:<sha>") resolved through the
-- real MapProps/ModelInstance owners, exactly as the live map resolves it;
-- member 0xD0 is MAP_PROP_ELEVATOR.
local ELEVATOR_PROP_MEMBER = 0xD0
local ELEVATOR_PLACEMENT_INDEX = 7
-- The ordinary building the fixture map also carries, so locating the elevator
-- prop has to select by placement identity and never by being the only
-- placement.
local ORDINARY_PROP_MEMBER = 0x25
local ORDINARY_PLACEMENT_INDEX = 3

local function placeBuilding(placements, instances, placementIndex, memberId)
  local definition = NitroModelFixture.elevatorDefinition(memberId)
  placements[#placements + 1] = {
    placementIndex = placementIndex,
    modelKey = definition.key,
    transform = Matrix4.translate(0, 0, 0),
  }
  instances[placementIndex] = ModelInstance.new(definition)
  return instances[placementIndex]
end

-- A bound map whose second building carries `elevatorMember`, and that building's
-- live model instance.
---@param elevatorMember integer
---@return table<string, unknown>, ModelInstance
local function elevatorMap(elevatorMember)
  local placements, instances = {}, {}
  placeBuilding(placements, instances, ORDINARY_PLACEMENT_INDEX, ORDINARY_PROP_MEMBER)
  local instance = placeBuilding(placements, instances, ELEVATOR_PLACEMENT_INDEX, elevatorMember)
  local mapProps = MapProps.new({ placements = placements, instances = instances, doorTiles = {} })
  return { mapId = 61, mapProps = mapProps }, instance
end

local function jointAttachments(instance)
  return instance.animationState:attachments("joint")
end

function T.elevator_prop_commands_drive_the_source_one_shot_of_the_bound_map()
  local owner = FieldScriptPropAnimations.new()
  local map, instance = elevatorMap(ELEVATOR_PROP_MEMBER)
  owner:bindMap(map)

  owner:loadAnimation(1)
  Assert.equal(#jointAttachments(instance), 0, "loading the source animation starts no playback")
  owner:playAnimation(1)
  local attachment = jointAttachments(instance)[1]
  Assert.equal(attachment.clip.name, "ElevatorDown", "the source direction selects its own animation")
  Assert.isFalse(owner:isAnimationLoopFinished(), "the loop end is the animation owner's answer")
  for _ = 1, 7 do
    instance:updateFixed()
  end
  Assert.isFalse(owner:isAnimationLoopFinished(), "the pass is not finished before its checked terminal")
  instance:updateFixed()
  Assert.isTrue(owner:isAnimationLoopFinished())

  owner:unloadAnimation()
  Assert.equal(#jointAttachments(instance), 0, "releasing the animation stops its playback")
  Assert.throws(function()
    owner:isAnimationLoopFinished()
  end, "a released elevator animation has no playback state")

  local missing = FieldScriptPropAnimations.new()
  local otherMap, otherInstance = elevatorMap(ORDINARY_PROP_MEMBER)
  missing:bindMap(otherMap)
  local err = Assert.throws(function()
    missing:loadAnimation(1)
  end)
  Assert.isTrue(Errors.is(err), "a map without the elevator prop faults instead of claiming an animation")
  Assert.equal(err.code, FieldErrors.FIELD_ELEVATOR_PROP_MISSING)
  Assert.equal(#jointAttachments(otherInstance), 0, "the fault claims no playback")

  local rebound = FieldScriptPropAnimations.new()
  rebound:bindMap(select(1, elevatorMap(ELEVATOR_PROP_MEMBER)))
  rebound:loadAnimation(2)
  rebound:bindMap(select(1, elevatorMap(ELEVATOR_PROP_MEMBER)))
  Assert.throws(function()
    rebound:playAnimation(0)
  end, "a map rebind releases the animation loaded for the previous map")
end

function T.elevator_direction_selects_its_own_source_clip()
  ---@type { direction: integer, clip: string }[]
  local directions = { { direction = 0, clip = "ElevatorUp" }, { direction = 1, clip = "ElevatorDown" } }
  for _, case in ipairs(directions) do
    local owner = FieldScriptPropAnimations.new()
    local map, instance = elevatorMap(ELEVATOR_PROP_MEMBER)
    owner:bindMap(map)
    owner:loadAnimation(1)
    owner:playAnimation(case.direction)
    Assert.equal(jointAttachments(instance)[1].clip.name, case.clip)
  end
end

-- The source repeat count is the animation loop count: a trip of N floors plays
-- N passes of the 8-frame clip and only then reports its loop end.
function T.elevator_repeat_count_drives_the_animation_loop_count()
  for _, loopCount in ipairs({ 1, 2, 5 }) do
    local owner = FieldScriptPropAnimations.new()
    local map, instance = elevatorMap(ELEVATOR_PROP_MEMBER)
    owner:bindMap(map)
    owner:loadAnimation(loopCount)
    owner:playAnimation(0)
    local ticks = 0
    while not owner:isAnimationLoopFinished() do
      ticks = ticks + 1
      Assert.isTrue(ticks <= 8 * loopCount, "the loop ends at the requested pass count")
      instance:updateFixed()
    end
    Assert.equal(ticks, 8 * loopCount, "each pass is the clip's 8 frames")
    owner:unloadAnimation()
  end
end

-- A map rebind already released the slot the elevator task owned, so a
-- cancellation landing afterwards is a clean release of nothing instead of a
-- fault over an animation the bound map no longer carries.
function T.a_cancelled_elevator_task_tolerates_a_map_rebind()
  local ElevatorAnimTask = require("libs.hgss.src.script.tasks.ElevatorAnimTask")
  local owner = FieldScriptPropAnimations.new()
  owner:bindMap(select(1, elevatorMap(ELEVATOR_PROP_MEMBER)))
  local ctx = {
    services = {
      propAnimations = owner,
      audio = {
        play = function() end,
        stop = function() end,
        isEffectWaitComplete = function()
          return false
        end,
      },
    },
  }
  local state = ElevatorAnimTask.create({ direction = 0, length = 2 }, ctx)
  Assert.isFalse(ElevatorAnimTask.poll(state, ctx).complete, "the animation still owns the script")

  owner:bindMap(select(1, elevatorMap(ELEVATOR_PROP_MEMBER)))
  ElevatorAnimTask.cancel(state, "script cancelled")

  owner:loadAnimation(2)
  owner:unloadAnimation()
end

local function objectRun(actorWorld)
  return {
    instance = { scriptId = "test.object_commands", mode = "foreground" },
    services = { actors = actorWorld },
    semantics = RuntimeValues,
  }
end

function T.object_commands_follow_their_source_movement_and_facing_rules()
  local actorId = "map:61:object:0"
  -- The actor's own source movement has already advanced its wait state, so a
  -- reinitializing change is distinguishable from a plain field write.
  local manager, world = liveActorWorld(
    { objectEvent(), objectEvent({ objectEventId = 1, eventFlag = 401, x = 4 }) },
    FieldEventState.new({ flags = { [401] = true } }),
    {
      schema = "g4-field-objects-v1",
      rng = { state = 7, calls = 0 },
      actors = {
        [actorId] = {
          actorId = actorId,
          mapId = 61,
          objectEventId = 0,
          sourceMovementType = "look_north",
          movementType = "look_north",
          fieldX = 2,
          fieldZ = 3,
          facing = "south",
          managerOrder = 0,
          controller = { kind = "stationary", timer = 40 },
        },
      },
    }
  )
  local actor = assert(manager:getById(actorId))
  Assert.equal(actor.movementType, "look_north")
  Assert.equal(manager.autonomy:state(actorId).timer, 40, "the restored actor carries an advanced movement wait")

  local run = objectRun(world)
  Assert.equal(
    Runtime.executeNode({
      op = "set_object_movement_type",
      actor = { ref = "actor", mapIndex = 0 },
      movementType = "wander_around",
      changeMovement = true,
    }, run),
    Runtime.OUTCOME_CONTINUE,
    "a source movement change returns in the same tick"
  )
  Assert.equal(manager:getById(actorId), actor, "the actor manager's own actor answers the change")
  Assert.equal(actor.movementType, "wander_around")
  local autonomy = manager.autonomy:state(actorId)
  Assert.equal(autonomy.movementType, "wander_around")
  Assert.equal(autonomy.timer, 0, "the source change reinitializes the movement wait")
  Assert.equal(#manager:drawRecords(), 1, "no second actor record appears")

  -- An object id the current map does not carry is an intentional same-tick
  -- no-op for the movement command.
  Assert.equal(
    Runtime.executeNode({
      op = "set_object_movement_type",
      actor = { ref = "actor", mapIndex = 7 },
      movementType = "stationary",
      changeMovement = true,
    }, objectRun(world)),
    Runtime.OUTCOME_CONTINUE,
    "an unknown map object index is a same-tick no-op"
  )
  Assert.equal(
    Runtime.executeNode({
      op = "set_object_movement_type",
      actor = { ref = "actor", id = "map:61:object:1" },
      movementType = "stationary",
      changeMovement = true,
    }, objectRun(world)),
    Runtime.OUTCOME_CONTINUE,
    "an object whose flag keeps it out of the map is a same-tick no-op"
  )
  Assert.equal(#manager:drawRecords(), 1, "the no-ops create no actor record")

  -- The facing command requires the object: the source asserts it exists.
  local missing = Assert.throws(function()
    Runtime.executeNode({
      op = "set_object_facing",
      actor = { ref = "actor", id = "map:61:object:1" },
      direction = "east",
    }, objectRun(world))
  end)
  Assert.isTrue(Errors.is(missing), "an absent object faults with an attributed error")
  Assert.equal(missing.code, "SCRIPT_ACTOR_NOT_FOUND")

  Assert.equal(
    Runtime.executeNode({
      op = "set_object_facing",
      actor = { ref = "actor", mapIndex = 0 },
      direction = "east",
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(actor.facing, "east")
  Assert.equal(manager:drawRecords()[1].facing, "east", "the drawn orientation follows in the same tick")
end

-- The source facing refresh reads its direction through a script variable, so
-- the evaluated source code becomes the actor's drawn facing in the same tick;
-- a code outside the source set is an attributed failure.
function T.source_facing_refresh_reads_its_direction_from_a_script_variable()
  local actorId = "map:61:object:0"
  local manager, world = liveActorWorld({ objectEvent() }, FieldEventState.new(), {
    schema = "g4-field-objects-v1",
    rng = { state = 7, calls = 0 },
    actors = {
      [actorId] = {
        actorId = actorId,
        mapId = 61,
        objectEventId = 0,
        sourceMovementType = "look_north",
        movementType = "look_north",
        fieldX = 2,
        fieldZ = 3,
        facing = "south",
        managerOrder = 0,
        controller = { kind = "stationary", timer = 0 },
      },
    },
  })
  local variables = { VAR_TEMP_x4001 = 2 }
  local run = objectRun(world)
  run.services.world = {
    getVar = function(_, id)
      return variables[id] or 0
    end,
  }
  Assert.equal(
    Runtime.executeNode({
      op = "set_object_facing",
      actor = { ref = "actor", mapIndex = 0 },
      direction = { value = "var", id = "VAR_TEMP_x4001" },
    }, run),
    Runtime.OUTCOME_CONTINUE,
    "the facing refresh returns in the same tick"
  )
  local actor = assert(manager:getById(actorId))
  Assert.equal(actor.facing, "west", "the source direction code becomes the actor facing")
  Assert.equal(manager:drawRecords()[1].facing, "west", "the drawn orientation follows in the same tick")

  variables.VAR_TEMP_x4001 = 7
  local err = Assert.throws(function()
    Runtime.executeNode({
      op = "set_object_facing",
      actor = { ref = "actor", mapIndex = 0 },
      direction = { value = "var", id = "VAR_TEMP_x4001" },
    }, run)
  end)
  Assert.isTrue(Errors.is(err), "a direction outside the source set is an attributed failure")
  Assert.equal(manager:getById(actorId).facing, "west", "a rejected direction leaves the facing untouched")
end

-- The source elevator choreography loads the map elevator prop, plays it,
-- waits for the loop count, plays the motor stop and chime, waits for the
-- chime and only then releases the animation. The fake prop/sound owners keep
-- the choreography observable; the real prop owner is exercised below.
local function elevatorContext(propPresent)
  local log = {}
  local control = { loopFinished = false, chimePlaying = false }
  local propAnimations = { presented = propPresent == true }
  function propAnimations:loadAnimation(loopCount)
    if not self.presented then
      Errors.raise(FieldErrors.FIELD_ELEVATOR_PROP_MISSING, "the active map has no elevator prop")
    end
    assert(self.loaded ~= true, "the elevator animation is already loaded")
    self.loaded = true
    self.loopCount = loopCount
    log[#log + 1] = "load:" .. tostring(loopCount)
  end
  function propAnimations:playAnimation(elevatorDirection)
    assert(self.loaded == true, "the elevator animation must be loaded before it plays")
    self.direction = elevatorDirection
    log[#log + 1] = "play:" .. tostring(elevatorDirection)
  end
  function propAnimations:isAnimationLoopFinished()
    return control.loopFinished
  end
  function propAnimations:unloadAnimation()
    assert(self.loaded == true, "only a loaded elevator animation is released")
    self.loaded = false
    log[#log + 1] = "unload"
  end

  local audio = {}
  function audio:play(sequence)
    log[#log + 1] = "se:" .. sequence
    if sequence == "SEQ_SE_DP_PINPON" then
      control.chimePlaying = true
    end
  end
  function audio:stop(sequence)
    log[#log + 1] = "stop:" .. sequence
  end
  function audio:isEffectWaitComplete(sequence)
    if sequence == "SEQ_SE_DP_PINPON" then
      return not control.chimePlaying
    end
    return true
  end

  return {
    services = { propAnimations = propAnimations, audio = audio },
  }, log, control, propAnimations
end

-- The live trip: the real prop owner over the fixture elevator model and a
-- recording sound service, so the source phases drive the actual clip.
local function elevatorTrip(memberId)
  local owner = FieldScriptPropAnimations.new()
  local map, instance = elevatorMap(memberId)
  owner:bindMap(map)
  local log = {}
  local control = { chimePlaying = true }
  local ctx = {
    services = {
      propAnimations = owner,
      audio = {
        play = function(_, sequence)
          log[#log + 1] = "se:" .. sequence
        end,
        stop = function(_, sequence)
          log[#log + 1] = "stop:" .. sequence
        end,
        isEffectWaitComplete = function()
          return not control.chimePlaying
        end,
      },
    },
  }
  return { instance = instance, ctx = ctx, log = log, control = control }
end

function T.elevator_animation_runs_the_source_prop_and_sound_sequence()
  local ElevatorAnimTask = require("libs.hgss.src.script.tasks.ElevatorAnimTask")
  Assert.equal(ElevatorAnimTask.type, "elevator_anim")
  Assert.equal(ElevatorAnimTask.version, 1)

  local ctx, log, control, propAnimations = elevatorContext(true)
  local state = ElevatorAnimTask.create({ direction = 0, length = 6 }, ctx)
  Assert.deepEqual(log, { "load:6" }, "creating the task loads the source one-shot animation")

  Assert.isFalse(ElevatorAnimTask.poll(state, ctx).complete, "the animation loop still owns the script")
  Assert.deepEqual(log, { "load:6", "play:0", "se:SEQ_SE_DP_ELEBETA2" }, "playback starts with the motor sound")

  control.loopFinished = true
  Assert.isFalse(ElevatorAnimTask.poll(state, ctx).complete, "the chime still owns the script")
  Assert.deepEqual(log, {
    "load:6",
    "play:0",
    "se:SEQ_SE_DP_ELEBETA2",
    "stop:SEQ_SE_DP_ELEBETA2",
    "se:SEQ_SE_DP_PINPON",
  }, "the loop end stops the motor and plays the arrival chime")
  Assert.isTrue(propAnimations.loaded, "the source-loaded animation is held until the chime finishes")

  control.chimePlaying = false
  Assert.isTrue(ElevatorAnimTask.poll(state, ctx).complete, "the script resumes after the chime finishes")
  Assert.deepEqual(log, {
    "load:6",
    "play:0",
    "se:SEQ_SE_DP_ELEBETA2",
    "stop:SEQ_SE_DP_ELEBETA2",
    "se:SEQ_SE_DP_PINPON",
    "unload",
  }, "the animation is released after the chime completes")
  Assert.isFalse(propAnimations.loaded, "the source-loaded animation is released")
  Assert.isTrue(ElevatorAnimTask.poll(state, ctx).complete, "a completed task never replays its sequence")
  Assert.equal(#log, 6, "the choreography runs once")
  Assert.isNil(ElevatorAnimTask.validate(state), "the completed task state is serializable")
  for _, value in pairs(state) do
    Assert.isTrue(type(value) ~= "function", "the saved task state carries no host handles")
  end
end

-- ScrCmd_ElevatorAnim reads both operands as halfwords and ElevatorAnimCreate
-- takes u8 parameters: the direction keeps its low byte (0 or 1) and the length
-- becomes the animation loop count, fixed to 1 when its low byte is 0
-- (src/field/map_prop_animation.c).
function T.elevator_animation_applies_the_source_operand_conversions()
  local ElevatorAnimTask = require("libs.hgss.src.script.tasks.ElevatorAnimTask")

  local ctx, log = elevatorContext(true)
  local state = ElevatorAnimTask.create({ direction = 0x100, length = 0x100 }, ctx)
  Assert.deepEqual(log, { "load:1" }, "a length whose low byte is zero loads one pass")
  ElevatorAnimTask.poll(state, ctx)
  Assert.deepEqual(
    log,
    { "load:1", "play:0", "se:SEQ_SE_DP_ELEBETA2" },
    "the direction's low byte selects the source pair"
  )
  Assert.equal(state.direction, 0, "the task keeps the effective direction")
  Assert.equal(state.length, 1, "the task keeps the effective loop count")

  local zeroCtx, zeroLog = elevatorContext(true)
  ElevatorAnimTask.create({ direction = 1, length = 0 }, zeroCtx)
  Assert.deepEqual(zeroLog, { "load:1" }, "a zero length never requests zero passes")

  local rejected = {
    { direction = 2, length = 1 },
    { direction = 0x102, length = 1 },
    { direction = "0", length = 1 },
    { direction = 0, length = 0x10000 },
    { direction = 0, length = 1.5 },
  }
  for _, spec in ipairs(rejected) do
    local invalidCtx = elevatorContext(true)
    local err = Assert.throws(function()
      ElevatorAnimTask.create(spec, invalidCtx)
    end)
    Assert.isTrue(Errors.is(err), "an operand outside the source domain is an attributed failure")
    Assert.equal(err.code, "SCRIPT_INVALID_REFERENCE")
  end
end

function T.elevator_animation_faults_without_the_map_elevator_prop()
  local ElevatorAnimTask = require("libs.hgss.src.script.tasks.ElevatorAnimTask")
  local missingCtx, missingLog = elevatorContext(false)
  local ok, err = pcall(function()
    return ElevatorAnimTask.create({ direction = 0, length = 6 }, missingCtx)
  end)
  Assert.isFalse(ok, "a map without the elevator prop faults instead of claiming success")
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, FieldErrors.FIELD_ELEVATOR_PROP_MISSING)
  Assert.deepEqual(missingLog, {}, "a failed acquisition releases nothing it never owned")
end

-- A trip of N floors plays N passes of the 8-frame clip before the motor stops
-- and the arrival chime starts.
function T.elevator_trip_holds_the_script_through_the_source_repeat_count()
  local ElevatorAnimTask = require("libs.hgss.src.script.tasks.ElevatorAnimTask")
  local trip = elevatorTrip(ELEVATOR_PROP_MEMBER)
  local state = ElevatorAnimTask.create({ direction = 0, length = 2 }, trip.ctx)
  Assert.isFalse(ElevatorAnimTask.poll(state, trip.ctx).complete)
  Assert.deepEqual(trip.log, { "se:SEQ_SE_DP_ELEBETA2" }, "the trip starts its motor")

  for _ = 1, 8 do
    trip.instance:updateFixed()
  end
  Assert.isFalse(ElevatorAnimTask.poll(state, trip.ctx).complete, "a two-floor trip is still in its second pass")
  Assert.deepEqual(trip.log, { "se:SEQ_SE_DP_ELEBETA2" }, "the first pass ends without stopping the motor")

  for _ = 1, 8 do
    trip.instance:updateFixed()
  end
  Assert.isFalse(ElevatorAnimTask.poll(state, trip.ctx).complete, "the chime still owns the script")
  Assert.deepEqual(trip.log, {
    "se:SEQ_SE_DP_ELEBETA2",
    "stop:SEQ_SE_DP_ELEBETA2",
    "se:SEQ_SE_DP_PINPON",
  }, "the requested pass count ends the loop and starts the chime")

  trip.control.chimePlaying = false
  Assert.isTrue(ElevatorAnimTask.poll(state, trip.ctx).complete)
  Assert.equal(#jointAttachments(trip.instance), 0, "the trip releases its prop after the chime")
end

-- The motor belongs to the trip, so cancellation stops it exactly once before
-- the prop lease is released.
function T.elevator_animation_stops_the_motor_when_cancelled()
  local ElevatorAnimTask = require("libs.hgss.src.script.tasks.ElevatorAnimTask")
  local ctx, log, _control, propAnimations = elevatorContext(true)
  local state = ElevatorAnimTask.create({ direction = 1, length = 3 }, ctx)
  ElevatorAnimTask.poll(state, ctx)
  ElevatorAnimTask.cancel(state, "script cancelled", ctx)
  Assert.deepEqual(log, {
    "load:3",
    "play:1",
    "se:SEQ_SE_DP_ELEBETA2",
    "stop:SEQ_SE_DP_ELEBETA2",
    "unload",
  }, "a cancelled animation stops its motor and releases its prop")
  Assert.isFalse(propAnimations.loaded, "the cancelled trip holds no animation")
  ElevatorAnimTask.cancel(state, "script cancelled", ctx)
  Assert.equal(#log, 5, "repeated cancellation stops and releases nothing again")
end

function T.elevator_cancellation_during_the_chime_stops_nothing()
  local ElevatorAnimTask = require("libs.hgss.src.script.tasks.ElevatorAnimTask")
  local trip = elevatorTrip(ELEVATOR_PROP_MEMBER)
  local state = ElevatorAnimTask.create({ direction = 1, length = 1 }, trip.ctx)
  Assert.isFalse(ElevatorAnimTask.poll(state, trip.ctx).complete)
  for _ = 1, 8 do
    trip.instance:updateFixed()
  end
  Assert.isFalse(ElevatorAnimTask.poll(state, trip.ctx).complete, "the chime owns the script")
  local chimeLog = {
    "se:SEQ_SE_DP_ELEBETA2",
    "stop:SEQ_SE_DP_ELEBETA2",
    "se:SEQ_SE_DP_PINPON",
  }
  Assert.deepEqual(trip.log, chimeLog)

  ElevatorAnimTask.cancel(state, "script cancelled", trip.ctx)
  Assert.deepEqual(trip.log, chimeLog, "the motor already stopped, so cancellation stops nothing")
  Assert.equal(#jointAttachments(trip.instance), 0, "the cancelled chime releases the held prop")
end

-- A map rebind already released the slot the elevator task owned, so a
-- cancellation landing afterwards is a clean release of nothing instead of a
-- fault over an animation the bound map no longer carries.
function T.a_cancelled_elevator_task_tolerates_a_map_rebind()
  local ElevatorAnimTask = require("libs.hgss.src.script.tasks.ElevatorAnimTask")
  local trip = elevatorTrip(ELEVATOR_PROP_MEMBER)
  local state = ElevatorAnimTask.create({ direction = 0, length = 2 }, trip.ctx)
  Assert.isFalse(ElevatorAnimTask.poll(state, trip.ctx).complete, "the animation still owns the script")

  local reboundMap = elevatorMap(ELEVATOR_PROP_MEMBER)
  trip.ctx.services.propAnimations:bindMap(reboundMap)
  ElevatorAnimTask.cancel(state, "script cancelled", trip.ctx)
  Assert.deepEqual(trip.log, { "se:SEQ_SE_DP_ELEBETA2", "stop:SEQ_SE_DP_ELEBETA2" })
end

-- An active trip owns a live prop and sound lease the scheduler's restore hook
-- cannot rebuild, so only the completed state is serializable.
function T.elevator_task_state_is_serializable_only_once_complete()
  local ElevatorAnimTask = require("libs.hgss.src.script.tasks.ElevatorAnimTask")
  local ctx, _log, control = elevatorContext(true)
  local state = ElevatorAnimTask.create({ direction = 0, length = 2 }, ctx)

  local function refuses(phase)
    local err = ElevatorAnimTask.validate(state)
    Assert.isTrue(Errors.is(err), "an active trip cannot be saved in phase " .. phase)
    Assert.equal(err.code, "SCRIPT_TASK_UNSERIALIZABLE")
    Assert.equal(err.context.phase, phase)
    Assert.isTrue(err.message:find("cannot be restored", 1, true) ~= nil, "the refusal names the unrestorable lease")
  end

  refuses("load")
  ElevatorAnimTask.poll(state, ctx)
  refuses("waitLoop")
  control.loopFinished = true
  ElevatorAnimTask.poll(state, ctx)
  refuses("waitChime")
  control.chimePlaying = false
  Assert.isTrue(ElevatorAnimTask.poll(state, ctx).complete)
  Assert.isNil(ElevatorAnimTask.validate(state), "the completed trip is serializable")
end

return { tests = T }
