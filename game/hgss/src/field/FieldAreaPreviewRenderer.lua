-- Paints the time-aware area preview at the canonical 256x192 MAIN field
-- surface: the selected generated image at the logical origin with the status
-- image alpha, and the black brightness cover above it while it is visible.
-- Placement and the single logical transform come from the shared
-- PixelScale/LogicalSurface primitives; the renderer is a pure draw leaf that
-- owns no GPU image and borrows the one selected bitmap from its owner.

local LogicalSurface = require("libs.ui.src.LogicalSurface")
local PixelScale = require("libs.ui.src.PixelScale")

---@class FieldAreaPreviewRenderer
---@field private _graphics love.graphics
---@field private _imageFor fun(imageKey: string): love.Image
local FieldAreaPreviewRenderer = {}
FieldAreaPreviewRenderer.__index = FieldAreaPreviewRenderer

FieldAreaPreviewRenderer.REFERENCE_WIDTH = 256
FieldAreaPreviewRenderer.REFERENCE_HEIGHT = 192

---@param opts { graphics: love.graphics, imageFor: fun(imageKey: string): love.Image }
---@return FieldAreaPreviewRenderer
function FieldAreaPreviewRenderer.new(opts)
  assert(type(opts) == "table", "the area-preview renderer needs its options")
  assert(type(opts.graphics) == "table", "the area-preview renderer needs the host graphics namespace")
  assert(type(opts.imageFor) == "function", "the area-preview renderer needs its selected image source")
  return setmetatable({ _graphics = opts.graphics, _imageFor = opts.imageFor }, FieldAreaPreviewRenderer)
end

-- Draws one preview status into the MAIN reference frame. The selected image
-- is resolved first: a missing generated image is a terminal cache-integrity
-- error that propagates before any paint, never a silent omission or a
-- substitute cover.
---@param status { imageKey: string, imageAlpha: number, blackAlpha: number }
---@param referenceFrame LayoutGeometry.Rect
function FieldAreaPreviewRenderer:draw(status, referenceFrame)
  local placement = PixelScale.placeFixed(
    referenceFrame,
    FieldAreaPreviewRenderer.REFERENCE_WIDTH,
    FieldAreaPreviewRenderer.REFERENCE_HEIGHT
  )
  if placement == nil then
    return
  end
  local image = self._imageFor(status.imageKey)
  local graphics = self._graphics
  LogicalSurface.draw(graphics, placement, function()
    graphics.setColor(1, 1, 1, status.imageAlpha)
    graphics.draw(image, 0, 0)
    if status.blackAlpha > 0 then
      graphics.setColor(0, 0, 0, status.blackAlpha)
      graphics.rectangle(
        "fill",
        0,
        0,
        FieldAreaPreviewRenderer.REFERENCE_WIDTH,
        FieldAreaPreviewRenderer.REFERENCE_HEIGHT
      )
    end
  end)
end

return FieldAreaPreviewRenderer
