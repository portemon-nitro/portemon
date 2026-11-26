-- Process-owned ROM-independent launcher fonts, optional icons and primitive painter.

local LauncherAssets = require("app.src.launcher.LauncherAssets")
local LauncherLayout = require("app.src.launcher.LauncherLayout")
local LogicalSurface = require("libs.ui.src.LogicalSurface")

local utf8 = rawget(_G, "utf8") --[[@as { len: fun(text: string): number|nil }?]]

---@class LauncherRenderer
---@field fonts table<string, love.Font>
---@field private gameIcons table<string, love.Image>
---@field disposed boolean
---@field refreshGameIcon fun(self: LauncherRenderer, romSha1: string, saveRelativePngPath: string): boolean
---@field dropGameIcon fun(self: LauncherRenderer, romSha1: string)
---@field dispose fun(self: LauncherRenderer)

---@class LauncherFont: love.Font
---@field setHinting fun(self: LauncherFont, mode: love.HintingMode)
---@field setDPIScale fun(self: LauncherFont, scale: number)

local LauncherRenderer = {}
LauncherRenderer.__index = LauncherRenderer

local COLORS = {
  background = { 0.961, 0.961, 0.961, 1 },
  majorGrid = { 0.816, 0.827, 0.835, 1 },
  minorGrid = { 0.902, 0.910, 0.914, 1 },
  header = { 0.843, 0.859, 0.875, 1 },
  headerLower = { 0.659, 0.686, 0.710, 1 },
  face = { 0.965, 0.965, 0.953, 1 },
  missingFace = { 0.906, 0.910, 0.914, 1 },
  rim = { 0.392, 0.420, 0.439, 1 },
  highlight = { 1, 1, 1, 1 },
  lowerBevel = { 0.655, 0.678, 0.694, 1 },
  text = { 0.145, 0.157, 0.165, 1 },
  muted = { 0.365, 0.392, 0.412, 1 },
  focus = { 0.769, 0.239, 0.478, 1 },
  gold = { 0.769, 0.604, 0.282, 1 },
  silver = { 0.502, 0.580, 0.671, 1 },
}

local function color(graphics, value)
  graphics.setColor(value[1], value[2], value[3], value[4] or 1)
end

local function loadFont(path, size)
  local data = assert(LauncherAssets.read(path), "required launcher font is missing: " .. path)
  local ok, font = pcall(love.graphics.newFont, data, size)
  data:release()
  if not ok then
    error(font, 0)
  end
  if type(font.setFilter) == "function" then
    font:setFilter("nearest", "nearest")
  end
  local configured = font --[[@as LauncherFont]]
  if type(configured.setHinting) == "function" then
    configured:setHinting("mono")
  end
  if type(configured.setDPIScale) == "function" then
    configured:setDPIScale(1)
  end
  return font
end

function LauncherRenderer.new()
  local self = setmetatable({ fonts = {}, gameIcons = {}, disposed = false }, LauncherRenderer)
  local ok, failure = pcall(function()
    self.fonts.body = loadFont("assets/fonts/galmuri/Galmuri11.ttf", 12)
    self.fonts.bold = loadFont("assets/fonts/galmuri/Galmuri11-Bold.ttf", 12)
    self.fonts.wordmark = loadFont("assets/fonts/mplus1p/MPLUS1p-Regular.ttf", 28)
  end)
  if not ok then
    self:dispose()
    error(failure, 0)
  end
  return self
end

function LauncherRenderer:_background(width, height)
  local graphics = love.graphics
  color(graphics, COLORS.background)
  graphics.rectangle("fill", 0, 0, width, height)
  color(graphics, COLORS.minorGrid)
  for y = 4, height - 1, 4 do
    graphics.rectangle("fill", 0, y, width, 1)
  end
  color(graphics, COLORS.majorGrid)
  for x = 0, width - 1, 16 do
    graphics.rectangle("fill", x, 0, 1, height)
  end
  for y = 0, height - 1, 16 do
    graphics.rectangle("fill", 0, y, width, 1)
  end
end

function LauncherRenderer:_bevel(rect, faceColor, pressed)
  local graphics = love.graphics
  color(graphics, pressed and COLORS.lowerBevel or COLORS.highlight)
  graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
  color(graphics, pressed and COLORS.highlight or COLORS.lowerBevel)
  graphics.rectangle("fill", rect.x + rect.width - 2, rect.y + 2, 2, rect.height - 4)
  graphics.rectangle("fill", rect.x + 2, rect.y + rect.height - 2, rect.width - 2, 2)
  color(graphics, faceColor)
  graphics.rectangle("fill", rect.x + 2, rect.y + 2, rect.width - 4, rect.height - 4)
  color(graphics, COLORS.rim)
  graphics.rectangle("line", rect.x + 0.5, rect.y + 0.5, rect.width - 1, rect.height - 1)
end

