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
---@field iconStatus string?
---@field iconFailure string?
---@field metrics fun(self: SaveEditorRenderer): { lineHeight: number, measure: fun(value: string): number }
---@field dispose fun(self: SaveEditorRenderer)
---@field preparePresentationAssets fun(self: SaveEditorRenderer, cacheFs: table<string, unknown>, manifest: table<string, unknown>)
---@field prepareVisibleIcons fun(self: SaveEditorRenderer, view: table<string, unknown>, plan: table<string, unknown>, cacheFs: table<string, unknown>, derivedAssets: table<string, unknown>)

local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
local BUTTON_COLORS = {
  navigation = {
    border = { 0.12, 0.22, 0.42, 1 },
    rim = { 0.72, 0.82, 0.96, 1 },
    innerBorder = { 0.18, 0.35, 0.62, 1 },
    faceTop = { 0.48, 0.67, 0.91, 1 },
    faceBottom = { 0.28, 0.48, 0.76, 1 },
  },
  primary = {
    border = { 0.12, 0.34, 0.18, 1 },
    rim = { 0.77, 0.92, 0.75, 1 },
    innerBorder = { 0.2, 0.48, 0.22, 1 },
    faceTop = { 0.56, 0.82, 0.48, 1 },
    faceBottom = { 0.34, 0.66, 0.3, 1 },
  },
  secondary = {
    border = { 0.28, 0.18, 0.42, 1 },
    rim = { 0.88, 0.78, 0.95, 1 },
    innerBorder = { 0.42, 0.3, 0.62, 1 },
    faceTop = { 0.73, 0.6, 0.87, 1 },
    faceBottom = { 0.54, 0.39, 0.72, 1 },
  },
  destructive = {
    border = { 0.46, 0.12, 0.12, 1 },
    rim = { 0.96, 0.77, 0.75, 1 },
    innerBorder = { 0.62, 0.2, 0.19, 1 },
    faceTop = { 0.92, 0.58, 0.53, 1 },
    faceBottom = { 0.76, 0.34, 0.3, 1 },
  },
  disabled = {
    border = { 0.38, 0.4, 0.41, 1 },
    rim = { 0.83, 0.84, 0.84, 1 },
    innerBorder = { 0.52, 0.54, 0.55, 1 },
    faceTop = { 0.76, 0.78, 0.79, 1 },
    faceBottom = { 0.62, 0.65, 0.66, 1 },
  },
}

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
    if self._itemIconProvider == nil then
      self._itemIconProvider = ItemIconAssetProvider.new(cacheFs, { graphics = self.graphics })
    end
    local paths = { assert(view.bagPocketStrip).image }
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

local function drawText(renderer, value, x, y, role)
  local textRole = role == "error" and "error"
    or role == "information" and "information"
    or role == "hint" and "hint"
    or "normal"
  local skin = renderer.skin
  if type(role) == "table" then
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

local function drawShadedControl(renderer, rect, label, selected, disabled, destructive, semantic)
  local role = disabled and "disabled" or destructive and "destructive" or semantic or "navigation"
  local colors = assert(BUTTON_COLORS[role], "unknown save editor button role: " .. tostring(role))
  local scale = math.min(1, rect.width / TextButton.REFERENCE_WIDTH, rect.height / TextButton.REFERENCE_HEIGHT)
  local button = TextButton.resolve({ rect = rect, scale = scale })
  TextButton.draw(renderer.graphics, button, {
    label = label,
    selected = selected,
    colors = colors,
    text = {
      lineHeight = renderer.text.fontDef.lineHeight,
      measure = function(value)
        return renderer.text:textWidth(value)
      end,
      draw = function(value, x, y)
        drawText(renderer, value, x, y, "normal")
      end,
    },
  })
  return button.contentRect
end

local fitText

local function drawListRow(renderer, rect, label, selected, value, semantic, labelRect, valueRect)
  local graphics = renderer.graphics
  graphics.setColor(1, 1, 1, 1)
  graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
  setColor(graphics, renderer.skin.cards.normal.border)
  graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
  if selected then
    setColor(graphics, { 0.86, 0.16, 0.18, 1 })
    graphics.rectangle("line", rect.x + 1, rect.y + 1, rect.width - 2, rect.height - 2)
  end
  if semantic then
    local colors = assert(BUTTON_COLORS[semantic])
    setColor(graphics, colors.border)
    graphics.rectangle("fill", rect.x + 2, rect.y + 2, 3, rect.height - 4)
  end
  local labelBounds = labelRect or { x = rect.x + 6, y = rect.y + 3, width = rect.width - 12 }
  drawText(renderer, fitText(renderer, label, labelBounds.width), labelBounds.x, labelBounds.y or rect.y + 3)
  if value ~= nil then
    local valueText = tostring(value)
    local bounds = valueRect or { x = rect.x, y = rect.y + 3, width = rect.width * 0.35 }
    local fitted = fitText(renderer, valueText, bounds.width)
    local x = valueRect and bounds.x or rect.x + rect.width - renderer.text:textWidth(fitted) - 6
    drawText(renderer, fitted, x, bounds.y or rect.y + 3, "hint")
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

