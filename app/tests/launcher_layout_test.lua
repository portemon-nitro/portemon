-- Responsive launcher geometry is pure app policy. Real DisplayContext and
-- PixelScale measurements feed one plan shared by hit testing and painting.

local Assert = require("tests.support.Assert")
local DisplayContext = require("libs.ui.src.DisplayContext")

local T = {}

local function editionGames(installed)
  installed = installed or {}
  return {
    { versionId = "heartgold", label = "HeartGold", installed = installed.heartgold == true },
    { versionId = "soulsilver", label = "SoulSilver", installed = installed.soulsilver == true },
  }
end

local function rootView(focusedId)
  return {
    games = editionGames({ heartgold = true }),
    focusedId = focusedId or "heartgold",
    version = "v0.0.0-private-build-with-a-long-version",
    dateText = "31/12/2026",
    timeText = "23:59",
    mode = "selection",
  }
end

local function measurement(width, height, pixelRatio, safeRect)
  safeRect = safeRect or { x = 0, y = 0, width = width, height = height }
  local context = DisplayContext.new({
    graphics = {
      getDimensions = function()
        return width, height
      end,
      getDPIScale = function()
        return pixelRatio or 1
      end,
    },
    topologyProvider = function()
      return {
        surfaces = {
          {
            id = "main",
            role = "world",
            rect = { x = 0, y = 0, width = width, height = height },
            safeRect = safeRect,
            touch = true,
          },
        },
      }
    end,
  })
  return context:measure(width, height)
end

local function assertInside(inner, outer, what)
  Assert.isTrue(inner.width > 0 and inner.height > 0, what .. " has positive area")
  Assert.isTrue(inner.x >= outer.x and inner.y >= outer.y, what .. " starts inside the usable viewport")
  Assert.isTrue(
    inner.x + inner.width <= outer.x + outer.width + 1e-7 and inner.y + inner.height <= outer.y + outer.height + 1e-7,
    what .. " ends inside the usable viewport"
  )
end

local function assertRootPlan(layout, viewport)
  Assert.notNil(layout.header)
  assertInside(layout.header, viewport, "status bar")
  Assert.notNil(layout.slots.heartgold, "HeartGold owns a resolved cartridge slot")
  Assert.notNil(layout.slots.soulsilver, "SoulSilver owns a resolved cartridge slot")
  assertInside(layout.slots.heartgold.rect, viewport, "HeartGold cartridge")
  assertInside(layout.slots.soulsilver.rect, viewport, "SoulSilver cartridge")
  assertInside(layout.slots.heartgold.iconWell, layout.slots.heartgold.rect, "HeartGold icon well")
  assertInside(layout.slots.soulsilver.iconWell, layout.slots.soulsilver.rect, "SoulSilver icon well")
  Assert.isFalse(
    layout.slots.heartgold.rect.y + layout.slots.heartgold.rect.height > layout.slots.soulsilver.rect.y,
    "the two cartridges never overlap"
  )
  Assert.isTrue(
    layout.slots.heartgold.rect.y >= layout.header.y + layout.header.height,
    "cartridges clear the status bar"
  )
  Assert.notNil(layout.graph.targets.heartgold)
  Assert.notNil(layout.graph.targets.soulsilver)
  Assert.isNil(layout.graph.targets["add-game"])
  Assert.isNil(layout.graph.targets.play)
  Assert.isNil(layout.graph.targets.cancel)
  for _, targetId in ipairs({ "heartgold", "soulsilver" }) do
    local target = layout.graph.targets[targetId]
    Assert.equal(target.rect.x, layout.slots[targetId].rect.x)
    Assert.equal(target.rect.y, layout.slots[targetId].rect.y)
    Assert.equal(target.rect.width, layout.slots[targetId].rect.width)
    Assert.equal(target.rect.height, layout.slots[targetId].rect.height)
  end
end

function T.reference_phone_and_desktop_sizes_keep_two_cartridges_and_status_reachable()
  local LauncherLayout = require("app.src.launcher.LauncherLayout")
  local cases = {
    { width = 256, height = 192, ratio = 1 },
    { width = 320, height = 240, ratio = 1 },
    { width = 385, height = 287, ratio = 1 },
    { width = 390, height = 844, ratio = 1 },
    { width = 844, height = 390, ratio = 1 },
    { width = 1280, height = 720, ratio = 1 },
    { width = 385, height = 287, ratio = 3, safeRect = { x = 18, y = 24, width = 349, height = 239 } },
  }
  for _, case in ipairs(cases) do
    local measured = measurement(case.width, case.height, case.ratio, case.safeRect)
    local safeRect = measured.topology.surfaces[1].safeRect
    local surface = LauncherLayout.surface(safeRect, case.ratio)
    Assert.equal(surface.placement.pixelRatio, case.ratio)
    Assert.equal(surface.placement.pixelScale % 1, 0, "physical magnification is integral")
    Assert.isTrue(surface.placement.pixelScale >= 1 and surface.placement.pixelScale <= 3)
    assertInside(surface.placement.frame, safeRect, "physical presentation frame")
    local view = rootView()
    local layout = LauncherLayout.compute(view, surface.placement.logicalWidth, surface.placement.logicalHeight)
    assertRootPlan(layout, layout.viewport)
    for _, targetId in ipairs({ "heartgold", "soulsilver" }) do
      local rect = layout.graph.targets[targetId].rect
      Assert.equal(
        LauncherLayout.hitTest(layout, view, rect.x + rect.width / 2, rect.y + rect.height / 2),
        targetId,
        "hit testing returns the stable semantic action id"
      )
    end
    Assert.isNil(LauncherLayout.hitTest(layout, view, -10, -10), "outside geometry has no target")
  end
