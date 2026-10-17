-- Each native wait form resumes only on the condition its own instruction
-- names: task-group waits, the voice-completion wait, the interpreter
-- counter wait, and the plain tick wait stay distinct, and a child that no
-- instruction awaits remains owned after the main stream ends. Setup below
-- proves the lowered wait inventory through the real producer path; the
-- execution gate drives the battle-private program player once it exists.
-- Native mechanism: asm/overlay_07.s ov07_0221BE20 delay counter,
-- ov07_0221BE68 and ov07_0221BEA4 child-task count categories
-- (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36).
-- Headless: synthetic command streams use the real producer lowering and
-- the shared program shape; the voice/task doubles record only.

local Assert = require("tests.support.Assert")
local BattleAnimationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
local BattleAnimationSchema = require("libs.assets.src.battle.BattleAnimationSchema")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local function u32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

local function streamOf(list)
  local parts = {}
  for _, word in ipairs(list) do
    parts[#parts + 1] = u32(word)
  end
  return table.concat(parts)
end

local function lowered(key, list)
  local program = assert(BattleAnimationCompiler.compile({ key = key, stream = streamOf(list) }))
  Assert.isTrue(
    BattleAnimationSchema.assertProgram({
      entry = program.entry,
      instructions = program.instructions,
      subprograms = program.subprograms,
      taskKinds = program.taskKinds,
    }),
    "the lowered program validates against the shared program shape"
  )
  return program
end

local function voiceSink()
  local sink = { played = {}, stopped = {}, done = {} }
  function sink.play(name)
    sink.played[#sink.played + 1] = name
  end
  function sink.stop(name)
    sink.stopped[#sink.stopped + 1] = name
  end
  function sink.isFinished(name)
    return sink.done[name] == true
  end
  function sink.finish(name)
    sink.done[name] = true
  end
  return sink
end

local function taskFactory(log)
  local factory = {}
  function factory.create(kind, _args, _context, _services)
    log.created[#log.created + 1] = kind
    local task = { _kind = kind, _state = "running", _disposed = false }
    function task.stepSourceTick(_tick)
      log.steps[#log.steps + 1] = kind
      if log.completeAfter ~= nil and log.completeAfter[kind] == #log.steps then
        task._state = "complete"
      end
    end
    function task.status()
      return task._state
    end
    function task.cancel(_reason)
      task._state = "cancelled"
      log.cancelled[#log.cancelled + 1] = kind
    end
    function task.dispose()
      task._disposed = true
      log.disposed[#log.disposed + 1] = kind
    end
    return task
  end
  return factory
end

local function sceneWithPair()
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  return scene
end

local function playbackPacket()
  local packet = BattlePresentationModel.packet({}, { events = {} }, {}, {
    launchId = "wait-kinds-probe",
    packetId = 1,
  })
  Assert.equal(packet.launchId, "wait-kinds-probe", "the playback input carries its launch identity")
  return packet
end

local function playerModule()
  local ok, Player = pcall(require, "libs.hgss.src.presentation.BattleAnimationPlayer")
  Assert.isTrue(ok, "the battle-private animation player resolves through the presentation boundary")
  Assert.equal(type(Player.new), "function", "the player exposes its construction entry point")
  return Player
end

function T.each_wait_form_lowers_to_its_own_operation_and_resumes_on_its_own_condition()
  local program = lowered("wait-kinds-form", {
    1,
    0,
    0,
    34,
    1,
    2,
    3,
    34,
    4,
    5,
    6,
    29,
    50,
    4,
  })
  local ops = {}
  for _, instruction in ipairs(program.instructions) do
    ops[#ops + 1] = instruction.op
  end
  Assert.deepEqual(ops, {
    "wait-interpreter-counter",
    "interpreter-wait",
    "schedule-battle-task",
    "schedule-battle-task",
    "wait-for-sound",
    "wait-for-battler-effects",
    "reset-battle-presentation",
  }, "counter, tick, task, voice, and effect waits lower as distinct operations")
  Assert.equal(program.instructions[1].branchTarget, 1, "the counter wait loops on itself while pending")

  local Player = playerModule()
  local scene = sceneWithPair()
  local audio = voiceSink()
  local log = { created = {}, steps = {}, cancelled = {}, disposed = {}, completeAfter = {} }
  local resources = {}
  function resources.resolve(key)
    return { key = key, lease = key }
  end
  function resources.release(_lease) end
  local player = assert(Player.new({
    scene = scene,
    audio = audio,
    resources = resources,
    tasks = taskFactory(log),
  }))
  local handle = assert(player:start(playbackPacket(), program))
  player:stepSourceTick({ tick = 1 })
  Assert.equal(player:status(handle), "waiting", "the voice wait holds while its voice is unfinished")
  audio.finish(audio.played[1])
  player:stepSourceTick({ tick = 2 })
  Assert.equal(player:status(handle), "waiting", "the effect wait holds while its tasks run")
  for _, kind in ipairs(log.created) do
    log.completeAfter[kind] = #log.steps + 1
  end
  for _ = 1, 10 do
    player:stepSourceTick({ tick = 3 })
    if player:status(handle) == "complete" then
      break
    end
  end
  Assert.equal(player:status(handle), "complete", "each wait releases on its own named condition")
end

function T.unawaited_children_stay_owned_after_the_main_stream_ends()
  local program = lowered("unawaited-child-form", {
    34,
    7,
    8,
    9,
    4,
  })
  Assert.equal(program.instructions[1].op, "schedule-battle-task", "the child is scheduled")
  Assert.equal(program.instructions[2].op, "reset-battle-presentation", "the main stream ends without a wait")

  local Player = playerModule()
  local scene = sceneWithPair()
  local audio = voiceSink()
  local log = { created = {}, steps = {}, cancelled = {}, disposed = {}, completeAfter = {} }
  local resources = {}
  function resources.resolve(key)
    return { key = key, lease = key }
  end
  function resources.release(_lease) end
  local player = assert(Player.new({
    scene = scene,
    audio = audio,
    resources = resources,
    tasks = taskFactory(log),
  }))
  local handle = assert(player:start(playbackPacket(), program))
  for _ = 1, 10 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) == "complete" then
      break
    end
  end
  Assert.equal(player:status(handle), "complete", "the main stream completes")
  Assert.equal(#log.disposed, 0, "the unawaited child is not retired with the main stream")
  player:dispose()
  Assert.equal(#log.disposed, 1, "release retires the still-owned child exactly once")
end

return { tests = T }
