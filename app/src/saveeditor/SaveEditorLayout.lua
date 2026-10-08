-- Computes the editor's canonical logical rows and hit targets.

local Layout = {}
local Decisions = require("app.src.saveeditor.SaveEditorDecisions")
local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local PixelScale = require("libs.ui.src.PixelScale")
local ScrollViewport = require("libs.ui.src.ScrollViewport")
local SaveEditorList = require("app.src.saveeditor.SaveEditorList")
local SaveEditorCard = require("app.src.saveeditor.SaveEditorCard")
local SaveEditorNumberLayout = require("app.src.saveeditor.SaveEditorNumberLayout")

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
-- The extent fits the 0.75-scale body text with a small inset; it grows only when
-- the surrounding metrics require more room for that text.
local function listRowExtent(metrics)
  return math.max(18, math.ceil(metrics.lineHeight * 0.75 + 4))
end

function Layout.preferredListWidth(view, metrics, height)
  local projection, trailingValueWidth
  if view.valueEditor ~= nil and view.valueEditor.kind == "choice" then
    projection = view.valueEditor
  elseif view.section == "Location" and view.location ~= nil and view.locationNavigation ~= nil
    and (view.locationNavigation.page == "root" or view.locationNavigation.page == "group") then
    projection = assert(view.location.mapModel, "Map list sizing uses its indexed projection")
    trailingValueWidth = math.max(metrics.measure("OFF"), metrics.measure("›"), metrics.measure("99"))
  elseif view.section == "Progress" then
    projection = assert(view.flagModel, "Flags list sizing uses its indexed projection")
    trailingValueWidth = metrics.measure("OFF")
  end
  if projection == nil then return nil end
  local rowAt = assert(projection.rowAt, "list sizing reads its bounded row projection")
  local rowHeight = listRowExtent(metrics)
  local query = projection.query or view.query or ""
  local filterText = projection.pending and "Filtering…" or query == "" and "Type to filter" or ("Filter: " .. query)
  local hintText = view.section == "Location" and view.location and view.location.breadcrumb
      and (view.location.breadcrumb .. "  ·  " .. filterText) or filterText
  return SaveEditorList.preferredWidth({
    bounds = { x = 0, y = 0, width = 640, height = height },
    rowCount = projection.count,
    rowHeight = rowHeight,
    gap = 0,
    headerHeight = metrics.lineHeight,
    hasTrailingValue = trailingValueWidth ~= nil,
    trailingValueWidth = trailingValueWidth,
    minimumLabelWidth = metrics.measure(hintText) * 0.75,
    font = { lineHeight = metrics.lineHeight, measure = metrics.measure },
    textScale = 0.75,
    rowAt = function(index)
      local row = assert(rowAt(index), "sampled list rows remain in the current projection")
      local value = trailingValueWidth ~= nil and (view.section == "Location"
          and (row.kind == "group" and "›" or row.section) or (row.value and "ON" or "OFF")) or nil
      return { label = row.displayName or row.label or row.name, value = value }
    end,
  })
end

function Layout.minimumListCanvasWidth(view, metrics, height)
  local bodyGlyphHeight = math.ceil(metrics.lineHeight * 0.75)
  local contentTop = 4 + bodyGlyphHeight + 8 + 2
  if view.section == "Location" or view.section == "Progress" then
    contentTop = contentTop + ApplicationLayout.applicationFrameInsets().top + 8
  end
  local bodyHeight = math.max(1, height - bodyGlyphHeight - 12 - 2 - contentTop)
  if view.valueEditor ~= nil and view.valueEditor.kind == "choice" then bodyHeight = math.max(1, bodyHeight - 40) end
  local listWidth = Layout.preferredListWidth(view, metrics, bodyHeight)
  if listWidth == nil then return nil end
  local stripWidth = 0
  for _, label in ipairs({ "Map", "Player", "Party", "Bag", "Flags" }) do
    stripWidth = stripWidth + metrics.measure(label) * 0.75 + 8
  end
  local actionWidth = 8
  for _, label in ipairs({ "Save", "Discard", view.locationSave and "Cancel check" or "Back" }) do
    actionWidth = actionWidth + math.max(40, metrics.measure(label) * 0.75 + 24)
  end
  return math.min(256, math.max(listWidth, stripWidth, actionWidth) + 16)
