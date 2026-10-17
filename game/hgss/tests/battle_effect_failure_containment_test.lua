-- Native effect failure containment at the production task boundary:
-- truncated streams, out-of-table words, and jumps into operand bytes
-- fail lowering with their own program and byte detail, while a
-- mid-run texture or voice failure reports its occurrence and
-- instruction detail, releases its partial acquisitions exactly once,
-- leaves the host scene live, and never completes as an invisible
-- animation. Setup below holds today through the real producer and
-- scene paths; the runtime gate drives the battle-private program
-- player together with the battle-private effect task factory once both
-- exist.
-- Native mechanism: the overlay-7 resource-opening teardown live-state
-- check and the animation word framing rules
-- (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36).
-- Headless: synthetic command streams use the real producer lowering and
-- the shared program shape; the failing doubles record only.

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
    launchId = "failure-containment-probe",
    packetId = 1,
  })
  Assert.equal(packet.launchId, "failure-containment-probe", "the playback input carries its launch identity")
  return packet
end

local function playerModule()
  local ok, Player = pcall(require, "libs.hgss.src.presentation.BattleAnimationPlayer")
  Assert.isTrue(ok, "the battle-private animation player resolves through the presentation boundary")
  Assert.equal(type(Player.new), "function", "the player exposes its construction entry point")
  return Player
end

local function effectFactoryModule()
  local ok, Factory = pcall(require, "libs.hgss.src.presentation.BattleEffectTasks")
  Assert.isTrue(ok, "the battle-private effect task factory resolves through the presentation boundary")
  Assert.equal(type(Factory.create), "function", "the factory exposes its task construction entry point")
  return Factory
end

function T.truncated_and_out_of_table_streams_fail_with_native_detail()
  local truncated = Assert.throws(function()
    BattleAnimationCompiler.compile({ key = "truncated-probe", stream = "abc" })
  end, "a partial word never lowers")
  Assert.isTrue(
    string.find(tostring(truncated), "truncated-probe", 1, true) ~= nil,
    "the truncation names the program under lowering"
  )
  local outOfTable = Assert.throws(function()
    BattleAnimationCompiler.compile({ key = "past-the-table", stream = streamOf({ 88 }) })
  end, "a word past the table end never lowers")
  Assert.isTrue(
    string.find(tostring(outOfTable), "unknown dispatch opcode", 1, true) ~= nil,
    "the rejection names the out-of-table word"
  )
  local overrun = Assert.throws(function()
    BattleAnimationCompiler.compile({ key = "skip-past-the-end", stream = streamOf({ 15, 5 }) })
  end, "a word-count skip past the program end never lowers")
  Assert.isTrue(
    string.find(tostring(overrun), "skip-past-the-end", 1, true) ~= nil,
    "the overrun names the program under lowering"
  )
end

function T.jumps_into_operand_bytes_never_lower()
  local err = Assert.throws(function()
    BattleAnimationCompiler.compile({ key = "into-operands", stream = streamOf({ 30, 1, 5, 6, 9 }) })
  end, "a branch target inside operand bytes never lowers")
  Assert.isTrue(
    string.find(tostring(err), "into-operands", 1, true) ~= nil,
    "the operand-byte jump names the program under lowering"
  )
end

function T.mid_run_resource_and_voice_failures_fail_loudly_and_stay_live()
  local program = lowered("run-failing-effect", { 34, 1, 2, 3, 29, 50, 4 })
  Assert.equal(program.instructions[1].op, "schedule-battle-task", "the failing run schedules its work first")
  Assert.equal(program.instructions[2].op, "wait-for-sound", "a voice wait follows the scheduled work")
  local Player = playerModule()
  local Factory = effectFactoryModule()
  Assert.isTrue(Factory ~= nil, "the production factory joins the failing run")
  local scene = sceneWithSolo()
  local journal = { acquired = {}, released = {}, played = {}, stopped = {} }
  local audio = { stuck = true }
  function audio.play(name)
    journal.played[#journal.played + 1] = name
  end
  function audio.stop(name)
    journal.stopped[#journal.stopped + 1] = name
  end
  function audio.isFinished(_name)
    return not audio.stuck
  end
  local resources = { failAfter = 1 }
  function resources.resolve(key)
    journal.acquired[#journal.acquired + 1] = key
    if #journal.acquired > resources.failAfter then
      error({ code = "TEXTURE_MISSING", key = key }, 0)
    end
    return { key = key, lease = key .. ":" .. key }
  end
  function resources.release(lease)
    journal.released[#journal.released + 1] = lease
  end
  local player = assert(Player.new({
    scene = scene,
    audio = audio,
    resources = resources,
    tasks = Factory,
  }))
  local handle = assert(player:start(playbackPacket(), program))
  local failure = nil
  for _ = 1, 30 do
    local ok, err = pcall(player.stepSourceTick, player, { tick = 1 })
    if not ok then
      failure = err
      break
    end
    if player:status(handle) == "failed" then
      failure = player:status(handle)
      break
    end
    if player:status(handle) == "complete" then
      break
    end
  end
  Assert.notNil(failure, "the mid-run failure surfaces instead of completing silently")
  Assert.isTrue(
    player:status(handle) ~= "complete",
    "the failed effect never counts as a completed invisible animation"
  )
  Assert.equal(#journal.released, #journal.acquired, "partial acquisitions release exactly once")
  local live = scene:observe({ { combatant = 1, activation = 1, visible = true } })
  Assert.isNil(live, "the host scene stays live after the failure")
  scene:stepSourceTick()
  Assert.equal(#scene:effectViews(), 0, "no failed effect record lingers in the live scene")
end

return { tests = T }
