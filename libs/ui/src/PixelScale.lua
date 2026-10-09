-- Integer-pixel presentation policy layered on `LayoutGeometry`: preferred
-- integer scale selection, ceil-covered logical allocations, and
-- logical-pixel snapping. Generic rectangle validation, fit geometry, and
-- host/logical transforms are owned by `LayoutGeometry`.

local LayoutGeometry = require("libs.ui.src.LayoutGeometry")

---@class PixelScale.Surface
---@field placement LayoutGeometry.Placement
---@field allocationWidth integer
---@field allocationHeight integer
---@field logicalViewport LayoutGeometry.Rect

local PixelScale = {}

local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function assertFiniteNumber(value, name)
  assert(isFiniteNumber(value), name .. " must be finite")
end

local function assertScale(scale)
  assertFiniteNumber(scale, "scale")
  assert(scale > 0 and scale == math.floor(scale), "scale must be a positive integer")
end

---@param scale number
---@return integer
function PixelScale.assertInteger(scale)
  assertScale(scale)
  return scale --[[@as integer]]
end

---@param placement LayoutGeometry.Placement
---@return LayoutGeometry.Placement
function PixelScale.assertPlacement(placement)
  assert(type(placement) == "table", "pixel placement must be a record")
  local pixelScale = placement.pixelScale
  local pixelRatio = placement.pixelRatio
  assert(isFiniteNumber(pixelScale), "pixel placement needs a physical scale")
  ---@cast pixelScale integer
  assert(
    pixelScale > 0 and pixelScale == math.floor(pixelScale),
    "pixel placement needs a positive integer physical scale"
  )
  assert(isFiniteNumber(pixelRatio) and pixelRatio > 0, "pixel placement needs a finite positive pixel ratio")
  assert(isFiniteNumber(placement.scale) and placement.scale > 0, "pixel placement needs a finite positive scale")
  local scaleError = math.abs(placement.scale * pixelRatio - pixelScale)
  assert(
    scaleError <= 1e-7 * math.max(1, math.abs(pixelScale)),
    "pixel placement scale does not match its physical scale"
  )
  local origin = placement.origin or placement.frame
  assert(type(origin) == "table", "pixel placement needs an origin or frame")
  for _, axis in ipairs({ "x", "y" }) do
    assert(isFiniteNumber(origin[axis]), "pixel placement origin must be finite")
    local physicalOrigin = origin[axis] * pixelRatio
    assert(isFiniteNumber(physicalOrigin), "pixel placement origin must be finite")
    local nearest = math.floor(physicalOrigin + 0.5)
    assert(
      math.abs(physicalOrigin - nearest) <= 1e-7 * math.max(1, math.abs(physicalOrigin)),
      "pixel placement origin must align to the physical pixel grid"
    )
  end
  return placement
end

---@param bounds LayoutGeometry.Rect
---@param referenceWidth number
---@param referenceHeight number
---@param preferredScale integer
---@return integer
function PixelScale.fitPreferred(bounds, referenceWidth, referenceHeight, preferredScale)
  assertScale(preferredScale)

  local fit = LayoutGeometry.centeredFit(bounds, referenceWidth, referenceHeight)
  local capacity = math.floor(fit.scale)

  return math.max(1, math.min(preferredScale, capacity))
end

---@param bounds LayoutGeometry.Rect
---@param scale integer framebuffer pixels per logical pixel
---@param pixelRatio number? framebuffer pixels per host unit; omitted stays 1
---@return PixelScale.Surface
function PixelScale.cover(bounds, scale, pixelRatio)
  assertScale(scale)

  local ratio = 1
  if pixelRatio ~= nil then
    assertFiniteNumber(pixelRatio, "pixelRatio")
    assert(pixelRatio > 0, "pixelRatio must be a finite positive number")
    ratio = pixelRatio
  end
  local effectiveScale = scale / ratio

  local boundsRect = LayoutGeometry.rect(bounds, "bounds")
  local nearX = math.ceil(boundsRect.x * ratio)
  local nearY = math.ceil(boundsRect.y * ratio)
  local farX = math.floor((boundsRect.x + boundsRect.width) * ratio)
  local farY = math.floor((boundsRect.y + boundsRect.height) * ratio)
  assert(farX > nearX and farY > nearY, "bounds must contain at least one physical pixel")
  local frame = {
    x = nearX / ratio,
    y = nearY / ratio,
    width = (farX - nearX) / ratio,
    height = (farY - nearY) / ratio,
  }
  local visibleWidth = frame.width / effectiveScale
  local visibleHeight = frame.height / effectiveScale

  return {
    placement = {
      frame = frame,
      origin = { x = frame.x, y = frame.y },
      scale = effectiveScale,
      logicalWidth = visibleWidth,
      logicalHeight = visibleHeight,
      clipRect = { x = frame.x, y = frame.y, width = frame.width, height = frame.height },
      pixelScale = scale,
      pixelRatio = ratio,
      visibleLogicalRect = { x = 0, y = 0, width = visibleWidth, height = visibleHeight },
      crop = { left = 0, right = 0, top = 0, bottom = 0 },
    },
    allocationWidth = math.ceil(visibleWidth),
    allocationHeight = math.ceil(visibleHeight),
    logicalViewport = {
      x = 0,
      y = 0,
      width = visibleWidth,
      height = visibleHeight,
    },
  }
