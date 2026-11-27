-- FieldViewport computes pure presentation rectangles for canonical 4:3 field
-- rendering. Expanded mode fills the host and centers the canonical frame;
-- strict mode centers a 4:3 view.

local FieldViewport = {}
FieldViewport.__index = FieldViewport

local function copyRectangle(rectangle)
  return {
    x = rectangle.x,
    y = rectangle.y,
    width = rectangle.width,
    height = rectangle.height,
  }
end

local function finite(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function strictRectangle(x, y, width, height, aspect)
  if width / height >= aspect then
    local fittedWidth = height * aspect
    return { x = math.floor(x + (width - fittedWidth) / 2 + 0.5), y = y, width = fittedWidth, height = height }
  end
  local fittedHeight = width / aspect
  return { x = x, y = math.floor(y + (height - fittedHeight) / 2 + 0.5), width = width, height = fittedHeight }
end

function FieldViewport.new(width, height, options)
  options = options or {}
  local viewport = setmetatable({
    mode = options.mode or "expanded",
    canonicalAspect = options.canonicalAspect or (4 / 3),
    x = options.x or 0,
    y = options.y or 0,
  }, FieldViewport)
  assert(viewport.mode == "expanded" or viewport.mode == "strict", "unsupported field viewport mode")
  assert(viewport.canonicalAspect > 0, "canonical aspect must be positive")
  viewport:resize(width, height)
  return viewport
end

---@param width number
---@param height number
---@param worldBounds { x: number, y: number, width: number, height: number }?
function FieldViewport:resize(width, height, worldBounds)
  assert(type(width) == "number" and width > 0, "viewport width must be positive")
  assert(type(height) == "number" and height > 0, "viewport height must be positive")
  local bounds = { x = self.x, y = self.y, width = width, height = height }
  if worldBounds ~= nil then
    assert(type(worldBounds) == "table", "world bounds must be a rectangle")
    assert(finite(worldBounds.x) and finite(worldBounds.y), "world bounds origin must be finite")
    assert(
      finite(worldBounds.width) and worldBounds.width > 0 and finite(worldBounds.height) and worldBounds.height > 0,
      "world bounds dimensions must be positive and finite"
    )
    assert(
      worldBounds.x >= bounds.x
        and worldBounds.y >= bounds.y
        and worldBounds.x + worldBounds.width <= bounds.x + bounds.width
        and worldBounds.y + worldBounds.height <= bounds.y + bounds.height,
      "world bounds must be inside the host rectangle"
    )
    bounds = copyRectangle(worldBounds)
  end
  self.width = width
  self.height = height
  local strict = strictRectangle(bounds.x, bounds.y, bounds.width, bounds.height, self.canonicalAspect)
  if self.mode == "strict" then
    self.worldViewport = strict
    self.referenceFrame = copyRectangle(strict)
    return
  end
  self.worldViewport = bounds
  if bounds.width / bounds.height >= self.canonicalAspect then
    self.referenceFrame = {
      x = bounds.x + (bounds.width - bounds.height * self.canonicalAspect) / 2,
      y = bounds.y,
      width = bounds.height * self.canonicalAspect,
      height = bounds.height,
    }
    return
  end
  self.referenceFrame = {
    x = bounds.x,
    y = bounds.y + (bounds.height - bounds.width / self.canonicalAspect) / 2,
    width = bounds.width,
    height = bounds.width / self.canonicalAspect,
  }
end

function FieldViewport:worldAspect()
  return self.worldViewport.width / self.worldViewport.height
end

return FieldViewport
