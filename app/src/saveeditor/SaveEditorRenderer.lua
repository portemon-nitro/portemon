-- Draws the app-native editor shell from its resolved view and plan.

local Renderer = {}
Renderer.__index = Renderer

local AssetPreparationQueue = require("libs.hgss.src.presentation.AssetPreparationQueue")
local Errors = require("libs.errors.src.Errors")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
local ItemIconAssetProvider = require("libs.hgss.src.presentation.ItemIconAssetProvider")
local ListSurface = require("libs.ui.src.ListSurface")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local PixelScale = require("libs.ui.src.PixelScale")
local TextButton = require("libs.ui.src.TextButton")
local FieldWindowRenderer = require("libs.hgss.src.ui.FieldWindowRenderer")
local ProductMenuSkin = require("app.src.ui.ProductMenuSkin")

---@class SaveEditorRenderer
---@field text table<string, unknown>
---@field skin ProductMenuSkin
---@field graphics table<string, unknown>
---@field _disposed boolean
---@field _iconQueue table<string, unknown>?
---@field _iconProvider MonIconAssetProvider?
---@field _icons table<string, { image: love.Image, quad: love.Quad, dimensions: { width: number, height: number } }>
---@field _windowRenderer FieldWindowRenderer?
---@field _bagImages table<string, love.Image>
---@field _pendingIconPreparation { cacheFs: table<string, unknown>, derivedAssets: table<string, unknown> }?
---@field iconStatus string?
---@field iconFailure string?
---@field metrics fun(self: SaveEditorRenderer): { lineHeight: number, measure: fun(value: string): number }
---@field dispose fun(self: SaveEditorRenderer)
---@field preparePresentationAssets fun(self: SaveEditorRenderer, cacheFs: table<string, unknown>, manifest: table<string, unknown>)
---@field prepareVisibleIcons fun(self: SaveEditorRenderer, view: table<string, unknown>, plan: table<string, unknown>, cacheFs: table<string, unknown>, derivedAssets: table<string, unknown>, deferGraphics: boolean?)

local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
local Button = require("libs.ui.src.Button")

local function midpoint(top, bottom)
  return {
    (top[1] + bottom[1]) / 2,
    (top[2] + bottom[2]) / 2,
    (top[3] + bottom[3]) / 2,
    1,
  }
end

local BUTTON_FACES = {
  navigation = {
    border = { 0.12, 0.22, 0.42, 1 },
    rim = { 0.72, 0.82, 0.96, 1 },
    faceTop = { 0.48, 0.67, 0.91, 1 },
    faceBottom = { 0.28, 0.48, 0.76, 1 },
  },
  back = {
    border = { 0.12, 0.2, 0.48, 1 },
    rim = { 0.78, 0.83, 1, 1 },
    faceTop = { 97 / 255, 138 / 255, 251 / 255, 1 },
    faceBottom = { 48 / 255, 89 / 255, 195 / 255, 1 },
  },
  primary = {
    border = { 0.12, 0.34, 0.18, 1 },
    rim = { 0.77, 0.92, 0.75, 1 },
    faceTop = { 32 / 255, 186 / 255, 162 / 255, 1 },
    faceBottom = { 40 / 255, 121 / 255, 113 / 255, 1 },
  },
  secondary = {
    border = { 0.28, 0.18, 0.42, 1 },
    rim = { 0.88, 0.78, 0.95, 1 },
    faceTop = { 0.73, 0.6, 0.87, 1 },
    faceBottom = { 0.54, 0.39, 0.72, 1 },
  },
  destructive = {
    border = { 0.46, 0.12, 0.12, 1 },
    rim = { 0.96, 0.77, 0.75, 1 },
    faceTop = { 0.92, 0.58, 0.53, 1 },
    faceBottom = { 0.76, 0.34, 0.3, 1 },
  },
  disabled = {
    border = { 0.38, 0.4, 0.41, 1 },
    rim = { 0.83, 0.84, 0.84, 1 },
    faceTop = { 0.76, 0.78, 0.79, 1 },
    faceBottom = { 0.62, 0.65, 0.66, 1 },
  },
  inactive = {
    border = { 0.38, 0.4, 0.41, 1 },
    rim = { 0.93, 0.94, 0.94, 1 },
    faceTop = { 1, 1, 1, 1 },
    faceBottom = { 0.87, 0.88, 0.89, 1 },
  },
}

local BUTTON_COLORS = {}
for role, faces in pairs(BUTTON_FACES) do
  BUTTON_COLORS[role] = {
    border = faces.border,
    rim = faces.rim,
    innerBorder = midpoint(faces.faceTop, faces.faceBottom),
    faceTop = faces.faceTop,
    faceBottom = faces.faceBottom,
  }
end

---@param cacheFs table<string, unknown>
---@param options table<string, unknown>
---@return MonIconAssetProvider|Errors.Error
local function createIconProvider(cacheFs, options)
  return MonIconAssetProvider.new(cacheFs, options)
end

local function setColor(graphics, color)
  if color.r ~= nil then
    graphics.setColor(color.r / 255, color.g / 255, color.b / 255, color.a or 1)
  else
    graphics.setColor(color[1], color[2], color[3], color[4] or 1)
  end
end

function Renderer.new(options)
  assert(type(options) == "table" and options.text, "save editor renderer needs field text")
  assert(type(options.versionId) == "string" and options.versionId ~= "", "save editor renderer needs a game version")
  return setmetatable({
    text = options.text,
    skin = ProductMenuSkin.forVersion(options.versionId),
    graphics = options.graphics or love.graphics,
    _disposed = false,
    _iconQueue = nil,
    _iconProvider = nil,
    _icons = {},
    _windowRenderer = nil,
    _itemIconProvider = nil,
    _bagImages = {},
    _pendingIconPreparation = nil,
    iconStatus = nil,
    iconFailure = nil,
  }, Renderer)
end

function Renderer:preparePresentationAssets(cacheFs, manifest)
  assert(not self._disposed, "disposed save editor renderer cannot prepare assets")
  if self._windowRenderer ~= nil then
    return
  end
  self._windowRenderer = FieldWindowRenderer.new({ cacheFs = cacheFs, manifest = manifest, graphics = self.graphics })
end

