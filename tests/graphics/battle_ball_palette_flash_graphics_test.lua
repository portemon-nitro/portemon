-- The source send-out ball flash draws the staged cell through the shared
-- PaletteData_BeginPaletteFade arithmetic: the source coefficient mixes the
-- cell toward white, and transparent texels stay transparent. The blend
-- formula itself is proved level-by-level by the summary picture shader's
-- integer reference over the same shared snippet; this smoke proves the
-- ball source compiles with it and reaches that blend.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ImageSampling = require("libs.nds.src.love.ImageSampling")

local T = {}

local SHADER_PATH = "libs/hgss/src/presentation/shaders/ball_palette_flash.glsl"

---@return string shader source
local function readShaderSource()
  local source = love.filesystem.read(SHADER_PATH)
  if source == nil then
    local base = love.filesystem.getSourceBaseDirectory()
    local handle = io.open(base .. "/" .. SHADER_PATH, "rb")
    Assert.notNil(handle, "the ball flash shader source loads")
    source = handle:read("*a")
    handle:close()
  end
  Assert.notNil(source, "the ball flash shader source loads")
  return source
end

function T.ball_flash_blends_the_staged_cell_toward_source_white(scope)
  local shader = scope:own(love.graphics.newShader(ImageSampling.withSharedSnippets(readShaderSource())))
  local data = love.image.newImageData(2, 1)
  data:setPixel(0, 0, 8 / 31, 0, 0, 1)
  data:setPixel(1, 0, 0, 0, 0, 0)
  local image = scope:own(love.graphics.newImage(data))
  image:setFilter("nearest", "nearest")
  ---@param coefficient integer source blend coefficient 0..16
  ---@return table rendered pixels of the two-texel strip
  local function render(coefficient)
    local canvas = scope:own(love.graphics.newCanvas(2, 1))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.setShader(shader)
    shader:send("u_target", { 1, 1, 1 })
    shader:send("u_coefficient", coefficient)
    love.graphics.draw(image, 0, 0)
    love.graphics.setShader()
    love.graphics.setCanvas()
    return scope:own(canvas:newImageData())
  end
  local unblended = render(0)
  local unblendedRed = unblended:getPixel(0, 0)
  Assert.near(unblendedRed, 8 / 31, 1 / 255, "a zero coefficient keeps the staged channel")
  local half = render(8)
  local halfRed, halfGreen = half:getPixel(0, 0)
  Assert.isTrue(halfRed > unblendedRed, "the blend brightens the cell toward white")
  Assert.isTrue(halfGreen > 0, "the blend pulls every channel toward the target")
  local white = render(16)
  local whiteRed, whiteGreen, whiteBlue = white:getPixel(0, 0)
  Assert.near(whiteRed, 1, 1 / 255, "red reaches source white at full blend")
  Assert.near(whiteGreen, 1, 1 / 255, "green reaches source white at full blend")
  Assert.near(whiteBlue, 1, 1 / 255, "blue reaches source white at full blend")
  for _, pixels in ipairs({ unblended, half, white }) do
    local _, _, _, transparent = pixels:getPixel(1, 0)
    Assert.isTrue(transparent < 0.5, "transparent texels stay transparent")
  end
end

return GraphicsSmoke.suite(T)
