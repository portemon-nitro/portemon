-- The region map's world view model: the selected cell, the visible cell
-- window, the hardware-style scroll and affine zoom of the world layer, the
-- cursor sprite position, and the tick-driven cell-move, zoom, and touch-drag
-- animations. Follows the Pokegear map application of pret/pokeheartgold
-- (src/application/pokegear/map: pokegear_map.c, overlay_101_021E9270.c and
-- overlay_101_021EB568.c) for both the gear card and the Fly/Town map, which
-- differ only in their screen frame. Coordinates are map cells (eight world
-- pixels) unless a name says pixels. Pure module: no love, no I/O.

---@class MapWorld.Frame
---@field centerX integer screen pixel of the window's left edge
---@field centerY integer screen pixel of the window's top edge
---@field xOffset integer layer scroll bias

---@class MapWorld
---@field kind string "gear" or "fly"
---@field frame MapWorld.Frame
---@field minX integer
---@field minY integer
---@field maxX integer
---@field maxY integer
---@field zoomed boolean
---@field ratio number affine zoom, 1.0 to 2.0
---@field cell { x: integer, y: integer } the selected cell (source playerX/playerY)
---@field player { x: integer, y: integer } the player's cell (source matrixX/matrixY)
---@field left integer window bounds, inclusive
---@field right integer
---@field top integer
---@field bottom integer
---@field scrollX number layer scroll in screen pixels
---@field scrollY number
---@field affineX number zoom pivot in layer pixels
---@field affineY number
---@field cursorX number cursor sprite centre in screen pixels
---@field cursorY number
local MapWorld = {}
MapWorld.__index = MapWorld

MapWorld.FRAME = {
  gear = { centerX = 8, centerY = 8, xOffset = 0 },
  fly = { centerX = 32, centerY = 8, xOffset = -24 },
}

-- Largest selectable window column per unlock level; the window and the
-- selection never go below one or past row seventeen.
local MAX_X = { 26, 29, 45 }
local MIN_X, MIN_Y, MAX_Y = 1, 1, 17

-- Keyboard cell moves: one cell per two ticks, see stepMove.
local MOVE_TICKS = 2
local ZOOM_TICKS = 4

-- Windows exclude their outer column and row from touch selection and
-- limit where the cursor sprite can sit before the world scrolls.
local TOUCH_LIMITS = {
  [false] = { yMin = 1, yMax = 16, xMin = 1, xMax = 22 },
  [true] = { yMin = 1, yMax = 7, xMin = 1, xMax = 10 },
}

---@param a number
---@param b number
---@return integer quotient truncated toward zero, like C integer division
local function tdiv(a, b)
  local q = a / b
  if q >= 0 then
    return math.floor(q)
  end
  return -math.floor(-q)
end

---@param a number
---@param b number
---@return number remainder with the sign of a, like C
local function tmod(a, b)
  return a - tdiv(a, b) * b
end

