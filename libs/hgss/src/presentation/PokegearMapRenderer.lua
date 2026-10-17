-- The gear region-map presentation drawn from the compiled source planes:
-- the lower pane composes the scrolling, zoomed world layer with its tile
-- patches and selection highlight, the object sprites under the chrome
-- frame and its two button states; the information pane composes the
-- location preview, the info frame with its text windows and the panel
-- sprites. Marking mode swaps the lower pane for the slot panel and
-- backdrop with their slide, and hides the upper panel. Layer and sprite
-- order follow the source (pret/pokeheartgold pokegear map): world layer,
-- then objects, then the chrome frame. Consumes the card's detached view
-- and the plan's resolved image paths; borrows prepared images and allocates
-- none while drawing. Pure presentation: no love globals, the host graphics
-- namespace arrives through resources.

local PokegearAtlas = require("libs.hgss.src.presentation.PokegearAtlas")
local PokegearMapLayers = require("libs.hgss.src.presentation.PokegearMapLayers")

local imageAt = PokegearMapLayers.imageAt
local drawSprite = PokegearMapLayers.drawSprite
local printText = PokegearMapLayers.printText
local drawWorld = PokegearMapLayers.drawWorld

---@class PokegearMapRenderer
local PokegearMapRenderer = {}

-- Object sets of the compiled map sprites.
local MARKERS = "markers"
local OBJECTS = "mapObjects"

-- The world-attached object sprites in source draw order, back to front:
-- marking dots, roamers, the player, then the cursor.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param sprites table<string, unknown>
---@param view table<string, unknown>
---@param showCursor boolean
local function drawObjects(graphics, images, sprites, view, showCursor)
  local objects = view.sprites --[[@as table<string, unknown>]]
  graphics.setColor(1, 1, 1, 1)
  for _, dot in
    ipairs(objects.hasMarkings --[[@as table[] ]])
  do
    drawSprite(graphics, images, sprites, OBJECTS, 5, 1, dot.x, dot.y)
  end
  for _, roamer in
    ipairs(objects.roamers --[[@as table[] ]])
  do
    drawSprite(graphics, images, sprites, OBJECTS, 3, roamer.frame, roamer.x, roamer.y)
  end
  local player = objects.player --[[@as table<string, number>]]
  drawSprite(graphics, images, sprites, OBJECTS, 2, player.frame, player.x, player.y)
  if showCursor then
    local cursor = objects.cursor --[[@as table<string, number>]]
    drawSprite(graphics, images, sprites, OBJECTS, 1, 1, cursor.x, cursor.y, cursor.scale)
  end
end

-- The chrome frame (the first twenty tile rows of the foreground plane) and
-- the two button states over it.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param content table<string, unknown>
---@param view table<string, unknown>
local function drawChrome(graphics, images, content, view)
  local image = imageAt(images, content.foreground)
  local buttons = view.buttons --[[@as table<string, string>]]
  local markings = ({ normal = 0, pressed = 1, disabled = 2 })[buttons.markings]
  local zoomed = buttons.zoom == "zoomed" and 1 or 0
  graphics.setColor(1, 1, 1, 1)
  PokegearAtlas.draw(graphics, image, 0, 0, 256, 160, 0, 0)
  PokegearAtlas.draw(graphics, image, 48 * markings, 168, 48, 56, 208, 16)
  PokegearAtlas.draw(graphics, image, 144 + 48 * zoomed, 168, 48, 72, 208, 88)
end

