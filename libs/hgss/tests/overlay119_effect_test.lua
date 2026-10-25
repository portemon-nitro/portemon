local Assert = require("tests.support.Assert")
local Overlay119Effect = require("libs.hgss.src.transition.battle.Overlay119Effect")

local T = {}

local function spriteResources()
  return {
    ["wipe-palette"] = { colors = { { r = 0, g = 0, b = 0 }, { r = 240, g = 220, b = 40 } } },
    ["wipe-character"] = { depth = 3, tiles = string.rep(string.char(0x11), 32) },
    ["wipe-cell"] = {
      cells = { { objs = { { tile = 0, width = 8, height = 8, x = -4, y = -4, palette = 0 } } } },
    },
    ["wipe-animation"] = {
      anims = {
        {
          frames = {
            { cell = 0, duration = 1, translateX = 0, translateY = 0, scaleX = 1, scaleY = 1, rotation = 0 },
            { cell = 0, duration = 2, translateX = 0, translateY = 0, scaleX = 1, scaleY = 1, rotation = 0 },
          },
        },
      },
    },
  }
end

local function routeFor(role)
  return {
    key = "fallback/plain/day/trainer",
    role = role,
    assetGroups = {
      sprite = {
        palette = "wipe-palette",
        character = "wipe-character",
        cell = "wipe-cell",
        animation = "wipe-animation",
      },
    },
  }
end

local function effectFor(role)
  local effect = Overlay119Effect.new(routeFor(role), spriteResources())
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

