-- Owner tests for the battle move particle systems: loading a staged system
-- through leases, emitter creation with the retail callback placement, the
-- emitter path callback, freeing, and the fail-closed vocabulary. The
-- simulation itself is covered by spl_particle_simulation_test.

local Assert = require("tests.support.Assert")
local BattleEffectTasks = require("libs.hgss.src.presentation.BattleEffectTasks")
local BattleParticleSystems = require("libs.hgss.src.presentation.BattleParticleSystems")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local function emitterRecord(overrides)
  local record = {
    id = 0,
    emitterLife = 1,
    particleLife = 40,
    startOffset = 0,
    generation = { countFx = 4096, interval = 1 },
    initPosType = 0,
    circleAxis = 0,
    drawType = 0,
    radius = 0,
    length = 0,
    position = { x = 0, y = 0, z = 0 },
    axis = { x = 0, y = 0, z = 0 },
    baseColorRgb = { r = 31, g = 31, b = 31 },
    baseAlpha = 31,
    baseScaleFx = 4096,
    velocityFx = { pos = 0, axis = 0 },
    velRandom = 0,
    scaleRandom = 0,
    lifeRandom = 0,
    rotation = { min = 0, max = 0 },
    useRotationAnim = false,
    useInitRotationRandom = false,
    initRotation = 0,
    airResist = 0,
    aspect = 1,
    loopFrame = 10,
    dbbScale = 0,
    sclAnmDirect = 0,
    texRepeat = { s = 0, t = 0 },
    texture = 0,
    animations = {},
    fields = {},
  }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  return record
end

local function placements()
  local result = {}
  local x = -4
  for _, position in ipairs({
    "solo-player",
    "solo-enemy",
    "player-side-slot-1",
    "enemy-side-slot-1",
    "player-side-slot-2",
    "enemy-side-slot-2",
  }) do
    result[position] = { { x = x, y = -1, z = 0 }, { x = x + 0.5, y = -1, z = 0 } }
    x = x + 2
  end
  return result
end

local function payload(emitters)
  return {
    seed = 0,
    emitters = emitters or { emitterRecord({ persistent = true }) },
    textures = { { id = 0, width = 8, height = 8, image = "texture/0" } },
    placements = placements(),
  }
end

