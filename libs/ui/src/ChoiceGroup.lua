-- Pure geometry and hit testing for the current two/three-choice groups.
-- Callers size each control at its natural extent; this module only
-- distributes the controls inside one logical rectangle with even gaps and
-- hit-tests the resulting half-open regions. Source pixels are never
-- scaled: an unfittable group fails so the caller selects a compact layout.
-- It retains no focus, selection, pointer, asset, or device state.

local ChoiceGroup = {}

---@alias ChoiceGroup.Rect { x: number, y: number, width: number, height: number }
---@alias ChoiceGroup.Spec { rect: ChoiceGroup.Rect, widths: number[], height: number }
---@alias ChoiceGroup.Resolved { rect: ChoiceGroup.Rect, rects: ChoiceGroup.Rect[] }

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

---@param spec ChoiceGroup.Spec
---@return ChoiceGroup.Resolved caller-owned { rect, rects } with snapped origins
function ChoiceGroup.resolve(spec)
  assert(type(spec) == "table", "choice group specification is required")
  local rectValue = rectangle(spec.rect, "choice group rectangle")
  assert(type(spec.widths) == "table", "choice group widths are required")
  local count = 0
  for key, _ in pairs(spec.widths) do
    assert(type(key) == "number" and key % 1 == 0 and key >= 1, "choice group widths must be a dense array")
    count = count + 1
  end
  assert(count >= 2, "choice group needs at least two choices")
  local total = 0
  for index = 1, count do
    local width = spec.widths[index]
    assert(finite(width) and width > 0, "choice widths must be positive finite numbers")
    total = total + width
  end
  assert(finite(spec.height) and spec.height > 0, "choice height must be a positive finite number")
  assert(spec.height <= rectValue.height, "choice height must fit its rectangle")
  assert(total <= rectValue.width, "choices must fit their rectangle without shrinking")
  -- Leftover space splits into even gaps around and between the controls.
  local gap = (rectValue.width - total) / (count + 1)
  local y = math.floor(rectValue.y + (rectValue.height - spec.height) / 2 + 0.5)
  local rects = {}
  local cursor = rectValue.x + gap
  for index = 1, count do
    rects[index] = { x = math.floor(cursor + 0.5), y = y, width = spec.widths[index], height = spec.height }
    cursor = cursor + spec.widths[index] + gap
  end
  -- Snapping may push the rightmost edge a fraction past the rectangle;
  -- shift the snapped row back inside by the integral overflow.
  local overflow = (rects[count].x + rects[count].width) - (rectValue.x + rectValue.width)
  if overflow > 0 then
    local shift = math.ceil(overflow)
    for index = 1, count do
      rects[index].x = rects[index].x - shift
    end
  end
  return { rect = rectValue, rects = rects }
end

---@param resolved ChoiceGroup.Resolved geometry returned by ChoiceGroup.resolve
---@param x number pointer position x in the same logical space
---@param y number pointer position y in the same logical space
---@return integer? the 1-based choice index, or nil outside every control
function ChoiceGroup.hitTest(resolved, x, y)
  assert(type(resolved) == "table" and type(resolved.rects) == "table", "resolved choice group is required")
  assert(finite(x) and finite(y), "choice hit point must be finite")
  for index, entry in ipairs(resolved.rects) do
    assert(
      finite(entry.x) and finite(entry.y) and finite(entry.width) and finite(entry.height),
      "resolved choice rectangle is invalid"
    )
    assert(entry.width > 0 and entry.height > 0, "resolved choice rectangle must be positive")
    if x >= entry.x and x < entry.x + entry.width and y >= entry.y and y < entry.y + entry.height then
      return index
    end
  end
  return nil
end

return ChoiceGroup
