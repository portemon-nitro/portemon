-- Active editor scopes reject background targets and incomplete gestures.

local Assert = require("tests.support.Assert")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local Controller = require("app.src.saveeditor.SaveEditorController")
local DisplayContext = require("libs.ui.src.DisplayContext")
local Interface = require("app.src.saveeditor.SaveEditorInterface")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local Layout = require("app.src.saveeditor.SaveEditorLayout")
local State = require("app.src.saveeditor.SaveEditorState")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = { tests = {} }

function T.tests.location_content_focus_is_restored_when_reentering_the_section()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 7, fieldX = 10, fieldZ = 12 })
  controller:setFocus("section")
  Assert.equal(controller:snapshot().location.contentFocus, "navigation")
  controller:setFocus("section:Location")
  Assert.equal(controller:snapshot().location.contentFocus, "navigation")

  controller:setSection("Player")
  controller:setSection("Location")
  Assert.equal(controller:snapshot().location.contentFocus, "grid")
end

function T.tests.location_back_target_returns_focus_to_the_grid()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 7, fieldX = 10, fieldZ = 12 })
  controller:openLocationMaps()
  controller:setFocus("location:map-back")

  Assert.equal(controller:press("confirm").kind, "location-page")
  Assert.equal(controller:snapshot().location.contentFocus, "grid")
end

function T.tests.modal_scope_rejects_background_grid_and_sparse_drag_gestures()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 7, fieldX = 10, fieldZ = 12 })
  controller:openModal("leave")

  local view = {
    section = "Location",
    status = "ready",
    ready = true,
    dirty = true,
    modal = "leave",
    focus = "cancel",
    scope = { id = "modal:leave", epoch = 1 },
    textMetrics = {
      lineHeight = 14,
      measure = function(text)
        return #text * 7
      end,
    },
    location = { status = { state = "ready" }, maps = {}, mapId = 7 },
    locationNavigation = {
      page = "grid",
      center = { fieldX = 10, fieldZ = 12 },
      cursor = { fieldX = 10, fieldZ = 12 },
      scale = 24,
      mapOffset = 0,
    },
  }
  local layout = Layout.compute(view, 256, 192, view.textMetrics)
  local grid = assert(layout.locationGrid)
  local tile = Layout.hitTest(layout, view, grid.originX + 1, grid.originY + 1)
  Assert.isFalse(
    type(tile) == "string" and tile:match("^location:tile:") ~= nil,
    "a leave decision never hit-tests a background Location tile"
  )

  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = true,
    role = "world",
  })
  local context = DisplayContext.new({
    graphics = love.graphics,
    topologyProvider = function()
      return topology
    end,
  })
  local presentation = ApplicationPresentation.new(Interface.defaults())
  local plan = presentation:resolve(context:measure(256, 192), view)
  local pane = assert(plan.panes[1])
  local insideX, insideY =
    LayoutGeometry.logicalToHost(pane.placement, grid.originX + grid.tileSize / 2, grid.originY + grid.tileSize / 2)
  local mappedTile = presentation:mapInput({
    { type = "pointer_down", pointerId = "touch:modal-grid", x = insideX, y = insideY },
  }, view)
  Assert.isFalse(
    (mappedTile[1].targetId or ""):match("^location:tile:") ~= nil,
    "the shared presentation path never maps a modal press to a background grid tile"
  )

  local sparseController = Controller.new()
  sparseController:setSection("Location")
  sparseController:enterLocation({ mapId = 7, fieldX = 10, fieldZ = 12 })
  local outsideX, outsideY = pane.placement.frame.x - 1, pane.placement.frame.y - 1
  local outsideDown = presentation:mapInput({
    { type = "pointer_down", pointerId = "touch:outside-drag", x = outsideX, y = outsideY },
  }, view)
  Assert.isTrue(#outsideDown == 0 or (outsideDown[1].targetId == nil and outsideDown[1].x == nil))
  if outsideDown[1] then
    sparseController:pointer(outsideDown[1])
  end
  local insideMove = presentation:mapInput({
    { type = "pointer_move", pointerId = "touch:outside-drag", x = insideX, y = insideY },
  }, view)
  local mappedMoveOk = pcall(function()
    if insideMove[1] then
      sparseController:pointer(insideMove[1])
    end
  end)
  Assert.isTrue(mappedMoveOk, "the shared presentation path safely ignores an outside drag into the pane")
  presentation:dispose()

  local backgroundAction = controller:pointer({
    type = "pointer_down",
    pointerId = "touch:background",
    targetId = tile,
  })
  Assert.isNil(backgroundAction, "a background press cannot activate an underlying tile")
  Assert.equal(controller.focus, "cancel", "background presses cannot replace modal focus")

  local sparseDownOk = pcall(function()
    controller:pointer({ type = "pointer_down", pointerId = "touch:outside" })
    controller:pointer({ type = "pointer_move", pointerId = "touch:outside", x = 12, y = 14 })
  end)
  Assert.isTrue(sparseDownOk, "an outside down without coordinates remains a harmless canceled gesture")
  Assert.isNil(
    controller:pointer({ type = "pointer_up", pointerId = "touch:outside", targetId = "discard" }),
    "a release from an outside press cannot activate a modal decision"
  )

  controller:pointer({ type = "pointer_down", pointerId = "touch:stale", targetId = "discard", x = 8, y = 8 })
  controller:openModal("remove")
  Assert.isNil(
    controller:pointer({ type = "pointer_up", pointerId = "touch:stale", targetId = "discard", x = 8, y = 8 }),
    "a release captured by a replaced scope cannot activate its former decision"
  )

  controller:pointer({ type = "pointer_down", pointerId = "touch:resize", targetId = "cancel", x = 8, y = 8 })
  controller:cancelInteraction()
  Assert.isNil(
    controller:pointer({ type = "pointer_up", pointerId = "touch:resize", targetId = "cancel", x = 8, y = 8 }),
    "a resize cancellation drops an in-flight press before release"
  )
end

function T.tests.sparse_outside_press_can_move_inside_without_nil_coordinate_failure()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 7, fieldX = 10, fieldZ = 12 })
  local ok = pcall(function()
    controller:pointer({ type = "pointer_down", pointerId = "touch:outside" })
    controller:pointer({ type = "pointer_move", pointerId = "touch:outside", x = 12, y = 14 })
  end)
  Assert.isTrue(ok, "a sparse outside press is canceled rather than treated as a drag origin")
