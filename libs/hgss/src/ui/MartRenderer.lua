-- Source-layered mart painting; all simulation data is borrowed read-only.

local FieldDrawState = require("libs.hgss.src.presentation.FieldDrawState")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local YesNoPromptRenderer = require("libs.hgss.src.ui.YesNoPromptRenderer")

---@class MartRenderer
---@field private _graphics love.graphics
---@field private _cacheFs CacheFs
---@field private _manifest table<string, unknown>
---@field private _text table<string, unknown>
---@field private _window table<string, unknown>
---@field private _frameIndex integer
---@field private _images table<string, love.Image>
---@field private _quads table<string, love.Quad>
---@field private _promptRenderer YesNoPromptRenderer
---@field private _released boolean
local MartRenderer = {}
MartRenderer.__index = MartRenderer

local STOCK_COLORS = { foreground = 1, shadow = 2, background = 0 }
local SYSTEM_COLORS = { foreground = 15, shadow = 14, background = 0 }

local function color(record)
  local r = assert(tonumber(record.r or record[1]))
  local g = assert(tonumber(record.g or record[2]))
  local b = assert(tonumber(record.b or record[3]))
  if r <= 1 and g <= 1 and b <= 1 then
    r, g, b = r * 255, g * 255, b * 255
  end
  return { r = r, g = g, b = b }
end

local function visualMap(manifest)
  local byPath = {}
  local function visit(value)
    if type(value) ~= "table" then
      return
    end
    if type(value.image) == "string" then
      byPath[value.image] = true
    end
    for _, child in pairs(value) do
      visit(child)
    end
  end
  visit(manifest)
  return byPath
end

---@param opts table<string, unknown>
---@return MartRenderer
function MartRenderer.new(opts)
  assert(type(opts) == "table", "mart renderer options must be a record")
  local cacheFs = assert(opts.cacheFs, "mart renderer requires its version-scoped cache")
  assert(type(cacheFs.read) == "function", "mart renderer cache can read asset bytes")
  -- The mart manifest is a trusted published artifact; every referenced
  -- image is loaded (and asserted present) below, which is the actual use.
  local manifest = assert(opts.manifest, "mart renderer requires the trusted published mart manifest")
  local uiManifest = assert(opts.uiManifest, "mart renderer requires the trusted published field-UI prompt manifest")
  local text = assert(opts.text, "mart renderer borrows the field text renderer")
  assert(
    type(text.drawTextWithPalette) == "function" and type(text.textWidth) == "function",
    "mart renderer requires field glyph painting"
  )
  local window = assert(opts.window, "mart renderer borrows the field window renderer")
  assert(type(window.drawWindow) == "function", "mart renderer requires framed field windows")
  local frameIndex = assert(opts.frameIndex, "mart renderer requires the selected user frame")
  assert(type(frameIndex) == "number" and frameIndex >= 0 and frameIndex % 1 == 0, "mart user frame index is valid")
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage and graphics.newQuad, "mart renderer requires love.graphics")
  ---@cast graphics love.graphics
  local self = setmetatable({
    _graphics = graphics,
    _cacheFs = cacheFs,
    _manifest = manifest,
    _text = text,
    _window = window,
    _frameIndex = frameIndex,
    _images = {},
    _quads = {},
    _promptRenderer = YesNoPromptRenderer.new({ cacheFs = cacheFs, manifest = uiManifest, graphics = graphics }),
    _released = false,
  }, MartRenderer)
  local images, quads = self._images, self._quads
  local ok, err = pcall(function()
    for path in pairs(visualMap(manifest)) do
      local bytes = cacheFs:read(path)
      assert(bytes, "mart visual is unavailable at " .. path)
      local image = graphics.newImage(love.filesystem.newFileData(bytes, path))
      images[path] = image
      image:setFilter("nearest", "nearest")
      local width, height = image:getDimensions()
      quads[path] = graphics.newQuad(0, 0, width, height, width, height)
    end
  end)
  if not ok then
    self:release()
    error(err, 0)
  end
  return self
end

function MartRenderer:_palette(role)
  local colors = assert(self._text.fontDef.palette, "field text renderer carries the generated field palette")
  local roles = role == "stock" and STOCK_COLORS or SYSTEM_COLORS
  local function at(index)
    return color(assert(colors[index + 1], "font palette carries source color slot " .. index))
  end
  local background = at(roles.background)
  return {
    foreground = at(roles.foreground),
    shadow = at(roles.shadow),
    background = { r = background.r, g = background.g, b = background.b, a = 0 },
  }
end

function MartRenderer:_drawVisual(visual, x, y)
  local path = assert(visual.image, "mart visual has a generated image path")
  local image = assert(self._images[path], "mart image was loaded before draw")
  local offsetX, offsetY = visual.offsetX or 0, visual.offsetY or 0
  local graphics = self._graphics
  graphics.setColor(1, 1, 1, 1)
  graphics.draw(image, self._quads[path], x + offsetX, y + offsetY)
end

