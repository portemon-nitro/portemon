-- Process-owned ROM-independent launcher fonts, icons and primitive painter.

local LogicalSurface = require("libs.ui.src.LogicalSurface")
local LauncherAssets = require("app.src.launcher.LauncherAssets")

local LauncherRenderer = {}
LauncherRenderer.__index = LauncherRenderer

---@class LauncherRenderer
---@field fonts table<string, love.Font>
---@field icons table<string, love.Image>
---@field disposed boolean
---@field dispose fun(self: LauncherRenderer)

---@class LauncherButtonState
---@field focused boolean?
---@field pressed boolean?
---@field disabled boolean?

---@class LauncherFont: love.Font
---@field setHinting fun(self: LauncherFont, mode: love.HintingMode)
---@field setDPIScale fun(self: LauncherFont, scale: number)

local COLORS = {
  background = { 0.984, 0.984, 0.984, 1 },
  panel = { 0.922, 0.922, 0.922, 1 },
  face = { 0.984, 0.984, 0.984, 1 },
  border = { 0.157, 0.157, 0.157, 1 },
  highlight = { 1, 1, 1, 1 },
  inset = { 0.439, 0.439, 0.439, 1 },
  text = { 0.157, 0.157, 0.157, 1 },
  muted = { 0.439, 0.439, 0.439, 1 },
  accent = { 0.984, 0, 0.573, 1 },
  disabled = { 0.58, 0.58, 0.58, 1 },
}
local ICONS = { "add-game", "play", "back", "check", "warning", "close" }

local function color(graphics, value)
  graphics.setColor(value[1], value[2], value[3], value[4] or 1)
end

---@param font love.Font
---@param bold boolean
local function configureFont(font, bold)
  -- LÖVE 11.5 exposes these font controls; the vendored annotations omit them.
  ---@cast font LauncherFont
  if type(font.setFilter) == "function" then
    font:setFilter("nearest", "nearest")
  end
  if not bold and type(font.setHinting) == "function" then
    font:setHinting("mono")
  end
  if type(font.setDPIScale) == "function" then
    font:setDPIScale(1)
  end
end

---@param data love.FileData
---@param size integer
---@return love.Font
local function newFont(data, size)
  -- The vendored LÖVE annotations omit the FileData overload that LÖVE 11.5 supports.
  local graphics = love.graphics --[[@as { newFont: fun(data: love.FileData, size: integer): love.Font }]]
  return graphics.newFont(data, size)
end

---@param path string
---@param size integer
---@return love.Font
local function loadFont(path, size)
  local data = assert(LauncherAssets.read(path), "required launcher font is missing: " .. path)
  local ok, font = pcall(newFont, data, size)
  data:release()
  if not ok then
    error(font, 0)
  end
  return font
end

---@return LauncherRenderer
function LauncherRenderer.new()
  local self = setmetatable({ fonts = {}, icons = {}, disposed = false }, LauncherRenderer)
  local ok, failure = pcall(function()
    self.fonts.body = loadFont("assets/fonts/galmuri/Galmuri11.ttf", 12)
    configureFont(self.fonts.body, false)
    self.fonts.bold = loadFont("assets/fonts/galmuri/Galmuri11-Bold.ttf", 12)
    configureFont(self.fonts.bold, true)
    self.fonts.wordmark = loadFont("assets/fonts/mplus1p/MPLUS1p-Regular.ttf", 20)
    configureFont(self.fonts.wordmark, true)
    for _, name in ipairs(ICONS) do
      local path = "assets/ui/launcher/icons/" .. name .. ".png"
      local data = assert(LauncherAssets.read(path), "required launcher icon is missing: " .. name)
      local imageDataOk, imageData = pcall(love.image.newImageData, data)
      data:release()
      if not imageDataOk then
        error(imageData, 0)
      end
      local imageOk, image = pcall(love.graphics.newImage, imageData)
      imageData:release()
      if not imageOk then
        error(image, 0)
      end
      self.icons[name] = image
      image:setFilter("nearest", "nearest")
    end
  end)
  if not ok then
    self:dispose()
    error(failure, 0)
  end
  return self
end

