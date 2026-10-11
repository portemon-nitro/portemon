-- Draws source-derived Apricorn Box panes and seven animated stock rows.

local ApricornBoxAssetCache = require("libs.assets.src.ApricornBoxAssetCache")

---@class ApricornBoxRenderer
---@field _graphics love.graphics
---@field _cacheFs CacheFs
---@field _text table<string, unknown>
---@field _manifest table<string, unknown>
---@field _images table<string, love.Image>
local ApricornBoxRenderer = {}
ApricornBoxRenderer.__index = ApricornBoxRenderer

local function setWhite(graphics)
  graphics.setColor(1, 1, 1, 1)
end

local function imageFor(self, path)
  local image = self._images[path]
  if image ~= nil then
    return image
  end
  local bytes = assert(self._cacheFs:read(path), "generated Apricorn Box image exists: " .. path)
  image = self._graphics.newImage(love.filesystem.newFileData(bytes, path))
  image:setFilter("nearest", "nearest")
  self._images[path] = image
  return image
end

---@param opts { cacheFs: CacheFs, manifest: table<string, unknown>, text: table<string, unknown>, graphics?: love.graphics }
---@return ApricornBoxRenderer
function ApricornBoxRenderer.new(opts)
  assert(type(opts) == "table", "Apricorn Box renderer options are records")
  local cacheFs = assert(opts.cacheFs, "Apricorn Box rendering needs the generated cache")
  local manifest = assert(opts.manifest, "Apricorn Box rendering needs a validated manifest")
  assert(ApricornBoxAssetCache.isManifestValid(manifest), "Apricorn Box renderer needs the strict family manifest")
  local graphics = opts.graphics or (love and love.graphics)
  assert(type(graphics) == "table" and type(graphics.draw) == "function", "Apricorn Box rendering needs love.graphics")
  local text = assert(opts.text, "Apricorn Box rendering borrows the generated field font")
  assert(type(text.drawText) == "function", "Apricorn Box rendering borrows text drawing")
  local self = setmetatable(
    { _graphics = graphics, _cacheFs = cacheFs, _images = {}, _manifest = manifest, _text = text },
    ApricornBoxRenderer
  )
  for _, path in ipairs(ApricornBoxAssetCache.referencedPaths(manifest)) do
    imageFor(self, path)
  end
  return self
end