function LauncherRenderer:_focus(rect)
  local graphics = love.graphics
  local x, y, w, h = rect.x, rect.y, rect.width, rect.height
  color(graphics, COLORS.focus)
  graphics.setLineWidth(2)
  graphics.line(x + 7, y, x, y, x, y + 7)
  graphics.line(x + w - 7, y, x + w, y, x + w, y + 7)
  graphics.line(x, y + h - 7, x, y + h, x + 7, y + h)
  graphics.line(x + w - 7, y + h, x + w, y + h, x + w, y + h - 7)
  graphics.setLineWidth(1)
end

local function fitText(font, text, width)
  text = tostring(text)
  if font:getWidth(text) <= width then
    return text
  end
  local ellipsis = "…"
  local low, high = 0, #text
  while low < high do
    local middle = math.ceil((low + high) / 2)
    if font:getWidth(text:sub(1, middle) .. ellipsis) <= width then
      low = middle
    else
      high = middle - 1
    end
  end
  local cut = text:sub(1, low)
  while #cut > 0 and utf8 ~= nil and not utf8.len(cut) do
    cut = cut:sub(1, -2)
  end
  return cut .. ellipsis
end

function LauncherRenderer:drawButton(rect, label, _, visualState)
  if self.disposed then
    return
  end
  visualState = visualState or {}
  local graphics = love.graphics
  local oldFont = graphics.getFont()
  self:_bevel(rect, COLORS.face, visualState.pressed == true)
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
  graphics.setFont(self.fonts.body)
  local pulse = (math.sin((elapsed or 0) * math.pi * 2 / 2.2) + 1) / 2
  color(graphics, { 0.506 + pulse * 0.125, 0.525 + pulse * 0.125, 0.541 + pulse * 0.125, 1 })
  local text = "Press a button for game selection"
  local prompt = layout.promptRect
  local _, lines = graphics.getFont():getWrap(text, prompt.width)
  local lineHeight = graphics.getFont():getHeight()
  local y = prompt.y + prompt.height - #lines * lineHeight
  for _, line in ipairs(lines) do
    local width = graphics.getFont():getWidth(line)
    graphics.print(line, prompt.x + prompt.width - width, y)
    y = y + lineHeight
  end
end

function LauncherRenderer:_header(view, layout)
  local graphics = love.graphics
  local header = layout.header
  self:_bevel(header, COLORS.header, false)
  graphics.setFont(self.fonts.bold)
  color(graphics, COLORS.text)
  local clock = (view.dateText or "") .. "  " .. (view.timeText or "")
  local lineHeight = graphics.getFont():getHeight()
  if layout.narrowHeader then
    graphics.print(clock, header.x + 8, header.y + 4)
    graphics.setFont(self.fonts.body)
    color(graphics, COLORS.muted)
    graphics.print(
      fitText(graphics.getFont(), tostring(view.version or ""), header.width - 16),
      header.x + 8,
      header.y + 4 + lineHeight
    )
  else
    graphics.print(clock, header.x + 8, header.y + (header.height - lineHeight) / 2)
    graphics.setFont(self.fonts.body)
    color(graphics, COLORS.muted)
    local version = fitText(graphics.getFont(), tostring(view.version or ""), math.max(0, header.width * 0.42))
    graphics.print(
      version,
      header.x + header.width - 8 - graphics.getFont():getWidth(version),
      header.y + (header.height - graphics.getFont():getHeight()) / 2
    )
  end
end

function LauncherRenderer:_cartridge(view, game, slot)
  local graphics = love.graphics
  local installed = game.installed == true
  local pressed = view.pressedTarget == game.versionId
  self:_bevel(slot.rect, installed and COLORS.face or COLORS.missingFace, pressed)
  color(graphics, game.versionId == "heartgold" and COLORS.gold or COLORS.silver)
  graphics.rectangle("fill", slot.rect.x + 2, slot.rect.y + 2, 4, slot.rect.height - 4)
  local well = slot.iconWell
  color(graphics, COLORS.headerLower)
  graphics.rectangle("fill", well.x, well.y, well.width, well.height)
  color(graphics, COLORS.background)
  graphics.rectangle("fill", well.x + 1, well.y + 1, well.width - 2, well.height - 2)
  local icon = installed and game.iconSha1 and self.gameIcons[game.iconSha1] or nil
  if icon ~= nil then
    graphics.draw(icon, well.x + math.floor((well.width - 32) / 2), well.y + math.floor((well.height - 32) / 2))
  end
  graphics.setFont(self.fonts.bold)
  color(graphics, installed and COLORS.text or COLORS.muted)
  local text = slot.textRect
  local title = fitText(graphics.getFont(), game.label, text.width)
  local lineHeight = graphics.getFont():getHeight()
  local titleY = text.y + (installed and math.floor((text.height - lineHeight) / 2) or 3)
  graphics.print(title, text.x, titleY)
  if not installed then
    graphics.setFont(self.fonts.body)
    color(graphics, COLORS.muted)
    local subtitle = fitText(graphics.getFont(), "Select to import ROM", text.width)
    graphics.print(subtitle, text.x, titleY + lineHeight + 3)
  end
  if view.action == game.versionId then
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

