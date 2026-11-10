-- Source queue order and shared argument cells: the interpreter runs
-- before queued visual work inside one tick, counter waits observe task
-- retirement on the following tick, visual waits track visual tasks, and
-- spawned tasks can read live shared cells. Op spellings below are the
-- current producer vocabulary; the scenario is the order, not the names.

local Assert = require("tests.support.Assert")
local BattleAnimationPlayer = require("libs.hgss.src.presentation.BattleAnimationPlayer")

local T = {}

local function collaborators()
  local shared = { sequence = {}, spawned = {}, contexts = {} }
  local audio = { done = {} }
  function audio.play(name)
    shared.sequence[#shared.sequence + 1] = "sound"
  end
  function audio.stop(_name)
  end
  function audio.isFinished(name)
    return audio.done[name] == true
  end
  local tasks = {}
  function tasks.create(kind, args, context, _services)
    local record = { kind = kind, args = args, _state = "running" }
    shared.spawned[#shared.spawned + 1] = record
    shared.contexts[#shared.contexts + 1] = context
    function record.stepSourceTick(_tick)
      shared.sequence[#shared.sequence + 1] = "task"
    end
    function record.status()
      return record._state
    end
    function record.finish()
      record._state = "complete"
    end
    function record.cancel(_reason)
      record._state = "cancelled"
    end
    function record.dispose()
    end
    return record
  end
  local resources = {}
  function resources.resolve(key)
    return { key = key, lease = key }
  end
  function resources.release(_lease)
  end
  return { audio = audio, tasks = tasks, resources = resources, shared = shared }
end

local function packet()
  return { launchId = "native-scheduling-probe", packetId = 1, events = {}, before = {}, after = {} }
end

local function programOf(instructions)
  return { entry = "main", instructions = instructions, subprograms = {}, taskKinds = {} }
end

local function startNew(program)
  local helpers = collaborators()
  local player = assert(BattleAnimationPlayer.new({
    scene = {},
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
    services = { onNativeFrame = function() end },
  }))
  local handle = assert(player:start(packet(), program))
  return player, handle, helpers
end

local function soundsIn(sequence)
  local count = 0
  for _, entry in ipairs(sequence) do
    if entry == "sound" then
      count = count + 1
    end
  end
  return count
end

function T.counter_waits_observe_task_retirement_on_the_next_tick()
  local player, handle, helpers = startNew(programOf({
    { op = "submit-battle-action", taskKind = "battle-background-blend-transition", values = { 1 } },
    {
      op = "wait-interpreter-counter",
      branchTarget = 2,
      cursorRule = "pending-redispatch-current-opcode; zero-advances-past-current-opcode",
    },
    { op = "play-sound", sound = "counter-cue" },
  }))
  player:stepSourceTick({ tick = 1 })
  Assert.equal(soundsIn(helpers.shared.sequence), 0, "the counter wait parks while its task runs")
  helpers.shared.spawned[1].finish()
  player:stepSourceTick({ tick = 2 })
  Assert.equal(
    soundsIn(helpers.shared.sequence),
    0,
    "retirement later in the tick is observed on the following tick"
  )
  player:stepSourceTick({ tick = 3 })
  Assert.equal(soundsIn(helpers.shared.sequence), 1, "the drained counter wait releases its chain")
  helpers.audio.done["counter-cue"] = true
  player:stepSourceTick({ tick = 4 })
  Assert.equal(player:status(handle), "complete", "the released chain drains once the stream ends")
end

function T.visual_waits_track_visual_tasks_not_raw_tasks()
  local player, _, helpers = startNew(programOf({
    { op = "start-visual-task", taskKind = "battle-background-blend-transition", values = { 1 } },
    {
      op = "wait-interpreter-counter",
      branchTarget = 2,
      cursorRule = "pending-redispatch-current-opcode; zero-advances-past-current-opcode",
    },
    { op = "play-sound", sound = "visual-cue" },
  }))
  player:stepSourceTick({ tick = 1 })
  Assert.equal(
    soundsIn(helpers.shared.sequence),
    0,
    "a pending visual task holds the counter wait instead of releasing it"
  )
end

function T.spawned_tasks_read_live_shared_cells()
  local player, _, helpers = startNew(programOf({
    { op = "submit-battle-action", taskKind = "battle-background-blend-transition", values = { 1 } },
    { op = "set-parameter", values = { 0, 7 } },
  }))
  player:stepSourceTick({ tick = 1 })
  local context = assert(helpers.shared.contexts[1], "spawns carry their occurrence context")
  Assert.isTrue(
    type(context.liveParam) == "function",
    "spawned tasks read live shared cells instead of a frozen copy"
  )
  Assert.equal(context.liveParam(0), 7, "live reads observe writes from later commands")
end

return { tests = T }
