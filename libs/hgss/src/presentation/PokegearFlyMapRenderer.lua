-- The standalone Fly and Town map presentation drawn from the compiled
-- source planes: the lower pane composes the world layer, the flypoint
-- indicators, the player, the cursor, the chrome frame, the prompt bar and
-- the Fly/Quit menu; the information pane composes the Fly banner background,
-- the location preview, the info frame and its text. Follows the Fly entry
-- of the Pokegear map application of the retail ROM: the Town map shows only the location name, its
-- banner shifted down the screen. Draws from the selector's detached view
-- and the plan's resolved image paths, borrows prepared images, and allocates
-- none while drawing. The two panes carry no shell: a host wraps each in its
-- own surface. Pure presentation: no love globals, the host graphics
-- namespace arrives through resources.

local PokegearAtlas = require("libs.hgss.src.presentation.PokegearAtlas")
local PokegearMapLayers = require("libs.hgss.src.presentation.PokegearMapLayers")

local imageAt = PokegearMapLayers.imageAt
local drawSprite = PokegearMapLayers.drawSprite
local printText = PokegearMapLayers.printText

---@class PokegearFlyMapRenderer
local PokegearFlyMapRenderer = {}

local OBJECTS = "mapObjects"

-- Flypoint indicator sequences of the compiled object set.
local INDICATOR_SEQUENCE = { unavailable = 10, available = 11, selected = 12 }

-- The Town map's banner sits eighty-one pixels lower than the Fly panel.
local TOWN_SLIDE = -81

-- Menu frame tile groups in the list-menu tile strip: top row, button
-- sides, separator, and bottom row, each of left, middle, and right tiles,
-- with the highlighted variants twelve (eighteen for separators) later.
local MENU_TOP, MENU_SIDE, MENU_SEPARATOR, MENU_BOTTOM = 0, 3, 6, 9
local MENU_HIGHLIGHT, MENU_SEPARATOR_BELOW = 12, 18
local MENU_ROW = 4

---@param graphics love.graphics
---@param image table<string, unknown> pooled atlas lease behind the menu strip
---@param tile integer tile index in the menu strip
---@param column integer
---@param row integer
local function menuTile(graphics, image, tile, column, row)
  PokegearAtlas.draw(graphics, image, tile * 8, 0, 8, 8, column * 8, row * 8)
end

-- One three-tile row of the menu frame: left, repeated middle, right.
---@param graphics love.graphics
---@param image table<string, unknown> pooled atlas lease behind the menu strip
---@param base integer first tile of the group
---@param x integer left column
---@param row integer
---@param width integer middle tiles
local function menuRow(graphics, image, base, x, row, width)
  menuTile(graphics, image, base, x, row)
  for column = 1, width do
    menuTile(graphics, image, base + 1, x + column, row)
  end
  menuTile(graphics, image, base + 2, x + width + 1, row)
end

