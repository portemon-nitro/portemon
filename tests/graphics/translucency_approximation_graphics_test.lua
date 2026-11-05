-- Real-GPU verification of the approximate translucency path: the DS
-- (alpha5 + 1) / 32 RGB blending coefficient and the per-pixel last
-- translucent polygon-ID suppression through the world depth canvas's
-- stencil attachment.
--
-- Every test renders real meshes through the production GxRenderer and reads
-- the blended sceneColor target back: fullscreen world-space quads under an
-- orthographic camera make every assertion a direct pixel comparison against
-- the DS blending equation. Quad depths stagger by 0.1 in world Z so
-- coplanar submissions never fail the strict host "less" depth test against
-- each other; the queue ties on identical screen extents and keeps submission
-- order, so sequence tests submit in their intended blend order.
--
-- Frames that belong to one scenario share a single renderer: constructing
-- the renderer (shader compilation, target generation) dominates per-frame
-- draw cost, so one scenario reuses it across its frames instead of paying
-- setup per assertion.

local Assert = require("tests.support.Assert")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local GxRenderer = require("libs.nds.src.love.GxRenderer")
local Matrix4 = require("libs.math.src.Matrix4")
local RenderQueue = require("libs.hgss.src.presentation.RenderQueue")
local VertexFormat = require("libs.assets.src.model.VertexFormat")

local T = {}

local IDENTITY = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
local IDENTITY_NORMAL = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }

local VIEWPORT_WIDTH, VIEWPORT_HEIGHT = 64, 48
local LEFT_X, RIGHT_X = 16, 48
local MID_Y = 24

local function zeroFog()
  local table32 = {}
  for i = 1, 32 do
    table32[i] = 0
  end
  return { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = table32 }
end

local function edgeColors()
  return { [0] = 0, 0, 0, 0, 0, 0, 0, 0 }
end

-- One fullscreen world-space quad (x/y in [-10, 10] under the orthographic
-- camera below) at world depth `z`, spanning the given U range. Literal
-- vertex colors with colorSource 0 bypass DS lighting; the combiner under
-- test is fed by the material and polygon alpha alone.
local function quadMesh(scope, z, left, right, uvLeft, uvRight, rgb)
  left = left or -10
  right = right or 10
  uvLeft = uvLeft or 0
  uvRight = uvRight or 1
  rgb = rgb or 1
  local function v(x, y, u)
    return { x, y, z, u, 0.5, 0, 0, 1, rgb, rgb, rgb, 1, 0 }
  end
  return scope:own(love.graphics.newMesh(VertexFormat.LAYOUT, {
    v(left, -10, uvLeft),
    v(right, -10, uvRight),
    v(right, 10, uvRight),
    v(left, -10, uvLeft),
    v(right, 10, uvRight),
    v(left, 10, uvLeft),
  }, "triangles", "static"))
end

local function plainMaterial(image)
  return { image = image, texMatrix = IDENTITY }
end

local function translucentItem(mesh, polygonAlpha5, polygonId, material, alphaClass)
  return {
    mesh = mesh,
    material = material or plainMaterial(),
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    center = { 0, 0, 0 },
    alphaClass = alphaClass or "translucent",
    cullMode = "none",
    polygonAlpha = polygonAlpha5 / 31,
    polygonMode = "modulation",
    polygonId = polygonId,
    lightMask = 0,
    translucentDepthWrite = false,
    depthEqual = false,
    fogEnabled = false,
  }
end

-- A 2x1 nearest-filtered texture with the given left/right byte alphas over
-- opaque white RGB.
local function alphaTexture(scope, leftAlpha, rightAlpha)
  local data = love.image.newImageData(2, 1)
  data:setPixel(0, 0, 1, 1, 1, leftAlpha / 255)
  data:setPixel(1, 0, 1, 1, 1, rightAlpha / 255)
  local image = scope:own(love.graphics.newImage(data))
  image:setFilter("nearest", "nearest")
  return image
end

local function newRenderer(scope, mode)
  return scope:own(GxRenderer.new(mode and { translucencyMode = mode } or {}))
end

