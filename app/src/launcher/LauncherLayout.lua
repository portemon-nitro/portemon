-- Pure responsive geometry for the app-owned game launcher.

local PixelScale = require("libs.ui.src.PixelScale")

local LauncherLayout = {}

local MARGIN = 8
local SLOT_HEIGHT = 46
local SLOT_GAP = 8
local ICON_COMPARTMENT = 46
local FOCUS_CLEARANCE = 3
local ACTION_HEIGHT = 32
local BACK_WIDTH = 56
local PROMPT = "Press a button for game selection"
local IMPORT_HINT = "Select to import ROM"

local function rect(x, y, width, height)
  return { x = x, y = y, width = math.max(0, width), height = math.max(0, height) }
end

local function contains(shape, x, y)
  return shape.width > 0
    and shape.height > 0
    and x >= shape.x
    and x < shape.x + shape.width
    and y >= shape.y
    and y < shape.y + shape.height
end

local function fontFor(fonts, key)
  return fonts ~= nil and fonts[key] or nil
end

local function fontHeight(fonts, key, fallback)
  local font = fontFor(fonts, key)
  if font ~= nil and type(font.getHeight) == "function" then
    return font:getHeight()
  end
  return fallback
end

local function textWidth(fonts, key, text, fallback)
  local font = fontFor(fonts, key)
  if font ~= nil and type(font.getWidth) == "function" then
    return font:getWidth(tostring(text))
  end
  return #tostring(text) * fallback
end

-- Shared operation body: one receipt row plus one status block that must
-- hold a text row, an inter-row gap, and an 8px activity indicator (or a
-- 4px progress track) without overlap. The minimum is derived from the
-- measured body height: 4px top inset, one text line, 8px gap, 8px
-- indicator, 2px bottom inset. A status block below that minimum is not an
-- acknowledgement: the caller sees an unavailable plan with no receipt so
-- an unpainted receipt is never acknowledged, while the footer cancel
-- target stays escapable.
---@param inner { x: number, y: number, width: number, height: number } inner content rectangle
---@param fonts { body: love.Font?, prompt: love.Font?, bold: love.Font? }? measured faces
---@param receiptTop number
---@param receiptHeight number
---@param statusTop number
---@param statusBottom number
---@return { x: number, y: number, width: number, height: number }? receipt
---@return { x: number, y: number, width: number, height: number }? status
---@return { x: number, y: number, width: number, height: number }? track
---@return { x: number, y: number, width: number, height: number }? indicator
local function operationBody(inner, fonts, receiptTop, receiptHeight, statusTop, statusBottom)
  local bodyHeight = fontHeight(fonts, "body", 12)
  local statusHeight = math.max(0, statusBottom - statusTop)
  local minHeight = bodyHeight + 22
  if statusHeight < minHeight then
    return nil, nil, nil, nil
  end
  local receipt = rect(inner.x + 4, receiptTop, inner.width - 8, receiptHeight)
  local status = rect(inner.x + 4, statusTop, inner.width - 8, statusHeight)
  local track = rect(status.x, status.y + status.height - 6, status.width, 4)
  local indicator = rect(status.x, status.y + status.height - 10, 50, 8)
  return receipt, status, track, indicator
end

