-- Visual execution is deterministic in the source clock: the same program
-- and visual seed produce the identical source-tick trace and final scene
-- state across host schedules, extra draw and status reads never advance
-- the clock, and no visual step consumes the mechanics or world random
-- streams. The scene half of that promise holds today through the real
-- presentation boundary; the program-trace half drives the
-- battle-private program player once it exists.
-- Native cadence: one accepted source tick is nominally 1/30 second;
-- draws, polls, and resizes never advance it.
-- Headless: the real scene advances by whole source ticks only; the
-- recorder doubles never touch a random stream.

local Assert = require("tests.support.Assert")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local function gaugeScene()
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  scene:startGaugeTask("lead-hp", { maximum = 52, current = 52, delta = 9, tiles = 6 })
  return scene
end

local function playbackPacket()
  local packet = BattlePresentationModel.packet({}, { events = {} }, {}, {
    launchId = "determinism-probe",
    packetId = 1,
  })
  Assert.equal(packet.launchId, "determinism-probe", "the playback input carries its launch identity")
  return packet
end

local function playerModule()
  local ok, Player = pcall(require, "libs.hgss.src.presentation.BattleAnimationPlayer")
  Assert.isTrue(ok, "the battle-private animation player resolves through the presentation boundary")
  Assert.equal(type(Player.new), "function", "the player exposes its construction entry point")
  return Player
end

function T.host_schedule_partitioning_never_changes_source_tick_state()
  local fine = gaugeScene()
  for _ = 1, 30 do
    fine:advance(1 / 30)
  end
  local coarse = gaugeScene()
  for _ = 1, 3 do
    coarse:advance(10 / 30)
  end
  Assert.equal(fine:gaugeTaskValue("lead-hp"), coarse:gaugeTaskValue("lead-hp"), "partitioning keeps the value")
  Assert.equal(fine:gaugeTaskPixels("lead-hp"), coarse:gaugeTaskPixels("lead-hp"), "partitioning keeps the pixels")
  Assert.equal(fine:gaugeTaskActive("lead-hp"), coarse:gaugeTaskActive("lead-hp"), "partitioning keeps liveness")
  local before = fine:gaugeTaskValue("lead-hp")
  Assert.equal(fine:gaugeTaskValue("lead-hp"), before, "status reads never advance the clock")
  Assert.equal(fine:gaugeTaskPixels("lead-hp"), fine:gaugeTaskPixels("lead-hp"), "repeated reads agree")
end

function T.same_program_and_seed_give_the_same_trace_at_any_host_schedule()
  local Player = playerModule()
  local function run(extraReads)
    local scene = BattleScene.new()
    scene:observe({
      { combatant = 1, activation = 1, visible = true },
      { combatant = 3, activation = 3, visible = true },
    })
    local audio = { played = {} }
    function audio.play(name)
      audio.played[#audio.played + 1] = name
    end
    function audio.stop(_name) end
    function audio.isFinished(_name)
      return true
    end
    local steps = {}
    local tasks = {}
    function tasks.create(kind, _args, _context, _services)
      local task = { _state = "complete" }
      function task.stepSourceTick(_tick)
        steps[#steps + 1] = kind
      end
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
      return { key = key, lease = key }
    end
    function resources.release(_lease) end
    local player = assert(Player.new({
      scene = scene,
      audio = audio,
      resources = resources,
      tasks = tasks,
    }))
    local program = {
      entry = "main",
      instructions = {
        { op = "interpreter-wait", values = { 2 } },
        {
          op = "schedule-battle-task",
          taskKind = "battle-background-blend-transition",
          taskInputRule = "x",
          values = { 1 },
        },
        { op = "reset-blend-alpha" },
      },
      subprograms = {},
      taskKinds = {},
    }
    local handle = assert(player:start(playbackPacket(), program))
    local trace = {}
    for tick = 1, 12 do
      player:stepSourceTick({ tick = tick, seed = 1234 })
      if extraReads then
        scene:stepSourceTick()
        player:status(handle)
      end
      trace[#trace + 1] = player:status(handle)
      if player:status(handle) == "complete" then
        break
      end
    end
    return { trace = trace, steps = steps, audio = audio.played }
  end
  local plain = run(false)
  local probed = run(true)
  Assert.deepEqual(probed.trace, plain.trace, "extra reads leave the source-tick trace identical")
  Assert.deepEqual(probed.steps, plain.steps, "extra reads leave child stepping identical")
  Assert.deepEqual(probed.audio, plain.audio, "extra reads leave the voice trace identical")
end

return { tests = T }
