-- Resolves the visible window of a framed, scrollable list surface.
-- The total extent always covers every logical row, but only the rows
-- intersecting the viewport materialize geometry records.

local ScrollViewport = require("libs.ui.src.ScrollViewport")

local ListSurface = {}

local PADDING = 8
ListSurface.PADDING = PADDING
local LABEL_CHARACTER_BUDGET = 24

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function validRect(value)
  return type(value) == "table"
    and finite(value.x)
    and finite(value.y)
    and finite(value.width)
    and finite(value.height)
    and value.width > 0
    and value.height > 0
end

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

---@param spec { bounds: { x:number, y:number, width:number, height:number }, rowCount: integer, rowHeight: number, gap: number, headerHeight?: number, hasTrailingValue?: boolean, trailingValueWidth?: number, minimumLabelWidth?: number, font: { lineHeight:number, measure: fun(text:string):number }, textScale?: number, rowAt: fun(index:integer): { label:string, value?:string } }
---@return number preferredWidth
---@return number trailingValueWidth
function ListSurface.preferredWidth(spec)
  assert(type(spec) == "table" and validRect(spec.bounds), "list measurement bounds must be finite and positive")
  assert(type(spec.rowCount) == "number" and spec.rowCount >= 0 and spec.rowCount % 1 == 0)
  assert(finite(spec.rowHeight) and spec.rowHeight > 0 and finite(spec.gap) and spec.gap >= 0)
  assert(type(spec.rowAt) == "function", "list width measurement needs a bounded row projection")
  local font = assert(spec.font, "list width measurement needs current font metrics")
  assert(type(font.measure) == "function" and finite(font.lineHeight) and font.lineHeight > 0)
  local textScale = spec.textScale or 1
  assert(finite(textScale) and textScale > 0)
  local headerHeight = spec.headerHeight or 0
  local availableHeight = math.max(0, spec.bounds.height - PADDING * 2 - headerHeight)
  local visibleRows = math.ceil(availableHeight / (spec.rowHeight + spec.gap))
  local sampleCount = math.min(spec.rowCount, visibleRows * 2)
  local labelBudget = font.measure(string.rep("W", LABEL_CHARACTER_BUDGET)) * textScale
  local trailingWidth = (spec.trailingValueWidth or 0) * textScale
  local measuredTrailingWidth = spec.trailingValueWidth or 0
  local widestLabel = math.min(spec.minimumLabelWidth or 0, labelBudget)
  for index = 1, sampleCount do
    local row = spec.rowAt(index)
    assert(type(row) == "table" and type(row.label) == "string", "measured rows need displayed labels")
    widestLabel = math.max(widestLabel, math.min(font.measure(row.label) * textScale, labelBudget))
    if spec.hasTrailingValue == true and row.value ~= nil then
      assert(type(row.value) == "string", "measured trailing values must be displayed text")
      measuredTrailingWidth = math.max(measuredTrailingWidth, font.measure(row.value))
      trailingWidth = measuredTrailingWidth * textScale
    end
  end
  local probeWidth = labelBudget + trailingWidth + 32
  local probeCount = math.max(1, sampleCount)
  local probeHeight = math.max(1, PADDING * 2 + headerHeight + probeCount * (spec.rowHeight + spec.gap))
  local geometry = ListSurface.resolve({
    bounds = { x = 0, y = 0, width = probeWidth, height = probeHeight },
    rowCount = probeCount,
    rowHeight = spec.rowHeight,
    gap = spec.gap,
    maxWidth = probeWidth,
    headerHeight = headerHeight,
    hasTrailingValue = spec.hasTrailingValue,
    trailingValueWidth = trailingWidth,
    font = { lineHeight = font.lineHeight, measure = font.measure },
  })
  local row = assert(geometry.rows[1], "the list geometry probe contains its first sample row")
  local leftGutter = row.labelRect.x - row.rect.x
  local rightGutter = row.rect.x + row.rect.width - row.labelRect.x - row.labelRect.width
  return math.ceil(widestLabel + leftGutter + rightGutter), trailingWidth
end

