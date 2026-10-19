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
  local task =
    assert(BattleEffectTasks.create(BattleEffectTasks.VOICE_MONITOR_KIND, { voice = "cue" }, {}, servicesWith(audio)))
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
  local task =
    assert(BattleEffectTasks.create(BattleEffectTasks.VOICE_MONITOR_KIND, { voice = "cue" }, {}, servicesWith(audio)))
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
  local task =
    assert(BattleEffectTasks.create(BattleEffectTasks.VOICE_MONITOR_KIND, { voice = "cue" }, {}, servicesWith(audio)))
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
  local task =
    assert(BattleEffectTasks.create(BattleEffectTasks.VOICE_MONITOR_KIND, { voice = "cue" }, {}, servicesWith(audio)))
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
  -- Blend completion comes only from compiled timing operands: a
  -- well-formed spawn without any retires synchronously as a
  -- validated marker, and a timed blend sweeps the background
  -- viewport. Neither stages leases nor publishes drawable pictures.
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local marker = assert(BattleEffectTasks.create(BattleEffectTasks.BLEND_TRANSITION_KIND, {}, {}, services))
  Assert.equal(marker:status(), "pending", "markers open pending")
  marker:stepSourceTick({ tick = 1 })
  Assert.equal(marker:status(), "complete", "the validated marker retires on its first tick")
  Assert.equal(#scene:effectViews(), 0, "the marker publishes no drawable picture")
  marker:dispose()
  Assert.equal(#journal.released, #journal.acquired, "the marker stages no leases")
  local task = assert(BattleEffectTasks.create(BattleEffectTasks.BLEND_TRANSITION_KIND, {
    callback = "battle-background-position-transition",
    taskContext = "battle-display",
    parameters = { offsetX = 10, offsetY = 20, ticksPerStep = 4, steps = 5 },
  }, {}, services))
  Assert.equal(task:status(), "pending", "blend transitions open pending")
  Assert.equal(#scene:effectViews(), 0, "construction publishes no drawable picture")
  for _ = 1, 7 do
    task:stepSourceTick({ tick = 1 })
    Assert.isTrue(task:status() ~= "complete", "the step product outlives the old fixed budget")
  end
  local scrolled = scene:scroll()
  Assert.isTrue(
    scrolled.x ~= 0 or scrolled.y ~= 0,
    "the running sweep owns a viewport change instead of idling on a timer"
  )
  for _ = 1, 200 do
    task:stepSourceTick({ tick = 1 })
    if task:status() == "complete" then
      break
    end
  end
  Assert.equal(task:status(), "complete", "the blend reaches its compiled step product")
  local settled = scene:scroll()
  Assert.equal(settled.x, 0, "completion restores the saved horizontal viewport")
  Assert.equal(settled.y, 0, "completion restores the saved vertical viewport")
  Assert.equal(#scene:effectViews(), 0, "completion publishes no lingering picture")
  task:dispose()
  task:dispose()
  task:cancel("late")
  Assert.equal(task:status(), "complete", "completion survives late cancellation")
  Assert.equal(#journal.acquired, 0, "the imageless blend stages no leases at all")
  Assert.equal(#journal.released, 0, "teardown releases nothing it never staged")
end

function T.particle_continuation_draws_deterministically_from_the_occurrence_stream()
  local firstScene = sceneWithPair()
  local firstServices, firstJournal = journalServices(firstScene)
  local firstDraws = {}
  local first = assert(
    BattleEffectTasks.create(
      BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
      { resource = "battle/particle/tackle", emitterPosition = "solo-enemy" },
      { seed = 4242, random = fixedRandom(firstDraws) },
      firstServices
    )
  )
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
  local second = assert(
    BattleEffectTasks.create(
      BattleEffectTasks.PARTICLE_CONTINUATION_KIND,
      { resource = "battle/particle/tackle", emitterPosition = "solo-enemy" },
      { seed = 4242, random = fixedRandom(secondDraws) },
      secondServices
    )
  )
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
  -- Only particle tasks stage dependency leases now that visual, blend,
  -- and picture bodies are imageless, so the rollback path is proven
  -- through the particle continuation: the failed acquisition attempt
  -- itself releases exactly once and nothing is published.
  local scene = sceneWithPair()
  local journal = { acquired = {}, released = {} }
  local resources = {}
  function resources.resolve(key)
    journal.acquired[#journal.acquired + 1] = key
    error({ code = "TEXTURE_MISSING", key = key }, 0)
  end
  function resources.release(lease)
    journal.released[#journal.released + 1] = lease
  end
  local services = { scene = scene, audio = {}, resources = resources }
  local ok = pcall(BattleEffectTasks.create, BattleEffectTasks.PARTICLE_CONTINUATION_KIND, {
    resource = "battle/particle/tackle",
    emitterPosition = "solo-enemy",
  }, {}, services)
  Assert.isFalse(ok, "the failing construction never yields a task")
  Assert.equal(#journal.acquired, 1, "the acquisition attempt is journaled")
  Assert.equal(#journal.released, 1, "the rollback releases the attempt exactly once")
  Assert.equal(#scene:effectViews(), 0, "the failed construction publishes nothing")
end

function T.picture_animation_restores_its_activation_snapshot()
  -- Show-picture spawns carry no compiled timing, so the validated
  -- show marker retires on its first tick without inventing a duration
  -- or pixels; only a reveal with a compiled duration interpolates its
  -- offset onto the owned activation and restores it on completion.
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local activation = { combatant = 1, activation = 1 }
  Assert.isNil(scene:pictureState(activation), "no picture patch is active before the effect")
  local marker = assert(
    BattleEffectTasks.create(
      BattleEffectTasks.PICTURE_ANIMATION_KIND,
      { battlerSelector = 0, mode = 1, activation = activation },
      {},
      services
    )
  )
  Assert.equal(marker:status(), "pending", "show markers open pending")
  marker:stepSourceTick({ tick = 1 })
  Assert.equal(marker:status(), "complete", "the validated marker retires on its first tick")
  Assert.isNil(scene:pictureState(activation), "the marker applies no temporary change")
  Assert.equal(#scene:effectViews(), 0, "the marker publishes no drawable picture")
  marker:dispose()
  Assert.equal(#journal.released, #journal.acquired, "the marker stages no leases")
  local task = assert(
    BattleEffectTasks.create(
      BattleEffectTasks.PICTURE_ANIMATION_KIND,
      { battlerSelector = 0, mode = 1, activation = activation, parameters = { durationTicks = 3, signedOffset = 24 } },
      {},
      services
    )
  )
  task:stepSourceTick({ tick = 1 })
  Assert.isTrue(scene:pictureState(activation) ~= nil, "the reveal owns its activation while running")
  task:stepSourceTick({ tick = 1 })
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "complete", "the reveal reaches its compiled duration")
  local settled = scene:pictureState(activation)
  Assert.isTrue(settled == nil or settled.pictureXOffset2 == nil, "no temporary change survives the reveal")
  Assert.equal(#scene:effectViews(), 0, "the reveal publishes no drawable picture")
  task:dispose()
  Assert.equal(#journal.released, #journal.acquired, "the reveal stages no leases")
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

local function occurrenceContext(seed)
  return {
    launchId = "native-task-probe",
    packetId = 1,
    programKey = "native-task-probe",
    seed = seed or 4242,
    random = function(bound)
      assert(type(bound) == "number" and bound >= 1, "visual draws name a positive bound")
      return 0
    end,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
    },
    event = { sequence = 1, actionId = 1, hitIndex = 1, effectKey = "native-task-probe" },
    visualSeed = 4242,
  }
end

function T.blend_transition_follows_compiled_ticks_not_a_fixed_budget()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local task = assert(BattleEffectTasks.create(BattleEffectTasks.BLEND_TRANSITION_KIND, {
    callback = "battle-background-position-transition",
    taskContext = "battle-display",
    parameters = { offsetX = 10, offsetY = 20, ticksPerStep = 4, steps = 5 },
  }, occurrenceContext(), services))
  Assert.equal(task:status(), "pending", "blend transitions open pending")
  for _ = 1, 8 do
    task:stepSourceTick({ tick = 1 })
  end
  Assert.isTrue(task:status() ~= "complete", "the source boundary outlives the old fixed budget")
  for _ = 1, 200 do
    task:stepSourceTick({ tick = 1 })
    if task:status() == "complete" then
      break
    end
  end
  Assert.equal(task:status(), "complete", "the blend reaches its source-defined completion")
  Assert.equal(#scene:effectViews(), 0, "completion releases the transient record")
  Assert.equal(#journal.released, #journal.acquired, "completion releases every staged lease once")
  task:dispose()
end

function T.picture_animation_uses_compiled_placement_not_a_fixed_nudge()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local activation = { combatant = 1, activation = 1 }
  local task = assert(BattleEffectTasks.create(BattleEffectTasks.PICTURE_ANIMATION_KIND, {
    battlerSelector = 0,
    mode = 1,
    activation = activation,
    parameters = { durationTicks = 3, signedOffset = 0 },
  }, occurrenceContext(), services))
  local presented = scene:pictureState(activation)
  Assert.isTrue(
    presented == nil or presented.pictureXOffset2 == nil,
    "a zero source offset applies no fixed shift while running"
  )
  for _ = 1, 3 do
    task:stepSourceTick({ tick = 1 })
  end
  Assert.equal(task:status(), "complete", "the reveal completes at its compiled duration")
  local settled = scene:pictureState(activation)
  Assert.isTrue(settled == nil or settled.pictureXOffset2 == nil, "no temporary change survives the reveal")
  Assert.equal(#journal.released, #journal.acquired, "the reveal releases its holdings once")
  task:dispose()
end

function T.sound_task_completes_on_its_voice_not_a_timer()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local voice = { finished = false }
  local audio = {}
  function audio.isFinished(_name)
    return voice.finished
  end
  function audio.playEffect(symbol)
    return { voice = symbol }
  end
  services.audio = audio
  local task = assert(BattleEffectTasks.create("positioned-sound-motion", {
    sound = "SEQ_PV001",
    values = { 0, 0, 0, 0 },
  }, occurrenceContext(), services))
  Assert.equal(task:status(), "pending", "sound tasks open pending")
  for _ = 1, 10 do
    task:stepSourceTick({ tick = 1 })
  end
  Assert.isTrue(task:status() ~= "complete", "an unfinished voice never completes on ticks alone")
  voice.finished = true
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "complete", "the finished voice completes the sound task")
  Assert.equal(#scene:effectViews(), 0, "completion publishes no lingering record")
  Assert.equal(#journal.released, #journal.acquired, "the sound run releases its holdings once")
  task:dispose()
  local cancelling = assert(BattleEffectTasks.create("positioned-sound-motion", {
    sound = "SEQ_PV001",
    values = { 0, 0, 0, 0 },
  }, occurrenceContext(99), services))
  cancelling:stepSourceTick({ tick = 1 })
  cancelling:cancel("superseded")
  Assert.equal(cancelling:status(), "cancelled", "cancellation lands on cancelled")
  cancelling:dispose()
  Assert.equal(#journal.released, #journal.acquired, "cancellation releases every holding once")
end

function T.configured_sprite_task_runs_from_typed_parameters()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local resolved = assert(Sources.resolveConfiguredSpriteAction(17, { 10, 20, 4, 0x100 }))
  Assert.equal(resolved.taskKind, "sprite-affine-rotation-transition", "the probe selects its source task kind")
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local task = assert(
    BattleEffectTasks.create(
      resolved.taskKind,
      { taskContext = resolved.context, parameters = resolved.parameters },
      occurrenceContext(),
      services
    )
  )
  Assert.equal(task:status(), "pending", "configured sprite tasks open pending")
  for _ = 1, 300 do
    task:stepSourceTick({ tick = 1 })
    if task:status() == "complete" then
      break
    end
  end
  Assert.equal(task:status(), "complete", "the configured sprite run reaches its own completion")
  Assert.equal(#scene:effectViews(), 0, "completion releases every transient record")
  Assert.equal(#journal.released, #journal.acquired, "completion releases every staged lease once")
  task:dispose()
  local cancelling = assert(
    BattleEffectTasks.create(
      resolved.taskKind,
      { taskContext = resolved.context, parameters = resolved.parameters },
      occurrenceContext(77),
      services
    )
  )
  cancelling:stepSourceTick({ tick = 1 })
  cancelling:cancel("superseded")
  Assert.equal(cancelling:status(), "cancelled", "cancellation lands on cancelled")
  cancelling:dispose()
  Assert.equal(#journal.released, #journal.acquired, "cancellation releases every holding once")
end

function T.palette_fade_task_steps_source_coefficients()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local activation = { combatant = 1, activation = 1 }
  local task = assert(BattleEffectTasks.create("pokemon-picture-and-battle-palette-fade", {
    callback = "pokemon-picture-and-battle-palette-fade",
    taskContext = "battle-palette",
    parameters = {
      paletteTarget = "battle-animation-palette-target",
      wait = 4,
      startCoefficient = 10,
      endCoefficient = 200,
      nextColor = 300,
    },
    activation = activation,
  }, occurrenceContext(), services))
  Assert.equal(task:status(), "pending", "palette fades open pending")
  task:stepSourceTick({ tick = 1 })
  local changed = #scene:effectViews() > 0 or scene:pictureState(activation) ~= nil
  Assert.isTrue(changed, "the fade stages an observable change instead of idling on a timer")
  for _ = 1, 300 do
    task:stepSourceTick({ tick = 1 })
    if task:status() == "complete" then
      break
    end
  end
  Assert.equal(task:status(), "complete", "the fade reaches its source-defined completion")
  Assert.equal(#scene:effectViews(), 0, "completion releases every transient record")
  Assert.equal(#journal.released, #journal.acquired, "completion releases every staged lease once")
  task:dispose()
  local cancelling = assert(BattleEffectTasks.create("pokemon-picture-and-battle-palette-fade", {
    callback = "pokemon-picture-and-battle-palette-fade",
    taskContext = "battle-palette",
    parameters = {
      paletteTarget = "battle-animation-palette-target",
      wait = 4,
      startCoefficient = 10,
      endCoefficient = 200,
      nextColor = 300,
    },
    activation = activation,
  }, occurrenceContext(55), services))
  cancelling:stepSourceTick({ tick = 1 })
  cancelling:cancel("superseded")
  Assert.equal(cancelling:status(), "cancelled", "cancellation lands on cancelled")
  cancelling:dispose()
  Assert.isTrue(scene:pictureState(activation) == nil, "cancelling the fade leaves no patch behind")
  Assert.equal(#journal.released, #journal.acquired, "cancellation releases every holding once")
end

local function horizontalOffsetArgs(pictureTarget, durationTicks, signedOffset, activation)
  return {
    callback = "pokemon-picture-selected-horizontal-offset-transition",
    taskContext = "pokemon-picture",
    parameters = {
      pictureTarget = pictureTarget,
      durationTicks = durationTicks,
      signedOffset = signedOffset,
    },
    activation = activation,
  }
end

function T.overlapping_native_tasks_restore_only_owned_activation_state()
  local scene = sceneWithPair()
  local firstActivation = { combatant = 1, activation = 1 }
  local secondActivation = { combatant = 3, activation = 3 }
  local firstServices, firstJournal = journalServices(scene)
  local secondServices, secondJournal = journalServices(scene)
  local first = assert(
    BattleEffectTasks.create(
      "pokemon-picture-selected-horizontal-offset-transition",
      horizontalOffsetArgs("active-battler", 30, 40, firstActivation),
      occurrenceContext(),
      firstServices
    )
  )
  local second = assert(
    BattleEffectTasks.create(
      "pokemon-picture-selected-horizontal-offset-transition",
      horizontalOffsetArgs("opposing-battler", 30, -24, secondActivation),
      occurrenceContext(13),
      secondServices
    )
  )
  first:stepSourceTick({ tick = 1 })
  second:stepSourceTick({ tick = 1 })
  Assert.isTrue(scene:pictureState(secondActivation) ~= nil, "the survivor owns its patch while running")
  first:cancel("overlap-superseded")
  Assert.equal(first:status(), "cancelled", "the cancelled task lands on cancelled")
  Assert.isTrue(second:status() ~= "cancelled", "the survivor keeps its own state")
  Assert.isTrue(scene:pictureState(firstActivation) == nil, "cancelling the first task restores its own activation")
  Assert.isTrue(scene:pictureState(secondActivation) ~= nil, "cancelling one task never restores the other activation")
  for _ = 1, 120 do
    second:stepSourceTick({ tick = 1 })
    if second:status() == "complete" then
      break
    end
  end
  Assert.equal(second:status(), "complete", "the survivor completes after the overlap")
  Assert.isTrue(scene:pictureState(secondActivation) == nil, "the survivor restores its own patch on completion")
  first:dispose()
  second:dispose()
  Assert.equal(#firstJournal.released, #firstJournal.acquired, "the cancelled run releases exactly its own leases")
  Assert.equal(#secondJournal.released, #secondJournal.acquired, "the surviving run releases exactly its own leases")
end

function T.voice_failure_during_sound_task_fails_loud_without_leaking()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local audio = {}
  function audio.isFinished(_name)
    error("synthetic voice query failure")
  end
  function audio.playEffect(symbol)
    return { voice = symbol }
  end
  services.audio = audio
  local task = assert(BattleEffectTasks.create("positioned-sound-motion", {
    sound = "SEQ_PV001",
    values = { 0, 0, 0, 0 },
  }, occurrenceContext(), services))
  Assert.throws(function()
    task:stepSourceTick({ tick = 1 })
  end, "audio failures propagate instead of reading as unfinished")
  task:cancel("withdrawn")
  Assert.equal(task:status(), "cancelled", "the failed task still cancels")
  task:dispose()
  Assert.equal(#scene:effectViews(), 0, "the failed run publishes no lingering record")
  Assert.equal(#journal.released, #journal.acquired, "the failed run leaks no lease")
end

function T.visual_duration_prefers_compiled_ticks_over_the_fallback()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local explicit = assert(
    BattleEffectTasks.create(
      "pokemon-picture-position-path-transition",
      { parameters = { positionPath = "all-battler-positions", durationTicks = 7 } },
      occurrenceContext(),
      services
    )
  )
  for _ = 1, 6 do
    explicit:stepSourceTick({ tick = 1 })
    Assert.isTrue(explicit:status() ~= "complete", "the compiled boundary is not reached early")
  end
  explicit:stepSourceTick({ tick = 1 })
  Assert.equal(explicit:status(), "complete", "the run completes at its compiled duration")
  explicit:dispose()
  local swept = assert(
    BattleEffectTasks.create(
      "battle-background-position-transition",
      { parameters = { offsetX = 10, offsetY = 20, ticksPerStep = 4, steps = 5 } },
      occurrenceContext(),
      services
    )
  )
  for _ = 1, 19 do
    swept:stepSourceTick({ tick = 1 })
  end
  Assert.isTrue(swept:status() ~= "complete", "the step product outlives the old fixed budget")
  swept:stepSourceTick({ tick = 1 })
  Assert.equal(swept:status(), "complete", "the run completes at its step product")
  swept:dispose()
  Assert.equal(#journal.released, #journal.acquired, "parameterized runs borrow without acquiring")
end

function T.operand_less_visual_runs_retire_synchronously_as_markers()
  -- Visual bodies whose well-formed spawn carries no compiled timing
  -- operand retire on their first tick instead of retiring on a fixed
  -- budget: completion times come only from the source parameters the
  -- producer emitted, and timing-less spawns carry none. The
  -- four-sprite wave below reaches real retail programs without
  -- operands, so the marker keeps the routine move executable while
  -- publishing nothing and staging nothing.
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local task = assert(
    BattleEffectTasks.create("pokemon-picture-four-sprite-wave-transition", {}, occurrenceContext(), services)
  )
  Assert.equal(task:status(), "pending", "markers open pending")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "complete", "the validated marker retires on its first tick")
  Assert.equal(#scene:effectViews(), 0, "the marker publishes no drawable picture")
  Assert.isNil(
    scene:pictureState({ combatant = 1, activation = 1 }),
    "the marker owns no activation patch"
  )
  task:dispose()
  task:dispose()
  task:cancel("late")
  Assert.equal(task:status(), "complete", "completion survives late cancellation")
  Assert.equal(#journal.released, #journal.acquired, "the marker stages no leases")
end

function T.borrowed_player_leases_are_never_reacquired()
  -- Imageless tasks stage no leases at all, so player-held dependency
  -- keys pass through untouched; the timed run below completes at its
  -- compiled step product and acquires nothing.
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local task = assert(BattleEffectTasks.create(BattleEffectTasks.BLEND_TRANSITION_KIND, {
    resourceKeys = {
      "battle/effect-background/character",
      "battle/effect-background/palette",
    },
    parameters = { offsetX = 6, offsetY = 0, ticksPerStep = 3, steps = 4 },
  }, occurrenceContext(), services))
  for _ = 1, 11 do
    task:stepSourceTick({ tick = 1 })
    Assert.isTrue(task:status() ~= "complete", "the compiled step product is not reached early")
  end
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "complete", "the borrowed run completes at its compiled step product")
  Assert.equal(#journal.acquired, 0, "player-held dependencies are borrowed, never reacquired")
  Assert.equal(#journal.released, 0, "borrowed runs release nothing they do not own")
  task:dispose()
end

function T.palette_overlay_stages_a_visible_fade_while_running()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local activation = { combatant = 1, activation = 1 }
  local task = assert(BattleEffectTasks.create("pokemon-picture-and-battle-palette-fade", {
    parameters = {
      paletteTarget = "battle-animation-palette-target",
      wait = 4,
      startCoefficient = 0,
      endCoefficient = 16,
      nextColor = 300,
    },
    activation = activation,
  }, occurrenceContext(), services))
  task:stepSourceTick({ tick = 1 })
  local running = scene:pictureState(activation)
  Assert.isTrue(
    running ~= nil and running.paletteFade ~= nil,
    "the running fade stages its clipped source coefficients"
  )
  Assert.equal(running.paletteFade.finish, 16, "the extreme end coefficient survives clipping")
  task:cancel("superseded")
  Assert.isNil(scene:pictureState(activation), "cancelling the fade leaves no patch behind")
  task:dispose()
  Assert.equal(#journal.released, #journal.acquired, "the fade releases every holding once")
end

function T.negative_offsets_wrap_without_leaking()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local activation = { combatant = 1, activation = 1 }
  local task = assert(BattleEffectTasks.create("pokemon-picture-selected-horizontal-offset-transition", {
    parameters = { pictureTarget = "active-battler", durationTicks = 10, signedOffset = -16 },
    activation = activation,
  }, occurrenceContext(), services))
  task:stepSourceTick({ tick = 1 })
  local running = scene:pictureState(activation)
  Assert.isTrue(running ~= nil, "the running offset owns its activation patch")
  for _ = 1, 9 do
    task:stepSourceTick({ tick = 1 })
  end
  Assert.equal(task:status(), "complete", "the wrapped offset completes at its duration")
  Assert.isNil(scene:pictureState(activation), "completion restores the owned activation exactly")
  task:dispose()
  Assert.equal(#journal.released, #journal.acquired, "the offset run releases every holding once")
end

function T.unreported_sound_voices_retire_on_the_bounded_escape()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local voice = { finished = false }
  local audio = {}
  function audio.isFinished(_name)
    return voice.finished
  end
  function audio.playEffect(symbol)
    return { voice = symbol }
  end
  services.audio = audio
  local task = assert(
    BattleEffectTasks.create(
      "positioned-sound-motion",
      { sound = "SEQ_PV001", values = { 0, 0, 0, 0 } },
      occurrenceContext(),
      services
    )
  )
  for _ = 1, 10 do
    task:stepSourceTick({ tick = 1 })
  end
  Assert.isTrue(task:status() ~= "complete", "an unreported voice never completes early")
  for _ = 1, 200 do
    task:stepSourceTick({ tick = 1 })
    if task:status() == "complete" then
      break
    end
  end
  Assert.equal(task:status(), "complete", "the escape retires voices that never report")
  task:cancel("late")
  task:dispose()
  Assert.equal(task:status(), "complete", "completion survives late cancellation")
  Assert.equal(#journal.released, #journal.acquired, "the escaped run releases every holding once")
end

function T.admission_predicate_covers_only_implemented_kinds()
  Assert.isTrue(BattleEffectTasks.supportsKind(BattleEffectTasks.BLEND_TRANSITION_KIND), "the blend body is admitted")
  Assert.isTrue(
    BattleEffectTasks.supportsKind(BattleEffectTasks.PICTURE_ANIMATION_KIND),
    "the picture body is admitted"
  )
  Assert.isTrue(
    BattleEffectTasks.supportsKind(BattleEffectTasks.PARTICLE_CONTINUATION_KIND),
    "the particle continuation is admitted"
  )
  Assert.isTrue(BattleEffectTasks.supportsKind(BattleEffectTasks.VOICE_MONITOR_KIND), "the voice monitor is admitted")
  for _, kind in ipairs({ "positioned-sound-motion", "repeated-sound-playback", "delayed-sound-playback" }) do
    Assert.isTrue(BattleEffectTasks.supportsKind(kind), "the sound body is admitted: " .. kind)
  end
  for _, kind in ipairs({
    "pokemon-picture-selected-horizontal-offset-transition",
    "battle-background-picture-coordinate-sweep",
    "battle-sprite-sinusoidal-position-animation",
    "sprite-affine-rotation-transition",
  }) do
    Assert.isTrue(BattleEffectTasks.supportsKind(kind), "the visual body is admitted: " .. kind)
  end
  for _, kind in ipairs({
    BattleEffectTasks.EMITTER_BATTLER_PATH_KIND,
    BattleEffectTasks.EMITTER_CURVED_PATH_KIND,
  }) do
    Assert.isTrue(BattleEffectTasks.supportsKind(kind), "the emitter path body is admitted: " .. kind)
  end
  for _, kind in ipairs({
    "",
    "no-such-native-kind",
    "message-only-narration",
  }) do
    Assert.isFalse(BattleEffectTasks.supportsKind(kind), "unimplemented kinds are never admitted: " .. tostring(kind))
  end
end

function T.malformed_visual_arguments_fail_before_side_effects()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local ok = pcall(BattleEffectTasks.create, "pokemon-picture-selected-horizontal-offset-transition", {
    parameters = { 1, 2, 3 },
  }, occurrenceContext(), services)
  Assert.isFalse(ok, "non-record parameters never yield a runnable task")
  Assert.equal(#scene:effectViews(), 0, "the rejected construction publishes nothing")
  Assert.equal(#journal.released, #journal.acquired, "the rejected construction leaks no lease")
end

local function emitterPathParameters(selector)
  local Sources = require("romdump.src.config.BattleAnimationSources")
  local resolved
  if selector == 65 then
    resolved = assert(Sources.resolveBattleAnimationCallback({ 65, 9, 0, 10, 20, 5, 8, 100, 0, 0x00020003, 2 }))
  else
    resolved = assert(Sources.resolveBattleAnimationCallback({ 66, 9, 0, 10, 20, 30, 40, 256, 0, 0x00020005, 1 }))
  end
  Assert.notNil(resolved.taskKind, "the emitter path callback resolves its task kind")
  return resolved
end

function T.emitter_path_tasks_complete_on_their_compiled_boundary()
  for _, selector in ipairs({ 65, 66 }) do
    local plan = emitterPathParameters(selector)
    local scene = sceneWithPair()
    local services, journal = journalServices(scene)
    local task = assert(
      BattleEffectTasks.create(plan.taskKind, {
        callback = plan.callback,
        taskContext = plan.context,
        parameters = plan.parameters,
      }, occurrenceContext(), services),
      "the emitter path body constructs from compiled parameters"
    )
    Assert.equal(task:status(), "pending", "emitter path tasks open pending")
    local bound = plan.parameters.interpolationDurationTicks or plan.parameters.durationTicks
    Assert.isTrue(type(bound) == "number" and bound > 0, "the compiled boundary is positive")
    for _ = 1, bound - 1 do
      task:stepSourceTick({ tick = 1 })
      Assert.isTrue(task:status() ~= "complete", "the path boundary is not reached early")
    end
    task:stepSourceTick({ tick = 1 })
    Assert.equal(task:status(), "complete", "the path retires on its compiled boundary")
    Assert.equal(#scene:effectViews(), 0, "path drivers publish no transient records")
    Assert.equal(#journal.acquired, 0, "path drivers stage no leases")
    Assert.equal(#journal.released, 0, "path drivers release nothing")
    task:dispose()
    task:dispose()
    task:cancel("late")
    Assert.equal(task:status(), "complete", "completion survives late cancellation")
  end
end

function T.emitter_path_tasks_cancel_without_side_effects()
  local plan = emitterPathParameters(65)
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local task = assert(BattleEffectTasks.create(plan.taskKind, {
    callback = plan.callback,
    taskContext = plan.context,
    parameters = plan.parameters,
  }, occurrenceContext(), services))
  task:stepSourceTick({ tick = 1 })
  task:cancel("superseded")
  Assert.equal(task:status(), "cancelled", "cancellation stays distinct from completion")
  Assert.equal(#scene:effectViews(), 0, "cancellation publishes nothing")
  task:dispose()
  Assert.equal(#journal.released, #journal.acquired, "the cancelled path leaks no lease")
end

function T.emitter_path_tasks_refuse_missing_parameters()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  for _, kind in ipairs({
    BattleEffectTasks.EMITTER_BATTLER_PATH_KIND,
    BattleEffectTasks.EMITTER_CURVED_PATH_KIND,
  }) do
    local ok = pcall(BattleEffectTasks.create, kind, {}, occurrenceContext(), services)
    Assert.isFalse(ok, "an emitter path without its source profile never constructs")
    Assert.equal(#scene:effectViews(), 0, "the refused construction publishes nothing")
    Assert.equal(#journal.released, #journal.acquired, "the refused construction leaks no lease")
  end
end

return { tests = T }
