-- Draws source Photo Album art, state controls, and ready private scenes.

local LogicalSurface = require("libs.ui.src.LogicalSurface")
local PhotoSceneRenderer = require("libs.hgss.src.presentation.PhotoSceneRenderer")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")

---@class PhotoAlbumRenderer
---@field graphics table<string, unknown>
---@field manifest table<string, unknown>
---@field images table<string, unknown>
---@field released boolean
local PhotoAlbumRenderer = {}
PhotoAlbumRenderer.__index = PhotoAlbumRenderer

local SOURCE_SPRITES = {
  -- The five native templates are from pokeheartgold asm/overlay_109.s
  -- ov109_021E7A58; viewer arrows and exit use application/view_photo.c.
  { x = 28, y = 8, animation = 6 },
  { x = 28, y = 8, animation = 7 },
  { x = 16, y = 64, animation = 0 },
  { x = 240, y = 64, animation = 3 },
  { x = 224, y = 176, animation = 8 },
}

local function acquireImages(self, cacheFs)
  local graphics = self.graphics
  local function acquire(visual)
    local path = assert(visual.image, "Photo Album visual carries its compiled image path")
    if self.images[path] == nil then
      local bytes = assert(cacheFs:read(path), "Photo Album visual is unavailable: " .. path)
      local image = graphics.newImage(love.filesystem.newFileData(bytes, path))
      image:setFilter("nearest", "nearest")
      self.images[path] = image
    end
  end
  for _, visual in pairs(self.manifest.photoAlbum.ui.backgrounds) do
    acquire(visual)
  end
  for _, animation in pairs(self.manifest.photoAlbum.ui.animations) do
    for _, frame in ipairs(animation.frames) do
      acquire(frame)
    end
  end
end

---@param options table<string, unknown>
---@return PhotoAlbumRenderer
function PhotoAlbumRenderer.new(options)
  assert(type(options) == "table", "Photo Album renderer requires options")
  local cacheFs = assert(options.cacheFs, "Photo Album renderer requires its version cache")
  local manifest = assert(options.manifest, "Photo Album renderer requires C02 assets")
  local graphics = options.graphics or (love and love.graphics)
  assert(graphics and graphics.newImage and graphics.newQuad, "Photo Album renderer requires LÖVE graphics")
  local self =
    setmetatable({ graphics = graphics, manifest = manifest, images = {}, released = false }, PhotoAlbumRenderer)
  local ok, err = pcall(acquireImages, self, cacheFs)
  if not ok then
    self:release()
    error(err, 0)
  end
  return self
end

