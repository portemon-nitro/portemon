local Assert = require("tests.support.Assert")
local Overlay118Effect = require("libs.hgss.src.transition.battle.Overlay118Effect")

local T = {}

local function routeAndResources()
  local resources = {
    ["kimono-palette"] = { colors = {} },
    ["kimono-character"] = { tiles = "" },
    ["kimono-map"] = { tiles = {} },
  }
  local route = {
    key = "trainer/kimono-girl",
    role = "background-transition",
    assetGroups = {
      background = {
        palette = "kimono-palette",
        character = "kimono-character",
        map = "kimono-map",
      },
    },
  }
  return route, resources
end

local function startEffect()
  local route, resources = routeAndResources()
  local effect = Overlay118Effect.new(route, resources)
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

function T.kimono_runs_the_nine_phase_background_scroll_with_parked_layers()
  local effect = startEffect()
  Assert.equal(effect:stepSourceTick(), false, "background task initializes with planes on")
  Assert.isTrue(effect:frame().planesEnabled, "background re-init owns the planes at phase zero")
  Assert.deepEqual(
    effect:frame().backgroundScroll,
    { bg1 = { x = 0, y = 0x80 }, bg3 = { x = 0, y = 0xFD } },
    "layers park at their pinned scroll positions"
  )
  stepTo(effect, 4, 40)
  local first = effect:frame().backgroundScroll
  effect:stepSourceTick()
  local second = effect:frame().backgroundScroll
  Assert.isTrue(
    second.bg1.y < first.bg1.y or second.bg3.y > first.bg3.y,
    "the eased scroll moves the parked layers every tick"
  )
  local ticks = 0
  while not effect:stepSourceTick() and ticks < 500 do
    ticks = ticks + 1
  end
  Assert.isNil(effect._resources, "teardown releases the background set")
  effect:dispose()
end

function T.scroll_snaps_through_the_raw_repeat_bound_then_arms_the_second_scroll()
  local effect = startEffect()
  stepTo(effect, 5, 200)
  effect:stepSourceTick()
  Assert.deepEqual(
    effect:frame().backgroundScroll,
    { bg1 = { x = 0, y = 0 }, bg3 = { x = 0, y = 0x3 * 0x80 } },
    "the snap moves both layers to their pinned positions"
  )
  local snaps = 1
  local ticks = 0
  while (effect:frame().sourcePhase == 5 or effect:frame().sourcePhase == 4) and ticks < 500 do
    if effect:frame().sourcePhase == 5 then
      snaps = snaps + 1
    end
    effect:stepSourceTick()
    ticks = ticks + 1
  end
  Assert.equal(snaps, 5, "the snap recurs through the repeat bound")
  Assert.equal(effect:frame().repeatCount, 5, "the first scroll repeats through its raw bound")
  Assert.equal(effect:frame().sourcePhase, 6, "the counted scroll arms the second scroll")
  Assert.equal(effect:frame().scrollArm.frame, 0, "the second scroll arms fresh")
  Assert.equal(effect:frame().scrollDuration, 0x12, "both scrolls report the raw arm duration")
  effect:dispose()
end

function T.kimono_frames_carry_no_fade_wipe_or_sprite_keys()
  local effect = startEffect()
  local ticks = 0
  while not effect:stepSourceTick() and ticks < 500 do
    local frame = effect:frame()
    Assert.isNil(frame.paletteFade, "no palette fade exists anywhere in the path")
    Assert.isNil(frame.whiteFadeAlpha, "no brightness fade exists anywhere in the path")
    Assert.isNil(frame.brightness, "no brightness work exists anywhere in the path")
    Assert.isNil(frame.wipe, "no scanline wipe exists anywhere in the path")
    Assert.isNil(frame.sprites, "no sprites exist anywhere in the path")
    Assert.isNil(frame.blendAlpha, "no blend layer exists anywhere in the path")
    Assert.equal(frame.requiresCurrentFieldLayers, false, "pure background work requests no field recapture")
    ticks = ticks + 1
  end
  local again = pcall(function()
    return effect:stepSourceTick()
  end)
  Assert.equal(again, false, "completed background tasks cannot advance")
  effect:dispose()
end

function T.unknown_roles_and_missing_backgrounds_fail_closed()
  local route, resources = routeAndResources()
  local ok = pcall(function()
    return Overlay118Effect.new({ role = "plain-wild-fallback", assetGroups = route.assetGroups }, resources)
  end)
  Assert.equal(ok, false, "fallback roles have no background-scroll worker")
  local missing = pcall(function()
    return Overlay118Effect.new({ role = "background-transition", assetGroups = {} }, resources)
  end)
  Assert.equal(missing, false, "routes without a transition background fail closed")
end

return { tests = T }
