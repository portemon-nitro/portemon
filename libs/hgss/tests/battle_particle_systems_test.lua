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
  for _, mode in ipairs({ "mode1", "mode8", "mode10", "mode12", "mode14", "mode16", "mode18", "mode20" }) do
    local entries = {}
    for _ = 1, 36 do
      entries[#entries + 1] = { x = 1, y = 0, z = 0 }
    end
    tables[mode] = entries
  end
  return tables
end

local function zeroOffsets()
  local offsets = {}
  for _ = 1, 36 do
    offsets[#offsets + 1] = 0
  end
  return offsets
end

local function zeroPairs(count)
  local pairs = {}
  for _ = 1, count do
    pairs[#pairs + 1] = { x = 0, y = 0 }
  end
  return pairs
end

local function emitterTables()
  local rows = {}
  for _ = 1, 7 do
    rows[#rows + 1] = { x = 0, y = 0, z = 0, mirrorFlag = 1 }
  end
  local angles = {}
  for _ = 1, 6 do
    angles[#angles + 1] = { x = 0, y = 0, z = 0 }
  end
  return {
    offsetX = zeroOffsets(),
    offsetY = zeroOffsets(),
    axisBase = { x = 0, y = 0, z = 0, mirrorFlag = 1 },
    axisRows = rows,
    axisPositions = zeroPairs(6),
    position30 = zeroPairs(7),
    position31 = zeroPairs(6),
    position32 = zeroPairs(7),
    cameraAngles = angles,
  }
end

local function payload(emitters)
  return {
    emitters = emitters or { emitterRecord({ persistent = true }) },
    textures = { { id = 0, width = 8, height = 8, image = "texture/0" } },
    placements = placements(),
    axisTables = axisTables(),
    emitterTables = emitterTables(),
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
  return { scene = scene, audio = {}, resources = resources, splRandomState = { state = 0 } }, journal
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

function T.system_loads_publish_compiled_texture_alpha_usage_for_classification()
  -- The compiled per-texture alpha usage rides the draw view beside
  -- the staged handles: the shared Gx classification discards
  -- transparent texels instead of writing depth on the opaque path.
  -- Systems with no usage table keep the picture blanket in the
  -- renderer; a system that stages a table but drops an entry fails
  -- loudly at render instead of hardening translucent texels.
  local scene = BattleScene.new()
  local ctx = context()
  local usage = { hasZero = true, hasPartial = true, hasOpaque = true }
  local system, _ = loadSystem(scene, {
    emitters = { emitterRecord({ persistent = true }) },
    textures = {
      { id = 0, width = 8, height = 8, image = "texture/0", alphaUsage = usage },
      { id = 1, width = 8, height = 8, image = "texture/1" },
    },
    placements = placements(),
    axisTables = axisTables(),
    emitterTables = emitterTables(),
  }, ctx)
  local view = scene:particleSystems()[1]
  Assert.notNil(view, "the loaded system is registered for drawing")
  Assert.deepEqual(
    view.textureAlphaUsage[0],
    usage,
    "compiled per-texture alpha usage rides the draw view"
  )
  Assert.isNil(
    view.textureAlphaUsage[1],
    "textures without compiled usage fall back to the picture blanket"
  )
  system:free()
  system:dispose()
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
  atoms.axisTables.mode10[2] = { x = 4000 / 4096, y = 0, z = 0 }
  atoms.axisTables.mode8[2] = { x = 0, y = 2000 / 4096, z = 1000 / 4096 }
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
    createEmitter(ctx, { actionProfile = "particle-emitter-active-pair-position" })
  end, "an emitter callback outside the staged vocabulary fails")
  ctx.particles.flipY[0] = 1
  local flipped = createEmitter(ctx)
  Assert.equal(
    system.simulation.camera.upY,
    -4096,
    "a flipped creation negates the manager camera up once instead of failing"
  )
  local twice = createEmitter(ctx, { continuationSlot = 4 })
  Assert.equal(
    system.simulation.camera.upY,
    4096,
    "a second flipped creation toggles the camera up back"
  )
  flipped:cancel("test")
  flipped:dispose()
  twice:cancel("test")
  twice:dispose()
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

local function curveArgs(overrides)
  local parameters = {
    emitterContextSlot = 0,
    horizontalOffset = 0,
    verticalOffset = 0,
    durationTicks = 0,
    curveControl = 14,
    curveScale = 16,
    battlerOrder = "attacker-target",
    initialInterpolationSteps = 0,
    completionLimit = 255,
    sinusoidalOffset = false,
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

function T.path_task_fails_without_an_emitter_and_the_curved_path_needs_one_staged()
  local scene = BattleScene.new()
  local ctx = context()
  local system = loadSystem(scene, payload({ emitterRecord({ persistent = true, particleLife = 3 }) }), ctx)
  Assert.throws(function()
    BattleEffectTasks.create(BattleEffectTasks.EMITTER_BATTLER_PATH_KIND, pathArgs(), ctx, {})
  end, "a path over an empty emitter slot fails")
  Assert.throws(function()
    BattleEffectTasks.create(BattleEffectTasks.EMITTER_CURVED_PATH_KIND, curveArgs(), ctx, {})
  end, "a curve over an empty emitter slot fails like the straight path")
  createEmitter(ctx)
  local curved = assert(
    BattleEffectTasks.create(BattleEffectTasks.EMITTER_CURVED_PATH_KIND, curveArgs(), ctx, {}),
    "the curved path constructs once its emitter slot holds a persistent emitter"
  )
  local runtime = system.simulation.emitters[1]
  local startX = runtime.x
  system:stepSourceTick({ tick = 1 })
  curved:stepSourceTick({ tick = 1 })
  Assert.isTrue(runtime.x ~= startX, "the staged curve moves its emitter instead of standing still")
  for tick = 2, 60 do
    system:stepSourceTick({ tick = tick })
    curved:stepSourceTick({ tick = tick })
  end
  Assert.equal(curved:status(), "complete", "the curve completes once its motion ends and the particles fade")
  Assert.throws(function()
    BattleEffectTasks.create(
      BattleEffectTasks.EMITTER_CURVED_PATH_KIND,
      curveArgs({ curveControl = 0 }),
      ctx,
      {}
    )
  end, "a zero-duration curve fails")
  system:dispose()
end

-- A relative-offset emitter shifts the immutable resource base by its
-- source pixel offsets without consuming random draws: the base stays the
-- placement the callback selected, the offsets ride the argument setter.
function T.relative_offset_emitters_shift_the_resource_base_without_random_draws()
  local scene = BattleScene.new()
  local ctx = context()
  local system = loadSystem(scene, nil, ctx)
  local ok, emitter = pcall(
    BattleEffectTasks.create,
    BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
    { systemIndex = 0, emitter = 0, actionProfile = "particle-emitter-relative-offset", offsetX = 3, offsetY = -2 },
    ctx,
    {}
  )
  Assert.isTrue(
    ok,
    "relative-offset emitters execute their source offsets instead of rejecting "
      .. "the callback: " .. tostring(emitter)
  )
  if ok then
    local runtime = system.simulation.emitters[1]
    Assert.notNil(runtime, "the offset emitter joins the simulation")
    Assert.near(runtime.x, (3 * 172) / 4096, 1e-9, "offset x shifts the resource base in world units")
    Assert.near(runtime.y, (-2 * 172) / 4096, 1e-9, "offset y shifts the resource base in world units")
    emitter:cancel("test")
    emitter:dispose()
  end
  system:dispose()
end

-- A configured flag mask targets the mutable per-manager field instead of
-- a second placement: gravity mode 1 writes the signed script vector so
-- every emitter sharing the manager resource feels it.
function T.configured_flag_masks_target_the_shared_field()
  local scene = BattleScene.new()
  local ctx = context()
  local system = loadSystem(scene, nil, ctx)
  local ok, emitter = pcall(
    BattleEffectTasks.create,
    BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
    {
      systemIndex = 0,
      emitter = 0,
      actionProfile = "particle-emitter-battler-class-camera-position",
      emitterConfig = { zMode = 0, battlerOrder = 2, positionMode = 1, axisMode = 0, flags = 2, cameraMode = 0 },
      fieldScripts = { { mask = 2, mode = 1, ignoreSide = 0, x = 100, y = -200, z = 50 } },
    },
    ctx,
    {}
  )
  Assert.isTrue(
    ok,
    "configured flag masks stage their field instead of rejecting the mask: " .. tostring(emitter)
  )
  if ok then
    emitter:cancel("test")
    emitter:dispose()
  end
  system:dispose()
end

-- A configured camera preset replaces the manager camera angle without
-- inventing roll: the stored z angle never steers the eye position.
function T.configured_camera_presets_replace_the_angle_without_rolling()
  local scene = BattleScene.new()
  local ctx = context()
  local system = loadSystem(scene, nil, ctx)
  local ok, emitter = pcall(
    BattleEffectTasks.create,
    BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
    {
      systemIndex = 0,
      emitter = 0,
      actionProfile = "particle-emitter-battler-class-camera-position",
      emitterConfig = { zMode = 0, battlerOrder = 2, positionMode = 1, axisMode = 0, flags = 0, cameraMode = 1 },
    },
    ctx,
    {}
  )
  Assert.isTrue(
    ok,
    "configured camera presets execute instead of rejecting the camera mode: " .. tostring(emitter)
  )
  if ok then
    emitter:cancel("test")
    emitter:dispose()
  end
  system:dispose()
end

-- Two emitters of one ordinal share the manager field mutation while a
-- sibling manager and the cached payload stay independent.
function T.configured_gravity_reaches_same_ordinal_emitters_only()
  local scene = BattleScene.new()
  local ctx = context()
  local staged = payload({ emitterRecord({ persistent = true }) })
  local system = loadSystem(scene, staged, ctx)
  local function configured(slot)
    return BattleEffectTasks.create(
      BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
      {
        systemIndex = 0,
        emitter = 0,
        continuationSlot = slot,
        actionProfile = "particle-emitter-battler-class-camera-position",
        emitterConfig = { zMode = 0, battlerOrder = 2, positionMode = 1, axisMode = 0, flags = 2, cameraMode = 0 },
        fieldScripts = { { mask = 2, mode = 1, ignoreSide = 0, x = 0, y = -4096, z = 0 } },
      },
      ctx,
      {}
    )
  end
  local first, second = configured(0), configured(1)
  for tick = 1, 3 do
    system:stepSourceTick({ tick = tick })
  end
  for index, runtime in ipairs(system.simulation.emitters) do
    local particle = runtime.particles[1]
    Assert.notNil(particle, "emitter " .. index .. " holds its particle")
    Assert.isTrue(particle.y < 0, "emitter " .. index .. " falls with the shared gravity")
  end
  first:cancel("test")
  first:dispose()
  second:cancel("test")
  second:dispose()
  Assert.equal(#staged.emitters[1].fields, 0, "the cached payload keeps no manager field mutation")
  local other = loadSystem(scene, staged, context())
  Assert.equal(#other.simulation.resources[1].fields, 0, "a sibling manager loads clean fields")
  system:dispose()
  other:dispose()
end

-- Gravity modes other than 1 subtract the configured position from zero;
-- position mode 0 leaves that variable uninitialized and rejects.
function T.configured_gravity_fallthrough_subtracts_the_configured_position()
  local scene = BattleScene.new()
  local ctx = context()
  local system = loadSystem(scene, nil, ctx)
  local emitter = BattleEffectTasks.create(
    BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
    {
      systemIndex = 0,
      emitter = 0,
      actionProfile = "particle-emitter-battler-class-camera-position",
      emitterConfig = { zMode = 0, battlerOrder = 2, positionMode = 1, axisMode = 0, flags = 2, cameraMode = 0 },
      fieldScripts = { { mask = 2, mode = 0, ignoreSide = 0, x = 0, y = 0, z = 0 } },
    },
    ctx,
    {}
  )
  local gravity = nil
  for _, field in ipairs(system.simulation.resources[1].fields) do
    if field.kind == "gravity" then
      gravity = field
    end
  end
  Assert.notNil(gravity, "the fallthrough stages the shared gravity field")
  -- Attacker kind-0 solo-player placement is (-4, -1, 0); the fallthrough
  -- negates it componentwise.
  Assert.deepEqual(
    { x = gravity.magnitude.x, y = gravity.magnitude.y, z = gravity.magnitude.z },
    { x = 4, y = 1, z = 0 },
    "mode 0 writes zero minus the configured position"
  )
  emitter:cancel("test")
  emitter:dispose()
  Assert.throws(function()
    BattleEffectTasks.create(
      BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
      {
        systemIndex = 0,
        emitter = 0,
        continuationSlot = 2,
        actionProfile = "particle-emitter-battler-class-camera-position",
        emitterConfig = { zMode = 0, battlerOrder = 2, positionMode = 0, axisMode = 0, flags = 2, cameraMode = 0 },
        fieldScripts = { { mask = 2, mode = 0, ignoreSide = 0, x = 0, y = 0, z = 0 } },
      },
      ctx,
      {}
    )
  end, "a fallthrough reading position mode 0 rejects its uninitialized variable")
  system:dispose()
end

-- Z modes 1 and 2 select by the defender type through the
-- argument-space setter; mode 3 rejects its undefined native local.
function T.configured_z_modes_select_by_defender_type()
  local scene = BattleScene.new()
  local ctx = context()
  local system = loadSystem(scene, nil, ctx)
  local function configured(zMode, slot)
    return BattleEffectTasks.create(
      BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
      {
        systemIndex = 0,
        emitter = 0,
        continuationSlot = slot,
        actionProfile = "particle-emitter-battler-class-camera-position",
        emitterConfig = { zMode = zMode, battlerOrder = 2, positionMode = 1, axisMode = 0, flags = 0, cameraMode = 0 },
      },
      ctx,
      {}
    )
  end
  local one = configured(1, 0)
  Assert.near(
    system.simulation.emitters[1].z,
    -5120 / 4096,
    1e-9,
    "z mode 1 uses -5120 for a nonzero defender type"
  )
  one:cancel("test")
  one:dispose()
  local two = configured(2, 1)
  Assert.near(
    system.simulation.emitters[1].z,
    -5376 / 4096,
    1e-9,
    "z mode 2 uses -5376 for a nonzero defender type"
  )
  two:cancel("test")
  two:dispose()
  Assert.throws(function()
    configured(3, 2)
  end, "z mode 3 rejects its undefined native local")
  system:dispose()
end

-- Configured camera modes drive the manager camera: presets install
-- their angles and force orthographic depth, mode 0 resets the angles,
-- and target modes retarget without moving the eye.
function T.configured_camera_modes_drive_the_manager_camera()
  local scene = BattleScene.new()
  local ctx = context()
  local system = loadSystem(scene, nil, ctx)
  local function configured(cameraMode, slot, extra)
    local args = {
      systemIndex = 0,
      emitter = 0,
      continuationSlot = slot,
      actionProfile = "particle-emitter-battler-class-camera-position",
      emitterConfig = { zMode = 0, battlerOrder = 2, positionMode = 1, axisMode = 0, flags = 0, cameraMode = cameraMode },
    }
    for key, value in pairs(extra or {}) do
      args[key] = value
    end
    return BattleEffectTasks.create(BattleEffectTasks.PARTICLE_CONTINUATION_KIND, args, ctx, {})
  end
  local preset = configured(1, 0)
  local camera = system.simulation.camera
  Assert.equal(camera.angleX, 8192, "preset 4 installs its x angle")
  Assert.equal(camera.angleY, 8192, "preset 4 installs its y angle")
  Assert.equal(camera.angleZ, 0, "the stored z angle never rolls")
  Assert.equal(camera.perspective, 1, "a preset forces orthographic projection")
  preset:cancel("test")
  preset:dispose()
  local reset = configured(0, 1)
  Assert.deepEqual(
    { x = camera.angleX, y = camera.angleY, z = camera.angleZ },
    { x = 0, y = 0, z = 0 },
    "camera mode 0 resets the angles preserving target and distance"
  )
  Assert.equal(camera.targetX, 0, "the reset keeps the target")
  reset:cancel("test")
  reset:dispose()
  local targeted = configured(7, 2)
  Assert.equal(camera.targetX, -4, "camera mode 7 targets the attacker kind-10 placement x")
  Assert.equal(camera.targetY, -1, "camera mode 7 targets the attacker kind-10 placement y")
  targeted:cancel("test")
  targeted:dispose()
  Assert.throws(function()
    configured(2, 3)
  end, "camera mode 2 without its angle triple rejects instead of inventing angles")
  local angled = configured(2, 4, { cameraAngles = { x = 100, y = 200, z = 300 } })
  Assert.equal(camera.angleX, 100, "camera mode 2 carries its angle triple")
  angled:cancel("test")
  angled:dispose()
  system:dispose()
end

-- The production randomized-position profile shares the relative-offset
-- handler: the immutable base plus pixel offsets with no random draws.
function T.production_randomized_position_profile_shares_the_offset_handler()
  local scene = BattleScene.new()
  local ctx = context()
  local system = loadSystem(scene, payload({ emitterRecord({ persistent = true }) }), ctx)
  local before = system.simulation.randomState.state
  local emitter = BattleEffectTasks.create(
    BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
    {
      systemIndex = 0,
      emitter = 0,
      actionProfile = "particle-emitter-randomized-position",
      offsetX = 3,
      offsetY = -2,
    },
    ctx,
    {}
  )
  local runtime = system.simulation.emitters[1]
  Assert.near(runtime.x, 3 * 172 / 4096, 1e-9, "the production profile shifts the base by pixel offsets")
  Assert.near(runtime.y, -2 * 172 / 4096, 1e-9, "both axes shift")
  Assert.equal(system.simulation.randomState.state, before, "the placement consumes no random values")
  emitter:cancel("test")
  emitter:dispose()
  system:dispose()
end

-- Every defined configured position mode selects its staged kind,
-- literal, table, or side placement through the native argument-space
-- setter, with script offsets mirrored exactly like the source reader.
function T.configured_position_modes_cover_all_defined_kinds_and_tables()
  local scene = BattleScene.new()
  local ctx = context()
  local staged = payload({ emitterRecord({ persistent = true }) })
  for _, position in ipairs({
    "solo-player",
    "solo-enemy",
    "player-side-slot-1",
    "enemy-side-slot-1",
    "player-side-slot-2",
    "enemy-side-slot-2",
  }) do
    local kinds = {}
    for kindIndex = 0, 11 do
      local vector = { x = kindIndex, y = -kindIndex, z = kindIndex }
      kinds[#kinds + 1] = { vector, { x = vector.x, y = vector.y, z = vector.z } }
    end
    staged.placements[position] = kinds
  end
  staged.emitterTables.position30[1] = { x = 70, y = 80 }
  staged.emitterTables.position31[1] = { x = 90, y = 100 }
  staged.emitterTables.position32[1] = { x = 110, y = 120 }
  local system = loadSystem(scene, staged, ctx)
  local kindsOf = staged.placements
  local function expectPlaced(args, expected, message)
    args.systemIndex = 0
    args.emitter = 0
    args.actionProfile = "particle-emitter-battler-class-camera-position"
    local emitter = BattleEffectTasks.create(BattleEffectTasks.PARTICLE_CONTINUATION_KIND, args, ctx, {})
    local runtime = system.simulation.emitters[#system.simulation.emitters]
    Assert.deepEqual({ x = runtime.x, y = runtime.y, z = runtime.z }, expected, message)
    emitter:cancel("test")
    emitter:dispose()
  end
  local function configured(positionMode, extra)
    local args = {
      continuationSlot = 0,
      emitterConfig = { zMode = 0, battlerOrder = 2, positionMode = positionMode, axisMode = 0, flags = 0, cameraMode = 0 },
    }
    for key, value in pairs(extra or {}) do
      args[key] = value
    end
    return args
  end
  local attackerKinds = kindsOf["solo-player"]
  local defenderKinds = kindsOf["solo-enemy"]
  local cases = {
    { 1, attackerKinds[1][1] },
    { 2, defenderKinds[1][1] },
    { 6, attackerKinds[2][1] },
    { 7, defenderKinds[2][1] },
    { 8, attackerKinds[12][1] },
    { 9, defenderKinds[12][1] },
    { 10, attackerKinds[3][1] },
    { 11, defenderKinds[3][1] },
    { 14, attackerKinds[4][1] },
    { 15, defenderKinds[4][1] },
    { 16, attackerKinds[5][1] },
    { 17, defenderKinds[5][1] },
    { 18, attackerKinds[6][1] },
    { 19, defenderKinds[6][1] },
    { 20, attackerKinds[7][1] },
    { 21, defenderKinds[7][1] },
    { 22, attackerKinds[8][1] },
    { 23, defenderKinds[8][1] },
    { 24, attackerKinds[9][1] },
    { 25, defenderKinds[9][1] },
    { 26, attackerKinds[10][1] },
    { 27, defenderKinds[10][1] },
    { 28, { x = 11488 / 4096, y = 0, z = 0 } },
    { 30, { x = 70, y = 80, z = 0 } },
    { 31, { x = 90, y = 100, z = 0 } },
    { 32, { x = 110, y = 120, z = 0 } },
    { 33, { x = -5000 / 4096, y = -6000 / 4096, z = 0 } },
    { 34, attackerKinds[1][1] },
  }
  for index, case in ipairs(cases) do
    expectPlaced(configured(case[1]), case[2], "position mode " .. case[1] .. " places its staged vector (case " .. index .. ")")
  end
  local offset = { x = 4096, y = -8192, z = 12288, ignoreSide = 0 }
  expectPlaced(
    configured(3, { emitterOffset = offset }),
    { x = 1, y = -2, z = 3 },
    "position mode 3 carries the offset alone"
  )
  expectPlaced(
    configured(4, { emitterOffset = offset }),
    { x = 0 + 1, y = 0 - 2, z = 0 + 3 },
    "position mode 4 mirrors all three offset components onto kind 0"
  )
  expectPlaced(
    configured(5, { emitterOffset = offset }),
    { x = 0 + 1, y = 0 - 2, z = 0 + 3 },
    "position mode 5 mirrors all three offset components onto the defender kind 0"
  )
  expectPlaced(
    configured(12, { emitterOffset = offset }),
    { x = 0 + 1, y = 0 - 2, z = 0 + 3 },
    "position mode 12 adds its offset to the attacker side solo placement"
  )
  expectPlaced(
    configured(13, { emitterOffset = offset }),
    { x = 0 + 1, y = 0 - 2, z = 0 + 3 },
    "position mode 13 adds its offset to the defender side solo placement"
  )
  local typeOffsets = {}
  for _ = 1, 6 do
    typeOffsets[#typeOffsets + 1] = { x = 0, y = 0, z = 0, ignoreSide = 0 }
  end
  typeOffsets[1] = { x = 4096, y = 8192, z = 12288, ignoreSide = 0 }
  typeOffsets[2] = { x = 100, y = 200, z = 300, ignoreSide = 1 }
  expectPlaced(
    configured(100, { typeOffsets = typeOffsets }),
    { x = 0 + 1, y = 0 + 2, z = 0 + 3 },
    "position mode 100 adds the attacker type block to kind 0"
  )
  expectPlaced(
    configured(101, { typeOffsets = typeOffsets }),
    { x = 0 + 100 / 4096, y = 0 + 200 / 4096, z = 0 + 300 / 4096 },
    "position mode 101 adds the defender type block to kind 0"
  )
  local foeCtx = context()
  foeCtx.topology.attacker = { slot = "solo-enemy" }
  foeCtx.topology.targets = { { slot = "solo-player" } }
  local foeScene = BattleScene.new()
  local foeStaged = payload({ emitterRecord({ persistent = true }) })
  local foeSystem = loadSystem(foeScene, foeStaged, foeCtx)
  local foeOffset = { x = 0, y = 0, z = 12288, ignoreSide = 0 }
  local function foePlaced(positionMode)
    local emitter = BattleEffectTasks.create(
      BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
      {
        systemIndex = 0,
        emitter = 0,
        continuationSlot = 0,
        actionProfile = "particle-emitter-battler-class-camera-position",
        emitterConfig = { zMode = 0, battlerOrder = 2, positionMode = positionMode, axisMode = 0, flags = 0, cameraMode = 0 },
        emitterOffset = foeOffset,
      },
      foeCtx,
      {}
    )
    local runtime = foeSystem.simulation.emitters[#foeSystem.simulation.emitters]
    local position = { x = runtime.x, y = runtime.y, z = runtime.z }
    emitter:cancel("test")
    emitter:dispose()
    return position
  end
  Assert.deepEqual(
    foePlaced(3),
    { x = 0, y = 0, z = 3 },
    "position mode 3 leaves the offset z unmirrored"
  )
  Assert.deepEqual(
    foePlaced(4),
    { x = -2 + 0, y = -1 + 0, z = 0 - 3 },
    "position mode 4 mirrors the offset z onto kind 0"
  )
  foeSystem:dispose()
  Assert.throws(function()
    expectPlaced(configured(29), nil, "unreachable")
  end, "position mode 29 rejects its undefined native local")
  system:dispose()
end

-- Every defined configured axis mode resolves its staged vector exactly
-- like the native lookup: per-pair tables with their divisors, static
-- rows with the native flag choices, and source literals.
function T.configured_axis_modes_cover_tables_rows_and_literals()
  local scene = BattleScene.new()
  local ctx = context()
  local staged = payload({ emitterRecord({ persistent = true }) })
  staged.axisTables.mode8[2] = { x = 10, y = 20, z = 30 }
  staged.axisTables.mode10[2] = { x = 40, y = 50, z = 60 }
  staged.axisTables.mode12[2] = { x = 70, y = 80, z = 90 }
  staged.emitterTables.axisRows[1] = { x = 1, y = 2, z = 3, mirrorFlag = 0 }
  staged.emitterTables.axisPositions[1] = { x = 11, y = 12 }
  local system = loadSystem(scene, staged, ctx)
  local function expectAxis(axisMode, expected, message)
    local emitter = BattleEffectTasks.create(
      BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
      {
        systemIndex = 0,
        emitter = 0,
        continuationSlot = 0,
        actionProfile = "particle-emitter-battler-class-camera-position",
        emitterConfig = { zMode = 0, battlerOrder = 2, positionMode = 1, axisMode = axisMode, flags = 0, cameraMode = 0 },
      },
      ctx,
      {}
    )
    local runtime = system.simulation.emitters[#system.simulation.emitters]
    Assert.deepEqual({ x = runtime.axis.x, y = runtime.axis.y, z = runtime.axis.z }, expected, message)
    emitter:cancel("test")
    emitter:dispose()
  end
  expectAxis(1, { x = 1, y = 0, z = 0 }, "axis mode 1 reads the staged mode-1 pair vector")
  expectAxis(2, { x = 1, y = 0, z = 0 }, "axis mode 2 reads the staged mode-1 pair vector")
  expectAxis(3, { x = -800 / 4096, y = 1200 / 4096, z = 500 / 4096 }, "axis mode 3 selects its literal")
  expectAxis(8, { x = 10, y = 20, z = 15 }, "axis mode 8 reads the staged mode-8 pair vector with its divisor")
  expectAxis(9, { x = 10, y = 20, z = 15 }, "axis mode 9 mirrors mode 8")
  expectAxis(10, { x = 40, y = 20, z = 15 }, "axis mode 10 takes x from mode 10 and y/z from mode 8")
  expectAxis(12, { x = 70, y = 80, z = 90 }, "axis mode 12 keeps the staged mode-12 z")
  expectAxis(24, { x = 11, y = 12, z = 0 }, "axis mode 24 reads the staged axis position pair")
  expectAxis(25, { x = -3440 / 4096, y = 1952 / 4096, z = 0 }, "axis mode 25 selects its literal")
  expectAxis(26, { x = 3776 / 4096, y = 2112 / 4096, z = 0 }, "axis mode 26 selects by the player attacker side")
  Assert.throws(function()
    expectAxis(23, nil, "unreachable")
  end, "axis mode 23 rejects its undefined native local")
  Assert.throws(function()
    expectAxis(27, nil, "unreachable")
  end, "axis mode 27 rejects its undefined table")
  system:dispose()
end

-- Static axis rows follow the native per-type selection with the
-- documented flag choices, including the partner-sign irregularities.
function T.configured_static_axis_rows_follow_the_native_flag_choices()
  local scene = BattleScene.new()
  local staged = payload({ emitterRecord({ persistent = true }) })
  staged.emitterTables.axisRows[1] = { x = 1, y = 2, z = 3, mirrorFlag = 0 }
  staged.emitterTables.axisRows[3] = { x = 4, y = 5, z = 6, mirrorFlag = 1 }
  staged.emitterTables.axisRows[5] = { x = 7, y = 8, z = 9, mirrorFlag = 0 }
  local staticCtx = context()
  local system = loadSystem(scene, staged, staticCtx)
  local function expectStaticAxis(attackerSlot, defenderSlot, expected, message)
    local ctx = staticCtx
    ctx.topology.attacker = { slot = attackerSlot }
    ctx.topology.targets = { { slot = defenderSlot } }
    local emitter = BattleEffectTasks.create(
      BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
      {
        systemIndex = 0,
        emitter = 0,
        continuationSlot = 0,
        actionProfile = "particle-emitter-battler-class-camera-position",
        emitterConfig = { zMode = 0, battlerOrder = 2, positionMode = 1, axisMode = 6, flags = 0, cameraMode = 0 },
      },
      ctx,
      {}
    )
    local runtime = system.simulation.emitters[#system.simulation.emitters]
    Assert.deepEqual({ x = runtime.axis.x, y = runtime.axis.y, z = runtime.axis.z }, expected, message)
    emitter:cancel("test")
    emitter:dispose()
  end
  expectStaticAxis("solo-enemy", "solo-player", { x = -1, y = -2, z = -3 }, "solo enemy attacker negates row a without its flag")
  expectStaticAxis("player-side-slot-1", "enemy-side-slot-1", { x = 0, y = 0, z = 0 }, "same-side doubles keep the zeroed row b")
  expectStaticAxis(
    "enemy-side-slot-1",
    "enemy-side-slot-2",
    { x = -7, y = -8, z = -9 },
    "the partner sign comes from row c while the axis comes from row e"
  )
  system:dispose()
end

-- Every meaningful configured flag mask mutates the shared manager
-- field in ascending mask order: magnet and convergence select their
-- position and force targets, spin selects its angle and axis, and
-- the side sign applies exactly where the source applies it.
function T.configured_field_masks_cover_magnet_spin_and_convergence()
  local scene = BattleScene.new()
  local ctx = context()
  local staged = payload({ emitterRecord({ persistent = true }) })
  local system = loadSystem(scene, staged, ctx)
  local function configuredField(mask, script, slot)
    return BattleEffectTasks.create(
      BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
      {
        systemIndex = 0,
        emitter = 0,
        continuationSlot = slot or 0,
        actionProfile = "particle-emitter-battler-class-camera-position",
        emitterConfig = { zMode = 0, battlerOrder = 2, positionMode = 1, axisMode = 0, flags = mask, cameraMode = 0 },
        fieldScripts = { script },
      },
      ctx,
      {}
    )
  end
  local function sharedField(fieldKind)
    for _, field in ipairs(system.simulation.resources[1].fields) do
      if field.kind == fieldKind then
        return field
      end
    end
    return nil
  end
  -- Attacker kind-0 solo-player placement is (-4, -1, 0).
  local magnet = configuredField(16, { mask = 16, mode = 1, ignoreSide = 0, x = 4096, y = 8192, z = 12288 }, 0)
  Assert.deepEqual(
    sharedField("magnet").position,
    { x = 1 + 4, y = 2 + 1, z = 3 },
    "magnet mode 1 writes the script vector minus the configured position, keeping target z"
  )
  magnet:cancel("test")
  magnet:dispose()
  local force = configuredField(32, { mask = 32, mode = 1, ignoreSide = 0, x = 500, y = 0, z = 0 }, 1)
  Assert.equal(sharedField("magnet").magnitude, 500 / 4096, "magnet mode 1 narrows the script force")
  force:cancel("test")
  force:dispose()
  local spinAngle = configuredField(64, { mask = 64, mode = 1, ignoreSide = 0, x = 70000, y = 0, z = 0 }, 2)
  Assert.equal(sharedField("spin").rotation, 70000 % 65536, "spin mode 1 wraps the script angle")
  spinAngle:cancel("test")
  spinAngle:dispose()
  local spinAxis = configuredField(128, { mask = 128, mode = 1, ignoreSide = 0, x = 70000, y = 0, z = 0 }, 3)
  Assert.equal(sharedField("spin").axis, 70000 % 65536, "spin mode 1 wraps the script axis without a side sign")
  spinAxis:cancel("test")
  spinAxis:dispose()
  local convergence = configuredField(4096, { mask = 4096, mode = 4, ignoreSide = 0, x = 3, y = 2, z = 0 }, 4)
  Assert.deepEqual(
    sharedField("convergence").position,
    { x = -3 + 4, y = -1.5 + 1, z = 0 },
    "convergence mode 4 scales the defender kind 0 by its script ratio minus the configured position"
  )
  convergence:cancel("test")
  convergence:dispose()
  local ratio = configuredField(8192, { mask = 8192, mode = 1, ignoreSide = 0, x = 40000, y = 0, z = 0 }, 5)
  local narrowed = 40000 % 65536
  Assert.equal(
    sharedField("convergence").ratio,
    narrowed >= 32768 and narrowed - 65536 or narrowed,
    "convergence mode 1 narrows the script force"
  )
  ratio:cancel("test")
  ratio:dispose()
  Assert.throws(function()
    BattleEffectTasks.create(
      BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
      {
        systemIndex = 0,
        emitter = 0,
        continuationSlot = 6,
        actionProfile = "particle-emitter-battler-class-camera-position",
        emitterConfig = { zMode = 0, battlerOrder = 2, positionMode = 0, axisMode = 0, flags = 16, cameraMode = 0 },
        fieldScripts = { { mask = 16, mode = 1, ignoreSide = 0, x = 0, y = 0, z = 0 } },
      },
      ctx,
      {}
    )
  end, "a magnet target reading position mode 0 rejects its uninitialized variable")
  local foeCtx = context()
  foeCtx.topology.attacker = { slot = "solo-enemy" }
  foeCtx.topology.targets = { { slot = "solo-player" } }
  local foeScene = BattleScene.new()
  local foeSystem = loadSystem(foeScene, payload({ emitterRecord({ persistent = true }) }), foeCtx)
  local foeSpin = BattleEffectTasks.create(
    BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
    {
      systemIndex = 0,
      emitter = 0,
      continuationSlot = 0,
      actionProfile = "particle-emitter-battler-class-camera-position",
      emitterConfig = { zMode = 0, battlerOrder = 2, positionMode = 1, axisMode = 0, flags = 128, cameraMode = 0 },
      fieldScripts = { { mask = 128, mode = 1, ignoreSide = 0, x = 100, y = 0, z = 0 } },
    },
    foeCtx,
    {}
  )
  local foeAxis = nil
  for _, field in ipairs(foeSystem.simulation.resources[1].fields) do
    if field.kind == "spin" then
      foeAxis = field.axis
    end
  end
  Assert.equal(foeAxis, 100, "the spin axis ignores the enemy side sign")
  foeSpin:cancel("test")
  foeSpin:dispose()
  local foeAngle = BattleEffectTasks.create(
    BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
    {
      systemIndex = 0,
      emitter = 0,
      continuationSlot = 1,
      actionProfile = "particle-emitter-battler-class-camera-position",
      emitterConfig = { zMode = 0, battlerOrder = 2, positionMode = 1, axisMode = 0, flags = 64, cameraMode = 0 },
      fieldScripts = { { mask = 64, mode = 1, ignoreSide = 0, x = 100, y = 0, z = 0 } },
    },
    foeCtx,
    {}
  )
  local foeRotation = nil
  for _, field in ipairs(foeSystem.simulation.resources[1].fields) do
    if field.kind == "spin" then
      foeRotation = field.rotation
    end
  end
  Assert.equal(foeRotation, 65436, "the spin angle mirrors by the enemy side sign")
  foeAngle:cancel("test")
  foeAngle:dispose()
  foeSystem:dispose()
  system:dispose()
end

-- The physical-battler callbacks place the emitter from fixed battler
-- identity: the first-opponent profile tracks battler 1 with a camera
-- reapply, the battler-0 profile pins battler 0 with the defender
-- indexed up vector, and the attacker-side profile pins its solo slot.
function T.physical_battler_callbacks_place_from_fixed_identity()
  local scene = BattleScene.new()
  local ctx = context()
  local system = loadSystem(scene, nil, ctx)
  local function placed(profile, slot)
    local emitter = BattleEffectTasks.create(
      BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
      { systemIndex = 0, emitter = 0, continuationSlot = slot, actionProfile = profile },
      ctx,
      {}
    )
    local runtime = system.simulation.emitters[#system.simulation.emitters]
    local position = { x = runtime.x, y = runtime.y, z = runtime.z }
    emitter:cancel("test")
    emitter:dispose()
    return position
  end
  Assert.deepEqual(
    placed("particle-emitter-camera-relative", 0),
    { x = -4, y = -1, z = 0 },
    "the first-opponent callback uses the opposing kind 0 on the foe side"
  )
  Assert.deepEqual(
    placed("particle-emitter-world-position", 1),
    { x = -4, y = -1, z = 0 },
    "the battler-0 callback places physical battler 0"
  )
  Assert.equal(
    system.simulation.camera.upY,
    -4096,
    "the battler-0 callback flips the camera up for a nonzero defender index"
  )
  Assert.deepEqual(
    placed("particle-emitter-battler-pair-position", 2),
    { x = -4, y = -1, z = 0 },
    "the attacker-side callback pins the attacker solo kind 0"
  )
  local foeCtx = context()
  foeCtx.topology.attacker = { slot = "solo-enemy" }
  foeCtx.topology.targets = { { slot = "solo-player" } }
  local foeScene = BattleScene.new()
  local foeSystem = loadSystem(foeScene, nil, foeCtx)
  local foeEmitter = BattleEffectTasks.create(
    BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
    { systemIndex = 0, emitter = 0, continuationSlot = 0, actionProfile = "particle-emitter-world-position" },
    foeCtx,
    {}
  )
  Assert.equal(
    foeSystem.simulation.camera.upY,
    4096,
    "the battler-0 callback keeps the default up for defender index 0"
  )
  foeEmitter:cancel("test")
  foeEmitter:dispose()
  foeSystem:dispose()
  system:dispose()
end

-- The pair-transform family shares one script transform: seven axis
-- triples select the axis by ordered battler types, the position
-- triple selects kind 0 or its scaled script placement, and the
-- convergence target resolves before the origin subtraction.
function T.pair_transform_callbacks_share_the_script_transform()
  local scene = BattleScene.new()
  local ctx = context()
  local system = loadSystem(scene, nil, ctx)
  local vectors = {}
  for index = 1, 7 do
    vectors[index] = { x = index * 100, y = index * 100 + 1, z = index * 100 + 2 }
  end
  local function transformed(profile, extra)
    local args = {
      systemIndex = 0,
      emitter = 0,
      continuationSlot = 0,
      actionProfile = profile,
      scriptVectors = vectors,
      scriptPosition = { x = 0, y = 0, z = 0 },
    }
    for key, value in pairs(extra or {}) do
      args[key] = value
    end
    local emitter = BattleEffectTasks.create(BattleEffectTasks.PARTICLE_CONTINUATION_KIND, args, ctx, {})
    local runtime = system.simulation.emitters[#system.simulation.emitters]
    local position = { x = runtime.x, y = runtime.y, z = runtime.z }
    local axis = { x = runtime.axis.x, y = runtime.axis.y, z = runtime.axis.z }
    emitter:cancel("test")
    emitter:dispose()
    return position, axis
  end
  local position, axis = transformed("particle-emitter-position-pair-primary-primary")
  Assert.deepEqual(position, { x = -4, y = -1, z = 0 }, "an all-zero script position keeps the attacker kind 0")
  Assert.deepEqual(
    axis,
    { x = 100 / 4096, y = 101 / 4096, z = 102 / 4096 },
    "solo attacker and defender select the first script triple"
  )
  local scripted = transformed("particle-emitter-position-pair-primary-primary", {
    scriptPosition = { x = 4096, y = 8192, z = 0 },
  })
  Assert.deepEqual(scripted, { x = 1, y = 2, z = 0 }, "the script position scales by the attacker side sign")
  local converged = transformed("particle-emitter-position-pair-primary-partner", {
    scriptPosition = { x = 4096, y = 0, z = 0 },
  })
  local entry = nil
  for _, field in ipairs(system.simulation.resources[1].fields) do
    if field.kind == "convergence" then
      entry = field
    end
  end
  Assert.deepEqual(
    entry.position,
    { x = 0 - 1, y = 0 - 0, z = 0 - 0 },
    "the by-side convergence target scales the current vector before the origin subtraction"
  )
  Assert.deepEqual(converged, { x = 1, y = 0, z = 0 }, "the converge carrier still places its script position")
  local toAttacker = transformed("particle-emitter-position-pair-primary-active", {
    scriptPosition = { x = 4096, y = 0, z = 0 },
  })
  local attackerEntry = nil
  for _, field in ipairs(system.simulation.resources[1].fields) do
    if field.kind == "convergence" then
      attackerEntry = field
    end
  end
  Assert.deepEqual(
    attackerEntry.position,
    { x = -4 - 1, y = -1 - 0, z = 0 - 0 },
    "the attacker convergence target subtracts the final argument-space position"
  )
  Assert.deepEqual(toAttacker, { x = 1, y = 0, z = 0 }, "the attacker carrier still places its script position")
  local scriptedTarget = transformed("particle-emitter-position-pair-secondary-primary", {
    scriptPosition = { x = 4096, y = 0, z = 0 },
    scriptTarget = { x = 8192, y = 16384, z = 24576, scaleKind = 7 },
  })
  local scriptedEntry = nil
  for _, field in ipairs(system.simulation.resources[1].fields) do
    if field.kind == "convergence" then
      scriptedEntry = field
    end
  end
  Assert.deepEqual(
    scriptedEntry.position,
    { x = 2 - 1, y = 4 - 0, z = 6 - 0 },
    "the from-script convergence target scales xyz by the side sign before the origin subtraction"
  )
  Assert.deepEqual(scriptedTarget, { x = 1, y = 0, z = 0 }, "the script-target carrier still places its position")
  system:dispose()
end

function T.draw_phase_captures_pre_advance_geometry_and_advances_exactly_once()
  -- The native draw phase submits the particle geometry before the
  -- simulation tick: the compositor paints the published pre-advance
  -- frame (including newborn and terminal polygons) while every manager
  -- advances exactly once underneath. Repeated draws of the published
  -- frame stay stable.
  local SplParticleDraw = require("libs.hgss.src.presentation.SplParticleDraw")
  local SplParticleSimulation = require("libs.hgss.src.presentation.SplParticleSimulation")
  local scene = BattleScene.new()
  local ctx = context()
  local system, _ = loadSystem(scene, {
    emitters = {
      emitterRecord({ emitterLife = 2, particleLife = 1, velocityFx = { pos = 4096, axis = 0 } }),
    },
    textures = { { id = 0, width = 8, height = 8, image = "texture/0" } },
    placements = placements(),
    axisTables = axisTables(),
    emitterTables = emitterTables(),
  }, ctx)
  local view = scene:particleSystems()[1]
  local sim = view.simulation
  Assert.notNil(
    SplParticleSimulation.addEmitter(sim, 0, nil),
    "the draw phase captures a live emitter"
  )
  -- Before the first draw phase the compositor falls back to the live systems.
  Assert.equal(#scene:drawParticleSystems(), 1, "drawing falls back to the live systems before capture")
  BattleParticleSystems.stepSourceDrawPhase(scene)
  local published = scene:drawParticleSystems()
  Assert.equal(
    #published[1].simulation.emitters[1].particles,
    0,
    "the first capture precedes the first simulation tick"
  )
  Assert.equal(#sim.emitters[1].particles, 1, "the draw phase advances the live simulation once")
  Assert.equal(sim.emitters[1].age, 1, "one draw phase advances the emitter by exactly one tick")
  -- The second capture shows the previous live state while the live
  -- simulation advances underneath it.
  local x1 = sim.emitters[1].particles[1].x
  BattleParticleSystems.stepSourceDrawPhase(scene)
  published = scene:drawParticleSystems()
  Assert.equal(#published[1].simulation.emitters[1].particles, 1, "the terminal polygon stays visible")
  Assert.equal(
    published[1].simulation.emitters[1].particles[1].x,
    x1,
    "the published frame shows the exact pre-update positions"
  )
  Assert.isTrue(
    sim.emitters[1].particles[1].x ~= x1,
    "the live simulation advanced underneath the published frame"
  )
  Assert.equal(sim.emitters[1].age, 2, "the second draw phase advances exactly once more")
  -- Repeated draws of one published frame stay stable without
  -- advancing the simulation or its random stream.
  local function primitivesOf(frame)
    local out = {}
    for _, entry in ipairs(frame) do
      SplParticleDraw.appendPrimitives(entry.simulation, nil, function(_, particle, child)
        local texNo = child ~= nil and child.texNo or particle.texNo
        return entry.textures[texNo]
      end, out)
    end
    return out
  end
  local first = primitivesOf(scene:drawParticleSystems())
  local second = primitivesOf(scene:drawParticleSystems())
  Assert.isTrue(#first > 0, "the terminal polygon reaches the compositor")
  Assert.deepEqual(first, second, "repeated draws of the published frame are stable")
  -- Generation stops once the emitter passes its lifespan; the last
  -- particle retires on the following tick and the published frame
  -- after that clears.
  BattleParticleSystems.stepSourceDrawPhase(scene)
  published = scene:drawParticleSystems()
  Assert.equal(
    #published[1].simulation.emitters[1].particles,
    1,
    "the final particle stays visible through its last frame"
  )
  BattleParticleSystems.stepSourceDrawPhase(scene)
  published = scene:drawParticleSystems()
  Assert.equal(
    #published[1].simulation.emitters,
    0,
    "the retired emitter clears on the following frame"
  )
  system:free()
  system:dispose()
end

return { tests = T, metadata = { capabilities = {} } }
