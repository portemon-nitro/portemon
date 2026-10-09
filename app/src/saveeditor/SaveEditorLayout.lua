-- Computes the editor's canonical logical rows and hit targets.

local Layout = {}
local Decisions = require("app.src.saveeditor.SaveEditorDecisions")
local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local PixelScale = require("libs.ui.src.PixelScale")
local ScrollViewport = require("libs.ui.src.ScrollViewport")
local ListSurface = require("libs.ui.src.ListSurface")
local SaveEditorCard = require("app.src.saveeditor.SaveEditorCard")
local SaveEditorNumberLayout = require("app.src.saveeditor.SaveEditorNumberLayout")

local BAG_ICON_SIZE_COMPACT = 16
local BAG_ICON_SIZE_EXPANDED = 24

local LOCATION_REASONS = {
  blocked = "Impassable tile",
  wrong_logical_map = "Another map",
  no_surface = "No walkable surface",
  ambiguous_surface = "Ambiguous surface",
  possible_actor = "Possible actor",
  actor_motion_active = "Actor in motion",
  outside_map = "Outside map",
  warp = "Warp destination",
  coordinate_trigger = "Event tile",
  special_terrain = "Special terrain",
}

local function makeViewport(clip, offset, contentExtent, rowExtent, gap, count, rowTargets)
  local firstIndex, lastIndex = ScrollViewport.visibleRange(offset, clip.height, rowExtent, gap, count)
  return {
    clip = clip,
    offset = offset,
    contentExtent = contentExtent,
    rowExtent = rowExtent,
    gap = gap,
    firstIndex = firstIndex,
    lastIndex = lastIndex,
    rowTargets = rowTargets,
  }
end

local function rect(x, y, width, height)
  return { x = x, y = y, width = math.max(1, width), height = math.max(1, height) }
end

-- Compact list rows stay visually distinct from roomy form and action controls.
-- Native glyphs fit with a small inset; rows grow only when font metrics require it.
local function listRowExtent(metrics)
  return math.max(18, math.ceil(metrics.lineHeight + 4))
end

function Layout.preferredListWidth(view, metrics, height)
  local projection, trailingValueWidth
  if view.valueEditor ~= nil and view.valueEditor.kind == "choice" then
    projection = view.valueEditor
  elseif
    view.section == "Location"
    and view.location ~= nil
    and view.locationNavigation ~= nil
    and (view.locationNavigation.page == "root" or view.locationNavigation.page == "group")
  then
    projection = assert(view.location.mapModel, "Map list sizing uses its indexed projection")
  elseif view.section == "Progress" then
    projection = assert(view.flagModel, "Flags list sizing uses its indexed projection")
    trailingValueWidth = metrics.measure("OFF")
  end
  if projection == nil then
    return nil
  end
  local rowAt = assert(projection.rowAt, "list sizing reads its bounded row projection")
  local rowHeight = listRowExtent(metrics)
  local query = projection.query or view.query or ""
  local filterText = projection.pending and "Filtering…" or query == "" and "Type to filter" or ("Filter: " .. query)
  local hintText = view.section == "Location"
      and view.location
      and view.location.breadcrumb
      and (view.location.breadcrumb .. "  ·  " .. filterText)
    or filterText
  local preferredWidth, measuredTrailingValueWidth = ListSurface.preferredWidth({
    bounds = { x = 0, y = 0, width = 640, height = height },
    rowCount = projection.count,
    rowHeight = rowHeight,
    gap = 0,
    headerHeight = metrics.lineHeight,
    hasTrailingValue = trailingValueWidth ~= nil,
    trailingValueWidth = trailingValueWidth,
    minimumLabelWidth = metrics.measure(hintText),
    font = { lineHeight = metrics.lineHeight, measure = metrics.measure },
    textScale = PixelScale.assertInteger(1),
    rowAt = function(index)
      local row = assert(rowAt(index), "sampled list rows remain in the current projection")
      local value = trailingValueWidth ~= nil and (row.value and "ON" or "OFF") or nil
      return { label = row.displayName or row.label or row.name, value = value }
    end,
  })
  if view.section == "Location" then
    preferredWidth = math.max(preferredWidth, math.ceil(metrics.measure(hintText) + 16))
  end
  return preferredWidth, measuredTrailingValueWidth
end

function Layout.minimumListCanvasWidth(view, metrics, height)
  local bodyGlyphHeight = math.ceil(metrics.lineHeight)
  local contentTop = 4 + bodyGlyphHeight + 8 + 2
  if view.section == "Location" or view.section == "Progress" then
    contentTop = contentTop + ApplicationLayout.applicationFrameInsets().top + 8
  end
  local bodyHeight = math.max(1, height - bodyGlyphHeight - 12 - 2 - contentTop)
  if view.valueEditor ~= nil and view.valueEditor.kind == "choice" then
    bodyHeight = math.max(1, bodyHeight - 40)
  end
  local listWidth = Layout.preferredListWidth(view, metrics, bodyHeight)
  if listWidth == nil then
    return nil
  end
  local stripWidth = 0
  for _, label in ipairs({ "Map", "Player", "Party", "Bag", "Flags" }) do
    stripWidth = stripWidth + metrics.measure(label) + 8
  end
  local actionWidth = 8
  for _, label in ipairs({ "Save", "Discard", view.locationSave and "Cancel check" or "Back" }) do
    actionWidth = actionWidth + math.max(40, metrics.measure(label) + 24)
  end
  return math.min(256, math.max(listWidth, stripWidth, actionWidth) + 16)
end

local function locationReason(reason)
  assert(type(reason) == "string" and reason ~= "", "unavailable tiles carry a policy reason")
  return LOCATION_REASONS[reason] or reason:gsub("_", " ")
end

local function activationAction(view, targetId)
  local section = targetId:match("^section:(.+)$")
  if section ~= nil then
    return { kind = "section.select", section = section }
  end
  if view.valueEditor ~= nil and view.modal == nil then
    local editor = view.valueEditor
    if targetId == "confirm" then
      return { kind = "value.confirm" }
    elseif targetId == "cancel" then
      return { kind = "value.cancel" }
    end
    local place, direction = targetId:match("^number:place:(%d+):([^:]+)$")
    if place ~= nil then
      assert(direction == "up" or direction == "down")
      return { kind = "value.adjust-number-place", place = tonumber(place), direction = direction }
    end
    local choiceKey = targetId:match("^choice:(.+)$")
    if choiceKey ~= nil then
      return { kind = "value.choose-option", key = choiceKey }
    end
    local nameControl = targetId:match("^name%-control:(.+)$")
    if nameControl ~= nil then
      return { kind = "value.activate-name-control", control = nameControl }
    end
    local row, column = targetId:match("^(%d+):(%d+)$")
    if row ~= nil then
      return { kind = "value.activate-name-key", row = tonumber(row), column = tonumber(column) }
    end
    if targetId == "page-next" or targetId == "page-previous" then
      return { kind = "value.change-page", direction = targetId == "page-next" and "next" or "previous" }
    end
    local digit = targetId:match("^digit%-(.+)$")
    if digit ~= nil then
      return { kind = "value.press", key = digit }
    end
    if editor.kind == "choice" and targetId == "list:value:choice" then
      return { kind = "value.focus-choice-list" }
    end
    return activationAction({ section = view.section }, targetId)
  elseif view.modal ~= nil then
    for _, action in
      ipairs(view.decisionActions or Decisions.describe(view.modal, { pendingSave = view.locationSave ~= nil }))
    do
      if action.id == targetId then
        local actionKind = action.command == "cancel" and "cancel"
          or action.command == "bag_quantity" and "edit-bag-quantity"
          or action.command == "bag_remove" and "remove-bag-item"
          or action.command == "party-move:move" and "edit-move"
          or action.command == "party-move:pp" and "edit-move-pp"
          or action.command == "party-move:pp-ups" and "edit-move-pp-ups"
          or action.command == "confirm_remove" and "confirm-remove"
          or action.command == "save" and "save-and-exit"
          or action.command == "cancel_pending_save" and "save-and-exit"
          or action.command == "discard" and "discard-and-exit"
        assert(type(actionKind) == "string", "decision command has a focus action")
        return { kind = "decision." .. actionKind, decision = view.modal, command = action.command, id = action.id }
      end
    end
    return activationAction({ section = view.section }, targetId)
  end
  if view.status == "error" then
    if targetId == "retry" then
      return { kind = "editor.retry-open" }
    elseif targetId == "back" then
      return { kind = "editor.close-open-error" }
    end
  end
  if targetId == "money" then
    return { kind = "player.edit-money" }
  elseif targetId == "dialogue-frame" then
    return { kind = "player.edit-dialogue-frame" }
  elseif targetId:match("^flag:") then
    return { kind = "progress.toggle-flag", name = targetId:sub(6) }
  elseif targetId == "save" then
    return { kind = "editor.save" }
  elseif targetId == "discard" then
    return { kind = "editor.discard" }
  elseif targetId == "back" then
    return { kind = "editor.back" }
  end

  if targetId == "location:grid" then
    return { kind = "location.select-current-tile" }
  end
  local fieldX, fieldZ = targetId:match("^location:tile:(%-?%d+):(%-?%d+)$")
  if fieldX ~= nil then
    return { kind = "location.select-tile", fieldX = tonumber(fieldX), fieldZ = tonumber(fieldZ) }
  end
  local groupId = targetId:match("^location:group:(.+)$")
  if groupId ~= nil then
    return { kind = "location.select-group", groupId = targetId }
  end
  local mapId = targetId:match("^location:map:(%d+)$")
  if mapId ~= nil then
    return { kind = "location.select-map", mapId = tonumber(mapId) }
  end
  local slot0 = targetId:match("^party:slot:(%d+)$")
  if slot0 ~= nil then
    return { kind = "party.select-slot", slot0 = tonumber(slot0) }
  end
  local moveIndex = targetId:match("^party:move:(%d+)$")
  if moveIndex ~= nil then
    return { kind = "party.edit-move", moveIndex = tonumber(moveIndex) }
  end
  local pocket = targetId:match("^bag:pocket:(.+)$")
  if pocket ~= nil then
    return { kind = "bag.select-pocket", pocket = pocket }
  end
  local itemKey = targetId:match("^bag:item:(.+)$")
  if itemKey ~= nil then
    return { kind = "bag.select-item", itemKey = itemKey }
  end
  if targetId == "party:add" then
    return { kind = "party.add-member" }
  elseif targetId == "party:page:previous" or targetId == "party:page:next" then
    return { kind = "party.change-page", direction = targetId:match("previous$") and "previous" or "next" }
  elseif targetId == "party:use-species-name" then
    return { kind = "party.use-species-name" }
  elseif targetId == "party:move:add" then
    return { kind = "party.add-move" }
  elseif targetId == "bag:page:previous" or targetId == "bag:page:next" then
    return { kind = "bag.change-page", direction = targetId:match("previous$") and "previous" or "next" }
  elseif targetId == "bag:add" then
    return { kind = "bag.add-item" }
  elseif targetId == "bag:quantity" then
    return { kind = "bag.edit-quantity" }
  elseif targetId == "bag:remove" then
    return { kind = "bag.remove-item" }
  end
  local fieldId = targetId:match("^party:field:(.+)$")
  if fieldId ~= nil then
    return { kind = "party.edit-field", fieldId = fieldId }
  end
  if targetId:match("^list:") then
    return { kind = "list.inert" }
  end
  error("unmapped Save Editor activation control: " .. targetId, 2)
end

