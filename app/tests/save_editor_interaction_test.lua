-- Active editor scopes reject background targets and incomplete gestures.

local Assert = require("tests.support.Assert")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local Controller = require("app.src.saveeditor.SaveEditorController")
local DisplayContext = require("libs.ui.src.DisplayContext")
local Interface = require("app.src.saveeditor.SaveEditorInterface")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local Layout = require("app.src.saveeditor.SaveEditorLayout")
local Renderer = require("app.src.saveeditor.SaveEditorRenderer")
local State = require("app.src.saveeditor.SaveEditorState")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local ScrollViewport = require("libs.ui.src.ScrollViewport")
local ValueEditor = require("app.src.saveeditor.SaveEditorValueEditor")
local ModalStack = require("app.src.saveeditor.SaveEditorModalStack")
local FieldInput = require("libs.hgss.src.field.FieldInput")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local T = { tests = {} }

local function stateHarness(fields)
  fields.fieldInput = fields.fieldInput or FieldInput.new()
  fields.scopeEpoch = fields.scopeEpoch or 0
  fields.inputTick = fields.inputTick or 0
  fields.locationPreviewMemory = fields.locationPreviewMemory or {}
  local state = setmetatable(fields, State)
  state:_syncScope()
  return state
end

local function activate(state, targetId)
  state.inputTick = state.inputTick or 0
  state.numberPressUntilTick = state.numberPressUntilTick or 0
  local view = state:_snapshot()
  if view.session ~= nil then
    local session = {}
    for key, value in pairs(view.session) do
      session[key] = value
    end
    session.frameIndex = session.frameIndex or 0
    view.session = session
  end
  local metrics = view.textMetrics
    or {
      lineHeight = 14,
      measure = function(text)
        return #text * 7
      end,
    }
  view.numberControlVisuals = { increment = { normal = { width = 8, height = 8 } } }
  local layout = Layout.compute(view, 800, 600, metrics)
  state:_activateControl(targetId, layout)
end

local function prepareLocationList(state, listId)
  state:_locationListCache(listId)
  while state._locationListCaches[listId] == nil do
    state:_advanceLocationPreparation(256)
  end
end

function T.tests.static_party_focus_moves_do_not_reveal_or_activate_controls()
  local metrics = {
    lineHeight = 14,
    measure = function(text)
      return #text * 7
    end,
  }
  local partyController = Controller.new()
  partyController:setSection("Party")
  partyController:setFocus("party:slot:0")
  local partyLayout = Layout.compute({
    ready = true,
    status = "ready",
    dirty = false,
    sectionDirty = false,
    section = "Party",
    scope = partyController:snapshot().scope,
    partyTab = "Moves",
    partySelector = {
      slots = {
        { kind = "member", slot0 = 0 },
        { kind = "member", slot0 = 1 },
        { kind = "empty" },
        { kind = "empty" },
        { kind = "empty" },
        { kind = "empty" },
      },
    },
    partyMoves = { slots = { { kind = "move", slot0 = 0, targetId = "party:move:0" } } },
  }, 800, 600, metrics)
  local partyState = setmetatable({ controller = partyController, valueEditor = nil }, State)

  partyState:_navigate(partyLayout, "right")

  Assert.equal(partyController.focus, "party:slot:1", "direction advances within the static Party member strip")
  Assert.equal(partyController.section, "Party", "directional focus does not activate another section")
  Assert.deepEqual(partyController.scrollOffsets, {}, "static Party focus does not change viewport offsets")

  partyController:setFocus("party:page:previous")
  partyState:_navigate(partyLayout, "right")
  Assert.equal(partyController.focus, "party:page:next", "direction advances within the static Party pager")

  partyController:setFocus("party:page:previous")
  partyState:_navigateTab(partyLayout, "next")
  Assert.equal(partyController.focus, "party:move:0", "Tab enters the static Party moves sequence")
end

function T.tests.static_bag_focus_moves_do_not_reveal_or_activate_controls()
  local metrics = {
    lineHeight = 14,
    measure = function(text)
      return #text * 7
    end,
  }
  local bagController = Controller.new()
  bagController:setSection("Bag")
  bagController:setFocus("bag:pocket:items")
  local bagLayout = Layout.compute({
    ready = true,
    status = "ready",
    dirty = false,
    sectionDirty = false,
    section = "Bag",
    scope = bagController:snapshot().scope,
    bagPockets = { { key = "items" }, { key = "medicine" } },
    bagPocketTabRects = {
      { x = 0, y = 0, width = 40, height = 20 },
      { x = 42, y = 0, width = 40, height = 20 },
    },
    bagPageRows = {},
    bagPage0 = 0,
    bagPageCount = 2,
    bagAddEnabled = true,
  }, 256, 192, metrics)
  local bagState = setmetatable({ controller = bagController, valueEditor = nil }, State)

  bagState:_navigate(bagLayout, "right")

  Assert.equal(bagController.focus, "bag:pocket:medicine", "direction advances within the static Bag pocket strip")
  Assert.equal(bagController.section, "Bag", "directional focus does not activate another section")
  Assert.deepEqual(bagController.scrollOffsets, {}, "static Bag focus does not change viewport offsets")

  bagController:setFocus("bag:page:next")
  bagState:_navigate(bagLayout, "right")
  Assert.equal(bagController.focus, "bag:add", "direction advances within static Bag actions")
end

function T.tests.progress_section_navigation_does_not_request_scrolling()
  local controller = Controller.new()
  controller:setSection("Progress")
  controller:setFocus("section:Progress")
  local layout = Layout.compute(
    {
      ready = true,
      status = "ready",
      dirty = false,
      sectionDirty = false,
      section = "Progress",
      scope = controller:snapshot().scope,
      query = "",
      scrollOffsets = {},
      flagModel = {
        count = 0,
        rowTargets = {},
        indexByTarget = {},
        rowAt = function()
          return nil
        end,
        idAt = function()
          return nil
        end,
      },
    },
    800,
    600,
    {
      lineHeight = 14,
      measure = function(text)
        return #text * 7
      end,
    }
  )
  local sectionTargets = {}
  for _, control in ipairs(layout.focusNavigation.controls) do
    if control.regionId == "sections" then
      sectionTargets[#sectionTargets + 1] = control.id
    end
  end
  Assert.isTrue(#sectionTargets >= 2, "the real Progress layout publishes multiple section controls")
  controller:setFocus(sectionTargets[1])
  local state = setmetatable({ controller = controller, valueEditor = nil }, State)

  state:_navigate(layout, "down")

  Assert.equal(controller.focus, sectionTargets[2], "the section rail follows its published logical order")
  Assert.equal(controller.section, "Progress", "section focus does not activate a different section")
  Assert.deepEqual(controller.scrollOffsets, {}, "section focus does not change viewport offsets")
end

function T.tests.location_section_entry_always_opens_the_map_list()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 7, fieldX = 10, fieldZ = 12 })
  Assert.equal(controller:snapshot().location.page, "root", "section entry opens the map-section root")
  Assert.equal(controller.focus, "list:location:root", "section entry focuses the map-section container")

  controller:chooseLocationMap(7, 10, 12)
  Assert.equal(controller:snapshot().location.page, "grid", "map activation enters coordinate selection")

  controller:setSection("Player")
  controller:setSection("Location")
  Assert.equal(controller:snapshot().location.page, "root", "returning to the section reopens the hierarchy root")
  Assert.equal(controller.focus, "list:location:root", "returning focuses the hierarchy root container")
end

function T.tests.activating_the_current_section_does_not_reset_coordinate_selection()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:chooseLocationMap(7, 10, 12)
  controller:setSection("Location")
  Assert.equal(controller:locationSnapshot().page, "grid", "the active section button is a no-op")
end

function T.tests.location_section_starts_at_map_hierarchy_root_without_choosing_a_map()
  local controller = Controller.new()
  controller:setSection("Location")

  local location = controller:locationSnapshot()
  Assert.equal(location.page, "root", "Location opens at the map-section root")
  Assert.isNil(location.groupId, "opening the root does not choose a map section")
  Assert.isNil(location.mapId, "opening the root does not activate a map")
end

function T.tests.saved_destination_seeds_root_group_and_first_leaf_focus()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:rememberLocationDestination("location:group:9", "location:map:72")

  Assert.equal(
    controller.locationMemory.root.cursor,
    "location:group:9",
    "the root starts at the saved map's source section"
  )
  controller:enterLocationGroup("location:group:9")
  Assert.equal(controller.focus, "location:map:72", "the first visit starts at the saved map leaf")

  controller:backLocation()
  controller:enterLocationGroup("location:group:9")
  Assert.equal(controller.focus, "location:map:72", "group memory remains the cursor owner on later visits")
end

function T.tests.carried_root_query_overrides_stale_group_filter_memory()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocationGroup("location:group:9")
  controller.query = "PREVIOUS"
  controller:backLocation()
  controller.query = "CHILD_ONLY_MATCH"

  controller:enterLocationGroup("location:group:9", "CHILD_ONLY_MATCH")

  Assert.equal(controller.query, "CHILD_ONLY_MATCH", "a root child match filters the entered group")
end

function T.tests.map_hierarchy_filtering_can_switch_queries_after_a_completed_filter()
  local state = stateHarness({
    controller = Controller.new(),
    locationService = {
      mapSummaries = function()
        return {
          {
            mapId = 7,
            mapSectionNativeId = 1,
            symbol = "MAP_ALPHA",
            section = "ALPHA_SECTION",
            displayName = "ALPHA_ROUTE",
          },
          {
            mapId = 8,
            mapSectionNativeId = 2,
            symbol = "MAP_BETA",
            section = "BETA_SECTION",
            displayName = "BETA_ROUTE",
          },
        }
      end,
    },
    _locationListCaches = {},
    _listFilterTask = nil,
    _listQueryRevision = 0,
  })
  state._locationMapCatalog =
    require("app.src.saveeditor.SaveEditorMapCatalog").new(state.locationService:mapSummaries())
  prepareLocationList(state, "location:root")
  state.controller:setSection("Location")
  state.controller.query = "ALPHA"
  state:_mapProjection()
  state:_advanceListFilter(10)
  Assert.deepEqual(
    state:_mapProjection().rowTargets,
    { "location:group:1" },
    "the first query filters the complete section catalog"
  )

  state.controller.query = "BETA"
  state:_mapProjection()
  state:_advanceListFilter(10)
  Assert.deepEqual(
    state:_mapProjection().rowTargets,
    { "location:group:2" },
    "a later query still filters the complete section catalog"
  )
end

function T.tests.map_group_entry_uses_projections_prepared_before_navigation()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 7, fieldX = 10, fieldZ = 12 })
  local state = stateHarness({
    controller = controller,
    locationService = {
      mapSummaries = function()
        return {
          {
            mapId = 7,
            mapSectionNativeId = 1,
            symbol = "MAP_ALPHA",
            section = "ALPHA_SECTION",
            displayName = "ALPHA_ROUTE",
          },
          {
            mapId = 8,
            mapSectionNativeId = 2,
            symbol = "MAP_BETA",
            section = "BETA_SECTION",
            displayName = "BETA_ROUTE",
          },
        }
      end,
    },
    _locationListCaches = {},
    _listFilterTask = nil,
    _listQueryRevision = 0,
  })
  state._locationMapCatalog =
    require("app.src.saveeditor.SaveEditorMapCatalog").new(state.locationService:mapSummaries())
  prepareLocationList(state, "location:root")

  local catalog = assert(state._locationMapCatalog)
  local mapProjectionCalls = 0
  local projectMaps = catalog.maps
  catalog.maps = function(_, groupId, query)
    mapProjectionCalls = mapProjectionCalls + 1
    return projectMaps(catalog, groupId, query)
  end
  state:_performDeferred({ kind = "location-group-select", groupId = "location:group:1" })
  Assert.equal(mapProjectionCalls, 0, "group entry never prepares a cold map projection in the input path")
  Assert.isNil(state._locationListCaches["location:group:1"], "entry does not materialize the group list synchronously")

  controller:backLocation()
  prepareLocationList(state, "location:group:1")
  local preparedCalls = mapProjectionCalls
  state:_performDeferred({ kind = "location-group-select", groupId = "location:group:1" })
  Assert.equal(mapProjectionCalls, preparedCalls, "readiness preparation leaves group entry projection-free")
  Assert.notNil(state._locationListCaches["location:group:1"], "group entry reuses its prepared indexed rows")
  Assert.equal(controller:locationSnapshot().page, "group", "preparation preserves group navigation")
end

function T.tests.location_hierarchy_back_restores_each_level_query_cursor_and_scroll()
  local groupId, mapId, leafTargetId = "test-group", 41, "location:map:41"
  local controller = Controller.new()
  controller:setSection("Location")

  Assert.equal(controller:locationSnapshot().page, "root", "Location starts at the source-section root")
  controller.query = "Shared"
  controller:setFocus(groupId)
  controller.scrollOffset = 6
  local rootMemory = {
    query = controller.query,
    cursor = controller.focus,
    scroll = controller.scrollOffset,
  }
  local groupEntry = controller:press("confirm")
  Assert.deepEqual(groupEntry, { kind = "activate", targetId = groupId }, "confirm activates the focused group")
  Assert.isTrue(type(controller.enterLocationGroup) == "function", "Controller enters a selected source group")
  controller:enterLocationGroup(groupId)
  Assert.equal(controller:locationSnapshot().page, "group", "group activation opens its map leaves")

  controller.query = "ALPHA"
  controller:setFocus(leafTargetId)
  controller.scrollOffset = 3
  local groupMemory = {
    query = controller.query,
    cursor = controller.focus,
    scroll = controller.scrollOffset,
  }
  local leafActivation = controller:press("confirm")
  Assert.deepEqual(leafActivation, { kind = "activate", targetId = leafTargetId }, "confirm activates a focused leaf")
  controller:chooseLocationMap(mapId, 12, 18)
  Assert.equal(controller:locationSnapshot().page, "grid", "leaf activation enters coordinate selection")

  Assert.isTrue(type(controller.backLocation) == "function", "Controller exposes one Location Back transition")
  controller:backLocation()
  Assert.equal(controller:locationSnapshot().page, "group", "first Back returns from grid to the group list")
  Assert.deepEqual(
    { query = controller.query, cursor = controller.focus, scroll = controller.scrollOffset },
    groupMemory,
    "Back restores the group query, leaf cursor, and scroll"
  )
  controller:backLocation()
  Assert.equal(controller:locationSnapshot().page, "root", "second Back returns to the root")
  Assert.deepEqual(
    { query = controller.query, cursor = controller.focus, scroll = controller.scrollOffset },
    rootMemory,
    "Back restores the root query, group cursor, and scroll"
  )

  controller:enterLocationGroup(groupId)
  Assert.deepEqual(
    { query = controller.query, cursor = controller.focus, scroll = controller.scrollOffset },
    groupMemory,
    "re-entering a group restores its independent list memory"
  )
  controller.query = "no matching maps"
  controller:backLocation()
  Assert.equal(controller:locationSnapshot().page, "root", "Back escapes an empty filtered group")
end

function T.tests.entering_the_same_map_preserves_the_grid_while_section_entry_resets_to_the_list()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 7, fieldX = 10, fieldZ = 12 })
  controller:chooseLocationMap(7, 10, 12)
  controller:enterLocation({ mapId = 7, fieldX = 14, fieldZ = 18 })
  Assert.equal(controller:snapshot().location.page, "grid", "staged sync on the same map stays in coordinate selection")
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
    controller:pointer({ type = "pointer_down", pointerId = pointerId, targetId = "number:place:0:up" })
    local adjustments = 0
    local state = stateHarness({
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
        targetId = "number:place:0:up",
        delta = 1,
        scopeEpoch = controller.scopeEpoch,
        nextTick = 1,
      },
      scopeEpoch = 0,
      _snapshot = function()
        return {}
      end,
      _resolve = function()
        return { content = { layout = {} } }
      end,
      _reconcileFocus = function() end,
      _dispatchIntent = function() end,
      valueEditor = {
        snapshot = function()
          return { pending = false }
        end,
        update = function()
          return 0
        end,
        adjustPlace = function()
          adjustments = adjustments + 1
        end,
      },
    })
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
      count = #options,
      idAt = function(index)
        return rowTargets[index]
      end,
      indexOf = function(targetId)
        return indexByTarget[targetId]
      end,
      rowAt = function(index)
        return options[index]
      end,
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
    Assert.equal(ordered, visible, "focus order matches the materialized choice window: " .. targetId)
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

local function numberInputHarness(width, height)
  local controller = Controller.new()
  local editor = ValueEditor.new({ kind = "integer", value = 123, min = 0, max = 999, base = "decimal" })
  local metrics = interactionMetrics()
  local session = {
    saveId = "number-input",
    versionId = "heartgold",
    playerName = "PLAYER",
    money = 123,
    frameIndex = 0,
  }
  local state = stateHarness({
    status = "ready",
    width = width,
    height = height,
    session = session,
    controller = controller,
    modalStack = ModalStack.new(),
    modalLayerSequence = 0,
    presentation = {
      cancelPointers = function() end,
      mapInput = function(_, events)
        return events
      end,
    },
    _snapshot = function(self)
      local valueEditor = self.valueEditor and self.valueEditor:snapshot() or nil
      return {
        status = self.status,
        ready = true,
        dirty = false,
        sectionDirty = false,
        section = self.controller.section,
        scope = {
          id = valueEditor and "value:money" or "section:Player",
          epoch = self.scopeEpoch,
          kind = valueEditor and "value" or "section",
          focusId = self.controller.focus,
        },
        focus = self.controller.focus,
        focusVisible = self.controller.focusVisible,
        session = session,
        valueEditor = valueEditor,
        numberControlVisuals = {
          increment = { normal = { width = 8, height = 8 }, pressed = { width = 8, height = 8 } },
          decrement = { normal = { width = 8, height = 8 }, pressed = { width = 8, height = 8 } },
        },
        numberPressTicks = 1,
        textMetrics = metrics,
      }
    end,
    _resolve = function(self, view)
      return { content = { layout = Layout.compute(view, self.width, self.height, metrics) } }
    end,
  })
  state:_installValueEditor(editor, "money", "money")
  state:_syncScope()
  return state, editor
end

