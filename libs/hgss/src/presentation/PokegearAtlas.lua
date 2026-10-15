-- Quad access over the prepared Pokegear planes: the gear draws pieces of
-- its tilemap-atlas planes (button states, strip cells, tile copies), so each
-- (image, source rectangle) pair keeps one quad, created on first use, and
-- steady drawing allocates nothing. Pure presentation: the host graphics
-- namespace arrives as an argument.

---@class PokegearAtlas
local PokegearAtlas = {}

local quadsByImage = setmetatable({}, { __mode = "k" })

---@param graphics love.graphics
---@param image love.Image
---@param x number atlas source x
---@param y number atlas source y
---@param width number
---@param height number
---@return love.Quad
function PokegearAtlas.quad(graphics, image, x, y, width, height)
  local quads = quadsByImage[image]
  if quads == nil then
    quads = {}
    quadsByImage[image] = quads
  end
  local key = ((x * 4096 + y) * 4096 + width) * 4096 + height
  local quad = quads[key]
  if quad == nil then
    local atlasWidth, atlasHeight = image:getDimensions()
    quad = graphics.newQuad(x, y, width, height, atlasWidth, atlasHeight)
    quads[key] = quad
  end
  return quad
end

-- Draws one rectangle of an atlas image at a destination.
---@param graphics love.graphics
---@param image love.Image
---@param srcX number
---@param srcY number
---@param width number
---@param height number
---@param destX number
---@param destY number
function PokegearAtlas.draw(graphics, image, srcX, srcY, width, height, destX, destY)
  graphics.draw(image, PokegearAtlas.quad(graphics, image, srcX, srcY, width, height), destX, destY)
end

-- Runs a drawing function with the host scissor narrowed to a logical-space
-- rectangle. The rectangle is transformed through the active graphics
-- transform, so it follows the pane placement; hosts without transform
-- queries draw unclipped.
---@param graphics love.graphics
---@param x number
---@param y number
---@param width number
---@param height number
---@param draw fun()
function PokegearAtlas.clipped(graphics, x, y, width, height, draw)
  if type(graphics.transformPoint) ~= "function" or type(graphics.intersectScissor) ~= "function" then
    draw()
    return
  end
  local left, top = graphics.transformPoint(x, y)
  local right, bottom = graphics.transformPoint(x + width, y + height)
  local savedX, savedY, savedWidth, savedHeight = graphics.getScissor()
  graphics.intersectScissor(
    math.floor(math.min(left, right) + 0.5),
    math.floor(math.min(top, bottom) + 0.5),
    math.floor(math.abs(right - left) + 0.5),
    math.floor(math.abs(bottom - top) + 0.5)
  )
  draw()
  graphics.setScissor(savedX, savedY, savedWidth, savedHeight)
end

return PokegearAtlas
