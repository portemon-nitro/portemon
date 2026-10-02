-- Computes the editor's canonical logical rows and hit targets.

local Layout = {}

local function rect(x, y, width, height)
  return { x = x, y = y, width = math.max(1, width), height = math.max(1, height) }
end

function Layout.compute(view, width, height)
  assert(type(view) == "table" and width > 0 and height > 0)
  local margin = width <= 280 and 4 or 12
  local footerHeight = height <= 200 and 38 or 40
  local headerHeight = height <= 200 and 32 or 48
  local railWidth = width >= 400 and 88 or 0
  local rows, targets = {}, {}
  local innerWidth = math.max(1, width - margin * 2 - (railWidth > 0 and railWidth + 6 or 0))
  local contentX = margin + (railWidth > 0 and railWidth + 6 or 0)
  local contentTop = headerHeight + (railWidth > 0 and 0 or 2)
  local contentBottom = math.max(contentTop + 1, height - footerHeight - 2)
  local rowHeight = height <= 200 and 22 or 34
  local section = view.section or "Player"
  local enabledSections = { "Player", "Progress" }
  local navigation = {}
  if railWidth > 0 then
    for index, name in ipairs(enabledSections) do
      local id = "section:" .. name
      targets[id] = rect(margin, headerHeight + (index - 1) * 30, railWidth, 26)
      navigation[#navigation + 1] = { role = "action", targetId = id, id = id, label = name }
    end
  else
    local other = section == "Player" and "Progress" or "Player"
    local id = "section:" .. other
    targets[id] = rect(margin, headerHeight + 1, innerWidth, 18)
    navigation[#navigation + 1] = { role = "action", targetId = id, id = id, label = "Sections: " .. other }
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
    local start = math.max(1, math.floor(view.scrollOffset or 0) + 1)
    for index = start, #flags do
      local flag = flags[index]
      addRow("toggle", "flag:" .. flag.name, flag.name, flag.value, true)
    end
  else
    addRow("read-only value", "section", section, "Available in a later update")
  end

  local actions = {
    { id = "save", label = "Save", enabled = view.ready == true and view.dirty == true and view.valueEditor == nil },
    { id = "discard", label = "Discard", enabled = view.ready == true and view.dirty == true },
    { id = "back", label = "Back", enabled = true },
  }
  local actionWidth = math.max(1, math.floor((innerWidth - 8) / 3))
  for index, action in ipairs(actions) do
    local x = contentX + (index - 1) * (actionWidth + 4)
    targets[action.id] = rect(x, height - footerHeight + 14, actionWidth, footerHeight - 16)
    action.role, action.targetId, action.value = "action", action.id, action.label
  end

  if view.valueEditor ~= nil then
    local dialog = view.valueEditor
    local dialogTop = contentTop + 4
    if dialog.kind == "choice" then
      targets["group-previous"] = rect(contentX, dialogTop, math.floor(innerWidth / 3) - 2, 20)
      targets["group-next"] = rect(contentX + 2 * math.floor(innerWidth / 3), dialogTop, math.floor(innerWidth / 3), 20)
      local optionTop = dialogTop + 24
      local optionHeight = math.min(24, math.floor((contentBottom - optionTop - 30) / 8))
      for index, option in ipairs(dialog.options) do
        targets[option.key] = rect(contentX, optionTop + (index - 1) * optionHeight, innerWidth, optionHeight - 1)
      end
      targets["page-previous"] = rect(contentX, contentBottom - 28, math.floor(innerWidth / 3) - 2, 24)
      targets["page-next"] =
        rect(contentX + math.floor(innerWidth / 3), contentBottom - 28, math.floor(innerWidth / 3) - 2, 24)
      targets.cancel =
        rect(contentX + 2 * math.floor(innerWidth / 3), contentBottom - 28, math.floor(innerWidth / 3), 24)
    elseif dialog.kind == "name" then
      local naming = assert(dialog.naming)
      local cellWidth = math.max(1, math.floor(innerWidth / 13))
      local gridTop = dialogTop + 32
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
      targets.confirm = rect(contentX, contentBottom - 26, math.floor(innerWidth / 2) - 2, 24)
      targets.cancel =
        rect(contentX + math.floor(innerWidth / 2) + 2, contentBottom - 26, math.floor(innerWidth / 2) - 2, 24)
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
    targets.save = rect(contentX, y, math.floor((innerWidth - 8) / 3), 28)
    targets.discard = rect(contentX + math.floor((innerWidth - 8) / 3) + 4, y, math.floor((innerWidth - 8) / 3), 28)
    targets.cancel =
      rect(contentX + 2 * (math.floor((innerWidth - 8) / 3) + 4), y, math.floor((innerWidth - 8) / 3), 28)
  end
  return {
    viewport = rect(0, 0, width, height),
    header = rect(margin, 2, innerWidth, headerHeight - 2),
    content = rect(contentX, contentTop, innerWidth, contentBottom - contentTop),
    footer = rect(margin, height - footerHeight, innerWidth, footerHeight),
    rows = rows,
    navigation = navigation,
    targets = targets,
    actions = actions,
    activeSection = section,
    scrollOffset = view.scrollOffset or 0,
  }
end

function Layout.hitTest(layout, view, x, y)
  assert(type(layout) == "table" and type(view) == "table")
  if view.valueEditor and view.valueEditor.kind == "name" then
    for _, control in ipairs(view.valueEditor.naming.controls) do
      local targetId = "name-control:" .. control.id
      local target = layout.targets[targetId]
      if
        target
        and x >= target.x
        and x < target.x + target.width
        and y >= target.y
        and y < target.y + target.height
      then
        return targetId
      end
    end
  end
  local allowed
  if view.modal ~= nil then
    allowed = { save = true, discard = true, cancel = true }
  elseif view.valueEditor ~= nil then
    if view.valueEditor.kind == "choice" then
      allowed = {
        cancel = true,
        ["page-previous"] = true,
        ["page-next"] = true,
        ["group-previous"] = true,
        ["group-next"] = true,
      }
      for _, option in ipairs(view.valueEditor.options) do
        allowed[option.key] = true
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
      if x >= target.x and x < target.x + target.width and y >= target.y and y < target.y + target.height then
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