function T.trainer_fallback_roles_share_the_eight_phase_affine_wipe_worker()
  for _, role in ipairs({ "plain-trainer-fallback", "water-trainer-fallback", "cave-trainer-fallback" }) do
    local effect = effectFor(role)
    Assert.equal(effect:stepSourceTick(), false, role .. " initializes with planes on")
    Assert.isTrue(effect:frame().planesEnabled, role .. " enables engine-A planes at phase zero")
    Assert.equal(effect:frame().sourcePhase, 1, role .. " arms its cover wait")
    stepTo(effect, 3, 30)
    Assert.equal(effect:frame().sourcePhase, 3, role .. " runs its wipe after the cover wait")
    Assert.equal(#effect:frame().sprites, 2, role .. " drives exactly two affine wipe sprites")
    local ticks = 0
    while not effect:stepSourceTick() and ticks < 100 do
      ticks = ticks + 1
    end
    Assert.equal(effect._sourcePhase, 7, role .. " reaches its terminal cleanup state")
    Assert.equal(#effect._sprites, 0, role .. " releases its wipe sprites at completion")
    Assert.isNil(effect._resources, role .. " releases its route resources at completion")
    effect:dispose()
  end
end

function T.cover_wait_arms_the_shared_eight_and_three_counts()
  local effect = effectFor("plain-trainer-fallback")
  effect:stepSourceTick()
  effect:stepSourceTick()
  Assert.equal(effect:frame().sourcePhase, 2, "cover wait steps from its armed state")
  for _ = 1, 7 do
    effect:stepSourceTick()
    Assert.equal(effect:frame().sourcePhase, 2, "cover holds through the opening arm count")
  end
  effect:stepSourceTick()
  Assert.equal(effect:frame().coverWait.stage, 1, "opening arm hands to the reverse count")
  for _ = 1, 2 do
    effect:stepSourceTick()
    Assert.equal(effect:frame().sourcePhase, 2, "cover holds through the reverse count")
  end
  effect:stepSourceTick()
  Assert.equal(effect:frame().sourcePhase, 3, "cover completion releases the wipe")
  Assert.isNil(effect:frame().coverWait, "released cover keeps no wait state")
  effect:dispose()
end

function T.two_stage_fade_reports_its_raw_words_and_drives_blend_and_sweep()
  local effect = effectFor("water-trainer-fallback")
  stepTo(effect, 3, 30)
  effect:stepSourceTick()
  Assert.deepEqual(
    effect:frame().paletteFade.args,
    { 8, 1, 4, 0, 3, 0x18 },
    "opening fade reports its raw native words"
  )
  local firstLeft = effect:frame().sprites[1].position.x
  local firstRight = effect:frame().sprites[2].position.x
  Assert.isTrue(effect:frame().sprites[1].visible, "wipe sprites show with the opening fade")
  Assert.equal(effect:frame().blendAlpha, 2, "blend follows opening fade progress")
  for _ = 1, 7 do
    effect:stepSourceTick()
  end
  Assert.equal(effect:frame().sourcePhase, 4, "opening fade completes on its raw first word")
  Assert.equal(effect:frame().blendAlpha, 16, "blend reaches its native coefficient with the opening fade")
  Assert.isTrue(effect:frame().sprites[1].position.x > firstLeft, "leading wipe sprite advances across the field")
  Assert.isTrue(effect:frame().sprites[2].position.x < firstRight, "trailing wipe sprite advances across the field")
  effect:stepSourceTick()
  Assert.equal(effect:frame().sourcePhase, 5, "brightness handoff separates the two fade stages")
  Assert.equal(effect:frame().brightness, 16, "brightness peaks between the fade stages")
  effect:stepSourceTick()
  Assert.deepEqual(
    effect:frame().paletteFade.args,
    { 8, 1, 4, 0, 3, 0x12 },
    "closing fade reports its raw native words"
  )
  stepTo(effect, 6, 20)
  Assert.equal(effect:frame().brightness, 0, "brightness settles with the closing fade")
  Assert.isTrue(
    effect:frame().sprites[1].position.x > firstLeft,
    "wipe sweep completes monotonically through both stages"
  )
  effect:dispose()
end

function T.sprites_animate_every_tick_and_upload_exactly_once()
  local effect = Overlay119Effect.new(routeFor("cave-trainer-fallback"), spriteResources())
  local ok = pcall(function()
    return effect:stepSourceTick()
  end)
  Assert.equal(ok, false, "the wipe task advances only after start")
  effect:prepareGraphics(love.graphics)
  local prepared = pcall(function()
    effect:prepareGraphics(love.graphics)
  end)
  Assert.equal(prepared, false, "sprite images upload exactly once")
  effect:start()
  stepTo(effect, 3, 30)
  local firstHandle = effect:frame().sprites[1].imageHandle
  Assert.notNil(firstHandle, "visible wipe sprites carry uploaded GPU images")
  local firstIndex = effect:frame().sprites[1].frameIndex
  effect:stepSourceTick()
  effect:stepSourceTick()
  Assert.isTrue(
    effect:frame().sprites[1].frameIndex ~= firstIndex,
    "wipe sprites animate on the native tail every tick"
  )
  effect:dispose()
end

function T.unknown_roles_and_missing_sprite_groups_fail_closed()
  local resources = spriteResources()
  for _, role in ipairs({ "generic-trainer-transition", "trainer-transition", "plain-wild-fallback" }) do
    local ok = pcall(function()
      return Overlay119Effect.new(
        { role = role, assetGroups = routeFor("plain-trainer-fallback").assetGroups },
        resources
      )
    end)
    Assert.equal(ok, false, "role " .. role .. " has no affine-wipe fallback worker")
  end
  local ok = pcall(function()
    return Overlay119Effect.new({ role = "plain-trainer-fallback", assetGroups = {} }, resources)
  end)
  Assert.equal(ok, false, "fallback routes without a sprite group fail closed")
  local effect = effectFor("plain-trainer-fallback")
  local ticks = 0
  while not effect:stepSourceTick() and ticks < 100 do
    ticks = ticks + 1
  end
  local again = pcall(function()
    return effect:stepSourceTick()
  end)
  Assert.equal(again, false, "completed wipe tasks cannot advance")
  effect:dispose()
end

return { tests = T }
