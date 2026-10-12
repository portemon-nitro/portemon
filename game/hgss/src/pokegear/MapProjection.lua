-- Source region-map coordinate transforms shared by the gear map and the
-- standalone fly selector: world-matrix cells to pane points and back, the
-- normalized map context cell, once-applied marker placement, and the
-- pan/cursor clamps with source integer semantics. Forward and inverse are
-- exact inverses on selectable cell centers: the projection carries no
-- constant offset, so drawing and pointer selection agree. The source map
-- Y offset and the sprite-manager virtual-origin normalization apply once
-- in marker placement only, never in the shared cell transform. Pure
-- domain module: no love dependency.

---@class MapProjection
local MapProjection = {}

-- Source world surface edge in pixels; selectable cells tile this square.
MapProjection.WORLD_SIZE = 512

-- Map scale is a discrete cell size in pixels, never continuous zoom.
MapProjection.ZOOM_OUT = 8
MapProjection.ZOOM_IN = 16

-- World coordinate units per world cell on outdoor main-matrix maps.
local MATRIX_DIVISOR = 32

-- Source map Y offset, applied once in marker placement.
local MAP_OFFSET_Y = 2

-- Sprite-manager virtual-origin normalization, applied once per marker
-- component where constructor positions and the map sprite origin combine.
local VIRTUAL_ORIGIN_SHIFT = 48

-- Coarse progression masks over world-cell columns, grounded in the
-- header coordinate distribution: Johto headers end near column 27,
-- the Routes 26-28, Victory Road, and Indigo approaches table near
-- columns 28-31, and Kanto headers start at column 32.
local TIER_COLUMNS = {
  { maxX = 27, tier = 1 },
  { maxX = 31, tier = 2 },
  { maxX = 63, tier = 3 },
}

---@param value number
---@return integer truncated toward zero
local function trunc0(value)
  return value < 0 and math.ceil(value) or math.floor(value)
end

---@param cell unknown
---@return integer x, integer y
local function checkCell(cell)
  assert(type(cell) == "table", "map projection names its world cell")
  assert(type(cell.x) == "number" and cell.x % 1 == 0, "map projection columns are integral world cells")
  assert(type(cell.y) == "number" and cell.y % 1 == 0, "map projection rows are integral world cells")
  return cell.x, cell.y
end

---@param pan unknown
---@return number x, number y
local function checkPan(pan)
  assert(type(pan) == "table", "map projection carries its pan")
  assert(type(pan.x) == "number" and type(pan.y) == "number", "map pan carries pixel offsets")
  return pan.x, pan.y
end

---@param zoom unknown
---@return integer cells
local function checkZoom(zoom)
  assert(
    zoom == MapProjection.ZOOM_OUT or zoom == MapProjection.ZOOM_IN,
    "map scale is a discrete eight or sixteen-pixel cell projection"
  )
  return zoom --[[@as integer]]
end

---@param pane unknown
---@return { x: number, y: number, width: number, height: number } rect
local function checkPane(pane)
  assert(type(pane) == "table", "map projection carries its viewport rect")
  assert(
    type(pane.x) == "number"
      and type(pane.y) == "number"
      and type(pane.width) == "number"
      and type(pane.height) == "number",
    "map viewport rects carry origin and size"
  )
  return pane --[[@as { x: number, y: number, width: number, height: number }]]
end

-- Resolves the source-normalized context cell: outdoor main-matrix maps
-- divide world player coordinates by thirty-two, maps with explicit
-- header coordinates keep them verbatim, maps with both coordinates zero
-- fall back to the last exterior (or the special spawn), and special
-- locations resolve through their tabled coordinates. Never invents a
-- position: a zero-coordinate map without a fallback fails loudly.
---@param input { matrixX: number?, matrixY: number?, explicitX: integer?, explicitY: integer?, lastExterior: { x: number, y: number }?, specialSpawn: { x: number, y: number }?, special: string? }
---@return { x: integer, y: integer }
function MapProjection.contextCell(input)
  assert(type(input) == "table", "map context resolution requires its coordinate record")
  local explicitX, explicitY = input.explicitX, input.explicitY
  if input.special ~= nil then
    assert(type(input.special) == "string" and input.special ~= "", "special locations name their mode")
    assert(
      type(explicitX) == "number" and explicitX % 1 == 0 and type(explicitY) == "number" and explicitY % 1 == 0,
      "special locations resolve through their tabled coordinates"
    )
    return { x = explicitX, y = explicitY }
  end
  if explicitX ~= nil or explicitY ~= nil then
    assert(
      type(explicitX) == "number" and explicitX % 1 == 0 and type(explicitY) == "number" and explicitY % 1 == 0,
      "header coordinates arrive as integral pairs"
    )
    if explicitX == 0 and explicitY == 0 then
      local fallback = input.lastExterior or input.specialSpawn
      assert(type(fallback) == "table", "a zero-coordinate map needs its last exterior or special spawn")
      assert(
        type(fallback.x) == "number" and type(fallback.y) == "number",
        "the exterior fallback carries its world cell"
      )
      return { x = fallback.x, y = fallback.y }
    end
    return { x = explicitX, y = explicitY }
  end
  assert(
    type(input.matrixX) == "number" and type(input.matrixY) == "number",
    "outdoor maps divide world player coordinates"
  )
  return {
    x = math.floor(input.matrixX / MATRIX_DIVISOR),
    y = math.floor(input.matrixY / MATRIX_DIVISOR),
  }
