-- MenuLayout deterministically resolves field-menu geometry. Menus are framed
-- ListSurface lists in the 256x192 reference space, anchored to the top-right
-- of the central 4:3 region of the selected surface. It is deliberately pure:
-- text measurement, rendering, and input dispatch remain outside this module.

local ListSurface = require("libs.ui.src.ListSurface")
local NativeDisplay = require("libs.ui.src.NativeDisplay")
local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local ScrollViewport = require("libs.ui.src.ScrollViewport")

---@class MenuLayout
local MenuLayout = {}

local ROW_HEIGHT = 16
-- One entry keeps three tile rows, the pitch of the source touchscreen list
-- menu (touchscreen_list_menu.c). The band below the glyph cell is what lets
-- a row's focus ring frame its label instead of closing over the ink.
local ROW_EXTENT = ROW_HEIGHT + 8
local TILE = 8
local EDGE_PADDING = 4
local MIN_SURFACE_WIDTH = 64

local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function assertRectangle(rectangle, name)
  assert(type(rectangle) == "table", name .. " must be a rectangle")
  assert(isFiniteNumber(rectangle.x), name .. ".x must be finite")
  assert(isFiniteNumber(rectangle.y), name .. ".y must be finite")
  assert(isFiniteNumber(rectangle.width) and rectangle.width > 0, name .. ".width must be positive and finite")
  assert(isFiniteNumber(rectangle.height) and rectangle.height > 0, name .. ".height must be positive and finite")
end

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

local function alignUp(value)
  return math.ceil(value / TILE) * TILE
end

local function alignDown(value)
  return math.floor(value / TILE) * TILE
end

