-- Draws compiled Storage visuals through the paired source presentation plan.

local LogicalSurface = require("libs.ui.src.LogicalSurface")

---@class PcStorageRenderer
---@field _graphics love.graphics
---@field _cacheFs CacheFs
---@field _manifest table<string, unknown>
---@field _text table<string, unknown>
---@field _images table<string, love.Image>
---@field _disposed boolean
local PcStorageRenderer = {}
PcStorageRenderer.__index = PcStorageRenderer

local function imageFor(self, visual)
  assert(type(visual) == "table" and type(visual.image) == "string", "Storage visuals carry image paths")
  local image = self._images[visual.image]
  if image == nil then
    local bytes = assert(self._cacheFs:read(visual.image), "compiled Storage image exists: " .. visual.image)
    image = self._graphics.newImage(love.filesystem.newFileData(bytes, visual.image))
    image:setFilter("nearest", "nearest")
    self._images[visual.image] = image
  end
  return image
end

local function drawVisual(self, visual, x, y)
  self._graphics.setColor(1, 1, 1, 1)
  local offset = visual.offset or { x = 0, y = 0 }
  self._graphics.draw(imageFor(self, visual), x + offset.x, y + offset.y)
end

---@param options { graphics: love.graphics, cacheFs: CacheFs, manifest: table<string, unknown>, text: table<string, unknown> }
---@return PcStorageRenderer
function PcStorageRenderer.new(options)
  assert(type(options) == "table", "Storage renderer requires its borrowed collaborators")
  return setmetatable({
    _graphics = assert(options.graphics, "Storage renderer requires graphics"),
    _cacheFs = assert(options.cacheFs, "Storage renderer requires the selected asset cache"),
    _manifest = assert(options.manifest, "Storage renderer requires the PC manifest"),
    _text = assert(options.text, "Storage renderer borrows the shared text renderer"),
    _images = {},
    _disposed = false,
  }, PcStorageRenderer)
end

local function drawIcon(graphics, provider, iconKey, x, y, scale)
  if iconKey == nil or provider == nil then
    return
  end
  local dimensions = provider:dimensions(iconKey)
  graphics.draw(
    provider:image(iconKey),
    provider:quadFor(iconKey),
    x,
    y,
    0,
    scale / dimensions.width,
    scale / dimensions.height
  )
end

local function drawMon(self, resources, mon, x, y, party)
  if mon == nil then
    return
  end
  local graphics = self._graphics
  drawIcon(graphics, resources.icons, mon.iconKey, x, y, 20)
  drawIcon(graphics, resources.itemIcons, mon.heldItem ~= "NONE" and mon.itemIconKey or nil, x + 20, y, 12)
  local markings = assert(self._manifest.storage.ui.markings, "Storage marking visuals are compiled")
  for bit = 0, 5 do
    local selected = math.floor(mon.markings / (2 ^ bit)) % 2 == 1
    local visual = markings[bit][selected and "set" or "clear"]
    drawVisual(self, visual, x + bit * 8, y + (party and 18 or 20))
  end
  local label = mon.nickname
  if type(label) == "table" then
    label = label.text or label.value
  end
  if type(label) == "string" then
    self._text:drawText(label, x + 22, y + 12)
  end
end

local function drawEditor(self, view)
  local editor = view.editor
  if editor == nil then
    return
  end
  local graphics = self._graphics
  graphics.setColor(1, 1, 1, 1)
  if editor.kind == "markings" then
    local markings = assert(self._manifest.storage.ui.markings, "Storage marking visuals are compiled")
    for bit = 0, 5 do
      local marked = math.floor(editor.mask / (2 ^ bit)) % 2 == 1
      drawVisual(self, markings[bit][marked and "set" or "clear"], 120 + bit * 8, 8)
      if editor.selected == bit then
        graphics.rectangle("line", 120 + bit * 8, 8, 8, 8)
      end
    end
  elseif editor.kind == "wallpaper" then
    self._text:drawText("Wallpaper", 37, 6)
    local unlocks = assert(view.wallpaperUnlocks, "Storage snapshots carry wallpaper unlocks")
    for logicalId = 0, 23 do
      local storedId = logicalId < 16 and logicalId or logicalId + 16
      local visual = assert(self._manifest.storage.wallpapers[storedId], "wallpaper preview is compiled")
      local column, row = logicalId % 4, math.floor(logicalId / 4)
      local x, y = 37 + column * 46, 20 + row * 24
      local unlocked = logicalId < 16 or unlocks[logicalId - 15] == true
      local image = imageFor(self, visual)
      local scaleX, scaleY = 44 / visual.width, 20 / visual.height
      local offset = visual.offset or { x = 0, y = 0 }
      graphics.setColor(1, 1, 1, unlocked and 1 or 0.35)
      graphics.draw(image, x + offset.x * scaleX, y + offset.y * scaleY, 0, scaleX, scaleY)
      graphics.setColor(1, 1, 1, 1)
      if editor.selected == logicalId then
        graphics.rectangle("line", x, y, 44, 20)
      end
    end
  else
    error("unknown Storage editor " .. tostring(editor.kind), 0)
  end
  graphics.setColor(1, 1, 1, 1)
