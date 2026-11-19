-- The one host-side sampler for generated images: a single exact
-- palette-or-RGBA rule (libs/nds/src/love/shaders/palette_sampling.glsl)
-- serving both generated 2D draws and the map renderer. Indexed sources
-- resolve through their exact RGBA palette, straight sources pass through
-- unchanged, and every draw restores the caller shader it found. This
-- module owns no pixels, caches, or leases; the image pool owns the GPU
-- objects, callers own the draw placement, and the map renderer binds the
-- same uniforms through sendMaterialSampling.

---@class ImageSamplingHandle
---@field image love.Image resolved source image (index bytes or straight RGBA)
---@field palette love.Image? exact RGBA palette, required for indexed sources
---@field kind "r8"|"rgba8" payload representation of the source image
---@field width integer decoded source width in pixels
---@field height integer decoded source height in pixels

---@class ImageSamplingMaterial
---@field image unknown? bound source image of a map material
---@field palette love.Image? exact RGBA palette of an indexed map material
---@field indexed boolean? true when the material samples through a palette
---@field offset integer? native palette override offset in colors

---@class ImageSamplingShader
---@field send function texture and sampling uniform delivery
---@field hasUniform function? uniform presence query when the host shader exposes it
---@field release function? shader disposal when owned elsewhere

local ImageSampling = {}

-- Repo-relative shader snippet path, addressed like every other engine
-- shader source in this package.
local SAMPLING_SOURCE_PATH = "libs/nds/src/love/shaders/palette_sampling.glsl"

-- Shared source palette blend toward an RGB555 target. Consumers that
-- carry the marker below splice it in at construction time.
local PALETTE_FADE_SOURCE_PATH = "libs/nds/src/love/shaders/palette_fade.glsl"

-- Marker comment inside map.glsl where the shared snippet is substituted
-- at renderer construction. Sources without the marker (test doubles)
-- pass through untouched.
local SAMPLING_MARKER = "/*__portemon_shared_image_sampling__*/"
local PALETTE_FADE_MARKER = "/*__portemon_shared_palette_fade__*/"

local EFFECT_WRAPPER = [[
vec4 effect(vec4 color, Image tex, vec2 texCoord, vec2 screenCoord) {
  return resolveExactTexel(Texel(tex, texCoord)) * color;
}
]]

local _snippet = nil
local _paletteFadeSnippet = nil
local _shaderCache = setmetatable({}, { __mode = "k" })

-- Read one shared snippet through the same archive-or-checkout boundary
-- the renderer uses for its own shader sources.
---@param path string
---@return string
local function readSharedSource(path)
  if love and love.filesystem then
    local source = love.filesystem.read(path)
    if source then
      return source
    end
    local base = love.filesystem.getSourceBaseDirectory()
    local handle = io.open(base .. "/" .. path, "rb")
    if handle then
      local fallback = handle:read("*a")
      handle:close()
      return fallback
    end
  end
  error("cannot read shared shader snippet: " .. path)
end

-- The shared snippet text, read once. The map renderer substitutes it for
-- its marker; the 2D shader below is built from it directly.
---@return string
function ImageSampling.samplingGlsl()
  if _snippet == nil then
    _snippet = readSharedSource(SAMPLING_SOURCE_PATH)
  end
  return _snippet
end

-- The shared palette-fade snippet text, read once. Shaders that apply the
-- source blend splice it in at their own marker.
---@return string
function ImageSampling.paletteFadeGlsl()
  if _paletteFadeSnippet == nil then
    _paletteFadeSnippet = readSharedSource(PALETTE_FADE_SOURCE_PATH)
  end
  return _paletteFadeSnippet
end