function LauncherRenderer:_operation(view, layout)
  local graphics = love.graphics
  local operation = assert(view.import)
  self:_background(layout.viewport.width, layout.viewport.height)
  self:_header(view, layout)
  if layout.unavailable then
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
    color(graphics, COLORS.muted)
    local status = operation.statusText or (operation.mode == "receipt" and "Waiting for readers" or "Working")
    graphics.print(
      fitText(graphics.getFont(), status, layout.statusRect.width),
      layout.statusRect.x,
      layout.statusRect.y + 4
    )
    if operation.progress ~= nil then
      local track = layout.statusRect
      color(graphics, COLORS.headerLower)
      graphics.rectangle("fill", track.x, track.y + 22, track.width, 4)
      color(graphics, COLORS.header)
      graphics.rectangle(
        "fill",
        track.x,
        track.y + 22,
        math.floor(track.width * math.max(0, math.min(1, operation.progress))),
        4
      )
    else
      self:drawLoadingSquares(layout.statusRect.x, layout.statusRect.y + 20, operation.elapsed or 0)
    end
  elseif layout.errorRect ~= nil then
    color(graphics, COLORS.muted)
    local message = operation.error and (operation.error.message or operation.error.code)
      or tostring(operation.error or "Import failed")
    local _, lines = graphics.getFont():getWrap(message, layout.errorRect.width)
    local y = layout.errorRect.y
    for _, line in ipairs(lines) do
      if y + graphics.getFont():getHeight() > layout.errorRect.y + layout.errorRect.height then
        break
      end
      graphics.print(line, layout.errorRect.x, y)
      y = y + graphics.getFont():getHeight()
    end
  end
  for targetId, target in pairs(layout.graph.targets) do
    local label = targetId == "choose-rom" and "Choose ROM"
      or targetId == "retry" and "Retry"
      or targetId == "cancel" and "Cancel"
      or "Back"
    self:drawButton(target.rect, label, nil, { focused = view.action == targetId })
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
    local width, height = surface.logicalViewport.width, surface.logicalViewport.height
    self:_background(width, height)
    local graphics = love.graphics
    graphics.setFont(self.fonts.wordmark)
    local alpha = math.min(1, (view.elapsed or 0) / 0.18)
    color(graphics, { COLORS.text[1], COLORS.text[2], COLORS.text[3], alpha })
    local lineHeight = graphics.getFont():getHeight()
    local top = math.floor((height - lineHeight * 2) / 2)
    for index, line in ipairs({ "Portémon", "Nitro" }) do
      graphics.print(line, math.floor((width - graphics.getFont():getWidth(line)) / 2), top + (index - 1) * lineHeight)
    end
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
    return
  end
  if view.header == true then
    self:_header(view, layout)
  end
  local content = layout.content
  graphics.setFont(self.fonts.bold)
  color(graphics, COLORS.text)
  local titleY = content.y + math.max(4, math.floor((content.height - 76) / 2))
  graphics.print(fitText(graphics.getFont(), view.gameLabel or "", content.width - 8), content.x + 4, titleY)
  graphics.setFont(self.fonts.body)
  color(graphics, COLORS.muted)
  graphics.print(
    fitText(graphics.getFont(), view.label or "Starting game", content.width - 8),
    content.x + 4,
    titleY + 18
  )
  self:drawLoadingSquares(content.x + 4, titleY + 40, view.elapsed)
  if view.selectionInterrupt == true then
    self:drawSelectionPrompt(layout, view.elapsed)
  elseif layout.receiptRect ~= nil then
    color(graphics, COLORS.text)
    graphics.print(
      fitText(graphics.getFont(), "File received: " .. tostring(view.receipt or ""), layout.receiptRect.width),
      layout.receiptRect.x,
      layout.receiptRect.y + 4
    )
    color(graphics, COLORS.muted)
    if layout.statusRect ~= nil then
      graphics.print(
        fitText(graphics.getFont(), view.label or "Waiting for readers", layout.statusRect.width),
        layout.statusRect.x,
        layout.statusRect.y + 4
      )
      self:drawLoadingSquares(layout.statusRect.x, layout.statusRect.y + 22, view.elapsed)
    end
  end
  if layout.errorRect ~= nil then
    local message = tostring(view.error or "")
    if view.detail ~= nil then
      message = message .. "\n" .. tostring(view.detail)
    end
    color(graphics, COLORS.muted)
    local _, lines = graphics.getFont():getWrap(message, layout.errorRect.width)
    local y = layout.errorRect.y
    for _, line in ipairs(lines) do
      if y + graphics.getFont():getHeight() > layout.errorRect.y + layout.errorRect.height then
        break
      end
      graphics.print(line, layout.errorRect.x, y)
      y = y + graphics.getFont():getHeight()
    end
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
  for _, image in pairs(gameIcons) do
    image:release()
  end
  for _, font in pairs(fonts) do
    font:release()
  end
end

return LauncherRenderer
