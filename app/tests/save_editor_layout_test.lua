-- The Location section retains reachable navigation and shared logical geometry.

local Assert = require("tests.support.Assert")
local Controller = require("app.src.saveeditor.SaveEditorController")
local Layout = require("app.src.saveeditor.SaveEditorLayout")

local T = { tests = {} }
local function computeLayout(view, width, height)
  return Layout.compute(view, width, height, {
    lineHeight = 14,
    measure = function(text)
      return #text * 7
    end,
  })
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
      frameIndex = 0,
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
      maps = { { mapId = 12, symbol = "MAP_TEST_ROUTE", displayName = "TEST_ROUTE", section = "TEST_SECTION" } },
      generation = 1,
      status = { state = "ready" },
      tiles = {
        { fieldX = 32, fieldZ = 48, selectable = true },
        { fieldX = 33, fieldZ = 48, selectable = false, reason = "blocked" },
      },
      cursor = { fieldX = 33, fieldZ = 48 },
    },
    locationNavigation = {
      page = "grid",
      mapId = 12,
      cursor = { fieldX = 33, fieldZ = 48 },
      center = { fieldX = 32, fieldZ = 48 },
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
      naming = {
        cursor = { row = 1, column = 1 },
        controls = { { id = "lower", firstColumn = 1, lastColumn = 1 } },
      },
    }
    local layout = computeLayout(view, viewport.width, viewport.height)
    local cancel = assert(layout.targets.cancel)
    cancel = cancel.rect
    for row = 1, 6 do
      for column = 1, 13 do
        local key = assert(layout.targets[row .. ":" .. column])
        key = key.rect
        local overlaps = key.x < cancel.x + cancel.width
          and cancel.x < key.x + key.width
          and key.y < cancel.y + cancel.height
          and cancel.y < key.y + key.height
        Assert.isFalse(overlaps, "name key " .. row .. ":" .. column .. " must not overlap Cancel")
      end
    end
  end
end

function T.tests.location_layout_uses_fixed_scale_and_omits_zoom_targets()
  local controller = Controller.new()
  controller:setSection("Location")
  for _, viewport in ipairs({ { width = 256, height = 192 }, { width = 800, height = 600 } }) do
    local layout = computeLayout(locationView(), viewport.width, viewport.height)
    Assert.equal(layout.locationGrid.tileSize, 16, "Location uses one fixed 16-pixel tile scale")
    Assert.isNil(layout.targets["location:zoom-in"], "Location does not publish zoom-in")
    Assert.isNil(layout.targets["location:zoom-out"], "Location does not publish zoom-out")
  end
  local wideLayout = computeLayout(locationView(), 800, 600)
  Assert.notNil(wideLayout.targets["location:map:12"], "logical wide layout publishes its map list")
  Assert.notNil(wideLayout.viewports["location:map-list"], "logical wide layout owns map-list scrolling")
  Assert.notNil(wideLayout.locationGrid, "logical wide layout keeps the grid beside the map list")
end

