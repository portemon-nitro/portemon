-- Text button composing the generic Button geometry with caller-owned colors.

local Button = require("libs.ui.src.Button")
local PixelScale = require("libs.ui.src.PixelScale")

---@class TextAdapter
---@field measure fun(label:string):number
---@field lineHeight number
---@field draw fun(label:string, x:number, y:number)

local TextButton = {}

TextButton.REFERENCE_WIDTH = 120
TextButton.REFERENCE_HEIGHT = 56

local FOCUS_OUTER_WIDTH = 5
local FOCUS_INNER_WIDTH = 3
local FOCUS_PATH_INSET = 1

-- Shared immutable default palette, borrowed by reference on every paint.
-- Draw callers either omit colors or supply one complete palette; paint
-- never copies or merges this record.
local DEFAULT_COLORS = {
  border = { 66 / 255, 66 / 255, 66 / 255, 1 },
  rim = { 230 / 255, 230 / 255, 222 / 255, 1 },
  innerBorder = { 25 / 255, 189 / 255, 197 / 255, 1 },
  faceTop = { 49 / 255, 222 / 255, 230 / 255, 1 },
  faceBottom = { 8 / 255, 156 / 255, 165 / 255, 1 },
  focusOuter = { 1, 1, 1, 1 },
  focusInner = { 1, 0, 0, 1 },
}

local function finite(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function rectangle(value, name)
  assert(type(value) == "table", name .. " is required")
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    assert(finite(value[field]), name .. " fields must be finite numbers")
  end
  assert(value.width > 0 and value.height > 0, name .. " must have positive dimensions")
  return { x = value.x, y = value.y, width = value.width, height = value.height }
end

---@param spec { rect: {x:number,y:number,width:number,height:number}, scale: number, cornerRadius?: number }
---@return table<string, unknown>
function TextButton.resolve(spec)
  assert(type(spec) == "table", "text button specification is required")
  local rectValue = rectangle(spec.rect, "text button rectangle")
  local scale = PixelScale.assertInteger(spec.scale)
  local cornerRadius = 3
  if spec.cornerRadius ~= nil then
    assert(
      type(spec.cornerRadius) == "number" and finite(spec.cornerRadius) and spec.cornerRadius >= 0,
      "text button corner radius must be a finite non-negative number"
    )
    cornerRadius = spec.cornerRadius
  end
  local resolved = Button.resolve({
    rect = rectValue,
    borderWidth = 2 * scale,
    rimWidth = 1 * scale,
    innerBorderWidth = 1 * scale,
    cornerRadius = cornerRadius * scale,
    faceSplit = 0.5,
    contentInsetX = 4 * scale,
    contentInsetY = 12 * scale,
  })
  resolved.scale = scale
  return resolved
end

local function drawFaceDivider(graphics, button, colors)
  local scale = button.scale
  local innerRect = button.innerBorder.rect
  local splitY = button.face.splitY
  local divider = colors.innerBorder
  graphics.setColor(divider[1], divider[2], divider[3], divider[4])
  graphics.rectangle("fill", innerRect.x, splitY - scale, innerRect.width, 2 * scale)
end

local function drawFocusOutline(graphics, button, colors)
  local scale = button.scale
  local outlineRect = button.rect
  local resolvedRadius = button.border.cornerRadius
  local outerWidth = FOCUS_OUTER_WIDTH * scale
  local innerWidth = FOCUS_INNER_WIDTH * scale
  local inset = FOCUS_PATH_INSET * scale
  local radius = math.max(0, resolvedRadius - outerWidth / 2)
  local outer = colors.focusOuter
  local inner = colors.focusInner
  graphics.setColor(outer[1], outer[2], outer[3], outer[4])
  graphics.setLineWidth(outerWidth)
  graphics.rectangle(
    "line",
    outlineRect.x + inset,
    outlineRect.y + inset,
    outlineRect.width - inset * 2,
    outlineRect.height - inset * 2,
    radius,
    radius
  )
  graphics.setColor(inner[1], inner[2], inner[3], inner[4])
  graphics.setLineWidth(innerWidth)
  graphics.rectangle(
    "line",
    outlineRect.x + inset,
    outlineRect.y + inset,
    outlineRect.width - inset * 2,
    outlineRect.height - inset * 2,
    radius,
    radius
  )
end

---@param button table<string, unknown>
---@param selected boolean
---@return { x: number, y: number, width: number, height: number }
function TextButton.visualBounds(button, selected)
  assert(type(button) == "table", "resolved text button is required")
  assert(type(button.rect) == "table", "text button rectangle is missing")
  assert(type(selected) == "boolean", "text button selected flag must be boolean")
  local body = rectangle(button.rect, "text button rectangle")
  local scale = assert(button.scale, "text button scale is missing")
  PixelScale.assertInteger(scale)
  if not selected then
    return body
  end
  local outset = math.max(0, FOCUS_OUTER_WIDTH / 2 - FOCUS_PATH_INSET) * scale
  return {
    x = body.x - outset,
    y = body.y - outset,
    width = body.width + outset * 2,
    height = body.height + outset * 2,
  }
end

-- Paints the resolved text button with its palette. The button record is
-- already resolved and the palette is either the shared default or a
-- caller-supplied complete palette, both borrowed by reference: paint
-- performs no color copying, merging, label-fit validation, or failure
-- cleanup. The borrowed line width is restored on success; a text failure
-- is terminal and propagates immediately.
---@param graphics table<string, unknown>
---@param button table<string, unknown> the resolved text button
---@param spec { label: string, selected: boolean, text: TextAdapter, colors?: table<string, unknown> }
function TextButton.draw(graphics, button, spec)
  local scale = button.scale
  local content = button.contentRect
  local labelWidth = spec.text.measure(spec.label)
  local lineHeight = spec.text.lineHeight
  local sourceContentWidth = content.width / scale
  local sourceContentHeight = content.height / scale
  local colors = spec.colors or DEFAULT_COLORS

  local palette = {
    border = colors.border,
    rim = colors.rim,
    innerBorder = colors.innerBorder,
    faceTop = colors.faceTop,
    faceBottom = colors.faceBottom,
  }

  local savedLineWidth = graphics.getLineWidth()

  Button.draw(graphics, button, palette)

  drawFaceDivider(graphics, button, colors)

  if spec.selected then
    drawFocusOutline(graphics, button, colors)
  end

  graphics.push()
  graphics.translate(content.x, content.y)
  graphics.scale(scale, scale)
  spec.text.draw(
    spec.label,
    PixelScale.snapLogical((sourceContentWidth - labelWidth) / 2),
    PixelScale.snapLogical((sourceContentHeight - lineHeight) / 2)
  )
  graphics.pop()
  graphics.setLineWidth(savedLineWidth)
end

return TextButton
