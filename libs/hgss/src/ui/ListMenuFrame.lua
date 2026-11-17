-- The shared HGSS touchscreen list menu (touchscreen_list_menu.c): the
-- sbox_gra frame tiles around one three-tile entry row per option, the
-- cursor entry framed, and every label centered over its own row. Retail
-- moves only the frame highlight with the cursor; the entry keeps its
-- deselected fill and text until the A-press blink, so a caller that
-- repaints the selected cell passes highlightFill = true and the framed
-- menus of this source keep the default. Pure presentation: the host
-- graphics namespace, the borrowed tile strip, and the text renderer all
-- arrive as arguments.

local ListMenuFrame = {}

-- Frame tile groups in the shared strip: top row, entry sides, separator,
-- and bottom row, each of left, middle, and right tiles, with the
-- highlighted variants twelve (eighteen for separators) later.
local TOP, SIDE, SEPARATOR, BOTTOM = 0, 3, 6, 9
local HIGHLIGHT, SEPARATOR_BELOW = 12, 18

local quadsByImage = setmetatable({}, { __mode = "k" })

---@param graphics love.graphics
---@param image love.Image
---@param sourceX number
---@param sourceY number
---@return love.Quad
local function tileQuad(graphics, image, sourceX, sourceY)
  local quads = quadsByImage[image]
  if quads == nil then
    quads = {}
    quadsByImage[image] = quads
  end
  local key = sourceX * 4096 + sourceY
  local quad = quads[key]
  if quad == nil then
    local width, height = image:getDimensions()
    quad = graphics.newQuad(sourceX, sourceY, 8, 8, width, height)
    quads[key] = quad
  end
  return quad
end

---@param graphics love.graphics
---@param tiles table<string, unknown> borrowed tile-strip lease
---@param tile integer tile index in the shared strip
---@param column integer tile column
---@param row integer tile row
local function drawTile(graphics, tiles, tile, column, row)
  local image = assert(tiles.image, "list menu tiles resolve their strip image")
  tiles:drawQuad(graphics, tileQuad(graphics, image, tile * 8, 0), column * 8, row * 8)
end

---@param graphics love.graphics
---@param tiles table<string, unknown>
---@param base integer first tile of the group
---@param x integer left tile column
---@param row integer tile row
---@param width integer middle tiles
local function drawRow(graphics, tiles, base, x, row, width)
  drawTile(graphics, tiles, base, x, row)
  for column = 1, width do
    drawTile(graphics, tiles, base + 1, x + column, row)
  end
  drawTile(graphics, tiles, base + 2, x + width + 1, row)
end

---@param text table<string, unknown>
---@param label string|table[] a plain label or a compiled source token line
---@return number
local function labelWidth(text, label)
  if type(label) == "string" then
    return (text --[[@as table]]).textWidth(text, label)
  end
  return (text --[[@as table]]).lineWidth(text, label)
end

---@param text table<string, unknown>
---@param label string|table[]
---@param x number
---@param y number
---@param palette table<string, unknown>
local function drawLabel(text, label, x, y, palette)
  if type(label) == "string" then
    (text --[[@as table]]).drawTextWithPalette(text, label, x, y, palette)
    return
  end
  (text --[[@as table]]).drawLineWithPalette(text, label, x, y, palette)
end

---@alias ListMenuFrameSpec { x: integer, y: integer, width: integer, labels: (string|table[])[], cursor: integer?, highlightFill: boolean? }

-- Draws one framed list menu at its tile position: the shared
-- top/side/separator/bottom frame around one three-tile entry row per
-- option, the cursor entry framed (and optionally filled), labels centered
-- over their entry rows.
---@param graphics love.graphics
---@param tiles table<string, unknown> borrowed tile strip behind the menu
---@param colors table<integer, table<string, number>> sixteen source colors, one-based
---@param text table<string, unknown>? borrowed palette text primitives
---@param spec ListMenuFrameSpec tile geometry, labels, and zero-based cursor
function ListMenuFrame.draw(graphics, tiles, colors, text, spec)
  local x, y, width = spec.x, spec.y, spec.width
  local labels = assert(spec.labels, "framed list menus carry their labels")
  local selected = spec.cursor or 0
  local entries = #labels
  assert(entries > 0, "framed list menus carry at least one option")
  local highlightFill = spec.highlightFill == true
  graphics.setColor(1, 1, 1, 1)
  drawRow(graphics, tiles, TOP + (selected == 0 and HIGHLIGHT or 0), x, y, width)
  for index = 0, entries - 1 do
    local row = y + 3 * index
    local highlighted = selected == index
    local filled = highlighted and highlightFill
    local fill = colors[(filled and 6 or 3) + 1]
    for line = 1, 2 do
      drawTile(graphics, tiles, SIDE + (highlighted and HIGHLIGHT or 0), x, row + line)
      drawTile(graphics, tiles, SIDE + 2 + (highlighted and HIGHLIGHT or 0), x + width + 1, row + line)
    end
    graphics.setColor(fill.r / 255, fill.g / 255, fill.b / 255, 1)
    graphics.rectangle("fill", (x + 1) * 8, (row + 1) * 8, width * 8, 16)
    graphics.setColor(1, 1, 1, 1)
    local label = labels[index + 1]
    if text ~= nil and label ~= nil then
      local foreground, shadow = colors[(filled and 4 or 1) + 1], colors[(filled and 5 or 2) + 1]
      drawLabel(text, label, (x + 1) * 8 + math.floor((width * 8 - labelWidth(text, label)) / 2), (row + 1) * 8, {
        foreground = foreground,
        shadow = shadow,
        background = { r = 0, g = 0, b = 0, a = 0 },
      })
    end
    if index < entries - 1 then
      local separator = SEPARATOR
      if highlighted then
        separator = separator + HIGHLIGHT
      elseif selected == index + 1 then
        separator = separator + SEPARATOR_BELOW
      end
      drawRow(graphics, tiles, separator, x, row + 3, width)
    end
  end
  drawRow(graphics, tiles, BOTTOM + (selected == entries - 1 and HIGHLIGHT or 0), x, y + 3 * (entries - 1) + 3, width)
  graphics.setColor(1, 1, 1, 1)
end

return ListMenuFrame
