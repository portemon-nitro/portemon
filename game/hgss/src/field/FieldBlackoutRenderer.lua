-- Draws the retail blackout message in its source window and palette.

local DialogueLayout = require("libs.hgss.src.ui.DialogueLayout")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")

local FieldBlackoutRenderer = {}

local BOX = { x = 32, y = 40, width = 200, height = 120 }
local FRAME_PALETTE = 13
local LINE_HEIGHT = 16
local TEXT_X_ADJUSTMENT = -4
-- `blackout.c::Blackout_PrintMessage` uses MAKE_TEXT_COLOR(1, 2, 0).
local TEXT_COLORS = { foreground = 1, shadow = 2, background = 0 }

local function sourceColor(text, slot)
  local palette = assert(text.fontDef.palette, "blackout field font has no color palette")
  return assert(palette[slot + 1], "blackout text palette slot is missing")
end

local function sourceWindowColor(color)
  local red = assert(tonumber(color.r or color[1]))
  local green = assert(tonumber(color.g or color[2]))
  local blue = assert(tonumber(color.b or color[3]))
  if red > 1 or green > 1 or blue > 1 then
    red, green, blue = red / 255, green / 255, blue / 255
  end
  return { red, green, blue, 1 }
end

---@param status FieldBlackoutStatus
---@param window FieldWindowRenderer
---@param text FieldTextRenderer
---@param bounds { x: number, y: number, width: number, height: number }
function FieldBlackoutRenderer.draw(status, window, text, bounds)
  local message = assert(status.message, "blackout presentation requires a formatted message")
  local formattedTokens = assert(message.tokens, "blackout message has no formatted tokens")
  local layout = DialogueLayout.layout(formattedTokens, FieldDialogueTheme.fontMetrics(text.fontDef), {
    width = BOX.width,
    maxLines = #formattedTokens + 1,
    sourcePositioned = true,
  })
  local lines = {}
  for _, page in ipairs(layout.pages) do
    for _, line in ipairs(page.lines) do
      lines[#lines + 1] = line
    end
  end
  local lg = love.graphics
  local scale = math.min(bounds.width / 256, bounds.height / 192)
  local originX = bounds.x + (bounds.width - 256 * scale) / 2
  local originY = bounds.y + (bounds.height - 192 * scale) / 2
  lg.push("all")
  lg.push()
  lg.translate(originX, originY)
  lg.scale(scale, scale)
  lg.setColor(1, 1, 1, 1)
  lg.rectangle("fill", 0, 0, 256, 192)
  local background = sourceColor(text, TEXT_COLORS.background)
  window:drawWindow(BOX, FRAME_PALETTE, sourceWindowColor(background))
  local palette = {
    foreground = sourceColor(text, TEXT_COLORS.foreground),
    shadow = sourceColor(text, TEXT_COLORS.shadow),
    background = background,
  }
  local maxWidth = 0
  for _, line in ipairs(lines) do
    maxWidth = math.max(maxWidth, line.width)
  end
  local textX = BOX.x + (BOX.width - maxWidth) / 2 + TEXT_X_ADJUSTMENT
  local lineY = BOX.y
  for _, line in ipairs(lines) do
    text:drawLineWithPalette(line.tokens, textX, lineY, palette)
    lineY = lineY + LINE_HEIGHT
  end
  lg.pop()
  lg.pop()
end

return FieldBlackoutRenderer
