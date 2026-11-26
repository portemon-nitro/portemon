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

local function assertDisjoint(inner, outer, what, otherWhat)
  Assert.isTrue(
    inner.y + inner.height <= outer.y
      or outer.y + outer.height <= inner.y
      or inner.x + inner.width <= outer.x
      or outer.x + outer.width <= inner.x,
    what .. " stays clear of " .. otherWhat
  )
end

local function measuredFont(height, widthPerCharacter)
  local font = { height = height, widthPerCharacter = widthPerCharacter }
  function font:getHeight()
    return self.height
  end
  function font:getWidth(text)
    return #tostring(text) * self.widthPerCharacter
  end
  return font
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

function T.neutral_error_region_follows_the_centered_block_and_clears_the_prompt()
  local LauncherLayout = require("app.src.launcher.LauncherLayout")
  local cases = {
    { width = 256, height = 192, body = 12, prompt = 10, label = "Pokémon SoulSilver" },
    { width = 320, height = 240, body = 12, prompt = 10, label = "Pokémon HeartGold" },
    {
      width = 390,
      height = 844,
      body = 14,
      prompt = 11,
      label = "Pokémon SoulSilver with an unusually long edition title",
    },
  }
  for _, case in ipairs(cases) do
    local fonts = { body = measuredFont(case.body, 8), prompt = measuredFont(case.prompt, 6) }
    local options = {
      selectionInterrupt = true,
      gameLabel = case.label,
      error = "Cache read failed",
      detail = "Card unreadable",
      fonts = fonts,
    }
    local plan = LauncherLayout.loading(case.width, case.height, options)
    local region = assert(plan.errorRect, "a neutral failure owns a measured diagnostic region")
    assertInside(region, plan.content, "neutral diagnostic")
    for _, part in ipairs({ plan.titleRect, plan.loadingStatusRect, plan.indicatorRect }) do
      assertDisjoint(region, part, "neutral diagnostic", "the centered title/status/indicator block")
    end
    local blockBottom = plan.indicatorRect.y + plan.indicatorRect.height
    Assert.isTrue(
      region.y >= blockBottom and region.y - blockBottom <= 8,
      "the diagnostic starts immediately below the finalized block"
    )
    Assert.isTrue(
      region.y + region.height <= plan.promptRect.y,
      "the diagnostic stays above the reserved bottom-right prompt"
    )
    Assert.isTrue(region.height >= case.body * 2, "the diagnostic region fits actionable copy")

    options.error = nil
    Assert.isNil(
      LauncherLayout.loading(case.width, case.height, options).errorRect,
      "a quiet loader reserves no diagnostic"
    )
  end

  local operation = LauncherLayout.loading(256, 192, { selectionInterrupt = false, error = "Import failed" })
  Assert.notNil(operation.errorRect, "operation loading keeps its own diagnostic region")
  Assert.equal(operation.errorRect.y, 8 + 96, "operation diagnostic placement is unchanged")
end

function T.compact_cartridges_fit_full_edition_names_and_measured_status_rows()
  local LauncherLayout = require("app.src.launcher.LauncherLayout")
  local view = rootView("heartgold")
  view.games[1].label = "Pokémon HeartGold"
  view.games[2].label = "Pokémon SoulSilver"
  view.fonts = {
    body = measuredFont(10, 8),
    bold = measuredFont(11, 9),
    prompt = measuredFont(10, 6),
  }
  local layout = LauncherLayout.compute(view, 256, 192)
  local slot = assert(layout.slots.heartgold)
  Assert.isTrue(
    slot.rect.width >= 196 and slot.rect.width <= 212,
    "a native-width cartridge stays compact: " .. tostring(slot.rect.width)
  )
  Assert.isTrue(
    slot.rect.height >= 44 and slot.rect.height <= 50,
    "a native-width cartridge stays a shallow row: " .. tostring(slot.rect.height)
  )
  Assert.isTrue(
    slot.iconWell.width >= 44 and slot.iconWell.width <= 48,
    "the icon owns a distinct full-height compartment: " .. tostring(slot.iconWell.width)
  )
  Assert.isTrue(slot.iconWell.height >= slot.rect.height - 4, "the icon compartment fills the cartridge height")
  Assert.isTrue(
    view.fonts.body:getWidth(view.games[1].label) <= slot.textRect.width,
    "the full edition name fits its measured text compartment"
  )
  Assert.isTrue(
    view.fonts.body:getWidth(view.games[2].label) <= assert(layout.slots.soulsilver).textRect.width,
    "both full edition names fit without shortening"
  )
  for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
    assertInside(layout.slots[versionId].focusRect, layout.viewport, versionId .. " focus clearance")
  end
  local wide = LauncherLayout.compute(view, 764, 575)
  Assert.isTrue(wide.header.height <= 22, "a normal-width status strip is a compact row")
  Assert.isTrue(wide.header.width == 764, "the status strip spans its viewport")
end