local function wrapLines(fonts, key, text, width, fallback)
  local font = fontFor(fonts, key)
  if font ~= nil and type(font.getWrap) == "function" then
    local _, lines = font:getWrap(tostring(text), math.max(1, width))
    return math.max(1, #lines)
  end
  return math.max(1, math.ceil(textWidth(fonts, key, text, fallback) / math.max(1, width)))
end

local function graph(targets, order, cyclic)
  local nodes, fallbacks = {}, {}
  for _, targetId in ipairs(order) do
    assert(targets[targetId], "action order names a current target")
    nodes[targetId] = { up = {}, down = {}, left = {}, right = {} }
    fallbacks[#fallbacks + 1] = targetId
  end
  for index, targetId in ipairs(order) do
    if index > 1 then
      nodes[targetId].up = { order[index - 1] }
      nodes[order[index - 1]].down = { targetId }
      nodes[targetId].left = { order[index - 1] }
      nodes[order[index - 1]].right = { targetId }
    end
  end
  if cyclic and #order > 1 then
    nodes[order[#order]].down = { order[1] }
    nodes[order[1]].up = { order[#order] }
    nodes[order[#order]].right = { order[1] }
    nodes[order[1]].left = { order[#order] }
    local reversed = {}
    for index = #fallbacks, 1, -1 do
      reversed[#reversed + 1] = fallbacks[index]
    end
    fallbacks = reversed
  end
  return { graph = nodes, targets = targets, fallbacks = fallbacks }
end

-- One integer physical density for every launcher surface. A high-DPI host
-- steps down until the reference layout has room instead of shrinking it into
-- an unusable fractionally magnified surface.
function LauncherLayout.surface(bounds, ratio)
  assert(type(bounds) == "table", "launcher surface needs native bounds")
  assert(type(ratio) == "number" and ratio > 0 and ratio < math.huge, "launcher surface needs a positive pixel ratio")
  local scale = math.max(1, math.min(3, math.floor(math.min(bounds.width * ratio / 320, bounds.height * ratio / 240))))
  local surface
  repeat
    surface = PixelScale.cover(bounds, scale, ratio)
    if surface.logicalViewport.width >= 256 and surface.logicalViewport.height >= 192 then
      break
    end
    scale = scale - 1
  until scale < 1
  return surface
end

local function emptyPlan(width, height)
  local header = rect(0, 0, width, math.min(height, 18))
  return {
    viewport = rect(0, 0, width, height),
    header = header,
    headerCells = { date = header, time = header, version = header, separators = {} },
    unavailable = true,
    graph = graph({}, {}),
  }
end

local function headerPlan(view, width)
  local fonts = view.fonts
  local face = (fonts ~= nil and fonts.prompt ~= nil) and "prompt" or "body"
  local fallback = face == "prompt" and 10 or 12
  local lineHeight = fontHeight(fonts, face, fallback)
  local timeWidth = textWidth(fonts, face, view.timeText or "", fallback)
  local dateWidth = textWidth(fonts, face, view.dateText or "", fallback)
  local versionWidth = textWidth(fonts, face, view.version or "", fallback)
  local padding = 8
  local height = math.max(18, lineHeight + 2)
  local header = rect(0, 0, width, height)
  local innerHeight = height - 4
  local y = header.y + 2
  local timeCell = timeWidth + padding * 2
  local dateCell = dateWidth + padding * 2
  local versionText = versionWidth + padding * 2
  local versionCell = versionText
  if timeCell + dateCell + versionText + 4 > width then
    versionCell = math.max(0, width - timeCell - dateCell - 4)
  end
  local timeX = width - timeCell - dateCell - versionCell - 4
  local cells = { separators = {} }
  cells.time = rect(timeX, y, timeCell, innerHeight)
  cells.separators[1] = timeX + timeCell
  cells.date = rect(timeX + timeCell + 2, y, dateCell, innerHeight)
  cells.separators[2] = timeX + timeCell + 2 + dateCell
  cells.version = rect(timeX + timeCell + dateCell + 4, y, versionCell, innerHeight)
  return header, cells
end

function LauncherLayout.loading(width, height, options)
  assert(type(width) == "number" and width > 0 and type(height) == "number" and height > 0)
  options = options or {}
  local viewport = rect(0, 0, width, height)
  if width < 200 or height < 128 then
    return emptyPlan(width, height)
  end
  local fonts = options.fonts
  local bodyHeight = fontHeight(fonts, "body", 12)
  local promptHeight = fontHeight(fonts, "prompt", 12)
  local promptWidth = math.min(width - MARGIN * 2, textWidth(fonts, "prompt", PROMPT, 6))
  local prompt = rect(width - MARGIN - promptWidth, height - MARGIN - promptHeight, promptWidth, promptHeight)
  local content = rect(MARGIN, MARGIN, width - MARGIN * 2, height - MARGIN * 2)
  local neutral = options.selectionInterrupt == true
  local title = tostring(options.gameLabel or options.title or "")
  local titleWidth = neutral and content.width or content.width - 8
  local titleHeight = wrapLines(fonts, "body", title, titleWidth, 6) * bodyHeight
  local plan = { viewport = viewport, content = content }
  if neutral then
    plan.titleRect = rect(content.x, content.y, content.width, titleHeight)
    plan.loadingStatusRect = rect(content.x, content.y, content.width, bodyHeight)
    plan.indicatorRect = rect(content.x + math.floor((content.width - 50) / 2), content.y, 50, 8)
    local blockHeight = titleHeight + 6 + bodyHeight + 8 + 8
    local areaHeight = content.height - promptHeight - 8
    local blockY = content.y + math.max(0, math.floor((areaHeight - blockHeight) / 2))
    plan.titleRect.y = blockY
    plan.loadingStatusRect.y = blockY + titleHeight + 6
    plan.indicatorRect.y = plan.loadingStatusRect.y + bodyHeight + 8
    local errorTop = plan.indicatorRect.y + plan.indicatorRect.height + 8
    local errorLimit = math.min(content.y + content.height, prompt.y) - 8
    local errorHeight = errorLimit - errorTop
    plan.errorRect = options.error ~= nil
        and errorHeight > 0
        and rect(content.x + 4, errorTop, content.width - 8, errorHeight)
      or nil
    plan.promptRect = prompt
    plan.graph = graph({}, {})
    return plan
  end

  plan.errorRect = options.error ~= nil
      and rect(MARGIN + 4, MARGIN + 96, width - MARGIN * 2 - 8, math.max(12, height - 150))
    or nil
  plan.titleRect = rect(content.x + 4, content.y + 4, content.width - 8, titleHeight)
  -- Footer first: the cancel action owns the bottom band, and the status
  -- block ends above it so the resolved progress geometry never paints
  -- under the button at the minimum supported height.
  local footerY = height - MARGIN - ACTION_HEIGHT
  local statusTop = MARGIN + 62
  local statusBottom = options.canCancel == true and (footerY - 8) or (height - MARGIN - 8)
  local cancel = options.canCancel == true and rect(width - MARGIN - 96, footerY, 96, ACTION_HEIGHT) or nil
  local targets = cancel ~= nil and { cancel = { kind = "cancel", rect = cancel } } or {}
  local receipt, status, track, indicator
  if options.receipt ~= nil then
    receipt, status, track, indicator = operationBody(content, fonts, MARGIN + 34, 24, statusTop, statusBottom)
  end
  plan.receiptRect = receipt
  plan.statusRect = status
  plan.progressTrackRect = track
  plan.indicatorRect = indicator
  -- A receipt without room for its measured status block is not an
  -- acknowledgement: the caller sees an unavailable plan rather than an
  -- overlapping paint. The footer cancel target is preserved through the
  -- empty plan so the operation stays escapable.
  if options.receipt ~= nil and status == nil then
    local unavailable = emptyPlan(width, height)
    if cancel ~= nil then
      unavailable.cancelRect = cancel
      unavailable.graph = graph({ cancel = { kind = "cancel", rect = cancel } }, { "cancel" })
    end
    unavailable.titleRect = plan.titleRect
    unavailable.receiptRect = nil
    unavailable.statusRect = nil
    unavailable.progressTrackRect = nil
    unavailable.indicatorRect = nil
    return unavailable
  end
  plan.cancelRect = cancel
  plan.graph = graph(targets, cancel ~= nil and { "cancel" } or {})
  return plan
end

local function actionRow(y, width, targets, order)
  local gap = 8
  local backIndex
  for index, targetId in ipairs(order) do
    if targetId == "back" then
      backIndex = index
      break
    end
  end
  if backIndex ~= nil then
    local primaries = {}
    for _, targetId in ipairs(order) do
      if targetId ~= "back" then
        primaries[#primaries + 1] = targetId
      end
    end
    if #primaries == 0 then
      local x = width - MARGIN - BACK_WIDTH
      targets.back = { kind = "back", rect = rect(x, y, BACK_WIDTH, ACTION_HEIGHT) }
      return
    end
    local primaryWidth = math.floor((width - MARGIN * 2 - BACK_WIDTH - gap * #primaries) / #primaries)
    local x = MARGIN
    for _, targetId in ipairs(primaries) do
      targets[targetId] = { kind = targetId, rect = rect(x, y, primaryWidth, ACTION_HEIGHT) }
      x = x + primaryWidth + gap
    end
    targets.back = { kind = "back", rect = rect(width - MARGIN - BACK_WIDTH, y, BACK_WIDTH, ACTION_HEIGHT) }
    return
  end
  -- No-back rows share the inset content width, not the full viewport, so a
  -- single action keeps its 8px margins and its focus ring stays on screen.
  local actionWidth = math.floor((width - MARGIN * 2 - gap * (#order - 1)) / #order)
  local x = MARGIN + math.floor((width - MARGIN * 2 - (actionWidth * #order + gap * (#order - 1))) / 2)
  for _, targetId in ipairs(order) do
    targets[targetId] = { kind = targetId, rect = rect(x, y, actionWidth, ACTION_HEIGHT) }
    x = x + actionWidth + gap
  end
end

function LauncherLayout.compute(view, width, height)
  assert(type(view) == "table" and type(view.games) == "table", "launcher geometry needs its edition snapshot")
  assert(type(width) == "number" and width > 0 and type(height) == "number" and height > 0)
  if width < 200 or height < 160 or #view.games ~= 2 then
    return emptyPlan(width, height)
  end
  local header, headerCells = headerPlan(view, width)
  local plan = {
    viewport = rect(0, 0, width, height),
    header = header,
    headerCells = headerCells,
    content = rect(MARGIN, header.height + MARGIN, width - MARGIN * 2, height - header.height - MARGIN * 2),
  }
  local import = view.import
  if import ~= nil then
    plan.mode = import.mode
    local inner = plan.content
    local targets, order = {}, {}
    if import.mode == "choose" or import.mode == "picker" then
      if import.mode == "choose" and import.pickerAvailable == true then
        order[#order + 1] = "choose-rom"
      end
      order[#order + 1] = "back"
      actionRow(inner.y + inner.height - ACTION_HEIGHT, width, targets, order)
      plan.messageRect = rect(inner.x + 4, inner.y + 22, inner.width - 8, math.max(20, inner.height - 76))
    elseif import.mode == "receipt" then
      if import.canCancel == true then
        order[#order + 1] = "cancel"
      end
      order[#order + 1] = "back"
      local footerY = inner.y + inner.height - ACTION_HEIGHT
      actionRow(footerY, width, targets, order)
      local receipt, status, track, indicator =
        operationBody(inner, view.fonts, inner.y + 38, 28, inner.y + 72, footerY - 8)
      plan.receiptRect, plan.statusRect, plan.progressTrackRect, plan.indicatorRect = receipt, status, track, indicator
      if status == nil then
        local unavailable = emptyPlan(width, height)
        unavailable.mode = import.mode
        unavailable.header = plan.header
        unavailable.headerCells = plan.headerCells
        unavailable.content = plan.content
        if next(targets) ~= nil then
          unavailable.graph = graph(targets, order, true)
        end
        return unavailable
      end
    elseif import.mode == "importing" then
      if import.canCancel == true then
        order[#order + 1] = "cancel"
        actionRow(inner.y + inner.height - ACTION_HEIGHT, width, targets, order)
      end
      local footerY = inner.y + inner.height - ACTION_HEIGHT
      local hasFooter = import.canCancel == true
      local statusBottom = hasFooter and (footerY - 8) or (inner.y + inner.height - 8)
      local receipt, status, track, indicator =
        operationBody(inner, view.fonts, inner.y + 38, 28, inner.y + 72, statusBottom)
      plan.receiptRect, plan.statusRect, plan.progressTrackRect, plan.indicatorRect = receipt, status, track, indicator
      if status == nil then
        local unavailable = emptyPlan(width, height)
        unavailable.mode = import.mode
        unavailable.header = plan.header
        unavailable.headerCells = plan.headerCells
        unavailable.content = plan.content
        if next(targets) ~= nil then
          unavailable.graph = graph(targets, order, true)
        end
        return unavailable
      end
    elseif import.mode == "error" then
      order = { "retry", "back" }
      actionRow(inner.y + inner.height - ACTION_HEIGHT, width, targets, order)
      plan.errorRect = rect(inner.x + 4, inner.y + 28, inner.width - 8, math.max(20, inner.height - 72))
    else
      error("unknown launcher import mode: " .. tostring(import.mode))
    end
    plan.graph = graph(targets, order, true)
    return plan
  end

  local fonts = view.fonts
  local bodyHeight = fontHeight(fonts, "body", 12)
  local widestName = 0
  local missingTitles, missingHints = 0, 0
  for _, game in ipairs(view.games) do
    widestName = math.max(widestName, textWidth(fonts, "body", game.label, 6))
    if game.installed ~= true then
      missingTitles = math.max(missingTitles, wrapLines(fonts, "body", game.label, 150, 6))
      missingHints = math.max(missingHints, wrapLines(fonts, "prompt", IMPORT_HINT, 150, 6))
    end
  end
  local wantedWidth = ICON_COMPARTMENT + 12 + widestName
  local widthLimit = width - MARGIN * 2 - FOCUS_CLEARANCE * 2
  local slotWidth = math.min(280, math.floor(width * 0.80), widthLimit)
  if slotWidth < wantedWidth and widthLimit >= wantedWidth then
    slotWidth = wantedWidth
  end
  local textWidthAvailable = slotWidth - ICON_COMPARTMENT - 8
  local titleLines = 0
  for _, game in ipairs(view.games) do
    titleLines = math.max(titleLines, wrapLines(fonts, "body", game.label, textWidthAvailable, 6))
  end
  local requiredHeight = titleLines * bodyHeight + 12
  if missingTitles > 0 then
    requiredHeight = math.max(requiredHeight, (missingTitles + missingHints) * bodyHeight + 3 + 12)
  end
  local slotHeight = math.max(SLOT_HEIGHT, requiredHeight)
  local groupHeight = slotHeight * 2 + SLOT_GAP
  local bodyTop = header.height + MARGIN
  local available = height - bodyTop - MARGIN
  if groupHeight > available then
    return emptyPlan(width, height)
  end
  local groupY = bodyTop + math.floor((available - groupHeight) / 2)
  local slotX = math.floor((width - slotWidth) / 2)
  local slots, targets = {}, {}
  for index, game in ipairs(view.games) do
    assert(type(game.versionId) == "string" and game.versionId ~= "", "edition targets have semantic identities")
    local shape = rect(slotX, groupY + (index - 1) * (slotHeight + SLOT_GAP), slotWidth, slotHeight)
    local slot = { rect = shape }
    local wellHeight = slotHeight - 2
    slot.iconWell = rect(shape.x + 1, shape.y + 1, ICON_COMPARTMENT, wellHeight)
    slot.textRect = rect(
      slot.iconWell.x + ICON_COMPARTMENT + 4,
      shape.y + 3,
      shape.x + shape.width - 3 - (slot.iconWell.x + ICON_COMPARTMENT + 4),
      slotHeight - 6
    )
    slot.focusRect = rect(
      shape.x - FOCUS_CLEARANCE,
      shape.y - FOCUS_CLEARANCE,
      shape.width + FOCUS_CLEARANCE * 2,
      shape.height + FOCUS_CLEARANCE * 2
    )
    slots[game.versionId] = slot
    targets[game.versionId] = { kind = game.versionId, rect = shape }
  end
  plan.slots = slots
  plan.graph = graph(targets, { view.games[1].versionId, view.games[2].versionId })
  return plan
end

function LauncherLayout.hitTest(layout, _, x, y)
  assert(type(layout) == "table", "hit testing needs a current launcher plan")
  if type(x) ~= "number" or type(y) ~= "number" then
    return nil
  end
  for targetId, target in pairs(layout.graph.targets) do
    if contains(target.rect, x, y) then
      return targetId
    end
  end
  return nil
end

function LauncherLayout.hitTestLoading(layout, x, y)
  return LauncherLayout.hitTest(layout, nil, x, y)
end

return LauncherLayout