-- The marking-mode lower screen: the static backdrop, then the slot panel
-- sliding down into its window, the slot sprites, word text, the pool,
-- the key cursor, and the drag ghost.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param text table<string, unknown>?
---@param content table<string, unknown>
---@param view table<string, unknown>
local function drawMarking(graphics, images, text, content, view)
  local marking = view.marking --[[@as table<string, unknown>?]]
  local sprites = content.sprites --[[@as table<string, table>]]
  local slide = view.bottomSlide --[[@as number]]
  local backdrop = imageAt(images, content.markingBackdrop)
  local panel = imageAt(images, content.markingPanel)
  graphics.setColor(1, 1, 1, 1)
  backdrop:draw(graphics, 0, 0)
  if marking == nil then
    return
  end
  local colors = content.textColors --[[@as table<string, unknown>]]
  -- The slot panel and its window text only show inside the top 112 pixels.
  if slide < 112 then
    PokegearAtlas.draw(graphics, panel, 0, slide, 256, 112 - slide, 0, 0)
    if marking.trashOpen == true then
      PokegearAtlas.clipped(graphics, 0, 0, 256, 112, function()
        PokegearAtlas.draw(graphics, panel, 112 + 64, 128, 64, 40, 40, 64 - slide)
      end)
    end
    if marking.backPressed == true then
      PokegearAtlas.clipped(graphics, 0, 0, 256, 112, function()
        PokegearAtlas.draw(graphics, panel, 56, 128, 48, 40, 184, 64 - slide)
      end)
    end
    PokegearAtlas.clipped(graphics, 0, 0, 256, 112, function()
      if type(marking.landmark) == "string" then
        printText(text, marking.landmark --[[@as string]], 24, 5 - slide, colors.lower)
      end
    end)
  end
  local ghost = marking.drag --[[@as table<string, number>?]]
  for _, slotRecord in
    ipairs(marking.slots --[[@as table[] ]])
  do
    local dragged = ghost ~= nil
      and (
        (slotRecord.kind == "icon" and ghost.type == "set" and ghost.icon == slotRecord.index - 1)
        or (slotRecord.kind == "word" and ghost.type == "set" and ghost.icon == slotRecord.index + 3)
      )
    if not dragged then
      if slotRecord.kind == "icon" and slotRecord.icon ~= false then
        drawSprite(graphics, images, sprites, MARKERS, 1, slotRecord.icon, slotRecord.x, slotRecord.y - slide)
      elseif slotRecord.kind == "word" and slotRecord.word ~= false then
        printText(text, slotRecord.text or "", slotRecord.x + 4, slotRecord.y - 6 - slide, colors.word)
      end
    end
  end
  for _, poolRecord in
    ipairs(marking.pool --[[@as table[] ]])
  do
    local dragged = ghost ~= nil and ghost.type == "pool" and ghost.icon == poolRecord.icon - 1
    if not dragged then
      drawSprite(graphics, images, sprites, MARKERS, 1, poolRecord.icon, poolRecord.x, poolRecord.y)
    end
  end
  if ghost ~= nil then
    if ghost.type == "pool" then
      drawSprite(graphics, images, sprites, MARKERS, 1, ghost.icon + 1, ghost.x, ghost.y)
    elseif ghost.icon < 4 then
      local icon = (marking.slots --[[@as table[] ]])[ghost.icon * 2 + 1].icon
      if icon ~= false then
        drawSprite(graphics, images, sprites, MARKERS, 1, icon, ghost.x, ghost.y)
      end
    else
      local slotRecord = (marking.slots --[[@as table[] ]])[(ghost.icon - 4) * 2 + 2]
      printText(text, slotRecord.text or "", ghost.x + 4, ghost.y - 6, colors.word)
    end
  end
  local cursor = marking.cursor --[[@as table<string, unknown>?]]
  if cursor ~= nil then
    local corners = cursor.corners --[[@as table<string, number>]]
    local x, y =
      cursor.x, --[[@as number]]
      cursor.y --[[@as number]]
    local points = {
      { x + corners.left, y + corners.top },
      { x + corners.left, y + corners.bottom },
      { x + corners.right, y + corners.top },
      { x + corners.right, y + corners.bottom },
    }
    for index, point in ipairs(points) do
      drawSprite(graphics, images, sprites, OBJECTS, 5 + index, 1, point[1], point[2])
    end
  end
  if slide == 0 and view.mode == "marking" then
    drawSprite(graphics, images, sprites, OBJECTS, 4, 1, 128, 108)
  end
end

