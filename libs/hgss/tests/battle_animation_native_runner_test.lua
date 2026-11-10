-- Source runner timing: waits resume on the native delay rules, and the
-- terminal command ends its arm instead of falling through. These probes
-- drive the real player one source tick at a time and record only
-- observable operation and status events. Op spellings below are the
-- current producer vocabulary; the scenario is the timing, not the names.

local Assert = require("tests.support.Assert")
local BattleAnimationPlayer = require("libs.hgss.src.presentation.BattleAnimationPlayer")

local T = {}

local function collaborators()
  local log = { played = {}, created = 0 }
  local audio = { done = {} }
  function audio.play(name)
    log.played[#log.played + 1] = name
  end
  function audio.stop(_name)
  end
  function audio.isFinished(name)
    return audio.done[name] == true
  end
  local tasks = {}
  function tasks.create(kind, _args, _context, _services)
    log.created = log.created + 1
    local task = { _state = "complete" }
    function task.stepSourceTick(_tick)
    end
    function task.status()
      return task._state
    end
    function task.cancel(_reason)
      task._state = "cancelled"
    end
    function task.dispose()
    end
    return task
  end
  local resources = {}
  function resources.resolve(key)
    return { key = key, lease = key }
  end
  function resources.release(_lease)
  end
  return { audio = audio, tasks = tasks, resources = resources, log = log }
end

local function packet()
  return { launchId = "native-timing-probe", packetId = 1, events = {}, before = {}, after = {} }
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

function T.positive_waits_resume_two_ticks_after_their_count()
  local player, handle, helpers = startNew(programOf({
    { op = "interpreter-wait", values = { 2 } },
    { op = "play-sound", sound = "timed-cue" },
  }))
  for tick = 1, 4 do
    player:stepSourceTick({ tick = tick })
    Assert.equal(#helpers.log.played, 0, "a two-frame wait stays silent through tick " .. tick)
  end
  player:stepSourceTick({ tick = 5 })
  Assert.equal(#helpers.log.played, 1, "the drained wait releases on its fifth tick")
  helpers.audio.done["timed-cue"] = true
  player:stepSourceTick({ tick = 6 })
  Assert.equal(player:status(handle), "complete", "the released chain drains once the stream ends")
end

function T.zero_waits_keep_the_immediate_chain_moving()
  local player, handle, helpers = startNew(programOf({
    { op = "interpreter-wait", values = { 0 } },
    { op = "play-sound", sound = "immediate-cue" },
  }))
  player:stepSourceTick({ tick = 1 })
  Assert.equal(#helpers.log.played, 1, "a zero wait continues the immediate chain in the same tick")
  helpers.audio.done["immediate-cue"] = true
  player:stepSourceTick({ tick = 2 })
  Assert.equal(player:status(handle), "complete", "the chain drains once the stream ends")
end

function T.terminal_commands_never_run_the_following_arm()
  local player, handle, helpers = startNew(programOf({
    { op = "reset-battle-presentation" },
    { op = "play-sound", sound = "forbidden-cue" },
  }))
  for tick = 1, 3 do
    player:stepSourceTick({ tick = tick })
    Assert.equal(#helpers.log.played, 0, "the terminal arm never sounds on tick " .. tick)
  end
  Assert.equal(player:status(handle), "complete", "the terminal command still drains to completion")
end

function T.empty_loops_wrap_their_counter_instead_of_hanging()
  local helpers = collaborators()
  local player = assert(BattleAnimationPlayer.new({
    scene = {},
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
    services = { onNativeFrame = function() end },
  }))
  local handle, reason = player:start(packet(), programOf({
    { op = "reserve-loop-slot", values = { 0 }, branchTarget = 2, resumeTarget = 2 },
    {
      op = "schedule-battle-task",
      taskKind = "battle-background-blend-transition",
      taskInputRule = "loop-rule",
      values = { 1 },
    },
    { op = "advance-loop-slot" },
    { op = "reset-blend-alpha" },
  }))
  Assert.notNil(handle, "a zero-count loop admits and wraps: " .. tostring(reason))
  for _ = 1, 300 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) == "complete" then
      break
    end
  end
  Assert.equal(player:status(handle), "complete", "a zero-count loop completes instead of hanging")
  Assert.equal(helpers.log.created, 256, "the unsigned counter wraps through its full cycle")
end

return { tests = T }
