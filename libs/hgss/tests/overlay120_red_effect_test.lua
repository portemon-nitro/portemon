local Assert = require("tests.support.Assert")
local Overlay120RedEffect = require("libs.hgss.src.transition.battle.Overlay120RedEffect")

local T = {}

local function routeAndResources()
  local resources = {
    ["red-palette"] = { colors = { { r = 0, g = 0, b = 0 }, { r = 200, g = 30, b = 30 } } },
    ["red-character"] = { depth = 3, tiles = string.rep(string.char(0x11), 32) },
    ["red-cell"] = {
      cells = { { objs = { { tile = 0, width = 8, height = 8, x = -4, y = -4, palette = 0 } } } },
    },
    ["red-animation"] = {
      anims = {
        {
          frames = { { cell = 0, duration = 1, translateX = 0, translateY = 0, scaleX = 1, scaleY = 1, rotation = 0 } },
        },
      },
    },
    ["red-bg-palette"] = { colors = {} },
    ["red-bg-character"] = { tiles = "" },
    ["red-bg-map"] = { tiles = {} },
  }
  local route = {
    key = "trainer/red",
    role = "red-trainer-transition",
    assetGroups = {
      sprite = {
        palette = "red-palette",
        character = "red-character",
        cell = "red-cell",
        animation = "red-animation",
      },
      background = {
        palette = "red-bg-palette",
        character = "red-bg-character",
        map = "red-bg-map",
      },
    },
  }
  return route, resources
end

local function startEffect()
  local route, resources = routeAndResources()
  local effect = Overlay120RedEffect.new(route, resources)
  effect:prepareGraphics(love.graphics)
  effect:start()
  return effect
end

local function stepTo(effect, phase, bound)
  local ticks = 0
  while effect:frame().sourcePhase < phase and ticks < bound do
    effect:stepSourceTick()
    ticks = ticks + 1
  end
  return ticks
end

function T.red_runs_the_six_phase_window_sprite_and_double_fade_intro()
  local effect = startEffect()
  Assert.equal(effect:stepSourceTick(), false, "Red task initializes with planes on")
  Assert.isTrue(effect:frame().planesEnabled, "Red task enables engine-A planes at phase zero")
  Assert.deepEqual(
    effect:frame().window,
    { width = 0x20, height = 0x20, plane = "bg3" },
    "Red task opens its pinned background window"
  )
  Assert.equal(#effect:frame().sprites, 1, "Red task builds its single trainer sprite")
  Assert.notNil(effect:frame().sprites[1].imageHandle, "Red sprite carries its uploaded GPU image")
  stepTo(effect, 4, 40)
  local ticks = 0
  while not effect:stepSourceTick() and ticks < 200 do
    ticks = ticks + 1
  end
  Assert.isNil(effect._window, "teardown removes the background window")
  Assert.isNil(effect._resources, "teardown releases the sprite and background")
  Assert.equal(#effect._sprites, 0, "teardown deletes the trainer sprite")
  effect:dispose()
end

function T.two_stage_fade_flashes_then_settles_over_its_raw_durations()
  local effect = startEffect()
  stepTo(effect, 4, 40)
  effect:stepSourceTick()
  Assert.deepEqual(
    effect:frame().paletteFade.args,
    { 0x1C, 1, 4, 0, 3, 0x2A },
    "flash stage reports its raw native words"
  )
  local mosaicStart = effect:frame().mosaicStep
  for _ = 1, 27 do
    effect:stepSourceTick()
  end
  Assert.deepEqual(
    effect:frame().paletteFade.args,
    { 0x18, 1, 4, 0, 3, 0x2A },
    "settle stage reports its raw native words"
  )
  Assert.near(effect:frame().whiteFadeAlpha, 1, 0.01, "flash peaks at the stage handoff")
  local mosaicMiddle = effect:frame().mosaicStep
  Assert.isTrue(mosaicMiddle > mosaicStart, "mosaic stepper advances alongside the flash")
  for _ = 1, 24 do
    effect:stepSourceTick()
  end
  Assert.equal(effect:frame().sourcePhase, 5, "settle stage completes on its raw duration")
  Assert.equal(effect:frame().whiteFadeAlpha, 0, "settle returns the field from the flash")
  Assert.isTrue(effect:frame().mosaicStep > mosaicMiddle, "mosaic stepper advances through the settle")
  local done = effect:stepSourceTick()
  Assert.equal(done, true, "window teardown completes the task")
  local again = pcall(function()
    return effect:stepSourceTick()
  end)
  Assert.equal(again, false, "completed Red tasks cannot advance")
  effect:dispose()
end

function T.unknown_roles_and_missing_groups_fail_closed()
  local route, resources = routeAndResources()
  for _, role in ipairs({ "trainer-transition", "background-transition", "plain-wild-fallback" }) do
    local ok = pcall(function()
      return Overlay120RedEffect.new({ role = role, assetGroups = route.assetGroups }, resources)
    end)
    Assert.equal(ok, false, "role " .. role .. " has no Red intro worker")
  end
  local missing = pcall(function()
    return Overlay120RedEffect.new({ role = "red-trainer-transition", assetGroups = {} }, resources)
  end)
  Assert.equal(missing, false, "Red routes without a trainer sprite fail closed")
end

return { tests = T }
