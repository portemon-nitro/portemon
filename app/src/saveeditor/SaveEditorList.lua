-- Resolves the bounded geometry of a Save Editor list surface.

local SaveEditorList = {}

local PADDING = 8

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

---@param spec { bounds: { x:number, y:number, width:number, height:number }, rowCount: integer, rowHeight: number, gap: number, maxWidth: number }
---@return { surface: { x:number, y:number, width:number, height:number }, content: { x:number, y:number, width:number, height:number }, contentHeight:number, rows: { index:integer, rect: { x:number, y:number, width:number, height:number }, hitRect: { x:number, y:number, width:number, height:number } }[] }
function SaveEditorList.resolve(spec)
  assert(type(spec) == "table" and validRect(spec.bounds), "list bounds must be finite and positive")
  assert(
    type(spec.rowCount) == "number" and spec.rowCount >= 0 and spec.rowCount == math.floor(spec.rowCount),
    "list row count must be a non-negative integer"
  )
  assert(finite(spec.rowHeight) and spec.rowHeight > 0, "list row height must be finite and positive")
  assert(finite(spec.gap) and spec.gap >= 0, "list row gap must be finite and non-negative")
  assert(finite(spec.maxWidth) and spec.maxWidth > 0, "list maximum width must be finite and positive")

  local bounds = spec.bounds
  local width = math.min(bounds.width, spec.maxWidth)
  local surface = rect(bounds.x + (bounds.width - width) / 2, bounds.y, width, bounds.height)
  local padding = math.min(PADDING, width / 4, bounds.height / 4)
  local content = rect(surface.x + padding, surface.y + padding, width - padding * 2, bounds.height - padding * 2)
  local rows = {}
  for index = 1, spec.rowCount do
    local row = rect(content.x, content.y + (index - 1) * (spec.rowHeight + spec.gap), content.width, spec.rowHeight)
    rows[index] = { index = index, rect = row, hitRect = rect(row.x, row.y, row.width, row.height) }
  end
  return {
    surface = surface,
    content = content,
    contentHeight = spec.rowCount == 0 and 0 or spec.rowCount * spec.rowHeight + (spec.rowCount - 1) * spec.gap,
    rows = rows,
  }
end

return SaveEditorList
