-- The Location section retains reachable navigation and shared logical geometry.

local Assert = require("tests.support.Assert")
local Controller = require("app.src.saveeditor.SaveEditorController")
local Layout = require("app.src.saveeditor.SaveEditorLayout")

local T = { tests = {} }

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
    local layout = Layout.compute(view, viewport.width, viewport.height)
    for _, targetId in ipairs({ "save", "discard", "back" }) do
      local target = assert(layout.targets[targetId], "Location must retain the " .. targetId .. " action")
      Assert.isTrue(target.x >= 0 and target.y >= 0, "footer actions stay inside the logical viewport")
      Assert.isTrue(target.x + target.width <= viewport.width, "footer action fits the measured width")
      Assert.isTrue(target.y + target.height <= viewport.height, "footer action fits the measured height")
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

return T
