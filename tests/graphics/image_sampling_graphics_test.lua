-- Graphics acceptance for the one shared indexed-image sampling rule: an
-- indexed source plus its exact RGBA palette renders pixel-identical frames
-- to the equivalent straight RGBA image on both the generated-2D path and
-- the map path, across wrap modes and non-identity UVs, while DS fog, alpha
-- and lighting behavior stay intact and every draw restores the caller's
-- shader and tint. Synthetic fixtures only; hosts without indexed texture
-- support skip the comparison explicitly instead of fabricating it.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FieldLightProfile = require("libs.assets.src.field.FieldLightProfile")
local GxRenderer = require("libs.nds.src.love.GxRenderer")
local RenderQueue = require("libs.hgss.src.presentation.RenderQueue")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local VertexFormat = require("libs.assets.src.model.VertexFormat")

local T = {}

local IMAGE_WIDTH = 8
local IMAGE_HEIGHT = 4
local PALETTE_COUNT = 4

-- The palette under test: an opaque entry, a fully transparent entry with
-- non-zero RGB (transparent RGB must survive), a fractional-alpha entry,
-- and white. The alternate palette permutes the same entries so an
-- animated material swap changes visible pixels without changing the
-- fixture shape; both palettes travel through the same sampler.
local PALETTE = {
  { 200, 10, 20, 255 },
  { 10, 200, 30, 0 },
  { 10, 20, 30, 128 },
  { 255, 255, 255, 255 },
}

local PALETTE_ALTERNATE = {
  { 255, 255, 255, 255 },
  { 10, 20, 30, 128 },
  { 10, 200, 30, 0 },
  { 200, 10, 20, 255 },
}

-- Loads the shared sampler. Each test below fails on this message -- naming
-- the missing sampling behavior -- instead of failing the suite load, so
-- the red names the contract rather than a require path.
local function sampler()
  local ok, mod = pcall(require, "libs.nds.src.love.ImageSampling")
  Assert.isTrue(
    ok and type(mod) == "table",
    "the shared indexed-image sampler is not implemented: one exact palette-or-RGBA "
      .. "sampling rule must serve both generated 2D draws and the map renderer"
  )
  return mod
end

