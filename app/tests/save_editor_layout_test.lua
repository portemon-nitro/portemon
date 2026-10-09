-- The Location section retains reachable navigation and shared logical geometry.

local Assert = require("tests.support.Assert")
local Controller = require("app.src.saveeditor.SaveEditorController")
local Layout = require("app.src.saveeditor.SaveEditorLayout")
local Interface = require("app.src.saveeditor.SaveEditorInterface")
local Navigation = require("app.src.saveeditor.SaveEditorNavigation")
local Renderer = require("app.src.saveeditor.SaveEditorRenderer")
local SaveEditorState = require("app.src.saveeditor.SaveEditorState")
local ValueEditor = require("app.src.saveeditor.SaveEditorValueEditor")
local ListSurface = require("libs.ui.src.ListSurface")
local ScrollViewport = require("libs.ui.src.ScrollViewport")

local T = { tests = {} }
local function computeLayout(view, width, height)
  if view.flagRows ~= nil and view.flagModel == nil then
    local rowTargets, indexByTarget = view.flagRowTargets, view.flagIndexByTarget
    view.flagModel = {
      revision = 1,
      queryRevision = 0,
      pending = false,
      count = #rowTargets,
      rowTargets = rowTargets,
      indexByTarget = indexByTarget,
      idAt = function(index)
        return rowTargets[index]
      end,
      indexOf = function(targetId)
        return indexByTarget[targetId]
      end,
      rowAt = function(index)
        return view.flagRowAt(index)
      end,
    }
  end
  if
    view.locationNavigation ~= nil
    and (view.locationNavigation.page == "root" or view.locationNavigation.page == "group")
    and view.location
    and view.location.maps ~= nil
    and view.location.mapModel == nil
  then
    local maps, rowTargets, indexByTarget =
      view.location.maps, view.location.mapRowTargets, view.location.mapIndexByTarget
    view.location.mapModel = {
      revision = 1,
      queryRevision = 0,
      pending = false,
      count = #rowTargets,
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
  if view.flagRows ~= nil and view.flagRowAt == nil then
    view.flagRowAt = function(index)
      return view.flagRows[index]
    end
  end
  return Layout.compute(view, width, height, {
    lineHeight = 14,
    measure = function(text)
      return #text * 7
    end,
  })
end

local function navigationFocus(layout, targetId)
  for _, control in ipairs(layout.focusNavigation.controls) do
    if control.id == targetId then
      return { scopeId = layout.scopeId, regionId = control.regionId, targetId = targetId }
    end
  end
  for _, region in ipairs(layout.focusNavigation.regions) do
    if region.logical and region.logical.indexOf and region.logical.indexOf(targetId) ~= nil then
      return { scopeId = layout.scopeId, regionId = region.id, targetId = targetId }
    end
  end
  return nil
end

local function navigate(controller, layout, direction)
  local snapshot = {
    scope = { id = layout.scopeId, epoch = layout.scopeEpoch },
    regions = layout.focusNavigation.regions,
    controls = layout.focusNavigation.controls,
    remembered = controller.listCursors,
  }
  local focus = Navigation.reconcile(snapshot, navigationFocus(layout, controller.focus) or {
    scopeId = layout.scopeId,
    regionId = "",
    targetId = controller.focus,
  }, { layout.defaultFocus })
  controller:setFocus(focus.targetId)
  local result = Navigation.resolve(snapshot, focus, direction)
  if result.kind == "move" then
    controller:setFocus(result.targetId)
  end
  return result
end

local function hasNavigationControl(layout, targetId)
  return navigationFocus(layout, targetId) ~= nil
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
      map = { mapId = 12, symbol = "MAP_TEST_ROUTE", section = "TEST_SECTION" },
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

function T.tests.numeric_dialog_uses_measured_content_and_publishes_only_a_bounded_cancel_target_when_unfit()
  local editor = ValueEditor.new({ kind = "integer", value = 123, min = 0, max = 0xFFFFFFFF, base = "decimal" })
  local view = locationView()
  view.section = "Player"
  view.valueEditor = editor:snapshot()
  view.numberControlVisuals = { increment = { normal = { width = 48, height = 48 } } }

  local layout = computeLayout(view, 256, 128)
  Assert.isTrue(layout.numberTooSmall, "the measured active content cannot fit the real numeric controls")
  Assert.isNil(layout.numberLayout, "unavailable geometry publishes no invisible numeric controls")
  Assert.isNil(layout.targets.confirm, "unavailable geometry has no submission target")
  Assert.equal(#layout.focusNavigation.controls, 1, "only the visible Cancel control remains focusable")
  local cancel = assert(layout.targets.cancel).rect
  Assert.isTrue(cancel.x >= 0 and cancel.y >= 0, "Cancel begins inside the logical surface")
  Assert.isTrue(cancel.x + cancel.width <= 256 and cancel.y + cancel.height <= 128, "Cancel stays inside the surface")
end

function T.tests.numeric_fallback_geometry_stays_inside_available_content()
  for _, viewport in ipairs({
    { width = 12, height = 128 },
    { width = 256, height = 16 },
    { width = 256, height = 10 },
  }) do
    local editor = ValueEditor.new({ kind = "integer", value = 123, min = 0, max = 0xFFFFFFFF, base = "decimal" })
    local view = locationView()
    view.section = "Player"
    view.valueEditor = editor:snapshot()
    view.numberControlVisuals = { increment = { normal = { width = 48, height = 48 } } }

    local layout = computeLayout(view, viewport.width, viewport.height)
    Assert.isTrue(layout.numberTooSmall, "small content publishes the numeric fallback")
    local margin = viewport.width <= 280 and 8 or 12
    local modalBottom = viewport.height <= 220 and viewport.height - (margin + 2) - 2
      or layout.content.y + layout.content.height
    local content = {
      x = layout.content.x,
      y = layout.content.y,
      width = layout.content.width,
      height = math.max(0, modalBottom - layout.content.y),
    }
    for name, target in pairs({
      cancel = layout.targets.cancel and layout.targets.cancel.rect,
      notice = layout.valueModalNotice,
    }) do
      if target ~= nil then
        Assert.isTrue(target.x >= content.x and target.y >= content.y, name .. " begins inside content")
        Assert.isTrue(
          target.x + target.width <= content.x + content.width
            and target.y + target.height <= content.y + content.height,
          name .. " ends inside content"
        )
      end
    end
    if content.width <= 0 or content.height <= 0 then
      Assert.isNil(layout.targets.cancel, "no positive fallback area has no synthetic Back target")
      Assert.isNil(layout.valueModalNotice, "no positive fallback area has no synthetic notice")
      Assert.equal(#layout.focusNavigation.controls, 0, "zero-area fallback publishes no focus controls")
      Assert.isNil(layout.defaultFocus, "zero-area fallback publishes no hidden default focus")
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
    Assert.isNil(
      layout.lists["location:group:1"],
      "coordinate selection never composes the map list (" .. viewport.width .. "x" .. viewport.height .. ")"
    )
    Assert.isNil(
      layout.targets["location:map-picker"],
      "coordinate selection has no picker control (" .. viewport.width .. "x" .. viewport.height .. ")"
    )
  end
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
      local strip =
        assert(layout.targets["section:Player"], "compact section navigation begins at the application margin")
      Assert.isTrue(strip.rect.y <= 8, "compact section navigation begins at the application margin")
      Assert.isTrue(layout.content.y <= 34, "compact player content follows its section strip")
    else
      Assert.isTrue(layout.targets["section:Location"].rect.y <= 12, "wide section navigation begins at the top margin")
      Assert.isTrue(layout.content.y <= 16, "wide player content begins at the top margin")
    end
  end
end

local function partyEditorView(tab, focus)
  local selector = { slots = {} }
  selector.slots[1] = { kind = "member", slot0 = 0, iconKey = "a", label = "A", level = 9, active = true }
  selector.slots[2] = { kind = "member", slot0 = 1, iconKey = "b", label = "B", level = 5, active = false }
  selector.slots[3] = { kind = "add", slot0 = 2 }
  selector.slots[4] = { kind = "empty" }
  selector.slots[5] = { kind = "empty" }
  selector.slots[6] = { kind = "empty" }
  local statsRows = {}
  for _, pair in ipairs({
    { "hp", "HP" },
    { "attack", "Attack" },
    { "defense", "Defense" },
    { "speed", "Speed" },
    { "specialAttack", "Sp. Atk" },
    { "specialDefense", "Sp. Def" },
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
    status = "ready",
    ready = true,
    section = "Party",
    scope = { id = "section:Party", epoch = 0 },
    focus = focus or "party:slot:0",
    partyTab = tab,
    partySlot0 = 0,
    partySelector = selector,
    partyStats = {
      header = {
        { id = "level", label = "Level", value = 9, targetId = "party:field:level", editor = { kind = "integer" } },
        {
          id = "experience",
          label = "Exp",
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
          value = "20/20",
          targetId = "party:field:currentHp",
          editor = { kind = "integer" },
        },
        { id = "status", label = "Status", value = "OK", targetId = "party:readonly:status" },
      },
      rows = statsRows,
    },
    partyMoves = {
      slots = {
        { kind = "move", slot0 = 0, label = "Tackle 35/35", targetId = "party:move:0" },
        { kind = "move", slot0 = 1, label = "Growl 40/40", targetId = "party:move:1" },
        { kind = "add", label = "+ Add", targetId = "party:move:add" },
        { kind = "empty" },
      },
    },
    partyDetails = {
      rows = {
        {
          role = "named choice",
          targetId = "party:field:species",
          id = "species",
          label = "Species",
          value = "A",
          editor = { kind = "choice" },
        },
        {
          role = "named choice",
          targetId = "party:field:ability",
          id = "ability",
          label = "Ability",
          value = "X",
          editor = { kind = "choice" },
        },
      },
    },
  }
end

function T.tests.action_control_geometry_fits_labels_with_padding_on_compact_and_wide_layouts()
  for _, size in ipairs({ { 256, 192 }, { 640, 480 } }) do
    local view = partyEditorView("Stats")
    view.session = { playerName = "PLAYER", money = 3000, frameIndex = 0 }
    view.dirty = true
    local metrics = {
      lineHeight = 14,
      measure = function(text)
        return #text * 7
      end,
    }
    local layout = Layout.compute(view, size[1], size[2], metrics)
    for _, action in ipairs(layout.actions) do
      local rect = assert(layout.targets[action.id]).rect
      Assert.isTrue(
        rect.height >= math.ceil(metrics.lineHeight * 0.75) + 8,
        action.label .. " has measured body-text padding"
      )
      Assert.isTrue(rect.width >= metrics.measure(action.label) + 16, action.label .. " has horizontal text padding")
    end
    Assert.isNil(layout.targets["party:apply"], "no Party-local Apply bar remains")
    Assert.isNil(layout.targets["party:discard"], "no Party-local Discard bar remains")
    Assert.isNil(layout.targets["party:cancel"], "no Party-local Return bar remains")
  end
end

local function partyEditorView(tab, focus)
  local selector = { slots = {} }
  selector.slots[1] = { kind = "member", slot0 = 0, iconKey = "a", label = "A", level = 9, active = true }
  selector.slots[2] = { kind = "member", slot0 = 1, iconKey = "b", label = "B", level = 5, active = false }
  selector.slots[3] = { kind = "add", slot0 = 2 }
  selector.slots[4] = { kind = "empty" }
  selector.slots[5] = { kind = "empty" }
  selector.slots[6] = { kind = "empty" }
  local statsRows = {}
  for _, pair in ipairs({
    { "hp", "HP" },
    { "attack", "Attack" },
    { "defense", "Defense" },
    { "speed", "Speed" },
    { "specialAttack", "Sp. Atk" },
    { "specialDefense", "Sp. Def" },
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
    status = "ready",
    ready = true,
    section = "Party",
    scope = { id = "section:Party", epoch = 0 },
    focus = focus or "party:slot:0",
    partyTab = tab,
    partySlot0 = 0,
    partySelector = selector,
    partyStats = {
      header = {
        { id = "level", label = "Level", value = 9, targetId = "party:field:level", editor = { kind = "integer" } },
        {
          id = "experience",
          label = "Exp",
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
          value = "20/20",
          targetId = "party:field:currentHp",
          editor = { kind = "integer" },
        },
        { id = "status", label = "Status", value = "OK", targetId = "party:readonly:status" },
      },
      rows = statsRows,
    },
    partyMoves = {
      slots = {
        { kind = "move", slot0 = 0, label = "Tackle 35/35", targetId = "party:move:0" },
        { kind = "move", slot0 = 1, label = "Growl 40/40", targetId = "party:move:1" },
        { kind = "add", label = "+ Add", targetId = "party:move:add" },
        { kind = "empty" },
      },
    },
    partyDetails = {
      rows = {
        {
          role = "named choice",
          targetId = "party:field:species",
          id = "species",
          label = "Species",
          value = "A",
          editor = { kind = "choice" },
        },
        {
          role = "named choice",
          targetId = "party:field:ability",
          id = "ability",
          label = "Ability",
          value = "X",
          editor = { kind = "choice" },
        },
      },
    },
  }
end

function T.tests.party_editor_publishes_a_strip_pager_and_exactly_three_pages()
  for _, size in ipairs({ { 256, 192 }, { 800, 600 } }) do
    for _, tab in ipairs({ "Stats", "Moves", "Details" }) do
      local layout = computeLayout(partyEditorView(tab), size[1], size[2])
      Assert.notNil(layout.targets["party:slot:0"], "the first member stays selectable")
      Assert.notNil(layout.targets["party:slot:1"], "the second member stays selectable")
      Assert.notNil(layout.targets["party:add"], "the first empty position offers + Add")
      Assert.isNil(layout.targets["party:slot:2"], "later empty positions stay non-focusable")
      Assert.notNil(layout.targets["party:page:previous"], "the pager offers previous")
      Assert.notNil(layout.targets["party:page:next"], "the pager offers next")
      Assert.notNil(layout.partyPageLabel, "the pager names its current page")
      Assert.equal(layout.partyPageLabel.text, tab, "the pager names " .. tab)
      Assert.notNil(layout.viewports.party, "the page body scrolls through its viewport")
      for _, targetId in ipairs({
        "party:subpage:Identity",
        "party:subpage:Training",
        "party:subpage:Stats",
        "party:subpage:Moves",
        "party:subpage:Origin",
        "party:edit",
        "party:remove",
        "party:back",
        "party:apply",
        "party:discard",
        "party:cancel",
        "party:move:remove:0",
        "party:clear-nickname",
      }) do
        Assert.isNil(layout.targets[targetId], "obsolete Party target is gone: " .. targetId)
        Assert.isFalse(hasNavigationControl(layout, targetId), "obsolete Party target leaves navigation: " .. targetId)
      end
    end
  end
  local statsLayout = computeLayout(partyEditorView("Stats"), 800, 600)
  Assert.notNil(statsLayout.targets["party:field:level"], "Stats exposes its level editor")
  Assert.notNil(statsLayout.targets["party:field:iv:attack"], "Stats exposes its IV editors")
  Assert.notNil(statsLayout.targets["party:field:ev:attack"], "Stats exposes its EV editors")
  Assert.notNil(statsLayout.partyStatsTable, "Stats keeps its IV/EV table")
  Assert.equal(#statsLayout.partyStatsTable.headers, 3, "the table has exactly Stat/IV/EV columns")
  Assert.equal(#statsLayout.partyStatsTable.rows, 6, "the table keeps one row per battle stat")
  Assert.isTrue(statsLayout.targets["party:page:previous"].activationEnabled, "Party Previous wraps from Stats")
  local movesLayout = computeLayout(partyEditorView("Moves", "party:move:0"), 800, 600)
  Assert.notNil(movesLayout.targets["party:move:0"], "occupied slots stay activatable")
  Assert.notNil(movesLayout.targets["party:move:1"], "every occupied slot stays activatable")
  Assert.notNil(movesLayout.targets["party:move:add"], "the first empty move slot offers + Add")
  Assert.isNil(movesLayout.targets["party:move:3"], "later empty move slots stay inert")
  Assert.equal(#movesLayout.partyMoves.slots, 4, "the Moves page spans four slots")
  local detailsLayout = computeLayout(partyEditorView("Details", "party:field:species"), 800, 600)
  Assert.notNil(detailsLayout.targets["party:field:species"], "Details exposes its fields")
  Assert.notNil(detailsLayout.targets["party:field:ability"], "Details exposes its ability choice")
  Assert.isTrue(detailsLayout.targets["party:page:next"].activationEnabled, "Party Next wraps from Details")
  local compactDetails = computeLayout(partyEditorView("Details", "party:field:species"), 256, 192)
  Assert.notNil(compactDetails.viewports.party, "compact Details keeps its scroll viewport")
  Assert.notNil(
    compactDetails.viewports.party.contentExtent > compactDetails.viewports.party.clip.height,
    "compact Details overflows and scrolls"
  )
end

function T.tests.live_stats_navigation_preserves_the_iv_ev_column()
  local controller = Controller.new()
  controller:setSection("Party")
  local view = partyEditorView("Stats")
  local layout = computeLayout(view, 800, 600)
  controller.scopeId, controller.scopeEpoch = layout.scopeId, layout.scopeEpoch
  controller:setFocus("party:field:iv:attack")
  local state = setmetatable({
    controller = controller,
    valueEditor = nil,
    _snapshot = function()
      return {}
    end,
    _setScrollOffset = function() end,
  }, SaveEditorState)

  SaveEditorState._navigate(state, layout, "down")

  Assert.equal(controller.focus, "party:field:iv:defense", "Down preserves the IV column in the live Stats table")
  SaveEditorState._navigate(state, layout, "right")
  Assert.equal(controller.focus, "party:field:ev:defense", "Right moves to the EV column in the live Stats table")
end

function T.tests.party_moves_use_a_two_by_two_grid_without_inventing_empty_slots()
  local view = partyEditorView("Moves")
  view.partyMoves.slots = {
    { kind = "move", slot0 = 0, label = "Tackle", targetId = "party:move:0" },
    { kind = "move", slot0 = 1, label = "Growl", targetId = "party:move:1" },
    { kind = "move", slot0 = 2, label = "Leer", targetId = "party:move:2" },
    { kind = "move", slot0 = 3, label = "Bite", targetId = "party:move:3" },
  }
  local layout = computeLayout(view, 640, 480)
  local slots = assert(layout.partyMoves).slots
  Assert.equal(#slots, 4, "the Moves page publishes exactly four physical slots")
  for index, targetId in ipairs({ "party:move:0", "party:move:1", "party:move:2", "party:move:3" }) do
    local slot = assert(slots[index])
    Assert.equal(slot.targetId, targetId, "row-major cells preserve semantic move identity")
    Assert.equal(
      Layout.hitTest(layout, view, slot.rect.x + slot.rect.width / 2, slot.rect.y + slot.rect.height / 2),
      targetId
    )
  end
  Assert.equal(slots[1].rect.y, slots[2].rect.y, "the first two moves share the top row")
  Assert.equal(slots[3].rect.y, slots[4].rect.y, "the last two moves share the bottom row")
  Assert.isTrue(slots[1].rect.x < slots[2].rect.x, "the top row uses left and right columns")
  Assert.isTrue(slots[3].rect.x < slots[4].rect.x, "the bottom row uses left and right columns")
  Assert.isTrue(slots[3].rect.y > slots[1].rect.y, "the grid has two distinct rows")

  local controller = Controller.new()
  controller:setSection("Party")
  controller:setFocus("party:move:0")
  navigate(controller, layout, "right")
  Assert.equal(controller.focus, "party:move:1", "Right stays in the first row")
  navigate(controller, layout, "down")
  Assert.equal(controller.focus, "party:move:3", "Down stays in the right column")
  navigate(controller, layout, "left")
  Assert.equal(controller.focus, "party:move:2", "Left stays in the second row")
  navigate(controller, layout, "up")
  Assert.equal(controller.focus, "party:move:0", "Up stays in the left column")

  for _, slotsToKeep in ipairs({ 0, 1, 3 }) do
    local sparse = partyEditorView("Moves")
    sparse.partyMoves.slots = {}
    for index = 0, slotsToKeep - 1 do
      sparse.partyMoves.slots[#sparse.partyMoves.slots + 1] = {
        kind = "move",
        slot0 = index,
        label = "Move " .. index,
        targetId = "party:move:" .. index,
      }
    end
    local sparseLayout = computeLayout(sparse, 640, 480)
    Assert.equal(#sparseLayout.partyMoves.slots, slotsToKeep, "the grid retains only supplied move slots")
    for index = 0, 3 do
      Assert.equal(
        sparseLayout.targets["party:move:" .. index] ~= nil,
        index < slotsToKeep,
        "an absent move slot has no synthetic target"
      )
    end
  end
end

function T.tests.party_layout_publishes_pixel_anchors_for_each_logical_body_item()
  local stats = partyEditorView("Stats")
  local compact = computeLayout(stats, 256, 192)
  local viewport = assert(compact.viewports.party)
  local anchors = assert(compact.revealByTarget)
  local firstStat = assert(anchors["party:field:iv:hp"], "offscreen Stats targets retain a reveal anchor")
  local firstEv = assert(anchors["party:field:ev:hp"])
  Assert.equal(firstStat.viewportId, "party")
  Assert.equal(firstStat.start, firstEv.start, "IV and EV targets share their source row start")
  Assert.equal(firstStat.extent, firstEv.extent, "IV and EV targets share their source row extent")
  Assert.isTrue(firstStat.extent > 0, "the Stats source row has a positive pixel extent")
  Assert.isTrue(firstStat.start >= 0, "the Stats source row uses unscrolled content coordinates")
  Assert.isTrue(
    compact.targets["party:field:iv:specialDefense"] == nil,
    "the compact viewport keeps distant stat geometry unmaterialized"
  )
  local distant = assert(anchors["party:field:iv:specialDefense"])
  Assert.isTrue(distant.start > firstStat.start, "offscreen rows retain their later content-pixel position")
  Assert.isTrue(viewport.contentExtent > distant.start, "the exact anchor remains inside the logical body")

  local moves = partyEditorView("Moves")
  moves.partyMoves.slots = {
    { kind = "move", slot0 = 0, label = "One", targetId = "party:move:0" },
    { kind = "move", slot0 = 1, label = "Two", targetId = "party:move:1" },
    { kind = "move", slot0 = 2, label = "Three", targetId = "party:move:2" },
    { kind = "move", slot0 = 3, label = "Four", targetId = "party:move:3" },
  }
  local moveLayout = computeLayout(moves, 256, 192)
  local moveAnchors = assert(moveLayout.revealByTarget)
  Assert.equal(moveAnchors["party:move:0"].start, moveAnchors["party:move:1"].start)
  Assert.equal(moveAnchors["party:move:2"].start, moveAnchors["party:move:3"].start)
  Assert.isTrue(
    moveAnchors["party:move:2"].start > moveAnchors["party:move:0"].start,
    "the second grid row has its own exact source offset"
  )

  local details = partyEditorView("Details")
  details.partyDetails.rows = {}
  for index = 1, 12 do
    details.partyDetails.rows[index] = {
      role = "named choice",
      targetId = "party:field:detail:" .. index,
      id = "detail:" .. index,
      label = "Detail " .. index,
      value = index,
      editor = { kind = "choice" },
    }
  end
  local detailLayout = computeLayout(details, 256, 192)
  local detailAnchors = assert(detailLayout.revealByTarget)
  Assert.isNil(detailLayout.targets["party:field:detail:12"], "distant Details geometry stays offscreen")
  Assert.isTrue(detailAnchors["party:field:detail:12"].start > detailAnchors["party:field:detail:1"].start)
  Assert.equal(detailAnchors["party:field:detail:12"].viewportId, "party")
end

function T.tests.party_body_materializes_rows_and_cells_that_overlap_its_viewport()
  local stats = partyEditorView("Stats")
  local initialStats = computeLayout(stats, 256, 192)
  local firstStat = assert(initialStats.revealByTarget["party:field:iv:hp"])

  stats.scrollOffsets = { ["party:Stats"] = 1 }
  local partialFact = computeLayout(stats, 256, 192)
  local partyClip = assert(partialFact.viewports.party).clip
  local level =
    assert(partialFact.targets["party:field:level"], "a fact cell remains materialized at a one-pixel overlap")
  Assert.equal(level.clip, partyClip, "the fact target retains the Party body clip")
  Assert.isTrue(level.rect.y < partyClip.y, "the original fact geometry extends above the viewport")
  Assert.equal(Layout.hitTest(partialFact, stats, level.rect.x + 1, partyClip.y + 1), "party:field:level")
  Assert.isNil(
    Layout.hitTest(partialFact, stats, level.rect.x + 1, partyClip.y - 1),
    "the clipped part of a fact cell cannot be hit"
  )

  stats.scrollOffsets = { ["party:Stats"] = firstStat.start + 1 }
  local partialStat = computeLayout(stats, 256, 192)
  local hpTarget =
    assert(partialStat.targets["party:field:iv:hp"], "a stat row remains materialized at a one-pixel overlap")
  Assert.isTrue(hpTarget.rect.y < partialStat.viewports.party.clip.y, "the stat row keeps its untrimmed rect")
  local hpRow
  for _, row in ipairs(assert(partialStat.partyStatsTable).rows) do
    if row.key == "hp" then
      hpRow = row
    end
  end
  Assert.notNil(hpRow, "an intersecting Stats table row is published")

  local moves = partyEditorView("Moves")
  local moveInitial = computeLayout(moves, 256, 160)
  local moveAnchor = assert(moveInitial.revealByTarget["party:move:0"])
  moves.scrollOffsets = { ["party:Moves"] = moveAnchor.start + 1 }
  local partialMove = computeLayout(moves, 256, 160)
  local move = assert(partialMove.targets["party:move:0"], "an intersecting Moves button is published")
  Assert.equal(move.clip, partialMove.viewports.party.clip)

  local details = partyEditorView("Details")
  details.partyDetails.rows = {}
  for index = 1, 12 do
    details.partyDetails.rows[index] = {
      role = "named choice",
      targetId = "party:field:detail:" .. index,
      id = "detail:" .. index,
      label = "Detail " .. index,
      value = index,
      editor = { kind = "choice" },
    }
  end
  local detailInitial = computeLayout(details, 256, 192)
  local detailAnchor = assert(detailInitial.revealByTarget["party:field:detail:1"])
  details.scrollOffsets = { ["party:Details"] = detailAnchor.start + 1 }
  local partialDetail = computeLayout(details, 256, 192)
  local detail = assert(partialDetail.targets["party:field:detail:1"], "an intersecting Details row is published")
  Assert.equal(detail.clip, partialDetail.viewports.party.clip)
end

function T.tests.party_stats_header_and_pager_are_explicit_focus_stops()
  local layout = computeLayout(partyEditorView("Stats"), 800, 600)
  local headerRegion = nil
  for _, region in ipairs(layout.focusNavigation.regions) do
    if region.id == "party:header" then
      headerRegion = region
      break
    end
  end
  Assert.notNil(headerRegion, "editable Stats facts own a semantic header region")
  Assert.notNil(headerRegion.logical, "the header region retains offscreen editable identities")
  Assert.isTrue(
    headerRegion.logical.indexOf("party:field:level") ~= nil,
    "the header region includes editable fact identities"
  )
  Assert.isNil(navigationFocus(layout, "party:readonly:status"), "read-only facts do not create focus targets")

  local controller = Controller.new()
  controller:setSection("Party")
  controller:setFocus("party:field:iv:hp")
  navigate(controller, layout, "up")
  Assert.isTrue(
    controller.focus == "party:field:level"
      or controller.focus == "party:field:experience"
      or controller.focus == "party:field:friendship"
      or controller.focus == "party:field:currentHp",
    "Up from the first stat row enters an editable header fact"
  )
  navigate(controller, layout, "up")
  Assert.isTrue(
    tostring(controller.focus):match("^party:slot:") ~= nil,
    "Up from the header returns to the member strip"
  )

  local offscreenView = partyEditorView("Stats")
  offscreenView.scrollOffsets = { ["party:Stats"] = 10000 }
  local offscreenLayout = computeLayout(offscreenView, 256, 192)
  Assert.isNil(offscreenLayout.targets["party:field:level"], "scrolled-out header geometry stays virtual")
  local offscreenHeader
  for _, region in ipairs(offscreenLayout.focusNavigation.regions) do
    if region.id == "party:header" then
      offscreenHeader = region
    end
  end
  Assert.notNil(offscreenHeader, "the scrolled-out header keeps its semantic region")
  Assert.equal(offscreenHeader.logical.indexOf("party:field:level"), 1)
  local offscreenStats
  for _, region in ipairs(offscreenLayout.focusNavigation.regions) do
    if region.id == "party:stats" then
      offscreenStats = region
    end
  end
  Assert.notNil(offscreenStats, "the visible Stats rows keep their semantic region")
  Assert.equal(offscreenStats.logical.matrix[1][1], "party:field:iv:hp")
  local reveal = Navigation.resolve({
    scope = { id = offscreenLayout.scopeId, epoch = offscreenLayout.scopeEpoch },
    regions = offscreenLayout.focusNavigation.regions,
    controls = offscreenLayout.focusNavigation.controls,
  }, {
    scopeId = offscreenLayout.scopeId,
    regionId = "party:stats",
    targetId = "party:field:iv:hp",
  }, "up")
  Assert.equal(reveal.targetId, "party:field:level")
  Assert.equal(reveal.reveal.viewportId, "party", "offscreen header focus requests the body viewport reveal")

  controller:setFocus("back")
  navigate(controller, layout, "up")
  Assert.isTrue(
    controller.focus == "party:page:previous" or controller.focus == "party:page:next",
    "Up from footer actions enters the pager before the body"
  )
  navigate(controller, layout, "up")
  Assert.isTrue(
    tostring(controller.focus):match("^party:field:iv:") ~= nil
      or tostring(controller.focus):match("^party:field:ev:") ~= nil,
    "Up from the pager enters the active Stats body"
  )
  controller:setFocus("party:page:previous")
  local pagerDown = navigate(controller, layout, "down")
  Assert.equal(pagerDown.regionId, "global-footer", "Down from the pager enters footer actions")
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
  local rowTargets, indexByTarget = {}, {}
  for index, flag in ipairs(flagRows) do
    local targetId = "flag:" .. flag.name
    rowTargets[index] = targetId
    indexByTarget[targetId] = index
  end
  return {
    section = "Progress",
    status = "ready",
    ready = true,
    dirty = true,
    scope = { id = "section:Progress", epoch = 0, kind = "section", focusId = "money" },
    flagRows = flagRows,
    flagRowTargets = rowTargets,
    flagIndexByTarget = indexByTarget,
    scrollOffsets = {},
    query = query or "",
  }
end

local function choiceDialog(options, selectedKey, query)
  local rowTargets, indexByTarget = {}, {}
  for index, option in ipairs(options) do
    local targetId = "choice:" .. option.key
    rowTargets[index] = targetId
    indexByTarget[targetId] = index
  end
  return {
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
    options = options,
    rowTargets = rowTargets,
    indexByTarget = indexByTarget,
    selectedKey = selectedKey,
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
  local layout = computeLayout(progressFilterView(flags, ""), 256, 320)

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
  local rowTarget = expectedRows[1]
  local marker = assert(layout.rowMarkers[rowTarget], "visible flag rows publish marker geometry")
  local label = assert(layout.rowLabelRects[rowTarget], "visible flag rows publish bounded label geometry")
  Assert.isTrue(label.x - (marker.x + 1) >= 3, "flag glyph bounds clear the marker stroke by at least three pixels")
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
  local entered = Navigation.reconcile({
    scope = { id = layout.scopeId, epoch = layout.scopeEpoch },
    regions = layout.focusNavigation.regions,
    controls = layout.focusNavigation.controls,
    remembered = controller.listCursors,
  }, navigationFocus(layout, "list:flags"), { layout.defaultFocus })
  Assert.isTrue(rowSet[entered.targetId] == true, "the list region immediately focuses its first logical row")
end

local function mapListView()
  local maps = {
    { mapId = 12, symbol = "MAP_TEST_ROUTE", displayName = "TEST_ROUTE", section = "TEST_SECTION" },
    { mapId = 34, symbol = "MAP_TEST_TOWN", displayName = "TEST_TOWN", section = "TEST_SECTION" },
    { mapId = 47, symbol = "MAP_TEST_CAVE", displayName = "TEST_CAVE", section = "TEST_OTHER" },
    { mapId = 7, symbol = "MAP_TEST_LAKE", displayName = "TEST_LAKE", section = "TEST_OTHER" },
  }
  local rowTargets = {}
  local indexByTarget = {}
  for position, map in ipairs(maps) do
    rowTargets[position] = "location:map:" .. map.mapId
    indexByTarget["location:map:" .. map.mapId] = position
  end
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
      mapListId = "location:group:1",
      breadcrumb = "TEST_SECTION",
      mapId = 12,
      symbol = "MAP_TEST_ROUTE",
      section = "TEST_SECTION",
      maps = maps,
      mapRowTargets = rowTargets,
      mapIndexByTarget = indexByTarget,
      generation = 1,
      status = { state = "ready" },
      tiles = {
        { fieldX = 32, fieldZ = 48, selectable = true },
      },
      cursor = { fieldX = 32, fieldZ = 48 },
    },
    locationNavigation = {
      page = "group",
      groupId = "location:group:1",
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
      layout.lists["location:group:1"],
      "the Location map list must publish its interaction record (" .. label .. ")"
    )
    Assert.equal(list.id, "location:group:1")
    Assert.equal(list.targetId, "list:location:group:1")
    Assert.equal(list.viewportId, "location:group:1")
    Assert.isTrue(list.filterable, "the map list accepts direct typing while focused (" .. label .. ")")
    Assert.deepEqual(list.rowTargets, expectedRows)
    Assert.isFalse(list.empty, "a populated map list is not empty (" .. label .. ")")
    Assert.notNil(
      layout.targets["list:location:group:1"],
      "the map list owns one screen-level container target (" .. label .. ")"
    )
    Assert.isTrue(
      focusOrderContains(layout.focusOrder, "list:location:group:1"),
      "the container belongs to the screen-level focus order (" .. label .. ")"
    )
    Assert.isFalse(
      focusOrderHasSearchControl(layout.focusOrder, layout.targets),
      "map filtering needs no standalone search target (" .. label .. ")"
    )
  end
end

function T.tests.location_map_rows_use_full_width_labels_without_a_trailing_value()
  local mapIds = { "location:map:12", "location:map:34", "location:map:47", "location:map:7" }
  for _, size in ipairs({ { 800, 600 }, { 256, 192 } }) do
    local layout = computeLayout(mapListView(), size[1], size[2])
    local rowsByTarget = {}
    for _, row in ipairs(layout.rows) do
      rowsByTarget[row.targetId] = row
    end
    for _, targetId in ipairs(mapIds) do
      local row = assert(rowsByTarget[targetId], "visible map rows publish label geometry")
      Assert.isNil(row.value, "map rows do not repeat their section in a right-hand value")
      Assert.isNil(row.valueRect, "map rows do not reserve a right-hand value cell")
      local target = assert(layout.targets[targetId]).rect
      Assert.isTrue(
        row.labelRect.x + row.labelRect.width >= target.x + target.width - 12,
        "the Map name fills the row after its marker inset"
      )
    end
  end
end

function T.tests.offscreen_location_map_rows_stay_addressable_while_only_visible_rows_materialize()
  local maps = {}
  local offsetRowTargets = {}
  local offsetIndexByTarget = {}
  for index = 1, 30 do
    maps[index] = {
      mapId = index,
      symbol = "MAP_TEST_" .. index,
      displayName = "TEST_" .. index,
      section = "TEST_SECTION",
    }
    offsetRowTargets[index] = "location:map:" .. index
    offsetIndexByTarget["location:map:" .. index] = index
  end
  for _, size in ipairs({ { 800, 600 }, { 256, 192 } }) do
    local view = mapListView()
    view.location.maps = maps
    view.location.mapRowTargets = offsetRowTargets
    view.location.mapIndexByTarget = offsetIndexByTarget
    local layout = computeLayout(view, size[1], size[2])
    local label = size[1] .. "x" .. size[2]
    local list = assert(
      layout.lists["location:group:1"],
      "the Location map list must publish its interaction record (" .. label .. ")"
    )
    Assert.equal(#list.rowTargets, 30, "every map stays addressable (" .. label .. ")")
    local viewport = assert(layout.viewports["location:group:1"])
    local visibleCount = viewport.lastIndex - viewport.firstIndex + 1
    local materialized = 0
    for _, rowTarget in ipairs(list.rowTargets) do
      if layout.targets[rowTarget] ~= nil then
        materialized = materialized + 1
      end
    end
    local distant = list.rowTargets[30]
    Assert.notNil(navigationFocus(layout, distant), "the last map remains logically addressable (" .. label .. ")")
    if viewport.lastIndex < 30 then
      Assert.isTrue(
        materialized <= visibleCount + 2,
        "only the visible map window materializes targets (" .. label .. ")"
      )
      Assert.isTrue(materialized < 30, "offscreen map rows share no per-frame target (" .. label .. ")")
      Assert.isNil(layout.targets[distant], "the last map has no target at the top offset (" .. label .. ")")
      local scrolledView = mapListView()
      scrolledView.location.maps = maps
      scrolledView.location.mapRowTargets = offsetRowTargets
      scrolledView.location.mapIndexByTarget = offsetIndexByTarget
      scrolledView.locationNavigation.mapOffset = (30 - viewport.lastIndex) * viewport.rowExtent
      local revealed = computeLayout(scrolledView, size[1], size[2])
      Assert.notNil(revealed.targets[distant], "the scrolled window materializes the last map (" .. label .. ")")
      Assert.notNil(navigationFocus(revealed, distant), "the scrolled window focuses the last map (" .. label .. ")")
    else
      Assert.equal(materialized, 30, "a fitting map list materializes every visible row (" .. label .. ")")
    end
  end
end

function T.tests.location_uses_one_mode_per_layout_without_picker_controls()
  for _, size in ipairs({ { 256, 192 }, { 360, 640 }, { 800, 600 } }) do
    local label = size[1] .. "x" .. size[2]
    local listLayout = computeLayout(mapListView(), size[1], size[2])
    Assert.isNil(listLayout.locationGrid, "the map list never composes the grid (" .. label .. ")")
    Assert.isNil(listLayout.locationHeader, "the map list never composes the grid header (" .. label .. ")")
    Assert.notNil(
      listLayout.lists["location:group:1"],
      "the map list publishes its interaction record (" .. label .. ")"
    )
    Assert.isNil(listLayout.targets["location:map-picker"], "map selection has no picker control (" .. label .. ")")
    Assert.isNil(listLayout.targets["location:map-back"], "map selection has no nested Back (" .. label .. ")")

    local gridLayout = computeLayout(locationView(), size[1], size[2])
    Assert.isNil(
      gridLayout.lists["location:group:1"],
      "coordinate selection never composes the map list (" .. label .. ")"
    )
    Assert.notNil(gridLayout.locationGrid, "coordinate selection publishes the grid (" .. label .. ")")
    Assert.notNil(gridLayout.targets["location:grid"], "the grid publishes its focus surface (" .. label .. ")")
    Assert.notNil(
      navigationFocus(gridLayout, "location:grid"),
      "the grid remains in the logical focus graph (" .. label .. ")"
    )
    Assert.notNil(gridLayout.locationHeader, "coordinate selection publishes one header (" .. label .. ")")
    Assert.isNil(
      gridLayout.targets["location:map-picker"],
      "coordinate selection has no picker control (" .. label .. ")"
    )
    Assert.isNil(gridLayout.targets["location:map-back"], "coordinate selection has no nested Back (" .. label .. ")")
    for targetId in pairs(gridLayout.targets) do
      Assert.isNil(targetId:match("^location:map:%d+$"), "coordinate selection exposes no map row (" .. label .. ")")
    end
  end
end

function T.tests.location_grid_header_combines_identity_coordinates_and_blocked_state_on_one_line()
  for _, size in ipairs({ { 256, 192 }, { 800, 600 } }) do
    local label = size[1] .. "x" .. size[2]
    local layout = computeLayout(locationView(), size[1], size[2])
    local header = assert(layout.locationHeader, "the grid publishes one header record (" .. label .. ")")
    Assert.isTrue(
      header.leftText:find("TEST_ROUTE", 1, true) ~= nil
        and header.leftText:find("X 33", 1, true) ~= nil
        and header.leftText:find("Z 48", 1, true) ~= nil,
      "the header names the map and both coordinates on one line (" .. label .. ")"
    )
    Assert.isFalse(header.leftText:find("\n") ~= nil, "the header identity never wraps (" .. label .. ")")
    Assert.equal(
      header.rightText,
      "Impassable tile",
      "the blocked cursor reports its cause at the right (" .. label .. ")"
    )
    Assert.equal(header.leftRect.y, header.rightRect.y, "header halves share one line (" .. label .. ")")
    Assert.equal(header.leftRect.height, 14, "the header occupies one text line (" .. label .. ")")
    Assert.isTrue(
      header.rightRect.x >= header.leftRect.x + header.leftRect.width,
      "the disclaimer never overlaps the identity (" .. label .. ")"
    )
    Assert.isTrue(
      header.rightRect.x + header.rightRect.width <= header.lineRect.x + header.lineRect.width + 0.01,
      "the disclaimer stays inside the header line (" .. label .. ")"
    )
    Assert.isNil(layout.locationStatus, "the old status block is gone (" .. label .. ")")
    for _, entry in ipairs(layout.navigation) do
      Assert.isNil(
        entry.label and entry.label:find("TEST_ROUTE", 1, true),
        "the map identity is not duplicated in navigation (" .. label .. ")"
      )
    end
    for _, row in ipairs(layout.rows) do
      Assert.isNil(
        row.label and row.label:find("TEST_ROUTE", 1, true),
        "the map identity is not duplicated in rows (" .. label .. ")"
      )
    end
  end

  local openView = locationView()
  openView.locationNavigation.cursor = { fieldX = 32, fieldZ = 48 }
  local openLayout = computeLayout(openView, 800, 600)
  local openHeader = assert(openLayout.locationHeader, "the grid publishes one header record")
  Assert.isNil(openHeader.rightText, "a selectable cursor shows no disclaimer")
end

function T.tests.location_map_rows_share_their_cached_order_by_reference()
  local view = mapListView()
  local first = computeLayout(view, 800, 600)
  local second = computeLayout(view, 256, 192)
  local firstList = assert(first.lists["location:group:1"], "the map list publishes its interaction record")
  Assert.isTrue(firstList.rowTargets == view.location.mapRowTargets, "layout shares the cached row order")
  Assert.isTrue(firstList.indexByTarget == view.location.mapIndexByTarget, "layout shares the cached row index")
  Assert.isTrue(
    second.lists["location:group:1"].rowTargets == view.location.mapRowTargets,
    "repeated layouts never copy the cached row order"
  )
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
    valueEditor = choiceDialog(options, "K01"),
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

  local entered = Navigation.reconcile({
    scope = { id = layout.scopeId, epoch = layout.scopeEpoch },
    regions = layout.focusNavigation.regions,
    controls = layout.focusNavigation.controls,
  }, navigationFocus(layout, "list:value:choice"), { layout.defaultFocus })
  Assert.isTrue(entered.targetId:match("^choice:") ~= nil, "the choice region immediately focuses its first row")
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

function T.tests.save_editor_card_geometry_is_bounded_and_row_major()
  local loadedCard, Card = pcall(require, "app.src.saveeditor.SaveEditorCard")
  Assert.isTrue(loadedCard, "the editor owns pure card-grid geometry")

  for _, bounds in ipairs({
    { x = 0, y = 0, width = 256, height = 192 },
    { x = 0, y = 0, width = 800, height = 600 },
  }) do
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

function T.tests.measured_map_surface_fits_its_labels_and_narrow_host_loses_no_canvas_width()
  local view = locationView()
  local rowTargets, indexByTarget, maps = {}, {}, {}
  for index = 1, 12 do
    local targetId = "location:map:" .. tostring(index)
    local row = {
      mapId = index,
      kind = "map",
      displayName = "ROUTE_" .. tostring(index),
      section = "Johto",
    }
    rowTargets[index], indexByTarget[targetId], maps[index] = targetId, index, row
  end
  view.locationNavigation.page = "root"
  view.location.maps = maps
  view.location.mapListId = "location:root"
  view.location.mapModel = {
    count = #maps,
    rowTargets = rowTargets,
    indexByTarget = indexByTarget,
    rowAt = function(index)
      return maps[index]
    end,
    idAt = function(index)
      return rowTargets[index]
    end,
  }
  view.scope = { id = "section:Location", epoch = 1, kind = "section" }
  view.textMetrics = {
    lineHeight = 14,
    measure = function(text)
      return #text * 7
    end,
  }

  local function resolve(width, height)
    local surface = { id = "primary", touch = false }
    return Interface.resolve({
      configuration = "nativeLike",
      measurement = { pixelRatio = 1 },
      primary = { surface = surface, usableBounds = { x = 0, y = 0, width = width, height = height } },
      secondary = nil,
    }, view)
  end

  local narrow = resolve(200, 300)
  local native = resolve(256, 192)
  local mapList = assert(narrow.content.layout.lists["location:root"])
  Assert.isTrue(narrow.content.width < 256, "a narrow non-dual host does not preserve the unused native canvas floor")
  Assert.equal(native.content.width, 256, "the canonical DS pane keeps native logical width")
  Assert.isTrue(
    mapList.surfaceRect.width < narrow.content.layout.content.width,
    "Map rows center a measured surface inside the body"
  )
  Assert.equal(
    mapList.surfaceRect.x,
    narrow.content.layout.content.x + (narrow.content.layout.content.width - mapList.surfaceRect.width) / 2,
    "the narrower Map surface remains centered"
  )
end

function T.tests.list_rows_publish_shared_text_and_marker_geometry_for_value_modes()
  local List = require("libs.ui.src.ListSurface")
  for _, size in ipairs({ { 128, 192 }, { 192, 256 }, { 256, 192 }, { 720, 480 }, { 1280, 720 } }) do
    local bounds = { x = 0, y = 0, width = size[1], height = size[2] }
    local rows = {}
    for _, hasTrailingValue in ipairs({ false, true }) do
      local list = List.resolve({
        bounds = bounds,
        rowCount = 1,
        rowHeight = 18,
        gap = 0,
        maxWidth = size[1],
        headerHeight = 14,
        hasTrailingValue = hasTrailingValue,
        font = {
          lineHeight = 14,
          measure = function(text)
            return #text * 7
          end,
        },
      })
      local row = assert(list.rows[1])
      local label = assert(row.labelRect, "each row publishes its bounded label region")
      local marker = row.markerRect
      Assert.isTrue(row.markerRadius <= 2, "list markers have straight lateral edges")
      Assert.isTrue(label.x >= marker.x + 4, "the label stays inside the marker with a readable gutter")
      Assert.isTrue(label.x + label.width <= marker.x + marker.width - 4)
      Assert.isTrue(label.y >= row.rect.y and label.y + label.height <= row.rect.y + row.rect.height)
      Assert.isTrue(label.height >= 14, "the label region fits the body font line")
      Assert.equal(row.valueRect ~= nil, hasTrailingValue, "only valued rows reserve a right text region")
      if row.valueRect ~= nil then
        Assert.isTrue(row.valueRect.x >= label.x + label.width + 4, "label and value have a readable gap")
        Assert.isTrue(row.valueRect.x + row.valueRect.width <= marker.x + marker.width - 4)
        Assert.isTrue(
          row.valueRect.y >= row.rect.y and row.valueRect.y + row.valueRect.height <= row.rect.y + row.rect.height
        )
      end
      rows[#rows + 1] = row
    end
    Assert.equal(rows[1].markerRect.x, rows[2].markerRect.x, "value presence does not change marker inset")
    Assert.equal(rows[1].labelRect.x, rows[2].labelRect.x, "value presence preserves the shared label gutter")
  end
end

function T.tests.filterable_lists_reserve_a_hint_line_above_their_rows()
  local metrics = filterMetrics()
  local flags = progressFilterFlags()
  for _, query in ipairs({ "", "beat" }) do
    local layout = computeLayout(progressFilterView(flags, query), 256, 192)
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
    valueEditor = choiceDialog(options, "K01"),
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
  local draft = partyEditorView("Stats")
  draft.dirty = true
  for _, size in ipairs({ { 256, 192 }, { 800, 600 } }) do
    local layout = Layout.compute(draft, size[1], size[2], metrics)
    local apply = assert(layout.targets["save"]).rect
    local discard = assert(layout.targets["discard"]).rect
    Assert.isTrue(
      discard.x - (apply.x + apply.width) >= 4,
      size[1] .. "px footer actions keep at least 4px between neighbors"
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
        local overlap = a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
        Assert.isFalse(overlap, size[1] .. "px draft controls never overlap")
      end
    end
  end
end

function T.tests.wide_buttons_stay_bounded_and_action_groups_stay_centered()
  local metrics = filterMetrics()
  local draft = partyEditorView("Stats")
  draft.dirty = true
  local layout = Layout.compute(draft, 1280, 720, metrics)
  local left, right = nil, nil
  for _, id in ipairs({ "save", "discard", "back" }) do
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

function T.tests.list_rows_use_a_compact_extent_independent_of_form_controls()
  local flags = progressFilterFlags()
  local layout = computeLayout(progressFilterView(flags, ""), 256, 192)
  local viewport = assert(layout.viewports.flags, "the flag list publishes its scroll viewport")
  Assert.equal(viewport.rowExtent, 18, "list rows use the compact list extent")
  Assert.equal(viewport.gap, 0, "list rows have no inter-row gap")
  local bodyTextHeight = math.ceil(14 * 0.75)
  Assert.isTrue(viewport.rowExtent >= bodyTextHeight, "the compact extent still contains the body text")
  local first = assert(layout.targets["flag:" .. flags[1].name]).rect
  local second = assert(layout.targets["flag:" .. flags[2].name]).rect
  Assert.equal(second.y - first.y, 18, "consecutive rows advance by exactly one compact extent")
  Assert.equal(first.height, 16, "rendered rows keep a one-pixel inset inside the compact extent")

  local player = computeLayout({
    status = "ready",
    ready = true,
    section = "Player",
    scope = { id = "section:Player", epoch = 0, kind = "section" },
    session = { playerName = "PLAYER", money = 3000, frameIndex = 0 },
  }, 256, 192)
  local money = assert(player.targets.money).rect
  Assert.isTrue(money.height >= 28, "form controls keep their roomy height while list rows stay compact")
  Assert.isTrue(money.height > first.height, "list rows are roughly half the form control height")

  local options = {}
  for index = 1, 6 do
    options[index] = { key = string.format("K%02d", index), label = "Choice " .. index }
  end
  local choice = computeLayout({
    section = "Bag",
    status = "ready",
    ready = true,
    dirty = false,
    bagRows = {},
    valueEditor = choiceDialog(options, "K01"),
    scope = { id = "value:choice", epoch = 1, kind = "value", focusId = "choice:K01" },
    scrollOffsets = {},
  }, 256, 192)
  local choiceViewport = assert(choice.viewports["value:choice"], "the choice list publishes its scroll viewport")
  Assert.equal(choiceViewport.rowExtent, 18, "choice rows share the compact list extent")
end

local function largeFlagCatalog(count)
  local flags, rowTargets, indexByTarget = {}, {}, {}
  for index = 1, count do
    local name = string.format("SYNTH_FLAG_%05d", index)
    flags[index] = { name = name, displayName = "Synthetic flag " .. index, value = index % 2 == 0 }
    local targetId = "flag:" .. name
    rowTargets[index] = targetId
    indexByTarget[targetId] = index
  end
  return flags, rowTargets, indexByTarget
end

local function countMatching(targets, pattern)
  local count = 0
  for targetId in pairs(targets) do
    if targetId:match(pattern) ~= nil then
      count = count + 1
    end
  end
  return count
end

function T.tests.large_flag_catalog_materializes_only_its_visible_window()
  local flags, rowTargets, indexByTarget = largeFlagCatalog(10000)
  local viewportHeight
  do
    local probe = computeLayout({
      section = "Progress",
      status = "ready",
      ready = true,
      dirty = true,
      scope = { id = "section:Progress", epoch = 0, kind = "section", focusId = "money" },
      flagRows = flags,
      flagRowTargets = rowTargets,
      flagIndexByTarget = indexByTarget,
      scrollOffsets = {},
      query = "",
    }, 256, 192)
    viewportHeight = assert(probe.viewports.flags).clip.height
  end
  local capacity = math.ceil(viewportHeight / 18) + 2
  Assert.isTrue(capacity < 100, "the fixture viewport fits far fewer rows than the catalog")
  for _, case in ipairs({
    { name = "top", offset = 0 },
    { name = "middle", offset = 5000 * 18 },
    { name = "end", offset = 10000 * 18 },
  }) do
    local layout = computeLayout({
      section = "Progress",
      status = "ready",
      ready = true,
      dirty = true,
      scope = { id = "section:Progress", epoch = 0, kind = "section", focusId = "money" },
      flagRows = flags,
      flagRowTargets = rowTargets,
      flagIndexByTarget = indexByTarget,
      scrollOffsets = { flags = case.offset },
      query = "",
    }, 256, 192)
    local viewport = assert(layout.viewports.flags)
    local first, last = ScrollViewport.visibleRange(viewport.offset, viewport.clip.height, 18, 0, 10000)
    local rendered = 0
    for _, row in ipairs(layout.rows) do
      if row.listSurface then
        rendered = rendered + 1
      end
    end
    Assert.isTrue(
      rendered <= last - first + 1,
      case.name .. " renders at most its visible window (" .. rendered .. " rows)"
    )
    Assert.isTrue(rendered < 100, case.name .. " never approaches the catalog size")
    Assert.isTrue(
      countMatching(layout.targets, "^flag:") <= last - first + 1,
      case.name .. " materializes targets only for its visible window"
    )
    Assert.isTrue(countMatching(
      (function()
        local ids = {}
        for _, control in ipairs(layout.focusNavigation.controls) do
          ids[control.id] = true
        end
        return ids
      end)(),
      "^flag:"
    ) <= last - first + 1, case.name .. " keeps navigation controls only for its visible window")
    Assert.equal(#layout.lists.flags.rowTargets, 10000, case.name .. " keeps the complete logical order")
    local firstTarget = rowTargets[first]
    local firstRect = assert(
      layout.targets[firstTarget],
      case.name .. " materializes the first row of its window (" .. firstTarget .. ")"
    )
    Assert.isTrue(
      firstRect.rect.y >= viewport.clip.y - 18 and firstRect.rect.y <= viewport.clip.y + viewport.clip.height,
      case.name .. " places its window rows inside the viewport"
    )
    if last < 10000 then
      Assert.isNil(layout.targets[rowTargets[last + 1]], case.name .. " shares no target with the row past its window")
    end
  end
end

function T.tests.large_choice_catalog_materializes_only_its_visible_window()
  local options, rowTargets, indexByTarget = {}, {}, {}
  for index = 1, 10000 do
    local key = string.format("K%05d", index)
    options[index] = { key = key, label = "Choice " .. index }
    local targetId = "choice:" .. key
    rowTargets[index] = targetId
    indexByTarget[targetId] = index
  end
  local layout = computeLayout({
    section = "Bag",
    status = "ready",
    ready = true,
    dirty = false,
    bagRows = {},
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
      options = options,
      rowTargets = rowTargets,
      indexByTarget = indexByTarget,
      selectedKey = "K00001",
      query = "",
    },
    scope = { id = "value:choice", epoch = 1, kind = "value", focusId = "choice:K00001" },
    scrollOffsets = {},
  }, 256, 192)
  local viewport = assert(layout.viewports["value:choice"])
  Assert.equal(viewport.rowExtent, 18, "choice rows share the compact list extent")
  local capacity = viewport.lastIndex - viewport.firstIndex + 1
  Assert.isTrue(capacity < 100, "the fixture viewport fits far fewer choices than the catalog")
  Assert.isTrue(
    countMatching(layout.targets, "^choice:") <= capacity,
    "choice targets stay bounded by the visible window"
  )
  Assert.isTrue(countMatching(
    (function()
      local ids = {}
      for _, control in ipairs(layout.focusNavigation.controls) do
        ids[control.id] = true
      end
      return ids
    end)(),
    "^choice:"
  ) <= capacity, "choice controls stay bounded by the visible window")
  Assert.equal(#layout.lists["value:choice"].rowTargets, 10000, "the logical choice order stays complete")
  Assert.isNil(layout.targets["choice:K10000"], "the last choice has no target at the top offset")
  Assert.notNil(navigationFocus(layout, "choice:K10000"), "the last choice stays logically addressable")
  Assert.notNil(layout.targets["list:value:choice"], "the container stays focusable in a large catalog")
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

function T.tests.compact_and_tall_section_navigation_matches_the_horizontal_strip()
  local rightTargets, leftTargets, downTargets = {}, {}, {}
  for _, size in ipairs({ { 256, 192 }, { 256, 400 } }) do
    local layout = computeLayout(sectionStripView("Player"), size[1], size[2])
    local controller = Controller.new()
    controller:setSection("Player")
    controller:setFocus("section:Player")

    navigate(controller, layout, "right")
    rightTargets[#rightTargets + 1] = controller.focus
    navigate(controller, layout, "left")
    leftTargets[#leftTargets + 1] = controller.focus
    navigate(controller, layout, "down")
    downTargets[#downTargets + 1] = controller.focus
  end
  Assert.deepEqual(rightTargets, { "section:Party", "section:Party" }, "Right advances one section in visible order")
  Assert.deepEqual(leftTargets, { "section:Player", "section:Player" }, "Left returns to the previous section")
  for _, targetId in ipairs(downTargets) do
    Assert.isFalse(targetId:match("^section:") ~= nil, "Down leaves the section strip")
    Assert.isFalse(targetId == "back", "Down does not enter the footer action")
  end
end

function T.tests.wide_section_navigation_keeps_the_vertical_rail_orientation()
  local layout = computeLayout(sectionStripView("Player"), 800, 600)
  local controller = Controller.new()
  controller:setSection("Player")
  controller:setFocus("section:Player")

  navigate(controller, layout, "up")
  Assert.equal(controller.focus, "section:Location", "Up moves to the previous rail item")
  navigate(controller, layout, "down")
  Assert.equal(controller.focus, "section:Player", "Down returns to the next rail item")
  navigate(controller, layout, "right")
  Assert.isFalse(controller.focus:match("^section:") ~= nil, "Right leaves the rail for page content")
end

function T.tests.wide_shell_is_centered_and_capped_with_footer_inside()
  for _, width in ipairs({ 800, 1200 }) do
    local label = width .. "px"
    local layout = computeLayout(sectionStripView("Player"), width, 600)
    local shell = assert(layout.shell, "the wide layout publishes its centered shell (" .. label .. ")")
    Assert.isTrue(shell.width <= 640, "the shell never spans the window (" .. label .. ")")
    Assert.near(shell.x, (width - shell.width) / 2, 1.01, "the shell is horizontally centered")
    local rail = assert(layout.targets["section:Location"], "the wide layout keeps its side rail").rect
    Assert.isTrue(rail.x >= shell.x, "the rail lives inside the shell")
    Assert.isTrue(layout.content.x >= rail.x + rail.width, "content starts right of the rail (" .. label .. ")")
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

function T.tests.wide_content_column_stays_narrow_as_the_host_grows()
  for _, width in ipairs({ 800, 1280, 2560 }) do
    local layout = computeLayout(sectionStripView("Player"), width, 600)
    local rail = assert(layout.targets["section:Location"], "wide layout keeps its section rail").rect
    Assert.isTrue(layout.content.width <= 384, width .. "-pixel hosts keep a 384-pixel content cap")
    Assert.isTrue(rail.x + rail.width <= layout.content.x, "navigation remains to the left of content")
    Assert.isTrue(layout.content.x >= 8, "content keeps the outer safety margin")
    Assert.isTrue(layout.content.x + layout.content.width <= width - 8, "content fits within the far margin")
  end
end

function T.tests.compact_content_and_footer_keep_the_minimum_outer_safety_margin()
  local width, height = 256, 192
  local layout = computeLayout(sectionStripView("Player"), width, height)
  Assert.isTrue(layout.content.x >= 8, "compact content keeps the minimum outer safety margin")
  Assert.isTrue(
    layout.content.x + layout.content.width <= width - 8,
    "compact content stays inside the far safety margin"
  )
  Assert.isTrue(layout.footer.x >= 8, "compact footer keeps the minimum outer safety margin")
  Assert.isTrue(layout.footer.x + layout.footer.width <= width - 8, "compact footer stays inside the far safety margin")
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
        flagRowTargets = {},
        flagIndexByTarget = {},
        scrollOffsets = {},
        query = "",
      },
      width = 256,
      height = 192,
    },
    {
      name = "Party",
      view = partyEditorView("Stats"),
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
      map = { mapId = 12, symbol = "MAP_TEST_ROUTE", section = "TEST_SECTION" },
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

function T.tests.decision_targets_derive_from_the_published_descriptors()
  local view = {
    section = "Bag",
    status = "ready",
    ready = true,
    dirty = false,
    modal = "bag-item",
    focus = "bag:quantity",
    scope = { id = "decision:bag-item", epoch = 1, kind = "decision", focusId = "bag:quantity" },
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
  local layout = Layout.compute(view, 256, 192, view.textMetrics)
  Assert.notNil(layout.decisionList, "the item decision publishes its surface")
  Assert.equal(#layout.decisionList.rows, 3, "every described action renders in order")
  Assert.equal(layout.decisionList.rows[1].label, "Quantity", "rows paint the described captions")
  Assert.equal(layout.decisionList.rows[2].semantic, "destructive", "rows paint the described roles")
  Assert.equal(layout.decisionList.rows[2].enabled, false, "rows carry the described enablement")
  Assert.notNil(layout.targets["bag:quantity"], "an enabled action stays hittable")
  Assert.notNil(layout.targets.cancel, "Cancel stays hittable")
  Assert.isNil(layout.targets["bag:remove"], "a disabled action is not a hit target")
  local disabledRow = assert(layout.decisionList.rows[2], "the disabled row still renders")
  local centerX = disabledRow.rect.x + math.floor(disabledRow.rect.width / 2)
  local centerY = disabledRow.rect.y + math.floor(disabledRow.rect.height / 2)
  Assert.isNil(Layout.hitTest(layout, view, centerX, centerY), "a press on a disabled action never activates")
end

local function everySectionScopeView()
  local bagTabs, bagPockets = {}, {}
  for index, key in ipairs({ "items", "balls" }) do
    bagTabs[index] = { x = (index - 1) * 32, y = 0, width = 32, height = 32 }
    bagPockets[index] = { key = key }
  end
  local bagRows = {
    { item = "POKE_BALL", label = "Poke Ball", quantity = 3 },
    { item = "POTION", label = "Potion", quantity = 1 },
  }
  local options = {}
  for index = 1, 6 do
    options[index] = { key = string.format("K%02d", index), label = "Choice " .. index }
  end
  return {
    { name = "Player", view = sectionStripView("Player") },
    { name = "Location grid", view = locationView() },
    { name = "Location map-list", view = mapListView() },
    { name = "Progress", view = progressFilterView(progressFilterFlags(), "") },
    { name = "Party Stats", view = partyEditorView("Stats") },
    { name = "Party Moves", view = partyEditorView("Moves") },
    { name = "Party Details", view = partyEditorView("Details") },
    {
      name = "Bag",
      view = {
        section = "Bag",
        status = "ready",
        ready = true,
        dirty = false,
        scope = { id = "section:Bag", epoch = 0, kind = "section" },
        bagPocket = "balls",
        bagPocketTabRects = bagTabs,
        bagPockets = bagPockets,
        bagRows = bagRows,
        bagPageRows = bagRows,
        bagPage0 = 0,
        bagPageCount = 1,
      },
    },
    {
      name = "choice scope",
      view = {
        section = "Bag",
        status = "ready",
        ready = true,
        dirty = false,
        bagRows = {},
        valueEditor = choiceDialog(options, "K01"),
        scope = { id = "value:choice", epoch = 1, kind = "value", focusId = "choice:K01" },
        scrollOffsets = {},
      },
    },
    {
      name = "name scope",
      view = {
        section = "Player",
        status = "ready",
        ready = true,
        dirty = false,
        session = { playerName = "PLAYER", money = 3000, frameIndex = 0 },
        valueEditor = {
          kind = "name",
          naming = {
            cursor = { row = 1, column = 1 },
            controls = { { id = "lower", firstColumn = 1, lastColumn = 1 } },
          },
        },
        scope = { id = "value:name", epoch = 1, kind = "value" },
        scrollOffsets = {},
      },
    },
    {
      name = "number scope",
      view = {
        section = "Player",
        status = "ready",
        ready = true,
        dirty = false,
        session = { playerName = "PLAYER", money = 3000, frameIndex = 0 },
        valueEditor = { kind = "number", parsedValue = 3, buffer = "3", digitCount = 1, digits = { "3" } },
        numberControlVisuals = { increment = { normal = { width = 48, height = 48 } } },
        numberControls = {
          { delta = 1, hitRect = { x = 0, y = 0, width = 24, height = 24 } },
          { delta = -1, hitRect = { x = 0, y = 28, width = 24, height = 24 } },
        },
        scope = { id = "value:number", epoch = 1, kind = "value" },
        scrollOffsets = {},
      },
    },
    {
      name = "decision scope",
      view = {
        section = "Bag",
        status = "ready",
        ready = true,
        dirty = true,
        modal = "bag-item",
        scope = { id = "decision:bag-item", epoch = 1, kind = "decision", focusId = "cancel" },
        decisionActions = {
          { id = "bag:quantity", label = "Quantity", semantic = "secondary", enabled = true, command = "bag_quantity" },
          { id = "bag:remove", label = "Remove", semantic = "destructive", enabled = false, command = "bag_remove" },
          { id = "cancel", label = "Cancel", semantic = "back", enabled = true, command = "cancel" },
        },
      },
    },
  }
end

function T.tests.every_section_publishes_the_complete_plan_shape_at_every_topology()
  local topologies = { { 256, 192 }, { 640, 480 }, { 360, 640 }, { 1280, 720 } }
  for _, plan in ipairs(everySectionScopeView()) do
    for _, size in ipairs(topologies) do
      local label = plan.name .. " at " .. size[1] .. "x" .. size[2]
      local layout = computeLayout(plan.view, size[1], size[2])
      for _, key in ipairs({
        "rows",
        "targets",
        "focusGraph",
        "focusOrder",
        "navigation",
        "actions",
        "viewports",
        "lists",
      }) do
        Assert.notNil(layout[key], label .. " publishes " .. key)
      end
      Assert.notNil(layout.defaultFocus, label .. " publishes a default focus")
      local wantScope = plan.view.scope or { id = "section:" .. tostring(plan.view.section or "Player"), epoch = 0 }
      Assert.equal(layout.scopeId, wantScope.id, label .. " echoes its active scope")
      Assert.equal(layout.scopeEpoch, wantScope.epoch, label .. " echoes its scope epoch")
      Assert.notNil(
        layout.focusGraph[layout.defaultFocus],
        label .. " default focus belongs to its graph (" .. layout.defaultFocus .. ")"
      )
      local seen, graphCount = {}, 0
      for targetId in pairs(layout.focusGraph) do
        graphCount = graphCount + 1
      end
      for _, targetId in ipairs(layout.focusOrder) do
        Assert.isNil(seen[targetId], label .. " keeps one focus record per target: " .. targetId)
        seen[targetId] = true
        Assert.notNil(layout.focusGraph[targetId], label .. " orders only graphed targets: " .. targetId)
      end
      local orderedCount = 0
      for _ in pairs(seen) do
        orderedCount = orderedCount + 1
      end
      Assert.equal(orderedCount, graphCount, label .. " orders every graphed target")
      for targetId, target in pairs(layout.targets) do
        Assert.notNil(target.rect, label .. " target has geometry: " .. targetId)
        Assert.isTrue(
          target.rect.width >= 1 and target.rect.height >= 1,
          label .. " target keeps positive geometry: " .. targetId
        )
        Assert.equal(type(target.activationEnabled), "boolean", label .. " target states enablement: " .. targetId)
        Assert.equal(type(target.focusable), "boolean", label .. " target states focusability: " .. targetId)
        Assert.equal(type(target.role), "string", label .. " target states its role: " .. targetId)
      end
    end
  end
  local metrics = {
    lineHeight = 14,
    measure = function(text)
      return #text * 7
    end,
  }
  local stable = sectionStripView("Player")
  local first = Layout.compute(stable, 256, 192, metrics)
  local second = Layout.compute(stable, 256, 192, metrics)
  local function withoutCallbacks(value)
    if type(value) ~= "table" then
      return value
    end
    local result = {}
    for key, item in pairs(value) do
      if type(item) ~= "function" then
        result[key] = withoutCallbacks(item)
      end
    end
    return result
  end
  Assert.deepEqual(
    withoutCallbacks(second),
    withoutCallbacks(first),
    "the same view and measurement produce the same public plan semantics"
  )
end

function T.tests.pointer_hits_resolve_from_published_targets_without_the_full_catalog()
  local options, rowTargets, indexByTarget = {}, {}, {}
  for index = 1, 6 do
    local key = string.format("K%02d", index)
    options[index] = { key = key, label = "Choice " .. index }
    rowTargets[index] = "choice:" .. key
    indexByTarget["choice:" .. key] = index
  end
  local choiceView = {
    section = "Bag",
    status = "ready",
    ready = true,
    dirty = false,
    bagRows = {},
    valueEditor = {
      kind = "choice",
      options = options,
      rowTargets = rowTargets,
      indexByTarget = indexByTarget,
      selectedKey = "K01",
      query = "",
      count = #options,
      idAt = function(index)
        return rowTargets[index]
      end,
      rowAt = function(index)
        return options[index]
      end,
    },
    scope = { id = "value:choice", epoch = 1, kind = "value", focusId = "choice:K01" },
    scrollOffsets = {},
  }
  local choiceLayout = computeLayout(choiceView, 256, 192)
  local firstChoice = assert(choiceLayout.targets["choice:K01"]).rect
  local choiceX, choiceY = firstChoice.x + 1, firstChoice.y + 1
  Assert.equal(
    Layout.hitTest(choiceLayout, choiceView, choiceX, choiceY),
    "choice:K01",
    "a visible choice resolves while its cached order is present"
  )
  local choiceWithoutCatalog = {
    section = "Bag",
    status = "ready",
    valueEditor = { kind = "choice", options = options, query = "" },
    scope = choiceView.scope,
  }
  Assert.equal(
    Layout.hitTest(choiceLayout, choiceWithoutCatalog, choiceX, choiceY),
    "choice:K01",
    "a visible choice resolves from its published target alone"
  )

  local numberView = {
    section = "Player",
    status = "ready",
    ready = true,
    dirty = false,
    session = { playerName = "PLAYER", money = 3000, frameIndex = 0 },
    valueEditor = { kind = "number", parsedValue = 3, buffer = "3", digitCount = 1, digits = { "3" } },
    numberControlVisuals = { increment = { normal = { width = 48, height = 48 } } },
    numberControls = {
      { delta = 1, hitRect = { x = 0, y = 0, width = 24, height = 24 } },
      { delta = -1, hitRect = { x = 0, y = 28, width = 24, height = 24 } },
    },
    scope = { id = "value:number", epoch = 1, kind = "value" },
    scrollOffsets = {},
  }
  local numberLayout = computeLayout(numberView, 256, 192)
  local numberTargetId = "number:place:0:up"
  local delta = assert(numberLayout.targets[numberTargetId]).rect
  local deltaX, deltaY = delta.x + 1, delta.y + 1
  Assert.equal(
    Layout.hitTest(numberLayout, numberView, deltaX, deltaY),
    numberTargetId,
    "a number control resolves while its manifest is present"
  )
  local numberWithoutManifest = {
    section = "Player",
    status = "ready",
    valueEditor = { kind = "number", parsedValue = 3, buffer = "3", digitCount = 1, digits = { "3" } },
    scope = numberView.scope,
  }
  Assert.equal(
    Layout.hitTest(numberLayout, numberWithoutManifest, deltaX, deltaY),
    numberTargetId,
    "a number control resolves from its published target alone"
  )
end

function T.tests.decision_targets_keep_their_canonical_shape_without_published_descriptors()
  local view = {
    section = "Bag",
    status = "ready",
    ready = true,
    dirty = false,
    modal = "bag-item",
    focus = "cancel",
    bagSelectedItem = "ITEM_7",
    bagSelectedLabel = "Item 7",
    bagSelectedQuantity = 7,
    scope = { id = "decision:bag-item", epoch = 1, kind = "decision", focusId = "cancel" },
    textMetrics = {
      lineHeight = 14,
      measure = function(text)
        return #text * 7
      end,
    },
  }
  local layout = Layout.compute(view, 256, 192, view.textMetrics)
  Assert.notNil(layout.targets["bag:quantity"], "the item decision offers Quantity")
  Assert.notNil(layout.targets["bag:remove"], "the item decision offers Remove")
  Assert.notNil(layout.targets.cancel, "the item decision offers Cancel")
end

local function layoutPaintGraphics(ops)
  local graphics = { ops = ops, depth = 0, lineWidth = 1 }
  function graphics.setColor(red, green, blue, alpha)
    ops[#ops + 1] = { op = "color", red, green, blue, alpha }
  end
  function graphics.getColor()
    return 1, 1, 1, 1
  end
  function graphics.getLineWidth()
    return graphics.lineWidth
  end
  function graphics.setLineWidth(width)
    graphics.lineWidth = width
  end
  function graphics.rectangle(mode, x, y, width, height)
    ops[#ops + 1] = { op = "rect", mode, x, y, width, height }
  end
  function graphics.line(...)
    ops[#ops + 1] = { op = "line" }
  end
  function graphics.draw(...)
    ops[#ops + 1] = { op = "image" }
  end
  function graphics.push()
    graphics.depth = graphics.depth + 1
  end
  function graphics.pop()
    graphics.depth = graphics.depth - 1
  end
  function graphics.origin() end
  function graphics.intersectScissor(x, y, width, height)
    ops[#ops + 1] = { op = "scissor", x, y, width, height }
  end
  function graphics.translate(x, y) end
  function graphics.scale(x, y) end
  function graphics.transformPoint(x, y)
    return x, y
  end
  return graphics
end

local function layoutPaintText()
  local text = { fontDef = { lineHeight = 14 } }
  function text.textWidth(_, value)
    return #tostring(value) * 7
  end
  function text.drawTextWithPalette(_, _value, _x, _y, _palette) end
  return text
end

function T.tests.painting_follows_resolved_geometry_without_recomputing_layout()
  local view = {
    status = "ready",
    ready = true,
    dirty = true,
    section = "Player",
    scope = { id = "section:Player", epoch = 0 },
    focus = "save",
    focusVisible = true,
    session = { playerName = "PLAYER", money = 3000 },
  }
  local width, height = 640, 480
  local layout = computeLayout({
    status = view.status,
    ready = true,
    dirty = true,
    section = "Player",
    scope = view.scope,
    focus = "save",
    focusVisible = true,
    session = { playerName = "PLAYER", money = 3000, frameIndex = 0 },
  }, width, height)
  local saveRect = assert(layout.targets.save, "the footer publishes its save target").rect
  local plan = {
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
  local computeCalls = 0
  local originalCompute = Layout.compute
  Layout.compute = function(...)
    computeCalls = computeCalls + 1
    return originalCompute(...)
  end
  local firstOps, secondOps = {}, {}
  local ok, drawError = pcall(function()
    local renderer =
      Renderer.new({ text = layoutPaintText(), graphics = layoutPaintGraphics(firstOps), versionId = "heartgold" })
    renderer:draw(view, plan)
    renderer:dispose()
    saveRect.x = saveRect.x + 7
    local shifted =
      Renderer.new({ text = layoutPaintText(), graphics = layoutPaintGraphics(secondOps), versionId = "heartgold" })
    shifted:draw(view, plan)
    shifted:dispose()
  end)
  Layout.compute = originalCompute
  Assert.isTrue(ok, "painting the resolved footer succeeds: " .. tostring(drawError))
  Assert.equal(computeCalls, 0, "painting never recomputes geometry")
  Assert.isTrue(#firstOps > 0, "painting emits draw commands")
  local function hasFillAt(ops, x)
    for _, entry in ipairs(ops) do
      if entry.op == "rect" and entry[1] == "fill" and entry[2] == x then
        return true
      end
    end
    return false
  end
  Assert.isTrue(hasFillAt(firstOps, saveRect.x - 7), "the footer paints at its resolved save position")
  Assert.isTrue(hasFillAt(secondOps, saveRect.x), "the footer follows the resolved save rectangle")
  Assert.isFalse(hasFillAt(secondOps, saveRect.x - 7), "the footer does not repaint the old position")
end

function T.tests.layout_publishes_semantic_activation_actions()
  local controller = Controller.new()
  local layout = computeLayout({
    status = "ready",
    ready = true,
    dirty = false,
    sectionDirty = false,
    section = "Player",
    scope = controller:snapshot().scope,
    session = { playerName = "PLAYER", money = 3000, frameIndex = 0 },
  }, 800, 600)
  local actions = {}
  for _, control in ipairs(layout.focusNavigation.controls) do
    actions[control.id] = control.action
  end

  Assert.equal(actions["section:Party"].kind, "section.select", "section controls publish a section action")
  Assert.equal(actions["section:Party"].section, "Party", "section action carries its semantic value")
  Assert.equal(actions.money.kind, "player.edit-money", "money publishes a field action")
  Assert.isNil(actions.money.targetId, "activation does not require reparsing the target ID")
end

function T.tests.layout_publishes_value_and_decision_payloads_without_control_ids()
  local controller = Controller.new()
  local metrics = {
    lineHeight = 14,
    measure = function(text)
      return #text * 7
    end,
  }
  local numberView = {
    status = "ready",
    ready = true,
    dirty = false,
    sectionDirty = false,
    section = "Player",
    scope = { id = "value:test", epoch = 1, kind = "value" },
    session = { playerName = "PLAYER", money = 3000, frameIndex = 0 },
    valueEditor = ValueEditor.new({ kind = "integer", value = 12, min = 0, max = 99, base = "decimal" }):snapshot(),
    numberControlVisuals = { increment = { normal = { width = 8, height = 8 } } },
  }
  local numberLayout = Layout.compute(numberView, 640, 480, metrics)
  local actions = {}
  for _, control in ipairs(numberLayout.focusNavigation.controls) do
    actions[control.id] = control.action
  end
  Assert.equal(actions["number:place:1:up"].kind, "value.adjust-number-place")
  Assert.equal(actions["number:place:1:up"].place, 1)
  Assert.equal(actions["number:place:1:up"].direction, "up")
  Assert.isNil(actions["number:place:1:up"].controlId)

  local decisionView = {
    status = "ready",
    ready = true,
    dirty = false,
    sectionDirty = false,
    section = "Player",
    scope = { id = "decision:test", epoch = 1, kind = "decision" },
    session = { playerName = "PLAYER", money = 3000, frameIndex = 0 },
    modal = "party-move",
  }
  local decisionLayout = Layout.compute(decisionView, 640, 480, metrics)
  actions = {}
  for _, control in ipairs(decisionLayout.focusNavigation.controls) do
    actions[control.id] = control.action
  end
  Assert.equal(actions["party-move:pp"].kind, "decision.edit-move-pp")
  Assert.equal(actions["party-move:pp"].decision, "party-move")
  Assert.isNil(actions["party-move:pp"].controlId)
  Assert.equal(actions.cancel.kind, "decision.cancel")
  Assert.equal(actions.cancel.decision, "party-move")
end

function T.tests.editor_chrome_is_compact_and_keeps_targets_inside_every_page()
  local metrics = {
    lineHeight = 14,
    measure = function(text)
      return #text * 7
    end,
  }
  local mapList = locationView()
  local pages = {
    { name = "Player", section = "Player", view = sectionStripView("Player") },
    { name = "Map", section = "Location", view = mapList },
    { name = "Progress", section = "Progress", view = progressFilterView(progressFilterFlags(), "") },
    { name = "Party", section = "Party", view = partyEditorView("Stats") },
    { name = "Bag", section = "Bag", view = sectionStripView("Bag") },
  }
  local sizes = {
    { width = 256, height = 192, compact = true },
    { width = 360, height = 640, compact = true },
    { width = 400, height = 300, compact = false },
  }

  for _, page in ipairs(pages) do
    for _, size in ipairs(sizes) do
      local layout = computeLayout(page.view, size.width, size.height)
      local activeSection = assert(layout.targets["section:" .. page.section])
      local sectionRect = activeSection.rect
      local glyphHeight = math.ceil(metrics.lineHeight * 0.75)
      local minButtonHeight = glyphHeight + 8
      if size.compact then
        Assert.isTrue(sectionRect.y >= 4, page.name .. " section strip has a visible outer top inset")
        Assert.isTrue(
          sectionRect.height >= minButtonHeight,
          page.name .. " section label keeps measured glyph clearance"
        )
        Assert.isTrue(sectionRect.height <= metrics.lineHeight + 8, page.name .. " section strip uses compact padding")
        Assert.isTrue(
          layout.content.y >= sectionRect.y + sectionRect.height + 2,
          page.name .. " content starts below the visible section strip"
        )
      else
        Assert.isTrue(sectionRect.height >= minButtonHeight, page.name .. " rail label keeps measured glyph clearance")
        Assert.isTrue(sectionRect.height <= metrics.lineHeight + 16, page.name .. " wide rail button is height-capped")
      end

      Assert.isTrue(layout.footer.height <= 32, page.name .. " footer returns height to the content viewport")
      Assert.isTrue(
        layout.content.y + layout.content.height <= layout.footer.y,
        page.name .. " content does not overlap the footer"
      )
      for _, action in ipairs(layout.actions) do
        local rect = assert(layout.targets[action.id]).rect
        Assert.isTrue(
          rect.height >= minButtonHeight,
          page.name .. " " .. action.label .. " keeps measured glyph clearance"
        )
        Assert.isTrue(
          rect.height <= metrics.lineHeight + 10,
          page.name .. " " .. action.label .. " uses compact vertical padding"
        )
        Assert.isTrue(
          rect.y + rect.height <= size.height,
          page.name .. " " .. action.label .. " stays within the viewport"
        )
      end
    end
  end
end

function T.tests.decision_actions_use_measured_rows_and_keep_back_last()
  local metrics = filterMetrics()
  local cases = {
    {
      kind = "remove",
      section = "Player",
      ids = { "remove", "cancel" },
      labels = { "Remove", "Back" },
    },
    {
      kind = "bag-item",
      section = "Player",
      ids = { "bag:quantity", "bag:remove", "cancel" },
      labels = { "Quantity", "Remove", "Back" },
    },
    {
      kind = "leave",
      section = "Player",
      ids = { "save", "discard", "cancel" },
      labels = { "Save & exit", "Discard all", "Cancel" },
    },
    {
      kind = "party-move",
      section = "Party",
      ids = { "party-move:move", "party-move:pp", "party-move:pp-ups", "cancel" },
      labels = { "Move", "Current PP", "PP Ups", "Back" },
    },
  }

  for _, case in ipairs(cases) do
    for _, size in ipairs({
      { width = 256, height = 192 },
      { width = 400, height = 300 },
      { width = 800, height = 600 },
    }) do
      local view = case.section == "Party" and partyEditorView("Moves") or sectionStripView("Player")
      view.section = case.section
      view.modal = case.kind
      view.scope = { id = "decision:" .. case.kind, epoch = 1, kind = "decision", focusId = case.ids[1] }
      local layout = Layout.compute(view, size.width, size.height, metrics)
      local decision = assert(layout.decisionList, case.kind .. " publishes its action surface")
      Assert.equal(#decision.rows, #case.ids, case.kind .. " retains every semantic action")
      local resolved = ListSurface.resolve({
        bounds = decision.surface,
        rowCount = 0,
        rowHeight = 1,
        gap = 0,
        maxWidth = decision.surface.width,
      })

      local previous
      for index, targetId in ipairs(case.ids) do
        local row = assert(decision.rows[index])
        Assert.equal(row.targetId, targetId, case.kind .. " retains semantic action order")
        local rect = row.rect
        Assert.isTrue(rect.x >= decision.surface.x and rect.y >= decision.surface.y)
        Assert.isTrue(rect.x + rect.width <= decision.surface.x + decision.surface.width)
        Assert.isTrue(rect.y + rect.height <= decision.surface.y + decision.surface.height)
        Assert.isTrue(rect.x >= resolved.content.x, targetId .. " clears the padded left edge")
        Assert.isTrue(rect.y >= resolved.content.y, targetId .. " clears the padded top edge")
        Assert.isTrue(
          rect.x + rect.width <= resolved.content.x + resolved.content.width,
          targetId .. " clears the padded right edge"
        )
        Assert.isTrue(
          rect.y + rect.height <= resolved.content.y + resolved.content.height,
          targetId .. " clears the padded bottom edge"
        )
        local target = assert(layout.targets[targetId], case.kind .. " publishes the action hit rectangle")
        Assert.equal(target.rect.x, rect.x, targetId .. " draws and hits the same horizontal bound")
        Assert.equal(target.rect.y, rect.y, targetId .. " draws and hits the same vertical bound")
        Assert.equal(target.rect.width, rect.width, targetId .. " shares its painted and hit width")
        Assert.equal(target.rect.height, rect.height, targetId .. " shares its painted and hit height")
        Assert.equal(
          Layout.hitTest(layout, view, rect.x + rect.width / 2, rect.y + rect.height / 2),
          targetId,
          targetId .. " center remains an actionable hit target"
        )
        if previous ~= nil and #case.ids <= 3 then
          Assert.equal(rect.y, previous.y, case.kind .. " places up to three actions in one row")
          Assert.isTrue(rect.x >= previous.x + previous.width + 4, case.kind .. " keeps a visible horizontal gap")
        end
        if previous ~= nil and #case.ids == 4 and index == 2 then
          Assert.equal(rect.y, previous.y, "Party Move places the first two actions in row one")
          Assert.isTrue(rect.x >= previous.x + previous.width + 4, "Party Move keeps a gap within row one")
        elseif previous ~= nil and #case.ids == 4 and index == 3 then
          Assert.isTrue(rect.y > previous.y, "Party Move starts its second row below row one")
        elseif previous ~= nil and #case.ids == 4 and index == 4 then
          Assert.equal(rect.y, previous.y, "Party Move places the final two actions in row two")
          Assert.isTrue(rect.x >= previous.x + previous.width + 4, "Party Move keeps a gap within row two")
        end
        if size.width > 256 then
          Assert.isTrue(
            rect.width >= metrics.measure(case.labels[index]) + 16,
            targetId .. " reserves measured label width and insets"
          )
        end
        Assert.equal(row.label, case.labels[index], case.kind .. " " .. targetId .. " has the intended label")
        previous = rect
      end
      local last = assert(decision.rows[#decision.rows]).rect
      local first = assert(decision.rows[1]).rect
      if #case.ids <= 3 then
        Assert.isTrue(last.x > first.x, case.kind .. " places Back/Cancel last at the right")
      else
        Assert.isTrue(last.y > first.y, "Party Move places Back on the bottom row")
        Assert.isTrue(last.x > assert(decision.rows[3]).rect.x, "Party Move places Back in the bottom-right cell")
      end
    end
  end

  local view = partyEditorView("Moves")
  view.section = "Party"
  view.modal = "party-move"
  view.scope = { id = "decision:party-move", epoch = 1, kind = "decision", focusId = "party-move:move" }
  local layout = Layout.compute(view, 640, 480, metrics)
  local controller = Controller.new()
  controller:setSection("Party")
  controller:setFocus("party-move:move")
  navigate(controller, layout, "right")
  Assert.equal(controller.focus, "party-move:pp", "right moves across the first modal row")
  navigate(controller, layout, "down")
  Assert.equal(controller.focus, "cancel", "down enters the bottom-right Back action")
  navigate(controller, layout, "left")
  Assert.equal(controller.focus, "party-move:pp-ups", "left moves across the bottom modal row")
  navigate(controller, layout, "up")
  Assert.equal(controller.focus, "party-move:move", "up returns to the top-left action")
end

function T.tests.party_move_actions_follow_a_two_by_two_navigation_grid()
  local metrics = filterMetrics()
  local view = partyEditorView("Moves")
  view.section = "Party"
  view.modal = "party-move"
  view.scope = { id = "decision:party-move", epoch = 1, kind = "decision", focusId = "party-move:move" }
  local layout = Layout.compute(view, 640, 480, metrics)
  local rows = assert(layout.decisionList).rows
  local move = assert(rows[1]).rect
  local currentPp = assert(rows[2]).rect
  local ppUps = assert(rows[3]).rect
  local back = assert(rows[4]).rect
  Assert.equal(rows[1].targetId, "party-move:move")
  Assert.equal(rows[2].targetId, "party-move:pp")
  Assert.equal(rows[3].targetId, "party-move:pp-ups")
  Assert.equal(rows[4].targetId, "cancel", "Back preserves the typed cancel action ID")
  Assert.equal(move.y, currentPp.y, "Move and Current PP share the top row")
  Assert.isTrue(move.x < currentPp.x, "Current PP is to the right of Move")
  Assert.isTrue(ppUps.y > move.y, "PP Ups starts the lower row")
  Assert.equal(ppUps.y, back.y, "PP Ups and Back share the lower row")
  Assert.isTrue(ppUps.x < back.x, "Back is the bottom-right action")

  local controller = Controller.new()
  controller:setSection("Party")
  controller:setFocus("party-move:move")
  navigate(controller, layout, "right")
  Assert.equal(controller.focus, "party-move:pp", "right moves within the top row")
  navigate(controller, layout, "down")
  Assert.equal(controller.focus, "cancel", "down enters Back from Current PP")
  navigate(controller, layout, "left")
  Assert.equal(controller.focus, "party-move:pp-ups", "left moves within the bottom row")
  navigate(controller, layout, "up")
  Assert.equal(controller.focus, "party-move:move", "up returns to Move from PP Ups")
end

function T.tests.resize_publishes_before_the_next_draw_without_resolving_in_draw()
  local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
  local FieldInput = require("libs.hgss.src.field.FieldInput")
  local ModalStack = require("app.src.saveeditor.SaveEditorModalStack")
  local controller = Controller.new()
  controller:setSection("Player")
  local snapshots, resolves = 0, 0
  local stateHolder = {}
  local state = setmetatable({
    status = "ready",
    width = 800,
    height = 600,
    controller = controller,
    modalStack = ModalStack.new(),
    fieldInput = FieldInput.new(),
    scopeEpoch = 0,
    inputTick = 0,
    session = nil,
    presentation = { cancelPointers = function() end },
    renderer = { graphics = {}, text = {} },
    _snapshot = function()
      snapshots = snapshots + 1
      return { section = "Player", width = stateHolder.state.width }
    end,
    _resolve = function()
      resolves = resolves + 1
      return { content = { layout = { width = stateHolder.state.width } } }
    end,
  }, SaveEditorState)
  stateHolder.state = state
  state:_syncScope()
  local published = state:view()
  Assert.equal(published.width, 800, "the observation publishes the opening measurement")
  snapshots, resolves = 0, 0
  state:resize(1024, 600)
  Assert.equal(resolves, 1, "resize publishes the new measurement in the same turn")
  snapshots, resolves = 0, 0
  local drawnView = nil
  local originalDraw = ApplicationPresentation.draw
  ApplicationPresentation.draw = function(_, _, view)
    drawnView = view
  end
  local ok, drawError = pcall(function()
    state:draw()
  end)
  ApplicationPresentation.draw = originalDraw
  Assert.isTrue(ok, "draw runs without platform rendering: " .. tostring(drawError))
  Assert.isTrue(drawnView ~= nil, "draw renders the settled publication")
  Assert.equal(drawnView.width, 1024, "the next draw shows the resized measurement without another update")
  Assert.equal(drawnView.layout.width, 1024, "the drawn layout matches the resized measurement")
  Assert.equal(snapshots, 0, "the draw performs no fresh snapshot")
  Assert.equal(resolves, 0, "the draw performs no fresh resolve")
end

return T
