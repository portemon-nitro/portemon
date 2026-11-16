-- Targeted background-transition placement at the task seam: a
-- picture-attribute shake moves only its named pictures, never the
-- viewport, when the compiled background flag stays clear; the viewport
-- sweep runs only while the background flag is set. Retail selector 36
-- lowers three independent displacement flags
-- (battle_anim_emitter.c AddOffsetFromScript family / selector-36 flag
-- word), so a Leer-style shake (pictureSets opposing-battler,
-- pictureAttributeOffset set, backgroundPositionEnabled clear) must
-- jitter the foe while the viewport scroll stays parked.
-- Headless: the real scene owns scroll and picture overlays; no battle
-- or ROM needed.

local Assert = require("tests.support.Assert")
local BattleEffectTasks = require("libs.hgss.src.presentation.BattleEffectTasks")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local KIND = "battle-background-blend-transition"

local function sceneWithPair()
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  return scene
end

local function servicesFor(scene)
  local resources = {}
  function resources.resolve(key)
    return { key = key, lease = key }
  end
  function resources.release(_lease) end
  return { scene = scene, audio = {}, resources = resources }
end

local function occurrenceContext()
  return {
    launchId = "picture-sets-probe",
    packetId = 1,
    programKey = "picture-sets-probe",
    seed = 4242,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
    },
    sourceBattlers = {
      { combatant = 1, activation = 1, sideType = 0 },
      { combatant = 3, activation = 3, sideType = 1 },
    },
    random = function(bound)
      assert(type(bound) == "number" and bound >= 1, "visual draws name a positive bound")
      return 0
    end,
  }
end

local function shakeArgs(pictureSets, backgroundPositionEnabled)
  return {
    callback = "battle-background-position-transition",
    taskContext = "battle-display",
    parameters = {
      backgroundPositionEnabled = backgroundPositionEnabled,
      managedSpriteOffset = false,
      offsetX = 1,
      offsetY = 0,
      pictureAttributeOffset = true,
      pictureSets = pictureSets,
      steps = 2,
      ticksPerStep = 1,
    },
  }
end

function T.picture_shake_leaves_the_viewport_parked_without_the_background_flag()
  local scene = sceneWithPair()
  local task = assert(
    BattleEffectTasks.create(KIND, shakeArgs({ "opposing-battler" }, false), occurrenceContext(), servicesFor(scene))
  )
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "running", "the shake keeps running past its first source tick")
  local scroll = scene:scroll()
  Assert.equal(scroll.x, 0, "the picture-only shake never drifts the viewport horizontally")
  Assert.equal(scroll.y, 0, "the picture-only shake never drifts the viewport vertically")
  local foe = scene:pictureState({ combatant = 3, activation = 3 })
  Assert.notNil(foe, "the named foe picture stays readable while it shakes")
  local moved = (foe.pictureXOffset or 0) ~= 0 or (foe.pictureYOffset or 0) ~= 0
  Assert.isTrue(moved, "the opposing battler picture carries the shake displacement")
  local attacker = scene:pictureState({ combatant = 1, activation = 1 })
  local attackerMoved = attacker ~= nil
    and ((attacker.pictureXOffset or 0) ~= 0 or (attacker.pictureYOffset or 0) ~= 0)
  Assert.isFalse(attackerMoved, "the unaddressed attacker picture stays parked")
  for _ = 1, 16 do
    if task:status() == "complete" then
      break
    end
    task:stepSourceTick({ tick = 1 })
  end
  Assert.equal(task:status(), "complete", "the shake retires on its own phase boundary")
  scroll = scene:scroll()
  Assert.equal(scroll.x, 0, "the retired picture-only shake restores no viewport drift")
  Assert.equal(scroll.y, 0, "the retired picture-only shake restores no viewport drift vertically")
end

function T.background_flag_restores_the_viewport_sweep()
  local scene = sceneWithPair()
  local task = assert(
    BattleEffectTasks.create(KIND, shakeArgs({ "opposing-battler" }, true), occurrenceContext(), servicesFor(scene))
  )
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "running", "the flagged shake keeps running past its first source tick")
  local scroll = scene:scroll()
  Assert.isTrue(scroll.x ~= 0 or scroll.y ~= 0, "the background-enabled shake sweeps the viewport")
  for _ = 1, 16 do
    if task:status() == "complete" then
      break
    end
    task:stepSourceTick({ tick = 1 })
  end
  Assert.equal(task:status(), "complete", "the flagged shake retires on its own phase boundary")
  scroll = scene:scroll()
  Assert.equal(scroll.x, 0, "the retired flagged shake restores the saved viewport horizontally")
  Assert.equal(scroll.y, 0, "the retired flagged shake restores the saved viewport vertically")
end

return { tests = T }