end

function PcStorageRenderer:drawPane(view, resources, paneId, placement, singlePane)
  assert(not self._disposed, "disposed Storage renderer draws nothing")
  local graphics = self._graphics
  LogicalSurface.draw(graphics, placement, function()
    local storage = self._manifest.storage
    local background = storage.backgrounds.default
    drawVisual(self, background, 0, 0)
    if paneId == "lower" then
      local wallpaperId = assert(view.wallpaperId or 0, "Storage snapshots carry a wallpaper")
      local wallpaper = assert(storage.wallpapers[wallpaperId], "selected wallpaper is compiled")
      drawVisual(self, wallpaper, 44, 16)
    end
    local paneVisual = paneId == "upper" and storage.ui.partyPane or storage.ui.boxPane
    if paneVisual ~= nil then
      drawVisual(self, paneVisual, 0, 0)
    end
    local showParty = paneId == "upper" or singlePane
    local showBox = paneId == "lower" or singlePane
    for slot, mon in ipairs(view.boxSlots or {}) do
      local index = slot - 1
      local source = view.carry and view.carry.source
      if
        showBox
        and not (source ~= nil and source.kind == "box" and source.box == view.activeBox and source.slot == index)
      then
        drawMon(self, resources or {}, mon, 80 + index % 6 * 28, 16 + math.floor(index / 6) * 28, false)
      end
    end
    for slot, mon in ipairs(view.party or {}) do
      local index = slot - 1
      local source = view.carry and view.carry.source
      if showParty and not (source ~= nil and source.kind == "party" and source.slot == index) then
        drawMon(self, resources or {}, mon, 8, 24 + index * 24, true)
      end
    end
    if paneId == "lower" or singlePane then
      drawEditor(self, view)
    end
    if view.carry ~= nil and view.carry.mon ~= nil then
      local target = view.carry.destination or view.focus
      if target ~= nil then
        if target.kind == "party" or target.domain == "party" then
          drawMon(self, resources or {}, view.carry.mon, 8, 24 + target.slot * 24, true)
        elseif target.slot ~= nil then
          local box = target.box or view.activeBox
          if box == view.activeBox then
            drawMon(
              self,
              resources or {},
              view.carry.mon,
              80 + target.slot % 6 * 28,
              16 + math.floor(target.slot / 6) * 28,
              false
            )
          end
        end
      end
    end
    if view.focus ~= nil then
      local focus = view.focus
      local x, y, width, height
      if focus.domain == "party" or focus.kind == "party" then
        x, y, width, height = 8, 24 + focus.slot * 24, 64, 20
      else
        x, y, width, height = 80 + focus.slot % 6 * 28, 16 + math.floor(focus.slot / 6) * 28, 24, 24
      end
      graphics.setColor(1, 1, 1, 1)
      graphics.rectangle("line", x, y, width, height)
    end
    if self._text.drawText then
      if paneId == "lower" or singlePane then
        self._text:drawText(tostring(view.boxName or ""), 44, 8)
      end
      if view.menu ~= nil then
        for index, action in ipairs(view.menu.actions) do
          self._text:drawText((index == view.menu.selected and "> " or "  ") .. action, 8, 150 + index * 10)
        end
      end
    end
    local frameStyle = view.frameStyle or "standard"
    local paletteBank = view.paletteBank or 0
    local frame = assert(
      storage.ui.windowFrames[frameStyle] and storage.ui.windowFrames[frameStyle]["paletteBank" .. paletteBank],
      "Storage frame style and palette bank are compiled"
    )
    local image = imageFor(self, frame)
    graphics.setColor(1, 1, 1, 1)
    graphics.draw(image, 8, 176, 0, 240 / frame.width, 2)
    graphics.setColor(1, 1, 1, 1)
  end)
end

function PcStorageRenderer:draw(view, plan)
  for _, pane in ipairs(plan.panes) do
    self:drawPane(view, plan, pane.id, pane.placement, #plan.panes == 1)
  end
end

function PcStorageRenderer:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  for _, image in pairs(self._images) do
    image:release()
  end
  self._images = {}
end

function PcStorageRenderer:release()
  self:dispose()
end

return PcStorageRenderer
