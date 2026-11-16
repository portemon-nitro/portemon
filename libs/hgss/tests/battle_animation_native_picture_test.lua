-- Common picture movement family: motion writes the canonical
-- battler center with exact endpoints, never the crop/texture byte.
-- These probes run the real task bodies against a real scene; the field
-- names below are the current task vocabulary and the locked canonical
-- center names the scene must carry. Palette-fade ownership lives with
-- the task factory suite.

local Assert = require("tests.support.Assert")
local BattleEffectTasks = require("libs.hgss.src.presentation.BattleEffectTasks")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local function sceneWithPair()
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  return scene
end

local function occurrenceContext()
  return {
    launchId = "native-picture-probe",
    packetId = 1,
    programKey = "native-picture-probe",
    seed = 4242,
    random = function(bound)
      assert(type(bound) == "number" and bound > 0, "visual draws name a positive bound")
      return 0
    end,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
    },
    event = { sequence = 1, actionId = 1, hitIndex = 1, effectKey = "native-picture-probe" },
    visualSeed = 4242,
  }
end

local function runToCompletion(task, ticks)
  for _ = 1, ticks do
    task:stepSourceTick({ tick = 1 })
    if task:status() == "complete" then
      return true
    end
  end
  return task:status() == "complete"
end

function T.picture_motion_writes_canonical_centers_not_the_crop_byte()
  local scene = sceneWithPair()
  local services = { scene = scene, audio = {}, resources = {} }
  local activation = { combatant = 1, activation = 1 }
  local task = assert(BattleEffectTasks.create("pokemon-picture-sinusoidal-position-motion", {
    parameters = { durationTicks = 4, startX = 0, endX = 16 },
    activation = activation,
  }, occurrenceContext(), services))
  task:stepSourceTick({ tick = 1 })
  local mid = scene:pictureState(activation)
  Assert.notNil(mid, "motion publishes picture state while running")
  Assert.isNil(mid.pictureXOffset2, "horizontal motion never routes through the crop byte")
  Assert.notNil(mid.centerX, "horizontal motion writes the canonical center")
end

function T.picture_motion_endpoints_persist_after_completion()
  local scene = sceneWithPair()
  local services = { scene = scene, audio = {}, resources = {} }
  local activation = { combatant = 1, activation = 1 }
  local task = assert(BattleEffectTasks.create("pokemon-picture-sinusoidal-position-motion", {
    parameters = { durationTicks = 4, startX = 0, endX = 16 },
    activation = activation,
  }, occurrenceContext(), services))
  Assert.isTrue(runToCompletion(task, 8), "the motion reaches its source-defined completion")
  local final = scene:pictureState(activation)
  Assert.notNil(final, "normal completion preserves the terminal picture write")
  Assert.equal(final.centerX, 16, "the terminal center keeps the commanded endpoint")
end

return { tests = T }
