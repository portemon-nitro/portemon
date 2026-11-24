-- Responsive launcher geometry is pure app policy. These cases use real
-- DisplayContext measurements and synthetic catalog rows; no renderer or
-- storage owner is faked.

local Assert = require("tests.support.Assert")
local DisplayContext = require("libs.ui.src.DisplayContext")
local PixelScale = require("libs.ui.src.PixelScale")

local T = {}

local function entries(count)
  local games = {}
  for index = 1, count do
    games[#games + 1] = {
      gameId = string.format("game-%02d", index),
      versionId = string.format("game-%02d", index),
      label = string.format("Game %02d", index),
      ready = true,
      hasSave = index % 2 == 0,
    }
  end
  return games
end

local function view(count, focusedId)
  return {
    games = entries(count),
    focusedId = focusedId or "game-01",
    scrollOffset = 0,
    status = nil,
    modal = nil,
    version = "dev",
  }
end

local function measurement(width, height, pixelRatio, safeRect)
  local graphics = {
    getDimensions = function()
      return width, height
    end,
    getDPIScale = function()
      return pixelRatio or 1
    end,
  }
  local context = DisplayContext.new({
    graphics = graphics,
    topologyProvider = function()
      local rect = { x = 0, y = 0, width = width, height = height }
      return {
        surfaces = {
          {
            id = "main",
            role = "world",
            rect = rect,
            safeRect = safeRect or rect,
            touch = true,
          },
        },
      }
    end,
  })
  return context:measure(width, height)
end

local function assertInside(inner, outer, what)
  Assert.isTrue(inner.x >= outer.x and inner.y >= outer.y, what .. " starts inside the usable viewport")
  Assert.isTrue(
    inner.x + inner.width <= outer.x + outer.width and inner.y + inner.height <= outer.y + outer.height,
    what .. " ends inside the usable viewport"
  )
end

