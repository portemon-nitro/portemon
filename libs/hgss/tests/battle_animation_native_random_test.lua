-- One continuous battle visual random stream: draws follow the shared
-- linear-congruential recurrence and separate roots never restart it.
-- Probes read the occurrence random function the real player hands to
-- spawned tasks. The recurrence below mirrors the shared generator the
-- visual stream must reuse, not a per-occurrence invention.

local Assert = require("tests.support.Assert")
local BattleAnimationPlayer = require("libs.hgss.src.presentation.BattleAnimationPlayer")

local T = {}

local MULTIPLIER = 1103515245
local INCREMENT = 24691
local MODULUS = 4294967296

local function nextDraw(state)
  local advanced = (state * MULTIPLIER + INCREMENT) % MODULUS
  return advanced, math.floor(advanced / 65536)
end

local function collaborators()
  local contexts = {}
  local audio = {}
  function audio.play(_name)
  end
  function audio.stop(_name)
  end
  function audio.isFinished(_name)
    return true
  end
  local tasks = {}
  function tasks.create(_kind, _args, context, _services)
    contexts[#contexts + 1] = context
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
  return { audio = audio, tasks = tasks, resources = resources, contexts = contexts }
end

local function playback(launchId)
  return { launchId = launchId or "native-random-probe", packetId = 1, events = {}, before = {}, after = {} }
end

local function programOf(instructions)
  return { entry = "main", instructions = instructions, subprograms = {}, taskKinds = {} }
end

local function spawnWithSeed(seed)
  local helpers = collaborators()
  local player = assert(BattleAnimationPlayer.new({
    scene = {},
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
    services = { onNativeFrame = function() end },
  }))
  local handle = assert(player:start(playback(), programOf({
    { op = "submit-battle-action", taskKind = "battle-background-blend-transition", values = { 1 } },
  })))
  player:stepSourceTick({ tick = 1, seed = seed })
  local context = assert(helpers.contexts[1], "spawns carry their occurrence context")
  return context.random
end

function T.visual_draws_follow_the_shared_generator_recurrence()
  local random = assert(spawnWithSeed(100), "spawns expose their visual draw function")
  local _, first = nextDraw(100)
  Assert.equal(random(65536), first, "the first draw advances the shared recurrence once")
  local state, _ = nextDraw(100)
  local _, second = nextDraw(state)
  Assert.equal(random(65536), second, "the second draw advances the same stream again")
end

function T.separate_roots_never_restart_the_visual_stream()
  local first = assert(spawnWithSeed(4242), "the first root exposes its visual draw function")
  local second = assert(spawnWithSeed(4242), "the second root exposes its visual draw function")
  local firstSequence = { first(65536), first(65536), first(65536) }
  local secondSequence = { second(65536), second(65536), second(65536) }
  Assert.isTrue(
    firstSequence[1] ~= secondSequence[1]
      or firstSequence[2] ~= secondSequence[2]
      or firstSequence[3] ~= secondSequence[3],
    "two roots seeded alike still draw from one continuous stream"
  )
end

return { tests = T }
