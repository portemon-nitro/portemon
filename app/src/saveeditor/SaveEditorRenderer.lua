-- Draws the app-native editor shell from its resolved view and plan.

local Renderer = {}
Renderer.__index = Renderer

local AssetPreparationQueue = require("libs.hgss.src.presentation.AssetPreparationQueue")
local Errors = require("libs.errors.src.Errors")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
local ItemIconAssetProvider = require("libs.hgss.src.presentation.ItemIconAssetProvider")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local TextButton = require("libs.ui.src.TextButton")
local FieldWindowRenderer = require("libs.hgss.src.ui.FieldWindowRenderer")
local ProductMenuSkin = require("app.src.ui.ProductMenuSkin")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")

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
---@field _bagQuads table<string, table<integer, love.Quad>>
---@field _partyImages table<string, love.Image>
---@field iconStatus string?
---@field iconFailure string?
---@field metrics fun(self: SaveEditorRenderer): { lineHeight: number, measure: fun(value: string): number }
---@field dispose fun(self: SaveEditorRenderer)
---@field preparePresentationAssets fun(self: SaveEditorRenderer, cacheFs: table<string, unknown>, manifest: table<string, unknown>)
---@field prepareVisibleIcons fun(self: SaveEditorRenderer, view: table<string, unknown>, plan: table<string, unknown>, cacheFs: table<string, unknown>, derivedAssets: table<string, unknown>)

local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
local Button = require("libs.ui.src.Button")

