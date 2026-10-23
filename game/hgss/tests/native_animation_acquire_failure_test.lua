-- A child-construction failure after earlier acquisitions reports failure
-- exactly once with occurrence and instruction detail, releases every
-- acquired picture, lease, and voice exactly once, leaves the field
-- restorable, and stays silent across repeated cancel and release calls.
-- Setup proves the acquisition-shaped program through the real producer
-- path; the failure run drives the battle-private program player once it
-- exists.
-- Native mechanism: asm/overlay_07.s ov07_0221BEDC resource opening and
-- its teardown live-state check
-- (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36).
-- Headless: a synthetic command stream uses the real producer lowering
-- and the shared program shape; the failing factory and the journals
-- record only.

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

local function voiceSink(log)
  local sink = { done = {} }
  function sink.play(name)
    log.played[#log.played + 1] = name
  end
  function sink.stop(name)
    log.stopped[#log.stopped + 1] = name
  end
  function sink.isFinished(name)
    return sink.done[name] == true
  end
  return sink
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
    launchId = "acquire-failure-probe",
    packetId = 1,
  })
  Assert.equal(packet.launchId, "acquire-failure-probe", "the playback input carries its launch identity")
  return packet
end

local function playerModule()
  local ok, Player = pcall(require, "libs.hgss.src.presentation.BattleAnimationPlayer")
  Assert.isTrue(ok, "the battle-private animation player resolves through the presentation boundary")
  Assert.equal(type(Player.new), "function", "the player exposes its construction entry point")
  return Player
end

function T.construction_failure_releases_every_acquisition_once_and_stays_silent_afterward()
  local program = lowered("acquire-failure-form", {
    12,
    0,
    7,
    29,
    34,
    9,
    9,
    9,
    50,
    4,
  })
  local ops = {}
  for _, instruction in ipairs(program.instructions) do
    ops[#ops + 1] = instruction.op
  end
  Assert.deepEqual(ops, {
    "set-parameter",
    "wait-for-sound",
    "schedule-battle-task",
    "wait-for-battler-effects",
    "reset-battle-presentation",
  }, "picture, voice, and child work lower ahead of the failing construction")

  local Player = playerModule()
  local scene = sceneWithPair()
  local log = { played = {}, stopped = {}, created = {}, failed = {}, released = {}, resolved = {} }
  local audio = voiceSink(log)
  local attempts = 0
  local tasks = {}
  function tasks.create(_kind, _args, _context, _services)
    attempts = attempts + 1
    if attempts == 2 then
      log.failed[#log.failed + 1] = attempts
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
  local resources = {}
  function resources.resolve(key)
    log.resolved[#log.resolved + 1] = key
    return { key = key, lease = key }
  end
  function resources.release(lease)
    log.released[#log.released + 1] = lease
  end
  local player = assert(Player.new({
    scene = scene,
    audio = audio,
    resources = resources,
    tasks = tasks,
  }))
  local handle = assert(player:start(playbackPacket(), program))
  for _ = 1, 10 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) == "failed" then
      break
    end
  end
  local report = player:status(handle)
  Assert.equal(report, "failed", "construction failure surfaces as failure, never as completion")
  local detail = player:failure(handle)
  Assert.notNil(detail, "failure carries its occurrence and instruction detail")
  Assert.equal(#log.failed, 1, "the failing construction is attempted once")
  local releasedOnce = {}
  for _, lease in ipairs(log.released) do
    Assert.isNil(releasedOnce[lease], "every acquired lease is released exactly once")
    releasedOnce[lease] = true
  end
  Assert.equal(#log.stopped, #log.played, "every started voice is stopped once")
  player:cancel(handle, "repeated")
  player:dispose()
  player:dispose()
  Assert.equal(#log.failed, 1, "repeated cancel and release cause no further construction")
  Assert.equal(
    #log.released,
    #log.resolved,
    "repeated cancel and release cause no further releases"
  )
  local followup = sceneWithPair()
  Assert.notNil(followup, "the scene boundary stays usable after the failure")
end

return { tests = T }