-- Computes the visible window and the scroll target around a selected cell
-- (source ov101_021E9530). `xIn`/`yIn` are the cursor sprite's screen position,
-- read only by the zoomed branch. The tween step divides by the live cursor
-- speed, which is zero at creation and then unused.
---@param zoomed boolean
---@param x0 integer
---@param y0 integer
---@param xIn number
---@param yIn number
function MapWorld:_computeWindow(zoomed, x0, y0, xIn, yIn)
  local grid, top, bottom, left, right, xCenter, yCenter
  if zoomed then
    grid = 16
    local xi = tdiv(xIn - self.frame.centerX, 16)
    local yi = tdiv(yIn - self.frame.centerY, 16)
    xCenter = 5 - xi
    yCenter = 4 - yi
    top = y0 - yi - yCenter
    bottom = y0 + (7 - yi) - yCenter
    left = x0 - xi - xCenter
    right = x0 + (11 - xi) - xCenter
  else
    grid = 8
    local xi = x0 - (tdiv(self.scrollX, 8) + 1)
    local yi = y0 - (tdiv(self.scrollY, 8) + 1)
    xCenter = 11 - xi
    yCenter = 8 - yi
    top = y0 - yi - yCenter
    bottom = y0 + (16 - yi) - yCenter
    left = x0 - xi - xCenter
    right = x0 + (23 - xi) - xCenter
  end
  if top < self.minY then
    local offset = top - self.minY
    yCenter = yCenter + offset
    top = top - offset
    bottom = bottom - offset
  elseif bottom > self.maxY then
    local offset = bottom - self.maxY
    yCenter = yCenter + offset
    bottom = bottom - offset
    top = top - offset
  end
  if left < self.minX then
    local offset = left - self.minX
    xCenter = xCenter + offset
    left = left - offset
    right = right - offset
  elseif right > self.maxX then
    local offset = right - self.maxX
    xCenter = xCenter + offset
    right = right - offset
    left = left - offset
  end
  self.top, self.bottom, self.left, self.right = top, bottom, left, right
  local dx, dy = -(xCenter * grid), -(yCenter * grid)
  self._destX, self._destY = self.scrollX + dx, self.scrollY + dy
  self._tweenX, self._tweenY = self.scrollX, self.scrollY
  if self._speed > 0 then
    self._stepX, self._stepY = dx / self._speed, dy / self._speed
  else
    self._stepX, self._stepY = 0, 0
  end
end

-- The zoom pivot in layer pixels for the zoom being entered or left, from the
-- cursor sprite's screen position before the toggle (source IN:645-682).
---@param zoomedAfter boolean
---@param curX number
---@param curY number
---@return number affineX
---@return number affineY
function MapWorld:_anchor(zoomedAfter, curX, curY)
  local frame = self.frame
  if zoomedAfter then
    local parX = tmod(tdiv(curX - frame.centerX, 8), 2)
    local parY = tmod(tdiv(curY - frame.centerY, 8), 2)
    return 8 * self.cell.x + 8 * parX, 8 * self.cell.y + 8 * parY
  end
  local x2 = tdiv(curX - frame.centerX, 16)
  local y2 = tdiv(curY - frame.centerY, 16)
  return 8 * self.cell.x + (x2 <= 5 and 8 or 0), 8 * self.cell.y + (y2 > 4 and 8 or 0)
end

---@class MapWorld.Options
---@field kind "gear"|"fly" the screen frame
---@field unlock integer 0 to 2
---@field matrix { x: integer, y: integer } the player's matrix cell; rows gain the source +2 here
---@field zoomed boolean?
---@field session MapWorld.Snapshot? a saved view to restore instead of centring on the player

---@class MapWorld.Snapshot
---@field zoomed boolean
---@field cell { x: integer, y: integer }
---@field cursorX number
---@field cursorY number
---@field scrollX number
---@field scrollY number
---@field affineX number
---@field affineY number
---@field left integer
---@field right integer
---@field top integer
---@field bottom integer

