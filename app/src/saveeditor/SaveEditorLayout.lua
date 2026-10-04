-- Computes the editor's canonical logical rows and hit targets.

local Layout = {}
local ScrollViewport = require("libs.ui.src.ScrollViewport")

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

local function sixCellGrid(body, gap, compact)
  local cellWidth = (body.width - gap) / 2
  local cellHeight = (body.height - gap * 2) / 3
  assert(cellWidth > 0 and cellHeight > 0, "six-cell grid needs positive cells")
  local cells = {}
  for index = 1, 6 do
    local column, row = (index - 1) % 2, math.floor((index - 1) / 2)
    local x = body.x + column * (cellWidth + gap)
    local y = body.y + row * (cellHeight + gap)
    local cell = rect(x, y, cellWidth, cellHeight)
    local inset = math.min(5, cell.width / 8)
    local iconRect, textRect
    if compact then
      iconRect = rect(cell.x + 2, cell.y + 2, math.min(16, cell.width - 26), math.min(16, cell.height - 4))
      textRect = rect(
        iconRect.x + iconRect.width + 4,
        cell.y + 2,
        cell.x + cell.width - iconRect.x - iconRect.width - 8,
        cell.height - 4
      )
    else
      local iconHeight = math.max(1, (cell.height - gap) * 0.62)
      iconRect = rect(cell.x + inset, cell.y + 2, cell.width - inset * 2, iconHeight - 2)
      textRect = rect(
        cell.x + inset,
        iconRect.y + iconRect.height + 2,
        cell.width - inset * 2,
        cell.y + cell.height - iconRect.y - iconRect.height - 5
      )
    end
    assert(
      cell.x >= body.x
        and cell.y >= body.y
        and cell.x + cell.width <= body.x + body.width + 0.01
        and cell.y + cell.height <= body.y + body.height + 0.01,
      "six-cell geometry stays inside its body"
    )
    if compact then
      assert(iconRect.x + iconRect.width <= textRect.x, "compact six-cell content regions remain side by side")
    else
      assert(iconRect.y + iconRect.height <= textRect.y, "six-cell content regions remain stacked")
    end
    assert(
      textRect.x >= cell.x
        and textRect.y >= cell.y
        and textRect.x + textRect.width <= cell.x + cell.width
        and textRect.y + textRect.height <= cell.y + cell.height,
      "six-cell text remains inside its cell"
    )
    cells[index] = { rect = cell, iconRect = iconRect, textRect = textRect }
  end
  return cells
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
  local compactPartyDetails = width < 400
    and view.section == "Party"
    and (view.partyPage == "detail" or view.partyPage == "draft")
  local compactBag = width <= 280 and view.section == "Bag"
  local footerHeight = compactPartyDetails and width <= 280 and 34
    or compactBag and 32
    or math.max(40, metrics.lineHeight + 24)
  local railWidth = width >= 400 and 88 or 0
  local rows, targets, focusable, disabledTargets, focusPositions = {}, {}, {}, {}, {}
  local locationGrid
  local locationStatus
  local bagGrid, bagTabs, bagStripTarget, bagPageTextRect
  local focusableSet = {}
  local function addFocusable(targetId)
    if not focusableSet[targetId] then
      focusableSet[targetId] = true
      focusable[#focusable + 1] = targetId
    end
  end
  local innerWidth = math.max(1, width - margin * 2 - (railWidth > 0 and railWidth + 6 or 0))
  local contentX = margin + (railWidth > 0 and railWidth + 6 or 0)
  local contentTop = margin
  local contentBottom = math.max(contentTop + 1, height - footerHeight - 2)
  local section = view.section or "Player"
  local rowHeight = math.max(30, metrics.lineHeight + 16)
  local enabledSections = { "Location", "Player", "Party", "Bag", "Progress" }
  local navigation = {}
  if railWidth > 0 then
    for index, name in ipairs(enabledSections) do
      local id = "section:" .. name
      targets[id] = rect(margin, margin + (index - 1) * 34, railWidth, 30)
      navigation[#navigation + 1] = { role = "action", targetId = id, id = id, label = name }
      addFocusable(id)
    end
  else
    local sectionWidth = compactPartyDetails and math.min(72, innerWidth) or innerWidth
    targets.section = rect(margin, 0, sectionWidth, compactPartyDetails and 34 or math.max(30, metrics.lineHeight + 16))
    navigation[#navigation + 1] = {
      role = "action",
      targetId = "section",
      id = "section",
      label = compactPartyDetails and section or ("Section: " .. section),
    }
    addFocusable("section")
    contentTop = targets.section.y + targets.section.height
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
  local partyGrid
  local layoutPartySummary
  local layoutPartyHelp

  local partySummary
  if section == "Party" and (view.partyPage == "detail" or view.partyPage == "draft") then
    if compactPartyDetails then
      local summaryX = targets.section.x + targets.section.width + 4
      local summaryWidth = contentX + innerWidth - summaryX
      partySummary = {
        inline = true,
        rect = rect(summaryX, targets.section.y, summaryWidth, targets.section.height),
        iconRect = rect(summaryX, targets.section.y + 1, 32, targets.section.height - 2),
        textRect = rect(summaryX + 36, targets.section.y + 2, summaryWidth - 38, targets.section.height - 4),
      }
    else
      local summaryHeight = math.min(54, math.max(42, contentBottom - contentTop - rowHeight * 2))
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
    if compactPartyDetails then
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
      if not compactPartyDetails and tabX > contentX and tabX + tabWidth > contentX + innerWidth then
        tabX = contentX
        tabY = tabY + rowHeight + 2
      end
      local tab = rect(tabX - tabOffset, tabY, tabWidth, rowHeight)
      if not compactPartyDetails or tab.x >= contentX and tab.x + tab.width <= contentX + innerWidth then
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
    addRow("action", "back", "Back", "", true)
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
      local mapViewport = rect(contentX, contentTop, listWidth, contentBottom - contentTop)
      mapOffset = ScrollViewport.clamp(mapOffset, #maps * rowHeight, mapViewport.height)
      local rowTargets = {}
      for index, map in ipairs(maps) do
        local id = "location:map:" .. map.mapId
        rowTargets[index] = id
        local y = contentTop + (index - 1) * rowHeight - mapOffset
        focusPositions[id] = rect(contentX, contentTop + (index - 1) * rowHeight - mapOffset, listWidth, rowHeight)
        if y >= contentTop and y + rowHeight <= contentBottom then
          targets[id] = rect(contentX, y, listWidth, rowHeight - 2)
          navigation[#navigation + 1] = {
            role = "action",
            targetId = id,
            label = map.displayName,
          }
          addFocusable(id)
        end
      end
      viewports["location:map-list"] =
        makeViewport(mapViewport, mapOffset, #maps * rowHeight, rowHeight, 0, #maps, rowTargets)
    elseif page == "map-list" then
      local rowTop = contentTop + rowHeight
      local mapViewport = rect(contentX, rowTop, innerWidth, math.max(0, contentBottom - rowTop - rowHeight))
      local mapOffset = ScrollViewport.clamp(locationNav.mapOffset or 0, #maps * rowHeight, mapViewport.height)
      local rowTargets = {}
      targets["location:map-picker"] = rect(contentX, contentTop, innerWidth, rowHeight - 2)
      navigation[#navigation + 1] = {
        role = "action",
        targetId = "location:map-picker",
        label = "Change Map",
      }
      addFocusable("location:map-picker")
      for index, map in ipairs(maps) do
        local id = "location:map:" .. map.mapId
        rowTargets[index] = id
        local y = rowTop + (index - 1) * rowHeight - mapOffset
        if y + rowHeight <= contentBottom then
          targets[id] = rect(contentX, y, innerWidth, rowHeight - 2)
          rows[#rows + 1] = { role = "action", targetId = id, label = map.displayName, value = map.section }
          addFocusable(id)
        end
      end
      viewports["location:map-list"] =
        makeViewport(mapViewport, mapOffset, #maps * rowHeight, rowHeight, 0, #maps, rowTargets)
      targets["location:map-back"] = rect(contentX, contentBottom - rowHeight, innerWidth, rowHeight - 2)
      navigation[#navigation + 1] = { role = "action", targetId = "location:map-back", label = "Back" }
      addFocusable("location:map-back")
    end

    if page ~= "map-list" or wide then
      local controlHeight = math.min(22, rowHeight)
      local controlY = contentTop
      local controlX = gridLeft
      local gridWidth = math.max(1, contentX + innerWidth - gridLeft)
      local pickerWidth = math.min(gridWidth * 0.55, wide and 240 or 144)
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
  elseif section == "Player" then
    local snapshot = assert(view.session)
    addRow("read-only value", "player", "Player", snapshot.playerName)
    addRow("integer value", "money", "Money", snapshot.money)
    addRow("named choice", "dialogue-frame", "Dialogue frame", "Frame " .. tostring(snapshot.frameIndex + 1))
  elseif section == "Progress" then
    addRow("read-only value", "flags:search", "Type to filter flags", nil)
    addFocusable("flags:search")
    focusPositions["flags:search"] = targets["flags:search"]
    local flags = view.flagRows or {}
    local flagOffset = view.scrollOffsets and view.scrollOffsets.flags or 0
    local bodyTop = contentTop + #rows * rowHeight
    local bodyHeight = math.max(0, contentBottom - bodyTop)
    local contentExtent = #flags * rowHeight
    flagOffset = ScrollViewport.clamp(flagOffset, contentExtent, bodyHeight)
    local rowTargets = {}
    for index, flag in ipairs(flags) do
      rowTargets[index] = "flag:" .. flag.name
    end
    viewports.flags = makeViewport(
      rect(contentX, bodyTop, innerWidth, bodyHeight),
      flagOffset,
      contentExtent,
      rowHeight,
      0,
      #flags,
      rowTargets
    )
    local first, last = ScrollViewport.visibleRange(flagOffset, bodyHeight, rowHeight, 0, #flags)
    for index, flag in ipairs(flags) do
      local id = "flag:" .. flag.name
      addFocusable(id)
      focusPositions[id] = rect(contentX, bodyTop + (index - 1) * rowHeight - flagOffset, innerWidth, rowHeight - 2)
      if index >= first and index <= last then
        local y = bodyTop + (index - 1) * rowHeight - flagOffset
        if y >= bodyTop and y + rowHeight <= contentBottom then
          placeRow("toggle", id, flag.name, flag.value, true, y, rowHeight)
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
      local cells = sixCellGrid(gridBody, 6)
      for index, card in ipairs(cards) do
        assert(index <= 6, "Party publishes no more than six cards")
        local cell = cells[index]
        local id = card.kind == "member" and ("party:slot:" .. card.slot0) or "party:add"
        local value = card.kind == "member" and ("Lv. " .. tostring(card.level)) or nil
        targets[id] = cell.rect
        focusPositions[id] = cell.rect
        addFocusable(id)
        gridCards[#gridCards + 1] = {
          kind = card.kind,
          targetId = id,
          label = card.label,
          value = value,
          iconKey = card.iconKey,
          rect = cell.rect,
          iconRect = cell.iconRect,
          textRect = cell.textRect,
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
        { "party:move-up", "Move up", view.partySlot0 ~= 0 },
        { "party:move-down", "Move down", view.partySlot0 ~= view.partyLastSlot0 },
        { "party:remove", "Remove" },
        { "party:back", "Party list" },
      }
      actionRows = width < 400 and 2 or 1
    elseif page == "draft" then
      actions = {
        { "party:apply", "Apply", view.partyValid == true },
        { "party:discard", "Discard" },
        { "party:cancel", "Return" },
      }
      actionRows = 1
    end
    local actionHeight = actionRows * rowHeight
    local helpHeight = page == "draft" and metrics.lineHeight + 4 or 0
    local bodyTop = contentTop
    local bodyBottom = contentBottom - actionHeight - helpHeight
    local bodyHeight = math.max(1, bodyBottom - bodyTop)
    if page ~= "list" then
      local scrollId = "party:" .. page .. ":" .. tostring(view.partySubpage or "Identity")
      ---@type number
      local offset = view.scrollOffsets and view.scrollOffsets[scrollId] or (view.scrollOffset or 0) * rowHeight
      local contentExtent = #partyRows * rowHeight
      offset = ScrollViewport.clamp(offset, contentExtent, bodyHeight)
      local rowTargets = {}
      for index, row in ipairs(partyRows) do
        rowTargets[index] = row.targetId
      end
      viewports.party = makeViewport(
        rect(contentX, bodyTop, innerWidth, bodyHeight),
        offset,
        contentExtent,
        rowHeight,
        0,
        #partyRows,
        rowTargets
      )
      local first, last = ScrollViewport.visibleRange(offset, bodyHeight, rowHeight, 0, #partyRows)
      for index, row in ipairs(partyRows) do
        local y = bodyTop + (index - 1) * rowHeight - offset
        local fieldRect = rect(contentX, y, innerWidth, rowHeight - 2)
        local actionable = row.role == "action" or row.role == "integer value" or row.role == "named choice"
        if actionable then
          addFocusable(row.targetId)
          focusPositions[row.targetId] = fieldRect
        end
        if index >= first and index <= last and y >= bodyTop and y + rowHeight <= bodyBottom then
          local layoutRow = {
            role = row.role,
            targetId = row.targetId,
            label = row.label,
            value = row.value,
            enabled = row.enabled,
            iconKey = nil,
            partyField = true,
            labelRect = rect(contentX + 4, y + 2, innerWidth * 0.43, rowHeight - 5),
            valueRect = rect(contentX + innerWidth * 0.48, y + 2, innerWidth * 0.5, rowHeight - 5),
            valueText = row.value == nil and nil or tostring(row.value),
            layoutRect = fieldRect,
            editable = row.editor ~= nil,
          }
          if actionable then
            targets[row.targetId] = fieldRect
          end
          rows[#rows + 1] = layoutRow
        end
      end
      if page == "draft" and view.partyFieldHelp then
        partyHelp = view.partyFieldHelp
      end
    end
    if page == "draft" and partyHelp ~= nil then
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
      local cellWidth = math.floor((innerWidth - (columnsThisRow - 1) * 3) / columnsThisRow)
      local x = contentX + columnIndex * (cellWidth + 3)
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
    local cells = sixCellGrid(gridBody, compactBag and 2 or 6, compactBag)
    local cards = {}
    for index, item in ipairs(view.bagPageRows or {}) do
      local cell = cells[index]
      local id = "bag:item:" .. item.item
      targets[id], focusPositions[id] = cell.rect, cell.rect
      addFocusable(id)
      cards[#cards + 1] = {
        kind = "item",
        targetId = id,
        label = item.label,
        value = tostring(item.quantity),
        iconKey = item.iconKey,
        rect = cell.rect,
        iconRect = cell.iconRect,
        textRect = cell.textRect,
        textScale = compactBag and 0.5 or nil,
      }
    end
    local buttonWidth = math.max(34, math.floor((innerWidth - 96) / 2))
    targets["bag:page:previous"] = rect(contentX, pageY, buttonWidth, pageHeight)
    targets["bag:page:next"] = rect(contentX + innerWidth - buttonWidth, pageY, buttonWidth, pageHeight)
    for _, id in ipairs({ "bag:page:previous", "bag:page:next" }) do
      addFocusable(id)
    end
    if view.bagPage0 == 0 then
      disabledTargets["bag:page:previous"] = true
    end
    if view.bagPage0 + 1 >= view.bagPageCount then
      disabledTargets["bag:page:next"] = true
    end
    local addX = contentX + buttonWidth + 4
    targets["bag:add"] = rect(addX, pageY, 60, pageHeight)
    bagPageTextRect =
      rect(addX + 64, pageY + (compactBag and 2 or 7), math.max(1, innerWidth - buttonWidth * 2 - 72), 16)
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

  local actions = {
    {
      id = "save",
      label = "Save",
      enabled = view.ready == true and view.dirty == true and view.valueEditor == nil and view.unappliedDraft ~= true,
    },
    { id = "discard", label = "Discard", enabled = view.ready == true and view.dirty == true },
    { id = "back", label = "Back", enabled = true },
  }
  local actionWidths = {
    math.max(40, metrics.measure("Save") + 24),
    math.max(40, metrics.measure("Discard") + 24),
    math.max(40, metrics.measure(view.locationSave and "Cancel check" or "Back") + 24),
  }
  local widthTotal = actionWidths[1] + actionWidths[2] + actionWidths[3]
  if widthTotal > innerWidth - 8 then
    local actionWidth = math.floor((innerWidth - 8) / 3)
    actionWidths = { actionWidth, actionWidth, actionWidth }
    widthTotal = actionWidth * 3
  end
  local actionGap = 4
  local actionX = contentX + math.floor((innerWidth - widthTotal - actionGap * 2) / 2)
  local actionHeight = math.max(30, metrics.lineHeight + 16)
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
      local searchHeight = math.max(metrics.lineHeight + 8, 24)
      local bodyTop = dialogTop + searchHeight + 2
      local bodyBottom = contentBottom - rowHeight - 2
      local bodyHeight = math.max(0, bodyBottom - bodyTop)
      local offset = view.scrollOffsets and view.scrollOffsets["value:choice"] or 0
      local contentExtent = #dialog.options * rowHeight
      local selectedIndex
      for index, option in ipairs(dialog.options) do
        if option.key == dialog.selectedKey then
          selectedIndex = index
          break
        end
      end
      if selectedIndex and not view.preserveChoiceScroll then
        offset = ScrollViewport.reveal(offset, bodyHeight, (selectedIndex - 1) * rowHeight, rowHeight)
      end
      offset = ScrollViewport.clamp(offset, contentExtent, bodyHeight)
      local viewport = rect(contentX, bodyTop, innerWidth, bodyHeight)
      local rowTargets = {}
      for index, option in ipairs(dialog.options) do
        rowTargets[index] = "choice:" .. option.key
      end
      viewports["value:choice"] =
        makeViewport(viewport, offset, contentExtent, rowHeight, 0, #dialog.options, rowTargets)
      local first, last = ScrollViewport.visibleRange(offset, bodyHeight, rowHeight, 0, #dialog.options)
      for index, option in ipairs(dialog.options) do
        local id = "choice:" .. option.key
        addFocusable(id)
        focusPositions[id] = rect(contentX, bodyTop + (index - 1) * rowHeight - offset, innerWidth, rowHeight - 1)
        if index >= first and index <= last then
          targets[id] = rect(contentX, bodyTop + (index - 1) * rowHeight - offset, innerWidth, rowHeight - 1)
        end
      end
      local footerWidth = math.max(1, math.floor(innerWidth / 2))
      targets.confirm = rect(contentX, contentBottom - rowHeight, footerWidth - 2, rowHeight - 1)
      targets.cancel = rect(contentX + footerWidth, contentBottom - rowHeight, innerWidth - footerWidth, rowHeight - 1)
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
    elseif dialog.kind == "quantity" then
      local controlSize = math.min(48, math.max(32, math.floor(innerWidth / 4)))
      local centerX = contentX + math.floor(innerWidth / 2)
      local controlY = contentTop + math.max(12, math.floor((contentBottom - contentTop - 94) / 2))
      targets["bag:quantity:decrement"] = rect(centerX - controlSize - 42, controlY, controlSize, controlSize)
      targets["bag:quantity:increment"] = rect(centerX + 42, controlY, controlSize, controlSize)
      targets["value-draft"] = rect(centerX - 32, controlY, 64, controlSize)
      targets.confirm = rect(contentX + 4, contentBottom - 34, math.floor(innerWidth / 2) - 6, 30)
      targets.cancel =
        rect(contentX + math.floor(innerWidth / 2) + 2, contentBottom - 34, math.floor(innerWidth / 2) - 6, 30)
      for _, id in ipairs({ "bag:quantity:decrement", "bag:quantity:increment", "confirm", "cancel" }) do
        addFocusable(id)
      end
    else
      local quarter = math.floor(innerWidth / 4)
      for index, action in ipairs({ "digit-left", "digit-right", "digit-down", "digit-up" }) do
        targets[action] =
          rect(contentX + (index - 1) * quarter, contentBottom - rowHeight * 2, quarter - 2, rowHeight - 2)
        addFocusable(action)
      end
      targets.confirm = rect(contentX, contentBottom - rowHeight, math.floor(innerWidth / 2) - 2, rowHeight - 2)
      targets.cancel = rect(
        contentX + math.floor(innerWidth / 2) + 2,
        contentBottom - rowHeight,
        math.floor(innerWidth / 2) - 2,
        rowHeight - 2
      )
      addFocusable("confirm")
      addFocusable("cancel")
      addRow("integer value", "value-draft", "Enter value", dialog.buffer or "")
    end
  end
  if view.modal ~= nil then
    local y = math.max(margin, math.floor(height / 2) - 16)
    local choices = view.modal == "bag-item" and { "bag:quantity", "bag:remove", "cancel" }
      or view.modal == "draft" and { "apply", "discard", "cancel" }
      or view.modal == "remove" and { "remove", "cancel" }
      or { "save", "discard", "cancel" }
    local modalActionWidth = math.floor((innerWidth - 8) / #choices)
    for index, id in ipairs(choices) do
      targets[id] = rect(contentX + (index - 1) * (modalActionWidth + 4), y, modalActionWidth, 28)
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
    else
      for _, id in ipairs({ "digit-left", "digit-right", "digit-up", "digit-down", "value-draft" }) do
        scopeAllowed[id] = true
      end
      if editor.kind == "quantity" then
        scopeAllowed["digit-left"], scopeAllowed["digit-right"] = true, true
        scopeAllowed["digit-up"], scopeAllowed["digit-down"] = true, true
        for _, id in ipairs({ "bag:quantity:decrement", "bag:quantity:increment" }) do
          scopeAllowed[id] = true
        end
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
      if targetId:sub(1, 8) ~= "section:" then
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
  if section == "Location" and width >= 640 and focusGraph["location:grid"] then
    local mapViewport = viewports["location:map-list"]
    if mapViewport then
      for _, mapTargetId in ipairs(mapViewport.rowTargets) do
        if focusGraph[mapTargetId] then
          focusGraph[mapTargetId].right = { "location:grid" }
        end
      end
      local firstMapId = mapViewport.rowTargets[mapViewport.firstIndex]
      if firstMapId and focusGraph[firstMapId] then
        focusGraph["location:grid"].left = { firstMapId }
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
    if editor.kind == "choice" and editor.selectedKey ~= nil then
      defaultFocus = "choice:" .. editor.selectedKey
    elseif editor.kind == "name" then
      local cursor = assert(editor.naming.cursor)
      defaultFocus = tostring(cursor.row) .. ":" .. tostring(cursor.column)
    else
      defaultFocus = focusGraph["value-draft"] and "value-draft" or "digit-left"
    end
  elseif section == "Player" then
    defaultFocus = "money"
  elseif section == "Location" then
    defaultFocus = "location:"
      .. ((view.locationNavigation and view.locationNavigation.page == "map-list") and "map-picker" or "grid")
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
    local flagsViewport = viewports.flags
    local firstVisibleFlag = flagsViewport and flagsViewport.rowTargets[flagsViewport.firstIndex]
    defaultFocus = firstVisibleFlag or "flags:search"
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
      clip = list and list.clip or nil,
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
    content = rect(contentX, contentTop, innerWidth, contentBottom - contentTop),
    footer = rect(margin, height - footerHeight, innerWidth, footerHeight),
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
    partyGrid = partyGrid,
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
        ["digit-left"] = true,
        ["digit-right"] = true,
        ["digit-up"] = true,
        ["digit-down"] = true,
      }
      if view.valueEditor.kind == "quantity" then
        allowed["bag:quantity:decrement"] = true
        allowed["bag:quantity:increment"] = true
      end
    end
  end
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
        return targetId
      end
    end
  end
  return nil
end

return Layout
