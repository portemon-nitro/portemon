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
    -- Every kind column repeats the kind-0 vectors in the shared
    -- helper; dedicated kind tests stage distinct vectors per kind.
    local kinds = {}
    for _ = 1, 12 do
      kinds[#kinds + 1] = { { x = x, y = -1, z = 0 }, { x = x + 0.5, y = -1, z = 0 } }
    end
    result[position] = kinds
    x = x + 2
  end
  return result
end

local function axisTables()
  local tables = {}
  for _, mode in ipairs({ "mode1", "mode10" }) do
    local entries = {}
    for _ = 1, 36 do
      entries[#entries + 1] = { x = 1, y = 0, z = 0 }
    end
    tables[mode] = entries
  end
  return tables
end

local function payload(emitters)
  return {
    seed = 0,
    emitters = emitters or { emitterRecord({ persistent = true }) },
    textures = { { id = 0, width = 8, height = 8, image = "texture/0" } },
    placements = placements(),
    axisTables = axisTables(),
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

function T.unsupported_members_fail_loudly_and_release_the_lease()
  local scene = BattleScene.new()
  local ctx = context()
  local svc, journal = services(scene, { unsupported = "draw kind 2" })
  Assert.throws(function()
    BattleEffectTasks.create(
      BattleEffectTasks.PARTICLE_SYSTEM_KIND,
      { systemIndex = 0, resource = "system" },
      ctx,
      svc
    )
  end, "an uncompilable particle member fails instead of playing nothing")
  Assert.equal(#journal.released, #journal.acquired, "the failed load releases its lease")
  Assert.equal(#scene:particleSystems(), 0, "nothing is registered for drawing")
  Assert.isNil(ctx.particles.systems[0], "the failed load occupies no system slot")
end

-- A configured emitter resolves its battler order, kind-4 placement,
-- and table-driven axis instead of playing nothing: the occurrence
-- attacker anchors kind 4 while the defender selects the axis row.
function T.configured_emitters_place_by_battler_kind_and_configured_axis()
  local scene = BattleScene.new()
  local ctx = context()
  local atoms = payload()
  atoms.placements["solo-player"][5][1] = { x = 10, y = 20, z = 30 }
  atoms.axisTables.mode10[2] = { x = 4000 / 4096, y = 2000 / 4096, z = 1000 / 4096 }
  local system = loadSystem(scene, atoms, ctx)
  local emitter = assert(BattleEffectTasks.create(
    BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
    {
      systemIndex = 0,
      emitter = 0,
      actionProfile = "particle-emitter-battler-class-camera-position",
      emitterConfig = { zMode = 0, battlerOrder = 2, positionMode = 16, axisMode = 10, flags = 0, cameraMode = 0 },
    },
    ctx,
    {}
  ))
  local runtime = system.simulation.emitters[1]
  Assert.notNil(runtime, "the configured emitter joins the simulation")
  Assert.equal(runtime.x, 10, "kind 4 of the attacker slot stages the emitter x")
  Assert.equal(runtime.y, 20, "kind 4 of the attacker slot stages the emitter y")
  Assert.equal(runtime.z, 30, "kind 4 of the attacker slot stages the emitter z")
  -- The axis rides the simulation record the emitter actually runs
  -- with, so the test observes composed runtime state instead of a
  -- private task field.
  local axis = assert(runtime.record.axis, "the configured emitter stages its axis on its simulation record")
  Assert.near(axis.x, 4000 / 4096, 1e-9, "the axis table stages the configured x")
  Assert.near(axis.y, 2000 / 4096, 1e-9, "the axis table stages the configured y")
  Assert.near(axis.z, 500 / 4096, 1e-9, "the axis table halves the configured z")
  Assert.equal(emitter:status(), "running", "a live configured emitter holds its task")
  emitter:cancel("test")
  emitter:dispose()
  system:dispose()
end

-- A defender-side callback places the emitter over the defender
-- side's solo slot without claiming a battler-anchored visual.
function T.defender_side_callbacks_place_over_the_defender_side()
  local scene = BattleScene.new()
  local ctx = context()
  local system = loadSystem(scene, nil, ctx)
  local emitter = assert(BattleEffectTasks.create(
    BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
    { systemIndex = 0, emitter = 0, actionProfile = "particle-emitter-battler-pair-orientation" },
    ctx,
    {}
  ))
  local runtime = system.simulation.emitters[1]
  Assert.notNil(runtime, "the defender-side emitter joins the simulation")
  Assert.equal(runtime.x, -2, "the foe-side defender resolves the enemy solo placement")
  Assert.equal(emitter:status(), "running", "a live defender-side emitter holds its task")
  emitter:cancel("test")
  emitter:dispose()
  system:dispose()
end

function T.configured_offset_modes_apply_their_signed_script_block()
  local scene = BattleScene.new()
  local ctx = context()
  local atoms = payload()
  atoms.placements["solo-player"][1][1] = { x = 100, y = 0, z = 0 }
  local system = loadSystem(scene, atoms, ctx)
  local emitter = assert(BattleEffectTasks.create(
    BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
    {
      systemIndex = 0,
      emitter = 0,
      actionProfile = "particle-emitter-battler-class-camera-position",
      emitterConfig = { zMode = 0, battlerOrder = 1, positionMode = 5, axisMode = 0, flags = 0, cameraMode = 0 },
      emitterOffset = { x = 4096, y = 0, z = 0, ignoreSide = 0 },
    },
    ctx,
    {}
  ))
  local runtime = system.simulation.emitters[1]
  Assert.notNil(runtime, "the configured emitter joins the simulation")
  Assert.equal(runtime.x, 99, "the foe-side order mirrors the script offset against kind 0")
  Assert.equal(runtime.y, 0, "the offset carries no vertical component")
  Assert.equal(emitter:status(), "running", "a live configured emitter holds its task")
  emitter:cancel("test")
  emitter:dispose()
  system:dispose()
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

function T.emitter_creation_fails_loudly_outside_the_replay_vocabulary()
  local scene = BattleScene.new()
  local ctx = context()
  local system = loadSystem(scene, nil, ctx)
  Assert.throws(function()
    createEmitter(ctx, { actionProfile = "particle-emitter-battler-pair-position" })
  end, "an emitter callback the replay does not reproduce fails")
  ctx.particles.flipY[0] = 1
  Assert.throws(function()
    createEmitter(ctx)
  end, "a flipped particle camera fails")
  ctx.particles.flipY[0] = 0
  ctx.topology.targets = { { slot = "solo-enemy" }, { slot = "enemy-side-slot-1" } }
  Assert.throws(function()
    createEmitter(ctx)
  end, "an emitter placed at one of several targets fails")
  Assert.equal(#system.simulation.emitters, 0, "failed creations add no emitters")
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

function T.path_task_fails_without_an_emitter_and_the_curved_path_fails_loudly()
  local scene = BattleScene.new()
  local ctx = context()
  local system = loadSystem(scene, nil, ctx)
  Assert.throws(function()
    BattleEffectTasks.create(BattleEffectTasks.EMITTER_BATTLER_PATH_KIND, pathArgs(), ctx, {})
  end, "a path over an empty emitter slot fails")
  Assert.throws(function()
    BattleEffectTasks.create(BattleEffectTasks.EMITTER_CURVED_PATH_KIND, pathArgs(), ctx, {})
  end, "the unreproduced curved path fails instead of playing nothing")
  Assert.throws(function()
    createEmitter(ctx)
    BattleEffectTasks.create(BattleEffectTasks.EMITTER_BATTLER_PATH_KIND, pathArgs({ durationTicks = 0 }), ctx, {})
  end, "a zero-duration path fails")
  system:dispose()
end

return { tests = T, metadata = { capabilities = {} } }