-- Substitute the shared snippet for the marker inside a map shader source.
-- Sources without the marker are returned unchanged so engine-source
-- doubles keep their exact construction contract.
---@param source string map shader source as read from its owner path
---@return string
function ImageSampling.withSharedSampling(source)
  local at = source:find(SAMPLING_MARKER, 1, true)
  if at == nil then
    return source
  end
  return source:sub(1, at - 1) .. ImageSampling.samplingGlsl() .. source:sub(at + #SAMPLING_MARKER)
end

-- Substitute the shared palette-fade snippet for its marker inside a shader
-- source. Sources without the marker pass through untouched.
---@param source string shader source as read from its owner path
---@return string
function ImageSampling.withSharedPaletteFade(source)
  local at = source:find(PALETTE_FADE_MARKER, 1, true)
  if at == nil then
    return source
  end
  return source:sub(1, at - 1) .. ImageSampling.paletteFadeGlsl() .. source:sub(at + #PALETTE_FADE_MARKER)
end

-- Substitute every shared snippet a shader source declares. Sources with no
-- markers come back unchanged, like withSharedSampling alone.
---@param source string shader source as read from its owner path
---@return string
function ImageSampling.withSharedSnippets(source)
  return ImageSampling.withSharedPaletteFade(ImageSampling.withSharedSampling(source))
end

-- Bind the map-side sampling uniforms for one material: indexed materials
-- resolve through their palette image, everything else samples straight
-- RGBA. The flag is sent on every draw so no stale palette state leaks
-- across materials or into untextured draws.
---@param shader { send: function, hasUniform: function? } sampling uniform sink of the calling renderer
---@param material ImageSamplingMaterial?
function ImageSampling.sendMaterialSampling(shader, material)
  if type(material) == "table" and material.indexed == true and material.image ~= nil then
    local palette = assert(material.palette, "indexed material sampling requires a palette image")
    shader:send("u_usePalette", true)
    shader:send("u_paletteCount", palette:getWidth())
    shader:send("u_palette", palette)
    if type(shader.hasUniform) == "function" and shader:hasUniform("u_paletteOffset") then
      shader:send("u_paletteOffset", material.offset or 0)
    end
  else
    shader:send("u_usePalette", false)
  end
end

-- Fetch the cached 2D sampling shader for one graphics namespace. One
-- shader serves every image: representation and palette travel as uniforms,
-- never as shader variants.
---@param graphics love.graphics
---@return ImageSamplingShader
local function shaderFor(graphics)
  local shader = _shaderCache[graphics]
  if shader == nil then
    shader = graphics.newShader(ImageSampling.samplingGlsl() .. "\n" .. EFFECT_WRAPPER)
    _shaderCache[graphics] = shader
  end
  return shader --[[@as ImageSamplingShader]]
end

-- Normalize one draw handle to the exact rule: both the source and its
-- palette (when present) sample nearest, so an index byte never
-- interpolates and straight comparisons stay exact.
---@param handle ImageSamplingHandle
local function normalizeHandleFilter(handle)
  handle.image:setFilter("nearest", "nearest")
  if handle.kind == "r8" then
    assert(handle.palette ~= nil, "indexed sampler draw requires a palette image")
    handle.palette:setFilter("nearest", "nearest")
  end
end

-- Bind the 2D sampling uniforms for one draw and issue it under the shared
-- shader. The caller quad stays optional; extra placement arguments pass
-- through to the draw call.
local function drawWithShader(graphics, shader, handle, quad, x, y, ...)
  graphics.setShader(shader)
  if handle.kind == "r8" then
    local palette = assert(handle.palette, "indexed sampler draw requires a palette image")
    shader:send("u_usePalette", true)
    shader:send("u_paletteCount", palette:getWidth())
    shader:send("u_palette", palette)
    shader:send("u_paletteOffset", 0)
  else
    shader:send("u_usePalette", false)
  end
  if quad ~= nil then
    graphics.draw(handle.image, quad, x, y, ...)
  else
    graphics.draw(handle.image, x, y, ...)
  end
end

-- Draw one resolved image handle through the shared exact rule onto the
-- current canvas. Tint, canvas, blend, and caller shader state are
-- preserved: the previous shader is restored on success and on failure,
-- and a failed draw re-raises without adopting anything.
---@param graphics love.graphics host namespace the handle was realized in
---@param handle ImageSamplingHandle resolved source (and palette) images
---@param quad love.Quad? optional source viewport, already transformed UVs owned by the caller
---@param x number draw position x
---@param y number draw position y
---@param ... number optional extra placement arguments forwarded to the draw call
function ImageSampling.draw(graphics, handle, quad, x, y, ...)
  assert(handle ~= nil and handle.image ~= nil, "sampler draw requires a resolved image handle")
  normalizeHandleFilter(handle)
  local shader = shaderFor(graphics)
  local previous = graphics.getShader()
  local ok, err = pcall(drawWithShader, graphics, shader, handle, quad, x, y, ...)
  graphics.setShader(previous)
  if not ok then
    error(err, 0)
  end
end

return ImageSampling
