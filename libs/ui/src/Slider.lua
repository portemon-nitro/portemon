-- Pure stop-to-position and pointer-to-stop geometry for the two option
-- sliders. Callers own the business-value mapping (volume percent, battle
-- speed multipliers), focus, and gesture state; this module only places
-- uniform stops over the usable track and maps pointer travel back to the
-- nearest stop. It retains no state, assets, or device.

local Slider = {}

---@alias Slider.Rect { x: number, y: number, width: number, height: number }
---@alias Slider.Spec { rect: Slider.Rect, count: integer, index: integer, knobExtent: number }
---@alias Slider.Resolved { rect: Slider.Rect, trackStartX: number, trackEndX: number, centerY: number, thumbRect: Slider.Rect, count: integer, index: integer }

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

local function snap(value)
  return math.floor(value + 0.5)
end

---@param spec Slider.Spec
---@return Slider.Resolved caller-owned resolved geometry
function Slider.resolve(spec)
  assert(type(spec) == "table", "slider specification is required")
  local rectValue = rectangle(spec.rect, "slider rectangle")
  assert(
    type(spec.count) == "number" and spec.count % 1 == 0 and spec.count >= 2,
    "slider count must be an integral stop count of at least 2"
  )
  assert(
    type(spec.index) == "number" and spec.index % 1 == 0 and spec.index >= 1 and spec.index <= spec.count,
    "slider index must be an integral stop within the stop count"
  )
  assert(finite(spec.knobExtent) and spec.knobExtent > 0, "slider knob extent must be a positive finite number")
  assert(rectValue.width > spec.knobExtent, "slider track must be wider than its knob")
  -- The usable span keeps half a knob of travel inside each track end.
  local trackStartX = rectValue.x + spec.knobExtent / 2
  local trackEndX = rectValue.x + rectValue.width - spec.knobExtent / 2
  local centerY = rectValue.y + rectValue.height / 2
  local fraction = (spec.index - 1) / (spec.count - 1)
  local thumbCenterX = snap(trackStartX + fraction * (trackEndX - trackStartX))
  return {
    rect = rectValue,
    trackStartX = trackStartX,
    trackEndX = trackEndX,
    centerY = centerY,
    thumbRect = {
      x = thumbCenterX - spec.knobExtent / 2,
      y = centerY - spec.knobExtent / 2,
      width = spec.knobExtent,
      height = spec.knobExtent,
    },
    count = spec.count,
    index = spec.index,
  }
end

---@param resolved Slider.Resolved geometry returned by Slider.resolve
---@param x number pointer position in the same logical space
---@return integer the nearest stop, clamped to the usable track
function Slider.indexAt(resolved, x)
  assert(type(resolved) == "table", "resolved slider is required")
  assert(
    finite(resolved.trackStartX) and finite(resolved.trackEndX) and resolved.trackEndX > resolved.trackStartX,
    "resolved slider track is invalid"
  )
  assert(
    type(resolved.count) == "number" and resolved.count % 1 == 0 and resolved.count >= 2,
    "resolved slider count is invalid"
  )
  assert(finite(x), "slider pointer position must be finite")
  local fraction = (x - resolved.trackStartX) / (resolved.trackEndX - resolved.trackStartX)
  if fraction < 0 then
    fraction = 0
  elseif fraction > 1 then
    fraction = 1
  end
  -- Halfway travel rounds toward the larger stop.
  return math.floor(fraction * (resolved.count - 1) + 0.5) + 1
end

return Slider
