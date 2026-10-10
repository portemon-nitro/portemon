-- The gear setup card's exact frame composition: the thumbnail background
-- with lock and selection patches, the OBJ cursor over the focused cell,
-- and the two-window dim mask behind an open context menu. Consumes the
-- controller's detached view and the plan's resolved image paths only;
-- allocates no images while drawing. Pure presentation: no love globals,
-- the host graphics namespace arrives through resources.

---@class PokegearConfigureRenderer
local PokegearConfigureRenderer = {}

local DIM_ALPHA = 0.5

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

---@param images table<string, unknown>
---@param path string?
---@return table<string, unknown>? image
local function preparedImage(images, path)
  if path == nil then
    return nil
  end
  local image = images[path]
  assert(image ~= nil, "the setup render needs its prepared thumbnail image")
  return image --[[@as table<string, unknown>]]
end

-- Draws the six thumbnail cells with lock patches and the OBJ cursor, then
-- the spotlight dim and the context window while a menu is open. Runs
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
  graphics.draw(background, 0, 0)
  local unlocked = unlockSet(unlockedSkins)
  local patch = preparedImage(images, content.configurePatch --[[@as string?]])
  local cursor = childView.cursor
  if type(cursor) ~= "number" then
    cursor = childView.selectedSkin
  end
  for skin = 0, 5 do
    local rect = assert(thumbnails[skin], "the setup view carries all six thumbnail cells")
    assert(type(rect) == "table", "the setup thumbnail cells are rectangles")
    local cell = rect --[[@as table<string, number>]]
    if unlocked[skin] == true then
      graphics.setColor(0.92, 0.92, 0.92, 1)
    else
      graphics.setColor(0.35, 0.35, 0.38, 1)
    end
    graphics.rectangle("fill", cell.x, cell.y, cell.width, cell.height)
    if unlocked[skin] ~= true and patch ~= nil then
      graphics.setColor(1, 1, 1, 1)
      graphics.draw(patch, cell.x, cell.y)
    end
    graphics.setColor(0.08, 0.08, 0.1, 1)
    graphics.rectangle("line", cell.x + 0.5, cell.y + 0.5, cell.width - 1, cell.height - 1)
  end
  if type(cursor) == "number" and thumbnails[cursor] ~= nil then
    local rect = thumbnails[cursor] --[[@as table<string, number>]]
    graphics.setColor(1, 1, 1, 1)
    graphics.rectangle("line", rect.x - 1.5, rect.y - 1.5, rect.width + 3, rect.height + 3)
    graphics.rectangle("fill", rect.x + 2, rect.y + 2, 10, 10)
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
    if text ~= nil and type(text.drawText) == "function" then
      local selected = childView.selectedSkin
      if type(selected) == "number" then
        graphics.setColor(1, 1, 1, 1)
        text:drawText("Skin " .. tostring(selected + 1), window.x + 8, window.y + 8)
      end
    end
  end
  graphics.setColor(1, 1, 1, 1)
end

return PokegearConfigureRenderer
