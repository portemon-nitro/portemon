-- Owner tests for the battle-private animation player: admission,
-- control flow, waits, lifecycle, and failure containment at the
-- injectable-collaborator boundary. Recorder doubles stand in for the
-- task bodies the effect lane supplies; no test here claims native
-- callback coverage.

local Assert = require("tests.support.Assert")
local BattleAnimationPlayer = require("libs.hgss.src.presentation.BattleAnimationPlayer")

local T = {}

local function collaborators()
  local log = {
    created = {},
    steps = {},
    cancelled = {},
    disposed = {},
    played = {},
    stopped = {},
    acquired = {},
    released = {},
  }
  local audio = { done = {} }
  function audio.play(name)
    log.played[#log.played + 1] = name
  end
  function audio.stop(name)
    log.stopped[#log.stopped + 1] = name
  end
  function audio.isFinished(name)
    return audio.done[name] == true
  end
  local tasks = {}
  function tasks.create(kind, _args, _context, _services)
    log.created[#log.created + 1] = kind
    local task = { _state = "running" }
    function task.stepSourceTick(_tick)
      log.steps[#log.steps + 1] = kind
    end
    function task.status()
      return task._state
    end
    function task.finish()
      task._state = "complete"
    end
    function task.cancel(_reason)
      task._state = "cancelled"
      log.cancelled[#log.cancelled + 1] = kind
    end
    function task.dispose()
      log.disposed[#log.disposed + 1] = kind
    end
    return task
  end
  local resources = {}
  function resources.resolve(key)
    log.acquired[#log.acquired + 1] = key
    return { key = key, lease = key }
  end
  function resources.release(lease)
    log.released[#log.released + 1] = lease
  end
  return { audio = audio, tasks = tasks, resources = resources, log = log }
end

local function packet(launchId)
  return { launchId = launchId or "owner-probe", packetId = 1, events = {}, before = {}, after = {} }
end

local function startNew(program, parts)
  local helpers = parts or collaborators()
  local player = assert(BattleAnimationPlayer.new({
    scene = {},
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
  }))
  local handle = player:start(packet(), program)
  return player, handle, helpers
end

local function programOf(instructions)
  return { entry = "main", instructions = instructions, subprograms = {}, taskKinds = {} }
end

function T.admission_refuses_malformed_programs_without_raising()
  local helpers = collaborators()
  local player = assert(BattleAnimationPlayer.new({
    scene = {},
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
  }))
  Assert.isNil(player:start(packet(), nil), "no program never admits")
  Assert.isNil(player:start(nil, programOf({ { op = "reset-blend-alpha" } })), "no playback never admits")
  Assert.isNil(
    player:start({ launchId = "", packetId = 1 }, programOf({ { op = "reset-blend-alpha" } })),
    "empty launch identity never admits"
  )
  Assert.isNil(player:start(packet(), { entry = "main", instructions = {}, subprograms = {}, taskKinds = {} }), "empty streams never admit")
  Assert.isNil(player:start(packet(), programOf({ { op = "no-such-operation" } })), "unknown operations never admit")
  Assert.isNil(player:start(packet(), programOf({ { op = "schedule-battle-task" } })), "task spawns without a kind never admit")
  Assert.isNil(
    player:start(packet(), programOf({ { op = "branch-on-parameter", values = { 1, 2 }, branchTarget = 99 } })),
    "destinations past the stream end never admit"
  )
  Assert.isNil(
    player:start(packet(), programOf({ { op = "reserve-loop-slot", values = { 0 }, branchTarget = 1, resumeTarget = 1 } })),
    "empty loops never admit"
  )
end

function T.tick_waits_count_exact_source_ticks()
  local player, handle, helpers = startNew(programOf({
    { op = "interpreter-wait", values = { 2 } },
    { op = "play-sound", sound = "counted-cue" },
    { op = "reset-blend-alpha" },
  }))
  Assert.equal(player:status(handle), "preparing", "admitted occurrences open preparing")
  player:stepSourceTick({ tick = 1 })
  Assert.equal(#helpers.log.played, 0, "the countdown holds its first tick")
  player:stepSourceTick({ tick = 2 })
  Assert.equal(#helpers.log.played, 0, "the countdown holds its second tick")
  player:stepSourceTick({ tick = 3 })
  Assert.equal(#helpers.log.played, 1, "the drained countdown releases in its own tick")
  helpers.audio.done["counted-cue"] = true
  player:stepSourceTick({ tick = 4 })
  Assert.equal(player:status(handle), "complete", "the released stream completes")
end

function T.zero_waits_continue_in_the_same_quantum()
  local function trace(instructions)
    local player, handle = startNew(programOf(instructions))
    local statuses = {}
    for _ = 1, 3 do
      player:stepSourceTick({ tick = 1 })
      statuses[#statuses + 1] = player:status(handle)
    end
    return statuses
  end
  Assert.deepEqual(trace({
    { op = "interpreter-wait", values = { 0 } },
    { op = "reset-blend-alpha" },
  }), trace({
    { op = "reset-blend-alpha" },
  }), "zero waits add no host frame")
end

function T.branches_read_scratch_and_calls_return()
  local player, handle = startNew(programOf({
    { op = "set-parameter", values = { 0, 7 } },
    { op = "branch-on-parameter", values = { 0, 7 }, branchTarget = 4 },
    { op = "set-parameter", values = { 1, 100 } },
    { op = "call-subprogram", branchTarget = 6, returnTarget = 5, cursorRule = "call-first-free-subprogram-slot; all-slots-busy-redispatch-count-word" },
    { op = "reset-blend-alpha" },
    { op = "set-parameter", values = { 1, 9 } },
    { op = "return-subprogram" },
  }))
  for _ = 1, 5 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) == "complete" then
      break
    end
  end
  Assert.equal(player:status(handle), "complete", "taken branches and calls run to completion")
end

function T.untaken_branches_fall_through()
  local player, handle = startNew(programOf({
    { op = "branch-on-parameter", values = { 0, 7 }, branchTarget = 3 },
    { op = "reset-blend-alpha" },
    { op = "reset-blend-alpha" },
  }))
  player:stepSourceTick({ tick = 1 })
  player:stepSourceTick({ tick = 2 })
  Assert.equal(player:status(handle), "complete", "zeroed scratch falls through the comparison")
end

function T.loops_execute_bounded_bodies_inline()
  local seen = {}
  local helpers = collaborators()
  function helpers.tasks.create(kind, _args, _context, _services)
    local task = { _state = "complete" }
    function task.stepSourceTick(_tick)
      seen[#seen + 1] = kind
    end
    function task.status()
      return task._state
    end
    function task.cancel(_reason) end
    function task.dispose() end
    return task
  end
  local player = assert(BattleAnimationPlayer.new({
    scene = {},
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
  }))
  local handle = assert(player:start(packet(), programOf({
    { op = "reserve-loop-slot", values = { 3 }, branchTarget = 2, resumeTarget = 2 },
    { op = "schedule-battle-task", taskKind = "battle-background-blend-transition", taskInputRule = "loop-rule", values = { 1 } },
    { op = "advance-loop-slot" },
    { op = "reset-blend-alpha" },
  })))
  for _ = 1, 5 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) == "complete" then
      break
    end
  end
  Assert.equal(player:status(handle), "complete", "bounded loops run to completion")
  Assert.equal(#seen, 3, "loop tasks step once each at the task phase, never inline")
end

function T.self_directed_branches_fail_instead_of_hanging()
  local player, handle = startNew(programOf({
    { op = "branch-on-parameter", values = { 0, 0 }, branchTarget = 1 },
    { op = "reset-blend-alpha" },
  }))
  Assert.notNil(handle, "the cyclic program admits its handle")
  for _ = 1, 200 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) == "failed" then
      break
    end
  end
  Assert.equal(player:status(handle), "failed", "zero-time cycles fail with provenance")
  local fault = player:failure(handle)
  Assert.notNil(fault, "the cycle carries its failure detail")
  Assert.equal(fault.op, "branch-on-parameter", "the detail names the cycling operation")
  Assert.equal(fault.launchId, "owner-probe", "the detail carries the playback identity")
end

function T.call_depth_beyond_three_slots_fails()
  local player, handle = startNew(programOf({
    { op = "call-subprogram", branchTarget = 1, returnTarget = 2, cursorRule = "call-first-free-subprogram-slot; all-slots-busy-redispatch-count-word" },
    { op = "reset-blend-alpha" },
  }))
  for _ = 1, 5 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) == "failed" then
      break
    end
  end
  Assert.equal(player:status(handle), "failed", "call saturation fails instead of redispatching words")
end

function T.return_without_a_call_falls_through()
  local player, handle = startNew(programOf({
    { op = "return-subprogram" },
    { op = "reset-blend-alpha" },
  }))
  player:stepSourceTick({ tick = 1 })
  player:stepSourceTick({ tick = 2 })
  Assert.equal(player:status(handle), "complete", "empty returns fall through")
end

function T.source_assertions_terminate_the_stream()
  -- A tripped native source assertion ends the occurrence instead of
  -- failing it: retail Invalid55 never advances (silent assert without
  -- comm state, or reset with it), yet retail programs that reach one
  -- play on and their battles continue, so the occurrence drains through
  -- the stream-end boundary and completes. The trip stays journaled with
  -- instruction provenance instead of passing silently.
  local player, handle = startNew(programOf({
    { op = "source-assertion", target = 3 },
    { op = "reset-blend-alpha" },
  }))
  for _ = 1, 5 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) == "complete" then
      break
    end
  end
  Assert.equal(player:status(handle), "complete", "tripped source assertions terminate past the stream end")
  Assert.isNil(player:failure(handle), "terminated assertions carry no failure")
end

function T.battle_phase_waits_release_without_background_work()
  -- Native op19/20 poll the background-switch task state (bgSwitchState == 2
  -- / == 0, battle_anim_system.c WaitForBackgroundLoaded/Switch): with no
  -- unretired raw work the awaited switch phase already passed, so the
  -- occurrence advances through the same drain a battler-effects wait uses
  -- instead of failing on a condition the packet never carries.
  for _, values in ipairs({ { 2 }, { 0 } }) do
    local player, handle = startNew(programOf({
      { op = "wait-for-battle-phase", values = values },
      { op = "reset-blend-alpha" },
    }))
    for _ = 1, 5 do
      player:stepSourceTick({ tick = 1 })
      if player:status(handle) == "complete" then
        break
      end
    end
    Assert.equal(
      player:status(handle),
      "complete",
      "background waits advance with no background work pending: " .. tostring(values[1])
    )
    Assert.isNil(player:failure(handle), "released background waits carry no failure")
  end
end

function T.stuck_background_work_escapes_bounded_instead_of_hanging()
  local player, handle, helpers = startNew(programOf({
    { op = "schedule-battle-task", taskKind = "battle-background-blend-transition", taskInputRule = "raw-rule", values = { 1 } },
    { op = "wait-for-battle-phase", values = { 0 } },
    { op = "reset-blend-alpha" },
  }))
  for _ = 1, 40 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) == "complete" then
      break
    end
  end
  Assert.equal(player:status(handle), "complete", "the background escape bounds stuck switch waits")
  Assert.equal(#helpers.log.created, 1, "the stuck switch task still constructs once")
end

function T.missing_context_reads_fail_before_side_effects()
  local ops = {
    { op = "wait-for-confirm-input", values = { 1 } },
    { op = "branch-on-battle-flag", values = { 2 }, branchTarget = 2, alternateTarget = 1 },
    { op = "show-pokemon-picture", values = { 0, 0 } },
  }
  for _, op in ipairs(ops) do
    local player, handle = startNew(programOf({ op }))
    Assert.notNil(handle, "context reads admit their handle")
    player:stepSourceTick({ tick = 1 })
    Assert.equal(player:status(handle), "failed", tostring(op.op) .. " fails on missing playback detail")
    Assert.notNil(player:failure(handle), tostring(op.op) .. " carries its failure detail")
  end
end

function T.counter_waits_track_the_general_group_only()
  local player, handle, helpers = startNew(programOf({
    { op = "wait-interpreter-counter", branchTarget = 1, cursorRule = "pending-redispatch-current-opcode; zero-advances-past-current-opcode" },
    { op = "schedule-battle-task", taskKind = "battle-background-blend-transition", taskInputRule = "raw-rule", values = { 1 } },
    { op = "reset-blend-alpha" },
  }))
  for _ = 1, 5 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) == "complete" then
      break
    end
  end
  Assert.equal(player:status(handle), "complete", "uncounted raw tasks never hold the counter wait")
  Assert.equal(#helpers.log.created, 1, "the raw task still constructs")
end

function T.cancel_and_dispose_stay_silent_and_exact()
  local player, handle, helpers = startNew(programOf({
    { op = "schedule-battle-task", taskKind = "battle-background-blend-transition", taskInputRule = "owned-rule", values = { 1 } },
    { op = "reset-blend-alpha" },
  }))
  player:stepSourceTick({ tick = 1 })
  player:cancel(handle, "withdrawn")
  Assert.equal(player:status(handle), "cancelled", "cancellation lands on cancelled")
  player:cancel(handle, "repeated")
  player:dispose()
  player:dispose()
  Assert.equal(player:status(handle), "cancelled", "terminal phases never move again")
  Assert.equal(#helpers.log.cancelled, 1, "owned tasks cancel exactly once")
  Assert.equal(#helpers.log.disposed, 1, "owned tasks dispose exactly once")
  Assert.isNil(player:failure(handle), "cancelled occurrences carry no failure")
end

function T.occurrences_step_in_stable_admission_order()
  local order = {}
  local helpers = collaborators()
  function helpers.tasks.create(kind, _args, _context, _services)
    local task = { _state = "running" }
    function task.stepSourceTick(_tick)
      order[#order + 1] = kind
    end
    function task.status()
      return task._state
    end
    function task.cancel(_reason)
      task._state = "cancelled"
    end
    function task.dispose() end
    return task
  end
  local player = assert(BattleAnimationPlayer.new({
    scene = {},
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
  }))
  local first = assert(player:start(packet("first"), programOf({
    { op = "schedule-battle-task", taskKind = "battle-background-blend-transition", taskInputRule = "first-rule", values = { 1 } },
    { op = "interpreter-wait", values = { 5 } },
  })))
  local second = assert(player:start(packet("second"), programOf({
    { op = "schedule-battle-task", taskKind = "battle-palette-fade", taskInputRule = "second-rule", values = { 1 } },
    { op = "interpreter-wait", values = { 5 } },
  })))
  player:stepSourceTick({ tick = 1 })
  player:stepSourceTick({ tick = 2 })
  Assert.deepEqual(order, { "battle-background-blend-transition", "battle-palette-fade" }, "admission order decides stepping")
  Assert.equal(player:status(first), "waiting", "the first occurrence keeps its own phase")
  Assert.equal(player:status(second), "waiting", "the second occurrence keeps its own phase")
  player:cancel(first, "stale")
  player:stepSourceTick({ tick = 3 })
  Assert.deepEqual(order, { "battle-background-blend-transition", "battle-palette-fade", "battle-palette-fade" }, "cancelled occurrences never step again")
end

function T.reads_never_advance_the_clock()
  local player, handle = startNew(programOf({
    { op = "interpreter-wait", values = { 1 } },
    { op = "reset-blend-alpha" },
  }))
  player:stepSourceTick({ tick = 1 })
  local first = player:status(handle)
  for _ = 1, 10 do
    Assert.equal(player:status(handle), first, "status reads stay side-effect free")
  end
  Assert.isNil(player:status({ id = 99999 }), "unknown handles report nothing")
  Assert.isNil(player:failure(handle), "waiting occurrences carry no failure")
end

function T.construction_failures_release_every_acquisition_once()
  local attempts = 0
  local helpers = collaborators()
  function helpers.tasks.create(_kind, _args, _context, _services)
    attempts = attempts + 1
    if attempts == 2 then
      error("synthetic child construction failure")
    end
    local task = { _state = "running" }
    function task.stepSourceTick(_tick) end
    function task.status()
      return task._state
    end
    function task.cancel(_reason)
      task._state = "cancelled"
    end
    function task.dispose() end
    return task
  end
  local player = assert(BattleAnimationPlayer.new({
    scene = {},
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
  }))
  local handle = assert(player:start(packet(), programOf({
    { op = "set-parameter", values = { 0, 7 } },
    { op = "wait-for-sound", values = { 90 } },
    { op = "schedule-battle-task", taskKind = "battle-background-blend-transition", taskInputRule = "failing-rule", values = { 1 } },
    { op = "reset-blend-alpha" },
  })))
  for _ = 1, 5 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) == "failed" then
      break
    end
  end
  Assert.equal(player:status(handle), "failed", "the second construction fails the occurrence")
  local fault = player:failure(handle)
  Assert.notNil(fault, "failure carries occurrence and instruction detail")
  Assert.equal(fault.op, "schedule-battle-task", "the detail names the failing instruction")
  Assert.equal(#helpers.log.played, 1, "the staged voice starts once")
  Assert.equal(#helpers.log.stopped, 1, "the staged voice stops once")
  Assert.equal(#helpers.log.acquired, 0, "the staged voice stages no holder lease")
  Assert.equal(#helpers.log.released, 0, "unstaged voices release nothing")
end

function T.task_step_failures_fail_the_occurrence()
  local helpers = collaborators()
  function helpers.tasks.create(_kind, _args, _context, _services)
    local task = { _state = "running" }
    function task.stepSourceTick(_tick)
      error("synthetic task execution failure")
    end
    function task.status()
      return task._state
    end
    function task.cancel(_reason)
      task._state = "cancelled"
    end
    function task.dispose() end
    return task
  end
  local player = assert(BattleAnimationPlayer.new({
    scene = {},
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
  }))
  local handle = assert(player:start(packet(), programOf({
    { op = "schedule-battle-task", taskKind = "battle-background-blend-transition", taskInputRule = "doomed-rule", values = { 1 } },
    { op = "interpreter-wait", values = { 5 } },
  })))
  player:stepSourceTick({ tick = 1 })
  player:stepSourceTick({ tick = 2 })
  Assert.equal(player:status(handle), "failed", "task execution failures fail loudly")
end

function T.unknown_task_states_fail_closed()
  local helpers = collaborators()
  function helpers.tasks.create(_kind, _args, _context, _services)
    local task = {}
    function task.stepSourceTick(_tick) end
    function task.status()
      return "melted"
    end
    function task.cancel(_reason) end
    function task.dispose() end
    return task
  end
  local player = assert(BattleAnimationPlayer.new({
    scene = {},
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
  }))
  local handle = assert(player:start(packet(), programOf({
    { op = "schedule-battle-task", taskKind = "battle-background-blend-transition", taskInputRule = "weird-rule", values = { 1 } },
    { op = "interpreter-wait", values = { 5 } },
  })))
  player:stepSourceTick({ tick = 1 })
  player:stepSourceTick({ tick = 2 })
  Assert.equal(player:status(handle), "failed", "unknown task states fail closed")
end

function T.malformed_factory_products_fail_admission_work()
  local helpers = collaborators()
  function helpers.tasks.create(_kind, _args, _context, _services)
    return {}
  end
  local player = assert(BattleAnimationPlayer.new({
    scene = {},
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
  }))
  local handle = assert(player:start(packet(), programOf({
    { op = "schedule-battle-task", taskKind = "battle-background-blend-transition", taskInputRule = "hollow-rule", values = { 1 } },
  })))
  player:stepSourceTick({ tick = 1 })
  Assert.equal(player:status(handle), "failed", "hollow tasks fail instead of running")
end

function T.resource_failures_fail_before_side_effects()
  local helpers = collaborators()
  function helpers.resources.resolve(_key)
    error("synthetic resource failure")
  end
  local player = assert(BattleAnimationPlayer.new({
    scene = {},
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
  }))
  local handle = assert(player:start(packet(), programOf({
    {
      op = "create-battler-effect",
      taskKind = "battle-particle-emitter-battler-path",
      resource = "battle/particle-emitter/probe-effect",
      emitterPosition = "solo-enemy",
    },
    { op = "reset-blend-alpha" },
  })))
  player:stepSourceTick({ tick = 1 })
  Assert.equal(player:status(handle), "failed", "resource staging failures fail loudly")
  Assert.equal(#helpers.log.played, 0, "failed staging starts no voice")
  Assert.equal(#helpers.log.created, 0, "failed staging constructs no child")
end

function T.stuck_voices_escape_bounded_instead_of_hanging()
  local helpers = collaborators()
  helpers.audio.done = {}
  function helpers.audio.isFinished(_name)
    return false
  end
  local player = assert(BattleAnimationPlayer.new({
    scene = {},
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
  }))
  local handle = assert(player:start(packet(), programOf({
    { op = "play-sound", sound = "stuck-cue" },
    { op = "wait-for-sound", values = { 90 } },
    { op = "reset-blend-alpha" },
  })))
  for _ = 1, 200 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) == "complete" then
      break
    end
  end
  Assert.equal(player:status(handle), "complete", "the voice escape bounds stuck waits")
  Assert.equal(#helpers.log.played, 1, "the wait reuses the already playing voice")
end

function T.particle_creation_parks_without_reacquiring_across_ticks()
  local player, handle, helpers = startNew(programOf({
    { op = "create-battler-effect", taskKind = "battle-particle-emitter-battler-path", resource = "battle/particle-emitter/probe-effect", emitterPosition = "solo-enemy" },
    { op = "play-sound", sound = "after-create-cue" },
    { op = "reset-blend-alpha" },
  }))
  player:stepSourceTick({ tick = 1 })
  Assert.equal(player:status(handle), "waiting", "the fresh creation parks on its staging wait")
  Assert.equal(#helpers.log.acquired, 1, "the first visit stages exactly one dependency")
  Assert.equal(#helpers.log.created, 1, "the first visit constructs exactly one child")
  for _ = 1, 3 do
    Assert.equal(player:status(handle), "waiting", "status reads hold the parked phase")
    Assert.isNil(player:failure(handle), "parked occurrences carry no failure")
  end
  Assert.equal(#helpers.log.acquired, 1, "status reads stage nothing more")
  Assert.equal(#helpers.log.created, 1, "status reads construct nothing more")
  player:stepSourceTick({ tick = 2 })
  player:stepSourceTick({ tick = 3 })
  player:stepSourceTick({ tick = 4 })
  Assert.equal(#helpers.log.acquired, 1, "parked ticks never restage the dependency")
  Assert.equal(#helpers.log.created, 1, "parked ticks never reconstruct the child")
  Assert.equal(#helpers.log.played, 1, "the stream advances past the drained wait in source order")
  Assert.equal(player:status(handle), "waiting", "the still-running child holds the stream end")
end

function T.particle_creation_repeats_once_per_loop_visit()
  local helpers = collaborators()
  function helpers.tasks.create(kind, _args, _context, _services)
    helpers.log.created[#helpers.log.created + 1] = kind
    local task = { _state = "running" }
    function task.stepSourceTick(_tick)
      task._state = "complete"
    end
    function task.status()
      return task._state
    end
    function task.cancel(_reason)
      task._state = "cancelled"
      helpers.log.cancelled[#helpers.log.cancelled + 1] = kind
    end
    function task.dispose()
      helpers.log.disposed[#helpers.log.disposed + 1] = kind
    end
    return task
  end
  local player = assert(BattleAnimationPlayer.new({
    scene = {},
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
  }))
  local handle = assert(player:start(packet(), programOf({
    { op = "reserve-loop-slot", values = { 2 }, branchTarget = 2, resumeTarget = 2 },
    { op = "create-battler-effect", taskKind = "battle-particle-emitter-battler-path", resource = "battle/particle-emitter/loop-effect", emitterPosition = "solo-enemy" },
    { op = "advance-loop-slot" },
    { op = "reset-blend-alpha" },
  })))
  for _ = 1, 10 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) == "complete" then
      break
    end
  end
  Assert.equal(player:status(handle), "complete", "both loop visits drain to completion")
  Assert.equal(#helpers.log.acquired, 2, "each real loop visit stages exactly once")
  Assert.equal(#helpers.log.created, 2, "each real loop visit constructs exactly once")
  Assert.equal(#helpers.log.released, 2, "each staged lease releases exactly once")
end

function T.parked_creation_cancels_and_fails_without_leaking()
  local player, handle, helpers = startNew(programOf({
    { op = "create-battler-effect", taskKind = "battle-particle-emitter-battler-path", resource = "battle/particle-emitter/cancel-effect", emitterPosition = "solo-enemy" },
    { op = "reset-blend-alpha" },
  }))
  player:stepSourceTick({ tick = 1 })
  Assert.equal(player:status(handle), "waiting", "the creation parks before cancellation")
  local second = assert(player:start(packet("second-occurrence"), programOf({
    { op = "reset-blend-alpha" },
  })))
  player:cancel(handle, "withdrawn")
  Assert.equal(player:status(handle), "cancelled", "cancellation lands on cancelled")
  player:cancel(handle, "repeated")
  player:stepSourceTick({ tick = 2 })
  player:stepSourceTick({ tick = 3 })
  Assert.equal(player:status(handle), "cancelled", "terminal phases never move again")
  Assert.equal(#helpers.log.acquired, 1, "the cancelled visit staged exactly once")
  Assert.equal(#helpers.log.created, 1, "the cancelled visit constructed exactly once")
  Assert.equal(#helpers.log.released, 1, "the cancelled lease releases exactly once")
  Assert.equal(#helpers.log.cancelled, 1, "the cancelled child cancels exactly once")
  Assert.equal(#helpers.log.disposed, 1, "the cancelled child disposes exactly once")
  Assert.equal(player:status(second), "complete", "the independent occurrence still runs normally")

  local throwing = collaborators()
  function throwing.resources.resolve(_key)
    error("synthetic staging failure")
  end
  local failPlayer = assert(BattleAnimationPlayer.new({
    scene = {},
    audio = throwing.audio,
    resources = throwing.resources,
    tasks = throwing.tasks,
  }))
  local failed = assert(failPlayer:start(packet(), programOf({
    { op = "create-battler-effect", taskKind = "battle-particle-emitter-battler-path", resource = "battle/particle-emitter/failing-effect", emitterPosition = "solo-enemy" },
    { op = "reset-blend-alpha" },
  })))
  failPlayer:stepSourceTick({ tick = 1 })
  Assert.equal(failPlayer:status(failed), "failed", "a throwing stage fails the occurrence")
  Assert.equal(#throwing.log.created, 0, "failed staging constructs no child")
  local fault = failPlayer:failure(failed)
  Assert.notNil(fault, "the failure carries its provenance")
  Assert.equal(fault.op, "create-battler-effect", "the detail names the failing instruction")

  local exploding = collaborators()
  function exploding.tasks.create(_kind, _args, _context, _services)
    error("synthetic child construction failure")
  end
  local burstPlayer = assert(BattleAnimationPlayer.new({
    scene = {},
    audio = exploding.audio,
    resources = exploding.resources,
    tasks = exploding.tasks,
  }))
  local burst = assert(burstPlayer:start(packet(), programOf({
    { op = "create-battler-effect", taskKind = "battle-particle-emitter-battler-path", resource = "battle/particle-emitter/burst-effect", emitterPosition = "solo-enemy" },
    { op = "reset-blend-alpha" },
  })))
  burstPlayer:stepSourceTick({ tick = 1 })
  Assert.equal(burstPlayer:status(burst), "failed", "a throwing construction fails the occurrence")
  Assert.equal(#exploding.log.acquired, 1, "the failed visit staged once before constructing")
  Assert.equal(#exploding.log.released, 1, "the earlier lease releases exactly once")

  local hollow = collaborators()
  function hollow.resources.resolve(_key)
    return nil
  end
  local hollowPlayer = assert(BattleAnimationPlayer.new({
    scene = {},
    audio = hollow.audio,
    resources = hollow.resources,
    tasks = hollow.tasks,
  }))
  local hollowHandle = assert(hollowPlayer:start(packet(), programOf({
    { op = "create-battler-effect", taskKind = "battle-particle-emitter-battler-path", resource = "battle/particle-emitter/hollow-effect", emitterPosition = "solo-enemy" },
    { op = "reset-blend-alpha" },
  })))
  hollowPlayer:stepSourceTick({ tick = 1 })
  Assert.equal(hollowPlayer:status(hollowHandle), "failed", "an empty stage fails instead of registering")
  Assert.equal(#hollow.log.created, 0, "an empty stage constructs no child")
  Assert.equal(#hollow.log.released, 0, "nothing acquired means nothing released")
end

local function sideBattler(slot, sideType, combatant, activation)
  return { combatant = combatant or 1, activation = activation or 1, slot = slot, sideType = sideType }
end

local function sidePacket(attacker, targets)
  return {
    launchId = "side-branch-probe",
    packetId = 7,
    event = { sequence = 1, effectKey = "side-branch-probe" },
    visualSeed = 11,
    topology = { attacker = attacker, targets = targets },
  }
end

local function startWithSides(program, attacker, targets)
  local helpers = collaborators()
  local player = assert(BattleAnimationPlayer.new({
    scene = {},
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
  }))
  local handle = assert(player:start(sidePacket(attacker, targets), program))
  return player, handle, helpers
end

function T.side_equality_takes_the_equal_target_on_matching_sides()
  local player, handle, helpers = startWithSides(programOf({
    { op = "branch-on-side-equality", values = {}, branchTarget = 4, alternateTarget = 2 },
    { op = "play-sound", sound = "cross-side-cue" },
    { op = "skip-words", target = 5 },
    { op = "play-sound", sound = "equal-side-cue" },
  }), sideBattler("solo-player", 0), { sideBattler("player-side-slot-2", 4, 5, 8) })
  player:stepSourceTick({ tick = 1 })
  Assert.equal(player:status(handle), "waiting", "matching sides take the equal branch without failing")
  Assert.deepEqual(helpers.log.played, { "equal-side-cue" }, "the equal-side path sounds")
end

function T.side_equality_falls_through_on_opposite_sides()
  local player, handle, helpers = startWithSides(programOf({
    { op = "branch-on-side-equality", values = {}, branchTarget = 4, alternateTarget = 2 },
    { op = "play-sound", sound = "cross-side-cue" },
    { op = "skip-words", target = 5 },
    { op = "play-sound", sound = "equal-side-cue" },
  }), sideBattler("solo-player", 0), { sideBattler("solo-enemy", 1, 2, 9) })
  player:stepSourceTick({ tick = 1 })
  Assert.equal(player:status(handle), "waiting", "opposite sides take the alternate branch without failing")
  Assert.deepEqual(helpers.log.played, { "cross-side-cue" }, "the cross-side path sounds")
end

function T.side_predicate_selector_zero_reads_the_attacker_side()
  local player, handle, helpers = startWithSides(programOf({
    { op = "branch-on-side-predicate", values = { 0 }, branchTarget = 4, alternateTarget = 2 },
    { op = "play-sound", sound = "user-player-cue" },
    { op = "skip-words", target = 5 },
    { op = "play-sound", sound = "user-foe-cue" },
  }), sideBattler("solo-enemy", 1, 2, 9), { sideBattler("solo-player", 0) })
  player:stepSourceTick({ tick = 1 })
  Assert.equal(player:status(handle), "waiting", "selector zero follows the attacker without failing")
  Assert.deepEqual(helpers.log.played, { "user-foe-cue" }, "a foe-side user takes the special branch")
end

function T.side_predicate_other_selectors_read_the_single_target_side()
  local player, handle, helpers = startWithSides(programOf({
    { op = "branch-on-side-predicate", values = { 1 }, branchTarget = 4, alternateTarget = 2 },
    { op = "play-sound", sound = "target-player-cue" },
    { op = "skip-words", target = 5 },
    { op = "play-sound", sound = "target-foe-cue" },
  }), sideBattler("solo-player", 0), { sideBattler("solo-enemy", 1, 2, 9) })
  player:stepSourceTick({ tick = 1 })
  Assert.equal(player:status(handle), "waiting", "a nonzero selector follows the target without failing")
  Assert.deepEqual(helpers.log.played, { "target-foe-cue" }, "a foe-side target takes the special branch")
end

function T.side_branches_fail_closed_on_ambiguous_or_missing_topology()
  local spread = {
    sideBattler("enemy-side-slot-1", 3, 2, 9),
    sideBattler("enemy-side-slot-2", 5, 4, 10),
  }
  local equalitySpread, equalitySpreadHandle = startWithSides(programOf({
    { op = "branch-on-side-equality", values = {}, branchTarget = 3, alternateTarget = 2 },
    { op = "reset-blend-alpha" },
    { op = "reset-blend-alpha" },
  }), sideBattler("player-side-slot-1", 2), spread)
  equalitySpread:stepSourceTick({ tick = 1 })
  Assert.equal(equalitySpread:status(equalitySpreadHandle), "failed", "equality never guesses across a spread")
  Assert.equal(equalitySpread:failure(equalitySpreadHandle).op, "branch-on-side-equality", "the spread failure names its branch")

  local predicateSpread, predicateSpreadHandle = startWithSides(programOf({
    { op = "branch-on-side-predicate", values = { 1 }, branchTarget = 3, alternateTarget = 2 },
    { op = "reset-blend-alpha" },
    { op = "reset-blend-alpha" },
  }), sideBattler("player-side-slot-1", 2), spread)
  predicateSpread:stepSourceTick({ tick = 1 })
  Assert.equal(predicateSpread:status(predicateSpreadHandle), "failed", "target predicates never take the first foe")

  local bare, bareHandle = startNew(programOf({
    { op = "branch-on-side-equality", values = {}, branchTarget = 2, alternateTarget = 2 },
    { op = "reset-blend-alpha" },
  }))
  bare:stepSourceTick({ tick = 1 })
  Assert.equal(bare:status(bareHandle), "failed", "equality without topology stays loud")

  local barePredicate, barePredicateHandle = startNew(programOf({
    { op = "branch-on-side-predicate", values = { 0 }, branchTarget = 2, alternateTarget = 2 },
    { op = "reset-blend-alpha" },
  }))
  barePredicate:stepSourceTick({ tick = 1 })
  Assert.equal(barePredicate:status(barePredicateHandle), "failed", "predicates without topology stay loud")
end

function T.side_predicate_selector_zero_ignores_spread_targets()
  local player, handle, helpers = startWithSides(programOf({
    { op = "branch-on-side-predicate", values = { 0 }, branchTarget = 4, alternateTarget = 2 },
    { op = "play-sound", sound = "user-player-cue" },
    { op = "skip-words", target = 5 },
    { op = "play-sound", sound = "user-foe-cue" },
  }), sideBattler("player-side-slot-1", 2), {
    sideBattler("enemy-side-slot-1", 3, 2, 9),
    sideBattler("enemy-side-slot-2", 5, 4, 10),
  })
  player:stepSourceTick({ tick = 1 })
  Assert.equal(player:status(handle), "waiting", "selector zero needs only the attacker")
  Assert.deepEqual(helpers.log.played, { "user-player-cue" }, "a player-side user takes the ordinary branch")
end

function T.side_classes_follow_side_type_parity_without_slot_names()
  local player, handle, helpers = startWithSides(programOf({
    { op = "branch-on-side-equality", values = {}, branchTarget = 4, alternateTarget = 2 },
    { op = "play-sound", sound = "cross-side-cue" },
    { op = "skip-words", target = 5 },
    { op = "play-sound", sound = "equal-side-cue" },
  }), { combatant = 1, activation = 1, sideType = 1 }, { { combatant = 2, activation = 2, sideType = 3 } })
  player:stepSourceTick({ tick = 1 })
  Assert.equal(player:status(handle), "waiting", "odd side types share the foe-side class without slot names")
  Assert.deepEqual(helpers.log.played, { "equal-side-cue" }, "the foe-side pair takes the equal branch")
end

-- The charge/strike dispatch behind opcode 13 (native ov07_0221D148 at
-- pret/pokeheartgold asm/overlay_07.s:2712-2737): the handler tests bit 0
-- of the battle-flag halfword and takes the first script word (the
-- compiler-lowered alternateTarget) when clear, the second word (the
-- branchTarget) when set. The charge-turn execution observes the bit
-- clear and the strike-turn execution observes it set, so the occurrence
-- move phase selects the charge half through the fallthrough and the
-- strike half through the branch.
local function playbackWithPhase(phase, withMove)
  local move = nil
  if withMove ~= false then
    move = { selected = "FLY", executed = "FLY", phase = phase }
  end
  return {
    launchId = "flag-probe",
    packetId = 1,
    event = { sequence = 1, effectKey = "FLY", move = move },
    visualSeed = 1,
  }
end

local function flagProgram()
  return programOf({
    { op = "branch-on-battle-flag", values = { 1 }, branchTarget = 4, alternateTarget = 2 },
    { op = "play-sound", sound = "charge-half" },
    { op = "skip-words", target = 5 },
    { op = "play-sound", sound = "strike-half" },
  })
end

local function startFlagged(program, playback)
  local helpers = collaborators()
  helpers.audio.done["charge-half"] = true
  helpers.audio.done["strike-half"] = true
  local player = assert(BattleAnimationPlayer.new({
    scene = {},
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
  }))
  local handle = assert(player:start(playback, program))
  for _ = 1, 3 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) == "complete" or player:status(handle) == "failed" then
      break
    end
  end
  return player, handle, helpers
end

function T.battle_flag_charge_phase_advances_to_the_charge_half()
  local player, handle, helpers = startFlagged(flagProgram(), playbackWithPhase("charge"))
  Assert.equal(player:status(handle), "complete", "the charge phase completes through the charge half")
  Assert.deepEqual(helpers.log.played, { "charge-half" }, "the charge phase plays only the charge half")
  Assert.equal(#helpers.log.created, 0, "the branch constructs no child")
end

function T.battle_flag_strike_phase_jumps_to_the_strike_half()
  local player, handle, helpers = startFlagged(flagProgram(), playbackWithPhase("direct"))
  Assert.equal(player:status(handle), "complete", "the strike phase completes through the strike half")
  Assert.deepEqual(helpers.log.played, { "strike-half" }, "the strike phase plays only the strike half")
  Assert.equal(#helpers.log.created, 0, "the branch constructs no child")
end

function T.battle_flag_other_operands_and_malformed_phases_fail_loud()
  local cases = {
    { values = { 2 }, playback = playbackWithPhase("charge"), name = "values {2}" },
    { values = { 1 }, playback = { launchId = "flag-probe", packetId = 1 }, name = "missing event" },
    {
      values = { 1 },
      playback = { launchId = "flag-probe", packetId = 1, event = { sequence = 1 } },
      name = "missing move",
    },
    { values = { 1 }, playback = playbackWithPhase("spinning", true), name = "unknown phase" },
    { values = { 1 }, playback = playbackWithPhase(7, true), name = "non-string phase" },
    { values = {}, playback = playbackWithPhase("charge"), name = "empty values" },
    { values = { 1, 2 }, playback = playbackWithPhase("charge"), name = "two values" },
  }
  for _, case in ipairs(cases) do
    local program = programOf({
      { op = "branch-on-battle-flag", values = case.values, branchTarget = 3, alternateTarget = 2 },
      { op = "play-sound", sound = "charge-half" },
      { op = "play-sound", sound = "strike-half" },
    })
    local player, handle, helpers = startFlagged(program, case.playback)
    Assert.equal(
      player:status(handle),
      "failed",
      case.name .. " fails instead of guessing a battle context"
    )
    local fault = player:failure(handle)
    Assert.notNil(fault, case.name .. " carries its failure provenance")
    Assert.equal(fault.op, "branch-on-battle-flag", case.name .. " names the failing instruction")
    Assert.equal(#helpers.log.created, 0, case.name .. " constructs no child")
    Assert.equal(#helpers.log.acquired, 0, case.name .. " stages no lease")
  end
end

-- The opcode-71 interpreter-state branch (native ov07_0221D214 at
-- pret/pokeheartgold asm/overlay_07.s, comparing the ov07_0221BFC0
-- contest-mode indicator against one) reads the indicator retail
-- zero-initializes at interpreter construction, so the ==1 arm never
-- matches and the occurrence falls through to the battle half.
-- Compiler-faithful shape: values {1}, branchTarget at the ==1 arm,
-- alternateTarget at the fall-through arm.
function T.interpreter_state_contest_indicator_falls_through_to_the_battle_half()
  local helpers = collaborators()
  helpers.audio.done["battle-half"] = true
  helpers.audio.done["contest-half"] = true
  local player = assert(BattleAnimationPlayer.new({
    scene = {},
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
  }))
  local handle = assert(player:start(playbackWithPhase("charge"), programOf({
    { op = "branch-on-interpreter-state", values = { 1 }, branchTarget = 4, alternateTarget = 2 },
    { op = "play-sound", sound = "battle-half" },
    { op = "skip-words", target = 5 },
    { op = "play-sound", sound = "contest-half" },
  })))
  for _ = 1, 3 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) == "complete" or player:status(handle) == "failed" then
      break
    end
  end
  Assert.equal(player:status(handle), "complete", "the zeroed contest indicator completes through the battle half")
  Assert.deepEqual(helpers.log.played, { "battle-half" }, "the fall-through plays only the battle half")
end

function T.carved_out_context_families_stay_loud_on_any_phase()
  -- Compiler-faithful shapes (see BattleAnimationCompiler lowering): the
  -- no-values interpreter-state form never admits through the strict
  -- program schema, while every remaining admitted context branch fails
  -- at its handler with provenance even when the move phase is
  -- well-formed. The admitted opcode-71 interpreter-state form is not
  -- carved out: its contest-mode indicator is retail zero-initialized,
  -- so it falls through (see the test above).
  local refused = programOf({
    { op = "branch-on-interpreter-state", branchTarget = 2 },
    { op = "reset-blend-alpha" },
  })
  local helpers = collaborators()
  local player = assert(BattleAnimationPlayer.new({
    scene = {},
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
  }))
  Assert.isNil(
    player:start(playbackWithPhase("charge"), refused),
    "the no-values interpreter-state form never admits"
  )
  local ops = {
    {
      op = "branch-on-battle-field",
      values = { 3 },
      branchTarget = 2,
      alternateTarget = nil,
    },
    {
      op = "branch-on-side-mask",
      branchCases = { { sideMask = 3, target = 2 }, { otherwise = true, target = 2 } },
    },
    {
      op = "branch-on-picture-state",
      values = { 0 },
      branchTarget = 2,
      alternateTarget = nil,
    },
  }
  for _, probe in ipairs(ops) do
    local instruction = { op = probe.op, branchTarget = probe.branchTarget, alternateTarget = probe.alternateTarget }
    if probe.values ~= nil then
      instruction.values = probe.values
    end
    if probe.branchCases ~= nil then
      instruction.branchCases = probe.branchCases
    end
    local player, handle, helpers = startFlagged(programOf({ instruction }), playbackWithPhase("charge"))
    Assert.equal(
      player:status(handle),
      "failed",
      probe.op .. " stays loud even with a well-formed move phase"
    )
    local fault = player:failure(handle)
    Assert.notNil(fault, probe.op .. " carries its failure provenance")
    Assert.equal(fault.op, probe.op, probe.op .. " names the failing instruction")
    Assert.equal(#helpers.log.created, 0, probe.op .. " constructs no child")
  end
end

return { tests = T }
