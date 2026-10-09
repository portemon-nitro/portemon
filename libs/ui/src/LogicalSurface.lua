-- Stateless execution of one logical coordinate boundary over an injected
-- graphics namespace. The caller resolves a complete placement, owns the
-- current render target and every GPU resource; this scope only pushes the
-- graphics state, resets the transform, intersects the visible clip, applies
-- the single root transform, runs the callback, and pops on success.
-- Placements and clip rectangles arrive already resolved, so paint performs
-- no validation, copying, or failure cleanup: a callback failure is terminal
-- and propagates immediately, leaving the pushed scope unpopped for the host
-- to observe. It allocates no canvases, images, or fonts and retains
-- nothing between calls.

local PixelScale = require("libs.ui.src.PixelScale")

local LogicalSurface = {}

-- Runs one callback inside the placement's logical coordinate space: the
-- pushed scope is popped on success and the render target is left unchanged.
---@param graphics love.graphics
---@param placement LayoutGeometry.Placement the already-resolved placement
---@param draw fun()
function LogicalSurface.draw(graphics, placement, draw)
  if placement.pixelScale ~= nil or placement.pixelRatio ~= nil then
    PixelScale.assertPlacement(placement)
  end
  local frame = placement.frame
  local origin = placement.origin or frame
  local clip = placement.clipRect or frame
  graphics.push("all")
  graphics.origin()
  graphics.intersectScissor(clip.x, clip.y, clip.width, clip.height)
  graphics.translate(origin.x, origin.y)
  graphics.scale(placement.scale, placement.scale)
  draw()
  graphics.pop()
end

-- Runs one callback under a nested logical clip: the rectangle maps through
-- the current graphics transform, intersects (never replaces) the active
-- scissor, and pops on success. No presentation scale is applied again.
---@param graphics love.graphics
---@param logicalRect LayoutGeometry.Rect logical bounds in the current scope
---@param draw fun()
function LogicalSurface.clip(graphics, logicalRect, draw)
  local nearX, nearY = graphics.transformPoint(logicalRect.x, logicalRect.y)
  local farX, farY = graphics.transformPoint(logicalRect.x + logicalRect.width, logicalRect.y + logicalRect.height)
  graphics.push("all")
  graphics.intersectScissor(
    math.min(nearX, farX),
    math.min(nearY, farY),
    math.abs(farX - nearX),
    math.abs(farY - nearY)
  )
  draw()
  graphics.pop()
end

return LogicalSurface
