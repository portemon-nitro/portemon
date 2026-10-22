-- Native animation programs carrying control flow lower through the real
-- producer path: branch selection, subprogram call/return, a zero-length
-- wait, and two scheduled visual tasks keep their normalized operations,
-- operand order, and branch destinations. Execution below the gate drives
-- the battle-private program player once it exists; today the gate itself
-- is the intended miss.
-- Native mechanism: asm/overlay_07.s ov07_0221BE44 step loop,
-- ov07_0221F8B0 dispatch guard, ov07_02234DE8 dispatch table
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
    local task = { _kind = kind, _state = "running", _steps = 0, _disposed = false }
    function task.stepSourceTick(_tick)
      task._steps = task._steps + 1
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
    launchId = "branch-call-probe",
    packetId = 1,
  })
  Assert.equal(packet.launchId, "branch-call-probe", "the playback input carries its launch identity")
  Assert.equal(packet.packetId, 1, "the playback input carries its per-launch identity")
  return packet
end

local function playerModule()
  local ok, Player = pcall(require, "libs.hgss.src.presentation.BattleAnimationPlayer")
  Assert.isTrue(ok, "the battle-private animation player resolves through the presentation boundary")
  Assert.equal(type(Player.new), "function", "the player exposes its construction entry point")
  return Player
end

function T.branch_call_zero_wait_and_two_tasks_keep_their_normalized_form()
  local program = lowered("branch-call-form", {
    30,
    1,
    5,
    76,
    0,
    0,
    10,
    9,
    12,
    0,
    3,
    34,
    1,
    2,
    3,
    4,
    12,
    1,
    4,
    11,
    0,
    34,
    5,
    6,
    7,
    4,
  })
  local ops = {}
  for _, instruction in ipairs(program.instructions) do
    ops[#ops + 1] = instruction.op
  end
  Assert.deepEqual(ops, {
    "branch-on-parameter",
    "interpreter-wait",
    "call-subprogram",
    "set-parameter",
    "schedule-battle-task",
    "reset-battle-presentation",
    "set-parameter",
    "return-subprogram",
    "schedule-battle-task",
    "reset-battle-presentation",
  }, "branch, zero wait, call block, body, and return landing lower in order")
  Assert.deepEqual(program.instructions[2].values, { 0 }, "the zero-length wait keeps its operand")
  Assert.equal(program.instructions[1].branchTarget, 8, "the branch lands on the return instruction")
  Assert.equal(program.instructions[3].branchTarget, 7, "the call enters the subprogram body")
  Assert.equal(program.instructions[3].returnTarget, 4, "the call returns to the word after its count")
  Assert.equal(program.instructions[8].op, "return-subprogram", "the subprogram ends on its return")

  local Player = playerModule()
  local scene = sceneWithPair()
  local audio = voiceSink()
  local log = { created = {}, steps = {}, cancelled = {}, disposed = {} }
  local leases = { acquired = {}, released = {} }
  local resources = {}
  function resources.resolve(key)
    leases.acquired[#leases.acquired + 1] = key
    return { key = key, lease = #leases.acquired }
  end
  function resources.release(lease)
    leases.released[#leases.released + 1] = lease
  end
  local player = assert(Player.new({
    scene = scene,
    audio = audio,
    resources = resources,
    tasks = taskFactory(log),
  }))
  local handle = assert(player:start(playbackPacket(), program))
  local trace = {}
  local previous = nil
  for _ = 1, 60 do
    player:stepSourceTick({ tick = 1 })
    local state = player:status(handle)
    if state ~= previous then
      trace[#trace + 1] = state
      previous = state
    end
    if state == "complete" or state == "failed" then
      break
    end
  end
  Assert.equal(trace[#trace], "complete", "the branched program with its call block runs to completion")
  Assert.equal(#log.created, 2, "both scheduled tasks are created in order")
  Assert.equal(player:status(handle), "complete", "reaching the end state is stable")
end

return { tests = T }
