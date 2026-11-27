-- Process-owned ROM-independent launcher fonts, boot artwork, optional icons and primitive painter.

local LauncherAssets = require("app.src.launcher.LauncherAssets")
local LauncherLayout = require("app.src.launcher.LauncherLayout")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

---@class LauncherRenderer
---@field fonts table<string, love.Font>
---@field private bootLogo love.Image?
---@field private bootLogoWidth number
---@field private bootLogoHeight number
---@field private gameIcons table<string, love.Image>
---@field disposed boolean
---@field refreshGameIcon fun(self: LauncherRenderer, romSha1: string, saveRelativePngPath: string): boolean
---@field dropGameIcon fun(self: LauncherRenderer, romSha1: string)
---@field dispose fun(self: LauncherRenderer)

local LauncherRenderer = {}
LauncherRenderer.__index = LauncherRenderer

local BOOT_LOGO_PATH = "assets/logo.png"
-- Measured from the native-resolution captured wordmark ink.
local BOOT_LOGO_LOGICAL_WIDTH = 301
local BOOT_LOGO_INSET = 8

local function rgb(red, green, blue)
  return { red / 255, green / 255, blue / 255, 1 }
end

local COLORS = {
  background = rgb(0xF7, 0xF7, 0xF7),
  majorGrid = rgb(0xBF, 0xC3, 0xC6),
  minorGrid = rgb(0xE9, 0xE9, 0xE9),
  header = rgb(0x8B, 0xAA, 0xBD),
  headerLower = rgb(0x64, 0x85, 0x9B),
  headerGlint = rgb(0xC2, 0xD3, 0xDE),
  headerRule = rgb(0x3C, 0x55, 0x68),
  separatorDark = rgb(0x53, 0x6D, 0x80),
  separatorLight = rgb(0xA6, 0xBD, 0xC9),
  face = rgb(0xFC, 0xFC, 0xFC),
  pressedFace = rgb(0xE8, 0xEA, 0xEB),
  missingFace = rgb(0xF7, 0xF7, 0xF7),
  rim = rgb(0x4D, 0x51, 0x54),
  highlight = rgb(0xFF, 0xFF, 0xFF),
  lowerBevel = rgb(0x8F, 0x93, 0x97),
  iconTop = rgb(0xF4, 0xF4, 0xF4),
  iconBottom = rgb(0xBF, 0xC2, 0xC5),
  panelTop = rgb(0xFC, 0xFC, 0xFC),
  panelBottom = rgb(0xE8, 0xEA, 0xEB),
  panelLine = rgb(0xF5, 0xF6, 0xF6),
  missingBottom = rgb(0xE3, 0xE5, 0xE6),
  text = rgb(0x25, 0x28, 0x2B),
  muted = rgb(0x77, 0x7C, 0x80),
  focus = rgb(0x4A, 0x78, 0x98),
}

local function color(graphics, value)
  graphics.setColor(value[1], value[2], value[3], value[4] or 1)
end

local function loadFont(path, size, hinting, dpi, filter)
  local data = assert(LauncherAssets.read(path), "required launcher font is missing: " .. path)
  local ok, font = pcall(love.graphics.newFont, data, size, hinting, dpi)
  data:release()
  if not ok then
    error(font, 0)
  end
  font:setFilter(filter, filter)
  return font
end

local function loadImage(path)
  local data = assert(LauncherAssets.read(path), "required launcher image is missing: " .. path)
  local ok, imageData = pcall(love.image.newImageData, data)
  data:release()
  if not ok then
    error(imageData, 0)
  end
  local imageOk, image = pcall(love.graphics.newImage, imageData)
  imageData:release()
  if not imageOk then
    error(image, 0)
  end
  image:setFilter("linear", "linear")
  return image
end

local function bootLogoScale(width, height, imageWidth, imageHeight)
  local fitWidth = math.max(1, width - BOOT_LOGO_INSET * 2)
  local fitHeight = math.max(1, height - BOOT_LOGO_INSET * 2)
  return math.min(BOOT_LOGO_LOGICAL_WIDTH / imageWidth, fitWidth / imageWidth, fitHeight / imageHeight)
end