-- Services whose leases mirror the production holder: particle systems come
-- back as decoded records and textures with an image handle.
local function services(scene, systemPayload)
  local journal = { acquired = {}, released = {} }
  local resources = {}
  function resources.resolve(key)
    journal.acquired[#journal.acquired + 1] = key
    if key == "system" then
      return { key = key, kind = "particle", data = systemPayload }
    end
    return { key = key, kind = "texture", handle = { image = key } }
  end
  function resources.release(lease)
    journal.released[#journal.released + 1] = lease
  end
  return { scene = scene, audio = {}, resources = resources }, journal
end

local function context()
  return {
    particles = BattleParticleSystems.newRegistry(),
    topology = {
      attacker = { slot = "solo-player" },
      targets = { { slot = "solo-enemy" } },
    },
  }
end

local function loadSystem(scene, systemPayload, ctx)
  local svc, journal = services(scene, systemPayload or payload())
  local task = BattleEffectTasks.create(
    BattleEffectTasks.PARTICLE_SYSTEM_KIND,
    { systemIndex = 0, resource = "system" },
    ctx,
    svc
  )
  return task, journal
end

local function createEmitter(ctx, overrides)
  local args = { systemIndex = 0, emitter = 0, actionProfile = "particle-emitter-target-battler-relative" }
  for key, value in pairs(overrides or {}) do
    args[key] = value
  end
  return BattleEffectTasks.create(BattleEffectTasks.PARTICLE_CONTINUATION_KIND, args, ctx, {})
end

function T.system_loads_registers_with_the_scene_and_frees_exactly_once()
  local scene = BattleScene.new()
  local ctx = context()
  local system, journal = loadSystem(scene, nil, ctx)
  Assert.equal(#scene:particleSystems(), 1, "the loaded system is registered for drawing")
  Assert.notNil(scene:particleSystems()[1].textures[0], "its texture handle is published by source id")
  Assert.equal(#journal.acquired, 2, "the system and its texture are leased")
  system:free()
  system:free()
  system:dispose()
  Assert.equal(system:status(), "complete", "freeing completes the system task")
  Assert.equal(#scene:particleSystems(), 0, "freeing drops the scene registration")
  Assert.equal(#journal.released, #journal.acquired, "every lease releases exactly once")
  Assert.isNil(ctx.particles.systems[0], "the system slot is free again")
end

function T.loading_one_slot_twice_fails_without_leaking_leases()
  local scene = BattleScene.new()
  local ctx = context()
  local _, first = loadSystem(scene, nil, ctx)
  local ok = pcall(loadSystem, scene, nil, ctx)
  Assert.isFalse(ok, "a loaded slot cannot be loaded again")
  Assert.equal(#first.released, 0, "the first system keeps its leases")
  Assert.equal(#scene:particleSystems(), 1, "the failed load registers nothing")
end

function T.unsupported_members_play_nothing_record_why_and_release_the_lease()
  local scene = BattleScene.new()
  local ctx = context()
  local svc, journal = services(scene, { unsupported = "draw kind 2" })
  local system = BattleEffectTasks.create(
    BattleEffectTasks.PARTICLE_SYSTEM_KIND,
    { systemIndex = 0, resource = "system" },
    ctx,
    svc
  )
  Assert.equal(#journal.released, #journal.acquired, "the unplayed member releases its lease")
  Assert.equal(#scene:particleSystems(), 0, "nothing is registered for drawing")
  Assert.isTrue(ctx.particles.skipped[1]:find("draw kind 2", 1, true) ~= nil, "the compile cause is recorded")
  local emitter = createEmitter(ctx, { continuationSlot = 2 })
  Assert.equal(emitter:status(), "complete", "emitters of an unplayed system are inert")
  local path = BattleEffectTasks.create(BattleEffectTasks.EMITTER_BATTLER_PATH_KIND, {
    parameters = { emitterSlot = 2 },
  }, ctx, {})
  Assert.equal(path:status(), "complete", "so is the path over such an emitter")
  system:free()
  Assert.isNil(ctx.particles.systems[0], "the script can still free the slot")
end

function T.emitters_take_the_callback_placement_and_complete_when_they_leave()
  local scene = BattleScene.new()
  local ctx = context()
  local system = loadSystem(scene, payload({ emitterRecord() }), ctx)
  local target = createEmitter(ctx)
  Assert.equal(system.simulation.emitters[1].x, -2, "the defender callback places the emitter at the enemy placement")
  local attacker = createEmitter(ctx, { actionProfile = "particle-emitter-active-battler-relative" })
  Assert.equal(system.simulation.emitters[2].x, -4, "the attacker callback places the emitter at the player placement")
  Assert.equal(target:status(), "running", "a live emitter holds its task")
  for tick = 1, 60 do
    system:stepSourceTick({ tick = tick })
  end
  Assert.equal(target:status(), "complete", "a self-destroying emitter completes once its particles retire")
  Assert.equal(attacker:status(), "complete", "so does the second emitter")
  system:dispose()
end

function T.persistent_emitters_stay_until_their_system_is_freed()
  local scene = BattleScene.new()
  local ctx = context()
  local system = loadSystem(scene, nil, ctx)
  local emitter = createEmitter(ctx, { continuationSlot = 3 })
  for tick = 1, 100 do
    system:stepSourceTick({ tick = tick })
  end
  Assert.equal(emitter:status(), "running", "a persistent emitter outlives its life")
  Assert.notNil(ctx.particles.emitters[3], "the persistent emitter is addressable by slot")
  system:free()
  Assert.equal(emitter:status(), "complete", "freeing the system retires its emitters")
  Assert.isNil(ctx.particles.emitters[3], "the slot clears with the system")
end

function T.emitter_creation_skips_vocabulary_outside_the_replay_and_fails_on_malformed_input()
  local scene = BattleScene.new()
  local ctx = context()
  local system = loadSystem(scene, nil, ctx)
  local skipped = createEmitter(ctx, { actionProfile = "particle-emitter-battler-pair-position" })
  Assert.equal(skipped:status(), "complete", "an emitter callback the replay does not reproduce plays nothing")
  Assert.equal(#ctx.particles.skipped, 1, "the skipped callback is recorded")
  ctx.particles.flipY[0] = 1
  Assert.equal(createEmitter(ctx):status(), "complete", "a flipped particle camera plays nothing")
  ctx.particles.flipY[0] = 0
  ctx.topology.targets = { { slot = "solo-enemy" }, { slot = "enemy-side-slot-1" } }
  Assert.equal(createEmitter(ctx):status(), "complete", "an emitter placed at one of several targets plays nothing")
  Assert.equal(#system.simulation.emitters, 0, "skipped creations add no emitters")
  Assert.throws(function()
    createEmitter(ctx, { systemIndex = 5 })
  end, "an unloaded system slot fails")
  Assert.throws(function()
    createEmitter(ctx, { emitter = 9 })
  end, "an emitter ordinal outside the system fails")
  system:dispose()
end

function T.perspective_selects_the_placement_column()
  local scene = BattleScene.new()
  local ctx = context()
  local system = loadSystem(scene, nil, ctx)
  ctx.particles.perspective[0] = 1
  createEmitter(ctx)
  Assert.equal(system.simulation.emitters[1].x, -1.5, "perspective type 1 reads the second staged vector")
  system:dispose()
end

local function pathArgs(overrides)
  local parameters = {
    emitterSlot = 0,
    offsetX = 0,
    offsetY = 0,
    delayTicks = 0,
    durationTicks = 14,
    pairOrder = "attacker-target",
    startFrame = 0,
    endFrame = 255,
    wave = false,
  }
  for key, value in pairs(overrides or {}) do
    parameters[key] = value
  end
  return { parameters = parameters }
end

function T.path_task_moves_the_emitter_between_battlers_and_removes_it_when_done()
  local scene = BattleScene.new()
  local ctx = context()
  local system = loadSystem(scene, payload({ emitterRecord({ persistent = true, particleLife = 3 }) }), ctx)
  local emitter = createEmitter(ctx, { actionProfile = "particle-emitter-active-battler-relative" })
  local path = BattleEffectTasks.create(BattleEffectTasks.EMITTER_BATTLER_PATH_KIND, pathArgs(), ctx, {})
  local runtime = system.simulation.emitters[1]
  Assert.near(runtime.x, -4, 0.05, "the path starts at the attacker placement")
  local last = runtime.x
  for tick = 1, 7 do
    system:stepSourceTick({ tick = tick })
    path:stepSourceTick({ tick = tick })
    Assert.isTrue(runtime.x > last, "the emitter advances toward the defender every tick")
    last = runtime.x
  end
  for tick = 8, 14 do
    system:stepSourceTick({ tick = tick })
    path:stepSourceTick({ tick = tick })
  end
  Assert.near(runtime.x, -2, 0.05, "the 14-tick motion ends on the defender placement")
  for tick = 15, 30 do
    system:stepSourceTick({ tick = tick })
    path:stepSourceTick({ tick = tick })
  end
  Assert.equal(path:status(), "complete", "the path completes once the motion ends and the particles fade")
  Assert.equal(emitter:status(), "complete", "the path task removes the emitter")
  system:dispose()
end

function T.path_task_fails_without_an_emitter_and_the_curved_path_plays_nothing()
  local scene = BattleScene.new()
  local ctx = context()
  local system = loadSystem(scene, nil, ctx)
  Assert.throws(function()
    BattleEffectTasks.create(BattleEffectTasks.EMITTER_BATTLER_PATH_KIND, pathArgs(), ctx, {})
  end, "a path over an empty emitter slot fails")
  local curved = BattleEffectTasks.create(BattleEffectTasks.EMITTER_CURVED_PATH_KIND, pathArgs(), ctx, {})
  Assert.equal(curved:status(), "complete", "the curved path is not reproduced")
  Assert.equal(ctx.particles.skipped[1], "curved emitter path", "the curved path is recorded as unplayed")
  Assert.throws(function()
    createEmitter(ctx)
    BattleEffectTasks.create(BattleEffectTasks.EMITTER_BATTLER_PATH_KIND, pathArgs({ durationTicks = 0 }), ctx, {})
  end, "a zero-duration path fails")
  system:dispose()
end

return { tests = T, metadata = { capabilities = {} } }
