-- The gear region-map presentation: world, mask, sprite, panel, and text
-- layers drawn as independent passes from the controller snapshot only.
-- The required world plane paints first at its snapshot pan and discrete
-- zoom, then the per-skin foreground and upper chrome from their resolved
-- content paths, then masked region patches, then marker, player, and
-- cursor sprites at their snapshot points, then the information windows
-- and the marking panel. Every plane paints unmodulated exactly as its
-- compiled palette authored it; a companion without a world plane raises
-- the established attributed error instead of inventing geography.
-- Consumes borrowed prepared images and draws with no allocation. Pure
-- presentation: no love globals, the host graphics namespace arrives
-- through resources.

---@class PokegearMapRenderer
local PokegearMapRenderer = {}

local MASK_COLOR = { 0.05, 0.06, 0.12, 1 }
local WINDOW_FILL = { 0.94, 0.94, 0.88, 1 }
local WINDOW_LINE = { 0.1, 0.1, 0.12, 1 }

-- Information-panel windows from the compiled tile geometry: region and
-- location across the upper row, flavor, rematch, and marking windows
-- across the lower row.
local INFO_WINDOWS = {
  region = { x = 8, y = 148, width = 72, height = 16 },
  location = { x = 88, y = 148, width = 152, height = 16 },
  flavor = { x = 8, y = 168, width = 112, height = 16 },
  rematch = { x = 128, y = 168, width = 64, height = 16 },
  marking = { x = 200, y = 168, width = 40, height = 16 },
}

-- Native icon hues behind pool positions one through nine.
local ICON_TINTS = {
  { 0.95, 0.25, 0.25 },
  { 0.95, 0.85, 0.25 },
  { 0.25, 0.5, 0.95 },
  { 0.35, 0.85, 0.35 },
  { 0.95, 0.55, 0.25 },
  { 0.7, 0.4, 0.95 },
  { 0.95, 0.45, 0.65 },
  { 0.45, 0.85, 0.9 },
  { 0.6, 0.6, 0.65 },
}

---@param images table<string, unknown>
---@param path string?
---@return table<string, unknown>? image
local function preparedImage(images, path)
  if type(path) ~= "string" then
    return nil
  end
  local image = images[path]
  assert(image ~= nil, "the map render needs its prepared plane image")
  return image
end

-- The world surface at its snapshot pan and discrete zoom: the required
-- prepared plane painted exactly as its compiled palette authored it. A
-- companion without a world plane raises the established attributed error
-- instead of inventing geography.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param view table<string, unknown>
---@param content table<string, unknown>
local function drawWorld(graphics, images, view, content)
  local pan = view.pan
  assert(type(pan) == "table", "the map view carries its pan")
  local zoom = view.zoomCells
  assert(zoom == 8 or zoom == 16, "the map view carries its discrete zoom")
  local world = preparedImage(images, content.world --[[@as string?]])
  assert(world ~= nil, "the map render needs its prepared plane image")
  local scale = zoom / 8
  graphics.setColor(1, 1, 1, 1)
  graphics.draw(world, -pan.x, -pan.y, 0, scale, scale)
end

-- The per-skin surface chrome over the world plane: the skin foreground
-- and upper planes exactly as their compiled palettes authored them,
-- resolved through the existing content paths behind the snapshot skin.
-- Sections without prepared chrome paint nothing rather than tinting the
-- world, so single-plane companions keep their geography unmodulated.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param content table<string, unknown>
local function drawChrome(graphics, images, content)
  local foreground = preparedImage(images, content.foreground --[[@as string?]])
  if foreground ~= nil then
    graphics.setColor(1, 1, 1, 1)
    graphics.draw(foreground, 0, 0)
  end
  local upper = preparedImage(images, content.upper --[[@as string?]])
  if upper ~= nil then
    graphics.setColor(1, 1, 1, 1)
    graphics.draw(upper, 0, 0)
  end
end

-- The locked-region patches: opaque masked panels over every snapshot
-- mask rect, so unlocking repaints the hidden geography.
---@param graphics love.graphics
---@param view table<string, unknown>
local function drawMasks(graphics, view)
  local rects = view.maskRects
  assert(type(rects) == "table", "the map view carries its mask rects")
  graphics.setColor(MASK_COLOR[1], MASK_COLOR[2], MASK_COLOR[3], MASK_COLOR[4])
  for _, rect in ipairs(rects) do
    assert(type(rect) == "table", "mask rects are rectangles")
    graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
  end
end

---@param graphics love.graphics
---@param point table<string, number>
---@param size number
local function drawDiamond(graphics, point, size)
  graphics.polygon("fill", {
    point.x,
    point.y - size,
    point.x + size,
    point.y,
    point.x,
    point.y + size,
    point.x - size,
    point.y,
  })
end

