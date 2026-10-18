local Assert = require("tests.support.Assert")
local Overlay120FallbackEffect = require("libs.hgss.src.transition.battle.Overlay120FallbackEffect")

local T = {}

local function backgroundResources()
  return {
    ["bg-palette"] = { colors = { { r = 0, g = 0, b = 0 } } },
    ["bg-characters-one"] = { depth = 4, tiles = "" },
    ["bg-characters-two"] = { depth = 4, tiles = "" },
    ["bg-map-one"] = { tiles = {} },
    ["bg-map-two"] = { tiles = {} },
    ["transition-palette"] = { colors = {} },
    ["transition-character"] = { tiles = "" },
    ["transition-map"] = { tiles = {} },
  }
end

local function routeFor(role, timeOfDay)
  return {
    key = "fallback/plain/" .. timeOfDay .. "/wild",
    role = role,
    assetGroups = {
      sceneAssets = {
        palette = "bg-palette",
        characters = { "bg-characters-one", "bg-characters-two" },
        maps = { "bg-map-one", "bg-map-two" },
        transitionBackground = {
          palette = "transition-palette",
          character = "transition-character",
          map = "transition-map",
        },
      },
    },
  }
end

local function effectFor(role, timeOfDay)
  local effect = Overlay120FallbackEffect.new(
    routeFor(role, timeOfDay),
    backgroundResources(),
    { kind = "wild", terrain = "plain", timeOfDay = timeOfDay }
  )
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

function T.wild_fallback_roles_share_the_eight_phase_mosaic_worker()
  for _, role in ipairs({ "plain-wild-fallback", "water-wild-fallback", "cave-wild-fallback" }) do
    local effect = effectFor(role, "day")
    Assert.equal(effect:stepSourceTick(), false, role .. " initializes with planes on")
    Assert.isTrue(effect:frame().planesEnabled, role .. " enables engine-A planes at phase zero")
    stepTo(effect, 3, 30)
    Assert.equal(effect:frame().sourcePhase, 3, role .. " reveals after the cover wait")
    Assert.equal(effect:frame().mosaicSteps, 24, role .. " reveals over the pinned order-table length")
    local ticks = 0
    while not effect:stepSourceTick() and ticks < 200 do
      ticks = ticks + 1
    end
    Assert.isNil(effect._resources, role .. " releases its background set at completion")
    Assert.isNil(effect._wipe, role .. " releases its reveal sweep at completion")
    effect:dispose()
  end
end

function T.day_and_late_routes_carry_opposite_reveal_polarity()
  local day = effectFor("plain-wild-fallback", "day")
  Assert.equal(day:frame().polarity, 0x10, "day routes carry the opening polarity word")
  local late = effectFor("plain-wild-fallback", "late")
  Assert.equal(late:frame().polarity, -16, "late routes carry the inverted polarity word")
  stepTo(day, 1, 10)
  stepTo(late, 1, 10)
  day:stepSourceTick()
  late:stepSourceTick()
  Assert.equal(day:frame().coverWait.polarity, 0x10, "day cover waits on the opening polarity")
  Assert.equal(late:frame().coverWait.polarity, -16, "late cover waits on the inverted polarity")
  stepTo(day, 3, 30)
  stepTo(late, 3, 30)
  day:stepSourceTick()
  late:stepSourceTick()
  Assert.equal(day:frame().backgroundScroll.x, 0x10, "day scroll follows the opening polarity")
  Assert.equal(late:frame().backgroundScroll.x, -16, "late scroll follows the inverted polarity")
  day:dispose()
  late:dispose()
end

function T.mosaic_reveal_advances_one_step_per_tick_with_a_scanline_countdown()
  local effect = effectFor("cave-wild-fallback", "day")
  stepTo(effect, 3, 30)
  local previous = 0
  for expected = 1, 24 do
    effect:stepSourceTick()
    Assert.equal(effect:frame().mosaicStep, expected, "mosaic reveals one order-table step per tick")
    Assert.isTrue(effect:frame().mosaicStep > previous, "reveal progresses monotonically")
    previous = effect:frame().mosaicStep
    Assert.equal(#effect:frame().wipe.rows, 192, "reveal sweep covers the native scanlines")
  end
  Assert.equal(effect:frame().sourcePhase, 4, "completed reveal arms the scanline driver")
  Assert.equal(effect:frame().scanlineCountdown, 10, "scanline driver starts from its raw countdown")
  for _ = 1, 9 do
    effect:stepSourceTick()
    Assert.equal(effect:frame().sourcePhase, 4, "scanline driver holds through its countdown")
  end
  effect:stepSourceTick()
  Assert.equal(effect:frame().sourcePhase, 5, "scanline completion releases the settle flash")
  effect:stepSourceTick()
  Assert.equal(effect:frame().sourcePhase, 6, "settle flash advances to teardown")
  Assert.equal(effect:frame().whiteFadeAlpha, 1, "settle flash marks the completion boundary")
  effect:stepSourceTick()
  Assert.equal(effect:frame().whiteFadeAlpha, 0, "settle flash clears before teardown")
  local done = effect:stepSourceTick()
  Assert.equal(done, true, "terminal cleanup completes the task")
  local again = pcall(function()
    return effect:stepSourceTick()
  end)
  Assert.equal(again, false, "completed reveal tasks cannot advance")
  effect:dispose()
end

function T.unknown_roles_and_missing_background_sets_fail_closed()
  local resources = backgroundResources()
  for _, role in ipairs({ "plain-trainer-fallback", "trainer-transition", "background-transition" }) do
    local ok = pcall(function()
      return Overlay120FallbackEffect.new(
        routeFor(role, "day"),
        resources,
        { kind = "wild", terrain = "plain", timeOfDay = "day" }
      )
    end)
    Assert.equal(ok, false, "role " .. role .. " has no window/mosaic fallback worker")
  end
  local ok = pcall(function()
    return Overlay120FallbackEffect.new({ key = "fallback/plain/day/wild", role = "plain-wild-fallback" }, resources)
  end)
  Assert.equal(ok, false, "routes without a background set fail closed")
  local badKey = pcall(function()
    return Overlay120FallbackEffect.new(
      {
        key = "fallback/plain/morning/wild",
        role = "plain-wild-fallback",
        assetGroups = routeFor("plain-wild-fallback", "day").assetGroups,
      },
      resources,
      { kind = "wild", terrain = "plain", timeOfDay = "morning" }
    )
  end)
  Assert.equal(badKey, false, "routes without a source time of day fail closed")
end

return { tests = T }