end

-- Bounded integer fitting for a fixed authored surface: the largest permitted
-- integer pixel scale with at most one safe overdraw bump. Crop budgets are
-- source-logical pixels per edge (default 4); the bump crops centred whole
-- source pixels and is refused when it would exceed a budget, hide protected
-- content, or pass the preferred-scale cap. A target without an admissible
-- whole-pixel placement returns nil.
---@param bounds LayoutGeometry.Rect host-unit target region
---@param width integer native logical width
---@param height integer native logical height
---@param options { pixelRatio?: number, preferredScale?: integer, maxOverdraw?: { left: integer, right: integer, top: integer, bottom: integer }, protectedRect?: LayoutGeometry.Rect }?
---@return LayoutGeometry.Placement?
function PixelScale.placeFixed(bounds, width, height, options)
  local target = LayoutGeometry.rect(bounds, "bounds")
  assert(isFiniteNumber(width) and width > 0 and width == math.floor(width), "width must be a positive integer")
  assert(isFiniteNumber(height) and height > 0 and height == math.floor(height), "height must be a positive integer")
  assert(options == nil or type(options) == "table", "options must be a table")
  local opts = options or {}

  local ratio = 1
  if opts.pixelRatio ~= nil then
    assertFiniteNumber(opts.pixelRatio, "options.pixelRatio")
    assert(opts.pixelRatio > 0, "options.pixelRatio must be a finite positive number")
    ratio = opts.pixelRatio
  end
  local cap = math.huge
  if opts.preferredScale ~= nil then
    assertScale(opts.preferredScale)
    cap = opts.preferredScale
  end
  local budget = { left = 4, right = 4, top = 4, bottom = 4 }
  if opts.maxOverdraw ~= nil then
    assert(type(opts.maxOverdraw) == "table", "options.maxOverdraw must be a table")
    for _, edge in ipairs({ "left", "right", "top", "bottom" }) do
      local value = opts.maxOverdraw[edge]
      assert(
        isFiniteNumber(value) and value >= 0 and value == math.floor(value),
        "options.maxOverdraw." .. edge .. " must be a non-negative integer"
      )
      budget[edge] = value
    end
  end
  assert(budget.left + budget.right < width, "the horizontal crop budget must leave visible content")
  assert(budget.top + budget.bottom < height, "the vertical crop budget must leave visible content")
  local protected = nil
  if opts.protectedRect ~= nil then
    protected = LayoutGeometry.rect(opts.protectedRect, "options.protectedRect")
    assert(
      protected.x >= 0
        and protected.y >= 0
        and protected.x + protected.width <= width
        and protected.y + protected.height <= height,
      "options.protectedRect must stay inside the logical surface"
    )
  end

  -- Work on the physical framebuffer grid: the host-unit edges convert once,
  -- the near edges rounding in and the far edges rounding out.
  local nearX = math.ceil(target.x * ratio)
  local nearY = math.ceil(target.y * ratio)
  local farX = math.floor((target.x + target.width) * ratio)
  local farY = math.floor((target.y + target.height) * ratio)
  local availableWidth = farX - nearX
  local availableHeight = farY - nearY
  if availableWidth <= 0 or availableHeight <= 0 then
    return nil
  end

  ---@param visibleX integer
  ---@param visibleY integer
  ---@param visibleWidth integer
  ---@param visibleHeight integer
  ---@return boolean
  local function bumpFits(visibleX, visibleY, visibleWidth, visibleHeight)
    local left = visibleX
    local right = width - (visibleX + visibleWidth)
    local top = visibleY
    local bottom = height - (visibleY + visibleHeight)
    if left > budget.left or right > budget.right or top > budget.top or bottom > budget.bottom then
      return false
    end
    if protected ~= nil then
      if
        protected.x < visibleX
        or protected.y < visibleY
        or protected.x + protected.width > visibleX + visibleWidth
        or protected.y + protected.height > visibleY + visibleHeight
      then
        return false
      end
    end
    return true
  end

  ---@param pixel integer physical pixels per logical pixel
  ---@param visibleX integer
  ---@param visibleY integer
  ---@param visibleWidth integer
  ---@param visibleHeight integer
  ---@return LayoutGeometry.Placement
  local function croppedPlacement(pixel, visibleX, visibleY, visibleWidth, visibleHeight)
    local originX = nearX + math.floor((availableWidth - visibleWidth * pixel) / 2)
    local originY = nearY + math.floor((availableHeight - visibleHeight * pixel) / 2)
    local fullX = originX - visibleX * pixel
    local fullY = originY - visibleY * pixel
    local scale = pixel / ratio
    local frame = {
      x = fullX / ratio,
      y = fullY / ratio,
      width = (width * pixel) / ratio,
      height = (height * pixel) / ratio,
    }
    local clip = {
      x = originX / ratio,
      y = originY / ratio,
      width = (visibleWidth * pixel) / ratio,
      height = (visibleHeight * pixel) / ratio,
    }
    return {
      frame = frame,
      origin = { x = frame.x, y = frame.y },
      scale = scale,
      logicalWidth = width,
      logicalHeight = height,
      clipRect = clip,
      pixelScale = pixel,
      pixelRatio = ratio,
      visibleLogicalRect = { x = visibleX, y = visibleY, width = visibleWidth, height = visibleHeight },
      crop = {
        left = visibleX,
        right = width - (visibleX + visibleWidth),
        top = visibleY,
        bottom = height - (visibleY + visibleHeight),
      },
    }
  end

  ---@param pixel integer
  ---@return LayoutGeometry.Placement
  local function centredPlacement(pixel)
    local originX = nearX + math.floor((availableWidth - width * pixel) / 2)
    local originY = nearY + math.floor((availableHeight - height * pixel) / 2)
    local scale = pixel / ratio
    local frame = {
      x = originX / ratio,
      y = originY / ratio,
      width = (width * pixel) / ratio,
      height = (height * pixel) / ratio,
    }
    return {
      frame = frame,
      origin = { x = frame.x, y = frame.y },
      scale = scale,
      logicalWidth = width,
      logicalHeight = height,
      clipRect = { x = frame.x, y = frame.y, width = frame.width, height = frame.height },
      pixelScale = pixel,
      pixelRatio = ratio,
      visibleLogicalRect = { x = 0, y = 0, width = width, height = height },
      crop = { left = 0, right = 0, top = 0, bottom = 0 },
    }
  end

  local natural = math.min(availableWidth / width, availableHeight / height)
  local whole = math.floor(natural)
  local base = math.min(whole, cap)

  -- Only the next integer above the natural fit is ever attempted as a
  -- bump, and never above the preferred-scale cap.
  local candidate = whole + 1
  if candidate <= cap then
    local visibleWidth = math.min(width, math.floor(availableWidth / candidate))
    local visibleHeight = math.min(height, math.floor(availableHeight / candidate))
    if visibleWidth > 0 and visibleHeight > 0 then
      local hiddenX = width - visibleWidth
      local hiddenY = height - visibleHeight
      -- Centred whole-source-pixel cropping: asymmetric budgets restrict
      -- the centred cut, content never shifts to spend an open edge.
      local visibleX = math.floor(hiddenX / 2)
      local visibleY = math.floor(hiddenY / 2)
      if hiddenX == 0 and hiddenY == 0 then
        return centredPlacement(candidate)
      end
      if bumpFits(visibleX, visibleY, visibleWidth, visibleHeight) then
        return croppedPlacement(candidate, visibleX, visibleY, visibleWidth, visibleHeight)
      end
    end
  end

  if base >= 1 then
    return centredPlacement(base)
  end

  -- Below 1x, admissible 1x cropping still applies before reporting no fit.
  local unitWidth = math.min(width, availableWidth)
  local unitHeight = math.min(height, availableHeight)
  if unitWidth > 0 and unitHeight > 0 then
    local hiddenX = width - unitWidth
    local hiddenY = height - unitHeight
    local visibleX = math.floor(hiddenX / 2)
    local visibleY = math.floor(hiddenY / 2)
    if hiddenX == 0 and hiddenY == 0 then
      return centredPlacement(1)
    end
    if bumpFits(visibleX, visibleY, unitWidth, unitHeight) then
      return croppedPlacement(1, visibleX, visibleY, unitWidth, unitHeight)
    end
  end

  return nil
end

---@param value number
---@return integer
function PixelScale.snapLogical(value)
  assertFiniteNumber(value, "value")
  return math.floor(value + 0.5)
end

return PixelScale