function LauncherRenderer:_panel(rect, pressed)
  local graphics = love.graphics
  color(graphics, pressed and COLORS.inset or COLORS.highlight)
  graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
  color(graphics, pressed and COLORS.highlight or COLORS.inset)
  graphics.rectangle("fill", rect.x + rect.width - 1, rect.y + 1, 1, rect.height - 2)
  graphics.rectangle("fill", rect.x + 1, rect.y + rect.height - 1, rect.width - 1, 1)
  local face = {
    x = rect.x + 1,
    y = rect.y + 1,
    width = math.max(1, rect.width - 3),
    height = math.max(1, rect.height - 3),
  }
  color(graphics, pressed and COLORS.inset or COLORS.face)
  graphics.rectangle("fill", face.x, face.y, face.width, face.height)
  LogicalSurface.clip(graphics, face, function()
    for row = 0, face.height - 1 do
      color(graphics, row % 2 == 0 and COLORS.panel or COLORS.face)
      graphics.rectangle("fill", face.x, face.y + row, face.width, 1)
    end
  end)
  color(graphics, COLORS.border)
  graphics.rectangle("line", rect.x + 0.5, rect.y + 0.5, rect.width - 1, rect.height - 1)
end

function LauncherRenderer:_focus(rect)
  local graphics = love.graphics
  local x, y, w, h = rect.x - 3, rect.y - 3, rect.width + 6, rect.height + 6
  color(graphics, COLORS.accent)
  graphics.setLineWidth(2)
  graphics.line(x, y + 7, x, y, x + 7, y)
  graphics.line(x + w - 7, y, x + w, y, x + w, y + 7)
  graphics.line(x, y + h - 7, x, y + h, x + 7, y + h)
  graphics.line(x + w - 7, y + h, x + w, y + h, x + w, y + h - 7)
  graphics.setLineWidth(1)
end

---@param rect { x: number, y: number, width: number, height: number }
---@param label string
---@param iconKey string?
---@param visualState LauncherButtonState?
function LauncherRenderer:drawButton(rect, label, iconKey, visualState)
  if self.disposed then
    return
  end
  visualState = visualState or {}
  local graphics = love.graphics
  local oldFont = graphics.getFont()
  graphics.setFont(self.fonts.bold)
  self:_panel(rect, visualState.pressed == true)
  if visualState.focused then
    self:_focus(rect)
  end
  local disabled = visualState.disabled == true
  color(graphics, disabled and COLORS.disabled or COLORS.text)
  local icon = iconKey ~= nil and self.icons[iconKey] or nil
  local textX = rect.x + 10
  if icon ~= nil then
    graphics.draw(icon, rect.x + 10, rect.y + (rect.height - 32) / 2, 0, 2, 2)
    textX = textX + 40
  end
  local textWidth = graphics.getFont():getWidth(label)
  local available = rect.x + rect.width - 10 - textX
  if textWidth > available and icon ~= nil then
    textX = rect.x + 10
  end
  graphics.print(label, textX, rect.y + (rect.height - 12) / 2)
  graphics.setFont(oldFont)
  color(graphics, COLORS.text)
end

---@param x number
---@param y number
---@param elapsed number?
function LauncherRenderer:drawLoadingSquares(x, y, elapsed)
  if self.disposed then
    return
  end
  local graphics = love.graphics
  local active = math.floor((elapsed or 0) / 0.12) % 4
  for index = 0, 3 do
    color(graphics, index == active and COLORS.accent or { 0.75, 0.75, 0.75, 1 })
    graphics.rectangle("fill", x + index * 14, y, 8, 8)
  end
end

function LauncherRenderer:_cartridge(x, y, empty)
  local graphics = love.graphics
  color(graphics, empty and COLORS.muted or COLORS.border)
  graphics.rectangle("fill", x + 3, y, 22, 28)
  color(graphics, COLORS.face)
  graphics.rectangle("fill", x + 5, y + 2, 18, 20)
  color(graphics, empty and COLORS.muted or COLORS.accent)
  graphics.rectangle("fill", x + 7, y + 5, 14, 10)
  color(graphics, COLORS.border)
  graphics.rectangle("line", x + 6, y + 25, 16, 3)
end

function LauncherRenderer:_background(x, y, width, height)
  local graphics = love.graphics
  color(graphics, COLORS.background)
  graphics.rectangle("fill", x, y, width, height)
  color(graphics, { 0.91, 0.91, 0.91, 1 })
  for row = y, y + height - 1, 4 do
    graphics.rectangle("fill", x, row, width, 1)
  end
  for column = x, x + width - 1, 16 do
    graphics.rectangle("fill", column, y, 1, height)
  end
  color(graphics, COLORS.background)
  graphics.rectangle("fill", x, y, width, 34)