-- The Fly/Quit menu: the framed two-entry list at its tile position, the
-- cursor entry highlighted (source touchscreen_list_menu.c).
---@param graphics love.graphics
---@param images table<string, unknown>
---@param text table<string, unknown>?
---@param content table<string, unknown>
---@param menu table<string, unknown>
local function drawMenu(graphics, images, text, content, menu)
  local tiles = imageAt(images, content.menuTiles)
  local colors = (content.textColors --[[@as table<string, unknown>]]).menu --[[@as table<integer, table<string, number>>]]
  local x, width, selected =
    menu.x, --[[@as integer]]
    menu.width, --[[@as integer]]
    menu.cursor --[[@as integer]]
  local entries = 2
  graphics.setColor(1, 1, 1, 1)
  menuRow(graphics, tiles, MENU_TOP + (selected == 0 and MENU_HIGHLIGHT or 0), x, MENU_ROW, width)
  for index = 0, entries - 1 do
    local row = MENU_ROW + 3 * index
    local highlighted = selected == index
    local fill = colors[(highlighted and 6 or 3) + 1]
    for line = 1, 2 do
      menuTile(graphics, tiles, MENU_SIDE + (highlighted and MENU_HIGHLIGHT or 0), x, row + line)
      menuTile(graphics, tiles, MENU_SIDE + 2 + (highlighted and MENU_HIGHLIGHT or 0), x + width + 1, row + line)
    end
    graphics.setColor(fill.r / 255, fill.g / 255, fill.b / 255, 1)
    graphics.rectangle("fill", (x + 1) * 8, (row + 1) * 8, width * 8, 16)
    graphics.setColor(1, 1, 1, 1)
    local label = (menu.labels --[[@as string[]?]] or {})[index + 1]
    if
      text ~= nil
      and label ~= nil
      and type((text --[[@as table<string, unknown>]]).drawTextWithPalette) == "function"
    then
      local measure = (text --[[@as table<string, unknown>]]).textWidth --[[@as fun(self: table, line: string): number]]
      local labelWidth = measure(text, label)
      local foreground, shadow = colors[(highlighted and 4 or 1) + 1], colors[(highlighted and 5 or 2) + 1]
      local palette = {
        foreground = foreground,
        shadow = shadow,
        background = { r = 0, g = 0, b = 0, a = 0 },
      }
      printText(text, label, (x + 1) * 8 + math.floor((width * 8 - labelWidth) / 2), (row + 1) * 8, palette)
    end
    local separator = MENU_SEPARATOR
    if selected == index then
      separator = separator + MENU_HIGHLIGHT
    elseif selected == index + 1 then
      separator = separator + MENU_SEPARATOR_BELOW
    end
    if index < entries - 1 then
      menuRow(graphics, tiles, separator, x, row + 3, width)
    end
  end
  menuRow(
    graphics,
    tiles,
    MENU_BOTTOM + (selected == entries - 1 and MENU_HIGHLIGHT or 0),
    x,
    MENU_ROW + 3 * (entries - 1) + 3,
    width
  )
end

-- Draws the lower pane: the world and flypoint indicators under the chrome
-- frame, then the prompt, the Close label, and the open menu.
---@param resources table<string, unknown> borrowed host collaborators
---@param child table<string, unknown> the selector status
---@param plan table<string, unknown> the published plan
function PokegearFlyMapRenderer.render(resources, child, plan)
  local graphics = assert(resources.graphics, "the fly render borrows its host graphics") --[[@as love.graphics]]
  local images = assert(resources.images, "the fly render borrows its prepared images") --[[@as table<string, unknown>]]
  local text = resources.textRenderer --[[@as table<string, unknown>?]]
  local view = assert(child.view, "the fly render reads the selector view") --[[@as table<string, unknown>]]
  local content = assert(plan.content, "the fly plan carries its payload") --[[@as table<string, unknown>]]
  local sprites = content.sprites --[[@as table<string, table>]]
  PokegearMapLayers.drawWorld(graphics, images, content, view)
  graphics.setColor(1, 1, 1, 1)
  for _, indicator in
    ipairs(view.indicators --[[@as table[] ]])
  do
    drawSprite(graphics, images, sprites, OBJECTS, INDICATOR_SEQUENCE[indicator.state], 1, indicator.x, indicator.y)
  end
  local player = view.player --[[@as table<string, number>]]
  drawSprite(graphics, images, sprites, OBJECTS, 2, player.frame, player.x, player.y)
  local cursor = view.cursor --[[@as table<string, number>]]
  drawSprite(graphics, images, sprites, OBJECTS, 1, 1, cursor.x, cursor.y, cursor.scale)
  PokegearAtlas.draw(graphics, imageAt(images, content.foreground), 0, 0, 256, 192, 0, 0)
  local colors = content.textColors --[[@as table<string, unknown>]]
  if view.prompt ~= nil then
    printText(text, view.prompt --[[@as string]], 8, 168, colors.prompt --[[@as table]])
  end
  if
    view.closeLabel ~= nil
    and text ~= nil
    and type((text --[[@as table<string, unknown>]]).textWidth) == "function"
  then
    local measure = (text --[[@as table<string, unknown>]]).textWidth --[[@as fun(self: table, line: string): number]]
    printText(text, view.closeLabel --[[@as string]], 200 + math.floor(
      (
        48 - measure(text, view.closeLabel --[[@as string]])
      ) / 2
    ), 168, colors.close --[[@as table]])
  end
  if view.menu ~= nil then
    drawMenu(graphics, images, text, content, view.menu --[[@as table<string, unknown>]])
  end
  graphics.setColor(1, 1, 1, 1)
