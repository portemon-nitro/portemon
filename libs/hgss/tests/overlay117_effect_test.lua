local Assert = require("tests.support.Assert")
local Overlay117Effect = require("libs.hgss.src.transition.battle.Overlay117Effect")

local T = {}

local function spriteSet(prefix)
  return {
    [prefix .. "-palette"] = { colors = { { r = 0, g = 0, b = 0 }, { r = 250, g = 30, b = 20 } } },
    [prefix .. "-character"] = { depth = 3, tiles = string.rep(string.char(0x11), 32) },
    [prefix .. "-cell"] = {
      cells = { { objs = { { tile = 0, width = 8, height = 8, x = -4, y = -4, palette = 0 } } } },
    },
    [prefix .. "-animation"] = {
      anims = {
        {
          frames = { { cell = 0, duration = 1, translateX = 0, translateY = 0, scaleX = 1, scaleY = 1, rotation = 0 } },
        },
      },
    },
  }
end

local function introRoute()
  local resources = spriteSet("grunt")
  return {
    key = "trainer/team-rocket",
    role = "trainer-transition",
    assetGroups = {
      sprite = {
        palette = "grunt-palette",
        character = "grunt-character",
        cell = "grunt-cell",
        animation = "grunt-animation",
      },
    },
  },
    resources
end

local function workerRoute()
  local resources = spriteSet("executive")
  resources["rocket-bg-palette"] = { colors = {} }
  resources["rocket-bg-character"] = { tiles = "" }
  resources["rocket-bg-map-one"] = { tiles = {} }
  resources["rocket-bg-map-two"] = { tiles = {} }
  return {
    key = "trainer/archer",
    role = "trainer-transition",
    messages = { "transition/trainer-name" },
    assetGroups = {
      record = {
        palette = "executive-palette",
        character = "executive-character",
        cell = "executive-cell",
        animation = "executive-animation",
      },
      background = {
        palette = "rocket-bg-palette",
        character = "rocket-bg-character",
        maps = { "rocket-bg-map-one", "rocket-bg-map-two" },
      },
    },
  },
    resources
end

local function startEffect(route, resources)
  local effect = Overlay117Effect.new(route, resources)
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

function T.intro_runs_the_eight_phase_six_sprite_reveal_with_a_raw_fade()
  local route, resources = introRoute()
  local effect = startEffect(route, resources)
  Assert.equal(effect:frame().shape, "intro", "sprite-only routes run the intro")
  Assert.equal(effect:stepSourceTick(), false, "intro initializes with planes on")
  stepTo(effect, 3, 30)
  for slot = 1, 6 do
    effect:stepSourceTick()
    Assert.isTrue(effect:frame().sprites[slot].visible, "reveal shows slot " .. slot .. " in order")
    Assert.equal(effect:frame().revealIndex, slot, "reveal index tracks shown slots")
  end
  Assert.equal(effect:frame().sourcePhase, 4, "six shown slots arm the intro fade")
  Assert.deepEqual(
    effect:frame().paletteFade.args,
    { 0xC, 1, 4, 0, 3, 0x22 },
    "intro fade reports its raw native words"
  )
  local ticks = 0
  while not effect:stepSourceTick() and ticks < 100 do
    ticks = ticks + 1
  end
  Assert.isNil(effect._resources, "intro teardown releases its sprite set")
  Assert.equal(#effect._sprites, 0, "intro teardown deletes its six sprites")
  effect:dispose()
end

function T.worker_runs_the_thirteen_phase_trainer_sequence_with_raw_counts()
  local route, resources = workerRoute()
  local effect = startEffect(route, resources)
  Assert.equal(effect:frame().shape, "worker", "record routes run the shared worker")
  Assert.equal(effect:stepSourceTick(), false, "worker initializes with planes on")
  Assert.isTrue(effect:frame().planesEnabled, "worker enables engine-A planes at phase zero")
  stepTo(effect, 2, 30)
  effect:stepSourceTick()
  Assert.equal(effect:frame().scroll.counter, 11, "background scroll counts down from its raw count")
  stepTo(effect, 3, 30)
  Assert.isNil(effect:frame().scroll, "scroll completion releases its counter")
  stepTo(effect, 6, 60)
  local blendStart = effect:frame().blendAlpha
  effect:stepSourceTick()
  Assert.equal(
    effect:frame().blendAlpha,
    math.min(blendStart + 4, 0x10),
    "blend ramps four coefficients per frame toward its raw cap"
  )
  local ticks = 0
  while effect:frame().blendAlpha < 0x10 and ticks < 30 do
    effect:stepSourceTick()
    ticks = ticks + 1
  end
  Assert.equal(effect:frame().blendAlpha, 0x10, "blend ramps to its raw maximum")
  stepTo(effect, 8, 60)
  effect:stepSourceTick()
  Assert.isTrue(effect:frame().brightness == nil, "background retoggle releases brightness work")
  stepTo(effect, 10, 30)
  effect:stepSourceTick()
  Assert.deepEqual(
    effect:frame().paletteFade.args,
    { 4, 1, 0, 4, 0, 0x7FFF },
    "final fade reports its raw native words"
  )
  local doneTicks = 0
  while not effect:stepSourceTick() and doneTicks < 100 do
    doneTicks = doneTicks + 1
  end
  Assert.isNil(effect._resources, "worker teardown releases its record and background")
  effect:dispose()
end

function T.worker_reports_window_message_and_brightness_sentinel()
  local route, resources = workerRoute()
  local effect = startEffect(route, resources)
  Assert.equal(
    effect:frame().window.messageRoute,
    "transition/trainer-name",
    "worker exposes its selected trainer-name message"
  )
  stepTo(effect, 6, 60)
  effect:stepSourceTick()
  Assert.deepEqual(
    effect:frame().brightness.args,
    { 8, 0, 0x10, 0x1E },
    "brightness transition reports its raw native words"
  )
  Assert.equal(effect:frame().brightness.sentinel, 0x14A5, "brightness carries its raw completion sentinel")
  effect:dispose()
end

function T.tasked_trainer_routes_and_unknown_shapes_fail_closed()
  local intro, introResources = introRoute()
  local tasked =
    { role = "trainer-transition", task = { kind = "overlay115-gym-rival-intro" }, assetGroups = intro.assetGroups }
  local ok = pcall(function()
    return Overlay117Effect.new(tasked, introResources)
  end)
  Assert.equal(ok, false, "tasked trainer routes stay with their intro-task family")
  local worker, workerResources = workerRoute()
  local rival = { role = "rival-transition", assetGroups = worker.assetGroups }
  local rivalOk = pcall(function()
    return Overlay117Effect.new(rival, workerResources)
  end)
  Assert.equal(rivalOk, false, "rival roles stay with their intro-task family")
  local empty = pcall(function()
    return Overlay117Effect.new({ role = "trainer-transition", assetGroups = {} }, {})
  end)
  Assert.equal(empty, false, "trainer routes without a sprite or record group fail closed")
  local effect = startEffect(intro, introResources)
  local doneTicks = 0
  while not effect:stepSourceTick() and doneTicks < 100 do
    doneTicks = doneTicks + 1
  end
  local again = pcall(function()
    return effect:stepSourceTick()
  end)
  Assert.equal(again, false, "completed rocket tasks cannot advance")
  effect:dispose()
end

return { tests = T }