-- One marker sprite at its snapshot point: roamers as diamonds, ready
-- contacts with their tier badge, pending gifts with a parcel dot.
-- Markers without a resolvable pane point stay out of the world layer.
---@param graphics love.graphics
---@param marker table<string, unknown>
local function drawMarker(graphics, marker)
  local point = marker.point
  if type(point) ~= "table" then
    return
  end
  assert(type(point.x) == "number" and type(point.y) == "number", "marker points carry coordinates")
  if marker.kind == "roamer" then
    graphics.setColor(0.85, 0.3, 0.85, 1)
    drawDiamond(graphics, point --[[@as table<string, number>]], 6)
  elseif marker.kind == "contact" then
    if marker.ready == true then
      graphics.setColor(0.95, 0.3, 0.25, 1)
      graphics.rectangle("fill", point.x - 4, point.y - 4, 8, 8)
    end
    if marker.gift ~= nil then
      graphics.setColor(0.95, 0.85, 0.3, 1)
      graphics.rectangle("fill", point.x + 3, point.y + 3, 5, 5)
    end
    if marker.ready ~= true and marker.gift == nil then
      graphics.setColor(0.6, 0.6, 0.65, 1)
      graphics.rectangle("line", point.x - 3.5, point.y - 3.5, 7, 7)
    end
  end
end

-- The player icon at its snapshot point with its source gender frame:
-- distinct silhouettes per gender behind one shared anchor.
---@param graphics love.graphics
---@param view table<string, unknown>
local function drawPlayer(graphics, view)
  local point = view.playerPoint
  assert(type(point) == "table", "the map view carries its player point")
  if view.playerGender == "girl" then
    graphics.setColor(0.95, 0.55, 0.65, 1)
    graphics.polygon("fill", { point.x, point.y - 6, point.x + 5, point.y, point.x, point.y + 5, point.x - 5, point.y })
  else
    graphics.setColor(0.3, 0.55, 0.95, 1)
    graphics.polygon("fill", { point.x, point.y - 6, point.x + 5, point.y + 4, point.x - 5, point.y + 4 })
  end
end

-- The double-size affine cursor over the selection cell: the compiled
-- animation frame at its anchors under the source zoom-affine transform,
-- or a double-size outline when the companion carries no cursor frames.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param view table<string, unknown>
local function drawCursor(graphics, images, view)
  local point = view.cursorPoint
  assert(type(point) == "table", "the map view carries its cursor point")
  local zoom = view.zoomCells
  assert(zoom == 8 or zoom == 16, "the map view carries its discrete zoom")
  local frame = view.cursorFrame
  if type(frame) == "table" and type(frame.image) == "string" then
    local image = images[frame.image]
    if image ~= nil then
      local scale = 2 * zoom / 8
      local anchorX = type(frame.anchorX) == "number" and frame.anchorX or 0
      local anchorY = type(frame.anchorY) == "number" and frame.anchorY or 0
      graphics.setColor(1, 1, 1, 1)
      graphics.draw(image, point.x - anchorX * scale, point.y - anchorY * scale, 0, scale, scale)
      return
    end
  end
  local size = zoom * 2
  graphics.setColor(1, 1, 1, 1)
  graphics.rectangle("line", point.x - 0.5, point.y - 0.5, size, size)
  graphics.rectangle("fill", point.x + 2, point.y + 2, 5, 5)
end

-- The information windows with their token text: window frames from tile
-- geometry always, text lines through the borrowed text primitives when
-- the host supplies them. The prepared upper chrome behind the band
-- carries the per-skin artwork, so the windows paint no invented fills.
---@param graphics love.graphics
---@param text table<string, unknown>?
---@param view table<string, unknown>
local function drawInformation(graphics, text, view)
  local lines = view.infoLines
  assert(type(lines) == "table", "the map view carries its information lines")
  local byWindow = {}
  for _, line in ipairs(lines) do
    if type(line) == "table" and type(line.window) == "string" then
      if byWindow[line.window] == nil then
        byWindow[line.window] = line.text
      end
    end
  end
  for name, rect in pairs(INFO_WINDOWS) do
    graphics.setColor(WINDOW_FILL[1], WINDOW_FILL[2], WINDOW_FILL[3], WINDOW_FILL[4])
    graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
    graphics.setColor(WINDOW_LINE[1], WINDOW_LINE[2], WINDOW_LINE[3], WINDOW_LINE[4])
    graphics.rectangle("line", rect.x + 0.5, rect.y + 0.5, rect.width - 1, rect.height - 1)
    local line = byWindow[name]
    if line ~= nil and text ~= nil and type(text.drawText) == "function" then
      graphics.setColor(0.08, 0.08, 0.1, 1)
      text:drawText(tostring(line), rect.x + 3, rect.y + 2)
    end
  end
end

