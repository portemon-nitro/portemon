-- Draws the app-native editor shell from its resolved view and plan.

local Renderer = {}
Renderer.__index = Renderer

local AssetPreparationQueue = require("libs.hgss.src.presentation.AssetPreparationQueue")
local Errors = require("libs.errors.src.Errors")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")

---@class SaveEditorRenderer
---@field text table<string, unknown>
---@field graphics table<string, unknown>
---@field _disposed boolean
---@field _iconQueue table<string, unknown>?
---@field _iconProvider MonIconAssetProvider?
---@field _icons table<string, { image: love.Image, quad: love.Quad }>
---@field iconStatus string?
---@field iconFailure string?
---@field dispose fun(self: SaveEditorRenderer)
---@field prepareVisibleIcons fun(self: SaveEditorRenderer, view: table<string, unknown>, plan: table<string, unknown>, cacheFs: table<string, unknown>, derivedAssets: table<string, unknown>)

local INK = { 0.12, 0.18, 0.25, 1 }
local CARD = { 1, 1, 1, 1 }
local BORDER = { 0.2, 0.32, 0.4, 1 }
local SELECTED = { 0.84, 0.19, 0.2, 1 }
local MUTED = { 0.42, 0.48, 0.52, 1 }
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

---@param cacheFs table<string, unknown>
---@param options table<string, unknown>
---@return MonIconAssetProvider|Errors.Error
local function createIconProvider(cacheFs, options)
  return MonIconAssetProvider.new(cacheFs, options)
end

local function setColor(graphics, color)
  graphics.setColor(color[1], color[2], color[3], color[4] or 1)
end

