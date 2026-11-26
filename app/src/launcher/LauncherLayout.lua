-- Pure responsive geometry for the app-owned game launcher.

local PixelScale = require("libs.ui.src.PixelScale")

local LauncherLayout = {}

local MARGIN = 8
local HEADER_HEIGHT = 36
local HEADER_TALL_HEIGHT = 40
local SLOT_HEIGHT = 56
local SLOT_GAP = 10
local ACTION_HEIGHT = 32

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

local function textWidth(view, text, bold)
  local fonts = view.fonts
  local font = fonts and (bold and fonts.bold or fonts.body)
  if font ~= nil and type(font.getWidth) == "function" then
    return font:getWidth(tostring(text))
  end
  return #tostring(text) * 6
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
  return {
    viewport = rect(0, 0, width, height),
    unavailable = true,
    graph = graph({}, {}),
  }
end

function LauncherLayout.loading(width, height, options)
  assert(type(width) == "number" and width > 0 and type(height) == "number" and height > 0)
  options = options or {}
  local viewport = rect(0, 0, width, height)
  if width < 200 or height < 128 then
    local plan = emptyPlan(width, height)
    plan.promptRect = nil
    return plan
  end
  local promptWidth = math.min(width - MARGIN * 2, textWidth(options, "Press a button for game selection"))
  local promptHeight = 12
  local prompt = rect(width - MARGIN - promptWidth, height - MARGIN - promptHeight, promptWidth, promptHeight)
  local plan = { viewport = viewport, content = rect(MARGIN, MARGIN, width - MARGIN * 2, height - MARGIN * 2) }
  local errorRect = options.error ~= nil
      and rect(MARGIN + 4, MARGIN + 96, width - MARGIN * 2 - 8, math.max(12, height - 150))
    or nil
  if options.selectionInterrupt == true then
    plan.promptRect = prompt
    plan.errorRect = errorRect
    plan.graph = graph({}, {})
    return plan
  end
  local receipt = options.receipt ~= nil and rect(MARGIN + 4, MARGIN + 34, width - MARGIN * 2 - 8, 24) or nil
  local cancel = options.canCancel == true
      and rect(width - MARGIN - 96, height - MARGIN - ACTION_HEIGHT, 96, ACTION_HEIGHT)
    or nil
  local targets = cancel ~= nil and { cancel = { kind = "cancel", rect = cancel } } or {}
  plan.receiptRect = receipt
  plan.statusRect = receipt ~= nil and rect(MARGIN + 4, MARGIN + 62, width - MARGIN * 2 - 8, 32) or nil
  plan.errorRect = errorRect
  plan.cancelRect = cancel
  plan.promptRect = nil
  plan.graph = graph(targets, cancel ~= nil and { "cancel" } or {})
  return plan
end

local function headerHeight(view, width)
  local versionWidth = textWidth(view, view.version or "", false) + 8
  local clockWidth = textWidth(view, string.format("%s  %s", view.dateText or "", view.timeText or ""), true)
  return clockWidth + versionWidth + 24 <= width and HEADER_HEIGHT or HEADER_TALL_HEIGHT
end

local function actionRow(y, width, targets, order)
  local gap = 8
  local actionWidth = math.floor((width - gap * (#order - 1)) / #order)
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
  local header = rect(0, 0, width, headerHeight(view, width))
  local plan = {
    viewport = rect(0, 0, width, height),
    header = header,
    content = rect(MARGIN, header.height + MARGIN, width - MARGIN * 2, height - header.height - MARGIN * 2),
    narrowHeader = header.height == HEADER_TALL_HEIGHT,
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
      actionRow(inner.y + inner.height - ACTION_HEIGHT, width, targets, order)
      plan.receiptRect = rect(inner.x + 4, inner.y + 38, inner.width - 8, 28)
      plan.statusRect = rect(inner.x + 4, inner.y + 72, inner.width - 8, math.max(16, inner.height - 116))
    elseif import.mode == "importing" then
      if import.canCancel == true then
        order[#order + 1] = "cancel"
        actionRow(inner.y + inner.height - ACTION_HEIGHT, width, targets, order)
      end
      plan.receiptRect = rect(inner.x + 4, inner.y + 38, inner.width - 8, 28)
      plan.statusRect = rect(inner.x + 4, inner.y + 72, inner.width - 8, math.max(16, inner.height - 116))
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

  local slotWidth = math.min(360, width - MARGIN * 2 - 8)
  local slotX = math.floor((width - slotWidth) / 2)
  local bodyTop = header.height + MARGIN
  local available = height - bodyTop - MARGIN
  local slotHeight = math.min(64, math.max(SLOT_HEIGHT, math.floor((available - SLOT_GAP) / 2)))
  local groupHeight = slotHeight * 2 + SLOT_GAP
  local groupY = bodyTop + math.floor((available - groupHeight) / 2)
  local slots, targets = {}, {}
  for index, game in ipairs(view.games) do
    assert(type(game.versionId) == "string" and game.versionId ~= "", "edition targets have semantic identities")
    local shape = rect(slotX, groupY + (index - 1) * (slotHeight + SLOT_GAP), slotWidth, slotHeight)
    local slot = { rect = shape }
    local wellSize = math.min(36, slotHeight - 12)
    slot.iconWell =
      rect(slot.rect.x + 8, slot.rect.y + math.floor((slot.rect.height - wellSize) / 2), wellSize, wellSize)
    slot.textRect =
      rect(slot.rect.x + wellSize + 18, slot.rect.y + 4, slot.rect.width - wellSize - 26, slot.rect.height - 8)
    slot.focusRect = rect(slot.rect.x - 3, slot.rect.y - 3, slot.rect.width + 6, slot.rect.height + 6)
    slots[game.versionId] = slot
    targets[game.versionId] = { kind = game.versionId, rect = slot.rect }
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