---@param view table<string, unknown>
---@param pane { id: string, placement: table<string, unknown> }
function ApricornBoxRenderer:drawPane(view, pane)
  assert(pane.id == "upper" or pane.id == "lower", "Apricorn Box pane identity is source-defined")
  local manifest = self._manifest
  local image = imageFor(self, manifest[pane.id].image)
  local graphics = self._graphics
  setWhite(graphics)
  graphics.draw(image, 0, 0)
  if pane.id ~= "lower" then
    return
  end
  local rows = assert(view.rows, "Box presentation carries the seven stock rows")
  local tick = assert(view.animationTick, "Box presentation carries its fixed animation tick")
  for index, row in ipairs(manifest.rows) do
    local stock = assert(rows[index], "stock snapshots preserve the canonical row order")
    local icon = row.icon
    local elapsed = tick % icon.totalTicks
    local frame
    for _, candidate in ipairs(icon.frames) do
      if elapsed < candidate.durationTicks then
        frame = candidate
        break
      end
      elapsed = elapsed - candidate.durationTicks
    end
    local selected = frame or icon.frames[#icon.frames]
    local sprite = imageFor(self, selected.image)
    setWhite(graphics)
    graphics.draw(
      sprite,
      icon.x - selected.width / 2 + selected.offsetX,
      icon.y - selected.height / 2 + selected.offsetY
    )
    local count = tostring(stock.quantity)
    local countWidth = self._text:textWidth(count)
    local countX = row.quantity.window.x * 8 + (row.quantity.textWidth - countWidth) / 2
    setWhite(graphics)
    self._text:drawText(count, countX, row.quantity.window.y * 8)
  end
  local selectedIndex = assert(view.selectedIndex, "Box presentation carries selected row")
  local selected = assert(rows[selectedIndex], "selected stock belongs to one canonical row")
  local selectedRow = assert(manifest.rows[selectedIndex], "selected row has source icon geometry")
  local cursor = manifest.selectionCursor
  local cursorState = assert(cursor.states[view.cursorSequenceId], "source cursor sequence is compiled")
  local cursorElapsed = tick % cursorState.totalTicks
  local cursorFrame
  for _, candidate in ipairs(cursorState.frames) do
    if cursorElapsed < candidate.durationTicks then
      cursorFrame = candidate
      break
    end
    cursorElapsed = cursorElapsed - candidate.durationTicks
  end
  local cursorVisible = cursorFrame or cursorState.frames[#cursorState.frames]
  local cursorImage = imageFor(self, cursorVisible.image)
  setWhite(graphics)
  graphics.draw(
    cursorImage,
    selectedRow.icon.x - cursorVisible.width / 2 + cursorVisible.offsetX,
    selectedRow.icon.y - cursorVisible.height / 2 + cursorVisible.offsetY + view.cursorOffsetY
  )
  local detail = self._manifest.selectedDetail.window
  local name = assert(view.selectedName, "selected detail uses its source message")
  local quantity = view.mode == "kurt_select" and view.quantity or selected.quantity
  local label = name .. " " .. tostring(quantity)
  setWhite(graphics)
  local detailY = detail.y * 8
  if view.flowMessage ~= nil then
    self._text:drawText(view.flowMessage, detail.x * 8, detailY)
    detailY = detailY + 16
  end
  self._text:drawText(label, detail.x * 8, detailY)
  if view.phase == "confirm" then
    self._text:drawText(view.promptChoice == "yes" and "> Yes  No" or "  Yes > No", detail.x * 8, detailY + 16)
  end
  if view.phase == "actions" then
    local modeName = view.mode == "browse" and "browse" or "kurtSelect"
    local menu = assert(self._manifest.controls.actions[modeName])
    local x = menu.x * 8
    local y = menu.y * 8
    local atlas = imageFor(self, self._manifest.actionMenu.image)
    local function drawTile(tileIndex, tileX, tileY)
      local quad = graphics.newQuad(tileIndex * 8, 0, 8, 8, atlas:getWidth(), atlas:getHeight())
      setWhite(graphics)
      graphics.draw(atlas, quad, tileX, tileY)
    end
    local function drawRowTiles(tileIndex, tileY)
      drawTile(tileIndex, x, tileY)
      for column = 1, menu.width do
        drawTile(tileIndex + 1, x + column * 8, tileY)
      end
      drawTile(tileIndex + 2, x + (menu.width + 1) * 8, tileY)
    end
    local selectedAction = assert(view.selectedAction, "the active Box action list carries its selection")
    drawRowTiles(selectedAction == 1 and 12 or 0, y)
    for index = 1, menu.windowCount do
      local rowY = y + 8 + (index - 1) * 24
      local side = 3 + (selectedAction == index and 12 or 0)
      drawTile(side, x, rowY)
      drawTile(side + 2, x + (menu.width + 1) * 8, rowY)
      drawTile(side, x, rowY + 8)
      drawTile(side + 2, x + (menu.width + 1) * 8, rowY + 8)
      local actionLabel = assert(view.actionLabels[menu.messageIds[index]], "source action message resolves")
      self._text:drawText(actionLabel, x + 8 + 2, rowY)
    end
    for index = 1, menu.windowCount - 1 do
      local separatorIndex = 6
      if (selectedAction == 1 and index == 1) or selectedAction == index then
        separatorIndex = separatorIndex + 12
      elseif (selectedAction == menu.windowCount and index == menu.windowCount - 1) or selectedAction == index + 1 then
        separatorIndex = separatorIndex + 18
      end
      drawRowTiles(separatorIndex, y + index * 24)
    end
    local bottom = selectedAction == menu.windowCount and 21 or 9
    drawRowTiles(bottom, y + menu.windowCount * 24)
    -- The rounded tile art and selected variants come from NARC165. The menu
    -- text sits in the source list windows, one line inset from each border.
  end
end

function ApricornBoxRenderer:release()
  for path, image in pairs(self._images) do
    self._images[path] = nil
    image:release()
  end
end

return ApricornBoxRenderer
