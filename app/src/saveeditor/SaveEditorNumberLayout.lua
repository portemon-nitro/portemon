-- Resolves compact numeric columns and action geometry without mutating editor state.

local NumberLayout = {}

---@class SaveEditorNumberLayoutRect
---@field x number
---@field y number
---@field width number
---@field height number

---@class SaveEditorNumberLayoutProjection
---@field digitCount integer
---@field digits string[]

---@class SaveEditorNumberLayoutFont
---@field lineHeight number
---@field measure fun(text: string): number

---@class SaveEditorNumberLayoutArrow
---@field width number
---@field height number

---@class SaveEditorNumberLayoutFrame
---@field inset number
---@field actionHeight number
---@field errorHeight number
---@field actionGap number

---@class SaveEditorNumberLayoutSpec
---@field available SaveEditorNumberLayoutRect
---@field projection SaveEditorNumberLayoutProjection
---@field font SaveEditorNumberLayoutFont
---@field arrows SaveEditorNumberLayoutArrow
---@field frame SaveEditorNumberLayoutFrame

---@class SaveEditorNumberLayoutColumn
---@field place integer
---@field digit string
---@field upRect SaveEditorNumberLayoutRect
---@field digitRect SaveEditorNumberLayoutRect
---@field downRect SaveEditorNumberLayoutRect

---@class SaveEditorNumberLayoutResult
---@field bodyRect SaveEditorNumberLayoutRect
---@field stripRect SaveEditorNumberLayoutRect
---@field columns SaveEditorNumberLayoutColumn[]
---@field confirmRect SaveEditorNumberLayoutRect
---@field backRect SaveEditorNumberLayoutRect
---@field errorRect SaveEditorNumberLayoutRect

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

---@param spec SaveEditorNumberLayoutSpec
---@return SaveEditorNumberLayoutResult|nil, 'too_small'?
function NumberLayout.resolve(spec)
  assert(type(spec) == "table" and type(spec.available) == "table")
  local available = spec.available
  local projection = assert(spec.projection)
  local font = assert(spec.font)
  local arrows = assert(spec.arrows)
  local frame = assert(spec.frame)
  local count = assert(projection.digitCount)
  assert(count > 0 and count % 1 == 0 and #projection.digits == count)
  assert(arrows.width > 0 and arrows.height > 0 and font.lineHeight > 0)
  assert(frame.inset >= 0 and frame.actionHeight > 0 and frame.errorHeight > 0)
  assert(available.x == available.x and available.y == available.y)
  assert(available.width == available.width and available.height == available.height)
  assert(available.width >= 0 and available.height >= 0)
  local gap, columnGap = 2, 2
  local pad = frame.inset
  local buttonsGap = frame.actionGap
  local confirmWidth = math.max(40, math.ceil(font.measure("Confirm") + 24))
  local backWidth = math.max(40, math.ceil(font.measure("Cancel") + 24))
  local actionsWidth = confirmWidth + buttonsGap + backWidth
  local fixedHeight = pad * 2 + font.lineHeight + gap * 2 + frame.actionGap + frame.actionHeight + 2 + frame.errorHeight
  local maxColumnWidth = math.floor((available.width - pad * 2 - (count - 1) * columnGap) / count)
  local maxScale = math.min(1, maxColumnWidth / arrows.width)
  local maxDigitWidth = 0
  for _, digit in ipairs(projection.digits) do
    maxDigitWidth = math.max(maxDigitWidth, math.ceil(font.measure(digit)))
  end
  local maxArrowHeight = math.floor((available.height - fixedHeight) / 2)
  local scale = math.min(maxScale, maxArrowHeight / arrows.height)
  if actionsWidth + pad * 2 > available.width or scale < 0.5 or maxScale <= 0 then
    return nil, "too_small"
  end
  local arrowWidth = math.floor(arrows.width * scale)
  local arrowHeight = math.floor(arrows.height * scale)
  if arrowWidth < maxDigitWidth or arrowWidth < math.ceil(arrows.width * 0.5) then
    return nil, "too_small"
  end
  local columnsWidth = count * arrowWidth + (count - 1) * columnGap
  local bodyWidth = math.max(columnsWidth, actionsWidth) + pad * 2
  local stripHeight = arrowHeight * 2 + font.lineHeight + gap * 2
  local bodyHeight = pad * 2 + stripHeight + frame.actionGap + frame.actionHeight + 2 + frame.errorHeight
  if bodyWidth > available.width or bodyHeight > available.height then
    return nil, "too_small"
  end
  local body = rect(
    available.x + math.floor((available.width - bodyWidth) / 2),
    available.y + math.floor((available.height - bodyHeight) / 2),
    bodyWidth,
    bodyHeight
  )
  local columns = {}
  local startX = body.x + math.floor((body.width - columnsWidth) / 2)
  local stripY = body.y + pad
  for index = 1, count do
    local x = startX + (index - 1) * (arrowWidth + columnGap)
    local y = stripY
    columns[index] = {
      place = count - index,
      digit = projection.digits[index],
      upRect = rect(x, y, arrowWidth, arrowHeight),
      digitRect = rect(x, y + arrowHeight + gap, arrowWidth, font.lineHeight),
      downRect = rect(x, y + arrowHeight + gap + font.lineHeight + gap, arrowWidth, arrowHeight),
    }
  end
  local actionsY = stripY + stripHeight + frame.actionGap
  local actionsX = body.x + math.floor((body.width - actionsWidth) / 2)
  local confirmRect = rect(actionsX, actionsY, confirmWidth, frame.actionHeight)
  local backRect = rect(actionsX + confirmWidth + buttonsGap, actionsY, backWidth, frame.actionHeight)
  local errorRect = rect(body.x + pad, actionsY + frame.actionHeight + 2, body.width - pad * 2, frame.errorHeight)
  return {
    bodyRect = body,
    stripRect = rect(startX, stripY, columnsWidth, stripHeight),
    columns = columns,
    confirmRect = confirmRect,
    backRect = backRect,
    errorRect = errorRect,
  }
end

return NumberLayout