end

-- Projects a world cell center to its pane point. Pure translation of the
-- shared cell transform, so hit testing inverts this exact mapping.
---@param cell { x: integer, y: integer }
---@param pan { x: number, y: number }
---@param zoom integer
---@param pane { x: number, y: number, width: number, height: number }
---@return { x: number, y: number }
function MapProjection.forward(cell, pan, zoom, pane)
  local cx, cy = checkCell(cell)
  local panX, panY = checkPan(pan)
  local step = checkZoom(zoom)
  local view = checkPane(pane)
  return {
    x = view.x + cx * step + panX,
    y = view.y + cy * step + panY,
  }
end

-- Maps a pane pointer back to its world cell with source truncation:
-- negative remainders truncate toward zero, never floor. Pointers whose
-- cell falls outside the world surface select nothing, so no hidden
-- region answers through an invisible hitbox.
---@param point { x: number, y: number }
---@param pan { x: number, y: number }
---@param zoom integer
---@param pane { x: number, y: number, width: number, height: number }
---@return { x: integer, y: integer }? the selected cell, or nil outside the surface
function MapProjection.inverse(point, pan, zoom, pane)
  assert(type(point) == "table", "map hit testing names its pointer")
  assert(type(point.x) == "number" and type(point.y) == "number", "map pointers carry coordinates")
  local panX, panY = checkPan(pan)
  local step = checkZoom(zoom)
  local view = checkPane(pane)
  local cx = trunc0((point.x - view.x - panX) / step)
  local cy = trunc0((point.y - view.y - panY) / step)
  local span = math.floor(MapProjection.WORLD_SIZE / step)
  if cx < 0 or cy < 0 or cx >= span or cy >= span then
    return nil
  end
  return { x = cx, y = cy }
end

-- Places one map marker sprite: the shared cell transform plus the source
-- map Y offset and the sprite-manager virtual-origin normalization,
-- each applied exactly once. Marker placement is the only path carrying
-- these constants; cell drawing and hit testing never see them.
---@param cell { x: integer, y: integer }
---@param pan { x: number, y: number }
---@param zoom integer
---@param pane { x: number, y: number, width: number, height: number }
---@return { x: number, y: number }
function MapProjection.markerPoint(cell, pan, zoom, pane)
  local point = MapProjection.forward(cell, pan, zoom, pane)
  return {
    x = point.x - VIRTUAL_ORIGIN_SHIFT,
    y = point.y + MAP_OFFSET_Y - VIRTUAL_ORIGIN_SHIFT,
  }
end

-- The progression tier gating one world-cell column: Johto columns first,
-- the Routes 26-28, Victory Road, and Indigo approaches next, then the
-- rest of Kanto. Tiers are progression facts over geography, not a census
-- of loaded maps.
---@param x integer
---@return integer tier
function MapProjection.tierOfColumn(x)
  assert(type(x) == "number" and x % 1 == 0 and x >= 0, "tier masks read integral world columns")
  for _, band in ipairs(TIER_COLUMNS) do
    if x <= band.maxX then
      return band.tier
    end
  end
  return 3
end

-- Clamps panning so the viewport never leaves the world surface.
---@param pan { x: number, y: number }
---@param zoom integer
---@param pane { x: number, y: number, width: number, height: number }
---@return { x: number, y: number }
function MapProjection.clampPan(pan, zoom, pane)
  local panX, panY = checkPan(pan)
  local step = checkZoom(zoom)
  local view = checkPane(pane)
  local scaled = MapProjection.WORLD_SIZE * step / MapProjection.ZOOM_OUT
  local maxX = math.max(0, scaled - view.width)
  local maxY = math.max(0, scaled - view.height)
  return {
    x = math.min(math.max(panX, -maxX), maxX),
    y = math.min(math.max(panY, -maxY), maxY),
  }
end

-- Clamps the selection cursor to selectable cells inside the unlocked
-- tiers: world bounds plus the progression mask, so a hidden region is
-- never selected through a stale pre-unlock cursor.
---@param cell { x: integer, y: integer }
---@param zoom integer
---@param unlockLevel integer
---@return { x: integer, y: integer }
function MapProjection.clampCursor(cell, zoom, unlockLevel)
  local cx, cy = checkCell(cell)
  local step = checkZoom(zoom)
  assert(
    type(unlockLevel) == "number" and unlockLevel % 1 == 0 and unlockLevel >= 1 and unlockLevel <= 3,
    "cursor clamps read the unlocked progression tier"
  )
  local span = math.floor(MapProjection.WORLD_SIZE / step)
  cx = math.min(math.max(cx, 0), span - 1)
  cy = math.min(math.max(cy, 0), span - 1)
  while cx > 0 and MapProjection.tierOfColumn(cx) > unlockLevel do
    cx = cx - 1
  end
  return { x = cx, y = cy }
end

return MapProjection
