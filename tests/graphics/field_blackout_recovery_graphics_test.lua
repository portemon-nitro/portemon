-- The blackout message keeps its source window over the canonical white surface.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FieldBlackoutRenderer = require("game.hgss.src.field.FieldBlackoutRenderer")

local T = {}

local function quantize(value)
  return math.floor(value * 255 + 0.5)
end

function T.wait_message_has_white_surround_and_keeps_its_window(scope)
  local canvas = scope:own(love.graphics.newCanvas(256, 192))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0.08, 0.1, 0.12, 1)

  local windowColor = { 0.1, 0.2, 0.3, 1 }
  local window = {
    drawWindow = function(_, box)
      love.graphics.setColor(windowColor[1], windowColor[2], windowColor[3], windowColor[4])
      love.graphics.rectangle("fill", box.x, box.y, box.width, box.height)
    end,
  }
  local text = {
    fontDef = {
      glyphs = { [1] = { advance = 8 } },
      letterSpacing = 0,
      palette = {
        { r = 8, g = 16, b = 24 },
        { r = 32, g = 48, b = 64 },
        { r = 80, g = 96, b = 112 },
      },
    },
    drawLineWithPalette = function() end,
  }

  local ok, err = pcall(FieldBlackoutRenderer.draw, {
    message = { tokens = { { kind = "glyph", code = 1 } } },
  }, window, text, { x = 0, y = 0, width = 256, height = 192 })
  love.graphics.setCanvas()
  Assert.isTrue(ok, "blackout message rendering must succeed: " .. tostring(err))

  local image = scope:own(canvas:newImageData())
  local outsideRed, outsideGreen, outsideBlue, outsideAlpha = image:getPixel(16, 16)
  Assert.equal(quantize(outsideRed), 255, "blackout surround red must be white")
  Assert.equal(quantize(outsideGreen), 255, "blackout surround green must be white")
  Assert.equal(quantize(outsideBlue), 255, "blackout surround blue must be white")
  Assert.equal(quantize(outsideAlpha), 255, "blackout surround must be opaque")

  local windowRed, windowGreen, windowBlue = image:getPixel(35, 43)
  Assert.isTrue(math.abs(quantize(windowRed) - quantize(windowColor[1])) <= 1, "source window red must remain visible")
  Assert.isTrue(math.abs(quantize(windowGreen) - quantize(windowColor[2])) <= 1, "source window green must remain visible")
  Assert.isTrue(math.abs(quantize(windowBlue) - quantize(windowColor[3])) <= 1, "source window blue must remain visible")
end

return GraphicsSmoke.suite(T)
