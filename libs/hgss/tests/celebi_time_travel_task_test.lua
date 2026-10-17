-- Celebi time-travel cutscene task: the visible source-ordered fade
-- timeline around the shrine's CelebiTimeTravel command. The cutscene
-- opens with a short white fade-out and back in, holds the field visible
-- through a 30-tick model beat and the first 79 swirl ticks, starts its
-- 30-step closing white fade exactly at swirl tick 80, and completes only
-- once the full 180-tick swirl and an opaque cover land together for the
-- authored warp. The 3D model, camera roll, and motion blur have no
-- presentation owner here, so this contract proves fade ordering and
-- cover only, never cinematic completeness.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CelebiTimeTravelTask = require("libs.hgss.src.script.tasks.CelebiTimeTravelTask")
local S = require("gen4.script")
local Registry = require("libs.script.src.Registry")
local Composition = require("libs.script.src.Composition")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local Scheduler = require("libs.script.src.Scheduler")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

local T = {}

local OPENING_STEPS = 4
local BEAT_TICKS = 30
local SWIRL_TICKS = 180
local CLOSING_START_TICK = 80
local CLOSING_STEPS = 30

-- A live screen backend: the real fade controller wrapped with a start
-- log. The fade advances only from an explicit source-frame tick driven
-- separately from task polls, exactly like the field runtime advances
-- its owned controller after each scheduler poll. A fake that counts
-- polls would prove nothing about visible cover.
local function liveScreen()
  local FieldScriptScreenFade = require("libs.hgss.src.transition.FieldScriptScreenFade")
  local fade = FieldScriptScreenFade.new()
  local backend = { fade = fade, starts = {} }
  function backend:startFade(spec)
    self.starts[#self.starts + 1] = {
      direction = spec.direction,
      color = spec.color,
      duration = spec.duration,
      speed = spec.speed,
      screenScope = spec.screenScope,
    }
    return self.fade:startFade(spec)
  end
  function backend:clearIfCurrent(lease)
    return self.fade:clearIfCurrent(lease)
  end
  function backend:fadeDone()
    return self.fade:fadeDone()
  end
  function backend:isOpaque()
    return self.fade:isOpaque()
  end
  function backend:status()
    return self.fade:status()
  end
  function backend:tick()
    self.fade:updateSourceFrame()
  end
  return backend
end

