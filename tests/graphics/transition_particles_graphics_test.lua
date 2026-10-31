-- Verifies a source task's particle layer through the real field renderer:
-- it draws under the retail particle camera scaled to the viewport, and the
-- source BG priority decides whether it covers the sprite plane.

local Assert = require("tests.support.Assert")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local GxRenderer = require("libs.nds.src.love.GxRenderer")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local SplParticleSimulation = require("libs.hgss.src.presentation.SplParticleSimulation")
local TransitionParticlesFixture = require("tests.support.TransitionParticlesFixture")

local T = {}

-- One white one-unit particle at the world origin, which the retail
-- particle camera maps to a 48 pixel square at the screen center.
---@return SplParticleSimulation
local function originParticle()
  local record = TransitionParticlesFixture.set(1).emitters[1]
  record.animations = {}
  record.fields = {}
  record.initPosType = 0
  record.position = { x = 0, y = 0, z = 0 }
  record.velocityFx = { pos = 0, axis = 0 }
  record.velRandom = 0
  local simulation = SplParticleSimulation.new(0, 0)
  SplParticleSimulation.addEmitter(simulation, 0, nil, record)
  SplParticleSimulation.advance(simulation)
  return simulation
end

---@param scope table
---@param color number[]
---@return love.Image
local function solidImage(scope, color)
  local imageData = scope:own(love.image.newImageData(1, 1))
  imageData:setPixel(0, 0, color[1], color[2], color[3], 1)
  local image = scope:own(love.graphics.newImage(imageData))
  image:setFilter("nearest", "nearest")
  image:setWrap("repeat", "repeat")
  return image
end

---@param scope table
---@param aboveSprites boolean
---@param destination { x: number, y: number, width: number, height: number }
---@return love.ImageData
local function drawLayer(scope, aboveSprites, destination)
  local world = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", dpiscale = 1 }))
  local target = scope:own(love.graphics.newCanvas(512, 384, { format = "rgba8", dpiscale = 1 }))
  local renderer = FieldRenderer.new({ gxRenderer = scope:own(GxRenderer.new()), graphics = love.graphics })
  local white = solidImage(scope, { 1, 1, 1 })
  local blue = solidImage(scope, { 0, 0, 1 })
  love.graphics.push("all")
  love.graphics.setCanvas(world)
  love.graphics.clear(1, 0, 0, 1)
  love.graphics.setCanvas(target)
  love.graphics.clear(0, 0, 0, 1)
  renderer:drawTransition({ world = world }, {
    sprites = {
      {
        visible = true,
        imageHandle = blue,
        image = { origin = { x = -0.5, y = -0.5 } },
        position = { x = 128 * 4096, y = 96 * 4096 },
        affine = { translateX = 0, translateY = 0, scaleX = 20, scaleY = 20, rotation = 0 },
      },
    },
    particleSystem = {
      draw = { simulation = originParticle(), textures = { [0] = white }, aboveSprites = aboveSprites },
    },
  }, destination)
  love.graphics.setCanvas()
  love.graphics.pop()
  return scope:own(target:newImageData())
end

function T.particle_layer_draws_under_the_retail_camera_scaled_to_the_viewport(scope)
  local image = drawLayer(scope, true, { x = 0, y = 0, width = 512, height = 384 })
  -- At double scale the 48 pixel particle spans 96 pixels around (256, 192).
  local red, green = image:getPixel(256 + 40, 192)
  Assert.near(red, 1, 0.02, "the layer covers pixels inside the scaled particle")
  Assert.near(green, 1, 0.02, "the particle keeps its white texture")
  red, green = image:getPixel(256 + 60, 192)
  Assert.near(red, 1, 0.02, "the field stays visible outside the particle")
  Assert.near(green, 0, 0.02, "the particle does not extend past its scaled extent")
end

function T.particle_priority_decides_whether_the_layer_covers_the_sprite_plane(scope)
  local destination = { x = 0, y = 0, width = 512, height = 384 }
  local above = drawLayer(scope, true, destination)
  local _, aboveGreen = above:getPixel(256, 192)
  Assert.near(aboveGreen, 1, 0.02, "an outranking layer draws white over the blue sprite")
  local below = drawLayer(scope, false, destination)
  local belowRed, belowGreen, belowBlue = below:getPixel(256, 192)
  Assert.near(belowBlue, 1, 0.02, "a layer at the sprite priority draws behind the sprite")
  Assert.near(belowRed + belowGreen, 0, 0.02, "the sprite covers the layer where they overlap")
end

return GraphicsSmoke.suite(T)
