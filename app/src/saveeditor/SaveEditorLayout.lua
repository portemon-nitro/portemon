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
  local rows, targets, focusable, disabledTargets = {}, {}, {}, {}
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
  local rowHeight = height <= 200 and ((section == "Bag" or section == "Party") and 19 or 22) or 34
  local enabledSections = { "Player", "Party", "Bag", "Progress" }
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
  elseif section == "Party" then
    local partyRows = view.partyRows or {}
    local first = math.max(1, math.floor(view.scrollOffset or 0) + 1)
    if view.partyPage == "list" then
      if view.partyCanAdd then
        addRow("action", "party:add", "Add Pokémon (" .. tostring(view.partyMemberCount) .. "/6)", nil, true)
      else
        addRow("read-only value", "party:capacity", "Party capacity", "Full (6/6)", false)
      end
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
    local decisionRows = view.partyPage == "detail" and 5 or 3
    local spaceForRows = math.max(0, contentBottom - contentTop - #rows * rowHeight)
    local visiblePartyRows = math.max(0, math.floor(spaceForRows / rowHeight) - decisionRows)
    for index = first, math.min(#partyRows, first + visiblePartyRows - 1) do
      local row = partyRows[index]
      addRow(row.role, row.targetId, row.label, row.value, row.enabled)
      local layoutRow = rows[#rows]
      if layoutRow and layoutRow.targetId == row.targetId then
        layoutRow.iconKey = row.iconKey
      end
    end
    if view.partyPage == "list" then
      -- Add/capacity appears before the member rows so it remains visible in compact layouts.
    elseif view.partyPage == "detail" then
      addRow("action", "party:edit", "Edit member", nil, true)
      addRow("action", "party:move-up", "Move up", nil, view.partySlot0 ~= 0)
      addRow("action", "party:move-down", "Move down", nil, view.partySlot0 ~= view.partyLastSlot0)
      addRow("action", "party:remove", "Remove member", nil, true)
      addRow("action", "party:back", "Party list", nil, true)
    elseif view.partyDirty then
      addRow("action", "party:apply", "Apply member changes", nil, view.partyValid == true)
      addRow("action", "party:discard", "Discard member changes", nil, true)
      addRow("action", "party:cancel", "Return to member", nil, true)
    else
      addRow("action", "party:apply", "Apply member changes", nil, view.partyValid == true)
      addRow("action", "party:discard", "Discard member changes", nil, true)
      addRow("action", "party:cancel", "Return to member", nil, true)
    end
  elseif section == "Bag" then
    if width >= 400 then
      for _, pocket in ipairs(view.bagPockets or {}) do
        local id = "bag:pocket:" .. pocket.key
        addRow("action", id, pocket.label, nil, true)
      end
    else
      addRow("action", "bag:pocket:choose", "Pocket", view.bagPocketLabel or view.bagPocket, true)
    end
    local bagRows = view.bagRows or {}
    local first = math.max(1, math.floor(view.scrollOffset or 0) + 1)
    for _, item in ipairs(bagRows) do
      addFocusable("bag:item:" .. item.item)
    end
    for index = first, #bagRows do
      local item = bagRows[index]
      addRow("read-only value", "bag:item:" .. item.item, item.label or item.item, item.quantity, true)
    end
    if view.bagSelectedItem then
      addRow("action", "bag:quantity", "Set quantity", view.bagSelectedQuantity, true)
      addRow("action", "bag:remove", "Remove stack", nil, true)
    end
    addRow("action", "bag:add", "Add item", nil, true)
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
  return {
    viewport = rect(0, 0, width, height),
    header = rect(margin, 2, innerWidth, headerHeight - 2),
    content = rect(contentX, contentTop, innerWidth, contentBottom - contentTop),
    footer = rect(margin, height - footerHeight, innerWidth, footerHeight),
    rows = rows,
    navigation = navigation,
    focusable = focusable,
    targets = targets,
    disabledTargets = disabledTargets,
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
    allowed = view.modal == "draft" and { apply = true, discard = true, cancel = true }
      or view.modal == "remove" and { remove = true, cancel = true }
      or { save = true, discard = true, cancel = true }
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
        if layout.disabledTargets[targetId] then
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