end

function T.tests.scope_replacement_drops_a_pressed_target_before_release()
  local controller = Controller.new()
  controller:openModal("leave")
  controller:pointer({ type = "pointer_down", pointerId = "touch:scope", targetId = "discard", x = 8, y = 8 })
  controller:openModal("remove")
  Assert.isNil(
    controller:pointer({ type = "pointer_up", pointerId = "touch:scope", targetId = "discard", x = 8, y = 8 }),
    "a release cannot activate a target captured by the previous scope"
  )
end

function T.tests.number_repeat_stops_on_pointer_cancel_and_focus_loss()
  local function stateWithHold(pointerId)
    local controller = Controller.new()
    controller:pointer({ type = "pointer_down", pointerId = pointerId, targetId = "number:delta:1" })
    local adjustments = 0
    local state = setmetatable({
      disposed = false,
      status = "ready",
      tickRemainder = 0,
      inputTick = 0,
      controller = controller,
      fieldInput = {
        uiSnapshot = function()
          return {}
        end,
        clearAll = function() end,
        beginUi = function() end,
      },
      presentation = {
        mapInput = function(_, events)
          return events
        end,
        cancelPointers = function() end,
      },
      numberHold = {
        pointerId = pointerId,
        targetId = "number:delta:1",
        delta = 1,
        scopeEpoch = controller.scopeEpoch,
        nextTick = 1,
      },
      _snapshot = function()
        return {}
      end,
      _resolve = function()
        return {}
      end,
      _reconcileFocus = function() end,
      _dispatchIntent = function() end,
      _adjustNumber = function()
        adjustments = adjustments + 1
      end,
    }, State)
    return state, function()
      return adjustments
    end
  end

  local canceled, canceledAdjustments = stateWithHold("touch:cancel")
  canceled:_pointer({ { type = "pointer_cancel", pointerId = "touch:cancel" } })
  canceled:update(1 / 60)
  Assert.isNil(canceled.numberHold, "pointer cancel clears the number hold")
  Assert.equal(canceledAdjustments(), 0, "pointer cancel prevents held number repeats")

  local blurred, blurredAdjustments = stateWithHold("touch:blur")
  blurred:focus(false)
  blurred:update(1 / 60)
  Assert.isNil(blurred.numberHold, "focus loss clears the number hold")
  Assert.equal(blurredAdjustments(), 0, "focus loss prevents held number repeats")
