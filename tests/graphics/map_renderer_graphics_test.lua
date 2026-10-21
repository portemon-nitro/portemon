-- Cheap field-renderer smoke: compile the production renderer and draw an
-- empty field frame through its normal viewport pipeline.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local loveGraphics = love.graphics

local identity = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
local table32 = {}
for index = 1, 32 do
  table32[index] = 0
end

local T = {}

function T.field_renderer_compiles_and_draws_an_empty_world(scope)
  local renderer = scope:own(FieldRenderer.new())
  local target = scope:own(loveGraphics.newCanvas(64, 48, { format = "rgba8", dpiscale = 1 }))
  loveGraphics.setCanvas(target)
  loveGraphics.clear(0, 0, 0, 1)

  renderer:draw(
    {
      edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
      fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = table32 },
    },
    {
      zoom = 1,
      view = function()
        return identity
      end,
      projection = function()
        return identity
      end,
      billboardProjection = function()
        return identity
      end,
    },
    {},
    nil,
    FieldViewport.new(64, 48, { mode = "strict" }),
    0
  )

  Assert.notNil(renderer.gxRenderer.shader, "the field renderer compiles its production shader")
end

return GraphicsSmoke.suite(T)