end

-- Draws the information pane: the Fly banner background, then the preview,
-- frame and text. The Town map keeps only its name and shifts the panel.
---@param resources table<string, unknown> borrowed host collaborators
---@param child table<string, unknown> the selector status
---@param plan table<string, unknown> the published plan
function PokegearFlyMapRenderer.renderInformation(resources, child, plan)
  local graphics = assert(resources.graphics, "the fly render borrows its host graphics") --[[@as love.graphics]]
  local images = assert(resources.images, "the fly render borrows its prepared images") --[[@as table<string, unknown>]]
  local text = resources.textRenderer --[[@as table<string, unknown>?]]
  local view = assert(child.view, "the fly render reads the selector view") --[[@as table<string, unknown>]]
  local content = assert(plan.content, "the fly plan carries its payload") --[[@as table<string, unknown>]]
  local town = view.kind == "townMap"
  local panel = view.panel --[[@as table<string, unknown>]]
  local colors = content.textColors --[[@as table<string, unknown>]]
  local slide = town and TOWN_SLIDE or 0
  graphics.setColor(1, 1, 1, 1)
  imageAt(images, content.top):draw(graphics, 0, 0)
  local upper = imageAt(images, content.upper)
  local previews = imageAt(images, content.previews)
  if town then
    PokegearAtlas.draw(graphics, upper, 0, 64, 256, 48, 0, 64 + slide)
    PokegearAtlas.draw(graphics, upper, 0, 0, 64, 56, 184, 88 + slide)
  else
    if panel.previewBlock ~= nil then
      local block = panel.previewBlock --[[@as integer]]
      PokegearAtlas.draw(graphics, previews, (block % 4) * 56, math.floor(block / 4) * 56, 56, 56, 192, 88)
    end
    PokegearAtlas.draw(graphics, upper, 0, 64, 256, 128, 0, 64)
    PokegearAtlas.draw(graphics, upper, panel.previewFrame == true and 64 or 0, 0, 64, 56, 184, 88)
  end
  if panel.region ~= nil then
    printText(text, panel.region --[[@as string]], 10, 68 + slide, colors.upper --[[@as table]])
  end
  if panel.landmark ~= nil then
    printText(text, panel.landmark --[[@as string]], 24, (town and 89 or 88) + slide, colors.upper --[[@as table]])
    if panel.flavor ~= nil then
      printText(text, panel.flavor --[[@as string]], 8, 112, colors.upper --[[@as table]])
    end
  end
  -- The source info pane shares the gear card's marking rows and
  -- rematch icon at the same window tiles; town mode prints neither.
  if not town then
    local words = panel.words --[[@as table<integer, string>]]
    if type(words) == "table" then
      for index = 1, 4 do
        if words[index] ~= nil then
          local column, row = (index - 1) % 2, math.floor((index - 1) / 2)
          printText(text, words[index], 44 + column * 104, 146 + row * 21, colors.upperWord --[[@as table]])
        end
      end
    end
    local sprites = content.sprites --[[@as table<string, table>?]]
    local markers = panel.markers --[[@as table<integer, integer>?]]
    if type(sprites) == "table" and type(markers) == "table" then
      for index = 1, 4 do
        if markers[index] ~= nil then
          local column, row = (index - 1) % 2, math.floor((index - 1) / 2)
          drawSprite(graphics, images, sprites, "markers", 1, markers[index], 32 + column * 104, 155 + row * 21)
        end
      end
      if panel.battleIcon == true then
        drawSprite(graphics, images, sprites, "markers", 2, 1, 16, 104)
      end
    end
  end
  graphics.setColor(1, 1, 1, 1)
end

return PokegearFlyMapRenderer
