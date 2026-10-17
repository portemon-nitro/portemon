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

function T.source_assertions_fail_loudly()
  local player, handle = startNew(programOf({
    { op = "source-assertion", target = 2 },
    { op = "reset-blend-alpha" },
  }))
  player:stepSourceTick({ tick = 1 })
  Assert.equal(player:status(handle), "failed", "tripped source assertions fail")
end

function T.missing_context_reads_fail_before_side_effects()
  local ops = {
    { op = "wait-for-confirm-input", values = { 1 } },
    { op = "wait-for-battle-phase", values = { 2 } },
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
  Assert.equal(#helpers.log.acquired, 1, "the staged voice stages one lease")
  Assert.equal(#helpers.log.released, 1, "the staged lease releases once")
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
    { op = "wait-for-sound", values = { 90 } },
    { op = "reset-blend-alpha" },
  })))
  player:stepSourceTick({ tick = 1 })
  Assert.equal(player:status(handle), "failed", "resource staging failures fail loudly")
  Assert.equal(#helpers.log.played, 0, "failed staging starts no voice")
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

return { tests = T }