function LauncherRenderer.new()
  local self = setmetatable({
    fonts = {},
    gameIcons = {},
    bootLogoWidth = 0,
    bootLogoHeight = 0,
    disposed = false,
  }, LauncherRenderer)
  local ok, failure = pcall(function()
    self.fonts.body = loadFont("assets/fonts/galmuri/Galmuri11.ttf", 12, "mono", 1, "nearest")
    self.fonts.bold = loadFont("assets/fonts/galmuri/Galmuri11-Bold.ttf", 12, "mono", 1, "nearest")
    self.fonts.prompt = loadFont("assets/fonts/galmuri/Galmuri9.ttf", 10, "mono", 1, "nearest")
    local image = loadImage(BOOT_LOGO_PATH)
    self.bootLogo = image
    self.bootLogoWidth, self.bootLogoHeight = image:getDimensions()
  end)
  if not ok then
    self:dispose()
    error(failure, 0)
  end
  return self
end

local function rampColor(top, bottom, fraction)
  return {
    top[1] + (bottom[1] - top[1]) * fraction,
    top[2] + (bottom[2] - top[2]) * fraction,
    top[3] + (bottom[3] - top[3]) * fraction,
    1,
  }
end

local function rampRows(graphics, rect, top, bottom, inset)
  local rows = math.max(1, math.floor(rect.height - inset * 2))
  for index = 0, rows - 1 do
    local fraction = rows > 1 and math.min(1, math.floor(index * 8 / rows) / 7) or 0
    color(graphics, rampColor(top, bottom, fraction))
    graphics.rectangle("fill", rect.x + inset, rect.y + inset + index, rect.width - inset * 2, 1)
  end
end

function LauncherRenderer:_background(width, height)
  local graphics = love.graphics
  color(graphics, COLORS.background)
  graphics.rectangle("fill", 0, 0, width, height)
  color(graphics, COLORS.minorGrid)
  for y = 2, height - 1, 2 do
    graphics.rectangle("fill", 0, y, width, 1)
  end
  color(graphics, COLORS.majorGrid)
  for y = 0, height - 1, 48 do
    graphics.rectangle("fill", 0, y, width, 1)
  end
  for x = 0, width - 1, 48 do
    graphics.rectangle("fill", x, 0, 1, height)
  end
  color(graphics, COLORS.majorGrid)
  for x = 0, width - 1, 48 do
    for y = 0, height - 1, 48 do
      local clearX, clearY = math.max(0, x - 1), math.max(0, y - 1)
      local clearWidth, clearHeight = math.min(width, x + 2) - clearX, math.min(height, y + 2) - clearY
      if clearWidth > 0 and clearHeight > 0 then
        graphics.rectangle("fill", clearX, clearY, clearWidth, clearHeight)
      end
    end
  end
end

function LauncherRenderer:_bevel(rect, faceColor, pressed)
  local graphics = love.graphics
  color(graphics, pressed and COLORS.lowerBevel or COLORS.highlight)
  graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
  color(graphics, pressed and COLORS.highlight or COLORS.lowerBevel)
  graphics.rectangle("fill", rect.x + rect.width - 1, rect.y + 1, 1, rect.height - 2)
  graphics.rectangle("fill", rect.x + 1, rect.y + rect.height - 1, rect.width - 1, 1)
  color(graphics, faceColor)
  graphics.rectangle("fill", rect.x + 1, rect.y + 1, rect.width - 2, rect.height - 2)
  color(graphics, COLORS.rim)
  graphics.rectangle("line", rect.x + 0.5, rect.y + 0.5, rect.width - 1, rect.height - 1)
end

function LauncherRenderer:_focus(rect)
  local graphics = love.graphics
  local x, y, w, h = rect.x, rect.y, rect.width, rect.height
  color(graphics, COLORS.highlight)
  graphics.setLineWidth(4)
  self:_focusCorners(graphics, x, y, w, h)
  color(graphics, COLORS.focus)
  graphics.setLineWidth(2)
  self:_focusCorners(graphics, x, y, w, h)
  graphics.setLineWidth(1)
end

function LauncherRenderer:_focusCorners(graphics, x, y, w, h)
  graphics.line(x + 8, y, x, y, x, y + 8)
  graphics.line(x + w - 8, y, x + w, y, x + w, y + 8)
  graphics.line(x, y + h - 8, x, y + h, x + 8, y + h)
  graphics.line(x + w - 8, y + h, x + w, y + h, x + w, y + h - 8)