local function animationFrame(self, animationId, tick)
  local ui = self.manifest.photoAlbum.ui
  local animation = assert(ui.animations[animationId], "source sprite animation is compiled")
  local timeline = assert(self.manifest.sequences["photoAlbum.animation." .. animationId])
  local elapsed = tick
  local total = 0
  for _, frame in ipairs(animation.frames) do
    total = total + frame.duration
  end
  if timeline.loop and total > 0 then
    elapsed = elapsed % total
  else
    elapsed = math.min(elapsed, math.max(0, total - 1))
  end
  for index, frame in ipairs(animation.frames) do
    if elapsed < frame.duration then
      return frame, index
    end
    elapsed = elapsed - frame.duration
  end
  return animation.frames[#animation.frames], #animation.frames
end

local function drawSprite(self, animationId, x, y, tick)
  local frame = animationFrame(self, animationId, tick)
  self.graphics.setColor(1, 1, 1, 1)
  self.graphics.draw(assert(self.images[frame.image]), x + (frame.anchorX or 0), y + (frame.anchorY or 0))
end

local function drawSourceSprites(self, view)
  local sprites = assert(self.manifest.photoAlbum.ui.sprites)
  for index, source in ipairs(SOURCE_SPRITES) do
    local state = assert(sprites[index], "C02 retains every source sprite role")
    if state.initiallyVisible then
      drawSprite(self, source.animation, source.x, source.y, state.initiallyAnimating and view.animationTick or 0)
    end
  end
end

local function sourceMessage(self, messageId)
  local bank = assert(self.manifest.text.banks[0], "compiled HGSS Photo Album message bank zero is required")
  return assert(bank[messageId], "the Photo Album source message is compiled")
end

local function validMonCount(photo)
  local count = 0
  for _, mon in ipairs(photo.party) do
    if mon ~= false then
      count = count + 1
    end
  end
  return count
end

local function drawSourceMessage(self, textRenderer, messageId, x, y)
  textRenderer:drawLine(sourceMessage(self, messageId), x, y)
end

local function viewerFlavor(self, textRenderer, messageId, photo, mapSectionNativeId)
  local template = sourceMessage(self, messageId)
  local landmark = assert(
    self.manifest.text.banks[279][mapSectionNativeId],
    "compiled map-section message is required for the saved photo"
  )
  local values = {
    [0] = photo.playerName,
    [1] = FieldMessageText.tokensToText(landmark),
    [2] = photo.leadNickname,
    [3] = string.format("%04d", photo.date.year),
    [4] = string.format("%02d", photo.date.month),
    [5] = string.format("%02d", photo.date.day),
  }
  local result = {}
  for _, token in ipairs(template) do
    if token.kind == "substitution" then
      local selector = assert(token.args)[1]
      local value = assert(values[selector], "source photo template selector is supported")
      local parsed = assert(FieldMessageText.parse(value, textRenderer.fontDef, { eos = false }))
      for _, glyph in ipairs(parsed) do
        if glyph.kind ~= "eos" then
          result[#result + 1] = glyph
        end
      end
    else
      result[#result + 1] = token
    end
  end
  return result
end

local function drawControl(self, control, textRenderer, messageId)
  local graphics = self.graphics
  local rect = control.rect
  if control.target == "photo" then
    if control.selected then
      graphics.setColor(1, 0.9, 0.3, 0.95)
      graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
    end
    return
  end
  graphics.setColor(
    control.selected and 0.24 or 0.08,
    control.selected and 0.34 or 0.1,
    control.selected and 0.52 or 0.16,
    0.95
  )
  graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
  graphics.setColor(
    control.selected and 1 or 0.85,
    control.selected and 0.92 or 0.85,
    control.selected and 0.4 or 0.85,
    1
  )
  graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
  if messageId then
    drawSourceMessage(self, textRenderer, messageId, rect.x + 6, rect.y + 6)
  elseif control.label and control.target ~= "delete-choice" then
    textRenderer:drawText(control.label, rect.x + 6, rect.y + 6)
  end
end

local function iconKeyFor(photo, catalog)
  for _, mon in ipairs(photo.party) do
    if mon ~= false then
      return catalog:iconSelection(mon)
    end
  end
end

local function actionMessageId(action)
  if action == "view" then
    return 1
  elseif action == "delete" then
    return 2
  elseif action == "move" then
    return 3
  elseif action == "cancel" then
    return 4
  end
  error("unknown Photo Album action: " .. tostring(action), 0)
end

function PhotoAlbumRenderer:advance(view, resources)
  assert(not self.released, "released Photo Album renderer cannot prepare icons")
  local icons = assert(resources.icons, "Photo Album borrows the shared mon icon provider")
  local catalog = assert(resources.monCatalog, "Photo Album borrows the shared MonCatalog")
  local keys = {}
  for _, entry in ipairs(view.visiblePhotos or {}) do
    local key = iconKeyFor(entry.photo, catalog)
    if key then
      keys[#keys + 1] = key
    end
  end
  return icons:prepareKeys(keys)
end

local function drawPhotoIcons(self, view, resources, textRenderer, controlBySlot)
  local icons = assert(resources.icons, "Photo Album borrows the shared mon icon provider")
  local catalog = assert(resources.monCatalog, "Photo Album borrows the shared MonCatalog")
  for _, entry in ipairs(view.visiblePhotos or {}) do
    local iconKey = iconKeyFor(entry.photo, catalog)
    local rect = assert(controlBySlot[entry.slot]).rect
    if iconKey then
      local dimensions = icons:dimensions(iconKey)
      self.graphics.setColor(1, 1, 1, 1)
      self.graphics.draw(
        icons:image(iconKey),
        icons:quadFor(iconKey, 1),
        rect.x + (rect.width - dimensions.width) / 2,
        rect.y + (rect.height - dimensions.height) / 2
      )
    else
      drawSourceMessage(self, textRenderer, 5, rect.x + 4, rect.y + 10)
    end
  end
end

---@param view table<string, unknown> screen status snapshot
---@param plan table<string, unknown> resolved screen layout
---@param resources table<string, unknown> borrowed renderer and icon collaborators
function PhotoAlbumRenderer:draw(view, plan, resources)
  assert(not self.released, "released Photo Album renderer cannot draw")
  local pane
  for _, candidate in ipairs(plan.panes) do
    if candidate.interactive then
      pane = candidate
    end
  end
  if pane == nil then
    return
  end
  local textRenderer = assert(resources.textRenderer, "Photo Album borrows the shared field text renderer")
  local controlBySlot = {}
  for _, control in ipairs(plan.controls) do
    if control.target == "photo" then
      controlBySlot[control.slot] = control
    end
  end
  LogicalSurface.draw(self.graphics, pane.placement, function()
    self.graphics.setColor(1, 1, 1, 1)
    for _, name in ipairs({ "albumCanvas", "albumControls" }) do
      local visual = self.manifest.photoAlbum.ui.backgrounds[name]
      if visual then
        local image = assert(self.images[visual.image])
        self.graphics.draw(image, visual.anchorX or 0, visual.anchorY or 0)
      end
    end
    drawSourceSprites(self, view)
    if view.phase == "viewer" then
      local viewer = view.viewer
      if viewer and viewer.phase == "ready" and viewer.view then
        PhotoSceneRenderer.draw(viewer.view, plan, resources)
      end
      local selected = assert(view.selectedPhoto)
      local flavorMessage = validMonCount(selected) > 1 and 11 or 10
      local mapSectionNativeId = assert(viewer.view and viewer.view.mapSectionNativeId)
      textRenderer:drawLine(viewerFlavor(self, textRenderer, flavorMessage, selected, mapSectionNativeId), 8, 66)
    elseif view.phase == "actions" then
      drawSourceMessage(self, textRenderer, 6, 52, 70)
    elseif view.phase == "delete_confirm" then
      drawSourceMessage(self, textRenderer, 9, 52, 96)
    elseif view.phase == "move_target" then
      drawSourceMessage(self, textRenderer, 7, 8, 4)
      drawPhotoIcons(self, view, resources, textRenderer, controlBySlot)
      for _, entry in ipairs(view.visiblePhotos or {}) do
        local control = controlBySlot[entry.slot]
        if control then
          textRenderer:drawText(tostring(entry.slot + 1), control.rect.x + 3, control.rect.y + 2)
          drawControl(self, control, textRenderer)
        end
      end
    else
      if view.sourceMessageId then
        drawSourceMessage(self, textRenderer, view.sourceMessageId, 8, 4)
      end
      drawPhotoIcons(self, view, resources, textRenderer, controlBySlot)
      for _, entry in ipairs(view.visiblePhotos or {}) do
        local control = controlBySlot[entry.slot]
        if control then
          textRenderer:drawText(tostring(entry.slot + 1), control.rect.x + 3, control.rect.y + 2)
          drawControl(self, control, textRenderer)
        end
      end
    end
    for _, control in ipairs(plan.controls) do
      if control.target ~= "photo" then
        drawControl(
          self,
          control,
          textRenderer,
          control.target == "action" and actionMessageId(control.action)
            or control.target == "viewer" and control.action == "back" and 0
        )
      end
    end
    if view.phase == "viewer" then
      for _, control in ipairs(plan.controls) do
        if control.sprite == "previous" then
          drawSprite(self, view.selectedIndex == 1 and 2 or 0, 88, 40, view.animationTick)
        elseif control.sprite == "next" then
          drawSprite(self, view.selectedIndex == #view.occupiedSlots and 5 or 3, 168, 40, view.animationTick)
        elseif control.sprite == "back" then
          drawSprite(self, 8, 224, 176, view.animationTick)
        end
      end
      local messageBank = self.manifest.text.banks[0]
      textRenderer:drawLine(assert(messageBank[0]), 192, 168)
    end
  end)
end

function PhotoAlbumRenderer:release()
  if self.released then
    return
  end
  self.released = true
  for _, image in pairs(self.images) do
    image:release()
  end
  self.images = {}
end

return PhotoAlbumRenderer
