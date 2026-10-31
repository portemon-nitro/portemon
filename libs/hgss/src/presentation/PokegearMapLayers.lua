-- Drawing pieces the region map and the Fly entry share: prepared image
-- lookup, compiled sprite frames, palette-colored window text, and the world
-- layer under its affine transform with its tile patches and highlight.
-- Pure presentation: the host graphics namespace arrives as an argument.

local PokegearAtlas = require("libs.hgss.src.presentation.PokegearAtlas")

---@class PokegearMapLayers
local PokegearMapLayers = {}

local HIGHLIGHT_ALPHA = 10 / 16

---@param images table<string, unknown> pooled atlas leases by generated path
---@param path unknown
---@return table<string, unknown> pooled atlas lease behind the plane
function PokegearMapLayers.imageAt(images, path)
  assert(type(path) == "string", "the map plan resolves its plane images")
  local lease = images[path]
  assert(lease ~= nil, "the map render needs its prepared plane image")
  return lease
end

-- Draws one frame of a compiled sprite sequence centred on a position.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param sprites table<string, table<integer, table<string, unknown>>>
---@param set string
---@param sequence number one-based
---@param frame number one-based
---@param x number
---@param y number
---@param scale number?
function PokegearMapLayers.drawSprite(graphics, images, sprites, set, sequence, frame, x, y, scale)
  local clip = assert(sprites[set][sequence], "the map sprites carry their sequence")
  local info = assert(clip.frames[frame], "the map sprite carries its frame")
  local lease = PokegearMapLayers.imageAt(images, info.image)
  if scale ~= nil and scale ~= 1 then
    lease:draw(graphics, x + info.anchorX * scale, y + info.anchorY * scale, 0, scale, scale)
  else
    lease:draw(graphics, x + info.anchorX, y + info.anchorY)
  end
end

---@param text table<string, unknown>?
---@param line string
---@param x number
---@param y number
---@param colors table<string, table<string, number>>
function PokegearMapLayers.printText(text, line, x, y, colors)
  if
    text == nil or type((text --[[@as table<string, unknown>]]).drawTextWithPalette) ~= "function"
  then
    return
  end
  local draw = (text --[[@as table<string, unknown>]]).drawTextWithPalette --[[@as fun(self: table, line: string, x: number, y: number, palette: table)]]
  local row = 0
  for piece in (line .. "\n"):gmatch("([^\n]*)\n") do
    draw(text, piece, x, y + row * 16, colors)
    row = row + 1
  end
end

-- Touchscreen list-menu frame tile groups in the shared list-menu tile
-- strip (source touchscreen_list_menu.c): top row, button sides,
-- separator, and bottom row, each of left, middle, and right tiles,
-- with the highlighted variants twelve (eighteen for separators) later.
local LIST_MENU_TOP, LIST_MENU_SIDE, LIST_MENU_SEPARATOR, LIST_MENU_BOTTOM = 0, 3, 6, 9
local LIST_MENU_HIGHLIGHT, LIST_MENU_SEPARATOR_BELOW = 12, 18

---@param graphics love.graphics
---@param tiles table<string, unknown> pooled atlas lease behind the menu strip
---@param tile integer tile index in the menu strip
---@param column integer tile column
---@param row integer tile row
local function listMenuTile(graphics, tiles, tile, column, row)
  PokegearAtlas.draw(graphics, tiles, tile * 8, 0, 8, 8, column * 8, row * 8)
end

---@param graphics love.graphics
---@param tiles table<string, unknown> pooled atlas lease behind the menu strip
---@param base integer first tile of the group
---@param x integer left tile column
---@param row integer tile row
---@param width integer middle tiles
local function listMenuRow(graphics, tiles, base, x, row, width)
  listMenuTile(graphics, tiles, base, x, row)
  for column = 1, width do
    listMenuTile(graphics, tiles, base + 1, x + column, row)
  end
  listMenuTile(graphics, tiles, base + 2, x + width + 1, row)
end

