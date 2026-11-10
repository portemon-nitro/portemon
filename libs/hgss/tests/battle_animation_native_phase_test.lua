-- Native frame phase composition: the player invokes the injected draw
-- and publish hooks on every accepted source tick, in order, even when
-- no visual machine is live. ScreenState supplies these hooks at
-- construction; draws and status reads never advance them on their own.

local Assert = require("tests.support.Assert")
local BattleAnimationPlayer = require("libs.hgss.src.presentation.BattleAnimationPlayer")

local T = {}

local function collaborators(observer)
  local calls = {}
  local audio = { done = {} }
  function audio.play(name)
    return name
  end
  function audio.stop(_name)
  end
  function audio.isFinished(name)
    return audio.done[name] == true
  end
  local tasks = {}
  function tasks.create(_kind, _args, _context, _services)
    local task = { _state = "complete" }
    function task.stepSourceTick(_tick)
    end
    function task.status()
      return task._state
    end
    function task.cancel(_reason)
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
  local services = nil
  if observer ~= nil then
    services = {
      onNativeFrame = function(phase, tick)
        calls[#calls + 1] = { phase = phase, tick = tick }
        observer[#observer + 1] = { phase = phase, tick = tick }
      end,
    }
  end
  return {
    scene = {},
    audio = audio,
    resources = resources,
    tasks = tasks,
    services = services,
    calls = calls,
  }
end

local function packet()
  return { launchId = "native-phase-probe", packetId = 1, events = {}, before = {}, after = {} }
end

local function programOf(instructions)
  return { entry = "main", instructions = instructions, subprograms = {}, taskKinds = {} }
end

function T.frame_hooks_are_mandatory_at_construction()
  local ok, _ = pcall(BattleAnimationPlayer.new, {
    scene = {},
    audio = collaborators(nil).audio,
    resources = collaborators(nil).resources,
    tasks = collaborators(nil).tasks,
  })
  Assert.isTrue(not ok, "players without a frame hook fail instead of running a silent clock")
end

function T.every_accepted_tick_invokes_draw_then_publish_in_order()
  local observed = {}
  local helpers = collaborators(observed)
  local player = assert(BattleAnimationPlayer.new({
    scene = helpers.scene,
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
    services = helpers.services,
  }))
  local handle = assert(player:start(packet(), programOf({
    { op = "play-sound", sound = "phase-cue" },
  })))
  player:stepSourceTick({ tick = 1 })
  helpers.audio.done["phase-cue"] = true
  player:stepSourceTick({ tick = 2 })
  Assert.equal(player:status(handle), "complete", "the probe occurrence drains")
  Assert.isTrue(player:retire(handle), "the drained occurrence retires")
  player:stepSourceTick({ tick = 3 })
  player:stepSourceTick({ tick = 4 })
  local phases = {}
  for _, call in ipairs(observed) do
    phases[#phases + 1] = call.phase
  end
  Assert.deepEqual(
    phases,
    { "draw", "publish", "draw", "publish", "draw", "publish", "draw", "publish" },
    "draw runs before publish on every tick, including ticks with no live machine"
  )
end

return { tests = T }
