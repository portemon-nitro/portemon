-- Selector-69 sprite mosaic retirement at the task seam: the lowered
-- duration owns the run boundary, so a timed mosaic stays running for
-- its first two source ticks and completes after the third, while the
-- same kind without compiled timing still fails closed instead of
-- retiring silently. No mosaic scene writes are asserted here; the
-- visual size registers have no headless seam, so this pins timing and
-- retirement only.

local Assert = require("tests.support.Assert")
local BattleEffectTasks = require("libs.hgss.src.presentation.BattleEffectTasks")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local KIND = "battle-sprite-mosaic-transition"

local function timedArgs()
  return {
    callback = "battle-sprite-mosaic-transition",
    taskContext = "battle-sprite",
    parameters = {
      spriteContextSlot = 2,
      step = -2,
      initialHorizontal = 4,
      initialVertical = 12,
      durationTicks = 3,
    },
  }
end

local function timingLessArgs()
  return {
    callback = "battle-sprite-mosaic-transition",
    taskContext = "battle-sprite",
    parameters = {
      spriteContextSlot = 2,
      step = -2,
      initialHorizontal = 4,
      initialVertical = 12,
    },
  }
end

local function services()
  return { scene = BattleScene.new(), audio = {}, resources = {} }
end

function T.mosaic_transition_retires_on_its_compiled_duration()
  local task = assert(BattleEffectTasks.create(KIND, timedArgs(), {}, services()))
  Assert.equal(task:status(), "pending", "mosaic transitions open pending")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "running", "the first source tick keeps the timed mosaic running")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "running", "the second source tick keeps the timed mosaic running")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "complete", "the mosaic completes after its third source tick")
end

function T.mosaic_transition_without_timing_fails_closed()
  local ok, failure = pcall(BattleEffectTasks.create, KIND, timingLessArgs(), {}, services())
  Assert.isFalse(ok, "a mosaic without compiled timing never yields a runnable task")
  Assert.isTrue(
    string.find(tostring(failure), KIND, 1, true) ~= nil
      and string.find(tostring(failure), "BATTLE_EFFECT_TASK_MALFORMED", 1, true) ~= nil,
    "the timing-less mosaic fails closed naming itself: " .. tostring(failure)
  )
end

return { tests = T }
