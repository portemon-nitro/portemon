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
local ValueEditor = require("app.src.saveeditor.SaveEditorValueEditor")

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


local function interactionMetrics()
  return {
    lineHeight = 14,
    measure = function(text)
      return #text * 7
    end,
  }
end

local function progressFlagCatalog(count)
  local catalog = {}
  for index = 1, count do
    local name = string.format("TEST_FLAG_%02d", index)
    catalog[index] = { name = name, displayName = "Test flag " .. index, value = index % 2 == 0 }
  end
  return catalog
end

local function progressListHarness(flagCatalog)
  local controller = Controller.new()
  controller:setSection("Progress")
  local metrics = interactionMetrics()
  local function filterFlags()
    local query = controller.query:lower()
    local rows = {}
    for _, flag in ipairs(flagCatalog) do
      if query == "" or flag.name:lower():find(query, 1, true) ~= nil then
        rows[#rows + 1] = flag
      end
    end
    return rows
  end
  local function buildView()
    return {
      section = "Progress",
      status = "ready",
      ready = true,
      dirty = true,
      scope = { id = "section:Progress", epoch = 0, kind = "section", focusId = controller.focus },
      focus = controller.focus,
      query = controller.query,
      flagRows = filterFlags(),
      scrollOffsets = controller.scrollOffsets,
    }
  end
  local function buildLayout()
    return Layout.compute(buildView(), 256, 192, metrics)
  end
  local current = { view = buildView(), layout = buildLayout() }
  local function sync()
    current.view = buildView()
    current.layout = buildLayout()
  end
  local activations = {}
  local backs = 0
  local state = setmetatable({
    status = "ready",
    controller = controller,
    _snapshot = buildView,
    _resolve = function()
      return { content = { layout = buildLayout() } }
    end,
    _activate = function(_, targetId)
      activations[#activations + 1] = targetId
    end,
    _requestBack = function()
      backs = backs + 1
    end,
  }, State)
  return {
    controller = controller,
    state = state,
    current = current,
    sync = sync,
    activations = activations,
    backCount = function()
      return backs
    end,
  }
end

local function rowTargetsSet(rowTargets)
  local set = {}
  for _, targetId in ipairs(rowTargets) do
    set[targetId] = true
  end
  return set
end

local function assertNoSearchTarget(layout)
  for _, focusId in ipairs(layout.focusOrder) do
    Assert.isFalse(
      focusId:find("search", 1, true) ~= nil,
      "filtering needs no standalone search target, found " .. focusId
    )
  end
  for targetId in pairs(layout.targets) do
    Assert.isFalse(
      targetId:find("search", 1, true) ~= nil,
      "filtering needs no standalone search control, found " .. targetId
    )
  end
end

function T.tests.focused_list_confirm_enters_first_and_remembered_rows_without_activation()
  local harness = progressListHarness(progressFlagCatalog(6))
  local controller, state = harness.controller, harness.state
  controller:setFocus("list:flags")
  harness.sync()
  Assert.notNil(harness.current.layout.lists, "the plan must publish one record per interactive list")
  local list = assert(harness.current.layout.lists.flags, "the flag list must publish its interaction record")
  Assert.equal(list.targetId, "list:flags", "the container target identifies the whole list")

  state:_consumeUiInput({ { type = "confirm" } })
  harness.sync()
  Assert.equal(#harness.activations, 0, "entering row focus never activates a row")
  local firstRow = list.rowTargets[1]
  Assert.equal(controller.focus, firstRow, "Confirm enters the first row")

  state:_consumeUiInput({ { type = "navigate", direction = "down" } })
  harness.sync()
  local secondRow = harness.current.layout.lists.flags.rowTargets[2]
  Assert.equal(controller.focus, secondRow, "Down moves one row")
  Assert.equal(#harness.activations, 0, "browsing rows never activates")

  state:_consumeUiInput({ { type = "cancel" } })
  harness.sync()
  Assert.equal(controller.focus, "list:flags", "Back returns to the list container")
  Assert.equal(harness.backCount(), 0, "leaving row focus never leaves the enclosing section")
  Assert.equal(#harness.activations, 0, "leaving row focus never activates")

  state:_consumeUiInput({ { type = "confirm" } })
  harness.sync()
  Assert.equal(#harness.activations, 0, "re-entering row focus never activates")
  Assert.equal(controller.focus, secondRow, "Confirm re-enters the remembered cursor row")
end

function T.tests.focused_list_row_navigation_pages_and_back_returns_to_container()
  local harness = progressListHarness(progressFlagCatalog(20))
  local controller, state = harness.controller, harness.state
  harness.sync()
  Assert.notNil(harness.current.layout.lists, "the plan must publish one record per interactive list")
  local rows = harness.current.layout.lists.flags.rowTargets
  Assert.equal(#rows, 20, "the long list exposes every row in display order")
  local viewport = assert(harness.current.layout.viewports.flags)
  local visibleCount = math.max(1, viewport.lastIndex - viewport.firstIndex + 1)
  Assert.isTrue(visibleCount < #rows, "the fixture list is longer than one viewport")

  controller:setFocus(rows[2])
  state:_consumeUiInput({ { type = "navigate", direction = "up" } })
  Assert.equal(controller.focus, rows[1], "Up moves one row")
  state:_consumeUiInput({ { type = "navigate", direction = "down" } })
  Assert.equal(controller.focus, rows[2], "Down moves one row")

  controller:setFocus(rows[1])
  state:_consumeUiInput({ { type = "navigate", direction = "right" } })
  Assert.equal(
    controller.focus,
    rows[math.min(#rows, 1 + visibleCount)],
    "Right pages by one visible count"
  )
  Assert.isTrue(
    (controller.scrollOffsets.flags or 0) > 0,
    "paging reveals its target row through the list viewport"
  )
  state:_consumeUiInput({ { type = "navigate", direction = "left" } })
  Assert.equal(
    controller.focus,
    rows[math.max(1, math.min(#rows, 1 + visibleCount) - visibleCount)],
    "Left pages back by one visible count"
  )

  controller:setFocus(rows[1])
  state:_consumeUiInput({ { type = "navigate", direction = "left" } })
  Assert.equal(controller.focus, rows[1], "paging clamps at the first row instead of wrapping")
  controller:setFocus(rows[#rows])
  state:_consumeUiInput({ { type = "navigate", direction = "right" } })
  Assert.equal(controller.focus, rows[#rows], "paging clamps at the last row instead of wrapping")

  state:_consumeUiInput({ { type = "cancel" } })
  Assert.equal(controller.focus, "list:flags", "Back returns to the list container")
  Assert.equal(harness.backCount(), 0, "leaving row focus never leaves the enclosing section")
  Assert.equal(#harness.activations, 0, "row navigation and Back never activate")
end

function T.tests.typing_filters_the_focused_list_without_a_search_target()
  local harness = progressListHarness(progressFlagCatalog(6))
  local controller, state = harness.controller, harness.state
  controller:setFocus("list:flags")
  harness.sync()
  assertNoSearchTarget(harness.current.layout)

  state:textinput("TEST_FLAG_02")
  harness.sync()
  Assert.equal(controller.query, "TEST_FLAG_02")
  Assert.deepEqual(harness.current.layout.lists.flags.rowTargets, { "flag:TEST_FLAG_02" })
  Assert.equal(controller.focus, "list:flags", "typing on the container filters without entering row focus")
  Assert.equal(#harness.activations, 0, "filtering never activates a row")

  controller:setFocus("list:flags")
  state:_consumeUiInput({ { type = "confirm" } })
  harness.sync()
  Assert.equal(controller.focus, "flag:TEST_FLAG_02", "Confirm enters the remaining row")
  state:textinput("X")
  harness.sync()
  Assert.deepEqual(harness.current.layout.lists.flags.rowTargets, {})
  Assert.equal(
    controller.focus,
    "list:flags",
    "filtering away every row returns focus to the container"
  )
  Assert.equal(#harness.activations, 0, "filter reconciliation never activates a row")

  controller:setFocus("back")
  state:textinput("Q")
  harness.sync()
  Assert.equal(controller.query, "TEST_FLAG_02X", "typing outside a focused list never filters")
end

function T.tests.focused_list_keeps_row_focus_and_edits_multibyte_queries()
  local harness = progressListHarness(progressFlagCatalog(6))
  local controller, state = harness.controller, harness.state
  controller:setFocus("list:flags")
  harness.sync()
  Assert.notNil(harness.current.layout.lists, "the plan must publish one record per interactive list")

  state:_consumeUiInput({ { type = "confirm" } })
  harness.sync()
  local rows = harness.current.layout.lists.flags.rowTargets
  Assert.equal(controller.focus, rows[1], "Confirm enters the first row")
  state:textinput(rows[1]:sub(6))
  harness.sync()
  Assert.isTrue(
    rowTargetsSet(harness.current.layout.lists.flags.rowTargets)[controller.focus] == true
      or controller.focus == "list:flags",
    "typing reconciles a removed cursor row to a live row or the container"
  )
  Assert.equal(#harness.activations, 0, "filtering from row focus never activates")

  state:keypressed("delete")
  harness.sync()
  Assert.equal(controller.query, "", "Delete clears the list query")
  Assert.equal(#harness.current.layout.lists.flags.rowTargets, 6, "clearing restores every row")

  state:textinput("é")
  harness.sync()
  Assert.equal(controller.query, "é")
  state:keypressed("backspace")
  harness.sync()
  Assert.equal(controller.query, "", "Backspace removes one complete multibyte glyph")
  Assert.equal(#harness.current.layout.lists.flags.rowTargets, 6, "the cleared query restores every row")
  Assert.equal(#harness.activations, 0, "query edits never activate")
end

function T.tests.empty_filter_leaves_confirm_inert_on_the_container()
  local harness = progressListHarness(progressFlagCatalog(6))
  local controller, state = harness.controller, harness.state
  controller:setFocus("list:flags")
  harness.sync()
  Assert.notNil(harness.current.layout.lists, "the plan must publish one record per interactive list")

  state:textinput("zzz-no-such-flag")
  harness.sync()
  local list = harness.current.layout.lists.flags
  Assert.isTrue(list.empty, "zero filtered rows mark the list empty")
  Assert.equal(controller.focus, "list:flags", "an empty filter keeps container focus")

  state:_consumeUiInput({ { type = "confirm" } })
  harness.sync()
  Assert.equal(#harness.activations, 0, "Confirm on an empty list does nothing")
  Assert.equal(controller.focus, "list:flags", "Confirm on an empty list keeps container focus")
end

function T.tests.pointer_taps_focus_before_they_activate_and_drag_never_activates()
  local controller = Controller.new()
  controller:setSection("Progress")

  Assert.isNil(
    controller:pointer({ type = "pointer_down", pointerId = "touch:row", targetId = "flag:TEST_FLAG_01", x = 8, y = 8 }),
    "pressing a row never activates on press"
  )
  local firstTap =
    controller:pointer({ type = "pointer_up", pointerId = "touch:row", targetId = "flag:TEST_FLAG_01", x = 8, y = 8 })
  Assert.isTrue(
    firstTap == nil or firstTap.kind ~= "activate",
    "a first clean tap on an unfocused row only focuses it"
  )
  Assert.equal(controller.focus, "flag:TEST_FLAG_01", "a first clean tap moves row focus")

  Assert.isNil(
    controller:pointer({ type = "pointer_down", pointerId = "touch:row-again", targetId = "flag:TEST_FLAG_01", x = 8, y = 8 })
  )
  Assert.deepEqual(
    controller:pointer({ type = "pointer_up", pointerId = "touch:row-again", targetId = "flag:TEST_FLAG_01", x = 8, y = 8 }),
    { kind = "activate", targetId = "flag:TEST_FLAG_01" },
    "a second clean tap on the already focused row activates it"
  )

  Assert.isNil(
    controller:pointer({
      type = "pointer_down",
      pointerId = "touch:drag",
      targetId = "flag:TEST_FLAG_02",
      scrollViewportId = "flags",
      scrollOffset = 0,
      x = 8,
      y = 8,
    })
  )
  local dragMove = controller:pointer({ type = "pointer_move", pointerId = "touch:drag", x = 8, y = 80 })
  Assert.isTrue(
    dragMove == nil or dragMove.kind == "scroll-drag",
    "a scroll drag produces no row intent while moving"
  )
  Assert.isNil(
    controller:pointer({ type = "pointer_up", pointerId = "touch:drag", targetId = "flag:TEST_FLAG_02", x = 8, y = 80 }),
    "releasing after a scroll drag never activates"
  )

  Assert.isNil(
    controller:pointer({ type = "pointer_down", pointerId = "touch:box", targetId = "list:flags", x = 4, y = 4 })
  )
  local boxTap =
    controller:pointer({ type = "pointer_up", pointerId = "touch:box", targetId = "list:flags", x = 4, y = 4 })
  Assert.isTrue(boxTap == nil or boxTap.kind ~= "activate", "a clean tap on the container only focuses it")
  Assert.equal(controller.focus, "list:flags", "a clean tap on the container moves container focus")
end

local function locationListHarness()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 12, fieldX = 32, fieldZ = 48 })
  controller:openLocationMaps()
  local metrics = interactionMetrics()
  local maps = {
    { mapId = 12, symbol = "MAP_TEST_ROUTE", displayName = "TEST_ROUTE", section = "TEST_SECTION" },
    { mapId = 34, symbol = "MAP_TEST_TOWN", displayName = "TEST_TOWN", section = "TEST_SECTION" },
    { mapId = 47, symbol = "MAP_TEST_CAVE", displayName = "TEST_CAVE", section = "TEST_OTHER" },
    { mapId = 7, symbol = "MAP_TEST_LAKE", displayName = "TEST_LAKE", section = "TEST_OTHER" },
  }
  local function buildView()
    return {
      section = "Location",
      status = "ready",
      ready = true,
      dirty = false,
      scope = { id = "section:Location:map-list", epoch = 0, kind = "section", focusId = controller.focus },
      focus = controller.focus,
      query = controller.query,
      location = {
        mapId = 12,
        symbol = "MAP_TEST_ROUTE",
        section = "TEST_SECTION",
        maps = maps,
        generation = 1,
        status = { state = "ready" },
        tiles = { { fieldX = 32, fieldZ = 48, selectable = true } },
        cursor = { fieldX = 32, fieldZ = 48 },
      },
      locationNavigation = {
        page = "map-list",
        contentFocus = "map-list",
        mapId = 12,
        cursor = { fieldX = 32, fieldZ = 48 },
        center = { fieldX = 32, fieldZ = 48 },
        mapOffset = controller.locationMapOffset,
      },
      scrollOffsets = controller.scrollOffsets,
    }
  end
  local function buildLayout()
    return Layout.compute(buildView(), 800, 600, metrics)
  end
  local intents = {}
  local backs = 0
  local state = setmetatable({
    status = "ready",
    controller = controller,
    _snapshot = buildView,
    _resolve = function()
      return { content = { layout = buildLayout() } }
    end,
    _activate = function(_, targetId)
      intents[#intents + 1] = { kind = "activate", targetId = targetId }
    end,
    _performDeferred = function(_, intent)
      intents[#intents + 1] = intent
    end,
    _requestBack = function()
      backs = backs + 1
    end,
  }, State)
  return {
    controller = controller,
    state = state,
    buildView = buildView,
    buildLayout = buildLayout,
    intents = intents,
    backCount = function()
      return backs
    end,
  }
end

function T.tests.location_map_rows_browse_without_committing_the_map()
  local harness = locationListHarness()
  local controller, state = harness.controller, harness.state
  local layout = harness.buildLayout()
  Assert.notNil(layout.lists, "the plan must publish one record per interactive list")
  local list = assert(layout.lists["location:map-list"], "map rows belong to one generic list record")
  Assert.deepEqual(
    list.rowTargets,
    { "location:map:12", "location:map:34", "location:map:47", "location:map:7" }
  )

  controller:setFocus("list:location:map-list")
  state:_consumeUiInput({ { type = "confirm" } })
  Assert.equal(#harness.intents, 0, "entering map rows never starts map work")
  Assert.equal(controller.focus, "location:map:12", "Confirm enters the first map row")

  state:_consumeUiInput({ { type = "navigate", direction = "down" } })
  Assert.equal(controller.focus, "location:map:34", "Down moves one map row")
  Assert.equal(controller.locationMapId, 12, "browsing rows never changes the committed map")
  Assert.equal(harness.buildView().location.mapId, 12, "the committed map snapshot is untouched by browsing")
  local committed = true
  for _, intent in ipairs(harness.intents) do
    committed = committed and intent.kind ~= "location-map-select"
  end
  Assert.isTrue(committed, "browsing rows never emits a map selection")

  state:_consumeUiInput({ { type = "cancel" } })
  Assert.equal(controller.focus, "list:location:map-list", "Back returns to the map-list container")
  Assert.equal(harness.backCount(), 0, "leaving map rows never leaves the map list")
  Assert.equal(#harness.intents, 0, "leaving map rows never starts map work")
end

local function overflowingLocationListHarness(width, height, count)
  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 12, fieldX = 32, fieldZ = 48 })
  controller:openLocationMaps()
  local metrics = interactionMetrics()
  local maps = {}
  for index = 1, count do
    maps[index] = {
      mapId = index,
      symbol = "MAP_TEST_" .. index,
      displayName = "TEST_" .. index,
      section = "TEST_SECTION",
    }
  end
  local function buildView()
    return {
      section = "Location",
      status = "ready",
      ready = true,
      dirty = false,
      scope = { id = "section:Location:map-list", epoch = 0, kind = "section", focusId = controller.focus },
      focus = controller.focus,
      query = controller.query,
      location = {
        mapId = 12,
        symbol = "MAP_TEST_12",
        section = "TEST_SECTION",
        maps = maps,
        generation = 1,
        status = { state = "ready" },
        tiles = { { fieldX = 32, fieldZ = 48, selectable = true } },
        cursor = { fieldX = 32, fieldZ = 48 },
      },
      locationNavigation = {
        page = "map-list",
        contentFocus = "map-list",
        mapId = 12,
        cursor = { fieldX = 32, fieldZ = 48 },
        center = { fieldX = 32, fieldZ = 48 },
        mapOffset = controller.locationMapOffset,
      },
      scrollOffsets = controller.scrollOffsets,
    }
  end
  local function buildLayout()
    return Layout.compute(buildView(), width, height, metrics)
  end
  local intents = {}
  local backs = 0
  local state = setmetatable({
    status = "ready",
    controller = controller,
    _snapshot = buildView,
    _resolve = function()
      return { content = { layout = buildLayout() } }
    end,
    _activate = function(_, targetId)
      intents[#intents + 1] = { kind = "activate", targetId = targetId }
    end,
    _performDeferred = function(_, intent)
      intents[#intents + 1] = intent
    end,
    _requestBack = function()
      backs = backs + 1
    end,
  }, State)
  return {
    controller = controller,
    state = state,
    buildView = buildView,
    buildLayout = buildLayout,
    intents = intents,
    backCount = function()
      return backs
    end,
  }
end

function T.tests.location_map_row_navigation_scrolls_past_the_viewport_without_resetting()
  for _, size in ipairs({ { 800, 600 }, { 256, 192 } }) do
    local label = size[1] .. "x" .. size[2]
    local harness = overflowingLocationListHarness(size[1], size[2], 30)
    local controller, state = harness.controller, harness.state
    local viewport = assert(harness.buildLayout().viewports["location:map-list"])
    Assert.isTrue(viewport.lastIndex < 30, "the map list must overflow its viewport (" .. label .. ")")

    controller:setFocus("list:location:map-list")
    state:_consumeUiInput({ { type = "confirm" } })
    Assert.equal(controller.focus, "location:map:1", "Confirm enters the first map row (" .. label .. ")")

    for index = 2, 30 do
      state:_consumeUiInput({ { type = "navigate", direction = "down" } })
      Assert.equal(
        controller.focus,
        "location:map:" .. index,
        "Down keeps walking rows past the viewport edge (" .. label .. ": row " .. index .. ")"
      )
    end
    Assert.equal(controller.locationMapId, 12, "scrolling rows never changes the committed map (" .. label .. ")")
    Assert.equal(#harness.intents, 0, "scrolling rows never starts map work (" .. label .. ")")
    Assert.equal(
      controller:listCursor("location:map-list"),
      "location:map:30",
      "the cursor tracks row focus past the viewport (" .. label .. ")"
    )

    state:_consumeUiInput({ { type = "cancel" } })
    Assert.equal(
      controller.focus,
      "list:location:map-list",
      "Back returns to the map-list container (" .. label .. ")"
    )
    Assert.equal(harness.backCount(), 0, "leaving map rows never leaves the map list (" .. label .. ")")

    state:wheelmoved(0, 3)
    local scrolledCursor = controller:listCursor("location:map-list")
    Assert.notNil(scrolledCursor, "scrolling keeps a live list cursor (" .. label .. ")")
    state:_consumeUiInput({ { type = "cancel" } })
    Assert.equal(
      controller.focus,
      "list:location:map-list",
      "Back returns to the map-list container after scrolling (" .. label .. ")"
    )
    state:_consumeUiInput({ { type = "confirm" } })
    Assert.equal(
      controller.focus,
      scrolledCursor,
      "re-entering rows restores the cursor row after scrolling (" .. label .. ")"
    )
    Assert.equal(controller.locationMapId, 12, "re-entering rows never commits a map (" .. label .. ")")
    Assert.equal(#harness.intents, 0, "re-entering rows never starts map work (" .. label .. ")")
  end
end

local function choiceListHarness()
  local controller = Controller.new()
  controller:setSection("Bag")
  local metrics = interactionMetrics()
  local options = {}
  for index = 1, 12 do
    options[index] = { key = string.format("K%02d", index), label = "Choice " .. index }
  end
  local editor = ValueEditor.new({ kind = "choice", value = "K05", options = options })
  local function buildView()
    return {
      section = "Bag",
      status = "ready",
      ready = true,
      dirty = false,
      bagRows = {},
      valueEditor = editor:snapshot(),
      scope = { id = "value:choice", epoch = 1, kind = "value", focusId = controller.focus },
      scrollOffsets = {},
    }
  end
  local function buildLayout()
    return Layout.compute(buildView(), 256, 192, metrics)
  end
  local finished = 0
  local state = setmetatable({
    status = "ready",
    controller = controller,
    valueEditor = editor,
    _snapshot = buildView,
    _resolve = function()
      return { content = { layout = buildLayout() } }
    end,
    _finishValueEditor = function()
      finished = finished + 1
    end,
  }, State)
  return {
    controller = controller,
    state = state,
    editor = editor,
    buildLayout = buildLayout,
    finishedCount = function()
      return finished
    end,
  }
end

function T.tests.choice_editor_enters_rows_and_back_returns_to_container()
  local harness = choiceListHarness()
  local controller, state, editor = harness.controller, harness.state, harness.editor
  local layout = harness.buildLayout()
  Assert.notNil(layout.lists, "the plan must publish one record per interactive list")
  local list = assert(layout.lists["value:choice"], "choice options belong to one generic list record")
  Assert.equal(list.rowTargets[1], "choice:K01", "rows follow the filtered display order")

  controller:setFocus("list:value:choice")
  state:_consumeUiInput({ { type = "confirm" } })
  Assert.equal(harness.finishedCount(), 0, "entering choice rows never submits the editor")
  Assert.isNil(editor:result(), "entering choice rows publishes no result")
  Assert.equal(controller.focus, "choice:K01", "Confirm enters the first row")

  controller:setFocus("choice:K05")
  state:_consumeUiInput({ { type = "cancel" } })
  Assert.equal(controller.focus, "list:value:choice", "Back returns to the choice container")
  Assert.isNil(editor:result(), "Back from a choice row keeps the editor open")
  Assert.equal(harness.finishedCount(), 0, "Back from a choice row never finishes the editor")

  controller:setFocus("choice:K05")
  state:_consumeUiInput({ { type = "navigate", direction = "up" } })
  Assert.equal(controller.focus, "choice:K04", "Up moves one row")
  state:_consumeUiInput({ { type = "navigate", direction = "down" } })
  Assert.equal(controller.focus, "choice:K05", "Down moves one row")
  local paged = harness.buildLayout()
  local viewport = assert(paged.viewports["value:choice"])
  local visibleCount = math.max(1, viewport.lastIndex - viewport.firstIndex + 1)
  controller:setFocus("choice:K01")
  state:_consumeUiInput({ { type = "navigate", direction = "right" } })
  Assert.equal(
    controller.focus,
    "choice:K" .. string.format("%02d", math.min(12, 1 + visibleCount)),
    "Right pages by one visible count"
  )
  state:_consumeUiInput({ { type = "navigate", direction = "left" } })
  Assert.equal(controller.focus, "choice:K01", "Left pages back and clamps at the first row")
end

function T.tests.choice_typing_reconciles_the_cursor_without_publishing()
  local harness = choiceListHarness()
  local controller, state, editor = harness.controller, harness.state, harness.editor
  controller:setFocus("choice:K05")
  state:textinput("Choice 1")
  local layout = harness.buildLayout()
  Assert.notNil(layout.lists, "the plan must publish one record per interactive list")
  local rows = layout.lists["value:choice"].rowTargets
  Assert.isTrue(#rows < 12, "typing filters the choice rows")
  Assert.isTrue(
    rowTargetsSet(rows)[controller.focus] == true or controller.focus == "list:value:choice",
    "a filtered-away cursor reconciles to a live row or the container, got " .. controller.focus
  )
  Assert.isNil(editor:result(), "filtering publishes no result")
end

return T