local BODY_TEXT_SCALE = 0.75

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
  primary = {
    border = { 0.12, 0.34, 0.18, 1 },
    rim = { 0.77, 0.92, 0.75, 1 },
    faceTop = { 0.56, 0.82, 0.48, 1 },
    faceBottom = { 0.34, 0.66, 0.3, 1 },
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
    _bagQuads = {},
    _partyImages = {},
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

function Renderer:prepareVisibleIcons(view, plan, cacheFs, derivedAssets)
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
    if view.bagBrowseBackground ~= nil then
      local background = assert(view.bagBrowseBackground)
      if self._bagImages[background.image] == nil then
        local bytes = assert(cacheFs:read(background.image), "Bag browse background bytes are required")
        local image = self.graphics.newImage(love.filesystem.newFileData(bytes, background.image))
        image:setFilter("nearest", "nearest")
        self._bagImages[background.image] = image
      end
      local browse = assert(self._bagImages[background.image])
      local imageWidth, imageHeight = browse:getDimensions()
      local quads = self._bagQuads[background.image]
      if quads == nil then
        quads = {}
        self._bagQuads[background.image] = quads
      end
      for index, slot in ipairs(assert(view.bagItemSlots, "Bag slot geometry accompanies its background")) do
        local slotRect = assert(slot.rect or slot)
        assert(
          slotRect.x >= 0
            and slotRect.y >= 0
            and slotRect.width > 0
            and slotRect.height > 0
            and slotRect.x + slotRect.width <= imageWidth
            and slotRect.y + slotRect.height <= imageHeight,
          "Bag slot crops stay within their browse background"
        )
        if quads[index] == nil then
          quads[index] =
            self.graphics.newQuad(slotRect.x, slotRect.y, slotRect.width, slotRect.height, imageWidth, imageHeight)
        end
      end
    end
    if self._itemIconProvider == nil then
      self._itemIconProvider = ItemIconAssetProvider.new(cacheFs, { graphics = self.graphics })
    end
    local paths = { assert(view.bagPocketStrip).image }
    paths[#paths + 1] = assert(view.bagItemFocusVisual).image
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
  if view.section ~= "Party" then
    self.iconStatus, self.iconFailure = nil, nil
    return
  end
  for _, card in ipairs(view.partyCards or {}) do
    if card.kind == "member" and card.chrome ~= nil then
      for _, variant in ipairs({ "normal", "selected", "fainted", "selectedFainted" }) do
        local path = assert(card.chrome[variant], "Party panels carry their focus chrome variant").image
        if self._partyImages[path] == nil then
          local bytes = assert(cacheFs:read(path), "Party panel chrome bytes are required")
          local image = self.graphics.newImage(love.filesystem.newFileData(bytes, path))
          image:setFilter("nearest", "nearest")
          self._partyImages[path] = image
        end
      end
    end
  end
  local iconKeys = {}
  for _, row in ipairs(assert(plan.content.layout).rows) do
    if row.iconKey ~= nil then
      iconKeys[#iconKeys + 1] = row.iconKey
    end
  end
  for _, card in ipairs(assert(plan.content.layout).partyGrid or {}) do
    if card.iconKey ~= nil then
      iconKeys[#iconKeys + 1] = card.iconKey
    end
  end
  local summary = plan.content.layout.partySummary
  if summary ~= nil and view.partySummary and view.partySummary.iconKey ~= nil then
    iconKeys[#iconKeys + 1] = view.partySummary.iconKey
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

local function visibleText(renderer, value)
  local text = tostring(value or "")
  if not text:find("{", 1, true) then
    return text
  end
  local tokens, parseError = FieldMessageText.parse(text, renderer.text.fontDef)
  if parseError ~= nil then
    error(parseError, 0)
  end
  local glyphs = {}
  for _, token in ipairs(assert(tokens)) do
    if token.kind == "glyph" then
      glyphs[#glyphs + 1] = token.text
    elseif token.kind == "line_break" or token.kind == "prompt_break" then
      glyphs[#glyphs + 1] = " "
    end
  end
  return table.concat(glyphs)
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
  return textPalette(skin, { r = 0, g = 0, b = 0 })
end

local function isFocusedVisible(view, targetId)
  return targetId == view.focus and view.focusVisible == true
end

local function actionSemantic(targetId)
  if targetId == "party:edit" or targetId == "party:apply" or targetId == "party:move:add" then
    return "primary"
  elseif
    targetId == "party:remove"
    or targetId == "party:discard"
    or targetId == "party:clear-nickname"
    or targetId:match("^party:move:remove:") ~= nil
  then
    return "destructive"
  elseif targetId == "party:back" or targetId == "party:cancel" then
    return "secondary"
  end
  return "navigation"
end

local function drawText(renderer, value, x, y, role)
  local textRole = role == "error" and "error"
    or role == "information" and "information"
    or role == "hint" and "hint"
    or "normal"
  local skin = renderer.skin
  if type(role) == "table" then
    if role.foreground ~= nil and role.shadow ~= nil then
      renderer.graphics.setColor(1, 1, 1, 1)
      renderer.text:drawTextWithPalette(visibleText(renderer, value), x, y, role)
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
    renderer.text:drawTextWithPalette(visibleText(renderer, value), x, y, palette)
    renderer.graphics.setColor(1, 1, 1, 1)
    return
  end
  ProductMenuSkin.drawText(renderer.graphics, renderer.text, skin, textRole, visibleText(renderer, value), x, y)
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

local function optionRole(disabled, semantic, option, active)
  if disabled then
    return "disabled"
  end
  if option and not active then
    return "inactive"
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

local function drawShadedControl(renderer, rect, label, active, focused, disabled, semantic, option)
  local role = optionRole(disabled, semantic, option, active)
  local colors = assert(BUTTON_COLORS[role], "unknown save editor button role: " .. tostring(role))
  local labelPalette = optionLabelPalette(renderer, disabled, option, active)
  local button = TextButton.resolve({ rect = rect, scale = 1 })
  TextButton.draw(renderer.graphics, button, {
    label = label,
    selected = false,
    colors = colors,
    text = {
      lineHeight = renderer.text.fontDef.lineHeight,
      measure = function(value)
        return renderer.text:textWidth(value)
      end,
      draw = function(value, x, y)
        drawText(renderer, value, x, y, labelPalette)
      end,
    },
  })
  if focused then
    local border = assert(button.border, "resolved text button border is missing")
    drawFocusRing(renderer, rect, math.max(0, assert(border.cornerRadius, "text button corner radius is missing") - 1))
  end
  return button.contentRect
end

local fitText

local function drawBodyText(renderer, value, x, y, role)
  local graphics = renderer.graphics
  graphics.push("all")
  graphics.translate(math.floor(x + 0.5), math.floor(y + 0.5))
  graphics.scale(BODY_TEXT_SCALE, BODY_TEXT_SCALE)
  drawText(renderer, value, 0, 0, role)
  graphics.pop()
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
  drawText(
    renderer,
    fitted,
    content.x + (content.width - renderer.text:textWidth(fitted)) / 2,
    content.y + (content.height - renderer.text.fontDef.lineHeight) / 2,
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
  local fitted = fitText(renderer, label, rectValue.width - 16)
  if rectValue.height >= lineHeight + 32 + 1 then
    return drawShadedControl(renderer, rectValue, fitted, active, focused, disabled, semantic, option)
  end
  return drawCompactControl(renderer, rectValue, fitted, active, focused, disabled, semantic, option)
end

local function drawListRow(renderer, rectValue, label, focused, value, labelRect, valueRect)
  local labelBounds = labelRect or { x = rectValue.x + 6, y = rectValue.y + 3, width = rectValue.width - 12 }
  local labelY = labelBounds.y or rectValue.y + 3
  drawBodyText(renderer, fitText(renderer, label, labelBounds.width / BODY_TEXT_SCALE), labelBounds.x, labelY)
  if value ~= nil then
    local valueText = tostring(value)
    local bounds = valueRect or { x = rectValue.x, y = rectValue.y + 3, width = rectValue.width * 0.35 }
    local fitted = fitText(renderer, valueText, bounds.width / BODY_TEXT_SCALE)
    local fittedWidth = renderer.text:textWidth(fitted) * BODY_TEXT_SCALE
    local x = valueRect and bounds.x or rectValue.x + rectValue.width - fittedWidth - 6
    drawBodyText(renderer, fitted, x, bounds.y or rectValue.y + 3, "hint")
  end
  if focused then
    drawFocusRing(renderer, rectValue, 0)
  end
end

fitText = function(renderer, value, width)
  local text = visibleText(renderer, value)
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

local function overflowsWithEllipsis(line)
  return line:sub(-3) == "…"
end

local function foldOverflowIntoSecondLine(renderer, lines, words, index, width)
  local remainder = table.concat(words, " ", index)
  lines[2] = fitText(renderer, lines[2] .. " " .. remainder, width)
end

local function descriptionLines(renderer, description, width)
  local words = {}
  for word in description:gmatch("%S+") do
    words[#words + 1] = word
  end
  local lines, current, index = {}, "", 1
  while index <= #words do
    local word = words[index]
    local candidate = current == "" and word or (current .. " " .. word)
    if renderer.text:textWidth(candidate) <= width then
      current = candidate
      index = index + 1
    elseif current == "" then
      local fitted = fitText(renderer, word, width)
      lines[#lines + 1] = fitted
      current = ""
      index = index + 1
      if #lines == 2 then
        if index <= #words and not overflowsWithEllipsis(lines[2]) then
          foldOverflowIntoSecondLine(renderer, lines, words, index, width)
        end
        return lines
      end
    else
      lines[#lines + 1] = current
      current = ""
      if #lines == 2 then
        foldOverflowIntoSecondLine(renderer, lines, words, index, width)
        return lines
      end
    end
  end
  if current ~= "" then
    if #lines < 2 then
      lines[#lines + 1] = current
    else
      lines[2] = fitText(renderer, lines[2] .. " " .. current, width)
    end
  end
  return lines
end

local function drawBagCard(renderer, card, slotIndex, focused, view, focusVisual)
  local graphics = renderer.graphics
  local bounds = card.rect
  local background = view.bagBrowseBackground
  local slots = view.bagItemSlots
  if background ~= nil and slots ~= nil then
    local slot = slots[slotIndex]
    local slotRect = slot ~= nil and (slot.rect or slot) or nil
    local image = renderer._bagImages[background.image or ""]
    if image ~= nil and slotRect ~= nil then
      local imageWidth, imageHeight = image:getDimensions()
      assert(
        slotRect.x >= 0
          and slotRect.y >= 0
          and slotRect.width > 0
          and slotRect.height > 0
          and slotRect.x + slotRect.width <= imageWidth
          and slotRect.y + slotRect.height <= imageHeight,
        "Bag slot crops stay within their browse background"
      )
      local quads = renderer._bagQuads[background.image]
      if quads == nil then
        quads = {}
        renderer._bagQuads[background.image] = quads
      end
      local quad = quads[slotIndex]
      if quad == nil then
        quad = graphics.newQuad(slotRect.x, slotRect.y, slotRect.width, slotRect.height, imageWidth, imageHeight)
        quads[slotIndex] = quad
      end
      graphics.setColor(1, 1, 1, 1)
      graphics.draw(image, quad, bounds.x, bounds.y, 0, bounds.width / slotRect.width, bounds.height / slotRect.height)
    end
  end
  if focused and focusVisual ~= nil then
    local descriptor = assert(focusVisual)
    local visual = assert(renderer._bagImages[descriptor.image])
    local offset = descriptor.offset or { x = 0, y = 0 }
    graphics.setColor(1, 1, 1, 1)
    graphics.draw(visual, bounds.x + bounds.width / 2 + offset.x, bounds.y + bounds.height / 2 + offset.y)
  end
  local icon = card.iconKey and renderer._icons[card.iconKey]
  if icon then
    drawCenteredIcon(renderer, icon, card.iconRect)
  end
  local text = card.textRect
  local scale = card.textScale or 1
  local lineHeight = renderer.text.fontDef.lineHeight
  graphics.push("all")
  graphics.translate(math.floor(bounds.x + 0.5), math.floor(bounds.y + 0.5))
  graphics.scale(scale, scale)
  local textX, textY = (text.x - bounds.x) / scale, (text.y - bounds.y) / scale
  local textWidth = text.width / scale
  drawText(renderer, fitText(renderer, card.label, textWidth), textX, textY)
  local lines = descriptionLines(renderer, card.description or "", textWidth)
  for lineIndex, line in ipairs(lines) do
    drawText(renderer, line, textX, textY + lineHeight * lineIndex, "hint")
  end
  local quantity = "x" .. tostring(card.value)
  local quantityWidth = renderer.text:textWidth(quantity)
  drawText(
    renderer,
    quantity,
    textX + math.max(0, textWidth - quantityWidth),
    bounds.height / scale - lineHeight - 3,
    "hint"
  )
  graphics.pop()
  if focused then
    drawFocusRing(
      renderer,
      bounds,
      math.max(0, assert(button.border.cornerRadius, "bag button corner radius is missing") - 1)
    )
  end
end

local function drawBagPageArrow(renderer, target, visuals, angle, focused, pressed, disabled)
  local visual = (pressed == true and not disabled) and visuals.pressed or visuals.normal
  local image = assert(renderer._bagImages[assert(visual.image)])
  local width, height = image:getDimensions()
  if disabled then
    renderer.graphics.setColor(1, 1, 1, 0.35)
  else
    renderer.graphics.setColor(1, 1, 1, 1)
  end
  renderer.graphics.draw(
    image,
    target.x + target.width / 2,
    target.y + target.height / 2,
    angle,
    1,
    1,
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
  local scale = math.min(1, bounds.width / dimensions.width, bounds.height / dimensions.height)
  local width, height = dimensions.width * scale, dimensions.height * scale
  renderer.graphics.setColor(1, 1, 1, 1)
  if icon.quad ~= nil then
    renderer.graphics.draw(
      icon.image,
      icon.quad,
      bounds.x + (bounds.width - width) / 2,
      bounds.y + (bounds.height - height) / 2,
      0,
      scale,
      scale
    )
  else
    renderer.graphics.draw(
      icon.image,
      bounds.x + (bounds.width - width) / 2,
      bounds.y + (bounds.height - height) / 2,
      0,
      scale,
      scale
    )
  end
end

local function drawGridCard(renderer, card, focused)
  if card.kind == "member" then
    local chrome = card.chrome
    if chrome ~= nil then
      local variant = card.fainted == true and (focused and "selectedFainted" or "fainted")
        or (focused and "selected" or "normal")
      local descriptor = assert(chrome[variant], "Party member panels carry their focus chrome variant")
      local image =
        assert(renderer._partyImages[assert(descriptor.image)], "Party panel chrome is prepared before drawing")
      local imageWidth, imageHeight = image:getDimensions()
      renderer.graphics.setColor(1, 1, 1, 1)
      renderer.graphics.draw(
        image,
        card.rect.x,
        card.rect.y,
        0,
        card.rect.width / imageWidth,
        card.rect.height / imageHeight
      )
    end
    local icon = card.iconKey and renderer._icons[card.iconKey]
    if icon then
      drawCenteredIcon(renderer, icon, card.iconRect)
    end
    local graphics = renderer.graphics
    local lineHeight = renderer.text.fontDef.lineHeight
    graphics.push("all")
    graphics.translate(math.floor(card.textRect.x + 0.5), math.floor(card.textRect.y + 0.5))
    graphics.scale(BODY_TEXT_SCALE, BODY_TEXT_SCALE)
    local textWidth = card.textRect.width / BODY_TEXT_SCALE
    drawText(renderer, fitText(renderer, card.label, textWidth), 0, 0)
    if card.value ~= nil then
      drawText(renderer, fitText(renderer, card.value, textWidth), 0, lineHeight, "hint")
    end
    graphics.pop()
  else
    drawButtonControl(renderer, card.rect, "+ Add", false, focused, false, "primary", false)
  end
end

local drawLocation

local function paintPane(self, view, plan, pane)
  local graphics = self.graphics
  local layout = assert(plan.content.layout)
  local placement = pane.placement
  local INK = self.skin.text.normal.foreground
  local BORDER = self.skin.cards.normal.border
  local SELECTED = self.skin.cards.normal.selectedRim
  setColor(graphics, self.skin.background)
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
  local frameIndex = view.framePreviewIndex or view.session and view.session.frameIndex
  for _, navigation in ipairs(layout.navigation) do
    local target = targetRect(layout, navigation.targetId)
    if target then
      local label = navigation.label
      if navigation.targetId:match("^location:map:") then
        label = fitText(self, label, target.width - 22)
      end
      if navigation.role == "list" then
        drawListRow(self, target, label, isFocusedVisible(view, navigation.targetId))
      else
        drawButtonControl(
          self,
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
  if view.section == "Party" and (view.partyPage == "detail" or view.partyPage == "draft") then
    for _, subpage in ipairs(view.partySubpages or {}) do
      local id = "party:subpage:" .. subpage
      local target = targetRect(layout, id)
      if target then
        drawButtonControl(
          self,
          target,
          subpage,
          view.partySubpage == subpage,
          isFocusedVisible(view, id),
          false,
          nil,
          true
        )
      end
    end
  end
  for _, row in ipairs(layout.rows) do
    local rect = targetRect(layout, row.targetId)
    if rect and not row.gridCard and not row.partyField then
      local target = assert(layout.targets[row.targetId])
      LogicalSurface.clip(graphics, target.clip or rect, function()
        if row.listSurface then
          drawListRow(
            self,
            rect,
            row.displayName or row.label,
            isFocusedVisible(view, row.targetId),
            row.valueText or row.value,
            row.labelRect,
            row.valueRect
          )
          return
        end
        if row.role == "toggle" or row.role == "integer value" or row.role == "named choice" then
          drawListRow(
            self,
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
            self,
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
        local icon = row.iconKey and self._icons[row.iconKey]
        if icon and graphics.draw then
          graphics.setColor(1, 1, 1, 1)
          graphics.draw(icon.image, icon.quad, rect.x + 3, rect.y + 2)
        end
        local labelRect = assert(row.labelRect, "layout rows own their label text bounds")
        local labelRole = row.role == "warning" and "error" or row.role == "read-only value" and "hint" or nil
        drawBodyText(
          self,
          fitText(self, row.displayName or row.label, labelRect.width / BODY_TEXT_SCALE),
          labelRect.x,
          rect.y + 3,
          labelRole
        )
        if row.valueText ~= nil and row.valueRect ~= nil then
          local valueRect = row.valueRect
          drawBodyText(
            self,
            fitText(self, row.valueText, valueRect.width / BODY_TEXT_SCALE),
            valueRect.x,
            rect.y + 3,
            "hint"
          )
        end
      end)
    end
  end
  if view.section == "Party" and layout.partyGrid ~= nil then
    local viewCards = {}
    for _, viewCard in ipairs(view.partyCards or {}) do
      viewCards[viewCard.kind == "member" and ("party:slot:" .. viewCard.slot0) or "party:add"] = viewCard
    end
    for _, card in ipairs(layout.partyGrid) do
      local cardRow
      for _, row in ipairs(layout.rows) do
        if row.targetId == card.targetId then
          cardRow = row
          break
        end
      end
      local viewCard = viewCards[card.targetId]
      local chrome, fainted = card.chrome, card.fainted
      if viewCard ~= nil then
        chrome, fainted = viewCard.chrome, viewCard.fainted
      end
      drawGridCard(self, {
        kind = card.kind,
        targetId = card.targetId,
        label = card.label,
        value = card.value,
        iconKey = cardRow and cardRow.iconKey or card.iconKey,
        rect = card.rect,
        iconRect = cardRow and cardRow.iconRect or card.iconRect,
        textRect = cardRow and cardRow.labelRect or card.textRect,
        textScale = card.textScale,
        fainted = fainted,
        chrome = chrome,
      }, isFocusedVisible(view, card.targetId))
    end
  end
  if view.section == "Bag" then
    local strip = assert(layout.bagStripTarget)
    local stripImage = self._bagImages[assert(view.bagPocketStrip).image]
    assert(stripImage, "selected Bag pocket strip was prepared before drawing")
    graphics.setColor(1, 1, 1, 1)
    graphics.draw(stripImage, strip.x, strip.y)
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
        local image = assert(self._bagImages[descriptor.image])
        local offset = descriptor.offset or { x = 0, y = 0 }
        graphics.setColor(1, 1, 1, 1)
        graphics.draw(image, strip.x + point.x + offset.x, strip.y + point.y + offset.y)
      end
    end
    for index, card in ipairs(layout.bagGrid or {}) do
      drawBagCard(self, card, index, isFocusedVisible(view, card.targetId), view, view.bagItemFocusVisual)
    end
    if targetRect(layout, "bag:add") then
      drawBagPageArrow(
        self,
        targetRect(layout, "bag:page:previous"),
        view.bagQuantityVisuals.decrement,
        math.pi / 2,
        isFocusedVisible(view, "bag:page:previous"),
        view.capturedTarget == "bag:page:previous",
        view.bagPage0 == 0
      )
      local pageText = tostring(layout.bagPage.index) .. " / " .. tostring(layout.bagPage.count)
      drawText(
        self,
        pageText,
        layout.bagPageText.x + math.max(0, (layout.bagPageText.width - self.text:textWidth(pageText)) / 2),
        layout.bagPageText.y,
        pageMutedPalette(self.skin)
      )
      drawBagPageArrow(
        self,
        targetRect(layout, "bag:page:next"),
        view.bagQuantityVisuals.increment,
        -- Next uses the up/increment source arrow rotated clockwise to point right.
        math.pi / 2,
        isFocusedVisible(view, "bag:page:next"),
        view.capturedTarget == "bag:page:next",
        view.bagPage0 + 1 >= view.bagPageCount
      )
      drawButtonControl(
        self,
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
  if view.section == "Party" and layout.partySummary ~= nil and view.partySummary ~= nil then
    local summary = assert(view.partySummary)
    local icon = summary.iconKey and self._icons[summary.iconKey]
    if icon then
      drawCenteredIcon(self, icon, layout.partySummary.iconRect)
    end
    local textRect = layout.partySummary.textRect
    if layout.partySummary.inline then
      local identity = summary.species .. "  Lv. " .. tostring(summary.level)
      drawText(self, fitText(self, identity, textRect.width), textRect.x, textRect.y + 1, pagePalette(self.skin))
    else
      drawText(self, fitText(self, summary.label, textRect.width), textRect.x, textRect.y, pagePalette(self.skin))
      drawText(
        self,
        fitText(self, summary.species .. "  Lv. " .. tostring(summary.level), textRect.width),
        textRect.x,
        textRect.y + self.text.fontDef.lineHeight,
        pageMutedPalette(self.skin)
      )
    end
  end
  if view.section == "Party" then
    for _, row in ipairs(layout.rows) do
      if row.partyField then
        local y = row.layoutRect.y + 3
        local fieldRole = row.role == "warning" and "error" or nil
        drawBodyText(
          self,
          fitText(self, row.label, row.labelRect.width / BODY_TEXT_SCALE),
          row.labelRect.x,
          y,
          fieldRole
        )
        if row.editable then
          drawButtonControl(
            self,
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
            self,
            row.layoutRect,
            row.label,
            false,
            isFocusedVisible(view, row.targetId),
            row.enabled == false,
            row.semantic or actionSemantic(row.targetId),
            false
          )
        elseif row.valueText ~= nil then
          drawBodyText(
            self,
            fitText(self, row.valueText, row.valueRect.width / BODY_TEXT_SCALE),
            row.valueRect.x,
            y,
            "hint"
          )
        end
      end
    end
    if layout.partyHelp then
      drawBodyText(
        self,
        fitText(self, layout.partyHelp.text, layout.partyHelp.rect.width / BODY_TEXT_SCALE),
        layout.partyHelp.rect.x,
        layout.partyHelp.rect.y,
        "hint"
      )
    end
    if layout.partyStatsTable ~= nil then
      local stats = layout.partyStatsTable
      local headerColor = self.skin.cards.normal.border
      local function drawCellText(text, target, role)
        local lineHeight = self.text.fontDef.lineHeight
        local scale = math.min(1, target.height / lineHeight)
        graphics.push("all")
        graphics.translate(target.x + 4, target.y + math.max(0, (target.height - lineHeight * scale) / 2))
        graphics.scale(scale, scale)
        local palette = role == "hint" and pageMutedPalette(self.skin)
          or role == "error" and pageErrorPalette(self.skin)
          or pagePalette(self.skin)
        drawText(self, fitText(self, text, (target.width - 8) / scale), 0, 0, palette)
        graphics.pop()
      end
      for _, header in ipairs(stats.headers) do
        setColor(graphics, headerColor)
        graphics.rectangle("fill", header.rect.x, header.rect.y, header.rect.width, header.rect.height)
        drawCellText(header.label, header.rect)
      end
      for _, row in ipairs(stats.rows) do
        for index, cell in ipairs(row.cells) do
          local cellRect = cell.rect
          if isFocusedVisible(view, cell.targetId) then
            setColor(graphics, SELECTED)
            graphics.rectangle("line", cellRect.x + 1, cellRect.y + 1, cellRect.width - 2, cellRect.height - 2)
          end
          drawCellText(cell.label, cellRect, index == 4 and "hint" or "normal")
        end
      end
      for _, fact in ipairs(stats.facts) do
        if isFocusedVisible(view, fact.targetId) then
          setColor(graphics, SELECTED)
          graphics.rectangle("line", fact.rect.x + 1, fact.rect.y + 1, fact.rect.width - 2, fact.rect.height - 2)
        end
        drawCellText(fact.label .. " " .. fact.value, fact.rect, fact.editable and "normal" or "hint")
      end
    end
  end
  if view.section == "Location" then
    drawLocation(self, view, layout)
  end
  for _, action in ipairs(layout.actions) do
    local rect = targetRect(layout, action.id)
    if rect then
      local label = action.id == "save" and view.locationSave and "Cancel check" or action.label
      local role = action.id == "save" and "primary" or action.id == "discard" and "destructive" or "secondary"
      drawButtonControl(self, rect, label, false, isFocusedVisible(view, action.id), not action.enabled, role, false)
    end
  end
  if view.valueEditor then
    local dialog = view.valueEditor
    if dialog.kind == "number" then
      local modal = assert(layout.valueModal)
      graphics.setColor(1, 1, 1, 1)
      graphics.rectangle("fill", modal.x, modal.y, modal.width, modal.height)
      local valueRect = assert(layout.valueModalValue, "the compact number modal reserves its value line")
      drawText(self, tostring(dialog.parsedValue or dialog.buffer), valueRect.x, valueRect.y)
      local failed = view.editorFeedback ~= nil or dialog.valid == false
      if failed then
        local errorRect = assert(layout.valueModalError, "the compact number modal reserves its error line")
        drawText(
          self,
          fitText(self, view.editorFeedback or "Enter a whole number.", errorRect.width),
          errorRect.x,
          errorRect.y,
          "error"
        )
      end
      for _, control in ipairs(assert(view.numberControls)) do
        local id = "number:delta:" .. tostring(control.delta)
        local target = assert(targetRect(layout, id))
        local state = view.numberHoldTarget == id and "pressed" or "normal"
        local visual = assert(view.numberControlVisuals[control.role][state])
        local image = assert(self._bagImages[visual.image], "retail number controls are prepared before drawing")
        graphics.setColor(1, 1, 1, 1)
        graphics.draw(
          image,
          target.x + (target.width - image:getWidth()) / 2,
          target.y + (target.height - image:getHeight()) / 2
        )
        if isFocusedVisible(view, id) then
          drawFocusRing(self, target, 0)
        end
      end
      drawButtonControl(
        self,
        targetRect(layout, "confirm"),
        "Confirm",
        false,
        isFocusedVisible(view, "confirm"),
        false,
        "primary",
        false
      )
      drawButtonControl(
        self,
        targetRect(layout, "cancel"),
        "Cancel",
        false,
        isFocusedVisible(view, "cancel"),
        false,
        nil,
        false
      )
    elseif dialog.kind == "choice" then
      local viewport = assert(layout.viewports["value:choice"])
      LogicalSurface.clip(graphics, viewport.clip, function()
        for index = viewport.firstIndex, viewport.lastIndex do
          local option = dialog.options[index]
          if option ~= nil then
            local rect = targetRect(layout, "choice:" .. option.key)
            if rect then
              drawListRow(self, rect, option.label, isFocusedVisible(view, "choice:" .. option.key))
            end
          end
        end
      end)
      if dialog.empty then
        drawBodyText(self, "No matching choices.", viewport.clip.x + 3, viewport.clip.y + 3, "hint")
      end
      for _, id in ipairs({ "confirm", "cancel" }) do
        local rect = targetRect(layout, id)
        assert(rect)
        local disabled = id == "confirm" and dialog.empty == true
        drawButtonControl(
          self,
          rect,
          id == "cancel" and "Cancel" or "Choose",
          false,
          isFocusedVisible(view, id),
          disabled,
          nil,
          false
        )
      end
    elseif dialog.kind == "name" then
      local naming = dialog.naming
      drawText(self, naming.text, layout.content.x + 4, layout.content.y + 3, pagePalette(self.skin))
      for row = 1, 6 do
        for column = 1, 13 do
          local id = row .. ":" .. column
          local rect = assert(targetRect(layout, id))
          local cell = naming.grid[row][column]
          setColor(graphics, naming.cursor.row == row and naming.cursor.column == column and SELECTED or BORDER)
          graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
          drawText(self, cell.glyph or "", rect.x + 2, rect.y + 2, pagePalette(self.skin))
        end
      end
      for _, control in ipairs(naming.controls) do
        local id = "name-control:" .. control.id
        local rect = assert(targetRect(layout, id))
        setColor(graphics, BORDER)
        graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
        drawText(self, control.label, rect.x + 2, rect.y + 2, pagePalette(self.skin))
      end
      for _, id in ipairs({ "confirm", "cancel" }) do
        local rect = targetRect(layout, id)
        setColor(graphics, BORDER)
        graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
        drawText(self, id == "confirm" and "OK" or "Cancel", rect.x + 3, rect.y + 3, pagePalette(self.skin))
      end
    end
  end
  if view.iconStatus == "pending" then
    drawText(
      self,
      "Preparing party icons…",
      layout.content.x + 4,
      layout.content.y + layout.content.height - 16,
      pageMutedPalette(self.skin)
    )
  elseif view.iconStatus == "failed" then
    drawText(
      self,
      "Icons unavailable",
      layout.content.x + 4,
      layout.content.y + layout.content.height - 16,
      pageErrorPalette(self.skin)
    )
  end
  if view.modal then
    local prompt
    if view.modal == "bag-item" then
      prompt = tostring(view.bagSelectedLabel or view.bagSelectedItem) .. "  × " .. tostring(view.bagSelectedQuantity)
    elseif view.modal == "draft" then
      prompt = "Apply party changes?"
    elseif view.modal == "remove" then
      prompt = "Remove this entry?"
    else
      prompt = "Save every section before leaving?"
    end
    local decisionList = assert(layout.decisionList)
    drawText(self, prompt, decisionList.prompt.x, decisionList.prompt.y, INK)
    for _, row in ipairs(decisionList.rows) do
      drawButtonControl(
        self,
        row.rect,
        row.label,
        false,
        isFocusedVisible(view, row.targetId),
        row.enabled == false,
        row.semantic,
        false
      )
    end
  end
  for _, list in pairs(layout.lists or {}) do
    local hint = list.hintRect
    if hint ~= nil and hint.height > 0 then
      local query = list.query or ""
      local hintText = query == "" and "Type to filter" or ("Filter: " .. query)
      drawBodyText(self, fitText(self, hintText, hint.width / BODY_TEXT_SCALE), hint.x, hint.y, "hint")
    end
    if isFocusedVisible(view, list.targetId) and list.surfaceRect ~= nil then
      drawFocusRing(self, list.surfaceRect, 0)
    end
  end
  for _, viewport in pairs(layout.viewports or {}) do
    if viewport.contentExtent > viewport.clip.height then
      local clip = viewport.clip
      local trackX = clip.x + clip.width - 2
      graphics.setColor(
        self.skin.cards.normal.border[1],
        self.skin.cards.normal.border[2],
        self.skin.cards.normal.border[3],
        0.35
      )
      graphics.rectangle("fill", trackX, clip.y, 2, clip.height)
      local thumbHeight = math.max(8, math.min(clip.height, clip.height * clip.height / viewport.contentExtent))
      local travel = math.max(0, clip.height - thumbHeight)
      local range = math.max(1, viewport.contentExtent - clip.height)
      local thumbY = clip.y + travel * math.min(1, math.max(0, viewport.offset / range))
      local hintInk = self.skin.text.hint.foreground
      graphics.setColor(hintInk.r / 255, hintInk.g / 255, hintInk.b / 255, 1)
      graphics.rectangle("fill", trackX, thumbY, 2, thumbHeight)
      graphics.setColor(1, 1, 1, 1)
    end
  end
  if frameIndex ~= nil then
    assert(self._windowRenderer, "field frame renderer is prepared before Save Editor drawing")
    -- Frame pass runs after surface content.
    if layout.valueModal then
      self._windowRenderer:drawApplicationFrame(framedContentRect(layout.valueModal), frameIndex)
    end
    if layout.decisionList then
      self._windowRenderer:drawApplicationFrame(framedContentRect(layout.decisionList.surface), frameIndex)
    end
    for _, surface in ipairs(layout.listSurfaces or {}) do
      self._windowRenderer:drawApplicationFrame(framedContentRect(surface), frameIndex)
    end
  end
end

drawLocation = function(self, view, layout)
  local graphics = self.graphics
  local BORDER = self.skin.cards.normal.border
  local tileMuted = self.skin.text.hint.foreground
  local location = assert(view.location)
  local navigation = assert(view.locationNavigation)
  local grid = layout.locationGrid
  local tiles = {}
  for _, tile in ipairs(location.tiles or {}) do
    tiles[string.format("%d:%d", tile.fieldX, tile.fieldZ)] = tile
  end
  if grid then
    local header = assert(layout.locationHeader, "Location grid needs its measured header")
    local ink = textPalette(self.skin, { r = 0, g = 0, b = 0 })
    drawText(self, fitText(self, header.leftText, header.leftRect.width), header.leftRect.x, header.leftRect.y, ink)
    if header.rightText ~= nil and header.rightRect.width > 0 then
      local fitted = fitText(self, header.rightText, header.rightRect.width)
      local rightWidth = self.text:textWidth(fitted)
      drawText(self, fitted, header.rightRect.x + header.rightRect.width - rightWidth, header.rightRect.y, ink)
    end
  end

  if grid then
    local clip = grid.clip
    setColor(graphics, { 0.84, 0.87, 0.84, 1 })
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
          else
            setColor(graphics, { 0.89, 0.9, 0.87, 1 })
            graphics.rectangle("fill", x, y, grid.tileSize, grid.tileSize)
            setColor(graphics, tileMuted)
            graphics.line(x + 2, y + grid.tileSize - 2, x + grid.tileSize - 2, y + 2)
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

  if layout.locationFocusCue then
    local cue = layout.locationFocusCue
    setColor(graphics, { 0.86, 0.16, 0.18, 1 })
    graphics.rectangle("line", cue.x, cue.y, cue.width, cue.height)
  end
end

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
  drawText(self, status.state == "ready" and "Map ready" or status.reason or "Preparing map data", 8, 64, statusPalette)
end

function Renderer:draw(view, plan)
  assert(not self._disposed, "disposed save editor renderer cannot draw")
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
  self._bagQuads = {}
  for _, image in pairs(self._partyImages) do
    if image.release then
      image:release()
    end
  end
  self._partyImages = {}
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