local function indexedBytes()
  local out = {}
  for row = 0, IMAGE_HEIGHT - 1 do
    for column = 0, IMAGE_WIDTH - 1 do
      out[#out + 1] = string.char((column + row) % PALETTE_COUNT)
    end
  end
  return table.concat(out)
end

local function buildIndexData()
  return love.image.newImageData(IMAGE_WIDTH, IMAGE_HEIGHT, "r8", indexedBytes())
end

local function buildPaletteData(palette)
  palette = palette or PALETTE
  local data = love.image.newImageData(PALETTE_COUNT, 1)
  for index, entry in ipairs(palette) do
    data:setPixel(index - 1, 0, entry[1] / 255, entry[2] / 255, entry[3] / 255, entry[4] / 255)
  end
  return data
end

local function buildRgbaData(palette)
  palette = palette or PALETTE
  local data = love.image.newImageData(IMAGE_WIDTH, IMAGE_HEIGHT)
  local raw = indexedBytes()
  for y = 0, IMAGE_HEIGHT - 1 do
    for x = 0, IMAGE_WIDTH - 1 do
      local slot = string.byte(raw, y * IMAGE_WIDTH + x + 1)
      local entry = palette[slot + 1]
      data:setPixel(x, y, entry[1] / 255, entry[2] / 255, entry[3] / 255, entry[4] / 255)
    end
  end
  return data
end

local function frameBytes(canvas)
  return canvas:newImageData():getString()
end

-- Indexed-format support is a host property of the available graphics module,
-- not a module-availability probe: callers skip explicitly through the runner
-- context instead of vanishing into a pass.
local function indexedFormatSupported()
  return love.graphics.getImageFormats().r8
end

local function skipWithoutIndexedSupport(context)
  if not indexedFormatSupported() then
    context:skip("this host reports no indexed (r8) texture support, so indexed sampling cannot be compared")
  end
end

local function handles(scope, indexImage, paletteImage, rgbaImage)
  return {
    indexed = { image = indexImage, palette = paletteImage, kind = "r8", width = 8, height = 4 },
    straight = { image = rgbaImage, kind = "rgba8", width = 8, height = 4 },
  }
end

-- The indexed 2D draw and the straight 2D draw produce byte-identical
-- frames for every wrap mode under a non-identity UV transform, restore the
-- caller's shader and tint, and allocate no per-draw GPU objects.
function T.indexed_and_straight_2d_draws_match_across_wrap_modes(scope, context)
  skipWithoutIndexedSupport(context)
  local Sampler = sampler()
  local lg = love.graphics

  local indexImage = scope:own(lg.newImage(buildIndexData()))
  local paletteImage = scope:own(lg.newImage(buildPaletteData()))
  local rgbaImage = scope:own(lg.newImage(buildRgbaData()))
  local pair = handles(scope, indexImage, paletteImage, rgbaImage)
  -- A viewport twice the source in each axis: sampling spans [0,2], so the
  -- wrap mode decides every far texel instead of staying dormant.
  local stretched = lg.newQuad(0, 0, IMAGE_WIDTH * 2, IMAGE_HEIGHT * 2, IMAGE_WIDTH, IMAGE_HEIGHT)
  local tintShader = scope:own(lg.newShader([[
vec4 effect(vec4 color, Image tex, vec2 texCoord, vec2 screenCoord) {
  return color;
}
]]))

  -- Warm up once before measuring the global census: the first sampler
  -- draw may settle a finalizer left over from earlier suites, so the
  -- steady-state draws below are measured against the settled count.
  -- (Canvases stay exact throughout: the suite owns every canvas below.)
  Sampler.draw(lg, pair.indexed, stretched, 0, 0)
  lg.setShader()
  collectgarbage("collect")
  local statsBefore = lg.getStats()
  for _, wrap in ipairs({ "repeat", "mirroredrepeat", "clamp" }) do
    indexImage:setWrap(wrap, wrap)
    rgbaImage:setWrap(wrap, wrap)
    local indexedCanvas = scope:own(lg.newCanvas(IMAGE_WIDTH * 2, IMAGE_HEIGHT * 2))
    local straightCanvas = scope:own(lg.newCanvas(IMAGE_WIDTH * 2, IMAGE_HEIGHT * 2))
    lg.setCanvas(indexedCanvas)
    lg.clear(0, 0, 0, 0)
    lg.setShader(tintShader)
    lg.setColor(0.2, 0.4, 0.6, 0.8)
    Sampler.draw(lg, pair.indexed, stretched, 0, 0)
    Assert.equal(lg.getShader(), tintShader, "an indexed draw restores the caller's shader (" .. wrap .. ")")
    local r, g, b, a = lg.getColor()
    Assert.near(r, 0.2, 1e-6, "an indexed draw restores the caller tint red (" .. wrap .. ")")
    Assert.near(g, 0.4, 1e-6, "an indexed draw restores the caller tint green (" .. wrap .. ")")
    Assert.near(b, 0.6, 1e-6, "an indexed draw restores the caller tint blue (" .. wrap .. ")")
    Assert.near(a, 0.8, 1e-6, "an indexed draw restores the caller tint alpha (" .. wrap .. ")")
    lg.setCanvas(straightCanvas)
    lg.clear(0, 0, 0, 0)
    Sampler.draw(lg, pair.straight, stretched, 0, 0)
    Assert.equal(lg.getShader(), tintShader, "a straight draw restores the caller's shader (" .. wrap .. ")")
    lg.setCanvas()
    lg.setShader()
    Assert.equal(
      frameBytes(indexedCanvas),
      frameBytes(straightCanvas),
      "indexed and straight 2D frames match under wrap " .. wrap .. ", including fractional alpha and transparent RGB"
    )
  end
  local statsAfter = lg.getStats()
  Assert.equal(statsAfter.images, statsBefore.images, "repeated sampler draws allocate no per-draw GPU images")
  Assert.equal(statsAfter.canvases, statsBefore.canvases + 6, "repeated sampler draws allocate no per-draw canvases")
end

local IDENTITY = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
local IDENTITY_NORMAL = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }

local function fixedCamera()
  local function identity(_)
    return IDENTITY
  end
  return { distance = 26, far = 400, view = identity, projection = identity, billboardProjection = identity }
end

-- A full-viewport quad whose U span is [0,2]: the repeat wrap tiles the
-- indexed fixture twice across the frame on both paths under test.
local function wrappedQuad(scope)
  local function vertex(x, y, u, v)
    return { x, y, 0, u, v, 0, 0, 1, 1, 1, 1, 1, 0 }
  end
  return scope:own(love.graphics.newMesh(VertexFormat.LAYOUT, {
    vertex(-1, -1, 0, 0),
    vertex(1, -1, 2, 0),
    vertex(1, 1, 2, 1),
    vertex(-1, -1, 0, 0),
    vertex(1, 1, 2, 1),
    vertex(-1, 1, 0, 1),
  }, "triangles", "static"))
