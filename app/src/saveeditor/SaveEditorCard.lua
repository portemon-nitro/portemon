-- Resolves the six-cell icon-left/text-right card grid used by Save Editor screens.

local SaveEditorCard = {}

local PADDING = 8
local ICON_SIZE = 32

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

---@param spec { bounds: { x:number, y:number, width:number, height:number }, count: integer, columns: integer, rows: integer, gap: number, maxWidth: number, maxCellWidth?: number, maxCellHeight?: number }
---@return { index:integer, rect: { x:number, y:number, width:number, height:number }, hitRect: { x:number, y:number, width:number, height:number }, iconRect: { x:number, y:number, width:number, height:number }, textRect: { x:number, y:number, width:number, height:number } }[]
function SaveEditorCard.resolveGrid(spec)
  assert(type(spec) == "table" and validRect(spec.bounds), "card grid bounds must be finite and positive")
  assert(
    type(spec.count) == "number" and spec.count >= 0 and spec.count <= 6 and spec.count == math.floor(spec.count),
    "card count must be an integer from zero through six"
  )
  assert(spec.columns == 2 and spec.rows == 3, "card grid uses two columns and three rows")
  assert(finite(spec.gap) and spec.gap >= 0, "card gap must be finite and non-negative")
  assert(finite(spec.maxWidth) and spec.maxWidth > 0, "card maximum width must be finite and positive")
  local maxCellWidth = spec.maxCellWidth
  assert(
    maxCellWidth == nil or (finite(maxCellWidth) and maxCellWidth > 0),
    "card maximum cell width must be finite and positive"
  )
  local maxCellHeight = spec.maxCellHeight
  assert(
    maxCellHeight == nil or (finite(maxCellHeight) and maxCellHeight > 0),
    "card maximum cell height must be finite and positive"
  )

  local bounds = spec.bounds
  local width = math.min(bounds.width, spec.maxWidth)
  local cellWidth = (width - spec.gap) / 2
  local cellHeight = (bounds.height - spec.gap * 2) / 3
  if maxCellWidth ~= nil then
    cellWidth = math.min(cellWidth, maxCellWidth)
  end
  if maxCellHeight ~= nil then
    cellHeight = math.min(cellHeight, maxCellHeight)
  end
  assert(cellWidth > 0 and cellHeight > 0, "card grid cells must have positive bounds")
  local gridWidth = cellWidth * 2 + spec.gap
  local gridHeight = cellHeight * 3 + spec.gap * 2
  local left = bounds.x + (bounds.width - gridWidth) / 2
  local top = bounds.y + (bounds.height - gridHeight) / 2

  local cards = {}
  for index = 1, spec.count do
    local column = (index - 1) % 2
    local row = math.floor((index - 1) / 2)
    local card =
      rect(left + column * (cellWidth + spec.gap), top + row * (cellHeight + spec.gap), cellWidth, cellHeight)
    local inset = math.min(PADDING, card.width / 3, card.height / 3)
    local iconSize = math.min(ICON_SIZE, card.height - inset * 2, card.width / 3)
    local icon = rect(card.x + inset, card.y + (card.height - iconSize) / 2, iconSize, iconSize)
    local textX = icon.x + icon.width + inset
    local text = rect(
      textX,
      card.y + inset,
      math.max(1, card.x + card.width - inset - textX),
      math.max(1, card.height - inset * 2)
    )
    cards[index] = {
      index = index,
      rect = card,
      hitRect = rect(card.x, card.y, card.width, card.height),
      iconRect = icon,
      textRect = text,
    }
  end
  return cards
end

return SaveEditorCard