local function assertItems(menu)
  assert(type(menu) == "table", "menu layout requires a menu")
  assert(type(menu.items) == "table" and #menu.items > 0, "menu layout requires at least one item")
  for index = 1, #menu.items do
    assert(type(menu.items[index]) == "table", "menu item must be a table")
  end
  local selectedIndex = menu.selectedIndex or 0
  assert(type(selectedIndex) == "number" and selectedIndex % 1 == 0, "menu selected index must be an integer")
  assert(selectedIndex >= 0 and selectedIndex < #menu.items, "menu selected index is out of range")
  assert(menu.cancellable == nil or type(menu.cancellable) == "boolean", "menu cancellable must be a boolean")
  return selectedIndex
end

-- The auxiliary surface carries the list menu on dual displays; otherwise the
-- first surface does. Source multichoice windows belong to the gameplay
-- display instead, so they select the first non-auxiliary surface.
local function selectSurface(topology, foreground)
  assert(
    type(topology) == "table" and type(topology.surfaces) == "table" and #topology.surfaces > 0,
    "menu layout requires a ScreenTopology"
  )
  local selected = topology.surfaces[1]
  for _, surface in ipairs(topology.surfaces) do
    local matches = foreground and surface.role ~= "auxiliary" or not foreground and surface.role == "auxiliary"
    if matches then
      selected = surface
      break
    end
  end
  assertRectangle(selected.safeRect, "selected surface safeRect")
  return selected
end

local function itemText(item)
  if type(item.label) == "string" then
    return item.label
  end
  if type(item.text) == "string" then
    return item.text
  end
  if type(item.text) == "table" and type(item.text.text) == "string" then
    return item.text.text
  end
  return ""
end

-- Places the 256x192 reference space at the top-right of the host region: the
-- exact fit on an auxiliary surface, or the field scale (never above the
-- integer fit) in the caller's 4:3 bounds.
local function placement(surface, bounds, preferredScale)
  local region = surface.safeRect
  local fit = math.min(region.width / NativeDisplay.WIDTH, region.height / NativeDisplay.HEIGHT)
  local scale = fit
  if surface.role ~= "auxiliary" then
    region = bounds or region
    assertRectangle(region, "menu bounds")
    local preferred = preferredScale or 1
    assert(preferred % 1 == 0 and preferred > 0, "menu preferred scale must be a positive integer")
    fit = math.min(region.width / NativeDisplay.WIDTH, region.height / NativeDisplay.HEIGHT)
    scale = fit >= 1 and math.min(preferred, math.floor(fit)) or fit
  end
  assert(scale > 0, "menu region is too small")
  local width, height = NativeDisplay.WIDTH * scale, NativeDisplay.HEIGHT * scale
  local origin = { x = region.x + region.width - width, y = region.y }
  return {
    frame = rect(origin.x, origin.y, width, height),
    origin = origin,
    scale = scale,
    clipRect = region,
  }
end

local DIRECTIONS = { up = true, down = true, left = true, right = true }

-- ScriptMenu_ShowMultichoice gives a source foreground window its native tile
-- position, one measured-and-tile-rounded width and two source tile rows per
-- item; its rows therefore span the window instead of sitting inside the
-- padded auxiliary list surface. The window frame draws on those edges.
local MULTICHOICE_ROW_HEIGHT = TILE * 2

-- ScriptMenu_GetItemsWidth returns the widest measured label plus 12 pixels.
local MULTICHOICE_WIDTH_PADDING = 12

-- The foreground family's native geometry: the source tile position a script
-- created the window with, plus the anchor selector it may set before the
-- window is executed.
---@param menu table<string, unknown>
---@return { tileX: number, tileY: number, anchorRight: boolean }
local function multichoiceGeometry(menu)
  local tileX, tileY = menu.tileX, menu.tileY
  assert(
    type(tileX) == "number" and tileX % 1 == 0 and tileX >= 0 and tileX <= 255,
    "multichoice window column must be a source tile coordinate"
  )
  assert(
    type(tileY) == "number" and tileY % 1 == 0 and tileY >= 0 and tileY <= 255,
    "multichoice window row must be a source tile coordinate"
  )
  local anchorRight = menu.anchorRight
  assert(anchorRight == nil or type(anchorRight) == "boolean", "multichoice anchor must be a boolean")
  return { tileX = tileX, tileY = tileY, anchorRight = anchorRight == true }
end

-- Places one source multichoice window in the 256x192 reference space. The
-- right anchor moves the left edge: the stored tile column loses exactly the
-- measured window width, which keeps the right edge on the source column.
---@param spec MenuLayout.Spec
---@param surface ScreenTopology.Surface
---@param selectedIndex integer
---@param items table[]
---@param itemTexts table<integer, string>
---@return table<string, unknown>
local function resolveMultichoice(spec, surface, selectedIndex, items, itemTexts)
  local geometry = multichoiceGeometry(spec.menu)
  local itemCount = #items
  local widestLabel = 0
  for itemIndex = 0, itemCount - 1 do
    widestLabel = math.max(widestLabel, spec.measureText(itemTexts[itemIndex]))
  end
  -- The source rounds that sum UP to whole tiles ((width >> 3) + 1 when it is
  -- not tile-aligned), draws the window on that tile count and lets it overflow
  -- the display: an over-wide window is a layout fault, never a clamp.
  local width = alignUp(widestLabel + MULTICHOICE_WIDTH_PADDING)
  local height = itemCount * MULTICHOICE_ROW_HEIGHT
  local x = geometry.tileX * TILE
  if geometry.anchorRight then
    x = x - width
  end
  local y = geometry.tileY * TILE
  assert(
    x >= 0 and x + width <= NativeDisplay.WIDTH and y + height <= NativeDisplay.HEIGHT,
    "multichoice window does not fit the 256x192 reference display"
  )
  local window = rect(x, y, width, height)
  local rows = {}
  local itemRects = {}
  for itemIndex = 0, itemCount - 1 do
    local rowY = y + itemIndex * MULTICHOICE_ROW_HEIGHT
    itemRects[itemIndex] = rect(x, rowY, width, MULTICHOICE_ROW_HEIGHT)
    rows[itemIndex + 1] = {
      itemIndex = itemIndex,
      rect = itemRects[itemIndex],
      marker = rect(x + TILE / 2, rowY + 2, width - TILE, MULTICHOICE_ROW_HEIGHT - 4),
      markerRadius = 2,
      -- The source printer starts the label one glyph cell (one tile) in and
      -- the window's measured width already carries its trailing margin, so
      -- the remaining window is the label row.
      labelRect = rect(x + TILE, rowY, width - TILE, MULTICHOICE_ROW_HEIGHT),
    }
  end
  return {
    surface = surface,
    placement = placement(surface, spec.bounds, spec.preferredScale),
    listSurface = { surface = window, content = window, rows = rows },
    rows = rows,
    itemCount = itemCount,
    itemRects = itemRects,
    itemTexts = itemTexts,
    scrollViewport = window,
    -- Source multichoice cancellation is the script's own B result; the
    -- touchscreen list family keeps its cancel target.
    cancelRect = nil,
    selectedIndex = selectedIndex,
    scrollOffset = 0,
    maxScrollOffset = 0,
  }
end

-- Finds the item most aligned with the current row or column in a cardinal
-- direction. Cross-axis alignment wins over distance, preserving grid-like
-- navigation when physical dimensions change.
---@param layout { itemCount: integer, itemRects: ScreenTopology.Rectangle[] }
---@param itemIndex integer
---@param direction "up"|"down"|"left"|"right"
---@return integer?
function MenuLayout.adjacentItem(layout, itemIndex, direction)
  assert(type(layout) == "table", "menu layout is required")
  assert(
    type(layout.itemCount) == "number" and layout.itemCount % 1 == 0 and layout.itemCount > 0,
    "menu layout item count is invalid"
  )
  assert(type(layout.itemRects) == "table", "menu layout item rectangles are required")
  assert(
    type(itemIndex) == "number" and itemIndex % 1 == 0 and itemIndex >= 0 and itemIndex < layout.itemCount,
    "menu item index is out of range"
  )
  assert(DIRECTIONS[direction], "menu navigation direction is invalid")

  local current = assert(layout.itemRects[itemIndex], "menu layout item rectangle is missing")
  assertRectangle(current, "menu layout item rectangle")
  local currentX = current.x + current.width / 2
  local currentY = current.y + current.height / 2
  local adjacentIndex
  local nearestOffset
  local nearestDistance
  for candidateIndex = 0, layout.itemCount - 1 do
    if candidateIndex ~= itemIndex then
      local candidate = assert(layout.itemRects[candidateIndex], "menu layout item rectangle is missing")
      assertRectangle(candidate, "menu layout item rectangle")
      local dx = candidate.x + candidate.width / 2 - currentX
      local dy = candidate.y + candidate.height / 2 - currentY
      local distance, offset
      if direction == "up" and dy < 0 then
        distance, offset = -dy, math.abs(dx)
      elseif direction == "down" and dy > 0 then
        distance, offset = dy, math.abs(dx)
      elseif direction == "left" and dx < 0 then
        distance, offset = -dx, math.abs(dy)
      elseif direction == "right" and dx > 0 then
        distance, offset = dx, math.abs(dy)
      end
      if
        distance
        and (
          nearestDistance == nil
          or offset < nearestOffset
          or (offset == nearestOffset and distance < nearestDistance)
        )
      then
        adjacentIndex = candidateIndex
        nearestOffset = offset
        nearestDistance = distance
      end
    end
  end
  return adjacentIndex
end

---@class MenuLayout.Spec
---@field topology ScreenTopology
---@field menu { items: table[], kind?: "multichoice", tileX?: integer, tileY?: integer, anchorRight?: boolean, selectedIndex?: integer, cancellable?: boolean }
---@field bounds? ScreenTopology.Rectangle central 4:3 host region for world surfaces; defaults to the surface safe rect
---@field preferredScale? integer field pixel scale for world surfaces
---@field measureText fun(text: string): number

-- Resolves immutable menu geometry in the 256x192 reference space. itemRects
-- use zero-based menu indexes and contain every item; rows outside
-- scrollViewport are clipped by the renderer, while the selected row is
-- always brought into view. `placement` maps reference space into the host.

---@param spec MenuLayout.Spec
---@return table<string, unknown>
function MenuLayout.resolve(spec)
  assert(type(spec) == "table", "menu layout requires a specification")
  local selectedIndex = assertItems(spec.menu)
  ---@cast selectedIndex integer
  assert(type(spec.measureText) == "function", "menu text measurement must be a function")
  local multichoice = spec.menu.kind == "multichoice"
  local surface = selectSurface(spec.topology, multichoice)
  local items = spec.menu.items
  local itemTexts = {}
  for luaIndex = 1, #items do
    itemTexts[luaIndex - 1] = itemText(items[luaIndex])
  end
  if multichoice then
    return resolveMultichoice(spec, surface, selectedIndex, items, itemTexts)
  end
  local resolvedPlacement = placement(surface, spec.bounds, spec.preferredScale)

  local cancellable = spec.menu.cancellable == true and surface.touch == true
  local insets = ApplicationLayout.applicationFrameInsets()
  local marginX = insets.right + EDGE_PADDING
  local marginY = insets.top + EDGE_PADDING
  -- The cancel target is a trailing list row inside the same frame, so it
  -- reserves one more entry instead of a detached touch box below the list.
  local cancelRows = cancellable and 1 or 0
  local padding = ListSurface.PADDING
  local maxWidth = alignDown(NativeDisplay.WIDTH - marginX - insets.left - EDGE_PADDING)
  local availableHeight = NativeDisplay.HEIGHT - marginY * 2
  local font = { lineHeight = ROW_HEIGHT, measure = spec.measureText }
  local function labelAt(index)
    return { label = itemTexts[index - 1] }
  end

  -- The measured width is one entry row, so the padded surface adds its own
  -- insets back before it becomes the framed box.
  local preferredWidth = ListSurface.preferredWidth({
    bounds = rect(0, 0, maxWidth - padding * 2, availableHeight),
    rowCount = #items,
    rowHeight = ROW_EXTENT,
    gap = 0,
    font = font,
    rowAt = labelAt,
  })
  local width = math.min(maxWidth, math.max(MIN_SURFACE_WIDTH, alignUp(preferredWidth + padding * 2)))
  local naturalHeight = alignUp((#items + cancelRows) * ROW_EXTENT + padding * 2)
  local height = alignDown(math.min(naturalHeight, availableHeight))

  local x = NativeDisplay.WIDTH - insets.right - EDGE_PADDING - width
  local itemAreaHeight = height - cancelRows * ROW_EXTENT
  local viewportHeight = itemAreaHeight - padding * 2
  local contentHeight = #items * ROW_EXTENT
  local maxScrollOffset = math.max(0, contentHeight - viewportHeight)
  local scrollOffset =
    ScrollViewport.clamp(selectedIndex * ROW_EXTENT - (viewportHeight - ROW_EXTENT), contentHeight, viewportHeight)
  local list = ListSurface.resolve({
    bounds = rect(x, marginY, width, itemAreaHeight),
    rowCount = #items,
    rowHeight = ROW_EXTENT,
    gap = 0,
    maxWidth = width,
    scrollOffset = scrollOffset,
    font = font,
  })

  local itemRects = {}
  for itemIndex = 0, #items - 1 do
    itemRects[itemIndex] =
      rect(list.content.x, list.content.y + itemIndex * ROW_EXTENT - scrollOffset, list.content.width, ROW_EXTENT)
  end
  local rows = {}
  for position, row in ipairs(list.rows) do
    rows[position] = {
      itemIndex = row.index - 1,
      rect = itemRects[row.index - 1],
      marker = rect(row.markerRect.x, row.markerRect.y - scrollOffset, row.markerRect.width, row.markerRect.height),
      markerRadius = row.markerRadius,
      labelRect = rect(row.labelRect.x, row.labelRect.y - scrollOffset, row.labelRect.width, row.labelRect.height),
    }
  end
  local frameBox = rect(list.surface.x, list.surface.y, list.surface.width, itemAreaHeight + cancelRows * ROW_EXTENT)
  local cancelRect, cancelLabelRect
  if cancellable then
    -- The cancel row reuses the shared row insets, so it reads as one more
    -- entry of the same list rather than a separate control.
    local sample = assert(rows[1], "a cancellable menu materializes its first row")
    cancelRect = rect(list.content.x, list.content.y + list.content.height, list.content.width, ROW_EXTENT)
    local markerInsetX = sample.marker.x - sample.rect.x
    local markerInsetY = sample.marker.y - sample.rect.y
    local labelInsetX = sample.labelRect.x - sample.marker.x
    local labelInsetY = sample.labelRect.y - sample.marker.y
    local cancelMarker = rect(
      cancelRect.x + markerInsetX,
      cancelRect.y + markerInsetY,
      cancelRect.width - markerInsetX * 2,
      cancelRect.height - markerInsetY * 2
    )
    cancelLabelRect = rect(
      cancelMarker.x + labelInsetX,
      cancelMarker.y + labelInsetY,
      cancelMarker.width - labelInsetX * 2,
      sample.labelRect.height
    )
  end
  return {
    surface = surface,
    placement = resolvedPlacement,
    listSurface = list,
    frameBox = frameBox,
    rows = rows,
    itemCount = #items,
    itemRects = itemRects,
    itemTexts = itemTexts,
    scrollViewport = list.content,
    cancelRect = cancelRect,
    cancelLabelRect = cancelLabelRect,
    selectedIndex = selectedIndex,
    scrollOffset = scrollOffset,
    maxScrollOffset = maxScrollOffset,
  }
end

return MenuLayout