end

local function texturedItem(mesh, materialImage, indexed)
  local material = {
    alphaClass = "opaque",
    texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
    image = materialImage,
  }
  if indexed then
    material.palette = indexed.palette
    material.indexed = true
  end
  return {
    mesh = mesh,
    material = material,
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    alphaClass = "opaque",
    cullMode = "none",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = 0,
    fogEnabled = true,
    lightMask = 0,
    alphaCutoff = 0.5 / 255,
    center = { 0, 0, 0 },
  }
end

local function sceneRuntime(fog)
  local white = 31 + 31 * 32 + 31 * 1024
  return {
    mapDraws = {},
    buildingDraws = {},
    stats = { triangleCount = 0, meshCount = 0, textureCount = 0 },
    edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
    fog = fog,
    lighting = {
      records = {
        {
          endHalfSeconds = 0,
          lights = {
            { enabled = true, colorRgb555 = white, vectorFx12 = { 0, 0, -4096 } },
            { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
            { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
            { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          },
          diffuseRgb555 = white,
          ambientRgb555 = white,
          specularRgb555 = 0,
          emissionRgb555 = 0,
        },
      },
    },
  }
end

local function denseFog()
  local table32 = {}
  for index = 1, 32 do
    table32[index] = 127
  end
  return { enabled = true, color = 31 + 31 * 32 + 31 * 1024, offset = 0, slope = 0, alpha = 31, table = table32 }
end

local function noFog()
  local table32 = {}
  for index = 1, 32 do
    table32[index] = 0
  end
  return { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = table32 }
end

local function renderScene(renderer, item, fog)
  local camera = fixedCamera()
  local queue = RenderQueue.buildInto({ { item } }, camera:view(), RenderQueue.newScratch())
  local runtime = sceneRuntime(fog)
  local lighting = FieldLightProfile.select(runtime.lighting, FieldLightProfile.DEFAULT_TIME_SECONDS)
  renderer:draw({
    lighting = lighting,
    edgeColors = runtime.edgeColors,
    fog = fog,
    viewMatrix = camera:view(),
    worldProjection = camera:projection(),
    billboardProjection = camera:billboardProjection(),
    queue = queue,
    spriteItems = nil,
    viewport = FieldViewport.new(64, 48, { mode = "strict" }),
  })
end

-- The map path samples the indexed fixture through the same rule as the
-- straight image: both frames -- color and render state -- are identical
-- with fog and lighting live, disabling fog still changes the frame (the DS
-- stages are untouched, not bypassed), and the draw restores caller state.
function T.indexed_and_straight_map_frames_match_with_fog_and_lighting_live(scope, context)
  skipWithoutIndexedSupport(context)
  local Sampler = sampler()
  Assert.notNil(Sampler, "the map comparison needs the shared sampler module present")
  local lg = love.graphics
  local renderer = scope:own(GxRenderer.new())

  local indexImage = scope:own(lg.newImage(buildIndexData()))
  local paletteImage = scope:own(lg.newImage(buildPaletteData()))
  local rgbaImage = scope:own(lg.newImage(buildRgbaData()))
  for _, image in ipairs({ indexImage, paletteImage, rgbaImage }) do
    image:setFilter("nearest", "nearest")
  end
  indexImage:setWrap("repeat", "repeat")
  rgbaImage:setWrap("repeat", "repeat")
  local mesh = wrappedQuad(scope)

  local tintShader = scope:own(lg.newShader([[
vec4 effect(vec4 color, Image tex, vec2 texCoord, vec2 screenCoord) {
  return color;
}
]]))
  lg.setShader(tintShader)
  lg.setColor(0.3, 0.5, 0.7, 1)
  renderScene(renderer, texturedItem(mesh, rgbaImage), denseFog())
  local straightColor = frameBytes(renderer.sceneColor)
  local straightState = frameBytes(renderer.renderState)
  renderScene(renderer, texturedItem(mesh, indexImage, { palette = paletteImage }), denseFog())
  local indexedColor = frameBytes(renderer.sceneColor)
  local indexedState = frameBytes(renderer.renderState)
  Assert.equal(lg.getShader(), tintShader, "a textured map draw restores the caller's shader")
  local r, g, b, a = lg.getColor()
  Assert.near(r, 0.3, 1e-6, "a textured map draw restores the caller tint red")
  Assert.near(g, 0.5, 1e-6, "a textured map draw restores the caller tint green")
  Assert.near(b, 0.7, 1e-6, "a textured map draw restores the caller tint blue")
  Assert.near(a, 1, 1e-6, "a textured map draw restores the caller tint alpha")
  lg.setShader()
  Assert.equal(indexedColor, straightColor, "indexed and straight map frames match with fog and lighting live")
  Assert.equal(indexedState, straightState, "indexed and straight map draws stamp identical render state")

  -- World MRT writes unfogged color to sceneColor by design; fog applies at
  -- the final resolve, so the fog toggle is observed on the presented frame.
  local function presentedBytes(item, fog)
    local canvas = scope:own(lg.newCanvas(renderer.colorW, renderer.colorH))
    lg.setCanvas(canvas)
    renderScene(renderer, item, fog)
    lg.setCanvas()
    return frameBytes(canvas)
  end
  local foggedPresented = presentedBytes(texturedItem(mesh, rgbaImage), denseFog())
  local unfoggedPresented = presentedBytes(texturedItem(mesh, rgbaImage), noFog())
  Assert.isTrue(
    unfoggedPresented ~= foggedPresented,
    "disabling fog still changes the frame: the fog stage stays live, not bypassed"
  )
end

-- Animated swaps stay exact across representations: a three-frame material
-- sequence (first palette, alternate palette, first again) renders
-- byte-identical color and render-state frames under indexed and straight
-- sampling on the map path with fog and lighting live, under both repeat
-- and mirrored-repeat wrapping. The swap visibly changes the frame and
-- returning to the first material restores its frame, so the comparison
-- proves live pixels rather than a dormant texture.
function T.paired_captures_match_across_animated_swaps_and_uv_phases(scope, context)
  skipWithoutIndexedSupport(context)
  local Sampler = sampler()
  Assert.notNil(Sampler, "the swap comparison needs the shared sampler module present")
  local lg = love.graphics
  local renderer = scope:own(GxRenderer.new())

  local firstIndex = scope:own(lg.newImage(buildIndexData()))
  local firstPalette = scope:own(lg.newImage(buildPaletteData()))
  local firstStraight = scope:own(lg.newImage(buildRgbaData()))
  local secondIndex = scope:own(lg.newImage(buildIndexData()))
  local secondPalette = scope:own(lg.newImage(buildPaletteData(PALETTE_ALTERNATE)))
  local secondStraight = scope:own(lg.newImage(buildRgbaData(PALETTE_ALTERNATE)))
  for _, image in ipairs({ firstIndex, firstPalette, firstStraight, secondIndex, secondPalette, secondStraight }) do
    image:setFilter("nearest", "nearest")
  end
  local mesh = wrappedQuad(scope)
  local sequence = {
    { index = firstIndex, palette = firstPalette, straight = firstStraight },
    { index = secondIndex, palette = secondPalette, straight = secondStraight },
    { index = firstIndex, palette = firstPalette, straight = firstStraight },
  }

  local tintShader = scope:own(lg.newShader([[
vec4 effect(vec4 color, Image tex, vec2 texCoord, vec2 screenCoord) {
  return color;
}
]]))
  for _, wrap in ipairs({ "repeat", "mirroredrepeat" }) do
    for _, image in ipairs({ firstIndex, firstStraight, secondIndex, secondStraight }) do
      image:setWrap(wrap, wrap)
    end
    local frames = {}
    lg.setShader(tintShader)
    lg.setColor(0.3, 0.5, 0.7, 1)
    for step, entry in ipairs(sequence) do
      renderScene(renderer, texturedItem(mesh, entry.straight), denseFog())
      local straightColor = frameBytes(renderer.sceneColor)
      local straightState = frameBytes(renderer.renderState)
      renderScene(renderer, texturedItem(mesh, entry.index, { palette = entry.palette }), denseFog())
      local indexedColor = frameBytes(renderer.sceneColor)
      local indexedState = frameBytes(renderer.renderState)
      Assert.equal(
        indexedColor,
        straightColor,
        "swap frame " .. step .. " matches across representations under wrap " .. wrap
      )
      Assert.equal(
        indexedState,
        straightState,
        "swap frame " .. step .. " stamps identical render state under wrap " .. wrap
      )
      frames[#frames + 1] = indexedColor
    end
    Assert.equal(lg.getShader(), tintShader, "a swap sequence restores the caller shader (" .. wrap .. ")")
    lg.setShader()
    Assert.isTrue(frames[1] ~= frames[2], "the material swap visibly changes the frame under wrap " .. wrap)
    Assert.equal(frames[1], frames[3], "returning to the first material restores its frame under wrap " .. wrap)
  end
end

-- The same-pipeline straight fallback needs no indexed capability: a
-- straight handle draws deterministically through the shared sampler
-- without consulting the format probe, and a failed draw restores the
-- caller shader and tint before re-raising instead of adopting pixels.
function T.straight_fallback_draws_without_indexed_support_and_restores_state_on_failure(scope)
  local Sampler = sampler()
  local lg = love.graphics

  local rgbaImage = scope:own(lg.newImage(buildRgbaData()))
  rgbaImage:setWrap("repeat", "repeat")
  local handle = { image = rgbaImage, kind = "rgba8", width = 8, height = 4 }
  -- A viewport twice the source in each axis: sampling spans [0,2], so the
  -- wrap mode decides every far texel instead of staying dormant.
  local stretched = lg.newQuad(0, 0, IMAGE_WIDTH * 2, IMAGE_HEIGHT * 2, IMAGE_WIDTH, IMAGE_HEIGHT)
  local first = scope:own(lg.newCanvas(IMAGE_WIDTH * 2, IMAGE_HEIGHT * 2))
  local second = scope:own(lg.newCanvas(IMAGE_WIDTH * 2, IMAGE_HEIGHT * 2))
  lg.setColor(1, 1, 1, 1)
  lg.setCanvas(first)
  lg.clear(0, 0, 0, 0)
  Sampler.draw(lg, handle, stretched, 0, 0)
  lg.setCanvas(second)
  lg.clear(0, 0, 0, 0)
  Sampler.draw(lg, handle, stretched, 0, 0)
  lg.setCanvas()
  Assert.equal(
    frameBytes(first),
    frameBytes(second),
    "the straight fallback renders deterministically through the shared sampler"
  )

  local tintShader = scope:own(lg.newShader([[
vec4 effect(vec4 color, Image tex, vec2 texCoord, vec2 screenCoord) {
  return color;
}
]]))
  lg.setShader(tintShader)
  lg.setColor(0.2, 0.4, 0.6, 0.8)
  local ok = pcall(Sampler.draw, lg, handle, "not-a-quad", 0, 0)
  Assert.isFalse(ok, "a failed sampler draw re-raises instead of adopting pixels")
  Assert.equal(lg.getShader(), tintShader, "a failed draw restores the caller shader")
  local r, g, b, a = lg.getColor()
  Assert.near(r, 0.2, 1e-6, "a failed draw restores the caller tint red")
  Assert.near(g, 0.4, 1e-6, "a failed draw restores the caller tint green")
  Assert.near(b, 0.6, 1e-6, "a failed draw restores the caller tint blue")
  Assert.near(a, 0.8, 1e-6, "a failed draw restores the caller tint alpha")
  lg.setShader()
  lg.setColor(1, 1, 1, 1)
end

-- Host contracts the shared image path relies on: the 11.5 indexed pixel
-- payload path exists, the format probe answers, texture bytes are reported
-- as bytes (never equated with process memory here), and a palette can be
-- sent to a shader as a texture uniform.
function T.host_image_contracts_for_fallback_and_accounting_hold(scope)
  local lg = love.graphics
  local raw = indexedBytes()
  local indexData = love.image.newImageData(IMAGE_WIDTH, IMAGE_HEIGHT, "r8", raw)
  Assert.equal(indexData:getWidth(), IMAGE_WIDTH, "the indexed payload path keeps the width")
  Assert.equal(indexData:getHeight(), IMAGE_HEIGHT, "the indexed payload path keeps the height")
  Assert.equal(#indexData:getString(), IMAGE_WIDTH * IMAGE_HEIGHT, "the indexed payload is one byte per pixel")
  Assert.equal(indexData:getString(), raw, "the indexed payload preserves exact index bytes")

  local formats = lg.getImageFormats()
  Assert.equal(type(formats), "table", "the format probe answers with a table")
  Assert.equal(type(formats.r8), "boolean", "the format probe answers indexed support as a boolean, never nil")

  local stats = lg.getStats()
  Assert.equal(type(stats.texturememory), "number", "used texture bytes are reported as a number")
  Assert.equal(type(stats.images), "number", "the live image count is reported as a number")

  local paletteImage = scope:own(lg.newImage(buildPaletteData()))
  local probe = scope:own(lg.newShader([[
uniform Image u_palette;
vec4 effect(vec4 color, Image tex, vec2 texCoord, vec2 screenCoord) {
  return color * Texel(u_palette, vec2(0.5, 0.5));
}
]]))
  probe:send("u_palette", paletteImage)
  Assert.notNil(probe, "a shader accepts a palette image as a texture uniform")
end

return GraphicsSmoke.suite(T)
