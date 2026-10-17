-- Verifies transition sprite tint and opacity through the real field renderer.

local Assert = require("tests.support.Assert")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local GxRenderer = require("libs.nds.src.love.GxRenderer")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")

local T = {}

function T.transition_sprite_applies_source_color_and_alpha(scope)
  local world = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", dpiscale = 1 }))
  local target = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", dpiscale = 1 }))
  local imageData = scope:own(love.image.newImageData(1, 1))
  imageData:setPixel(0, 0, 1, 1, 1, 1)
  local sprite = scope:own(love.graphics.newImage(imageData))
  sprite:setFilter("nearest", "nearest")
  local gxRenderer = GxRenderer.new()
  scope:own(gxRenderer)
  local renderer = FieldRenderer.new({ gxRenderer = gxRenderer, graphics = love.graphics })

  love.graphics.push("all")
  love.graphics.setCanvas(world)
  love.graphics.clear(0, 0, 0, 1)
  love.graphics.setCanvas(target)
  love.graphics.clear(0, 0, 0, 1)
  renderer:drawTransition({ world = world }, {
    sprites = {
      {
        visible = true,
        imageHandle = sprite,
        image = { origin = { x = 0, y = 0 } },
        position = { x = 128 * 4096, y = 96 * 4096 },
        affine = { translateX = 0, translateY = 0, scaleX = 1, scaleY = 1, rotation = 0 },
        tint = { r = 1, g = 0, b = 0 },
        opacity = 0.5,
      },
    },
  }, { x = 0, y = 0, width = 256, height = 192 })
  love.graphics.setCanvas()
  love.graphics.pop()

  local image = scope:own(target:newImageData())
  local red, green, blue = image:getPixel(128, 96)
  Assert.near(red, 0.5, 0.03, "transition sprite preserves source particle red × opacity")
  Assert.near(green, 0, 0.03, "transition sprite tint suppresses source green")
  Assert.near(blue, 0, 0.03, "transition sprite tint suppresses source blue")
end

return GraphicsSmoke.suite(T)