-- Draws one frame on a caller-owned renderer and samples the mid-row
-- left/right pixels of the resolved scene color.
local function drawAndSample(renderer, items)
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local projection = Matrix4.orthographic(-10, 10, -10, 10, 0.1, 100)
  local queue = RenderQueue.buildInto({ items }, view, projection, projection, RenderQueue.newScratch())
  renderer:draw({
    lighting = nil,
    edgeColors = edgeColors(),
    fog = zeroFog(),
    viewMatrix = view,
    cameraZoom = 1,
    worldProjection = projection,
    billboardProjection = projection,
    queue = queue,
    spriteItems = nil,
    viewport = FieldViewport.new(VIEWPORT_WIDTH, VIEWPORT_HEIGHT, { mode = "strict" }),
  })
  local image = renderer.sceneColor:newImageData()
  local left = { image:getPixel(LEFT_X, MID_Y) }
  local right = { image:getPixel(RIGHT_X, MID_Y) }
  image:release()
  return left, right
end

local function red(value)
  return value[1]
end

-- Translucent white over the black clear color must equal the DS source
-- weight (alpha5 + 1) / 32 across the quantized domain, including both ends.
-- The alpha15 case pins 0.5 within 0.01, which the old host coefficient
-- (15 / 31) misses by more than that distance: no separate test asserts the
-- absence of the old weight.
function T.approximate_blend_uses_ds_coefficients_across_the_alpha_domain(scope)
  local renderer = newRenderer(scope)
  local cases = {
    { alpha5 = 1, expected = 2 / 32, tolerance = 0.02 },
    { alpha5 = 15, expected = 16 / 32, tolerance = 0.01 },
    { alpha5 = 30, expected = 31 / 32, tolerance = 0.02 },
    { alpha5 = 31, expected = 1.0, tolerance = 0.02 },
  }
  for _, case in ipairs(cases) do
    local left = drawAndSample(renderer, {
      translucentItem(quadMesh(scope, 0), case.alpha5, 4),
    })
    Assert.near(red(left), case.expected, case.tolerance, "alpha5 " .. case.alpha5 .. " blends with (alpha5 + 1) / 32")
  end
end

-- The combiner paths share the corrected coefficient: DECAL keeps its
-- combiner (texture wins at texture alpha 31) while its RGB blends with the
-- corrected weight; a mixed MODULATE material at polygon alpha 31 splits
-- exactly (opaque texels replace through the opaque subpass, partial texels
-- blend through the translucent subpass); and zero-alpha texels discard in
-- both subpasses.
function T.approximate_combiner_paths_share_the_corrected_coefficient(scope)
  local renderer = newRenderer(scope)

  local decal = translucentItem(quadMesh(scope, 0), 15, 4)
  decal.polygonMode = "decal"
  local left, right = drawAndSample(renderer, { decal })
  Assert.near(red(left), 0.5, 0.02, "decal alpha5 15 blends with 16 / 32")

  local splitTexture = alphaTexture(scope, 255, 128)
  -- Right texel alpha5 is floor(128 / 255 * 31 + 0.5) = 16: outputAlpha5 16,
  -- DS weight 17 / 32 over black.
  left, right = drawAndSample(renderer, {
    translucentItem(quadMesh(scope, 0), 31, 4, plainMaterial(splitTexture), "mixed"),
  })
  Assert.near(red(left), 1.0, 0.02, "the opaque texel replaces")
  Assert.near(red(right), 17 / 32, 0.02, "the partial texel blends with (16 + 1) / 32")

  local discardTexture = alphaTexture(scope, 255, 0)
  left, right = drawAndSample(renderer, {
    translucentItem(quadMesh(scope, 0), 31, 4, plainMaterial(discardTexture), "mixed"),
  })
  Assert.near(red(left), 1.0, 0.02, "the opaque texel replaces")
  Assert.near(red(right), 0.0, 0.02, "the zero-alpha texel discards")
end

-- A repeated polygon ID at the same pixel blends once, including ID 63 at
-- the top of the valid domain (stencil 64).
function T.repeated_polygon_id_blends_once_at_both_domain_ends(scope)
  local renderer = newRenderer(scope)
  for _, polygonId in ipairs({ 0, 63 }) do
    local left = drawAndSample(renderer, {
      translucentItem(quadMesh(scope, 0), 15, polygonId),
      translucentItem(quadMesh(scope, -0.1), 15, polygonId),
    })
    Assert.near(red(left), 0.5, 0.02, "ID " .. polygonId .. " blends once, not twice")
  end
end

