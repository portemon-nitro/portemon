-- Owner tests for the battle-private effect task factory: the narrow
-- create-by-kind contract, the voice monitor lifecycle, the blend,
-- particle, and picture bodies with their scene application and lease
-- discipline, and fail-closed unknown kinds (never a timer stand-in).

local Assert = require("tests.support.Assert")
local BattleEffectTasks = require("libs.hgss.src.presentation.BattleEffectTasks")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local function servicesWith(audio)
  return { scene = {}, audio = audio, resources = {} }
end

local function controllableVoice()
  local voice = { finished = false }
  local audio = {}
  function audio.isFinished(_name)
    return voice.finished
  end
  return voice, audio
end

function T.unknown_kinds_fail_instead_of_returning_a_stand_in()
  for _, kind in ipairs({ "no-such-native-kind", "message-only-narration", "" }) do
    local ok, task = pcall(BattleEffectTasks.create, kind, {}, {}, servicesWith({}))
    Assert.isTrue(not ok or task == nil, "kind " .. tostring(kind) .. " never yields a runnable task")
    if ok then
      Assert.isTrue(type(task) ~= "table" or type(task.stepSourceTick) ~= "function", "no runnable task escapes")
    end
  end
end

function T.voice_monitor_completes_only_on_its_voice()
  local voice, audio = controllableVoice()
  local task = assert(BattleEffectTasks.create(BattleEffectTasks.VOICE_MONITOR_KIND, { voice = "cue" }, {}, servicesWith(audio)))
  Assert.equal(task:status(), "pending", "monitors open pending")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "running", "an unfinished voice keeps the monitor running")
  task:stepSourceTick({ tick = 2 })
  Assert.equal(task:status(), "running", "repeated ticks never complete without the voice")
  voice.finished = true
  task:stepSourceTick({ tick = 3 })
  Assert.equal(task:status(), "complete", "the finished voice completes the monitor")
end

function T.voice_monitor_cancel_and_dispose_stay_exact()
  local _, audio = controllableVoice()
  local task = assert(BattleEffectTasks.create(BattleEffectTasks.VOICE_MONITOR_KIND, { voice = "cue" }, {}, servicesWith(audio)))
  task:cancel("withdrawn")
  Assert.equal(task:status(), "cancelled", "cancellation lands on cancelled")
  task:cancel("repeated")
  Assert.equal(task:status(), "cancelled", "repeated cancellation is silent")
  task:dispose()
  task:dispose()
  task:stepSourceTick({ tick = 9 })
  Assert.equal(task:status(), "cancelled", "disposed monitors never advance again")
end

function T.voice_monitor_completion_survives_cancellation()
  local voice, audio = controllableVoice()
  local task = assert(BattleEffectTasks.create(BattleEffectTasks.VOICE_MONITOR_KIND, { voice = "cue" }, {}, servicesWith(audio)))
  voice.finished = true
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "complete", "the monitor completes first")
  task:cancel("late")
  Assert.equal(task:status(), "complete", "completion and cancellation stay separate")
end

function T.voice_monitor_construction_validates_its_collaborators()
  Assert.throws(function()
    BattleEffectTasks.create(BattleEffectTasks.VOICE_MONITOR_KIND, {}, {}, servicesWith({}))
  end, "monitors without an audio query never construct")
  Assert.throws(function()
    BattleEffectTasks.create(BattleEffectTasks.VOICE_MONITOR_KIND, { voice = "cue" }, {}, { scene = {} })
  end, "monitors without services never construct")
  Assert.throws(function()
    BattleEffectTasks.create(BattleEffectTasks.VOICE_MONITOR_KIND, {}, {}, servicesWith({}))
  end, "monitors without a named voice never construct")
end

function T.voice_monitor_audio_failures_propagate()
  local audio = {}
  function audio.isFinished(_name)
    error("synthetic voice query failure")
  end
  local task = assert(BattleEffectTasks.create(BattleEffectTasks.VOICE_MONITOR_KIND, { voice = "cue" }, {}, servicesWith(audio)))
  Assert.throws(function()
    task:stepSourceTick({ tick = 1 })
  end, "audio failures propagate instead of reading as unfinished")
end

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