function T.tests.player_rows_reserve_measured_raw_value_width_in_a_separate_text_cell()
  local view = {
    status = "ready",
    ready = true,
    section = "Player",
    scope = { id = "section:Player", epoch = 0 },
    session = { playerName = "PLAYER", money = 4294967295, frameIndex = 0 },
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
  Assert.equal(
    layout.focusedValueHelp,
    "Money: 4294967295",
    "the full value stays visible when the row must truncate it"
  )
end

function T.tests.shell_content_starts_at_the_application_margin_without_a_header_reservation()
  for _, size in ipairs({ { 256, 192 }, { 640, 480 } }) do
    local view = {
      status = "ready",
      ready = true,
      section = "Player",
      scope = { id = "section:Player", epoch = 0 },
      session = { playerName = "PLAYER", money = 3000, frameIndex = 0 },
    }
    local layout = computeLayout(view, size[1], size[2])
    Assert.isNil(layout.header, "the shell does not reserve header geometry")
    if size[1] < 400 then
      local strip = assert(
        layout.targets["section:Player"],
        "compact section navigation begins at the application margin"
      )
      Assert.isTrue(strip.rect.y <= 8, "compact section navigation begins at the application margin")
      Assert.isTrue(layout.content.y <= 34, "compact player content follows its section strip")
    else
      Assert.isTrue(layout.targets["section:Location"].rect.y <= 12, "wide section navigation begins at the top margin")
      Assert.isTrue(layout.content.y <= 16, "wide player content begins at the top margin")
    end
  end
end

function T.tests.action_control_geometry_fits_labels_with_padding_on_compact_and_wide_layouts()
  for _, size in ipairs({ { 256, 192 }, { 640, 480 } }) do
    local view = {
      status = "ready",
      ready = true,
      dirty = true,
      section = "Party",
      scope = { id = "section:Party", epoch = 0 },
      session = { playerName = "PLAYER", money = 3000, frameIndex = 0 },
      partyPage = "draft",
      partyValid = true,
      partySubpages = { "Identity", "Training", "Stats", "Moves", "Origin" },
      partyRows = {},
    }
    local metrics = {
      lineHeight = 14,
      measure = function(text)
        return #text * 7
      end,
    }
    local layout = Layout.compute(view, size[1], size[2], metrics)
    for _, action in ipairs(layout.actions) do
      local rect = assert(layout.targets[action.id]).rect
      Assert.isTrue(rect.height >= metrics.lineHeight + 16, action.label .. " has vertical text padding")
      Assert.isTrue(rect.width >= metrics.measure(action.label) + 16, action.label .. " has horizontal text padding")
    end
    for _, id in ipairs({ "party:apply", "party:discard", "party:cancel" }) do
      local row = assert(layout.targets[id], "draft action is visible: " .. id)
      Assert.isTrue(row.rect.height >= metrics.lineHeight + 16, id .. " has vertical text padding")
    end
  end
end

function T.tests.party_subpage_controls_remain_reachable_without_truncating_their_labels()
  local metrics = {
    lineHeight = 14,
    measure = function(text)
      return #text * 7
    end,
  }
  local view = {
    status = "ready",
    ready = true,
    section = "Party",
    scope = { id = "section:Party", epoch = 0 },
    partyPage = "detail",
    partySubpages = { "Identity", "Training", "Stats", "Moves", "Origin" },
  }

  for _, size in ipairs({ { 256, 192 }, { 720, 1280 } }) do
    local layout = Layout.compute(view, size[1], size[2], metrics)
    local tabs = {}
    for _, label in ipairs(view.partySubpages) do
      local id = "party:subpage:" .. label
      Assert.isTrue(layout.focusGraph[id] ~= nil, label .. " remains reachable by directional focus")
      if size[1] == 256 then
        view.focus = id
        layout = Layout.compute(view, size[1], size[2], metrics)
      end
      local tab = assert(layout.targets[id], label .. " is revealed as a complete control")
      Assert.isTrue(tab.rect.width >= metrics.measure(label) + 22, label .. " fits inside its shaded control")
      tabs[#tabs + 1] = tab.rect
    end
    if size[1] ~= 256 then
      for firstIndex, first in ipairs(tabs) do
        for laterIndex = firstIndex + 1, #tabs do
          local later = tabs[laterIndex]
          Assert.isTrue(
            first.y ~= later.y or first.x + first.width <= later.x or later.x + later.width <= first.x,
            "subpage controls do not overlap"
          )
        end
      end
    end
  end
end

local function filterMetrics()
  return {
    lineHeight = 14,
    measure = function(text)
      return #text * 7
    end,
  }
end

local function progressFilterFlags()
  return {
    { name = "GOT_POKEDEX", displayName = "Got Pokedex", value = true },
    { name = "BEAT_FALKNER", displayName = "Beat Falkner", value = true },
    { name = "MET_PROF_OAK", displayName = "Met Prof Oak", value = false },
    { name = "HAS_RUNNING_SHOES", displayName = "Has Running Shoes", value = false },
    { name = "VISITED_ECRUTEAK", displayName = "Visited Ecruteak", value = false },
    { name = "UNLOCKED_SAFARI", displayName = "Unlocked Safari", value = false },
  }
end

local function progressFilterView(flagRows, query)
  return {
    section = "Progress",
    status = "ready",
    ready = true,
    dirty = true,
    scope = { id = "section:Progress", epoch = 0, kind = "section", focusId = "money" },
    flagRows = flagRows,
    scrollOffsets = {},
    query = query or "",
  }
end

local function focusOrderContains(list, targetId)
  for _, focusId in ipairs(list) do
    if focusId == targetId then
      return true
    end
  end
  return false
end

local function focusOrderHasSearchControl(focusOrder, targets)
  for _, focusId in ipairs(focusOrder) do
    if focusId:find("search", 1, true) ~= nil then
      return true
    end
  end
  for targetId in pairs(targets) do
    if targetId:find("search", 1, true) ~= nil then
      return true
    end
  end
  return false
end

function T.tests.progress_list_publishes_one_container_with_ordered_filterable_rows()
  local flags = progressFilterFlags()
  local layout = computeLayout(progressFilterView(flags, ""), 256, 192)

  Assert.notNil(layout.lists, "the plan must publish one record per interactive list")
  local list = assert(layout.lists.flags, "the Progress flag list must publish its interaction record")
  Assert.equal(list.id, "flags")
  Assert.equal(list.targetId, "list:flags")
  Assert.equal(list.viewportId, "flags")
  Assert.isTrue(list.filterable, "the flag list accepts direct typing while focused")
  Assert.equal(list.query, "")
  Assert.isFalse(list.empty, "a populated flag list is not empty")
  local expectedRows = {}
  for _, flag in ipairs(flags) do
    expectedRows[#expectedRows + 1] = "flag:" .. flag.name
  end
  Assert.deepEqual(list.rowTargets, expectedRows)

  local container = assert(layout.targets["list:flags"], "the flag list owns one screen-level container target")
  Assert.isTrue(container.focusable, "the container remains focusable while rows scroll")
  Assert.isTrue(
    focusOrderContains(layout.focusOrder, "list:flags"),
    "the container belongs to the screen-level focus order"
  )
  for _, rowTarget in ipairs(expectedRows) do
    local row = assert(layout.targets[rowTarget], "row activation keeps its existing target: " .. rowTarget)
    Assert.isTrue(row.activationEnabled, "rows remain activatable: " .. rowTarget)
  end
  Assert.isFalse(
    focusOrderHasSearchControl(layout.focusOrder, layout.targets),
    "filtering needs no standalone search target"
  )

  local controller = Controller.new()
  controller:setSection("Progress")
  controller:setFocus("list:flags")
  local rowSet = {}
  for _, rowTarget in ipairs(expectedRows) do
    rowSet[rowTarget] = true
  end
  for _, direction in ipairs({ "up", "down", "left", "right" }) do
    controller:setFocus("list:flags")
    controller:moveFocus(layout.focusGraph, direction)
    Assert.isFalse(
      rowSet[controller.focus] == true,
      "directional input from the container never lands on a list row: " .. direction
    )
  end
  controller:setFocus("list:flags")
  controller:moveFocus(layout.focusGraph, "down")
  Assert.isTrue(
    controller.focus == "save" or controller.focus == "discard" or controller.focus == "back",
    "down from the flag container reaches a neighboring screen-level control, got " .. controller.focus
  )
end

local function mapListView()
  return {
    section = "Location",
    status = "ready",
    ready = true,
    dirty = false,
    scope = { id = "section:Location:map-list", epoch = 0, kind = "section", focusId = "location:grid" },
    query = "",
    session = {
      saveId = "layout-save",
      versionId = "heartgold",
      playerName = "PLAYER",
      money = 3000,
      frameIndex = 0,
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
      maps = {
        { mapId = 12, symbol = "MAP_TEST_ROUTE", displayName = "TEST_ROUTE", section = "TEST_SECTION" },
        { mapId = 34, symbol = "MAP_TEST_TOWN", displayName = "TEST_TOWN", section = "TEST_SECTION" },
        { mapId = 47, symbol = "MAP_TEST_CAVE", displayName = "TEST_CAVE", section = "TEST_OTHER" },
        { mapId = 7, symbol = "MAP_TEST_LAKE", displayName = "TEST_LAKE", section = "TEST_OTHER" },
      },
      generation = 1,
      status = { state = "ready" },
      tiles = {
        { fieldX = 32, fieldZ = 48, selectable = true },
      },
      cursor = { fieldX = 32, fieldZ = 48 },
    },
    locationNavigation = {
      page = "map-list",
      contentFocus = "map-list",
      mapId = 12,
      cursor = { fieldX = 32, fieldZ = 48 },
      center = { fieldX = 32, fieldZ = 48 },
      mapOffset = 0,
    },
  }
end

function T.tests.location_map_list_publishes_one_container_with_ordered_rows()
  local expectedRows = { "location:map:12", "location:map:34", "location:map:47", "location:map:7" }
  for _, size in ipairs({ { 800, 600 }, { 256, 192 } }) do
    local layout = computeLayout(mapListView(), size[1], size[2])
    local label = size[1] .. "x" .. size[2]
    Assert.notNil(layout.lists, "the plan must publish one record per interactive list (" .. label .. ")")
    local list = assert(
      layout.lists["location:map-list"],
      "the Location map list must publish its interaction record (" .. label .. ")"
    )
    Assert.equal(list.id, "location:map-list")
    Assert.equal(list.targetId, "list:location:map-list")
    Assert.equal(list.viewportId, "location:map-list")
    Assert.isTrue(list.filterable, "the map list accepts direct typing while focused (" .. label .. ")")
    Assert.deepEqual(list.rowTargets, expectedRows)
    Assert.isFalse(list.empty, "a populated map list is not empty (" .. label .. ")")
    Assert.notNil(
      layout.targets["list:location:map-list"],
      "the map list owns one screen-level container target (" .. label .. ")"
    )
    Assert.isTrue(
      focusOrderContains(layout.focusOrder, "list:location:map-list"),
      "the container belongs to the screen-level focus order (" .. label .. ")"
    )
    Assert.isFalse(
      focusOrderHasSearchControl(layout.focusOrder, layout.targets),
      "map filtering needs no standalone search target (" .. label .. ")"
    )
  end
end

function T.tests.offscreen_location_map_rows_remain_in_focus_order()
  local maps = {}
  for index = 1, 30 do
    maps[index] = {
      mapId = index,
      symbol = "MAP_TEST_" .. index,
      displayName = "TEST_" .. index,
      section = "TEST_SECTION",
    }
  end
  for _, size in ipairs({ { 800, 600 }, { 256, 192 } }) do
    local view = mapListView()
    view.location.maps = maps
    local layout = computeLayout(view, size[1], size[2])
    local label = size[1] .. "x" .. size[2]
    local list = assert(
      layout.lists["location:map-list"],
      "the Location map list must publish its interaction record (" .. label .. ")"
    )
    Assert.equal(#list.rowTargets, 30, "every map stays addressable (" .. label .. ")")
    local viewport = assert(layout.viewports["location:map-list"])
    Assert.isTrue(viewport.lastIndex < 30, "the map list must overflow its viewport (" .. label .. ")")
    for _, rowTarget in ipairs(list.rowTargets) do
      Assert.isTrue(
        focusOrderContains(layout.focusOrder, rowTarget),
        "offscreen map rows stay in focus order (" .. label .. ": " .. rowTarget .. ")"
      )
      Assert.notNil(
        layout.focusGraph[rowTarget],
        "offscreen map rows stay in the focus graph (" .. label .. ": " .. rowTarget .. ")"
      )
    end
  end
end

function T.tests.choice_list_publishes_one_container_with_ordered_rows()
  local options = {}
  for index = 1, 6 do
    options[index] = { key = string.format("K%02d", index), label = "Choice " .. index }
  end
  local view = {
    section = "Bag",
    status = "ready",
    ready = true,
    dirty = false,
    bagRows = {},
    valueEditor = { kind = "choice", options = options, selectedKey = "K01" },
    scope = { id = "value:choice", epoch = 1, kind = "value", focusId = "choice:K01" },
    scrollOffsets = {},
  }
  local layout = computeLayout(view, 256, 192)

  Assert.notNil(layout.lists, "the plan must publish one record per interactive list")
  local list = assert(layout.lists["value:choice"], "the choice editor must publish its interaction record")
  Assert.equal(list.id, "value:choice")
  Assert.equal(list.targetId, "list:value:choice")
  Assert.equal(list.viewportId, "value:choice")
  Assert.isTrue(list.filterable, "the choice list accepts direct typing while focused")
  Assert.isFalse(list.empty, "a populated choice list is not empty")
  local expectedRows = {}
  for _, option in ipairs(options) do
    expectedRows[#expectedRows + 1] = "choice:" .. option.key
  end
  Assert.deepEqual(list.rowTargets, expectedRows)
  Assert.notNil(layout.targets["list:value:choice"], "the choice list owns one screen-level container target")
  Assert.isTrue(
    focusOrderContains(layout.focusOrder, "list:value:choice"),
    "the container belongs to the screen-level focus order"
  )
  Assert.isNil(layout.targets["clear-search"], "choice filtering needs no visible Clear control")
  Assert.isFalse(
    focusOrderHasSearchControl(layout.focusOrder, layout.targets),
    "choice filtering needs no standalone search target"
  )

  local controller = Controller.new()
  controller:setFocus("list:value:choice")
  for _, direction in ipairs({ "up", "down", "left", "right" }) do
    controller:setFocus("list:value:choice")
    controller:moveFocus(layout.focusGraph, direction)
    Assert.isFalse(
      controller.focus:match("^choice:") ~= nil,
      "directional input from the container never lands on a choice row: " .. direction
    )
  end
end

function T.tests.modal_scope_omits_background_list_rows_and_containers()
  local view = progressFilterView(progressFilterFlags(), "")
  view.modal = "leave"
  view.scope = { id = "leave", epoch = 1, kind = "decision", focusId = "cancel" }
  local layout = computeLayout(view, 256, 192)
  for _, focusId in ipairs(layout.focusOrder) do
    Assert.isFalse(focusId:match("^flag:") ~= nil, "a modal scope never exposes a background flag row")
    Assert.isFalse(focusId:match("^list:") ~= nil, "a modal scope never exposes a background list container")
  end
  for targetId in pairs(layout.targets) do
    Assert.isFalse(targetId:match("^flag:") ~= nil, "a modal scope never targets a background flag row")
    Assert.isFalse(targetId:match("^list:") ~= nil, "a modal scope never targets a background list container")
  end
end

function T.tests.empty_filter_keeps_the_container_in_focus_order()
  local layout = computeLayout(progressFilterView({}, "zzz-no-such-flag"), 256, 192)
  Assert.notNil(layout.lists, "the plan must publish one record per interactive list")
  local list = assert(layout.lists.flags, "an empty flag list still publishes its interaction record")
  Assert.isTrue(list.empty, "zero filtered rows mark the list empty")
  Assert.equal(list.query, "zzz-no-such-flag")
  Assert.deepEqual(list.rowTargets, {})
  Assert.notNil(layout.targets["list:flags"], "the empty list keeps a focusable container")
  Assert.isTrue(
    focusOrderContains(layout.focusOrder, "list:flags"),
    "the empty container stays in the screen-level focus order"
  )
end

function T.tests.save_editor_list_and_card_geometry_is_bounded_and_row_major()
  local loadedList, List = pcall(require, "app.src.saveeditor.SaveEditorList")
  Assert.isTrue(loadedList, "the editor owns pure framed-list geometry")
  local loadedCard, Card = pcall(require, "app.src.saveeditor.SaveEditorCard")
  Assert.isTrue(loadedCard, "the editor owns pure card-grid geometry")

  for _, bounds in ipairs({
    { x = 0, y = 0, width = 256, height = 192 },
    { x = 0, y = 0, width = 800, height = 600 },
  }) do
    local list = List.resolve({
      bounds = bounds,
      rowCount = 12,
      rowHeight = 24,
      gap = 2,
      maxWidth = 480,
    })
    Assert.isTrue(list.surface.x >= bounds.x)
    Assert.isTrue(list.surface.x + list.surface.width <= bounds.x + bounds.width)
    Assert.equal(list.surface.width, math.min(bounds.width, 480), "the list width clamps to its maximum")
    Assert.equal(
      list.surface.x,
      bounds.x + (bounds.width - list.surface.width) / 2,
      "the list is horizontally centered"
    )
    Assert.isTrue(
      list.content.x >= list.surface.x and list.content.x + list.content.width <= list.surface.x + list.surface.width
    )
    Assert.isTrue(list.contentHeight >= 12 * 24)
    if list.contentHeight > list.content.height then
      Assert.isTrue(
        list.rows[#list.rows].rect.y + list.rows[#list.rows].rect.height > list.content.y + list.content.height,
        "the logical row geometry extends beyond the viewport for ScrollViewport clipping"
      )
    end
    Assert.equal(#list.rows, 12)
    for index, row in ipairs(list.rows) do
      Assert.equal(row.index, index)
      Assert.isTrue(row.hitRect.width > 0 and row.hitRect.height > 0)
      Assert.isTrue(row.rect.y >= list.content.y)
      if index > 1 then
        Assert.isTrue(row.rect.y >= list.rows[index - 1].rect.y + list.rows[index - 1].rect.height + 2)
      end
    end

    local cards = Card.resolveGrid({
      bounds = bounds,
      count = 6,
      columns = 2,
      rows = 3,
      gap = 12,
      maxWidth = 720,
    })
    Assert.equal(#cards, 6)
    local gridWidth = math.min(bounds.width, 720)
    Assert.equal(
      cards[1].rect.x,
      bounds.x + (bounds.width - gridWidth) / 2,
      "the card grid is centered within its maximum width"
    )
    for index, card in ipairs(cards) do
      Assert.equal(card.index, index)
      Assert.isTrue(card.rect.width > 0 and card.rect.height > 0)
      Assert.isTrue(card.hitRect.width > 0 and card.hitRect.height > 0)
      Assert.equal(card.hitRect.x, card.rect.x, "card pointer target spans the complete cell")
      Assert.equal(card.hitRect.width, card.rect.width, "card pointer target spans the complete cell")
      Assert.isTrue(card.iconRect.x < card.textRect.x, "card text follows its icon")
      Assert.isTrue(
        card.iconRect.x >= card.rect.x and card.iconRect.x + card.iconRect.width <= card.rect.x + card.rect.width
      )
      Assert.isTrue(
        card.textRect.x >= card.rect.x and card.textRect.x + card.textRect.width <= card.rect.x + card.rect.width
      )
      if index > 1 then
        local previous = cards[index - 1]
        if index % 2 == 0 then
          Assert.isTrue(card.rect.x >= previous.rect.x + previous.rect.width + 12)
        else
          Assert.isTrue(card.rect.y >= previous.rect.y + previous.rect.height + 12)
        end
      end
    end
  end

  Assert.throws(function()
    List.resolve({
      bounds = { x = 0, y = 0, width = 0, height = 192 },
      rowCount = 1,
      rowHeight = 24,
      gap = 0,
      maxWidth = 300,
    })
  end, "invalid list bounds fail loudly")
  Assert.throws(function()
    Card.resolveGrid({
      bounds = { x = 0, y = 0, width = 256, height = 192 },
      count = 7,
      columns = 2,
      rows = 3,
      gap = 8,
      maxWidth = 720,
    })
  end, "card count cannot exceed the six visible cells")
end

function T.tests.filterable_lists_reserve_a_hint_line_above_their_rows()
  local metrics = filterMetrics()
  local flags = progressFilterFlags()
  for _, query in ipairs({ "", "beat" }) do
    local layout = Layout.compute(progressFilterView(flags, query), 256, 192, metrics)
    local surface = assert(layout.listSurfaces[1], "the flag list owns one framed surface")
    local firstRow = assert(layout.targets["flag:" .. flags[1].name]).rect
    Assert.isTrue(
      firstRow.y - surface.y >= metrics.lineHeight,
      "flag rows begin below one hint line inside the surface (query=" .. query .. ")"
    )
    Assert.isTrue(
      layout.targets["list:flags"].rect.y <= surface.y + 2,
      "the list container still spans the complete surface"
    )
  end

  local options = {}
  for index = 1, 6 do
    options[index] = { key = string.format("K%02d", index), label = "Choice " .. index }
  end
  local choiceView = {
    section = "Bag",
    status = "ready",
    ready = true,
    dirty = false,
    bagRows = {},
    valueEditor = { kind = "choice", options = options, selectedKey = "K01" },
    scope = { id = "value:choice", epoch = 1, kind = "value", focusId = "choice:K01" },
    scrollOffsets = {},
  }
  local choiceLayout = Layout.compute(choiceView, 256, 192, metrics)
  local choiceSurface = assert(choiceLayout.listSurfaces[1], "the choice list owns one framed surface")
  local firstChoice = assert(choiceLayout.targets["choice:K01"]).rect
  Assert.isTrue(
    firstChoice.y - choiceSurface.y >= metrics.lineHeight,
    "choice rows begin below one hint line inside the surface"
  )

  for _, scoped in ipairs({
    computeLayout(progressFilterView(flags, ""), 256, 192),
    choiceLayout,
  }) do
    for targetId in pairs(scoped.targets) do
      Assert.isFalse(
        targetId:find("search", 1, true) ~= nil or targetId == "clear-search",
        "filtering needs no standalone search target: " .. targetId
      )
    end
    for _, focusId in ipairs(scoped.focusOrder) do
      Assert.isFalse(focusId:find("search", 1, true) ~= nil, "no search control enters focus order")
    end
  end
end

function T.tests.adjacent_action_controls_keep_a_minimum_gap_without_overlap()
  local metrics = filterMetrics()
  local draft = {
    section = "Party",
    status = "ready",
    ready = true,
    dirty = true,
    partyPage = "draft",
    partyDirty = true,
    partyValid = true,
    partySubpage = "Identity",
    partySubpages = { "Identity", "Training", "Stats", "Moves", "Origin" },
    partyRows = {},
  }
  for _, size in ipairs({ { 256, 192 }, { 800, 600 } }) do
    local layout = Layout.compute(draft, size[1], size[2], metrics)
    local apply = assert(layout.targets["party:apply"]).rect
    local discard = assert(layout.targets["party:discard"]).rect
    Assert.isTrue(
      discard.x - (apply.x + apply.width) >= 4,
      size[1] .. "px draft actions keep at least 4px between neighbors"
    )
    local rects = {}
    for _, target in pairs(layout.targets) do
      if target.rect ~= nil then
        rects[#rects + 1] = target.rect
      end
    end
    for left = 1, #rects do
      for right = left + 1, #rects do
        local a, b = rects[left], rects[right]
        local overlap = a.x < b.x + b.width
          and b.x < a.x + a.width
          and a.y < b.y + b.height
          and b.y < a.y + a.height
        Assert.isFalse(overlap, size[1] .. "px draft controls never overlap")
      end
    end
  end
end

function T.tests.wide_buttons_stay_bounded_and_action_groups_stay_centered()
  local metrics = filterMetrics()
  local draft = {
    section = "Party",
    status = "ready",
    ready = true,
    dirty = true,
    partyPage = "draft",
    partyDirty = true,
    partyValid = true,
    partySubpage = "Identity",
    partySubpages = { "Identity", "Training", "Stats", "Moves", "Origin" },
    partyRows = {},
  }
  local layout = Layout.compute(draft, 1280, 720, metrics)
  local left, right = nil, nil
  for _, id in ipairs({ "party:apply", "party:discard", "party:cancel" }) do
    local rect = assert(layout.targets[id]).rect
    Assert.isTrue(rect.width <= 128, id .. " never stretches with a large viewport")
    left = left == nil and rect.x or math.min(left, rect.x)
    right = right == nil and rect.x + rect.width or math.max(right, rect.x + rect.width)
  end
  Assert.isTrue(
    math.abs((left - layout.content.x) - (layout.content.x + layout.content.width - right)) < 2,
    "the bounded action group stays centered instead of stretching"
  )
end

function T.tests.section_rail_marks_the_active_option_without_using_focus()
  local view = {
    status = "ready",
    ready = true,
    dirty = false,
    section = "Player",
    focus = "money",
    scope = { id = "section:Player", epoch = 0, kind = "section" },
    session = { playerName = "PLAYER", money = 3000, frameIndex = 0 },
  }
  local layout = computeLayout(view, 640, 480)
  local byId = {}
  for _, item in ipairs(layout.navigation) do
    byId[item.targetId] = item
  end
  Assert.notNil(byId["section:Player"], "the wide layout keeps its section rail")
  Assert.equal(byId["section:Player"].active, true, "the current section is the active option")
  Assert.equal(byId["section:Party"].active, false, "other sections stay inactive while focused elsewhere")
  Assert.equal(byId["section:Bag"].active, false, "other sections stay inactive while focused elsewhere")
end

local SECTION_ORDER = { "Location", "Player", "Party", "Bag", "Progress" }

local function sectionStripView(section)
  return {
    status = "ready",
    ready = true,
    dirty = false,
    section = section,
    focus = "money",
    scope = { id = "section:" .. section, epoch = 0, kind = "section" },
    session = { playerName = "PLAYER", money = 3000, frameIndex = 0 },
  }
end

function T.tests.compact_layouts_offer_five_direct_section_controls_instead_of_a_cycler()
  for _, size in ipairs({ { 256, 192 }, { 360, 640 } }) do
    local label = size[1] .. "x" .. size[2]
    local layout = computeLayout(sectionStripView("Player"), size[1], size[2])
    Assert.isNil(layout.targets.section, "no section cycler remains (" .. label .. ")")
    local previousRight = nil
    for _, name in ipairs(SECTION_ORDER) do
      local targetId = "section:" .. name
      local target = assert(layout.targets[targetId], "the strip exposes " .. name .. " (" .. label .. ")")
      local stripRect = target.rect
      Assert.isTrue(stripRect.x >= 0 and stripRect.x + stripRect.width <= size[1], name .. " fits the width")
      if previousRight ~= nil then
        Assert.isTrue(stripRect.x >= previousRight, name .. " starts after its neighbor")
      end
      previousRight = stripRect.x + stripRect.width
      local inFocusOrder = false
      for _, focusId in ipairs(layout.focusOrder) do
        if focusId == targetId then
          inFocusOrder = true
          break
        end
      end
      Assert.isTrue(inFocusOrder, name .. " is keyboard/controller reachable")
    end
    local first = assert(layout.targets["section:Location"]).rect
    local last = assert(layout.targets["section:Progress"]).rect
    Assert.equal(first.y, last.y, "the five controls share one top strip")
    Assert.isTrue(
      layout.content.y >= first.y + first.height,
      "section content starts below the strip (" .. label .. ")"
    )
    local byId = {}
    for _, item in ipairs(layout.navigation) do
      byId[item.targetId] = item
    end
    Assert.equal(byId["section:Player"].active, true, "the current section stays the active option")
    Assert.equal(byId["section:Party"].active, false, "other sections stay inactive")
  end
end

function T.tests.wide_shell_is_centered_and_capped_with_footer_inside()  for _, width in ipairs({ 800, 1200 }) do
    local label = width .. "px"
    local layout = computeLayout(sectionStripView("Player"), width, 600)
    local shell = assert(layout.shell, "the wide layout publishes its centered shell (" .. label .. ")")
    Assert.isTrue(shell.width <= 640, "the shell never spans the window (" .. label .. ")")
    Assert.near(shell.x, (width - shell.width) / 2, 1.01, "the shell is horizontally centered")
    local rail = assert(layout.targets["section:Location"], "the wide layout keeps its side rail").rect
    Assert.isTrue(rail.x >= shell.x, "the rail lives inside the shell")
    Assert.isTrue(
      layout.content.x >= rail.x + rail.width,
      "content starts right of the rail (" .. label .. ")"
    )
    Assert.isTrue(
      layout.content.x + layout.content.width <= shell.x + shell.width + 1.01,
      "content stays inside the shell (" .. label .. ")"
    )
    Assert.isTrue(layout.footer.x >= shell.x - 1.01, "the footer aligns to the shell")
    Assert.isTrue(
      layout.footer.x + layout.footer.width <= shell.x + shell.width + 1.01,
      "the footer never stretches past the shell (" .. label .. ")"
    )
  end
end

local function backLabels(layout)
  local found = {}
  for _, item in ipairs(layout.navigation) do
    if item.label == "Back" or item.label == "Return" then
      found[#found + 1] = item.targetId
    end
  end
  for _, row in ipairs(layout.rows) do
    if row.label == "Back" or row.label == "Return" then
      found[#found + 1] = row.targetId
    end
  end
  for _, action in ipairs(layout.actions) do
    if action.label == "Back" or action.label == "Return" then
      found[#found + 1] = action.id
    end
  end
  if layout.decisionList ~= nil then
    for _, row in ipairs(layout.decisionList.rows) do
      if row.label == "Back" or row.label == "Return" then
        found[#found + 1] = row.targetId
      end
    end
  end
  return found
end

function T.tests.normal_scopes_expose_exactly_one_back_action()
  local scopes = {
    { name = "Player", view = sectionStripView("Player"), width = 256, height = 192 },
    { name = "Player wide", view = sectionStripView("Player"), width = 800, height = 600 },
    {
      name = "Progress",
      view = {
        status = "ready",
        ready = true,
        dirty = false,
        section = "Progress",
        scope = { id = "section:Progress", epoch = 0, kind = "section" },
        flagRows = {},
        scrollOffsets = {},
        query = "",
      },
      width = 256,
      height = 192,
    },
    {
      name = "Party list",
      view = {
        status = "ready",
        ready = true,
        dirty = false,
        section = "Party",
        scope = { id = "section:Party", epoch = 0, kind = "section" },
        partyPage = "list",
        partyCards = { { kind = "add", slot0 = 0, label = "+ Add" } },
        partyCanAdd = true,
      },
      width = 256,
      height = 192,
    },
    {
      name = "error",
      view = {
        status = "error",
        ready = false,
        dirty = false,
        section = "Player",
        scope = { id = "section:Player", epoch = 0, kind = "section" },
        message = "Could not open save",
        session = { playerName = "PLAYER", money = 3000, frameIndex = 0 },
      },
      width = 256,
      height = 192,
    },
  }
  for _, scope in ipairs(scopes) do
    local layout = computeLayout(scope.view, scope.width, scope.height)
    Assert.deepEqual(backLabels(layout), { "back" }, scope.name .. " keeps one footer Back and no copy")
  end
  local gridView = {
    status = "ready",
    ready = true,
    dirty = false,
    section = "Location",
    scope = { id = "section:Location", epoch = 0, kind = "section" },
    session = { playerName = "PLAYER", money = 3000, frameIndex = 0 },
    location = {
      mapId = 12,
      symbol = "MAP_TEST_ROUTE",
      section = "TEST_SECTION",
      maps = { { mapId = 12, symbol = "MAP_TEST_ROUTE", displayName = "TEST_ROUTE", section = "TEST_SECTION" } },
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
  local gridLayout = computeLayout(gridView, 256, 192)
  Assert.deepEqual(backLabels(gridLayout), { "back" }, "Location grid keeps one footer Back and no copy")
end

function T.tests.footer_discard_enables_only_for_the_active_section_changes()
  local view = sectionStripView("Player")
  view.ready, view.dirty = true, true
  view.sectionDirty = false
  local layout = computeLayout(view, 256, 192)
  for _, action in ipairs(layout.actions) do
    if action.id == "discard" then
      Assert.isFalse(action.enabled, "a clean section keeps footer Discard disabled")
    end
  end
  view.sectionDirty = true
  layout = computeLayout(view, 256, 192)
  for _, action in ipairs(layout.actions) do
    if action.id == "discard" then
      Assert.isTrue(action.enabled, "staged changes in the active section enable footer Discard")
    end
  end
  view.modal = "leave"
  view.scope = { id = "modal:leave", epoch = 1, kind = "decision", focusId = "cancel" }
  view.sectionDirty = false
  layout = computeLayout(view, 256, 192)
  for _, action in ipairs(layout.actions) do
    if action.id == "discard" then
      Assert.isTrue(action.enabled, "the global leave decision keeps Discard all enabled")
    end
  end
end

return T
