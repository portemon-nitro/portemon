-- Drawing pieces the region map and the Fly entry share: prepared image
-- lookup, compiled sprite frames, palette-colored window text, and the world
-- layer under its affine transform with its tile patches and highlight.
-- Pure presentation: the host graphics namespace arrives as an argument.

local PokegearAtlas = require("libs.hgss.src.presentation.PokegearAtlas")

---@class PokegearMapLayers
local PokegearMapLayers = {}

local HIGHLIGHT_ALPHA = 10 / 16

---@param images table<string, unknown>
---@param path unknown
---@return love.Image
function PokegearMapLayers.imageAt(images, path)
  assert(type(path) == "string", "the map plan resolves its plane images")
  local image = images[path]
  assert(image ~= nil, "the map render needs its prepared plane image")
  return image --[[@as love.Image]]
end

-- Draws one frame of a compiled sprite sequence centred on a position.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param sprites table<string, table<integer, table<string, unknown>>>
---@param set string
---@param sequence number one-based
---@param frame number one-based
---@param x number
---@param y number
---@param scale number?
function PokegearMapLayers.drawSprite(graphics, images, sprites, set, sequence, frame, x, y, scale)
  local clip = assert(sprites[set][sequence], "the map sprites carry their sequence")
  local info = assert(clip.frames[frame], "the map sprite carries its frame")
  local image = PokegearMapLayers.imageAt(images, info.image)
  if scale ~= nil and scale ~= 1 then
    graphics.draw(image, x + info.anchorX * scale, y + info.anchorY * scale, 0, scale, scale)
  else
    graphics.draw(image, x + info.anchorX, y + info.anchorY)
  end
end

---@param text table<string, unknown>?
---@param line string
---@param x number
---@param y number
---@param colors table<string, table<string, number>>
function PokegearMapLayers.printText(text, line, x, y, colors)
  if
    text == nil or type((text --[[@as table<string, unknown>]]).drawTextWithPalette) ~= "function"
  then
    return
  end
  local draw = (text --[[@as table<string, unknown>]]).drawTextWithPalette --[[@as fun(self: table, line: string, x: number, y: number, palette: table)]]
  local row = 0
  for piece in (line .. "\n"):gmatch("([^\n]*)\n") do
    draw(text, piece, x, y + row * 16, colors)
    row = row + 1
  end
end

-- The world layer under its affine transform: the base, the patches copied
-- over it, and the selection highlight blended above.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param content table<string, unknown>
---@param view table<string, unknown>
function PokegearMapLayers.drawWorld(graphics, images, content, view)
  local world = view.world --[[@as table<string, number>]]
  local image = PokegearMapLayers.imageAt(images, content.world)
  local r = world.ratio
  graphics.push()
  graphics.translate(
    -(world.scrollX + world.xOffset) - (r - 1) * world.affineX,
    -world.scrollY - (r - 1) * world.affineY
  )
  graphics.scale(r, r)
  graphics.setColor(1, 1, 1, 1)
  graphics.draw(image, 0, 0)
  for _, patch in
    ipairs(view.patches --[[@as table[] ]])
  do
    PokegearAtlas.draw(
      graphics,
      image,
      patch.srcX * 8,
      patch.srcY * 8,
      patch.width * 8,
      patch.height * 8,
      patch.destX * 8,
      patch.destY * 8
    )
  end
  graphics.setColor(1, 1, 1, HIGHLIGHT_ALPHA)
  for _, patch in
    ipairs(view.highlight --[[@as table[] ]])
  do
    PokegearAtlas.draw(
      graphics,
      image,
      patch.srcX * 8,
      patch.srcY * 8,
      patch.width * 8,
      patch.height * 8,
      patch.destX * 8,
      patch.destY * 8
    )
  end
  graphics.setColor(1, 1, 1, 1)
  graphics.pop()
end

return PokegearMapLayers
