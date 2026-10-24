-- The gear setup card's exact frame composition: the thumbnail background
-- with lock and selection patches, the OBJ cursor over the focused cell,
-- and the two-window dim mask behind an open context menu. Consumes the
-- controller's detached view and the plan's resolved image paths only;
-- allocates no images while drawing. Pure presentation: no love globals,
-- the host graphics namespace arrives through resources.

---@class PokegearConfigureRenderer
local PokegearConfigureRenderer = {}

local PokegearMapLayers = require("libs.hgss.src.presentation.PokegearMapLayers")

local drawSprite = PokegearMapLayers.drawSprite

-- The compiled setup OBJ set (one-based compiled sequences): the focus
-- cursor is four corner sprites in phone order (top-left, bottom-left,
-- top-right, bottom-right), matching the setup set's four two-frame
-- corner animations. Positions are source surface centers.
local CONFIGURE_SET = "configure"
local CURSOR_SEQUENCES = { 1, 2, 3, 4 }

local DIM_ALPHA = 0.5

-- The CHANGE/QUIT option rows inside the menu window at the shared
-- list-menu pitch: sixteen-pixel text rows on a twenty-four pitch.
local MENU_ROW_PITCH = 24
local MENU_TEXT_TOP = 8
local MENU_TEXT_HEIGHT = 16

---@param list table<integer, integer>?
---@return table<integer, boolean>
local function unlockSet(list)
  local set = {}
  if type(list) == "table" then
    for _, skin in ipairs(list) do
      if type(skin) == "number" then
        set[skin] = true
      end
    end
  end
  return set
end

---@param images table<string, unknown> pooled atlas leases by generated path
---@param path string?
---@return table<string, unknown>? pooled atlas lease behind the thumbnail
local function preparedImage(images, path)
  if path == nil then
    return nil
  end
  local lease = images[path]
  assert(lease ~= nil, "the setup render needs its prepared thumbnail image")
  return lease
end

-- Draws the six thumbnail cells, the OBJ cursor over the focused cell,
-- and the dim mask with its context window while a menu is open. The
-- thumbnail art rides the prepared foreground plane, so the pane paints
-- no cell fills of its own; only locked cells take the lock patch. Runs
-- inside the controls-pane logical transform owned by the caller.
---@param graphics love.graphics
---@param images table<string, unknown> borrowed prepared images by path
---@param text table<string, unknown>? borrowed text primitives
---@param content table<string, unknown> the plan payload with resolved paths
---@param childView table<string, unknown> the detached setup selection view
---@param unlockedSkins table<integer, integer>? the saved unlocked skins
function PokegearConfigureRenderer.drawPane(graphics, images, text, content, childView, unlockedSkins)
  assert(graphics ~= nil, "the setup render borrows its host graphics")
  assert(type(images) == "table", "the setup render borrows its prepared images")
  local thumbnails = assert(childView.thumbnails, "the setup view carries its thumbnail cells")
  assert(type(thumbnails) == "table", "the setup view carries its thumbnail cells")
  local backgroundPath = content.configureForeground or content.shellForeground
  assert(type(backgroundPath) == "string", "the setup plan resolves its background image")
  local background = images[backgroundPath]
  assert(background ~= nil, "the setup render needs its prepared background image")
  graphics.setColor(1, 1, 1, 1)
  background:draw(graphics, 0, 0)
  local unlocked = unlockSet(unlockedSkins)
  local patch = preparedImage(images, content.configurePatch --[[@as string?]])
  local cursor = childView.cursor
  if type(cursor) ~= "number" then
    cursor = childView.selectedSkin
  end
  -- The six skin previews are background art: locked cells take the
  -- source lock patch over their cell, nothing else paints over them.
  for skin = 0, 5 do
    if unlocked[skin] ~= true then
      local rect = assert(childView.thumbnails[skin], "the setup view carries all six thumbnail cells")
      local cell = rect --[[@as table<string, number>]]
      if patch ~= nil then
        graphics.setColor(1, 1, 1, 1)
        patch:draw(graphics, cell.x, cell.y)
      else
        graphics.setColor(0.35, 0.35, 0.38, 1)
        graphics.rectangle("fill", cell.x, cell.y, cell.width, cell.height)
      end
    end
  end
  if type(cursor) == "number" and thumbnails[cursor] ~= nil then
    local rect = thumbnails[cursor] --[[@as table<string, number>]]
    local sprites = assert(content.configureSprites, "the setup plan resolves its sprite set")
    local corners = {
      { rect.x, rect.y },
      { rect.x, rect.y + rect.height },
      { rect.x + rect.width, rect.y },
      { rect.x + rect.width, rect.y + rect.height },
    }
    graphics.setColor(1, 1, 1, 1)
    for index, point in ipairs(corners) do
      drawSprite(graphics, images, sprites, CONFIGURE_SET, CURSOR_SEQUENCES[index], 1, point[1], point[2])
    end
  end
  local menu = childView.menu
  local spotlight = childView.spotlight
  if type(menu) == "table" and type(spotlight) == "table" then
    local window = menu --[[@as table<string, number>]]
    graphics.setColor(0, 0, 0, DIM_ALPHA)
    for _, rect in
      ipairs(spotlight --[[@as table[] ]])
    do
      local dim = rect --[[@as table<string, number>]]
      graphics.rectangle("fill", dim.x, dim.y, dim.width, dim.height)
    end
    graphics.setColor(0.12, 0.12, 0.16, 1)
    graphics.rectangle("fill", window.x, window.y, window.width, window.height)
    graphics.setColor(1, 1, 1, 1)
    graphics.rectangle("line", window.x + 0.5, window.y + 0.5, window.width - 1, window.height - 1)
    local options = childView.menuOptions
    local labels = type(options) == "table" and options.labels or nil
    local cursorOption = type(options) == "table" and options.cursor or 0
    if type(labels) == "table" then
      for index = 1, #labels do
        local rowY = window.y + MENU_TEXT_TOP + MENU_ROW_PITCH * (index - 1)
        if index - 1 == cursorOption then
          graphics.setColor(0.12, 0.28, 0.62, 1)
          graphics.rectangle("fill", window.x + 4, rowY - 2, window.width - 8, MENU_TEXT_HEIGHT)
        end
        graphics.setColor(1, 1, 1, 1)
        if text ~= nil and type(text.drawText) == "function" then
          text:drawText(tostring(labels[index]), window.x + 8, rowY)
        end
      end
    end
  end
  graphics.setColor(1, 1, 1, 1)
end

return PokegearConfigureRenderer
