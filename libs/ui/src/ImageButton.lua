-- Image button composing the generic Button geometry with caller-owned colors.

local Button = require("libs.ui.src.Button")

local ImageButton = {}

-- Shared immutable default roles, borrowed by reference on every paint.
-- Caller overrides are likewise borrowed by reference; paint never copies
-- or validates palette roles.
local DEFAULT_BORDER = { 58 / 255, 58 / 255, 58 / 255, 1 }
local DEFAULT_RIM = { 222 / 255, 230 / 255, 230 / 255, 1 }
local DEFAULT_SELECTED_RIM = { 255 / 255, 58 / 255, 58 / 255, 1 }

local function finite(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function assertFinitePositiveScale(value)
  assert(finite(value) and value > 0, "image button scale must be a finite positive number")
end

local function rectangle(value, name)
  assert(type(value) == "table", name .. " is required")
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    assert(finite(value[field]), name .. " fields must be finite numbers")
  end
  assert(value.width > 0 and value.height > 0, name .. " must have positive dimensions")
  return { x = value.x, y = value.y, width = value.width, height = value.height }
end

---@param spec { rect: {x:number,y:number,width:number,height:number}, scale: number, cornerRadius?: number, innerBorderWidth?: number }
---@return table<string, unknown>
function ImageButton.resolve(spec)
  assert(type(spec) == "table", "image button specification is required")
  local rectValue = rectangle(spec.rect, "image button rectangle")
  assertFinitePositiveScale(spec.scale)
  local scale = spec.scale
  local cornerRadius = 6
  if spec.cornerRadius ~= nil then
    assert(
      type(spec.cornerRadius) == "number" and finite(spec.cornerRadius) and spec.cornerRadius >= 0,
      "image button corner radius must be a finite non-negative number"
    )
    cornerRadius = spec.cornerRadius
  end
  local innerBorderWidth = 1
  if spec.innerBorderWidth ~= nil then
    assert(
      type(spec.innerBorderWidth) == "number" and finite(spec.innerBorderWidth) and spec.innerBorderWidth > 0,
      "image button inner border width must be a finite positive number"
    )
    innerBorderWidth = spec.innerBorderWidth
  end
  local resolved = Button.resolve({
    rect = rectValue,
    borderWidth = 1 * scale,
    rimWidth = 2 * scale,
    innerBorderWidth = innerBorderWidth * scale,
    cornerRadius = cornerRadius * scale,
    faceSplit = 0.5,
    contentInsetX = 0,
    contentInsetY = 0,
  })
  resolved.scale = scale
  return resolved
end

-- Paints the resolved image button with its face color. The button record is
-- already resolved and every palette role is borrowed by reference: omitted
-- roles fall back to the shared defaults without copying, and the image
-- rectangle is drawn as given. Only the selected/unselected rim branch
-- decides pixels here; a paint failure is terminal and propagates.
---@param graphics table<string, unknown>
---@param button table<string, unknown> the resolved image button
---@param spec { selected: boolean, colors: {face:number[], border?:number[], rim?:number[], selectedRim?:number[], innerBorder?:number[]}, imageRect: {x:number,y:number,width:number,height:number}, drawImage: fun(rect:table<string, unknown>)}
function ImageButton.draw(graphics, button, spec)
  local face = spec.colors.face
  local palette = {
    border = spec.colors.border or DEFAULT_BORDER,
    rim = spec.selected and (spec.colors.selectedRim or DEFAULT_SELECTED_RIM) or (spec.colors.rim or DEFAULT_RIM),
    innerBorder = spec.colors.innerBorder or face,
    faceTop = face,
    faceBottom = face,
  }

  Button.draw(graphics, button, palette)
  spec.drawImage(spec.imageRect)
end

return ImageButton
