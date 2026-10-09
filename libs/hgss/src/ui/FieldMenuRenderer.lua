-- Draws a resolved field-menu presentation snapshot as a framed list in the
-- layout's reference space. It neither reads item result values nor decides
-- cancellation policy; those stay in the controller and script task
-- respectively.

local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local ListSurface = require("libs.ui.src.ListSurface")
local LogicalSurface = require("libs.ui.src.LogicalSurface")

local SELECTED_MARKER = { 0.86, 0.16, 0.18, 1 }
local CANCEL_COLOR = { 0.42, 0.12, 0.16, 1 }

---@class FieldMenuRenderer
---@field _graphics love.graphics
---@field _text FieldTextRenderer
---@field _window FieldWindowRenderer
local FieldMenuRenderer = {}
FieldMenuRenderer.__index = FieldMenuRenderer

local function assertPresentation(presentation, frameIndex)
  assert(type(presentation) == "table" and type(presentation.status) == "table", "field menu renderer requires status")
  assert(
    type(frameIndex) == "number" and frameIndex % 1 == 0 and frameIndex >= 0,
    "field menu renderer requires the player's frame index"
  )
  local status = presentation.status
  assert(type(status.selectedIndex) == "number", "field menu status requires a selected index")
  local layout = presentation.layout
  assert(
    type(layout) == "table" and layout.placement and layout.listSurface and layout.scrollViewport,
    "field menu renderer requires a resolved layout"
  )
  assert(
    type(layout.itemCount) == "number"
      and layout.itemCount % 1 == 0
      and layout.itemCount >= 0
      and type(layout.rows) == "table"
      and type(layout.itemTexts) == "table",
    "resolved layout requires item geometry and text"
  )
  assert(
    status.selectedIndex % 1 == 0 and status.selectedIndex >= 0 and status.selectedIndex < layout.itemCount,
    "field menu selected index is outside the resolved layout"
  )
  return status, layout
end

---@param opts { graphics?: love.graphics, text: FieldTextRenderer, window: FieldWindowRenderer }
---@return FieldMenuRenderer
function FieldMenuRenderer.new(opts)
  assert(type(opts) == "table", "field menu renderer options must be a table")
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.rectangle and graphics.push, "FieldMenuRenderer requires love.graphics")
  assert(
    type(opts.text) == "table" and type(opts.text.drawTextWithPalette) == "function" and opts.text.fontDef,
    "FieldMenuRenderer requires the field text renderer"
  )
  assert(
    type(opts.window) == "table" and type(opts.window.drawApplicationFrame) == "function",
    "FieldMenuRenderer requires the field window renderer"
  )
  return setmetatable({ _graphics = graphics, _text = opts.text, _window = opts.window }, FieldMenuRenderer)
end

function FieldMenuRenderer:_drawList(status, layout, frameIndex)
  local graphics = self._graphics
  local box = layout.listSurface.surface
  local background = self._text:windowBackgroundColor()
  graphics.setColor(background[1], background[2], background[3], background[4])
  graphics.rectangle("fill", box.x, box.y, box.width, box.height)
  self._window:drawApplicationFrame(box, frameIndex)
  local palette = FieldTextRenderer.dialoguePalette(self._text.fontDef)
  LogicalSurface.clip(graphics, layout.scrollViewport, function()
    for _, row in ipairs(layout.rows) do
      if row.itemIndex == status.selectedIndex then
        ListSurface.drawMarker(graphics, row.marker, row.markerRadius, SELECTED_MARKER)
      end
      self._text:drawTextWithPalette(
        assert(layout.itemTexts[row.itemIndex], "resolved layout item text is missing"),
        row.labelRect.x,
        row.labelRect.y,
        palette
      )
    end
  end)
end

function FieldMenuRenderer:_drawScrollIndicators(layout)
  if layout.maxScrollOffset <= 0 then
    return
  end
  local graphics = self._graphics
  local viewport = layout.scrollViewport
  local x = viewport.x + viewport.width - 4
  graphics.setColor(SELECTED_MARKER[1], SELECTED_MARKER[2], SELECTED_MARKER[3], SELECTED_MARKER[4])
  if layout.scrollOffset > 0 then
    graphics.polygon("fill", x - 3, viewport.y + 4, x + 3, viewport.y + 4, x, viewport.y)
  end
  if layout.scrollOffset < layout.maxScrollOffset then
    local bottom = viewport.y + viewport.height
    graphics.polygon("fill", x - 3, bottom - 4, x + 3, bottom - 4, x, bottom)
  end
end

function FieldMenuRenderer:_drawCancel(layout, palette)
  local rect = layout.cancelRect
  if not rect then
    return
  end
  local graphics = self._graphics
  graphics.setColor(CANCEL_COLOR[1], CANCEL_COLOR[2], CANCEL_COLOR[3], CANCEL_COLOR[4])
  graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height)
  self._text:drawTextWithPalette("Cancel", rect.x + 8, rect.y + (rect.height - 16) / 2, palette)
end

-- Draws one active menu from an immutable presentation snapshot. The renderer
-- does not resolve text, reconstruct interaction state, or mutate the snapshot.

---@param presentation { status: { selectedIndex: integer }, layout: table<string, unknown> }
---@param frameIndex integer the player's chosen window frame
function FieldMenuRenderer:draw(presentation, frameIndex)
  local status, layout = assertPresentation(presentation, frameIndex)
  local graphics = self._graphics
  graphics.push("all")
  LogicalSurface.draw(graphics, layout.placement, function()
    self:_drawList(status, layout, frameIndex)
    self:_drawScrollIndicators(layout)
    self:_drawCancel(layout, FieldTextRenderer.dialoguePalette(self._text.fontDef))
  end)
  graphics.pop()
end

return FieldMenuRenderer