-- The record tracks the most recent ID, not a frame-wide seen set: a
-- different ID blends over the previous result and becomes the new last ID,
-- so a returning ID blends a third time.
function T.last_id_record_tracks_the_most_recent_blend(scope)
  local renderer = newRenderer(scope)
  local left = drawAndSample(renderer, {
    translucentItem(quadMesh(scope, 0), 15, 5),
    translucentItem(quadMesh(scope, -0.1), 15, 9),
  })
  Assert.near(red(left), 0.75, 0.02, "A, B blends twice")

  left = drawAndSample(renderer, {
    translucentItem(quadMesh(scope, 0), 15, 7),
    translucentItem(quadMesh(scope, -0.1), 15, 9),
    translucentItem(quadMesh(scope, -0.2), 15, 7),
  })
  Assert.near(red(left), 0.875, 0.03, "A, B, A blends three times")
end

-- Only accepted coverage stamps the last-ID record. Discarded fragments
-- never stamp (the mixed quad's zero-alpha right half leaves no record, so
-- the same-ID fullscreen quad still blends there); depth-rejected fragments
-- never stamp either (the back quad fails depth on the black opaque left
-- half, so the nearer same-ID quad still blends there while it is
-- suppressed on the right). The occluder is black so the front blend stays
-- observable: over white any blend would read white either way.
function T.rejected_fragments_do_not_stamp_the_last_id(scope)
  local renderer = newRenderer(scope)

  local discardTexture = alphaTexture(scope, 255, 0)
  local left, right = drawAndSample(renderer, {
    translucentItem(quadMesh(scope, 0), 31, 5, plainMaterial(discardTexture), "mixed"),
    translucentItem(quadMesh(scope, -0.1), 15, 5),
  })
  Assert.near(red(left), 1.0, 0.02, "the opaque texel plus one blend stays white")
  Assert.near(red(right), 0.5, 0.02, "the discarded texel left no ID record behind")

  local opaque = translucentItem(quadMesh(scope, 0, -10, 0, 0, 1, 0), 31, 2, plainMaterial(), "opaque")
  left, right = drawAndSample(renderer, {
    opaque,
    translucentItem(quadMesh(scope, -5), 15, 5),
    translucentItem(quadMesh(scope, 2), 30, 5),
  })
  Assert.near(red(left), 31 / 32, 0.02, "the nearer same-ID quad blends where depth rejected the back quad")
  Assert.near(red(right), 0.5, 0.02, "the back quad's accepted coverage suppresses the nearer same-ID quad")
end

-- Frame lifecycle on one renderer: the last-ID record resets at every frame
-- boundary (the second frame blends again instead of suppressing against the
-- first frame's record); stencil testing ends disabled after the translucent
-- pass (a later wireframe batch still rasterizes its edges over the stamped
-- ownership record); and exact mode keeps its compositor and semantic alpha
-- through the shared frame path (one translucent quad composites to the
-- DS-correct single blend through the unmodified exact shaders).
function T.translucent_frame_lifecycle_resets_restores_and_preserves_exact_mode(scope)
  local renderer = newRenderer(scope)

  local first, _ = drawAndSample(renderer, {
    translucentItem(quadMesh(scope, 0), 15, 5),
  })
  Assert.near(red(first), 0.5, 0.02, "the first frame blends once")
  local second, _ = drawAndSample(renderer, {
    translucentItem(quadMesh(scope, 0), 15, 5),
  })
  Assert.near(red(second), 0.5, 0.02, "the second frame blends again after the ownership reset")

  local wireframe = translucentItem(quadMesh(scope, 2, -5, 5), 0, 9, plainMaterial(), "wireframe")
  drawAndSample(renderer, {
    translucentItem(quadMesh(scope, 0), 15, 5),
    wireframe,
  })
  local image = renderer.sceneColor:newImageData()
  -- The wireframe box's left edge falls on pixel column 16 (the neighbor
  -- column is read too, so exact line placement cannot hide the edge).
  local edge = math.max(image:getPixel(15, MID_Y), image:getPixel(16, MID_Y))
  image:release()
  Assert.near(edge, 1.0, 0.05, "the wireframe edge draws over the translucent ownership record")

  local exactRenderer = newRenderer(scope, GxRenderer.TRANSLUCENCY_EXACT)
  local exact = drawAndSample(exactRenderer, {
    translucentItem(quadMesh(scope, 0), 15, 4),
  })
  Assert.near(red(exact), 0.5, 0.03, "exact mode still composites the DS-correct single blend")
end

return GraphicsSmoke.suite(T)