-- Draws one framed touchscreen list menu at its tile position: the
-- shared top/side/separator/bottom frame around one three-tile entry
-- row per option, the cursor entry highlighted, labels centered over
-- their entry rows. Every framed menu (Fly destinations, phone
-- actions) shares this exact source frame.
---@param graphics love.graphics
---@param tiles table<string, unknown> pooled atlas lease behind the menu strip
---@param colors table<integer, table<string, number>> sixteen list-menu palette colors, one-based
---@param text table<string, unknown>? borrowed text primitives
---@param spec { x: integer, y: integer, width: integer, labels: string[], cursor: integer } tile geometry, labels, and zero-based cursor
function PokegearMapLayers.drawListMenuFrame(graphics, tiles, colors, text, spec)
  local x, y, width = spec.x, spec.y, spec.width
  local labels = spec.labels or {}
  local selected = spec.cursor or 0
  local entries = #labels
  assert(entries > 0, "framed list menus carry at least one option")
  graphics.setColor(1, 1, 1, 1)
  listMenuRow(graphics, tiles, LIST_MENU_TOP + (selected == 0 and LIST_MENU_HIGHLIGHT or 0), x, y, width)
  for index = 0, entries - 1 do
    local row = y + 3 * index
    local highlighted = selected == index
    local fill = colors[(highlighted and 6 or 3) + 1]
    for line = 1, 2 do
      listMenuTile(graphics, tiles, LIST_MENU_SIDE + (highlighted and LIST_MENU_HIGHLIGHT or 0), x, row + line)
      listMenuTile(
        graphics,
        tiles,
        LIST_MENU_SIDE + 2 + (highlighted and LIST_MENU_HIGHLIGHT or 0),
        x + width + 1,
        row + line
      )
    end
    graphics.setColor(fill.r / 255, fill.g / 255, fill.b / 255, 1)
    graphics.rectangle("fill", (x + 1) * 8, (row + 1) * 8, width * 8, 16)
    graphics.setColor(1, 1, 1, 1)
    local label = labels[index + 1]
    if
      text ~= nil
      and label ~= nil
      and type((text --[[@as table<string, unknown>]]).drawTextWithPalette) == "function"
    then
      local measure = (text --[[@as table<string, unknown>]]).textWidth --[[@as fun(self: table, line: string): number]]
      local labelWidth = measure(text, label)
      local foreground, shadow = colors[(highlighted and 4 or 1) + 1], colors[(highlighted and 5 or 2) + 1]
      PokegearMapLayers.printText(text, label, (x + 1) * 8 + math.floor((width * 8 - labelWidth) / 2), (row + 1) * 8, {
        foreground = foreground,
        shadow = shadow,
        background = { r = 0, g = 0, b = 0, a = 0 },
      })
    end
    local separator = LIST_MENU_SEPARATOR
    if selected == index then
      separator = separator + LIST_MENU_HIGHLIGHT
    elseif selected == index + 1 then
      separator = separator + LIST_MENU_SEPARATOR_BELOW
    end
    if index < entries - 1 then
      listMenuRow(graphics, tiles, separator, x, row + 3, width)
    end
  end
  listMenuRow(
    graphics,
    tiles,
    LIST_MENU_BOTTOM + (selected == entries - 1 and LIST_MENU_HIGHLIGHT or 0),
    x,
    y + 3 * (entries - 1) + 3,
    width
  )
  graphics.setColor(1, 1, 1, 1)
end

-- The world layer under its affine transform: the base, the patches copied
-- over it, and the selection highlight blended above.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param content table<string, unknown>
---@param view table<string, unknown>
function PokegearMapLayers.drawWorld(graphics, images, content, view)
  local world = view.world --[[@as table<string, number>]]
  local lease = PokegearMapLayers.imageAt(images, content.world)
  local r = world.ratio
  graphics.push()
  graphics.translate(
    -(world.scrollX + world.xOffset) - (r - 1) * world.affineX,
    -world.scrollY - (r - 1) * world.affineY
  )
  graphics.scale(r, r)
  graphics.setColor(1, 1, 1, 1)
  lease:draw(graphics, 0, 0)
  for _, patch in
    ipairs(view.patches --[[@as table[] ]])
  do
    PokegearAtlas.draw(
      graphics,
      lease,
      patch.srcX * 8,
      patch.srcY * 8,
      patch.width * 8,
      patch.height * 8,
      patch.destX * 8,
      patch.destY * 8
    )
  end
  graphics.setColor(1, 1, 1, HIGHLIGHT_ALPHA)
  for _, patch in
    ipairs(view.highlight --[[@as table[] ]])
  do
    PokegearAtlas.draw(
      graphics,
      lease,
      patch.srcX * 8,
      patch.srcY * 8,
      patch.width * 8,
      patch.height * 8,
      patch.destX * 8,
      patch.destY * 8
    )
  end
  graphics.setColor(1, 1, 1, 1)
  graphics.pop()
end

return PokegearMapLayers
