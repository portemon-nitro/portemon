-- Stateless logical scroll offset and uniform-row visibility geometry.

local ScrollViewport = {}

local function finiteNumber(value, name)
  assert(
    type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge,
    name .. " must be finite"
  )
end

---@param offset number
---@param contentExtent number
---@param viewportExtent number
---@return number
function ScrollViewport.clamp(offset, contentExtent, viewportExtent)
  finiteNumber(offset, "offset")
  finiteNumber(contentExtent, "content extent")
  finiteNumber(viewportExtent, "viewport extent")
  assert(contentExtent >= 0, "content extent must be nonnegative")
  assert(viewportExtent >= 0, "viewport extent must be nonnegative")

  return math.max(0, math.min(offset, math.max(0, contentExtent - viewportExtent)))
end

---@param offset number
---@param viewportExtent number
---@param itemStart number
---@param itemExtent number
---@return number
function ScrollViewport.reveal(offset, viewportExtent, itemStart, itemExtent)
  finiteNumber(offset, "offset")
  finiteNumber(viewportExtent, "viewport extent")
  finiteNumber(itemStart, "item start")
  finiteNumber(itemExtent, "item extent")
  assert(viewportExtent >= 0, "viewport extent must be nonnegative")
  assert(itemStart >= 0, "item start must be nonnegative")
  assert(itemExtent >= 0, "item extent must be nonnegative")

  offset = math.max(0, offset)
  if itemStart < offset then
    return itemStart
  end
  if itemStart + itemExtent > offset + viewportExtent then
    return itemExtent > viewportExtent and itemStart or itemStart + itemExtent - viewportExtent
  end
  return offset
end

---@param offset number
---@param viewportExtent number
---@param itemExtent number
---@param gap number
---@param count integer
---@return integer first1
---@return integer last1
function ScrollViewport.visibleRange(offset, viewportExtent, itemExtent, gap, count)
  finiteNumber(offset, "offset")
  finiteNumber(viewportExtent, "viewport extent")
  finiteNumber(itemExtent, "item extent")
  finiteNumber(gap, "gap")
  finiteNumber(count, "count")
  assert(viewportExtent >= 0, "viewport extent must be nonnegative")
  assert(itemExtent > 0, "item extent must be positive")
  assert(gap >= 0, "gap must be nonnegative")
  assert(count >= 0 and count % 1 == 0, "count must be a nonnegative integer")

  if count == 0 or viewportExtent == 0 then
    return 1, 0
  end

  local stride = itemExtent + gap
  local viewportEnd = offset + viewportExtent
  local first1 = math.max(1, math.floor((offset - itemExtent) / stride) + 2)
  local last1 = math.min(count, math.ceil(viewportEnd / stride))
  if first1 > last1 then
    return 1, 0
  end
  return first1, last1
end

return ScrollViewport