function T.status_cells_measure_date_and_time_with_the_painted_prompt_face()
  local LauncherLayout = require("app.src.launcher.LauncherLayout")
  local view = rootView()
  view.version = "v1"
  view.fonts = {
    body = measuredFont(10, 4),
    bold = measuredFont(14, 9),
    prompt = measuredFont(10, 6),
  }
  local layout = LauncherLayout.compute(view, 256, 192)
  local cells = layout.headerCells
  Assert.equal(cells.date.width, view.fonts.prompt:getWidth(view.dateText) + 16, "the date cell measures the prompt face")
  Assert.equal(cells.time.width, view.fonts.prompt:getWidth(view.timeText) + 16, "the time cell measures the prompt face")
end

function T.loading_prompt_geometry_uses_the_supplied_face_metrics()
  local LauncherLayout = require("app.src.launcher.LauncherLayout")
  local plan = LauncherLayout.loading(256, 192, {
    selectionInterrupt = true,
    fonts = { prompt = measuredFont(10, 6) },
  })
  local prompt = assert(plan.promptRect)
  Assert.equal(prompt.height, 10, "the prompt reserves its actual font height")
  Assert.equal(prompt.x + prompt.width, 248, "the prompt keeps the right inset")
  Assert.equal(prompt.y + prompt.height, 184, "the prompt keeps the bottom inset")
end

function T.unusable_tiny_geometry_suspends_instead_of_fabricating_one_pixel_actions()
  local LauncherLayout = require("app.src.launcher.LauncherLayout")
  local layout = LauncherLayout.compute(rootView(), 12, 8)
  Assert.isTrue(layout.unavailable == true, "tiny host geometry is explicitly noninteractive")
  Assert.isNil(next(layout.graph.targets), "no fake one-pixel cartridge is published")
  Assert.isNil(LauncherLayout.hitTest(layout, rootView(), 1, 1))
end

function T.status_bar_clusters_time_date_and_version_on_the_right_with_the_prompt_face()
  local LauncherLayout = require("app.src.launcher.LauncherLayout")
  local view = rootView()
  view.version = "v1"
  view.fonts = {
    body = measuredFont(10, 8),
    bold = measuredFont(14, 9),
    prompt = measuredFont(10, 4),
  }
  local layout = LauncherLayout.compute(view, 256, 192)
  local cells = layout.headerCells
  Assert.isTrue(cells.time.x < cells.date.x, "time precedes date left-to-right")
  Assert.isTrue(cells.date.x < cells.version.x, "date precedes version left-to-right")
  Assert.equal(
    cells.version.x + cells.version.width,
    256,
    "the status cluster ends at the right edge"
  )
  Assert.isTrue(cells.time.x > 8, "the left side stays reserved for future features")
  Assert.equal(
    cells.time.width,
    view.fonts.prompt:getWidth(view.timeText) + 16,
    "the time cell measures the smaller prompt face"
  )
  Assert.equal(
    cells.date.width,
    view.fonts.prompt:getWidth(view.dateText) + 16,
    "the date cell measures the smaller prompt face"
  )
end

function T.back_action_is_a_compact_trailing_button()
  local LauncherLayout = require("app.src.launcher.LauncherLayout")
  local view = rootView("soulsilver")
  view.mode = "choose"
  view.import = {
    attemptId = "geometry-attempt",
    mode = "choose",
    expectedVersionId = "soulsilver",
    pickerAvailable = true,
    canCancel = true,
  }
  local layout = LauncherLayout.compute(view, 256, 192)
  local back = assert(layout.graph.targets.back, "choose exposes back")
  local primary = assert(layout.graph.targets["choose-rom"], "choose exposes its primary action")
  Assert.isTrue(back.rect.width <= 64, "back stays compact: " .. tostring(back.rect.width))
  Assert.isTrue(primary.rect.width > back.rect.width, "the primary action keeps the remaining width")
  Assert.equal(back.rect.x + back.rect.width, layout.viewport.width - 8, "back trails at the right inset")

  view.import.pickerAvailable = false
  local single = LauncherLayout.compute(view, 256, 192)
  local lone = assert(single.graph.targets.back, "a lone back is still exposed")
  Assert.isTrue(lone.rect.width <= 64, "a lone back never stretches full width")
  Assert.equal(lone.rect.x + lone.rect.width, single.viewport.width - 8, "a lone back trails at the right inset")

  view.mode = "error"
  view.import = {
    attemptId = "geometry-attempt",
    mode = "error",
    expectedVersionId = "soulsilver",
    pickerAvailable = false,
    canCancel = false,
    error = "Expected SoulSilver; detected HeartGold",
  }
  local failed = LauncherLayout.compute(view, 256, 192)
  local retry = assert(failed.graph.targets.retry, "error exposes retry")
  local retreat = assert(failed.graph.targets.back, "error exposes back")
  Assert.isTrue(retreat.rect.width <= 64, "error back stays compact")
  Assert.isTrue(retry.rect.width > retreat.rect.width, "retry keeps the remaining width")
  Assert.equal(
    retreat.rect.x + retreat.rect.width,
    failed.viewport.width - 8,
    "error back trails at the right inset"
  )
end

return { tests = T }
