local Assert = require("tests.support.Assert")
local WildCellOrdersFixture = require("tests.support.WildCellOrdersFixture")
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
    ["wild-cell-orders"] = WildCellOrdersFixture.payload(),
  }
end

local function routeFor(role, timeOfDay)
  local terrain = role == "water-wild-fallback" and "water" or role == "cave-wild-fallback" and "cave" or "plain"
  return {
    key = "fallback/" .. terrain .. "/" .. timeOfDay .. "/wild",
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
      wildCellOrders = "wild-cell-orders",
    },
  }
end

local function effectFor(role, timeOfDay)
  local terrain = role == "water-wild-fallback" and "water" or role == "cave-wild-fallback" and "cave" or "plain"
  local effect = Overlay120FallbackEffect.new(
    routeFor(role, timeOfDay),
    backgroundResources(),
    { kind = "wild", terrain = terrain, timeOfDay = timeOfDay }
  )
  effect:start()
  return effect
end

function T.plain_day_starts_with_flash_and_reveals_in_source_row_order()
  local effect = effectFor("plain-wild-fallback", "day")
  Assert.isNil(effect:frame().wipe, "wild grid has no black cover during initialization")
  effect:stepSourceTick()
  Assert.isNil(effect:frame().wipe, "the first setup tick keeps the field visible")
  local brightness = {}
  for tick = 1, 22 do
    effect:stepSourceTick()
    brightness[tick] = effect:frame().screenBrightness
  end
  Assert.deepEqual(
    brightness,
    { 0, 0, 0, 5, 10, 16, 16, 16, 11, 6, 0, 0, 0, 5, 10, 16, 16, 16, 11, 6, 0, 0 },
    "day flash follows the source task states and duration-three interpolation"
  )
  Assert.equal(effect:frame().sourcePhase, "grid-start", "the flash worker finishes before grid setup")
  effect:stepSourceTick()
  Assert.isNil(effect:frame().wipe, "the retail grid start state leaves the field visible")
  effect:stepSourceTick()
  Assert.equal(effect:frame().wipe.rows[1][1][2], 256, "first running frame leaves the field visible")
  Assert.equal(effect:frame().mosaicStep, 1, "one source grid pair starts per tick")
  Assert.equal(effect:frame().sourceCells[1], 0, "day rows use the source reverse-order table")
  Assert.equal(effect:frame().sourceCells[2], 47, "each source row cell starts with its opposite mirror")
  effect:dispose()
end

function T.cave_day_uses_source_diagonal_pairs_and_finishes_covered()
  local effect = effectFor("cave-wild-fallback", "day")
  effect:stepSourceTick()
  for _ = 1, 22 do
    effect:stepSourceTick()
  end
  effect:stepSourceTick()
  effect:stepSourceTick()
  Assert.equal(effect:frame().sourceCells[1], 0, "day diagonals start at source A index zero")
  Assert.equal(effect:frame().sourceCells[2], 1, "day diagonals use source B order")
  for _ = 1, 26 do
    effect:stepSourceTick()
  end
  Assert.equal(effect:frame().mosaicStep, 24, "diagonal fill starts all source pairs")
  Assert.equal(#effect:frame().wipe.rows, 192, "the diagonal mask covers every native scanline")
  local done = effect:stepSourceTick()
  Assert.isTrue(done, "the completed grid ends the transition")
end

function T.water_wave_publishes_source_hblank_offsets_and_scrolls()
  local effect = effectFor("water-wild-fallback", "day")
  effect:stepSourceTick()
  for _ = 1, 22 do
    effect:stepSourceTick()
  end
  effect:stepSourceTick()
  local frame = effect:frame()
  Assert.equal(frame.family, "wild-wave", "water routes use the wave worker")
  Assert.equal(#frame.scanlineOffsets, 192, "the HBlank wave covers each native scanline")
  Assert.isTrue(frame.backgroundScroll.bg3.y > 0, "water wave advances the source BG3 scroll")
  local hasOffset = false
  for _, offset in ipairs(frame.scanlineOffsets) do
    hasOffset = hasOffset or offset ~= 0
  end
  Assert.isTrue(hasOffset, "source scanline wave produces horizontal offsets")
  local done = false
  for _ = 1, 40 do
    done = effect:stepSourceTick() or done
    if done then
      break
    end
  end
  Assert.isTrue(done, "water scroll completion ends the transition")
end

function T.unknown_roles_and_missing_orders_fail_closed()
  local resources = backgroundResources()
  for _, role in ipairs({ "plain-trainer-fallback", "trainer-transition", "background-transition" }) do
    local ok = pcall(function()
      return Overlay120FallbackEffect.new(
        routeFor(role, "day"),
        resources,
        { kind = "wild", terrain = "plain", timeOfDay = "day" }
      )
    end)
    Assert.equal(ok, false, "role " .. role .. " has no wild transition worker")
  end
  local ok = pcall(function()
    return Overlay120FallbackEffect.new({ key = "fallback/plain/day/wild", role = "plain-wild-fallback" }, resources)
  end)
  Assert.equal(ok, false, "routes without source asset groups fail closed")
  local badKey = pcall(function()
    return Overlay120FallbackEffect.new({
      key = "fallback/plain/morning/wild",
      role = "plain-wild-fallback",
      assetGroups = routeFor("plain-wild-fallback", "day").assetGroups,
    }, resources, { kind = "wild", terrain = "plain", timeOfDay = "morning" })
  end)
  Assert.equal(badKey, false, "routes without a source time of day fail closed")
  local missingOrders = routeFor("plain-wild-fallback", "day")
  missingOrders.assetGroups.wildCellOrders = "missing-orders"
  local missingOk = pcall(function()
    return Overlay120FallbackEffect.new(missingOrders, backgroundResources(), {
      kind = "wild",
      terrain = "plain",
      timeOfDay = "day",
    })
  end)
  Assert.equal(missingOk, false, "routes without staged row/diagonal order data fail closed")
end

return { tests = T }
