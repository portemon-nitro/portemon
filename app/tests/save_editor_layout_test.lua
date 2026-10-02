-- The Location section retains reachable navigation and shared logical geometry.

local Assert = require("tests.support.Assert")
local Controller = require("app.src.saveeditor.SaveEditorController")
local Layout = require("app.src.saveeditor.SaveEditorLayout")

local T = { tests = {} }
local function computeLayout(view, width, height)
  return Layout.compute(view, width, height, { lineHeight = 14, measure = function(text) return #text * 7 end })
end

local function locationView()
  return {
    status = "ready",
    ready = true,
    dirty = false,
    section = "Location",
    session = {
      saveId = "layout-save",
      versionId = "heartgold",
      playerName = "PLAYER",
      money = 3000,
      location = {
        mapId = 12,
        fieldX = 32,
        fieldZ = 48,
        surfaceId = 3,
        worldY = 0,
        terrainDependencyHash = "location-layout",
      },
    },
    location = {
      mapId = 12,
      symbol = "MAP_TEST_ROUTE",
      section = "TEST_SECTION",
      maps = { { mapId = 12, symbol = "MAP_TEST_ROUTE", section = "TEST_SECTION" } },
      generation = 1,
      status = { state = "ready" },
      tiles = {
        { fieldX = 32, fieldZ = 48, selectable = true },
        { fieldX = 33, fieldZ = 48, selectable = false, reason = "blocked" },
      },
      cursor = { fieldX = 33, fieldZ = 48 },
      scale = 24,
    },
    locationNavigation = {
      page = "grid",
      mapId = 12,
      cursor = { fieldX = 33, fieldZ = 48 },
      center = { fieldX = 32, fieldZ = 48 },
      scale = 24,
      mapOffset = 0,
    },
  }
end

function T.tests.location_section_is_controller_reachable_and_keeps_footer_targets_visible()
  local controller = Controller.new()
  controller:setSection("Location")
  Assert.equal(controller:snapshot().section, "Location", "the Location section is reachable through editor navigation")

  for _, viewport in ipairs({
    { width = 256, height = 192 },
    { width = 640, height = 480 },
    { width = 360, height = 640 },
    { width = 1280, height = 720 },
  }) do
    local view = locationView()
    local layout = computeLayout(view, viewport.width, viewport.height)
    for _, targetId in ipairs({ "save", "discard", "back" }) do
      local target = assert(layout.targets[targetId], "Location must retain the " .. targetId .. " action")
      local rect = target.rect
      Assert.isTrue(rect.x >= 0 and rect.y >= 0, "footer actions stay inside the logical viewport")
      Assert.isTrue(rect.x + rect.width <= viewport.width, "footer action fits the measured width")
      Assert.isTrue(rect.y + rect.height <= viewport.height, "footer action fits the measured height")
    end
  end
end

function T.tests.naming_keyboard_rows_do_not_overlap_the_footer_cancel_target()
  for _, viewport in ipairs({
    { width = 256, height = 192 },
    { width = 640, height = 480 },
  }) do
    local view = locationView()
    view.valueEditor = {
      kind = "name",
      naming = { controls = { { id = "lower", firstColumn = 1, lastColumn = 1 } } },
    }
    local layout = computeLayout(view, viewport.width, viewport.height)
    local cancel = assert(layout.targets.cancel)
    cancel = cancel.rect
    for row = 1, 6 do
      for column = 1, 13 do
        local key = assert(layout.targets[row .. ":" .. column])
        key = key.rect
        local overlaps =
          key.x < cancel.x + cancel.width
          and cancel.x < key.x + key.width
          and key.y < cancel.y + cancel.height
          and cancel.y < key.y + key.height
        Assert.isFalse(overlaps, "name key " .. row .. ":" .. column .. " must not overlap Cancel")
      end
    end
  end
end

function T.tests.location_navigation_uses_transient_cursor_zoom_and_matched_pointer_activation()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 12, fieldX = 32, fieldZ = 48 })
  controller:moveLocationCursor("down", 5, 3)
  local inspected = controller:locationSnapshot()
  Assert.equal(inspected.cursor.fieldX, 32)
  Assert.equal(inspected.cursor.fieldZ, 49, "D-pad inspects adjacent tiles without selecting them")
  Assert.equal(inspected.center.fieldZ, 48, "cursor remains visible without moving the viewport early")
  controller:zoomLocation(1)
  Assert.equal(controller:locationSnapshot().scale, 32, "zoom uses the explicit larger scale step")
  controller:zoomLocation(1)
  Assert.equal(controller:locationSnapshot().scale, 32, "zoom clamps at the largest supported scale")
  controller:zoomLocation(-1)
  Assert.equal(controller:locationSnapshot().scale, 24, "zoom returns to the middle scale step")

  controller:openLocationMaps()
  local back = controller:press("back")
  Assert.equal(back.kind, "location-page", "Back returns from map browsing to the current grid")
  Assert.equal(controller:locationSnapshot().mapId, 12, "map browsing does not change the destination map")

  controller:setFocus("location:tile:35:49")
  local keyboard = controller:press("confirm")
  Assert.equal(keyboard.kind, "select_tile")
  Assert.equal(keyboard.fieldX, 35)
  Assert.equal(keyboard.fieldZ, 49)
  controller:setFocus("location:map-picker")
  local pointerTarget = "location:tile:35:49"
  controller:pointer({ type = "pointer_down", pointerId = "touch:1", targetId = pointerTarget, x = 100, y = 100 })
  local pointer = controller:pointer({ type = "pointer_up", pointerId = "touch:1", targetId = pointerTarget, x = 100, y = 100 })
  Assert.equal(pointer.kind, keyboard.kind, "pointer and controller activation share one tile intent")
  Assert.equal(pointer.fieldX, keyboard.fieldX)
  Assert.equal(pointer.fieldZ, keyboard.fieldZ)

  controller:pointer({
    type = "pointer_down",
    pointerId = "touch:2",
    targetId = pointerTarget,
    x = 100,
    y = 100,
    grid = { tileSize = 24 },
  })
  controller:pointer({
    type = "pointer_move",
    pointerId = "touch:2",
    x = 148,
    y = 100,
    grid = { tileSize = 24 },
  })
  local pan = controller:pointer({
    type = "pointer_up",
    pointerId = "touch:2",
    targetId = pointerTarget,
    x = 148,
    y = 100,
    grid = { tileSize = 24 },
  })
  Assert.equal(pan.kind, "location-pan", "drag pans the view instead of selecting a trail of tiles")
  Assert.equal(controller:locationSnapshot().cursor.fieldX, 35, "panning does not replace the inspected tile")