local function indexedMapModel(maps)
  local rowTargets, indexByTarget = {}, {}
  for index, map in ipairs(maps) do
    local targetId = "location:map:" .. map.mapId
    rowTargets[index] = targetId
    indexByTarget[targetId] = index
  end
  return {
    revision = 1,
    queryRevision = 0,
    pending = false,
    count = #maps,
    rowTargets = rowTargets,
    indexByTarget = indexByTarget,
    idAt = function(index)
      return rowTargets[index]
    end,
    indexOf = function(targetId)
      return indexByTarget[targetId]
    end,
    rowAt = function(index)
      return maps[index]
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
      flagRowAt = function(index)
        return rows[index]
      end,
      flagRowTargets = rowTargets,
      flagIndexByTarget = indexByTarget,
      flagModel = {
        revision = 1,
        queryRevision = 0,
        pending = false,
        count = #rows,
        rowTargets = rowTargets,
        indexByTarget = indexByTarget,
        idAt = function(index)
          return rowTargets[index]
        end,
        indexOf = function(targetId)
          return indexByTarget[targetId]
        end,
        rowAt = function(index)
          return rows[index]
        end,
      },
      scrollOffsets = controller.scrollOffsets,
    }
  end
  local function buildLayout()
    return Layout.compute(buildView(), 256, 192, metrics)
  end
  local current = { view = buildView(), layout = buildLayout() }
  local activations = {}
  local backs = 0
  local state = stateHarness({
    status = "ready",
    controller = controller,
    fieldInput = FieldInput.new(),
    scopeEpoch = 0,
    _snapshot = buildView,
    _resolve = function()
      return { content = { layout = buildLayout() } }
    end,
    _activate = function(_, targetId)
      activations[#activations + 1] = targetId
    end,
    _dispatchActivationAction = function(_, action)
      Assert.equal(action.kind, "progress.toggle-flag", "flag activation arrives as a typed action")
      activations[#activations + 1] = "flag:" .. action.name
    end,
    _requestBack = function()
      backs = backs + 1
    end,
  })
  local function sync()
    current.view = buildView()
    current.layout = buildLayout()
    state:_reconcileFocus(nil, current.layout)
    current.view = buildView()
    current.layout = buildLayout()
  end
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

function T.tests.focused_list_focus_starts_on_the_row_and_activation_is_explicit()
  local harness = progressListHarness(progressFlagCatalog(6))
  local controller, state = harness.controller, harness.state
  controller:setFocus("list:flags")
  harness.sync()
  Assert.notNil(harness.current.layout.lists, "the plan must publish one record per interactive list")
  local list = assert(harness.current.layout.lists.flags, "the flag list must publish its interaction record")
  Assert.equal(list.targetId, "list:flags", "the container target identifies the whole list")

  Assert.equal(#harness.activations, 0, "entering row focus never activates a row")
  local firstRow = list.rowTargets[1]
  Assert.equal(controller.focus, firstRow, "the list opens directly on its first row: " .. controller.focus)

  state:_consumeUiInput({ { type = "navigate", direction = "down" } })
  harness.sync()
  local secondRow = harness.current.layout.lists.flags.rowTargets[2]
  Assert.equal(controller.focus, secondRow, "Down moves one row")
  Assert.equal(#harness.activations, 0, "browsing rows never activates")

  state:_consumeUiInput({ { type = "cancel" } })
  harness.sync()
  Assert.equal(controller.focus, secondRow, "Back leaves the logical cursor intact")
  Assert.equal(harness.backCount(), 1, "Back exits the active page scope")
  Assert.equal(#harness.activations, 0, "leaving row focus never activates")

  controller:setFocus(list.targetId)
  harness.sync()
  state:_consumeUiInput({ { type = "confirm" } })
  harness.sync()
  Assert.equal(#harness.activations, 1, "explicit activation runs once")
  Assert.equal(controller.focus, secondRow, "reconciliation restores the remembered logical row")
end

function T.tests.focused_list_row_navigation_uses_logical_adjacency_and_back_exits_scope()
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
  state:_consumeUiInput({ { type = "navigate", direction = "left" } })
  Assert.isTrue(controller.focus ~= rows[2], "Left exits the list region instead of paging rows")

  controller:setFocus(rows[1])
  local last = rows[#rows]
  for _ = 2, #rows do
    state:_consumeUiInput({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(controller.focus, last, "logical Down reaches the last row beyond the viewport")
  Assert.equal(controller.focus, last, "list navigation has no automatic wrap")

  state:_consumeUiInput({ { type = "cancel" } })
  Assert.equal(controller.focus, last, "Back preserves the logical row identity")
  Assert.equal(harness.backCount(), 1, "Back exits the current page scope")
  Assert.equal(#harness.activations, 0, "row navigation and Back never activate")
end

function T.tests.reconciling_a_logical_list_focus_reveals_it_once_and_honors_variable_anchors()
  local harness = progressListHarness(progressFlagCatalog(40))
  local controller, state = harness.controller, harness.state
  local list = assert(harness.current.layout.lists.flags)
  local viewport = assert(harness.current.layout.viewports.flags)
  local offscreen = list.rowTargets[#list.rowTargets]

  controller:setFocus(offscreen)
  state:_reconcileFocus(offscreen, harness.current.layout)
  Assert.equal(
    controller.scrollOffsets.flags,
    viewport.contentExtent - viewport.clip.height,
    "focus reconciliation reveals a distant uniform row"
  )
  harness.sync()
  local revealed = assert(harness.current.layout.viewports.flags)
  Assert.isTrue(
    revealed.firstIndex <= #list.rowTargets and #list.rowTargets <= revealed.lastIndex,
    "the focused row is in the re-resolved viewport"
  )

  controller.scrollOffsets.flags = 0
  controller:setFocus(list.rowTargets[1])
  harness.sync()
  local anchorLayout = harness.current.layout
  local anchoredTarget = anchorLayout.lists.flags.rowTargets[2]
  anchorLayout.revealByTarget = {
    [anchoredTarget] = { viewportId = "flags", start = 120, extent = 12 },
  }
  controller:setFocus(anchoredTarget)
  state:_reconcileFocus(anchoredTarget, anchorLayout)
  Assert.equal(
    controller.scrollOffsets.flags,
    math.max(0, math.min(132 - viewport.clip.height, viewport.contentExtent - viewport.clip.height)),
    "a variable-height anchor determines its exact unscrolled reveal interval"
  )
end

function T.tests.party_navigation_uses_the_exact_unscrolled_body_anchor()
  local controller = Controller.new()
  controller:setSection("Party")
  controller:setFocus("party:field:iv:hp")
  local statsRows = {}
  for _, key in ipairs({ "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }) do
    statsRows[#statsRows + 1] = {
      key = key,
      label = key,
      iv = 1,
      ivEditor = { targetId = "party:field:iv:" .. key, editor = { kind = "integer" } },
      ev = 2,
      evEditor = { targetId = "party:field:ev:" .. key, editor = { kind = "integer" } },
    }
  end
  local view = {
    section = "Party",
    status = "ready",
    ready = true,
    dirty = false,
    partyTab = "Stats",
    partySlot0 = 0,
    focus = controller.focus,
    scope = { id = "section:Party", epoch = controller.scopeEpoch },
    scrollOffsets = controller.scrollOffsets,
    partySelector = {
      slots = {
        { kind = "member", slot0 = 0, iconKey = "test/member", label = "Member", active = true },
        { kind = "add", slot0 = 1 },
        { kind = "empty" },
        { kind = "empty" },
        { kind = "empty" },
        { kind = "empty" },
      },
    },
    partyStats = {
      header = {
        { id = "level", label = "Level", value = 5, targetId = "party:field:level", editor = { kind = "integer" } },
        {
          id = "experience",
          label = "Experience",
          value = 100,
          targetId = "party:field:experience",
          editor = { kind = "integer" },
        },
        {
          id = "friendship",
          label = "Friendship",
          value = 70,
          targetId = "party:field:friendship",
          editor = { kind = "integer" },
        },
        {
          id = "currentHp",
          label = "HP",
          value = 12,
          targetId = "party:field:currentHp",
          editor = { kind = "integer" },
        },
        { id = "status", label = "Status", value = "OK", targetId = "party:readonly:status" },
      },
      rows = statsRows,
    },
  }
  local metrics = interactionMetrics()
  local layout = Layout.compute(view, 256, 260, metrics)
  local targetId = "party:field:iv:specialDefense"
  local anchor = assert(layout.revealByTarget[targetId], "Party publishes exact anchors for logical focus targets")
  local viewport = assert(layout.viewports[anchor.viewportId])
  local expected = ScrollViewport.reveal(viewport.offset, viewport.clip.height, anchor.start, anchor.extent)
  local state = stateHarness({
    controller = controller,
    status = "ready",
    _snapshot = function()
      return view
    end,
    _resolve = function()
      return { content = { layout = layout } }
    end,
  })

  for _ = 1, 5 do
    state:_navigate(layout, "down")
  end

  Assert.equal(controller.focus, targetId, "Down preserves the IV column across every logical stat row")
  Assert.equal(
    controller.scrollOffsets["party:Stats"],
    expected,
    "the focused row is revealed from its exact pixel interval"
  )

  local partialTargetId = "party:field:iv:attack"
  local focusedAnchor = assert(layout.revealByTarget[partialTargetId])
  view.scrollOffsets["party:Stats"] = focusedAnchor.start + 1
  local partialLayout = Layout.compute(view, 256, 192, metrics)
  local partialTarget =
    assert(partialLayout.targets[partialTargetId], "partially visible focused rows remain pointer targets")
  local clip = assert(partialLayout.viewports.party).clip
  Assert.isTrue(partialTarget.rect.y < clip.y, "the target keeps its full rectangle above the clip")
  Assert.equal(
    Layout.hitTest(partialLayout, view, partialTarget.rect.x + 1, clip.y + 1),
    partialTargetId,
    "a pointer hit inside the visible intersection selects the partial row"
  )
  Assert.isNil(
    Layout.hitTest(partialLayout, view, partialTarget.rect.x + 1, clip.y - 1),
    "a pointer hit in the hidden part of the same row is rejected"
  )
end

function T.tests.party_keyboard_focus_reveals_stats_before_their_controls_are_materialized()
  local metrics = {
    lineHeight = 16,
    measure = function(text)
      return #text * 8
    end,
  }
  local controller = Controller.new()
  controller:setSection("Party")
  controller:setFocus("party:field:currentHp")
  local rows = {}
  for _, key in ipairs({ "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }) do
    rows[#rows + 1] = {
      key = key,
      label = key,
      iv = 1,
      ivEditor = { targetId = "party:field:iv:" .. key, editor = { kind = "integer" } },
      ev = 2,
      evEditor = { targetId = "party:field:ev:" .. key, editor = { kind = "integer" } },
    }
  end
  local view = {
    status = "ready",
    ready = true,
    dirty = false,
    section = "Party",
    scope = controller:snapshot().scope,
    partyTab = "Stats",
    partySlot0 = 0,
    partySelector = {
      slots = {
        { kind = "member", slot0 = 0, iconKey = "test/member", label = "Member", active = true },
        { kind = "add", slot0 = 1 },
        { kind = "empty" },
        { kind = "empty" },
        { kind = "empty" },
        { kind = "empty" },
      },
    },
    partyStats = {
      header = {
        { id = "level", label = "Level", value = 5, targetId = "party:field:level", editor = { kind = "integer" } },
        { id = "experience", label = "Experience", value = 100, targetId = "party:field:experience", editor = { kind = "integer" } },
        { id = "friendship", label = "Friendship", value = 70, targetId = "party:field:friendship", editor = { kind = "integer" } },
        { id = "currentHp", label = "HP", value = 12, targetId = "party:field:currentHp", editor = { kind = "integer" } },
        { id = "status", label = "Status", value = "OK", targetId = "party:readonly:status" },
      },
      rows = rows,
    },
  }
  local function snapshot()
    view.focus = controller.focus
    view.scope = { id = controller.scopeId, epoch = controller.scopeEpoch }
    view.scrollOffsets = controller.scrollOffsets
    return view
  end
  local function resolve(current)
    return { content = { layout = Layout.compute(current, 256, 192, metrics) } }
  end
  local state = stateHarness({
    status = "ready",
    controller = controller,
    _snapshot = snapshot,
    _resolve = function(_, current)
      return resolve(current)
    end,
  })

  local initial = resolve(snapshot()).content.layout
  Assert.isTrue(
    initial.partyStrip.slots[1].rect.height >= 38,
    "native Stats focus remains composed with the Party strip tall enough for a native icon"
  )
  local firstIv = "party:field:iv:hp"
  local anchor = assert(initial.revealByTarget[firstIv], "offscreen Stats targets publish exact body coordinates")
  local viewport = assert(initial.viewports.party)
  local expected = ScrollViewport.reveal(viewport.offset, viewport.clip.height, anchor.start, anchor.extent)
  Assert.isNil(initial.targets[firstIv], "the offscreen destination has no physical hit geometry")
  state:_navigate(initial, "down")
  Assert.equal(controller.focus, firstIv, "Down from the last editable fact enters the virtual Stats table")
  Assert.equal(controller.scrollOffsets["party:Stats"], expected, "keyboard focus reveals the exact IV row interval")
  local revealed = resolve(snapshot()).content.layout
  Assert.notNil(revealed.targets[firstIv], "the focused IV receives hit geometry only after it is revealed")

  local function tabIntoStats(direction)
    controller.scrollOffsets["party:Stats"] = 0
    local current = resolve(snapshot()).content.layout
    local statsIndex
    for index, region in ipairs(current.focusNavigation.regions) do
      if region.id == "party:stats" then
        statsIndex = index
        break
      end
    end
    statsIndex = assert(statsIndex, "the virtual table participates in Tab navigation")
    local adjacent = assert(current.focusNavigation.regions[statsIndex + (direction == "next" and -1 or 1)])
    controller:setFocus(assert(adjacent.defaultId, "an adjacent Tab region has an entry target"))
    local expected = assert(current.revealByTarget[firstIv])
    local expectedOffset = ScrollViewport.reveal(
      current.viewports.party.offset,
      current.viewports.party.clip.height,
      expected.start,
      expected.extent
    )
    state:_navigateTab(current, direction)
    Assert.equal(controller.focus, firstIv, "Tab enters the first logical Stats cell")
    Assert.equal(controller.scrollOffsets["party:Stats"], expectedOffset, "Tab entry applies the exact row reveal")
  end
  tabIntoStats("next")
  tabIntoStats("previous")

  controller:setFocus("party:page:previous")
  local pagerLayout = resolve(snapshot()).content.layout
  local lastIv = "party:field:iv:specialDefense"
  local lastAnchor = assert(pagerLayout.revealByTarget[lastIv])
  local pagerViewport = assert(pagerLayout.viewports.party)
  local expectedLast = ScrollViewport.reveal(
    pagerViewport.offset,
    pagerViewport.clip.height,
    lastAnchor.start,
    lastAnchor.extent
  )
  state:_navigate(pagerLayout, "up")
  Assert.equal(controller.focus, lastIv, "Up from the pager enters the final logical Stats row")
  Assert.equal(controller.scrollOffsets["party:Stats"], expectedLast, "pager entry uses the final row's exact anchor")
end

function T.tests.partial_party_details_and_moves_targets_respect_the_body_clip()
  local metrics = interactionMetrics()
  local function partialView(tab)
    local controller = Controller.new()
    controller:setSection("Party")
    controller:selectPartyTab(tab)
    controller:setFocus(tab == "Details" and "party:field:detail0" or "party:move:0")
    local view = {
      section = "Party",
      status = "ready",
      ready = true,
      dirty = false,
      partyTab = tab,
      partySlot0 = 0,
      focus = controller.focus,
      scope = { id = "section:Party", epoch = controller.scopeEpoch },
      scrollOffsets = controller.scrollOffsets,
      partySelector = {
        slots = {
          { kind = "member", slot0 = 0 },
          { kind = "empty" },
          { kind = "empty" },
          { kind = "empty" },
          { kind = "empty" },
          { kind = "empty" },
        },
      },
      partyMoves = { slots = {} },
      partyDetails = { rows = {} },
    }
    for index = 0, 12 do
      view.partyMoves.slots[#view.partyMoves.slots + 1] = {
        kind = "move",
        slot0 = index,
        targetId = "party:move:" .. index,
        name = "Move " .. index,
      }
      view.partyDetails.rows[#view.partyDetails.rows + 1] = {
        role = "integer value",
        targetId = "party:field:detail" .. index,
        label = "Detail " .. index,
        value = index,
        editor = { kind = "integer" },
      }
    end
    local targetId = tab == "Details" and "party:field:detail0" or "party:move:0"
    local initial = Layout.compute(view, 256, 192, metrics)
    local anchor = assert(initial.revealByTarget[targetId])
    view.scrollOffsets["party:" .. tab] = anchor.start + 1
    local layout = Layout.compute(view, 256, 192, metrics)
    return controller, view, layout, targetId
  end

  for _, tab in ipairs({ "Moves", "Details" }) do
    local controller, view, layout, targetId = partialView(tab)
    local target = assert(layout.targets[targetId])
    local clip = assert(layout.viewports.party).clip
    Assert.isTrue(target.rect.y < clip.y, tab .. " keeps the full rectangle for a partially visible first row")
    Assert.equal(
      Layout.hitTest(layout, view, target.rect.x + 1, clip.y + 1),
      targetId,
      tab .. " accepts pointer hits within the visible intersection"
    )
    Assert.isNil(
      Layout.hitTest(layout, view, target.rect.x + 1, clip.y - 1),
      tab .. " rejects pointer hits in the clipped part"
    )

    local actions = {}
    local state = stateHarness({
      status = "ready",
      controller = controller,
      presentation = {
        cancelPointers = function() end,
        mapInput = function(_, events)
          for _, event in ipairs(events) do
            event.targetId = Layout.hitTest(layout, view, event.x, event.y)
          end
          return events
        end,
      },
      _snapshot = function()
        return view
      end,
      _resolve = function()
        return { content = { layout = layout } }
      end,
      _dispatchActivationAction = function(_, action)
        actions[#actions + 1] = action
      end,
    })
    state:_pointer({ {
      type = "pointer_down",
      pointerId = "touch:partial-" .. tab,
      x = target.rect.x + 1,
      y = clip.y + 1,
    } })
    state:_pointer({ {
      type = "pointer_up",
      pointerId = "touch:partial-" .. tab,
      x = target.rect.x + 1,
      y = clip.y + 1,
    } })
    Assert.equal(#actions, 1, tab .. " dispatches an in-clip partial-control tap on release")

    if tab == "Details" then
      actions = {}
      state:_pointer({ {
        type = "pointer_down",
        pointerId = "touch:partial-detail-drag",
        x = target.rect.x + 1,
        y = clip.y + 1,
      } })
      state:_pointer({ {
        type = "pointer_up",
        pointerId = "touch:partial-detail-drag",
        x = target.rect.x + 1,
        y = clip.y - 1,
      } })
      Assert.equal(#actions, 0, "releasing an edit outside the body clip never activates or commits it")
    end
  end
end

function T.tests.expanded_party_moves_keep_dpad_navigation_and_reveal_the_last_card()
  local metrics = interactionMetrics()
  local controller = Controller.new()
  controller:setSection("Party")
  controller:selectPartyTab("Moves")
  controller:setFocus("party:move:0")
  local view = {
    status = "ready",
    ready = true,
    dirty = false,
    section = "Party",
    scope = controller:snapshot().scope,
    partyTab = "Moves",
    partySlot0 = 0,
    partySelector = {
      slots = {
        { kind = "member", slot0 = 0, iconKey = "test/member", active = true },
        { kind = "empty" },
        { kind = "empty" },
        { kind = "empty" },
        { kind = "empty" },
        { kind = "empty" },
      },
    },
    partyMoves = {
      slots = {
        { kind = "move", slot0 = 0, label = "Tackle", targetId = "party:move:0" },
        { kind = "move", slot0 = 1, label = "Growl", targetId = "party:move:1" },
        { kind = "move", slot0 = 2, label = "Leer", targetId = "party:move:2" },
        { kind = "move", slot0 = 3, label = "Bite", targetId = "party:move:3" },
      },
    },
    textMetrics = metrics,
  }
  local function snapshot()
    view.focus = controller.focus
    view.scope = { id = controller.scopeId, epoch = controller.scopeEpoch }
    view.scrollOffsets = controller.scrollOffsets
    return view
  end
  local function layout()
    return Layout.compute(snapshot(), 256, 192, metrics)
  end
  local state = stateHarness({
    status = "ready",
    controller = controller,
    _snapshot = snapshot,
    _resolve = function()
      return { content = { layout = layout() } }
    end,
  })

  local current = layout()
  local lastAnchor = assert(current.revealByTarget["party:move:3"])
  local viewport = assert(current.viewports.party)
  local expectedOffset = ScrollViewport.reveal(viewport.offset, viewport.clip.height, lastAnchor.start, lastAnchor.extent)
  state:_navigate(current, "right")
  Assert.equal(controller.focus, "party:move:1", "Right moves between the top row cards")
  state:_navigate(layout(), "down")
  Assert.equal(controller.focus, "party:move:3", "Down preserves the right column in the second row")
  local revealed = layout()
  local target = assert(revealed.targets["party:move:3"], "the focused last card is physically materialized")
  local clip = assert(revealed.viewports.party).clip
  Assert.isTrue(target.rect.y >= clip.y and target.rect.y + target.rect.height <= clip.y + clip.height)
  Assert.equal(
    controller.scrollOffsets["party:Moves"] or 0,
    expectedOffset,
    "the focused last card applies its exact reveal offset"
  )
  Assert.equal(lastAnchor.viewportId, "party", "the last card remains anchored to the shared Party viewport")
end

function T.tests.party_reveal_keeps_exact_offsets_across_tabs_inputs_and_sizes()
  local metrics = interactionMetrics()
  local stats = {}
  for _, key in ipairs({ "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }) do
    stats[#stats + 1] = {
      key = key,
      label = key,
      iv = 1,
      ivEditor = { targetId = "party:field:iv:" .. key, editor = { kind = "integer" } },
      ev = 2,
      evEditor = { targetId = "party:field:ev:" .. key, editor = { kind = "integer" } },
    }
  end

  local function runCase(tab, width, height, steps, navigatedTargetId, targetId)
    local controller = Controller.new()
    controller:setSection("Party")
    controller:selectPartyTab(tab)
    controller:setFocus(tab == "Stats" and "party:field:iv:hp" or tab == "Moves" and "party:move:0" or "party:field:detail0")
    local view = {
      section = "Party",
      status = "ready",
      ready = true,
      dirty = false,
      partyTab = tab,
      partySlot0 = 0,
      partySelector = {
        slots = {
          { kind = "member", slot0 = 0 },
          { kind = "empty" },
          { kind = "empty" },
          { kind = "empty" },
          { kind = "empty" },
          { kind = "empty" },
        },
      },
      partyStats = { rows = stats, header = {} },
      partyMoves = { slots = {} },
      partyDetails = { rows = {} },
      scrollOffsets = controller.scrollOffsets,
    }
    for index = 0, 39 do
      view.partyMoves.slots[#view.partyMoves.slots + 1] = {
        kind = "move",
        slot0 = index,
        targetId = "party:move:" .. index,
        name = "Move " .. index,
      }
      view.partyDetails.rows[#view.partyDetails.rows + 1] = {
        role = "integer value",
        targetId = "party:field:detail" .. index,
        label = "Detail " .. index,
        value = index,
        editor = { kind = "integer" },
      }
    end
    local function snapshot()
      view.focus = controller.focus
      view.scope = { id = controller.scopeId, epoch = controller.scopeEpoch }
      view.scrollOffsets = controller.scrollOffsets
      return view
    end
    local function resolve(current)
      return { content = { layout = Layout.compute(current, width, height, metrics) } }
    end
    local state = stateHarness({
      status = "ready",
      controller = controller,
      _snapshot = snapshot,
      _resolve = function(_, current)
        return resolve(current)
      end,
    })
    local before = resolve(snapshot()).content.layout
    local anchor = assert(before.revealByTarget[targetId], "every logical Party row retains its pixel anchor")
    local viewport = assert(before.viewports.party)
    local expected = ScrollViewport.reveal(0, viewport.clip.height, anchor.start, anchor.extent)
    Assert.isNil(before.targets[targetId], tab .. " starts with the destination offscreen and without hit geometry")

    for _ = 1, steps do
      state:_navigate(resolve(snapshot()).content.layout, "down")
    end
    Assert.equal(
      controller.focus,
      navigatedTargetId,
      tab .. " navigates through its materialized focus region (actual " .. tostring(controller.focus) .. ")"
    )
    Assert.equal(controller.focus, targetId, tab .. " preserves logical focus on the requested offscreen row")
    Assert.equal(controller.scrollOffsets["party:" .. tab], expected, tab .. " reveals from the exact row interval")
    local wheelFocus = controller.focus
    state:wheelmoved(0, -1)
    Assert.equal(controller.focus, wheelFocus, tab .. " wheel scrolling preserves logical focus")
    Assert.equal(
      controller.scrollOffsets["party:" .. tab],
      math.max(0, math.min(expected + 20, viewport.contentExtent - viewport.clip.height)),
      tab .. " wheel scrolling advances by the published row extent"
    )
    local revealed = resolve(snapshot()).content.layout
    local target = assert(revealed.targets[targetId], tab .. " materializes the destination after logical reveal")
    local clip = assert(revealed.viewports.party).clip
    Assert.isTrue(target.rect.y < clip.y + clip.height and target.rect.y + target.rect.height > clip.y)
  end

  runCase("Stats", 256, 192, 5, "party:field:iv:specialDefense", "party:field:iv:specialDefense")
  runCase("Moves", 256, 192, 6, "party:move:12", "party:move:12")
  runCase("Details", 640, 480, 20, "party:field:detail20", "party:field:detail20")
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
  Assert.equal(controller.focus, "flag:TEST_FLAG_02", "filtering keeps focus on the surviving logical row")
  Assert.equal(#harness.activations, 0, "filtering never activates a row")

  controller:setFocus("list:flags")
  harness.sync()
  Assert.equal(controller.focus, "flag:TEST_FLAG_02", "reconciliation enters the remaining row directly")
  state:textinput("X")
  harness.sync()
  Assert.deepEqual(harness.current.layout.lists.flags.rowTargets, {})
  Assert.equal(controller.focus, "list:flags", "an empty list exposes its inert placeholder")
  Assert.equal(#harness.activations, 0, "filter reconciliation never activates a row")

  controller:setFocus("back")
  state:textinput("Q")
  harness.sync()
  Assert.equal(controller.query, "TEST_FLAG_02X", "typing outside a focused list never filters")
end

function T.tests.tab_moves_between_declared_regions_and_restores_the_remembered_control()
  local harness = progressListHarness(progressFlagCatalog(6))
  local controller, state = harness.controller, harness.state
  controller:setFocus("flag:TEST_FLAG_01")
  harness.sync()
  local regions = harness.current.layout.focusNavigation.regions
  local bodyIndex, footerIndex
  for index, region in ipairs(regions) do
    if region.id == "flags" then
      bodyIndex = index
    elseif region.id == "global-footer" then
      footerIndex = index
    end
  end
  Assert.notNil(bodyIndex, "the Progress list declares its page-body region")
  Assert.notNil(footerIndex, "the shell declares its footer region")
  Assert.isTrue(footerIndex > bodyIndex, "the footer follows the list in declared tab order")
  controller:rememberRegionFocus("global-footer", "back")

  state:keypressed("tab")
  Assert.equal(controller.focus, "back", "Tab restores the next region's remembered control")

  local wasDown = love.keyboard.isDown
  love.keyboard.isDown = function(key)
    return key == "lshift"
  end
  state:keypressed("tab")
  love.keyboard.isDown = wasDown
  Assert.equal(controller.focus, "flag:TEST_FLAG_01", "Shift-Tab restores the remembered list row")
end

function T.tests.printable_action_binding_stays_text_in_every_filterable_list()
  local harness = progressListHarness(progressFlagCatalog(6))
  local controller, state = harness.controller, harness.state
  controller.section = "Bag"
  controller:setFocus("flag:TEST_FLAG_01")
  state.fieldInput:beginUi(0)

  state:keypressed("space")
  state:keyreleased("space")
  state:textinput(" ")

  Assert.equal(#harness.activations, 0, "Space never activates a focused filterable row")
  Assert.equal(controller.query, " ", "Space still reaches the list as filter text")
  Assert.equal(controller.focus, "list:flags", "filtering reconciles the removed row to the empty-list control")
end

function T.tests.focused_list_keeps_row_focus_and_edits_multibyte_queries()
  local harness = progressListHarness(progressFlagCatalog(6))
  local controller, state = harness.controller, harness.state
  controller:setFocus("list:flags")
  harness.sync()
  Assert.notNil(harness.current.layout.lists, "the plan must publish one record per interactive list")

  local rows = harness.current.layout.lists.flags.rowTargets
  Assert.equal(controller.focus, rows[1], "a list begins with its first logical row focused")
  state:textinput(rows[1]:sub(6))
  harness.sync()
  Assert.isTrue(
    rowTargetsSet(harness.current.layout.lists.flags.rowTargets)[controller.focus] == true
      or controller.focus == "list:flags",
    "typing reconciles a removed cursor row to a surviving row or empty placeholder"
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

function T.tests.pointer_taps_activate_on_release_and_drag_never_activates()
  local controller = Controller.new()
  controller:setSection("Progress")

  Assert.isNil(
    controller:pointer({ type = "pointer_down", pointerId = "touch:row", targetId = "flag:TEST_FLAG_01", x = 8, y = 8 }),
    "pressing a row never activates on press"
  )
  local firstTap =
    controller:pointer({ type = "pointer_up", pointerId = "touch:row", targetId = "flag:TEST_FLAG_01", x = 8, y = 8 })
  Assert.deepEqual(
    firstTap,
    { kind = "activate", targetId = "flag:TEST_FLAG_01" },
    "a clean tap activates the row on release"
  )
  Assert.equal(controller.focus, "flag:TEST_FLAG_01", "a clean tap moves row focus")

  Assert.isNil(controller:pointer({
    type = "pointer_down",
    pointerId = "touch:row-again",
    targetId = "flag:TEST_FLAG_01",
    x = 8,
    y = 8,
  }))
  Assert.deepEqual(
    controller:pointer({
      type = "pointer_up",
      pointerId = "touch:row-again",
      targetId = "flag:TEST_FLAG_01",
      x = 8,
      y = 8,
    }),
    { kind = "activate", targetId = "flag:TEST_FLAG_01" },
    "a clean tap on the focused row activates it"
  )

  Assert.isNil(controller:pointer({
    type = "pointer_down",
    pointerId = "touch:drag",
    targetId = "flag:TEST_FLAG_02",
    scrollViewportId = "flags",
    scrollOffset = 0,
    x = 8,
    y = 8,
  }))
  local dragMove = controller:pointer({ type = "pointer_move", pointerId = "touch:drag", x = 8, y = 80 })
  Assert.isTrue(dragMove == nil or dragMove.kind == "scroll-drag", "a scroll drag produces no row intent while moving")
  Assert.isNil(
    controller:pointer({ type = "pointer_up", pointerId = "touch:drag", targetId = "flag:TEST_FLAG_02", x = 8, y = 80 }),
    "releasing after a scroll drag never activates"
  )
end

local function locationListHarness()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 12, fieldX = 32, fieldZ = 48 })
  controller:enterLocationGroup("location:group:1")
  local listId = "location:group:1"
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
    local mapModel = indexedMapModel(filtered)
    return {
      section = "Location",
      status = "ready",
      ready = true,
      dirty = false,
      scope = { id = "section:Location:group", epoch = 0, kind = "section", focusId = controller.focus },
      focus = controller.focus,
      query = controller.query,
      location = {
        mapListId = listId,
        breadcrumb = "TEST_SECTION",
        mapId = 12,
        symbol = "MAP_TEST_ROUTE",
        section = "TEST_SECTION",
        maps = filtered,
        mapModel = mapModel,
        mapRowTargets = mapModel.rowTargets,
        mapIndexByTarget = mapModel.indexByTarget,
        generation = 1,
        status = { state = "ready" },
        tiles = { { fieldX = 32, fieldZ = 48, selectable = true } },
        cursor = { fieldX = 32, fieldZ = 48 },
      },
      locationNavigation = {
        page = "group",
        groupId = "location:group:1",
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
  local state = stateHarness({
    status = "ready",
    controller = controller,
    fieldInput = FieldInput.new(),
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
  })
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
  local list = assert(layout.lists["location:group:1"], "map rows belong to one generic list record")
  Assert.deepEqual(list.rowTargets, { "location:map:12", "location:map:34", "location:map:47", "location:map:7" })

  controller:setFocus("list:location:group:1")
  state:_reconcileFocus()
  Assert.equal(#harness.intents, 0, "focusing map rows never starts map work")
  Assert.equal(controller.focus, "location:map:12", "the map list opens on its first row")

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
  Assert.equal(controller.focus, "location:map:34", "Back retains the logical map row")
  Assert.equal(harness.backCount(), 1, "Back exits the current page scope")
  Assert.equal(#harness.intents, 0, "leaving map rows never starts map work")
end

local function overflowingLocationListHarness(width, height, count)
  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 12, fieldX = 32, fieldZ = 48 })
  controller:enterLocationGroup("location:group:1")
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
    local mapModel = indexedMapModel(maps)
    return {
      section = "Location",
      status = "ready",
      ready = true,
      dirty = false,
      scope = { id = "section:Location:map-list", epoch = 0, kind = "section", focusId = controller.focus },
      focus = controller.focus,
      query = controller.query,
      location = {
        mapListId = "location:group:1",
        breadcrumb = "TEST_SECTION",
        mapId = 12,
        symbol = "MAP_TEST_12",
        section = "TEST_SECTION",
        maps = maps,
        mapModel = mapModel,
        mapRowTargets = mapModel.rowTargets,
        mapIndexByTarget = mapModel.indexByTarget,
        generation = 1,
        status = { state = "ready" },
        tiles = { { fieldX = 32, fieldZ = 48, selectable = true } },
        cursor = { fieldX = 32, fieldZ = 48 },
      },
      locationNavigation = {
        page = "group",
        groupId = "location:group:1",
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
  local state = stateHarness({
    status = "ready",
    controller = controller,
    fieldInput = FieldInput.new(),
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
  })
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

function T.tests.location_map_row_navigation_keeps_offscreen_identity()
  for _, size in ipairs({ { 800, 600 }, { 256, 192 } }) do
    local label = size[1] .. "x" .. size[2]
    local harness = overflowingLocationListHarness(size[1], size[2], 31)
    local controller, state = harness.controller, harness.state
    local viewport = assert(harness.buildLayout().viewports["location:group:1"])
    Assert.isTrue(viewport.lastIndex < 31, "the map list must overflow its viewport (" .. label .. ")")

    controller:setFocus("list:location:group:1")
    state:_reconcileFocus()
    Assert.equal(controller.focus, "location:map:1", "the map list opens on its first row (" .. label .. ")")

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
      controller:listCursor("location:group:1"),
      "location:map:30",
      "the cursor tracks row focus past the viewport (" .. label .. ")"
    )

    state:_consumeUiInput({ { type = "cancel" } })
    Assert.equal(
      controller.focus,
      "location:map:30",
      "Back preserves logical focus while leaving the list region (" .. label .. ")"
    )
    Assert.equal(harness.backCount(), 1, "Back exits the active page scope (" .. label .. ")")

    state:wheelmoved(0, 3)
    Assert.equal(controller.focus, "location:map:30", "wheel scrolling preserves logical focus (" .. label .. ")")
    Assert.equal(controller.locationMapId, 12, "re-entering rows never commits a map (" .. label .. ")")
    Assert.equal(#harness.intents, 0, "re-entering rows never starts map work (" .. label .. ")")
  end
end

local function choiceListHarness(optionCount)
  local controller = Controller.new()
  controller:setSection("Bag")
  local metrics = interactionMetrics()
  local options = {}
  for index = 1, optionCount or 12 do
    options[index] = { key = string.format("K%02d", index), label = "Choice " .. index }
  end
  local editor = ValueEditor.new({ kind = "choice", value = options[5].key, options = options })
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
    editor:update(256)
    return Layout.compute(buildView(), 256, 192, metrics)
  end
  local finished = 0
  local state = stateHarness({
    status = "ready",
    controller = controller,
    fieldInput = FieldInput.new(),
    inputTick = 0,
    tickRemainder = 0,
    valueEditor = editor,
    _snapshot = buildView,
    _resolve = function()
      return { content = { layout = buildLayout() } }
    end,
    _finishValueEditor = function()
      finished = finished + 1
    end,
  })
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

function T.tests.large_choice_filtering_is_sliced_and_cannot_submit_stale_rows()
  local harness = choiceListHarness(10000)
  local editor, state, controller = harness.editor, harness.state, harness.controller
  local sourceOptions = editor._options
  local visits = 0
  local originalIpairs = ipairs
  _G.ipairs = function(value)
    if value ~= sourceOptions then
      return originalIpairs(value)
    end
    local function nextOption(_, index)
      index = index + 1
      local option = value[index]
      if option == nil then
        return nil
      end
      visits = visits + 1
      return index, option
    end
    return nextOption, value, 0
  end
  local ok, failure = xpcall(function()
    controller:setFocus("choice:K05")
    state:textinput("Choice 1")
    Assert.isTrue(visits <= 256, string.format("one input event visited %d of 10000 choices", visits))
    local pending = editor:snapshot()
    Assert.isTrue(pending.pending, "a large query remains pending after its first bounded slice")
    Assert.equal(pending.query, "Choice 1", "the newest query is visible while its model is pending")
    Assert.isFalse(editor:submit(), "a stale row cannot submit while filtering is pending")
    Assert.isNil(editor:result(), "a pending query publishes no selection")
  end, debug.traceback)
  _G.ipairs = originalIpairs
  if not ok then
    error(failure, 0)
  end
end

function T.tests.choice_editor_opens_on_a_row_and_back_cancels_the_editor()
  local harness = choiceListHarness()
  local controller, state, editor = harness.controller, harness.state, harness.editor
  local layout = harness.buildLayout()
  Assert.notNil(layout.lists, "the plan must publish one record per interactive list")
  local list = assert(layout.lists["value:choice"], "choice options belong to one generic list record")
  Assert.equal(list.rowTargets[1], "choice:K01", "rows follow the filtered display order")

  controller:setFocus("list:value:choice")
  state:_reconcileFocus()
  Assert.equal(harness.finishedCount(), 0, "entering choice rows never submits the editor")
  Assert.isNil(editor:result(), "entering choice rows publishes no result")
  Assert.equal(controller.focus, "choice:K01", "the choice region opens with its first row focused")

  for _ = 1, 4 do
    state:_consumeUiInput({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(controller.focus, "choice:K05", "repeated Down steps reveal each logical row")
  state:_consumeUiInput({ { type = "cancel" } })
  Assert.equal(harness.finishedCount(), 1, "Back cancels the active choice editor")
  Assert.equal(assert(editor:result()).kind, "cancel", "Back publishes only a cancellation result")
end

function T.tests.choice_footer_back_remains_available_for_pending_and_empty_filters()
  local function isEligible(layout, targetId)
    for _, control in ipairs(layout.focusNavigation.controls) do
      if control.id == targetId then
        return control.eligible
      end
    end
    return false
  end

  local function tapBack(harness, layout)
    local state = harness.state
    local rect = assert(layout.targets.cancel, "Back remains a live action").rect
    state.presentation = {
      mapInput = function(_, events)
        return events
      end,
      cancelPointers = function() end,
    }
    local x, y = rect.x + rect.width / 2, rect.y + rect.height / 2
    Assert.equal(Layout.hitTest(layout, state:_snapshot(), x, y), "cancel", "Back's published bounds stay hittable")
    state:_pointer({ { type = "pointer_down", pointerId = "touch:choice-back", targetId = "cancel", x = x, y = y } })
    state:_pointer({ { type = "pointer_up", pointerId = "touch:choice-back", targetId = "cancel", x = x, y = y } })
    Assert.equal(assert(harness.editor:result()).kind, "cancel", "tapping Back cancels the choice editor")
    Assert.equal(harness.finishedCount(), 1, "Back completes the active editor once")
  end

  local pending = choiceListHarness(10000)
  pending.controller:setFocus("choice:K05")
  pending.state:textinput("Choice 1")
  local pendingLayout = pending.buildLayout()
  local pendingList = assert(pendingLayout.lists["value:choice"])
  Assert.isTrue(pendingList.pending, "a large choice filter remains pending after its bounded layout update")
  Assert.notNil(pendingLayout.targets.cancel, "pending filtering retains Back")
  Assert.isFalse(isEligible(pendingLayout, "confirm"), "pending filtering disables Choose")
  pending.state:_activateControl("confirm", pendingLayout)
  Assert.isNil(pending.editor:result(), "disabled Choose cannot submit a stale option")
  Assert.equal(pending.finishedCount(), 0, "disabled Choose leaves the editor open")
  tapBack(pending, pendingLayout)

  local empty = choiceListHarness(12)
  empty.controller:setFocus("choice:K05")
  empty.state:textinput("no-match")
  empty.editor:update(256)
  local emptyLayout = empty.buildLayout()
  local emptyList = assert(emptyLayout.lists["value:choice"])
  Assert.isTrue(emptyList.empty, "a zero-result query publishes an empty choice list")
  Assert.deepEqual(emptyList.rowTargets, {}, "a zero-result query has no selectable options")
  Assert.notNil(emptyLayout.viewports["value:choice"], "the empty result keeps its list viewport")
  Assert.notNil(emptyLayout.targets.cancel, "an empty result retains Back")
  Assert.isFalse(isEligible(emptyLayout, "confirm"), "an empty result disables Choose")
  empty.state:_activateControl("confirm", emptyLayout)
  Assert.isNil(empty.editor:result(), "disabled Choose cannot submit from an empty result")
  Assert.equal(empty.finishedCount(), 0, "disabled Choose leaves the empty picker open")
  tapBack(empty, emptyLayout)
end

function T.tests.choice_typing_reconciles_the_cursor_without_publishing()
  local harness = choiceListHarness()
  local controller, state, editor = harness.controller, harness.state, harness.editor
  controller:setFocus("choice:K05")
  state:textinput("Choice 1")
  editor:update(256)
  state:update(0)
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

function T.tests.keyboard_and_gamepad_directions_produce_the_same_choice_focus()
  local function moveWith(device)
    local harness = choiceListHarness()
    harness.state.fieldInput = FieldInput.new()
    harness.state.inputTick = 1
    harness.state.fieldInput:beginUi(0)
    harness.controller:setFocus("choice:K05")
    if device == "keyboard" then
      harness.state:keypressed("down")
      harness.state:keyreleased("down")
    else
      harness.state:gamepadpressed(nil, "dpdown")
      harness.state:gamepadreleased(nil, "dpdown")
    end
    return harness.controller.focus
  end

  Assert.equal(moveWith("keyboard"), "choice:K06", "keyboard Down moves one choice row")
  Assert.equal(moveWith("gamepad"), "choice:K06", "D-pad Down has the same logical result")
end

local function recordingLocationService()
  local stub = {
    openMaps = {},
    updateCalls = 0,
    viewportCalls = {},
    releaseGridCalls = 0,
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
  function stub:releaseGrid()
    self.releaseGridCalls = self.releaseGridCalls + 1
  end
  function stub:cancelInitialSurvey()
    self.cancelInitialSurveyCalls = (self.cancelInitialSurveyCalls or 0) + 1
  end
  function stub:snapshot()
    return {
      generation = 3,
      status = { state = "pending" },
      initialCursor = { state = "pending", mapId = 34, generation = 3, factsRevision = 1 },
    }
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
  local state = stateHarness({
    status = "ready",
    controller = controller,
    locationService = service,
    fieldInput = FieldInput.new(),
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
  })
  return {
    controller = controller,
    service = service,
    state = state,
    resolveCount = function()
      return resolveCount
    end,
  }
end

function T.tests.manual_tile_selection_disarms_pending_survey_centering()
  local harness = mapActivationHarness()
  harness.service.resolve = function(_, mapId, fieldX, fieldZ)
    Assert.equal(mapId, 12, "manual selection resolves the active map")
    Assert.equal(fieldX, 32, "manual selection resolves the chosen x coordinate")
    Assert.equal(fieldZ, 48, "manual selection resolves the chosen z coordinate")
    return { mapId = mapId, fieldX = fieldX, fieldZ = fieldZ }, { state = "ready" }
  end
  harness.state.session = {
    setLocation = function()
      return { ok = true }
    end,
  }
  harness.state.locationAutoCenterToken = { mapId = 12, generation = 3 }

  harness.state:_performDeferred({ kind = "select_tile", fieldX = 32, fieldZ = 48 })

  Assert.isNil(harness.state.locationAutoCenterToken, "manual tile selection takes ownership from the survey")
end

function T.tests.pending_manual_tile_selection_cancels_survey_ownership()
  local harness = mapActivationHarness()
  harness.service.resolve = function()
    return nil, { state = "pending", reason = "preparing" }
  end
  harness.state.locationAutoCenterToken = { mapId = 12, generation = 3 }

  harness.state:_selectLocationTile(32, 48)

  Assert.isNil(harness.state.locationAutoCenterToken, "a manual tile attempt takes ownership from the survey")
  Assert.equal(harness.service.cancelInitialSurveyCalls or 0, 1, "a pending survey is canceled before tile resolution")
end

local function tappedLocationHarness(width, height)
  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 12, fieldX = 32, fieldZ = 48 })
  controller:chooseLocationMap(12, 30, 46)
  local metrics = interactionMetrics()
  local view
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
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
  local measurement = context:measure(width, height)
  local attempts, writes = {}, {}
  local service = {
    snapshot = function()
      return { generation = 3, status = { state = "ready" } }
    end,
    resolve = function(_, mapId, fieldX, fieldZ, generation)
      attempts[#attempts + 1] = { mapId = mapId, fieldX = fieldX, fieldZ = fieldZ, generation = generation }
      if fieldX == 32 and fieldZ == 48 then
        return { mapId = mapId, fieldX = fieldX, fieldZ = fieldZ }, { state = "ready" }
      end
      if fieldX == 33 then
        return nil, { state = "blocked", reason = "blocked tile" }
      end
      return nil, { state = "pending", reason = "preparing tile" }
    end,
    setViewport = function() end,
    update = function() end,
    cancelInitialSurvey = function() end,
  }
  local session = {
    snapshot = function()
      return { location = writes[#writes] or { mapId = 12, fieldX = 30, fieldZ = 46 } }
    end,
    setLocation = function(_, placement)
      writes[#writes + 1] = placement
      return { ok = true }
    end,
  }
  local state = stateHarness({
    status = "ready",
    controller = controller,
    presentation = presentation,
    session = session,
    locationService = service,
    locationServiceMapId = 12,
    locationGridWidthTiles = 7,
    locationGridHeightTiles = 5,
    locationPreviewMemory = {},
    errorMessage = nil,
    _snapshot = function()
      local navigation = controller:locationSnapshot()
      view = {
        ready = true,
        status = "ready",
        dirty = false,
        sectionDirty = false,
        section = "Location",
        scope = controller:snapshot().scope,
        focus = controller.focus,
        textMetrics = metrics,
        scrollOffsets = controller.scrollOffsets,
        location = {
          mapId = 12,
          map = { symbol = "MAP_TEST" },
          status = { state = "ready" },
          tiles = {},
          maps = {},
          cursor = navigation.cursor,
        },
        locationNavigation = navigation,
      }
      return view
    end,
    _resolve = function(_, currentView)
      return presentation:resolve(measurement, currentView)
    end,
  })
  return {
    controller = controller,
    state = state,
    presentation = presentation,
    attempts = attempts,
    writes = writes,
    view = function()
      return state:_snapshot()
    end,
    close = function()
      presentation:dispose()
    end,
  }
end

local function pointerAtGridTile(harness, fieldX, fieldZ)
  local view = harness.view()
  local plan = harness.state:_resolve(view)
  local grid = assert(plan.content.layout.locationGrid)
  local x = grid.originX + (fieldX - grid.firstFieldX + 0.5) * grid.tileSize
  local y = grid.originY + (fieldZ - grid.firstFieldZ + 0.5) * grid.tileSize
  local pane = assert(plan.panes[1])
  return LayoutGeometry.logicalToHost(pane.placement, x, y)
end

function T.tests.map_tile_taps_use_location_policy_and_grid_drags_only_pan()
  for _, size in ipairs({ { 256, 192 }, { 256, 400 }, { 800, 600 } }) do
    local harness = tappedLocationHarness(size[1], size[2])
    local x, y = pointerAtGridTile(harness, 32, 48)
    harness.state:_pointer({
      { type = "pointer_down", pointerId = "touch:safe", x = x, y = y },
      { type = "pointer_up", pointerId = "touch:safe", x = x, y = y },
    })
    Assert.equal(#harness.attempts, 1, "a safe tap reaches location policy at " .. size[1] .. "x" .. size[2])
    Assert.equal(#harness.writes, 1, "the accepted tile updates the staged destination")

    for _, tile in ipairs({ { 33, 48, "blocked" }, { 34, 48, "pending" } }) do
      x, y = pointerAtGridTile(harness, tile[1], tile[2])
      harness.state:_pointer({
        { type = "pointer_down", pointerId = "touch:" .. tile[3], x = x, y = y },
        { type = "pointer_up", pointerId = "touch:" .. tile[3], x = x, y = y },
      })
      Assert.equal(#harness.writes, 1, tile[3] .. " taps cannot change the staged destination")
      Assert.equal(harness.attempts[#harness.attempts].fieldX, tile[1], tile[3] .. " tile reaches policy")
    end

    x, y = pointerAtGridTile(harness, 32, 48)
    harness.state:_pointer({ { type = "pointer_down", pointerId = "touch:drag", x = x, y = y } })
    harness.state:_pointer({ { type = "pointer_move", pointerId = "touch:drag", x = x + 48, y = y } })
    harness.state:_pointer({ { type = "pointer_up", pointerId = "touch:drag", x = x + 48, y = y } })
    Assert.equal(#harness.writes, 1, "a grid drag pans without staging another destination")
    Assert.equal(#harness.attempts, 3, "a grid drag never resolves a destination")
    harness.close()
  end
end

function T.tests.location_map_browsing_moves_only_focus_and_never_starts_map_work()
  local harness = locationListHarness()
  local controller, state = harness.controller, harness.state
  controller:setFocus("list:location:group:1")
  state:_reconcileFocus()
  Assert.equal(controller.focus, "location:map:12", "the map list opens on its first row")

  state:_consumeUiInput({ { type = "navigate", direction = "down" } })
  Assert.equal(controller.focus, "location:map:34", "Down moves one map row")
  Assert.equal(controller.locationMapId, 12, "moving the map cursor leaves the committed map alone")
  Assert.equal(harness.buildView().location.mapId, 12, "the committed map snapshot is untouched by browsing")
  for _, intent in ipairs(harness.intents) do
    Assert.isTrue(intent.kind ~= "location-map-select", "browsing rows never selects a map")
  end

  Assert.isNil(
    controller:pointer({
      type = "pointer_down",
      pointerId = "touch:map-row",
      targetId = "location:map:47",
      x = 8,
      y = 8,
    }),
    "pressing a map row never starts map work"
  )
  local firstTap =
    controller:pointer({ type = "pointer_up", pointerId = "touch:map-row", targetId = "location:map:47", x = 8, y = 8 })
  Assert.deepEqual(firstTap, { kind = "activate", targetId = "location:map:47" }, "a clean tap activates the map row")
  Assert.equal(controller.focus, "location:map:47", "the tap moves focus to its map row")
  Assert.equal(controller.locationMapId, 12, "the activation request does not commit a map itself")

  Assert.isNil(controller:pointer({
    type = "pointer_down",
    pointerId = "touch:map-act",
    targetId = "location:map:47",
    x = 8,
    y = 8,
  }))
  local secondTap =
    controller:pointer({ type = "pointer_up", pointerId = "touch:map-act", targetId = "location:map:47", x = 8, y = 8 })
  Assert.deepEqual(
    secondTap,
    { kind = "activate", targetId = "location:map:47" },
    "a clean tap on the focused row requests activation"
  )
  Assert.equal(
    controller.locationMapId,
    12,
    "the activation request alone never commits the map; only explicit handling does"
  )

  Assert.isNil(controller:pointer({
    type = "pointer_down",
    pointerId = "touch:map-drag",
    targetId = "location:map:7",
    x = 8,
    y = 8,
  }))
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
  Assert.equal(harness.service.updateCalls, 0, "the input path performs no service update before the next update")
end

function T.tests.location_grid_direction_moves_the_cursor_without_a_list_viewport()
  local harness = mapActivationHarness()
  harness.state.locationAutoCenterToken = { mapId = 12 }
  local before = assert(harness.controller:locationSnapshot().cursor)
  harness.state:_navigate({
    defaultFocus = "location:grid",
    focusNavigation = {
      regions = {
        {
          id = "body",
          kind = "spatial",
          order = 1,
          defaultId = "location:grid",
          rect = { x = 0, y = 0, width = 40, height = 40 },
        },
      },
      controls = {
        {
          id = "location:grid",
          regionId = "body",
          order = 1,
          eligible = true,
          rect = { x = 0, y = 0, width = 40, height = 40 },
        },
      },
    },
    viewports = {},
  }, "right")
  local after = assert(harness.controller:locationSnapshot().cursor)

  Assert.equal(after.fieldX, before.fieldX + 1, "directional grid input moves the location cursor one tile")
  Assert.equal(after.fieldZ, before.fieldZ, "horizontal grid input preserves the row")
  Assert.isNil(harness.state.locationAutoCenterToken, "manual grid movement takes ownership from the suggestion")
  Assert.equal(harness.service.cancelInitialSurveyCalls or 0, 1, "manual grid movement cancels the pending survey")
end

function T.tests.pointer_pan_takes_location_cursor_ownership_before_the_next_update()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:chooseLocationMap(12, 32, 48)
  local canceled = 0
  local state = stateHarness({
    controller = controller,
    locationAutoCenterToken = { mapId = 12, generation = 3 },
    locationService = {
      cancelInitialSurvey = function()
        canceled = canceled + 1
      end,
    },
    presentation = {
      mapInput = function(_, events)
        return events
      end,
    },
    _snapshot = function()
      return {}
    end,
    _resolve = function()
      return { content = { layout = { lists = {} } } }
    end,
    _reconcileFocus = function() end,
    _syncScope = function() end,
    _settleScope = function() end,
    _dispatchIntent = function() end,
  })

  state:_pointer({
    {
      type = "pointer_down",
      pointerId = "touch:grid-pan",
      targetId = "location:grid",
      grid = { tileSize = 16 },
      x = 10,
      y = 10,
      scopeId = controller.scopeId,
      scopeEpoch = controller.scopeEpoch,
    },
  })
  state:_pointer({
    {
      type = "pointer_move",
      pointerId = "touch:grid-pan",
      x = 30,
      y = 10,
      scopeId = controller.scopeId,
      scopeEpoch = controller.scopeEpoch,
    },
  })

  Assert.isNil(state.locationAutoCenterToken, "manual map panning owns the preview before an update can recenter it")
  Assert.equal(canceled, 1, "starting a pointer pan cancels the automatic survey")
end

function T.tests.location_grid_page_only_moves_its_cursor_when_grid_has_focus()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:chooseLocationMap(12, 32, 48)
  local function target(id, regionId, order, x, y, width, height)
    return {
      id = id,
      regionId = regionId,
      order = order,
      eligible = true,
      rect = { x = x, y = y, width = width, height = height },
    }
  end
  local layout = {
    scopeId = controller.scopeId,
    scopeEpoch = controller.scopeEpoch,
    defaultFocus = "location:grid",
    viewports = {},
    focusNavigation = {
      regions = {
        {
          id = "sections",
          kind = "column",
          order = 1,
          rect = { x = 0, y = 0, width = 20, height = 20 },
          defaultId = "section:Location",
          exits = {
            right = { kind = "region", id = "body", entry = "spatial", fallback = "auto" },
          },
        },
        {
          id = "body",
          kind = "spatial",
          order = 2,
          rect = { x = 32, y = 32, width = 40, height = 40 },
          defaultId = "location:grid",
        },
        {
          id = "global-footer",
          kind = "row",
          order = 3,
          rect = { x = 32, y = 80, width = 40, height = 20 },
          defaultId = "back",
          exits = {
            up = { kind = "region", id = "body", entry = "spatial", fallback = "auto" },
          },
        },
      },
      controls = {
        target("section:Location", "sections", 1, 0, 0, 20, 20),
        target("location:grid", "body", 2, 32, 32, 40, 40),
        target("back", "global-footer", 3, 32, 80, 40, 20),
      },
    },
  }
  local cursorMoves = 0
  local state = stateHarness({
    controller = controller,
    valueEditor = nil,
    _performDeferred = function(_, intent)
      if intent.kind == "location-cursor-move" then
        cursorMoves = cursorMoves + 1
      end
    end,
  })
  local initialCursor = controller:locationSnapshot().cursor

  controller:setFocus("section:Location")
  state:_navigate(layout, "right")
  Assert.equal(controller.focus, "location:grid", "the section rail enters the grid through focus navigation")
  Assert.equal(cursorMoves, 0, "section-rail focus does not move the grid cursor")

  controller:setFocus("location:grid")
  controller:setFocus("back")
  Assert.equal(controller.locationFocus, "grid", "footer focus leaves the grid mode remembered")
  state:_navigate(layout, "up")
  Assert.equal(controller.focus, "location:grid", "the footer enters the grid through focus navigation")
  Assert.equal(cursorMoves, 0, "global-footer focus does not move the grid cursor")
  Assert.deepEqual(controller:locationSnapshot().cursor, initialCursor, "off-grid focus preserves the preview cursor")
end

function T.tests.map_hierarchy_focus_and_group_entry_wait_for_leaf_browse_activation()
  local groupId = "test-group"
  local harness = mapActivationHarness()
  local controller, state, service = harness.controller, harness.state, harness.service
  controller:backLocation()
  controller:setFocus(groupId)
  state:_updateLocationService()
  Assert.isTrue(type(controller.enterLocationGroup) == "function", "Controller enters an explicit map section")
  controller:enterLocationGroup(groupId)
  controller:setFocus(groupId)
  state:_updateLocationService()
  Assert.deepEqual(service.openMaps, {}, "root and group focus do not start map preparation")
  Assert.equal(service.updateCalls, 0, "root and group navigation do not advance location work")

  controller:chooseLocationMap(34, 12, 18)
  Assert.deepEqual(service.openMaps, {}, "publishing the coordinate page does not run a loader synchronously")
  state:_updateLocationService()
  Assert.deepEqual(service.openMaps, { 34 }, "the next owned update starts one browse request for the leaf")
  state:_updateLocationService()
  Assert.deepEqual(service.openMaps, { 34 }, "repeated grid refreshes reuse the active browse request")
end

function T.tests.ready_map_suggestion_centers_the_preview_without_committing_the_destination()
  local harness = mapActivationHarness()
  local writes = 0
  harness.state.session = {
    snapshot = function()
      return { location = { mapId = 12, fieldX = 32, fieldZ = 48 } }
    end,
    setLocation = function()
      writes = writes + 1
      return { ok = true }
    end,
  }
  harness.service.snapshot = function()
    return {
      generation = 3,
      status = { state = "ready" },
      initialCursor = {
        state = "ready",
        mapId = 34,
        generation = 3,
        fieldX = 121,
        fieldZ = 223,
      },
    }
  end

  harness.state:_performDeferred({ kind = "location-map-select", mapId = 34 })
  harness.state:_updateLocationService()

  local navigation = harness.controller:locationSnapshot()
  Assert.deepEqual(navigation.cursor, { fieldX = 121, fieldZ = 223 }, "the matching survey result centers the cursor")
  Assert.deepEqual(navigation.center, { fieldX = 121, fieldZ = 223 }, "the matching survey result centers the viewport")

  harness.state:_performDeferred({ kind = "location-pan", direction = "right" })
  local manuallyPanned = harness.controller:locationSnapshot()
  harness.state:_updateLocationService()
  Assert.deepEqual(
    harness.controller:locationSnapshot().center,
    manuallyPanned.center,
    "a later service publication cannot take ownership back from manual panning"
  )
  Assert.equal(writes, 0, "a cursor suggestion does not stage a save destination")
end

function T.tests.first_viewport_generation_keeps_the_initial_map_suggestion_current()
  local harness = mapActivationHarness()
  local generation = 0
  local requestGeneration = 0
  local initialCursor
  function harness.service:openMap(mapId)
    self.openMaps[#self.openMaps + 1] = mapId
    generation = generation + 1
    requestGeneration = requestGeneration + 1
    initialCursor = { state = "pending", mapId = mapId, generation = requestGeneration }
  end
  function harness.service:setViewport()
    generation = generation + 1
  end
  function harness.service:update()
    self.updateCalls = self.updateCalls + 1
    initialCursor = {
      state = "ready",
      mapId = 34,
      generation = requestGeneration,
      fieldX = 121,
      fieldZ = 223,
    }
  end
  function harness.service:snapshot()
    return {
      generation = generation,
      status = { state = "ready" },
      initialCursor = initialCursor,
    }
  end

  harness.state:_performDeferred({ kind = "location-map-select", mapId = 34 })
  harness.state:_updateLocationService()

  Assert.equal(generation, 2, "the first viewport publication advances the browse generation")
  Assert.deepEqual(
    harness.controller:locationSnapshot().cursor,
    { fieldX = 121, fieldZ = 223 },
    "the state consumes a valid suggestion from its browse-request generation"
  )
  Assert.isNil(harness.state.locationAutoCenterToken, "consuming the current suggestion clears its token")
end

function T.tests.map_suggestion_waits_for_the_service_to_be_ready_before_centering()
  local harness = mapActivationHarness()
  local generation, status, initialCursor = 0, "pending", nil
  function harness.service:openMap(mapId)
    self.openMaps[#self.openMaps + 1] = mapId
    generation = generation + 1
    initialCursor = { state = "pending", mapId = mapId, generation = generation }
  end
  function harness.service:setViewport()
    generation = generation + 1
    initialCursor.generation = generation
  end
  function harness.service:update()
    self.updateCalls = self.updateCalls + 1
    if self.updateCalls == 1 then
      initialCursor = { state = "ready", mapId = 34, generation = generation, fieldX = 16, fieldZ = 24 }
    else
      status = "ready"
      initialCursor = { state = "ready", mapId = 34, generation = generation, fieldX = 121, fieldZ = 223 }
    end
  end
  function harness.service:snapshot()
    return { generation = generation, status = { state = status }, initialCursor = initialCursor }
  end

  harness.state:_performDeferred({ kind = "location-map-select", mapId = 34 })
  harness.state:_updateLocationService()

  Assert.notNil(harness.state.locationAutoCenterToken, "an early suggestion cannot consume the pending center request")
  Assert.deepEqual(
    harness.controller:locationSnapshot().cursor,
    { fieldX = 116, fieldZ = 216 },
    "a ready survey result does not move the preview while map preparation is pending"
  )

  harness.state:_updateLocationService()

  Assert.deepEqual(
    harness.controller:locationSnapshot().cursor,
    { fieldX = 121, fieldZ = 223 },
    "the final suggestion centers the preview after service readiness"
  )
  Assert.isNil(harness.state.locationAutoCenterToken, "the completed suggestion consumes its center request")
end

function T.tests.leaving_location_disarms_a_late_map_suggestion_and_releases_grid_work()
  local harness = mapActivationHarness()
  harness.service.snapshot = function()
    return {
      generation = 3,
      status = { state = "ready" },
      initialCursor = {
        state = "ready",
        mapId = 12,
        generation = 3,
        fieldX = 41,
        fieldZ = 55,
      },
    }
  end
  local updatesBeforeExit = harness.service.updateCalls

  harness.state:_performDeferred({ kind = "section", section = "Player" })
  harness.state:_updateLocationService()

  Assert.equal(harness.controller.section, "Player", "the user leaves Location")
  Assert.equal(harness.service.releaseGridCalls, 1, "leaving the coordinate page releases browse work")
  Assert.equal(harness.service.updateCalls, updatesBeforeExit, "a late result cannot advance after leaving the page")
  Assert.deepEqual(
    harness.controller:locationSnapshot().cursor,
    { fieldX = 32, fieldZ = 48 },
    "a late suggestion cannot move the preview after leaving Location"
  )
end

function T.tests.late_suggestion_from_replaced_map_cannot_move_or_commit_the_new_preview()
  local harness = mapActivationHarness()
  harness.state.dependencies.world = {
    maps = {
      { worldOriginX = 100, worldOriginZ = 200 },
      { worldOriginX = 300, worldOriginZ = 400 },
    },
    byId = { [12] = 1, [34] = 2 },
  }
  local writes = 0
  harness.state.session = {
    snapshot = function()
      return { location = { mapId = 12, fieldX = 32, fieldZ = 48 } }
    end,
    setLocation = function()
      writes = writes + 1
      return { ok = true }
    end,
  }
  local serviceView = { generation = 3, status = { state = "pending" } }
  harness.service.openMap = function(self, mapId)
    self.openMaps[#self.openMaps + 1] = mapId
    serviceView = {
      generation = serviceView.generation + 1,
      status = { state = "pending" },
      initialCursor = { state = "pending", mapId = mapId, generation = serviceView.generation + 1 },
    }
  end
  harness.service.snapshot = function()
    return serviceView
  end

  harness.state:_performDeferred({ kind = "location-map-select", mapId = 12 })
  harness.state:_updateLocationService()
  Assert.deepEqual(harness.service.openMaps, { 12 }, "map A starts the first browse request")

  harness.state:_performDeferred({ kind = "location-map-select", mapId = 34 })
  serviceView = { generation = 4, status = { state = "pending" } }
  harness.state:_updateLocationService()
  Assert.deepEqual(harness.service.openMaps, { 12, 34 }, "map B replaces the pending browse request")
  local mapBPreview = harness.controller:locationSnapshot()

  serviceView = {
    generation = 3,
    status = { state = "ready" },
    initialCursor = {
      state = "ready",
      mapId = 12,
      generation = 3,
      fieldX = 41,
      fieldZ = 55,
    },
  }
  harness.state:_updateLocationService()

  Assert.equal(harness.controller:locationSnapshot().mapId, 34, "the replacement map keeps page ownership")
  Assert.deepEqual(
    harness.controller:locationSnapshot().cursor,
    mapBPreview.cursor,
    "map A's late suggestion cannot move map B's preview cursor"
  )
  Assert.deepEqual(
    harness.controller:locationSnapshot().center,
    mapBPreview.center,
    "map A's late suggestion cannot recenter map B's viewport"
  )
  Assert.equal(writes, 0, "a stale survey result never writes the staged destination")
end

function T.tests.steady_update_never_prepares_icons()
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
    scopeId = harness.controller.scopeId,
    scopeEpoch = harness.controller.scopeEpoch,
    focusNavigation = {
      regions = { { id = "body", order = 1, kind = "spatial", rect = { x = 0, y = 0, width = 1, height = 1 } } },
      controls = {
        {
          id = harness.controller.focus,
          regionId = "body",
          rect = { x = 0, y = 0, width = 1, height = 1 },
          eligible = true,
          order = 1,
          action = { kind = "target", targetId = harness.controller.focus },
        },
      },
    },
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
  local published = harness.state:view()
  Assert.equal(snapshots, 1, "the observation publishes the settled pair once")
  Assert.equal(resolves, 1, "the observation resolves the settled plan once")
  Assert.isTrue(published.presentation == plan, "the observation pairs the view with its plan")
  snapshots, resolves = 0, 0
  local drawnView, drawnPresentation = nil, nil
  local originalDraw = ApplicationPresentation.draw
  ApplicationPresentation.draw = function(_, _, view, presentation)
    drawnView, drawnPresentation = view, presentation
  end
  local firstOk, firstError = pcall(function()
    harness.state:draw()
  end)
  local secondOk, secondError = pcall(function()
    harness.state:draw()
  end)
  ApplicationPresentation.draw = originalDraw
  Assert.isTrue(firstOk, "the first draw runs without platform rendering: " .. tostring(firstError))
  Assert.isTrue(secondOk, "the second draw runs without platform rendering: " .. tostring(secondError))
  Assert.equal(snapshots, 0, "settled draws never snapshot again")
  Assert.equal(resolves, 0, "settled draws never resolve again")
  Assert.equal(iconPrepCalls, 0, "draw never requests derived icon work")
  Assert.isTrue(drawnView == published, "draw renders the settled view")
  Assert.isTrue(drawnPresentation == plan, "draw renders the settled plan")
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
      scope = {
        id = "value:" .. (holder.state and holder.state.valuePurpose or "choice"),
        epoch = 1,
        kind = "value",
        focusId = controller.focus,
      },
      scrollOffsets = controller.scrollOffsets,
      preserveChoiceScroll = holder.state ~= nil and holder.state.preserveChoiceScroll or false,
    }
  end
  local function buildLayout()
    return Layout.compute(buildView(), 256, 192, metrics)
  end
  local finished = 0
  local state = stateHarness({
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
  })
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

function T.tests.party_species_choice_opens_without_prior_scope_focus()
  local harness = scrollableChoiceHarness(12)
  local controller, state = harness.controller, harness.state
  state.valuePurpose = "party_add_species"
  controller:setFocus("party:add")

  state:_reconcileFocus()

  Assert.equal(
    controller.focus,
    "choice:K01",
    "a new Party species selector enters its first option without remembered scope focus"
  )
end

function T.tests.location_focus_without_a_published_grid_control_falls_back_to_its_section()
  local controller = Controller.new()
  controller:setSection("Location")
  controller.scopeId = "section:Location"
  controller.scopeEpoch = 2
  controller:setFocus("location:grid")
  controller.focusByScope[controller.scopeId] = "back"
  local layout = {
    scopeId = controller.scopeId,
    scopeEpoch = controller.scopeEpoch,
    defaultFocus = "location:grid",
    focusNavigation = {
      regions = {
        { id = "sections", kind = "row", order = 1, rect = { x = 0, y = 0, width = 80, height = 20 } },
        { id = "global-footer", kind = "row", order = 2, rect = { x = 0, y = 20, width = 80, height = 20 } },
      },
      controls = {
        {
          id = "section:Location",
          regionId = "sections",
          eligible = true,
          order = 1,
          rect = { x = 0, y = 0, width = 40, height = 20 },
        },
        {
          id = "back",
          regionId = "global-footer",
          eligible = true,
          order = 2,
          rect = { x = 0, y = 20, width = 40, height = 20 },
        },
      },
    },
    lists = {},
  }
  local state = stateHarness({
    controller = controller,
    _snapshot = function()
      return { section = "Location" }
    end,
    _resolve = function()
      return { content = { layout = layout } }
    end,
  })

  state:_reconcileFocus()

  Assert.equal(controller.focus, "section:Location", "an unpublished grid sentinel falls back to the active section")
end

function T.tests.wheel_scroll_preserves_the_logical_row_focus()
  local flags = progressListHarness(progressFlagCatalog(20))
  local flagController, flagState = flags.controller, flags.state
  flagController:setFocus("list:flags")
  flags.sync()
  local flagFocus = flagController.focus
  Assert.isTrue(flagFocus ~= "list:flags", "the list starts on a logical row")
  flagController:markKeyboardNavigation()
  flagState:wheelmoved(0, -30)
  flags.sync()
  Assert.equal(flagController.focus, flagFocus, "wheel scrolling preserves the logical row (flags)")
  Assert.isFalse(flagController.focusVisible, "wheel input hides keyboard focus indication (flags)")
  Assert.deepEqual(flags.activations, {}, "wheel scrolling never activates (flags)")

  local maps = overflowingLocationListHarness(800, 600, 30)
  local mapController, mapState = maps.controller, maps.state
  mapController:setFocus("list:location:group:1")
  mapState:_reconcileFocus()
  local mapFocus = mapController.focus
  mapState:wheelmoved(0, -30)
  Assert.equal(mapController.focus, mapFocus, "wheel scrolling preserves the logical row (map list)")
  Assert.isFalse(mapController.focusVisible, "wheel input hides keyboard focus indication (map list)")
  Assert.deepEqual(maps.intents, {}, "wheel scrolling never starts map work (map list)")
  Assert.equal(mapController.locationMapId, 12, "wheel scrolling never commits a map (map list)")

  local choice = scrollableChoiceHarness(12)
  local choiceController, choiceState, choiceEditor = choice.controller, choice.state, choice.editor
  choiceController:setFocus("list:value:choice")
  choiceState:_reconcileFocus()
  local choiceFocus = choiceController.focus
  choiceState:wheelmoved(0, -30)
  Assert.equal(choiceController.focus, choiceFocus, "wheel scrolling preserves the logical row (choices)")
  Assert.isFalse(choiceController.focusVisible, "wheel input hides keyboard focus indication (choices)")
  Assert.equal(choice.finishedCount(), 0, "wheel scrolling never submits the editor (choices)")
  Assert.isNil(choiceEditor:result(), "wheel scrolling publishes no result (choices)")
end

function T.tests.scrolling_preserves_logical_focus_until_the_next_direction()
  local harness = progressListHarness(progressFlagCatalog(20))
  local controller, state = harness.controller, harness.state
  controller:setFocus("list:flags")
  harness.sync()
  for _ = 1, 2 do
    state:_consumeUiInput({ { type = "navigate", direction = "down" } })
  end
  harness.sync()
  local rows = harness.current.layout.lists.flags.rowTargets
  Assert.equal(controller.focus, rows[3], "keyboard navigation reaches the third row")
  controller:markKeyboardNavigation()
  state:wheelmoved(0, -1)
  harness.sync()
  Assert.equal(controller.focus, rows[3], "a small scroll preserves logical row focus")
  Assert.isFalse(controller.focusVisible, "wheel input hides keyboard focus indication")

  state:wheelmoved(0, -30)
  harness.sync()
  Assert.equal(controller.focus, rows[3], "a far scroll preserves logical row focus")
  state:_consumeUiInput({ { type = "navigate", direction = "down" } })
  harness.sync()
  Assert.equal(controller.focus, rows[4], "the next direction resolves from the remembered row")

  state:textinput("zzz-no-such-flag")
  harness.sync()
  Assert.deepEqual(harness.current.layout.lists.flags.rowTargets, {}, "the filter empties the list")
  state:wheelmoved(0, -5)
  harness.sync()
  Assert.isNil(controller:listCursor("flags"), "an empty list keeps a nil cursor")
  Assert.equal(controller.focus, "list:flags", "an empty list keeps its inert placeholder focus")
end

function T.tests.pointer_row_activation_and_scope_exit_preserve_logical_identity()
  local flags = progressListHarness(progressFlagCatalog(6))
  local flagController, flagState = flags.controller, flags.state
  installPointerPassThrough(flagState)
  flagController:setFocus("list:flags")
  flags.sync()
  local flagRows = flags.current.layout.lists.flags.rowTargets
  local flagTarget = flagRows[3]
  flagState:_pointer({ { type = "pointer_down", pointerId = "touch:flags", targetId = flagTarget, x = 8, y = 8 } })
  flags.sync()
  flagState:_pointer({ { type = "pointer_up", pointerId = "touch:flags", targetId = flagTarget, x = 8, y = 8 } })
  flags.sync()
  Assert.equal(flagController.focus, flagTarget, "a first tap focuses the tapped row (flags)")
  Assert.deepEqual(flags.activations, { flagTarget }, "a clean first tap activates the row (flags)")
  flagState:_consumeUiInput({ { type = "cancel" } })
  flags.sync()
  Assert.equal(flagController.focus, flagTarget, "Back preserves row identity (flags)")
  Assert.equal(flagController:listCursor("flags"), flagTarget, "pointer focus synchronizes the cursor (flags)")

  local maps = locationListHarness()
  local mapController, mapState = maps.controller, maps.state
  installPointerPassThrough(mapState)
  mapController:setFocus("list:location:group:1")
  mapState:_reconcileFocus()
  Assert.equal(mapController.focus, "location:map:12", "map browsing starts on a logical row")
  mapState:_pointer({
    { type = "pointer_down", pointerId = "touch:maps", targetId = "location:map:47", x = 8, y = 8 },
  })
  mapState:_pointer({
    { type = "pointer_up", pointerId = "touch:maps", targetId = "location:map:47", x = 8, y = 8 },
  })
  Assert.equal(mapController.focus, "location:map:47", "a first tap focuses the tapped map row")
  Assert.equal(#maps.intents, 1, "a clean tap requests map selection")
  Assert.equal(mapController.locationMapId, 12, "a first tap never commits a map")
  mapState:_consumeUiInput({ { type = "cancel" } })
  Assert.equal(mapController.focus, "location:map:47", "Back preserves the focused map row")
  Assert.equal(
    mapController:listCursor("location:group:1"),
    "location:map:47",
    "pointer focus synchronizes the map cursor"
  )
  Assert.equal(mapController.locationMapId, 12, "re-entering the row never commits a map")

  local choice = scrollableChoiceHarness(12)
  local choiceController, choiceState, choiceEditor = choice.controller, choice.state, choice.editor
  installPointerPassThrough(choiceState)
  choiceController:setFocus("list:value:choice")
  choiceState:_reconcileFocus()
  Assert.equal(choiceController.focus, "choice:K01", "choice browsing starts on a logical row")
  choiceState:_pointer({ { type = "pointer_down", pointerId = "touch:choice", targetId = "choice:K03", x = 8, y = 8 } })
  choiceState:_pointer({ { type = "pointer_up", pointerId = "touch:choice", targetId = "choice:K03", x = 8, y = 8 } })
  Assert.equal(choiceController.focus, "choice:K03", "a first tap focuses the tapped choice row")
  Assert.equal(choice.finishedCount(), 1, "a clean tap activates the selected choice")
  Assert.notNil(choiceEditor:result(), "a clean tap publishes the choice result")
end

function T.tests.location_map_keyboard_navigation_uses_logical_rows_without_selecting()
  local harness = overflowingLocationListHarness(256, 192, 30)
  local controller, state = harness.controller, harness.state
  local rows = harness.buildLayout().lists["location:group:1"].rowTargets
  Assert.equal(#rows, 30, "the long map list exposes every row in display order")
  local viewport = assert(harness.buildLayout().viewports["location:group:1"])
  local visibleCount = math.max(1, viewport.lastIndex - viewport.firstIndex + 1)
  Assert.isTrue(visibleCount < #rows, "the fixture list is longer than one viewport")

  controller:setFocus("list:location:group:1")
  state:_reconcileFocus()
  Assert.equal(controller.focus, rows[1], "the map list opens on its first row")
  Assert.equal(controller:listCursor("location:group:1"), rows[1], "opening the region sets its cursor")

  state:_consumeUiInput({ { type = "navigate", direction = "down" } })
  Assert.equal(controller.focus, rows[2], "Down moves one map row")
  Assert.equal(controller:listCursor("location:group:1"), rows[2], "the cursor follows row focus")
  state:_consumeUiInput({ { type = "navigate", direction = "up" } })
  Assert.equal(controller.focus, rows[1], "Up moves one map row")
  Assert.equal(controller:listCursor("location:group:1"), rows[1], "the cursor follows row focus upward")

  state:_consumeUiInput({ { type = "navigate", direction = "left" } })
  Assert.isTrue(controller.focus ~= rows[2], "Left leaves the map list instead of paging rows")
  controller:setFocus(rows[1])
  for index = 2, #rows do
    state:_consumeUiInput({ { type = "navigate", direction = "down" } })
    Assert.equal(controller.focus, rows[index], "Down keeps walking rows (row " .. index .. ")")
    Assert.equal(
      controller:listCursor("location:group:1"),
      rows[index],
      "the cursor tracks focus (row " .. index .. ")"
    )
  end
  Assert.equal(controller.locationMapId, 12, "keyboard browsing never changes the committed map")
  Assert.deepEqual(harness.intents, {}, "keyboard browsing never starts map work")

  state:_consumeUiInput({ { type = "cancel" } })
  Assert.equal(controller.focus, rows[#rows], "Back preserves logical focus within the test scope")
  Assert.equal(harness.backCount(), 1, "Back leaves the active list scope")
end

function T.tests.location_grid_directions_share_the_common_navigation_intent()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 7, fieldX = 10, fieldZ = 12 })
  controller:setFocus("location:grid")
  Assert.equal(controller.locationFocus, "grid", "grid focus remains in its current Location mode")
  for _, direction in ipairs({ "up", "down", "left", "right" }) do
    Assert.deepEqual(
      controller:press(direction),
      { kind = "move", direction = direction },
      "grid focus emits the common navigation intent (" .. direction .. ")"
    )
  end

  controller:setFocus("location:tile:10:12")
  Assert.equal(controller.locationFocus, "grid", "tile focus uses grid movement")
  for _, direction in ipairs({ "up", "down", "left", "right" }) do
    Assert.deepEqual(
      controller:press(direction),
      { kind = "move", direction = direction },
      "tile focus emits the common navigation intent (" .. direction .. ")"
    )
  end

  local before = controller:locationSnapshot().cursor
  controller:moveLocationCursor("up", 7, 5)
  local after = controller:locationSnapshot().cursor
  Assert.notNil(after, "grid movement keeps a grid cursor")
  Assert.isFalse(before.fieldX == after.fieldX and before.fieldZ == after.fieldZ, "grid movement moves the cursor")
  Assert.equal(controller.locationFocus, "grid", "grid movement stays in grid focus")
  Assert.isNil(controller:listCursor("flags"), "grid movement touches no flag cursor")
  Assert.isNil(controller:listCursor("location:group:1"), "grid movement touches no map-list cursor")
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

function T.tests.location_grid_cursor_pages_a_full_visible_window_at_each_edge()
  for _, grid in ipairs({ { width = 11, height = 7 }, { width = 12, height = 8 } }) do
    for _, center in ipairs({ 20, 30000 }) do
      for _, edge in ipairs({ "left", "right", "up", "down" }) do
        local centerX, centerZ = center, center
        local firstX = centerX - math.floor(grid.width / 2)
        local firstZ = centerZ - math.floor(grid.height / 2)
        local cursorX = edge == "left" and firstX or edge == "right" and firstX + grid.width - 1 or centerX
        local cursorZ = edge == "up" and firstZ or edge == "down" and firstZ + grid.height - 1 or centerZ
        local controller = Controller.new()
        controller:setSection("Location")
        controller:enterLocation({ mapId = 7, fieldX = cursorX, fieldZ = cursorZ })
        controller:chooseLocationMap(7, cursorX, cursorZ)
        controller.locationCenterX, controller.locationCenterZ = centerX, centerZ

        controller:moveLocationCursor(edge, grid.width, grid.height)

        local location = controller:locationSnapshot()
        local expectedX = cursorX + (edge == "left" and -1 or edge == "right" and 1 or 0)
        local expectedZ = cursorZ + (edge == "up" and -1 or edge == "down" and 1 or 0)
        local expectedCenterX = centerX + (edge == "left" and -grid.width or edge == "right" and grid.width or 0)
        local expectedCenterZ = centerZ + (edge == "up" and -grid.height or edge == "down" and grid.height or 0)
        Assert.deepEqual(
          location.cursor,
          { fieldX = expectedX, fieldZ = expectedZ },
          "an edge step advances one field tile (" .. grid.width .. "x" .. grid.height .. ", " .. edge .. ")"
        )
        Assert.deepEqual(
          location.center,
          { fieldX = expectedCenterX, fieldZ = expectedCenterZ },
          "an edge step pages one full visible window (" .. grid.width .. "x" .. grid.height .. ", " .. edge .. ")"
        )
        local newFirstX = expectedCenterX - math.floor(grid.width / 2)
        local newFirstZ = expectedCenterZ - math.floor(grid.height / 2)
        Assert.equal(
          expectedX,
          edge == "left" and newFirstX + grid.width - 1 or edge == "right" and newFirstX or expectedX,
          "horizontal paging puts the cursor at the opposite edge"
        )
        Assert.equal(
          expectedZ,
          edge == "up" and newFirstZ + grid.height - 1 or edge == "down" and newFirstZ or expectedZ,
          "vertical paging puts the cursor at the opposite edge"
        )
      end
    end
  end

  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 7, fieldX = 25, fieldZ = 25 })
  controller:chooseLocationMap(7, 25, 25)
  controller:moveLocationCursor("right", 11, 7)
  Assert.deepEqual(
    controller:locationSnapshot().center,
    { fieldX = 25, fieldZ = 25 },
    "a move that remains inside the visible window leaves its center fixed"
  )
end

function T.tests.location_grid_paging_respects_native_limits_drag_and_measured_bounds()
  for _, limit in ipairs({ 0, 65535 }) do
    local controller = Controller.new()
    controller:setSection("Location")
    controller:enterLocation({ mapId = 7, fieldX = limit, fieldZ = limit })
    controller:chooseLocationMap(7, limit, limit)
    local before = controller:locationSnapshot()
    controller:moveLocationCursor(limit == 0 and "left" or "right", 11, 7)
    Assert.deepEqual(
      controller:locationSnapshot(),
      before,
      "an outward move at the native coordinate limit does not wrap or pan"
    )
  end

  local saturated = Controller.new()
  saturated:setSection("Location")
  saturated:enterLocation({ mapId = 7, fieldX = 65534, fieldZ = 100 })
  saturated:chooseLocationMap(7, 65534, 100)
  saturated.locationCenterX = 65529
  saturated:moveLocationCursor("right", 11, 7)
  Assert.deepEqual(
    saturated:locationSnapshot().cursor,
    { fieldX = 65535, fieldZ = 100 },
    "the final in-range cursor step is retained at the native maximum"
  )
  Assert.deepEqual(
    saturated:locationSnapshot().center,
    { fieldX = 65535, fieldZ = 100 },
    "a full page center clamps at the native maximum while keeping the cursor visible"
  )

  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 7, fieldX = 100, fieldZ = 100 })
  controller:chooseLocationMap(7, 100, 100)
  controller:panLocation("right", 11, 7)
  Assert.deepEqual(
    controller:locationSnapshot().center,
    { fieldX = 105, fieldZ = 100 },
    "pointer panning keeps its existing half-screen step"
  )

  local harness = mapActivationHarness()
  harness.state.locationGridWidthTiles, harness.state.locationGridHeightTiles = 11, 7
  harness.state:_performDeferred({ kind = "location-cursor-move", direction = "right" })
  Assert.deepEqual(
    harness.service.viewportCalls[#harness.service.viewportCalls],
    { centerX = 32, centerZ = 48, widthTiles = 11, heightTiles = 7 },
    "the Location service receives the currently measured grid bounds"
  )
  harness.state.locationGridWidthTiles, harness.state.locationGridHeightTiles = 12, 8
  harness.state:_performDeferred({ kind = "location-cursor-move", direction = "down" })
  Assert.deepEqual(
    harness.service.viewportCalls[#harness.service.viewportCalls],
    { centerX = 32, centerZ = 48, widthTiles = 12, heightTiles = 8 },
    "a resized grid publishes its new measured bounds to LocationService"
  )
end

function T.tests.modal_navigation_does_not_move_the_underlying_location_grid()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 7, fieldX = 40, fieldZ = 50 })
  controller:chooseLocationMap(7, 40, 50)
  controller:openModal("leave")
  local updateCalls = 0
  local service = {
    setViewport = function() end,
    update = function()
      updateCalls = updateCalls + 1
    end,
  }
  local token = { mapId = 7, generation = 4 }
  local state = stateHarness({
    controller = controller,
    locationService = service,
    locationServiceMapId = 7,
    locationViewport = { centerX = 40, centerZ = 50, widthTiles = 1, heightTiles = 1 },
    locationAutoCenterToken = token,
    locationGridWidthTiles = 1,
    locationGridHeightTiles = 1,
  })
  local cursorBefore = controller:locationSnapshot().cursor
  local layout = {
    scopeId = controller.scopeId,
    scopeEpoch = controller.scopeEpoch,
    defaultFocus = "cancel",
    viewports = {},
    focusNavigation = {
      regions = { { id = "modal:leave", order = 1, kind = "spatial" } },
      controls = {
        {
          id = "cancel",
          regionId = "modal:leave",
          order = 1,
          eligible = true,
          rect = { x = 0, y = 0, width = 10, height = 10 },
        },
      },
    },
  }

  state:_navigate(layout, "right")

  Assert.deepEqual(
    controller:locationSnapshot().cursor,
    cursorBefore,
    "modal navigation leaves the grid cursor unchanged"
  )
  Assert.equal(updateCalls, 0, "modal navigation never advances LocationService")
  Assert.equal(state.locationAutoCenterToken, token, "modal navigation preserves the pending auto-center token")
end

function T.tests.directional_input_marks_visible_focus_while_pointer_down_hides_it()
  local controller = Controller.new()
  controller:setFocus("money")
  Assert.equal(controller.focusVisible, false, "fresh editors hide the keyboard focus ring")
  controller:markKeyboardNavigation()
  controller:setFocus("dialogue-frame")
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
  controller:setFocus("dialogue-frame")
  Assert.equal(controller.focus, "dialogue-frame", "directional input moves focus after pointer use")
  Assert.equal(controller.focusVisible, true, "directional input restores the ring")
end

function T.tests.pointer_down_on_the_focused_target_still_hides_visible_focus()
  local controller = Controller.new()
  controller:setFocus("money")
  controller:markKeyboardNavigation()
  controller:setFocus("dialogue-frame")
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

function T.tests.wheel_hides_focus_indication_without_replacing_the_logical_row()
  local harness = progressListHarness(progressFlagCatalog(20))
  local controller, state = harness.controller, harness.state
  harness.sync()
  local rows = harness.current.layout.lists.flags.rowTargets
  controller:setFocus(rows[3])
  state:_consumeUiInput({ { type = "navigate", direction = "down" } })
  harness.sync()
  local focusedRow = controller.focus
  Assert.isTrue(controller.focusVisible, "directional navigation shows keyboard focus")

  state:wheelmoved(0, -1)
  harness.sync()
  Assert.equal(controller.focus, focusedRow, "wheel scrolling preserves logical row identity")
  Assert.equal(controller.focusVisible, false, "wheel scrolling hides keyboard focus indication")
  Assert.deepEqual(harness.activations, {}, "wheel scrolling does not activate the focused row")

  state:_consumeUiInput({ { type = "navigate", direction = "down" } })
  harness.sync()
  Assert.equal(controller.focus, rows[5], "the next direction continues from the remembered logical row")
  Assert.isTrue(controller.focusVisible, "directional navigation restores visible focus")
  local viewport = assert(harness.current.layout.viewports.flags)
  Assert.isTrue(
    viewport.firstIndex <= 5 and viewport.lastIndex >= 5,
    "directional navigation reveals the next logical row after scrolling"
  )
end

function T.tests.merely_focusing_a_section_never_activates_it()
  local controller = Controller.new()
  controller:setFocus("section:Bag")
  Assert.equal(controller.focus, "section:Bag", "focus can rest on a section option")
  Assert.equal(controller.section, "Player", "focused section options stay inactive until activated")
end

function T.tests.focus_memory_is_scoped_to_the_active_interaction()
  local controller = Controller.new()
  controller.scopeId = "scope:one"
  controller:setFocus("money")
  controller.scopeId = "scope:two"
  controller:setFocus("save")
  controller.scopeId = "scope:one"
  Assert.equal(controller.focusByScope["scope:one"], "money", "the prior scope retains its logical focus")
  Assert.equal(controller.focusByScope["scope:two"], "save", "the replacement scope owns its own focus")
  Assert.equal(controller.focusVisible, false, "scope focus changes never show the ring by themselves")
end

function T.tests.flag_value_snapshots_do_not_mutate_cached_flag_metadata()
  local controller = Controller.new()
  controller:setSection("Progress")
  local state = stateHarness({
    controller = controller,
    status = "ready",
    session = {},
    tickRemainder = 0,
    inputTick = 0,
    valueEditor = nil,
    numberHold = nil,
    disposed = false,
  })
  while state._flagCatalog == nil do
    state:update(0)
  end
  local opening = state:_flagProjection({})
  Assert.isTrue(opening.count > 0, "the catalog exposes flag rows")
  local sample = assert(opening.rowAt(1))
  local originalName, originalLabel, originalValue = sample.name, sample.displayName, sample.value
  local values = { [sample.id] = true }
  local refreshed = state:_flagProjection(values)
  Assert.equal(sample.name, originalName, "a value revision leaves cached flag identity unchanged")
  Assert.equal(sample.displayName, originalLabel, "a value revision leaves cached labels unchanged")
  Assert.equal(sample.value, originalValue, "a new snapshot does not mutate an earlier snapshot")
  Assert.equal(assert(refreshed.rowAt(1)).value, true, "the refreshed visible flag reflects the current revision")
  local cleared = state:_flagProjection({})
  Assert.equal(assert(refreshed.rowAt(1)).value, true, "a later revision leaves the prior value snapshot stable")
  Assert.equal(assert(cleared.rowAt(1)).value, false, "the current snapshot reflects the cleared flag")
  controller.query = sample.name:sub(1, 8):lower()
  state:_flagProjection({})
  while state._listFilterTask ~= nil do
    state:_advanceListFilter(256)
  end
  local filtered = state:_flagProjection({})
  Assert.isTrue(filtered.count < opening.count, "filtering narrows the catalog")
  for index = 1, filtered.count do
    local row = assert(filtered.rowAt(index))
    Assert.notNil(row.targetId, "cached rows carry their stable target identity")
  end
end

function T.tests.flag_value_reads_stay_within_the_visible_rows_and_two_width_samples()
  local controller = Controller.new()
  controller:setSection("Progress")
  local reads = 0
  local flags = setmetatable({}, {
    __index = function()
      reads = reads + 1
      return false
    end,
  })
  local snapshot = {
    flags = flags,
    dirtySections = { flags = false },
    frameIndex = 0,
    playerName = "Trainer",
    money = 0,
  }
  local session = {
    revision = function()
      return 0
    end,
    snapshot = function()
      return snapshot
    end,
    isDirty = function(self)
      local dirty = self:snapshot().dirtySections
      return dirty.money or dirty.frame or dirty.flags or dirty.party or dirty.bag or dirty.location
    end,
  }
  local catalog = {}
  for index = 1, 1000 do
    local name = string.format("FLAG_TEST_%04d", index)
    catalog[index] = {
      name = name,
      displayName = name:sub(6),
      id = index,
      targetId = "flag:" .. name,
    }
  end
  local state = stateHarness({
    status = "ready",
    controller = controller,
    fieldInput = FieldInput.new(),
    inputTick = 0,
    scopeEpoch = 0,
    numberPressUntilTick = 0,
    preserveChoiceScroll = false,
    session = session,
    _flagCatalog = catalog,
    modalStack = ModalStack.new(),
    modalLayerSequence = 0,
  })
  local view = state:_snapshot()
  view.scope = { id = "section:Progress", epoch = 1, kind = "section", focusId = controller.focus }
  view.textMetrics = interactionMetrics()
  view.scrollOffsets = {}
  local layout = Layout.compute(view, 256, 192, view.textMetrics)
  local viewport = assert(layout.viewports.flags)
  local visibleCount = math.max(0, viewport.lastIndex - viewport.firstIndex + 1)
  Assert.isTrue(visibleCount > 0 and visibleCount < #catalog, "the test viewport covers only part of the flag list")
  Assert.isTrue(
    reads <= visibleCount * 3,
    string.format(
      "the layout read %d flag values for %d visible rows and two bounded width samples",
      reads,
      visibleCount
    )
  )
end

function T.tests.flag_filter_publishes_bounded_generations()
  local controller = Controller.new()
  controller:setSection("Progress")
  local catalog = {}
  for index = 1, 1000 do
    local name = string.format("FLAG_TEST_%04d", index)
    catalog[index] = {
      name = name,
      displayName = name,
      id = index,
      targetId = "flag:" .. name,
    }
  end
  local state = stateHarness({
    status = "ready",
    controller = controller,
    fieldInput = FieldInput.new(),
    inputTick = 0,
    tickRemainder = 0,
    scopeEpoch = 0,
    numberPressUntilTick = 0,
    preserveChoiceScroll = false,
    _flagCatalog = catalog,
  })
  local initial = state:_flagProjection({})
  Assert.equal(initial.count, #catalog, "the initial indexed projection covers the catalog")
  Assert.equal(initial.idAt(1), "flag:FLAG_TEST_0001", "the projection resolves stable row identity")
  Assert.equal(initial.indexOf("flag:FLAG_TEST_0999"), 999, "the projection resolves stable row position")
  Assert.equal(initial.rowAt(1).value, false, "row payloads read the current flag value")

  controller.query = "does-not-exist"
  state:_filteredFlagRows()
  state:update(0)
  local pending = state:_flagProjection({})
  Assert.isTrue(pending.pending, "the previous rows remain published while the query is pending")
  Assert.equal(pending.idAt(1), initial.idAt(1), "pending rows retain their prior logical order")
  Assert.isTrue(state._listFilterTask.cursor <= 257, "one update visits at most 256 catalog rows")
  Assert.equal(pending.queryRevision, initial.queryRevision + 1, "the pending query has a new generation")

  controller.query = "FLAG_TEST_1000"
  state:_filteredFlagRows()
  local newest = state:_flagProjection({})
  Assert.isTrue(newest.pending, "a newer query replaces the unfinished generation")
  Assert.equal(newest.queryRevision, pending.queryRevision + 1, "the replacement query owns a newer revision")
  state:update(0)
  state:update(0)
  state:update(0)
  state:update(0)
  local published = state:_flagProjection({})
  Assert.isFalse(published.pending, "a completed generation publishes atomically")
  Assert.equal(published.count, 1, "the newest query contains only matching rows")
  Assert.equal(published.idAt(1), "flag:FLAG_TEST_1000", "an obsolete generation never publishes")
  Assert.equal(published.revision, initial.revision + 1, "publication advances the projection revision once")
end

function T.tests.first_progress_snapshot_defers_flag_catalog_enumeration_to_bounded_updates()
  local controller = Controller.new()
  controller:setSection("Progress")
  local state = stateHarness({
    controller = controller,
    status = "ready",
    session = {},
    tickRemainder = 0,
    inputTick = 0,
    valueEditor = nil,
    numberHold = nil,
    disposed = false,
    _listFilterTask = nil,
    _listQueryRevision = 0,
  })
  local visits = 0
  local originalPairs = pairs
  local expectedVisits = 0
  for _ in originalPairs(FieldScriptSymbols.flagsByName) do
    expectedVisits = expectedVisits + 1
  end
  _G.pairs = function(source)
    local iterator, tableValue, key = originalPairs(source)
    if source ~= FieldScriptSymbols.flagsByName then
      return iterator, tableValue, key
    end
    return function()
      key = iterator(tableValue, key)
      if key ~= nil then
        visits = visits + 1
      end
      return key, tableValue[key]
    end,
      tableValue,
      key
  end
  local ok, errorMessage = xpcall(function()
    local initial = state:_flagProjection({})
    Assert.equal(visits, 0, "the first Progress snapshot does not enumerate the flag catalog")
    Assert.equal(initial.count, 0, "the pending catalog publishes an empty Progress projection")
    Assert.isTrue(initial.pending, "the projection reports that its catalog is still being prepared")

    state:update(0)
    Assert.isTrue(visits > 0 and visits <= 256, "one update enumerates only its row budget")
    while visits < expectedVisits do
      local before = visits
      state:update(0)
      Assert.isTrue(visits - before <= 256, "later updates keep flag enumeration bounded")
    end
    Assert.isNil(state._flagCatalog, "catalog enumeration does not synchronously sort and index all flags")
    while state._flagCatalog == nil do
      state:update(0)
    end
    local prepared = state:_flagProjection({})
    Assert.isFalse(prepared.pending, "the complete flag catalog publishes after preparation")
    Assert.isTrue(prepared.count > 0, "the prepared projection contains known script flags")
  end, debug.traceback)
  _G.pairs = originalPairs
  if not ok then
    error(errorMessage, 0)
  end
end

function T.tests.map_filter_publishes_bounded_generations()
  local controller = Controller.new()
  controller:setSection("Location")
  controller.locationPage = "group"
  controller.locationGroupId = "location:group:1"
  local summaries = {}
  for index = 1, 1000 do
    summaries[index] = {
      mapId = index,
      symbol = string.format("MAP_TEST_%04d", index),
      section = "TEST_SECTION",
      mapSectionNativeId = 1,
      displayName = string.format("Test map %04d", index),
    }
  end
  local state = stateHarness({
    status = "ready",
    controller = controller,
    fieldInput = FieldInput.new(),
    inputTick = 0,
    tickRemainder = 0,
    scopeEpoch = 0,
    numberPressUntilTick = 0,
    preserveChoiceScroll = false,
    _locationListCaches = {},
    locationService = {
      mapSummaries = function()
        return summaries
      end,
    },
  })
  state._locationMapCatalog = require("app.src.saveeditor.SaveEditorMapCatalog").new(summaries)
  prepareLocationList(state, "location:group:1")
  local initial = state:_mapProjection()
  Assert.equal(initial.count, #summaries, "the initial indexed map projection covers the catalog")
  Assert.equal(initial.idAt(1), "location:map:1", "the map projection resolves stable row identity")
  Assert.equal(initial.indexOf("location:map:999"), 999, "the map projection resolves stable row position")
  Assert.equal(initial.rowAt(1).symbol, "MAP_TEST_0001", "the projection resolves map metadata")

  controller.query = "no-such-map"
  state:_mapProjection()
  state:update(0)
  local pending = state:_mapProjection()
  Assert.isTrue(pending.pending, "the previous map rows remain published while the query is pending")
  Assert.equal(pending.idAt(1), initial.idAt(1), "pending maps retain their prior logical order")
  Assert.isTrue(state._listFilterTask.cursor <= 257, "one update visits at most 256 map summaries")
  Assert.equal(pending.queryRevision, initial.queryRevision + 1, "the pending map query has a new generation")

  state:update(0)
  state:update(0)
  state:update(0)
  local published = state:_mapProjection()
  Assert.isFalse(published.pending, "a completed map generation publishes atomically")
  Assert.equal(published.count, 0, "the published map query contains only matching rows")
  Assert.equal(published.revision, initial.revision + 1, "map publication advances the revision once")
end

function T.tests.location_catalog_and_list_publication_share_the_update_budget()
  local controller = Controller.new()
  controller:setSection("Location")
  local summaries, sourceReads = {}, 0
  local sourceTask = { cursor = 1 }
  function sourceTask:advance(budget)
    local used = 0
    while used < budget and self.cursor <= 600 do
      local mapId = self.cursor
      summaries[#summaries + 1] = {
        mapId = mapId,
        symbol = string.format("MAP_TEST_%04d", mapId),
        section = "TEST_SECTION",
        mapSectionNativeId = 1,
        displayName = string.format("Test map %04d", mapId),
      }
      self.cursor = mapId + 1
      sourceReads = sourceReads + 1
      used = used + 1
    end
    return used, self.cursor > 600
  end
  function sourceTask:take()
    return summaries
  end

  local state = stateHarness({
    status = "preparing",
    controller = controller,
    locationService = {},
    fieldInput = FieldInput.new(),
    inputTick = 0,
    tickRemainder = 0,
    _locationMapSummaryTask = sourceTask,
    _locationListCaches = {},
  })
  local advance = state._advanceLocationPreparation
  local updateWork = {}
  state._advanceLocationPreparation = function(self, budget)
    local used = advance(self, budget)
    updateWork[#updateWork + 1] = used
    return used
  end

  Assert.isTrue(state:_mapProjection().pending, "the map root stays pending before its source scan completes")
  state:update(0)
  Assert.equal(sourceReads, 256, "the real update loop limits source-summary acquisition to its row budget")
  Assert.isNil(state._locationMapCatalog, "the whole map catalog does not publish during one source-scan update")

  local updates = 1
  while state._locationListCaches["location:root"] == nil do
    state:update(0)
    updates = updates + 1
    Assert.isTrue(
      updateWork[#updateWork] <= 256,
      "source scan, catalog build, and list indexing share one update budget"
    )
    Assert.isTrue(updates < 100, "bounded catalog preparation eventually publishes the root list")
  end
  Assert.isTrue(updates > 1, "a full hierarchy is never acquired and indexed in one update")
  Assert.equal(state:_mapProjection().count, 1, "the root publishes its complete source group after preparation")
  Assert.equal(
    state._locationListCaches["location:root"].rows[1].maps[600].mapId,
    600,
    "all maps remain available after publication"
  )
end

function T.tests.map_filter_charges_each_group_child_label_to_its_budget()
  local controller = Controller.new()
  local maps = {}
  for index = 1, 2000 do
    maps[index] = { displayName = string.format("Test map %04d", index) }
  end
  local state = stateHarness({
    controller = controller,
    _locationListCaches = {},
    _listFilterTask = nil,
    _listQueryRevision = 0,
  })
  local listId = "location:group:1"
  state:_beginListFilter(listId, "not-found", {
    {
      kind = "group",
      targetId = "location:group:1",
      displayName = "Test section",
      maps = maps,
    },
  }, nil)

  local visited = state:_advanceListFilter(256)
  Assert.equal(visited, 256, "every group and child-label check consumes one unit of the bounded work budget")
  Assert.equal(state._listFilterTask.cursor, 1, "the group remains unpublished while child labels are pending")
  Assert.equal(state._listFilterTask.groupMapCursor, 256, "the child cursor records exactly the labels already checked")
  Assert.isNil(state._locationListCaches[listId], "an incomplete child scan never publishes a partial group projection")

  while state._listFilterTask ~= nil do
    state:_advanceListFilter(256)
  end
  Assert.equal(#state._locationListCaches[listId].rows, 0, "the group is excluded after all child labels fail to match")
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
  Assert.isTrue(fresh.targets[nextRow].focusable, "the revealed row joins published navigation")
  Assert.notNil(fresh.targets[nextRow], "the revealed row materializes its target")
  Assert.isTrue((controller.scrollOffsets.flags or 0) > 0, "the viewport offset advances to reveal the focused row")
end

function T.tests.horizontal_list_navigation_does_not_page_or_wrap_rows()
  local harness = progressListHarness(progressFlagCatalog(40))
  local controller, state = harness.controller, harness.state
  harness.sync()
  local rows = harness.current.layout.lists.flags.rowTargets
  controller:setFocus(rows[1])
  state:_consumeUiInput({ { type = "navigate", direction = "right" } })
  harness.sync()
  local fresh = harness.current.layout
  Assert.equal(controller.focus, rows[1], "Right does not page a list's logical rows")
  Assert.isTrue(fresh.targets[controller.focus].focusable, "the focused row remains a valid control")
  Assert.notNil(fresh.targets[controller.focus], "the focused row remains materialized")
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
  Assert.isTrue(
    harness.current.layout.targets[controller.focus].focusable,
    "the reconciled focus joins published navigation"
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

function T.tests.filtering_away_the_focused_row_uses_the_nearest_surviving_index()
  local harness = progressListHarness(progressFlagCatalog(30))
  local controller, state = harness.controller, harness.state
  harness.sync()
  local list = harness.current.layout.lists.flags
  controller:setFocus(list.rowTargets[20])
  state:_filterFocusedList(list, 20, "append", "test_flag_0")
  harness.sync()
  local fresh = harness.current.layout.lists.flags
  Assert.equal(#fresh.rowTargets, 9, "the filter keeps the first nine rows")
  Assert.equal(controller.focus, fresh.rowTargets[9], "a deleted row falls back to the nearest surviving logical index")
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
  Assert.isNil(layout.targets[rows[#rows]], "the last logical row has no target at the top offset")
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
  controller.scopeId = "scope:one"
  controller:setFocus("money")
  Assert.equal(controller.focusByScope["scope:one"], "money", "scope memory records current focus identity")
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
  local modalStack = ModalStack.new()
  if options.modal then
    local kind = options.modal == "party-move" and "move" or options.modal == "remove" and "bag-remove" or options.modal
    modalStack:push({
      id = "test:" .. kind,
      kind = kind,
      payload = {},
      opener = { controlId = controller.focus, regionId = controller.scopeId, scrollAnchor = 0 },
    })
  end
  if options.valueEditor then
    local kind = options.valueEditor:snapshot().kind
    modalStack:push({
      id = "test:value",
      kind = kind,
      payload = {},
      opener = { controlId = controller.focus, regionId = controller.scopeId, scrollAnchor = 0 },
    })
  end
  local session = {
    dirty = options.dirty == true,
    snapshotRevision = 0,
    revision = function(self)
      return self.snapshotRevision
    end,
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
      self.snapshotRevision = self.snapshotRevision + 1
      return true
    end,
    discard = function(self)
      self.globalDiscards = self.globalDiscards + 1
      self.snapshotRevision = self.snapshotRevision + 1
      return true
    end,
  }
  local results = {}
  local state = stateHarness({
    status = "ready",
    disposed = false,
    approvedExit = false,
    controller = controller,
    modalStack = modalStack,
    modalLayerSequence = 0,
    session = session,
    valueEditor = options.valueEditor,
    monDraft = options.monDraft,
    locationService = options.locationService,
    fieldInput = FieldInput.new(),
    scopeEpoch = 0,
    locationServiceMapId = options.locationServiceMapId,
    locationViewport = options.locationViewport,
    errorMessage = nil,
    pendingDraftAction = nil,
    onResult = function(result)
      results[#results + 1] = result
    end,
  })
  return { controller = controller, session = session, state = state, results = results }
end

function T.tests.every_section_button_activates_its_section_directly()
  local harness = backHarness({ section = "Player" })
  for _, name in ipairs({ "Location", "Player", "Party", "Bag", "Progress" }) do
    harness.state:_dispatchActivationAction({ kind = "section.select", section = name })
    Assert.equal(harness.controller.section, name, "the " .. name .. " button enters its section")
  end
end

function T.tests.back_cancels_only_the_open_value_editor()
  local canceled = 0
  local editor = {
    snapshot = function()
      return { kind = "number" }
    end,
    dispose = function() end,
    result = function()
      return { kind = "cancel" }
    end,
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

function T.tests.too_small_number_layout_blocks_submission_and_recovers_without_losing_the_draft()
  local controller = Controller.new()
  local editor = ValueEditor.new({ kind = "integer", value = 123, min = 0, max = 0xFFFFFFFF, base = "decimal" })
  local layout = { numberTooSmall = true, targets = { cancel = { focusable = true } } }
  local finishResults = {}
  local state = stateHarness({
    status = "ready",
    controller = controller,
    modalStack = ModalStack.new(),
    valueEditor = editor,
    valuePurpose = "money",
    inputTick = 0,
    presentation = { cancelPointers = function() end },
    _snapshot = function()
      return { valueEditor = editor:snapshot() }
    end,
    _resolve = function()
      return { content = { layout = layout } }
    end,
    _reconcileFocus = function()
      return layout
    end,
    _syncScope = function() end,
    _finishValueEditor = function()
      finishResults[#finishResults + 1] = editor:result()
    end,
  })

  state:_consumeUiInput({ { type = "confirm" } })
  state:keypressed("return")
  state:keypressed("kpenter")
  state:gamepadpressed(nil, "a")
  state:keypressed("backspace")
  state:keypressed("delete")
  state:textinput("9")
  state:_dispatchActivationAction({ kind = "value.adjust-number-place", place = 0, direction = "up" })
  Assert.isNil(editor:result(), "hidden Confirm and direct submit inputs cannot commit the number")
  Assert.equal(
    editor:snapshot().buffer,
    "123",
    "hidden keyboard, text, and arrow actions cannot mutate the numeric draft"
  )
  Assert.equal(#finishResults, 0, "blocked submission leaves the value editor open")

  state.numberHold = { targetId = "number:place:0:up" }
  state.numberPressTarget = "number:place:0:up"
  state:resize(800, 600)
  layout = { targets = { confirm = { focusable = true }, cancel = { focusable = true } } }
  Assert.equal(state.valueEditor, editor, "a larger layout keeps the same draft editor alive")
  Assert.isNil(state.numberHold, "resizing clears a held arrow from the old geometry")
  Assert.isNil(state.numberPressTarget, "resizing clears a pressed arrow from the old geometry")
  Assert.isFalse(layout.numberTooSmall == true, "the resized presentation returns to its normal mode")
  Assert.equal(editor:snapshot().buffer, "123", "resize preserves the unmodified draft")

  layout = { numberTooSmall = true, targets = { cancel = { focusable = true } } }
  state:keypressed("escape")
  Assert.equal(editor:result().kind, "cancel", "Escape remains available in the too-small state")
  Assert.equal(#finishResults, 1, "the cancel path closes the editor exactly once")
end

function T.tests.zero_area_number_editor_has_no_focus_and_only_back_events_cancel()
  local state, editor = numberInputHarness(256, 10)
  local layout = state:_resolve(state:_snapshot()).content.layout
  Assert.isTrue(layout.numberTooSmall, "zero drawable content enters numeric fallback mode")
  editor:selectPlace(1)

  local inputsOk, inputFailure = pcall(function()
    state:keypressed("tab")
    state:keypressed("up")
    state:keypressed("down")
    state:keypressed("return")
    state:gamepadpressed(nil, "dpup")
    state:gamepadpressed(nil, "a")
  end)
  Assert.isTrue(
    inputsOk,
    "focus movement and hidden confirmation are safe without drawable controls: " .. tostring(inputFailure)
  )
  Assert.equal(state.valueEditor, editor, "focus movement and hidden confirmation leave the number editor open")
  Assert.equal(editor:snapshot().buffer, "123", "hidden input cannot change the numeric draft")
  Assert.isNil(layout.targets.cancel, "zero-area cancellation has no hit target")
  Assert.equal(#layout.focusNavigation.controls, 0, "zero-area cancellation has no focusable control")
  Assert.isNil(layout.defaultFocus, "zero-area cancellation has no synthetic focus target")

  state:resize(800, 600)
  local resized = state:_reconcileFocus()
  Assert.isFalse(resized.numberTooSmall, "resize restores the normal numeric editor")
  Assert.equal(state.controller.focus, "number:place:1:up", "resize reconciles focus to the selected visible digit")
  Assert.equal(editor:snapshot().selectedPlace, 1, "resize preserves the selected numeric place")
  Assert.equal(editor:snapshot().buffer, "123", "resize preserves the draft")

  for _, cancelInput in ipairs({ "escape", "gamepad-b" }) do
    local cancelState, cancelEditor = numberInputHarness(256, 10)
    local cancel = cancelEditor.cancel
    local canceled = false
    cancelEditor.cancel = function(self)
      canceled = cancel(self)
      return canceled
    end
    if cancelInput == "escape" then
      cancelState:keypressed("escape")
    else
      cancelState:gamepadpressed(nil, "b")
    end
    Assert.isTrue(canceled, cancelInput .. " produces an explicit cancellation")
    Assert.isNil(cancelState.valueEditor, cancelInput .. " retires the numeric layer")
  end
end

function T.tests.visible_numeric_fallback_back_activates_by_keyboard_gamepad_and_pointer()
  local function stateWithFallback()
    local state, editor = numberInputHarness(256, 128)
    local layout = state:_resolve(state:_snapshot()).content.layout
    Assert.isTrue(layout.numberTooSmall, "insufficient content publishes the numeric fallback")
    local back = assert(layout.targets.cancel, "positive fallback content publishes a real Back target").rect
    Assert.isTrue(back.width > 0 and back.height > 0, "the fallback Back target has drawable geometry")
    state:_reconcileFocus()
    Assert.equal(
      state.controller.focus,
      "cancel",
      "the visible fallback Back target is focusable; actual focus=" .. tostring(state.controller.focus)
    )
    return state, editor, back
  end

  local keyboard, keyboardEditor = stateWithFallback()
  for _, key in ipairs({ "up", "down", "left", "right", "backspace", "delete" }) do
    keyboard:keypressed(key)
  end
  keyboard:textinput("9")
  Assert.equal(keyboardEditor:snapshot().buffer, "123", "numeric mutation keys are ignored in fallback mode")
  keyboard:keypressed("return")
  local keyboardClosed = keyboard.valueEditor == nil
  Assert.equal(keyboard.session.money, 123, "Back does not publish a numeric change")

  local keypad = stateWithFallback()
  keypad:keypressed("kpenter")
  Assert.isNil(keypad.valueEditor, "keypad Enter activates the focused Back target")

  local gamepad = stateWithFallback()
  gamepad:gamepadpressed(nil, "a")
  local gamepadClosed = gamepad.valueEditor == nil
  Assert.equal(gamepad.session.money, 123, "gamepad Back does not publish a numeric change")

  local pointer, _, back = stateWithFallback()
  local x, y = back.x + math.floor(back.width / 2), back.y + math.floor(back.height / 2)
  pointer:_pointer({
    { type = "pointer_down", pointerId = "touch:back", targetId = "cancel", x = x, y = y },
    { type = "pointer_up", pointerId = "touch:back", targetId = "cancel", x = x, y = y },
  })
  Assert.equal(pointer.session.money, 123, "pointer Back does not publish a numeric change")
  Assert.isTrue(keyboardClosed, "Return activates the visible Back target")
  Assert.isTrue(gamepadClosed, "gamepad A activates the visible Back target")
  Assert.isNil(pointer.valueEditor, "pointer activation uses the same visible Back target")
end

function T.tests.numeric_modal_keyboard_focus_reaches_confirm_and_hardware_back_focuses_cancel()
  local keyboard, keyboardEditor = numberInputHarness(256, 192)
  keyboard.valuePurpose = "money"
  keyboard.session.setMoney = function(self, value)
    self.money = value
    return { ok = true }
  end
  local keyboardLayout = keyboard:_reconcileFocus()
  Assert.notNil(keyboardLayout.targets.confirm, "the authored numeric modal exposes Confirm")
  Assert.notNil(keyboardLayout.targets.cancel, "the authored numeric modal exposes Back")
  keyboard.controller:setFocus("number:place:0:up")
  keyboard:keypressed("up")
  keyboard:keypressed("right")
  Assert.equal(keyboard.controller.focus, "confirm", "Right from the units digit reaches Confirm")
  keyboard:keypressed("return")
  Assert.isNil(keyboard.valueEditor, "Enter activates the focused Confirm action")
  Assert.equal(keyboard.session.money, 124, "Enter commits the explicitly adjusted numeric value")
  Assert.isNil(keyboardEditor:result(), "a completed modal retires its editor result")
end

function T.tests.gamepad_back_from_numeric_digits_focuses_back_before_canceling()
  local gamepad, gamepadEditor = numberInputHarness(256, 192)
  gamepad:_reconcileFocus()
  gamepad.controller:setFocus("number:place:0:up")
  gamepad:gamepadpressed(nil, "b")
  Assert.equal(gamepad.valueEditor, gamepadEditor, "hardware Back first leaves the number editor open")
  Assert.equal(gamepad.controller.focus, "cancel", "hardware Back moves focus to the visible Back action")
  gamepad:gamepadreleased(nil, "b")
  gamepad:gamepadpressed(nil, "b")
  Assert.isNil(gamepad.valueEditor, "Back on the focused Back action cancels the editor")
  Assert.isNil(gamepadEditor:result(), "a canceled modal retires its editor result")
end

function T.tests.gamepad_confirms_and_pointer_back_cancels_native_numeric_actions()
  local gamepad, confirmedEditor = numberInputHarness(256, 192)
  gamepad.valuePurpose = "money"
  gamepad.session.setMoney = function(self, value)
    self.money = value
    return { ok = true }
  end
  gamepad:_reconcileFocus()
  gamepad.controller:setFocus("number:place:0:up")
  gamepad:gamepadpressed(nil, "dpup")
  gamepad:gamepadreleased(nil, "dpup")
  gamepad:gamepadpressed(nil, "dpright")
  Assert.equal(gamepad.controller.focus, "confirm", "the gamepad D-pad reaches Confirm from the units place")
  gamepad:gamepadreleased(nil, "dpright")
  gamepad:gamepadpressed(nil, "a")
  Assert.equal(gamepad.session.money, 124, "gamepad A commits the explicitly adjusted numeric value")
  Assert.isNil(confirmedEditor:result(), "a completed modal retires its editor result")
end

function T.tests.pointer_back_cancels_the_native_numeric_footer()
  local pointer, canceledEditor = numberInputHarness(256, 192)
  local layout = pointer:_resolve(pointer:_snapshot()).content.layout
  local back = assert(layout.targets.cancel, "the native numeric footer publishes Back").rect
  local x, y = back.x + math.floor(back.width / 2), back.y + math.floor(back.height / 2)
  pointer:_pointer({
    { type = "pointer_down", pointerId = "touch:native-back", targetId = "cancel", x = x, y = y },
    { type = "pointer_up", pointerId = "touch:native-back", targetId = "cancel", x = x, y = y },
  })
  Assert.isNil(pointer.valueEditor, "pointer Back cancels from the native footer")
  Assert.isNil(canceledEditor:result(), "a canceled modal retires its editor result")
end

function T.tests.numeric_arrow_recovers_invalid_typed_input_without_publishing_early()
  local state, editor = numberInputHarness(256, 192)
  state.controller:setFocus("number:place:0:up")
  Assert.isTrue(editor:textinput("9999999"), "out-of-range text remains editable")
  state:keypressed("up")
  Assert.equal(editor:snapshot().parsedValue, 124, "the arrow starts from the last valid number")
  Assert.isNil(editor:result(), "arrow recovery remains a draft until explicit Confirm")
end

function T.tests.back_closes_only_the_open_decision()
  local harness = backHarness({ section = "Player", dirty = true, modal = "remove" })
  harness.state:_requestBack()
  Assert.isNil(harness.controller.modal, "the decision layer is gone")
  Assert.isNil(harness.state.closeRequest, "the dirty session never enters its leave flow")
  Assert.deepEqual(harness.results, {}, "one Back never leaves the editor")
end

function T.tests.leave_save_keeps_invalid_value_editable_and_discard_remains_explicit()
  local invalid = ValueEditor.new({ kind = "integer", value = 12, min = 0, max = 99, base = "decimal" })
  Assert.isTrue(invalid:textinput("bad"), "invalid text remains in the editor buffer")
  local harness = backHarness({ section = "Player", dirty = true, valueEditor = invalid })
  harness.state:requestClose("back")
  harness.state:_performClose("save")
  Assert.equal(harness.controller.modal, "leave", "a rejected Save keeps the leave prompt open")
  Assert.equal(harness.state.valueEditor, invalid, "a rejected Save preserves the unfinished editor")
  Assert.equal(invalid:snapshot().buffer, "bad", "a rejected Save preserves the exact invalid buffer")
  Assert.notNil(harness.state.errorMessage, "the failure remains visible for correction")
  Assert.deepEqual(harness.results, {}, "a rejected Save cannot leave the editor")

  harness.state:_dispatchIntent({ kind = "cancel", modal = "leave" })
  Assert.isNil(harness.controller.modal, "cancel returns from the leave prompt")
  Assert.equal(harness.state.valueEditor, invalid, "cancel returns to the same unfinished editor")
  Assert.equal(invalid:snapshot().buffer, "bad", "cancel preserves the invalid text for correction")

  local discard = ValueEditor.new({ kind = "integer", value = 12, min = 0, max = 99, base = "decimal" })
  local discarded = backHarness({ section = "Player", dirty = true, valueEditor = discard })
  discarded.state:requestClose("back")
  discarded.state:_performClose("discard")
  Assert.equal(discarded.session.globalDiscards, 1, "explicit Discard uses the session-wide discard operation")
  Assert.isNil(discarded.state.valueEditor, "explicit Discard retires the unfinished editor")
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
  local state = stateHarness({
    status = "ready",
    disposed = false,
    approvedExit = false,
    controller = controller,
    modalStack = ModalStack.new(),
    modalLayerSequence = 0,
    session = session,
    dependencies = {
      context = fixture.context,
      bagManifest = {
        interactive = {
          overlays = {
            quantity = {
              visuals = {
                decrement = {
                  normal = { image = "bag/dec-normal" },
                  pressed = { image = "bag/dec-pressed" },
                },
                increment = {
                  normal = { image = "bag/inc-normal" },
                  pressed = { image = "bag/inc-pressed" },
                },
              },
            },
          },
        },
      },
    },
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
    scopeEpoch = 0,
    inputTick = 0,
    numberPressUntilTick = 0,
    fieldInput = {
      beginUi = function() end,
    },
    errorMessage = nil,
    dateProvider = function()
      return { year = 2000, month = 1, day = 1 }
    end,
    onResult = function() end,
  })
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

function T.tests.confirming_party_level_editor_updates_exp_and_derived_hp_through_the_draft()
  local Experience = require("libs.mons.src.gen4.Experience")
  local harness = livePartyHarness(1)
  harness.state:_ensurePartyDraft()
  local draft = assert(harness.state.monDraft)
  local before = draft:record()
  local curve = harness.state.dependencies.context.monCatalog:growthCurve(
    harness.state.dependencies.context.monCatalog:species(before.species).growthCurve
  )

  activate(harness.state, "party:field:level")
  local editor = assert(harness.state.valueEditor)
  Assert.equal(editor:snapshot().maximum, 100, "the real Party Level descriptor owns the numeric range")
  Assert.isTrue(editor:press("up"), "the opened Level editor accepts a numeric adjustment")
  local nextLevel = editor:snapshot().parsedValue
  Assert.isTrue(editor:press("confirm"), "the adjusted level confirms")
  harness.state:_finishValueEditor()

  Assert.equal(draft:record().experience, Experience.expFor(curve, nextLevel), "State applies the canonical EXP threshold")
  Assert.equal(draft:projection().level, nextLevel, "the projection publishes the newly derived level")
  Assert.notNil(draft:projection().stats.hp, "the derived HP projection refreshes with the level")
  Assert.equal(
    harness.session:partySnapshot().members[1].mon.experience,
    before.experience,
    "the confirmed editor updates the draft without prematurely persisting it"
  )

  local previousExperience = draft:record().experience
  activate(harness.state, "party:field:level")
  local canceled = assert(harness.state.valueEditor)
  Assert.isTrue(canceled:cancel(), "the reopened Level editor can be canceled")
  harness.state:_finishValueEditor()
  Assert.equal(draft:record().experience, previousExperience, "cancel leaves the draft record unchanged")
end

function T.tests.switching_members_applies_a_valid_dirty_draft()
  local harness = livePartyHarness(2)
  harness.state:_ensurePartyDraft()
  Assert.isTrue(harness.state.monDraft:setScalar("friendship", 200))
  activate(harness.state, "party:slot:1")
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
  activate(harness.state, "party:slot:1")
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
  activate(harness.state, "party:page:next")
  Assert.equal(harness.controller.partyTab, "Moves", "next advances Stats to Moves")
  Assert.equal(harness.state.monDraft, draft, "paging never recreates the draft")
  activate(harness.state, "party:page:next")
  Assert.equal(harness.controller.partyTab, "Details", "next advances Moves to Details")
  activate(harness.state, "party:page:next")
  Assert.equal(harness.controller.partyTab, "Stats", "next wraps Details to Stats")
  activate(harness.state, "party:page:previous")
  Assert.equal(harness.controller.partyTab, "Details", "previous wraps Stats to Details")
  activate(harness.state, "party:page:previous")
  Assert.equal(harness.controller.partyTab, "Moves", "previous returns to Moves")
  activate(harness.state, "party:page:previous")
  Assert.equal(harness.controller.partyTab, "Stats", "previous returns to Stats")
  Assert.equal(harness.controller.partySlot0, 0, "page wrapping keeps the selected member")
  Assert.equal(harness.state.monDraft, draft, "page wrapping keeps the same draft object")
  Assert.equal(harness.session:partyRevision(), revision, "paging never publishes the draft")
  Assert.isTrue(harness.state.monDraft:isDirty(), "the dirty draft survives paging")
end

function T.tests.section_switch_applies_the_open_draft()
  local harness = livePartyHarness(1)
  harness.state:_ensurePartyDraft()
  Assert.isTrue(harness.state.monDraft:setScalar("friendship", 77))
  activate(harness.state, "section:Player")
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
  activate(harness.state, "party:slot:0")
  Assert.equal(#harness.session:partySnapshot().members, 6, "the member switch applies the provisional add")
  Assert.equal(harness.controller.partySlot0, 0, "selection follows the requested member")
  Assert.equal(harness.state.monDraft:mode(), "edit", "the new member context owns a fresh edit draft")
  Assert.isNil(harness.state.errorMessage)
end

function T.tests.move_slot_opens_a_three_action_overlay_returning_from_its_children()
  local harness = livePartyHarness(1)
  harness.state:_ensurePartyDraft()
  activate(harness.state, "party:page:next")
  Assert.equal(harness.controller.partyTab, "Moves")
  activate(harness.state, "party:move:0")
  Assert.equal(harness.controller.modal, "party-move", "an occupied slot opens its move overlay")
  Assert.equal(harness.state.pendingMoveSlot, 0)
  activate(harness.state, "party-move:pp-ups")
  Assert.notNil(harness.state.valueEditor, "the component opens a child editor")
  Assert.isNil(harness.controller.modal, "the child editor sits above the suspended overlay")
  Assert.isTrue(harness.state.valueEditor:press("confirm"), "the unchanged value confirms")
  harness.state:_finishValueEditor()
  Assert.isNil(harness.state.valueEditor, "the child editor retires")
  Assert.equal(harness.controller.modal, "party-move", "a finished child returns to its parent overlay")
  activate(harness.state, "cancel")
  Assert.isNil(harness.controller.modal, "Back pops the parent overlay")
  Assert.equal(harness.controller.partyTab, "Moves", "Back lands on the Moves page")
  Assert.isNil(harness.state.closeRequest, "popping the overlay never enters the leave flow")
end

function T.tests.move_child_survives_leave_cancel_and_restores_its_opener()
  local harness = livePartyHarness(1)
  harness.state:_ensurePartyDraft()
  activate(harness.state, "party:page:next")
  activate(harness.state, "party:move:0")
  activate(harness.state, "party-move:pp")

  local editor = assert(harness.state.valueEditor)
  local originalBuffer = editor:snapshot().buffer
  harness.state:requestClose("quit")
  Assert.equal(harness.controller.modal, "leave", "quit confirmation becomes the top decision")
  Assert.equal(harness.state.valueEditor, editor, "the unfinished PP editor remains owned below the prompt")
  local nested = harness.state.modalStack:layers()
  Assert.deepEqual(
    { nested[1].kind, nested[2].kind, nested[3].kind },
    { "move", "number", "leave" },
    "the stack retains the move and PP layers below leave confirmation"
  )
  harness.state:_dispatchIntent({ kind = "cancel", modal = "leave" })
  Assert.isNil(harness.controller.modal, "cancel removes only the leave confirmation")
  Assert.equal(harness.state.valueEditor, editor, "cancel restores the same PP editor")
  Assert.equal(editor:snapshot().buffer, originalBuffer, "cancel preserves the exact editor buffer")
  Assert.equal(#harness.state.modalStack:layers(), 2, "cancel pops only the leave layer")

  harness.state:_requestBack()
  Assert.isNil(harness.state.valueEditor, "Back removes the PP editor")
  Assert.equal(harness.controller.modal, "party-move", "the retained move dialog becomes active again")
  Assert.equal(harness.controller.focus, "party-move:pp", "the child returns to the action that opened it")
  Assert.equal(harness.state.modalStack:top().kind, "move", "Back pops exactly the PP editor layer")
  harness.state:_requestBack()
  Assert.isNil(harness.controller.modal, "the next Back removes only the move dialog")
  Assert.equal(harness.controller.partyTab, "Moves", "the selected page survives both pops")
  Assert.equal(harness.controller.partySlot0, 0, "the selected member survives both pops")
end

function T.tests.nested_pp_editor_keeps_invalid_input_local_and_returns_to_its_move_layer()
  local harness = livePartyHarness(1)
  harness.state:_ensurePartyDraft()
  activate(harness.state, "party:page:next")
  activate(harness.state, "party:move:0")
  activate(harness.state, "party-move:pp")

  local editor = assert(harness.state.valueEditor)
  local before = harness.state.monDraft:record().moves[1]
  Assert.isTrue(editor:textinput("invalid"), "invalid typed text stays in the PP editor")
  activate(harness.state, "confirm")
  Assert.equal(harness.state.valueEditor, editor, "invalid text cannot pop or publish the numeric child")
  Assert.equal(editor:snapshot().buffer, "invalid", "rejected input remains available for correction")
  Assert.equal(harness.state.monDraft:record().moves[1].pp, before.pp, "invalid input leaves draft PP unchanged")

  harness.state.numberHold = {
    pointerId = "touch:held-pp-arrow",
    targetId = "number:place:0:up",
    delta = 1,
    scopeEpoch = harness.state.scopeEpoch,
    nextTick = 1,
  }
  harness.state:_requestBack()
  Assert.isNil(harness.state.valueEditor, "Back removes only the numeric child")
  Assert.equal(harness.controller.modal, "party-move", "the move overlay is restored")
  Assert.isNil(harness.state.numberHold, "popping the numeric layer clears its held arrow")
  Assert.equal(harness.state.monDraft:record().moves[1].pp, before.pp, "cancel leaves PP unchanged")
  Assert.equal(harness.state.monDraft:record().moves[1].ppUps, before.ppUps, "cancel preserves PP Ups")

  activate(harness.state, "party-move:pp")
  local validEditor = assert(harness.state.valueEditor)
  Assert.isTrue(validEditor:press("down"), "the reopened child accepts an arithmetic edit")
  Assert.isTrue(validEditor:press("confirm"), "a valid value can be confirmed")
  harness.state:_finishValueEditor()
  local after = harness.state.monDraft:record().moves[1]
  Assert.equal(after.pp, before.pp - 1, "one confirmation updates draft PP exactly once")
  Assert.equal(after.ppUps, before.ppUps, "editing PP preserves PP Ups")
  Assert.equal(after.move, before.move, "editing PP preserves the selected move")
  Assert.equal(harness.controller.modal, "party-move", "valid confirmation returns to the retained overlay")
  Assert.equal(harness.state.modalStack:top().kind, "move", "only the numeric layer is retired")
end

function T.tests.confirming_a_move_component_changes_only_the_party_draft()
  local harness = livePartyHarness(1)
  harness.state:_ensurePartyDraft()
  activate(harness.state, "party:page:next")
  activate(harness.state, "party:move:0")
  activate(harness.state, "party-move:pp")
  local before = harness.state.monDraft:record().moves[1].pp
  local editor = assert(harness.state.valueEditor)
  Assert.isTrue(editor:press("down"), "the PP editor accepts a local adjustment")
  Assert.isTrue(editor:press("confirm"), "the adjusted PP value confirms")
  harness.state:_finishValueEditor()

  Assert.equal(harness.state.monDraft:record().moves[1].pp, before - 1, "confirmation updates the open draft")
  Assert.equal(
    harness.session:partySnapshot().members[1].mon.moves[1].pp,
    before,
    "the editor session remains unchanged until the draft is explicitly applied"
  )
  Assert.equal(harness.controller.modal, "party-move", "confirmation returns to the retained move dialog")
  Assert.equal(harness.controller.focus, "party-move:pp", "confirmation restores the PP action")
  Assert.equal(harness.state.modalStack:top().kind, "move", "confirmation retires only the value layer")
end

function T.tests.modal_keeps_the_resized_party_page_painted_but_rejects_old_input()
  local harness = livePartyHarness(1)
  harness.state:_ensurePartyDraft()
  activate(harness.state, "party:page:next")
  harness.controller:pointer({ type = "pointer_down", pointerId = "touch:base", targetId = "party:move:0" })
  activate(harness.state, "party:move:0")

  local view = harness.state:_snapshot()
  local metrics = {
    lineHeight = 14,
    measure = function(text)
      return #text * 7
    end,
  }
  local compact = Layout.compute(view, 256, 192, metrics)
  local wide = Layout.compute(view, 640, 480, metrics)
  Assert.isTrue(
    type(wide.renderLayers) == "table" and #wide.renderLayers >= 2,
    "the Party page remains in the visual plan under the active decision"
  )
  Assert.notNil(wide.partyStrip, "the retained page keeps its member strip geometry")
  Assert.isNil(wide.targets["party:move:0"], "the retained base target is absent from active input")
  Assert.notNil(wide.targets["party-move:pp"], "the top decision retains its own active control")
  Assert.isTrue(
    compact.decisionList.surface.x ~= wide.decisionList.surface.x
      or compact.decisionList.surface.y ~= wide.decisionList.surface.y,
    "resizing recomputes the top dialog geometry"
  )
  Assert.isNil(
    harness.controller:pointer({
      type = "pointer_up",
      pointerId = "touch:base",
      targetId = "party:move:0",
    }),
    "a release captured by the base page cannot activate after a modal opens"
  )
  local selected = harness.controller.partySlot0
  activate(harness.state, "party:move:0")
  Assert.equal(harness.controller.partySlot0, selected, "a base activation cannot pass through the top modal")
end

function T.tests.member_removal_has_no_party_path()
  local harness = livePartyHarness(2)
  harness.state:_ensurePartyDraft()
  activate(harness.state, "party:remove")
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

function T.tests.back_from_coordinate_selection_returns_to_the_root_and_releases_grid_work()
  local releases = 0
  local service = {
    releaseGrid = function()
      releases = releases + 1
    end,
  }
  local harness = backHarness({ section = "Location", dirty = true, grid = true, locationService = service })
  Assert.equal(harness.controller.locationPage, "grid", "the harness starts inside coordinate selection")
  harness.state:_requestBack()
  Assert.equal(harness.controller.locationPage, "root", "one Back returns to the hierarchy root")
  Assert.equal(harness.controller.focus, "list:location:root", "one Back focuses the hierarchy root container")
  Assert.equal(releases, 1, "abandoned grid work is released exactly once")
  Assert.isNil(harness.state.closeRequest, "Back from an inner mode never enters the leave flow")
  Assert.deepEqual(harness.results, {}, "one Back never leaves the editor")
end

function T.tests.back_from_the_map_list_root_follows_the_normal_leave_path()
  local dirty = backHarness({ section = "Location", dirty = true, mapList = true })
  dirty.controller:setFocus("section:Location")
  Assert.equal(dirty.controller.locationPage, "root", "the harness starts at the hierarchy root")
  dirty.state:_requestBack()
  Assert.equal(dirty.controller.locationPage, "root", "root Back stays at the hierarchy root")
  Assert.notNil(dirty.state.closeRequest, "root Back with staged work enters the leave flow")
  Assert.deepEqual(dirty.results, {}, "entering the leave flow never leaves the editor")

  local clean = backHarness({ section = "Location", dirty = false, mapList = true })
  clean.controller:setFocus("section:Location")
  clean.state:_requestBack()
  Assert.deepEqual(clean.results, { { kind = "main_menu" } }, "root Back without work leaves the editor")
end

function T.tests.back_from_a_map_group_ascends_to_the_root_before_the_section()
  local harness = locationListHarness()
  local controller, state = harness.controller, harness.state
  state._requestBack = State._requestBack
  controller.locationMemory.root = { query = "route", cursor = "location:group:1", scroll = 2 }
  controller.query = "cave"
  controller.scrollOffset = 3
  controller.locationMapOffset = 3
  controller:setListCursor("location:group:1", "location:map:47")
  controller:setFocus("location:map:47")

  state:_requestBack()

  Assert.equal(controller.locationPage, "root", "Back from a group ascends to the root first")
  Assert.equal(controller.focus, "location:group:1", "root Back restores its remembered group cursor")
  Assert.equal(controller.query, "route", "root Back restores its filter")
  Assert.equal(controller.locationMapOffset, 2, "root Back restores its scroll offset")
  Assert.deepEqual(
    controller.locationMemory.groups["location:group:1"],
    { query = "cave", cursor = "location:map:47", scroll = 3 },
    "group Back remembers its filter, cursor, and scroll for re-entry"
  )
end

local function terminalInputHarness()
  local harness = backHarness({ section = "Location", dirty = false, mapList = true })
  local state = harness.state
  state.controller:setFocus("section:Location")
  local metrics = interactionMetrics()
  state.width, state.height = 800, 600
  state.generation = 0
  state.numberPressUntilTick = 0
  state._snapshot = function()
    return {
      section = "Location",
      status = "ready",
      ready = true,
      dirty = false,
      sectionDirty = false,
      scope = state.controller:snapshot().scope,
      query = "",
      scrollOffsets = state.controller.scrollOffsets,
      location = {
        mapModel = indexedMapModel({}),
        mapListId = "location:root",
        status = { state = "ready" },
        maps = {},
      },
      locationNavigation = state.controller:locationSnapshot(),
      modalLayers = {},
    }
  end
  state.presentation = {
    mapInput = function(_, events)
      return events
    end,
    dispose = function() end,
  }
  state.renderer = {
    metrics = function()
      return metrics
    end,
    dispose = function() end,
  }
  state._resolve = function(_, view)
    view.textMetrics = metrics
    local layout = Layout.compute(view, state.width, state.height, metrics)
    return { content = { layout = layout } }
  end
  local originalSyncScope = state._syncScope
  local postDisposeScopeSyncs = 0
  state._syncScope = function(self)
    if self.disposed then
      postDisposeScopeSyncs = postDisposeScopeSyncs + 1
    end
    return originalSyncScope(self)
  end
  state.onResult = function(result)
    harness.results[#harness.results + 1] = result
    state:dispose()
  end
  return harness, function()
    return postDisposeScopeSyncs
  end
end

function T.tests.terminal_escape_input_stops_before_post_disposal_focus_reconciliation()
  local harness, postDisposeScopeSyncs = terminalInputHarness()

  harness.state:keypressed("escape")

  Assert.deepEqual(harness.results, { { kind = "main_menu" } }, "Escape returns to the menu once")
  Assert.isTrue(harness.state.disposed, "the result callback disposes the editor synchronously")
  Assert.equal(postDisposeScopeSyncs(), 0, "terminal input skips scope synchronization after disposal")
  harness.state:dispose()
  Assert.equal(#harness.results, 1, "disposing again does not publish another result")
end

function T.tests.terminal_gamepad_cancel_stops_after_disposal()
  local gamepad, gamepadPostDisposeScopeSyncs = terminalInputHarness()
  gamepad.state:gamepadpressed(nil, "b")
  Assert.deepEqual(gamepad.results, { { kind = "main_menu" } }, "gamepad B returns to the menu once")
  Assert.equal(gamepadPostDisposeScopeSyncs(), 0, "gamepad cancel skips post-disposal scope work")
end

function T.tests.terminal_pointer_back_stops_after_disposal()
  local pointer, pointerPostDisposeScopeSyncs = terminalInputHarness()
  pointer.state:_pointer({
    { type = "pointer_down", pointerId = "touch:back", targetId = "back", x = 4, y = 4 },
    { type = "pointer_up", pointerId = "touch:back", targetId = "back", x = 4, y = 4 },
  })
  Assert.deepEqual(pointer.results, { { kind = "main_menu" } }, "pointer Back returns to the menu once")
  Assert.equal(pointerPostDisposeScopeSyncs(), 0, "pointer Back skips post-disposal scope work")
end

function T.tests.activating_the_staged_map_keeps_its_coordinates_while_other_maps_use_their_default()
  local controller = Controller.new()
  controller:setSection("Location")
  controller:enterLocation({ mapId = 12, fieldX = 40, fieldZ = 50 })
  controller:openLocationMaps()
  local state = stateHarness({
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
    fieldInput = FieldInput.new(),
    scopeEpoch = 0,
    session = {
      snapshot = function()
        return { location = { mapId = 12, fieldX = 40, fieldZ = 50 } }
      end,
    },
  })
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
  controller:setFocus("list:location:group:1")
  controller.query = "zzz-no-such-map"
  local layout = harness.buildLayout()
  local list = assert(layout.lists["location:group:1"], "the plan publishes the map list record")
  Assert.isTrue(list.empty, "zero filtered maps mark the list empty")
  state:_consumeUiInput({ { type = "confirm" } })
  Assert.equal(#harness.intents, 0, "Confirm on an empty map list selects nothing")
  Assert.equal(controller.focus, "list:location:group:1", "Confirm on an empty map list keeps container focus")
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
  harness.session.snapshot = function()
    return { dirtySections = { flags = true }, location = { mapId = 7, fieldX = 10, fieldZ = 12 } }
  end
  activate(harness.state, "discard")
  Assert.deepEqual(harness.session.discardedSections, { "Progress" }, "footer Discard resets its own section")
  Assert.equal(harness.session.globalDiscards, 0, "footer Discard never resets the whole session")
end

function T.tests.footer_discard_abandons_a_party_draft_with_its_section()
  local harness = livePartyHarness(2)
  Assert.isTrue(harness.session:save(false).ok, "the harness roster persists before staging edits")
  harness.state:_ensurePartyDraft()
  Assert.isTrue(harness.state.monDraft:setScalar("friendship", 199))
  Assert.isTrue(harness.session:setMoney(3100).ok, "money stages in another section")
  activate(harness.state, "discard")
  Assert.isTrue(harness.session:snapshot().dirtySections.money, "other sections stay staged")
  Assert.isFalse(harness.session:snapshot().dirtySections.party, "the Party baseline is restored without applying")
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
    revision = function()
      return 1
    end,
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
    modalStack = ModalStack.new(),
    modalLayerSequence = 0,
    session = session,
    dependencies = {
      cacheFs = {},
      context = { monCatalog = { move = function()
        return { name = "Move" }
      end } },
    },
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
    activeScopeId = "section:Player",
    scopeEpoch = 7,
    numberHold = {
      pointerId = "touch:hold",
      targetId = "number:place:0:up",
      delta = 1,
      scopeEpoch = 7,
      nextTick = 100,
    },
    numberPressUntilTick = 0,
    valueEditor = nil,
    valuePurpose = nil,
    pendingMoveSlot = 0,
    monDraft = nil,
    locationService = nil,
    iconStatus = nil,
    iconFailure = nil,
  }, State)
  controller.scopeId, controller.scopeEpoch = "section:Player", 7
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
    activeScopeId = "section:Player",
    activeScopeRevision = "section:Player",
    scopeEpoch = 3,
    numberHold = {
      pointerId = "touch:stale",
      targetId = "number:place:0:up",
      delta = 1,
      scopeEpoch = 3,
      nextTick = 100,
    },
    numberPressTarget = nil,
    _reconcileFocus = function()
      return {
        focusNavigation = {
          controls = {
            {
              id = "section:Bag",
              eligible = true,
              action = { kind = "section.select", section = "Bag" },
            },
          },
        },
      }
    end,
  }, State)
  controller.scopeId, controller.scopeEpoch = "section:Player", 3
  controller.focus = "section:Bag"

  state:_consumeUiInput({ { type = "confirm" } })
  Assert.equal(
    state.scopeEpoch,
    4,
    "the section transition settles its scope before later events act (got " .. tostring(state.scopeEpoch) .. ")"
  )
  Assert.equal(controller.scopeId, "section:Bag", "the settled scope names the entered section")
  Assert.equal(controller.scopeEpoch, 4, "the controller observes the settled epoch")
  Assert.isNil(state.numberHold, "the transition cancels the previous number hold")
  Assert.isNil(controller.capturedTarget, "the transition cancels the previous capture")
  Assert.isNil(controller.pointerId, "the transition releases the previous pointer")

  Assert.isNil(
    controller:pointer({ type = "pointer_up", pointerId = "touch:stale", targetId = "money", x = 4, y = 6 }),
    "a release from the retired press cannot activate its old target"
  )
  Assert.isNil(
    controller:pointer({
      type = "pointer_down",
      pointerId = "touch:fresh",
      targetId = "bag:pocket:items",
      x = 4,
      y = 6,
    }),
    "a fresh press only captures its target"
  )
  Assert.equal(controller.pointerId, "touch:fresh", "fresh navigation works after the transition")
  Assert.deepEqual(
    controller:pointer({ type = "pointer_up", pointerId = "touch:fresh", targetId = "bag:pocket:items", x = 4, y = 6 }),
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
      { id = "cancel", label = "Back", semantic = "back" },
    },
    ["party-move"] = {
      { id = "party-move:move", label = "Move", semantic = "secondary" },
      { id = "party-move:pp", label = "Current PP", semantic = "secondary" },
      { id = "party-move:pp-ups", label = "PP Ups", semantic = "secondary" },
      { id = "cancel", label = "Back", semantic = "back" },
    },
    ["remove"] = {
      { id = "remove", label = "Remove", semantic = "destructive" },
      { id = "cancel", label = "Back", semantic = "back" },
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
      Assert.equal(
        Layout.hitTest(layout, view, centerX, centerY),
        want.id,
        kind .. " action " .. want.id .. " hits its row"
      )
    end
  end
  local publisher, publisherIconPrep = observationHarness()
  for kind in pairs(expectations) do
    publisher.controller.modal = kind
    publisher.controller.focus = "cancel"
    if kind == "party-move" then
      publisher.pendingMoveSlot = 0
      publisher.monDraft = {
        mode = function()
          return "edit"
        end,
        isDirty = function()
          return false
        end,
        record = function()
          return { moves = { { move = "MOVE" } } }
        end,
      }
    end
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
    Layout.hitTest(decisionLayout, decisionView, enabledRow.rect.x + 1, enabledRow.rect.y + 1),
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
    local state = setmetatable({ controller = controller, valueEditor = nil }, State)
    state:_navigate(decisionLayout, direction)
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
  Assert.equal(firstCell.up[1], "bag:pocket:items", "the top row rises into its pocket tab")
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

local function stubPaintImage(name)
  return {
    __stubImage = name,
    getDimensions = function()
      return 64, 64
    end,
    getWidth = function()
      return 64
    end,
    getHeight = function()
      return 64
    end,
    setFilter = function() end,
    release = function() end,
  }
end

local function recordingPaintGraphics()
  local graphics = { ops = {}, depth = 0, lineWidth = 1, imagesMade = 0 }
  function graphics.setColor(red, green, blue, alpha)
    graphics.ops[#graphics.ops + 1] = { op = "color", red, green, blue, alpha }
  end
  function graphics.getColor()
    return 1, 1, 1, 1
  end
  function graphics.getLineWidth()
    return graphics.lineWidth
  end
  function graphics.setLineWidth(width)
    graphics.lineWidth = width
    graphics.ops[#graphics.ops + 1] = { op = "width", width }
  end
  function graphics.rectangle(mode, x, y, width, height)
    graphics.ops[#graphics.ops + 1] = { op = "rect", mode, x, y, width, height }
  end
  function graphics.line(...)
    graphics.ops[#graphics.ops + 1] = { op = "line" }
  end
  function graphics.draw(...)
    graphics.ops[#graphics.ops + 1] = { op = "image" }
  end
  function graphics.push()
    graphics.depth = graphics.depth + 1
    graphics.ops[#graphics.ops + 1] = { op = "push" }
  end
  function graphics.pop()
    graphics.depth = graphics.depth - 1
    graphics.ops[#graphics.ops + 1] = { op = "pop" }
  end
  function graphics.origin() end
  function graphics.intersectScissor(x, y, width, height)
    graphics.ops[#graphics.ops + 1] = { op = "scissor", x, y, width, height }
  end
  function graphics.translate(x, y)
    graphics.ops[#graphics.ops + 1] = { op = "translate", x, y }
  end
  function graphics.scale(x, y)
    graphics.ops[#graphics.ops + 1] = { op = "scale", x, y }
  end
  function graphics.transformPoint(x, y)
    return x, y
  end
  function graphics.newImage(_fileData)
    graphics.imagesMade = graphics.imagesMade + 1
    return stubPaintImage("prepared:" .. graphics.imagesMade)
  end
  return graphics
end

local function recordingPaintText(fail)
  local drawn = {}
  local text = { fontDef = { lineHeight = 14 } }
  function text.textWidth(_, value)
    return #tostring(value) * 7
  end
  function text.drawTextWithPalette(_, value, x, y, _palette)
    if fail ~= nil and fail.shouldFail(value) then
      error(fail.error, 0)
    end
    drawn[#drawn + 1] = { text = tostring(value), x = x, y = y }
  end
  return { object = text, drawn = drawn }
end

local function serializePaintOperand(value, seen)
  if type(value) == "number" then
    return string.format("%.4f", value)
  elseif type(value) == "string" then
    return string.format("%q", value)
  elseif type(value) == "boolean" then
    return tostring(value)
  elseif type(value) == "table" then
    if value.__stubImage ~= nil then
      return "<image:" .. tostring(value.__stubImage) .. ">"
    end
    if seen[value] then
      return "<cycle>"
    end
    seen[value] = true
    local keys = {}
    for key in pairs(value) do
      keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    local parts = {}
    for _, key in ipairs(keys) do
      parts[#parts + 1] = tostring(key) .. "=" .. serializePaintOperand(value[key], seen)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "<" .. type(value) .. ">"
end

local function serializePaintOps(ops)
  local lines = {}
  for _, entry in ipairs(ops) do
    lines[#lines + 1] = serializePaintOperand(entry, {})
  end
  return lines
end

local function layoutViewFor(view)
  if view.session ~= nil and view.session.frameIndex == nil then
    local copy = {}
    for key, value in pairs(view) do
      copy[key] = value
    end
    local session = {}
    for key, value in pairs(view.session) do
      session[key] = value
    end
    session.frameIndex = 0
    copy.session = session
    return copy
  end
  return view
end

local function paintPlanFor(view, width, height)
  local layout = Layout.compute(layoutViewFor(view), width, height, interactionMetrics())
  return {
    content = { layout = layout },
    panes = {
      {
        interactive = true,
        placement = {
          frame = { x = 0, y = 0, width = width, height = height },
          origin = { x = 0, y = 0 },
          clipRect = { x = 0, y = 0, width = width, height = height },
          scale = 1,
          logicalWidth = width,
          logicalHeight = height,
        },
      },
    },
  }
end

local function paintPlayerViewForPaint()
  return {
    section = "Player",
    status = "ready",
    ready = true,
    dirty = false,
    scope = { id = "section:Player", epoch = 0 },
    focus = "money",
    focusVisible = true,
    session = { playerName = "PLAYER", money = 3000 },
  }
end

local function paintPartyView()
  local selector = { slots = {} }
  selector.slots[1] = { kind = "member", slot0 = 0, label = "A", level = 9, active = true }
  selector.slots[2] = { kind = "member", slot0 = 1, label = "B", level = 5, active = false }
  selector.slots[3] = { kind = "add", slot0 = 2 }
  selector.slots[4] = { kind = "empty" }
  selector.slots[5] = { kind = "empty" }
  selector.slots[6] = { kind = "empty" }
  local statsRows = {}
  for _, pair in ipairs({
    { "hp", "HP" },
    { "attack", "Attack" },
  }) do
    statsRows[#statsRows + 1] = {
      key = pair[1],
      label = pair[2],
      iv = 1,
      ivEditor = { targetId = "party:field:iv:" .. pair[1], editor = { kind = "integer" } },
      ev = 2,
      evEditor = { targetId = "party:field:ev:" .. pair[1], editor = { kind = "integer" } },
    }
  end
  return {
    section = "Party",
    status = "ready",
    ready = true,
    dirty = false,
    scope = { id = "section:Party", epoch = 0 },
    focus = "party:slot:0",
    focusVisible = true,
    session = { playerName = "PLAYER", money = 3000 },
    partyTab = "Stats",
    partySlot0 = 0,
    bagQuantityVisuals = {
      decrement = { normal = { image = "dec/n" }, pressed = { image = "dec/p" } },
      increment = { normal = { image = "inc/n" }, pressed = { image = "inc/p" } },
    },
    partySelector = selector,
    partyStats = {
      header = {
        { id = "level", label = "Level", value = 9, targetId = "party:field:level", editor = { kind = "integer" } },
        { id = "status", label = "Status", value = "OK", targetId = "party:readonly:status" },
      },
      rows = statsRows,
    },
    partyMoves = {
      slots = {
        { kind = "move", slot0 = 0, label = "Tackle 35/35", targetId = "party:move:0" },
        { kind = "add", label = "+ Add", targetId = "party:move:add" },
        { kind = "empty" },
        { kind = "empty" },
      },
    },
  }
end

local function paintBagView()
  local view = scopedBagView()
  view.focus = "bag:item:POKE_BALL"
  view.focusVisible = true
  view.session = { playerName = "PLAYER", money = 3000 }
  view.bagPageRows[1] = { item = "POKE_BALL", label = "Poke Ball", quantity = 3, iconKey = "ball" }
  view.bagPocketStrip = { image = "strip/items" }
  view.bagQuantityVisuals = {
    decrement = { normal = { image = "dec/n" }, pressed = { image = "dec/p" } },
    increment = { normal = { image = "inc/n" }, pressed = { image = "inc/p" } },
  }
  return view
end

local function paintLocationView()
  return {
    section = "Location",
    status = "ready",
    ready = true,
    dirty = false,
    scope = { id = "section:Location", epoch = 0, kind = "section" },
    focus = "location:tile:32:48",
    focusVisible = true,
    session = { playerName = "P", money = 0 },
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
end

local function paintProgressView()
  local rows = { { name = "FLAG_A", displayName = "Flag A", id = 1, targetId = "flag:FLAG_A", value = false } }
  local rowTargets = { "flag:FLAG_A" }
  local indexByTarget = { ["flag:FLAG_A"] = 1 }
  return {
    section = "Progress",
    status = "ready",
    ready = true,
    dirty = false,
    scope = { id = "section:Progress", epoch = 0 },
    focus = "flag:FLAG_A",
    focusVisible = true,
    query = "",
    session = { playerName = "PLAYER", money = 3000 },
    flagRows = rows,
    flagRowTargets = rowTargets,
    flagIndexByTarget = indexByTarget,
    flagModel = {
      revision = 1,
      queryRevision = 0,
      pending = false,
      count = #rows,
      rowTargets = rowTargets,
      indexByTarget = indexByTarget,
      idAt = function(index)
        return rowTargets[index]
      end,
      indexOf = function(targetId)
        return indexByTarget[targetId]
      end,
      rowAt = function(index)
        return rows[index]
      end,
    },
    flagFilter = "Named",
    flagGroupLabel = "Named",
  }
end

local function paintNumberEditorView()
  return {
    section = "Player",
    status = "ready",
    ready = true,
    dirty = false,
    scope = { id = "value:number", epoch = 1, kind = "value" },
    focus = "confirm",
    focusVisible = true,
    session = { playerName = "PLAYER", money = 3000 },
    valueEditor = {
      kind = "number",
      parsedValue = 3,
      buffer = "3",
      digitCount = 1,
      digits = { "3" },
      selectedPlace = 0,
      valid = true,
    },
    numberControls = {
      { delta = 1, role = "increment", hitRect = { x = 0, y = 0, width = 24, height = 24 } },
      { delta = -1, role = "decrement", hitRect = { x = 0, y = 28, width = 24, height = 24 } },
    },
    numberControlVisuals = {
      increment = {
        normal = { image = "num/inc", width = 48, height = 48 },
        pressed = { image = "num/inc-pressed", width = 48, height = 48 },
      },
      decrement = {
        normal = { image = "num/dec", width = 48, height = 48 },
        pressed = { image = "num/dec-pressed", width = 48, height = 48 },
      },
    },
  }
end

local function paintChoiceEditorView()
  local options = {}
  for index = 1, 6 do
    options[index] = { key = string.format("K%02d", index), label = "Choice " .. index }
  end
  local editor = ValueEditor.new({ kind = "choice", value = "K01", options = options })
  local view = paintBagView()
  view.scope = { id = "value:choice", epoch = 1, kind = "value" }
  view.focus = "choice:K01"
  view.valueEditor = editor:snapshot()
  view.scrollOffsets = {}
  return view
end

local function paintNameEditorView()
  local grid = {}
  for row = 1, 6 do
    grid[row] = {}
    for column = 1, 13 do
      grid[row][column] = { glyph = "A" }
    end
  end
  return {
    section = "Player",
    status = "ready",
    ready = true,
    dirty = false,
    scope = { id = "value:name", epoch = 1, kind = "value" },
    focus = "confirm",
    focusVisible = true,
    session = { playerName = "PLAYER", money = 3000 },
    valueEditor = {
      kind = "name",
      naming = {
        text = "AB",
        cursor = { row = 1, column = 1 },
        grid = grid,
        controls = { { id = "lower", label = "abc", firstColumn = 1, lastColumn = 1 } },
      },
    },
    scrollOffsets = {},
  }
end

local function paintLeaveDecisionView()
  local view = paintLocationView()
  view.dirty = true
  view.modal = "leave"
  view.focus = "cancel"
  view.scope = { id = "decision:leave", epoch = 2, kind = "decision", focusId = "cancel" }
  view.decisionActions = {
    { id = "save", label = "Save", semantic = "primary", enabled = false, command = "save" },
    { id = "discard", label = "Discard", semantic = "destructive", enabled = true, command = "discard" },
    { id = "cancel", label = "Cancel", semantic = "secondary", enabled = true, command = "cancel" },
  }
  return view
end

local function drawPaintView(view, width, height, graphics, text, cacheReads)
  local renderer = Renderer.new({ text = text.object, graphics = graphics, versionId = "heartgold" })
  renderer._windowRenderer = { drawApplicationFrame = function() end, release = function() end }
  local plan = paintPlanFor(view, width, height)
  local cacheFs = {
    read = function(_, path)
      cacheReads[#cacheReads + 1] = path
      return "bytes"
    end,
  }
  local ItemIcons = require("libs.hgss.src.presentation.ItemIconAssetProvider")
  local providerNew = ItemIcons.new
  ItemIcons.new = function()
    return {
      image = function()
        return stubPaintImage("item")
      end,
      quadFor = function()
        return {}
      end,
      dimensions = function()
        return { width = 32, height = 32 }
      end,
      release = function() end,
    }
  end
  local ok, prepareError = pcall(function()
    renderer:prepareVisibleIcons(view, plan, cacheFs, {})
  end)
  ItemIcons.new = providerNew
  if not ok then
    renderer:dispose()
    error(prepareError, 0)
  end
  local readsBeforeDraw = #cacheReads
  local imagesBeforeDraw = graphics.imagesMade
  renderer:draw(view, plan)
  local drawReads = #cacheReads - readsBeforeDraw
  local drawImages = graphics.imagesMade - imagesBeforeDraw
  renderer:dispose()
  return { plan = plan, drawReads = drawReads, drawImages = drawImages }
end

local function drawnPaintText(text)
  local labels = {}
  for _, entry in ipairs(text.drawn) do
    labels[#labels + 1] = entry.text
  end
  return table.concat(labels, "\n")
end

function T.tests.every_section_and_overlay_paints_stable_draw_commands()
  local cases = {
    { name = "Player", view = paintPlayerViewForPaint() },
    { name = "Party", view = paintPartyView() },
    { name = "Bag", view = paintBagView() },
    { name = "Location", view = paintLocationView() },
    { name = "Progress", view = paintProgressView() },
    { name = "number editor", view = paintNumberEditorView() },
    { name = "choice editor", view = paintChoiceEditorView() },
    { name = "name editor", view = paintNameEditorView() },
    { name = "leave decision", view = paintLeaveDecisionView() },
  }
  local streams = {}
  for _, case in ipairs(cases) do
    local graphics = recordingPaintGraphics()
    local text = recordingPaintText()
    local cacheReads = {}
    local first = drawPaintView(case.view, 640, 480, graphics, text, cacheReads)
    Assert.equal(first.drawReads, 0, case.name .. " draws without reading retail bytes")
    Assert.equal(first.drawImages, 0, case.name .. " draws without decoding new images")
    local firstStream = serializePaintOps(graphics.ops)
    Assert.isTrue(#firstStream > 0, case.name .. " emits draw commands")
    local secondGraphics = recordingPaintGraphics()
    local secondText = recordingPaintText()
    drawPaintView(case.view, 640, 480, secondGraphics, secondText, {})
    Assert.deepEqual(
      serializePaintOps(secondGraphics.ops),
      firstStream,
      case.name .. " paints the same commands on repeated draws"
    )
    streams[case.name] = firstStream
  end
  Assert.isTrue(#streams.Player ~= #streams.Party, "Player and Party paint through distinct sections")
  Assert.isTrue(#streams.Bag ~= #streams.Location, "Bag and Location paint through distinct sections")
  local bagImages = 0
  for _, entry in ipairs(streams.Bag) do
    if entry:find("image", 1, true) then
      bagImages = bagImages + 1
    end
  end
  Assert.isTrue(bagImages > 0, "the Bag section paints its prepared pocket art")
  local locationLines = 0
  for _, entry in ipairs(streams.Location) do
    if entry:find("line", 1, true) then
      locationLines = locationLines + 1
    end
  end
  Assert.isTrue(locationLines > 0, "the Location section paints its grid tiles")
  local decisionGraphics = recordingPaintGraphics()
  local decisionText = recordingPaintText()
  drawPaintView(paintLeaveDecisionView(), 640, 480, decisionGraphics, decisionText, {})
  Assert.isTrue(
    drawnPaintText(decisionText):find("Save every section before leaving?", 1, true) ~= nil,
    "the leave decision paints its prompt"
  )
end

function T.tests.repeated_and_failing_draws_keep_observation_and_graphics_state_still()
  local view = paintPartyView()
  local graphics = recordingPaintGraphics()
  local text = recordingPaintText()
  local beforeView = serializePaintOperand(view, {})
  local first = drawPaintView(view, 640, 480, graphics, text, {})
  Assert.equal(first.drawReads, 0, "Party draws without reading retail bytes")
  Assert.equal(first.drawImages, 0, "Party draws without decoding new images")
  local firstStream = serializePaintOps(graphics.ops)
  Assert.equal(serializePaintOperand(view, {}), beforeView, "drawing never mutates the published view")
  Assert.equal(
    serializePaintOperand(first.plan.content.layout, {}),
    serializePaintOperand(paintPlanFor(view, 640, 480).content.layout, {}),
    "drawing never mutates the resolved layout"
  )
  local repeatGraphics = recordingPaintGraphics()
  drawPaintView(view, 640, 480, repeatGraphics, recordingPaintText(), {})
  Assert.deepEqual(serializePaintOps(repeatGraphics.ops), firstStream, "repeated draws emit identical commands")
  local failure = { message = "injected stats paint failure" }
  local failingText = recordingPaintText({
    error = failure,
    shouldFail = function(value)
      return value == "Level"
    end,
  })
  local failingGraphics = recordingPaintGraphics()
  local failingRenderer = Renderer.new({
    text = failingText.object,
    graphics = failingGraphics,
    versionId = "heartgold",
  })
  failingRenderer._windowRenderer = { drawApplicationFrame = function() end, release = function() end }
  for _, direction in ipairs({ "decrement", "increment" }) do
    for _, state in ipairs({ "normal", "pressed" }) do
      local imagePath = view.bagQuantityVisuals[direction][state].image
      failingRenderer._bagImages[imagePath] = { getDimensions = function() return 16, 16 end }
    end
  end
  local failingPlan = paintPlanFor(view, 640, 480)
  local depthBefore = failingGraphics.depth
  local ok, caught = pcall(function()
    failingRenderer:draw(view, failingPlan)
  end)
  failingRenderer:dispose()
  Assert.isFalse(ok, "a nested section failure propagates out of draw")
  Assert.isTrue(caught == failure, "draw retains the original section failure")
  Assert.isTrue(
    failingGraphics.depth == depthBefore + 1,
    "a failing draw unwinds every painter-owned scope and keeps only the host surface scope"
      .. " (depth "
      .. failingGraphics.depth
      .. ", base "
      .. depthBefore
      .. ")"
  )
  Assert.equal(serializePaintOperand(view, {}), beforeView, "a failing draw never mutates the published view")
  local recoveryGraphics = recordingPaintGraphics()
  drawPaintView(view, 640, 480, recoveryGraphics, recordingPaintText(), {})
  Assert.deepEqual(
    serializePaintOps(recoveryGraphics.ops),
    firstStream,
    "drawing recovers with identical commands after a failure"
  )
  Assert.equal(recoveryGraphics.depth, 0, "a successful draw balances every graphics scope")
end

function T.tests.snapshot_does_not_publish_or_mutate_the_active_scope()
  local controller = Controller.new()
  controller.capturedTarget = "money"
  controller.pointerId = "mouse:1"
  local fieldInput = { beginCount = 0 }
  function fieldInput:beginUi()
    self.beginCount = self.beginCount + 1
  end
  local state = setmetatable({
    status = "ready",
    versionId = "heartgold",
    saveId = "save",
    message = "",
    controller = controller,
    modalStack = ModalStack.new(),
    fieldInput = fieldInput,
    scopeEpoch = 0,
    activeScopeId = nil,
    activeScopeRevision = nil,
    inputTick = 0,
    numberHold = { targetId = "number:place:0:up" },
    numberPressTarget = "number:place:0:up",
    numberPressUntilTick = 10,
    session = nil,
    valueEditor = nil,
    locationService = nil,
    pendingLocationSave = nil,
  }, State)

  local first = state:_snapshot()
  local second = state:_snapshot()

  Assert.equal(first.scope.id, "section:Player", "snapshots describe the current focus scope")
  Assert.equal(second.scope.epoch, first.scope.epoch, "observing the scope does not publish a new epoch")
  Assert.equal(state.scopeEpoch, 0, "scope epochs change outside snapshot creation")
  Assert.equal(fieldInput.beginCount, 0, "snapshots never reset input ownership")
  Assert.equal(controller.capturedTarget, "money", "snapshots preserve an active pointer capture")
  Assert.equal(controller.pointerId, "mouse:1", "snapshots preserve the pointer owner")
  Assert.notNil(state.numberHold, "snapshots preserve active numeric holds")
  Assert.isNil(state.activeScopeId, "snapshots do not publish scope identity")

  controller:setSection("Bag")
  state:_syncScope()
  Assert.equal(state.activeScopeId, "section:Bag", "the state transition publishes its new scope")
  Assert.equal(state.scopeEpoch, 1, "a real scope transition advances the epoch")
  Assert.equal(fieldInput.beginCount, 1, "a real scope transition resets input ownership")
  Assert.isNil(controller.capturedTarget, "a real scope transition retires the old pointer capture")
  Assert.isNil(state.numberHold, "a real scope transition retires the old numeric hold")
end

function T.tests.typed_section_activation_dispatches_its_semantic_payload()
  local request
  local state = setmetatable({
    _requestDraftResolution = function(_, action)
      request = action
    end,
    _activate = function()
      error("typed action dispatch must not reparse a target ID")
    end,
  }, State)

  State._dispatchActivationAction(state, { kind = "section.select", section = "Party" })

  Assert.equal(request.kind, "section", "the typed action requests the section transition")
  Assert.equal(request.section, "Party", "the semantic section value reaches the transition owner")
end

function T.tests.active_control_activation_uses_its_published_semantic_action()
  local dispatched
  local action = { kind = "test.semantic-action", value = "published" }
  local layout = {
    focusNavigation = {
      controls = { { id = "section:Party", eligible = true, action = action } },
    },
  }
  local state = setmetatable({
    view = function()
      return { layout = layout }
    end,
    _dispatchActivationAction = function(_, value)
      dispatched = value
    end,
  }, State)

  State._activateControl(state, "section:Party", layout)

  Assert.equal(dispatched, action, "the entry point forwards the published semantic action")
end

function T.tests.typed_decision_action_uses_its_declared_decision_and_choice()
  local closed = false
  local state = setmetatable({
    _popDecision = function(_, decision)
      closed = decision == "party-move"
    end,
    _activate = function()
      error("typed decision dispatch must not reparse a control ID or inspect the current modal")
    end,
  }, State)

  State._dispatchActivationAction(state, { kind = "decision.cancel", decision = "party-move" })

  Assert.isTrue(closed, "the typed cancel action closes its decision")
end

function T.tests.stable_state_snapshots_reuse_the_session_revision_projection()
  local controller = Controller.new()
  local calls = 0
  local revision = 1
  local flags = { [1] = true }
  local session = {
    revision = function()
      return revision
    end,
    snapshot = function()
      calls = calls + 1
      return {
        playerName = "Trainer",
        money = 100,
        frameIndex = 0,
        flags = flags,
        dirtySections = { money = false, frame = false, flags = false },
      }
    end,
    isDirty = function(self)
      local dirty = self:snapshot().dirtySections
      return dirty.money or dirty.frame or dirty.flags or dirty.party or dirty.bag or dirty.location
    end,
  }
  local state = stateHarness({
    controller = controller,
    status = "ready",
    session = session,
    modalStack = ModalStack.new(),
    valueEditor = nil,
    inputTick = 0,
    numberPressUntilTick = 0,
    disposed = false,
  })

  local first = state:_snapshot()
  local second = state:_snapshot()
  Assert.equal(calls, 1, "stable State reads reuse their session projection")
  Assert.equal(second.session.flags[1], true, "stable reads preserve projected flags")
  Assert.isTrue(rawequal(first.session, second.session), "stable reads borrow the same State-owned projection")

  revision = revision + 1
  flags[1] = false
  local refreshed = state:_snapshot()
  Assert.equal(calls, 2, "a changed session revision refreshes the projection")
  Assert.equal(refreshed.session.flags[1], false, "the refreshed projection shows the changed flag")

  local sameRevisionReplacement = {
    revision = function()
      return revision
    end,
    snapshot = function()
      calls = calls + 1
      return {
        playerName = "Replacement",
        money = 200,
        frameIndex = 0,
        flags = {},
        dirtySections = { money = false, frame = false, flags = false },
      }
    end,
    isDirty = function(self)
      local dirty = self:snapshot().dirtySections
      return dirty.money or dirty.frame or dirty.flags or dirty.party or dirty.bag or dirty.location
    end,
  }
  state.session = sameRevisionReplacement
  Assert.equal(state:_snapshot().session.playerName, "Replacement", "a new Session identity refreshes equal revisions")
  Assert.equal(calls, 3, "identity replacement takes exactly one new snapshot")
end

function T.tests.failed_save_preserves_the_cached_dirty_projection_until_retry_succeeds()
  local Errors = require("libs.errors.src.Errors")
  local harness = livePartyHarness(0)
  local state = harness.state
  local session = harness.session
  local money = session:snapshot().money + 1
  Assert.isTrue(session:setMoney(money).ok, "the Session stages the edit")
  local before = state:_snapshot()
  Assert.isTrue(before.session.dirtySections.money, "the State publishes the staged dirty section")

  local save = session._saveStore.save
  session._saveStore.save = function()
    error(Errors.new("SAVE_CONFLICT", "The save changed before publication.", {}))
  end
  Assert.isFalse(state:_save(false), "a store failure rejects the Save")
  local failed = state:_snapshot()
  Assert.isTrue(rawequal(failed.session, before.session), "failure retains the cached projection")
  Assert.isTrue(failed.session.dirtySections.money, "failure keeps the staged money dirty")
  Assert.notNil(state.errorMessage, "the failure remains visible")

  session._saveStore.save = save
  Assert.isTrue(state:_save(false), "the same staged edit can be retried")
  local saved = state:_snapshot()
  Assert.isFalse(saved.session.dirtySections.money, "successful retry publishes a clean projection")
end

function T.tests.draw_consumes_the_settled_publication_without_resolving()
  local controller = Controller.new()
  controller:setSection("Player")
  local snapshots, resolves = 0, 0
  local plan = { content = { layout = { scopeId = "section:Player" } } }
  local state = stateHarness({
    status = "ready",
    controller = controller,
    modalStack = ModalStack.new(),
    fieldInput = FieldInput.new(),
    scopeEpoch = 0,
    inputTick = 0,
    session = nil,
    _snapshot = function()
      snapshots = snapshots + 1
      return { section = "Player", focus = controller.focus }
    end,
    _resolve = function()
      resolves = resolves + 1
      return plan
    end,
    renderer = { graphics = {}, text = {} },
  })
  local published = state:view()
  Assert.equal(snapshots, 1, "the synchronous observation publishes the pair once")
  Assert.equal(resolves, 1, "the synchronous observation resolves the plan once")
  snapshots, resolves = 0, 0
  local focusBefore = controller.focus
  local epochBefore = state.scopeEpoch
  local drawn = {}
  local originalDraw = ApplicationPresentation.draw
  ApplicationPresentation.draw = function(_, _, view, presentation)
    drawn[#drawn + 1] = { view = view, presentation = presentation }
  end
  local firstOk, firstError = pcall(function()
    state:draw()
  end)
  local secondOk, secondError = pcall(function()
    state:draw()
  end)
  ApplicationPresentation.draw = originalDraw
  Assert.isTrue(firstOk, "the first settled draw runs without platform rendering: " .. tostring(firstError))
  Assert.isTrue(secondOk, "the second settled draw runs without platform rendering: " .. tostring(secondError))
  Assert.equal(snapshots, 0, "settled draws never snapshot again")
  Assert.equal(resolves, 0, "settled draws never resolve again")
  Assert.equal(#drawn, 2, "both settled draws render")
  Assert.isTrue(drawn[1].view == published, "the first draw renders the settled view")
  Assert.isTrue(drawn[2].view == published, "the second draw renders the same settled view")
  Assert.isTrue(drawn[1].presentation == plan, "the first draw renders the settled plan")
  Assert.isTrue(drawn[2].presentation == plan, "the second draw renders the same settled plan")
  Assert.equal(controller.focus, focusBefore, "drawing never moves focus")
  Assert.equal(state.scopeEpoch, epochBefore, "drawing never advances the scope epoch")
  Assert.isNil(state.numberHold, "drawing never invents a held repeat")
end

function T.tests.retained_flag_and_bag_records_stay_detached_across_quantity_updates()
  local controller = Controller.new()
  controller:setSection("Progress")
  local catalog = {}
  for index = 1, 4 do
    local name = string.format("FLAG_TEST_%04d", index)
    catalog[index] = { name = name, displayName = name, id = index, targetId = "flag:" .. name }
  end
  local flagState = stateHarness({
    status = "ready",
    controller = controller,
    fieldInput = FieldInput.new(),
    inputTick = 0,
    scopeEpoch = 0,
    numberPressUntilTick = 0,
    preserveChoiceScroll = false,
    _flagCatalog = catalog,
  })
  local beforeFlags = flagState:_flagProjection({ [1] = true })
  local oldFlagRow = assert(beforeFlags.rowAt(1), "the retained projection materializes its row")
  Assert.isTrue(oldFlagRow.value, "the retained row reads the flag value at publication")
  local afterFlags = flagState:_flagProjection({ [1] = false })
  local newFlagRow = assert(afterFlags.rowAt(1), "the new projection materializes its row")
  Assert.isFalse(newFlagRow.value, "the new projection reads the toggled flag value")
  Assert.isTrue(oldFlagRow.value, "toggling a flag never mutates the retained row record")
  Assert.isTrue(oldFlagRow ~= newFlagRow, "each publication materializes a fresh row record")
  Assert.equal(afterFlags.idAt(1), beforeFlags.idAt(1), "toggling a flag keeps stable row identity")
  Assert.isTrue(rawequal(flagState._flagCatalog, catalog), "flag reads never reenumerate the catalog")

  local bagController = Controller.new()
  bagController:setSection("Bag")
  local itemCatalog = {}
  local bagMetadata = {
    catalog = itemCatalog,
    pockets = { { key = "items" } },
    pocketByKey = { items = { key = "items" } },
    optionsByPocket = { items = { { key = "POTION", label = "Potion" } } },
    itemByKey = { POTION = { item = "POTION", label = "Potion", iconKey = "potion" } },
  }
  local bagRevision = 1
  local bagQuantity = 5
  local bagManifest = {
    interactive = {
      pocketTabs = { rects = {}, strips = { items = {} } },
      focus = { tabs = { visual = {}, targets = {} } },
      overlays = { quantity = { visuals = {} } },
    },
  }
  local bagSession = {
    revision = function()
      return bagRevision
    end,
    bagSnapshot = function()
      return { { item = "POTION", quantity = bagQuantity } }
    end,
  }
  local bagState = stateHarness({
    status = "ready",
    controller = bagController,
    fieldInput = FieldInput.new(),
    inputTick = 0,
    scopeEpoch = 0,
    modalStack = ModalStack.new(),
    dependencies = { context = { itemCatalog = itemCatalog }, bagManifest = bagManifest },
    session = bagSession,
    _bagCatalogMetadata = bagMetadata,
  })
  local firstBag = bagState:_bagView()
  local oldPageRow = assert(firstBag.bagPageRows[1], "the retained bag page materializes its row")
  Assert.equal(oldPageRow.quantity, 5, "the retained page reads the quantity at publication")
  bagRevision = 2
  bagQuantity = 7
  local secondBag = bagState:_bagView()
  Assert.equal(secondBag.bagPageRows[1].quantity, 7, "the new page reads the changed quantity")
  Assert.equal(oldPageRow.quantity, 5, "changing a quantity never mutates the retained page row")
  Assert.isTrue(rawequal(bagState._bagCatalogMetadata, bagMetadata), "bag reads never reenumerate the catalog")
  Assert.isTrue(
    secondBag.bagRows[1] == firstBag.bagRows[1],
    "catalog metadata rows are shared while page rows stay detached"
  )
  bagRevision = 3
  bagSession.bagSnapshot = function()
    return { { item = "UNKNOWN", quantity = 1 } }
  end
  local unknownOk = pcall(function()
    bagState:_bagView()
  end)
  Assert.isFalse(unknownOk, "entries outside the item catalog fail instead of guessing")
end

return T