function Renderer.new(options)
  assert(type(options) == "table" and options.text, "save editor renderer needs field text")
  return setmetatable({
    text = options.text,
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

local function drawText(renderer, value, x, y, color)
  renderer.graphics.setColor(color[1], color[2], color[3], color[4] or 1)
  renderer.text:drawText(tostring(value or ""), x, y)
end

local function fitText(value, width)
  local text = tostring(value or "")
  local limit = math.max(1, math.floor(width / 8))
  local glyphs = {}
  for glyph in Utf8Glyphs.iter(text) do
    glyphs[#glyphs + 1] = glyph
  end
  if #glyphs > limit then
    local visible = {}
    for index = 1, math.max(1, limit - 1) do
      visible[index] = glyphs[index]
    end
    visible[#visible + 1] = "…"
    return table.concat(visible)
  end
  return text
end

local function wrapText(value, width)
  local limit = math.max(1, math.floor(width / 8))
  local lines, line = {}, ""
  for word in tostring(value or ""):gmatch("%S+") do
    if line ~= "" and #line + 1 + #word > limit then
      lines[#lines + 1] = line
      line = word
    elseif line == "" then
      line = word
    else
      line = line .. " " .. word
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
  graphics.push()
  graphics.translate(placement.frame.x, placement.frame.y)
  graphics.scale(placement.scale, placement.scale)
  graphics.setColor(0.93, 0.94, 0.92, 1)
  graphics.rectangle("fill", 0, 0, placement.logicalWidth, placement.logicalHeight)
  setColor(graphics, BORDER)
  graphics.rectangle("fill", layout.header.x, layout.header.y, layout.header.width, layout.header.height)
  drawText(self, "Save Editor", layout.header.x + 5, layout.header.y + 3, CARD)
  if view.session then
    local identity = view.session.playerName .. " " .. view.session.versionId .. " " .. tostring(view.saveId or "")
    drawText(self, fitText(identity, layout.header.width - 10), layout.header.x + 5, layout.header.y + 17, CARD)
  end
  for _, navigation in ipairs(layout.navigation) do
    local rect = layout.targets[navigation.targetId]
    setColor(graphics, navigation.targetId == ("section:" .. view.section) and SELECTED or BORDER)
    graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
    drawText(self, navigation.label, rect.x + 4, rect.y + 3, INK)
  end
  if view.section == "Party" and (view.partyPage == "detail" or view.partyPage == "draft") then
    for _, subpage in ipairs(view.partySubpages or {}) do
      local id = "party:subpage:" .. subpage
      local rect = layout.targets[id]
      if rect then
        setColor(graphics, view.partySubpage == subpage and SELECTED or BORDER)
        graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
        drawText(self, fitText(subpage, rect.width - 6), rect.x + 3, rect.y + 3, CARD)
      end
    end
  end
  for _, row in ipairs(layout.rows) do
    local rect = layout.targets[row.targetId]
    if rect then
      setColor(graphics, row.targetId == view.focus and SELECTED or BORDER)
      graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
      local labelWidth = row.role == "warning" and rect.width - 8 or rect.width * 0.5 - 8
      local icon = row.iconKey and self._icons[row.iconKey]
      local labelX = rect.x + 4
      if icon and graphics.draw then
        graphics.draw(icon.image, icon.quad, rect.x + 3, rect.y + 2)
        labelX = rect.x + 22
        labelWidth = labelWidth - 18
      end
      drawText(self, fitText(row.label, labelWidth), labelX, rect.y + 3, INK)
      if row.value ~= nil then
        local value = type(row.value) == "boolean" and (row.value and "ON" or "OFF") or tostring(row.value)
        local valueX = rect.x + math.min(rect.width * 0.52, 128)
        drawText(self, fitText(value, rect.x + rect.width - valueX - 4), valueX, rect.y + 3, INK)
      end
    end
  end
  if view.section == "Location" then
    drawLocation(self, view, layout)
  end
  if view.section == "Progress" then
    for _, id in ipairs({ "group-previous", "group-next" }) do
      local rect = layout.targets[id]
      setColor(graphics, BORDER)
      graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
      drawText(self, id == "group-previous" and "<" or ">", rect.x + 4, rect.y + 3, INK)
    end
  end
  for _, action in ipairs(layout.actions) do
    local rect = layout.targets[action.id]
    setColor(graphics, action.enabled and BORDER or MUTED)
    graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
    drawText(self, action.label, rect.x + 4, rect.y + 4, CARD)
  end
  drawText(self, view.dirty and "Unsaved changes" or "Saved", layout.footer.x + 4, layout.footer.y + 2, INK)
  if view.valueEditor then
    local dialog = view.valueEditor
    graphics.setColor(0.96, 0.97, 0.96, 1)
    graphics.rectangle("fill", layout.content.x, layout.content.y, layout.content.width, layout.content.height)
    if dialog.kind == "choice" then
      local groupPrevious = layout.targets["group-previous"]
      local groupNext = layout.targets["group-next"]
      drawText(self, "Search: " .. (dialog.query or ""), layout.content.x + 4, layout.content.y + 2, INK)
      setColor(graphics, BORDER)
      graphics.rectangle("line", groupPrevious.x, groupPrevious.y, groupPrevious.width, groupPrevious.height)
      graphics.rectangle("line", groupNext.x, groupNext.y, groupNext.width, groupNext.height)
      drawText(self, "Group " .. (dialog.group or "All"), groupPrevious.x + 3, groupPrevious.y + 3, INK)
      drawText(self, "Next group", groupNext.x + 3, groupNext.y + 3, INK)
      for index, option in ipairs(dialog.options) do
        local rect = layout.targets[option.key]
        setColor(graphics, index == dialog.index and SELECTED or BORDER)
        graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
        drawText(self, fitText(option.label, rect.width - 8), rect.x + 4, rect.y + 3, INK)
      end
      drawText(
        self,
        "Page " .. dialog.page .. "/" .. dialog.pageCount,
        layout.content.x + 4,
        layout.content.y + layout.content.height - 24,
        INK
      )
      for _, id in ipairs({ "page-previous", "page-next", "cancel" }) do
        local rect = layout.targets[id]
        setColor(graphics, BORDER)
        graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
        drawText(
          self,
          id == "cancel" and "Cancel" or id == "page-next" and "Next" or "Previous",
          rect.x + 3,
          rect.y + 3,
          INK
        )
      end
    elseif dialog.kind == "name" then
      local naming = dialog.naming
      drawText(self, naming.text, layout.content.x + 4, layout.content.y + 3, INK)
      for row = 1, 6 do
        for column = 1, 13 do
          local id = row .. ":" .. column
          local rect = layout.targets[id]
          local cell = naming.grid[row][column]
          setColor(graphics, naming.cursor.row == row and naming.cursor.column == column and SELECTED or BORDER)
          graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
          drawText(self, cell.glyph or "", rect.x + 2, rect.y + 2, INK)
        end
      end
      for _, control in ipairs(naming.controls) do
        local id = "name-control:" .. control.id
        local rect = layout.targets[id]
        setColor(graphics, BORDER)
        graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
        drawText(self, control.label, rect.x + 2, rect.y + 2, INK)
      end
      for _, id in ipairs({ "confirm", "cancel" }) do
        local rect = layout.targets[id]
        setColor(graphics, BORDER)
        graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
        drawText(self, id == "confirm" and "OK" or "Cancel", rect.x + 3, rect.y + 3, INK)
      end
    else
      drawText(self, dialog.buffer or "", layout.content.x + 5, layout.content.y + 36, INK)
      for _, id in ipairs({ "digit-left", "digit-right", "digit-down", "digit-up", "confirm", "cancel" }) do
        local rect = layout.targets[id]
        if rect then
          setColor(graphics, BORDER)
          graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
          drawText(self, id:gsub("digit-", ""), rect.x + 3, rect.y + 3, INK)
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
      MUTED
    )
  elseif view.iconStatus == "failed" then
    drawText(self, "Icons unavailable", layout.content.x + 4, layout.content.y + layout.content.height - 16, MUTED)
  end
  if view.modal then
    graphics.setColor(0, 0, 0, 0.78)
    graphics.rectangle("fill", layout.content.x, layout.content.y, layout.content.width, layout.content.height)
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
      local rect = layout.targets[id]
      if rect then
        setColor(graphics, id == view.focus and SELECTED or BORDER)
        graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
        drawText(self, id:sub(1, 1):upper() .. id:sub(2), rect.x + 4, rect.y + 6, CARD)
      end
    end
  end
  graphics.pop()
end

drawLocation = function(self, view, layout)
  local graphics = self.graphics
  local location = assert(view.location)
  local navigation = assert(view.locationNavigation)
  local grid = layout.locationGrid
  local tiles = {}
  for _, tile in ipairs(location.tiles or {}) do
    tiles[string.format("%d:%d", tile.fieldX, tile.fieldZ)] = tile
  end
  for _, targetId in ipairs({ "location:map-picker", "location:zoom-out", "location:zoom-in", "location:map-back" }) do
    local target = layout.targets[targetId]
    if target then
      setColor(graphics, targetId == view.focus and SELECTED or BORDER)
      graphics.rectangle("line", target.x, target.y, target.width, target.height)
      local label = targetId == "location:map-picker" and "Change Map"
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
    local original = location.original or view.session.location
    local draft = location.draft or view.session.location
    for row = 0, grid.rows - 1 do
      for column = 0, grid.columns - 1 do
        local fieldX = grid.firstFieldX + column
        local fieldZ = grid.firstFieldZ + row
        local key = string.format("%d:%d", fieldX, fieldZ)
        local tile = tiles[key]
        local x = grid.originX + column * grid.tileSize
        local y = grid.originY + row * grid.tileSize
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
        if original and fieldX == original.fieldX and fieldZ == original.fieldZ then
          setColor(graphics, { 0.16, 0.38, 0.72, 1 })
          graphics.rectangle("line", x + 2, y + 2, grid.tileSize - 4, grid.tileSize - 4)
        end
        if draft and fieldX == draft.fieldX and fieldZ == draft.fieldZ then
          setColor(graphics, { 0.83, 0.23, 0.18, 1 })
          graphics.rectangle("line", x + 4, y + 4, grid.tileSize - 8, grid.tileSize - 8)
        end
        local cursor = navigation.cursor
        if cursor and fieldX == cursor.fieldX and fieldZ == cursor.fieldZ then
          setColor(graphics, { 0.12, 0.18, 0.25, 1 })
          graphics.rectangle("line", x + 1, y + 1, grid.tileSize - 2, grid.tileSize - 2)
        end
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
    fitText(mapLabel .. " · " .. statusLabel, layout.content.width - 8),
    layout.content.x + 4,
    statusY,
    INK
  )
  local cursor = navigation.cursor
  if cursor then
    local inspected = tiles[string.format("%d:%d", cursor.fieldX, cursor.fieldZ)]
    local tileReason = inspected and inspected.reason or ""
    drawText(
      self,
      fitText(
        string.format("Global tile %d, %d %s", cursor.fieldX, cursor.fieldZ, tileReason),
        layout.content.width - 8
      ),
      layout.content.x + 4,
      statusY + 14,
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
  for lineIndex, line in ipairs(wrapText(help, layout.content.width - 8)) do
    drawText(self, line, layout.content.x + 4, statusY + 28 + (lineIndex - 1) * 14, MUTED)
  end
end

local function paintLocationContext(self, view, pane)
  local graphics = self.graphics
  local location = assert(view.location)
  graphics.push()
  graphics.translate(pane.placement.frame.x, pane.placement.frame.y)
  graphics.scale(pane.placement.scale, pane.placement.scale)
  graphics.setColor(0.88, 0.9, 0.88, 1)
  graphics.rectangle("fill", 0, 0, pane.placement.logicalWidth, pane.placement.logicalHeight)
  drawText(self, "Location context", 8, 8, INK)
  drawText(self, fitText(location.symbol or tostring(location.mapId), pane.placement.logicalWidth - 16), 8, 28, INK)
  local current = location.original or view.session.location
  drawText(self, string.format("Current %d, %d", current.fieldX, current.fieldZ), 8, 46, INK)
  local status = location.status
  drawText(self, status.state == "ready" and "Map ready" or status.reason or "Preparing map data", 8, 64, MUTED)
  graphics.pop()
end

function Renderer:draw(view, plan)
  assert(not self._disposed, "disposed save editor renderer cannot draw")
  local graphics = self.graphics
  for _, pane in ipairs(plan.panes) do
    if pane.interactive then
      paintPane(self, view, plan, pane)
    else
      if view.section == "Location" then
        paintLocationContext(self, view, pane)
      else
        graphics.push()
        graphics.translate(pane.placement.frame.x, pane.placement.frame.y)
        graphics.scale(pane.placement.scale, pane.placement.scale)
        graphics.setColor(0.88, 0.9, 0.88, 1)
        graphics.rectangle("fill", 0, 0, pane.placement.logicalWidth, pane.placement.logicalHeight)
        graphics.pop()
      end
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
