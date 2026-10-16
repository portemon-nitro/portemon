-- Paints the transient area-name banner at the canonical 256x192 MAIN field
-- surface: the compiled 136x32 skin at logical x0 displaced by the banner's
-- scroll offset, and the centered native title through the style's own text
-- palette. Placement, clip, and the single logical transform come from the
-- shared PixelScale/LogicalSurface primitives; the renderer resolves no map
-- data and owns no GPU image.

local LogicalSurface = require("libs.ui.src.LogicalSurface")
local PixelScale = require("libs.ui.src.PixelScale")

---@class FieldMapNameRenderer
---@field private _graphics love.graphics
---@field private _text FieldTextRenderer
---@field private _imageFor fun(styleKey: integer): { image: love.Image, palette: FieldEntryAssetCache.BannerTextPalette }
local FieldMapNameRenderer = {}
FieldMapNameRenderer.__index = FieldMapNameRenderer

-- The source field screen the banner is authored against and the literal
-- source text placement: skin at logical x0, first glyph at inset 4, baseline
-- row 8, centered over the 132-pixel text span.
FieldMapNameRenderer.REFERENCE_WIDTH = 256
FieldMapNameRenderer.REFERENCE_HEIGHT = 192
local BANNER_TEXT_SPAN = 132
local TEXT_INSET = 4
local TEXT_Y = 8

---@param opts { graphics: love.graphics, text: FieldTextRenderer, imageFor: fun(styleKey: integer): { image: love.Image, palette: FieldEntryAssetCache.BannerTextPalette } }
---@return FieldMapNameRenderer
function FieldMapNameRenderer.new(opts)
  assert(type(opts) == "table", "the map-name renderer needs its options")
  assert(opts.graphics and opts.graphics.newImage, "the map-name renderer needs the host graphics namespace")
  assert(type(opts.text) == "table", "the map-name renderer borrows the field text renderer")
  assert(type(opts.imageFor) == "function", "the map-name renderer needs its banner image source")
  return setmetatable({ _graphics = opts.graphics, _text = opts.text, _imageFor = opts.imageFor }, FieldMapNameRenderer)
end

-- Renders one banner status into the MAIN reference frame. The skin and title
-- share the same vertical scroll displacement; the title is centered by the
-- source X formula at local row 8 and painted through the style palette.
---@param status FieldMapNameBanner.Status
---@param referenceFrame LayoutGeometry.Rect
function FieldMapNameRenderer:draw(status, referenceFrame)
  local placement =
    PixelScale.placeFixed(referenceFrame, FieldMapNameRenderer.REFERENCE_WIDTH, FieldMapNameRenderer.REFERENCE_HEIGHT)
  if placement == nil then
    return
  end
  local skin = self._imageFor(status.styleKey)
  local offset = status.scrollOffset
  local text = self._text
  local textX = math.floor((BANNER_TEXT_SPAN - text:textWidth(status.title)) / 2) + TEXT_INSET
  local graphics = self._graphics
  LogicalSurface.draw(graphics, placement, function()
    graphics.setColor(1, 1, 1, 1)
    graphics.draw(skin.image, 0, -offset)
    text:drawTextWithPalette(status.title, textX, TEXT_Y - offset, skin.palette)
  end)
end

return FieldMapNameRenderer