end

local function fitText(font, text, width)
  text = Utf8Glyphs.sanitize(tostring(text))
  if font:getWidth(text) <= width then
    return text
  end
  local ellipsis = "…"
  local glyphs = {}
  for glyph in Utf8Glyphs.iter(text) do
    glyphs[#glyphs + 1] = glyph
  end
  -- Binary-search the glyph prefix so every measured candidate stays on a
  -- codepoint boundary; byte midpoints can split a multibyte sequence and
  -- make LÖVE font metrics raise on valid input.
  local low, high = 0, #glyphs
  while low < high do
    local middle = math.ceil((low + high) / 2)
    local candidate = table.concat(glyphs, "", 1, middle) .. ellipsis
    if font:getWidth(candidate) <= width then
      low = middle
    else
      high = middle - 1
    end
  end
  return table.concat(glyphs, "", 1, low) .. ellipsis
end

function LauncherRenderer:drawButton(rect, label, _, visualState)
  if self.disposed then
    return
  end
  visualState = visualState or {}
  local graphics = love.graphics
  local oldFont = graphics.getFont()
  self:_bevel(rect, visualState.pressed == true and COLORS.pressedFace or COLORS.face, visualState.pressed == true)
  if visualState.focused then
    self:_focus(rect.focusRect or { x = rect.x - 3, y = rect.y - 3, width = rect.width + 6, height = rect.height + 6 })
  end
  graphics.setFont(self.fonts.bold)
  color(graphics, visualState.disabled and COLORS.muted or COLORS.text)
  graphics.print(
    fitText(graphics.getFont(), label, rect.width - 16),
    rect.x + 8,
    rect.y + (rect.height - graphics.getFont():getHeight()) / 2
  )
  graphics.setFont(oldFont)
end

function LauncherRenderer:_backButton(rect, label, visualState)
  if self.disposed then
    return
  end
  visualState = visualState or {}
  local graphics = love.graphics
  local oldFont = graphics.getFont()
  local pressed = visualState.pressed == true
  color(graphics, COLORS.rim)
  graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
  rampRows(
    graphics,
    { x = rect.x + 1, y = rect.y + 1, width = rect.width - 2, height = rect.height - 2 },
    pressed and COLORS.iconBottom or COLORS.iconTop,
    pressed and COLORS.iconTop or COLORS.iconBottom,
    0
  )
  if visualState.focused then
    self:_focus({ x = rect.x - 3, y = rect.y - 3, width = rect.width + 6, height = rect.height + 6 })
  end
  graphics.setFont(self.fonts.bold)
  color(graphics, COLORS.text)
  local visible = fitText(graphics.getFont(), label, rect.width - 8)
  graphics.print(
    visible,
    rect.x + math.max(0, math.floor((rect.width - graphics.getFont():getWidth(visible)) / 2)),
    rect.y + (rect.height - graphics.getFont():getHeight()) / 2
  )
  graphics.setFont(oldFont)
end

function LauncherRenderer:drawLoadingSquares(x, y, elapsed)
  local graphics = love.graphics
  local active = math.floor((elapsed or 0) / 0.12) % 4
  for index = 0, 3 do
    color(graphics, index == active and COLORS.headerLower or COLORS.majorGrid)
    graphics.rectangle("fill", x + index * 14, y, 8, 8)
  end
end

function LauncherRenderer:drawSelectionPrompt(layout, elapsed)
  if self.disposed or layout.promptRect == nil then
    return
  end
  local graphics = love.graphics
  local font = self.fonts.prompt
  graphics.setFont(font)
  local pulse = (math.sin((elapsed or 0) * math.pi * 2 / 2.2) + 1) / 2
  color(graphics, { 0.468 + pulse * 0.012, 0.486 + pulse * 0.012, 0.502 + pulse * 0.012, 1 })
  local text = "Press a button for game selection"
  local prompt = layout.promptRect
  local _, lines = font:getWrap(text, prompt.width)
  local lineHeight = font:getHeight()
  local y = prompt.y + prompt.height - #lines * lineHeight
  for _, line in ipairs(lines) do
    local width = font:getWidth(line)
    graphics.print(line, prompt.x + prompt.width - width, y)
    y = y + lineHeight
  end
end

local function drawCellText(graphics, font, text, cell, rightAligned)
  -- Both insets match the layout's 8px cell padding so each separator keeps
  -- equal air on both sides: the time cell's right gap and the date cell's
  -- left gap are both 8px, as are the date cell's right gap and the version
  -- cell's left gap.
  local visible = rightAligned and fitText(font, text, math.max(0, cell.width - 16)) or text
  local x = rightAligned and cell.x + cell.width - 8 - font:getWidth(visible) or cell.x + 8
  graphics.print(visible, x, cell.y + math.floor((cell.height - font:getHeight()) / 2))
end

function LauncherRenderer:_header(view, layout)
  local graphics = love.graphics
  local header = assert(layout.header)
  local cells = assert(layout.headerCells)
  rampRows(graphics, header, COLORS.header, COLORS.headerLower, 1)
  color(graphics, COLORS.headerGlint)
  graphics.rectangle("fill", header.x, header.y, header.width, 1)
  color(graphics, COLORS.headerRule)
  graphics.rectangle("fill", header.x, header.y + header.height - 1, header.width, 1)
  for _, x in ipairs(cells.separators) do
    color(graphics, COLORS.separatorDark)
    graphics.rectangle("fill", x, header.y + 2, 1, header.height - 4)
    color(graphics, COLORS.separatorLight)
    graphics.rectangle("fill", x + 1, header.y + 2, 1, header.height - 4)
  end
  graphics.setFont(self.fonts.prompt)
  color(graphics, COLORS.highlight)
  drawCellText(graphics, graphics.getFont(), view.timeText or "", cells.time, false)
  drawCellText(graphics, graphics.getFont(), view.dateText or "", cells.date, false)
  drawCellText(graphics, graphics.getFont(), tostring(view.version or ""), cells.version, true)
end

local function centeredLines(graphics, font, lines, rect)
  local lineHeight = font:getHeight()
  local y = rect.y + math.max(0, math.floor((rect.height - #lines * lineHeight) / 2))
  for _, line in ipairs(lines) do
    graphics.print(line, rect.x + math.max(0, math.floor((rect.width - font:getWidth(line)) / 2)), y)
    y = y + lineHeight
  end
end

function LauncherRenderer:_cartridge(view, game, slot)
  local graphics = love.graphics
  local installed = game.installed == true
  local pressed = view.pressedTarget == game.versionId
  local rect = slot.rect
  local well = slot.iconWell
  local text = slot.textRect
  color(graphics, COLORS.rim)
  graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
  color(graphics, pressed and COLORS.lowerBevel or COLORS.highlight)
  graphics.rectangle("fill", rect.x + 1, rect.y + 1, rect.width - 2, 1)
  graphics.rectangle("fill", rect.x + 1, rect.y + 1, 1, rect.height - 2)
  color(graphics, pressed and COLORS.highlight or COLORS.lowerBevel)
  graphics.rectangle("fill", rect.x + 1, rect.y + rect.height - 1, rect.width - 1, 1)
  graphics.rectangle("fill", rect.x + rect.width - 1, rect.y + 1, 1, rect.height - 2)

  rampRows(
    graphics,
    well,
    installed and COLORS.iconTop or COLORS.missingFace,
    installed and COLORS.iconBottom or COLORS.missingBottom,
    0
  )
  color(graphics, COLORS.separatorDark)
  graphics.rectangle("fill", well.x + well.width, well.y, 1, well.height)
  color(graphics, COLORS.highlight)
  graphics.rectangle("fill", well.x + well.width + 1, well.y, 1, well.height)
  local panel = {
    x = well.x + well.width + 2,
    y = rect.y + 1,
    width = rect.x + rect.width - 1 - (well.x + well.width + 2),
    height = rect.height - 2,
  }
  rampRows(
    graphics,
    panel,
    pressed and COLORS.panelBottom or COLORS.panelTop,
    pressed and COLORS.panelTop or COLORS.panelBottom,
    0
  )
  color(graphics, COLORS.panelLine)
  for y = panel.y + 2, panel.y + panel.height - 2, 2 do
    graphics.rectangle("fill", panel.x, y, panel.width, 1)
  end

  local icon = installed and game.iconSha1 and self.gameIcons[game.iconSha1] or nil
  if icon ~= nil then
    graphics.draw(icon, well.x + math.floor((well.width - 32) / 2), well.y + math.floor((well.height - 32) / 2))
  end

  graphics.setFont(self.fonts.body)
  color(graphics, installed and COLORS.text or COLORS.muted)
  local _, lines = graphics.getFont():getWrap(tostring(game.label), text.width)
  if not installed then
    graphics.setFont(self.fonts.prompt)
    local _, hintLines = graphics.getFont():getWrap("Select to import ROM", text.width)
    local titleHeight = #lines * self.fonts.body:getHeight()
    local hintHeight = #hintLines * self.fonts.prompt:getHeight()
    local top = text.y + math.max(0, math.floor((text.height - titleHeight - hintHeight - 3) / 2))
    graphics.setFont(self.fonts.body)
    centeredLines(graphics, self.fonts.body, lines, { x = text.x, y = top, width = text.width, height = titleHeight })
    graphics.setFont(self.fonts.prompt)
    centeredLines(
      graphics,
      self.fonts.prompt,
      hintLines,
      { x = text.x, y = top + titleHeight + 3, width = text.width, height = hintHeight }
    )
  else
    centeredLines(graphics, self.fonts.body, lines, text)
  end
  if view.action == game.versionId or (view.mode == "selection" and view.focusedId == game.versionId) then
    self:_focus(slot.focusRect)
  end
end

function LauncherRenderer:_selection(view, layout)
  self:_background(layout.viewport.width, layout.viewport.height)
  self:_header(view, layout)
  if layout.unavailable then
    return
  end
  for _, game in ipairs(view.games) do
    self:_cartridge(view, game, assert(layout.slots[game.versionId]))
  end
end

local function drawDiagnostic(graphics, view, layout)
  if layout.errorRect == nil then
    return false
  end
  color(graphics, COLORS.muted)
  local message = tostring(view.error or "")
  if view.detail ~= nil then
    message = message .. "\n" .. tostring(view.detail)
  end
  local font = graphics.getFont()
  local _, lines = font:getWrap(message, layout.errorRect.width)
  local y = layout.errorRect.y
  for _, line in ipairs(lines) do
    if y + font:getHeight() > layout.errorRect.y + layout.errorRect.height then
      break
    end
    graphics.print(line, layout.errorRect.x, y)
    y = y + font:getHeight()
  end
  return true
end

function LauncherRenderer:_operation(view, layout)
  local graphics = love.graphics
  local operation = assert(view.import)
  self:_background(layout.viewport.width, layout.viewport.height)
  self:_header(view, layout)
  if layout.unavailable then
    -- Even when the content does not fit, the footer cancel/back targets
    -- stay painted so the operation remains escapable; no receipt is
    -- acknowledged for a paint that did not occur.
    for targetId, target in pairs(layout.graph.targets) do
      local label = targetId == "choose-rom" and "Choose ROM"
        or targetId == "retry" and "Retry"
        or targetId == "cancel" and "Cancel"
        or "Back"
      if targetId == "back" then
        self:_backButton(target.rect, label, { focused = view.action == targetId })
      else
        self:drawButton(target.rect, label, nil, { focused = view.action == targetId })
      end
    end
    return
  end
  graphics.setFont(self.fonts.bold)
  color(graphics, COLORS.text)
  local edition = operation.expectedVersionId == "heartgold" and "HeartGold"
    or operation.expectedVersionId == "soulsilver" and "SoulSilver"
    or "ROM"
  local title = operation.mode == "error" and (edition .. " import failed") or ("Import " .. edition)
  graphics.print(
    fitText(graphics.getFont(), title, layout.content.width - 8),
    layout.content.x + 4,
    layout.content.y + 4
  )
  graphics.setFont(self.fonts.body)
  if operation.mode == "choose" or operation.mode == "picker" then
    color(graphics, COLORS.muted)
    local message = operation.mode == "picker" and "Waiting for file picker…"
      or (
        operation.pickerAvailable and ("Choose a " .. edition .. " ROM (.nds or .zip)")
        or ("Drag and drop a " .. edition .. " ROM (.nds or .zip)")
      )
    local _, lines = graphics.getFont():getWrap(message, layout.messageRect.width)
    local y = layout.messageRect.y
    for _, line in ipairs(lines) do
      if y + graphics.getFont():getHeight() > layout.messageRect.y + layout.messageRect.height then
        break
      end
      graphics.print(line, layout.messageRect.x, y)
      y = y + graphics.getFont():getHeight()
    end
  elseif layout.receiptRect ~= nil then
    color(graphics, COLORS.text)
    graphics.print(
      fitText(graphics.getFont(), "File received: " .. tostring(operation.receipt or ""), layout.receiptRect.width),
      layout.receiptRect.x,
      layout.receiptRect.y + 4
    )
    if operation.error == nil then
      color(graphics, COLORS.muted)
      local status = operation.statusText or (operation.mode == "receipt" and "Waiting for readers" or "Working")
      graphics.print(
        fitText(graphics.getFont(), status, layout.statusRect.width),
        layout.statusRect.x,
        layout.statusRect.y + 4
      )
      if operation.progress ~= nil then
        local track = layout.progressTrackRect or layout.statusRect
        color(graphics, COLORS.headerLower)
        graphics.rectangle("fill", track.x, track.y, track.width, 4)
        color(graphics, COLORS.header)
        graphics.rectangle(
          "fill",
          track.x,
          track.y,
          math.floor(track.width * math.max(0, math.min(1, operation.progress))),
          4
        )
      else
        local indicator = layout.indicatorRect or layout.statusRect
        self:drawLoadingSquares(indicator.x, indicator.y, operation.elapsed or 0)
      end
    end
  elseif layout.errorRect ~= nil then
    drawDiagnostic(
      graphics,
      { error = operation.error and (operation.error.message or operation.error.code) or operation.error },
      layout
    )
  end
  for targetId, target in pairs(layout.graph.targets) do
    local label = targetId == "choose-rom" and "Choose ROM"
      or targetId == "retry" and "Retry"
      or targetId == "cancel" and "Cancel"
      or "Back"
    if targetId == "back" then
      self:_backButton(target.rect, label, { focused = view.action == targetId })
    else
      self:drawButton(target.rect, label, nil, { focused = view.action == targetId })
    end
  end
  if operation.receipt ~= nil and layout.receiptRect ~= nil then
    return operation.attemptId
  end
end

function LauncherRenderer:drawDual(view, plan)
  if self.disposed then
    return
  end
  local content = assert(plan.content)
  local receiptToken
  for _, pane in ipairs(plan.panes) do
    LogicalSurface.draw(love.graphics, pane.placement, function()
      local layout = pane.id == content.statusPaneId and content.statusLayout or content.layout
      self:_background(layout.viewport.width, layout.viewport.height)
      self:_header(view, layout)
      if pane.id ~= content.statusPaneId and not layout.unavailable then
        if view.import ~= nil then
          receiptToken = self:_operation(view, layout)
        else
          for _, game in ipairs(view.games) do
            self:_cartridge(view, game, assert(layout.slots[game.versionId]))
          end
        end
      end
    end)
  end
  return receiptToken
end

function LauncherRenderer:drawBoot(view, surface)
  if self.disposed then
    return
  end
  LogicalSurface.draw(love.graphics, surface.placement, function()
    local graphics = love.graphics
    local width, height = surface.logicalViewport.width, surface.logicalViewport.height
    color(graphics, COLORS.highlight)
    graphics.rectangle("fill", 0, 0, width, height)
    local alpha = math.min(1, (view.elapsed or 0) / 0.18)
    local scale = bootLogoScale(width, height, self.bootLogoWidth, self.bootLogoHeight)
    local drawnWidth, drawnHeight = self.bootLogoWidth * scale, self.bootLogoHeight * scale
    graphics.setColor(1, 1, 1, alpha)
    graphics.draw(
      self.bootLogo,
      math.floor((width - drawnWidth) / 2),
      math.floor((height - drawnHeight) / 2),
      0,
      scale,
      scale
    )
    local layout = LauncherLayout.loading(width, height, { selectionInterrupt = true, fonts = self.fonts })
    self:drawSelectionPrompt(layout, view.elapsed)
  end)
end

function LauncherRenderer:draw(view, plan)
  if self.disposed then
    return
  end
  if plan == nil then
    self:drawBoot(view, assert(view.surface))
    return
  end
  local layout = assert(plan.content.layout)
  LogicalSurface.draw(love.graphics, assert(plan.panes[1].placement), function()
    if view.import ~= nil then
      view.paintedReceiptToken = self:_operation(view, layout)
      return
    end
    self:_selection(view, layout)
  end)
end

function LauncherRenderer:drawLoading(view, layout)
  if self.disposed then
    return
  end
  local graphics = love.graphics
  self:_background(layout.viewport.width, layout.viewport.height)
  if layout.unavailable then
    if layout.cancelRect ~= nil then
      self:drawButton(layout.cancelRect, "Cancel", nil, { focused = view.action == "cancel" })
    end
    return
  end
  graphics.setFont(self.fonts.bold)
  color(graphics, COLORS.text)
  local _, titleLines = graphics.getFont():getWrap(tostring(view.gameLabel or ""), assert(layout.titleRect).width)
  centeredLines(graphics, self.fonts.bold, titleLines, layout.titleRect)

  if view.selectionInterrupt == true then
    if view.error == nil then
      color(graphics, COLORS.muted)
      local status = tostring(view.label or "Now loading...")
      graphics.setFont(self.fonts.prompt)
      centeredLines(graphics, self.fonts.prompt, { status }, assert(layout.loadingStatusRect))
      self:drawLoadingSquares(assert(layout.indicatorRect).x, layout.indicatorRect.y, view.elapsed)
    else
      self:drawSelectionPrompt(layout, view.elapsed)
      drawDiagnostic(graphics, view, layout)
      return nil
    end
    self:drawSelectionPrompt(layout, view.elapsed)
  elseif layout.receiptRect ~= nil then
    color(graphics, COLORS.text)
    graphics.print(
      fitText(graphics.getFont(), "File received: " .. tostring(view.receipt or ""), layout.receiptRect.width),
      layout.receiptRect.x,
      layout.receiptRect.y + 4
    )
    if view.error == nil then
      color(graphics, COLORS.muted)
      graphics.print(
        fitText(graphics.getFont(), tostring(view.label or "Waiting for readers"), layout.statusRect.width),
        layout.statusRect.x,
        layout.statusRect.y + 4
      )
      self:drawLoadingSquares(layout.statusRect.x, (layout.indicatorRect or layout.statusRect).y, view.elapsed)
    else
      drawDiagnostic(graphics, view, layout)
    end
  else
    drawDiagnostic(graphics, view, layout)
  end
  if layout.cancelRect ~= nil then
    self:drawButton(layout.cancelRect, "Cancel", nil, { focused = view.action == "cancel" })
  end
  if view.receipt ~= nil and layout.receiptRect ~= nil then
    return view.attemptId
  end
end

---@param romSha1 string
---@param saveRelativePngPath string
---@return boolean
function LauncherRenderer:refreshGameIcon(romSha1, saveRelativePngPath)
  if self.disposed then
    return false
  end
  if self.gameIcons[romSha1] ~= nil then
    return true
  end
  local data = LauncherAssets.read(saveRelativePngPath)
  if data == nil then
    return false
  end
  local decodedOk, imageData = pcall(love.image.newImageData, data)
  data:release()
  if not decodedOk then
    return false
  end
  local width, height = imageData:getDimensions()
  if width ~= 32 or height ~= 32 then
    imageData:release()
    return false
  end
  local imageOk, image = pcall(love.graphics.newImage, imageData)
  imageData:release()
  if not imageOk then
    return false
  end
  image:setFilter("nearest", "nearest")
  self.gameIcons[romSha1] = image
  return true
end

function LauncherRenderer:dropGameIcon(romSha1)
  local image = self.gameIcons[romSha1]
  if image ~= nil then
    self.gameIcons[romSha1] = nil
    image:release()
  end
end

function LauncherRenderer:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  local fonts, gameIcons = self.fonts, self.gameIcons
  self.fonts, self.gameIcons = {}, {}
  if self.bootLogo ~= nil then
    self.bootLogo:release()
    self.bootLogo = nil
  end
  for _, image in pairs(gameIcons) do
    image:release()
  end
  for _, font in pairs(fonts) do
    font:release()
  end
end

return LauncherRenderer
