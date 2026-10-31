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

-- Menu tile row of the two-entry Fly/Quit frame (source M9270:1083-1097).
local MENU_ROW = 4

-- The Fly/Quit menu: the framed two-entry list at its tile position, the
-- cursor entry highlighted (source touchscreen_list_menu.c). The frame
-- itself is the shared touchscreen list menu.
---@param graphics love.graphics
---@param tiles table<string, unknown> pooled atlas lease behind the menu strip
---@param colors table<integer, table<string, number>> sixteen list-menu palette colors, one-based
---@param text table<string, unknown>? borrowed text primitives
---@param menu table<string, unknown> tile geometry with labels and cursor
local function drawMenu(graphics, tiles, colors, text, menu)
  PokegearMapLayers.drawListMenuFrame(graphics, tiles, colors, text, {
    x = menu.x, --[[@as integer]]
    y = MENU_ROW,
    width = menu.width, --[[@as integer]]
    labels = menu.labels --[[@as string[] ]],
    cursor = menu.cursor --[[@as integer]],
  })
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
    local menu = view.menu --[[@as table<string, unknown>]]
    drawMenu(
      graphics,
      imageAt(images, content.menuTiles),
      (content.textColors --[[@as table<string, unknown>]]).menu --[[@as table<integer, table<string, number>>]],
      text,
      menu
    )
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