end

function T.choose_receipt_and_error_plans_expose_only_their_current_actions()
  local LauncherLayout = require("app.src.launcher.LauncherLayout")
  local cases = {
    {
      mode = "choose",
      expected = { "choose-rom", "back" },
      receipt = nil,
      canCancel = true,
    },
    {
      mode = "receipt",
      expected = { "cancel", "back" },
      receipt = "A very long selected ROM filename that must remain inside the compact receipt row.nds",
      canCancel = true,
    },
    {
      mode = "importing",
      expected = { "cancel" },
      receipt = "SoulSilver.nds",
      canCancel = true,
      progress = nil,
    },
    {
      mode = "importing",
      expected = {},
      receipt = "SoulSilver.nds",
      canCancel = false,
      progress = 0.9,
    },
    {
      mode = "error",
      expected = { "retry", "back" },
      error = "Expected SoulSilver; detected HeartGold",
      pickerAvailable = false,
      canCancel = false,
    },
  }
  for _, case in ipairs(cases) do
    local view = rootView("soulsilver")
    view.mode = case.mode
    view.import = {
      attemptId = "geometry-attempt",
      mode = case.mode,
      expectedVersionId = "soulsilver",
      receipt = case.receipt,
      statusText = case.mode == "importing" and "Saving ROM" or "Waiting for readers",
      progress = case.progress,
      canCancel = case.canCancel,
      pickerAvailable = case.pickerAvailable ~= false,
      error = case.error,
    }
    local layout = LauncherLayout.compute(view, 256, 192)
    Assert.isNil(layout.graph.targets.heartgold, "root cartridges are absent during an operation")
    Assert.isNil(layout.graph.targets.soulsilver, "root cartridges are absent during an operation")
    local expected = {}
    for _, targetId in ipairs(case.expected) do
      expected[targetId] = true
      local target = assert(layout.graph.targets[targetId], case.mode .. " exposes " .. targetId)
      assertInside(target.rect, layout.viewport, targetId)
    end
    for targetId in pairs(layout.graph.targets) do
      Assert.isTrue(expected[targetId], "unexpected action in " .. case.mode .. ": " .. targetId)
    end
    if case.receipt ~= nil then
      Assert.notNil(layout.receiptRect, "the receipt owns measured visible geometry")
      assertInside(layout.receiptRect, layout.viewport, "receipt")
      Assert.isTrue(layout.receiptRect.height > 0)
    end
  end
end

function T.neutral_loading_has_a_prompt_but_operation_loading_owns_real_cancel()
  local LauncherLayout = require("app.src.launcher.LauncherLayout")
  local neutral = LauncherLayout.loading(256, 192, { selectionInterrupt = true })
  Assert.notNil(neutral.promptRect)
  assertInside(neutral.promptRect, neutral.viewport, "selection prompt")
  Assert.isNil(neutral.cancelRect, "pre-movie selection is not a fake operation Cancel")
  Assert.isNil(neutral.graph.targets.cancel)

  local operation = LauncherLayout.loading(256, 192, {
    selectionInterrupt = false,
    receipt = "SoulSilver.nds",
    statusText = "Waiting for readers",
    canCancel = true,
  })
  Assert.notNil(operation.receiptRect)
  Assert.notNil(operation.cancelRect)
  assertInside(operation.receiptRect, operation.viewport, "operation receipt")
  assertInside(operation.cancelRect, operation.viewport, "operation Cancel")
  Assert.notNil(operation.graph.targets.cancel)
end

function T.unusable_tiny_geometry_suspends_instead_of_fabricating_one_pixel_actions()
  local LauncherLayout = require("app.src.launcher.LauncherLayout")
  local layout = LauncherLayout.compute(rootView(), 12, 8)
  Assert.isTrue(layout.unavailable == true, "tiny host geometry is explicitly noninteractive")
  Assert.isNil(next(layout.graph.targets), "no fake one-pixel cartridge is published")
  Assert.isNil(LauncherLayout.hitTest(layout, rootView(), 1, 1))
end

return { tests = T }