---@param opts MapWorld.Options
---@return MapWorld
function MapWorld.new(opts)
  assert(type(opts) == "table", "the world view needs its options")
  local frame = assert(MapWorld.FRAME[opts.kind], "the world view needs a known frame")
  assert(
    type(opts.unlock) == "number" and opts.unlock >= 0 and opts.unlock <= 2,
    "the world view needs its unlock level"
  )
  assert(
    type(opts.matrix) == "table" and type(opts.matrix.x) == "number" and type(opts.matrix.y) == "number",
    "the world view needs the player's matrix cell"
  )
  local self = setmetatable({
    kind = opts.kind,
    frame = frame,
    minX = MIN_X,
    minY = MIN_Y,
    maxX = MAX_X[opts.unlock + 1],
    maxY = MAX_Y,
    zoomed = opts.zoomed == true,
    ratio = opts.zoomed == true and 2 or 1,
    cell = { x = opts.matrix.x, y = opts.matrix.y + 2 },
    player = { x = opts.matrix.x, y = opts.matrix.y + 2 },
    left = 0,
    right = 0,
    top = 0,
    bottom = 0,
    scrollX = 0,
    scrollY = 0,
    affineX = 0,
    affineY = 0,
    cursorX = 0,
    cursorY = 0,
    _speed = 0,
    _destX = 0,
    _destY = 0,
    _tweenX = 0,
    _tweenY = 0,
    _stepX = 0,
    _stepY = 0,
    _dir = nil,
    _moveStartX = 0,
    _moveStartY = 0,
    _zoomTicks = 0,
    _moveTicks = 0,
    _cursorFrom = nil,
    _cursorDest = nil,
    _drag = nil,
  }, MapWorld)
  if opts.session ~= nil then
    self:restore(opts.session)
  else
    self:_initialView()
  end
  return self
end

-- The creation-time window and cursor (source ov101_021E990C).
function MapWorld:_initialView()
  local frame = self.frame
  self:_computeWindow(false, self.cell.x, self.cell.y, 0, 0)
  self.scrollX, self.scrollY = self._destX, self._destY
  local sx = (self.cell.x - self.left) * 8 + frame.centerX + 4
  local sy = (self.cell.y - self.top) * 8 + frame.centerY + 4
  if self.zoomed then
    self:_computeWindow(true, self.cell.x, self.cell.y, sx, sy)
    self.affineX, self.affineY = self:_anchor(true, sx, sy)
    self.scrollX, self.scrollY = self._destX, self._destY
    sx = (self.cell.x - self.left) * 16 + frame.centerX + 8
    sy = (self.cell.y - self.top) * 16 + frame.centerY + 8
  end
  self.cursorX, self.cursorY = sx, sy
end

---@return MapWorld.Snapshot
function MapWorld:snapshot()
  return {
    zoomed = self.zoomed,
    cell = { x = self.cell.x, y = self.cell.y },
    cursorX = self.cursorX,
    cursorY = self.cursorY,
    scrollX = self.scrollX,
    scrollY = self.scrollY,
    affineX = self.affineX,
    affineY = self.affineY,
    left = self.left,
    right = self.right,
    top = self.top,
    bottom = self.bottom,
  }
end

---@param snapshot MapWorld.Snapshot
function MapWorld:restore(snapshot)
  self.zoomed = snapshot.zoomed
  self.ratio = snapshot.zoomed and 2 or 1
  self.cell = { x = snapshot.cell.x, y = snapshot.cell.y }
  self.cursorX, self.cursorY = snapshot.cursorX, snapshot.cursorY
  self.scrollX, self.scrollY = snapshot.scrollX, snapshot.scrollY
  self.affineX, self.affineY = snapshot.affineX, snapshot.affineY
  self.left, self.right, self.top, self.bottom = snapshot.left, snapshot.right, snapshot.top, snapshot.bottom
end

-- True while a scroll, zoom, or drag animation owns the view and gates input.
---@return boolean
function MapWorld:busy()
  return self._zoomTicks > 0 or self._moveTicks > 0
end

---@return boolean
function MapWorld:zooming()
  return self._zoomTicks > 0
end

-- The screen pixel of a world point under the layer's affine transform:
-- `screen = r * world - (scroll + offset) - (r - 1) * pivot`.
---@param worldX number layer pixels
---@param worldY number layer pixels
---@return number x
---@return number y
function MapWorld:screenOf(worldX, worldY)
  local r = self.ratio
  return r * worldX - (self.scrollX + self.frame.xOffset) - (r - 1) * self.affineX,
    r * worldY - self.scrollY - (r - 1) * self.affineY
end

