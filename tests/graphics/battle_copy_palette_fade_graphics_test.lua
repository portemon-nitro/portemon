-- The battle OBJ palette blend (animation sprite copies and the send-out
-- ball flash) draws the staged cell through the shared
-- PaletteData_BeginPaletteFade arithmetic: the source coefficient mixes the
-- cell toward the target, indexed cells resolve through their exact palette
-- first, and transparent texels stay transparent. The blend formula itself
-- is proved level-by-level by the summary picture shader's integer
-- reference over the same shared snippet; this smoke proves the source
-- compiles with it and reaches that blend for both representations.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ImageSampling = require("libs.nds.src.love.ImageSampling")

local T = {}

local SHADER_PATH = "libs/hgss/src/presentation/shaders/battle_copy_palette_fade.glsl"

---@return string shader source
local function readShaderSource()
  local source = love.filesystem.read(SHADER_PATH)
  if source == nil then
    local base = love.filesystem.getSourceBaseDirectory()
    local handle = io.open(base .. "/" .. SHADER_PATH, "rb")
    Assert.notNil(handle, "the palette fade shader source loads")
    source = handle:read("*a")
    handle:close()
  end
  Assert.notNil(source, "the palette fade shader source loads")
  return source
end

-- Renders a two-texel strip through the blend toward white and proves the
-- first texel brightens from its source red to white while the second
-- stays transparent.
---@param scope table graphics smoke resource scope
---@param image love.Image staged two-texel strip
---@param bind fun(shader: love.Shader) representation uniform binding
local function assertBlendsTowardWhite(scope, image, bind)
  local shader = scope:own(love.graphics.newShader(ImageSampling.withSharedSnippets(readShaderSource())))
  ---@param coefficient integer source blend coefficient 0..16
  ---@return love.ImageData rendered pixels of the two-texel strip
  local function render(coefficient)
    local canvas = scope:own(love.graphics.newCanvas(2, 1))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.setShader(shader)
    shader:send("u_fadeTarget", { 1, 1, 1 })
    shader:send("u_fadeCoefficient", coefficient)
    bind(shader)
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

function T.palette_fade_blends_a_straight_cell_toward_source_white(scope)
  local data = love.image.newImageData(2, 1)
  data:setPixel(0, 0, 8 / 31, 0, 0, 1)
  data:setPixel(1, 0, 0, 0, 0, 0)
  local image = scope:own(love.graphics.newImage(data))
  image:setFilter("nearest", "nearest")
  assertBlendsTowardWhite(scope, image, function(shader)
    shader:send("u_usePalette", false)
  end)
end

function T.palette_fade_resolves_an_indexed_cell_before_the_blend(scope)
  local indices = love.image.newImageData(2, 1, "r8", string.char(1, 0))
  local image = scope:own(love.graphics.newImage(indices))
  image:setFilter("nearest", "nearest")
  local colors = love.image.newImageData(2, 1)
  colors:setPixel(0, 0, 0, 0, 0, 0)
  colors:setPixel(1, 0, 8 / 31, 0, 0, 1)
  local palette = scope:own(love.graphics.newImage(colors))
  palette:setFilter("nearest", "nearest")
  assertBlendsTowardWhite(scope, image, function(shader)
    shader:send("u_usePalette", true)
    shader:send("u_paletteCount", 2)
    shader:send("u_palette", palette)
    shader:send("u_paletteOffset", 0)
  end)
end

return GraphicsSmoke.suite(T)