---@param graphics love.graphics
---@param icon integer|false
---@param rect table<string, number>
local function drawIconGlyph(graphics, icon, rect)
  if icon == false then
    graphics.setColor(0.2, 0.2, 0.24, 1)
    graphics.rectangle("line", rect.x + 0.5, rect.y + 0.5, rect.width - 1, rect.height - 1)
    return
  end
  assert(type(icon) == "number", "icon glyphs carry native icon identities")
  local tint = ICON_TINTS[icon] or ICON_TINTS[1]
  graphics.setColor(tint[1], tint[2], tint[3], 1)
  graphics.rectangle("fill", rect.x + 2, rect.y + 2, rect.width - 4, rect.height - 4)
end

-- The marking panel with its icon pool, occupied and empty slots, word
-- tabs, and trash action. Pool order is the native icon vocabulary.
---@param graphics love.graphics
---@param text table<string, unknown>?
---@param view table<string, unknown>
---@param marking table<string, unknown>?
local function drawMarkingPanel(graphics, text, view, marking)
  local panel = view.markingPanel
  if type(panel) ~= "table" then
    return
  end
  local frame = panel.panel
  assert(type(frame) == "table", "the marking panel carries its frame")
  graphics.setColor(0.1, 0.11, 0.16, 0.92)
  graphics.rectangle("fill", frame.x, frame.y, frame.width, frame.height)
  graphics.setColor(1, 1, 1, 1)
  graphics.rectangle("line", frame.x + 0.5, frame.y + 0.5, frame.width - 1, frame.height - 1)
  assert(type(panel.pool) == "table", "the marking panel carries its icon pool")
  for index, rect in ipairs(panel.pool) do
    drawIconGlyph(graphics, index, rect --[[@as table<string, number>]])
  end
  local icons = marking ~= nil and marking.icons or nil
  assert(type(panel.icons) == "table", "the marking panel carries its icon slots")
  for index, rect in ipairs(panel.icons) do
    local value = false
    if type(icons) == "table" and icons[index] ~= nil then
      value = icons[index]
    end
    drawIconGlyph(graphics, value, rect --[[@as table<string, number>]])
  end
  assert(type(panel.words) == "table", "the marking panel carries its word slots")
  local words = marking ~= nil and marking.words or nil
  for index, rect in ipairs(panel.words) do
    local cell = rect --[[@as table<string, number>]]
    local value = type(words) == "table" and words[index] or false
    if value == false or value == nil then
      graphics.setColor(0.2, 0.2, 0.24, 1)
      graphics.rectangle("line", cell.x + 0.5, cell.y + 0.5, cell.width - 1, cell.height - 1)
    else
      graphics.setColor(0.85, 0.85, 0.9, 1)
      graphics.rectangle("fill", cell.x + 1, cell.y + 1, cell.width - 2, cell.height - 2)
      if text ~= nil and type(text.drawText) == "function" then
        graphics.setColor(0.08, 0.08, 0.1, 1)
        text:drawText(tostring(value), cell.x + 4, cell.y + 4)
      end
    end
  end
  local trash = panel.trash
  assert(type(trash) == "table", "the marking panel carries its trash action")
  graphics.setColor(0.7, 0.25, 0.25, 1)
  graphics.rectangle("line", trash.x + 0.5, trash.y + 0.5, trash.width - 1, trash.height - 1)
end

-- Draws the independent world, mask, sprite, information, and marking
-- layers from the controller snapshot and the skin identity. The skin
-- selects the resolved per-skin content paths the controller publishes;
-- every plane paints unmodulated. Fresh reads only; draw performs no
-- mutation or source parsing.
---@param resources table<string, unknown> borrowed host collaborators
---@param status table<string, unknown> the controller snapshot
---@param skin integer
function PokegearMapRenderer.draw(resources, status, skin)
  assert(resources ~= nil, "the map render borrows its host resources")
  local graphics = resources.graphics
  assert(graphics ~= nil, "the map render borrows its host graphics")
  assert(type(resources.images) == "table", "the map render borrows its prepared images")
  local images = resources.images --[[@as table<string, unknown>]]
  assert(type(skin) == "number" and skin % 1 == 0 and skin >= 0 and skin <= 5, "the map render needs its skin")
  local view = status.view
  assert(type(view) == "table", "the map render reads the controller view")
  local content = view.content
  assert(type(content) == "table", "the map view carries its resolved content")
  local text = resources.textRenderer or resources.text
  if text ~= nil then
    assert(type(text) == "table", "the map text boundary arrives as a record")
  end
  drawWorld(graphics, images, view, content --[[@as table<string, unknown>]])
  drawChrome(graphics, images, content --[[@as table<string, unknown>]])
  drawMasks(graphics, view)
  local markers = view.markers
  assert(type(markers) == "table", "the map view carries its markers")
  for _, marker in ipairs(markers) do
    drawMarker(graphics, marker)
  end
  drawPlayer(graphics, view)
  drawCursor(graphics, images, view)
  drawInformation(graphics, text --[[@as table<string, unknown>?]], view)
  drawMarkingPanel(graphics, text --[[@as table<string, unknown>?]], view, status.marking)
  graphics.setColor(1, 1, 1, 1)
end

return PokegearMapRenderer