-- The screen centre of a cell with a pixel offset in unscaled layer pixels:
-- the placement every world-attached sprite shares.
---@param cellX number
---@param cellY number
---@param offsetX number?
---@param offsetY number?
---@return number x
---@return number y
function MapWorld:cellCentre(cellX, cellY, offsetX, offsetY)
  return self:screenOf(8 * cellX + 4 + (offsetX or 0), 8 * cellY + 4 + (offsetY or 0))
end

-- Re-centres the cursor sprite on the selected cell (source ov101_021E94C0).
function MapWorld:placeCursor()
  local scale = self.zoomed and 2 or 1
  self.cursorX = (self.cell.x - self.left) * (8 * scale) + self.frame.centerX + 4 * scale
  self.cursorY = (self.cell.y - self.top) * (8 * scale) + self.frame.centerY + 4 * scale
end

-- The selected cell after a keyboard direction, held directions combined with
-- up before down and left before right. Returns the move mask, or nil.
---@param up boolean
---@param down boolean
---@param left boolean
---@param right boolean
---@return { up: boolean, down: boolean, left: boolean, right: boolean }? moved axes, or nil when blocked
function MapWorld:moveSelection(up, down, left, right)
  local moved = { up = false, down = false, left = false, right = false }
  local cell = self.cell
  if up then
    if cell.y > self.minY + 1 then
      cell.y = cell.y - 1
      moved.up = true
    end
  elseif down then
    if cell.y < self.maxY then
      cell.y = cell.y + 1
      moved.down = true
    end
  end
  if left then
    if cell.x > self.minX + 1 then
      cell.x = cell.x - 1
      moved.left = true
    end
  elseif right then
    if cell.x < self.maxX - 1 then
      cell.x = cell.x + 1
      moved.right = true
    end
  end
  if not (moved.up or moved.down or moved.left or moved.right) then
    return nil
  end
  return moved
end

-- Starts the two-tick cursor tween behind a keyboard move.
---@param moved { up: boolean, down: boolean, left: boolean, right: boolean }
function MapWorld:beginMove(moved)
  self._dir = moved
  self._moveTicks = MOVE_TICKS
  self._moveStartX, self._moveStartY = self.cursorX, self.cursorY
end

-- Recomputes the window bounds from the scroll after a move tween
-- (source PokegearMap_UpdateCursorBounds).
function MapWorld:_updateBounds()
  if self.zoomed then
    self.top = tdiv(self.scrollY + self.affineY - 8, 16) + 1
    self.left = tdiv(self.scrollX + self.affineX - 8, 16) + 1
    self.bottom = self.top + 7
    self.right = self.left + 11
  else
    self.top = tdiv(-self.scrollY, 8) + 1
    self.left = tdiv(self.scrollX, 8) + 1
    self.bottom = self.top + 16
    self.right = self.left + 23
  end
end

-- One tick of the keyboard move tween (source ov101_021EC304): the cursor
-- sprite walks one cell across two ticks until it reaches the window edge,
-- where the world scrolls under it instead.
function MapWorld:_stepMove()
  if self._moveTicks == 0 then
    return
  end
  local delta = self.zoomed and 8 or 4
  local size = self.zoomed and 16 or 8
  local limX = self.zoomed and 10 or 22
  local limY = self.zoomed and 7 or 16
  local cx = tdiv(self._moveStartX - self.frame.centerX, size)
  local cy = tdiv(self._moveStartY - self.frame.centerY, size)
  local dx, dy = 0, 0
  local scrolled = false
  local dir = assert(self._dir, "a move tween carries its directions")
  if dir.up then
    if cy <= 1 then
      dy = dy - delta
      scrolled = true
    else
      self.cursorY = self.cursorY - delta
    end
  elseif dir.down then
    if cy >= limY then
      dy = dy + delta
      scrolled = true
    else
      self.cursorY = self.cursorY + delta
    end
  end
  if dir.left then
    if cx <= 1 then
      dx = dx - delta
      scrolled = true
    else
      self.cursorX = self.cursorX - delta
    end
  elseif dir.right then
    if cx >= limX then
      dx = dx + delta
      scrolled = true
    else
      self.cursorX = self.cursorX + delta
    end
  end
  if scrolled then
    self.scrollX = self.scrollX + dx
    self.scrollY = self.scrollY + dy
  end
  self._moveTicks = self._moveTicks - 1
  if self._moveTicks == 0 then
    self:_updateBounds()
    self._dir = nil
  end