end

function LauncherRenderer:_boot(view, safe)
  local graphics = love.graphics
  local x, y, width, height = safe.x, safe.y, safe.width, safe.height
  self:_background(x, y, width, height)
  local alpha = math.min(1, (view.elapsed or 0) / 0.18)
  graphics.setFont(self.fonts.wordmark)
  color(graphics, { COLORS.text[1], COLORS.text[2], COLORS.text[3], alpha })
  local title = "Portémon Nitro"
  graphics.print(title, x + (width - graphics.getFont():getWidth(title)) / 2, y + height / 2 - 42)
  color(graphics, COLORS.border)
  graphics.setLineWidth(2)
  graphics.rectangle("line", x + width / 2 - 58, y + height / 2 - 4, 48, 34)
  graphics.rectangle("line", x + width / 2 + 10, y + height / 2 - 4, 48, 34)
  graphics.setLineWidth(1)
  graphics.setFont(self.fonts.body)
  color(graphics, COLORS.muted)
  local prompt = "Press any button to select game"
  graphics.print(prompt, x + (width - graphics.getFont():getWidth(prompt)) / 2, y + height / 2 + 58)
end

function LauncherRenderer:_header(view, layout)
  local graphics = love.graphics
  graphics.setFont(self.fonts.bold)
  color(graphics, COLORS.text)
  graphics.print("Game selection", layout.header.x, layout.header.y + 6)
  graphics.setFont(self.fonts.body)
  color(graphics, COLORS.muted)
  local version = tostring(view.version or "dev")
  graphics.print(
    version,
    layout.header.x + layout.header.width - graphics.getFont():getWidth(version),
    layout.header.y + 6
  )
end

function LauncherRenderer:_summary(view, layout)
  local graphics = love.graphics
  self:_panel(layout.summary, false)
  local selected = nil
  for _, game in ipairs(view.games) do
    if game.gameId == view.focusedId then
      selected = game
      break
    end
  end
  graphics.setFont(self.fonts.bold)
  color(graphics, COLORS.text)
  graphics.print(selected and selected.label or "No games yet", layout.summary.x + 10, layout.summary.y + 8)
  graphics.setFont(self.fonts.body)
  color(graphics, COLORS.muted)
  if selected then
    graphics.print(
      selected.ready and (selected.hasSave and "Save available" or "Ready to play") or "Needs ROM",
      layout.summary.x + 10,
      layout.summary.y + 26
    )
  elseif not layout.tiny then
    graphics.print(".nds / .zip", layout.summary.x + 10, layout.summary.y + 26)
  end
  return selected
end

