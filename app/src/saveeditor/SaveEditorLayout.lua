-- Computes the editor's canonical logical rows and hit targets.

local Layout = {}
local PixelScale = require("libs.ui.src.PixelScale")
local ScrollViewport = require("libs.ui.src.ScrollViewport")
local SaveEditorList = require("app.src.saveeditor.SaveEditorList")
local SaveEditorCard = require("app.src.saveeditor.SaveEditorCard")

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

function Layout.compute(view, width, height, metrics)
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
  local margin = width <= 280 and 4 or 12
  local compactParty = width < 400
    and view.section == "Party"
    and (view.partyPage == "detail" or view.partyPage == "draft")
  local compactBag = width <= 280 and view.section == "Bag"
  local footerHeight = compactParty and width <= 280 and 38
    or compactBag and 38
    or math.max(40, metrics.lineHeight + 24)
  local hasRail = width >= 400
  local railWidth = hasRail and 88 or 0
  local railButtonHeight = 34
  local railStep = railButtonHeight + 4
  if railWidth > 0 and height >= 360 then
    railButtonHeight, railStep = 56, 60
  end
  local rows, targets, focusable, disabledTargets, focusPositions = {}, {}, {}, {}, {}
  local locationGrid
  local locationFocusCue
  local valueModal
  local valueModalValue
  local valueModalError
  local decisionList
  local locationStatus
  local bagGrid, bagTabs, bagStripTarget, bagPageTextRect
  local listSurfaces = {}
  local partyStatsTable
  local focusableSet = {}
  local function addFocusable(targetId)
    if not focusableSet[targetId] then
      focusableSet[targetId] = true
      focusable[#focusable + 1] = targetId
    end
  end
  local shellWidth = hasRail and math.min(width - margin * 2, 640) or width
  local shellX = hasRail and PixelScale.snapLogical((width - shellWidth) / 2) or 0
  local shell = rect(shellX, 0, shellWidth, height)
  local innerWidth = math.max(1, shellWidth - margin * 2 - (railWidth > 0 and railWidth + 6 or 0))
  local contentX = shellX + margin + (railWidth > 0 and railWidth + 6 or 0)
  local contentTop = margin
  local footerReserve = view.modal ~= nil and (margin + 2) or footerHeight
  local contentBottom = math.max(contentTop + 1, height - footerReserve - 2)
  local section = view.section or "Player"
  local rowHeight = math.max(30, metrics.lineHeight + 16)
  local enabledSections = { "Location", "Player", "Party", "Bag", "Progress" }
  local navigation = {}
  if railWidth > 0 then
    for index, name in ipairs(enabledSections) do
      local id = "section:" .. name
      targets[id] = rect(shellX + margin, margin + (index - 1) * railStep, railWidth, railButtonHeight)
      navigation[#navigation + 1] = { role = "action", targetId = id, id = id, label = name, active = name == section }
      addFocusable(id)
    end
  else
    local stripHeight = math.max(30, metrics.lineHeight + 16)
    local cellWidth = innerWidth / #enabledSections
    for index, name in ipairs(enabledSections) do
      local id = "section:" .. name
      targets[id] = rect(contentX + (index - 1) * cellWidth, 0, cellWidth, stripHeight)
      navigation[#navigation + 1] = { role = "action", targetId = id, id = id, label = name, active = name == section }
      addFocusable(id)
    end
    contentTop = stripHeight
  end
  local function addRow(role, id, label, value, enabled)
    local y = contentTop + (#rows * rowHeight)
    if y + rowHeight > contentBottom then
      return
    end
    local rowRect = rect(contentX, y, innerWidth, rowHeight - 2)
    local row = { role = role, targetId = id, id = id, label = label, value = value, enabled = enabled ~= false }
    rows[#rows + 1] = row
    targets[id] = rowRect
    if
      role == "action"
      or role == "toggle"
      or role == "integer value"
      or role == "named choice"
      or id:match("^party:slot:")
      or id:match("^bag:item:")
    then
      addFocusable(id)
    end
    if enabled == false then
      disabledTargets[id] = true
    end
    if id:match("^party:empty%-slot:") then
      disabledTargets[id] = true
    end
  end
  local function placeRow(role, id, label, value, enabled, y, rowExtent)
    local rowRect = rect(contentX, y, innerWidth, rowExtent - 2)
    rows[#rows + 1] = { role = role, targetId = id, id = id, label = label, value = value, enabled = enabled ~= false }
    targets[id] = rowRect
    if
      role == "action"
      or role == "toggle"
      or role == "integer value"
      or role == "named choice"
      or id:match("^party:slot:")
      or id:match("^bag:item:")
    then
      addFocusable(id)
    end
    if enabled == false or id:match("^party:empty%-slot:") then
      disabledTargets[id] = true
    end
  end
  local viewports = {}
  local lists = {}
  local listRowRoles = {}
  local containerClips = {}
  local function registerList(id, viewportId, resolved, rowTargets, query)
    local targetId = "list:" .. id
    local ordered = {}
    for index, rowTarget in ipairs(rowTargets) do
      ordered[index] = rowTarget
    end
    local content, header = resolved.content, resolved.header
    local rowClip =
      rect(content.x, content.y + header.height, content.width, math.max(1, content.height - header.height))
    lists[id] = {
      id = id,
      targetId = targetId,
      viewportId = viewportId,
      rowTargets = ordered,
      filterable = true,
      query = query or "",
      empty = #ordered == 0,
      surfaceRect = resolved.surface,
      hintRect = { x = header.x, y = header.y, width = header.width, height = header.height },
    }
    targets[targetId] = rect(resolved.surface.x, resolved.surface.y, resolved.surface.width, resolved.surface.height)
    focusPositions[targetId] = targets[targetId]
    containerClips[targetId] = rowClip
    addFocusable(targetId)
    return rowClip
  end
  local partyGrid
  local layoutPartySummary
  local layoutPartyHelp

  local partySummary
  if section == "Party" and (view.partyPage == "detail" or view.partyPage == "draft") then
    if not hasRail then
      local summaryHeight = metrics.lineHeight + 4
      partySummary = {
        inline = true,
        rect = rect(contentX, contentTop, innerWidth, summaryHeight),
        iconRect = rect(contentX, contentTop + 1, 32, summaryHeight - 2),
        textRect = rect(contentX + 36, contentTop + 2, innerWidth - 38, summaryHeight - 4),
      }
      contentTop = contentTop + summaryHeight + 3
    elseif hasRail then
      local summaryHeight = math.min(48, math.max(42, contentBottom - contentTop - rowHeight * 2))
      partySummary = {
        rect = rect(contentX, contentTop, innerWidth, summaryHeight),
        iconRect = rect(contentX + 4, contentTop + 3, summaryHeight - 6, summaryHeight - 6),
        textRect = rect(
          contentX + summaryHeight + 2,
          contentTop + 4,
          innerWidth - summaryHeight - 6,
          summaryHeight - 8
        ),
      }
      contentTop = contentTop + summaryHeight + 3
    end
  end
  if section == "Party" and (view.partyPage == "detail" or view.partyPage == "draft") and view.partySubpages ~= nil then
    local labels = view.partySubpages
    local tabX, tabY = contentX, contentTop
    local tabOffset = 0
    local compactTabs = width < 400
    if compactTabs then
      local revealedSubpage = view.partySubpage
      local focusedSubpage = view.focus and view.focus:match("^party:subpage:(.+)$")
      if focusedSubpage ~= nil then
        revealedSubpage = focusedSubpage
      end
      local selectedIndex, totalWidth = 1, 0
      for index, label in ipairs(labels) do
        local tabWidth = math.ceil(metrics.measure(label) + 22)
        if label == revealedSubpage then
          selectedIndex = index
        end
        totalWidth = totalWidth + tabWidth
      end
      local precedingWidth = 0
      for index = 1, selectedIndex - 1 do
        precedingWidth = precedingWidth + math.ceil(metrics.measure(labels[index]) + 22)
      end
      local selectedWidth = math.ceil(metrics.measure(labels[selectedIndex]) + 22)
      tabOffset =
        math.min(math.max(0, precedingWidth + selectedWidth - innerWidth), math.max(0, totalWidth - innerWidth))
    end
    for _, label in ipairs(labels) do
      local id = "party:subpage:" .. label
      local tabWidth = math.ceil(metrics.measure(label) + 22)
      assert(tabWidth <= innerWidth, "party subpage label must fit within the available layout width")
      if not compactTabs and tabX > contentX and tabX + tabWidth > contentX + innerWidth then
        tabX = contentX
        tabY = tabY + rowHeight + 2
      end
      local tab = rect(tabX - tabOffset, tabY, tabWidth, rowHeight)
      if not compactTabs or tab.x >= contentX and tab.x + tab.width <= contentX + innerWidth then
        targets[id] = tab
      end
      focusPositions[id] = tab
      addFocusable(id)
      tabX = tabX + tabWidth
    end
    contentTop = tabY + rowHeight + 2
  end

  if view.notice then
    addRow("warning", "notice", view.notice, nil)
  end
  if view.errorMessage and view.status == "ready" then
    addRow("warning", "error-notice", view.errorMessage, nil)
  end

  if view.status == "opening" then
    addRow("read-only value", "opening", "Preparing save editor", view.message or "Waiting for field data")
  elseif view.status == "error" then
    addRow("warning", "error", "Save unavailable", view.message or "Could not open save")
    addRow("action", "retry", "Retry", "", true)
  elseif section == "Location" then
    local location = assert(view.location, "Location needs the headless service snapshot")
    local locationNav = assert(view.locationNavigation, "Location needs controller navigation state")
    local maps = assert(location.maps, "Location needs copied structural map summaries")
    local page = locationNav.page
    local wide = width >= 640
    local listWidth = wide and math.min(200, math.max(144, math.floor(innerWidth * 0.24))) or 0
    local gridLeft = contentX
    if wide then
      gridLeft = contentX + listWidth + 8
      local mapOffset = locationNav.mapOffset or 0
      local mapBounds = rect(contentX, contentTop, listWidth, contentBottom - contentTop)
      local mapList = SaveEditorList.resolve({
        bounds = mapBounds,
        rowCount = #maps,
        rowHeight = rowHeight,
        gap = 0,
        maxWidth = listWidth,
        headerHeight = metrics.lineHeight,
      })
      listSurfaces[#listSurfaces + 1] = mapList.surface
      local mapRowTargets = {}
      for index, map in ipairs(maps) do
        mapRowTargets[index] = "location:map:" .. map.mapId
        listRowRoles[mapRowTargets[index]] = "list"
      end
      local mapViewport = registerList("location:map-list", "location:map-list", mapList, mapRowTargets, view.query)
      mapOffset = ScrollViewport.clamp(mapOffset, mapList.contentHeight, mapViewport.height)
      local rowTargets = mapRowTargets
      for index, map in ipairs(maps) do
        local id = "location:map:" .. map.mapId
        listRowRoles[id] = "list"
        local row = mapList.rows[index].rect
        local y = row.y - mapOffset
        targets[id] = rect(row.x, y, row.width, rowHeight - 2)
        focusPositions[id] = rect(row.x, y, row.width, row.height)
        addFocusable(id)
        if y >= mapViewport.y and y + rowHeight <= mapViewport.y + mapViewport.height then
          navigation[#navigation + 1] = {
            role = "list",
            targetId = id,
            label = map.displayName,
          }
        end
      end
      viewports["location:map-list"] =
        makeViewport(mapViewport, mapOffset, mapList.contentHeight, rowHeight, 0, #maps, rowTargets)
    elseif page == "map-list" then
      local pickerHeight, backHeight = 26, 26
      local rowTop = contentTop + pickerHeight + 2
      local mapBounds = rect(contentX, rowTop, innerWidth, math.max(1, contentBottom - backHeight - rowTop))
      local mapList = SaveEditorList.resolve({
        bounds = mapBounds,
        rowCount = #maps,
        rowHeight = rowHeight,
        gap = 0,
        maxWidth = innerWidth,
        headerHeight = metrics.lineHeight,
      })
      listSurfaces[#listSurfaces + 1] = mapList.surface
      local rowTargets = {}
      for index, map in ipairs(maps) do
        rowTargets[index] = "location:map:" .. map.mapId
      end
      local mapViewport = registerList("location:map-list", "location:map-list", mapList, rowTargets, view.query)
      local mapOffset = ScrollViewport.clamp(locationNav.mapOffset or 0, mapList.contentHeight, mapViewport.height)
      targets["location:map-picker"] = rect(contentX, contentTop, innerWidth, pickerHeight)
      navigation[#navigation + 1] = {
        role = "action",
        targetId = "location:map-picker",
        label = "Change Map",
      }
      addFocusable("location:map-picker")
      for index, map in ipairs(maps) do
        local id = "location:map:" .. map.mapId
        rowTargets[index] = id
        listRowRoles[id] = "list"
        local row = mapList.rows[index].rect
        local y = row.y - mapOffset
        targets[id] = rect(row.x, y, row.width, rowHeight - 2)
        addFocusable(id)
        if y >= mapViewport.y and y + rowHeight <= mapViewport.y + mapViewport.height then
          rows[#rows + 1] = {
            role = "list",
            listSurface = true,
            targetId = id,
            label = map.displayName,
            value = map.section,
            labelRect = rect(row.x + 6, y + 3, row.width * 0.58, rowHeight - 6),
            valueRect = rect(row.x + row.width * 0.62, y + 3, row.width * 0.34, rowHeight - 6),
          }
        end
      end
      viewports["location:map-list"] =
        makeViewport(mapViewport, mapOffset, mapList.contentHeight, rowHeight, 0, #maps, rowTargets)
      targets["location:map-back"] = rect(contentX, contentBottom - backHeight, innerWidth, backHeight)
      navigation[#navigation + 1] = { role = "action", targetId = "location:map-back", label = "Back" }
      addFocusable("location:map-back")
    end

    if page ~= "map-list" or wide then
      local controlHeight = math.min(22, rowHeight)
      local controlY = contentTop
      local controlX = gridLeft
      local gridWidth = math.max(1, contentX + innerWidth - gridLeft)
      local pickerWidth = math.min(gridWidth * 0.55, 128)
      targets["location:map-picker"] = rect(controlX, controlY, pickerWidth, controlHeight)
      navigation[#navigation + 1] = {
        role = "action",
        targetId = "location:map-picker",
        label = "Change Map",
      }
      addFocusable("location:map-picker")

      local lineGap = 1
      local statusHeight = metrics.lineHeight * 2 + lineGap
      local gridY = controlY + controlHeight + 2
      local statusBoundsY = contentBottom - statusHeight
      local gridStatusGap = 1
      local gridClip = rect(gridLeft, gridY, gridWidth, statusBoundsY - gridY - gridStatusGap)
      assert(gridClip.height > 0, "Location grid needs room above its measured status block")
      local tileSize = 16
      local columns = math.max(1, math.floor(gridClip.width / tileSize))
      local gridRows = math.max(1, math.floor(gridClip.height / tileSize))
      local center = assert(locationNav.center, "Location needs a grid center")
      local firstFieldX = center.fieldX - math.floor(columns / 2)
      local firstFieldZ = center.fieldZ - math.floor(gridRows / 2)
      local renderedWidth, renderedHeight = columns * tileSize, gridRows * tileSize
      locationGrid = {
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

      local statusX, statusWidth = gridLeft, gridWidth
      local mapLine = rect(statusX, statusBoundsY, statusWidth, metrics.lineHeight)
      local summaryLine = rect(statusX, mapLine.y + metrics.lineHeight + lineGap, statusWidth, metrics.lineHeight)
      locationStatus = {
        mapLine = mapLine,
        summaryLine = summaryLine,
        bounds = rect(statusX, statusBoundsY, statusWidth, statusHeight),
      }
      assert(summaryLine.y + summaryLine.height == contentBottom, "Location status block ends at the content boundary")

      addFocusable("location:grid")
      focusPositions["location:grid"] = gridClip
      local cursor = locationNav.cursor
      if cursor ~= nil then
        local id = string.format("location:tile:%d:%d", cursor.fieldX, cursor.fieldZ)
        addFocusable(id)
      end
    end
    if locationNav.contentFocus == "map-list" then
      local viewport = viewports["location:map-list"]
      locationFocusCue = viewport and viewport.clip or nil
    elseif locationNav.contentFocus == "grid" then
      locationFocusCue = locationGrid and locationGrid.clip or nil
    end
  elseif section == "Player" then
    local snapshot = assert(view.session)
    addRow("read-only value", "player", "Player", snapshot.playerName)
    addRow("integer value", "money", "Money", snapshot.money)
    addRow("named choice", "dialogue-frame", "Dialogue frame", "Frame " .. tostring(snapshot.frameIndex + 1))
  elseif section == "Progress" then
    local flags = view.flagRows or {}
    local flagOffset = view.scrollOffsets and view.scrollOffsets.flags or 0
    local bodyTop = contentTop + #rows * rowHeight
    local bodyHeight = math.max(0, contentBottom - bodyTop)
    local flagList = SaveEditorList.resolve({
      bounds = rect(contentX, bodyTop, innerWidth, bodyHeight),
      rowCount = #flags,
      rowHeight = rowHeight,
      gap = 0,
      maxWidth = innerWidth,
      headerHeight = metrics.lineHeight,
    })
    local contentExtent = flagList.contentHeight
    listSurfaces[#listSurfaces + 1] = flagList.surface
    local rowTargets = {}
    for index, flag in ipairs(flags) do
      rowTargets[index] = "flag:" .. flag.name
      listRowRoles[rowTargets[index]] = "toggle"
    end
    local flagViewport = registerList("flags", "flags", flagList, rowTargets, view.query)
    flagOffset = ScrollViewport.clamp(flagOffset, contentExtent, flagViewport.height)
    viewports.flags = makeViewport(flagViewport, flagOffset, contentExtent, rowHeight, 0, #flags, rowTargets)
    local first, last = ScrollViewport.visibleRange(flagOffset, flagViewport.height, rowHeight, 0, #flags)
    for index, flag in ipairs(flags) do
      local id = "flag:" .. flag.name
      addFocusable(id)
      local flagRow = flagList.rows[index].rect
      local y = flagRow.y - flagOffset
      targets[id] = rect(flagRow.x, y, flagRow.width, rowHeight - 2)
      focusPositions[id] = rect(flagRow.x, y, flagRow.width, rowHeight - 2)
      if index >= first and index <= last then
        if y >= flagViewport.y and y + rowHeight <= flagViewport.y + flagViewport.height then
          placeRow("toggle", id, flag.name, flag.value, true, y, rowHeight)
          rows[#rows].listSurface = true
          rows[#rows].displayName = flag.displayName
        end
      end
    end
  elseif section == "Party" then
    local partyRows = view.partyRows or {}
    local page = view.partyPage or "list"
    local gridCards = {}
    local partyHelp
    if page == "list" then
      local cards = assert(view.partyCards, "Party list provides occupied cards")
      local gridBody = rect(contentX, contentTop, innerWidth, contentBottom - contentTop)
      local compact = width <= 280
      local cells = SaveEditorCard.resolveGrid({
        bounds = gridBody,
        count = math.min(6, #cards),
        columns = 2,
        rows = 3,
        gap = compact and 4 or 8,
        maxWidth = 264,
        maxCellWidth = 128,
        maxCellHeight = 48,
      })
      for index, card in ipairs(cards) do
        assert(index <= 6, "Party publishes no more than six cards")
        local cell = cells[index]
        local id = card.kind == "member" and ("party:slot:" .. card.slot0) or "party:add"
        local value = card.kind == "member" and (card.species .. "  Lv. " .. tostring(card.level)) or nil
        local cardRect = cell.rect
        if card.kind == "add" then
          cardRect = rect(
            cell.rect.x + (cell.rect.width - math.min(72, cell.rect.width)) / 2,
            cell.rect.y + (cell.rect.height - math.min(28, cell.rect.height)) / 2,
            math.min(72, cell.rect.width),
            math.min(28, cell.rect.height)
          )
        end
        targets[id] = cardRect
        focusPositions[id] = cardRect
        addFocusable(id)
        gridCards[#gridCards + 1] = {
          kind = card.kind,
          targetId = id,
          label = card.kind == "add" and "+ Add" or card.label,
          value = value,
          iconKey = card.iconKey,
          rect = cardRect,
          iconRect = card.kind == "add" and cardRect or cell.iconRect,
          textRect = card.kind == "add" and cardRect or cell.textRect,
          textScale = compact and math.min(1, cell.textRect.height / (2 * metrics.lineHeight)) or nil,
          fainted = card.fainted,
          chrome = card.chrome,
        }
        rows[#rows + 1] = {
          role = card.kind == "member" and "party slot" or "action",
          targetId = id,
          label = card.label,
          value = value,
          iconKey = card.iconKey,
          iconRect = cell.iconRect,
          labelRect = cell.textRect,
          gridCard = true,
        }
      end
      partyGrid = gridCards
    else
      for _, row in ipairs(partyRows) do
        if row.help ~= nil and row.targetId == view.focus then
          partyHelp = row.help
        end
      end
    end
    local actions = {}
    local actionRows = 0
    if page == "detail" then
      actions = {
        { "party:edit", "Edit" },
        { "party:remove", "Remove" },
        { "party:back", "Back" },
      }
      actionRows = 1
    elseif page == "draft" then
      actions = {
        { "party:apply", "Apply", view.partyValid == true },
        { "party:discard", "Discard" },
        { "party:cancel", "Return" },
      }
      actionRows = 1
    end
    local actionHeight = actionRows * rowHeight
    local helpHeight = page == "draft" and view.partySubpage ~= "Stats" and metrics.lineHeight + 4 or 0
    local bodyTop = contentTop
    local bodyBottom = contentBottom - actionHeight - helpHeight
    local bodyHeight = math.max(1, bodyBottom - bodyTop)
    if page == "draft" and view.partySubpage ~= "Stats" and view.partyFieldHelp then
      partyHelp = view.partyFieldHelp
    end
    if page ~= "list" and view.statsTable ~= nil then
      local tableView = view.statsTable
      local compactStats = width <= 280
      assert(#tableView.rows == 6 and #tableView.facts == 4, "Party Stats has six rows and four secondary facts")
      local tableRowHeight = math.min(metrics.lineHeight + 4, math.floor(bodyHeight / (#tableView.rows + 2)))
      assert(tableRowHeight > 0, "Party Stats table fits its detail body")
      local tableTop = bodyTop
      local columnWidths = { innerWidth * 0.37, innerWidth * 0.13, innerWidth * 0.13, innerWidth * 0.37 }
      local headers, x = {}, contentX + 0.0
      for index, label in ipairs({ "Stat", "IV", "EV", "Derived" }) do
        headers[index] = { label = label, rect = rect(x, tableTop, columnWidths[index], tableRowHeight) }
        x = x + columnWidths[index]
      end
      local tableRows = {}
      for index, stat in ipairs(tableView.rows) do
        local y = tableTop + index * tableRowHeight
        local cells, cellX = {}, contentX + 0.0
        local values = { stat.label, tostring(stat.iv), tostring(stat.ev), tostring(stat.derived) }
        local descriptors = { nil, stat.ivEditor, stat.evEditor, nil }
        for column = 1, 4 do
          local cellRect = rect(cellX, y, columnWidths[column], tableRowHeight)
          local descriptor = descriptors[column]
          cells[column] = {
            label = values[column],
            rect = cellRect,
            targetId = descriptor and descriptor.targetId or nil,
            editable = descriptor ~= nil and descriptor.editor ~= nil,
          }
          if descriptor ~= nil and descriptor.editor ~= nil then
            targets[descriptor.targetId] = cellRect
            focusPositions[descriptor.targetId] = cellRect
            addFocusable(descriptor.targetId)
          end
          cellX = cellX + columnWidths[column]
        end
        tableRows[index] = { key = stat.key, cells = cells }
      end
      local factY = tableTop + (#tableView.rows + 1) * tableRowHeight
      local factGroups = {}
      if compactStats then
        factGroups = {
          { tableView.facts[1] },
          { tableView.facts[2] },
          { tableView.facts[3], tableView.facts[4] },
        }
      else
        for _, fact in ipairs(tableView.facts) do
          factGroups[#factGroups + 1] = { fact }
        end
      end
      local factWidth = innerWidth / #factGroups
      local factRects = {}
      for index, group in ipairs(factGroups) do
        local fact = group[1]
        local factRect = rect(contentX + (index - 1) * factWidth, factY, factWidth, tableRowHeight)
        local label = compactStats and fact.id == "currentHp" and "HP" or fact.label
        local value = tostring(fact.value)
        if #group == 2 then
          label = "EV"
          value = tostring(group[1].value) .. "/" .. tostring(group[2].value)
        end
        local valueTarget = #group == 1 and fact.editor and ("party:field:" .. fact.id) or nil
        if valueTarget ~= nil then
          targets[valueTarget] = factRect
          focusPositions[valueTarget] = factRect
          addFocusable(valueTarget)
        end
        factRects[index] = {
          id = fact.id,
          label = label,
          value = value,
          rect = factRect,
          targetId = valueTarget,
          editable = valueTarget ~= nil,
        }
      end
      partyStatsTable = { headers = headers, rows = tableRows, facts = factRects }
    elseif page ~= "list" then
      local scrollId = "party:" .. page .. ":" .. tostring(view.partySubpage or "Identity")
      local ordinaryExtent = metrics.lineHeight + 6
      local controlExtent = metrics.lineHeight + 33
      local extents, tops, contentExtent = {}, {}, 0
      for index, row in ipairs(partyRows) do
        extents[index] = row.role == "action" and controlExtent or ordinaryExtent
        tops[index] = contentExtent
        contentExtent = contentExtent + extents[index]
      end
      ---@type number
      local offset = view.scrollOffsets and view.scrollOffsets[scrollId] or (view.scrollOffset or 0) * ordinaryExtent
      offset = ScrollViewport.clamp(offset, contentExtent, bodyHeight)
      local rowTargets = {}
      for index, row in ipairs(partyRows) do
        rowTargets[index] = row.targetId
      end
      local partyViewport = rect(contentX, bodyTop, innerWidth, bodyHeight)
      viewports.party = makeViewport(partyViewport, offset, contentExtent, ordinaryExtent, 0, #partyRows, rowTargets)
      for index, row in ipairs(partyRows) do
        local extent = extents[index]
        local y = bodyTop + tops[index] - offset
        local bandHeight = row.role == "action" and extent or extent - 2
        local fieldRect = rect(contentX, y, innerWidth, bandHeight)
        local actionable = row.role == "action" or row.role == "integer value" or row.role == "named choice"
        if actionable then
          addFocusable(row.targetId)
          focusPositions[row.targetId] = fieldRect
        end
        if y >= bodyTop and y + extent <= bodyBottom then
          local layoutRow = {
            role = row.role,
            targetId = row.targetId,
            label = row.label,
            value = row.value,
            enabled = row.enabled,
            iconKey = nil,
            partyField = true,
            labelRect = rect(contentX + 4, y + 2, innerWidth * 0.43, extent - 5),
            valueRect = rect(contentX + innerWidth * 0.48, y + 2, innerWidth * 0.5, extent - 5),
            valueText = row.value == nil and nil or tostring(row.value),
            layoutRect = fieldRect,
            editable = row.editor ~= nil,
            semantic = row.semantic,
          }
          if actionable then
            targets[row.targetId] = fieldRect
          end
          rows[#rows + 1] = layoutRow
        end
      end
      local hasActionableRow = false
      for _, row in ipairs(partyRows) do
        if row.role == "action" or row.role == "integer value" or row.role == "named choice" then
          hasActionableRow = true
          break
        end
      end
      if not hasActionableRow and contentExtent > bodyHeight then
        local region = rect(contentX, bodyTop, innerWidth, bodyHeight)
        targets["party:detail-scroll"] = region
        focusPositions["party:detail-scroll"] = region
        addFocusable("party:detail-scroll")
      end
      if page == "draft" and view.partyFieldHelp then
        partyHelp = view.partyFieldHelp
      end
    end
    if page == "draft" and view.partySubpage ~= "Stats" and partyHelp ~= nil then
      layoutPartyHelp = {
        rect = rect(contentX, bodyBottom + 2, innerWidth, metrics.lineHeight),
        text = partyHelp,
      }
    end
    if page == "detail" or page == "draft" then
      layoutPartySummary = partySummary
    end
    for index, action in ipairs(actions) do
      local columns = actionRows > 1 and 3 or #actions
      local rowIndex = math.floor((index - 1) / columns)
      local columnIndex = (index - 1) % columns
      local columnsThisRow = math.min(columns, #actions - rowIndex * columns)
      local cellWidth = math.min(128, math.floor((innerWidth - (columnsThisRow - 1) * 4) / columnsThisRow))
      local bandWidth = columnsThisRow * cellWidth + (columnsThisRow - 1) * 4
      local x = contentX + math.floor((innerWidth - bandWidth) / 2) + columnIndex * (cellWidth + 4)
      local y = contentBottom - actionHeight + rowIndex * rowHeight
      local id = action[1]
      targets[id] = rect(x, y, cellWidth, rowHeight)
      rows[#rows + 1] = { role = "action", targetId = id, id = id, label = action[2], enabled = action[3] ~= false }
      addFocusable(id)
      if action[3] == false then
        disabledTargets[id] = true
      end
    end
  elseif section == "Bag" and view.bagPocketTabRects ~= nil then
    local stripX = contentX + math.floor((innerWidth - 256) / 2)
    local stripY = contentTop
    local tabTargets = {}
    for index, native in ipairs(view.bagPocketTabRects) do
      local id = "bag:pocket:" .. view.bagPockets[index].key
      local target = rect(stripX + native.x, stripY + native.y, native.width, native.height)
      targets[id], focusPositions[id] = target, target
      tabTargets[#tabTargets + 1] = id
      addFocusable(id)
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
    for index, item in ipairs(view.bagPageRows or {}) do
      local cell = cells[index]
      local iconSize = cell.rect.height > 32 and 24 or 16
      local iconRect = rect(cell.rect.x + 4, cell.rect.y + (cell.rect.height - iconSize) / 2, iconSize, iconSize)
      local textRect = rect(
        cell.rect.x + 8 + iconSize,
        cell.rect.y + 1,
        cell.rect.x + cell.rect.width - 4 - (cell.rect.x + 8 + iconSize),
        cell.rect.height - 1
      )
      local id = "bag:item:" .. item.item
      targets[id], focusPositions[id] = cell.rect, cell.rect
      addFocusable(id)
      cards[#cards + 1] = {
        kind = "item",
        targetId = id,
        label = item.label,
        value = tostring(item.quantity),
        iconKey = item.iconKey,
        description = item.description,
        rect = cell.rect,
        iconRect = iconRect,
        textRect = textRect,
        textScale = compactBag and 0.5 or 0.75,
      }
    end
    local arrowWidth = math.min(pageHeight, 32)
    local pageWidth = math.min(56, math.max(32, innerWidth - arrowWidth * 2 - 12))
    local pageGroupWidth = arrowWidth * 2 + pageWidth + 8
    local pageGroupX = contentX + math.max(0, (innerWidth - pageGroupWidth) / 2)
    targets["bag:page:previous"] = rect(pageGroupX, pageY, arrowWidth, pageHeight)
    bagPageTextRect = rect(pageGroupX + arrowWidth + 4, pageY + (pageHeight - 16) / 2, pageWidth, 16)
    targets["bag:page:next"] = rect(pageGroupX + arrowWidth + 4 + pageWidth + 4, pageY, arrowWidth, pageHeight)
    if view.bagPage0 == 0 then
      disabledTargets["bag:page:previous"] = true
    else
      addFocusable("bag:page:previous")
    end
    if view.bagPage0 + 1 >= view.bagPageCount then
      disabledTargets["bag:page:next"] = true
    else
      addFocusable("bag:page:next")
    end
    local addWidth = math.min(60, math.max(40, innerWidth - pageGroupWidth - 8))
    local addX = contentX + innerWidth - addWidth
    targets["bag:add"] = rect(addX, pageY, addWidth, pageHeight)
    addFocusable("bag:add")
    if view.bagAddEnabled == false then
      disabledTargets["bag:add"] = true
    end
    bagGrid = cards
    bagTabs = tabTargets
    bagStripTarget = rect(stripX, stripY, 256, 32)
  else
    addRow("read-only value", "section", section, "Available in a later update")
  end

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
  local actionHeight = math.max(34, metrics.lineHeight + 16)
  for index, action in ipairs(actions) do
    targets[action.id] = rect(
      actionX,
      height - footerHeight + math.floor((footerHeight - actionHeight) / 2),
      actionWidths[index],
      actionHeight
    )
    actionX = actionX + actionWidths[index] + actionGap
    action.role, action.targetId, action.value = "action", action.id, action.label
    addFocusable(action.id)
    if not action.enabled then
      disabledTargets[action.id] = true
    end
  end

  if view.valueEditor ~= nil then
    local dialog = view.valueEditor
    local dialogTop = contentTop + 4
    if dialog.kind == "choice" then
      local bodyTop = dialogTop
      local bodyBottom = contentBottom - 36
      local bodyHeight = math.max(1, bodyBottom - bodyTop)
      local offset = view.scrollOffsets and view.scrollOffsets["value:choice"] or 0
      local choiceList = SaveEditorList.resolve({
        bounds = rect(contentX, bodyTop, innerWidth, bodyHeight),
        rowCount = #dialog.options,
        rowHeight = rowHeight,
        gap = 0,
        maxWidth = innerWidth,
        headerHeight = metrics.lineHeight,
      })
      local contentExtent = choiceList.contentHeight
      listSurfaces[#listSurfaces + 1] = choiceList.surface
      local rowTargets = {}
      for index, option in ipairs(dialog.options) do
        rowTargets[index] = "choice:" .. option.key
      end
      for _, targetId in ipairs(rowTargets) do
        listRowRoles[targetId] = "choice"
      end
      local viewport = registerList("value:choice", "value:choice", choiceList, rowTargets, dialog.query)
      local selectedIndex
      for index, option in ipairs(dialog.options) do
        if option.key == dialog.selectedKey then
          selectedIndex = index
          break
        end
      end
      if selectedIndex and not view.preserveChoiceScroll then
        offset = ScrollViewport.reveal(offset, viewport.height, (selectedIndex - 1) * rowHeight, rowHeight)
      end
      offset = ScrollViewport.clamp(offset, contentExtent, viewport.height)
      viewports["value:choice"] =
        makeViewport(viewport, offset, contentExtent, rowHeight, 0, #dialog.options, rowTargets)
      for index, option in ipairs(dialog.options) do
        local id = "choice:" .. option.key
        addFocusable(id)
        local row = choiceList.rows[index].rect
        focusPositions[id] = rect(row.x, row.y - offset, row.width, row.height - 1)
        targets[id] = rect(row.x, row.y - offset, row.width, row.height - 1)
      end
      local footerWidth = math.max(1, math.floor(innerWidth / 2))
      targets.confirm = rect(contentX, contentBottom - 34, footerWidth - 2, 34)
      targets.cancel = rect(contentX + footerWidth, contentBottom - 34, innerWidth - footerWidth, 34)
      addFocusable("confirm")
      addFocusable("cancel")
      if #dialog.options == 0 then
        disabledTargets.confirm = true
      end
    elseif dialog.kind == "name" then
      local naming = assert(dialog.naming)
      local cellWidth = math.max(1, math.floor(innerWidth / 13))
      local keyboardBottom = height - 26
      local gridTop = math.min(contentTop + 20, keyboardBottom - 5 * 15 - 14 - 2)
      for row = 1, 6 do
        for column = 1, 13 do
          targets[row .. ":" .. column] =
            rect(contentX + (column - 1) * cellWidth, gridTop + (row - 1) * 15, cellWidth - 1, 14)
        end
      end
      for _, control in ipairs(naming.controls) do
        targets["name-control:" .. control.id] = rect(
          contentX + (control.firstColumn - 1) * cellWidth,
          gridTop,
          (control.lastColumn - control.firstColumn + 1) * cellWidth - 1,
          14
        )
      end
      targets.confirm = rect(contentX, keyboardBottom, math.floor(innerWidth / 2) - 2, 24)
      targets.cancel =
        rect(contentX + math.floor(innerWidth / 2) + 2, keyboardBottom, math.floor(innerWidth / 2) - 2, 24)
      addFocusable("confirm")
      addFocusable("cancel")
      for row = 1, 6 do
        for column = 1, 13 do
          addFocusable(row .. ":" .. column)
        end
      end
      for _, control in ipairs(naming.controls) do
        addFocusable("name-control:" .. control.id)
      end
    elseif dialog.kind == "number" then
      local controls = assert(view.numberControls, "number controls come from the Bag manifest")
      local minX, minY = math.huge, math.huge
      local maxX, maxY = -math.huge, -math.huge
      for _, control in ipairs(controls) do
        local hit = assert(control.hitRect)
        minX, minY = math.min(minX, hit.x), math.min(minY, hit.y)
        maxX, maxY = math.max(maxX, hit.x + hit.width), math.max(maxY, hit.y + hit.height)
      end
      local unionWidth, unionHeight = math.max(1, maxX - minX), math.max(1, maxY - minY)
      local valueText = tostring(dialog.parsedValue or dialog.buffer or "")
      local valueWidth = metrics.measure(valueText)
      local pad = 8
      local confirmWidth = math.min(128, math.max(40, math.floor(metrics.measure("Confirm") + 24)))
      local cancelWidth = math.min(128, math.max(40, math.floor(metrics.measure("Cancel") + 24)))
      local buttonsWidth = confirmWidth + 4 + cancelWidth
      local buttonHeight = 34
      local errorHeight = metrics.lineHeight + 2
      local padTop = pad
      local gapValueControls, gapControlsButtons, gapButtonsError = 4, 6, 2
      local modalTop, modalBottom = contentTop, contentBottom
      local function verticalNeed(verticalPad)
        local need = verticalPad + metrics.lineHeight + gapValueControls + unionHeight
        need = need + gapControlsButtons + buttonHeight + gapButtonsError + errorHeight
        return need + verticalPad
      end
      if verticalNeed(padTop) > modalBottom - modalTop then
        -- Value scope prunes every footer target, so the idle footer strip is
        -- safe to borrow; tighten to the minimum frame clearance instead of
        -- spilling controls past a clamped frame.
        modalBottom = height - (margin + 2) - 2
        padTop, gapValueControls, gapControlsButtons, gapButtonsError = 4, 2, 4, 2
      end
      local modalWidth = math.max(unionWidth, buttonsWidth, valueWidth) + pad * 2
      modalWidth = math.max(8, math.floor(math.min(modalWidth, innerWidth) / 8) * 8)
      local modalHeight = verticalNeed(padTop)
      modalHeight = math.max(8, math.floor(math.min(modalHeight, modalBottom - modalTop) / 8) * 8)
      valueModal = rect(
        contentX + math.floor((innerWidth - modalWidth) / 2),
        modalTop + math.max(0, math.floor((modalBottom - modalTop - modalHeight) / 2)),
        modalWidth,
        modalHeight
      )
      local controlsX = valueModal.x + math.floor((valueModal.width - unionWidth) / 2)
      local controlsY = valueModal.y + padTop + metrics.lineHeight + gapValueControls
      for _, control in ipairs(controls) do
        local hit = assert(control.hitRect)
        local targetId = "number:delta:" .. tostring(control.delta)
        targets[targetId] = rect(controlsX + (hit.x - minX), controlsY + (hit.y - minY), hit.width, hit.height)
        addFocusable(targetId)
      end
      local buttonsY = controlsY + unionHeight + gapControlsButtons
      local buttonsX = valueModal.x + math.floor((valueModal.width - buttonsWidth) / 2)
      targets.confirm = rect(buttonsX, buttonsY, confirmWidth, buttonHeight)
      targets.cancel = rect(buttonsX + confirmWidth + 4, buttonsY, cancelWidth, buttonHeight)
      addFocusable("confirm")
      addFocusable("cancel")
      targets["value-draft"] =
        rect(valueModal.x + pad, valueModal.y + padTop, valueModal.width - pad * 2, metrics.lineHeight)
      valueModalValue = rect(valueModal.x + pad, valueModal.y + padTop, valueModal.width - pad * 2, metrics.lineHeight)
      valueModalError =
        rect(valueModal.x + pad, buttonsY + buttonHeight + gapButtonsError, valueModal.width - pad * 2, errorHeight)
    end
  end
  if view.modal ~= nil then
    local choices = view.modal == "bag-item" and { "bag:quantity", "bag:remove", "cancel" }
      or view.modal == "draft" and { "apply", "discard", "cancel" }
      or view.modal == "remove" and { "remove", "cancel" }
      or { "save", "discard", "cancel" }
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
    decisionList = {
      surface = surface.surface,
      prompt = rect(surface.content.x, surface.content.y, surface.content.width, promptHeight),
      rows = {},
    }
    for index, id in ipairs(choices) do
      local buttonWidth = math.min(128, surface.content.width)
      local rowRect = rect(
        surface.content.x + math.floor((surface.content.width - buttonWidth) / 2),
        surface.content.y + promptHeight + 4 + (index - 1) * (buttonHeight + 4),
        buttonWidth,
        buttonHeight
      )
      targets[id] = rowRect
      decisionList.rows[index] = {
        targetId = id,
        label = id == "bag:quantity" and "Quantity"
          or id == "bag:remove" and "Remove"
          or view.modal == "leave" and id == "save" and "Save & exit"
          or view.modal == "leave" and id == "discard" and "Discard all"
          or id:sub(1, 1):upper() .. id:sub(2),
        semantic = (id == "save" or id == "apply") and "primary"
          or (id == "discard" or id == "remove" or id == "bag:remove") and "destructive"
          or "secondary",
        enabled = id ~= "apply" or view.partyValid == true,
        rect = rowRect,
      }
      addFocusable(id)
      if id == "apply" and view.partyValid ~= true then
        disabledTargets[id] = true
      end
      if view.modal == "draft" and id == "apply" and view.partyValid ~= true then
        disabledTargets[id] = true
      end
    end
  end
  local scopeAllowed
  if scope.kind == "decision" then
    scopeAllowed = view.modal == "bag-item" and { ["bag:quantity"] = true, ["bag:remove"] = true, cancel = true }
      or view.modal == "draft" and { apply = true, discard = true, cancel = true }
      or view.modal == "remove" and { remove = true, cancel = true }
      or { save = true, discard = true, cancel = true }
  elseif scope.kind == "value" then
    local editor = assert(view.valueEditor, "value scope needs its active editor")
    scopeAllowed = { confirm = true, cancel = true }
    if editor.kind == "choice" then
      scopeAllowed["list:value:choice"] = true
      for _, option in ipairs(editor.options) do
        scopeAllowed["choice:" .. option.key] = true
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
      for _, control in ipairs(assert(view.numberControls)) do
        scopeAllowed["number:delta:" .. tostring(control.delta)] = true
      end
    end
  end
  if scopeAllowed then
    for targetId in pairs(targets) do
      if not scopeAllowed[targetId] then
        targets[targetId] = nil
      end
    end
    local activeFocusable = {}
    focusableSet = {}
    for _, targetId in ipairs(focusable) do
      if scopeAllowed[targetId] and (targets[targetId] ~= nil or focusPositions[targetId] ~= nil) then
        activeFocusable[#activeFocusable + 1] = targetId
        focusableSet[targetId] = true
      end
    end
    focusable = activeFocusable
    local activeNavigation = {}
    for _, item in ipairs(navigation) do
      if scopeAllowed[item.targetId] then
        activeNavigation[#activeNavigation + 1] = item
      end
    end
    navigation = activeNavigation
    local activeRows = {}
    for _, row in ipairs(rows) do
      if scopeAllowed[row.targetId] then
        activeRows[#activeRows + 1] = row
      end
    end
    rows = activeRows
    for listId, list in pairs(lists) do
      if not scopeAllowed[list.targetId] then
        lists[listId] = nil
      else
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
  focusableSet = {}
  for _, targetId in ipairs(focusable) do
    if not disabledTargets[targetId] then
      enabledFocusable[#enabledFocusable + 1] = targetId
      focusableSet[targetId] = true
    end
  end
  focusable = enabledFocusable

  local roleById = {}
  for targetId, role in pairs(listRowRoles) do
    roleById[targetId] = role
  end
  local focusedValueHelp
  for _, row in ipairs(rows) do
    roleById[row.targetId] = row.role
  end
  for _, item in ipairs(navigation) do
    roleById[item.targetId] = item.role or "action"
  end
  for _, action in ipairs(actions) do
    roleById[action.id] = "action"
  end
  local viewportByTarget = {}
  local listTargets = {}
  for viewportId, list in pairs(viewports) do
    assert(
      list.clip and list.rowExtent and list.firstIndex and list.lastIndex and list.rowTargets,
      "scroll viewports publish logical row geometry"
    )
    for _, targetId in ipairs(list.rowTargets) do
      viewportByTarget[targetId] = viewportId
      listTargets[targetId] = true
    end
  end
  local focusGraph = {}
  for _, targetId in ipairs(focusable) do
    focusGraph[targetId] = { up = {}, down = {}, left = {}, right = {} }
  end
  local fixedFocusable = {}
  for _, targetId in ipairs(focusable) do
    if not listTargets[targetId] then
      fixedFocusable[#fixedFocusable + 1] = targetId
    end
  end
  for _, targetId in ipairs(fixedFocusable) do
    local source = focusPositions[targetId] or targets[targetId]
    if source then
      local sourceX, sourceY = source.x + source.width / 2, source.y + source.height / 2
      local candidates = { up = {}, down = {}, left = {}, right = {} }
      for _, candidateId in ipairs(fixedFocusable) do
        local candidate = focusPositions[candidateId] or targets[candidateId]
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
          focusGraph[targetId][direction][#focusGraph[targetId][direction] + 1] = candidate.id
        end
      end
    end
  end
  for _, list in pairs(viewports) do
    local ordered = {}
    for _, targetId in ipairs(list.rowTargets) do
      if focusableSet[targetId] then
        ordered[#ordered + 1] = targetId
      end
    end
    for index, targetId in ipairs(ordered) do
      local node = focusGraph[targetId]
      if index > 1 then
        node.up = { ordered[index - 1] }
      end
      if index < #ordered then
        node.down = { ordered[index + 1] }
      end
    end
    if #ordered > 0 then
      local first, last = ordered[1], ordered[#ordered]
      local firstPosition = focusPositions[first] or targets[first]
      local lastPosition = focusPositions[last] or targets[last]
      for _, targetId in ipairs(fixedFocusable) do
        local position = focusPositions[targetId] or targets[targetId]
        if position and firstPosition and position.y + position.height / 2 < firstPosition.y then
          table.insert(focusGraph[first].up, targetId)
          table.insert(focusGraph[targetId].down, first)
        end
        if position and lastPosition and position.y + position.height / 2 > lastPosition.y then
          table.insert(focusGraph[last].down, targetId)
          table.insert(focusGraph[targetId].up, last)
        end
      end
    end
  end
  if railWidth > 0 then
    for index, name in ipairs(enabledSections) do
      local targetId = "section:" .. name
      local node = focusGraph[targetId]
      if node then
        if index > 1 then
          node.up = { "section:" .. enabledSections[index - 1] }
        end
        if index < #enabledSections then
          node.down = { "section:" .. enabledSections[index + 1] }
        end
      end
    end
    local sectionTarget = "section:" .. section
    for _, targetId in ipairs(focusable) do
      if targetId:sub(1, 8) ~= "section:" and not listTargets[targetId] then
        local position = focusPositions[targetId] or targets[targetId]
        if position and position.x >= contentX then
          local node = focusGraph[targetId]
          if node and focusGraph[sectionTarget] then
            table.insert(node.left, 1, sectionTarget)
          end
        end
      end
    end
  end
  if section == "Bag" and bagTabs ~= nil then
    for index, tabId in ipairs(bagTabs) do
      local node = focusGraph[tabId]
      if node ~= nil then
        node.left = { bagTabs[(index - 2) % #bagTabs + 1] }
        node.right = { bagTabs[index % #bagTabs + 1] }
      end
    end
  end
  if section == "Bag" then
    local occupied = view.bagPageRows or {}
    local gridTargets = {}
    for index, item in ipairs(occupied) do
      gridTargets[index] = "bag:item:" .. item.item
    end
    local pocketTargets = bagTabs or {}
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
      local node = focusGraph[targetId]
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
  if section == "Party" and view.partyPage == "list" then
    local cards = view.partyCards or {}
    local cardTargets = {}
    for index, card in ipairs(cards) do
      cardTargets[index] = card.kind == "member" and ("party:slot:" .. card.slot0) or "party:add"
    end
    for index, targetId in ipairs(cardTargets) do
      local node = focusGraph[targetId]
      if node ~= nil then
        local column = (index - 1) % 2
        local row = math.floor((index - 1) / 2)
        local left = column == 1 and cardTargets[index - 1] or nil
        local right = column == 0 and cardTargets[index + 1] or nil
        local above = row > 0 and cardTargets[index - 2] or nil
        local below = cardTargets[index + 2]
        node.left = { left or targetId }
        node.right = { right or targetId }
        node.up = { above or targetId }
        node.down = { below or targetId }
      end
    end
  end
  local focusOrder = {}
  local targetRecords = {}
  for _, targetId in ipairs(focusable) do
    focusOrder[#focusOrder + 1] = targetId
  end
  local defaultFocus
  if scope.kind == "decision" then
    defaultFocus = "cancel"
  elseif scope.kind == "value" then
    local editor = assert(view.valueEditor)
    if editor.kind == "choice" and viewports["value:choice"] ~= nil then
      defaultFocus = "list:value:choice"
    elseif editor.kind == "choice" and editor.selectedKey ~= nil then
      defaultFocus = "choice:" .. editor.selectedKey
    elseif editor.kind == "name" then
      local cursor = assert(editor.naming.cursor)
      defaultFocus = tostring(cursor.row) .. ":" .. tostring(cursor.column)
    elseif editor.kind == "number" then
      defaultFocus = "number:delta:1"
    else
      defaultFocus = focusGraph["value-draft"] and "value-draft" or "digit-left"
    end
  elseif section == "Player" then
    defaultFocus = "money"
  elseif section == "Location" then
    if
      view.locationNavigation
      and view.locationNavigation.page == "map-list"
      and viewports["location:map-list"] ~= nil
    then
      defaultFocus = "list:location:map-list"
    else
      defaultFocus = "location:"
        .. ((view.locationNavigation and view.locationNavigation.page == "map-list") and "map-picker" or "grid")
    end
  elseif section == "Party" and view.partyPage == "list" then
    for _, targetId in ipairs(focusOrder) do
      if targetId:match("^party:slot:") then
        defaultFocus = targetId
        break
      end
    end
    defaultFocus = defaultFocus or (view.partyCanAdd and "party:add")
  elseif section == "Party" then
    for _, targetId in ipairs(focusOrder) do
      if targetId:match("^party:subpage:") then
        defaultFocus = targetId
        break
      end
    end
    if defaultFocus == nil then
      for _, targetId in ipairs(focusOrder) do
        if targetId:match("^party:") then
          defaultFocus = targetId
          break
        end
      end
    end
  elseif section == "Progress" then
    defaultFocus = "list:flags"
  elseif section == "Bag" then
    defaultFocus = "bag:pocket:" .. tostring(view.bagPocket)
  end
  if defaultFocus == nil or not focusGraph[defaultFocus] then
    defaultFocus = assert(
      focusOrder[1],
      "active focus graph has no nodes: scope=" .. tostring(scope.kind) .. " modal=" .. tostring(view.modal)
    )
  end
  assert(focusGraph[defaultFocus], "layout default focus must be present in its graph")
  local scrollOwner
  if scope.kind ~= "decision" then
    if scope.kind == "value" then
      if view.valueEditor.kind == "choice" and viewports["value:choice"] ~= nil then
        scrollOwner = "value:choice"
      end
    elseif section == "Location" and viewports["location:map-list"] ~= nil then
      scrollOwner = "location:map-list"
    elseif section == "Party" and viewports.party ~= nil then
      scrollOwner = "party"
    elseif section == "Bag" and viewports.bag ~= nil then
      scrollOwner = "bag"
    elseif section == "Progress" and viewports.flags ~= nil then
      scrollOwner = "flags"
    end
  end
  for targetId, targetRect in pairs(targets) do
    local viewportId = viewportByTarget[targetId]
    local list = viewportId and viewports[viewportId]
    local containerClip = containerClips[targetId]
    local role = roleById[targetId]
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
      focusable = focusableSet[targetId] == true,
      activationEnabled = not disabledTargets[targetId],
      role = role,
      viewportId = viewportId,
    }
  end
  for _, row in ipairs(rows) do
    local target = targetRecords[row.targetId]
    if target and row.gridCard then
      row.valueText = row.value == nil and nil or tostring(row.value)
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
  return {
    viewport = rect(0, 0, width, height),
    shell = shell,
    content = rect(contentX, contentTop, innerWidth, contentBottom - contentTop),
    footer = rect(contentX, height - footerHeight, innerWidth, footerHeight),
    rows = rows,
    focusedValueHelp = focusedValueHelp,
    navigation = navigation,
    focusOrder = focusOrder,
    focusGraph = focusGraph,
    defaultFocus = defaultFocus,
    targets = targetRecords,
    actions = actions,
    activeSection = section,
    locationGrid = locationGrid,
    locationFocusCue = locationFocusCue,
    valueModal = valueModal,
    valueModalValue = valueModalValue,
    valueModalError = valueModalError,
    decisionList = decisionList,
    partyGrid = partyGrid,
    listSurfaces = listSurfaces,
    partyStatsTable = partyStatsTable,
    partySummary = layoutPartySummary,
    partyHelp = layoutPartyHelp,
    locationStatus = locationStatus,
    bagGrid = bagGrid,
    bagTabs = bagTabs,
    bagStripTarget = bagStripTarget,
    bagPageText = bagPageTextRect,
    bagPage = { index = (view.bagPage0 or 0) + 1, count = view.bagPageCount or 1 },
    scrollOffset = view.scrollOffset or 0,
    viewports = viewports,
    lists = lists,
    scrollOwner = scrollOwner,
    scopeId = scope.id,
    scopeEpoch = scope.epoch,
    metrics = metrics,
  }
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
    and view.locationNavigation.page ~= "map-list"
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
  local allowed
  if view.modal ~= nil then
    allowed = view.modal == "bag-item" and { ["bag:quantity"] = true, ["bag:remove"] = true, cancel = true }
      or view.modal == "draft" and { apply = true, discard = true, cancel = true }
      or view.modal == "remove" and { remove = true, cancel = true }
      or { save = true, discard = true, cancel = true }
  elseif view.valueEditor ~= nil then
    if view.valueEditor.kind == "choice" then
      allowed = {
        cancel = true,
        confirm = true,
        ["list:value:choice"] = true,
      }
      for _, option in ipairs(view.valueEditor.options) do
        allowed["choice:" .. option.key] = true
      end
    elseif view.valueEditor.kind == "name" then
      allowed = { confirm = true, cancel = true }
      for row = 1, 6 do
        for column = 1, 13 do
          allowed[row .. ":" .. column] = true
        end
      end
      for _, control in ipairs(view.valueEditor.naming.controls) do
        allowed["name-control:" .. control.id] = true
      end
    else
      allowed = {
        confirm = true,
        cancel = true,
      }
      if view.valueEditor.kind == "number" then
        for _, control in ipairs(assert(view.numberControls)) do
          allowed["number:delta:" .. tostring(control.delta)] = true
        end
      end
    end
  end
  local deferred
  for targetId, target in pairs(layout.targets) do
    if allowed == nil or allowed[targetId] then
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
        if targetId == "save" or targetId == "discard" or targetId == "back" then
          for _, action in ipairs(layout.actions) do
            if action.id == targetId and not action.enabled then
              return nil
            end
          end
        end
        if targetId:match("^list:") or targetId == "party:detail-scroll" then
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