function Renderer:prepareVisibleIcons(view, plan, cacheFs, derivedAssets, deferGraphics)
  if deferGraphics then
    self._pendingIconPreparation = { cacheFs = cacheFs, derivedAssets = derivedAssets }
    return
  end
  if view.valueEditor and view.valueEditor.kind == "number" then
    for _, role in ipairs({ "increment", "decrement" }) do
      for _, state in ipairs({ "normal", "pressed" }) do
        local visual = assert(view.numberControlVisuals[role][state])
        if self._bagImages[visual.image] == nil then
          local bytes = assert(cacheFs:read(visual.image), "retail quantity visual bytes are required")
          local image = self.graphics.newImage(love.filesystem.newFileData(bytes, visual.image))
          image:setFilter("nearest", "nearest")
          self._bagImages[visual.image] = image
        end
      end
    end
  end
  if view.section == "Bag" then
    if self._itemIconProvider == nil then
      self._itemIconProvider = ItemIconAssetProvider.new(cacheFs, { graphics = self.graphics })
    end
    local paths = { assert(view.bagPocketStrip).image }
    if view.bagTabFocusVisual ~= nil then
      paths[#paths + 1] = view.bagTabFocusVisual.image
    end
    local visuals = assert(view.bagQuantityVisuals)
    for _, direction in ipairs({ "decrement", "increment" }) do
      for _, state in ipairs({ "normal", "pressed" }) do
        paths[#paths + 1] = visuals[direction][state].image
      end
    end
    for _, path in ipairs(paths) do
      if self._bagImages[path] == nil then
        local bytes = assert(cacheFs:read(path), "Bag visual bytes are required")
        local image = self.graphics.newImage(love.filesystem.newFileData(bytes, path))
        image:setFilter("nearest", "nearest")
        self._bagImages[path] = image
      end
    end
    for _, card in ipairs(assert(plan.content.layout).bagGrid or {}) do
      if card.iconKey and self._icons[card.iconKey] == nil then
        self._icons[card.iconKey] = {
          image = self._itemIconProvider:image(),
          quad = self._itemIconProvider:quadFor(card.iconKey),
          dimensions = self._itemIconProvider:dimensions(card.iconKey),
        }
      end
    end
    self.iconStatus, self.iconFailure = "ready", nil
    return
  end
  local partyLayout = view.section == "Party" and assert(plan.content.layout)
  if partyLayout and partyLayout.targets["party:page:previous"] ~= nil then
    local visuals = assert(view.bagQuantityVisuals)
    for _, direction in ipairs({ "decrement", "increment" }) do
      for _, state in ipairs({ "normal", "pressed" }) do
        local path = visuals[direction][state].image
        if self._bagImages[path] == nil then
          local bytes = assert(cacheFs:read(path), "Party pager visual bytes are required")
          local image = self.graphics.newImage(love.filesystem.newFileData(bytes, path))
          image:setFilter("nearest", "nearest")
          self._bagImages[path] = image
        end
      end
    end
  end
  if view.section ~= "Party" then
    self.iconStatus, self.iconFailure = nil, nil
    return
  end
  local iconKeys = {}
  for _, row in ipairs(assert(plan.content.layout).rows) do
    if row.iconKey ~= nil then
      iconKeys[#iconKeys + 1] = row.iconKey
    end
  end
  for _, slot in ipairs((assert(plan.content.layout).partyStrip or {}).slots or {}) do
    if slot.iconKey ~= nil then
      iconKeys[#iconKeys + 1] = slot.iconKey
    end
  end
  if #iconKeys == 0 then
    self.iconStatus, self.iconFailure = nil, nil
    return
  end
  if self._iconProvider == nil then
    local queue = AssetPreparationQueue.new(cacheFs)
    local ok, providerOrError = pcall(createIconProvider, cacheFs, {
      graphics = self.graphics,
      preparationQueue = queue,
      derivedAssets = derivedAssets,
    })
    if not ok then
      queue:release()
      if Errors.is(providerOrError) then
        ---@cast providerOrError Errors.Error
        self.iconStatus, self.iconFailure = "failed", providerOrError.message
        return
      end
      error(providerOrError, 0)
    end
    self._iconQueue = queue
    self._iconProvider = assert(providerOrError)
  end
  local ready, failure = self._iconProvider:prepareKeys(iconKeys)
  if failure ~= nil then
    self.iconStatus, self.iconFailure = "failed", failure
    return
  elseif not ready then
    self.iconStatus, self.iconFailure = "pending", nil
    return
  end
  for _, iconKey in ipairs(iconKeys) do
    if self._icons[iconKey] == nil then
      self._icons[iconKey] = {
        image = self._iconProvider:image(iconKey),
        quad = self._iconProvider:quadFor(iconKey, 1),
        dimensions = self._iconProvider:dimensions(iconKey),
      }
    end
  end
  self.iconStatus, self.iconFailure = "ready", nil
end

function Renderer:metrics()
  local text = assert(self.text)
  return {
    lineHeight = assert(text.fontDef.lineHeight),
    measure = function(value)
      return text:textWidth(value)
    end,
  }
end

local function visibleText(value)
  return tostring(value or "")
end

local function textPalette(skin, foreground)
  local shadow = skin.text.normal.foreground
  return {
    foreground = foreground,
    shadow = { r = shadow.r, g = shadow.g, b = shadow.b },
    background = { r = 0, g = 0, b = 0, a = 0 },
  }
end

local function pagePalette(skin)
  return textPalette(skin, { r = 248, g = 248, b = 248 })
end

local function pageMutedPalette(skin)
  return textPalette(skin, { r = 198, g = 200, b = 204 })
end

local function pageErrorPalette(skin)
  return textPalette(skin, { r = 255, g = 200, b = 190 })
end

local function buttonPalette(skin)
  return textPalette(skin, { r = 250, g = 250, b = 250 })
end

local function buttonDisabledPalette(skin)
  return textPalette(skin, { r = 192, g = 194, b = 197 })
end

local function buttonInactivePalette(skin)
  return skin.text.normal
end

local function isFocusedVisible(view, targetId)
  return targetId == view.focus and view.focusVisible == true
end

local function actionSemantic(targetId)
  if targetId == "party:move:add" then
    return "primary"
  elseif targetId == "party:use-species-name" then
    return "destructive"
  end
  return "navigation"
end

local function drawText(renderer, value, x, y, role)
  x, y = PixelScale.snapLogical(x), PixelScale.snapLogical(y)
  local textRole = role == "error" and "error"
    or role == "information" and "information"
    or role == "hint" and "hint"
    or "normal"
  local skin = renderer.skin
  if type(role) == "table" then
    if role.foreground ~= nil and role.shadow ~= nil then
      renderer.graphics.setColor(1, 1, 1, 1)
      renderer.text:drawTextWithPalette(visibleText(value), x, y, role)
      renderer.graphics.setColor(1, 1, 1, 1)
      return
    end
    local foreground
    if role.foreground ~= nil then
      foreground = role.foreground
    elseif role.r ~= nil then
      foreground = role
    else
      foreground = { r = role[1] * 255, g = role[2] * 255, b = role[3] * 255 }
    end
    local base = skin.text.normal
    local palette = {
      foreground = { r = foreground.r, g = foreground.g, b = foreground.b },
      shadow = base.shadow,
      background = base.background,
    }
    renderer.graphics.setColor(1, 1, 1, 1)
    renderer.text:drawTextWithPalette(visibleText(value), x, y, palette)
    renderer.graphics.setColor(1, 1, 1, 1)
    return
  end
  ProductMenuSkin.drawText(renderer.graphics, renderer.text, skin, textRole, visibleText(value), x, y)
end

local function drawFocusRing(renderer, rectValue, radius)
  assert(type(radius) == "number" and radius >= 0, "focus outline radius follows its control geometry")
  local graphics = renderer.graphics
  local savedWidth = graphics.getLineWidth()
  setColor(graphics, renderer.skin.cards.normal.selectedRim)
  graphics.setLineWidth(2)
  graphics.rectangle(
    "line",
    rectValue.x + 1,
    rectValue.y + 1,
    rectValue.width - 2,
    rectValue.height - 2,
    radius,
    radius
  )
  graphics.setLineWidth(savedWidth)
  graphics.setColor(1, 1, 1, 1)
end

local function drawRowMarker(renderer, rectValue, radius, active)
  local graphics = renderer.graphics
  ListSurface.drawMarker(
    graphics,
    rectValue,
    radius,
    active and { 0.86, 0.16, 0.18, 1 } or BUTTON_COLORS.disabled.faceBottom
  )
  graphics.setColor(1, 1, 1, 1)
end

local function optionRole(disabled, semantic, option, active)
  if disabled then
    return "disabled"
  end
  if option and not active then
    return "inactive"
  end
  if semantic == "back" then
    return "back"
  end
  return semantic or "navigation"
end

local function optionLabelPalette(renderer, disabled, option, active)
  if disabled then
    return buttonDisabledPalette(renderer.skin)
  end
  if option and not active then
    return buttonInactivePalette(renderer.skin)
  end
  return buttonPalette(renderer.skin)
end

local drawBodyText
local fitText

local function drawShadedControl(renderer, rect, label, active, focused, disabled, semantic, option)
  local role = optionRole(disabled, semantic, option, active)
  local colors = assert(BUTTON_COLORS[role], "unknown save editor button role: " .. tostring(role))
  local labelPalette = optionLabelPalette(renderer, disabled, option, active)
  local button = TextButton.resolve({ rect = rect, scale = 1 })
  local fitted = fitText(renderer, label, button.contentRect.width)
  TextButton.draw(renderer.graphics, button, {
    label = fitted,
    selected = false,
    colors = colors,
    text = {
      lineHeight = renderer.text.fontDef.lineHeight,
      measure = function(value)
        return renderer.text:textWidth(value)
      end,
      draw = function(value, x, y)
        drawBodyText(renderer, value, x, y, labelPalette)
      end,
    },
  })
  if focused then
    local border = assert(button.border, "resolved text button border is missing")
    drawFocusRing(renderer, rect, math.max(0, assert(border.cornerRadius, "text button corner radius is missing") - 1))
  end
  return button.contentRect
end

drawBodyText = function(renderer, value, x, y, role)
  local graphics = renderer.graphics
  graphics.push("all")
  local ok, err = pcall(function()
    drawText(renderer, value, x, y, role)
  end)
  graphics.pop()
  if not ok then
    error(err, 0)
  end
end

local function drawListText(renderer, value, x, y, role)
  drawBodyText(renderer, value, x, y, role)
end

local function drawCompactControl(renderer, rectValue, label, active, focused, disabled, semantic, option)
  local role = optionRole(disabled, semantic, option, active)
  local colors = assert(BUTTON_COLORS[role], "unknown save editor button role: " .. tostring(role))
  local graphics = renderer.graphics
  local button = Button.resolve({
    rect = rectValue,
    borderWidth = 1,
    rimWidth = 1,
    innerBorderWidth = 1,
    cornerRadius = 2,
    faceSplit = 0.5,
    contentInsetX = 4,
    contentInsetY = 2,
  })
  Button.draw(graphics, button, {
    border = colors.border,
    rim = colors.rim,
    innerBorder = colors.innerBorder,
    faceTop = colors.faceTop,
    faceBottom = colors.faceBottom,
  })
  local innerRect = assert(button.innerBorder, "compact button inner border is missing").rect
  local splitY = assert(button.face, "compact button face is missing").splitY
  graphics.setColor(colors.innerBorder[1], colors.innerBorder[2], colors.innerBorder[3], colors.innerBorder[4])
  graphics.rectangle("fill", innerRect.x, splitY - 1, innerRect.width, 2)
  local content = button.contentRect
  local fitted = fitText(renderer, label, content.width)
  local labelPalette = optionLabelPalette(renderer, disabled, option, active)
  local textWidth = renderer.text:textWidth(fitted)
  local textHeight = renderer.text.fontDef.lineHeight
  drawBodyText(
    renderer,
    fitted,
    content.x + (content.width - textWidth) / 2,
    content.y + (content.height - textHeight) / 2,
    labelPalette
  )
  if focused then
    local border = assert(button.border, "resolved compact button border is missing")
    drawFocusRing(
      renderer,
      rectValue,
      math.max(0, assert(border.cornerRadius, "compact button corner radius is missing") - 1)
    )
  end
  graphics.setColor(1, 1, 1, 1)
  return content
end

local function drawButtonControl(renderer, rectValue, label, active, focused, disabled, semantic, option)
  local lineHeight = renderer.text.fontDef.lineHeight
  if rectValue.height >= lineHeight + 32 + 1 then
    return drawShadedControl(renderer, rectValue, label, active, focused, disabled, semantic, option)
  end
  return drawCompactControl(renderer, rectValue, label, active, focused, disabled, semantic, option)
end

local function drawSectionControl(renderer, rectValue, label, active, focused)
  local palette = active and buttonPalette(renderer.skin) or buttonInactivePalette(renderer.skin)
  local fitted = fitText(renderer, label, math.max(0, rectValue.width - 8))
  if rectValue.height >= renderer.text.fontDef.lineHeight + 33 then
    local role = optionRole(false, nil, true, active)
    local button = TextButton.resolve({ rect = rectValue, scale = 1 })
    TextButton.draw(renderer.graphics, button, {
      label = fitted,
      selected = false,
      colors = assert(BUTTON_COLORS[role]),
      text = {
        lineHeight = renderer.text.fontDef.lineHeight,
        measure = function(value)
          return renderer.text:textWidth(value)
        end,
        draw = function(value, x, y)
          drawBodyText(renderer, value, x, y, palette)
        end,
      },
    })
    if focused then
      local border = assert(button.border, "resolved section button border is missing")
      drawFocusRing(renderer, rectValue, math.max(0, assert(border.cornerRadius) - 1))
    end
    return
  end
  drawButtonControl(renderer, rectValue, "", active, focused, false, nil, true)
  local textWidth = renderer.text:textWidth(fitted)
  local textHeight = renderer.text.fontDef.lineHeight
  drawBodyText(
    renderer,
    fitted,
    rectValue.x + (rectValue.width - textWidth) / 2,
    rectValue.y + (rectValue.height - textHeight) / 2,
    palette
  )
end

local function drawListRow(renderer, rectValue, label, focused, value, labelRect, valueRect, markerRect, muted)
  if markerRect == nil and focused then
    drawFocusRing(renderer, rectValue, 0)
  end
  local labelBounds = labelRect or { x = rectValue.x + 6, y = rectValue.y + 3, width = rectValue.width - 12 }
  local labelHeight = labelBounds.height or renderer.text.fontDef.lineHeight
  local labelY = labelBounds.y + math.max(0, (labelHeight - renderer.text.fontDef.lineHeight) / 2)
  local labelWidth = labelBounds.width
  drawListText(renderer, fitText(renderer, label, labelWidth), labelBounds.x, labelY, muted and "hint" or nil)
  if value ~= nil then
    local valueText = tostring(value)
    local bounds = valueRect
      or { x = rectValue.x, y = rectValue.y + 3, width = rectValue.width * 0.35, height = labelHeight }
    local fitted = fitText(renderer, valueText, bounds.width)
    local fittedWidth = renderer.text:textWidth(fitted)
    local x = valueRect and bounds.x or rectValue.x + rectValue.width - fittedWidth - 6
    local valueY = bounds.y + math.max(0, ((bounds.height or labelHeight) - renderer.text.fontDef.lineHeight) / 2)
    drawListText(renderer, fitted, x, valueY, "hint")
  end
end

local function findListForTarget(lists, targetId)
  for _, list in pairs(lists or {}) do
    if list.cursorTarget == targetId or list.indexByTarget ~= nil and list.indexByTarget[targetId] ~= nil then
      return list
    end
  end
  return nil
end

local function listRowClip(layout, targetId, fallback)
  local list = findListForTarget(layout.lists, targetId)
  local viewport = list and layout.viewports[list.viewportId]
  return viewport and viewport.clip or fallback
end

fitText = function(renderer, value, width)
  local text = visibleText(value)
  local textRenderer = assert(renderer.text)
  if textRenderer:textWidth(text) <= width then
    return text
  end
  local visible = {}
  for glyph in Utf8Glyphs.iter(text) do
    local candidate = table.concat(visible) .. glyph
    if textRenderer:textWidth(candidate .. "…") > width then
      break
    end
    visible[#visible + 1] = glyph
  end
  local fitted = table.concat(visible) .. "…"
  return textRenderer:textWidth(fitted) <= width and fitted or ""
end

local drawCenteredIcon

local function drawBagCard(renderer, card, focused)
  local graphics = renderer.graphics
  local bounds = card.rect
  local colors = assert(BUTTON_COLORS.inactive, "Bag cards reuse the neutral button face")
  local button = Button.resolve({
    rect = bounds,
    borderWidth = 1,
    rimWidth = 1,
    innerBorderWidth = 1,
    cornerRadius = 2,
    faceSplit = 0.5,
    contentInsetX = 4,
    contentInsetY = 2,
  })
  Button.draw(graphics, button, {
    border = colors.border,
    rim = colors.rim,
    innerBorder = colors.innerBorder,
    faceTop = colors.faceTop,
    faceBottom = colors.faceBottom,
  })
  local icon = card.iconKey and renderer._icons[card.iconKey]
  if icon then
    drawCenteredIcon(renderer, icon, card.iconRect)
  end
  local palette = buttonInactivePalette(renderer.skin)
  assert(PixelScale.assertInteger(card.textScale) == 1, "Bag card text uses native glyph scale")
  local name = card.nameRect
  drawText(renderer, fitText(renderer, card.label, name.width), name.x, name.y, palette)
  local quantity = "x" .. tostring(card.quantity)
  local quantityWidth = renderer.text:textWidth(quantity)
  local slot = card.quantityRect
  drawText(renderer, quantity, slot.x + math.max(0, slot.width - quantityWidth), slot.y, palette)
  if focused then
    drawFocusRing(
      renderer,
      bounds,
      math.max(0, assert(button.border.cornerRadius, "bag button corner radius is missing") - 1)
    )
  end
end

local function drawPageArrow(renderer, target, visuals, angle, focused, pressed, disabled)
  local visual = (pressed == true and not disabled) and visuals.pressed or visuals.normal
  local image = assert(renderer._bagImages[assert(visual.image)])
  local width, height = image:getDimensions()
  local scale = PixelScale.assertInteger(1)
  if disabled then
    renderer.graphics.setColor(1, 1, 1, 0.35)
  else
    renderer.graphics.setColor(1, 1, 1, 1)
  end
  renderer.graphics.draw(
    image,
    PixelScale.snapLogical(target.x + target.width / 2),
    PixelScale.snapLogical(target.y + target.height / 2),
    angle,
    scale,
    scale,
    width / 2,
    height / 2
  )
  renderer.graphics.setColor(1, 1, 1, 1)
  if focused == true and not disabled then
    setColor(renderer.graphics, renderer.skin.cards.normal.selectedRim)
    renderer.graphics.rectangle("line", target.x, target.y, target.width, target.height)
    renderer.graphics.setColor(1, 1, 1, 1)
  end
end

local function targetRect(layout, targetId)
  local target = layout.targets[targetId]
  return target and target.rect
end

local function framedContentRect(content)
  local width = math.floor(content.width / 8) * 8
  local height = math.floor(content.height / 8) * 8
  assert(width >= 8 and height >= 8, "Save Editor framed content must fit at least one dialogue-frame tile")
  return {
    x = math.floor(content.x + (content.width - width) / 2 + 0.5),
    y = math.floor(content.y + (content.height - height) / 2 + 0.5),
    width = width,
    height = height,
  }
end

drawCenteredIcon = function(renderer, icon, bounds)
  local dimensions = icon.dimensions
  local scale = PixelScale.assertInteger(1)
  local x = PixelScale.snapLogical(bounds.x + (bounds.width - dimensions.width) / 2)
  local y = PixelScale.snapLogical(bounds.y + (bounds.height - dimensions.height) / 2)
  renderer.graphics.setColor(1, 1, 1, 1)
  LogicalSurface.clip(renderer.graphics, bounds, function()
    if icon.quad ~= nil then
      renderer.graphics.draw(icon.image, icon.quad, x, y, 0, scale, scale)
    else
      renderer.graphics.draw(icon.image, x, y, 0, scale, scale)
    end
  end)
end

local function drawStripSlot(renderer, slot, focused)
  if slot.kind == "empty" then
    return
  end
  if slot.kind == "add" then
    drawButtonControl(renderer, slot.rect, "+ Add", false, focused, false, "primary", false)
    return
  end
  drawButtonControl(renderer, slot.rect, "", slot.active == true, focused, false, nil, true)
  local icon = slot.iconKey and renderer._icons[slot.iconKey]
  if icon then
    drawCenteredIcon(renderer, icon, slot.iconRect)
  end
end

local drawLocation

---@class SaveEditorPaintContext
---@field renderer SaveEditorRenderer
---@field graphics table<string, unknown>
---@field view table<string, unknown>
---@field layout table<string, unknown>
---@field placement table<string, unknown>
---@field renderLayers table<string, unknown>[]
---@field pane table<string, unknown>

---@param ctx SaveEditorPaintContext
local function paintBackground(ctx)
  local renderer, graphics, layout = ctx.renderer, ctx.graphics, ctx.layout
  local placement = ctx.placement
  setColor(graphics, renderer.skin.background)
  graphics.rectangle("fill", 0, 0, placement.logicalWidth, placement.logicalHeight)
  for _, surface in ipairs(layout.listSurfaces or {}) do
    graphics.setColor(1, 1, 1, 1)
    graphics.rectangle("fill", surface.x, surface.y, surface.width, surface.height)
  end
  if layout.decisionList then
    local surface = layout.decisionList.surface
    graphics.setColor(1, 1, 1, 1)
    graphics.rectangle("fill", surface.x, surface.y, surface.width, surface.height)
  end
end

---@param ctx SaveEditorPaintContext
local function paintNavigation(ctx)
  local renderer, layout = ctx.renderer, ctx.layout
  local view = ctx.view
  for _, navigation in ipairs(layout.navigation) do
    local target = targetRect(layout, navigation.targetId)
    if target then
      local label = navigation.label
      if navigation.targetId:match("^location:map:") then
        label = fitText(renderer, label, target.width - 22)
      end
      if navigation.targetId:match("^list:") then
        -- The visible row marker represents focus within this list surface.
      elseif navigation.role == "list" then
        local list = findListForTarget(layout.lists, navigation.targetId)
        drawListRow(
          renderer,
          target,
          label,
          not navigation.targetId:match("^list:") and isFocusedVisible(view, navigation.targetId),
          nil,
          nil,
          nil,
          layout.rowMarkers[navigation.targetId],
          list ~= nil and list.pending == true
        )
      else
        if navigation.targetId:match("^section:") then
          drawSectionControl(
            renderer,
            target,
            label,
            navigation.active == true,
            isFocusedVisible(view, navigation.targetId)
          )
        else
          drawButtonControl(
            renderer,
            target,
            label,
            navigation.active == true,
            isFocusedVisible(view, navigation.targetId),
            false,
            nil,
            navigation.active ~= nil
          )
        end
      end
    end
  end
end

---@param ctx SaveEditorPaintContext
local function paintRows(ctx)
  local renderer, graphics, view, layout = ctx.renderer, ctx.graphics, ctx.view, ctx.layout
  local SELECTED = renderer.skin.cards.normal.selectedRim
  for _, row in ipairs(layout.rows) do
    local rect = targetRect(layout, row.targetId)
    if rect and not row.gridCard and not row.partyField then
      local target = assert(layout.targets[row.targetId])
      LogicalSurface.clip(graphics, listRowClip(layout, row.targetId, target.clip or rect), function()
        if row.listSurface then
          local list = findListForTarget(layout.lists, row.targetId)
          drawListRow(
            renderer,
            rect,
            row.displayName or row.label,
            isFocusedVisible(view, row.targetId),
            row.valueText or row.value,
            row.labelRect,
            row.valueRect,
            layout.rowMarkers[row.targetId],
            row.muted or list ~= nil and list.pending == true
          )
          return
        end
        if row.role == "toggle" or row.role == "integer value" or row.role == "named choice" then
          drawListRow(
            renderer,
            rect,
            row.displayName or row.label,
            isFocusedVisible(view, row.targetId),
            row.valueText or row.value,
            row.labelRect,
            row.valueRect
          )
          return
        end
        if row.role == "action" then
          drawButtonControl(
            renderer,
            rect,
            row.displayName or row.label,
            false,
            isFocusedVisible(view, row.targetId),
            row.enabled == false,
            row.semantic or actionSemantic(row.targetId),
            false
          )
          return
        end
        local actionable = row.role == "party slot"
          or row.role == "bag item"
          or row.targetId:match("^party:slot:") ~= nil
          or row.targetId:match("^bag:item:") ~= nil
        if actionable and isFocusedVisible(view, row.targetId) then
          setColor(graphics, SELECTED)
          graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
        end
        local icon = row.iconKey and renderer._icons[row.iconKey]
        if icon and graphics.draw then
          graphics.setColor(1, 1, 1, 1)
          graphics.draw(icon.image, icon.quad, PixelScale.snapLogical(rect.x + 3), PixelScale.snapLogical(rect.y + 2))
        end
        local labelRect = assert(row.labelRect, "layout rows own their label text bounds")
        local labelRole = row.role == "warning" and "error" or row.role == "read-only value" and "hint" or nil
        drawBodyText(
          renderer,
          fitText(renderer, row.displayName or row.label, labelRect.width),
          labelRect.x,
          rect.y + 3,
          labelRole
        )
        if row.valueText ~= nil and row.valueRect ~= nil then
          local valueRect = row.valueRect
          drawBodyText(renderer, fitText(renderer, row.valueText, valueRect.width), valueRect.x, rect.y + 3, "hint")
        end
      end)
    end
  end
end

---@param ctx SaveEditorPaintContext
local function paintParty(ctx)
  local renderer, graphics, view, layout = ctx.renderer, ctx.graphics, ctx.view, ctx.layout
  local SELECTED = renderer.skin.cards.normal.selectedRim
  if view.section == "Party" and layout.partyStrip ~= nil then
    for _, slot in ipairs(layout.partyStrip.slots) do
      drawStripSlot(renderer, slot, isFocusedVisible(view, slot.targetId))
    end
  end
  if
    view.section == "Party"
    and layout.partyPageLabel ~= nil
    and targetRect(layout, "party:page:previous") ~= nil
    and targetRect(layout, "party:page:next") ~= nil
  then
    local visuals = assert(view.bagQuantityVisuals, "Party pager arrows reuse prepared quantity visuals")
    local previous = assert(targetRect(layout, "party:page:previous"))
    local next = assert(targetRect(layout, "party:page:next"))
    local label = layout.partyPageLabel
    local previousDisabled = layout.targets["party:page:previous"].activationEnabled == false
    local nextDisabled = layout.targets["party:page:next"].activationEnabled == false
    drawPageArrow(
      renderer,
      previous,
      visuals.decrement,
      math.pi / 2,
      isFocusedVisible(view, "party:page:previous"),
      view.capturedTarget == "party:page:previous",
      previousDisabled
    )
    drawText(
      renderer,
      fitText(renderer, label.text, label.rect.width),
      label.rect.x + math.max(0, (label.rect.width - renderer.text:textWidth(label.text)) / 2),
      label.rect.y + 1,
      pagePalette(renderer.skin)
    )
    drawPageArrow(
      renderer,
      next,
      visuals.increment,
      math.pi / 2,
      isFocusedVisible(view, "party:page:next"),
      view.capturedTarget == "party:page:next",
      nextDisabled
    )
  end
  if view.section == "Party" then
    local bodySucceeded, bodyFailure
    LogicalSurface.clip(graphics, assert(layout.viewports.party).clip, function()
      bodySucceeded, bodyFailure = pcall(function()
        for _, row in ipairs(layout.rows) do
          if row.partyField then
            local y = row.layoutRect.y + 3
            local fieldRole = row.role == "warning" and "error" or pagePalette(renderer.skin)
            drawBodyText(renderer, fitText(renderer, row.label, row.labelRect.width), row.labelRect.x, y, fieldRole)
            if row.editable then
              drawButtonControl(
                renderer,
                row.valueRect,
                row.valueText or "",
                false,
                isFocusedVisible(view, row.targetId),
                false,
                nil,
                false
              )
            elseif row.role == "action" then
              drawButtonControl(
                renderer,
                row.layoutRect,
                row.label,
                false,
                isFocusedVisible(view, row.targetId),
                row.enabled == false,
                row.semantic or actionSemantic(row.targetId),
                false
              )
            elseif row.valueText ~= nil then
              drawBodyText(renderer, fitText(renderer, row.valueText, row.valueRect.width), row.valueRect.x, y, "hint")
            end
          end
        end
        if layout.partyStatsTable ~= nil then
          local stats = layout.partyStatsTable
          local headerColor = renderer.skin.cards.normal.border
          local function drawCellText(text, target, role)
            local lineHeight = renderer.text.fontDef.lineHeight
            local y = target.y + math.max(0, (target.height - lineHeight) / 2)
            local palette = role == "hint" and pageMutedPalette(renderer.skin)
              or role == "error" and pageErrorPalette(renderer.skin)
              or pagePalette(renderer.skin)
            drawText(renderer, fitText(renderer, text, target.width - 8), target.x + 4, y, palette)
          end
          for _, header in ipairs(stats.headers) do
            setColor(graphics, headerColor)
            graphics.rectangle("fill", header.rect.x, header.rect.y, header.rect.width, header.rect.height)
            drawCellText(header.label, header.rect)
          end
          for _, row in ipairs(stats.rows) do
            for _, cell in ipairs(row.cells) do
              local cellRect = cell.rect
              if isFocusedVisible(view, cell.targetId) then
                setColor(graphics, SELECTED)
                graphics.rectangle("line", cellRect.x + 1, cellRect.y + 1, cellRect.width - 2, cellRect.height - 2)
              end
              drawCellText(cell.label, cellRect, "normal")
            end
          end
        end
        if layout.partyMoves ~= nil then
          for _, slot in ipairs(layout.partyMoves.slots) do
            if slot.kind ~= "empty" then
              drawButtonControl(
                renderer,
                slot.rect,
                slot.label or "",
                false,
                isFocusedVisible(view, slot.targetId),
                false,
                slot.kind == "add" and "primary" or nil,
                false
              )
            end
          end
        end
      end)
    end)
    if not bodySucceeded then
      error(bodyFailure, 0)
    end
  end
end

---@param ctx SaveEditorPaintContext
local function paintBag(ctx)
  local renderer, graphics, view, layout = ctx.renderer, ctx.graphics, ctx.view, ctx.layout
  if view.section == "Bag" then
    local strip = assert(layout.bagStripTarget)
    local stripImage = renderer._bagImages[assert(view.bagPocketStrip).image]
    assert(stripImage, "selected Bag pocket strip was prepared before drawing")
    graphics.setColor(1, 1, 1, 1)
    graphics.draw(stripImage, PixelScale.snapLogical(strip.x), PixelScale.snapLogical(strip.y))
    for _, targetId in ipairs(layout.bagTabs or {}) do
      if isFocusedVisible(view, targetId) and view.bagTabFocusVisual ~= nil then
        local tabIndex = tonumber(targetId:match("bag:pocket:(%d+)$"))
        local pocketKey = targetId:match("bag:pocket:(.+)$")
        for index, pocket in ipairs(view.bagPockets) do
          if pocket.key == pocketKey then
            tabIndex = index
            break
          end
        end
        local point = assert(view.bagTabFocusTargets[assert(tabIndex)])
        local descriptor = assert(view.bagTabFocusVisual)
        local image = assert(renderer._bagImages[descriptor.image])
        local offset = descriptor.offset or { x = 0, y = 0 }
        graphics.setColor(1, 1, 1, 1)
        graphics.draw(
          image,
          PixelScale.snapLogical(strip.x + point.x + offset.x),
          PixelScale.snapLogical(strip.y + point.y + offset.y)
        )
      end
    end
    for _, card in ipairs(layout.bagGrid or {}) do
      drawBagCard(renderer, card, isFocusedVisible(view, card.targetId))
    end
    if targetRect(layout, "bag:add") then
      drawPageArrow(
        renderer,
        targetRect(layout, "bag:page:previous"),
        view.bagQuantityVisuals.decrement,
        math.pi / 2,
        isFocusedVisible(view, "bag:page:previous"),
        view.capturedTarget == "bag:page:previous",
        view.bagPage0 == 0
      )
      local pageText = tostring(layout.bagPage.index) .. " / " .. tostring(layout.bagPage.count)
      drawText(
        renderer,
        pageText,
        layout.bagPageText.x + math.max(0, (layout.bagPageText.width - renderer.text:textWidth(pageText)) / 2),
        layout.bagPageText.y,
        pageMutedPalette(renderer.skin)
      )
      drawPageArrow(
        renderer,
        targetRect(layout, "bag:page:next"),
        view.bagQuantityVisuals.increment,
        -- Next uses the up/increment source arrow rotated clockwise to point right.
        math.pi / 2,
        isFocusedVisible(view, "bag:page:next"),
        view.capturedTarget == "bag:page:next",
        view.bagPage0 + 1 >= view.bagPageCount
      )
      drawButtonControl(
        renderer,
        targetRect(layout, "bag:add"),
        "Add",
        false,
        isFocusedVisible(view, "bag:add"),
        view.bagAddEnabled == false,
        "primary",
        false
      )
    end
  end
end

---@param ctx SaveEditorPaintContext
local function paintLocation(ctx)
  if ctx.view.section == "Location" then
    drawLocation(ctx.renderer, ctx.view, ctx.layout)
  end
end

---@param ctx SaveEditorPaintContext
local function paintFooter(ctx)
  local renderer, layout = ctx.renderer, ctx.layout
  local view = ctx.view
  for _, action in ipairs(layout.actions) do
    local rect = targetRect(layout, action.id)
    if rect then
      local label = action.label
      local role = action.id == "save" and "primary"
        or action.id == "discard" and "destructive"
        or action.id == "back" and "back"
        or "secondary"
      drawButtonControl(
        renderer,
        rect,
        label,
        false,
        isFocusedVisible(view, action.id),
        not action.enabled,
        role,
        false
      )
    end
  end
end

---@param ctx SaveEditorPaintContext
local function paintValueEditor(ctx)
  local renderer, graphics, view, layout = ctx.renderer, ctx.graphics, ctx.view, ctx.layout
  local renderLayers, pane = ctx.renderLayers, ctx.pane
  local SELECTED = renderer.skin.cards.normal.selectedRim
  local BORDER = renderer.skin.cards.normal.border
  if view.valueEditor then
    local dialog = view.valueEditor
    local topLayer = renderLayers[#renderLayers]
    if topLayer ~= nil and topLayer.kind == dialog.kind and #renderLayers > 1 then
      graphics.setColor(0, 0, 0, 0.42)
      graphics.rectangle("fill", 0, 0, pane.placement.logicalWidth, pane.placement.logicalHeight)
    end
    for _, surface in ipairs(layout.listSurfaces or {}) do
      graphics.setColor(1, 1, 1, 1)
      graphics.rectangle("fill", surface.x, surface.y, surface.width, surface.height)
    end
    if dialog.kind == "number" then
      local modal = assert(layout.valueModal)
      graphics.setColor(1, 1, 1, 1)
      graphics.rectangle("fill", modal.x, modal.y, modal.width, modal.height)
      local number = layout.numberLayout
      if number == nil then
        local notice = assert(layout.valueModalNotice)
        local noticeText = fitText(renderer, "Expand window to edit this number.", notice.width)
        local noticeWidth = renderer:metrics().measure(noticeText)
        drawText(renderer, noticeText, notice.x + math.floor((notice.width - noticeWidth) / 2), notice.y)
        if layout.targets.cancel ~= nil then
          drawButtonControl(
            renderer,
            targetRect(layout, "cancel"),
            "Back",
            false,
            isFocusedVisible(view, "cancel"),
            false,
            "back",
            false
          )
        end
      else
        graphics.setColor(0.86, 0.88, 0.9, 1)
        graphics.rectangle(
          "fill",
          number.stripRect.x,
          number.stripRect.y,
          number.stripRect.width,
          number.stripRect.height
        )
        for _, column in ipairs(number.columns) do
          local id = "number:place:" .. tostring(column.place)
          local upId, downId = id .. ":up", id .. ":down"
          if column.place == assert(dialog.selectedPlace, "number projection publishes its active place") then
            graphics.setColor(0.98, 0.88, 0.56, 1)
            graphics.rectangle(
              "fill",
              column.digitRect.x,
              column.digitRect.y,
              column.digitRect.width,
              column.digitRect.height
            )
          end
          local upState = view.numberHoldTarget == upId and "pressed" or "normal"
          local downState = view.numberHoldTarget == downId and "pressed" or "normal"
          local upVisual = assert(view.numberControlVisuals.increment[upState])
          local downVisual = assert(view.numberControlVisuals.decrement[downState])
          local upImage =
            assert(renderer._bagImages[upVisual.image], "retail number controls are prepared before drawing")
          local downImage =
            assert(renderer._bagImages[downVisual.image], "retail number controls are prepared before drawing")
          for _, item in ipairs({
            { image = upImage, target = column.upRect, visual = upVisual, targetId = upId },
            { image = downImage, target = column.downRect, visual = downVisual, targetId = downId },
          }) do
            local scale = PixelScale.assertInteger(number.arrowScale)
            assert(item.visual.width == item.target.width and item.visual.height == item.target.height)
            graphics.setColor(1, 1, 1, 1)
            graphics.draw(
              item.image,
              PixelScale.snapLogical(item.target.x + (item.target.width - item.visual.width) / 2),
              PixelScale.snapLogical(item.target.y + (item.target.height - item.visual.height) / 2),
              0,
              scale,
              scale
            )
          end
          if isFocusedVisible(view, upId) or isFocusedVisible(view, downId) then
            drawFocusRing(renderer, column.digitRect, 0)
          end
          local digitWidth = renderer:metrics().measure(column.digit)
          drawText(
            renderer,
            column.digit,
            column.digitRect.x + math.floor((column.digitRect.width - digitWidth) / 2),
            column.digitRect.y
          )
        end
        local failed = view.editorFeedback ~= nil or dialog.valid == false
        if failed then
          local errorRect = assert(layout.valueModalError, "the compact number modal reserves its error line")
          drawText(
            renderer,
            fitText(renderer, view.editorFeedback or "Enter a whole number.", errorRect.width),
            errorRect.x,
            errorRect.y,
            "error"
          )
        end
        drawButtonControl(
          renderer,
          targetRect(layout, "confirm"),
          "Confirm",
          false,
          isFocusedVisible(view, "confirm"),
          false,
          "primary",
          false
        )
        drawButtonControl(
          renderer,
          targetRect(layout, "cancel"),
          "Back",
          false,
          isFocusedVisible(view, "cancel"),
          false,
          "back",
          false
        )
      end
    elseif dialog.kind == "choice" then
      local viewport = assert(layout.viewports["value:choice"])
      LogicalSurface.clip(graphics, viewport.clip, function()
        for index = viewport.firstIndex, viewport.lastIndex do
          local option = dialog.rowAt(index)
          if option ~= nil then
            local rect = targetRect(layout, "choice:" .. option.key)
            if rect then
              local id = "choice:" .. option.key
              drawListRow(
                renderer,
                rect,
                option.label,
                isFocusedVisible(view, id),
                nil,
                layout.rowLabelRects[id],
                nil,
                layout.rowMarkers[id],
                dialog.pending == true
              )
            end
          end
        end
      end)
      if dialog.empty then
        drawBodyText(renderer, "No matching choices.", viewport.clip.x + 3, viewport.clip.y + 3, "hint")
      end
      local actionIds = layout.choiceTooSmall and { "cancel" } or { "confirm", "cancel" }
      for _, id in ipairs(actionIds) do
        local rect = targetRect(layout, id)
        assert(rect)
        local disabled = id == "confirm" and dialog.empty == true
        drawButtonControl(
          renderer,
          rect,
          id == "cancel" and "Back" or "Choose",
          false,
          isFocusedVisible(view, id),
          disabled,
          nil,
          false
        )
      end
    elseif dialog.kind == "name" then
      local naming = dialog.naming
      drawText(renderer, naming.text, layout.content.x + 4, layout.content.y + 3, pagePalette(renderer.skin))
      for row = 1, 6 do
        for column = 1, 13 do
          local id = row .. ":" .. column
          local rect = assert(targetRect(layout, id))
          local cell = naming.grid[row][column]
          setColor(graphics, naming.cursor.row == row and naming.cursor.column == column and SELECTED or BORDER)
          graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
          drawText(renderer, cell.glyph or "", rect.x + 2, rect.y + 2, pagePalette(renderer.skin))
        end
      end
      for _, control in ipairs(naming.controls) do
        local id = "name-control:" .. control.id
        local rect = assert(targetRect(layout, id))
        setColor(graphics, BORDER)
        graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
        drawText(renderer, control.label, rect.x + 2, rect.y + 2, pagePalette(renderer.skin))
      end
      for _, id in ipairs({ "confirm", "cancel" }) do
        local rect = targetRect(layout, id)
        setColor(graphics, BORDER)
        graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
        drawText(renderer, id == "confirm" and "OK" or "Back", rect.x + 3, rect.y + 3, pagePalette(renderer.skin))
      end
    end
  end
end

---@param ctx SaveEditorPaintContext
local function paintNotices(ctx)
  local renderer, layout = ctx.renderer, ctx.layout
  local view = ctx.view
  if view.iconStatus == "pending" then
    drawText(
      renderer,
      "Preparing party icons…",
      layout.content.x + 4,
      layout.content.y + layout.content.height - 16,
      pageMutedPalette(renderer.skin)
    )
  elseif view.iconStatus == "failed" then
    drawText(
      renderer,
      "Icons unavailable",
      layout.content.x + 4,
      layout.content.y + layout.content.height - 16,
      pageErrorPalette(renderer.skin)
    )
  end
end

---@param ctx SaveEditorPaintContext
local function paintDecision(ctx)
  local renderer, layout = ctx.renderer, ctx.layout
  local view = ctx.view
  local INK = renderer.skin.text.normal.foreground
  if view.modal then
    local prompt
    if view.modal == "bag-item" then
      prompt = tostring(view.bagSelectedLabel or view.bagSelectedItem) .. "  × " .. tostring(view.bagSelectedQuantity)
    elseif view.modal == "remove" then
      prompt = "Remove this entry?"
    elseif view.modal == "party-move" then
      prompt = assert(view.modalTitle, "move modal title names the selected move")
    else
      prompt = "Save every section before leaving?"
    end
    local decisionList = assert(layout.decisionList)
    local promptRect = decisionList.prompt
    if decisionList.tooSmall then
      prompt = "Window too small"
    end
    if promptRect.height > 0 then
      drawText(renderer, fitText(renderer, prompt, promptRect.width), promptRect.x, promptRect.y, INK)
    end
    local backIndex = #decisionList.rows
    for index = 1, backIndex - 1 do
      local row = decisionList.rows[index]
      drawButtonControl(
        renderer,
        row.rect,
        row.label,
        false,
        isFocusedVisible(view, row.targetId),
        row.enabled == false,
        row.semantic,
        false
      )
    end
    local back = assert(decisionList.rows[backIndex], "decision modal keeps its final Back action")
    drawButtonControl(
      renderer,
      back.rect,
      back.label,
      false,
      isFocusedVisible(view, back.targetId),
      back.enabled == false,
      back.semantic,
      false
    )
  end
end

---@param ctx SaveEditorPaintContext
local function paintListHints(ctx)
  local renderer, layout = ctx.renderer, ctx.layout
  for _, list in pairs(layout.lists or {}) do
    local hint = list.hintRect
    if hint ~= nil and hint.height > 0 then
      local query = list.query or ""
      local filterText = list.pending and "Filtering…" or query == "" and "Type to filter" or ("Filter: " .. query)
      local hintText = list.breadcrumb and (list.breadcrumb .. "  ·  " .. filterText) or filterText
      drawBodyText(renderer, fitText(renderer, hintText, hint.width), hint.x, hint.y, "hint")
    end
  end
end

---@param ctx SaveEditorPaintContext
local function paintScrollbars(ctx)
  local renderer, graphics, layout = ctx.renderer, ctx.graphics, ctx.layout
  for _, viewport in pairs(layout.viewports or {}) do
    if viewport.contentExtent > viewport.clip.height then
      local clip = viewport.clip
      local trackX = clip.x + clip.width - 2
      graphics.setColor(
        renderer.skin.cards.normal.border[1],
        renderer.skin.cards.normal.border[2],
        renderer.skin.cards.normal.border[3],
        0.35
      )
      graphics.rectangle("fill", trackX, clip.y, 2, clip.height)
      local thumbHeight = math.max(8, math.min(clip.height, clip.height * clip.height / viewport.contentExtent))
      local travel = math.max(0, clip.height - thumbHeight)
      local range = math.max(1, viewport.contentExtent - clip.height)
      local thumbY = clip.y + travel * math.min(1, math.max(0, viewport.offset / range))
      local hintInk = renderer.skin.text.hint.foreground
      graphics.setColor(hintInk.r / 255, hintInk.g / 255, hintInk.b / 255, 1)
      graphics.rectangle("fill", trackX, thumbY, 2, thumbHeight)
      graphics.setColor(1, 1, 1, 1)
    end
  end
end

---@param ctx SaveEditorPaintContext
local function paintFrames(ctx)
  local renderer, graphics, layout = ctx.renderer, ctx.graphics, ctx.layout
  local view = ctx.view
  local frameIndex = view.framePreviewIndex or view.session and view.session.frameIndex
  if frameIndex ~= nil then
    assert(renderer._windowRenderer, "field frame renderer is prepared before Save Editor drawing")
    if layout.valueModal then
      renderer._windowRenderer:drawApplicationFrame(framedContentRect(layout.valueModal), frameIndex)
    end
    if layout.decisionList then
      renderer._windowRenderer:drawApplicationFrame(framedContentRect(layout.decisionList.surface), frameIndex)
    end
    for _, surface in ipairs(layout.listSurfaces or {}) do
      renderer._windowRenderer:drawApplicationFrame(framedContentRect(surface), frameIndex)
    end
  end
  for targetId, markerRect in pairs(layout.rowMarkers or {}) do
    local list = findListForTarget(layout.lists, targetId)
    local focused = view.focus == targetId
    local active = focused and view.focusVisible == true
    local remembered = list ~= nil
      and (list.cursorTarget == targetId or view.listCursors ~= nil and view.listCursors[list.id] == targetId)
    if focused or remembered then
      local target = assert(layout.targets[targetId])
      LogicalSurface.clip(graphics, listRowClip(layout, targetId, target.clip or target.rect), function()
        drawRowMarker(renderer, markerRect, layout.rowMarkerRadii[targetId] or 0, active)
      end)
    end
  end
end

local function paintDecisionLayer(ctx)
  local renderer, graphics, view, layout = ctx.renderer, ctx.graphics, ctx.view, ctx.layout
  local surface = assert(layout.decisionList, "decision layer needs its published surface")
  graphics.setColor(0, 0, 0, 0.42)
  graphics.rectangle("fill", 0, 0, ctx.placement.logicalWidth, ctx.placement.logicalHeight)
  graphics.setColor(1, 1, 1, 1)
  graphics.rectangle("fill", surface.surface.x, surface.surface.y, surface.surface.width, surface.surface.height)
  paintDecision(ctx)
  local frameIndex = view.framePreviewIndex or view.session and view.session.frameIndex
  if frameIndex ~= nil then
    assert(renderer._windowRenderer, "field frame renderer is prepared before Save Editor drawing")
    renderer._windowRenderer:drawApplicationFrame(framedContentRect(surface.surface), frameIndex)
  end
end

local function paintPane(self, view, plan, pane)
  local activeLayout = assert(plan.content.layout)
  local renderLayers = activeLayout.renderLayers or {}
  local ctx = {
    renderer = self,
    graphics = self.graphics,
    view = view,
    layout = activeLayout,
    placement = pane.placement,
    pane = pane,
    renderLayers = renderLayers,
  }
  if #renderLayers > 0 and renderLayers[1].layout ~= nil then
    ctx.view = renderLayers[1].view or view
    ctx.layout = renderLayers[1].layout
    ctx.renderLayers = ctx.layout.renderLayers or {}
  end
  paintBackground(ctx)
  paintNavigation(ctx)
  paintRows(ctx)
  paintParty(ctx)
  paintBag(ctx)
  paintLocation(ctx)
  paintFooter(ctx)
  paintNotices(ctx)
  paintListHints(ctx)
  paintScrollbars(ctx)
  paintFrames(ctx)
  for index = 2, #renderLayers do
    local layer = renderLayers[index]
    local layerView = layer.view or view
    if index == #renderLayers then
      layerView.focus = view.focus
      layerView.focusVisible = view.focusVisible
      layerView.capturedTarget = view.capturedTarget
      layerView.listCursors = view.listCursors
    end
    local layerLayout = layer.layout or activeLayout
    local layerCtx = {
      renderer = self,
      graphics = self.graphics,
      view = layerView,
      layout = layerLayout,
      placement = pane.placement,
      pane = pane,
      renderLayers = layerLayout.renderLayers or renderLayers,
    }
    if layerView.modal ~= nil then
      paintDecisionLayer(layerCtx)
    elseif layerView.valueEditor ~= nil then
      paintValueEditor(layerCtx)
      paintListHints(layerCtx)
      paintScrollbars(layerCtx)
      paintFrames(layerCtx)
    end
  end
end

drawLocation = function(self, view, layout)
  local graphics = self.graphics
  local BORDER = self.skin.cards.normal.border
  local location = assert(view.location)
  local navigation = assert(view.locationNavigation)
  local grid = layout.locationGrid
  local tiles = {}
  for _, tile in ipairs(location.tiles or {}) do
    tiles[string.format("%d:%d", tile.fieldX, tile.fieldZ)] = tile
  end
  if layout.locationHeader then
    local header = assert(layout.locationHeader, "Location grid needs its measured header")
    local ink = textPalette(self.skin, { r = 0, g = 0, b = 0 })
    drawText(
      self,
      fitText(self, header.mapNameText, header.mapNameRect.width),
      header.mapNameRect.x,
      header.mapNameRect.y,
      ink
    )
    drawText(
      self,
      fitText(self, header.coordinatesText, header.coordinatesRect.width),
      header.coordinatesRect.x,
      header.coordinatesRect.y,
      ink
    )
    if header.rightText ~= nil and header.rightRect.width > 0 then
      local fitted = fitText(self, header.rightText, header.rightRect.width)
      local rightWidth = self.text:textWidth(fitted)
      drawText(self, fitted, header.rightRect.x + header.rightRect.width - rightWidth, header.rightRect.y, ink)
    end
  end

  if grid then
    local clip = grid.clip
    setColor(graphics, { 168 / 255, 168 / 255, 168 / 255, 1 })
    graphics.rectangle("fill", clip.x, clip.y, clip.width, clip.height)
    local saved = view.savedLocation
    local pending = view.pendingLocation
    for row = 0, grid.rows - 1 do
      for column = 0, grid.columns - 1 do
        local fieldX = grid.firstFieldX + column
        local fieldZ = grid.firstFieldZ + row
        local key = string.format("%d:%d", fieldX, fieldZ)
        local tile = tiles[key]
        local x = grid.originX + column * grid.tileSize
        local y = grid.originY + row * grid.tileSize
        LogicalSurface.clip(graphics, { x = x, y = y, width = grid.tileSize, height = grid.tileSize }, function()
          if tile == nil or tile.state == "pending" then
            return
          end
          if tile and tile.selectable == true then
            setColor(graphics, { 0.75, 0.87, 0.7, 1 })
            graphics.rectangle("fill", x, y, grid.tileSize, grid.tileSize)
            setColor(graphics, { 0.46, 0.62, 0.42, 1 })
            for offset = -grid.tileSize, grid.tileSize * 2, 8 do
              graphics.line(x + offset, y, x + offset - grid.tileSize, y + grid.tileSize)
            end
          elseif tile and tile.selectable == false then
            setColor(graphics, { 0.73, 0.75, 0.75, 1 })
            graphics.rectangle("fill", x, y, grid.tileSize, grid.tileSize)
            setColor(graphics, { 0.38, 0.42, 0.44, 1 })
            graphics.line(x + 3, y + 3, x + grid.tileSize - 3, y + grid.tileSize - 3)
            graphics.line(x + grid.tileSize - 3, y + 3, x + 3, y + grid.tileSize - 3)
          end
          setColor(graphics, BORDER)
          graphics.rectangle("line", x, y, grid.tileSize, grid.tileSize)
          if saved and saved.mapId == location.mapId and fieldX == saved.fieldX and fieldZ == saved.fieldZ then
            setColor(graphics, { 0.16, 0.38, 0.72, 1 })
            graphics.rectangle("line", x + 2, y + 2, grid.tileSize - 4, grid.tileSize - 4)
          end
          if pending and pending.mapId == location.mapId and fieldX == pending.fieldX and fieldZ == pending.fieldZ then
            setColor(graphics, { 0.83, 0.23, 0.18, 1 })
            graphics.rectangle("line", x + 4, y + 4, grid.tileSize - 8, grid.tileSize - 8)
          end
          local cursor = navigation.cursor
          if cursor and fieldX == cursor.fieldX and fieldZ == cursor.fieldZ then
            setColor(graphics, { 0.12, 0.18, 0.25, 1 })
            graphics.rectangle("line", x + 1, y + 1, grid.tileSize - 2, grid.tileSize - 2)
          end
        end)
      end
    end
  end

  if layout.locationFocusCue and navigation.contentFocus == "grid" then
    local cue = layout.locationFocusCue
    setColor(graphics, { 0.86, 0.16, 0.18, 1 })
    graphics.rectangle("line", cue.x, cue.y, cue.width, cue.height)
  end
end

local drawWrappedContextStatus

local function paintLocationContext(self, view, pane)
  local graphics = self.graphics
  local location = assert(view.location)
  setColor(graphics, self.skin.background)
  graphics.rectangle("fill", 0, 0, pane.placement.logicalWidth, pane.placement.logicalHeight)
  drawText(self, "Location context", 8, 8, pagePalette(self.skin))
  drawText(
    self,
    fitText(
      self,
      location.map and (location.map.symbol:gsub("^MAP_", "", 1)) or tostring(location.mapId),
      pane.placement.logicalWidth - 16
    ),
    8,
    28,
    pagePalette(self.skin)
  )
  local current = view.savedLocation
  if current then
    drawText(self, string.format("Current %d, %d", current.fieldX, current.fieldZ), 8, 46, pagePalette(self.skin))
  elseif view.session then
    drawText(
      self,
      fitText(self, view.session.playerName .. " · " .. view.session.versionId, pane.placement.logicalWidth - 16),
      8,
      46,
      pagePalette(self.skin)
    )
  end
  local status = location.status
  local statusPalette = status.state == "failed" and pageErrorPalette(self.skin) or pageMutedPalette(self.skin)
  drawWrappedContextStatus(
    self,
    status.state == "ready" and "Map ready" or status.reason or "Preparing map data",
    pane,
    statusPalette
  )
end

drawWrappedContextStatus = function(self, value, pane, palette)
  local text = assert(self.text)
  local lineHeight = assert(text.fontDef.lineHeight)
  local width = pane.placement.logicalWidth - 16
  local maxLines = math.floor((pane.placement.logicalHeight - 8 - 64) / lineHeight)
  if maxLines <= 0 or width <= 0 then
    return
  end

  local lines = {}
  local line = ""
  local truncated = false
  local function pushLine()
    if line ~= "" then
      lines[#lines + 1] = line
      line = ""
    end
  end
  local function fits(candidate)
    return text:textWidth(candidate) <= width
  end

  for token in value:gmatch("%S+") do
    local candidate = line == "" and token or line .. " " .. token
    if fits(candidate) then
      line = candidate
    else
      pushLine()
      if #lines >= maxLines then
        truncated = true
        break
      end

      local tokenLine = ""
      for glyph in Utf8Glyphs.iter(token) do
        local glyphCandidate = tokenLine .. glyph
        if fits(glyphCandidate) then
          tokenLine = glyphCandidate
        else
          if tokenLine == "" then
            truncated = true
            break
          end
          lines[#lines + 1] = tokenLine
          tokenLine = glyph
          if #lines >= maxLines then
            truncated = true
            break
          end
        end
      end
      if truncated then
        break
      end
      line = tokenLine
    end
  end

  if not truncated and line ~= "" then
    if #lines < maxLines then
      lines[#lines + 1] = line
    else
      truncated = true
    end
  end

  if truncated and #lines > 0 then
    lines[#lines] = fitText(self, lines[#lines] .. "…", width)
  end
  for index, wrappedLine in ipairs(lines) do
    drawText(self, wrappedLine, 8, 64 + (index - 1) * lineHeight, palette)
  end
end

function Renderer:draw(view, plan)
  assert(not self._disposed, "disposed save editor renderer cannot draw")
  local pending = self._pendingIconPreparation
  if pending ~= nil then
    self._pendingIconPreparation = nil
    self:prepareVisibleIcons(view, plan, pending.cacheFs, pending.derivedAssets)
  end
  local graphics = self.graphics
  for _, background in ipairs(plan.hostBackgrounds or {}) do
    setColor(graphics, self.skin.background)
    graphics.rectangle("fill", background.x, background.y, background.width, background.height)
  end
  for _, pane in ipairs(plan.panes) do
    if pane.interactive then
      LogicalSurface.draw(graphics, pane.placement, function()
        paintPane(self, view, plan, pane)
      end)
    else
      LogicalSurface.draw(graphics, pane.placement, function()
        if view.section == "Location" then
          paintLocationContext(self, view, pane)
        else
          setColor(graphics, self.skin.background)
          graphics.rectangle("fill", 0, 0, pane.placement.logicalWidth, pane.placement.logicalHeight)
          drawText(
            self,
            view.session and (view.session.playerName .. " · " .. view.session.versionId) or "Save context",
            8,
            8,
            pagePalette(self.skin)
          )
        end
      end)
    end
  end
end

function Renderer:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._pendingIconPreparation = nil
  if self._windowRenderer then
    self._windowRenderer:release()
    self._windowRenderer = nil
  end
  if self._iconProvider then
    self._iconProvider:release()
    self._iconProvider = nil
  end
  if self._itemIconProvider then
    self._itemIconProvider:release()
    self._itemIconProvider = nil
  end
  for _, image in pairs(self._bagImages) do
    if image.release then
      image:release()
    end
  end
  self._bagImages = {}
  if self._iconQueue then
    self._iconQueue:release()
    self._iconQueue = nil
  end
  self._icons = {}
  if self.text and self.text.release then
    self.text:release()
  end
  self.text = nil
end

return Renderer