function MartRenderer:_drawText(value, box, role)
  if value == nil or value == "" then
    return
  end
  assert(type(value) == "string", "mart display text is a string")
  local text = self._text
  local y = box.y + box.textY
  for line in (value .. "\n"):gmatch("(.-)\n") do
    local width = text:textWidth(line)
    local x = box.x + box.textX
    if box.alignment == "center" then
      x = box.x + math.floor((box.width - width) / 2) + box.textX
    elseif box.alignment == "right" then
      x = box.x + box.width - width + box.textX
    end
    text:drawTextWithPalette(line, x, y, self:_palette(role))
    y = y + 16
    if y >= box.y + box.height then
      break
    end
  end
end

function MartRenderer:_drawTokens(tokens, box, role)
  if tokens == nil or #tokens == 0 then
    return
  end
  local width = self._text:textWidth(FieldMessageText.tokensToText(tokens))
  local x = box.x + box.textX
  if box.alignment == "right" then
    x = box.x + box.width - width + box.textX
  elseif box.alignment == "center" then
    x = box.x + math.floor((box.width - width) / 2) + box.textX
  end
  self._text:drawLineWithPalette(tokens, x, box.y + box.textY, self:_palette(role))
end

function MartRenderer:_drawIcon(icons, itemKey, anchor)
  if itemKey == nil then
    return
  end
  local quad = icons:quadFor(itemKey)
  local size = icons:dimensions(itemKey)
  self._graphics.setColor(1, 1, 1, 1)
  self._graphics.draw(icons:image(), quad, anchor.x - size.width / 2, anchor.y - size.height / 2)
end

function MartRenderer:_drawUpper(status, icons)
  local manifest, graphics = self._manifest, self._graphics
  local legacyFamily = status.presentationKind == "seals" or status.presentationKind == "legacy_decorations"
  local family = legacyFamily and "legacy" or "items"
  local upper = manifest.upper
  self:_drawVisual(upper.backgrounds[family], 0, 0)
  local selected = status.currentEntry
  if selected ~= nil then
    if not legacyFamily then
      self:_drawIcon(icons, selected.displayItemKey, upper.itemAnchor)
    end
    local box = upper.description[family]
    self._window:drawWindow(box, self._frameIndex, { 0, 0, 0, 0 })
    self:_drawText(selected.descriptionText, box, "system")
  end
  graphics.setColor(1, 1, 1, 1)
end

function MartRenderer:_drawBrowse(status, icons)
  local lower = self._manifest.lower
  local first = status.page * 6 + 1
  local visibleCount = math.min(6, math.max(0, status.entryCount - first + 1))
  self:_drawVisual(lower.backgrounds.browse[visibleCount], 0, 0)
  local pagePrevious = lower.pagePrevious
  local pageNext = lower.pageNext
  if status.page > 0 then
    self:_drawControl(pagePrevious, status, "pagePrevious")
  end
  if status.page + 1 < status.pageCount then
    self:_drawControl(pageNext, status, "pageNext")
  end
  self:_drawControl(lower.cancel, status, "cancel")
  local focusVisual, focusAnchor
  if status.selection >= 0 and status.selection < 6 then
    local animation = self._manifest.animations.selectionEntry
    local active = status.state == "selection_feedback" and animation.frames[status.animationFrame] or nil
    if active ~= nil then
      focusVisual = active.visual
    elseif status.state == "browse" then
      focusVisual = lower.focus.item
    end
    focusAnchor = lower.slots[status.selection + 1].focusAnchor
  elseif status.selection == 8 then
    focusVisual, focusAnchor = lower.focus.cancel, lower.cancel.anchor
  end
  if focusVisual ~= nil and focusAnchor ~= nil then
    self:_drawVisual(focusVisual, focusAnchor.x, focusAnchor.y)
  end
  for index = 1, 6 do
    local slot = status.entries[index]
    if slot.entryKey ~= nil then
      local geometry = lower.slots[index]
      self:_drawIcon(icons, slot.displayItemKey, geometry.iconAnchor)
      self:_drawText(slot.bindings.itemName, geometry.labelBox, "stock")
      if slot.priceVisible then
        self._text:drawLineWithPalette(slot.priceTokens, geometry.priceAt.x, geometry.priceAt.y, self:_palette("stock"))
      end
    end
  end
  self:_drawText(self._manifest.text.labels.cancelLabel or "", lower.cancelLabelBox, "system")
  self:_drawTokens(status.pageTokens, lower.pageBox, "system")
  local balanceLabel = status.currency == "athlete_points" and self._manifest.text.labels.pointsLabel
    or self._manifest.text.labels.moneyLabel
  self:_drawText(balanceLabel, lower.balance.labelBox, "system")
  self:_drawTokens(status.balanceTokens, lower.balance.valueBox, "system")
end

function MartRenderer:_drawControl(control, status, key)
  local normal = assert(self._manifest.controls[control.normalVisualKey], "mart control normal visual is generated")
  local selected =
    assert(self._manifest.controls[control.selectedVisualKey], "mart control selected visual is generated")
  local feedback = status.controlFeedback
  local pressed = feedback ~= nil and feedback.key == key and feedback.phase == "selected"
  local visual = pressed and selected.selected or normal.normal
  self:_drawVisual(visual, control.anchor.x, control.anchor.y)
