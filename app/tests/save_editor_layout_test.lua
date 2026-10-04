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
      Assert.isTrue(layout.targets.section.rect.y <= 8, "compact section navigation begins at the application margin")
      Assert.isTrue(layout.content.y <= 30, "compact player content follows its section control")
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

return T
