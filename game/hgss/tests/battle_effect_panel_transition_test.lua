-- Selector-80 panel-slide retirement at the task seam: the lowered
-- duration owns the run boundary, so a timed slide stays running for
-- its first 36 source ticks and completes after the 37th, while the
-- same kind without compiled timing still fails closed instead of
-- retiring silently. No panel scene writes are asserted here; the
-- window scroll registers have no headless seam, so this pins timing
-- and retirement only.

local Assert = require("tests.support.Assert")
local BattleEffectTasks = require("libs.hgss.src.presentation.BattleEffectTasks")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local KIND = "battle-sprite-panel-slide"

local function timedArgs()
  return {
    callback = "battle-sprite-panel-slide-down",
    taskContext = "sprite-system",
    parameters = {
      firstPanelOffsetX = 0,
      firstPanelOffsetY = 3,
      secondPanelOffsetX = 12,
      secondPanelOffsetY = 4,
      durationTicks = 37,
    },
  }
end

local function timingLessArgs()
  return {
    callback = "battle-sprite-panel-slide-down",
    taskContext = "sprite-system",
    parameters = {
      firstPanelOffsetX = 0,
      firstPanelOffsetY = 3,
      secondPanelOffsetX = 12,
      secondPanelOffsetY = 4,
    },
  }
end

local function services()
  return { scene = BattleScene.new(), audio = {}, resources = {} }
end

function T.panel_slide_retires_on_its_compiled_duration()
  local task = assert(BattleEffectTasks.create(KIND, timedArgs(), {}, services()))
  Assert.equal(task:status(), "pending", "panel slides open pending")
  for _ = 1, 36 do
    task:stepSourceTick({ tick = 1 })
    Assert.equal(task:status(), "running", "the timed slide keeps running before its final source tick")
  end
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "complete", "the slide completes after its 37th source tick")
end

function T.panel_slide_without_timing_fails_closed()
  local ok, failure = pcall(BattleEffectTasks.create, KIND, timingLessArgs(), {}, services())
  Assert.isFalse(ok, "a slide without compiled timing never yields a runnable task")
  Assert.isTrue(
    string.find(tostring(failure), KIND, 1, true) ~= nil
      and string.find(tostring(failure), "BATTLE_EFFECT_TASK_MALFORMED", 1, true) ~= nil,
    "the timing-less slide fails closed naming itself: " .. tostring(failure)
  )
end

return { tests = T }
