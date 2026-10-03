-- Draws the app-native editor shell from its resolved view and plan.

local Renderer = {}
Renderer.__index = Renderer

local AssetPreparationQueue = require("libs.hgss.src.presentation.AssetPreparationQueue")
local Errors = require("libs.errors.src.Errors")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local Button = require("libs.ui.src.Button")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")

---@class SaveEditorRenderer
---@field text table<string, unknown>
---@field graphics table<string, unknown>
---@field _disposed boolean
---@field _iconQueue table<string, unknown>?
---@field _iconProvider MonIconAssetProvider?
---@field _icons table<string, { image: love.Image, quad: love.Quad }>
---@field iconStatus string?
---@field iconFailure string?
---@field metrics fun(self: SaveEditorRenderer): { lineHeight: number, measure: fun(value: string): number }
---@field dispose fun(self: SaveEditorRenderer)
---@field prepareVisibleIcons fun(self: SaveEditorRenderer, view: table<string, unknown>, plan: table<string, unknown>, cacheFs: table<string, unknown>, derivedAssets: table<string, unknown>)

local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
local PALETTE = {
  background = { 0.91, 0.93, 0.91, 1 },
  ink = { 0.12, 0.16, 0.19, 1 },
  muted = { 0.34, 0.4, 0.43, 1 },
  error = { 0.68, 0.12, 0.12, 1 },
  border = { 0.2, 0.25, 0.28, 1 },
  rim = { 0.87, 0.9, 0.88, 1 },
  normal = {
    innerBorder = { 0.1, 0.34, 0.38, 1 },
    faceTop = { 0.48, 0.78, 0.78, 1 },
    faceBottom = { 0.29, 0.62, 0.64, 1 },
  },
  focused = {
    innerBorder = { 0.08, 0.29, 0.58, 1 },
    faceTop = { 0.69, 0.83, 0.98, 1 },
    faceBottom = { 0.39, 0.61, 0.84, 1 },
  },
  disabled = {
    innerBorder = { 0.48, 0.51, 0.5, 1 },
    faceTop = { 0.78, 0.8, 0.78, 1 },
    faceBottom = { 0.65, 0.68, 0.65, 1 },
  },
  destructive = {
    innerBorder = { 0.51, 0.2, 0.17, 1 },
    faceTop = { 0.91, 0.62, 0.54, 1 },
    faceBottom = { 0.76, 0.39, 0.32, 1 },
  },
  text = { normal = { foreground = { 0.12, 0.16, 0.19, 1 } }, hint = { foreground = { 0.34, 0.4, 0.43, 1 } } },
  cards = { normal = { border = { 0.2, 0.25, 0.28, 1 }, selectedRim = { 0.08, 0.29, 0.58, 1 } } },
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
  return setmetatable({
    text = options.text,
    skin = PALETTE,
    graphics = options.graphics or love.graphics,
    _disposed = false,
    _iconQueue = nil,
    _iconProvider = nil,
    _icons = {},
    iconStatus = nil,
    iconFailure = nil,
  }, Renderer)
end

function Renderer:prepareVisibleIcons(view, plan, cacheFs, derivedAssets)
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
  local color = role == "error" and renderer.skin.error
    or (role == "hint" or role == "information") and renderer.skin.muted
    or type(role) == "table" and role
    or renderer.skin.ink
  setColor(renderer.graphics, color)
  renderer.text:drawText(visibleText(renderer, value), x, y)
end

local function drawShadedControl(renderer, rect, label, selected, disabled, destructive)
  local state = disabled and renderer.skin.disabled
    or destructive and renderer.skin.destructive
    or selected and renderer.skin.focused
    or renderer.skin.normal
  local button = Button.resolve({
    rect = rect,
    borderWidth = 1,
    rimWidth = 1,
    innerBorderWidth = 1,
    cornerRadius = 3,
    faceSplit = 0.45,
    contentInsetX = 8,
    contentInsetY = 2,
  })
  Button.draw(renderer.graphics, button, {
    border = renderer.skin.border,
    rim = renderer.skin.rim,
    innerBorder = state.innerBorder,
    faceTop = state.faceTop,
    faceBottom = state.faceBottom,
  })
  local content = button.contentRect
  local textWidth = renderer.text:textWidth(label)
  assert(textWidth <= content.width, label .. " does not fit its shaded control")
  drawText(renderer, label, content.x + (content.width - textWidth) / 2, content.y + 2, disabled and "hint" or "normal")
end

local function fitText(renderer, value, width)
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

local drawLocation

local function paintPane(self, view, plan, pane)
  local graphics = self.graphics
  local layout = assert(plan.content.layout)
  local placement = pane.placement
  local INK = self.skin.text.normal.foreground
  local CARD = { 1, 1, 1, 1 }
  local BORDER = self.skin.cards.normal.border
  local SELECTED = self.skin.cards.normal.selectedRim
  local MUTED = self.skin.text.hint.foreground
  setColor(graphics, self.skin.background)
  graphics.rectangle("fill", 0, 0, placement.logicalWidth, placement.logicalHeight)
  for _, navigation in ipairs(layout.navigation) do
    local target = targetRect(layout, navigation.targetId)
    if target then
      drawShadedControl(self, target, navigation.label, navigation.targetId == ("section:" .. view.section), false)
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
    if rect then
      local target = assert(layout.targets[row.targetId])
      LogicalSurface.clip(graphics, target.clip or rect, function()
        local actionable = row.role == "action"
          or row.role == "toggle"
          or row.role == "integer value"
          or row.role == "named choice"
          or row.role == "party slot"
          or row.role == "bag item"
          or row.targetId:match("^party:slot:") ~= nil
          or row.targetId:match("^bag:item:") ~= nil
        if actionable then
          drawShadedControl(self, rect, row.label, row.targetId == view.focus, row.enabled == false)
        end
        local icon = row.iconKey and self._icons[row.iconKey]
        if icon and graphics.draw then
          graphics.draw(icon.image, icon.quad, rect.x + 3, rect.y + 2)
        end
        local labelRect = assert(row.labelRect, "layout rows own their label text bounds")
        local textRole = row.role == "warning" and "error" or row.role == "read-only value" and "hint" or "normal"
        if not actionable then
          drawText(self, fitText(self, row.label, labelRect.width), labelRect.x, rect.y + 3, textRole)
        end
        if row.valueText ~= nil and row.valueRect ~= nil then
          local valueRect = row.valueRect
          drawText(self, fitText(self, row.valueText, valueRect.width), valueRect.x, rect.y + 3)
        end
      end)
    end
  end
  if view.section == "Location" then
    drawLocation(self, view, layout)
  end
  if view.section == "Progress" then
    for _, id in ipairs({ "group-previous", "group-next" }) do
      local rect = targetRect(layout, id)
      if rect then
        setColor(graphics, BORDER)
        graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
        drawText(self, id == "group-previous" and "<" or ">", rect.x + 4, rect.y + 3, INK)
      end
    end
  end
  for _, action in ipairs(layout.actions) do
    local rect = targetRect(layout, action.id)
    if rect then
      local label = action.id == "save" and view.locationSave and "Cancel check" or action.label
      drawShadedControl(self, rect, label, action.id == view.focus, not action.enabled)
    end
  end
  if view.valueEditor then
    local dialog = view.valueEditor
    if dialog.kind == "choice" then
      drawText(self, "Search: " .. dialog.query, layout.content.x + 4, layout.content.y + 4, MUTED)
      local viewport = assert(layout.viewports["value:choice"])
      LogicalSurface.clip(graphics, viewport.clip, function()
        for _, option in ipairs(dialog.options) do
          local rect = targetRect(layout, "choice:" .. option.key)
          if rect then
            drawShadedControl(self, rect, option.label, option.key == dialog.selectedKey, false)
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
    else
      local validity = dialog.parsedValue
      local inRange = type(validity) == "number" and validity >= dialog.minimum and validity <= dialog.maximum
      drawText(self, dialog.buffer or "", layout.content.x + 5, layout.content.y + 30, INK)
      drawText(
        self,
        "Range " .. tostring(dialog.minimum) .. "-" .. tostring(dialog.maximum),
        layout.content.x + 5,
        layout.content.y + 46,
        MUTED
      )
      if view.editorFeedback or not inRange then
        drawText(
          self,
          view.editorFeedback or "Enter a whole number within the allowed range.",
          layout.content.x + 5,
          layout.content.y + 60,
          "error"
        )
      end
      for _, id in ipairs({ "digit-left", "digit-right", "digit-down", "digit-up", "confirm", "cancel" }) do
        local rect = targetRect(layout, id)
        if rect then
          setColor(graphics, BORDER)
          graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
          local labels = {
            ["digit-left"] = "Left",
            ["digit-right"] = "Right",
            ["digit-down"] = "-",
            ["digit-up"] = "+",
            confirm = "OK",
            cancel = "Cancel",
          }
          drawText(self, labels[id], rect.x + 3, rect.y + 3, INK)
        end
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
    local choices, prompt
    if view.modal == "draft" then
      choices, prompt = { "apply", "discard", "cancel" }, "Apply party changes?"
    elseif view.modal == "remove" then
      choices, prompt = { "remove", "cancel" }, "Remove this entry?"
    else
      choices, prompt = { "save", "discard", "cancel" }, "Save changes before leaving?"
    end
    drawText(self, prompt, layout.content.x + 8, layout.content.y + 18, CARD)
    for _, id in ipairs(choices) do
      local rect = targetRect(layout, id)
      if rect then
        local disabled = id == "apply" and view.partyValid ~= true
        drawShadedControl(self, rect, id:sub(1, 1):upper() .. id:sub(2), id == view.focus, disabled, id == "remove")
      end
    end
  end
end

drawLocation = function(self, view, layout)
  local graphics = self.graphics
  local INK = self.skin.text.normal.foreground
  local BORDER = self.skin.cards.normal.border
  local SELECTED = self.skin.cards.normal.selectedRim
  local MUTED = self.skin.text.hint.foreground
  local location = assert(view.location)
  local navigation = assert(view.locationNavigation)
  local grid = layout.locationGrid
  local tiles = {}
  for _, tile in ipairs(location.tiles or {}) do
    tiles[string.format("%d:%d", tile.fieldX, tile.fieldZ)] = tile
  end
  for _, targetId in ipairs({ "location:map-picker", "location:zoom-out", "location:zoom-in", "location:map-back" }) do
    local target = targetRect(layout, targetId)
    if target then
      setColor(graphics, targetId == view.focus and SELECTED or BORDER)
      graphics.rectangle("line", target.x, target.y, target.width, target.height)
      local label = targetId == "location:map-picker"
          and navigation.page == "map-list"
          and ("Search maps: " .. tostring(view.query or ""))
        or targetId == "location:map-picker" and "Change Map"
        or targetId == "location:zoom-out" and "−"
        or targetId == "location:zoom-in" and "+"
        or "Back"
      drawText(self, label, target.x + 4, target.y + 3, INK)
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
    local mapLabel = location.symbol or ("Map " .. tostring(location.mapId or "—"))
    local status = location.status
    local statusLabel = status.state == "ready" and "Ready"
      or status.state == "pending" and "Preparing map data"
      or status.reason
      or "Map unavailable"
    local mapLine = statusLayout.mapLine
    drawText(
      self,
      fitText(self, mapLabel .. " · " .. statusLabel, mapLine.width),
      mapLine.x,
      mapLine.y,
      status.state == "ready" and "information" or status.state == "failed" and "error" or "hint"
    )
    local function markerLabel(label, marker)
      if marker == nil then
        return label .. " —"
      end
      local markerMapName = "Map " .. tostring(marker.mapId)
      for _, candidate in ipairs(view.location.maps) do
        if candidate.mapId == marker.mapId then
          markerMapName = candidate.symbol
          break
        end
      end
      return string.format("%s %s %d,%d", label, markerMapName, marker.fieldX, marker.fieldZ)
    end
    local markerText = view.pendingLocation and markerLabel("Pending", view.pendingLocation) or nil
    local savedText = markerLabel("Saved", view.savedLocation)
    markerText = markerText and (markerText .. " · " .. savedText) or savedText
    local cursor = navigation.cursor
    if cursor then
      local inspected = tiles[string.format("%d:%d", cursor.fieldX, cursor.fieldZ)]
      local tileReason = inspected and inspected.reason or ""
      markerText = markerText .. " · " .. string.format("Cursor %d,%d %s", cursor.fieldX, cursor.fieldZ, tileReason)
    end
    local summaryLine = statusLayout.summaryLine
    drawText(self, fitText(self, markerText, summaryLine.width), summaryLine.x, summaryLine.y, INK)

    local helpLine = statusLayout.helpLine
    local help = "Physical only; story state unchecked."
    local helpWidth = self.text:textWidth(help)
    if helpWidth > helpLine.width then
      local scale = math.max(0, (helpLine.width - 1) / helpWidth)
      graphics.push("transform")
      graphics.translate(helpLine.x, helpLine.y)
      graphics.scale(scale, 1)
      graphics.translate(-helpLine.x, -helpLine.y)
      drawText(self, help, helpLine.x, helpLine.y, MUTED)
      graphics.pop()
    else
      drawText(self, fitText(self, help, helpLine.width), helpLine.x, helpLine.y, MUTED)
    end
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
    fitText(self, location.symbol or tostring(location.mapId), pane.placement.logicalWidth - 16),
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
  if self._iconProvider then
    self._iconProvider:release()
    self._iconProvider = nil
  end
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