end

function T.tests.player_rows_reserve_measured_raw_value_width_in_a_separate_text_cell()
  local view = {
    status = "ready",
    ready = true,
    section = "Player",
    scope = { id = "section:Player", epoch = 0 },
    session = { playerName = "PLAYER", money = 4294967295 },
  }
  local metrics = {
    lineHeight = 12,
    measure = function(text)
      local width = 0
      for glyph in text:gmatch(".") do
        width = width + (glyph:match("%d") and 9 or 5)
      end
      return width
    end,
  }
  local layout = Layout.compute(view, 256, 192, metrics)
  local row = nil
  for _, candidate in ipairs(layout.rows) do
    if candidate.targetId == "money" then
      row = candidate
      break
    end
  end
  row = assert(row, "the Player layout contains the raw money value")

  Assert.isTrue(row.valueRect.width >= metrics.measure(tostring(view.session.money)))
  Assert.isTrue(row.labelRect.x + row.labelRect.width < row.valueRect.x, "label and raw value have separate cells")
  Assert.isTrue(
    row.valueRect.x + row.valueRect.width <= layout.targets.money.rect.x + layout.targets.money.rect.width,
    "the measured value cell remains inside the row target"
  )

  view.focus = "money"
  metrics.measure = function(text)
    local digits = 0
    for glyph in text:gmatch(".") do
      digits = digits + (glyph:match("%d") and 30 or 20)
    end
    return digits
  end
  layout = Layout.compute(view, 256, 192, metrics)
  Assert.equal(layout.focusedValueHelp, "Money: 4294967295", "the full value stays visible when the row must truncate it")
end

return T