end

function T.tests.choice_layout_publishes_active_scope_records_and_clips_row_hits()
  local options = {}
  for index = 1, 12 do
    options[index] = { key = string.format("choice-%02d", index), label = "Choice " .. index }
  end
  local view = {
    section = "Player",
    status = "ready",
    ready = true,
    dirty = false,
    scope = { id = "value:choice:species", epoch = 4, kind = "value", focusId = "choice:choice-01" },
    session = { playerName = "Player", money = 0, frameIndex = 0 },
    valueEditor = {
      kind = "choice",
      purpose = "species",
      options = options,
      selectedKey = nil,
    },
    scrollOffsets = { ["value:choice"] = 4 },
    textMetrics = {
      lineHeight = 14,
      measure = function(text)
        return #text * 7
      end,
    },
  }
  local layout = Layout.compute(view, 256, 192, view.textMetrics)

  Assert.equal(layout.scopeId, view.scope.id)
  Assert.equal(layout.scopeEpoch, view.scope.epoch)
  Assert.notNil(layout.focusOrder, "the plan must publish complete semantic focus order")
  Assert.isNil(layout.focusable, "the public plan has one semantic focus order")
  Assert.isNil(layout.disabledTargets, "activation state belongs to each target record")
  for _, option in ipairs(options) do
    local targetId = "choice:" .. option.key
    local found = false
    for _, focusId in ipairs(layout.focusOrder) do
      if focusId == targetId then
        found = true
      end
    end
    Assert.isTrue(found, "offscreen choice remains in focus order: " .. targetId)
  end
  Assert.isNil(layout.targets.save, "the value scope cannot publish shell targets")
  Assert.isNil(layout.targets.section, "the value scope cannot publish navigation targets")

  local viewport = assert(layout.viewports["value:choice"])
  Assert.notNil(viewport.clip)
  Assert.equal(viewport.rowExtent, 30)
  Assert.equal(viewport.gap, 0)
  Assert.equal(viewport.firstIndex, 1)
  Assert.isTrue(viewport.lastIndex < #options, "the short viewport must expose a strict row range")
  local expectedRows = {}
  for _, option in ipairs(options) do
    expectedRows[#expectedRows + 1] = "choice:" .. option.key
  end
  Assert.deepEqual(viewport.rowTargets, expectedRows)

  local first = assert(layout.targets["choice:choice-01"])
  Assert.equal(first.role, "choice")
  Assert.isTrue(first.focusable)
  Assert.isTrue(first.activationEnabled)
  Assert.equal(first.viewportId, "value:choice")
  Assert.notNil(first.clip)
  Assert.notNil(first.rect)
  local clip = viewport.clip
  local x = first.rect.x + first.rect.width / 2
  Assert.isNil(
    Layout.hitTest(layout, view, x, clip.y - 1),
    "a partially clipped choice cannot activate outside its visible viewport intersection"
  )
  Assert.equal(
    Layout.hitTest(layout, view, x, clip.y + 1),
    "choice:choice-01",
    "the visible part of a partially clipped choice remains actionable"
  )
end

return T