function T.tall_wide_compact_and_dpi_views_keep_rows_and_actions_reachable()
  local LauncherLayout = require("app.src.launcher.LauncherLayout")
  local cases = {
    { width = 320, height = 240, count = 1 },
    { width = 360, height = 640, count = 2 },
    { width = 390, height = 844, count = 8 },
    { width = 844, height = 390, count = 20 },
    { width = 1280, height = 720, count = 20 },
    { width = 240, height = 320, count = 20 },
    {
      width = 1280,
      height = 720,
      count = 20,
      pixelRatio = 3,
      safeRect = { x = 24, y = 36, width = 1200, height = 636 },
    },
  }
  for _, case in ipairs(cases) do
    local measured = measurement(case.width, case.height, case.pixelRatio, case.safeRect)
    local safeRect = measured.topology.surfaces[1].safeRect
    local pixelScale = math.max(1, math.min(3, math.floor(math.min(case.width / 320, case.height / 240))))
    local surface = PixelScale.cover(safeRect, pixelScale, case.pixelRatio or 1)
    assertInside(surface.placement.frame, safeRect, "physical presentation frame")
    local logicalWidth = surface.placement.logicalWidth
    local logicalHeight = surface.placement.logicalHeight
    local focusedId = string.format("game-%02d", case.count)
    local layout = LauncherLayout.compute(view(case.count, focusedId), logicalWidth, logicalHeight)
    local usable = { x = 0, y = 0, width = logicalWidth, height = logicalHeight }
    Assert.isTrue(usable.width > 0 and usable.height > 0, "every host size resolves a usable logical viewport")
    assertInside(layout.header, usable, "header")
    assertInside(layout.summary, usable, "summary")
    assertInside(layout.list.viewport, usable, "list viewport")
    assertInside(layout.actions.addGame, usable, "Add game")
    assertInside(layout.actions.play, usable, "Play")
    Assert.isTrue(
      layout.list.viewport.y + layout.list.viewport.height <= math.min(layout.actions.addGame.y, layout.actions.play.y),
      "the scrollable list never renders behind the footer actions"
    )
    Assert.isTrue(layout.actions.addGame.height >= 44, "ordinary action targets stay at least 44 logical pixels")
    Assert.isTrue(layout.actions.play.height >= 44, "ordinary action targets stay at least 44 logical pixels")
    Assert.isTrue(#layout.list.rows == case.count, "every synthetic row resolves geometry")
    if case.count == 20 then
      Assert.isTrue(layout.scroll.maxOffset > 0, "the twenty-entry fixture exercises scrolling")
    end
    local focused = assert(layout.list.rows[focusedId], "the focused semantic id survives reflow")
    Assert.isTrue(
      focused.y >= layout.list.viewport.y
        and focused.y + focused.height <= layout.list.viewport.y + layout.list.viewport.height,
      "scrolling reveals the focused row instead of hiding it behind the footer"
    )
  end
end

function T.wide_layout_uses_the_locked_column_width_and_tiny_layout_removes_decoration_first()
  local LauncherLayout = require("app.src.launcher.LauncherLayout")
  local wide = LauncherLayout.compute(view(8), 844, 390)
  Assert.equal(wide.summary.width, 208, "the wide summary keeps its 208-pixel column")
  Assert.isTrue(wide.list.viewport.x >= wide.summary.x + wide.summary.width + 12, "wide columns keep the 12-pixel gap")

  local tiny = LauncherLayout.compute(view(8), 240, 320)
  for _, row in pairs(tiny.list.rows) do
    Assert.isFalse(row.hasCartridgeMarker, "sub-280 widths remove cartridge decoration before actions")
  end
  Assert.isTrue(tiny.summary.height <= 96, "the tall summary never consumes the list without bound")
end

function T.import_status_reserves_space_above_the_scrollable_rows()
  local LauncherLayout = require("app.src.launcher.LauncherLayout")
  local snapshot = view(2)
  snapshot.status = "File received heartgold.nds"
  snapshot.canCancel = true
  local layout = LauncherLayout.compute(snapshot, 390, 844)
  local status = assert(layout.statusRect, "import status owns a resolved row")
  local cancel = assert(layout.cancelRect, "cancellable status owns a Cancel target")
  Assert.equal(status.height, 44, "the status row reserves a full touch target")
  Assert.equal(cancel.height, 44)
  assertInside(cancel, status, "Cancel")
  Assert.equal(layout.list.viewport.y, status.y + status.height, "rows begin below the status row")
  Assert.isTrue(layout.list.rows["game-01"].y >= layout.list.viewport.y)
  Assert.notNil(layout.graph.targets.cancel, "Cancel is reachable in the semantic focus graph")
end

function T.neutral_loading_reserves_the_shared_cancel_target_before_its_content()
  local LauncherLayout = require("app.src.launcher.LauncherLayout")
  local layout = LauncherLayout.loading(390, 844)
  local cancel = assert(layout.cancelRect, "neutral loading resolves the shared Cancel target")
  Assert.equal(cancel.height, 44)
  Assert.isTrue(layout.content.y + layout.content.height <= cancel.y, "loading content never renders under Cancel")
  Assert.notNil(layout.graph.targets.cancel, "loading Cancel is a semantic focus target")
end

function T.hit_testing_uses_the_same_resolved_rows_and_modal_consumes_the_backdrop()
  local LauncherLayout = require("app.src.launcher.LauncherLayout")
  local layout = LauncherLayout.compute(view(8, "game-03"), 390, 844)
  local row = assert(layout.list.rows["game-03"])
  local hit = LauncherLayout.hitTest(layout, view(8, "game-03"), row.x + row.width / 2, row.y + row.height / 2)
  Assert.equal(hit.kind, "game", "row presses resolve to the semantic game target")
  Assert.equal(hit.gameId, "game-03")

  local modalView = view(8, "game-03")
  modalView.modal = { kind = "error" }
  local modalLayout = LauncherLayout.compute(modalView, 390, 844)
  local blocked = LauncherLayout.hitTest(modalLayout, modalView, row.x + row.width / 2, row.y + row.height / 2)
  Assert.equal(blocked.kind, "modal-backdrop", "an open modal consumes input without click-through")
end

return { tests = T }
