-- Cancellation reaches a defined boundary from every phase: during
-- resource preparation, amid active child work, inside a voice wait, and
-- across restoration it releases only its own pictures, leases, and
-- voices, and the next valid occurrence still runs normally afterward.
-- The source-clock half holds today through the real scene boundary: only
-- accepted ticks advance entry work and reads stay side-effect-free. The
-- cancellation run drives the battle-private program player once it
-- exists.
-- Native cadence: one accepted source tick is nominally 1/30 second;
-- entry waits count down on ticks, never on reads.
-- Headless: the real scene owns entry phases; the recorder doubles never
-- advance anything on reads.

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

local function sceneWithSolo()
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
  })
  return scene
end

local function playbackPacket()
  local packet = BattlePresentationModel.packet({}, { events = {} }, {}, {
    launchId = "cancel-probe",
    packetId = 1,
  })
  Assert.equal(packet.launchId, "cancel-probe", "the playback input carries its launch identity")
  return packet
end

local function playerModule()
  local ok, Player = pcall(require, "libs.hgss.src.presentation.BattleAnimationPlayer")
  Assert.isTrue(ok, "the battle-private animation player resolves through the presentation boundary")
  Assert.equal(type(Player.new), "function", "the player exposes its construction entry point")
  return Player
end

function T.entry_work_advances_on_ticks_only_and_reads_stay_free_of_side_effects()
  local scene = sceneWithSolo()
  local battler = { combatant = 1, activation = 1 }
  scene:startEntry(battler, { entryX = 0, settledX = 64 }, 8)
  local phase, remaining = scene:entryStatus(battler)
  Assert.equal(phase, "waiting", "the entry opens in its source wait")
  Assert.equal(remaining, BattleScene.ENTRY_WAIT_TICKS, "the wait carries the native tick count")
  for _ = 1, 10 do
    local first, _ = scene:entryOffsetFor(battler, { settledX = 64 })
    local second, _ = scene:entryOffsetFor(battler, { settledX = 64 })
    Assert.equal(first, second, "repeated reads agree without advancing anything")
  end
  local held, _ = scene:entryStatus(battler)
  Assert.equal(held, "waiting", "reads alone never leave the source wait")
  for _ = 1, BattleScene.ENTRY_WAIT_TICKS - 1 do
    scene:stepSourceTick()
  end
  local waiting, left = scene:entryStatus(battler)
  Assert.equal(waiting, "waiting", "the wait drains one tick at a time")
  Assert.equal(left, 1, "one source tick of waiting remains")
  scene:stepSourceTick()
  local moving, _ = scene:entryStatus(battler)
  Assert.equal(moving, "moving", "the drained wait releases into movement")
  for _ = 1, 8 do
    scene:stepSourceTick()
  end
  local gated, _ = scene:entryStatus(battler)
  Assert.equal(gated, "awaiting-completion", "movement settles at its completion gate")
  Assert.isTrue(
    scene:completeEntry(battler, {
      battlerReady = true,
      pictureAnimationActive = false,
      followupTaskRequired = false,
      followupTaskComplete = false,
    }),
    "the fully observed entry completes"
  )
  local done, _ = scene:entryStatus(battler)
  Assert.equal(done, "complete", "completion is recorded")
end

function T.cancel_from_every_phase_releases_only_its_own_holdings()
  local program = lowered("cancel-form", {
    34,
    1,
    2,
    3,
    29,
    50,
    4,
  })
  Assert.equal(program.instructions[1].op, "schedule-battle-task", "child work is scheduled")
  Assert.equal(program.instructions[2].op, "wait-for-sound", "a voice wait follows")

  local Player = playerModule()
  local scene = sceneWithSolo()
  local journals = {}
  local function journalFor(key)
    local journal = { acquired = {}, released = {}, played = {}, stopped = {} }
    journals[key] = journal
    return journal
  end
  local function collaborators(key, stuckVoice)
    local journal = journalFor(key)
    local audio = {}
    function audio.play(name)
      journal.played[#journal.played + 1] = name
    end
    function audio.stop(name)
      journal.stopped[#journal.stopped + 1] = name
    end
    function audio.isFinished(_name)
      return stuckVoice ~= true
    end
    local tasks = {}
    function tasks.create(_kind, _args, _context, _services)
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
    function resources.resolve(name)
      journal.acquired[#journal.acquired + 1] = name
      return { key = name, lease = key .. ":" .. key }
    end
    function resources.release(lease)
      journal.released[#journal.released + 1] = lease
    end
    return { audio = audio, resources = resources, tasks = tasks, journal = journal }
  end
  local first = collaborators("first")
  local player = assert(Player.new({
    scene = scene,
    audio = first.audio,
    resources = first.resources,
    tasks = first.tasks,
  }))
  local preparing = assert(player:start(playbackPacket(), program))
  player:cancel(preparing, "preparation")
  Assert.equal(player:status(preparing), "cancelled", "cancel during preparation lands on cancelled")
  local active = assert(player:start(playbackPacket(), program))
  player:stepSourceTick({ tick = 1 })
  player:cancel(active, "active")
  Assert.equal(player:status(active), "cancelled", "cancel amid child work lands on cancelled")
  local second = collaborators("second", true)
  local voicePlayer = assert(Player.new({
    scene = scene,
    audio = second.audio,
    resources = second.resources,
    tasks = second.tasks,
  }))
  local voiced = assert(voicePlayer:start(playbackPacket(), program))
  for _ = 1, 5 do
    voicePlayer:stepSourceTick({ tick = 1 })
    if voicePlayer:status(voiced) == "waiting" then
      break
    end
  end
  voicePlayer:cancel(voiced, "voice-wait")
  Assert.equal(voicePlayer:status(voiced), "cancelled", "cancel inside a voice wait lands on cancelled")
  for _, journal in pairs(journals) do
    Assert.equal(#journal.released, #journal.acquired, "each occurrence releases exactly its own leases")
    Assert.equal(#journal.stopped, #journal.played, "each occurrence stops exactly its own voices")
  end
  local fresh = collaborators("fresh")
  local runner = assert(Player.new({
    scene = scene,
    audio = fresh.audio,
    resources = fresh.resources,
    tasks = fresh.tasks,
  }))
  local nextHandle = assert(runner:start(playbackPacket(), program))
  for _ = 1, 20 do
    runner:stepSourceTick({ tick = 1 })
    if runner:status(nextHandle) == "complete" then
      break
    end
  end
  Assert.equal(runner:status(nextHandle), "complete", "the next valid occurrence still runs normally")
end

return { tests = T }