-- Draws the lower pane: the world, objects and chrome in map mode, the
-- marking panel in marking mode.
---@param resources table<string, unknown> borrowed host collaborators
---@param child table<string, unknown> the card status
---@param plan table<string, unknown> the published plan
---@param shell table<string, unknown> the shell snapshot
function PokegearMapRenderer.render(resources, child, plan, shell)
  local graphics = assert(resources.graphics, "the map render borrows its host graphics") --[[@as love.graphics]]
  local images = assert(resources.images, "the map render borrows its prepared images") --[[@as table<string, unknown>]]
  local text = resources.textRenderer --[[@as table<string, unknown>?]]
  local view = assert(child.view, "the map render reads the card view") --[[@as table<string, unknown>]]
  local content = assert(plan.content, "the map plan carries its payload") --[[@as table<string, unknown>]]
  if view.mode == "marking" then
    drawMarking(graphics, images, text, content, view)
    graphics.setColor(1, 1, 1, 1)
    return
  end
  drawWorld(graphics, images, content, view)
  drawObjects(graphics, images, content.sprites --[[@as table]], view, shell.entered == true)
  drawChrome(graphics, images, content, view)
  graphics.setColor(1, 1, 1, 1)
end

-- Draws the information pane in map mode: preview, frame, text and panel
-- sprites, sliding up from below the screen on entry.
---@param resources table<string, unknown> borrowed host collaborators
---@param child table<string, unknown> the card status
---@param plan table<string, unknown> the published plan
function PokegearMapRenderer.renderInformation(resources, child, plan)
  local graphics = assert(resources.graphics, "the map render borrows its host graphics") --[[@as love.graphics]]
  local images = assert(resources.images, "the map render borrows its prepared images") --[[@as table<string, unknown>]]
  local text = resources.textRenderer --[[@as table<string, unknown>?]]
  local view = assert(child.view, "the map render reads the card view") --[[@as table<string, unknown>]]
  local content = assert(plan.content, "the map plan carries its payload") --[[@as table<string, unknown>]]
  if view.mode ~= "map" then
    return
  end
  local panel = view.panel --[[@as table<string, unknown>]]
  local slide = view.topSlide --[[@as number]]
  local sprites = content.sprites --[[@as table<string, table>]]
  local colors = content.textColors --[[@as table<string, unknown>]]
  local upper = imageAt(images, content.upper)
  local previews = imageAt(images, content.previews)
  PokegearAtlas.clipped(graphics, 0, 64, 256, 128, function()
    graphics.setColor(1, 1, 1, 1)
    if panel.previewBlock ~= nil then
      local block = panel.previewBlock --[[@as integer]]
      PokegearAtlas.draw(graphics, previews, (block % 4) * 56, math.floor(block / 4) * 56, 56, 56, 192, 88 + slide)
    end
    PokegearAtlas.draw(graphics, upper, 0, 56, 256, 136, 0, 56 + slide)
    PokegearAtlas.draw(graphics, upper, panel.previewFrame == true and 64 or 0, 0, 64, 56, 184, 88 + slide)
    printText(text, panel.region --[[@as string]], 10, 68 + slide, colors.upper)
    if panel.landmark ~= nil then
      printText(text, panel.landmark --[[@as string]], 24, 96 + slide, colors.upper)
      printText(text, panel.flavor --[[@as string]], 8, 112 + slide, colors.upper)
    end
    local words = panel.words --[[@as table<integer, string>]]
    for index = 1, 4 do
      if words[index] ~= nil then
        local column, row = (index - 1) % 2, math.floor((index - 1) / 2)
        printText(text, words[index], 44 + column * 104, 146 + row * 21 + slide, colors.upperWord)
      end
    end
  end)
  -- The panel sprites travel with the slide but are never clipped.
  local markers = panel.markers --[[@as table<integer, integer>]]
  for index = 1, 4 do
    if markers[index] ~= nil then
      local column, row = (index - 1) % 2, math.floor((index - 1) / 2)
      drawSprite(graphics, images, sprites, MARKERS, 1, markers[index], 32 + column * 104, 155 + row * 21 + slide)
    end
  end
  if panel.battleIcon == true then
    drawSprite(graphics, images, sprites, MARKERS, 2, 1, 16, 104 + slide)
  end
  graphics.setColor(1, 1, 1, 1)
end

return PokegearMapRenderer
