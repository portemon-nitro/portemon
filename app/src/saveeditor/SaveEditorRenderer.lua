-- Draws the app-native editor shell from its resolved view and plan.

local Renderer = {}
Renderer.__index = Renderer

---@class SaveEditorRenderer
---@field text table<string, unknown>
---@field graphics table<string, unknown>
---@field _disposed boolean
---@field dispose fun(self: SaveEditorRenderer)

local INK = { 0.12, 0.18, 0.25, 1 }
local CARD = { 1, 1, 1, 1 }
local BORDER = { 0.2, 0.32, 0.4, 1 }
local SELECTED = { 0.84, 0.19, 0.2, 1 }
local MUTED = { 0.42, 0.48, 0.52, 1 }
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

local function setColor(graphics, color)
  graphics.setColor(color[1], color[2], color[3], color[4] or 1)
end

function Renderer.new(options)
  assert(type(options) == "table" and options.text, "save editor renderer needs field text")
  return setmetatable(
    { text = options.text, graphics = options.graphics or love.graphics, _disposed = false },
    Renderer
  )
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
  for _, row in ipairs(layout.rows) do
    local rect = layout.targets[row.targetId]
    if rect then
      setColor(graphics, row.targetId == view.focus and SELECTED or BORDER)
      graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
      local labelWidth = row.role == "warning" and rect.width - 8 or rect.width * 0.5 - 8
      drawText(self, fitText(row.label, labelWidth), rect.x + 4, rect.y + 3, INK)
      if row.value ~= nil then
        local value = type(row.value) == "boolean" and (row.value and "ON" or "OFF") or tostring(row.value)
        local valueX = rect.x + math.min(rect.width * 0.52, 128)
        drawText(self, fitText(value, rect.x + rect.width - valueX - 4), valueX, rect.y + 3, INK)
      end
    end
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
  if view.modal then
    graphics.setColor(0, 0, 0, 0.78)
    graphics.rectangle("fill", layout.content.x, layout.content.y, layout.content.width, layout.content.height)
    drawText(self, "Save changes before leaving?", layout.content.x + 8, layout.content.y + 18, CARD)
    for _, id in ipairs({ "save", "discard", "cancel" }) do
      local rect = layout.targets[id]
      setColor(graphics, id == view.focus and SELECTED or BORDER)
      graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
      drawText(self, id:sub(1, 1):upper() .. id:sub(2), rect.x + 4, rect.y + 6, CARD)
    end
  end
  graphics.pop()
end

function Renderer:draw(view, plan)
  assert(not self._disposed, "disposed save editor renderer cannot draw")
  local graphics = self.graphics
  for _, pane in ipairs(plan.panes) do
    if pane.interactive then
      paintPane(self, view, plan, pane)
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

function Renderer:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  if self.text and self.text.release then
    self.text:release()
  end
  self.text = nil
end

return Renderer
