-- Renders the field Yes/No list in source coordinates under one host placement.

local FieldDrawState = require("libs.hgss.src.presentation.FieldDrawState")
local LogicalSurface = require("libs.ui.src.LogicalSurface")

---@alias FieldYesNoRenderer.Color { r: integer, g: integer, b: integer }
---@alias FieldYesNoRenderer.Palette { [integer]: FieldYesNoRenderer.Color }
---@alias FieldYesNoRenderer.TextPalette { foreground: FieldYesNoRenderer.Color, shadow: FieldYesNoRenderer.Color, background: FieldYesNoRenderer.Color }

---@class FieldYesNoRenderer.TextRenderer
---@field drawTextWithPalette fun(self: FieldYesNoRenderer.TextRenderer, text: string, x: number, y: number, palette: FieldYesNoRenderer.TextPalette)
---@class FieldYesNoRenderer.WindowRenderer
---@field drawWindow fun(self: FieldYesNoRenderer.WindowRenderer, box: table<string, number>, frameIndex: integer, background: number[])
---@field framePalette fun(self: FieldYesNoRenderer.WindowRenderer, frameIndex: integer): FieldYesNoRenderer.Palette
---@field drawStandardWindow fun(self: FieldYesNoRenderer.WindowRenderer, box: table<string, number>, background: number[])
---@field standardFramePalette fun(self: FieldYesNoRenderer.WindowRenderer): FieldYesNoRenderer.Palette

---@class FieldYesNoRenderer
---@field _graphics love.graphics
---@field _text FieldYesNoRenderer.TextRenderer
---@field _window FieldYesNoRenderer.WindowRenderer
local FieldYesNoRenderer = {}
FieldYesNoRenderer.__index = FieldYesNoRenderer

---@param palette FieldYesNoRenderer.Palette
---@return number[]
local function windowFill(palette)
  local color = assert(palette[15], "Yes/No window palette has no background color")
  return { color.r / 255, color.g / 255, color.b / 255, 1 }
end

---@param palette FieldYesNoRenderer.Palette
---@return FieldYesNoRenderer.TextPalette
local function textPalette(palette)
  return {
    foreground = assert(palette[1], "Yes/No window palette has no foreground color"),
    shadow = assert(palette[2], "Yes/No window palette has no shadow color"),
    background = assert(palette[15], "Yes/No window palette has no background color"),
  }
end

---@param opts { text: table<string, unknown>, window: table<string, unknown>, graphics?: love.graphics }
---@return FieldYesNoRenderer
function FieldYesNoRenderer.new(opts)
  assert(type(opts) == "table", "yes/no renderer options are required")
  local graphics = opts.graphics or assert(love.graphics)
  assert(graphics and graphics.setColor, "yes/no renderer requires love.graphics")
  local text = opts.text
  assert(text and type(text.drawTextWithPalette) == "function", "yes/no renderer requires the field text renderer")
  ---@cast text FieldYesNoRenderer.TextRenderer
  local window = opts.window
  assert(
    window
      and type(window.drawWindow) == "function"
      and type(window.framePalette) == "function"
      and type(window.drawStandardWindow) == "function"
      and type(window.standardFramePalette) == "function",
    "yes/no renderer requires the field window renderer"
  )
  ---@cast window FieldYesNoRenderer.WindowRenderer
  return setmetatable({ _graphics = graphics, _text = text, _window = window }, FieldYesNoRenderer)
end

-- Layout arrives from the live choice host, which owns the single geometry
-- shared by fixed-tick hit testing and this draw. This renderer never
-- resolves layout itself.
---@param status { selectedIndex: integer, yesText: string, noText: string, frameIndex: integer? }
---@param layout table<string, unknown>
function FieldYesNoRenderer:draw(status, layout)
  assert(type(status) == "table" and type(layout) == "table", "yes/no draw requires status and layout")
  assert(status.selectedIndex == 0 or status.selectedIndex == 1, "yes/no selection is outside the two choices")
  local box = assert(layout.content)
  local presentation = assert(layout.presentation)
  assert(presentation == "source" or presentation == "adapted", "yes/no layout has an unknown presentation")
  FieldDrawState.protectedDraw(self._graphics, function()
    LogicalSurface.draw(self._graphics, assert(layout.placement), function()
      local palette
      if presentation == "source" then
        palette = self._window:standardFramePalette()
        self._window:drawStandardWindow(box, windowFill(palette))
      else
        local frameIndex = assert(status.frameIndex, "adapted yes/no choice has no dialogue frame index")
        palette = self._window:framePalette(frameIndex)
        self._window:drawWindow(box, frameIndex, windowFill(palette))
      end
      local colors = textPalette(palette)
      self._text:drawTextWithPalette("‣", box.x, box.y + status.selectedIndex * 16, colors)
      self._text:drawTextWithPalette(assert(status.yesText), box.x + 8, box.y, colors)
      self._text:drawTextWithPalette(assert(status.noText), box.x + 8, box.y + 16, colors)
    end)
  end)
end

function FieldYesNoRenderer:release() end

return FieldYesNoRenderer
