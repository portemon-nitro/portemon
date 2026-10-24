-- Verifies source white-palette fade composition through the real field renderer.

local Assert = require("tests.support.Assert")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local GxRenderer = require("libs.nds.src.love.GxRenderer")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local T = {}

function T.overlay116_white_fade_composites_over_the_native_field_frame(scope)
  local world = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", dpiscale = 1 }))
  local target = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", dpiscale = 1 }))
  love.graphics.push("all")
  love.graphics.setCanvas(world)
  love.graphics.clear(0.2, 0.4, 0.6, 1)
  love.graphics.setCanvas(target)
  love.graphics.clear(0, 0, 0, 1)

  local renderer = FieldRenderer.new({ gxRenderer = GxRenderer.new(), graphics = love.graphics })
  scope:own(renderer.gxRenderer)
  renderer:drawTransition({ world = world }, { whiteFadeAlpha = 0.5 }, { x = 0, y = 0, width = 256, height = 192 })
  love.graphics.setCanvas()
  love.graphics.pop()

  local image = scope:own(target:newImageData())
  local red, green, blue = image:getPixel(128, 96)
  Assert.near(red, 0.6, 0.01, "fade blends the native red channel toward white")
  Assert.near(green, 0.7, 0.01, "fade blends the native green channel toward white")
  Assert.near(blue, 0.8, 0.01, "fade blends the native blue channel toward white")
end

function T.source_screen_brightness_composites_white_and_black_over_the_field(scope)
  local world = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", dpiscale = 1 }))
  local target = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", dpiscale = 1 }))
  local renderer = FieldRenderer.new({ gxRenderer = GxRenderer.new(), graphics = love.graphics })
  scope:own(renderer.gxRenderer)

  love.graphics.push("all")
  love.graphics.setCanvas(world)
  love.graphics.clear(0.2, 0.4, 0.6, 1)
  love.graphics.setCanvas(target)
  love.graphics.clear(0, 0, 0, 1)
  renderer:drawTransition(
    { world = world },
    { screenBrightness = 8 },
    { x = 0, y = 0, width = 256, height = 192 }
  )
  love.graphics.setCanvas()
  local halfWhite = scope:own(target:newImageData())
  local red, green, blue = halfWhite:getPixel(128, 96)
  Assert.near(red, 0.6, 0.01, "positive source brightness blends the field toward white")
  Assert.near(green, 0.7, 0.01, "positive source brightness applies the same coefficient to green")
  Assert.near(blue, 0.8, 0.01, "positive source brightness applies the same coefficient to blue")

  love.graphics.setCanvas(target)
  love.graphics.clear(0, 0, 0, 1)
  renderer:drawTransition(
    { world = world },
    { brightness = -8 },
    { x = 0, y = 0, width = 256, height = 192 }
  )
  love.graphics.setCanvas()
  local halfBlack = scope:own(target:newImageData())
  red, green, blue = halfBlack:getPixel(128, 96)
  Assert.near(red, 0.1, 0.01, "negative source brightness blends the field toward black")
  Assert.near(green, 0.2, 0.01, "negative source brightness applies the same coefficient to green")
  Assert.near(blue, 0.3, 0.01, "negative source brightness applies the same coefficient to blue")
  love.graphics.pop()
end

return GraphicsSmoke.suite(T)
