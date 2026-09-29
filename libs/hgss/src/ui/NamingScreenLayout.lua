-- Canonical HGSS naming surface geometry using the source integer cursor and
-- touch layout. Pinned source: pret/pokeheartgold `src/naming_screen.c`
-- (`NamingScreen_UpdateCursorSpritePosition`, `sTouchHitboxDef`).

local LayoutGeometry = require("libs.ui.src.LayoutGeometry")

local NamingScreenLayout = {}
local WIDTH, HEIGHT = 256, 192
local ROWS, COLUMNS = 6, 13

---@class NamingScreenLayoutResult
---@field surface table<string, number>
---@field keyboard table<string, number>
---@field cells table<integer, table<integer, table<string, number>>>
---@field cursorCenters table<integer, table<integer, table<string, number>>>
---@field controls table<string, table<string, number>>
---@field nameSlots table<string, number>
---@field subject table<string, number>
---@field placement nil
---@field scale nil

local function rect(x, y, width, height)
  assert(width > 0 and height > 0)
  return { x = x, y = y, width = width, height = height }
end

local HOME_WIDTHS = {
  upper = 32,
  lower = 32,
  symbols = 32,
  back = 33,
  ok = 33,
}
-- Fixed touch templates around the manifest anchors: the hit rectangle
-- starts one pixel left and eight pixels above the drawn control anchor,
-- and the glyph hit rectangle starts two pixels right and three pixels
-- above the keyboard stepping origin, overlapping its neighbor by one
-- pixel on each stepping axis. Only the absolute anchors, origins, and
-- steps come from the manifest; these offsets reproduce the source layout.
local CONTROL_DX, CONTROL_DY, CONTROL_HEIGHT = -1, -8, 23
local CELL_DX, CELL_DY = 2, -3

local HOME_IDS = { "upper", "lower", "symbols", "back", "ok" }

local CONTROL_COLUMNS = {
  upper = { 1, 2 },
  lower = { 3, 4 },
  symbols = { 5, 6 },
  back = { 9, 10, 11 },
  ok = { 12, 13 },
}

local function controlIdAt(column)
  for id, span in pairs(CONTROL_COLUMNS) do
    for _, member in ipairs(span) do
      if member == column then
        return id
      end
    end
  end
  return nil
end

---@param viewport LayoutGeometry.Rect
---@param naming table<string, unknown> the validated namingScreen manifest section
---@return NamingScreenLayoutResult
function NamingScreenLayout.compute(viewport, naming)
  assert(type(viewport) == "table", "naming layout viewport is required")
  assert(
    type(viewport.width) == "number" and type(viewport.height) == "number",
    "naming layout viewport dimensions are required"
  )
  assert(viewport.width >= WIDTH and viewport.height >= HEIGHT, "naming surface cannot fit in the host viewport")
  assert(type(naming) == "table", "naming layout requires the namingScreen manifest section")
  local controls = assert(naming.controls, "naming layout requires the manifest controls")
  local cursor = assert(naming.cursor, "naming layout requires the manifest cursor")
  local home = assert(cursor.home, "naming layout requires the manifest home cursors")
  local keyboardCursor = assert(cursor.keyboard, "naming layout requires the manifest keyboard cursor")
  local origin = assert(keyboardCursor.origin, "naming layout requires the keyboard stepping origin")
  local stepX = assert(keyboardCursor.stepX, "naming layout requires the keyboard column step")
  local stepY = assert(keyboardCursor.stepY, "naming layout requires the keyboard row step")
  assert(type(origin.x) == "number" and type(origin.y) == "number", "naming layout requires a numeric keyboard origin")
  assert(type(stepX) == "number" and type(stepY) == "number", "naming layout requires numeric keyboard steps")
  local homeControls = {}
  local homeCenters = {}
  for _, id in ipairs(HOME_IDS) do
    local anchor = assert(controls[id], "naming layout requires the " .. id .. " control").anchor
    assert(
      type(anchor) == "table" and type(anchor.x) == "number" and type(anchor.y) == "number",
      "naming layout requires a numeric " .. id .. " control anchor"
    )
    homeControls[id] = rect(anchor.x + CONTROL_DX, anchor.y + CONTROL_DY, HOME_WIDTHS[id], CONTROL_HEIGHT)
    local center = assert(home[id], "naming layout requires the " .. id .. " home cursor").anchor
    assert(
      type(center) == "table" and type(center.x) == "number" and type(center.y) == "number",
      "naming layout requires a numeric " .. id .. " home cursor anchor"
    )
    homeCenters[id] = { x = center.x, y = center.y }
  end
  local surface = rect(
    math.floor(viewport.x + (viewport.width - WIDTH) / 2),
    math.floor(viewport.y + (viewport.height - HEIGHT) / 2),
    WIDTH,
    HEIGHT
  )
  local cells = {}
  local cursorCenters = {}
  for row = 1, ROWS do
    cells[row] = {}
    cursorCenters[row] = {}
    for column = 1, COLUMNS do
      if row == 1 then
        local id = controlIdAt(column)
        if id == nil then
          -- The source home row leaves a blank gap between Symbols and
          -- Back; those columns own no hit region and no cursor center.
          cells[row][column] = { x = 121, y = 60, width = 0, height = 0 }
          cursorCenters[row][column] = { x = 121, y = 68 }
        else
          cells[row][column] =
            rect(homeControls[id].x, homeControls[id].y, homeControls[id].width, homeControls[id].height)
          cursorCenters[row][column] = { x = homeCenters[id].x, y = homeCenters[id].y }
        end
      else
        cells[row][column] =
          rect(origin.x + CELL_DX + (column - 1) * stepX, origin.y + CELL_DY + (row - 2) * stepY, stepX + 1, stepY + 1)
        cursorCenters[row][column] = { x = origin.x + (column - 1) * stepX, y = origin.y + (row - 2) * stepY }
      end
    end
  end
  local hitControls = {}
  for id, region in pairs(homeControls) do
    hitControls[id] = rect(region.x, region.y, region.width, region.height)
  end
  return {
    surface = surface,
    keyboard = rect(8, 58, 240, 106),
    cells = cells,
    cursorCenters = cursorCenters,
    controls = hitControls,
    -- The entered-name and subject display regions are fixed areas of the
    -- static base artwork, so they stay constant while anchors move: the
    -- manifest carries no region record for them, and no consumer reads
    -- these values for hit testing or drawing.
    nameSlots = rect(32, 22, 192, 24),
    subject = rect(8, 8, 48, 42),
  }
end

function NamingScreenLayout.contains(region, x, y)
  if region == nil or region.width <= 0 or region.height <= 0 then
    return false
  end
  return LayoutGeometry.containsPoint(region, x, y)
end

return NamingScreenLayout