-- One compute invocation owns a single context holding shell metrics, geometry
-- accumulators and bounded target/list builders. The context is created fresh
-- per call and discarded with its plan; settled views and measurements are
-- borrowed read-only and never mutated.
local function newContext(view, width, height, metrics)
  assert(type(view) == "table" and width > 0 and height > 0)
  local scope = view.scope
    or {
      id = view.modal and "decision:" .. view.modal or view.valueEditor and "value:editor" or "section:" .. tostring(
        view.section or "Player"
      ),
      epoch = 0,
      kind = view.modal and "decision" or view.valueEditor and "value" or "section",
    }
  assert(type(metrics) == "table" and type(metrics.measure) == "function" and metrics.lineHeight > 0)
  local wideShell = width >= 400 and width >= height
  local margin = width <= 280 and 8 or wideShell and 8 or 12
  local bodyGlyphHeight = math.ceil(metrics.lineHeight)
  local footerHeight = bodyGlyphHeight + 12
  local hasRail = wideShell
  local railWidth = hasRail and 88 or 0
  local railButtonHeight = math.min(bodyGlyphHeight + 12, metrics.lineHeight + 16)
  local railStep = railButtonHeight + 4
  if railWidth > 0 and height >= 360 then
    railButtonHeight, railStep = 56, 60
  end
  local shellWidth = hasRail and math.min(width - margin * 2, 640) or width
  local shellX = hasRail and PixelScale.snapLogical((width - shellWidth) / 2) or 0
  local railGap = hasRail and 12 or 0
  local contentWidth = hasRail and math.min(384, width - margin * 2 - railWidth - railGap) or shellWidth - margin * 2
  local minContentX = hasRail and margin + railWidth + railGap or margin
  local desiredContentX = hasRail and PixelScale.snapLogical((width - contentWidth) / 2) or shellX + margin
  local maxContentX = width - margin - contentWidth
  local contentX = math.max(minContentX, math.min(desiredContentX, maxContentX))
  local innerWidth = math.max(1, contentWidth)
  local railX = contentX - railGap - railWidth
  local contentTop = margin
  local footerReserve = view.modal ~= nil and (margin + 2) or footerHeight
  local contentBottom = math.max(contentTop + 1, height - footerReserve - 2)
  local listHeight = math.max(1, contentBottom - contentTop)
  local listMeasurementHeight = listHeight
  if
    view.section == "Progress"
    or view.section == "Location"
      and view.locationNavigation ~= nil
      and (view.locationNavigation.page == "root" or view.locationNavigation.page == "group")
  then
    listMeasurementHeight =
      math.max(1, listMeasurementHeight - ApplicationLayout.applicationFrameInsets().top - 8 - listRowExtent(metrics))
  end
  local preferredListWidth, measuredTrailingValueWidth = Layout.preferredListWidth(view, metrics, listMeasurementHeight)
  return {
    view = view,
    width = width,
    height = height,
    metrics = metrics,
    scope = scope,
    margin = margin,
    compactBag = width <= 280 and view.section == "Bag",
    footerHeight = footerHeight,
    bodyGlyphHeight = bodyGlyphHeight,
    preferredListWidth = preferredListWidth,
    measuredTrailingValueWidth = measuredTrailingValueWidth,
    railWidth = railWidth,
    railButtonHeight = railButtonHeight,
    railStep = railStep,
    railX = railX,
    rows = {},
    targets = {},
    focusable = {},
    disabledTargets = {},
    focusPositions = {},
    locationGrid = nil,
    locationFocusCue = nil,
    valueModal = nil,
    valueModalValue = nil,
    valueModalError = nil,
    valueModalNotice = nil,
    numberLayout = nil,
    numberTooSmall = false,
    choiceTooSmall = false,
    decisionList = nil,
    locationHeader = nil,
    bagGrid = nil,
    bagTabs = nil,
    bagStripTarget = nil,
    bagPageTextRect = nil,
    listSurfaces = {},
    partyStatsTable = nil,
    partyStrip = nil,
    partyMoves = nil,
    revealByTarget = {},
    partyPageLabel = nil,
    focusableSet = {},
    rowMarkers = {},
    rowMarkerRadii = {},
    rowLabelRects = {},
    shellWidth = shellWidth,
    shellX = shellX,
    shell = rect(shellX, 0, shellWidth, height),
    innerWidth = innerWidth,
    contentX = contentX,
    contentTop = contentTop,
    contentBottom = contentBottom,
    section = view.section or "Player",
    rowHeight = math.max(30, metrics.lineHeight + 16),
    compactRowExtent = listRowExtent(metrics),
    enabledSections = { "Location", "Player", "Party", "Bag", "Progress" },
    navigation = {},
    viewports = {},
    lists = {},
    listRowRoles = {},
    containerClips = {},
    actions = {},
    decisionActions = nil,
    focusGraph = {},
    fixedFocusable = {},
    listTargets = {},
    viewportByTarget = {},
    roleById = {},
    focusOrder = {},
  }
end