---@param spec { bounds: { x:number, y:number, width:number, height:number }, rowCount: integer, rowHeight: number, gap: number, maxWidth: number, headerHeight?: number, scrollOffset?: number, hasTrailingValue?: boolean, trailingValueWidth?: number, font?: { lineHeight:number, measure: fun(text:string):number } }
---@return { surface: { x:number, y:number, width:number, height:number }, content: { x:number, y:number, width:number, height:number }, header: { x:number, y:number, width:number, height:number }, contentHeight:number, firstIndex:integer, lastIndex:integer, rows: { index:integer, rect: { x:number, y:number, width:number, height:number }, hitRect: { x:number, y:number, width:number, height:number }, markerRect: { x:number, y:number, width:number, height:number }, markerRadius:number, labelRect: { x:number, y:number, width:number, height:number }, valueRect?: { x:number, y:number, width:number, height:number } }[] }
function ListSurface.resolve(spec)
  assert(type(spec) == "table" and validRect(spec.bounds), "list bounds must be finite and positive")
  assert(
    type(spec.rowCount) == "number" and spec.rowCount >= 0 and spec.rowCount == math.floor(spec.rowCount),
    "list row count must be a non-negative integer"
  )
  assert(finite(spec.rowHeight) and spec.rowHeight > 0, "list row height must be finite and positive")
  assert(finite(spec.gap) and spec.gap >= 0, "list row gap must be finite and non-negative")
  assert(finite(spec.maxWidth) and spec.maxWidth > 0, "list maximum width must be finite and positive")
  local headerHeight = spec.headerHeight or 0
  assert(finite(headerHeight) and headerHeight >= 0, "list header height must be finite and non-negative")
  local scrollOffset = spec.scrollOffset or 0
  assert(finite(scrollOffset) and scrollOffset >= 0, "list scroll offset must be finite and non-negative")
  local hasTrailingValue = spec.hasTrailingValue == true
  local font = spec.font
  if font ~= nil then
    assert(
      type(font) == "table" and finite(font.lineHeight) and font.lineHeight > 0,
      "list font line height must be finite and positive"
    )
    assert(type(font.measure) == "function", "list font must measure text")
  end
  local trailingValueWidth = spec.trailingValueWidth
  if trailingValueWidth ~= nil then
    assert(
      finite(trailingValueWidth) and trailingValueWidth >= 0,
      "list trailing value width must be finite and non-negative"
    )
  end

  local bounds = spec.bounds
  local width = math.min(bounds.width, spec.maxWidth)
  local surface = rect(bounds.x + (bounds.width - width) / 2, bounds.y, width, bounds.height)
  local padding = math.min(PADDING, width / 4, bounds.height / 4)
  local content = rect(surface.x + padding, surface.y + padding, width - padding * 2, bounds.height - padding * 2)
  local header = rect(content.x, content.y, content.width, headerHeight)
  local contentHeight = spec.rowCount == 0 and 0 or spec.rowCount * spec.rowHeight + (spec.rowCount - 1) * spec.gap
  local viewportHeight = math.max(0, content.height - headerHeight)
  scrollOffset = ScrollViewport.clamp(scrollOffset, contentHeight, viewportHeight)
  local firstIndex, lastIndex =
    ScrollViewport.visibleRange(scrollOffset, viewportHeight, spec.rowHeight, spec.gap, spec.rowCount)
  ---@type { index:integer, rect:{ x:number, y:number, width:number, height:number }, hitRect:{ x:number, y:number, width:number, height:number }, markerRect:{ x:number, y:number, width:number, height:number }, markerRadius:number, labelRect:{ x:number, y:number, width:number, height:number }, valueRect?:{ x:number, y:number, width:number, height:number } }[]
  local rows = {}
  for index = firstIndex, lastIndex do
    local row = rect(
      content.x,
      content.y + headerHeight + (index - 1) * (spec.rowHeight + spec.gap),
      content.width,
      spec.rowHeight
    )
    local horizontalInset = math.min(6, row.width / 4)
    local verticalInset = math.min(2, row.height / 4)
    local marker = rect(
      row.x + horizontalInset,
      row.y + verticalInset,
      row.width - horizontalInset * 2,
      row.height - verticalInset * 2
    )
    local textInset = math.min(4, marker.width / 4)
    local textLeft = marker.x + textInset
    local textRight = marker.x + marker.width - textInset
    local textHeight = math.min(font and font.lineHeight or row.height, row.height)
    local textY = row.y + (row.height - textHeight) / 2
    local valueRect
    if hasTrailingValue then
      local measuredValueWidth = trailingValueWidth
      if measuredValueWidth == nil and font ~= nil then
        measuredValueWidth = font.measure("OFF")
      end
      local slotWidth = math.min(measuredValueWidth or marker.width * 0.28, marker.width * 0.32)
      local gap = math.min(4, math.max(0, textRight - textLeft))
      slotWidth = math.min(slotWidth, math.max(0, textRight - textLeft - gap))
      valueRect = rect(textRight - slotWidth, textY, slotWidth, textHeight)
    end
    local labelRight = valueRect and math.max(textLeft, valueRect.x - math.min(4, math.max(0, valueRect.x - textLeft)))
      or textRight
    rows[#rows + 1] = {
      index = index,
      rect = row,
      hitRect = rect(row.x, row.y, row.width, row.height),
      markerRect = marker,
      markerRadius = math.min(2, marker.height / 2),
      labelRect = rect(textLeft, textY, math.max(0, labelRight - textLeft), textHeight),
      valueRect = valueRect,
    }
  end
  return {
    surface = surface,
    content = content,
    header = header,
    contentHeight = contentHeight,
    firstIndex = firstIndex,
    lastIndex = lastIndex,
    rows = rows,
  }
end

-- Outlines one resolved row marker. The caller owns the color after the call.
---@param graphics love.graphics
---@param markerRect { x:number, y:number, width:number, height:number }
---@param radius number
---@param color number[]
function ListSurface.drawMarker(graphics, markerRect, radius, color)
  local savedWidth = graphics.getLineWidth()
  local corner = math.min(radius, markerRect.height / 2)
  graphics.setColor(color[1], color[2], color[3], color[4])
  graphics.setLineWidth(2)
  graphics.rectangle(
    "line",
    markerRect.x + 1,
    markerRect.y + 1,
    markerRect.width - 2,
    markerRect.height - 2,
    corner,
    corner
  )
  graphics.setLineWidth(savedWidth)
end

return ListSurface