end

local function locationReason(reason)
  assert(type(reason) == "string" and reason ~= "", "unavailable tiles carry a policy reason")
  return LOCATION_REASONS[reason] or reason:gsub("_", " ")
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
  local bodyGlyphHeight = math.ceil(metrics.lineHeight * 0.75)
  local footerHeight = bodyGlyphHeight + 12
  local hasRail = wideShell
  local railWidth = hasRail and 88 or 0
  local railButtonHeight = math.min(bodyGlyphHeight + 12, metrics.lineHeight + 16)
  local railStep = railButtonHeight + 4
  railButtonHeight = math.min(bodyGlyphHeight + 12, metrics.lineHeight + 16)
  railStep = railButtonHeight + 4
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
  local preferredListWidth = Layout.preferredListWidth(view, metrics, listHeight)
  return {
    view = view,
    width = width,
    height = height,
    metrics = metrics,
    scope = scope,
    margin = margin,
    compactBag = width <= 280 and view.section == "Bag",
    footerHeight = footerHeight,
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
    partyPageLabel = nil,
    focusableSet = {},
    rowMarkers = {},
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
  local shellX, margin, innerWidth, contentX = ctx.shellX, ctx.margin, ctx.innerWidth, ctx.contentX
  if railWidth > 0 then
    for index, name in ipairs(ctx.enabledSections) do
      local id = "section:" .. name
      ctx.targets[id] = rect(ctx.railX, margin + (index - 1) * railStep, railWidth, railButtonHeight)
      ctx.navigation[#ctx.navigation + 1] =
        { role = "action", targetId = id, id = id, label = name, active = name == ctx.section }
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
        { role = "action", targetId = id, id = id, label = name, active = name == ctx.section }
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
  local mapList = SaveEditorList.resolve({
    bounds = mapBounds,
    rowCount = mapModel.count,
    rowHeight = compactRowExtent,
    gap = 0,
    maxWidth = preferredListWidth or innerWidth,
    headerHeight = metrics.lineHeight,
    scrollOffset = storedMapOffset,
  })
  local mapOffset =
    ScrollViewport.clamp(storedMapOffset, mapList.contentHeight, mapList.content.height - mapList.header.height)
  ctx.listSurfaces[#ctx.listSurfaces + 1] = mapList.surface
  local mapViewport = registerList(
    ctx,
    listId,
    listId,
    mapList,
    mapRowTargets,
    view.query,
    mapModel.indexByTarget
  )
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
    ctx.rowMarkers[id] = rect(row.markerRect.x, row.markerRect.y - mapOffset, row.markerRect.width, row.markerRect.height)
    ctx.rowLabelRects[id] = rect(row.markerRect.x + 6, y + 3, row.rect.width * 0.58 - 6, compactRowExtent - 6)
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
      value = map.kind == "group" and "›" or map.section,
      labelRect = ctx.rowLabelRects[id],
      valueRect = rect(row.rect.x + row.rect.width * 0.62, y + 3, row.rect.width * 0.34, compactRowExtent - 6),
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
  local leftText = string.format("%s  X %d  Z %d", mapLabel, cursor.fieldX, cursor.fieldZ)
  local rightText
  local serviceStatus = location.status or {}
  if serviceStatus.state == "failed" then
    rightText = locationReason(assert(serviceStatus.reason, "failed preparation carries its cause"))
  else
    for _, tile in ipairs(location.tiles or {}) do
      if tile.fieldX == cursor.fieldX and tile.fieldZ == cursor.fieldZ then
        if tile.selectable == false then
          rightText = locationReason(assert(tile.reason, "blocked grid tiles carry their policy reason"))
        end
        break
      end
    end
  end
  local leftWidth = math.min(metrics.measure(leftText), headerRect.width)
  local leftRect = rect(headerRect.x, headerRect.y, leftWidth, headerHeight)
  local rightWidth = 0
  if rightText ~= nil then
    rightWidth = math.min(metrics.measure(rightText), math.max(0, headerRect.width - leftWidth - 8))
  end
  local rightRect = rect(headerRect.x + headerRect.width - rightWidth, headerRect.y, rightWidth, headerHeight)
  ctx.locationHeader = {
    lineRect = headerRect,
    leftText = leftText,
    rightText = rightText,
    leftRect = leftRect,
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
  local flagList = SaveEditorList.resolve({
    bounds = rect(contentX, bodyTop, innerWidth, bodyHeight),
    rowCount = flagModel.count,
    rowHeight = compactRowExtent,
    gap = 0,
    maxWidth = preferredListWidth or innerWidth,
    headerHeight = metrics.lineHeight,
    scrollOffset = storedFlagOffset,
  })
  local flagOffset =
    ScrollViewport.clamp(storedFlagOffset, flagList.contentHeight, flagList.content.height - flagList.header.height)
  local contentExtent = flagList.contentHeight
  ctx.listSurfaces[#ctx.listSurfaces + 1] = flagList.surface
  local flagViewport = registerList(ctx, "flags", "flags", flagList, flagRowTargets, view.query, view.flagIndexByTarget)
  ctx.lists.flags.pending = flagModel.pending
  local flagScroll = makeViewport(flagViewport, flagOffset, contentExtent, compactRowExtent, 0, flagModel.count, flagRowTargets)
  flagScroll.visibleTargets = {}
  ctx.viewports.flags = flagScroll
  for _, row in ipairs(flagList.rows) do
    local flag = assert(flagModel.rowAt(row.index), "visible flag rows resolve to their logical payload")
    local id = assert(flagModel.idAt(row.index), "visible flag rows keep their logical identity")
    ctx.listRowRoles[id] = "toggle"
    local y = row.rect.y - flagOffset
    ctx.targets[id] = rect(row.rect.x, y, row.rect.width, compactRowExtent - 2)
    ctx.rowMarkers[id] = rect(row.markerRect.x, row.markerRect.y - flagOffset, row.markerRect.width, row.markerRect.height)
    ctx.rowLabelRects[id] = rect(row.markerRect.x + 6, y + 3, row.rect.width - 18, compactRowExtent - 6)
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
  local stripHeight = math.max(34, metrics.lineHeight + 20)
  local stripY = ctx.contentTop
  local cellWidth = innerWidth / 6
  local stripSlots = {}
  for position, slot in ipairs(selector.slots) do
    local cell = rect(contentX + (position - 1) * cellWidth + 1, stripY, cellWidth - 2, stripHeight - 2)
    local entry = { kind = slot.kind, slot0 = slot.slot0, rect = cell, active = slot.active == true }
    if slot.kind == "member" then
      local targetId = "party:slot:" .. assert(slot.slot0, "member positions carry their slot")
      entry.targetId = targetId
      entry.iconKey = slot.iconKey
      entry.label = slot.label
      entry.level = slot.level
      entry.iconRect = rect(cell.x + 2, cell.y + 2, cell.height - 4, cell.height - 4)
      entry.textRect =
        rect(cell.x + cell.height, cell.y + 2, cell.x + cell.width - 4 - (cell.x + cell.height), cell.height - 4)
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
  local labelWidth = math.min(120, math.max(64, innerWidth - arrowWidth * 2 - 16))
  local pagerX = contentX + math.max(0, (innerWidth - arrowWidth * 2 - labelWidth - 8) / 2)
  ctx.targets["party:page:previous"] = rect(pagerX, pageY, arrowWidth, pageHeight)
  addFocusable(ctx, "party:page:previous")
  ctx.partyPageLabel = { text = tab, rect = rect(pagerX + arrowWidth + 4, pageY, labelWidth, pageHeight) }
  ctx.targets["party:page:next"] = rect(pagerX + arrowWidth + 4 + labelWidth + 4, pageY, arrowWidth, pageHeight)
  addFocusable(ctx, "party:page:next")
  if tab == "Stats" then
    ctx.disabledTargets["party:page:previous"] = true
  elseif tab == "Details" then
    ctx.disabledTargets["party:page:next"] = true
  end
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
    local factColumns = innerWidth >= 480 and 5 or innerWidth >= 300 and 3 or 2
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
    for _, slot in ipairs(view.partyMoves.slots) do
      bodyItems[#bodyItems + 1] = { kind = "move", slot = slot, extent = math.max(24, metrics.lineHeight + 12) }
    end
  elseif tab == "Details" and view.partyDetails ~= nil then
    for _, row in ipairs(view.partyDetails.rows) do
      local extent = row.role == "action" and metrics.lineHeight + 33 or metrics.lineHeight + 8
      bodyItems[#bodyItems + 1] = { kind = "detail", row = row, extent = extent }
    end
  end
  local tops, contentExtent = {}, 0
  for index, item in ipairs(bodyItems) do
    tops[index] = contentExtent
    contentExtent = contentExtent + item.extent
  end
  local bodyHeight = math.max(1, bodyBottom - bodyTop)
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
    elseif item.kind == "move" and item.slot.targetId ~= nil then
      rowTargets[#rowTargets + 1] = item.slot.targetId
    elseif item.kind == "detail" then
      rowTargets[#rowTargets + 1] = item.row.targetId
    end
  end
  local partyViewport = rect(contentX, bodyTop, innerWidth, bodyHeight)
  ctx.viewports.party = makeViewport(partyViewport, offset, contentExtent, 20, 0, #bodyItems, rowTargets)
  local statHeaders, statRows, moveSlots = {}, {}, {}
  for index, item in ipairs(bodyItems) do
    local y = bodyTop + tops[index] - offset
    local fits = y >= bodyTop and y + item.extent <= bodyBottom
    local overlaps = y < bodyBottom and y + item.extent > bodyTop
    if fits or (item.kind == "facts" and overlaps) then
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
          if cellRect.y >= bodyTop and cellRect.y + cellRect.height <= bodyBottom then
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
      elseif item.kind == "move" then
        local slot = item.slot
        local buttonRect = rect(contentX, y, innerWidth, item.extent - 2)
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
      else
        assert(item.kind == "detail", "party body rows have a known kind")
        local row = item.row
        local bandHeight = row.role == "action" and item.extent or item.extent - 2
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
  local textScale = compactBag and 0.5 or 0.75
  local lineHeight = math.max(1, math.floor(metrics.lineHeight * textScale + 0.5))
  for index, item in ipairs(view.bagPageRows or {}) do
    local cell = cells[index]
    local iconSize = cell.rect.height > 32 and 24 or 16
    local iconRect = rect(cell.rect.x + 4, cell.rect.y + (cell.rect.height - iconSize) / 2, iconSize, iconSize)
    local quantityWidth = math.ceil(metrics.measure("x" .. tostring(item.quantity)) * textScale) + 6
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
    return SaveEditorList.resolve({
      bounds = choiceBounds,
      rowCount = dialog.count,
      rowHeight = compactRowExtent,
      gap = 0,
      maxWidth = preferredListWidth or innerWidth,
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
    ctx.rowLabelRects[id] = rect(row.markerRect.x + 6, row.rect.y - offset + 3, row.rect.width - 18, row.rect.height - 6)
    if dialog.pending then
      ctx.disabledTargets[id] = true
    end
    choiceScroll.visibleTargets[#choiceScroll.visibleTargets + 1] = id
  end
  local footerWidth = math.max(1, math.floor(innerWidth / 2))
  ctx.targets.confirm = rect(contentX, contentBottom - 34, footerWidth - 2, 34)
  ctx.targets.cancel = rect(contentX + footerWidth, contentBottom - 34, innerWidth - footerWidth, 34)
  addFocusable(ctx, "confirm")
  addFocusable(ctx, "cancel")
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
  local contentX, contentTop, contentBottom, innerWidth = ctx.contentX, ctx.contentTop, ctx.contentBottom, ctx.innerWidth
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
    ctx.valueModalNotice = rect(contentX + 4, contentTop + math.floor((contentBottom - contentTop) / 2), innerWidth - 8, metrics.lineHeight)
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
  local choices = {}
  for _, action in ipairs(decisionActions) do
    choices[#choices + 1] = action.id
  end
  local buttonHeight = metrics.lineHeight + 34
  local promptHeight = math.max(1, metrics.lineHeight)
  local needed = promptHeight + 4 + #choices * buttonHeight + (#choices - 1) * 4 + 8
  if contentBottom - contentTop < needed then
    buttonHeight = 26
    needed = promptHeight + 4 + #choices * buttonHeight + (#choices - 1) * 4 + 8
  end
  local modalHeight = math.min(contentBottom - contentTop, needed)
  local surface = SaveEditorList.resolve({
    bounds = rect(
      contentX,
      contentTop + math.floor((contentBottom - contentTop - modalHeight) / 2),
      innerWidth,
      modalHeight
    ),
    rowCount = #choices,
    rowHeight = buttonHeight,
    gap = 4,
    maxWidth = 360,
  })
  ctx.decisionList = {
    surface = surface.surface,
    prompt = rect(surface.content.x, surface.content.y, surface.content.width, promptHeight),
    rows = {},
  }
  for index, action in ipairs(assert(decisionActions, "the decision surface needs its described actions")) do
    local id = action.id
    local buttonWidth = math.min(128, surface.content.width)
    local rowRect = rect(
      surface.content.x + math.floor((surface.content.width - buttonWidth) / 2),
      surface.content.y + promptHeight + 4 + (index - 1) * (buttonHeight + 4),
      buttonWidth,
      buttonHeight
    )
    ctx.decisionList.rows[index] = {
      targetId = id,
      label = action.label,
      semantic = action.semantic,
      enabled = action.enabled,
      rect = rowRect,
    }
    if action.enabled then
      ctx.targets[id] = rowRect
      ctx.disabledTargets[id] = nil
      addFocusable(ctx, id)
    else
      ctx.disabledTargets[id] = true
    end
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
      for _, targetId in ipairs(assert(editor.rowTargets, "the choice dialog carries its cached logical row order")) do
        scopeAllowed[targetId] = true
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
  if noFocusableNumberFallback then
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
    elseif section == "Location" and view.location.mapListId ~= nil and ctx.viewports[view.location.mapListId] ~= nil then
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
  local function regionFor(targetId, record)
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
    elseif targetId:match("^bag:pocket:") then
      return "bag:pockets"
    elseif targetId:match("^bag:page:") or targetId == "bag:add" then
      return "bag:actions"
    elseif targetId == "save" or targetId == "discard" or targetId == "cancel" then
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
  for targetId, record in pairs(targetRecords) do
    if record.focusable then
      local id = regionFor(targetId, record)
      local list = ctx.lists[id]
      local region = addRegion(id, list ~= nil and "list" or "spatial", record.rect)
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
        action = { kind = "target", targetId = targetId },
      }
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
  local renderLayers = { { id = "page:" .. tostring(ctx.section), kind = "page" } }
  for index, layer in ipairs(view.modalLayers or {}) do
    renderLayers[#renderLayers + 1] = {
      id = layer.id,
      kind = layer.kind,
      payload = layer.payload,
      top = index == #(view.modalLayers or {}),
    }
  end
  if #renderLayers == 1 and (view.modal ~= nil or view.valueEditor ~= nil) then
    renderLayers[2] = {
      id = view.modal and ("modal:" .. view.modal) or ("value:" .. view.valueEditor.kind),
      kind = view.modal or view.valueEditor.kind,
      top = true,
    }
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
    rowMarkers = ctx.rowMarkers,
    rowLabelRects = ctx.rowLabelRects,
    scrollOwner = scrollOwner,
    scopeId = ctx.scope.id,
    scopeEpoch = ctx.scope.epoch,
    metrics = metrics,
    renderLayers = renderLayers,
    inputLayerId = renderLayers[#renderLayers].id or scope.id,
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
