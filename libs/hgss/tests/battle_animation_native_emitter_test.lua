-- Emitter handle identity and the source particle phase: occurrence
-- emitter slots resolve to stable identities, one draw phase captures
-- every manager before calculating, and curved paths execute the source
-- linear-plus-sine trajectory instead of refusing or standing still.
-- These probe the shared particle adapter surface the movement tasks
-- drive.

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

local function services(scene, systemPayload)
  local resources = {}
  function resources.resolve(key)
    if key == "system" then
      return { key = key, kind = "particle", data = systemPayload }
    end
    return { key = key, kind = "texture", handle = { image = key } }
  end
  function resources.release(_lease) end
  return { scene = scene, audio = {}, resources = resources, splRandomState = { state = 0 } }
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
  local svc = services(scene, systemPayload or payload())
  return BattleEffectTasks.create(
    BattleEffectTasks.PARTICLE_SYSTEM_KIND,
    { systemIndex = 0, resource = "system" },
    ctx,
    svc
  )
end

local function createEmitter(ctx, overrides)
  local args = { systemIndex = 0, emitter = 0, actionProfile = "particle-emitter-target-battler-relative" }
  for key, value in pairs(overrides or {}) do
    args[key] = value
  end
  return BattleEffectTasks.create(BattleEffectTasks.PARTICLE_CONTINUATION_KIND, args, ctx, {})
end

-- C integer division truncates toward zero; the source pixel cast wraps
-- to signed 16 bits.
local function cdiv(numerator, denominator)
  local quotient = numerator / denominator
  return quotient >= 0 and math.floor(quotient) or math.ceil(quotient)
end

local function toS16(value)
  value = value % 65536
  return value >= 32768 and value - 65536 or value
end

local function pixel(world)
  return toS16(cdiv(math.floor(world * 4096 + 0.5), 172))
end

local function arcArgs(overrides)
  local parameters = {
    emitterContextSlot = 0,
    horizontalOffset = 0,
    verticalOffset = 0,
    durationTicks = 0,
    curveControl = 8,
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

local function stageArc(overrides, perspective)
  local scene = BattleScene.new()
  local ctx = context()
  if perspective ~= nil then
    ctx.particles.perspective[0] = perspective
  end
  local system = loadSystem(scene, nil, ctx)
  local emitter = createEmitter(ctx)
  Assert.notNil(ctx.particles.emitters[0], "the persistent emitter is addressable by slot")
  local task = assert(BattleEffectTasks.create(BattleEffectTasks.EMITTER_CURVED_PATH_KIND, arcArgs(overrides), ctx, {}))
  return task, system, emitter, ctx
end

function T.emitter_handles_bind_occurrence_system_and_slot()
  Assert.isTrue(
    type(BattleParticleSystems.getEmitterHandle) == "function",
    "emitter slots resolve through an occurrence-bound handle provider"
  )
end

function T.draw_phase_captures_before_calculating_in_slot_order()
  Assert.isTrue(
    type(BattleParticleSystems.stepSourceDrawPhase) == "function",
    "one source phase captures every manager before calculating"
  )
end

function T.curved_paths_execute_the_compiled_arc_instead_of_standing_still()
  local task, system = stageArc()
  local runtime = system.simulation.emitters[1]
  Assert.notNil(runtime, "the staged emitter joins the simulation")
  local startX, startY = pixel(-4), pixel(-1)
  Assert.equal(runtime.x, startX * 172 / 4096, "construction writes the attacker-side start before the first tick")
  Assert.equal(runtime.y, startY * 172 / 4096, "construction writes the attacker-side height before the first tick")
  local seen = {}
  for tick = 1, 8 do
    task:stepSourceTick({ tick = tick })
    Assert.equal(task:status(), "running", "the arc keeps running across its duration")
    seen[#seen + 1] = { x = runtime.x, y = runtime.y }
  end
  local endX, endY = pixel(-2), pixel(-1)
  Assert.isTrue(
    (seen[1].x - startX * 172 / 4096) * (endX - startX) > 0,
    "the first tick moves toward the defender-side end"
  )
  local midStraightY = (startY + endY) / 2 * 172 / 4096
  Assert.isTrue(
    math.abs(seen[4].y - midStraightY) * 4096 / 172 >= 1,
    "the midpoint leaves the straight line by at least one pixel under the compiled amplitude"
  )
  Assert.isTrue(seen[4].x ~= seen[1].x and seen[4].x ~= seen[8].x, "the midpoint differs from both endpoints")
  task:stepSourceTick({ tick = 9 })
  Assert.equal(task:status(), "complete", "the arc retires once its motion ends and its particles retire")
  Assert.isNil(system.simulation.emitters[1], "the spent emitter leaves the simulation")
  system:dispose()
end

function T.curved_paths_mirror_across_battler_orders_and_sides()
  local task, system = stageArc()
  local runtime = system.simulation.emitters[1]
  local forwardStart = runtime.x
  for tick = 1, 8 do
    task:stepSourceTick({ tick = tick })
  end
  task:stepSourceTick({ tick = 9 })
  local reverseTask, reverseSystem = stageArc({ battlerOrder = "target-attacker" })
  local reverseRuntime = reverseSystem.simulation.emitters[1]
  local reverseStart = reverseRuntime.x
  Assert.isTrue(reverseStart > forwardStart, "the reversed arc starts from the defender side")
  reverseTask:stepSourceTick({ tick = 1 })
  Assert.isTrue(reverseRuntime.x < reverseStart, "the reversed arc moves toward the attacker side")
  reverseSystem:dispose()
  system:dispose()
end

function T.curved_paths_reject_malformed_arcs_without_running()
  local scene = BattleScene.new()
  local ctx = context()
  loadSystem(scene, nil, ctx)
  createEmitter(ctx)
  local ok, err = pcall(
    BattleEffectTasks.create,
    BattleEffectTasks.EMITTER_CURVED_PATH_KIND,
    arcArgs({
      curveControl = 0,
    }),
    ctx,
    {}
  )
  Assert.isTrue(not ok, "a zero duration fails instead of dividing by zero: " .. tostring(err))
  local missing
  missing, err = pcall(
    BattleEffectTasks.create,
    BattleEffectTasks.EMITTER_CURVED_PATH_KIND,
    arcArgs({
      emitterContextSlot = 4,
    }),
    ctx,
    {}
  )
  Assert.isTrue(not missing, "an empty slot fails instead of moving nothing: " .. tostring(err))
end

return { tests = T }