function LauncherRenderer:_library(view, layout, selected)
  local graphics = love.graphics
  local width, height = layout.viewport.width, layout.viewport.height
  if view.status ~= nil then
    local statusRect = assert(layout.statusRect)
    self:_panel(statusRect, false)
    local cancel = layout.cancelRect
    local contentWidth = cancel ~= nil and cancel.x - statusRect.x - 18 or statusRect.width - 12
    LogicalSurface.clip(
      graphics,
      { x = statusRect.x + 6, y = statusRect.y + 6, width = math.max(1, contentWidth), height = 18 },
      function()
        color(graphics, COLORS.text)
        graphics.print(tostring(view.status), statusRect.x + 6, statusRect.y + 6)
      end
    )
    if view.busy == true or view.pickerPending == true then
      local progress = view.progress
      if type(progress) == "number" and progress == progress and math.abs(progress) < math.huge then
        local trackWidth = math.max(1, contentWidth)
        color(graphics, COLORS.inset)
        graphics.rectangle("fill", statusRect.x + 6, statusRect.y + 30, trackWidth, 4)
        local fraction = math.max(0, math.min(1, progress))
        if fraction > 0 then
          color(graphics, COLORS.accent)
          graphics.rectangle("fill", statusRect.x + 6, statusRect.y + 30, math.floor(trackWidth * fraction), 4)
        end
      else
        self:drawLoadingSquares(statusRect.x + 6, statusRect.y + 26, love.timer.getTime())
      end
    end
    if cancel ~= nil then
      self:drawButton(cancel, "Cancel", "back", { focused = view.action == "cancel" })
    end
  end
  LogicalSurface.clip(graphics, layout.list.viewport, function()
    for _, game in ipairs(view.games) do
      local row = layout.list.rows[game.gameId]
      if not layout.tiny then
        self:_cartridge(row.x + 8, row.y + 8, not game.ready)
      end
      self:_panel(row, false)
      local textX = row.x + (layout.tiny and 8 or 48)
      graphics.setFont(self.fonts.bold)
      color(graphics, game.ready and COLORS.text or COLORS.disabled)
      if layout.tiny then
        local _, lines = graphics.getFont():getWrap(game.label, row.width - textX - 8)
        for index = 1, math.min(2, #lines) do
          graphics.print(lines[index], textX, row.y + 3 + (index - 1) * 12)
        end
      else
        graphics.print(game.label, textX, row.y + 7)
      end
      graphics.setFont(self.fonts.body)
      color(graphics, COLORS.muted)
      local status = game.ready and (game.hasSave and "Save available" or "Ready") or "Needs ROM"
      graphics.print(status, textX, row.y + (layout.tiny and 30 or 27))
      if game.gameId == view.focusedId then
        self:_focus(row)
      end
    end
  end)
  self:drawButton(layout.actions.addGame, "Add game", "add-game", {
    focused = view.action == "add-game",
    disabled = view.pickerPending == true,
  })
  self:drawButton(layout.actions.play, "Play", "play", {
    focused = view.action == "play",
    disabled = view.pickerPending == true or selected == nil or not selected.ready,
  })
  if view.modal ~= nil then
    color(graphics, { 0.16, 0.16, 0.16, 0.35 })
    graphics.rectangle("fill", 0, 0, width, height)
    self:_panel(layout.modal.box, false)
    graphics.setFont(self.fonts.bold)
    color(graphics, COLORS.text)
    graphics.print("Game unavailable", layout.modal.box.x + 10, layout.modal.box.y + 10)
    graphics.setFont(self.fonts.body)
    color(graphics, COLORS.muted)
    graphics.printf(
      tostring(view.failureText or "Choose another game or return."),
      layout.modal.box.x + 10,
      layout.modal.box.y + 30,
      layout.modal.box.width - 20
    )
    self:drawButton(layout.modal.back, "Back", "back", { focused = view.action == "back" })
    self:drawButton(layout.modal.pick, "Pick another", "add-game", { focused = view.action == "pick" })
  end
end

function LauncherRenderer:_selection(view, layout)
  self:_background(0, 0, layout.viewport.width, layout.viewport.height)
  self:_header(view, layout)
  local selected = self:_summary(view, layout)
  self:_library(view, layout, selected)
end

function LauncherRenderer:drawDual(view, plan)
  if self.disposed then
    return
  end
  local content = assert(plan.content)
  local graphics = love.graphics
  for _, background in ipairs(content.hostBackgrounds or {}) do
    color(graphics, COLORS.background)
    graphics.rectangle("fill", background.x, background.y, background.width, background.height)
  end
  for _, pane in ipairs(assert(plan.panes)) do
    LogicalSurface.draw(graphics, pane.placement, function()
      if pane.id == content.summaryPaneId then
        local layout = assert(content.summaryLayout)
        self:_background(0, 0, layout.viewport.width, layout.viewport.height)
        self:_header(view, layout)
        self:_summary(view, layout)
      else
        local layout = assert(content.layout)
        self:_background(0, 0, layout.viewport.width, layout.viewport.height)
        self:_header(view, layout)
        local selected = self:_summary(view, layout)
        self:_library(view, layout, selected)
      end
    end)
  end
end

function LauncherRenderer:draw(view, plan)
  if self.disposed then
    return
  end
  view = view or {}
  if plan == nil then
    local width, height = love.graphics.getDimensions()
    local safe = view.safeRect or { x = 0, y = 0, width = width, height = height }
    self:_boot(view, safe)
    return
  end
  local content = assert(plan.content)
  local graphics = love.graphics
  for _, background in ipairs(content.hostBackgrounds or {}) do
    color(graphics, COLORS.background)
    graphics.rectangle("fill", background.x, background.y, background.width, background.height)
  end
  local pane = assert(plan.panes[1])
  LogicalSurface.draw(graphics, pane.placement, function()
    self:_selection(view, content.layout)
  end)
end

function LauncherRenderer:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  local icons, fonts = self.icons, self.fonts
  self.icons, self.fonts = {}, {}
  for _, image in pairs(icons) do
    image:release()
  end
  for _, font in pairs(fonts) do
    font:release()
  end
end

return LauncherRenderer
