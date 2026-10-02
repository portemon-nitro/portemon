-- Draws the app-native editor shell from its resolved view and plan.

local Renderer = {}
Renderer.__index = Renderer

local AssetPreparationQueue = require("libs.hgss.src.presentation.AssetPreparationQueue")
local Errors = require("libs.errors.src.Errors")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local ProductMenuSkin = require("app.src.ui.ProductMenuSkin")
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
  local versionId = options.versionId
  assert(type(versionId) == "string" and versionId ~= "", "save editor needs a game version")
  ---@cast versionId string
  return setmetatable({
    text = options.text,
    skin = ProductMenuSkin.forVersion(versionId),
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
  local textRole = type(role) == "string" and role or "normal"
  if role == renderer.skin.text.hint.foreground then
    textRole = "hint"
  elseif role == renderer.skin.text.information.foreground then
    textRole = "information"
  elseif role == renderer.skin.text.error.foreground then
    textRole = "error"
  end
  ProductMenuSkin.drawText(
    renderer.graphics,
    renderer.text,
    renderer.skin,
    textRole,
    visibleText(renderer, value),
    x,
    y
  )
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

local function wrapText(renderer, value, width)
  local lines, line = {}, ""
  for word in tostring(value or ""):gmatch("%S+") do
    local candidate = line == "" and word or (line .. " " .. word)
    if line ~= "" and renderer.text:textWidth(candidate) > width then
      lines[#lines + 1] = line
      line = word
    elseif line == "" then
      line = word
    else
      line = candidate
    end
  end
  if line ~= "" then
    lines[#lines + 1] = line
  end
  return lines
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
  ProductMenuSkin.drawCard(graphics, self.skin, layout.header, "normal", false, false)
  drawText(self, "Save Editor", layout.header.x + 5, layout.header.y + 3)
  if view.valueEditor and view.valueEditor.kind == "choice" then
    drawText(
      self,
      fitText(self, "Search: " .. (view.valueEditor.query or ""), layout.header.width - 10),
      layout.header.x + 5,
      layout.header.y + 17
    )
  elseif view.session then
    local identity = view.session.playerName .. " " .. view.session.versionId .. " " .. tostring(view.saveId or "")
    drawText(self, fitText(self, identity, layout.header.width - 10), layout.header.x + 5, layout.header.y + 17)
  end
  for _, navigation in ipairs(layout.navigation) do
    local target = targetRect(layout, navigation.targetId)
    if target then
      ProductMenuSkin.drawCard(
        graphics,
        self.skin,
        target,
        "inset",
        navigation.targetId == ("section:" .. view.section),
        false
      )
      drawText(self, navigation.label, target.x + 4, target.y + 3)
    end
  end
  if view.section == "Party" and (view.partyPage == "detail" or view.partyPage == "draft") then
    for _, subpage in ipairs(view.partySubpages or {}) do
      local id = "party:subpage:" .. subpage
      local target = targetRect(layout, id)
      if target then
        ProductMenuSkin.drawCard(graphics, self.skin, target, "inset", view.partySubpage == subpage, false)
        drawText(self, fitText(self, subpage, target.width - 6), target.x + 3, target.y + 3)
      end
    end
  end
  for _, row in ipairs(layout.rows) do
    local rect = targetRect(layout, row.targetId)
    if rect then
      local target = assert(layout.targets[row.targetId])
      LogicalSurface.clip(graphics, target.clip or rect, function()
        ProductMenuSkin.drawCard(
          graphics,
          self.skin,
          rect,
          row.value == nil and "normal" or "inset",
          row.targetId == view.focus,
          row.enabled == false
        )
        local icon = row.iconKey and self._icons[row.iconKey]
        if icon and graphics.draw then
          graphics.draw(icon.image, icon.quad, rect.x + 3, rect.y + 2)
        end
        local labelRect = assert(row.labelRect, "layout rows own their label text bounds")
        local textRole = row.role == "warning" and "error" or row.role == "read-only value" and "hint" or "normal"
        drawText(self, fitText(self, row.label, labelRect.width), labelRect.x, rect.y + 3, textRole)
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
      ProductMenuSkin.drawCard(graphics, self.skin, rect, "normal", action.id == view.focus, not action.enabled)
      local label = action.id == "save" and view.locationSave and "Cancel check" or action.label
      drawText(self, label, rect.x + 4, rect.y + 4, action.enabled and "normal" or "hint")
    end
  end
  local footerMessage = view.locationSave and "Checking destination · Save cancels"
    or (view.dirty and "Unsaved changes" or "Saved")
  local footerRole = "normal"
  if layout.focusedValueHelp then
    footerMessage = "Full value · " .. layout.focusedValueHelp
    footerRole = "hint"
  end
  drawText(
    self,
    fitText(self, footerMessage, layout.footer.width - 8),
    layout.footer.x + 4,
    layout.footer.y + 2,
    footerRole
  )
  if view.valueEditor then
    local dialog = view.valueEditor
    ProductMenuSkin.drawCard(graphics, self.skin, layout.content, "normal", false, false)
    if dialog.kind == "choice" then
      local groupPrevious = assert(targetRect(layout, "group-previous"))
      local clearSearch = assert(targetRect(layout, "clear-search"))
      local groupNext = assert(targetRect(layout, "group-next"))
      ProductMenuSkin.drawCard(graphics, self.skin, groupPrevious, "inset", false, false)
      ProductMenuSkin.drawCard(graphics, self.skin, clearSearch, "inset", false, false)
      ProductMenuSkin.drawCard(graphics, self.skin, groupNext, "inset", false, false)
      drawText(self, "Group " .. (dialog.group or "All"), groupPrevious.x + 3, groupPrevious.y + 3, INK)
      drawText(self, "Clear", clearSearch.x + 3, clearSearch.y + 3, INK)
      drawText(self, "Next group", groupNext.x + 3, groupNext.y + 3, INK)
      local viewport = assert(layout.viewports["value:choice"])
      LogicalSurface.clip(graphics, viewport.clip, function()
        for _, option in ipairs(dialog.options) do
          local rect = targetRect(layout, "choice:" .. option.key)
          if rect then
            ProductMenuSkin.drawCard(graphics, self.skin, rect, "normal", option.key == dialog.selectedKey, false)
            drawText(self, fitText(self, option.label, rect.width - 8), rect.x + 4, rect.y + 3, INK)
          end
        end
      end)
      if dialog.empty then
        drawText(
          self,
          "No matching choices. Clear search or change group.",
          viewport.clip.x + 3,
          viewport.clip.y + 3,
          "hint"
        )
      end
      for _, id in ipairs({ "confirm", "cancel" }) do
        local rect = targetRect(layout, id)
        assert(rect)
        local disabled = id == "confirm" and dialog.empty == true
        ProductMenuSkin.drawCard(graphics, self.skin, rect, "normal", id == view.focus, disabled)
        drawText(self, id == "cancel" and "Cancel" or "Choose", rect.x + 3, rect.y + 3, disabled and "hint" or "normal")
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
    ProductMenuSkin.drawCard(graphics, self.skin, layout.content, "normal", false, false)
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
        ProductMenuSkin.drawCard(graphics, self.skin, rect, "normal", id == view.focus, false)
        drawText(self, id:sub(1, 1):upper() .. id:sub(2), rect.x + 4, rect.y + 6)
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

  local statusY = grid and (grid.clip.y + grid.clip.height + 2) or (layout.content.y + 30)
  local mapLabel = location.symbol or ("Map " .. tostring(location.mapId or "—"))
  local status = location.status
  local statusLabel = status.state == "ready" and "Ready"
    or status.state == "pending" and "Preparing map data"
    or status.reason
    or "Map unavailable"
  drawText(
    self,
    fitText(self, mapLabel .. " · " .. statusLabel, layout.content.width - 8),
    layout.content.x + 4,
    statusY,
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
  local markerText = markerLabel("Saved", view.savedLocation)
  if view.pendingLocation then
    markerText = markerText .. " · " .. markerLabel("Pending", view.pendingLocation)
  end
  drawText(self, fitText(self, markerText, layout.content.width - 8), layout.content.x + 4, statusY + 28, INK)
  local cursor = navigation.cursor
  if cursor then
    local inspected = tiles[string.format("%d:%d", cursor.fieldX, cursor.fieldZ)]
    local tileReason = inspected and inspected.reason or ""
    drawText(
      self,
      fitText(
        self,
        string.format("Global tile %d, %d %s", cursor.fieldX, cursor.fieldZ, tileReason),
        layout.content.width - 8
      ),
      layout.content.x + 4,
      statusY + 42,
      INK
    )
  end
  local help = "Physical placement only; story consistency isn't checked."
  for _, row in ipairs(layout.rows) do
    if row.targetId == "location:help" then
      help = row.label
      break
    end
  end
  for lineIndex, line in ipairs(wrapText(self, help, layout.content.width - 8)) do
    drawText(self, line, layout.content.x + 4, statusY + 56 + (lineIndex - 1) * 14, MUTED)
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
          drawText(self, view.dirty and "Unsaved changes" or "Saved", 8, 26, view.dirty and "information" or "hint")
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
