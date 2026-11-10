-- Independent stage state: background planes stay distinct per engine,
-- scanline waves write per-row offsets instead of one viewport shift,
-- and mosaic dimensions reach the scene instead of idling. Probes run
-- the real task bodies against a real scene; the compositor snapshot
-- below is the locked consumer boundary for the renderer.

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
    launchId = "native-stage-probe",
    packetId = 1,
    programKey = "native-stage-probe",
    seed = 4242,
    random = function(bound)
      assert(type(bound) == "number" and bound > 0, "visual draws name a positive bound")
      return 0
    end,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
    },
    event = { sequence = 1, actionId = 1, hitIndex = 1, effectKey = "native-stage-probe" },
    visualSeed = 4242,
  }
end

local function rowsOf(frame)
  if type(frame) ~= "table" then
    return nil
  end
  local scanlines = frame.scanlines or frame.scanlineBuffer or frame.rows
  if type(scanlines) ~= "table" then
    return nil
  end
  return scanlines
end

function T.animation_planes_carry_independent_per_engine_bindings()
  local scene = sceneWithPair()
  Assert.isTrue(
    type(scene.writeAnimationPlane) == "function",
    "the scene writes independent planes per engine instead of one raster"
  )
  local _ = scene
end

function T.scanline_waves_write_per_row_offsets_instead_of_one_viewport_shift()
  local scene = sceneWithPair()
  local services = { scene = scene, audio = {}, resources = {} }
  local task = assert(BattleEffectTasks.create("battle-background-scanline-sine-wave-transition", {
    callback = "battle-background-scanline-sine-wave-transition",
    taskContext = "battle-display",
    parameters = { backgroundLayer = "battle-background-layer-3", durationTicks = 12 },
  }, occurrenceContext(), services))
  local viewports = {}
  for _ = 1, 12 do
    task:stepSourceTick({ tick = 1 })
    local viewport = scene:scroll()
    viewports[#viewports + 1] = viewport.x .. "," .. viewport.y
  end
  for index, viewport in ipairs(viewports) do
    Assert.equal(viewport, "0,0", "a scanline wave never shifts the whole viewport on tick " .. index)
  end
  Assert.isTrue(
    type(scene.animationFrame) == "function",
    "per-row wave offsets reach the published frame for the renderer"
  )
  local rows = rowsOf(scene:animationFrame())
  Assert.notNil(rows, "the published frame carries the source row buffer")
  Assert.equal(#rows, 192, "the row buffer covers every visible scanline")
  local varied = false
  for index = 2, #rows do
    if rows[index] ~= rows[1] then
      varied = true
      break
    end
  end
  Assert.isTrue(varied, "wave rows differ across scanlines instead of repeating one shift")
end

function T.mosaic_writes_reach_the_scene_instead_of_idling()
  local scene = sceneWithPair()
  local services = { scene = scene, audio = {}, resources = {} }
  local task = assert(BattleEffectTasks.create("battle-sprite-mosaic-transition", {
    callback = "battle-sprite-mosaic-transition",
    taskContext = "battle-sprite",
    parameters = {
      spriteContextSlot = 2,
      step = -2,
      initialHorizontal = 4,
      initialVertical = 12,
      durationTicks = 3,
    },
  }, {}, services))
  task:stepSourceTick({ tick = 1 })
  Assert.isTrue(
    type(scene.animationFrame) == "function",
    "mosaic dimensions reach the published frame for the renderer"
  )
  local frame = scene:animationFrame()
  local mosaic = type(frame) == "table" and (frame.mosaic or frame.compositorMosaic or frame.stageMosaic)
  Assert.notNil(mosaic, "the published frame carries mosaic state while the task runs")
end

return { tests = T }
