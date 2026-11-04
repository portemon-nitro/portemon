-- Owner tests for the battle-private effect task factory: the narrow
-- create-by-kind contract, the voice monitor lifecycle, the blend,
-- particle, and picture bodies with their scene application and lease
-- discipline, and fail-closed unknown kinds (never a timer stand-in).

local Assert = require("tests.support.Assert")
local BattleEffectTasks = require("libs.hgss.src.presentation.BattleEffectTasks")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")
local BattleAnimationPlayer = require("libs.hgss.src.presentation.BattleAnimationPlayer")

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
  -- Opcode-34 visual spawns carry selectors, never timing operands: the
  -- parameter-less blend retires synchronously as a verified marker, and
  -- a timed blend sweeps the background viewport. Neither stages leases
  -- nor publishes drawable pictures.
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local marker = assert(BattleEffectTasks.create(BattleEffectTasks.BLEND_TRANSITION_KIND, {}, {}, services))
  Assert.equal(marker:status(), "pending", "markers open pending")
  marker:stepSourceTick({ tick = 1 })
  Assert.equal(marker:status(), "complete", "the timing-less marker retires on its first tick")
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

function T.paired_interpolation_completes_on_its_compiled_step_product()
  -- Selector-73 paired-interpolation carries no durationTicks, but its
  -- step operands bound the run: initialSteps at stepIntervalTicks each
  -- (producer-packed word 8; the native emitter-motion task runs its own
  -- duration the same way). A 3x4 interpolation completes at 12 ticks,
  -- never as a tick-1 marker.
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local activation = { combatant = 1, activation = 1 }
  local task = assert(BattleEffectTasks.create("pokemon-picture-paired-position-interpolation", {
    battlerTarget = "attacker",
    activation = activation,
    parameters = { endpointX = 40, endpointY = -72, initialSteps = 3, stepIntervalTicks = 4 },
  }, occurrenceContext(), services))
  for _ = 1, 11 do
    task:stepSourceTick({ tick = 1 })
    Assert.isTrue(task:status() ~= "complete", "the step product outlives its prefix")
  end
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "complete", "the interpolation completes at steps times interval")
  task:dispose()
  Assert.equal(#journal.released, #journal.acquired, "the interpolation stages no leases")
end

function T.visual_duration_prefers_compiled_ticks_over_the_fallback()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local explicit = assert(
    BattleEffectTasks.create(
      "pokemon-picture-position-path-transition",
      { parameters = { positionPath = "all-battler-positions", stepMultiplier = 1, durationTicks = 7 } },
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

function T.battle_animation_position_path_runs_source_sine_and_restores_picture_offsets()
  -- Source behavior: src/battle/battle_anim_funcs.c::BattleAnimFunc_MoveBattlerSin and
  -- src/battle/battle_anim_util.c::BattleAnimUtil_InitCircleMotion.
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local task = assert(BattleEffectTasks.create("pokemon-picture-position-path-transition", {
    parameters = {
      positionPath = "all-battler-positions",
      stepMultiplier = 2,
      durationTicks = 3,
    },
  }, occurrenceContext(), services))
  local attacker = { combatant = 1, activation = 1 }
  local target = { combatant = 3, activation = 3 }

  task:stepSourceTick({ tick = 1 })
  task:stepSourceTick({ tick = 2 })
  Assert.equal(task:status(), "running", "the source multiplier extends the base circle duration")
  Assert.equal(scene:pictureState(attacker).pictureXOffset, -1, "the source sine reaches its native negative pixel")
  Assert.equal(scene:pictureState(attacker).pictureYOffset, 8, "the source task keeps its eight-pixel baseline")
  Assert.equal(scene:pictureState(target).pictureXOffset, -1, "the source role mask moves every selected picture")

  for tick = 3, 6 do
    task:stepSourceTick({ tick = tick })
  end
  Assert.equal(task:status(), "complete", "the task ends after duration times multiplier")
  Assert.isNil(scene:pictureState(attacker), "completion restores the attacker's picture")
  Assert.isNil(scene:pictureState(target), "completion restores the target's picture")
  task:dispose()
  Assert.equal(#journal.released, #journal.acquired, "the source picture task stages no resources")
end

function T.battle_animation_battler_sprite_slot_persists_until_source_delete()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local context = occurrenceContext()
  context.topology = {
    attacker = { combatant = 1, activation = 1 },
    targets = { { combatant = 3, activation = 3 } },
  }
  context.sourceBattlers = {
    { combatant = 1, activation = 1, sideType = 0 },
    { combatant = 3, activation = 3, sideType = 1 },
  }
  local create = assert(BattleEffectTasks.create("pokemon-battler-sprite-slot", {
    operation = "create",
    battlerTarget = "first-battler-state-one-or-three",
    spriteSlot = 1,
    follow = false,
    runtimeSelection = "battler-pokemon-picture-resource",
  }, context, services))
  create:stepSourceTick({ tick = 1 })
  Assert.equal(create:status(), "complete", "source sprite creation is a synchronous slot publication")
  local views = scene:effectViews()
  Assert.equal(#views, 1, "the source slot keeps its battler picture in the scene")
  Assert.equal(views[1].picture.spriteSlot, 1, "the scene preserves the source slot identity")
  Assert.equal(views[1].picture.battlerActivation.combatant, 3, "the role resolves to the event target")
  Assert.equal(views[1].picture.follow, false, "the source follow flag stays explicit")
  Assert.throws(function()
    scene:setBattlerSpriteSlot("native-task-probe:1:native-task-probe", 1, { combatant = 3, activation = 3 }, false)
  end, "source sprite slots reject a second create before the matching delete")
  Assert.equal(#scene:effectViews(), 1, "a rejected duplicate leaves the original source slot intact")
  create:dispose()
  Assert.equal(#scene:effectViews(), 1, "retiring the one-tick command leaves scene-owned slot state")

  local delete = assert(BattleEffectTasks.create("pokemon-battler-sprite-slot", {
    operation = "delete",
    spriteSlot = 1,
  }, context, services))
  delete:stepSourceTick({ tick = 2 })
  Assert.equal(delete:status(), "complete", "source deletion is synchronous")
  Assert.equal(#scene:effectViews(), 0, "opcode 60 releases the exact created slot")
  delete:dispose()
  Assert.equal(#journal.released, #journal.acquired, "slot commands acquire no duplicate source resource")
end

function T.battle_animation_battler_sprite_role_four_and_five_use_native_fallbacks()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local context = occurrenceContext()
  context.sourceBattlers = {
    { combatant = 1, activation = 1, sideType = 0 },
    { combatant = 3, activation = 3, sideType = 1 },
    { combatant = 5, activation = 5, sideType = 4 },
    { combatant = 7, activation = 7, sideType = 5 },
  }
  local function create(role, slot)
    local task = assert(BattleEffectTasks.create("pokemon-battler-sprite-slot", {
      operation = "create",
      battlerTarget = role,
      spriteSlot = slot,
      follow = false,
      runtimeSelection = "battler-pokemon-picture-resource",
    }, context, services))
    task:stepSourceTick({ tick = 1 })
  end
  create("first-battler-state-four", 6)
  create("first-battler-state-five", 7)
  local views = scene:effectViews()
  Assert.equal(views[1].picture.battlerActivation.combatant, 5, "state-four roles choose source type four")
  Assert.equal(views[2].picture.battlerActivation.combatant, 7, "state-five roles choose source type five")
  scene:releaseBattlerSpriteSlots("native-task-probe:1:native-task-probe")
  context.sourceBattlers = {
    { combatant = 1, activation = 1, sideType = 0 },
    { combatant = 3, activation = 3, sideType = 1 },
  }
  create("first-battler-state-four", 6)
  create("first-battler-state-five", 7)
  views = scene:effectViews()
  Assert.equal(views[1].picture.battlerActivation.combatant, 1, "missing state-four roles use source battler zero")
  Assert.equal(views[2].picture.battlerActivation.combatant, 1, "missing state-five roles use source battler zero")
  scene:release()
  Assert.equal(#scene:effectViews(), 0, "scene settlement retires both source fallback copies")
  Assert.equal(#journal.released, #journal.acquired, "role selection stages no duplicate resources")
end

function T.battler_sprite_active_position_roles_follow_attacker_and_defender_partners()
  local scene = sceneWithPair()
  local services = journalServices(scene)
  local context = occurrenceContext()
  context.topology = {
    attacker = { combatant = 3, activation = 3, sideType = 3 },
    targets = { { combatant = 1, activation = 1, sideType = 2 } },
  }
  context.sourceBattlers = {
    { combatant = 1, activation = 1, sideType = 2 },
    { combatant = 2, activation = 2, sideType = 4 },
    { combatant = 3, activation = 3, sideType = 3 },
    { combatant = 4, activation = 4, sideType = 5 },
  }
  local function create(role, slot)
    local task = assert(BattleEffectTasks.create("pokemon-battler-sprite-slot", {
      operation = "create",
      battlerTarget = role,
      spriteSlot = slot,
      follow = false,
      runtimeSelection = "battler-pokemon-picture-resource",
    }, context, services))
    task:stepSourceTick({ tick = 1 })
  end

  create("first-battler-for-active-position-first", 0)
  create("first-battler-for-active-position-second", 1)

  local views = scene:effectViews()
  Assert.equal(views[1].picture.battlerActivation.combatant, 4, "the first role resolves the attacker's partner")
  Assert.equal(views[2].picture.battlerActivation.combatant, 2, "the second role resolves the defender's partner")
  scene:releaseBattlerSpriteSlots("native-task-probe:1:native-task-probe")
  scene:release()
end

function T.palette_pulse_accepts_a_compiled_zero_frame_interval()
  local scene = sceneWithPair()
  local services = journalServices(scene)
  local task = assert(BattleEffectTasks.create("pokemon-picture-repeated-palette-fade", {
    battlerTarget = "attacker",
    parameters = {
      pictureTarget = "attacker",
      framesPerStep = 0,
      repeatCount = 3,
      targetColor = 31,
      fadeExtent = 10,
      pauseTicks = 0,
    },
  }, occurrenceContext(), services))
  for _ = 1, 2 do
    task:stepSourceTick({ tick = 1 })
    Assert.isTrue(task:status() ~= "complete", "the repeats have not completed early")
  end
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "complete", "a zero frame interval still retires on its compiled repeat count")
  task:dispose()
end

function T.operand_less_visual_without_a_marker_citation_fails_closed()
  -- Only verified synchronous-marker kinds retire without compiled timing
  -- operands; every other timing-less spawn fails closed with its kind
  -- identity instead of retiring silently with zero writes. The
  -- four-sprite wave below carries no marker citation, so its
  -- operand-less spawn never yields a runnable task, publishes nothing,
  -- and stages nothing.
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local ok, failure =
    pcall(BattleEffectTasks.create, "pokemon-picture-four-sprite-wave-transition", {}, occurrenceContext(), services)
  Assert.isFalse(ok, "a timing-less spawn outside the marker set never yields a runnable task")
  Assert.isTrue(
    string.find(tostring(failure), "pokemon-picture-four-sprite-wave-transition", 1, true) ~= nil
      and string.find(tostring(failure), "BATTLE_EFFECT_TASK_MALFORMED", 1, true) ~= nil,
    "the timing-less spawn fails closed naming itself: " .. tostring(failure)
  )
  Assert.equal(#scene:effectViews(), 0, "the rejected construction publishes no drawable picture")
  Assert.isNil(
    scene:pictureState({ combatant = 1, activation = 1 }),
    "the rejected construction owns no activation patch"
  )
  Assert.equal(#journal.released, #journal.acquired, "the rejected construction stages no leases")
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
  for _, kind in ipairs({ BattleEffectTasks.PARTICLE_SYSTEM_KIND, BattleEffectTasks.PARTICLE_CONTINUATION_KIND }) do
    Assert.isTrue(BattleEffectTasks.supportsKind(kind), "the particle body is admitted: " .. kind)
  end
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

function T.directed_offscreen_motion_exits_each_side_away_from_center()
  -- MoveBattlerLinear resolves its exit direction from the occurrence
  -- side type: the foe-side target slides right while a player-side
  -- attacker slides left, both over the compiled distance and duration.
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local foe = { combatant = 3, activation = 3 }
  local foeTask = assert(BattleEffectTasks.create("pokemon-picture-linear-offscreen-transition", {
    activation = foe,
    parameters = {
      durationTicks = 20,
      offscreenDistance = 144,
      exitOwnSide = true,
      pictureTarget = "target",
    },
  }, occurrenceContext(), services))
  for _ = 1, 10 do
    foeTask:stepSourceTick({ tick = 1 })
  end
  local midFoe = assert(scene:pictureState(foe), "the running slide stages its offscreen patch")
  Assert.equal(midFoe.pictureXOffset2, 72, "the foe slides toward its own side at half time")
  for _ = 1, 9 do
    foeTask:stepSourceTick({ tick = 1 })
    Assert.isTrue(foeTask:status() ~= "complete", "the offscreen run outlives its prefix")
  end
  foeTask:stepSourceTick({ tick = 1 })
  Assert.equal(foeTask:status(), "complete", "the run completes at its compiled duration")
  Assert.isNil(scene:pictureState(foe), "completion restores the base position")
  local friend = { combatant = 1, activation = 1 }
  local friendTask = assert(BattleEffectTasks.create("pokemon-picture-linear-offscreen-transition", {
    activation = friend,
    parameters = {
      durationTicks = 20,
      offscreenDistance = 144,
      exitOwnSide = true,
      pictureTarget = "attacker",
    },
  }, occurrenceContext(), services))
  for _ = 1, 10 do
    friendTask:stepSourceTick({ tick = 1 })
  end
  local midFriend = assert(scene:pictureState(friend), "the player-side run stages its own patch")
  Assert.equal(midFriend.pictureXOffset2, (256 - 72) % 256, "the player-side battler exits left")
  for _ = 1, 10 do
    friendTask:stepSourceTick({ tick = 1 })
  end
  Assert.equal(friendTask:status(), "complete", "the player-side run completes at its duration")
  friendTask:dispose()
  Assert.equal(#journal.released, #journal.acquired, "directed runs stage no leases")
end

function T.directed_offscreen_motion_without_a_known_side_stays_loud()
  local scene = sceneWithPair()
  local services, _ = journalServices(scene)
  local args = {
    activation = { combatant = 3, activation = 3 },
    parameters = {
      durationTicks = 20,
      offscreenDistance = 144,
      exitOwnSide = true,
      pictureTarget = "target",
    },
  }
  Assert.throws(function()
    BattleEffectTasks.create("pokemon-picture-linear-offscreen-transition", args, {}, services)
  end, "an offscreen run without its occurrence topology never constructs")
  local context = occurrenceContext()
  context.topology.targets[1].sideType = 7
  Assert.throws(function()
    BattleEffectTasks.create("pokemon-picture-linear-offscreen-transition", args, context, services)
  end, "an offscreen run with an unknown side type never constructs")
  Assert.isNil(scene:pictureState({ combatant = 3, activation = 3 }), "the refused construction publishes nothing")
end

function T.battler_motion_holds_keep_source_timing_without_invented_motion()
  -- DefenderKnockback ends where it starts (the knockback returns), so
  -- its run holds the native boundary with no patch instead of inventing
  -- motion the source operands never describe; AttackerDashAfterimages
  -- stages its out/back coordinate legs from the occurrence slot geometry
  -- instead, and ResetBattlerPosition snaps home at once and retires as
  -- a validated marker.
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local knockback = assert(BattleEffectTasks.create("pokemon-picture-defender-knockback", {
    battlerTarget = "target",
    activation = { combatant = 3, activation = 3 },
    parameters = { durationTicks = 29 },
  }, occurrenceContext(), services))
  for _ = 1, 28 do
    knockback:stepSourceTick({ tick = 1 })
    Assert.isTrue(knockback:status() ~= "complete", "the knockback boundary outlives its prefix")
  end
  knockback:stepSourceTick({ tick = 1 })
  Assert.equal(knockback:status(), "complete", "the knockback completes at its native 29 ticks")
  Assert.isNil(scene:pictureState({ combatant = 3, activation = 3 }), "the hold stages no patch")
  knockback:dispose()
  local dash = assert(BattleEffectTasks.create("pokemon-picture-attacker-dash-afterimages", {
    battlerTarget = "attacker",
    activation = { combatant = 1, activation = 1 },
    parameters = { durationTicks = 20 },
  }, occurrenceContext(), services))
  dash:stepSourceTick({ tick = 1 })
  dash:stepSourceTick({ tick = 1 })
  local early = assert(scene:pictureState({ combatant = 1, activation = 1 }), "the dash stages its out-leg coordinates")
  for _ = 1, 8 do
    dash:stepSourceTick({ tick = 1 })
  end
  Assert.isTrue(dash:status() ~= "complete", "the dash boundary outlives its prefix")
  local mid = assert(scene:pictureState({ combatant = 1, activation = 1 }), "the dash keeps its coordinates")
  Assert.isTrue(mid.pictureXOffset2 ~= early.pictureXOffset2, "the out leg advances the dash")
  for _ = 1, 6 do
    dash:stepSourceTick({ tick = 1 })
  end
  local returning = assert(scene:pictureState({ combatant = 1, activation = 1 }), "the back leg keeps its stages")
  Assert.isTrue(returning.pictureXOffset2 ~= mid.pictureXOffset2, "the back leg retreats from the reach")
  for _ = 1, 4 do
    dash:stepSourceTick({ tick = 1 })
  end
  Assert.equal(dash:status(), "complete", "the dash completes at its native 20 ticks")
  Assert.isNil(scene:pictureState({ combatant = 1, activation = 1 }), "the dash restores the attacker")
  dash:dispose()
  local reset = assert(BattleEffectTasks.create("pokemon-picture-reset-position-transition", {
    activation = { combatant = 3, activation = 3 },
    parameters = { pictureTarget = "target" },
  }, occurrenceContext(), services))
  Assert.equal(reset:status(), "pending", "markers open pending")
  reset:stepSourceTick({ tick = 1 })
  Assert.equal(reset:status(), "complete", "the reset retires on its first tick")
  reset:dispose()
  Assert.equal(#journal.released, #journal.acquired, "holds and markers stage no leases")
end

local function movePowerParameters(overrides)
  local parameters = {
    backgroundLayer = "battle-background-layer-3",
    pictureSets = { "all-battler-positions" },
    durationTicks = 10,
    defaultProfile = 0,
    profileByMovePower = {
      { movePower = 30, profile = 1 },
      { movePower = 50, profile = 2 },
      { movePower = 70, profile = 3 },
      { movePower = 90, profile = 4 },
      { movePower = 110, profile = 5 },
      { movePower = 150, profile = 6 },
    },
  }
  if overrides ~= nil then
    for field, value in pairs(overrides) do
      parameters[field] = value
    end
  end
  return parameters
end

local function movePowerContext(power)
  local context = occurrenceContext()
  context.event = {
    sequence = 1,
    actionId = 1,
    hitIndex = 1,
    effectKey = "native-task-probe",
    move = { power = power },
  }
  return context
end

local function movePowerArgs(parameters)
  return {
    callback = "battle-background-four-picture-move-power-transition",
    taskContext = "battle-display",
    parameters = parameters,
  }
end

local function pictureDigest(scene, combatant, activation)
  local state = scene:pictureState({ combatant = combatant, activation = activation })
  if state == nil then
    return "absent"
  end
  return string.format(
    "%s|%s|%s|%s",
    tostring(state.pictureXOffset2),
    tostring(state.pictureYOffset),
    tostring(state.rotationZ),
    tostring(state.scaleX)
  )
end

local function runProfileTrace(power)
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local task = assert(
    BattleEffectTasks.create(
      "battle-background-four-picture-move-power-transition",
      movePowerArgs(movePowerParameters()),
      movePowerContext(power),
      services
    )
  )
  local trace = {}
  for _ = 1, 40 do
    task:stepSourceTick({ tick = 1 })
    trace[#trace + 1] = pictureDigest(scene, 1, 1) .. "/" .. pictureDigest(scene, 3, 3)
    if task:status() == "complete" then
      break
    end
  end
  Assert.equal(task:status(), "complete", "the power profile run reaches its compiled duration")
  task:dispose()
  return trace, scene, journal
end

function T.move_power_profile_selects_distinct_visible_frames()
  local low, _, lowJournal = runProfileTrace(30)
  local high, _, highJournal = runProfileTrace(90)
  Assert.equal(#low, 10, "the low-power run spans its ten compiled ticks")
  Assert.equal(#high, 10, "the high-power run spans its ten compiled ticks")
  local moved = false
  for _, frame in ipairs(low) do
    if frame ~= low[1] then
      moved = true
    end
  end
  Assert.isTrue(moved, "the low-power run animates across its ticks instead of holding one frame")
  local distinct = false
  for index = 1, 10 do
    if low[index] ~= high[index] then
      distinct = true
    end
  end
  Assert.isTrue(distinct, "the two ladder powers paint distinct visible frames")
  Assert.equal(#lowJournal.released, #lowJournal.acquired, "the profile run stages no leases")
end

function T.move_power_profile_restores_both_pictures_on_completion()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local task = assert(
    BattleEffectTasks.create(
      "battle-background-four-picture-move-power-transition",
      movePowerArgs(movePowerParameters()),
      movePowerContext(30),
      services
    )
  )
  task:stepSourceTick({ tick = 1 })
  Assert.isTrue(
    scene:pictureState({ combatant = 1, activation = 1 }) ~= nil
      or scene:pictureState({ combatant = 3, activation = 3 }) ~= nil,
    "the running profile owns battler picture state instead of idling on a timer"
  )
  for _ = 1, 40 do
    if task:status() == "complete" then
      break
    end
    task:stepSourceTick({ tick = 1 })
  end
  Assert.equal(task:status(), "complete", "the profile run completes at its compiled duration")
  Assert.isNil(
    scene:pictureState({ combatant = 1, activation = 1 }),
    "completion restores the attacker picture exactly"
  )
  Assert.isNil(scene:pictureState({ combatant = 3, activation = 3 }), "completion restores the target picture exactly")
  task:dispose()
  Assert.equal(#journal.released, #journal.acquired, "the profile run stages no leases")
end

function T.move_power_profile_cancels_without_stranding_pictures()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local task = assert(
    BattleEffectTasks.create(
      "battle-background-four-picture-move-power-transition",
      movePowerArgs(movePowerParameters()),
      movePowerContext(90),
      services
    )
  )
  task:stepSourceTick({ tick = 1 })
  task:stepSourceTick({ tick = 1 })
  task:cancel("superseded")
  Assert.equal(task:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isNil(scene:pictureState({ combatant = 1, activation = 1 }), "cancellation restores the attacker picture")
  Assert.isNil(scene:pictureState({ combatant = 3, activation = 3 }), "cancellation restores the target picture")
  task:dispose()
  Assert.equal(#journal.released, #journal.acquired, "cancellation stages no leases")
end

function T.move_power_profile_requires_the_executed_power()
  local scene = sceneWithPair()
  local services, _journal = journalServices(scene)
  local ok, failure = pcall(
    BattleEffectTasks.create,
    "battle-background-four-picture-move-power-transition",
    movePowerArgs(movePowerParameters()),
    occurrenceContext(),
    services
  )
  Assert.isTrue(not ok, "a missing executed power never yields a runnable profile")
  Assert.isTrue(
    type(failure) == "string"
      and string.find(failure, "battle-background-four-picture-move-power-transition", 1, true) ~= nil,
    "the missing power fails naming its kind"
  )
  local badContext = movePowerContext("strong")
  local badOk = pcall(
    BattleEffectTasks.create,
    "battle-background-four-picture-move-power-transition",
    movePowerArgs(movePowerParameters()),
    badContext,
    services
  )
  Assert.isTrue(not badOk, "a malformed executed power never yields a runnable profile")
  Assert.equal(#scene:effectViews(), 0, "the rejected profile publishes no drawable picture")
end

function T.move_power_profile_rejects_unmatched_power_without_a_default()
  local scene = sceneWithPair()
  local services, _journal = journalServices(scene)
  local parameters = movePowerParameters()
  parameters.defaultProfile = nil
  local ok, failure = pcall(
    BattleEffectTasks.create,
    "battle-background-four-picture-move-power-transition",
    movePowerArgs(parameters),
    movePowerContext(999),
    services
  )
  Assert.isTrue(not ok, "an unmatched power without a default never yields a silent profile")
  Assert.isTrue(
    type(failure) == "string"
      and string.find(failure, "battle-background-four-picture-move-power-transition", 1, true) ~= nil,
    "the unmatched power fails naming its kind"
  )
  local defaulted = assert(
    BattleEffectTasks.create(
      "battle-background-four-picture-move-power-transition",
      movePowerArgs(movePowerParameters()),
      movePowerContext(999),
      services
    )
  )
  defaulted:stepSourceTick({ tick = 1 })
  Assert.equal(defaulted:status(), "running", "the defaulted profile runs past its first tick")
  defaulted:dispose()
end

function T.alternating_scroll_sweeps_both_directions_and_restores()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local task = assert(BattleEffectTasks.create("battle-background-alternating-scroll-transition", {
    callback = "battle-background-alternating-scroll-transition",
    taskContext = "battle-display",
    parameters = {
      backgroundLayer = "battle-background-layer-3",
      directionChanges = 3,
      ticksPerDirection = 2,
      phaseIntervalTicks = 1,
      horizontalOffset = 4,
      verticalOffset = 8,
    },
  }, occurrenceContext(), services))
  local seen = {}
  for _ = 1, 20 do
    task:stepSourceTick({ tick = 1 })
    local scroll = scene:scroll()
    seen[#seen + 1] = scroll.x .. "," .. scroll.y
    if task:status() == "complete" then
      break
    end
  end
  Assert.equal(task:status(), "complete", "the alternating run completes on its direction product")
  Assert.equal(#seen, 9, "the alternating run spans its phased nine compiled ticks")
  local moved = false
  for _, frame in ipairs(seen) do
    if frame ~= "0,0" then
      moved = true
    end
  end
  Assert.isTrue(moved, "the alternating sweep owns a viewport change instead of idling on a timer")
  local reversed = false
  local lastX = 0
  for _, frame in ipairs(seen) do
    local comma = string.find(frame, ",", 1, true)
    local x = tonumber(string.sub(frame, 1, comma - 1))
    if x ~= nil and lastX ~= 0 and x ~= 0 and ((x > 0) ~= (lastX > 0)) then
      reversed = true
    end
    if x ~= 0 then
      lastX = x
    end
  end
  Assert.isTrue(reversed, "the alternating sweep reverses direction across its phases")
  local settled = scene:scroll()
  Assert.equal(settled.x, 0, "completion restores the saved horizontal viewport")
  Assert.equal(settled.y, 0, "completion restores the saved vertical viewport")
  task:dispose()
  Assert.equal(#journal.released, #journal.acquired, "the sweep stages no leases")
end

function T.alternating_scroll_without_compiled_phases_stays_loud()
  local scene = sceneWithPair()
  local services, _journal = journalServices(scene)
  local ok, failure = pcall(
    BattleEffectTasks.create,
    "battle-background-alternating-scroll-transition",
    { parameters = { backgroundLayer = "battle-background-layer-3" } },
    occurrenceContext(),
    services
  )
  Assert.isTrue(not ok, "a phaseless alternating sweep never yields a runnable task")
  Assert.isTrue(
    type(failure) == "string"
      and string.find(failure, "battle-background-alternating-scroll-transition", 1, true) ~= nil,
    "the phaseless sweep fails naming its kind"
  )
end

function T.scanline_sine_sweep_moves_the_viewport_and_restores()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local task = assert(BattleEffectTasks.create("battle-background-scanline-sine-wave-transition", {
    callback = "battle-background-scanline-sine-wave-transition",
    taskContext = "battle-display",
    parameters = { backgroundLayer = "battle-background-layer-3", durationTicks = 12 },
  }, occurrenceContext(), services))
  local seen = {}
  for _ = 1, 40 do
    task:stepSourceTick({ tick = 1 })
    local scroll = scene:scroll()
    seen[#seen + 1] = scroll.x .. "," .. scroll.y
    if task:status() == "complete" then
      break
    end
  end
  Assert.equal(task:status(), "complete", "the sine sweep completes at its compiled duration")
  Assert.equal(#seen, 12, "the sine sweep spans its twelve compiled ticks")
  local moved = false
  for _, frame in ipairs(seen) do
    if frame ~= "0,0" then
      moved = true
    end
  end
  Assert.isTrue(moved, "the sine sweep owns a viewport change instead of idling on a timer")
  local settled = scene:scroll()
  Assert.equal(settled.x, 0, "completion restores the saved horizontal viewport")
  Assert.equal(settled.y, 0, "completion restores the saved vertical viewport")
  task:dispose()
  task:cancel("late")
  Assert.equal(task:status(), "complete", "completion survives late cancellation")
  Assert.equal(#journal.released, #journal.acquired, "the sweep stages no leases")
end

function T.blend_alpha_coefficients_interpolate_and_release()
  local scene = sceneWithPair()
  local services, journal = journalServices(scene)
  local task = assert(BattleEffectTasks.create("battle-sprite-blend-alpha-transition", {
    callback = "battle-sprite-blend-alpha-transition",
    taskContext = "battle-display",
    parameters = {
      durationTicks = 8,
      oamModeSpriteSlots = { "sprite-context-slot-0", "sprite-context-slot-1" },
      startCoefficientA = 16,
      startCoefficientB = 16,
      targetCoefficientA = 100,
      targetCoefficientB = 200,
    },
  }, occurrenceContext(), services))
  Assert.equal(task:status(), "pending", "blend coefficient runs open pending")
  task:stepSourceTick({ tick = 1 })
  local first = scene:taskScalarPatch(task)
  Assert.isTrue(first ~= nil, "the running blend owns its register state")
  for _ = 1, 40 do
    if task:status() == "complete" then
      break
    end
    task:stepSourceTick({ tick = 1 })
  end
  Assert.equal(task:status(), "complete", "the blend completes at its compiled duration")
  local held = scene:taskScalarPatch(task)
  Assert.isTrue(held ~= nil, "completion holds the final register state instead of restoring")
  Assert.equal(held.blendCoefficientA, 100, "the held sprite weight reaches its compiled target")
  Assert.equal(held.blendCoefficientB, 200, "the held background weight reaches its compiled target")
  task:dispose()
  Assert.isNil(scene:taskScalarPatch(task), "disposal releases the owned register state")
  Assert.equal(#journal.released, #journal.acquired, "the blend stages no leases")
end

function T.blend_alpha_coefficients_reach_their_compiled_targets()
  local scene = sceneWithPair()
  local services, _journal = journalServices(scene)
  local task = assert(BattleEffectTasks.create("battle-sprite-blend-alpha-transition", {
    parameters = {
      durationTicks = 8,
      startCoefficientA = 16,
      startCoefficientB = 16,
      targetCoefficientA = 100,
      targetCoefficientB = 200,
    },
  }, occurrenceContext(), services))
  for _ = 1, 7 do
    task:stepSourceTick({ tick = 1 })
  end
  Assert.isTrue(task:status() ~= "complete", "the compiled duration is not reached early")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "complete", "the blend completes at its eighth tick")
  task:dispose()
end

function T.overlapping_background_sweeps_restore_only_owned_viewport()
  local scene = sceneWithPair()
  local firstServices, firstJournal = journalServices(scene)
  local secondServices, secondJournal = journalServices(scene)
  local first = assert(BattleEffectTasks.create("battle-background-alternating-scroll-transition", {
    parameters = {
      backgroundLayer = "battle-background-layer-3",
      directionChanges = 2,
      ticksPerDirection = 2,
      horizontalOffset = 6,
      verticalOffset = 0,
    },
  }, occurrenceContext(), firstServices))
  local second = assert(BattleEffectTasks.create("battle-background-scanline-sine-wave-transition", {
    parameters = { backgroundLayer = "battle-background-layer-3", durationTicks = 4 },
  }, occurrenceContext(), secondServices))
  first:stepSourceTick({ tick = 1 })
  second:stepSourceTick({ tick = 1 })
  first:cancel("superseded")
  Assert.equal(first:status(), "cancelled", "cancellation lands on cancelled")
  local during = scene:scroll()
  Assert.isTrue(during.x ~= 0 or during.y ~= 0, "cancelling the first sweep never restores away the live second sweep")
  for _ = 1, 10 do
    if second:status() == "complete" then
      break
    end
    second:stepSourceTick({ tick = 1 })
  end
  Assert.equal(second:status(), "complete", "the surviving sweep completes on its own boundary")
  local settled = scene:scroll()
  Assert.equal(settled.x, 0, "the surviving completion restores the horizontal viewport")
  Assert.equal(settled.y, 0, "the surviving completion restores the vertical viewport")
  first:dispose()
  second:dispose()
  Assert.equal(#firstJournal.released, #firstJournal.acquired, "the cancelled sweep stages no leases")
  Assert.equal(#secondJournal.released, #secondJournal.acquired, "the surviving sweep stages no leases")
end

local BACKGROUND_RESOURCE_KEYS = {
  character = "battle/background/test/character",
  palette = "battle/background/test/palette",
  screenDefault = "battle/background/test/screen-default",
  screenAlternate = "battle/background/test/screen-alternate",
}

local function sceneWithEffectBackground()
  local scene = sceneWithPair()
  local colors = {}
  for _ = 1, 16 do
    colors[#colors + 1] = { r = 0, g = 0, b = 0 }
  end
  colors[2] = { r = 200, g = 0, b = 0 }
  scene:installBackground({
    characters = string.char(0x11) .. string.rep("\0", 31),
    colorMode = "4bpp",
    map = { width = 8, height = 8, entries = { { tile = 0, flipH = false, flipV = false, palette = 0 } } },
    palette = { colors = colors },
  })
  return scene
end

local function backgroundServices(scene, journal, overrides)
  local payloads = {
    [BACKGROUND_RESOURCE_KEYS.character] = { depth = 3, tiles = string.char(0x10) .. string.rep("\0", 31) },
    [BACKGROUND_RESOURCE_KEYS.palette] = {
      colors = (function()
        local colors = {}
        for _ = 1, 16 do
          colors[#colors + 1] = { r = 0, g = 0, b = 0 }
        end
        colors[2] = { r = 0, g = 180, b = 0 }
        return colors
      end)(),
    },
    [BACKGROUND_RESOURCE_KEYS.screenDefault] = {
      width = 8,
      height = 8,
      entries = { { tile = 0, flipH = false, flipV = false, palette = 0 } },
    },
    [BACKGROUND_RESOURCE_KEYS.screenAlternate] = {
      width = 8,
      height = 8,
      entries = { { tile = 0, flipH = true, flipV = false, palette = 0 } },
    },
  }
  if type(overrides) == "table" then
    for key, payload in pairs(overrides) do
      payloads[key] = payload
    end
  end
  local resources = {}
  function resources.resolve(key)
    journal.acquired[#journal.acquired + 1] = key
    local data = payloads[key]
    if data == nil then
      error("unknown battle background resource " .. tostring(key), 0)
    end
    return { key = key, data = data }
  end
  function resources.release(lease)
    journal.released[#journal.released + 1] = lease
  end
  return { scene = scene, audio = {}, resources = resources }
end

local function backgroundLoadArgs(values)
  return {
    values = values or { 9, 0x1234 },
    screenFlipArg = 0,
    resourceKeys = BACKGROUND_RESOURCE_KEYS,
    runtimeSelection = "battle-background-screen-selection",
  }
end

local function backgroundPlayback(scene, journal, attackerSide, defenderSide, arg, cleanup)
  local services = backgroundServices(scene, journal)
  services.audio = {
    play = function(_name) end,
    stop = function(_name) end,
    isFinished = function(_name)
      return true
    end,
  }
  local instruction = {
    op = "start-visual-task",
    taskKind = cleanup and "battle-presentation-resource-cleanup" or "battle-background-resource-load",
    values = { 9, 0x1234 },
  }
  if not cleanup then
    instruction.resourceKeys = BACKGROUND_RESOURCE_KEYS
    instruction.runtimeSelection = "battle-background-screen-selection"
  end
  local player = assert(BattleAnimationPlayer.new({
    scene = scene,
    audio = services.audio,
    resources = services.resources,
    tasks = {
      create = function(kind, args, context, collaborators)
        return BattleEffectTasks.create(kind, args, context, collaborators)
      end,
    },
  }))
  local program = {
    entry = "main",
    instructions = {
      { op = "set-parameter", values = { 7, arg } },
      instruction,
      { op = "set-parameter", values = { 7, 0 } },
    },
    subprograms = {},
    taskKinds = {},
  }
  local handle = assert(player:start({
    launchId = "background-playback",
    packetId = 1,
    topology = {
      attacker = { combatant = 1, activation = 1, sideType = attackerSide },
      targets = { { combatant = 2, activation = 2, sideType = defenderSide } },
    },
  }, program))
  player:stepSourceTick({ tick = 1 })
  player:stepSourceTick({ tick = 2 })
  return player, handle
end

function T.native_background_selection_uses_event_sides_and_spawn_time_parameter()
  local cases = {
    { arg = 0, attacker = 0, defender = 0, alternate = false },
    { arg = 0, attacker = 1, defender = 0, alternate = false },
    { arg = 1, attacker = 0, defender = 4, alternate = true },
    { arg = 1, attacker = 1, defender = 1, alternate = false },
    { arg = 2, attacker = 4, defender = 2, alternate = false },
    { arg = 2, attacker = 3, defender = 5, alternate = true },
    { arg = 2, attacker = 2, defender = 1, alternate = false },
    { arg = 2, attacker = 5, defender = 0, alternate = true },
  }
  local failures = {}
  for _, case in ipairs(cases) do
    local scene = sceneWithEffectBackground()
    local journal = { acquired = {}, released = {} }
    local player, handle = backgroundPlayback(scene, journal, case.attacker, case.defender, case.arg)
    Assert.equal(player:status(handle), "complete", "the staged background task completes")
    local pixel = { scene:backgroundRaster():pixel(1, 0) }
    local expected
    if case.alternate then
      expected = { 0, 0, 0, 0 }
    else
      expected = { 0, 180, 0, 255 }
    end
    local matches = pcall(Assert.deepEqual, pixel, expected, "the selected map is visible at its native tile position")
    if not matches then
      failures[#failures + 1] = string.format(
        "arg=%d attacker=%d defender=%d selected %s map produced %s",
        case.arg,
        case.attacker,
        case.defender,
        case.alternate and "alternate" or "default",
        table.concat(pixel, ",")
      )
    end
    Assert.equal(#journal.acquired, 4, "both variants and shared background resources are staged")
    Assert.equal(#journal.released, 4, "the completed occurrence releases every staged lease")
    player:dispose()
  end
  Assert.equal(#failures, 0, table.concat(failures, "\n"))
end

function T.native_background_selection_persists_until_cleanup_and_rejects_missing_sides()
  local failures = {}
  local function recordEqual(actual, expected, label)
    local matches = pcall(Assert.deepEqual, actual, expected, label)
    if not matches then
      failures[#failures + 1] = label
    end
  end
  local scene = sceneWithEffectBackground()
  local journal = { acquired = {}, released = {} }
  local player, handle = backgroundPlayback(scene, journal, 3, 5, 2)
  if player:status(handle) ~= "complete" then
    failures[#failures + 1] = "the alternate load completes"
  end
  recordEqual(
    { scene:backgroundRaster():pixel(1, 0) },
    { 0, 0, 0, 0 },
    "the selected alternate remains installed after task completion and disposal"
  )
  player:dispose()
  local cleanupPlayer, cleanupHandle = backgroundPlayback(scene, { acquired = {}, released = {} }, 0, 1, 0, true)
  if cleanupPlayer:status(cleanupHandle) ~= "complete" then
    failures[#failures + 1] = "the source cleanup task completes"
  end
  recordEqual(
    { scene:backgroundRaster():pixel(1, 0) },
    { 200, 0, 0, 255 },
    "cleanup restores the original scene background"
  )
  cleanupPlayer:dispose()

  local malformedScene = sceneWithEffectBackground()
  local malformedJournal = { acquired = {}, released = {} }
  local services = backgroundServices(malformedScene, malformedJournal)
  services.audio = {
    play = function(_name) end,
    stop = function(_name) end,
    isFinished = function(_name)
      return true
    end,
  }
  local malformedPlayer = assert(BattleAnimationPlayer.new({
    scene = malformedScene,
    audio = services.audio,
    resources = services.resources,
    tasks = {
      create = function(kind, args, context, collaborators)
        return BattleEffectTasks.create(kind, args, context, collaborators)
      end,
    },
  }))
  local malformedHandle = assert(malformedPlayer:start({
    launchId = "background-missing-defender",
    packetId = 2,
    topology = { attacker = { combatant = 1, activation = 1, sideType = 0 }, targets = {} },
  }, {
    entry = "main",
    instructions = {
      { op = "set-parameter", values = { 7, 1 } },
      {
        op = "start-visual-task",
        taskKind = "battle-background-resource-load",
        values = { 9, 0x1234 },
        resourceKeys = BACKGROUND_RESOURCE_KEYS,
        runtimeSelection = "battle-background-screen-selection",
      },
    },
    subprograms = {},
    taskKinds = {},
  }))
  malformedPlayer:stepSourceTick({ tick = 1 })
  malformedPlayer:stepSourceTick({ tick = 2 })
  local status = malformedPlayer:status(malformedHandle)
  if status ~= "failed" then
    failures[#failures + 1] = "a required missing defender fails the occurrence"
  end
  local failure = malformedPlayer:failure(malformedHandle)
  if failure == nil or failure.launchId ~= "background-missing-defender" then
    failures[#failures + 1] = "the failure keeps launch provenance"
  end
  if failure == nil or string.find(failure.reason, "background", 1, true) == nil then
    failures[#failures + 1] = "the failure explains the missing context"
  end
  if #malformedJournal.released ~= #malformedJournal.acquired then
    failures[#failures + 1] = "failed context releases staged leases exactly once"
  end
  malformedPlayer:dispose()
  Assert.equal(#failures, 0, table.concat(failures, "\n"))
end

function T.background_resource_load_installs_the_staged_layer_and_holds_it_past_disposal()
  local scene = sceneWithEffectBackground()
  local journal = { acquired = {}, released = {} }
  local services = backgroundServices(scene, journal)
  Assert.deepEqual({ scene:backgroundRaster():pixel(0, 0) }, { 200, 0, 0, 255 }, "the base plane shows first")
  local task = assert(
    BattleEffectTasks.create("battle-background-resource-load", backgroundLoadArgs(), occurrenceContext(), services)
  )
  Assert.equal(task:status(), "pending", "the load opens pending")
  Assert.deepEqual(
    { scene:backgroundRaster():pixel(1, 0) },
    { 200, 0, 0, 255 },
    "construction stages the layer without installing it"
  )
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "complete", "the load retires on its first tick")
  Assert.deepEqual(
    { scene:backgroundRaster():pixel(1, 0) },
    { 0, 180, 0, 255 },
    "the staged effect pixels replace the ordinary BG3 plane"
  )
  Assert.deepEqual(
    { scene:backgroundRaster():pixel(0, 0) },
    { 0, 0, 0, 0 },
    "transparent palette index does not reveal the replaced BG3"
  )
  task:dispose()
  task:cancel("late")
  Assert.equal(task:status(), "complete", "completion survives late cancellation")
  Assert.deepEqual(
    { scene:backgroundRaster():pixel(1, 0) },
    { 0, 180, 0, 255 },
    "the installed layer survives the owning task's disposal until cleanup"
  )
  Assert.equal(#journal.released, #journal.acquired, "every staged lease releases exactly once")
  Assert.equal(#journal.acquired, 4, "the load stages its four declared slots")
end

function T.background_resource_cleanup_removes_the_layer_exactly_once()
  local scene = sceneWithEffectBackground()
  local journal = { acquired = {}, released = {} }
  local services = backgroundServices(scene, journal)
  local load = assert(
    BattleEffectTasks.create("battle-background-resource-load", backgroundLoadArgs(), occurrenceContext(), services)
  )
  load:stepSourceTick({ tick = 1 })
  load:dispose()
  local cleanupServices, cleanupJournal = journalServices(scene)
  local cleanup = assert(
    BattleEffectTasks.create(
      "battle-presentation-resource-cleanup",
      { values = { 9, 0x1234 } },
      occurrenceContext(),
      cleanupServices
    )
  )
  Assert.equal(cleanup:status(), "pending", "cleanup opens pending")
  cleanup:stepSourceTick({ tick = 1 })
  Assert.equal(cleanup:status(), "complete", "cleanup retires on its first tick")
  Assert.deepEqual(
    { scene:backgroundRaster():pixel(1, 0) },
    { 200, 0, 0, 255 },
    "removal restores the persistent BG3 plane"
  )
  cleanup:dispose()
  cleanup:cancel("late")
  Assert.equal(cleanup:status(), "complete", "cleanup completion survives late cancellation")
  Assert.deepEqual(
    { scene:backgroundRaster():pixel(1, 0) },
    { 200, 0, 0, 255 },
    "repeated teardown never reinstalls or disturbs the restored plane"
  )
  Assert.equal(#cleanupJournal.released, #cleanupJournal.acquired, "cleanup stages no leases")
end

function T.background_resource_failures_stay_closed()
  local scene = sceneWithEffectBackground()
  local journal = { acquired = {}, released = {} }
  local services = backgroundServices(scene, journal)
  local first = assert(
    BattleEffectTasks.create("battle-background-resource-load", backgroundLoadArgs(), occurrenceContext(), services)
  )
  first:stepSourceTick({ tick = 1 })
  local second = assert(
    BattleEffectTasks.create("battle-background-resource-load", backgroundLoadArgs(), occurrenceContext(), services)
  )
  local ok, failure = pcall(second.stepSourceTick, second, { tick = 1 })
  Assert.isTrue(not ok, "a duplicate effect layer never installs twice")
  Assert.isTrue(
    string.find(tostring(failure), "effect layer keys are unique", 1, true) ~= nil,
    "the duplicate rejection names the ownership rule"
  )
  second:dispose()
  first:dispose()
  local bare = sceneWithEffectBackground()
  local bareServices, _ = journalServices(bare)
  local cleanup = assert(
    BattleEffectTasks.create(
      "battle-presentation-resource-cleanup",
      { values = { 9, 0x1234 } },
      occurrenceContext(),
      bareServices
    )
  )
  local removed, removeFailure = pcall(cleanup.stepSourceTick, cleanup, { tick = 1 })
  Assert.isTrue(not removed, "removing an absent layer never succeeds silently")
  Assert.isTrue(
    string.find(tostring(removeFailure), "battle-background-layer-3", 1, true) ~= nil,
    "the unknown-layer rejection names the layer"
  )
  cleanup:dispose()

  local malformed = {
    { values = { 9 }, resourceKeys = BACKGROUND_RESOURCE_KEYS },
    { values = "nine", resourceKeys = BACKGROUND_RESOURCE_KEYS },
    { values = { 9, 0x1234 } },
    { values = { 9, 0x1234 }, resourceKeys = { character = BACKGROUND_RESOURCE_KEYS.character } },
    {
      values = { 9, 0x1234 },
      resourceKeys = BACKGROUND_RESOURCE_KEYS,
      runtimeSelection = "battle-background-three-way-screen-selection",
    },
  }
  for index, args in ipairs(malformed) do
    local ok, failure =
      pcall(BattleEffectTasks.create, "battle-background-resource-load", args, occurrenceContext(), services)
    if ok then
      local stepOk, stepFailure = pcall(failure.stepSourceTick, failure, { tick = 1 })
      failure:dispose()
      Assert.isTrue(not stepOk, "malformed load " .. index .. " never installs")
      Assert.isTrue(
        string.find(tostring(stepFailure), "battle-background-resource-load", 1, true) ~= nil,
        "malformed load " .. index .. " fails naming its kind"
      )
    else
      Assert.isTrue(
        string.find(tostring(failure), "battle-background-resource-load", 1, true) ~= nil,
        "malformed load " .. index .. " fails naming its kind"
      )
    end
  end
  Assert.equal(#journal.released, #journal.acquired, "failed loads release every staged lease")

  local slotlessScene = sceneWithEffectBackground()
  local slotlessServices, _ = journalServices(slotlessScene)
  local slotOk, slotFailure = pcall(
    BattleEffectTasks.create,
    "battle-background-resource-load",
    { values = { 9, 0x1234 } },
    occurrenceContext(),
    slotlessServices
  )
  if slotOk then
    local stepOk = pcall(slotFailure.stepSourceTick, slotFailure, { tick = 1 })
    slotFailure:dispose()
    Assert.isTrue(not stepOk, "a slotless load never installs")
  else
    Assert.isTrue(
      string.find(tostring(slotFailure), "battle-background-resource-load", 1, true) ~= nil,
      "a slotless load fails naming its kind"
    )
  end

  local cancelScene = sceneWithEffectBackground()
  local cancelJournal = { acquired = {}, released = {} }
  local cancelServices = backgroundServices(cancelScene, cancelJournal)
  local cancelled = assert(
    BattleEffectTasks.create(
      "battle-background-resource-load",
      backgroundLoadArgs(),
      occurrenceContext(),
      cancelServices
    )
  )
  cancelled:cancel("withdrawn")
  Assert.equal(cancelled:status(), "cancelled", "cancellation lands on cancelled")
  cancelled:stepSourceTick({ tick = 1 })
  Assert.equal(cancelled:status(), "cancelled", "cancelled loads never install late")
  Assert.deepEqual(
    { cancelScene:backgroundRaster():pixel(1, 0) },
    { 200, 0, 0, 255 },
    "the persistent plane is untouched"
  )
  cancelled:dispose()
  Assert.equal(#cancelJournal.released, #cancelJournal.acquired, "cancelled loads release every staged lease")
end

return { tests = T }