local function addFocusable(ctx, targetId)
  if not ctx.focusableSet[targetId] then
    ctx.focusableSet[targetId] = true
    ctx.focusable[#ctx.focusable + 1] = targetId
  end
end

local function addRow(ctx, role, id, label, value, enabled)
  local contentTop, contentBottom, contentX, innerWidth, rowHeight =
    ctx.contentTop, ctx.contentBottom, ctx.contentX, ctx.innerWidth, ctx.rowHeight
  local y = contentTop + (#ctx.rows * rowHeight)
  if y + rowHeight > contentBottom then
    return
  end
  local rowRect = rect(contentX, y, innerWidth, rowHeight - 2)
  local row = { role = role, targetId = id, id = id, label = label, value = value, enabled = enabled ~= false }
  ctx.rows[#ctx.rows + 1] = row
  ctx.targets[id] = rowRect
  if
    role == "action"
    or role == "toggle"
    or role == "integer value"
    or role == "named choice"
    or id:match("^party:slot:")
    or id:match("^bag:item:")
  then
    addFocusable(ctx, id)
  end
  if enabled == false then
    ctx.disabledTargets[id] = true
  end
  if id:match("^party:empty%-slot:") then
    ctx.disabledTargets[id] = true
  end
end

local function placeRow(ctx, role, id, label, value, enabled, y, rowExtent)
  local contentX, innerWidth = ctx.contentX, ctx.innerWidth
  local rowRect = rect(contentX, y, innerWidth, rowExtent - 2)
  ctx.rows[#ctx.rows + 1] =
    { role = role, targetId = id, id = id, label = label, value = value, enabled = enabled ~= false }
  ctx.targets[id] = rowRect
  if
    role == "action"
    or role == "toggle"
    or role == "integer value"
    or role == "named choice"
    or id:match("^party:slot:")
    or id:match("^bag:item:")
  then
    addFocusable(ctx, id)
  end
  if enabled == false or id:match("^party:empty%-slot:") then
    ctx.disabledTargets[id] = true
  end
end

local function registerList(ctx, id, viewportId, resolved, rowTargets, query, indexByTarget)
  local content, header = resolved.content, resolved.header
  local rowClip = rect(content.x, content.y + header.height, content.width, math.max(1, content.height - header.height))
  ctx.lists[id] = {
    id = id,
    targetId = "list:" .. id,
    viewportId = viewportId,
    -- The logical order is owned by the cached data owner and shared by
    -- reference; only visible rows below gain geometry and focus records.
    rowTargets = rowTargets,
    indexByTarget = indexByTarget,
    cursorTarget = ctx.view.listCursors and ctx.view.listCursors[id] or nil,
    filterable = true,
    query = query or "",
    empty = #rowTargets == 0,
    surfaceRect = resolved.surface,
    hintRect = { x = header.x, y = header.y, width = header.width, height = header.height },
  }
  local targetId = "list:" .. id
  ctx.targets[targetId] = rect(resolved.surface.x, resolved.surface.y, resolved.surface.width, resolved.surface.height)
  ctx.focusPositions[targetId] = ctx.targets[targetId]
  ctx.containerClips[targetId] = rowClip
  addFocusable(ctx, targetId)
  return rowClip
end

local function buildShell(ctx)
  local railWidth, railButtonHeight, railStep = ctx.railWidth, ctx.railButtonHeight, ctx.railStep
  local bodyGlyphHeight = ctx.bodyGlyphHeight
  local margin, innerWidth, contentX = ctx.margin, ctx.innerWidth, ctx.contentX
  local sectionLabels = { Location = "Map", Progress = "Flags" }
  if railWidth > 0 then
    for index, name in ipairs(ctx.enabledSections) do
      local id = "section:" .. name
      ctx.targets[id] = rect(ctx.railX, margin + (index - 1) * railStep, railWidth, railButtonHeight)
      ctx.navigation[#ctx.navigation + 1] =
        { role = "action", targetId = id, id = id, label = sectionLabels[name] or name, active = name == ctx.section }
      addFocusable(ctx, id)
    end
  else
    local stripHeight = bodyGlyphHeight + 8
    local stripY = 4
    local cellWidth = innerWidth / #ctx.enabledSections
    for index, name in ipairs(ctx.enabledSections) do
      local id = "section:" .. name
      ctx.targets[id] = rect(contentX + (index - 1) * cellWidth, stripY, cellWidth, stripHeight)
      ctx.navigation[#ctx.navigation + 1] =
        { role = "action", targetId = id, id = id, label = sectionLabels[name] or name, active = name == ctx.section }
      addFocusable(ctx, id)
    end
    ctx.contentTop = stripY + stripHeight + 2
    if
      ctx.section == "Progress"
      or ctx.section == "Location"
        and (ctx.view.locationNavigation.page == "root" or ctx.view.locationNavigation.page == "group")
    then
      ctx.contentTop = ctx.contentTop + ApplicationLayout.applicationFrameInsets().top + 8
    end
  end
end

local function buildNoticeRows(ctx)
  local view = ctx.view
  if view.notice then
    addRow(ctx, "warning", "notice", view.notice, nil)
  end
  if view.errorMessage and view.status == "ready" then
    addRow(ctx, "warning", "error-notice", view.errorMessage, nil)
  end
end

local function buildOpening(ctx)
  local view = ctx.view
  addRow(ctx, "read-only value", "opening", "Preparing save editor", view.message or "Waiting for field data")
end

local function buildErrorStatus(ctx)
  local view = ctx.view
  addRow(ctx, "warning", "error", "Save unavailable", view.message or "Could not open save")
  addRow(ctx, "action", "retry", "Retry", "", true)
end

local function buildLocationMapList(ctx)
  local view = ctx.view
  local contentX, contentTop, contentBottom, innerWidth =
    ctx.contentX, ctx.contentTop, ctx.contentBottom, ctx.innerWidth
  local metrics, compactRowExtent = ctx.metrics, ctx.compactRowExtent
  local location = assert(view.location, "Location needs the headless service snapshot")
  local locationNav = assert(view.locationNavigation, "Location needs controller navigation state")
  local mapModel = assert(location.mapModel, "Location needs its indexed map projection")
  local listId = assert(location.mapListId, "hierarchy list has a stable page identity")
  local mapRowTargets = mapModel.rowTargets
  local storedMapOffset = locationNav.mapOffset or 0
  local mapBounds = rect(contentX, contentTop, innerWidth, math.max(1, contentBottom - contentTop))
  local mapList = ListSurface.resolve({
    bounds = mapBounds,
    rowCount = mapModel.count,
    rowHeight = compactRowExtent,
    gap = 0,
    maxWidth = innerWidth,
    headerHeight = metrics.lineHeight,
    scrollOffset = storedMapOffset,
    font = { lineHeight = metrics.lineHeight, measure = metrics.measure },
  })
  local mapOffset =
    ScrollViewport.clamp(storedMapOffset, mapList.contentHeight, mapList.content.height - mapList.header.height)
  ctx.listSurfaces[#ctx.listSurfaces + 1] = mapList.surface
  local mapViewport = registerList(ctx, listId, listId, mapList, mapRowTargets, view.query, mapModel.indexByTarget)
  ctx.lists[listId].pending = mapModel.pending
  local mapScroll =
    makeViewport(mapViewport, mapOffset, mapList.contentHeight, compactRowExtent, 0, mapModel.count, mapRowTargets)
  mapScroll.visibleTargets = {}
  ctx.lists[listId].breadcrumb = location.breadcrumb
  ctx.viewports[listId] = mapScroll
  for _, row in ipairs(mapList.rows) do
    local map = assert(mapModel.rowAt(row.index), "visible map rows resolve to their logical payload")
    local id = assert(mapModel.idAt(row.index), "visible map rows keep their logical identity")
    ctx.listRowRoles[id] = "list"
    local y = row.rect.y - mapOffset
    ctx.targets[id] = rect(row.rect.x, y, row.rect.width, compactRowExtent - 2)
    ctx.rowMarkers[id] =
      rect(row.markerRect.x, row.markerRect.y - mapOffset, row.markerRect.width, row.markerRect.height)
    ctx.rowMarkerRadii[id] = row.markerRadius
    ctx.rowLabelRects[id] =
      rect(row.labelRect.x, row.labelRect.y - mapOffset, row.labelRect.width, row.labelRect.height)
    ctx.focusPositions[id] = rect(row.rect.x, y, row.rect.width, row.rect.height)
    addFocusable(ctx, id)
    mapScroll.visibleTargets[#mapScroll.visibleTargets + 1] = id
    if mapModel.pending then
      ctx.disabledTargets[id] = true
    end
    ctx.rows[#ctx.rows + 1] = {
      role = "list",
      listSurface = true,
      targetId = id,
      label = map.displayName,
      labelRect = ctx.rowLabelRects[id],
      muted = mapModel.pending,
    }
  end
end

local function buildLocationGrid(ctx)
  local view = ctx.view
  local contentX, contentTop, contentBottom, innerWidth =
    ctx.contentX, ctx.contentTop, ctx.contentBottom, ctx.innerWidth
  local metrics = ctx.metrics
  local location = assert(view.location, "Location needs the headless service snapshot")
  local locationNav = assert(view.locationNavigation, "Location needs controller navigation state")
  local headerHeight = metrics.lineHeight
  local headerRect = rect(contentX, contentTop, innerWidth, headerHeight)
  local mapLabel = location.map and location.map.symbol:gsub("^MAP_", "", 1)
    or ("Map " .. tostring(location.mapId or locationNav.mapId or "—"))
  local cursor = assert(locationNav.cursor, "Location grid header needs its cursor")
  local coordinatesText = string.format("  X %d  Z %d", cursor.fieldX, cursor.fieldZ)
  local leftText = mapLabel .. coordinatesText
  local rightText
  local serviceStatus = location.status or {}
  if serviceStatus.state == "failed" then
    rightText = locationReason(assert(serviceStatus.reason, "failed preparation carries its cause"))
  else
    local matched = false
    for _, tile in ipairs(location.tiles or {}) do
      if tile.fieldX == cursor.fieldX and tile.fieldZ == cursor.fieldZ then
        matched = true
        if tile.state == "pending" then
          rightText = "Preparing…"
        end
        if tile.selectable == false then
          rightText = locationReason(assert(tile.reason, "blocked grid tiles carry their policy reason"))
        end
        break
      end
    end
    if not matched then
      rightText = "Preparing…"
    end
  end
  local rightWidth = rightText ~= nil
      and math.min(math.max(56, metrics.measure(rightText)), math.floor(headerRect.width * 0.4))
    or 0
  rightWidth = math.min(rightWidth, headerRect.width)
  local leftWidth = math.max(0, headerRect.width - rightWidth - (rightWidth > 0 and 8 or 0))
  local leftRect = rect(headerRect.x, headerRect.y, leftWidth, headerHeight)
  local coordinatesWidth = math.min(metrics.measure(coordinatesText), leftWidth)
  local mapNameWidth = math.max(0, leftWidth - coordinatesWidth)
  local rightRect = rect(headerRect.x + headerRect.width - rightWidth, headerRect.y, rightWidth, headerHeight)
  ctx.locationHeader = {
    lineRect = headerRect,
    leftText = leftText,
    mapNameText = mapLabel,
    coordinatesText = coordinatesText,
    rightText = rightText,
    leftRect = leftRect,
    mapNameRect = rect(leftRect.x, leftRect.y, mapNameWidth, headerHeight),
    coordinatesRect = rect(leftRect.x + mapNameWidth, leftRect.y, coordinatesWidth, headerHeight),
    rightRect = rightRect,
  }

  local gridY = contentTop + headerHeight + 2
  local gridClip = rect(contentX, gridY, innerWidth, contentBottom - gridY)
  assert(gridClip.height > 0, "Location grid needs room below its header line")
  local tileSize = 16
  local columns = math.max(1, math.floor(gridClip.width / tileSize))
  local gridRows = math.max(1, math.floor(gridClip.height / tileSize))
  local center = assert(locationNav.center, "Location needs a grid center")
  local firstFieldX = center.fieldX - math.floor(columns / 2)
  local firstFieldZ = center.fieldZ - math.floor(gridRows / 2)
  local renderedWidth, renderedHeight = columns * tileSize, gridRows * tileSize
  ctx.locationGrid = {
    clip = gridClip,
    originX = gridClip.x + (gridClip.width - renderedWidth) / 2,
    originY = gridClip.y + (gridClip.height - renderedHeight) / 2,
    tileSize = tileSize,
    columns = columns,
    rows = gridRows,
    firstFieldX = firstFieldX,
    firstFieldZ = firstFieldZ,
    renderedWidth = renderedWidth,
    renderedHeight = renderedHeight,
  }

  addFocusable(ctx, "location:grid")
  ctx.targets["location:grid"] = gridClip
  ctx.focusPositions["location:grid"] = gridClip
  local tileId = string.format("location:tile:%d:%d", cursor.fieldX, cursor.fieldZ)
  addFocusable(ctx, tileId)
end

local function buildLocation(ctx)
  local location = assert(ctx.view.location)
  local locationNav = assert(ctx.view.locationNavigation, "Location needs controller navigation state")
  if locationNav.page == "root" or locationNav.page == "group" then
    buildLocationMapList(ctx)
  else
    buildLocationGrid(ctx)
  end
  if locationNav.contentFocus == "map-list" then
    local viewport = location.mapListId and ctx.viewports[location.mapListId]
    ctx.locationFocusCue = viewport and viewport.clip or nil
  elseif locationNav.contentFocus == "grid" then
    ctx.locationFocusCue = ctx.locationGrid and ctx.locationGrid.clip or nil
  end
end

local function buildPlayer(ctx)
  local snapshot = assert(ctx.view.session)
  addRow(ctx, "read-only value", "player", "Player", snapshot.playerName)
  addRow(ctx, "integer value", "money", "Money", snapshot.money)
  addRow(ctx, "named choice", "dialogue-frame", "Dialogue frame", "Frame " .. tostring(snapshot.frameIndex + 1))
end

local function buildProgress(ctx)
  local view = ctx.view
  local contentX, contentTop, contentBottom, innerWidth =
    ctx.contentX, ctx.contentTop, ctx.contentBottom, ctx.innerWidth
  local metrics, compactRowExtent = ctx.metrics, ctx.compactRowExtent
  local flagModel = assert(view.flagModel, "Progress needs its indexed flag projection")
  local flagRowTargets = flagModel.rowTargets
  local storedFlagOffset = view.scrollOffsets and view.scrollOffsets.flags or 0
  local bodyTop = contentTop + #ctx.rows * ctx.rowHeight
  local bodyHeight = math.max(0, contentBottom - bodyTop)
  local flagList = ListSurface.resolve({
    bounds = rect(contentX, bodyTop, innerWidth, bodyHeight),
    rowCount = flagModel.count,
    rowHeight = compactRowExtent,
    gap = 0,
    maxWidth = innerWidth,
    headerHeight = metrics.lineHeight,
    scrollOffset = storedFlagOffset,
    hasTrailingValue = true,
    trailingValueWidth = ctx.measuredTrailingValueWidth or metrics.measure("OFF"),
    font = { lineHeight = metrics.lineHeight, measure = metrics.measure },
  })
  local flagOffset =
    ScrollViewport.clamp(storedFlagOffset, flagList.contentHeight, flagList.content.height - flagList.header.height)
  local contentExtent = flagList.contentHeight
  ctx.listSurfaces[#ctx.listSurfaces + 1] = flagList.surface
  local flagViewport = registerList(ctx, "flags", "flags", flagList, flagRowTargets, view.query, view.flagIndexByTarget)
  ctx.lists.flags.pending = flagModel.pending
  local flagScroll =
    makeViewport(flagViewport, flagOffset, contentExtent, compactRowExtent, 0, flagModel.count, flagRowTargets)
  flagScroll.visibleTargets = {}
  ctx.viewports.flags = flagScroll
  for _, row in ipairs(flagList.rows) do
    local flag = assert(flagModel.rowAt(row.index), "visible flag rows resolve to their logical payload")
    local id = assert(flagModel.idAt(row.index), "visible flag rows keep their logical identity")
    ctx.listRowRoles[id] = "toggle"
    local y = row.rect.y - flagOffset
    ctx.targets[id] = rect(row.rect.x, y, row.rect.width, compactRowExtent - 2)
    ctx.rowMarkers[id] =
      rect(row.markerRect.x, row.markerRect.y - flagOffset, row.markerRect.width, row.markerRect.height)
    ctx.rowMarkerRadii[id] = row.markerRadius
    ctx.rowLabelRects[id] =
      rect(row.labelRect.x, row.labelRect.y - flagOffset, row.labelRect.width, row.labelRect.height)
    ctx.focusPositions[id] = rect(row.rect.x, y, row.rect.width, compactRowExtent - 2)
    addFocusable(ctx, id)
    flagScroll.visibleTargets[#flagScroll.visibleTargets + 1] = id
    if flagModel.pending then
      ctx.disabledTargets[id] = true
    end
    placeRow(ctx, "toggle", id, flag.name, flag.value, not flagModel.pending, y, compactRowExtent)
    ctx.rows[#ctx.rows].listSurface = true
    ctx.rows[#ctx.rows].displayName = flag.displayName
    ctx.rows[#ctx.rows].labelRect = ctx.rowLabelRects[id]
    ctx.rows[#ctx.rows].valueRect =
      rect(row.valueRect.x, row.valueRect.y - flagOffset, row.valueRect.width, row.valueRect.height)
    ctx.rows[#ctx.rows].muted = flagModel.pending
    ctx.rows[#ctx.rows].muted = flagModel.pending
  end
end

local function buildParty(ctx)
  local view = ctx.view
  local contentX, contentBottom, innerWidth = ctx.contentX, ctx.contentBottom, ctx.innerWidth
  local metrics, rowHeight = ctx.metrics, ctx.rowHeight
  -- Persistent selected-mon editor: a six-position sprite strip on top,
  -- exactly one of Stats/Moves/Details in the body, and a bottom pager.
  -- No tab bar and no local action bar remain.
  local selector = assert(view.partySelector, "Party publishes its member strip")
  assert(#selector.slots == 6, "the member strip always spans six positions")
  local tab = view.partyTab or "Stats"
  assert(tab == "Stats" or tab == "Moves" or tab == "Details", "unknown party page " .. tostring(tab))
  if tab == "Stats" and view.partyStats ~= nil and ctx.width >= 800 then
    local shellRight = ctx.shellX + ctx.shellWidth - ctx.margin
    innerWidth = math.max(innerWidth, shellRight - contentX)
    ctx.innerWidth = innerWidth
  end
  local stripHeight = math.max(30, metrics.lineHeight + 14)
  local stripY = ctx.contentTop + 4
  local cellWidth = innerWidth / 6
  local stripSlots = {}
  for position, slot in ipairs(selector.slots) do
    local cell = rect(contentX + (position - 1) * cellWidth + 1, stripY, cellWidth - 2, stripHeight - 2)
    local entry = { kind = slot.kind, slot0 = slot.slot0, rect = cell, active = slot.active == true }
    if slot.kind == "member" then
      local targetId = "party:slot:" .. assert(slot.slot0, "member positions carry their slot")
      entry.targetId = targetId
      entry.iconKey = slot.iconKey
      local iconSize = math.min(cell.width - 4, cell.height - 4)
      entry.iconRect =
        rect(cell.x + (cell.width - iconSize) / 2, cell.y + (cell.height - iconSize) / 2, iconSize, iconSize)
      ctx.targets[targetId] = cell
      ctx.focusPositions[targetId] = cell
      addFocusable(ctx, targetId)
    elseif slot.kind == "add" then
      entry.targetId = "party:add"
      ctx.targets["party:add"] = cell
      ctx.focusPositions["party:add"] = cell
      addFocusable(ctx, "party:add")
    end
    stripSlots[position] = entry
  end
  ctx.partyStrip = { slots = stripSlots }
  local bodyTop = stripY + stripHeight + 4
  local pageHeight = math.min(30, math.max(22, metrics.lineHeight + 10))
  local pageY = contentBottom - pageHeight
  local arrowWidth = math.min(pageHeight + 8, 44)
  local labelWidth = math.min(metrics.measure(tab) + 8, math.max(1, innerWidth - arrowWidth * 2 - 8))
  local pagerWidth = arrowWidth * 2 + labelWidth + 8
  local pagerX = contentX + math.max(0, (innerWidth - pagerWidth) / 2)
  ctx.targets["party:page:previous"] = rect(pagerX, pageY, arrowWidth, pageHeight)
  addFocusable(ctx, "party:page:previous")
  ctx.partyPageLabel = { text = tab, rect = rect(pagerX + arrowWidth + 4, pageY, labelWidth, pageHeight) }
  ctx.targets["party:page:next"] = rect(pagerX + arrowWidth + 4 + labelWidth + 4, pageY, arrowWidth, pageHeight)
  addFocusable(ctx, "party:page:next")
  local bodyBottom = pageY - 4
  -- Every page body shares one scroll viewport: logical rows cover the
  -- full page while geometry and focus targets materialize only for the
  -- visible window. Counts stay tiny (facts, six stat rows, four move
  -- slots, twenty details rows), so no catalog work is involved.
  local bodyItems = {}
  if view.partyWarning ~= nil then
    bodyItems[#bodyItems + 1] = { kind = "notice", extent = metrics.lineHeight + 6 }
  end
  if view.partyEmpty then
    bodyItems[#bodyItems + 1] = { kind = "prompt", extent = rowHeight }
  elseif tab == "Stats" and view.partyStats ~= nil then
    local factColumns = ctx.width >= 800 and 5 or ctx.width >= 400 and 3 or 2
    ctx.partyHeaderColumns = factColumns
    local factHeight = metrics.lineHeight + 8
    bodyItems[#bodyItems + 1] = {
      kind = "facts",
      facts = view.partyStats.header,
      columns = factColumns,
      extent = math.ceil(#view.partyStats.header / factColumns) * factHeight,
    }
    bodyItems[#bodyItems + 1] = { kind = "stat-header", extent = math.max(14, metrics.lineHeight + 2) }
    for _, stat in ipairs(view.partyStats.rows) do
      bodyItems[#bodyItems + 1] = { kind = "stat-row", stat = stat, extent = math.max(18, metrics.lineHeight + 6) }
    end
  elseif tab == "Moves" and view.partyMoves ~= nil then
    for index = 1, #view.partyMoves.slots, 2 do
      bodyItems[#bodyItems + 1] = {
        kind = "move-row",
        slots = { view.partyMoves.slots[index], view.partyMoves.slots[index + 1] },
        extent = math.max(30, metrics.lineHeight + 14),
      }
    end
  elseif tab == "Details" and view.partyDetails ~= nil then
    for _, row in ipairs(view.partyDetails.rows) do
      local extent = metrics.lineHeight + 8
      bodyItems[#bodyItems + 1] = { kind = "detail", row = row, extent = extent }
    end
  end
  local bodyHeight = math.max(1, bodyBottom - bodyTop)
  local baseExtent = 0
  for _, item in ipairs(bodyItems) do
    baseExtent = baseExtent + item.extent
  end
  local bodyGap = #bodyItems > 0 and math.min(8, math.floor(math.max(0, bodyHeight - baseExtent) / (#bodyItems + 1)))
    or 0
  local tops, contentExtent = {}, 0
  for index, item in ipairs(bodyItems) do
    contentExtent = contentExtent + bodyGap
    tops[index] = contentExtent
    contentExtent = contentExtent + item.extent
  end
  contentExtent = contentExtent + bodyGap
  local offset = view.scrollOffsets and view.scrollOffsets["party:" .. tab] or 0
  offset = ScrollViewport.clamp(offset, contentExtent, bodyHeight)
  local rowTargets = {}
  for _, item in ipairs(bodyItems) do
    if item.kind == "facts" then
      for _, fact in ipairs(item.facts) do
        if fact.targetId ~= nil and fact.editor ~= nil then
          rowTargets[#rowTargets + 1] = fact.targetId
        end
      end
    elseif item.kind == "stat-row" then
      rowTargets[#rowTargets + 1] = item.stat.ivEditor.targetId
      rowTargets[#rowTargets + 1] = item.stat.evEditor.targetId
    elseif item.kind == "move-row" then
      for _, slot in ipairs(item.slots) do
        if slot ~= nil and slot.targetId ~= nil then
          rowTargets[#rowTargets + 1] = slot.targetId
        end
      end
    elseif item.kind == "detail" then
      if item.row.role == "action" or item.row.role == "integer value" or item.row.role == "named choice" then
        rowTargets[#rowTargets + 1] = item.row.targetId
      end
    end
  end
  for index, item in ipairs(bodyItems) do
    local start = tops[index]
    local function reveal(targetId, itemStart, extent)
      ctx.revealByTarget[targetId] = { viewportId = "party", start = itemStart, extent = extent }
    end
    if item.kind == "facts" then
      local factHeight = item.extent / math.ceil(#item.facts / item.columns)
      for factIndex, fact in ipairs(item.facts) do
        if fact.targetId ~= nil and fact.editor ~= nil then
          reveal(fact.targetId, start + math.floor((factIndex - 1) / item.columns) * factHeight, factHeight - 2)
        end
      end
    elseif item.kind == "stat-row" then
      reveal(item.stat.ivEditor.targetId, start, item.extent)
      reveal(item.stat.evEditor.targetId, start, item.extent)
    elseif item.kind == "move-row" then
      for _, slot in ipairs(item.slots) do
        if slot ~= nil and slot.targetId ~= nil then
          reveal(slot.targetId, start, item.extent)
        end
      end
    elseif
      item.kind == "detail"
      and (item.row.role == "action" or item.row.role == "integer value" or item.row.role == "named choice")
    then
      reveal(item.row.targetId, start, item.extent)
    end
  end
  local partyViewport = rect(contentX, bodyTop, innerWidth, bodyHeight)
  ctx.viewports.party = makeViewport(partyViewport, offset, contentExtent, 20, 0, #bodyItems, rowTargets)
  local statHeaders, statRows, moveSlots = {}, {}, {}
  for index, item in ipairs(bodyItems) do
    local y = bodyTop + tops[index] - offset
    local overlaps = y < bodyBottom and y + item.extent > bodyTop
    if overlaps then
      if item.kind == "notice" then
        local noticeRect = rect(contentX, y, innerWidth, item.extent - 2)
        ctx.rows[#ctx.rows + 1] = { role = "warning", targetId = "party:validation", label = assert(view.partyWarning) }
        ctx.targets["party:validation"] = noticeRect
      elseif item.kind == "prompt" then
        local promptRect = rect(contentX, y, innerWidth, item.extent - 2)
        ctx.rows[#ctx.rows + 1] =
          { role = "read-only value", targetId = "party:empty", label = "No member selected", value = "Choose + Add" }
        ctx.targets["party:empty"] = promptRect
      elseif item.kind == "facts" then
        local factWidth = innerWidth / item.columns
        local factHeight = item.extent / (math.ceil(#item.facts / item.columns))
        for factIndex, fact in ipairs(item.facts) do
          local column = (factIndex - 1) % item.columns
          local factRow = math.floor((factIndex - 1) / item.columns)
          local cellRect =
            rect(contentX + column * factWidth + 1, y + factRow * factHeight, factWidth - 2, factHeight - 2)
          if cellRect.y < bodyBottom and cellRect.y + cellRect.height > bodyTop then
            local layoutRow = {
              role = "integer value",
              targetId = assert(fact.targetId, "header facts carry their editor target"),
              label = fact.label,
              value = fact.value,
              enabled = true,
              partyField = true,
              labelRect = rect(cellRect.x + 2, cellRect.y + 1, cellRect.width * 0.4, cellRect.height - 3),
              valueRect = rect(
                cellRect.x + cellRect.width * 0.44,
                cellRect.y + 1,
                cellRect.width * 0.54,
                cellRect.height - 3
              ),
              valueText = fact.display ~= nil and fact.display or tostring(fact.value),
              layoutRect = cellRect,
              editable = fact.editor ~= nil,
            }
            if fact.editor ~= nil then
              ctx.targets[assert(fact.targetId)] = cellRect
              ctx.focusPositions[fact.targetId] = cellRect
              addFocusable(ctx, fact.targetId)
            end
            ctx.rows[#ctx.rows + 1] = layoutRow
          end
        end
      elseif item.kind == "stat-header" then
        local headerX = contentX + 0.0
        for _, pair in ipairs({ { "Stat", 0.4 }, { "IV", 0.3 }, { "EV", 0.3 } }) do
          statHeaders[#statHeaders + 1] =
            { label = pair[1], rect = rect(headerX, y, innerWidth * pair[2], item.extent) }
          headerX = headerX + innerWidth * pair[2]
        end
      elseif item.kind == "stat-row" then
        local stat = item.stat
        local columnWidths = { innerWidth * 0.4, innerWidth * 0.3, innerWidth * 0.3 }
        local values = { stat.label, tostring(stat.iv), tostring(stat.ev) }
        local descriptors = { nil, stat.ivEditor, stat.evEditor }
        local cells, cellX = {}, contentX + 0.0
        for column = 1, 3 do
          local cellRect = rect(cellX, y, columnWidths[column], item.extent)
          local descriptor = descriptors[column]
          cells[column] = {
            label = values[column],
            rect = cellRect,
            targetId = descriptor and descriptor.targetId or nil,
            editable = descriptor ~= nil and descriptor.editor ~= nil,
          }
          if descriptor ~= nil and descriptor.editor ~= nil then
            ctx.targets[descriptor.targetId] = cellRect
            ctx.focusPositions[descriptor.targetId] = cellRect
            addFocusable(ctx, descriptor.targetId)
          end
          cellX = cellX + columnWidths[column]
        end
        statRows[#statRows + 1] = { key = stat.key, cells = cells }
      elseif item.kind == "move-row" then
        local columnWidth = innerWidth / 2
        for column, slot in ipairs(item.slots) do
          if slot ~= nil then
            local buttonRect = rect(contentX + (column - 1) * columnWidth + 2, y, columnWidth - 4, item.extent - 2)
            if slot.kind == "empty" then
              moveSlots[#moveSlots + 1] = { kind = "empty", rect = buttonRect }
            else
              local buttonTarget = assert(slot.targetId, "visible move slots carry their target")
              moveSlots[#moveSlots + 1] =
                { kind = slot.kind, slot0 = slot.slot0, label = slot.label, targetId = buttonTarget, rect = buttonRect }
              ctx.targets[buttonTarget] = buttonRect
              ctx.focusPositions[buttonTarget] = buttonRect
              addFocusable(ctx, buttonTarget)
            end
          end
        end
      else
        assert(item.kind == "detail", "party body rows have a known kind")
        local row = item.row
        local bandHeight = item.extent - 2
        local fieldRect = rect(contentX, y, innerWidth, bandHeight)
        local actionable = row.role == "action" or row.role == "integer value" or row.role == "named choice"
        if actionable then
          addFocusable(ctx, row.targetId)
          ctx.focusPositions[row.targetId] = fieldRect
        end
        local layoutRow = {
          role = row.role,
          targetId = row.targetId,
          label = row.label,
          value = row.value,
          enabled = row.enabled,
          iconKey = nil,
          partyField = true,
          labelRect = rect(contentX + 4, y + 2, innerWidth * 0.43, item.extent - 5),
          valueRect = rect(contentX + innerWidth * 0.48, y + 2, innerWidth * 0.5, item.extent - 5),
          valueText = row.value == nil and nil or tostring(row.value),
          layoutRect = fieldRect,
          editable = row.editor ~= nil,
          semantic = row.semantic,
        }
        if actionable then
          ctx.targets[row.targetId] = fieldRect
        end
        ctx.rows[#ctx.rows + 1] = layoutRow
      end
    end
  end
  if tab == "Stats" then
    ctx.partyStatsTable = { headers = statHeaders, rows = statRows }
  elseif tab == "Moves" then
    ctx.partyMoves = { slots = moveSlots }
  end
end

local function buildBag(ctx)
  local view = ctx.view
  local contentX, contentTop, contentBottom, innerWidth =
    ctx.contentX, ctx.contentTop, ctx.contentBottom, ctx.innerWidth
  local metrics = ctx.metrics
  local compactBag = ctx.compactBag
  local stripX = contentX + math.floor((innerWidth - 256) / 2)
  local stripY = contentTop
  local tabTargets = {}
  for index, native in ipairs(view.bagPocketTabRects) do
    local id = "bag:pocket:" .. view.bagPockets[index].key
    local target = rect(stripX + native.x, stripY + native.y, native.width, native.height)
    ctx.targets[id], ctx.focusPositions[id] = target, target
    tabTargets[#tabTargets + 1] = id
    addFocusable(ctx, id)
  end
  local gridY = stripY + (compactBag and 34 or 38)
  local pageHeight = compactBag and 20 or 28
  local pageY = contentBottom - pageHeight - 2
  local gridBody = rect(contentX, gridY, innerWidth, math.max(3, pageY - gridY - 4))
  local cells = SaveEditorCard.resolveGrid({
    bounds = gridBody,
    count = math.min(6, #(view.bagPageRows or {})),
    columns = 2,
    rows = 3,
    gap = compactBag and 4 or 8,
    maxWidth = 264,
    maxCellWidth = 128,
    maxCellHeight = 44,
  })
  local cards = {}
  local textScale = PixelScale.assertInteger(1)
  local lineHeight = math.max(1, math.ceil(metrics.lineHeight))
  for index, item in ipairs(view.bagPageRows or {}) do
    local cell = cells[index]
    local iconSize = cell.rect.height > 32 and BAG_ICON_SIZE_EXPANDED or BAG_ICON_SIZE_COMPACT
    local iconRect = rect(cell.rect.x + 4, cell.rect.y + (cell.rect.height - iconSize) / 2, iconSize, iconSize)
    local quantityWidth = math.ceil(metrics.measure("x" .. tostring(item.quantity))) + 6
    local textY = cell.rect.y + (cell.rect.height - lineHeight) / 2
    local quantityRect = rect(cell.rect.x + cell.rect.width - 4 - quantityWidth, textY, quantityWidth, lineHeight)
    local nameRect =
      rect(iconRect.x + iconRect.width + 4, textY, quantityRect.x - 4 - (iconRect.x + iconRect.width + 4), lineHeight)
    local id = "bag:item:" .. item.item
    ctx.targets[id], ctx.focusPositions[id] = cell.rect, cell.rect
    addFocusable(ctx, id)
    cards[#cards + 1] = {
      kind = "item",
      targetId = id,
      label = item.label,
      quantity = item.quantity,
      iconKey = item.iconKey,
      rect = cell.rect,
      iconRect = iconRect,
      nameRect = nameRect,
      quantityRect = quantityRect,
      textScale = textScale,
    }
  end
  local arrowWidth = math.min(pageHeight, 32)
  local pageWidth = math.min(56, math.max(32, innerWidth - arrowWidth * 2 - 12))
  local pageGroupWidth = arrowWidth * 2 + pageWidth + 8
  local pageGroupX = contentX + math.max(0, (innerWidth - pageGroupWidth) / 2)
  ctx.targets["bag:page:previous"] = rect(pageGroupX, pageY, arrowWidth, pageHeight)
  ctx.bagPageTextRect = rect(pageGroupX + arrowWidth + 4, pageY + (pageHeight - 16) / 2, pageWidth, 16)
  ctx.targets["bag:page:next"] = rect(pageGroupX + arrowWidth + 4 + pageWidth + 4, pageY, arrowWidth, pageHeight)
  if view.bagPage0 == 0 then
    ctx.disabledTargets["bag:page:previous"] = true
  else
    addFocusable(ctx, "bag:page:previous")
  end
  if view.bagPage0 + 1 >= view.bagPageCount then
    ctx.disabledTargets["bag:page:next"] = true
  else
    addFocusable(ctx, "bag:page:next")
  end
  local addWidth = math.min(60, math.max(40, innerWidth - pageGroupWidth - 8))
  local addX = contentX + innerWidth - addWidth
  ctx.targets["bag:add"] = rect(addX, pageY, addWidth, pageHeight)
  addFocusable(ctx, "bag:add")
  if view.bagAddEnabled == false then
    ctx.disabledTargets["bag:add"] = true
  end
  ctx.bagGrid = cards
  ctx.bagTabs = tabTargets
  ctx.bagStripTarget = rect(stripX, stripY, 256, 32)
end

local function buildFallbackSection(ctx)
  addRow(ctx, "read-only value", "section", ctx.section, "Available in a later update")
end

-- The closed section selection invokes exactly one builder; overlays below
-- add value/decision geometry on top of the section rows.
local function buildSection(ctx)
  local view = ctx.view
  if view.status == "opening" then
    buildOpening(ctx)
  elseif view.status == "error" then
    buildErrorStatus(ctx)
  elseif ctx.section == "Location" then
    buildLocation(ctx)
  elseif ctx.section == "Player" then
    buildPlayer(ctx)
  elseif ctx.section == "Progress" then
    buildProgress(ctx)
  elseif ctx.section == "Party" then
    buildParty(ctx)
  elseif ctx.section == "Bag" and view.bagPocketTabRects ~= nil then
    buildBag(ctx)
  else
    buildFallbackSection(ctx)
  end
end

local function buildFooterActions(ctx)
  local view = ctx.view
  local contentX, innerWidth = ctx.contentX, ctx.innerWidth
  local metrics, height, footerHeight = ctx.metrics, ctx.height, ctx.footerHeight
  local bodyGlyphHeight = ctx.bodyGlyphHeight
  local discardEnabled
  if view.modal ~= nil then
    discardEnabled = view.ready == true and view.dirty == true
  else
    discardEnabled = view.ready == true and view.sectionDirty == true
  end
  local actions = {
    {
      id = "save",
      label = "Save",
      enabled = view.ready == true and view.dirty == true and view.valueEditor == nil and view.unappliedDraft ~= true,
    },
    { id = "discard", label = "Discard", enabled = discardEnabled },
    { id = "back", label = "Back", enabled = true },
  }
  local actionWidths = {
    math.min(128, math.max(40, metrics.measure("Save") + 24)),
    math.min(128, math.max(40, metrics.measure("Discard") + 24)),
    math.min(128, math.max(40, metrics.measure(view.locationSave and "Cancel check" or "Back") + 24)),
  }
  local widthTotal = actionWidths[1] + actionWidths[2] + actionWidths[3]
  if widthTotal > innerWidth - 8 then
    local actionWidth = math.floor((innerWidth - 8) / 3)
    actionWidths = { actionWidth, actionWidth, actionWidth }
    widthTotal = actionWidth * 3
  end
  local actionGap = 4
  local actionX = contentX + math.floor((innerWidth - widthTotal - actionGap * 2) / 2)
  local actionHeight = bodyGlyphHeight + 8
  for index, action in ipairs(actions) do
    ctx.targets[action.id] = rect(
      actionX,
      height - footerHeight + math.floor((footerHeight - actionHeight) / 2),
      actionWidths[index],
      actionHeight
    )
    actionX = actionX + actionWidths[index] + actionGap
    action.role, action.targetId, action.value = "action", action.id, action.label
    addFocusable(ctx, action.id)
    if not action.enabled then
      ctx.disabledTargets[action.id] = true
    end
  end
  ctx.actions = actions
end

local function buildChoiceScope(ctx)
  local view = ctx.view
  local dialog = view.valueEditor
  local contentX, contentTop, contentBottom, innerWidth =
    ctx.contentX, ctx.contentTop, ctx.contentBottom, ctx.innerWidth
  local metrics, compactRowExtent = ctx.metrics, ctx.compactRowExtent
  local dialogTop = contentTop + 4
  local bodyTop = dialogTop
  local bodyBottom = contentBottom - 36
  local bodyHeight = math.max(1, bodyBottom - bodyTop)
  local storedChoiceOffset = view.scrollOffsets and view.scrollOffsets["value:choice"] or 0
  local choiceBounds = rect(contentX, bodyTop, innerWidth, bodyHeight)
  local function resolveChoice(offset)
    return ListSurface.resolve({
      bounds = choiceBounds,
      rowCount = dialog.count,
      rowHeight = compactRowExtent,
      gap = 0,
      maxWidth = innerWidth,
      headerHeight = metrics.lineHeight,
      scrollOffset = offset,
    })
  end
  local choiceList = resolveChoice(storedChoiceOffset)
  local choiceViewportHeight = choiceList.content.height - choiceList.header.height
  local offset = ScrollViewport.clamp(storedChoiceOffset, choiceList.contentHeight, choiceViewportHeight)
  local contentExtent = choiceList.contentHeight
  ctx.listSurfaces[#ctx.listSurfaces + 1] = choiceList.surface
  local rowTargets = assert(dialog.rowTargets, "the choice dialog carries its cached logical row order")
  assert(dialog.count == #rowTargets, "choice projection and row order describe the same logical rows")
  local viewport =
    registerList(ctx, "value:choice", "value:choice", choiceList, rowTargets, dialog.query, dialog.indexByTarget)
  ctx.lists["value:choice"].pending = dialog.pending
  local selectedIndex = dialog.index ~= 0 and dialog.index or nil
  if selectedIndex ~= nil and dialog.selectedKey ~= nil then
    assert(
      rowTargets[selectedIndex] == "choice:" .. dialog.selectedKey,
      "the cached choice order matches the cached selection"
    )
  end
  if selectedIndex and not view.preserveChoiceScroll then
    offset =
      ScrollViewport.reveal(offset, choiceViewportHeight, (selectedIndex - 1) * compactRowExtent, compactRowExtent)
  end
  offset = ScrollViewport.clamp(offset, contentExtent, choiceViewportHeight)
  local resolvedOffset = ScrollViewport.clamp(storedChoiceOffset, contentExtent, choiceViewportHeight)
  if offset ~= resolvedOffset then
    choiceList = resolveChoice(offset)
  end
  local choiceScroll = makeViewport(viewport, offset, contentExtent, compactRowExtent, 0, dialog.count, rowTargets)
  choiceScroll.visibleTargets = {}
  ctx.viewports["value:choice"] = choiceScroll
  for _, row in ipairs(choiceList.rows) do
    local id = assert(dialog.idAt(row.index), "visible choice rows keep their logical identity")
    addFocusable(ctx, id)
    ctx.focusPositions[id] = rect(row.rect.x, row.rect.y - offset, row.rect.width, row.rect.height - 1)
    ctx.targets[id] = rect(row.rect.x, row.rect.y - offset, row.rect.width, row.rect.height - 1)
    ctx.rowMarkers[id] = rect(row.markerRect.x, row.markerRect.y - offset, row.markerRect.width, row.markerRect.height)
    ctx.rowMarkerRadii[id] = row.markerRadius
    ctx.rowLabelRects[id] =
      rect(row.markerRect.x + 6, row.rect.y - offset + 3, row.rect.width - 18, row.rect.height - 6)
    if dialog.pending then
      ctx.disabledTargets[id] = true
    end
    choiceScroll.visibleTargets[#choiceScroll.visibleTargets + 1] = id
  end
  local chooseGlyphWidth = math.ceil(metrics.measure("Choose"))
  local backGlyphWidth = math.ceil(metrics.measure("Back"))
  local actionPadding, actionGap, outerPadding = 12, 6, 8
  local availableWidth = innerWidth - outerPadding * 2
  local chooseWidth, backWidth
  for padding = actionPadding, 4, -1 do
    chooseWidth = math.max(40, chooseGlyphWidth + padding * 2)
    backWidth = math.max(40, backGlyphWidth + padding * 2)
    if chooseWidth + actionGap + backWidth <= availableWidth then
      break
    end
  end
  local pairWidth = chooseWidth + actionGap + backWidth
  local footerY = contentBottom - 34
  if pairWidth > availableWidth then
    ctx.choiceTooSmall = true
    ctx.disabledTargets.confirm = true
    if innerWidth > 0 and contentBottom > bodyBottom then
      backWidth = math.min(math.max(40, backGlyphWidth + 8), innerWidth)
      ctx.targets.cancel = rect(contentX + math.floor((innerWidth - backWidth) / 2), footerY, backWidth, 34)
      addFocusable(ctx, "cancel")
    end
  else
    local actionX = contentX + math.floor((innerWidth - pairWidth) / 2)
    ctx.targets.confirm = rect(actionX, footerY, chooseWidth, 34)
    ctx.targets.cancel = rect(actionX + chooseWidth + actionGap, footerY, backWidth, 34)
    addFocusable(ctx, "confirm")
    addFocusable(ctx, "cancel")
  end
  if dialog.count == 0 or dialog.pending then
    ctx.disabledTargets.confirm = true
  end
end

local function buildNameScope(ctx)
  local view = ctx.view
  local dialog = view.valueEditor
  local contentX, contentTop, innerWidth = ctx.contentX, ctx.contentTop, ctx.innerWidth
  local height = ctx.height
  local naming = assert(dialog.naming)
  local cellWidth = math.max(1, math.floor(innerWidth / 13))
  local keyboardBottom = height - 26
  local gridTop = math.min(contentTop + 20, keyboardBottom - 5 * 15 - 14 - 2)
  for row = 1, 6 do
    for column = 1, 13 do
      ctx.targets[row .. ":" .. column] =
        rect(contentX + (column - 1) * cellWidth, gridTop + (row - 1) * 15, cellWidth - 1, 14)
    end
  end
  for _, control in ipairs(naming.controls) do
    ctx.targets["name-control:" .. control.id] = rect(
      contentX + (control.firstColumn - 1) * cellWidth,
      gridTop,
      (control.lastColumn - control.firstColumn + 1) * cellWidth - 1,
      14
    )
  end
  ctx.targets.confirm = rect(contentX, keyboardBottom, math.floor(innerWidth / 2) - 2, 24)
  ctx.targets.cancel =
    rect(contentX + math.floor(innerWidth / 2) + 2, keyboardBottom, math.floor(innerWidth / 2) - 2, 24)
  addFocusable(ctx, "confirm")
  addFocusable(ctx, "cancel")
  for row = 1, 6 do
    for column = 1, 13 do
      addFocusable(ctx, row .. ":" .. column)
    end
  end
  for _, control in ipairs(naming.controls) do
    addFocusable(ctx, "name-control:" .. control.id)
  end
end

local function buildNumberScope(ctx)
  local view, dialog = ctx.view, ctx.view.valueEditor
  local contentX, contentTop, contentBottom, innerWidth =
    ctx.contentX, ctx.contentTop, ctx.contentBottom, ctx.innerWidth
  local metrics, margin, height = ctx.metrics, ctx.margin, ctx.height
  local modalTop, modalBottom = contentTop, contentBottom
  local frame = { inset = 8, actionHeight = 34, errorHeight = metrics.lineHeight + 2, actionGap = 4 }
  local arrow = assert(view.numberControlVisuals.increment.normal)
  if height <= 220 then
    modalBottom = height - (margin + 2) - 2
    frame.inset = 4
  end
  local numberLayout = SaveEditorNumberLayout.resolve({
    available = rect(contentX, modalTop, innerWidth, modalBottom - modalTop),
    projection = dialog,
    font = metrics,
    arrows = { width = arrow.width, height = arrow.height },
    frame = frame,
  })
  if numberLayout == nil then
    ctx.valueModal = rect(contentX, contentTop, innerWidth, math.max(1, contentBottom - contentTop))
    ctx.numberTooSmall = true
    if innerWidth > 0 and contentBottom > contentTop then
      local backWidth = math.min(math.max(40, math.ceil(metrics.measure("Back") + 24)), innerWidth)
      local backHeight = math.min(frame.actionHeight, contentBottom - contentTop)
      ctx.targets.cancel =
        rect(contentX + math.floor((innerWidth - backWidth) / 2), contentBottom - backHeight, backWidth, backHeight)
      addFocusable(ctx, "cancel")
      local noticeInset = math.min(4, math.floor((innerWidth - 1) / 2))
      local noticeWidth = innerWidth - noticeInset * 2
      local noticeHeight = math.min(metrics.lineHeight, contentBottom - contentTop - backHeight - frame.actionGap)
      if noticeHeight > 0 and noticeWidth > 0 then
        ctx.valueModalNotice = rect(
          contentX + noticeInset,
          contentTop + math.floor((contentBottom - contentTop - backHeight - frame.actionGap - noticeHeight) / 2),
          noticeWidth,
          noticeHeight
        )
      end
    end
    return
  end
  ctx.numberLayout = numberLayout
  ctx.valueModal = numberLayout.bodyRect
  for _, column in ipairs(numberLayout.columns) do
    for direction, targetRect in pairs({ up = column.upRect, down = column.downRect }) do
      local targetId = "number:place:" .. tostring(column.place) .. ":" .. direction
      ctx.targets[targetId] = targetRect
      addFocusable(ctx, targetId)
    end
  end
  ctx.targets.confirm = numberLayout.confirmRect
  ctx.targets.cancel = numberLayout.backRect
  addFocusable(ctx, "confirm")
  addFocusable(ctx, "cancel")
  ctx.valueModalValue = numberLayout.stripRect
  ctx.valueModalError = numberLayout.errorRect
end

local function buildValueScope(ctx)
  if ctx.view.valueEditor == nil then
    return
  end
  local dialog = ctx.view.valueEditor
  if dialog.kind == "choice" then
    buildChoiceScope(ctx)
  elseif dialog.kind == "name" then
    buildNameScope(ctx)
  elseif dialog.kind == "number" then
    buildNumberScope(ctx)
  end
end

local function buildDecisionScope(ctx)
  local view = ctx.view
  if view.modal == nil then
    return
  end
  local contentX, contentTop, contentBottom, innerWidth =
    ctx.contentX, ctx.contentTop, ctx.contentBottom, ctx.innerWidth
  local metrics = ctx.metrics
  local decisionActions = view.decisionActions
    or Decisions.describe(view.modal, { pendingSave = view.locationSave ~= nil })
  ctx.decisionActions = decisionActions
  assert(#decisionActions >= 2, "a decision modal has a primary action and a final Back action")
  local back = decisionActions[#decisionActions]
  assert(back.command == "cancel", "the final decision action is Back or Cancel")
  for index = 1, #decisionActions - 1 do
    assert(decisionActions[index].command ~= "cancel", "only the final decision action cancels")
  end
  local primaryCount = #decisionActions - 1
  local primaryColumnCount = math.min(2, primaryCount)
  local primaryRowCount = math.ceil(primaryCount / 2)
  local rowCount = primaryRowCount + 1
  local buttonHeight = metrics.lineHeight + 34
  local promptHeight = math.max(1, metrics.lineHeight)
  local availableHeight = contentBottom - contentTop
  local function publishTooSmall(surface)
    local content = surface.content
    local fallbackHeight = math.max(1, math.min(buttonHeight, content.height))
    local backRect =
      rect(content.x, content.y + math.max(0, content.height - fallbackHeight), content.width, fallbackHeight)
    ctx.decisionList = {
      surface = surface.surface,
      prompt = rect(content.x, content.y, content.width, math.max(0, content.height - fallbackHeight)),
      rows = {
        {
          targetId = back.id,
          label = back.label,
          semantic = back.semantic,
          enabled = back.enabled,
          rect = backRect,
          rowIndex = 1,
          columnIndex = 1,
        },
      },
      tooSmall = true,
    }
    if back.enabled then
      ctx.targets[back.id] = backRect
      ctx.disabledTargets[back.id] = nil
      addFocusable(ctx, back.id)
    else
      ctx.disabledTargets[back.id] = true
    end
  end
  local function resolveSurface(height)
    return ListSurface.resolve({
      bounds = rect(contentX, contentTop + math.floor((availableHeight - height) / 2), innerWidth, height),
      rowCount = rowCount,
      rowHeight = buttonHeight,
      gap = 4,
      maxWidth = 360,
    })
  end
  local availableSurface = resolveSurface(availableHeight)
  local function requiredContentHeight()
    return promptHeight + 4 + rowCount * buttonHeight + (rowCount - 1) * 4
  end
  local function fitSurface()
    local verticalInsets = availableSurface.surface.height - availableSurface.content.height
    local height = requiredContentHeight() + verticalInsets
    if height > availableHeight then
      return nil
    end
    local resolved = resolveSurface(height)
    if resolved.content.height < requiredContentHeight() then
      return nil
    end
    return resolved
  end
  local surface = fitSurface()
  if surface == nil and buttonHeight > 26 then
    buttonHeight = 26
    availableSurface = resolveSurface(availableHeight)
    surface = fitSurface()
  end
  if surface == nil then
    publishTooSmall(availableSurface)
    return
  end
  ctx.decisionList = {
    surface = surface.surface,
    prompt = rect(surface.content.x, surface.content.y, surface.content.width, promptHeight),
    rows = {},
  }
  local primaryColumnWidths = {}
  local backWidth = math.max(56, metrics.measure(back.label) + 24)
  if backWidth > surface.content.width then
    publishTooSmall(surface)
    return
  end
  for column = 1, primaryColumnCount do
    local minimumWidth = 40
    for index = column, primaryCount, 2 do
      minimumWidth = math.max(minimumWidth, metrics.measure(decisionActions[index].label) + 16)
    end
    primaryColumnWidths[column] = math.min(128, minimumWidth)
  end
  local primaryWidth = 4 * (primaryColumnCount - 1)
  for _, width in ipairs(primaryColumnWidths) do
    primaryWidth = primaryWidth + width
  end
  if primaryWidth > surface.content.width then
    local compressedWidth = math.floor((surface.content.width - 4 * (primaryColumnCount - 1)) / primaryColumnCount)
    if compressedWidth < 40 then
      publishTooSmall(surface)
      return
    end
    for column = 1, primaryColumnCount do
      primaryColumnWidths[column] = compressedWidth
    end
    primaryWidth = compressedWidth * primaryColumnCount + 4 * (primaryColumnCount - 1)
  end
  local rowStartY = surface.content.y + promptHeight + 4
  for index = 1, primaryCount do
    local action = decisionActions[index]
    local rowIndex = math.floor((index - 1) / 2) + 1
    local column = (index - 1) % 2 + 1
    local firstInRow = (rowIndex - 1) * 2 + 1
    local lastInRow = math.min(firstInRow + 1, primaryCount)
    local rowWidth, rowColumns = 0, lastInRow - firstInRow + 1
    for rowAction = firstInRow, lastInRow do
      rowWidth = rowWidth + primaryColumnWidths[(rowAction - 1) % 2 + 1]
    end
    rowWidth = rowWidth + 4 * (rowColumns - 1)
    local x = surface.content.x + math.floor((surface.content.width - rowWidth) / 2)
    for priorAction = firstInRow, index - 1 do
      x = x + primaryColumnWidths[(priorAction - 1) % 2 + 1] + 4
    end
    local rowRect = rect(x, rowStartY + (rowIndex - 1) * (buttonHeight + 4), primaryColumnWidths[column], buttonHeight)
    ctx.decisionList.rows[index] = {
      targetId = action.id,
      label = action.label,
      semantic = action.semantic,
      enabled = action.enabled,
      rect = rowRect,
      rowIndex = rowIndex,
      columnIndex = column,
    }
    if action.enabled then
      ctx.targets[action.id] = rowRect
      ctx.disabledTargets[action.id] = nil
      addFocusable(ctx, action.id)
    else
      ctx.disabledTargets[action.id] = true
    end
  end
  local backRowIndex = primaryRowCount + 1
  local backRect = rect(
    surface.content.x + math.floor((surface.content.width - backWidth) / 2),
    rowStartY + primaryRowCount * (buttonHeight + 4),
    backWidth,
    buttonHeight
  )
  ctx.decisionList.rows[#decisionActions] = {
    targetId = back.id,
    label = back.label,
    semantic = back.semantic,
    enabled = back.enabled,
    rect = backRect,
    rowIndex = backRowIndex,
    columnIndex = 1,
  }
  if back.enabled then
    ctx.targets[back.id] = backRect
    ctx.disabledTargets[back.id] = nil
    addFocusable(ctx, back.id)
  else
    ctx.disabledTargets[back.id] = true
  end
end

-- Active-scope selection and disabled filtering happen once, centrally: a
-- value/decision scope prunes every background target, and disabled records
-- leave the focus order. Geometry, keyboard targets and pointer hits all
-- derive from the surviving active set.
local function finalizeTargets(ctx)
  local view, scope = ctx.view, ctx.scope
  local scopeAllowed
  if scope.kind == "decision" then
    scopeAllowed = {}
    for _, action in ipairs(assert(ctx.decisionActions, "the decision scope needs its described actions")) do
      if action.enabled then
        scopeAllowed[action.id] = true
      end
    end
  elseif scope.kind == "value" then
    local editor = assert(view.valueEditor, "value scope needs its active editor")
    scopeAllowed = { confirm = true, cancel = true }
    if editor.kind == "choice" then
      scopeAllowed["list:value:choice"] = true
      for targetId in pairs(ctx.targets) do
        if editor.indexByTarget[targetId] ~= nil then
          scopeAllowed[targetId] = true
        end
      end
    elseif editor.kind == "name" then
      for row = 1, 6 do
        for column = 1, 13 do
          scopeAllowed[row .. ":" .. column] = true
        end
      end
      for _, control in ipairs(editor.naming.controls) do
        scopeAllowed["name-control:" .. control.id] = true
      end
    elseif editor.kind == "number" then
      scopeAllowed["value-draft"] = true
      for place = 0, editor.digitCount - 1 do
        scopeAllowed["number:place:" .. tostring(place) .. ":up"] = true
        scopeAllowed["number:place:" .. tostring(place) .. ":down"] = true
      end
    end
  end
  if scopeAllowed then
    for targetId in pairs(ctx.targets) do
      if not scopeAllowed[targetId] then
        ctx.targets[targetId] = nil
      end
    end
    local activeFocusable = {}
    ctx.focusableSet = {}
    for _, targetId in ipairs(ctx.focusable) do
      if scopeAllowed[targetId] and (ctx.targets[targetId] ~= nil or ctx.focusPositions[targetId] ~= nil) then
        activeFocusable[#activeFocusable + 1] = targetId
        ctx.focusableSet[targetId] = true
      end
    end
    ctx.focusable = activeFocusable
    local activeNavigation = {}
    for _, item in ipairs(ctx.navigation) do
      if scopeAllowed[item.targetId] then
        activeNavigation[#activeNavigation + 1] = item
      end
    end
    ctx.navigation = activeNavigation
    local activeRows = {}
    for _, row in ipairs(ctx.rows) do
      if scopeAllowed[row.targetId] then
        activeRows[#activeRows + 1] = row
      end
    end
    ctx.rows = activeRows
    for listId, list in pairs(ctx.lists) do
      if not scopeAllowed[list.targetId] then
        ctx.lists[listId] = nil
      elseif scope.kind == "decision" then
        local kept = {}
        for _, targetId in ipairs(list.rowTargets) do
          if scopeAllowed[targetId] then
            kept[#kept + 1] = targetId
          end
        end
        list.rowTargets = kept
        list.empty = #kept == 0
      end
    end
  end

  local enabledFocusable = {}
  ctx.focusableSet = {}
  for _, targetId in ipairs(ctx.focusable) do
    if not ctx.disabledTargets[targetId] then
      enabledFocusable[#enabledFocusable + 1] = targetId
      ctx.focusableSet[targetId] = true
    end
  end
  ctx.focusable = enabledFocusable
end

local function applyRailAdjacency(ctx)
  if ctx.railWidth <= 0 then
    return
  end
  for index, name in ipairs(ctx.enabledSections) do
    local targetId = "section:" .. name
    local node = ctx.focusGraph[targetId]
    if node then
      if index > 1 then
        node.up = { "section:" .. ctx.enabledSections[index - 1] }
      end
      if index < #ctx.enabledSections then
        node.down = { "section:" .. ctx.enabledSections[index + 1] }
      end
    end
  end
  local sectionTarget = "section:" .. ctx.section
  for _, targetId in ipairs(ctx.focusable) do
    if targetId:sub(1, 8) ~= "section:" and not ctx.listTargets[targetId] then
      local position = ctx.focusPositions[targetId] or ctx.targets[targetId]
      if position and position.x >= ctx.contentX then
        local node = ctx.focusGraph[targetId]
        if node and ctx.focusGraph[sectionTarget] then
          table.insert(node.left, 1, sectionTarget)
        end
      end
    end
  end
end

local function applyBagTabAdjacency(ctx)
  if ctx.section ~= "Bag" or ctx.bagTabs == nil then
    return
  end
  for index, tabId in ipairs(ctx.bagTabs) do
    local node = ctx.focusGraph[tabId]
    if node ~= nil then
      node.left = { ctx.bagTabs[(index - 2) % #ctx.bagTabs + 1] }
      node.right = { ctx.bagTabs[index % #ctx.bagTabs + 1] }
    end
  end
end

local function applyBagGridAdjacency(ctx)
  if ctx.section ~= "Bag" then
    return
  end
  local view = ctx.view
  local occupied = view.bagPageRows or {}
  local gridTargets = {}
  for index, item in ipairs(occupied) do
    gridTargets[index] = "bag:item:" .. item.item
  end
  local pocketTargets = ctx.bagTabs or {}
  local function nearestInRow(index, rowOffset)
    local row = math.floor((index - 1) / 2) + rowOffset
    if row < 0 or row > 2 then
      return nil
    end
    local column = (index - 1) % 2
    local preferred = row * 2 + column + 1
    if gridTargets[preferred] then
      return gridTargets[preferred]
    end
    local other = row * 2 + (1 - column) + 1
    return gridTargets[other]
  end
  for index, targetId in ipairs(gridTargets) do
    local node = ctx.focusGraph[targetId]
    if node ~= nil then
      local column = (index - 1) % 2
      local rowStart = math.floor((index - 1) / 2) * 2 + 1
      local rowEnd = math.min(rowStart + 1, #gridTargets)
      node.left = { column == 1 and gridTargets[index - 1] or targetId }
      node.right = { column == 0 and rowEnd > index and gridTargets[index + 1] or targetId }
      node.up = { nearestInRow(index, -1) or pocketTargets[math.min(#pocketTargets, column + 1)] or targetId }
      local below = nearestInRow(index, 1)
      if below then
        node.down = { below }
      else
        node.down = { view.bagPage0 + 1 < view.bagPageCount and "bag:page:next" or "bag:add" }
      end
    end
  end
end

local function buildFocusGraph(ctx)
  for targetId, role in pairs(ctx.listRowRoles) do
    ctx.roleById[targetId] = role
  end
  for _, row in ipairs(ctx.rows) do
    ctx.roleById[row.targetId] = row.role
  end
  for _, item in ipairs(ctx.navigation) do
    ctx.roleById[item.targetId] = item.role or "action"
  end
  for _, action in ipairs(ctx.actions) do
    ctx.roleById[action.id] = "action"
  end
  for viewportId, list in pairs(ctx.viewports) do
    assert(
      list.clip and list.rowExtent and list.firstIndex and list.lastIndex and list.rowTargets,
      "scroll viewports publish logical row geometry"
    )
    -- Geometry, hit testing, and focus records cover the materialized window;
    -- the complete logical order stays on the list record for index navigation.
    for _, targetId in ipairs(list.visibleTargets or list.rowTargets) do
      ctx.viewportByTarget[targetId] = viewportId
      ctx.listTargets[targetId] = true
    end
  end
  for _, targetId in ipairs(ctx.focusable) do
    ctx.focusGraph[targetId] = { up = {}, down = {}, left = {}, right = {} }
  end
  local fixedFocusable = {}
  for _, targetId in ipairs(ctx.focusable) do
    if not ctx.listTargets[targetId] then
      fixedFocusable[#fixedFocusable + 1] = targetId
    end
  end
  ctx.fixedFocusable = fixedFocusable
  for _, targetId in ipairs(fixedFocusable) do
    local source = ctx.focusPositions[targetId] or ctx.targets[targetId]
    if source then
      local sourceX, sourceY = source.x + source.width / 2, source.y + source.height / 2
      local candidates = { up = {}, down = {}, left = {}, right = {} }
      for _, candidateId in ipairs(fixedFocusable) do
        local candidate = ctx.focusPositions[candidateId] or ctx.targets[candidateId]
        if candidate and candidateId ~= targetId then
          local dx = candidate.x + candidate.width / 2 - sourceX
          local dy = candidate.y + candidate.height / 2 - sourceY
          local direction = math.abs(dx) > math.abs(dy) and (dx < 0 and "left" or "right")
            or (dy < 0 and "up" or "down")
          candidates[direction][#candidates[direction] + 1] = {
            id = candidateId,
            distance = dx * dx + dy * dy,
          }
        end
      end
      for direction, ordered in pairs(candidates) do
        table.sort(ordered, function(a, b)
          return a.distance < b.distance
        end)
        for _, candidate in ipairs(ordered) do
          ctx.focusGraph[targetId][direction][#ctx.focusGraph[targetId][direction] + 1] = candidate.id
        end
      end
    end
  end
  for _, list in pairs(ctx.viewports) do
    local ordered = {}
    for _, targetId in ipairs(list.visibleTargets or list.rowTargets) do
      if ctx.focusableSet[targetId] then
        ordered[#ordered + 1] = targetId
      end
    end
    for index, targetId in ipairs(ordered) do
      local node = ctx.focusGraph[targetId]
      if index > 1 then
        node.up = { ordered[index - 1] }
      end
      if index < #ordered then
        node.down = { ordered[index + 1] }
      end
    end
    if #ordered > 0 then
      local first, last = ordered[1], ordered[#ordered]
      local firstPosition = ctx.focusPositions[first] or ctx.targets[first]
      local lastPosition = ctx.focusPositions[last] or ctx.targets[last]
      for _, targetId in ipairs(fixedFocusable) do
        local position = ctx.focusPositions[targetId] or ctx.targets[targetId]
        if position and firstPosition and position.y + position.height / 2 < firstPosition.y then
          table.insert(ctx.focusGraph[first].up, targetId)
          table.insert(ctx.focusGraph[targetId].down, first)
        end
        if position and lastPosition and position.y + position.height / 2 > lastPosition.y then
          table.insert(ctx.focusGraph[last].down, targetId)
          table.insert(ctx.focusGraph[targetId].up, last)
        end
      end
    end
  end
  -- Deliberate rail, tab and grid adjacency runs after the general spatial
  -- candidates so the native navigation overrides always win.
  applyRailAdjacency(ctx)
  applyBagTabAdjacency(ctx)
  applyBagGridAdjacency(ctx)
end

local function defaultFocusFor(ctx)
  local view, section, scope = ctx.view, ctx.section, ctx.scope
  local defaultFocus
  if
    scope.kind == "value"
    and view.valueEditor.kind == "number"
    and ctx.numberTooSmall
    and not ctx.focusableSet.cancel
  then
    defaultFocus = nil
  elseif scope.kind == "decision" then
    defaultFocus = "cancel"
  elseif scope.kind == "value" then
    local editor = assert(view.valueEditor)
    if editor.kind == "choice" and ctx.viewports["value:choice"] ~= nil then
      defaultFocus = "list:value:choice"
    elseif editor.kind == "choice" and editor.selectedKey ~= nil then
      defaultFocus = "choice:" .. editor.selectedKey
    elseif editor.kind == "name" then
      local cursor = assert(editor.naming.cursor)
      defaultFocus = tostring(cursor.row) .. ":" .. tostring(cursor.column)
    elseif editor.kind == "number" then
      defaultFocus = "number:place:0:up"
    else
      defaultFocus = ctx.focusGraph["value-draft"] and "value-draft" or "digit-left"
    end
  elseif section == "Player" then
    defaultFocus = "money"
  elseif section == "Location" then
    if
      view.locationNavigation
      and (view.locationNavigation.page == "root" or view.locationNavigation.page == "group")
      and ctx.viewports[view.location.mapListId] ~= nil
    then
      defaultFocus = "list:" .. view.location.mapListId
    else
      defaultFocus = "location:grid"
    end
  elseif section == "Party" then
    for _, targetId in ipairs(ctx.focusOrder) do
      if targetId:match("^party:slot:") then
        defaultFocus = targetId
        break
      end
    end
    defaultFocus = defaultFocus or (ctx.focusGraph["party:add"] and "party:add")
  elseif section == "Progress" then
    defaultFocus = "list:flags"
  elseif section == "Bag" then
    defaultFocus = "bag:pocket:" .. tostring(view.bagPocket)
  end
  if defaultFocus == nil and #ctx.focusOrder == 0 then
    return nil
  end
  if defaultFocus == nil or not ctx.focusGraph[defaultFocus] then
    defaultFocus = assert(
      ctx.focusOrder[1],
      "active focus graph has no nodes: scope=" .. tostring(scope.kind) .. " modal=" .. tostring(view.modal)
    )
  end
  assert(ctx.focusGraph[defaultFocus], "layout default focus must be present in its graph")
  return defaultFocus
end

local function scrollOwnerFor(ctx)
  local view, section, scope = ctx.view, ctx.section, ctx.scope
  if scope.kind ~= "decision" then
    if scope.kind == "value" then
      if view.valueEditor.kind == "choice" and ctx.viewports["value:choice"] ~= nil then
        return "value:choice"
      end
    elseif
      section == "Location"
      and view.location.mapListId ~= nil
      and ctx.viewports[view.location.mapListId] ~= nil
    then
      return view.location.mapListId
    elseif section == "Party" and ctx.viewports.party ~= nil then
      return "party"
    elseif section == "Bag" and ctx.viewports.bag ~= nil then
      return "bag"
    elseif section == "Progress" and ctx.viewports.flags ~= nil then
      return "flags"
    end
  end
  return nil
end

local function buildFocusNavigation(ctx, targetRecords)
  local regions, controls, regionsById = {}, {}, {}
  local partyTab = ctx.view.partyTab or "Stats"
  local decisionIds = {}
  for _, action in ipairs(ctx.decisionActions or {}) do
    decisionIds[action.id] = true
  end
  local function regionFor(targetId)
    if decisionIds[targetId] then
      return "decision:actions"
    end
    if targetId:match("^section:") then
      return "sections"
    end
    local viewportId = ctx.viewportByTarget[targetId]
    for listId, list in pairs(ctx.lists) do
      if targetId == list.targetId or viewportId == list.viewportId then
        return listId
      end
    end
    if targetId:match("^party:slot:") or targetId == "party:add" then
      return "party:members"
    elseif targetId:match("^party:page:") then
      return "party:pager"
    elseif targetId:match("^party:move:") then
      return "party:moves"
    elseif targetId:match("^party:field:") then
      local field = targetId:sub(#"party:field:" + 1)
      if field:match("Iv$") or field:match("Ev$") or field:match("^[iI][vV]:") or field:match("^[eE][vV]:") then
        return "party:stats"
      elseif
        partyTab == "Stats"
        and field ~= "level"
        and field ~= "experience"
        and field ~= "friendship"
        and field ~= "currentHp"
      then
        return "party:stats"
      elseif partyTab == "Stats" then
        return "party:header"
      end
      return "party:details"
    elseif targetId:match("^bag:pocket:") then
      return "bag:pockets"
    elseif targetId:match("^bag:page:") or targetId == "bag:add" then
      return "bag:actions"
    elseif targetId == "save" or targetId == "discard" or targetId == "back" then
      return "global-footer"
    end
    if viewportId ~= nil then
      return "viewport:" .. viewportId
    end
    return "body"
  end
  local function addRegion(id, kind, bounds)
    local region = regionsById[id]
    if region == nil then
      region = { id = id, kind = kind, order = #regions + 1, rect = bounds }
      regionsById[id] = region
      regions[#regions + 1] = region
    elseif bounds ~= nil then
      local left, top = math.min(region.rect.x, bounds.x), math.min(region.rect.y, bounds.y)
      region.rect = {
        x = left,
        y = top,
        width = math.max(region.rect.x + region.rect.width, bounds.x + bounds.width) - left,
        height = math.max(region.rect.y + region.rect.height, bounds.y + bounds.height) - top,
      }
    end
    return region
  end
  for _, targetId in ipairs(ctx.focusOrder) do
    local record = targetRecords[targetId]
    if record ~= nil and record.focusable then
      local id = regionFor(targetId)
      local list = ctx.lists[id]
      local kind = "spatial"
      if list ~= nil then
        kind = "list"
      elseif id == "decision:actions" or id == "party:stats" then
        kind = "table"
      elseif
        id == "party:members"
        or id == "party:pager"
        or id == "party:header"
        or id == "sections"
        or id == "bag:pockets"
      then
        kind = "row"
      elseif id == "party:moves" or id == "party:details" then
        kind = "column"
      end
      local region = addRegion(id, kind, record.rect)
      if list ~= nil then
        region.viewportId = list.viewportId
        region.containerId = list.targetId
        region.logical = {
          count = #list.rowTargets,
          idAt = function(index)
            return list.rowTargets[index]
          end,
          indexOf = function(rowTarget)
            if list.indexByTarget ~= nil then
              return list.indexByTarget[rowTarget]
            end
            for index, idAt in ipairs(list.rowTargets) do
              if rowTarget == idAt then
                return index
              end
            end
            return nil
          end,
        }
        region.defaultId = region.defaultId or list.rowTargets[1] or targetId
      else
        region.defaultId = region.defaultId or targetId
      end
      controls[#controls + 1] = {
        id = targetId,
        rect = record.rect,
        regionId = id,
        order = #controls + 1,
        eligible = record.activationEnabled,
        action = activationAction(ctx.view, targetId),
      }
    end
  end
  local decisionMatrix
  if ctx.decisionList ~= nil then
    decisionMatrix = {}
    for _, row in ipairs(ctx.decisionList.rows) do
      local rowIndex = assert(row.rowIndex, "decision rows publish their visual row")
      decisionMatrix[rowIndex] = decisionMatrix[rowIndex] or {}
      if targetRecords[row.targetId] ~= nil and targetRecords[row.targetId].activationEnabled then
        decisionMatrix[rowIndex][#decisionMatrix[rowIndex] + 1] = row.targetId
      end
    end
    local region = regionsById["decision:actions"]
    if region ~= nil then
      region.logical = { matrix = decisionMatrix }
      region.defaultId = decisionMatrix[1] and decisionMatrix[1][1]
    end
  end
  local partyStats = not ctx.view.partyEmpty and partyTab == "Stats" and ctx.view.partyStats or nil
  local statsMatrix, firstIvTarget, lastIvTarget = {}, nil, nil
  if partyStats ~= nil then
    for _, stat in ipairs(partyStats.rows) do
      local ivTarget = assert(stat.ivEditor.targetId, "Stats rows have an IV target")
      local evTarget = assert(stat.evEditor.targetId, "Stats rows have an EV target")
      assert(stat.ivEditor.editor ~= nil and stat.evEditor.editor ~= nil, "Stats targets are editable")
      statsMatrix[#statsMatrix + 1] = { ivTarget, evTarget }
      firstIvTarget = firstIvTarget or ivTarget
      lastIvTarget = ivTarget
    end
  end
  if #statsMatrix > 0 then
    local viewport = assert(ctx.viewports.party, "Stats regions use the Party viewport")
    local region = regionsById["party:stats"] or addRegion("party:stats", "table", viewport.clip)
    region.kind = "table"
    region.rect = viewport.clip
    region.viewportId = "party"
    region.logical = { matrix = statsMatrix }
    region.defaultId = firstIvTarget
    region.entryUpId = lastIvTarget
  end
  if ctx.partyMoves ~= nil then
    local matrix = {}
    local slots
    if ctx.view.partyEmpty then
      slots = {}
    else
      slots = assert(ctx.view.partyMoves).slots
    end
    for index = 1, #slots, 2 do
      local row = {}
      for column = index, math.min(index + 1, #slots) do
        local slot = slots[column]
        if slot ~= nil and slot.targetId ~= nil then
          row[#row + 1] = slot.targetId
        end
      end
      if #row > 0 then
        matrix[#matrix + 1] = row
      end
    end
    local region = regionsById["party:moves"]
    if region ~= nil then
      region.logical = { matrix = matrix }
      region.viewportId = "party"
    end
  end
  if ctx.partyStrip ~= nil then
    local partyStatsModel = not ctx.view.partyEmpty and partyTab == "Stats" and ctx.view.partyStats or nil
    local headerMatrix, firstHeaderTarget, lastHeaderTarget = {}, nil, nil
    if partyStatsModel ~= nil then
      local columns = assert(ctx.partyHeaderColumns, "Stats layout publishes its physical header columns")
      for factIndex, fact in ipairs(partyStatsModel.header) do
        local rowIndex = math.floor((factIndex - 1) / columns) + 1
        local columnIndex = (factIndex - 1) % columns + 1
        local row = headerMatrix[rowIndex]
        if row == nil then
          row = {}
          for column = 1, columns do
            row[column] = false
          end
          headerMatrix[rowIndex] = row
        end
        if fact.targetId ~= nil and fact.editor ~= nil then
          row[columnIndex] = fact.targetId
          firstHeaderTarget = firstHeaderTarget or fact.targetId
          lastHeaderTarget = fact.targetId
        end
      end
    end
    for _, regionId in ipairs({ "party:members", "party:header", "party:details", "party:pager" }) do
      local region = regionsById[regionId]
      if region == nil and regionId == "party:header" and firstHeaderTarget ~= nil then
        region = addRegion(regionId, "table", assert(ctx.viewports.party).clip)
      end
      if region ~= nil then
        local ids = {}
        if regionId == "party:header" and partyStatsModel ~= nil then
          for _, fact in ipairs(partyStatsModel.header) do
            if fact.targetId ~= nil and fact.editor ~= nil then
              ids[#ids + 1] = fact.targetId
            end
          end
          region.kind = "table"
          region.viewportId = "party"
          region.rect = assert(ctx.viewports.party).clip
          region.logical = {
            matrix = headerMatrix,
            count = #ids,
            idAt = function(index)
              return ids[index]
            end,
            indexOf = function(targetId)
              for index, id in ipairs(ids) do
                if id == targetId then
                  return index
                end
              end
              return nil
            end,
          }
          region.defaultId = firstHeaderTarget
          region.entryUpId = lastHeaderTarget
        elseif regionId == "party:details" and ctx.view.partyDetails ~= nil then
          for _, row in ipairs(ctx.view.partyDetails.rows) do
            if row.role == "action" or row.role == "integer value" or row.role == "named choice" then
              ids[#ids + 1] = row.targetId
            end
          end
          region.viewportId = "party"
        else
          for _, targetId in ipairs(ctx.focusOrder) do
            if targetRecords[targetId] ~= nil and regionFor(targetId) == regionId then
              ids[#ids + 1] = targetId
            end
          end
        end
        if regionId ~= "party:header" then
          region.logical = {
            count = #ids,
            idAt = function(index)
              return ids[index]
            end,
            indexOf = function(targetId)
              for index, id in ipairs(ids) do
                if id == targetId then
                  return index
                end
              end
              return nil
            end,
          }
          region.defaultId = region.defaultId or ids[1]
        end
      end
    end
  end
  for _, regionId in ipairs({ "sections", "bag:pockets" }) do
    local region = regionsById[regionId]
    if region ~= nil then
      local ids = {}
      for _, control in ipairs(controls) do
        if control.regionId == regionId then
          ids[#ids + 1] = control.id
        end
      end
      region.logical = {
        count = #ids,
        wrap = regionId == "bag:pockets",
        idAt = function(index)
          return ids[index]
        end,
        indexOf = function(targetId)
          for index, id in ipairs(ids) do
            if id == targetId then
              return index
            end
          end
          return nil
        end,
      }
      if regionId == "sections" then
        region.kind = ctx.railWidth > 0 and "column" or "row"
      else
        region.kind = "row"
      end
      region.defaultId = region.defaultId or ids[1]
    end
  end
  local function exitTo(regionId, direction, destinationId)
    local region = regionsById[regionId]
    if region ~= nil then
      region.exits = region.exits or {}
      region.exits[direction] = { kind = "region", id = destinationId, entry = "spatial", fallback = "auto" }
    end
  end
  if ctx.partyStrip ~= nil then
    exitTo("party:members", "down", partyTab == "Stats" and "party:header" or "party:moves")
    exitTo("party:header", "up", "party:members")
    exitTo("party:header", "down", "party:stats")
    exitTo("party:stats", "up", "party:header")
    exitTo("party:stats", "down", "party:pager")
    exitTo("party:moves", "up", "party:members")
    exitTo("party:moves", "down", "party:pager")
    exitTo("party:details", "up", "party:members")
    exitTo("party:details", "down", "party:pager")
    exitTo("party:pager", "up", partyTab == "Stats" and "party:stats" or "party:moves")
    exitTo("party:pager", "down", "global-footer")
    exitTo("global-footer", "up", "party:pager")
  end
  if decisionMatrix ~= nil then
    local region = regionsById["decision:actions"]
    if region ~= nil then
      region.kind = "table"
    end
  end
  if ctx.partyStrip ~= nil and partyTab == "Stats" then
    local partyOrder = {
      ["party:members"] = 1,
      ["party:header"] = 2,
      ["party:stats"] = 3,
      ["party:moves"] = 3,
      ["party:details"] = 3,
      ["party:pager"] = 4,
    }
    local insertionIndex
    for index = #regions, 1, -1 do
      if partyOrder[regions[index].id] ~= nil then
        insertionIndex = index
        table.remove(regions, index)
      end
    end
    if insertionIndex ~= nil then
      local orderedParty = {}
      for _, regionId in ipairs({
        "party:members",
        "party:header",
        "party:stats",
        "party:moves",
        "party:details",
        "party:pager",
      }) do
        local region = regionsById[regionId]
        if region ~= nil then
          orderedParty[#orderedParty + 1] = region
        end
      end
      for index, region in ipairs(orderedParty) do
        table.insert(regions, insertionIndex + index - 1, region)
      end
    end
    for index, region in ipairs(regions) do
      region.order = index
    end
  end
  return { regions = regions, controls = controls }
end

local function publishPlan(ctx)
  local view, metrics = ctx.view, ctx.metrics
  for _, targetId in ipairs(ctx.focusable) do
    ctx.focusOrder[#ctx.focusOrder + 1] = targetId
  end
  local defaultFocus = defaultFocusFor(ctx)
  local scrollOwner = scrollOwnerFor(ctx)
  local targetRecords = {}
  for targetId, targetRect in pairs(ctx.targets) do
    local viewportId = ctx.viewportByTarget[targetId]
    local list = viewportId and ctx.viewports[viewportId]
    local containerClip = ctx.containerClips[targetId]
    local role = ctx.roleById[targetId]
      or targetId:match("^choice:") and "choice"
      or targetId:match("^location:tile:") and "location"
      or targetId:match("^%d+:%d+$") and "name"
      or targetId:match("^name%-control:") and "action"
      or targetId:match("^digit%-") and "action"
      or (targetId == "confirm" or targetId == "cancel") and "action"
      or "action"
    targetRecords[targetId] = {
      rect = targetRect,
      clip = list and list.clip or containerClip,
      focusable = ctx.focusableSet[targetId] == true,
      activationEnabled = not ctx.disabledTargets[targetId],
      role = role,
      viewportId = viewportId,
    }
  end
  local focusedValueHelp
  for _, row in ipairs(ctx.rows) do
    local target = targetRecords[row.targetId]
    if target and row.gridCard then
      row.valueText = row.value == nil and nil or tostring(row.value)
    elseif target and row.listSurface then
      if row.value ~= nil then
        row.valueText = type(row.value) == "boolean" and (row.value and "ON" or "OFF") or tostring(row.value)
      end
    elseif target and row.partyField then
      row.valueTruncated = row.valueText ~= nil and metrics.measure(row.valueText) > row.valueRect.width
      if row.valueTruncated and row.targetId == view.focus then
        focusedValueHelp = row.label .. ": " .. row.valueText
      end
    elseif target then
      local rowRect = target.rect
      local inset = row.iconKey and 22 or 4
      row.labelRect = rect(rowRect.x + inset, rowRect.y + 2, rowRect.width - inset - 4, rowRect.height - 4)
      if row.value ~= nil then
        row.valueText = type(row.value) == "boolean" and (row.value and "ON" or "OFF") or tostring(row.value)
        local availableWidth = rowRect.width - inset - 8
        local valueWidth =
          math.min(availableWidth * 0.7, math.max(availableWidth * 0.32, metrics.measure(row.valueText) + 2))
        valueWidth = math.floor(valueWidth)
        row.valueTruncated = metrics.measure(row.valueText) > valueWidth
        local valueX = rowRect.x + rowRect.width - valueWidth - 4
        row.labelRect = rect(rowRect.x + inset, rowRect.y + 2, valueX - rowRect.x - inset - 4, rowRect.height - 4)
        row.valueRect = rect(valueX, rowRect.y + 2, valueWidth, rowRect.height - 4)
        if row.valueTruncated and row.targetId == view.focus then
          focusedValueHelp = row.label .. ": " .. row.valueText
        end
      end
    end
  end
  local focusNavigation = buildFocusNavigation(ctx, targetRecords)
  local modalLayers = view.modalLayers or {}
  local hasLayers = view.modal ~= nil or view.valueEditor ~= nil or #modalLayers > 0
  local renderLayers = {}
  if hasLayers then
    local function copyView()
      local result = {}
      for key, value in pairs(view) do
        result[key] = value
      end
      result.modal = nil
      result.valueEditor = nil
      result.decisionActions = nil
      result.modalLayers = nil
      return result
    end
    local baseView = copyView()
    baseView.scope = { id = "section:" .. tostring(ctx.section), epoch = ctx.scope.epoch, kind = "section" }
    renderLayers[1] = {
      id = "page:" .. tostring(ctx.section),
      kind = "page",
      view = baseView,
      layout = Layout.compute(baseView, ctx.width, ctx.height, metrics),
    }
    local decisionKind = {
      leave = "leave",
      ["bag-item"] = "bag-item",
      ["bag-remove"] = "remove",
      move = "party-move",
    }
    local editorLayerAssigned = false
    for index, layer in ipairs(modalLayers) do
      assert(type(layer.payload) == "table", "modal layer payload is required for its paint plan")
      local layerView = copyView()
      layerView.modal = decisionKind[layer.kind]
      if layerView.modal ~= nil then
        layerView.modalTitle = layer.payload.title or view.modalTitle
        layerView.scope = { id = layer.id, epoch = ctx.scope.epoch, kind = "decision" }
      else
        local layerEditor = layer.payload.snapshot
        if
          layerEditor == nil
          and not editorLayerAssigned
          and view.valueEditor ~= nil
          and view.valueEditor.kind == layer.kind
        then
          layerEditor = view.valueEditor
          editorLayerAssigned = true
        end
        assert(layerEditor ~= nil, "value modal layer payload needs its editor snapshot")
        layerView.valueEditor = layerEditor
        layerView.scope = { id = layer.id, epoch = ctx.scope.epoch, kind = "value" }
      end
      renderLayers[#renderLayers + 1] = {
        id = layer.id,
        kind = layer.kind,
        payload = layer.payload,
        view = layerView,
        layout = Layout.compute(layerView, ctx.width, ctx.height, metrics),
        top = index == #modalLayers,
      }
    end
    if #modalLayers == 0 then
      renderLayers[#renderLayers + 1] = {
        id = view.modal and ("modal:" .. view.modal) or ("value:" .. view.valueEditor.kind),
        kind = view.modal or view.valueEditor.kind,
        view = view,
        layout = nil,
        top = true,
      }
    end
  else
    renderLayers[1] = { id = "page:" .. tostring(ctx.section), kind = "page" }
  end
  return {
    viewport = rect(0, 0, ctx.width, ctx.height),
    shell = ctx.shell,
    content = rect(ctx.contentX, ctx.contentTop, ctx.innerWidth, ctx.contentBottom - ctx.contentTop),
    footer = rect(ctx.contentX, ctx.height - ctx.footerHeight, ctx.innerWidth, ctx.footerHeight),
    rows = ctx.rows,
    focusedValueHelp = focusedValueHelp,
    navigation = ctx.navigation,
    focusOrder = ctx.focusOrder,
    focusGraph = ctx.focusGraph,
    focusNavigation = focusNavigation,
    defaultFocus = defaultFocus,
    targets = targetRecords,
    actions = ctx.actions,
    activeSection = ctx.section,
    locationGrid = ctx.locationGrid,
    locationFocusCue = ctx.locationFocusCue,
    valueModal = ctx.valueModal,
    valueModalValue = ctx.valueModalValue,
    valueModalError = ctx.valueModalError,
    valueModalNotice = ctx.valueModalNotice,
    numberLayout = ctx.numberLayout,
    numberTooSmall = ctx.numberTooSmall,
    choiceTooSmall = ctx.choiceTooSmall,
    decisionList = ctx.decisionList,
    listSurfaces = ctx.listSurfaces,
    partyStatsTable = ctx.partyStatsTable,
    partyStrip = ctx.partyStrip,
    partyMoves = ctx.partyMoves,
    partyPageLabel = ctx.partyPageLabel,
    locationHeader = ctx.locationHeader,
    bagGrid = ctx.bagGrid,
    bagTabs = ctx.bagTabs,
    bagStripTarget = ctx.bagStripTarget,
    bagPageText = ctx.bagPageTextRect,
    bagPage = { index = (view.bagPage0 or 0) + 1, count = view.bagPageCount or 1 },
    scrollOffset = view.scrollOffset or 0,
    viewports = ctx.viewports,
    lists = ctx.lists,
    revealByTarget = ctx.revealByTarget,
    rowMarkers = ctx.rowMarkers,
    rowMarkerRadii = ctx.rowMarkerRadii,
    rowLabelRects = ctx.rowLabelRects,
    scrollOwner = scrollOwner,
    scopeId = ctx.scope.id,
    scopeEpoch = ctx.scope.epoch,
    metrics = metrics,
    renderLayers = renderLayers,
    inputLayerId = renderLayers[#renderLayers].id or ctx.scope.id,
  }
end

function Layout.compute(view, width, height, metrics)
  local ctx = newContext(view, width, height, metrics)
  buildShell(ctx)
  buildNoticeRows(ctx)
  buildSection(ctx)
  buildFooterActions(ctx)
  buildValueScope(ctx)
  buildDecisionScope(ctx)
  finalizeTargets(ctx)
  buildFocusGraph(ctx)
  return publishPlan(ctx)
end

function Layout.hitTest(layout, view, x, y)
  assert(type(layout) == "table" and type(view) == "table")
  if view.valueEditor and not view.modal and view.valueEditor.kind == "name" then
    for _, control in ipairs(view.valueEditor.naming.controls) do
      local targetId = "name-control:" .. control.id
      local target = layout.targets[targetId]
      local targetRect = target and target.rect
      if
        targetRect
        and x >= targetRect.x
        and x < targetRect.x + targetRect.width
        and y >= targetRect.y
        and y < targetRect.y + targetRect.height
      then
        return targetId
      end
    end
  end
  if
    view.modal == nil
    and view.valueEditor == nil
    and view.section == "Location"
    and view.locationNavigation
    and view.locationNavigation.page ~= "root"
    and view.locationNavigation.page ~= "group"
  then
    local grid = layout.locationGrid
    if grid then
      local clip = grid.clip
      if x >= clip.x and x < clip.x + clip.width and y >= clip.y and y < clip.y + clip.height then
        local column = math.floor((x - grid.originX) / grid.tileSize)
        local row = math.floor((y - grid.originY) / grid.tileSize)
        if column >= 0 and column < grid.columns and row >= 0 and row < grid.rows then
          return string.format("location:tile:%d:%d", grid.firstFieldX + column, grid.firstFieldZ + row)
        end
      end
    end
  end
  -- Pointer hits consult only the resolved active target records published
  -- by compute. Scope pruning already removed every background target, so no
  -- second allowlist is rebuilt from the cached row order here. Display-only
  -- records in a value scope never activate.
  local valueScope = view.modal == nil and view.valueEditor ~= nil
  local deferred
  for targetId, target in pairs(layout.targets) do
    if not valueScope or target.focusable then
      local targetRect = target.rect
      local clip = target.clip
      if
        x >= targetRect.x
        and x < targetRect.x + targetRect.width
        and y >= targetRect.y
        and y < targetRect.y + targetRect.height
        and (clip == nil or (x >= clip.x and x < clip.x + clip.width and y >= clip.y and y < clip.y + clip.height))
      then
        if not target.activationEnabled then
          return nil
        end
        -- Decision targets carry their own descriptor enablement and are
        -- never gated on the footer actions that share their spelling.
        if view.modal == nil and (targetId == "save" or targetId == "discard" or targetId == "back") then
          for _, action in ipairs(layout.actions) do
            if action.id == targetId and not action.enabled then
              return nil
            end
          end
        end
        if targetId:match("^list:") then
          deferred = targetId
        else
          return targetId
        end
      end
    end
  end
  return deferred
end

return Layout