end

-- Toggles the zoom with its four-tick scroll and scale tween
-- (source IN:142-155 and ov101_021EC49C). Gear card only.
function MapWorld:toggleZoom()
  assert(self.kind == "gear", "only the gear card zooms")
  local curX, curY = self.cursorX, self.cursorY
  self.zoomed = not self.zoomed
  self._speed = ZOOM_TICKS
  self._zoomTicks = ZOOM_TICKS
  local scale = self.zoomed and 2 or 1
  local grid = 8 * scale
  self:_computeWindow(self.zoomed, self.cell.x, self.cell.y, curX, curY)
  self.affineX, self.affineY = self:_anchor(self.zoomed, curX, curY)
  self._cursorFrom = { x = curX, y = curY }
  self._cursorDest = {
    x = (self.cell.x - self.left) * grid + self.frame.centerX + grid / 2,
    y = (self.cell.y - self.top) * grid + self.frame.centerY + grid / 2,
  }
  self._zoomStep = 0
end

-- One tick of the zoom tween (source ov101_021EC778).
function MapWorld:_stepZoom()
  if self._zoomTicks == 0 then
    return
  end
  self.ratio = self.ratio + (self.zoomed and 0.25 or -0.25)
  self._zoomTicks = self._zoomTicks - 1
  self._zoomStep = self._zoomStep + 1
  if self._zoomTicks == 0 then
    self.scrollX, self.scrollY = self._destX, self._destY
    self.cursorX, self.cursorY = self._cursorDest.x, self._cursorDest.y
    self.ratio = self.zoomed and 2 or 1
    self._speed = 0
  else
    self._tweenX = self._tweenX + self._stepX
    self._tweenY = self._tweenY + self._stepY
    self.scrollX, self.scrollY = math.floor(self._tweenX), math.floor(self._tweenY)
    local t = self._zoomStep / ZOOM_TICKS
    self.cursorX = math.floor(self._cursorFrom.x + (self._cursorDest.x - self._cursorFrom.x) * t)
    self.cursorY = math.floor(self._cursorFrom.y + (self._cursorDest.y - self._cursorFrom.y) * t)
  end
end

-- Maps a touch to the window cell it selects (source IN:757-793) and moves
-- the cursor sprite onto it.
---@param touchX number
---@param touchY number
---@return integer cellX
---@return integer cellY
function MapWorld:cellFromTouch(touchX, touchY)
  local limits = TOUCH_LIMITS[self.zoomed]
  local size = self.zoomed and 16 or 8
  local c = tdiv(touchX - self.frame.centerX, size)
  local r = tdiv(touchY - self.frame.centerY, size)
  c = math.max(limits.xMin, math.min(limits.xMax, c))
  r = math.max(limits.yMin, math.min(limits.yMax, r))
  return self.left + c, self.top + r
end

---@param cellX integer
---@param cellY integer
function MapWorld:selectCell(cellX, cellY)
  self.cell.x, self.cell.y = cellX, cellY
  self:placeCursor()
end

-- Begins a touch drag of the map from its first contact point.
---@param touchX number
---@param touchY number
function MapWorld:beginDrag(touchX, touchY)
  self._drag = { anchorX = touchX, anchorY = touchY, pendingX = 0, pendingY = 0, second = false }
end

---@return boolean
function MapWorld:dragging()
  return self._drag ~= nil
end

function MapWorld:endDrag()
  self._drag = nil
end

