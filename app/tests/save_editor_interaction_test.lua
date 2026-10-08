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

function T.tests.location_section_entry_always_opens_the_map_list()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 7, fieldX = 10, fieldZ = 12 })
  Assert.equal(controller:snapshot().location.page, "map-list", "section entry opens the map list")
  Assert.equal(controller.focus, "list:location:map-list", "section entry focuses the map-list container")

  controller:chooseLocationMap(7, 10, 12)
  Assert.equal(controller:snapshot().location.page, "grid", "map activation enters coordinate selection")

  controller:setSection("Player")
  controller:setSection("Location")
  Assert.equal(controller:snapshot().location.page, "map-list", "returning to the section reopens the map list")
  Assert.equal(controller.focus, "list:location:map-list", "returning focuses the map-list container")
end

function T.tests.entering_the_same_map_preserves_the_grid_while_section_entry_resets_to_the_list()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 7, fieldX = 10, fieldZ = 12 })
  controller:chooseLocationMap(7, 10, 12)
  controller:enterLocation({ mapId = 7, fieldX = 14, fieldZ = 18 })
  Assert.equal(
    controller:snapshot().location.page,
    "grid",
    "staged sync on the same map stays in coordinate selection"
  )
  Assert.deepEqual(
    controller:snapshot().location.cursor,
    { fieldX = 14, fieldZ = 18 },
    "staged sync refreshes the grid cursor"
  )
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
      scopeEpoch = 0,
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
  local rowTargets, indexByTarget = {}, {}
  for index, option in ipairs(options) do
    local targetId = "choice:" .. option.key
    rowTargets[index] = targetId
    indexByTarget[targetId] = index
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
      rowTargets = rowTargets,
      indexByTarget = indexByTarget,
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
  for _, targetId in ipairs(rowTargets) do
    local visible = layout.targets[targetId] ~= nil
    local ordered = false
    for _, focusId in ipairs(layout.focusOrder) do
      if focusId == targetId then
        ordered = true
      end
    end
    Assert.equal(
      ordered,
      visible,
      "focus order matches the materialized choice window: " .. targetId
    )
  end
  Assert.equal(#layout.lists["value:choice"].rowTargets, 12, "the logical choice order stays complete")
  Assert.isNil(layout.targets.save, "the value scope cannot publish shell targets")
  Assert.isNil(layout.targets.section, "the value scope cannot publish navigation targets")

  local viewport = assert(layout.viewports["value:choice"])
  Assert.notNil(viewport.clip)
  Assert.equal(viewport.rowExtent, 18)
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
    local rows = filterFlags()
    local rowTargets, indexByTarget = {}, {}
    for index, flag in ipairs(rows) do
      local targetId = "flag:" .. flag.name
      rowTargets[index] = targetId
      indexByTarget[targetId] = index
    end
    return {
      section = "Progress",
      status = "ready",
      ready = true,
      dirty = true,
      scope = { id = "section:Progress", epoch = 0, kind = "section", focusId = controller.focus },
      focus = controller.focus,
      query = controller.query,
      flagRows = rows,
      flagRowTargets = rowTargets,
      flagIndexByTarget = indexByTarget,
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
    fieldInput = { beginUi = function() end },
    scopeEpoch = 0,
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

  local last = rows[#rows]
  for _ = 1, 10 do
    if controller.focus == last then
      break
    end
    state:_consumeUiInput({ { type = "navigate", direction = "right" } })
  end
  Assert.equal(controller.focus, last, "repeated paging reaches the last row through revealed windows")
  state:_consumeUiInput({ { type = "navigate", direction = "right" } })
  Assert.equal(controller.focus, last, "paging clamps at the last row instead of wrapping")

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
    local filtered = {}
    local normalized = controller.query:lower()
    for _, map in ipairs(maps) do
      if
        normalized == ""
        or map.symbol:lower():find(normalized, 1, true)
        or map.displayName:lower():find(normalized, 1, true)
        or map.section:lower():find(normalized, 1, true)
        or tostring(map.mapId):find(normalized, 1, true)
      then
        filtered[#filtered + 1] = map
      end
    end
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
        maps = filtered,
        mapRowTargets = (function()
          local targets = {}
          for _, map in ipairs(filtered) do
            targets[#targets + 1] = "location:map:" .. map.mapId
          end
          return targets
        end)(),
        mapIndexByTarget = (function()
          local index = {}
          for position, map in ipairs(filtered) do
            index["location:map:" .. map.mapId] = position
          end
          return index
        end)(),
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
    fieldInput = { beginUi = function() end },
    scopeEpoch = 0,
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
        mapRowTargets = (function()
          local targets = {}
          for _, map in ipairs(maps) do
            targets[#targets + 1] = "location:map:" .. map.mapId
          end
          return targets
        end)(),
        mapIndexByTarget = (function()
          local index = {}
          for position, map in ipairs(maps) do
            index["location:map:" .. map.mapId] = position
          end
          return index
        end)(),
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
    fieldInput = { beginUi = function() end },
    scopeEpoch = 0,
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

local function listRowIndex(rowTargets, targetId)
  for index, rowTarget in ipairs(rowTargets) do
    if rowTarget == targetId then
      return index
    end
  end
  return nil
end

local function assertCursorAddressesVisibleRow(controller, layout, listId, label)
  local list = assert(layout.lists[listId], "the plan publishes the list record (" .. label .. ")")
  local viewport = assert(layout.viewports[list.viewportId], "the plan publishes the list viewport (" .. label .. ")")
  local cursor = controller:listCursor(listId)
  local index = listRowIndex(list.rowTargets, cursor)
  Assert.notNil(index, "scrolling keeps a live list cursor (" .. label .. ")")
  Assert.isTrue(
    index >= viewport.firstIndex and index <= viewport.lastIndex,
    "scrolling reconciles the cursor into the visible range (" .. label .. ")"
  )
  return cursor
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
    Assert.equal(
      controller.focus,
      "list:location:map-list",
      "wheel scrolling keeps container focus (" .. label .. ")"
    )
    assertCursorAddressesVisibleRow(controller, harness.buildLayout(), "location:map-list", label .. " after wheel")
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
    fieldInput = { beginUi = function() end },
    scopeEpoch = 0,
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

  for _ = 1, 4 do
    state:_consumeUiInput({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(controller.focus, "choice:K05", "repeated Down steps reveal each logical row")
  state:_consumeUiInput({ { type = "cancel" } })
  Assert.equal(controller.focus, "list:value:choice", "Back returns to the choice container")
  Assert.isNil(editor:result(), "Back from a choice row keeps the editor open")
  Assert.equal(harness.finishedCount(), 0, "Back from a choice row never finishes the editor")

  state:_consumeUiInput({ { type = "confirm" } })
  Assert.equal(controller.focus, "choice:K05", "re-entering rows restores the cursor row")
  state:_consumeUiInput({ { type = "navigate", direction = "up" } })
  Assert.equal(controller.focus, "choice:K04", "Up moves one row")
  state:_consumeUiInput({ { type = "navigate", direction = "down" } })
  Assert.equal(controller.focus, "choice:K05", "Down moves one row")
  local paged = harness.buildLayout()
  local viewport = assert(paged.viewports["value:choice"])
  local visibleCount = math.max(1, viewport.lastIndex - viewport.firstIndex + 1)
  Assert.notNil(paged.focusGraph[controller.focus], "paging starts from a materialized row")
  state:_consumeUiInput({ { type = "navigate", direction = "right" } })
  Assert.equal(
    controller.focus,
    "choice:K" .. string.format("%02d", math.min(12, 5 + visibleCount)),
    "Right pages by one visible count"
  )
  state:_consumeUiInput({ { type = "navigate", direction = "left" } })
  Assert.equal(controller.focus, "choice:K05", "Left pages back to the starting row")
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

local function recordingLocationService()
  local stub = {
    openMaps = {},
    updateCalls = 0,
    viewportCalls = {},
  }
  function stub:openMap(mapId)
    self.openMaps[#self.openMaps + 1] = mapId
  end
  function stub:setViewport(centerX, centerZ, widthTiles, heightTiles)
    self.viewportCalls[#self.viewportCalls + 1] = {
      centerX = centerX,
      centerZ = centerZ,
      widthTiles = widthTiles,
      heightTiles = heightTiles,
    }
  end
  function stub:update()
    self.updateCalls = self.updateCalls + 1
  end
  function stub:snapshot()
    return { generation = 3, status = { state = "pending" } }
  end
  return stub
end

local function mapActivationHarness()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 12, fieldX = 32, fieldZ = 48 })
  controller:chooseLocationMap(12, 32, 48)
  local service = recordingLocationService()
  local resolveCount = 0
  local grid = { columns = 7, rows = 5 }
  local state = setmetatable({
    status = "ready",
    controller = controller,
    locationService = service,
    fieldInput = { beginUi = function() end },
    scopeEpoch = 0,
    locationServiceMapId = 12,
    locationViewport = nil,
    locationActionStatus = nil,
    errorMessage = nil,
    dependencies = {
      world = {
        maps = { { worldOriginX = 100, worldOriginZ = 200 } },
        byId = { [34] = 1 },
      },
    },
    _snapshot = function()
      return {}
    end,
    _resolve = function()
      resolveCount = resolveCount + 1
      return { content = { layout = { locationGrid = grid } } }
    end,
  }, State)
  return {
    controller = controller,
    service = service,
    state = state,
    resolveCount = function()
      return resolveCount
    end,
  }
end

function T.tests.location_map_browsing_moves_only_focus_and_never_starts_map_work()
  local harness = locationListHarness()
  local controller, state = harness.controller, harness.state
  controller:setFocus("list:location:map-list")
  state:_consumeUiInput({ { type = "confirm" } })
  Assert.equal(controller.focus, "location:map:12", "Confirm enters the first map row")

  state:_consumeUiInput({ { type = "navigate", direction = "down" } })
  Assert.equal(controller.focus, "location:map:34", "Down moves one map row")
  Assert.equal(controller.locationMapId, 12, "moving the map cursor leaves the committed map alone")
  Assert.equal(harness.buildView().location.mapId, 12, "the committed map snapshot is untouched by browsing")
  for _, intent in ipairs(harness.intents) do
    Assert.isTrue(intent.kind ~= "location-map-select", "browsing rows never selects a map")
  end

  Assert.isNil(
    controller:pointer({ type = "pointer_down", pointerId = "touch:map-row", targetId = "location:map:47", x = 8, y = 8 }),
    "pressing a map row never starts map work"
  )
  local firstTap =
    controller:pointer({ type = "pointer_up", pointerId = "touch:map-row", targetId = "location:map:47", x = 8, y = 8 })
  Assert.isTrue(firstTap == nil, "a first clean tap on an unfocused map row only focuses it")
  Assert.equal(controller.focus, "location:map:47", "a first clean tap moves map row focus")
  Assert.equal(controller.locationMapId, 12, "a focusing tap leaves the committed map alone")

  Assert.isNil(
    controller:pointer({ type = "pointer_down", pointerId = "touch:map-act", targetId = "location:map:47", x = 8, y = 8 })
  )
  local secondTap =
    controller:pointer({ type = "pointer_up", pointerId = "touch:map-act", targetId = "location:map:47", x = 8, y = 8 })
  Assert.deepEqual(
    secondTap,
    { kind = "location-map-select", mapId = 47 },
    "a second clean tap on the focused row requests activation"
  )
  Assert.equal(
    controller.locationMapId,
    12,
    "the activation request alone never commits the map; only explicit handling does"
  )

  Assert.isNil(
    controller:pointer({ type = "pointer_down", pointerId = "touch:map-drag", targetId = "location:map:7", x = 8, y = 8 })
  )
  Assert.isNil(
    controller:pointer({ type = "pointer_move", pointerId = "touch:map-drag", x = 8, y = 80 }),
    "a map-list scroll drag produces no map intent while moving"
  )
  Assert.isNil(
    controller:pointer({ type = "pointer_up", pointerId = "touch:map-drag", targetId = "location:map:7", x = 8, y = 80 }),
    "releasing after a scroll drag never selects a map"
  )
  Assert.equal(controller.locationMapId, 12, "scrolling the map list leaves the committed map alone")
end

function T.tests.confirming_a_map_row_publishes_the_map_without_loading_in_the_input_path()
  local harness = mapActivationHarness()
  harness.state:_performDeferred({ kind = "location-map-select", mapId = 34 })

  local navigation = harness.controller:locationSnapshot()
  Assert.equal(navigation.mapId, 34, "activation publishes the new browser map immediately")
  Assert.deepEqual(navigation.center, { fieldX = 116, fieldZ = 216 }, "activation recenters on the new map")
  Assert.equal(
    harness.service.updateCalls,
    0,
    "the input path performs no service update before the next update"
  )
end

function T.tests.steady_update_prepares_icons_from_the_published_selection()
  local harness = mapActivationHarness()
  harness.state.locationViewport = { centerX = 32, centerZ = 48, widthTiles = 7, heightTiles = 5 }
  local iconPrepCalls = 0
  local iconView, iconPlan = nil, nil
  harness.state.tickRemainder = 0
  harness.state.inputTick = 0
  harness.state.numberHold = nil
  harness.state.locationSave = nil
  harness.state.derivedAssets = {
    requestMilestone = function()
      return true
    end,
  }
  harness.state.dependencies.cacheFs = {}
  harness.state.renderer = {
    iconStatus = "ready",
    iconFailure = nil,
    prepareVisibleIcons = function(_, view, plan)
      iconPrepCalls = iconPrepCalls + 1
      iconView, iconPlan = view, plan
    end,
  }
  harness.state.fieldInput = {
    uiSnapshot = function()
      return {}
    end,
    beginUi = function() end,
  }
  local published = { section = "Location" }
  local layout = {
    focusGraph = { [harness.controller.focus] = true },
    defaultFocus = harness.controller.focus,
  }
  harness.state._snapshot = function()
    return published
  end
  harness.state._resolve = function()
    return { content = { layout = layout } }
  end

  harness.state:update(1 / 60)
  Assert.equal(iconPrepCalls, 1, "the steady update path prepares icons once per tick")
  Assert.isTrue(iconView == published, "icon preparation sees the published selection")
  Assert.isTrue(iconPlan ~= nil and iconPlan.content.layout == layout, "icon preparation sees the resolved plan")
end

function T.tests.location_service_refresh_reuses_known_grid_size_without_resolving_layout()
  local harness = mapActivationHarness()
  harness.state:_updateLocationService()

  Assert.equal(harness.resolveCount(), 0, "the service refresh never resolves presentation layout")
  Assert.equal(harness.service.updateCalls, 1, "the refresh still advances loading through the service")
  local viewport = assert(harness.service.viewportCalls[1], "the refresh still publishes its viewport")
  Assert.equal(viewport.centerX, 32, "the viewport follows the browser center")
  Assert.equal(viewport.centerZ, 48, "the viewport follows the browser center")
  Assert.equal(viewport.widthTiles, 1, "an unknown grid falls back to a temporary single tile")
  Assert.equal(viewport.heightTiles, 1, "an unknown grid falls back to a temporary single tile")
end

function T.tests.draw_renders_the_published_plan_without_requesting_icons()
  local harness = mapActivationHarness()
  harness.state.disposed = false
  harness.state.dependencies.cacheFs = {}
  harness.state.derivedAssets = {}
  local snapshots, resolves = 0, 0
  local plan = { content = { layout = {} } }
  harness.state._snapshot = function()
    snapshots = snapshots + 1
    return { section = "Location" }
  end
  harness.state._resolve = function()
    resolves = resolves + 1
    return plan
  end
  local iconPrepCalls = 0
  harness.state.renderer = {
    graphics = {},
    text = {},
    prepareVisibleIcons = function()
      iconPrepCalls = iconPrepCalls + 1
    end,
  }
  local drawnView, drawnPresentation = nil, nil
  local originalDraw = ApplicationPresentation.draw
  ApplicationPresentation.draw = function(_, _, view, presentation)
    drawnView, drawnPresentation = view, presentation
  end
  local ok, drawError = pcall(function()
    harness.state:draw()
  end)
  ApplicationPresentation.draw = originalDraw
  Assert.isTrue(ok, "draw runs without platform rendering: " .. tostring(drawError))
  Assert.equal(snapshots, 1, "draw snapshots its view once")
  Assert.equal(resolves, 1, "draw resolves its presentation plan once")
  Assert.equal(iconPrepCalls, 0, "draw never requests derived icon work")
  Assert.isTrue(drawnView ~= nil, "draw renders its resolved view")
  Assert.isTrue(drawnPresentation == plan, "draw renders its resolved plan")
end

function T.tests.resize_republishes_the_location_viewport_on_the_next_refresh()
  local harness = mapActivationHarness()
  harness.state.presentation = {
    cancelPointers = function() end,
  }
  harness.state:resize(800, 600)
  harness.state:_updateLocationService()

  Assert.equal(#harness.service.viewportCalls, 1, "the next refresh republishes the viewport after a resize")
  Assert.equal(harness.service.updateCalls, 1, "the refresh still advances loading after a resize")
end

local function installPointerPassThrough(state)
  state.presentation = {
    mapInput = function(_, events)
      return events
    end,
    cancelPointers = function() end,
  }
end

local function scrollableChoiceHarness(optionCount)
  local controller = Controller.new()
  controller:setSection("Bag")
  local metrics = interactionMetrics()
  local options = {}
  for index = 1, optionCount do
    options[index] = { key = string.format("K%02d", index), label = "Choice " .. index }
  end
  local editor = ValueEditor.new({ kind = "choice", value = "K05", options = options })
  local holder = {}
  local function buildView()
    return {
      section = "Bag",
      status = "ready",
      ready = true,
      dirty = false,
      bagRows = {},
      valueEditor = editor:snapshot(),
      scope = { id = "value:choice", epoch = 1, kind = "value", focusId = controller.focus },
      scrollOffsets = controller.scrollOffsets,
      preserveChoiceScroll = holder.state ~= nil and holder.state.preserveChoiceScroll or false,
    }
  end
  local function buildLayout()
    return Layout.compute(buildView(), 256, 192, metrics)
  end
  local finished = 0
  local state = setmetatable({
    status = "ready",
    controller = controller,
    fieldInput = { beginUi = function() end },
    scopeEpoch = 0,
    valueEditor = editor,
    _snapshot = buildView,
    _resolve = function()
      return { content = { layout = buildLayout() } }
    end,
    _finishValueEditor = function()
      finished = finished + 1
    end,
  }, State)
  holder.state = state
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

function T.tests.container_scroll_keeps_focus_and_confirm_enters_a_visible_cursor()
  local flags = progressListHarness(progressFlagCatalog(20))
  local flagController, flagState = flags.controller, flags.state
  flagController:setFocus("list:flags")
  flags.sync()
  flagState:_consumeUiInput({ { type = "confirm" } })
  flags.sync()
  flagState:_consumeUiInput({ { type = "cancel" } })
  flags.sync()
  Assert.notNil(flagController:listCursor("flags"), "container browsing remembers its cursor row (flags)")
  flagState:wheelmoved(0, -30)
  flags.sync()
  Assert.equal(flagController.focus, "list:flags", "wheel scrolling keeps container focus (flags)")
  Assert.deepEqual(flags.activations, {}, "wheel scrolling never activates (flags)")
  local flagCursor = assertCursorAddressesVisibleRow(flagController, flags.current.layout, "flags", "flags")
  flagState:_consumeUiInput({ { type = "confirm" } })
  flags.sync()
  Assert.deepEqual(flags.activations, {}, "confirming the container never activates (flags)")
  Assert.equal(flagController.focus, flagCursor, "confirm enters the remembered cursor (flags)")
  assertCursorAddressesVisibleRow(flagController, flags.current.layout, "flags", "flags after confirm")

  local maps = overflowingLocationListHarness(800, 600, 30)
  local mapController, mapState = maps.controller, maps.state
  mapController:setFocus("list:location:map-list")
  mapState:_consumeUiInput({ { type = "confirm" } })
  mapState:_consumeUiInput({ { type = "cancel" } })
  Assert.equal(mapController.focus, "list:location:map-list", "map browsing starts from the container")
  Assert.notNil(
    mapController:listCursor("location:map-list"),
    "container browsing remembers its cursor row (map list)"
  )
  mapState:wheelmoved(0, -30)
  Assert.equal(
    mapController.focus,
    "list:location:map-list",
    "wheel scrolling keeps container focus (map list)"
  )
  Assert.deepEqual(maps.intents, {}, "wheel scrolling never starts map work (map list)")
  Assert.equal(mapController.locationMapId, 12, "wheel scrolling never commits a map (map list)")
  local mapCursor =
    assertCursorAddressesVisibleRow(mapController, maps.buildLayout(), "location:map-list", "map list")
  mapState:_consumeUiInput({ { type = "confirm" } })
  Assert.deepEqual(maps.intents, {}, "confirming the container never starts map work (map list)")
  Assert.equal(mapController.focus, mapCursor, "confirm enters the remembered cursor (map list)")
  Assert.equal(mapController.locationMapId, 12, "confirming the container never commits a map (map list)")
  assertCursorAddressesVisibleRow(mapController, maps.buildLayout(), "location:map-list", "map list after confirm")

  local choice = scrollableChoiceHarness(12)
  local choiceController, choiceState, choiceEditor = choice.controller, choice.state, choice.editor
  choiceController:setFocus("list:value:choice")
  choiceState:_consumeUiInput({ { type = "confirm" } })
  choiceState:_consumeUiInput({ { type = "cancel" } })
  Assert.equal(choiceController.focus, "list:value:choice", "choice browsing starts from the container")
  Assert.notNil(choiceController:listCursor("value:choice"), "container browsing remembers its cursor (choices)")
  choiceState:wheelmoved(0, -30)
  Assert.equal(choiceController.focus, "list:value:choice", "wheel scrolling keeps container focus (choices)")
  Assert.equal(choice.finishedCount(), 0, "wheel scrolling never submits the editor (choices)")
  Assert.isNil(choiceEditor:result(), "wheel scrolling publishes no result (choices)")
  local choiceCursor =
    assertCursorAddressesVisibleRow(choiceController, choice.buildLayout(), "value:choice", "choices")
  choiceState:_consumeUiInput({ { type = "confirm" } })
  Assert.equal(choice.finishedCount(), 0, "confirming the container never submits the editor (choices)")
  Assert.isNil(choiceEditor:result(), "confirming the container publishes no result (choices)")
  Assert.equal(choiceController.focus, choiceCursor, "confirm enters the remembered cursor (choices)")
  assertCursorAddressesVisibleRow(choiceController, choice.buildLayout(), "value:choice", "choices after confirm")
end

function T.tests.scrolling_reconciles_a_stale_cursor_to_the_nearest_visible_row()
  local harness = progressListHarness(progressFlagCatalog(20))
  local controller, state = harness.controller, harness.state
  controller:setFocus("list:flags")
  harness.sync()
  state:_consumeUiInput({ { type = "confirm" } })
  harness.sync()
  for _ = 1, 2 do
    state:_consumeUiInput({ { type = "navigate", direction = "down" } })
  end
  harness.sync()
  local rows = harness.current.layout.lists.flags.rowTargets
  Assert.equal(controller.focus, rows[3], "keyboard navigation reaches the third row")
  state:_consumeUiInput({ { type = "cancel" } })
  harness.sync()
  Assert.equal(controller:listCursor("flags"), rows[3], "leaving rows remembers the cursor")

  state:wheelmoved(0, -1)
  harness.sync()
  Assert.equal(controller.focus, "list:flags", "a small scroll keeps container focus")
  local viewport = assert(harness.current.layout.viewports.flags)
  if 3 >= viewport.firstIndex and 3 <= viewport.lastIndex then
    Assert.equal(
      controller:listCursor("flags"),
      rows[3],
      "a cursor that is still visible is kept"
    )
  end

  state:wheelmoved(0, -30)
  harness.sync()
  viewport = assert(harness.current.layout.viewports.flags)
  Assert.equal(controller.focus, "list:flags", "a far scroll keeps container focus")
  Assert.equal(
    controller:listCursor("flags"),
    rows[viewport.firstIndex],
    "a cursor above the visible range becomes the first visible row"
  )

  state:_consumeUiInput({ { type = "confirm" } })
  harness.sync()
  for _ = 1, 29 do
    state:_consumeUiInput({ { type = "navigate", direction = "down" } })
  end
  harness.sync()
  rows = harness.current.layout.lists.flags.rowTargets
  Assert.equal(controller.focus, rows[#rows], "keyboard navigation reaches the last row")
  state:_consumeUiInput({ { type = "cancel" } })
  harness.sync()
  Assert.equal(controller:listCursor("flags"), rows[#rows], "leaving rows remembers the last cursor")
  state:wheelmoved(0, 30)
  harness.sync()
  viewport = assert(harness.current.layout.viewports.flags)
  Assert.equal(controller.focus, "list:flags", "scrolling back up keeps container focus")
  Assert.equal(
    controller:listCursor("flags"),
    rows[viewport.lastIndex],
    "a cursor below the visible range becomes the last visible row"
  )

  controller:setListCursor("flags", nil)
  state:wheelmoved(0, -30)
  harness.sync()
  viewport = assert(harness.current.layout.viewports.flags)
  Assert.equal(
    controller:listCursor("flags"),
    rows[viewport.firstIndex],
    "a missing cursor becomes the first visible row"
  )

  state:textinput("zzz-no-such-flag")
  harness.sync()
  Assert.deepEqual(harness.current.layout.lists.flags.rowTargets, {}, "the filter empties the list")
  state:wheelmoved(0, -5)
  harness.sync()
  Assert.isNil(controller:listCursor("flags"), "an empty list keeps a nil cursor")
  Assert.equal(controller.focus, "list:flags", "an empty list keeps container focus")
end

function T.tests.pointer_row_focus_survives_back_then_confirm()
  local flags = progressListHarness(progressFlagCatalog(6))
  local flagController, flagState = flags.controller, flags.state
  installPointerPassThrough(flagState)
  flagController:setFocus("list:flags")
  flags.sync()
  flagState:_consumeUiInput({ { type = "confirm" } })
  flags.sync()
  flagState:_consumeUiInput({ { type = "cancel" } })
  flags.sync()
  local flagRows = flags.current.layout.lists.flags.rowTargets
  local flagTarget = flagRows[3]
  flagState:_pointer({ { type = "pointer_down", pointerId = "touch:flags", targetId = flagTarget, x = 8, y = 8 } })
  flags.sync()
  flagState:_pointer({ { type = "pointer_up", pointerId = "touch:flags", targetId = flagTarget, x = 8, y = 8 } })
  flags.sync()
  Assert.equal(flagController.focus, flagTarget, "a first tap focuses the tapped row (flags)")
  Assert.deepEqual(flags.activations, {}, "a first tap never activates (flags)")
  flagState:_consumeUiInput({ { type = "cancel" } })
  flags.sync()
  Assert.equal(flagController.focus, "list:flags", "Back returns to the container (flags)")
  Assert.equal(flagController:listCursor("flags"), flagTarget, "pointer focus synchronizes the cursor (flags)")
  flagState:_consumeUiInput({ { type = "confirm" } })
  flags.sync()
  Assert.equal(flagController.focus, flagTarget, "Confirm returns to the pointer-focused row (flags)")
  Assert.deepEqual(flags.activations, {}, "re-entering the row never activates (flags)")

  local maps = locationListHarness()
  local mapController, mapState = maps.controller, maps.state
  installPointerPassThrough(mapState)
  mapController:setFocus("list:location:map-list")
  mapState:_consumeUiInput({ { type = "confirm" } })
  mapState:_consumeUiInput({ { type = "cancel" } })
  Assert.equal(mapController.focus, "list:location:map-list", "map browsing starts from the container")
  mapState:_pointer({
    { type = "pointer_down", pointerId = "touch:maps", targetId = "location:map:47", x = 8, y = 8 },
  })
  mapState:_pointer({
    { type = "pointer_up", pointerId = "touch:maps", targetId = "location:map:47", x = 8, y = 8 },
  })
  Assert.equal(mapController.focus, "location:map:47", "a first tap focuses the tapped map row")
  Assert.deepEqual(maps.intents, {}, "a first tap never starts map work")
  Assert.equal(mapController.locationMapId, 12, "a first tap never commits a map")
  mapState:_consumeUiInput({ { type = "cancel" } })
  Assert.equal(mapController.focus, "list:location:map-list", "Back returns to the map container")
  Assert.equal(
    mapController:listCursor("location:map-list"),
    "location:map:47",
    "pointer focus synchronizes the map cursor"
  )
  mapState:_consumeUiInput({ { type = "confirm" } })
  Assert.equal(mapController.focus, "location:map:47", "Confirm returns to the pointer-focused map row")
  Assert.deepEqual(maps.intents, {}, "re-entering the row never starts map work")
  Assert.equal(mapController.locationMapId, 12, "re-entering the row never commits a map")

  local choice = scrollableChoiceHarness(12)
  local choiceController, choiceState, choiceEditor = choice.controller, choice.state, choice.editor
  installPointerPassThrough(choiceState)
  choiceController:setFocus("list:value:choice")
  choiceState:_consumeUiInput({ { type = "confirm" } })
  choiceState:_consumeUiInput({ { type = "cancel" } })
  Assert.equal(choiceController.focus, "list:value:choice", "choice browsing starts from the container")
  choiceState:_pointer({ { type = "pointer_down", pointerId = "touch:choice", targetId = "choice:K03", x = 8, y = 8 } })
  choiceState:_pointer({ { type = "pointer_up", pointerId = "touch:choice", targetId = "choice:K03", x = 8, y = 8 } })
  Assert.equal(choiceController.focus, "choice:K03", "a first tap focuses the tapped choice row")
  Assert.equal(choice.finishedCount(), 0, "a first tap never submits the editor")
  Assert.isNil(choiceEditor:result(), "a first tap publishes no result")
  choiceState:_consumeUiInput({ { type = "cancel" } })
  Assert.equal(choiceController.focus, "list:value:choice", "Back returns to the choice container")
  Assert.equal(choiceController:listCursor("value:choice"), "choice:K03", "pointer focus syncs the choice cursor")
  Assert.isNil(choiceEditor:result(), "Back publishes no result")
  choiceState:_consumeUiInput({ { type = "confirm" } })
  Assert.equal(choiceController.focus, "choice:K03", "Confirm returns to the pointer-focused choice row")
  Assert.equal(choice.finishedCount(), 0, "re-entering the row never submits the editor")
  Assert.isNil(choiceEditor:result(), "re-entering the row publishes no result")
end

function T.tests.location_map_keyboard_navigation_pages_without_selecting()
  local harness = overflowingLocationListHarness(256, 192, 30)
  local controller, state = harness.controller, harness.state
  local rows = harness.buildLayout().lists["location:map-list"].rowTargets
  Assert.equal(#rows, 30, "the long map list exposes every row in display order")
  local viewport = assert(harness.buildLayout().viewports["location:map-list"])
  local visibleCount = math.max(1, viewport.lastIndex - viewport.firstIndex + 1)
  Assert.isTrue(visibleCount < #rows, "the fixture list is longer than one viewport")

  controller:setFocus("list:location:map-list")
  state:_consumeUiInput({ { type = "confirm" } })
  Assert.equal(controller.focus, rows[1], "Confirm enters the first map row")
  Assert.equal(controller:listCursor("location:map-list"), rows[1], "entering rows sets the cursor")

  state:_consumeUiInput({ { type = "navigate", direction = "down" } })
  Assert.equal(controller.focus, rows[2], "Down moves one map row")
  Assert.equal(controller:listCursor("location:map-list"), rows[2], "the cursor follows row focus")
  state:_consumeUiInput({ { type = "navigate", direction = "up" } })
  Assert.equal(controller.focus, rows[1], "Up moves one map row")
  Assert.equal(controller:listCursor("location:map-list"), rows[1], "the cursor follows row focus upward")

  state:_consumeUiInput({ { type = "navigate", direction = "right" } })
  Assert.equal(controller.focus, rows[1 + visibleCount], "Right pages by one visible count")
  Assert.equal(
    controller:listCursor("location:map-list"),
    rows[1 + visibleCount],
    "the cursor follows paged focus"
  )
  Assert.isTrue(controller.locationMapOffset > 0, "paging reveals its target row through the viewport")
  state:_consumeUiInput({ { type = "navigate", direction = "left" } })
  Assert.equal(controller.focus, rows[1], "Left pages back by one visible count")
  Assert.equal(controller:listCursor("location:map-list"), rows[1], "the cursor follows the paged-back focus")

  state:_consumeUiInput({ { type = "navigate", direction = "left" } })
  Assert.equal(controller.focus, rows[1], "paging clamps at the first row instead of wrapping")
  for index = 2, #rows do
    state:_consumeUiInput({ { type = "navigate", direction = "down" } })
    Assert.equal(controller.focus, rows[index], "Down keeps walking rows (row " .. index .. ")")
    Assert.equal(controller:listCursor("location:map-list"), rows[index], "the cursor tracks focus (row " .. index .. ")")
  end
  state:_consumeUiInput({ { type = "navigate", direction = "right" } })
  Assert.equal(controller.focus, rows[#rows], "paging clamps at the last row instead of wrapping")

  Assert.equal(controller.locationMapId, 12, "keyboard browsing never changes the committed map")
  Assert.deepEqual(harness.intents, {}, "keyboard browsing never starts map work")

  state:_consumeUiInput({ { type = "cancel" } })
  Assert.equal(controller.focus, "list:location:map-list", "Back returns to the map-list container")
  state:_consumeUiInput({ { type = "confirm" } })
  Assert.equal(controller.focus, rows[#rows], "Confirm re-enters the remembered cursor row")
  Assert.equal(controller.locationMapId, 12, "re-entering rows never commits a map")
  Assert.deepEqual(harness.intents, {}, "re-entering rows never starts map work")
end

function T.tests.location_grid_directions_keep_grid_cursor_movement()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 7, fieldX = 10, fieldZ = 12 })
  controller:setFocus("location:grid")
  Assert.equal(controller.locationFocus, "grid", "grid focus uses grid movement")
  for _, direction in ipairs({ "up", "down", "left", "right" }) do
    Assert.deepEqual(
      controller:press(direction),
      { kind = "location-cursor-move", direction = direction },
      "grid focus keeps its Location direction (" .. direction .. ")"
    )
  end

  controller:setFocus("location:tile:10:12")
  Assert.equal(controller.locationFocus, "grid", "tile focus uses grid movement")
  for _, direction in ipairs({ "up", "down", "left", "right" }) do
    Assert.deepEqual(
      controller:press(direction),
      { kind = "location-cursor-move", direction = direction },
      "tile focus keeps its Location direction (" .. direction .. ")"
    )
  end

  local before = controller:locationSnapshot().cursor
  controller:moveLocationCursor("up", 7, 5)
  local after = controller:locationSnapshot().cursor
  Assert.notNil(after, "grid movement keeps a grid cursor")
  Assert.isFalse(before.fieldX == after.fieldX and before.fieldZ == after.fieldZ, "grid movement moves the cursor")
  Assert.equal(controller.locationFocus, "grid", "grid movement stays in grid focus")
  Assert.isNil(controller:listCursor("flags"), "grid movement touches no flag cursor")
  Assert.isNil(controller:listCursor("location:map-list"), "grid movement touches no map-list cursor")
  Assert.isNil(controller:listCursor("value:choice"), "grid movement touches no choice cursor")

  local harness = mapActivationHarness()
  local gridBefore = harness.controller:locationSnapshot().cursor
  harness.state:_performDeferred({ kind = "location-cursor-move", direction = "down" })
  local gridAfter = harness.controller:locationSnapshot().cursor
  Assert.notNil(gridAfter, "the deferred grid branch keeps a grid cursor")
  Assert.isFalse(
    gridBefore.fieldX == gridAfter.fieldX and gridBefore.fieldZ == gridAfter.fieldZ,
    "the deferred grid branch moves the cursor"
  )
  Assert.equal(harness.service.updateCalls, 1, "grid movement still advances loading through the service")
end

local function twoButtonGraph()
  return {
    money = { up = {}, down = { "dialogue-frame" }, left = {}, right = {} },
    ["dialogue-frame"] = { up = { "money" }, down = {}, left = {}, right = {} },
  }
end

function T.tests.directional_input_marks_visible_focus_while_pointer_down_hides_it()
  local controller = Controller.new()
  local graph = twoButtonGraph()
  controller:setFocus("money")
  Assert.equal(controller.focusVisible, false, "fresh editors hide the keyboard focus ring")
  controller:markKeyboardNavigation()
  controller:moveFocus(graph, "down")
  Assert.equal(controller.focus, "dialogue-frame", "directional input moves logical focus")
  Assert.equal(controller.focusVisible, true, "directional input marks focus visible")
  Assert.equal(controller.section, "Player", "moving focus never activates a section")
  Assert.isNil(
    controller:pointer({ type = "pointer_down", pointerId = "touch:ring", targetId = "money", x = 8, y = 8 }),
    "pointer press never activates on press"
  )
  Assert.equal(controller.focus, "money", "pointer selection still establishes logical focus")
  Assert.equal(controller.focusVisible, false, "pointer selection hides the keyboard focus ring")
  controller:markKeyboardNavigation()
  controller:moveFocus(graph, "down")
  Assert.equal(controller.focus, "dialogue-frame", "directional input moves focus after pointer use")
  Assert.equal(controller.focusVisible, true, "directional input restores the ring")
end

function T.tests.pointer_down_on_the_focused_target_still_hides_visible_focus()
  local controller = Controller.new()
  local graph = twoButtonGraph()
  controller:setFocus("money")
  controller:markKeyboardNavigation()
  controller:moveFocus(graph, "down")
  Assert.equal(controller.focusVisible, true, "directional input marks focus visible")
  controller:pointer({
    type = "pointer_down",
    pointerId = "touch:same",
    targetId = "dialogue-frame",
    x = 8,
    y = 8,
  })
  Assert.equal(controller.focus, "dialogue-frame", "pointer keeps the already focused target")
  Assert.equal(controller.focusVisible, false, "pointer hides the ring even without moving focus")
end

function T.tests.programmatic_section_entry_does_not_enable_visible_focus()
  local controller = Controller.new()
  controller:pointer({ type = "pointer_down", pointerId = "touch:entry", targetId = "money", x = 8, y = 8 })
  Assert.equal(controller.focusVisible, false, "pointer selection hides the ring")
  controller:setSection("Bag")
  Assert.equal(controller.focusVisible, false, "programmatic section entry never shows the ring by itself")
end

function T.tests.merely_focusing_a_section_never_activates_it()
  local controller = Controller.new()
  controller:setFocus("section:Bag")
  Assert.equal(controller.focus, "section:Bag", "focus can rest on a section option")
  Assert.equal(controller.section, "Player", "focused section options stay inactive until activated")
end

function T.tests.scope_replacement_restores_remembered_focus_when_current_is_gone()
  local controller = Controller.new()
  local graph = {
    money = { up = {}, down = {}, left = {}, right = {} },
    ["dialogue-frame"] = { up = {}, down = {}, left = {}, right = {} },
  }
  controller.scopeId = "scope:one"
  controller:setFocus("money")
  controller.scopeId = "scope:two"
  controller:setFocus("save")
  controller.scopeId = "scope:one"
  local resolved = controller:reconcileFocus(graph, "save", { "dialogue-frame" })
  Assert.equal(resolved, "money", "replacement restores the remembered scope focus when current is gone")
  Assert.equal(controller.focus, "money", "reconciliation publishes the remembered focus")
  Assert.equal(controller.focusVisible, false, "reconciliation never shows the ring by itself")
end

function T.tests.repeated_flag_snapshots_reuse_the_filtered_catalog_until_the_query_changes()
  local controller = Controller.new()
  local state = setmetatable({ controller = controller }, State)
  local opening = state:_flagRows({})
  Assert.isTrue(#opening > 0, "the catalog exposes flag rows")
  Assert.isTrue(state:_flagRows({}) == opening, "snapshots without query changes reuse the cached rows")
  local sample = opening[1]
  local values = { [sample.id] = true }
  local refreshed = state:_flagRows(values)
  Assert.isTrue(refreshed == opening, "value refresh never rebuilds the cached descriptors")
  Assert.equal(refreshed[1].value, true, "refreshed rows still reflect the latest session flags")
  local cleared = state:_flagRows({})
  Assert.isTrue(cleared == opening, "clearing flags reuses the cached rows")
  Assert.equal(cleared[1].value, false, "cleared flags read back as disabled")
  controller.query = sample.name:sub(1, 8):lower()
  local filtered = state:_flagRows({})
  Assert.isFalse(filtered == opening, "a changed query rebuilds the filtered order once")
  Assert.isTrue(state:_flagRows({}) == filtered, "the rebuilt filter is reused while the query is stable")
  Assert.isTrue(#filtered < #opening, "filtering narrows the catalog")
  for _, row in ipairs(filtered) do
    Assert.notNil(row.targetId, "cached rows carry their stable target identity")
  end
end

function T.tests.moving_past_the_visible_window_reveals_and_focuses_the_next_row()
  local harness = progressListHarness(progressFlagCatalog(30))
  local controller, state = harness.controller, harness.state
  harness.sync()
  local viewport = assert(harness.current.layout.viewports.flags)
  local rows = harness.current.layout.lists.flags.rowTargets
  controller:setFocus(rows[viewport.lastIndex])
  state:_consumeUiInput({ { type = "navigate", direction = "down" } })
  harness.sync()
  local nextRow = rows[viewport.lastIndex + 1]
  Assert.equal(controller.focus, nextRow, "Down from the last visible row focuses the next logical row")
  local fresh = harness.current.layout
  Assert.notNil(fresh.focusGraph[nextRow], "the revealed row joins the focus graph")
  Assert.notNil(fresh.targets[nextRow], "the revealed row materializes its target")
  Assert.isTrue(
    (controller.scrollOffsets.flags or 0) > 0,
    "the viewport offset advances to reveal the focused row"
  )
end

function T.tests.paging_from_a_row_lands_on_a_revealed_row_outside_the_previous_window()
  local harness = progressListHarness(progressFlagCatalog(40))
  local controller, state = harness.controller, harness.state
  harness.sync()
  local rows = harness.current.layout.lists.flags.rowTargets
  controller:setFocus(rows[1])
  state:_consumeUiInput({ { type = "navigate", direction = "right" } })
  harness.sync()
  local fresh = harness.current.layout
  Assert.isFalse(controller.focus == rows[1], "Right pages away from the first row")
  Assert.notNil(fresh.focusGraph[controller.focus], "the paged row joins the focus graph")
  Assert.notNil(fresh.targets[controller.focus], "the paged row materializes its target")
end

function T.tests.filtering_away_the_focused_row_reconciles_to_a_visible_live_row()
  local harness = progressListHarness(progressFlagCatalog(30))
  local controller, state = harness.controller, harness.state
  harness.sync()
  local list = harness.current.layout.lists.flags
  local focused = list.rowTargets[5]
  controller:setFocus(focused)
  state:_filterFocusedList(list, 5, "append", "test_flag_02")
  harness.sync()
  local fresh = harness.current.layout.lists.flags
  Assert.isTrue(#fresh.rowTargets > 0, "the filter keeps live rows")
  Assert.notNil(
    harness.current.layout.focusGraph[controller.focus],
    "the reconciled focus joins the visible graph"
  )
  Assert.notNil(harness.current.layout.targets[controller.focus], "the reconciled focus has a target")
  local live = false
  for _, targetId in ipairs(fresh.rowTargets) do
    if targetId == controller.focus then
      live = true
      break
    end
  end
  Assert.isTrue(live, "the reconciled focus is a live filtered row")
end

function T.tests.pointer_targets_cover_only_visible_rows_and_empty_lists_stay_stable()
  local harness = progressListHarness(progressFlagCatalog(30))
  harness.sync()
  local layout = harness.current.layout
  local viewport = assert(layout.viewports.flags)
  local rows = layout.lists.flags.rowTargets
  local visible = layout.targets[rows[viewport.firstIndex]]
  Assert.notNil(visible, "the first visible row has a target")
  local rect = visible.rect
  Assert.equal(
    Layout.hitTest(layout, harness.current.view, rect.x + rect.width / 2, rect.y + 1),
    rows[viewport.firstIndex],
    "pointer input reaches the visible row"
  )
  Assert.isNil(
    layout.targets[rows[#rows]],
    "the last logical row has no target at the top offset"
  )
  local list = layout.lists.flags
  harness.controller.query = ""
  harness.state:_filterFocusedList(list, nil, "append", "zzz-no-such-flag")
  harness.sync()
  local empty = harness.current.layout
  Assert.deepEqual(empty.lists.flags.rowTargets, {}, "an unmatched query leaves no logical rows")
  local container = assert(empty.targets["list:flags"], "the empty list keeps its container target")
  Assert.isTrue(container.focusable, "the empty container stays focusable")
  Assert.equal(
    Layout.hitTest(
      empty,
      harness.current.view,
      container.rect.x + container.rect.width / 2,
      container.rect.y + container.rect.height / 2
    ),
    "list:flags",
    "pointer input on the empty list reaches its container"
  )
  harness.controller:setFocus("list:flags")
  harness.sync()
  harness.state:_consumeUiInput({ { type = "confirm" } })
  Assert.equal(harness.controller.focus, "list:flags", "confirm on an empty list keeps container focus")
  Assert.equal(#harness.activations, 0, "confirm on an empty list never activates")
end

function T.tests.scope_replacement_falls_back_to_the_explicit_default()
  local controller = Controller.new()
  local graph = {
    ["dialogue-frame"] = { up = {}, down = {}, left = {}, right = {} },
  }
  controller.scopeId = "scope:one"
  controller.focus = "money"
  local resolved = controller:reconcileFocus(graph, "money", { "missing", "dialogue-frame" })
  Assert.equal(resolved, "dialogue-frame", "replacement selects the first live ordered fallback")
  Assert.equal(controller.focusVisible, false, "fallback reconciliation never shows the ring by itself")
end

local function backHarness(options)
  options = options or {}
  local controller = Controller.new()
  controller:setSection(options.section or "Player")
  if options.partyDetail then
    controller:selectPartySlot(0)
  end
  if options.bagItem then
    controller.bagItemKey = options.bagItem
    controller.focus = "bag:item:" .. options.bagItem
  end
  if options.mapList then
    controller:enterLocation({ mapId = 7, fieldX = 10, fieldZ = 12 })
    controller:openLocationMaps()
  end
  if options.grid then
    controller:enterLocation({ mapId = 7, fieldX = 10, fieldZ = 12 })
    controller:chooseLocationMap(7, 10, 12)
  end
  if options.modal then
    controller:openModal(options.modal)
  end
  local session = {
    dirty = options.dirty == true,
    partyRevision = function()
      return 0
    end,
    partySnapshot = function()
      return { revision = 0, members = {} }
    end,
    discardedSections = {},
    globalDiscards = 0,
    bagSnapshot = function()
      return {}
    end,
    isDirty = function(self)
      return self.dirty
    end,
    snapshot = function()
      return { dirtySections = {}, location = { mapId = 7, fieldX = 10, fieldZ = 12 } }
    end,
    discardSection = function(self, section)
      self.discardedSections[#self.discardedSections + 1] = section
      return true
    end,
    discard = function(self)
      self.globalDiscards = self.globalDiscards + 1
      return true
    end,
  }
  local results = {}
  local state = setmetatable({
    status = "ready",
    disposed = false,
    approvedExit = false,
    controller = controller,
    session = session,
    valueEditor = options.valueEditor,
    monDraft = options.monDraft,
    locationService = options.locationService,
    fieldInput = { beginUi = function() end },
    scopeEpoch = 0,
    locationServiceMapId = options.locationServiceMapId,
    locationViewport = options.locationViewport,
    errorMessage = nil,
    pendingDraftAction = nil,
    onResult = function(result)
      results[#results + 1] = result
    end,
  }, State)
  return { controller = controller, session = session, state = state, results = results }
end

function T.tests.every_section_button_activates_its_section_directly()
  local harness = backHarness({ section = "Player" })
  for _, name in ipairs({ "Location", "Player", "Party", "Bag", "Progress" }) do
    harness.state:_activate("section:" .. name)
    Assert.equal(harness.controller.section, name, "the " .. name .. " button enters its section")
  end
end

function T.tests.back_cancels_only_the_open_value_editor()
  local canceled = 0
  local editor = {
    cancel = function()
      canceled = canceled + 1
    end,
  }
  local harness = backHarness({ section = "Player", dirty = true, valueEditor = editor })
  harness.state:_requestBack()
  Assert.equal(canceled, 1, "the value editor is canceled once")
  Assert.isNil(harness.state.valueEditor, "the editor layer is gone")
  Assert.isNil(harness.controller.modal, "no decision layer opens")
  Assert.isNil(harness.state.closeRequest, "the dirty session never enters its leave flow")
  Assert.deepEqual(harness.results, {}, "one Back never leaves the editor")
end

function T.tests.back_closes_only_the_open_decision()
  local harness = backHarness({ section = "Player", dirty = true, modal = "remove" })
  harness.state:_requestBack()
  Assert.isNil(harness.controller.modal, "the decision layer is gone")
  Assert.isNil(harness.state.closeRequest, "the dirty session never enters its leave flow")
  Assert.deepEqual(harness.results, {}, "one Back never leaves the editor")
end

local function livePartyHarness(memberCount)
  local Fixture = require("app.tests.support.SaveEditorFixture")
  local fixture = Fixture.new()
  local Session = require("app.src.saveeditor.SaveEditorSession")
  local session = assert(Session.new({
    record = fixture.initial,
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    validateRecord = fixture.validateRecord,
    symbols = fixture.symbols,
  }))
  for _ = 1, memberCount or 0 do
    local draft = assert(session:beginMonAdd("CHIKORITA", {
      location = 7,
      date = { year = 2000, month = 1, day = 1 },
    }))
    Assert.isTrue(session:applyMonDraft(draft).ok, "harness members apply cleanly")
  end
  local controller = Controller.new()
  controller:setSection("Party")
  local PartyView = require("app.src.saveeditor.SaveEditorPartyView")
  local state = setmetatable({
    status = "ready",
    disposed = false,
    approvedExit = false,
    controller = controller,
    session = session,
    dependencies = { context = fixture.context },
    partyView = PartyView.new(fixture.context),
    fieldInput = { beginUi = function() end },
    scopeEpoch = 0,
    monDraft = nil,
    valueEditor = nil,
    valuePurpose = nil,
    activeDraftField = nil,
    valueReturnFocus = nil,
    pendingFocusReturn = nil,
    pendingDraftAction = nil,
    errorMessage = nil,
    dateProvider = function()
      return { year = 2000, month = 1, day = 1 }
    end,
    onResult = function() end,
  }, State)
  return { state = state, controller = controller, session = session }
end

function T.tests.entering_party_selects_the_first_member_with_an_edit_draft()
  local harness = livePartyHarness(3)
  Assert.isNil(harness.controller.partySlot0, "section entry alone selects no member")
  harness.state:_ensurePartyDraft()
  Assert.equal(harness.controller.partySlot0, 0, "the first member is selected by default")
  Assert.equal(harness.controller.partyTab, "Stats", "the default page is Stats")
  local draft = harness.state.monDraft
  Assert.notNil(draft, "selecting a member opens its edit draft without an Edit action")
  Assert.equal(draft:mode(), "edit")
  Assert.equal(draft:slot0(), 0)

  local empty = livePartyHarness(0)
  empty.state:_ensurePartyDraft()
  Assert.isNil(empty.controller.partySlot0, "an empty party selects no member")
  Assert.isNil(empty.state.monDraft, "an empty party opens no draft")
end

function T.tests.switching_members_applies_a_valid_dirty_draft()
  local harness = livePartyHarness(2)
  harness.state:_ensurePartyDraft()
  Assert.isTrue(harness.state.monDraft:setScalar("friendship", 200))
  harness.state:_activate("party:slot:1")
  Assert.equal(harness.controller.partySlot0, 1, "selection moves after the draft applies")
  Assert.equal(harness.session:partySnapshot().members[1].mon.friendship, 200)
  Assert.equal(harness.state.monDraft:slot0(), 1, "the new member context owns a fresh draft")
  Assert.isNil(harness.state.errorMessage)
end

function T.tests.invalid_draft_blocks_leaving_the_member()
  local harness = livePartyHarness(2)
  harness.state:_ensurePartyDraft()
  local draft = harness.state.monDraft
  Assert.isTrue(draft:setScalar("currentHp", 9999), "the invalid value stages in the draft")
  harness.state:_activate("party:slot:1")
  Assert.equal(harness.controller.partySlot0, 0, "selection stays on the invalid member")
  Assert.equal(harness.state.monDraft, draft, "the invalid draft is preserved")
  Assert.notNil(harness.state.errorMessage, "the validation error is shown")
  Assert.equal(harness.session:partySnapshot().members[1].mon.condition.currentHp ~= 9999, true)
end

function T.tests.paging_preserves_the_open_draft_without_applying()
  local harness = livePartyHarness(1)
  harness.state:_ensurePartyDraft()
  local draft = harness.state.monDraft
  local revision = harness.session:partyRevision()
  Assert.isTrue(draft:setScalar("friendship", 150))
  harness.state:_activate("party:page:next")
  Assert.equal(harness.controller.partyTab, "Moves", "next advances Stats to Moves")
  Assert.equal(harness.state.monDraft, draft, "paging never recreates the draft")
  harness.state:_activate("party:page:next")
  Assert.equal(harness.controller.partyTab, "Details", "next advances Moves to Details")
  harness.state:_activate("party:page:next")
  Assert.equal(harness.controller.partyTab, "Details", "next is disabled on Details")
  harness.state:_activate("party:page:previous")
  Assert.equal(harness.controller.partyTab, "Moves", "previous returns to Moves")
  harness.state:_activate("party:page:previous")
  Assert.equal(harness.controller.partyTab, "Stats", "previous returns to Stats")
  harness.state:_activate("party:page:previous")
  Assert.equal(harness.controller.partyTab, "Stats", "previous is disabled on Stats")
  Assert.equal(harness.session:partyRevision(), revision, "paging never publishes the draft")
  Assert.isTrue(harness.state.monDraft:isDirty(), "the dirty draft survives paging")
end

function T.tests.section_switch_applies_the_open_draft()
  local harness = livePartyHarness(1)
  harness.state:_ensurePartyDraft()
  Assert.isTrue(harness.state.monDraft:setScalar("friendship", 77))
  harness.state:_activate("section:Player")
  Assert.equal(harness.controller.section, "Player", "the section switch proceeds")
  Assert.equal(harness.session:partySnapshot().members[1].mon.friendship, 77)
  Assert.isNil(harness.state.monDraft, "the applied draft is retired")
end

function T.tests.member_switch_applies_a_provisional_add_on_a_full_strip()
  local harness = livePartyHarness(5)
  local provisional = assert(harness.session:beginMonAdd("CHIKORITA", {
    location = 7,
    date = { year = 2000, month = 1, day = 1 },
  }))
  harness.state.monDraft = provisional
  harness.controller.partySlot0 = #harness.session:partySnapshot().members
  local selector = assert(harness.state:_partyView().partySelector, "Party publishes its member strip")
  local kinds = {}
  for _, slot in ipairs(selector.slots) do
    kinds[#kinds + 1] = slot.kind
  end
  Assert.deepEqual(
    kinds,
    { "member", "member", "member", "member", "member", "member" },
    "the provisional add occupies the final strip position with no room left for Add"
  )
  harness.state:_activate("party:slot:0")
  Assert.equal(#harness.session:partySnapshot().members, 6, "the member switch applies the provisional add")
  Assert.equal(harness.controller.partySlot0, 0, "selection follows the requested member")
  Assert.equal(harness.state.monDraft:mode(), "edit", "the new member context owns a fresh edit draft")
  Assert.isNil(harness.state.errorMessage)
end

function T.tests.move_slot_opens_a_three_action_overlay_returning_from_its_children()
  local harness = livePartyHarness(1)
  harness.state:_ensurePartyDraft()
  harness.state:_activate("party:page:next")
  Assert.equal(harness.controller.partyTab, "Moves")
  harness.state:_activate("party:move:0")
  Assert.equal(harness.controller.modal, "party-move", "an occupied slot opens its move overlay")
  Assert.equal(harness.state.pendingMoveSlot, 0)
  harness.state:_activate("party-move:pp-ups")
  Assert.notNil(harness.state.valueEditor, "the component opens a child editor")
  Assert.isNil(harness.controller.modal, "the child editor sits above the suspended overlay")
  Assert.isTrue(harness.state.valueEditor:press("confirm"), "the unchanged value confirms")
  harness.state:_finishValueEditor()
  Assert.isNil(harness.state.valueEditor, "the child editor retires")
  Assert.equal(harness.controller.modal, "party-move", "a finished child returns to its parent overlay")
  harness.state:_requestBack()
  Assert.isNil(harness.controller.modal, "Back pops the parent overlay")
  Assert.equal(harness.controller.partyTab, "Moves", "Back lands on the Moves page")
  Assert.isNil(harness.state.closeRequest, "popping the overlay never enters the leave flow")
end

function T.tests.member_removal_has_no_party_path()
  local harness = livePartyHarness(2)
  harness.state:_ensurePartyDraft()
  harness.state:_activate("party:remove")
  Assert.isNil(harness.controller.modal, "no removal decision opens")
  Assert.equal(#harness.session:partySnapshot().members, 2, "no member is removed")
  Assert.equal(harness.controller.partySlot0, 0, "selection is untouched")
end

function T.tests.back_from_party_applies_a_valid_draft_before_the_leave_flow()
  local harness = livePartyHarness(1)
  harness.state:_ensurePartyDraft()
  Assert.isTrue(harness.state.monDraft:setScalar("friendship", 42))
  harness.state:_requestBack()
  Assert.equal(harness.session:partySnapshot().members[1].mon.friendship, 42)
  Assert.notNil(harness.state.closeRequest, "root Back with staged work enters the leave flow")
  Assert.equal(harness.controller.modal, "leave", "the leave decision opens")
end

function T.tests.back_from_party_with_an_invalid_draft_stays_put()
  local harness = livePartyHarness(1)
  harness.state:_ensurePartyDraft()
  local draft = harness.state.monDraft
  Assert.isTrue(draft:setScalar("currentHp", 9999))
  harness.state:_requestBack()
  Assert.equal(harness.state.monDraft, draft, "the invalid draft is preserved")
  Assert.notNil(harness.state.errorMessage, "the validation error is shown")
  Assert.isNil(harness.state.closeRequest, "an invalid draft never enters the leave flow")
end

function T.tests.back_from_a_selected_bag_item_returns_to_its_pocket()
  local harness = backHarness({ section = "Bag", dirty = true, bagItem = "POTION" })
  harness.state:_requestBack()
  Assert.isNil(harness.controller.bagItemKey, "the item layer is gone")
  Assert.equal(harness.controller.focus, "bag:pocket:items", "focus returns to the pocket")
  Assert.isNil(harness.state.closeRequest, "the dirty session never enters its leave flow")
  Assert.deepEqual(harness.results, {}, "one Back never leaves the editor")
end

function T.tests.back_from_coordinate_selection_returns_to_the_map_list_and_releases_grid_work()
  local releases = 0
  local service = {
    releaseGrid = function()
      releases = releases + 1
    end,
  }
  local harness = backHarness({ section = "Location", dirty = true, grid = true, locationService = service })
  Assert.equal(harness.controller.locationPage, "grid", "the harness starts inside coordinate selection")
  harness.state:_requestBack()
  Assert.equal(harness.controller.locationPage, "map-list", "one Back returns to the map list")
  Assert.equal(
    harness.controller.focus,
    "list:location:map-list",
    "one Back focuses the map-list container"
  )
  Assert.equal(releases, 1, "abandoned grid work is released exactly once")
  Assert.isNil(harness.state.closeRequest, "Back from an inner mode never enters the leave flow")
  Assert.deepEqual(harness.results, {}, "one Back never leaves the editor")
end

function T.tests.back_from_the_map_list_root_follows_the_normal_leave_path()
  local dirty = backHarness({ section = "Location", dirty = true, mapList = true })
  Assert.equal(dirty.controller.locationPage, "map-list", "the harness starts at the map list root")
  dirty.state:_requestBack()
  Assert.equal(dirty.controller.locationPage, "map-list", "root Back stays on the map list")
  Assert.notNil(dirty.state.closeRequest, "root Back with staged work enters the leave flow")
  Assert.deepEqual(dirty.results, {}, "entering the leave flow never leaves the editor")

  local clean = backHarness({ section = "Location", dirty = false, mapList = true })
  clean.state:_requestBack()
  Assert.deepEqual(clean.results, { { kind = "main_menu" } }, "root Back without work leaves the editor")
end

function T.tests.activating_the_staged_map_keeps_its_coordinates_while_other_maps_use_their_default()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 12, fieldX = 40, fieldZ = 50 })
  controller:openLocationMaps()
  local state = setmetatable({
    status = "ready",
    controller = controller,
    dependencies = {
      world = {
        maps = {
          { worldOriginX = 1000, worldOriginZ = 2000 },
          { worldOriginX = 100, worldOriginZ = 200 },
        },
        byId = { [12] = 1, [34] = 2 },
      },
    },
    fieldInput = { beginUi = function() end },
    scopeEpoch = 0,
    session = {
      snapshot = function()
        return { location = { mapId = 12, fieldX = 40, fieldZ = 50 } }
      end,
    },
  }, State)
  state:_performDeferred({ kind = "location-map-select", mapId = 12 })
  local staged = controller:locationSnapshot()
  Assert.equal(staged.page, "grid", "activation enters coordinate selection")
  Assert.deepEqual(staged.center, { fieldX = 40, fieldZ = 50 }, "the staged map keeps its staged coordinates")
  state:_performDeferred({ kind = "location-map-select", mapId = 34 })
  local other = controller:locationSnapshot()
  Assert.deepEqual(other.center, { fieldX = 116, fieldZ = 216 }, "another map starts from its record default")
end

function T.tests.empty_map_filter_keeps_confirm_inert_on_the_container()
  local harness = locationListHarness()
  local controller, state = harness.controller, harness.state
  controller:setFocus("list:location:map-list")
  controller.query = "zzz-no-such-map"
  local layout = harness.buildLayout()
  local list = assert(layout.lists["location:map-list"], "the plan publishes the map list record")
  Assert.isTrue(list.empty, "zero filtered maps mark the list empty")
  state:_consumeUiInput({ { type = "confirm" } })
  Assert.equal(#harness.intents, 0, "Confirm on an empty map list selects nothing")
  Assert.equal(controller.focus, "list:location:map-list", "Confirm on an empty map list keeps container focus")
end

function T.tests.back_from_a_root_section_with_staged_work_enters_the_leave_flow()
  local harness = backHarness({ section = "Player", dirty = true })
  harness.state:_requestBack()
  Assert.notNil(harness.state.closeRequest, "root Back alone enters the leave flow")
  Assert.equal(harness.controller.modal, "leave", "the leave decision opens")
  Assert.deepEqual(harness.results, {}, "entering the leave flow never leaves the editor")
end

function T.tests.back_from_a_clean_root_section_leaves_the_editor()
  local harness = backHarness({ section = "Player", dirty = false })
  harness.state:_requestBack()
  Assert.deepEqual(harness.results, { { kind = "main_menu" } }, "root Back without work leaves the editor")
end

function T.tests.footer_discard_resets_only_the_active_section()
  local harness = backHarness({ section = "Progress", dirty = true })
  harness.state:_activate("discard")
  Assert.deepEqual(harness.session.discardedSections, { "Progress" }, "footer Discard resets its own section")
  Assert.equal(harness.session.globalDiscards, 0, "footer Discard never resets the whole session")
end

function T.tests.footer_discard_abandons_a_party_draft_with_its_section()
  local harness = livePartyHarness(2)
  Assert.isTrue(harness.session:save(false).ok, "the harness roster persists before staging edits")
  harness.state:_ensurePartyDraft()
  Assert.isTrue(harness.state.monDraft:setScalar("friendship", 199))
  Assert.isTrue(harness.session:setMoney(3100).ok, "money stages in another section")
  harness.state:_activate("discard")
  Assert.isTrue(harness.session:snapshot().dirtySections.money, "other sections stay staged")
  Assert.isFalse(
    harness.session:snapshot().dirtySections.party,
    "the Party baseline is restored without applying"
  )
  Assert.equal(harness.controller.partySlot0, 0, "the same slot stays selected")
  local fresh = harness.state.monDraft
  Assert.notNil(fresh, "a fresh draft opens for the restored member")
  Assert.isFalse(fresh:isDirty(), "the fresh draft starts clean")
end

local function observationHarness()
  local FieldInput = require("libs.hgss.src.field.FieldInput")
  local controller = Controller.new()
  controller:pointer({ type = "pointer_down", pointerId = "touch:hold", targetId = "money", x = 4, y = 6 })
  local session = {
    snapshot = function()
      return {
        flags = {},
        money = 0,
        frameIndex = 0,
        revision = 1,
        locationChanged = false,
        location = { mapId = 7, fieldX = 10, fieldZ = 12 },
        originalLocation = { mapId = 7, fieldX = 10, fieldZ = 12 },
        dirtySections = {},
      }
    end,
    isDirty = function()
      return false
    end,
  }
  local iconPrepCalls = 0
  local state = setmetatable({
    status = "ready",
    width = 256,
    height = 192,
    controller = controller,
    session = session,
    dependencies = { cacheFs = {} },
    derivedAssets = {},
    displayContext = {
      measure = function()
        return {}
      end,
    },
    renderer = {
      graphics = {},
      text = {},
      metrics = function()
        return {
          lineHeight = 14,
          measure = function(text)
            return #text * 7
          end,
        }
      end,
      prepareVisibleIcons = function()
        iconPrepCalls = iconPrepCalls + 1
      end,
    },
    presentation = {
      resolve = function()
        return { content = { layout = {} } }
      end,
    },
    fieldInput = FieldInput.new(),
    inputTick = 0,
    activeScopeId = "stale-scope",
    scopeEpoch = 7,
    numberHold = {
      pointerId = "touch:hold",
      targetId = "number:delta:1",
      delta = 1,
      scopeEpoch = 7,
      nextTick = 100,
    },
    numberPressUntilTick = 0,
    valueEditor = nil,
    valuePurpose = nil,
    monDraft = nil,
    locationService = nil,
    iconStatus = nil,
    iconFailure = nil,
  }, State)
  controller.scopeId, controller.scopeEpoch = "section:Player:map-list", 7
  return state, function()
    return iconPrepCalls
  end
end

function T.tests.repeated_observation_keeps_interaction_state_and_resource_requests_still()
  local state, iconPrepCalls = observationHarness()
  local heldPointer = state.controller.pointerId
  local heldTarget = state.controller.capturedTarget

  local first = state:view()
  Assert.notNil(state.numberHold, "observation never cancels a held repeat")
  Assert.equal(state.scopeEpoch, 7, "observation never advances the scope epoch")
  Assert.equal(state.controller.pointerId, heldPointer, "observation never drops a held pointer")
  Assert.equal(state.controller.capturedTarget, heldTarget, "observation never drops a held capture")
  Assert.equal(state.controller.focus, "money", "observation never moves focus")
  local second = state:view()
  Assert.equal(second.scope.id, first.scope.id, "repeated observations describe the same scope")
  Assert.equal(second.scope.epoch, first.scope.epoch, "repeated observations describe the same epoch")

  local originalDraw = ApplicationPresentation.draw
  ApplicationPresentation.draw = function() end
  local ok, drawError = pcall(function()
    state:draw()
  end)
  ApplicationPresentation.draw = originalDraw
  Assert.isTrue(ok, "draw runs without platform rendering: " .. tostring(drawError))
  Assert.equal(iconPrepCalls(), 0, "draw never requests derived icon work")
  Assert.notNil(state.numberHold, "drawing never cancels a held repeat")
  Assert.equal(state.scopeEpoch, 7, "drawing never advances the scope epoch")
end

function T.tests.scope_transitions_cancel_stale_input_before_later_events_act()
  local controller = Controller.new()
  controller:pointer({ type = "pointer_down", pointerId = "touch:stale", targetId = "money", x = 4, y = 6 })
  local state = setmetatable({
    status = "ready",
    controller = controller,
    monDraft = nil,
    errorMessage = nil,
    fieldInput = {
      beginUi = function() end,
      uiSnapshot = function()
        return {}
      end,
    },
    activeScopeId = "section:Player:map-list",
    scopeEpoch = 3,
    numberHold = {
      pointerId = "touch:stale",
      targetId = "number:delta:1",
      delta = 1,
      scopeEpoch = 3,
      nextTick = 100,
    },
    numberPressTarget = nil,
    _reconcileFocus = function()
      return {}
    end,
  }, State)
  controller.scopeId, controller.scopeEpoch = "section:Player:map-list", 3
  controller.focus = "section:Bag"

  state:_consumeUiInput({ { type = "confirm" } })
  Assert.equal(state.scopeEpoch, 4, "the section transition settles its scope before later events act")
  Assert.equal(controller.scopeId, "section:Bag:items", "the settled scope names the entered section")
  Assert.equal(controller.scopeEpoch, 4, "the controller observes the settled epoch")
  Assert.isNil(state.numberHold, "the transition cancels the previous number hold")
  Assert.isNil(controller.capturedTarget, "the transition cancels the previous capture")
  Assert.isNil(controller.pointerId, "the transition releases the previous pointer")

  Assert.isNil(
    controller:pointer({ type = "pointer_up", pointerId = "touch:stale", targetId = "money", x = 4, y = 6 }),
    "a release from the retired press cannot activate its old target"
  )
  Assert.isNil(
    controller:pointer(
      { type = "pointer_down", pointerId = "touch:fresh", targetId = "bag:pocket:items", x = 4, y = 6 }
    ),
    "a fresh press only captures its target"
  )
  Assert.equal(controller.pointerId, "touch:fresh", "fresh navigation works after the transition")
  Assert.deepEqual(
    controller:pointer(
      { type = "pointer_up", pointerId = "touch:fresh", targetId = "bag:pocket:items", x = 4, y = 6 }
    ),
    { kind = "activate", targetId = "bag:pocket:items" },
    "a clean tap on the new section activates"
  )
end

function T.tests.every_modal_action_renders_hits_and_executes_from_one_description()
  local loaded, Decisions = pcall(require, "app.src.saveeditor.SaveEditorDecisions")
  Assert.isTrue(loaded, "modal actions come from one decision vocabulary")
  local expectations = {
    ["bag-item"] = {
      { id = "bag:quantity", label = "Quantity", semantic = "secondary" },
      { id = "bag:remove", label = "Remove", semantic = "destructive" },
      { id = "cancel", label = "Cancel", semantic = "secondary" },
    },
    ["party-move"] = {
      { id = "party-move:move", label = "Move", semantic = "secondary" },
      { id = "party-move:pp", label = "Current PP", semantic = "secondary" },
      { id = "party-move:pp-ups", label = "PP Ups", semantic = "secondary" },
      { id = "cancel", label = "Cancel", semantic = "secondary" },
    },
    ["remove"] = {
      { id = "remove", label = "Remove", semantic = "destructive" },
      { id = "cancel", label = "Cancel", semantic = "secondary" },
    },
    ["leave"] = {
      { id = "save", label = "Save & exit", semantic = "primary" },
      { id = "discard", label = "Discard all", semantic = "destructive" },
      { id = "cancel", label = "Cancel", semantic = "secondary" },
    },
  }
  for kind, expected in pairs(expectations) do
    local facts = kind == "leave" and { pendingSave = false } or {}
    local actions = Decisions.describe(kind, facts)
    Assert.equal(#actions, #expected, kind .. " publishes its closed action set")
    for index, want in ipairs(expected) do
      local action = assert(actions[index], kind .. " action " .. index .. " is ordered")
      Assert.equal(action.id, want.id, kind .. " action " .. index .. " keeps its target spelling")
      Assert.equal(action.label, want.label, kind .. " action " .. want.id .. " keeps its caption")
      Assert.equal(action.semantic, want.semantic, kind .. " action " .. want.id .. " keeps its role")
      Assert.isTrue(action.enabled, kind .. " action " .. want.id .. " stays enabled")
      Assert.equal(type(action.command), "string", kind .. " action " .. want.id .. " carries a command")
    end
    local view = {
      section = "Player",
      status = "ready",
      ready = true,
      dirty = false,
      session = { playerName = "PLAYER", money = 0, frameIndex = 0 },
      modal = kind,
      focus = "cancel",
      scope = { id = "decision:" .. kind, epoch = 1, kind = "decision", focusId = "cancel" },
      decisionActions = actions,
      textMetrics = {
        lineHeight = 14,
        measure = function(text)
          return #text * 7
        end,
      },
    }
    local layout = Layout.compute(view, 256, 192, view.textMetrics)
    Assert.notNil(layout.decisionList, kind .. " publishes its decision surface")
    Assert.equal(#layout.decisionList.rows, #expected, kind .. " renders every described action")
    for index, want in ipairs(expected) do
      local row = assert(layout.decisionList.rows[index], kind .. " row " .. index .. " is ordered")
      Assert.equal(row.targetId, want.id, kind .. " row " .. index .. " keeps its target spelling")
      Assert.equal(row.label, want.label, kind .. " row " .. want.id .. " paints the described caption")
      Assert.equal(row.semantic, want.semantic, kind .. " row " .. want.id .. " paints the described role")
      Assert.notNil(layout.targets[want.id], kind .. " action " .. want.id .. " is hittable")
      local centerX = row.rect.x + math.floor(row.rect.width / 2)
      local centerY = row.rect.y + math.floor(row.rect.height / 2)
      Assert.equal(Layout.hitTest(layout, view, centerX, centerY), want.id, kind .. " action " .. want.id .. " hits its row")
    end
  end
  local publisher, publisherIconPrep = observationHarness()
  for kind in pairs(expectations) do
    publisher.controller.modal = kind
    publisher.controller.focus = "cancel"
    local published = publisher:_snapshot()
    Assert.deepEqual(
      published.decisionActions,
      Decisions.describe(kind, kind == "leave" and { pendingSave = false } or {}),
      kind .. " publishes its canonical actions without mutating interaction state"
    )
    Assert.notNil(publisher.numberHold, kind .. " publication never cancels a held repeat")
  end
  publisher.controller.modal = nil
  Assert.equal(publisherIconPrep(), 0, "publication never requests derived icon work")
  local pendingSave = Decisions.describe("leave", { pendingSave = true })
  Assert.equal(
    pendingSave[1].command,
    "cancel_pending_save",
    "a save target during verification cancels the check instead of saving"
  )
  local idleSave = Decisions.describe("leave", { pendingSave = false })
  Assert.equal(idleSave[1].command, "save", "an idle save target saves")
  local unknownOk = pcall(Decisions.describe, "leave-everything", {})
  Assert.isFalse(unknownOk, "an unknown decision kind is a programming error, not an implicit leave")
end

local function scopedDecisionView()
  return {
    section = "Bag",
    status = "ready",
    ready = true,
    dirty = true,
    modal = "bag-item",
    scope = { id = "decision:bag-item", epoch = 1, kind = "decision", focusId = "cancel" },
    decisionActions = {
      { id = "bag:quantity", label = "Quantity", semantic = "secondary", enabled = true, command = "bag_quantity" },
      { id = "bag:remove", label = "Remove", semantic = "destructive", enabled = false, command = "bag_remove" },
      { id = "cancel", label = "Cancel", semantic = "secondary", enabled = true, command = "cancel" },
    },
    textMetrics = {
      lineHeight = 14,
      measure = function(text)
        return #text * 7
      end,
    },
  }
end

local function scopedBagView()
  local tabs, pockets = {}, {}
  for index, key in ipairs({ "items", "balls" }) do
    tabs[index] = { x = (index - 1) * 32, y = 0, width = 32, height = 32 }
    pockets[index] = { key = key }
  end
  local rows = {
    { item = "POKE_BALL", label = "Poke Ball", quantity = 3 },
    { item = "POTION", label = "Potion", quantity = 1 },
  }
  return {
    section = "Bag",
    status = "ready",
    ready = true,
    dirty = false,
    scope = { id = "section:Bag", epoch = 0, kind = "section" },
    bagPocket = "items",
    bagPocketTabRects = tabs,
    bagPockets = pockets,
    bagRows = rows,
    bagPageRows = rows,
    bagPage0 = 0,
    bagPageCount = 1,
  }
end

function T.tests.scoped_focus_and_pointer_hits_agree_on_active_targets()
  local metrics = interactionMetrics()
  local decisionView = scopedDecisionView()
  local decisionLayout = Layout.compute(decisionView, 256, 192, metrics)
  Assert.isNil(decisionLayout.targets.save, "a decision scope prunes the background save target")
  Assert.isNil(decisionLayout.targets.discard, "a decision scope prunes the background discard target")
  Assert.isNil(decisionLayout.targets.back, "a decision scope prunes the background back target")
  for _, focusId in ipairs(decisionLayout.focusOrder) do
    Assert.isTrue(
      focusId == "bag:quantity" or focusId == "cancel",
      "a decision scope focuses only its enabled actions, found " .. focusId
    )
  end
  local enabledRow = assert(decisionLayout.decisionList.rows[1])
  Assert.equal(
    Layout.hitTest(
      decisionLayout,
      decisionView,
      enabledRow.rect.x + 1,
      enabledRow.rect.y + 1
    ),
    "bag:quantity",
    "a press on an enabled decision activates it"
  )
  local disabledRow = assert(decisionLayout.decisionList.rows[2])
  Assert.isNil(
    Layout.hitTest(
      decisionLayout,
      decisionView,
      disabledRow.rect.x + math.floor(disabledRow.rect.width / 2),
      disabledRow.rect.y + math.floor(disabledRow.rect.height / 2)
    ),
    "a press on a disabled decision never activates"
  )
  local controller = Controller.new()
  controller:setFocus("cancel")
  for _, direction in ipairs({ "up", "down", "left", "right" }) do
    controller:setFocus("cancel")
    controller:moveFocus(decisionLayout.focusGraph, direction)
    Assert.isTrue(
      controller.focus == "cancel" or controller.focus == "bag:quantity",
      "decision focus stays on enabled actions, got " .. controller.focus
    )
  end

  local bagView = scopedBagView()
  local bagLayout = Layout.compute(bagView, 800, 600, metrics)
  local firstCell = assert(bagLayout.focusGraph["bag:item:POKE_BALL"], "the first cell joins the focus graph")
  Assert.deepEqual(firstCell.right, { "bag:item:POTION" }, "the first column reaches right into the second")
  Assert.equal(firstCell.left[1], "bag:item:POKE_BALL", "the first column clamps left onto itself")
  local secondCell = assert(bagLayout.focusGraph["bag:item:POTION"], "the second cell joins the focus graph")
  Assert.deepEqual(secondCell.left, { "bag:item:POKE_BALL" }, "the second column reaches left into the first")
  Assert.equal(secondCell.right[1], "bag:item:POTION", "the second column clamps right onto itself")
  Assert.equal(
    firstCell.up[1],
    "bag:pocket:items",
    "the top row rises into its pocket tab"
  )
  local pocket = assert(bagLayout.focusGraph["bag:pocket:items"], "pocket tabs join the focus graph")
  Assert.deepEqual(pocket.right, { "bag:pocket:balls" }, "pocket tabs wrap horizontally")
  local itemTarget = assert(bagLayout.targets["bag:item:POKE_BALL"]).rect
  Assert.equal(
    Layout.hitTest(bagLayout, bagView, itemTarget.x + 1, itemTarget.y + 1),
    "bag:item:POKE_BALL",
    "a press on a grid cell resolves to its item"
  )

  local gridView = {
    section = "Location",
    status = "ready",
    ready = true,
    dirty = false,
    scope = { id = "section:Location", epoch = 0, kind = "section" },
    session = { playerName = "P", money = 0, frameIndex = 0 },
    location = {
      mapId = 12,
      symbol = "MAP_TEST_ROUTE",
      map = { mapId = 12, symbol = "MAP_TEST_ROUTE", section = "TEST" },
      section = "TEST",
      generation = 1,
      status = { state = "ready" },
      tiles = { { fieldX = 32, fieldZ = 48, selectable = true } },
      cursor = { fieldX = 32, fieldZ = 48 },
    },
    locationNavigation = {
      page = "grid",
      mapId = 12,
      cursor = { fieldX = 32, fieldZ = 48 },
      center = { fieldX = 32, fieldZ = 48 },
      mapOffset = 0,
    },
  }
  local gridLayout = Layout.compute(gridView, 800, 600, metrics)
  local grid = assert(gridLayout.locationGrid, "coordinate selection publishes its grid")
  local tileColumn = 32 - grid.firstFieldX
  local tileRow = 48 - grid.firstFieldZ
  local tileX = grid.originX + tileColumn * grid.tileSize + 1
  local tileY = grid.originY + tileRow * grid.tileSize + 1
  Assert.equal(
    Layout.hitTest(gridLayout, gridView, tileX, tileY),
    "location:tile:32:48",
    "a press inside the grid converts to its field coordinates"
  )
  local modalGridView = {
    section = "Location",
    status = "ready",
    ready = true,
    dirty = true,
    modal = "leave",
    scope = { id = "decision:leave", epoch = 2, kind = "decision", focusId = "cancel" },
    session = gridView.session,
    location = gridView.location,
    locationNavigation = gridView.locationNavigation,
    decisionActions = {
      { id = "save", label = "Save", semantic = "primary", enabled = false, command = "save" },
      { id = "discard", label = "Discard", semantic = "destructive", enabled = true, command = "discard" },
      { id = "cancel", label = "Cancel", semantic = "secondary", enabled = true, command = "cancel" },
    },
  }
  local modalGridLayout = Layout.compute(modalGridView, 800, 600, metrics)
  local modalTile = Layout.hitTest(modalGridLayout, modalGridView, tileX, tileY)
  Assert.isTrue(
    modalTile == nil or modalTile:match("^location:tile:") == nil,
    "a decision scope never resolves a background grid tile"
  )
end

return T