local function schedulerWith(screen)
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local resource = S.script({ api = 1, id = "test.celebi_cancel", steps = { S.waitTicks({ ticks = 100 }) } })
  registry:installBase(resource.id, resource, "generated")
  local taskRegistry = TaskRegistry.new()
  taskRegistry:register(CelebiTimeTravelTask.type, CelebiTimeTravelTask.version, CelebiTimeTravelTask)
  local WaitTicksTask = require("libs.script.src.tasks.WaitTicksTask")
  taskRegistry:register(WaitTicksTask.type, WaitTicksTask.version, WaitTicksTask)
  local scheduler = Scheduler.new({
    semantics = RuntimeValues,
    services = { screen = screen },
    taskRegistry = taskRegistry,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  local instanceId = scheduler:createForeground(assert(composition:effective(resource.id)), nil, 100)
  local instance = assert(scheduler:instance(instanceId))
  scheduler:createTask("celebi_time_travel", {}, instance, 100, nil)
  return scheduler, instance
end

local function ctxWith(screen)
  return { services = { screen = screen } }
end

-- One production tick: the scheduler polls the task first, then the
-- runtime advances the owned screen fade by one source frame.
local function tick(screen, state, ctx)
  local result = CelebiTimeTravelTask.poll(state, ctx)
  screen:tick()
  return result, result.state
end

local function assertStart(spec, direction, duration, what)
  Assert.equal(spec.direction, direction, what .. " direction")
  Assert.equal(spec.color, "white", what .. " color")
  Assert.equal(spec.duration, duration, what .. " duration")
  Assert.equal(spec.speed, 1, what .. " speed")
end

-- Drive poll-plus-source-frame ticks until the task leaves `phase`.
-- Fails if the phase never ends within the bound.
local function drivePhase(screen, state, ctx, phase, maxTicks)
  local spent = 0
  local result = nil
  while state.phase == phase and spent < maxTicks do
    result, state = tick(screen, state, ctx)
    spent = spent + 1
  end
  Assert.isFalse(state.phase == phase, "the cutscene must leave " .. phase)
  return spent, result, state
end

-- Drive from a fresh cutscene until the beat phase opens. The opening
-- fades must have run exactly once each before the beat is visible.
local function reachBeat(screen, ctx)
  local state = CelebiTimeTravelTask.create()
  Assert.equal(state.phase, "opening_out", "the cutscene opens on its short white fade-out")
  local _, _, beat = drivePhase(screen, state, ctx, "opening_out", 30)
  state = beat
  _, _, state = drivePhase(screen, state, ctx, "opening_in", 30)
  Assert.equal(state.phase, "beat", "the cleared opening hands off to the model beat")
  Assert.equal(#screen.starts, 2, "only the two opening fades run before the beat")
  return state
end

function T.opening_fades_run_out_then_in_and_clear_before_the_beat()
  local screen = liveScreen()
  local ctx = ctxWith(screen)
  local state = CelebiTimeTravelTask.create()
  local result
  result, state = tick(screen, state, ctx)
  Assert.isFalse(result.complete, "starting the opening fade must not settle the cutscene")
  Assert.equal(#screen.starts, 1, "the first poll starts exactly one fade")
  assertStart(screen.starts[1], "out", OPENING_STEPS, "opening fade-out")
  Assert.equal(screen.starts[1].screenScope, "main", "the opening fade targets the source main screen")
  Assert.equal(screen:status().coefficient, 4, "one source frame interpolates the white cover to 4")
  local borrowed = screen.fade:presentationOverlay()
  Assert.notNil(borrowed, "the opening fade lends a presentation overlay while active")
  result, state = tick(screen, state, ctx)
  Assert.isFalse(result.complete, "the opening fade-out must not settle the cutscene")
  Assert.equal(screen:status().coefficient, 8, "the second source frame interpolates the cover to 8")
  Assert.isTrue(screen.fade:presentationOverlay() == borrowed, "in-flight frames reuse one overlay record")
  result, state = tick(screen, state, ctx)
  Assert.equal(screen:status().coefficient, 12, "the third source frame interpolates the cover to 12")
  result, state = tick(screen, state, ctx)
  Assert.isFalse(result.complete, "landing the opening fade-out must not settle the cutscene")
  Assert.isTrue(screen:fadeDone(), "four source frames land the short opening fade-out")
  Assert.isTrue(screen:isOpaque(), "the landed opening fade-out is fully opaque")
  Assert.equal(screen:status().coefficient, 16, "the landed opening fade-out reports a full coefficient")
  result, state = tick(screen, state, ctx)
  Assert.isFalse(result.complete, "starting the fade-in must not settle the cutscene")
  Assert.equal(#screen.starts, 2, "the landed fade-out hands off to exactly one fade-in")
  assertStart(screen.starts[2], "in", OPENING_STEPS, "opening fade-in")
  Assert.equal(screen.starts[2].screenScope, "main", "the opening fade-in targets the source main screen")
  Assert.equal(screen:status().coefficient, 12, "the start poll's own source frame interpolates the cover to 12")
  local expected = { 8, 4, 0 }
  for index, want in ipairs(expected) do
    result, state = tick(screen, state, ctx)
    Assert.isFalse(result.complete, "the opening fade-in must not settle the cutscene")
    Assert.equal(screen:status().coefficient, want, "fade-in coefficient after source frame " .. index)
  end
  Assert.isTrue(screen:fadeDone(), "four source frames land the opening fade-in")
  Assert.isFalse(screen:isOpaque(), "the landed fade-in leaves the field visible")
  Assert.isNil(screen:status().overlay, "a clear screen lends no overlay")
  Assert.equal(#screen.starts, 2, "the opening never starts a third fade")
end

function T.beat_and_early_swirl_stay_visible_until_the_late_closing_fade()
  local screen = liveScreen()
  local ctx = ctxWith(screen)
  local state = reachBeat(screen, ctx)
  local spent = 0
  while state.phase == "beat" and spent < 40 do
    Assert.isNil(screen:status().overlay, "the model beat holds a clear screen")
    local result
    result, state = tick(screen, state, ctx)
    spent = spent + 1
    Assert.isFalse(result.complete, "the beat alone must not settle the cutscene")
    Assert.equal(#screen.starts, 2, "the beat starts no fade of its own")
  end
  Assert.equal(spent, BEAT_TICKS, "the beat lasts exactly its authored ticks")
  Assert.equal(state.phase, "swirl", "the beat hands off to the swirl interval")
  Assert.equal(state.elapsed, 0, "the swirl restarts its count on entry")
  local swirlPolls = 0
  local closingPoll = nil
  local result = nil
  while swirlPolls < SWIRL_TICKS + 40 do
    if state.phase == "swirl" and state.elapsed < CLOSING_START_TICK and #screen.starts == 2 then
      Assert.isNil(screen:status().overlay, "the early swirl holds a clear screen")
    end
    result, state = tick(screen, state, ctx)
    swirlPolls = swirlPolls + 1
    if #screen.starts == 3 and closingPoll == nil then
      closingPoll = swirlPolls
      Assert.equal(state.elapsed, CLOSING_START_TICK, "the closing fade starts exactly at swirl tick 80")
      assertStart(screen.starts[3], "out", CLOSING_STEPS, "closing fade-out")
      Assert.equal(screen.starts[3].screenScope, "both", "the final white cover targets both source screens")
    end
    if result.complete then
      break
    end
    if closingPoll == nil then
      Assert.equal(#screen.starts, 2, "only the closing fade may start after the opening")
    else
      Assert.equal(#screen.starts, 3, "the closing fade starts exactly once")
    end
  end
  Assert.equal(closingPoll, CLOSING_START_TICK, "the closing fade starts on the 80th swirl poll")
  Assert.isTrue(result.complete, "the full swirl settles the cutscene under its landed cover")
  Assert.equal(swirlPolls, SWIRL_TICKS, "the closing fade never extends the swirl clock")
  Assert.equal(#screen.starts, 3, "the timeline runs exactly three fades with no overlap")
  Assert.isTrue(screen:isOpaque(), "the cutscene lands under a fully opaque cover for its warp")
  Assert.equal(screen:status().coefficient, 16, "the terminal cover reports a full coefficient")
  Assert.equal(screen:status().overlay.a, 1, "the terminal overlay is fully opaque")
end

function T.a_busy_entry_fade_waits_without_consuming_beat_ticks()
  local screen = liveScreen()
  -- An unrelated in-flight fade owns the shared controller at entry; it
  -- bypasses the task start log so only cutscene starts are counted.
  screen.fade:startFade({ direction = "out", color = "white", duration = 30, speed = 1 })
  local ctx = ctxWith(screen)
  local state = CelebiTimeTravelTask.create()
  for _ = 1, 5 do
    local result = CelebiTimeTravelTask.poll(state, ctx)
    state = result.state
    Assert.isFalse(result.complete, "the entry wait must not settle the cutscene")
  end
  Assert.equal(#screen.starts, 0, "the cutscene never overlaps an in-flight fade")
  Assert.equal(state.phase, "opening_out", "the cutscene still waits in its opening")
  Assert.equal(state.elapsed, 0, "the opening wait consumes no beat ticks")
  for _ = 1, 30 do
    screen:tick()
  end
  Assert.isTrue(screen:fadeDone(), "the setup lands the unrelated fade")
  local result
  result, state = CelebiTimeTravelTask.poll(state, ctx)
  Assert.isFalse(result.complete, "starting the opening fade must not settle the cutscene")
  Assert.equal(#screen.starts, 1, "the landed fade lets the opening fade start exactly once")
  assertStart(screen.starts[1], "out", OPENING_STEPS, "opening fade-out")
end

function T.a_slow_closing_fade_holds_completion_open_with_a_capped_swirl_count()
  local screen = liveScreen()
  local ctx = ctxWith(screen)
  local state = reachBeat(screen, ctx)
  local setup = 0
  while not (#screen.starts == 3) do
    Assert.isTrue(setup < 400, "the closing fade must start within its authored beats")
    setup = setup + 1
    local result
    result, state = tick(screen, state, ctx)
    Assert.isFalse(result.complete, "the cutscene must not settle before its closing fade lands")
    Assert.isTrue(state.elapsed <= SWIRL_TICKS, "the swirl count stays within its authored interval")
  end
  Assert.equal(state.elapsed, CLOSING_START_TICK, "slow-fade setup stops at the closing edge")
  -- Freeze the source-frame clock: polls alone must neither advance the
  -- fade nor restart it.
  local held = 0
  while held < SWIRL_TICKS do
    local result = CelebiTimeTravelTask.poll(state, ctx)
    state = result.state
    held = held + 1
    Assert.isFalse(result.complete, "an unlanded closing fade holds the cutscene open")
    Assert.equal(#screen.starts, 3, "waiting never restarts the closing fade")
  end
  Assert.equal(state.elapsed, SWIRL_TICKS, "the swirl count caps instead of running past its interval")
  Assert.isNil(CelebiTimeTravelTask.validate(state), "the capped closing-wait shape stays a valid saved state")
  local result = nil
  local extra = 0
  while extra < 60 do
    result, state = tick(screen, state, ctx)
    extra = extra + 1
    if result.complete then
      break
    end
  end
  Assert.isTrue(result.complete, "the landed closing fade settles the cutscene")
  Assert.equal(#screen.starts, 3, "landing the closing fade starts no further fade")
  Assert.isTrue(screen:isOpaque(), "the settled cutscene leaves the opaque cover for its warp")
end

function T.a_done_but_clear_backend_is_a_loud_fault()
  local backend = { starts = {} }
  function backend:startFade(spec)
    self.starts[#self.starts + 1] = spec
  end
  function backend:clearIfCurrent(_)
    return false
  end
  function backend:fadeDone()
    return true
  end
  function backend:isOpaque()
    return false
  end
  local state = { phase = "swirl", elapsed = SWIRL_TICKS, fadeStarted = true }
  local ok, result = pcall(CelebiTimeTravelTask.poll, state, { services = { screen = backend } })
  Assert.isFalse(ok, "a done-but-clear backend must not settle the cutscene")
  Assert.isFalse(ok and result.complete, "a done-but-clear backend must never report a covered warp")
end

function T.a_backend_without_opaque_status_is_an_attributed_fault()
  local backend = { starts = {} }
  function backend:startFade(spec)
    self.starts[#self.starts + 1] = spec
  end
  function backend:clearIfCurrent(_)
    return false
  end
  function backend:fadeDone()
    return true
  end
  local state = CelebiTimeTravelTask.create()
  local ctx = { services = { screen = backend } }
  local fault = nil
  local settled = false
  for _ = 1, 600 do
    local ok, result = pcall(CelebiTimeTravelTask.poll, state, ctx)
    if not ok then
      fault = result
      break
    end
    state = result.state
    if result.complete then
      settled = true
      break
    end
  end
  Assert.isFalse(settled, "a backend without opaque status must never settle the cutscene")
  Assert.notNil(fault, "a backend without opaque status must fail loudly")
  Assert.isTrue(Errors.is(fault), "the missing opaque status raises a structured fault")
  Assert.equal(fault.code, "SCRIPT_SERVICE_MISSING", "the fault names the missing service")
end

function T.a_missing_screen_is_an_attributed_fault()
  local ok, err = pcall(CelebiTimeTravelTask.poll, CelebiTimeTravelTask.create(), { services = {} })
  Assert.isFalse(ok, "the cutscene requires its screen cover backend")
  Assert.isTrue(Errors.is(err), "the missing backend raises a structured fault")
  Assert.equal(err.code, "SCRIPT_SERVICE_MISSING", "the fault names the missing service")
end

function T.cancellation_settles_without_starting_another_fade()
  local screen = liveScreen()
  local ctx = ctxWith(screen)
  local state = CelebiTimeTravelTask.create()
  local result
  result, state = tick(screen, state, ctx)
  Assert.equal(#screen.starts, 1, "the setup starts the opening fade")
  CelebiTimeTravelTask.cancel(state, "acceptance injected failure", ctx)
  result = CelebiTimeTravelTask.poll(state, ctx)
  state = result.state
  Assert.isTrue(result.complete, "cancellation settles the cutscene")
  Assert.equal(#screen.starts, 1, "cancellation starts no further fade")
  Assert.isNil(CelebiTimeTravelTask.validate(state), "the cancelled shape still validates")
end

function T.cancellation_before_the_first_poll_needs_no_fade_owner()
  local state = CelebiTimeTravelTask.create()
  CelebiTimeTravelTask.cancel(state, "cancelled before acceptance", nil)
  Assert.isNil(CelebiTimeTravelTask.validate(state), "early cancellation keeps a valid task state")
  local result = CelebiTimeTravelTask.poll(state, {})
  Assert.isTrue(result.complete, "a task cancelled before polling settles without starting a fade")
end

function T.cancellation_during_opening_in_and_beat_releases_the_latest_lease()
  local screen = liveScreen()
  local ctx = ctxWith(screen)
  local state = CelebiTimeTravelTask.create()
  _, _, state = drivePhase(screen, state, ctx, "opening_out", 30)
  Assert.equal(state.phase, "opening_in", "the opening out hands off to the inbound fade")
  Assert.notNil(screen.fade:presentationOverlay(), "the inbound fade has a visible cover to release")
  CelebiTimeTravelTask.cancel(state, "interrupted during opening in", ctx)
  Assert.isNil(screen.fade:presentationOverlay(), "inbound cancellation clears the owned cover immediately")
  Assert.isNil(screen:status().screenScope, "inbound cancellation returns ownership to idle")

  screen = liveScreen()
  ctx = ctxWith(screen)
  state = reachBeat(screen, ctx)
  Assert.equal(state.phase, "beat", "the opening fades finish before the model beat")
  CelebiTimeTravelTask.cancel(state, "interrupted during beat", ctx)
  Assert.isNil(screen:status().screenScope, "beat cancellation releases the retained completed fade lease")
end

function T.scheduler_cancellation_releases_the_opening_cover_and_allows_an_ordinary_fade()
  local screen = liveScreen()
  local scheduler, instance = schedulerWith(screen)
  scheduler:step(100, nil)
  scheduler:step(101, nil)
  screen:tick()
  scheduler:step(102, nil)
  screen:tick()
  Assert.equal(screen:status().coefficient, 8, "the scheduler has entered the active opening cover")

  scheduler:cancelEnvironment(instance.environmentId, "injected failure")
  Assert.isNil(screen.fade:presentationOverlay(), "scheduler cancellation immediately removes the owned cover")
  Assert.isFalse(screen:status().active, "scheduler cancellation returns the shared controller to idle")
  for _ = 1, 40 do
    screen:tick()
  end
  Assert.isNil(screen.fade:presentationOverlay(), "later source ticks cannot restore the cancelled cover")
  local ok = pcall(function()
    screen.fade:startFade({ direction = "out", color = "black", duration = 6, speed = 1 })
  end)
  Assert.isTrue(ok, "an ordinary fade can start after cleanup")
end

function T.cancelling_while_waiting_for_a_foreign_fade_preserves_it()
  local screen = liveScreen()
  screen.fade:startFade({ direction = "out", color = "black", duration = 30, speed = 1 })
  local scheduler, instance = schedulerWith(screen)
  scheduler:step(100, nil)
  scheduler:step(101, nil)
  screen:tick()
  scheduler:step(102, nil)
  screen:tick()
  Assert.equal(#screen.starts, 0, "Celebi is still waiting while the foreign fade owns the controller")
  local foreignCoefficient = screen.fade:status().coefficient

  scheduler:cancelEnvironment(instance.environmentId, "injected failure")
  Assert.equal(
    screen.fade:status().coefficient,
    foreignCoefficient,
    "cancelling a waiter leaves the foreign fade's progress intact"
  )
end

function T.only_the_documented_state_shape_validates()
  for _, state in ipairs({
    { phase = "opening_out", elapsed = 0, fadeStarted = false },
    { phase = "opening_out", elapsed = 0, fadeStarted = true },
    { phase = "opening_in", elapsed = 0, fadeStarted = false },
    { phase = "opening_in", elapsed = 0, fadeStarted = true },
    { phase = "beat", elapsed = 0, fadeStarted = false },
    { phase = "beat", elapsed = BEAT_TICKS, fadeStarted = false },
    { phase = "swirl", elapsed = 0, fadeStarted = false },
    { phase = "swirl", elapsed = CLOSING_START_TICK, fadeStarted = true },
    { phase = "swirl", elapsed = SWIRL_TICKS, fadeStarted = true },
    { phase = "beat", elapsed = 0, fadeStarted = false, cancelled = "operator request" },
  }) do
    Assert.isNil(CelebiTimeTravelTask.validate(state), "a documented shape must validate")
  end
  local rejected = {
    "beat",
    {},
    { phase = "fade", elapsed = 0, fadeStarted = false },
    { phase = "opening_out", elapsed = 1, fadeStarted = true },
    { phase = "opening_in", elapsed = 1, fadeStarted = true },
    { phase = "beat", elapsed = -1, fadeStarted = false },
    { phase = "beat", elapsed = BEAT_TICKS + 1, fadeStarted = false },
    { phase = "swirl", elapsed = SWIRL_TICKS + 1, fadeStarted = true },
    { phase = "swirl", elapsed = 1.5, fadeStarted = true },
    { phase = "beat", elapsed = 0, fadeStarted = 0 },
    { phase = "beat", elapsed = 0, fadeStarted = false, swirl = true },
    { phase = "beat", elapsed = 0, fadeStarted = false, cancelled = 7 },
  }
  for _, state in ipairs(rejected) do
    local err = CelebiTimeTravelTask.validate(state)
    Assert.notNil(err, "a malformed shape must not validate")
    Assert.isTrue(Errors.is(err), "a malformed shape raises a structured fault")
    Assert.equal(err.code, "SCRIPT_TASK_UNSERIALIZABLE", "the fault names the unserializable state")
  end
end

return { tests = T }