local function targetRect(layout, targetId)
  local target = layout.targets[targetId]
  return target and target.rect
end

local function framedContentRect(content)
  local width = math.floor(content.width / 8) * 8
  local height = math.floor(content.height / 8) * 8
  assert(width >= 8 and height >= 8, "Save Editor framed content must fit at least one dialogue-frame tile")
  return {
    x = content.x + (content.width - width) / 2,
    y = content.y + (content.height - height) / 2,
    width = width,
    height = height,
  }
end

local function drawCenteredIcon(renderer, icon, bounds)
  local dimensions = icon.dimensions
  local scale = math.min(1, bounds.width / dimensions.width, bounds.height / dimensions.height)
  local width, height = dimensions.width * scale, dimensions.height * scale
  renderer.graphics.setColor(1, 1, 1, 1)
  renderer.graphics.draw(
    icon.image,
    icon.quad,
    bounds.x + (bounds.width - width) / 2,
    bounds.y + (bounds.height - height) / 2,
    0,
    scale,
    scale
  )
end

local function drawGridCard(renderer, card, focused)
  drawShadedControl(renderer, card.rect, "", focused, false, false, card.kind == "add" and "primary" or "navigation")
  local icon = card.iconKey and renderer._icons[card.iconKey]
  if icon then
    drawCenteredIcon(renderer, icon, card.iconRect)
  end
  if card.kind == "add" then
    local plus = "+"
    local plusWidth = renderer.text:textWidth(plus)
    drawText(
      renderer,
      plus,
      card.iconRect.x + (card.iconRect.width - plusWidth) / 2,
      card.iconRect.y + math.max(0, (card.iconRect.height - renderer.text.fontDef.lineHeight) / 2)
    )
  end
  if card.textScale ~= nil then
    local scale = card.textScale
    renderer.graphics.push("all")
    renderer.graphics.translate(card.textRect.x, card.textRect.y)
    renderer.graphics.scale(scale, scale)
    drawText(renderer, fitText(renderer, card.label, card.textRect.width / scale), 0, 0)
    if card.value ~= nil then
      drawText(
        renderer,
        fitText(renderer, card.value, card.textRect.width / scale),
        0,
        renderer.text.fontDef.lineHeight,
        "hint"
      )
    end
    renderer.graphics.pop()
  else
    drawText(renderer, fitText(renderer, card.label, card.textRect.width), card.textRect.x, card.textRect.y)
    if card.value ~= nil then
      drawText(
        renderer,
        fitText(renderer, card.value, card.textRect.width),
        card.textRect.x,
        card.textRect.y + renderer.text.fontDef.lineHeight,
        "hint"
      )
    end
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
  local MUTED = self.skin.text.hint.foreground
  local framedContent = framedContentRect(layout.content)
  setColor(graphics, self.skin.background)
  graphics.rectangle("fill", 0, 0, placement.logicalWidth, placement.logicalHeight)
  setColor(graphics, { 1, 1, 1, 1 })
  graphics.rectangle("fill", framedContent.x, framedContent.y, framedContent.width, framedContent.height)
  if layout.decisionList then
    local surface = layout.decisionList.surface
    graphics.setColor(1, 1, 1, 1)
    graphics.rectangle("fill", surface.x, surface.y, surface.width, surface.height)
  end
  local frameIndex = view.framePreviewIndex or view.session and view.session.frameIndex
  if frameIndex ~= nil then
    assert(self._windowRenderer, "field frame renderer is prepared before Save Editor drawing")
    if layout.valueModal then
      self._windowRenderer:drawApplicationFrame(layout.valueModal, frameIndex)
    end
    if layout.decisionList then
      self._windowRenderer:drawApplicationFrame(layout.decisionList.surface, frameIndex)
    end
    self._windowRenderer:drawApplicationFrame(framedContent, frameIndex)
  end
  for _, navigation in ipairs(layout.navigation) do
    local target = targetRect(layout, navigation.targetId)
    if target then
      local label = navigation.label
      if navigation.targetId:match("^location:map:") then
        label = fitText(self, label, target.width - 22)
      end
      if navigation.role == "list" then
        drawListRow(self, target, label, navigation.targetId == view.focus)
      else
        drawShadedControl(self, target, label, navigation.targetId == ("section:" .. view.section), false)
      end
    end
  end
  if view.section == "Party" and (view.partyPage == "detail" or view.partyPage == "draft") then
    for _, subpage in ipairs(view.partySubpages or {}) do
      local id = "party:subpage:" .. subpage
      local target = targetRect(layout, id)
      if target then
        drawShadedControl(self, target, subpage, view.partySubpage == subpage, false)
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
            row.targetId == view.focus,
            row.valueText or row.value,
            nil,
            row.labelRect,
            row.valueRect
          )
          return
        end
        local actionable = row.role == "action"
          or row.role == "toggle"
          or row.role == "integer value"
          or row.role == "named choice"
          or row.role == "party slot"
          or row.role == "bag item"
          or row.targetId:match("^party:slot:") ~= nil
          or row.targetId:match("^bag:item:") ~= nil
        if actionable and row.targetId == view.focus then
          setColor(graphics, SELECTED)
          graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
        end
        local icon = row.iconKey and self._icons[row.iconKey]
        if icon and graphics.draw then
          graphics.setColor(1, 1, 1, 1)
          graphics.draw(icon.image, icon.quad, rect.x + 3, rect.y + 2)
        end
        local labelRect = assert(row.labelRect, "layout rows own their label text bounds")
        local textRole = row.role == "warning" and "error" or row.role == "read-only value" and "hint" or "normal"
        drawText(
          self,
          fitText(self, row.displayName or row.label, labelRect.width),
          labelRect.x,
          rect.y + 3,
          actionable and row.enabled == false and "hint" or textRole
        )
        if row.valueText ~= nil and row.valueRect ~= nil then
          local valueRect = row.valueRect
          drawText(self, fitText(self, row.valueText, valueRect.width), valueRect.x, rect.y + 3)
        end
      end)
    end
  end
  if view.section == "Party" and layout.partyGrid ~= nil then
    for _, card in ipairs(layout.partyGrid) do
      local cardRow
      for _, row in ipairs(layout.rows) do
        if row.targetId == card.targetId then
          cardRow = row
          break
        end
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
      }, card.targetId == view.focus)
    end
  end
  if view.section == "Bag" then
    local strip = assert(layout.bagStripTarget)
    local stripImage = self._bagImages[assert(view.bagPocketStrip).image]
    assert(stripImage, "selected Bag pocket strip was prepared before drawing")
    graphics.setColor(1, 1, 1, 1)
    graphics.draw(stripImage, strip.x, strip.y)
    for _, targetId in ipairs(layout.bagTabs or {}) do
      if targetId == view.focus then
        local target = targetRect(layout, targetId)
        setColor(graphics, SELECTED)
        graphics.rectangle("line", target.x, target.y, target.width, target.height)
      end
    end
    for _, card in ipairs(layout.bagGrid or {}) do
      drawGridCard(self, card, card.targetId == view.focus or view.bagSelectedItem == card.targetId:sub(10))
    end
    if targetRect(layout, "bag:add") then
      drawShadedControl(
        self,
        targetRect(layout, "bag:page:previous"),
        "Previous",
        view.focus == "bag:page:previous",
        view.bagPage0 == 0
      )
      local pageText = tostring(layout.bagPage.index) .. " / " .. tostring(layout.bagPage.count)
      drawText(
        self,
        pageText,
        layout.bagPageText.x + math.max(0, (layout.bagPageText.width - self.text:textWidth(pageText)) / 2),
        layout.bagPageText.y,
        MUTED
      )
      drawShadedControl(
        self,
        targetRect(layout, "bag:page:next"),
        "Next",
        view.focus == "bag:page:next",
        view.bagPage0 + 1 >= view.bagPageCount
      )
      drawShadedControl(
        self,
        targetRect(layout, "bag:add"),
        "Add",
        view.focus == "bag:add",
        view.bagAddEnabled == false,
        false,
        "primary"
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
      drawText(self, fitText(self, identity, textRect.width), textRect.x, textRect.y + 1, "hint")
    else
      drawText(self, fitText(self, summary.label, textRect.width), textRect.x, textRect.y)
      drawText(
        self,
        fitText(self, summary.species .. "  Lv. " .. tostring(summary.level), textRect.width),
        textRect.x,
        textRect.y + self.text.fontDef.lineHeight,
        "hint"
      )
    end
  end
  if view.section == "Party" then
    for _, row in ipairs(layout.rows) do
      if row.partyField then
        local y = row.layoutRect.y + 3
        drawText(
          self,
          fitText(self, row.label, row.labelRect.width),
          row.labelRect.x,
          y,
          row.role == "warning" and "error" or "normal"
        )
        if row.editable then
          drawShadedControl(
            self,
            row.valueRect,
            fitText(self, row.valueText, row.valueRect.width - 20),
            row.targetId == view.focus,
            false
          )
        elseif row.role == "action" then
          drawShadedControl(self, row.layoutRect, row.label, row.targetId == view.focus, row.enabled == false)
        elseif row.valueText ~= nil then
          drawText(self, fitText(self, row.valueText, row.valueRect.width), row.valueRect.x, y, "hint")
        end
      end
    end
    if layout.partyHelp then
      drawText(
        self,
        fitText(self, layout.partyHelp.text, layout.partyHelp.rect.width),
        layout.partyHelp.rect.x,
        layout.partyHelp.rect.y,
        "hint"
      )
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
      drawShadedControl(self, rect, label, action.id == view.focus, not action.enabled, false, role)
    end
  end
  if view.valueEditor then
    local dialog = view.valueEditor
    if dialog.kind == "number" then
      local modal = assert(layout.valueModal)
      graphics.setColor(1, 1, 1, 1)
      graphics.rectangle("fill", modal.x, modal.y, modal.width, modal.height)
      drawText(self, tostring(dialog.parsedValue or dialog.buffer), modal.x + 10, modal.y + 8, INK)
      drawText(
        self,
        "Range " .. tostring(dialog.minimum) .. "-" .. tostring(dialog.maximum),
        modal.x + 10,
        modal.y + 28,
        MUTED
      )
      if view.editorFeedback or dialog.valid == false then
        drawText(
          self,
          view.editorFeedback or "Enter a whole number within the allowed range.",
          modal.x + 10,
          modal.y + 48,
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
        if id == view.focus then
          setColor(graphics, { 0.86, 0.16, 0.18, 1 })
          graphics.rectangle("line", target.x, target.y, target.width, target.height)
        end
        local label = (control.delta > 0 and "+" or "") .. tostring(control.delta)
        drawText(self, label, target.x + 2, target.y + target.height - self.text.fontDef.lineHeight, INK)
      end
      drawShadedControl(
        self,
        targetRect(layout, "confirm"),
        "Confirm",
        view.focus == "confirm",
        false,
        false,
        "primary"
      )
      drawShadedControl(self, targetRect(layout, "cancel"), "Cancel", view.focus == "cancel", false)
    elseif dialog.kind == "choice" then
      drawText(self, "Search: " .. dialog.query, layout.content.x + 4, layout.content.y + 4, MUTED)
      local viewport = assert(layout.viewports["value:choice"])
      LogicalSurface.clip(graphics, viewport.clip, function()
        for _, option in ipairs(dialog.options) do
          local rect = targetRect(layout, "choice:" .. option.key)
          if rect then
            drawListRow(self, rect, option.label, option.key == dialog.selectedKey)
          end
        end
      end)
      if dialog.empty then
        drawText(self, "No matching choices. Change search.", viewport.clip.x + 3, viewport.clip.y + 3, "hint")
      end
      for _, id in ipairs({ "confirm", "cancel" }) do
        local rect = targetRect(layout, id)
        assert(rect)
        local disabled = id == "confirm" and dialog.empty == true
        drawShadedControl(self, rect, id == "cancel" and "Cancel" or "Choose", id == view.focus, disabled)
      end
    elseif dialog.kind == "name" then
      local naming = dialog.naming
      drawText(self, naming.text, layout.content.x + 4, layout.content.y + 3, INK)
      for row = 1, 6 do
        for column = 1, 13 do
          local id = row .. ":" .. column
          local rect = assert(targetRect(layout, id))
          local cell = naming.grid[row][column]
          setColor(graphics, naming.cursor.row == row and naming.cursor.column == column and SELECTED or BORDER)
          graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
          drawText(self, cell.glyph or "", rect.x + 2, rect.y + 2, INK)
        end
      end
      for _, control in ipairs(naming.controls) do
        local id = "name-control:" .. control.id
        local rect = assert(targetRect(layout, id))
        setColor(graphics, BORDER)
        graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
        drawText(self, control.label, rect.x + 2, rect.y + 2, INK)
      end
      for _, id in ipairs({ "confirm", "cancel" }) do
        local rect = targetRect(layout, id)
        setColor(graphics, BORDER)
        graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
        drawText(self, id == "confirm" and "OK" or "Cancel", rect.x + 3, rect.y + 3, INK)
      end
    end
  end
  if view.iconStatus == "pending" then
    drawText(
      self,
      "Preparing party icons…",
      layout.content.x + 4,
      layout.content.y + layout.content.height - 16,
      "hint"
    )
  elseif view.iconStatus == "failed" then
    drawText(self, "Icons unavailable", layout.content.x + 4, layout.content.y + layout.content.height - 16, "error")
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
      prompt = "Save changes before leaving?"
    end
    local decisionList = assert(layout.decisionList)
    drawText(self, prompt, decisionList.prompt.x, decisionList.prompt.y, INK)
    for _, row in ipairs(decisionList.rows) do
      drawListRow(self, row.rect, row.label, row.targetId == view.focus, nil, row.semantic)
    end
  end
end

drawLocation = function(self, view, layout)
  local graphics = self.graphics
  local INK = self.skin.text.normal.foreground
  local BORDER = self.skin.cards.normal.border
  local MUTED = self.skin.text.hint.foreground
  local location = assert(view.location)
  local navigation = assert(view.locationNavigation)
  local grid = layout.locationGrid
  local tiles = {}
  for _, tile in ipairs(location.tiles or {}) do
    tiles[string.format("%d:%d", tile.fieldX, tile.fieldZ)] = tile
  end
  for _, targetId in ipairs({ "location:map-picker", "location:map-back" }) do
    local target = targetRect(layout, targetId)
    if target then
      local content = drawShadedControl(self, target, "", targetId == view.focus, false)
      local label = targetId == "location:map-picker"
          and navigation.page == "map-list"
          and ("Search maps: " .. tostring(view.query or ""))
        or targetId == "location:map-picker" and "Change Map"
        or "Back"
      local fitted = fitText(self, label, content.width)
      if targetId == "location:map-picker" and navigation.page == "map-list" then
        fitted = fitText(self, label, target.width - 16)
      end
      local textWidth = self.text:textWidth(fitted)
      drawText(self, fitted, content.x + (content.width - textWidth) / 2, content.y + 2, INK)
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
            setColor(graphics, MUTED)
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

  if grid then
    local statusLayout = assert(layout.locationStatus, "Location grid needs measured status geometry")
    local mapLabel = location.map and location.map.symbol:gsub("^MAP_", "", 1)
      or ("Map " .. tostring(location.mapId or "—"))
    local status = location.status
    local statusLabel = status.state == "ready" and ""
      or status.state == "pending" and "Preparing map data"
      or status.reason
      or "Map unavailable"
    local mapLine = statusLayout.mapLine
    drawText(
      self,
      fitText(self, mapLabel .. (statusLabel ~= "" and (" · " .. statusLabel) or ""), mapLine.width),
      mapLine.x,
      mapLine.y,
      status.state == "ready" and "information" or status.state == "failed" and "error" or "hint"
    )
    local staged = view.pendingLocation or view.savedLocation
    local markerText = staged and string.format("X %d  Z %d", staged.fieldX, staged.fieldZ) or ""
    local summaryLine = statusLayout.summaryLine
    drawText(self, fitText(self, markerText, summaryLine.width), summaryLine.x, summaryLine.y, INK)
  end
  if layout.locationFocusCue then
    local cue = layout.locationFocusCue
    setColor(graphics, { 0.86, 0.16, 0.18, 1 })
    graphics.rectangle("line", cue.x, cue.y, cue.width, cue.height)
  end
end

local function paintLocationContext(self, view, pane)
  local graphics = self.graphics
  local INK = self.skin.text.normal.foreground
  local MUTED = self.skin.text.hint.foreground
  local location = assert(view.location)
  setColor(graphics, self.skin.background)
  graphics.rectangle("fill", 0, 0, pane.placement.logicalWidth, pane.placement.logicalHeight)
  drawText(self, "Location context", 8, 8, INK)
  drawText(
    self,
    fitText(
      self,
      location.map and (location.map.symbol:gsub("^MAP_", "", 1)) or tostring(location.mapId),
      pane.placement.logicalWidth - 16
    ),
    8,
    28,
    INK
  )
  local current = view.savedLocation
  if current then
    drawText(self, string.format("Current %d, %d", current.fieldX, current.fieldZ), 8, 46, INK)
  elseif view.session then
    drawText(
      self,
      fitText(self, view.session.playerName .. " · " .. view.session.versionId, pane.placement.logicalWidth - 16),
      8,
      46
    )
  end
  local status = location.status
  drawText(self, status.state == "ready" and "Map ready" or status.reason or "Preparing map data", 8, 64, MUTED)
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
            8
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