---@param steps integer signed cells to scroll horizontally
---@return integer
function MapWorld:_keepCursorX(steps)
  local xMin = self.left - steps + 1
  local xMax = self.right - steps - 1
  local cell = self.cell
  if xMin <= cell.x and cell.x <= xMax then
    return steps
  elseif cell.x <= xMin then
    return steps + (xMin - cell.x)
  end
  return steps - (cell.x - xMax)
end

---@param steps integer
---@return integer
function MapWorld:_keepCursorY(steps)
  local yMin = self.top - steps + 1
  local yMax = self.bottom - steps
  local cell = self.cell
  if yMin <= cell.y and cell.y <= yMax then
    return steps
  elseif cell.y <= yMin then
    return steps + (yMin - cell.y)
  end
  return steps - (cell.y - yMax)
end

---@param steps integer
---@param nMax integer
---@return integer
function MapWorld:_clampX(steps, nMax)
  if steps > 0 then
    local avail = self.left - self.minX
    if avail <= 0 then
      return 0
    elseif avail < nMax then
      return self:_keepCursorX(avail)
    end
  else
    local avail = self.maxX - self.right
    if avail <= 0 then
      return 0
    elseif avail < nMax then
      return self:_keepCursorX(-avail)
    end
  end
  return self:_keepCursorX(steps)
end

---@param steps integer
---@param nMax integer
---@return integer
function MapWorld:_clampY(steps, nMax)
  if steps > 0 then
    local avail = self.top - self.minY
    if avail <= 0 then
      return 0
    elseif avail < nMax then
      return self:_keepCursorY(avail)
    end
  else
    local avail = self.maxY - self.bottom
    if avail <= 0 then
      return 0
    elseif avail < nMax then
      return self:_keepCursorY(-avail)
    end
  end
  return self:_keepCursorY(steps)
end

-- One tick of a touch drag (source ov101_021EC980 family). Returns false
-- when the finger lifted and the drag ended.
---@param held boolean
---@param touchX number
---@param touchY number
---@return boolean continuing
function MapWorld:stepDrag(held, touchX, touchY)
  local drag = self._drag
  if drag == nil then
    return false
  end
  local grid = self.zoomed and 8 or 4
  local step = self.zoomed and 9 or 5
  if drag.second then
    self.scrollX = self.scrollX - drag.pendingX
    self.scrollY = self.scrollY - drag.pendingY
    -- The cursor sprite travels with the world during a drag.
    self.cursorX = self.cursorX + drag.pendingX
    self.cursorY = self.cursorY + drag.pendingY
    drag.second = false
    drag.pendingX, drag.pendingY = 0, 0
    return true
  end
  if not held then
    self._drag = nil
    return false
  end
  local dX, dY = touchX - drag.anchorX, touchY - drag.anchorY
  local nX, nY = math.floor(math.abs(dX) / step), math.floor(math.abs(dY) / step)
  if nX < 1 and nY < 1 then
    return true
  end
  local sx, sy = 0, 0
  if nX > 0 then
    sx = self:_clampX(tdiv(dX, step), nX)
    if sx ~= 0 then
      self.scrollX = self.scrollX - sx * grid
      self.cursorX = self.cursorX + sx * grid
      self.right = self.right - sx
      self.left = self.left - sx
      drag.anchorX = touchX - tmod(dX, step)
      drag.second = true
      drag.pendingX = sx * grid
    end
  end
  if nY > 0 then
    sy = self:_clampY(tdiv(dY, step), nY)
    if sy ~= 0 then
      self.scrollY = self.scrollY - sy * grid
      self.cursorY = self.cursorY + sy * grid
      self.bottom = self.bottom - sy
      self.top = self.top - sy
      drag.anchorY = touchY - tmod(dY, step)
      drag.second = true
      drag.pendingY = sy * grid
    end
  end
  return true
end

-- Advances every running animation by one tick.
function MapWorld:tick()
  self:_stepMove()
  self:_stepZoom()
end

return MapWorld