end

function MartRenderer:_drawAmountControl(control, status, key)
  local animation = status.amountAnimations[key]
  local visual
  if animation ~= nil then
    local clip = assert(self._manifest.animations[animation.family], "mart amount animation family is generated")
    visual = assert(clip.frames[animation.frame], "mart amount animation frame is generated").visual
  else
    local pair = assert(self._manifest.controls[control.normalVisualKey], "mart amount idle visual is generated")
    visual = pair.normal
  end
  self:_drawVisual(visual, control.anchor.x, control.anchor.y)
end

function MartRenderer:_drawQuantity(status, icons)
  local lower, quantity = self._manifest.lower, self._manifest.lower.quantity
  self:_drawVisual(lower.backgrounds.quantity, 0, 0)
  local entry = assert(status.currentEntry, "quantity states carry their selected entry")
  self:_drawIcon(icons, entry.displayItemKey, quantity.selectedItemAnchor)
  self:_drawText(entry.bindings.itemName, quantity.itemBox, "stock")
  self:_drawText(self._manifest.text.labels.ownedLabel, quantity.owned.labelBox, "system")
  self:_drawTokens(status.ownedTokens, quantity.owned.valueBox, "system")
  self:_drawTokens(status.totalTokens, quantity.totalBox, "system")
  local digits = string.format("%02d", status.quantity)
  self:_drawText(digits:sub(1, 1), quantity.digitBoxes[1], "system")
  self:_drawText(digits:sub(2, 2), quantity.digitBoxes[2], "system")
  for _, name in ipairs({ "increment10", "increment1", "decrement10", "decrement1", "confirm", "cancel" }) do
    if name == "confirm" or name == "cancel" then
      self:_drawControl(quantity[name], status, name)
    else
      self:_drawAmountControl(quantity[name], status, name)
    end
  end
  self:_drawText(self._manifest.text.labels.buyLabel or "", quantity.buyLabelBox, "system")
end

function MartRenderer:_drawPrinter(status)
  local lines = status.printer and status.printer.visibleLines or status.messageLines
  if lines == nil or #lines == 0 then
    return
  end
  local confirmMessage = status.messageRole == "moneyConfirm" or status.messageRole == "pointsConfirm"
  local box = confirmMessage and self._manifest.lower.messages.confirm
    or status.lowerMode == "confirm" and self._manifest.lower.messages.confirm
    or self._manifest.lower.messages.short
  self._window:drawWindow(box, self._frameIndex, { 0, 0, 0, 0 })
  for lineIndex, line in ipairs(lines) do
    local tokens = line.tokens or line
    local lineHeight = status.printer and status.printer.lineHeight or 16
    local y = box.y + (lineIndex - 1) * lineHeight + box.textY
    self._text:drawLineWithPalette(tokens, box.x + box.textX, y, self:_palette("system"))
  end
end

function MartRenderer:_drawLower(status, icons)
  local mode = status.lowerMode
  if mode == "quantity" then
    self:_drawQuantity(status, icons)
  elseif mode == "confirm" then
    self:_drawVisual(self._manifest.lower.backgrounds.confirm, 0, 0)
    local entry = status.currentEntry
    if entry ~= nil then
      self:_drawIcon(icons, entry.displayItemKey, self._manifest.lower.quantity.selectedItemAnchor)
      self:_drawText(entry.bindings.itemName, self._manifest.lower.quantity.itemBox, "stock")
    end
    self:_drawPrinter(status)
    if status.prompt ~= nil then
      self._promptRenderer:draw(status.prompt)
    end
    return
  else
    self:_drawBrowse(status, icons)
  end
  self:_drawPrinter(status)
end

function MartRenderer:draw(status, plan, collaborators)
  assert(type(status) == "table" and type(plan) == "table", "mart draw requires a semantic snapshot and plan")
  if self._released or status.open ~= true then
    return
  end
  local icons = assert(collaborators and collaborators.icons, "mart rendering borrows the item icon provider")
  local upperPane, lowerPane
  for _, pane in ipairs(assert(plan.panes)) do
    if pane.id == "upper" then
      upperPane = pane
    elseif pane.id == "lower" then
      lowerPane = pane
    end
  end
  assert(lowerPane, "the mart plan always includes the lower interaction pane")
  FieldDrawState.protectedDraw(self._graphics, function()
    if upperPane ~= nil then
      LogicalSurface.draw(self._graphics, upperPane.placement, function()
        self:_drawUpper(status, icons)
      end)
    end
    LogicalSurface.draw(self._graphics, lowerPane.placement, function()
      self:_drawLower(status, icons)
    end)
  end)
end

function MartRenderer:release()
  if self._released then
    return
  end
  self._released = true
  for _, image in pairs(self._images) do
    if image.release then
      image:release()
    end
  end
  self._promptRenderer:release()
  self._images = {}
  self._quads = {}
  self._window = nil
  self._text = nil
end

return MartRenderer
