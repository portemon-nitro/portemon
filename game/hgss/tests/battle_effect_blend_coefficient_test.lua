-- Blend-coefficient register behavior at the scene seam: completion holds
-- the final EVA/EVB pair until disposal, cancellation, or an explicit
-- blend reset releases it; the midpoint of a retail flash pair lands on
-- the rounded linear ramp; and the scene-level effective read exposes
-- the newest active blend patch or nothing when no blend is live.
-- Retail holds its final BLDALPHA pair in hardware until teardown or
-- reset overwrites it (pret/pokeheartgold BattleAnimTask_BlendAlphaMotion
-- marks done without restoring the register), so the overlay outlives
-- the completing task the same way. Headless: the real scene owns the
-- register overlays; hand-built tasks drive it, no battle or ROM needed.

local Assert = require("tests.support.Assert")
local BattleEffectTasks = require("libs.hgss.src.presentation.BattleEffectTasks")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local BLEND_KIND = "battle-sprite-blend-alpha-transition"

local function sceneWithPair()
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  return scene
end

local function journalServices(scene)
  local journal = { acquired = {}, released = {} }
  local resources = {}
  function resources.resolve(key)
    journal.acquired[#journal.acquired + 1] = key
    return { key = key, lease = key }
  end
  function resources.release(lease)
    journal.released[#journal.released + 1] = lease
  end
  return { scene = scene, audio = {}, resources = resources }, journal
end

local function occurrenceContext()
  return {
    launchId = "blend-coefficient-probe",
    packetId = 1,
    programKey = "blend-coefficient-probe",
    seed = 4242,
    random = function(bound)
      assert(type(bound) == "number" and bound >= 1, "visual draws name a positive bound")
      return 0
    end,
  }
end

local function blendTask(services, parameters)
  return assert(BattleEffectTasks.create(BLEND_KIND, {
    callback = BLEND_KIND,
    taskContext = "battle-display",
    parameters = parameters,
  }, occurrenceContext(), services))
end

local function flashParameters()
  return {
    durationTicks = 16,
    oamModeSpriteSlots = { "sprite-context-slot-0", "sprite-context-slot-1" },
    startCoefficientA = 31,
    startCoefficientB = 0,
    targetCoefficientA = 0,
    targetCoefficientB = 31,
  }
end

local function stepToComplete(task)
  for _ = 1, 40 do
    if task:status() == "complete" then
      break
    end
    task:stepSourceTick({ tick = 1 })
  end
  Assert.equal(task:status(), "complete", "the blend reaches its compiled duration")
end

function T.blend_completion_holds_final_coefficients_until_dispose()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local task = blendTask(services, flashParameters())
  stepToComplete(task)
  local held = scene:blendCoefficients()
  Assert.isTrue(held ~= nil, "completion stops publishing without removing the final register state")
  Assert.equal(held.blendCoefficientA, 0, "the held sprite weight reaches its compiled target")
  Assert.equal(held.blendCoefficientB, 31, "the held background weight reaches its compiled target")
  Assert.deepEqual(
    held.spriteSlots,
    { "sprite-context-slot-0", "sprite-context-slot-1" },
    "the held overlay keeps its compiled sprite scope"
  )
  Assert.isTrue(scene:taskScalarPatch(task) ~= nil, "the owning task still names its held overlay")
  task:stepSourceTick({ tick = 1 })
  local settled = assert(scene:blendCoefficients(), "extra ticks never publish past completion")
  Assert.equal(settled.blendCoefficientA, 0, "extra ticks leave the held sprite weight alone")
  Assert.equal(settled.blendCoefficientB, 31, "extra ticks leave the held background weight alone")
  task:dispose()
  Assert.isNil(scene:blendCoefficients(), "disposal restores the base register state")
  Assert.isNil(scene:taskScalarPatch(task), "disposal releases the owned overlay")
  task:dispose()
  task:cancel("late")
  Assert.equal(task:status(), "complete", "completion survives late cancellation")
  Assert.equal(#journal.released, #journal.acquired, "the imageless blend stages no leases")
end

function T.blend_cancellation_releases_the_owned_register_state()
  local scene = sceneWithPair()
  local services, _ = journalServices(scene)
  local task = blendTask(services, flashParameters())
  task:stepSourceTick({ tick = 1 })
  Assert.isTrue(scene:blendCoefficients() ~= nil, "the running blend owns its register state")
  task:cancel("superseded")
  Assert.equal(task:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isNil(scene:blendCoefficients(), "cancellation restores the base register state")
  Assert.isNil(scene:taskScalarPatch(task), "cancellation releases the owned overlay")
  task:dispose()
end

function T.blend_midpoint_tick_interpolates_both_channels()
  local scene = sceneWithPair()
  local services, _ = journalServices(scene)
  local task = blendTask(services, flashParameters())
  for _ = 1, 4 do
    task:stepSourceTick({ tick = 1 })
  end
  local quarter = assert(scene:blendCoefficients(), "the running blend publishes its register state")
  Assert.equal(quarter.blendCoefficientA, 23, "the quarter tick ramps the sprite weight down the linear ramp")
  Assert.equal(quarter.blendCoefficientB, 8, "the quarter tick ramps the background weight up the linear ramp")
  for _ = 1, 4 do
    task:stepSourceTick({ tick = 1 })
  end
  local midpoint = assert(scene:blendCoefficients(), "the midpoint publishes its register state")
  Assert.equal(midpoint.blendCoefficientA, 16, "the midpoint halves the 31-step sprite fade")
  Assert.equal(midpoint.blendCoefficientB, 16, "the midpoint halves the 31-step background fade")
  stepToComplete(task)
  task:dispose()
end

function T.blend_reset_clears_only_blend_overlays()
  local scene = sceneWithPair()
  local services, _ = journalServices(scene)
  local task = blendTask(services, flashParameters())
  stepToComplete(task)
  Assert.isTrue(scene:blendCoefficients() ~= nil, "completion holds the final register state")
  local bystander = {}
  scene:applyTaskScalarPatch(bystander, { mosaicSize = 3 })
  scene:resetBlendCoefficients()
  Assert.isNil(scene:blendCoefficients(), "the blend reset restores the base register state")
  Assert.isNil(scene:taskScalarPatch(task), "the blend reset releases the held blend overlay")
  Assert.deepEqual(
    scene:taskScalarPatch(bystander),
    { mosaicSize = 3 },
    "the blend reset leaves unrelated register overlays alone"
  )
  task:dispose()
end

function T.blend_read_stays_quiet_without_a_blend_patch()
  local scene = sceneWithPair()
  Assert.isNil(scene:blendCoefficients(), "a scene without blends exposes no coefficients")
  local bystander = {}
  scene:applyTaskScalarPatch(bystander, { mosaicSize = 3 })
  Assert.isNil(scene:blendCoefficients(), "non-blend overlays never read as coefficients")
end

return { tests = T }
