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
  local footerHeight = height <= 200 and 38 or 40
  local headerHeight = height <= 200 and 32 or 48
  local railWidth = width >= 400 and 88 or 0
  local rows, targets, focusable, disabledTargets, focusPositions = {}, {}, {}, {}, {}
  local locationGrid
  local focusableSet = {}
  local function addFocusable(targetId)
    if not focusableSet[targetId] then
      focusableSet[targetId] = true
      focusable[#focusable + 1] = targetId
    end
  end
  local innerWidth = math.max(1, width - margin * 2 - (railWidth > 0 and railWidth + 6 or 0))
  local contentX = margin + (railWidth > 0 and railWidth + 6 or 0)
  local contentTop = headerHeight + (railWidth > 0 and 0 or 2)
  local contentBottom = math.max(contentTop + 1, height - footerHeight - 2)
  local section = view.section or "Player"
  local rowHeight = math.max(16, metrics.lineHeight + 5)
  local enabledSections = { "Location", "Player", "Party", "Bag", "Progress" }
  local navigation = {}
  if railWidth > 0 then
    for index, name in ipairs(enabledSections) do
      local id = "section:" .. name
      targets[id] = rect(margin, headerHeight + (index - 1) * 30, railWidth, 26)
      navigation[#navigation + 1] = { role = "action", targetId = id, id = id, label = name }
      addFocusable(id)
    end
  else
    targets.section = rect(margin, headerHeight + 1, innerWidth, 18)
    navigation[#navigation + 1] = {
      role = "action",
      targetId = "section",
      id = "section",
      label = "Section: " .. section,
    }
    addFocusable("section")
    contentTop = headerHeight + 22
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

  if section == "Party" and (view.partyPage == "detail" or view.partyPage == "draft") and view.partySubpages ~= nil then
    local labels = view.partySubpages
    local tabWidth = math.max(1, math.floor(innerWidth / #labels))
    for index, label in ipairs(labels) do
      local id = "party:subpage:" .. label
      local tab = rect(contentX + (index - 1) * tabWidth, contentTop, tabWidth - 1, rowHeight - 2)
      targets[id] = tab
      addFocusable(id)
    end
    contentTop = contentTop + rowHeight
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
        if y >= contentTop and y + rowHeight <= contentBottom then
          targets[id] = rect(contentX, y, listWidth, rowHeight - 2)
          navigation[#navigation + 1] = {
            role = "action",
            targetId = id,
            label = map.symbol,
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
          rows[#rows + 1] = { role = "action", targetId = id, label = map.symbol, value = map.section }
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
      local zoomWidth = math.min(36, math.floor(gridWidth / 4))
      targets["location:zoom-out"] = rect(controlX + gridWidth - zoomWidth * 2 - 2, controlY, zoomWidth, controlHeight)
      targets["location:zoom-in"] = rect(controlX + gridWidth - zoomWidth, controlY, zoomWidth, controlHeight)
      navigation[#navigation + 1] = { role = "action", targetId = "location:zoom-out", label = "−" }
      navigation[#navigation + 1] = { role = "action", targetId = "location:zoom-in", label = "+" }
      addFocusable("location:zoom-out")
      addFocusable("location:zoom-in")

      local statusHeight = 58
      local gridClip = rect(
        gridLeft,
        controlY + controlHeight + 3,
        gridWidth,
        math.max(1, contentBottom - controlY - controlHeight - statusHeight - 5)
      )
      local tileSize = locationNav.scale
      assert(tileSize == 16 or tileSize == 24 or tileSize == 32, "location scale must be one of the supported steps")
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

      addFocusable("location:grid")
      focusPositions["location:grid"] = gridClip
      local cursor = locationNav.cursor
      if cursor ~= nil then
        local id = string.format("location:tile:%d:%d", cursor.fieldX, cursor.fieldZ)
        addFocusable(id)
      end
      local status = location.status
      local reason = status.state == "failed" and status.reason
        or status.state == "pending" and "Preparing map data"
        or ""
      rows[#rows + 1] = {
        role = "read-only value",
        targetId = "location:status",
        label = location.symbol or ("Map " .. tostring(location.mapId)),
        value = reason,
      }
      rows[#rows + 1] = {
        role = "read-only value",
        targetId = "location:help",
        label = "Physical placement only; story consistency isn't checked.",
      }
    end
  elseif section == "Player" then
    local snapshot = assert(view.session)
    addRow("read-only value", "player", "Player", snapshot.playerName)
    addRow("integer value", "money", "Money", snapshot.money)
  elseif section == "Progress" then
    addRow("action", "filter-named", "Flag filter", view.flagFilterLabel or view.flagFilter or "Named", true)
    local filterRect = targets["filter-named"]
    if filterRect then
      local controlWidth = math.max(1, math.floor(filterRect.width / 4))
      targets["group-previous"] = rect(filterRect.x, filterRect.y, controlWidth, filterRect.height)
      targets["filter-named"] =
        rect(filterRect.x + controlWidth + 1, filterRect.y, filterRect.width - controlWidth * 2 - 2, filterRect.height)
      targets["group-next"] =
        rect(filterRect.x + filterRect.width - controlWidth, filterRect.y, controlWidth, filterRect.height)
    end
    addRow("warning", "story-warning", "Flags may affect story state.", nil)
    local flags = view.flagRows or {}
    local flagOffset = view.scrollOffsets
        and view.scrollOffsets["flags:" .. tostring(view.flagGroup or view.flagFilter)]
      or 0
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
        end
      end
    end
  elseif section == "Party" then
    local partyRows = view.partyRows or {}
    local page = view.partyPage or "list"
    if view.partyPage == "list" then
      local id = view.partyCanAdd and "party:add" or "party:capacity"
      local label = view.partyCanAdd and ("Add Pokémon (" .. tostring(view.partyMemberCount) .. "/6)")
        or "Party full (6/6)"
      placeRow(
        view.partyCanAdd and "action" or "read-only value",
        id,
        label,
        nil,
        view.partyCanAdd,
        contentTop,
        rowHeight
      )
      if not view.partyCanAdd then
        disabledTargets[id] = true
      end
      contentTop = contentTop + rowHeight
    end
    for _, row in ipairs(partyRows) do
      if
        row.role == "action"
        or row.role == "toggle"
        or row.role == "integer value"
        or row.role == "named choice"
        or row.targetId:match("^party:slot:")
      then
        addFocusable(row.targetId)
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
    local bodyTop = contentTop + #rows * rowHeight
    local bodyBottom = contentBottom - actionHeight
    local bodyHeight = math.max(0, bodyBottom - bodyTop)
    local scrollId = "party:" .. page .. ":" .. tostring(view.partySubpage or "list")
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
      if not row.targetId:match("^party:empty%-slot:") then
        addFocusable(row.targetId)
      end
      focusPositions[row.targetId] =
        rect(contentX, bodyTop + (index - 1) * rowHeight - offset, innerWidth, rowHeight - 2)
      if index >= first and index <= last then
        local y = bodyTop + (index - 1) * rowHeight - offset
        if y >= bodyTop and y + rowHeight <= bodyBottom then
          placeRow(row.role, row.targetId, row.label, row.value, row.enabled, y, rowHeight)
          rows[#rows].iconKey = row.iconKey
        end
      end
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
      targets[id] = rect(x, y, cellWidth, rowHeight - 2)
      rows[#rows + 1] = { role = "action", targetId = id, id = id, label = action[2], enabled = action[3] ~= false }
      addFocusable(id)
      if action[3] == false then
        disabledTargets[id] = true
      end
    end
  elseif section == "Bag" then
    local bagRows = view.bagRows or {}
    local compact = width < 400
    if compact then
      local top = contentTop + #rows * rowHeight
      targets["bag:pocket:choose"] = rect(contentX, top, innerWidth, rowHeight - 2)
      navigation[#navigation + 1] =
        { role = "action", targetId = "bag:pocket:choose", label = view.bagPocketLabel or "Pocket" }
      addFocusable("bag:pocket:choose")
      contentTop = top + rowHeight
    else
      for _, pocket in ipairs(view.bagPockets or {}) do
        local id = "bag:pocket:" .. pocket.key
        addRow("action", id, pocket.label, nil, true)
      end
    end
    local actionY = contentBottom - rowHeight
    local bodyTop = contentTop + #rows * rowHeight
    local bodyBottom = actionY - 2
    local bodyHeight = math.max(0, bodyBottom - bodyTop)
    ---@type number
    local offset = view.scrollOffsets and view.scrollOffsets["bag:" .. tostring(view.bagPocket)]
      or (view.scrollOffset or 0) * rowHeight
    local contentExtent = #bagRows * rowHeight
    offset = ScrollViewport.clamp(offset, contentExtent, bodyHeight)
    local rowTargets = {}
    for index, item in ipairs(bagRows) do
      rowTargets[index] = "bag:item:" .. item.item
    end
    viewports.bag = makeViewport(
      rect(contentX, bodyTop, innerWidth, bodyHeight),
      offset,
      contentExtent,
      rowHeight,
      0,
      #bagRows,
      rowTargets
    )
    local first, last = ScrollViewport.visibleRange(offset, bodyHeight, rowHeight, 0, #bagRows)
    for index, item in ipairs(bagRows) do
      local id = "bag:item:" .. item.item
      addFocusable(id)
      focusPositions[id] = rect(contentX, bodyTop + (index - 1) * rowHeight - offset, innerWidth, rowHeight - 2)
      if index >= first and index <= last then
        local y = bodyTop + (index - 1) * rowHeight - offset
        local target = rect(contentX, y, innerWidth, rowHeight - 2)
        if y >= bodyTop and y + rowHeight <= bodyBottom then
          targets[id] = target
          rows[#rows + 1] = {
            role = "read-only value",
            targetId = id,
            id = id,
            label = item.label or item.item,
            value = item.quantity,
            enabled = true,
          }
        end
      end
    end
    local actionWidth = math.max(1, math.floor((innerWidth - 8) / 3))
    local bagActions = {
      { id = "bag:quantity", label = "Quantity", enabled = view.bagSelectedItem ~= nil },
      { id = "bag:remove", label = "Remove", enabled = view.bagSelectedItem ~= nil },
      { id = "bag:add", label = "Add", enabled = true },
    }
    for index, action in ipairs(bagActions) do
      local x = contentX + (index - 1) * (actionWidth + 4)
      targets[action.id] = rect(x, actionY, actionWidth, rowHeight - 2)
      action.targetId, action.role = action.id, "action"
      navigation[#navigation + 1] = action
      addFocusable(action.id)
      if not action.enabled then
        disabledTargets[action.id] = true
      end
    end
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
  local actionWidth = math.max(1, math.floor((innerWidth - 8) / 3))
  for index, action in ipairs(actions) do
    local x = contentX + (index - 1) * (actionWidth + 4)
    targets[action.id] = rect(x, height - footerHeight + 14, actionWidth, footerHeight - 16)
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
      local controlWidth = math.max(1, math.floor(innerWidth / 3))
      targets["group-previous"] = rect(contentX, dialogTop, controlWidth - 2, rowHeight)
      targets["clear-search"] = rect(contentX + controlWidth, dialogTop, controlWidth - 2, rowHeight)
      targets["group-next"] = rect(contentX + controlWidth * 2, dialogTop, innerWidth - controlWidth * 2, rowHeight)
      local bodyTop = dialogTop + rowHeight + 2
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
      if selectedIndex then
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
    else
      local quarter = math.floor(innerWidth / 4)
      for index, action in ipairs({ "digit-left", "digit-right", "digit-down", "digit-up" }) do
        targets[action] =
          rect(contentX + (index - 1) * quarter, contentBottom - rowHeight * 2, quarter - 2, rowHeight - 2)
      end
      targets.confirm = rect(contentX, contentBottom - rowHeight, math.floor(innerWidth / 2) - 2, rowHeight - 2)
      targets.cancel = rect(
        contentX + math.floor(innerWidth / 2) + 2,
        contentBottom - rowHeight,
        math.floor(innerWidth / 2) - 2,
        rowHeight - 2
      )
      addRow("integer value", "value-draft", "Enter value", dialog.buffer or "")
    end
  end
  if view.modal ~= nil then
    local y = math.max(headerHeight, math.floor(height / 2) - 16)
    local choices = view.modal == "draft" and { "apply", "discard", "cancel" }
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
    scopeAllowed = view.modal == "draft" and { apply = true, discard = true, cancel = true }
      or view.modal == "remove" and { remove = true, cancel = true }
      or { save = true, discard = true, cancel = true }
  elseif scope.kind == "value" then
    local editor = assert(view.valueEditor, "value scope needs its active editor")
    scopeAllowed = { confirm = true, cancel = true }
    if editor.kind == "choice" then
      scopeAllowed["group-previous"] = true
      scopeAllowed["group-next"] = true
      scopeAllowed["clear-search"] = true
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
  for viewportId, list in pairs(viewports) do
    assert(
      list.clip and list.rowExtent and list.firstIndex and list.lastIndex and list.rowTargets,
      "scroll viewports publish logical row geometry"
    )
    for _, targetId in ipairs(list.rowTargets) do
      viewportByTarget[targetId] = viewportId
    end
  end
  local focusGraph = {}
  for _, targetId in ipairs(focusable) do
    focusGraph[targetId] = { up = {}, down = {}, left = {}, right = {} }
  end
  for _, targetId in ipairs(focusable) do
    local source = focusPositions[targetId] or targets[targetId]
    if source then
      local sourceX, sourceY = source.x + source.width / 2, source.y + source.height / 2
      local candidates = { up = {}, down = {}, left = {}, right = {} }
      for _, candidateId in ipairs(focusable) do
        local candidate = focusPositions[candidateId] or targets[candidateId]
        if candidate and candidateId ~= targetId then
          local dx = candidate.x + candidate.width / 2 - sourceX
          local dy = candidate.y + candidate.height / 2 - sourceY
          local direction = math.abs(dx) > math.abs(dy) and (dx < 0 and "left" or "right")
            or (dy < 0 and "up" or "down")
          local distance = dx * dx + dy * dy
          candidates[direction][#candidates[direction] + 1] = { id = candidateId, distance = distance }
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
  local focusOrder = {}
  local targetRecords = {}
  for _, targetId in ipairs(focusable) do
    focusOrder[#focusOrder + 1] = targetId
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
    if target then
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
    header = rect(margin, 2, innerWidth, headerHeight - 2),
    content = rect(contentX, contentTop, innerWidth, contentBottom - contentTop),
    footer = rect(margin, height - footerHeight, innerWidth, footerHeight),
    rows = rows,
    focusedValueHelp = focusedValueHelp,
    navigation = navigation,
    focusOrder = focusOrder,
    focusGraph = focusGraph,
    targets = targetRecords,
    actions = actions,
    activeSection = section,
    locationGrid = locationGrid,
    scrollOffset = view.scrollOffset or 0,
    viewports = viewports,
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
    allowed = view.modal == "draft" and { apply = true, discard = true, cancel = true }
      or view.modal == "remove" and { remove = true, cancel = true }
      or { save = true, discard = true, cancel = true }
  elseif view.valueEditor ~= nil then
    if view.valueEditor.kind == "choice" then
      allowed = {
        cancel = true,
        confirm = true,
        ["group-previous"] = true,
        ["group-next"] = true,
        ["clear-search"] = true,
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