local function fixedRandom(draws)
  local random = {}
  function random.draw(bound)
    Assert.isTrue(type(bound) == "number" and bound > 0, "visual draws name a positive bound")
    draws[#draws + 1] = bound
    return 0
  end
  return random.draw
end

function T.blend_transition_completes_and_releases_everything_once()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local task = assert(BattleEffectTasks.create(BattleEffectTasks.BLEND_TRANSITION_KIND, {}, {}, services))
  Assert.equal(task:status(), "pending", "blend transitions open pending")
  Assert.equal(#scene:effectViews(), 1, "construction publishes its transient record")
  for _ = 1, 7 do
    task:stepSourceTick({ tick = 1 })
    Assert.isTrue(task:status() ~= "complete", "the blend boundary is not reached early")
  end
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "complete", "the blend reaches its own completion boundary")
  Assert.equal(#scene:effectViews(), 0, "completion releases the transient record")
  task:dispose()
  task:dispose()
  task:cancel("late")
  Assert.equal(task:status(), "complete", "completion survives late cancellation")
  Assert.equal(#journal.acquired, 2, "the blend stages its background holdings")
  Assert.equal(#journal.released, 2, "every staged lease releases exactly once")
end

function T.particle_continuation_draws_deterministically_from_the_occurrence_stream()
  local firstScene = sceneWithPair()
  local firstServices, firstJournal = journalServices(firstScene)
  local firstDraws = {}
  local first = assert(BattleEffectTasks.create(
    BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
    { resource = "battle/particle/tackle", emitterPosition = "solo-enemy" },
    { seed = 4242, random = fixedRandom(firstDraws) },
    firstServices
  ))
  local firstTrace = {}
  for tick = 1, 30 do
    first:stepSourceTick({ tick = tick })
    firstTrace[#firstTrace + 1] = first:status()
  end
  Assert.equal(first:status(), "complete", "the particle run reaches its own completion boundary")
  Assert.isTrue(#firstDraws > 0, "the run draws its visual randomness from the occurrence-local stream")
  local secondScene = sceneWithPair()
  local secondServices, _ = journalServices(secondScene)
  local secondDraws = {}
  local second = assert(BattleEffectTasks.create(
    BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
    { resource = "battle/particle/tackle", emitterPosition = "solo-enemy" },
    { seed = 4242, random = fixedRandom(secondDraws) },
    secondServices
  ))
  local secondTrace = {}
  for tick = 1, 30 do
    second:stepSourceTick({ tick = tick })
    secondTrace[#secondTrace + 1] = second:status()
  end
  Assert.deepEqual(secondTrace, firstTrace, "the same seed gives the same source-tick trace")
  Assert.deepEqual(secondDraws, firstDraws, "the same seed draws the same visual sequence")
  first:dispose()
  second:dispose()
  Assert.equal(#firstJournal.released, #firstJournal.acquired, "the particle run releases its holdings once")
end

function T.particle_continuation_rejects_unknown_emitters()
  local scene = sceneWithPair()
  local services, _ = journalServices(scene)
  Assert.throws(function()
    BattleEffectTasks.create(
      BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
      { resource = "battle/particle/tackle", emitterPosition = "no-such-slot" },
      {},
      services
    )
  end, "unknown emitters fail closed instead of staging a collapsed emission")
  Assert.equal(#scene:effectViews(), 0, "the rejected construction publishes nothing")
end

function T.construction_failure_rolls_back_every_attempted_lease()
  local scene = sceneWithPair()
  local journal = { acquired = {}, released = {} }
  local resources = { failAfter = 1 }
  function resources.resolve(key)
    journal.acquired[#journal.acquired + 1] = key
    if #journal.acquired > resources.failAfter then
      error({ code = "TEXTURE_MISSING", key = key }, 0)
    end
    return { key = key, lease = key }
  end
  function resources.release(lease)
    journal.released[#journal.released + 1] = lease
  end
  local services = { scene = scene, audio = {}, resources = resources }
  local ok = pcall(BattleEffectTasks.create, BattleEffectTasks.BLEND_TRANSITION_KIND, {}, {}, services)
  Assert.isFalse(ok, "the failing construction never yields a task")
  Assert.equal(#journal.acquired, 2, "both acquisition attempts are journaled")
  Assert.equal(#journal.released, 2, "the rollback releases every attempt exactly once")
  Assert.equal(#scene:effectViews(), 0, "the failed construction publishes nothing")
end

function T.picture_animation_restores_its_activation_snapshot()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local activation = { combatant = 1, activation = 1 }
  Assert.isNil(scene:pictureState(activation), "no picture patch is active before the effect")
  local task = assert(BattleEffectTasks.create(
    BattleEffectTasks.PICTURE_ANIMATION_KIND,
    { battlerSelector = 0, mode = 1, activation = activation },
    {},
    services
  ))
  Assert.isTrue(scene:pictureState(activation) ~= nil, "the reveal owns its activation while running")
  for _ = 1, 6 do
    task:stepSourceTick({ tick = 1 })
  end
  Assert.equal(task:status(), "complete", "the reveal reaches its own completion boundary")
  local settled = scene:pictureState(activation)
  Assert.isTrue(settled == nil or settled.pictureXOffset2 == nil, "no temporary change survives the reveal")
  task:dispose()
  Assert.equal(#journal.released, #journal.acquired, "the reveal releases its holdings once")
end

function T.cancelled_bodies_release_and_stay_silent()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local task = assert(BattleEffectTasks.create(BattleEffectTasks.PARTICLE_CONTINUATION_KIND, {
    resource = "battle/particle/asleep",
    emitterPosition = "solo-player",
  }, {}, services))
  task:stepSourceTick({ tick = 1 })
  task:cancel("superseded")
  Assert.equal(task:status(), "cancelled", "cancellation lands on cancelled")
  task:cancel("repeated")
  task:dispose()
  task:dispose()
  task:stepSourceTick({ tick = 9 })
  Assert.equal(task:status(), "cancelled", "disposed tasks never advance again")
  Assert.equal(#scene:effectViews(), 0, "cancellation releases the transient record")
  Assert.equal(#journal.released, #journal.acquired, "cancellation releases every holding once")
end

return { tests = T }
