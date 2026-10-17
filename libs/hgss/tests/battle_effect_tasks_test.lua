-- Owner tests for the battle-private effect task factory: the narrow
-- create-by-kind contract, the voice monitor lifecycle, and fail-closed
-- unknown kinds (never a timer stand-in).

local Assert = require("tests.support.Assert")
local BattleEffectTasks = require("libs.hgss.src.presentation.BattleEffectTasks")

local T = {}

local function servicesWith(audio)
  return { scene = {}, audio = audio, resources = {} }
end

local function controllableVoice()
  local voice = { finished = false }
  local audio = {}
  function audio.isFinished(_name)
    return voice.finished
  end
  return voice, audio
end

function T.unknown_kinds_fail_instead_of_returning_a_stand_in()
  for _, kind in ipairs({ "no-such-native-kind", "message-only-narration", "" }) do
    local ok, task = pcall(BattleEffectTasks.create, kind, {}, {}, servicesWith({}))
    Assert.isTrue(not ok or task == nil, "kind " .. tostring(kind) .. " never yields a runnable task")
    if ok then
      Assert.isTrue(type(task) ~= "table" or type(task.stepSourceTick) ~= "function", "no runnable task escapes")
    end
  end
end

function T.voice_monitor_completes_only_on_its_voice()
  local voice, audio = controllableVoice()
  local task = assert(BattleEffectTasks.create(BattleEffectTasks.VOICE_MONITOR_KIND, { voice = "cue" }, {}, servicesWith(audio)))
  Assert.equal(task:status(), "pending", "monitors open pending")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "running", "an unfinished voice keeps the monitor running")
  task:stepSourceTick({ tick = 2 })
  Assert.equal(task:status(), "running", "repeated ticks never complete without the voice")
  voice.finished = true
  task:stepSourceTick({ tick = 3 })
  Assert.equal(task:status(), "complete", "the finished voice completes the monitor")
end

function T.voice_monitor_cancel_and_dispose_stay_exact()
  local _, audio = controllableVoice()
  local task = assert(BattleEffectTasks.create(BattleEffectTasks.VOICE_MONITOR_KIND, { voice = "cue" }, {}, servicesWith(audio)))
  task:cancel("withdrawn")
  Assert.equal(task:status(), "cancelled", "cancellation lands on cancelled")
  task:cancel("repeated")
  Assert.equal(task:status(), "cancelled", "repeated cancellation is silent")
  task:dispose()
  task:dispose()
  task:stepSourceTick({ tick = 9 })
  Assert.equal(task:status(), "cancelled", "disposed monitors never advance again")
end

function T.voice_monitor_completion_survives_cancellation()
  local voice, audio = controllableVoice()
  local task = assert(BattleEffectTasks.create(BattleEffectTasks.VOICE_MONITOR_KIND, { voice = "cue" }, {}, servicesWith(audio)))
  voice.finished = true
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "complete", "the monitor completes first")
  task:cancel("late")
  Assert.equal(task:status(), "complete", "completion and cancellation stay separate")
end

function T.voice_monitor_construction_validates_its_collaborators()
  Assert.throws(function()
    BattleEffectTasks.create(BattleEffectTasks.VOICE_MONITOR_KIND, {}, {}, servicesWith({}))
  end, "monitors without an audio query never construct")
  Assert.throws(function()
    BattleEffectTasks.create(BattleEffectTasks.VOICE_MONITOR_KIND, { voice = "cue" }, {}, { scene = {} })
  end, "monitors without services never construct")
  Assert.throws(function()
    BattleEffectTasks.create(BattleEffectTasks.VOICE_MONITOR_KIND, {}, {}, servicesWith({}))
  end, "monitors without a named voice never construct")
end

function T.voice_monitor_audio_failures_propagate()
  local audio = {}
  function audio.isFinished(_name)
    error("synthetic voice query failure")
  end
  local task = assert(BattleEffectTasks.create(BattleEffectTasks.VOICE_MONITOR_KIND, { voice = "cue" }, {}, servicesWith(audio)))
  Assert.throws(function()
    task:stepSourceTick({ tick = 1 })
  end, "audio failures propagate instead of reading as unfinished")
end

return { tests = T }
