-- Indexed battle pictures resolve their source indices through the exact
-- staged palette before alpha discard in the isolated Pokepic pass.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local BattlePicturePass = require("libs.hgss.src.presentation.BattlePicturePass")

local T = {}

function T.indexed_picture_uses_palette_alpha_and_color(scope, context)
  local graphics = love.graphics
  if not graphics.getImageFormats().r8 then
    context:skip("this host reports no indexed (r8) texture support")
  end

  local indices = {}
  for y = 0, 7 do
    for x = 0, 7 do
      indices[#indices + 1] = string.char(x < 4 and 0 or 1)
    end
  end
  local source = scope:own(graphics.newImage(love.image.newImageData(8, 8, "r8", table.concat(indices))))
  local paletteData = love.image.newImageData(2, 1)
  paletteData:setPixel(0, 0, 1, 0, 1, 0)
  paletteData:setPixel(1, 0, 0.25, 0.5, 0.75, 1)
  local palette = scope:own(graphics.newImage(paletteData))
  source:setFilter("nearest", "nearest")
  palette:setFilter("nearest", "nearest")

  local pass = scope:own(BattlePicturePass.new(graphics))
  local canvas = pass:render(graphics, {
    {
      kind = "picture",
      image = source,
      palette = palette,
      imageKind = "r8",
      centerX = 128,
      centerY = 96,
      zCenter = 0,
      width = 8,
      height = 8,
      tintR = 1,
      tintG = 1,
      tintB = 1,
      alpha = 1,
    },
  })
  local pixels = canvas:newImageData()
  local _, _, _, transparentAlpha = pixels:getPixel(125, 96)
  local red, green, blue, opaqueAlpha = pixels:getPixel(131, 96)
  Assert.equal(transparentAlpha, 0, "palette index zero keeps its transparent alpha")
  Assert.near(red, 0.25, 1 / 255, "opaque indexed pixels resolve the palette red")
  Assert.near(green, 0.5, 1 / 255, "opaque indexed pixels resolve the palette green")
  Assert.near(blue, 0.75, 1 / 255, "opaque indexed pixels resolve the palette blue")
  Assert.equal(opaqueAlpha, 1, "opaque indexed pixels keep their palette alpha")
end

return GraphicsSmoke.suite(T)
