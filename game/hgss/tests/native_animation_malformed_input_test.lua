-- Malformed animation input fails deterministically at its own boundary:
-- words outside the dispatch table and jumps landing inside operand bytes
-- never lower, while missing playback detail and zero-time control-flow
-- cycles fail at admission or execution instead of counting as complete.
-- The lowering half holds today through the real producer path; the
-- admission and execution half drives the battle-private program player
-- once it exists. No unsupported instruction may read as success and no
-- artificial yield may disguise malformed data.
-- Native table: asm/overlay_07.s ov07_02234DE8 through ov07_02234F48 holds
-- 0x160 bytes of pointers (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36).
-- Headless: synthetic command streams use the real producer lowering and
-- the shared program shape only.

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

local function playerModule()
  local ok, Player = pcall(require, "libs.hgss.src.presentation.BattleAnimationPlayer")
  Assert.isTrue(ok, "the battle-private animation player resolves through the presentation boundary")
  Assert.equal(type(Player.new), "function", "the player exposes its construction entry point")
  return Player
end

function T.words_outside_the_dispatch_table_never_lower()
  local err = Assert.throws(function()
    BattleAnimationCompiler.compile({ key = "out-of-table", stream = streamOf({ 88 }) })
  end, "words past the table end never lower")
  Assert.isTrue(
    string.find(tostring(err), "unknown dispatch opcode", 1, true) ~= nil,
    "the rejection names the out-of-table word"
  )
  local program = assert(BattleAnimationCompiler.compile({ key = "table-edge", stream = streamOf({ 9 }) }))
  Assert.equal(#program.instructions, 1, "a bare table member still lowers to one instruction")
  Assert.equal(program.instructions[1].op, "reset-blend-alpha", "the edge member keeps its normalized form")
end

function T.jumps_into_operand_bytes_never_lower()
  local err = Assert.throws(function()
    BattleAnimationCompiler.compile({ key = "into-operands", stream = streamOf({ 30, 1, 5, 6, 9 }) })
  end, "a branch target inside operand bytes never lowers")
  Assert.notNil(err, "the operand-byte jump reports its lowering failure")
end

function T.missing_playback_detail_and_zero_time_cycles_fail_instead_of_completing()
  local cycled = assert(BattleAnimationCompiler.compile({ key = "self-branch", stream = streamOf({ 30, 1, 5, 0, 9 }) }))
  Assert.isTrue(
    BattleAnimationSchema.assertProgram({
      entry = cycled.entry,
      instructions = cycled.instructions,
      subprograms = cycled.subprograms,
      taskKinds = cycled.taskKinds,
    }),
    "the self-directed branch lowers; running it must still fail, never hang"
  )
  Assert.equal(cycled.instructions[1].branchTarget, 1, "the cycle returns to its own instruction")

  local Player = playerModule()
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  local audio = {}
  function audio.play(_name) end
  function audio.stop(_name) end
  function audio.isFinished(_name)
    return true
  end
  local tasks = {}
  function tasks.create(_kind, _args, _context, _services)
    error("no child exists on the malformed path")
  end
  local resources = {}
  function resources.resolve(key)
    return { key = key, lease = key }
  end
  function resources.release(_lease) end
  local player = assert(Player.new({
    scene = scene,
    audio = audio,
    resources = resources,
    tasks = tasks,
  }))
  local missing = BattlePresentationModel.packet({}, { events = {} }, {}, {
    launchId = "malformed-probe",
    packetId = 1,
  })
  local rejected = player:start(missing, {
    entry = "main",
    instructions = { { op = "schedule-battle-task" } },
    subprograms = {},
    taskKinds = {},
  })
  Assert.isNil(rejected, "an instruction without its required playback detail is never admitted")
  local spinning = assert(player:start(missing, cycled))
  for _ = 1, 200 do
    player:stepSourceTick({ tick = 1 })
    if player:status(spinning) == "failed" then
      break
    end
  end
  Assert.equal(player:status(spinning), "failed", "the zero-time cycle fails with provenance, never hangs")
end

return { tests = T }
