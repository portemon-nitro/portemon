-- Panel-slide visual contract at the task seam: the lowered
-- ObjWindowBgScroll run (selectors 80-83) owns its 37-tick duration --
-- the run stays live for its first 36 source ticks and retires after
-- the 37th -- installs its stripe layer, scrolls it by the compiled
-- velocity, holds blend 12/4 behind an object-window silhouette of the
-- affected battler, fades the blend out over the last twelve ticks, and
-- removes everything on its destroy tick. Timing-less spawns fail
-- closed instead of retiring silently; sound plays on a separate task.
-- Headless: the real scene owns stripes, scroll, blend, windows, and
-- silhouette; fake resources stage minimal stripe payloads, no battle
-- or ROM needed.

local Assert = require("tests.support.Assert")
local BattleEffectTasks = require("libs.hgss.src.presentation.BattleEffectTasks")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local KIND = "battle-sprite-panel-slide"

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
    local lower = string.lower(key)
    local data
    if string.find(lower, "char", 1, true) ~= nil then
      data = { depth = 3, tiles = string.rep("\0", 32) }
    elseif string.find(lower, "palette", 1, true) ~= nil then
      local colors = {}
      for _ = 1, 16 do
        colors[#colors + 1] = { r = 8, g = 16, b = 24 }
      end
      data = { colors = colors }
    else
      data = {
        width = 8,
        height = 8,
        entries = { { tile = 0, flipH = false, flipV = false, palette = 0 } },
      }
    end
    return { key = key, data = data }
  end
  function resources.release(_lease) end
  return { scene = scene, audio = {}, resources = resources }
end

local function occurrenceContext()
  return {
    launchId = "panel-slide-probe",
    packetId = 1,
    programKey = "panel-slide-probe",
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

local function stripeResourceKeys()
  local keys = {}
  for graphic = 0, 3 do
    keys["stripeGraphic" .. graphic .. "Char"] = "stripe-graphic-" .. graphic .. "-char"
    keys["stripeGraphic" .. graphic .. "Palette"] = "stripe-graphic-" .. graphic .. "-palette"
    keys["stripeGraphic" .. graphic .. "Screen"] = "stripe-graphic-" .. graphic .. "-screen"
  end
  return keys
end

local function slideArgs()
  return {
    callback = "battle-sprite-panel-slide-down",
    taskContext = "sprite-system",
    runtimeSelection = "object-window-stripe-selection",
    resourceKeys = stripeResourceKeys(),
    parameters = {
      firstPanelOffsetX = 0,
      firstPanelOffsetY = 3,
      secondPanelOffsetX = 12,
      secondPanelOffsetY = 4,
      durationTicks = 37,
    },
  }
end

local function frameOf(scene)
  return scene:animationFrame()
end

function T.panel_slide_installs_scrolls_blends_and_cleans_up()
  local scene = sceneWithPair()
  local task = assert(BattleEffectTasks.create(KIND, slideArgs(), occurrenceContext(), servicesFor(scene)))
  Assert.equal(task:status(), "pending", "the slide opens pending")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "running", "the slide keeps running past its setup tick")
  local setup = frameOf(scene)
  Assert.notNil(setup.stripe, "the setup tick installs the stripe layer")
  Assert.equal(setup.stripe.scrollY, 3, "the stripe scrolls by its velocity on the first tick")
  Assert.equal(setup.stripe.scrollX, 0, "the down scroll carries no horizontal velocity")
  local compositor = assert(setup.main and setup.main.compositor, "the setup tick publishes its main-engine compositor")
  Assert.notNil(compositor.blend, "the setup tick stages the stripe blend")
  Assert.equal(compositor.blend.eva, 12, "the blend holds the compiled start A coefficient")
  Assert.equal(compositor.blend.evb, 4, "the blend holds the compiled start B coefficient")
  Assert.notNil(compositor.windows, "the setup tick stages the object window")
  -- Retail translucency: the stripe blends over the mon picture
  -- (G2_SetBlendAlpha BG2 over BG0|BG3|OBJ|BD), so the second target
  -- keeps world3d and the stripe priority rides above the mon.
  local second = assert(compositor.secondTarget, "the setup tick stages its blend second targets")
  Assert.isTrue(second.world3d == true, "the stripe blends over the mon picture")
  local priority = assert(compositor.priority, "the setup tick stages its blend priorities")
  Assert.equal(priority.transition, 1, "the stripe rides above the mon like the native base priority")
  Assert.equal(priority.world3d, 2, "the mon rides below the stripe like the native sprite priority")
  local objWindow = assert(compositor.windows.objWindow, "the setup tick stages the object window")
  Assert.isTrue(objWindow.mask.world3d == true, "the inside mask keeps the mon visible as the blend partner")
  Assert.notNil(setup.objWindowSilhouette, "the setup tick names the silhouette battler")
  Assert.equal(setup.objWindowSilhouette.combatant, 1, "the default target silhouettes the occurrence attacker")
  for tick = 2, 36 do
    task:stepSourceTick({ tick = 1 })
    Assert.equal(task:status(), "running", "the timed slide keeps running before its final source tick")
    if tick == 10 then
      local mid = frameOf(scene)
      Assert.equal(mid.stripe.scrollY, 30, "the scroll accumulates the velocity every tick")
      Assert.equal(mid.main.compositor.blend.eva, 12, "the hold keeps the blend before the fade-out")
    end
  end
  task:stepSourceTick({ tick = 1 })
  Assert.equal(task:status(), "complete", "the slide retires after its 37th source tick")
  local settled = frameOf(scene)
  Assert.isNil(settled.stripe, "the destroy tick removes the stripe layer")
  Assert.isNil(settled.objWindowSilhouette, "the destroy tick clears the silhouette")
  local blend = settled.main.compositor.blend
  Assert.isTrue(
    blend == nil or (blend.eva == nil and blend.evb == nil),
    "the destroy tick restores the journaled blend"
  )
end

function T.panel_slide_without_timing_fails_closed()
  local scene = sceneWithPair()
  local args = slideArgs()
  args.parameters = {
    firstPanelOffsetX = 0,
    firstPanelOffsetY = 3,
    secondPanelOffsetX = 12,
    secondPanelOffsetY = 4,
  }
  local ok, failure = pcall(BattleEffectTasks.create, KIND, args, occurrenceContext(), servicesFor(scene))
  Assert.isFalse(ok, "a slide without compiled timing never yields a runnable task")
  Assert.isTrue(
    string.find(tostring(failure), KIND, 1, true) ~= nil,
    "the timing-less slide fails closed naming itself: " .. tostring(failure)
  )
end

return { tests = T }
