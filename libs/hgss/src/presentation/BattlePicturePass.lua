-- Projects the source Pokepic quad into an isolated color/depth layer.
-- The typed composition frame shares one exact 3D target between native
-- pictures and particle polygons through GxRenderer MANUAL/Z, then resolves
-- the battle 2D planes with host replace semantics under one world
-- transform. The legacy pictures-array path stays byte-identical.

local ImageSampling = require("libs.nds.src.love.ImageSampling")
local AlphaClassifier = require("libs.nds.src.gx.AlphaClassifier")
local GxRenderer = require("libs.nds.src.love.GxRenderer")
local RenderQueue = require("libs.hgss.src.presentation.RenderQueue")

local BattlePicturePass = {}
BattlePicturePass.__index = BattlePicturePass

local WIDTH, HEIGHT = 256, 192
local DEPTH_RANGE = 1024
-- Shared native 3D target dimensions: the battle world raster is always
-- the native 256x192 lattice; the layout scale/offset applies once at the
-- final host presentation, never as a per-picture re-anchor.
local COMPOSITION_VERTEX_FORMAT = {
  { "VertexPosition", "float", 4 },
  { "VertexTexCoord", "float", 2 },
  { "VertexNormal", "float", 3 },
  { "VertexColor", "float", 4 },
  { "VertexColorSource", "float", 1 },
}
local IDENTITY_VIEW = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
local IDENTITY_PROJECTION = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
local IDENTITY_MODEL = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
local IDENTITY_NORMAL = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
local IDENTITY_TEXMATRIX = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
local VERTEX_FORMAT = {
  { "VertexPosition", "float", 3 },
  { "VertexTexCoord", "float", 2 },
  { "VertexNormal", "float", 3 },
  { "VertexColor", "float", 4 },
  { "VertexColorSource", "float", 1 },
}
local SHADER = [[
#ifdef VERTEX
varying vec2 vTexCoord;

vec4 position(mat4 transform_projection, vec4 vertex_position)
{
  vTexCoord = VertexTexCoord.xy;
  return vec4(vertex_position.x / 128.0 - 1.0,
    vertex_position.y / 96.0 - 1.0, vertex_position.z, 1.0);
}
#endif

#ifdef PIXEL
varying vec2 vTexCoord;
/*__portemon_shared_image_sampling__*/
uniform vec3 paletteFadeColor;
uniform float paletteFadeAmount;
vec4 effect(vec4 color, Image image, vec2 texture_coords, vec2 screen_coords)
{
  vec4 pixel = resolveExactTexel(Texel(image, vTexCoord));
  if (pixel.a <= 0.0) discard;
  if (paletteFadeAmount > 0.0) {
    vec3 source5 = floor(pixel.rgb * 31.0 + 0.5);
    vec3 target5 = floor(paletteFadeColor * 31.0 + 0.5);
    vec3 blended5 = source5 + floor((target5 - source5) * paletteFadeAmount / 16.0);
    pixel.rgb = (blended5 * 8.0 + floor(blended5 / 4.0)) / 255.0;
  }
  pixel *= color;
  return pixel;
}
#endif
]]

local function angle(value)
  return (value or 0) * (2 * math.pi / 0x10000)
end

local function vertex(x, y, z, u, v)
  return { x, y, z, u, v, 0, 0, 1, 1, 1, 1, 1, 0 }
end

local function paletteFade(fade)
  if type(fade) ~= "table" or fade.applied ~= true then
    return { 0, 0, 0 }, 0
  end
  local color = fade.targetColor
  local intensity = fade.intensity
  assert(type(color) == "number" and color % 1 == 0, "palette fade carries RGB555 target color")
  assert(type(intensity) == "number" and intensity % 1 == 0, "palette fade carries integer intensity")
  return {
    (color % 32) / 31,
    (math.floor(color / 32) % 32) / 31,
    (math.floor(color / 1024) % 32) / 31,
  },
    intensity
end

local function rotate(x, y, z, item)
  local ax, ay, az = angle(item.rotationX), angle(item.rotationY), angle(item.rotationZ)
  az = az + (item.rotation or 0)
  local sx, cx = math.sin(ax), math.cos(ax)
  local sy, cy = math.sin(ay), math.cos(ay)
  local sz, cz = math.sin(az), math.cos(az)
  local y1, z1 = cx * y - sx * z, sx * y + cx * z
  local x2, z2 = cy * x + sy * z1, -sy * x + cy * z1
  return cz * x2 - sz * y1, sz * x2 + cz * y1, z2
end

local function vertices(item)
  local imageWidth, imageHeight = item.image:getDimensions()
  local width, height = item.width, item.height
  local xOffset, yOffset = item.xOffset or 0, item.yOffset or 0
  local xOffset2, yOffset2 = 0, 0
  local u0, v0, u1, v1 = 0, 0, 1, 1
  -- Battler portrait frames address a window of their shared atlas
  -- page: the frame origin offsets the UV window while the rectangle
  -- keeps its submitted geometry, so pooled pages draw through the
  -- same crop math as owned crops. Items without a frame keep their
  -- exact existing windows.
  local frameX, frameY = item.frameX or 0, item.frameY or 0
  local frameW, frameH = item.frameW, item.frameH
  local hasFrame = type(frameW) == "number" and type(frameH) == "number"
  -- Source cell bands crop their staged tile strip through an exact
  -- pixel origin instead of the battler portrait frame: the rectangle
  -- stays centered on the submitted native center while only the UV
  -- window moves, with authored flips mirroring the sampled texels.
  local hasStripCrop = item.kind == "effect" and (item.xOffset2 ~= nil or item.yOffset2 ~= nil)
  if item.kind == "shadow" then
    local region = assert(item.textureRegion, "shadow submissions select a staged native size region")
    u0, v0 = region.x / imageWidth, region.y / imageHeight
    u1, v1 = (region.x + region.width) / imageWidth, (region.y + region.height) / imageHeight
    if item.shadowAffine then
      width = width * (item.affineWidth or 0x100) / 0x100
      height = height * (item.affineHeight or 0x100) / 0x100
    end
  elseif hasStripCrop then
    xOffset2, yOffset2 = item.xOffset2 or 0, item.yOffset2 or 0
    assert(
      xOffset2 >= 0
        and yOffset2 >= 0
        and width > 0
        and height > 0
        and xOffset2 + width <= imageWidth
        and yOffset2 + height <= imageHeight,
      "effect sprite crop stays inside its staged strip"
    )
    u0, v0 = xOffset2 / imageWidth, yOffset2 / imageHeight
    u1, v1 = (xOffset2 + width) / imageWidth, (yOffset2 + height) / imageHeight
    if item.flipH == true then
      u0, u1 = u1, u0
    end
    if item.flipV == true then
      v0, v1 = v1, v0
    end
  elseif item.pictureVisible then
    xOffset2, yOffset2 = item.xOffset2 or 0, item.yOffset2 or 0
    assert(
      xOffset2 >= 0
        and yOffset2 >= 0
        and width > 0
        and height > 0
        and frameX + xOffset2 >= 0
        and frameY + yOffset2 >= 0
        and frameX + xOffset2 + width <= imageWidth
        and frameY + yOffset2 + height <= imageHeight,
      "Pokepic crop stays inside its staged selector frame"
    )
    u0, v0 = (frameX + xOffset2) / imageWidth, (frameY + yOffset2) / imageHeight
    u1, v1 = (frameX + xOffset2 + width) / imageWidth, (frameY + yOffset2 + height) / imageHeight
  elseif hasFrame then
    -- A submitted frame without a visible animation still addresses
    -- its page window: the shared page never draws whole behind a
    -- framed portrait.
    assert(
      frameX >= 0
        and frameY >= 0
        and frameW > 0
        and frameH > 0
        and frameX + frameW <= imageWidth
        and frameY + frameH <= imageHeight,
      "portrait frame stays inside its staged page"
    )
    u0, v0 = frameX / imageWidth, frameY / imageHeight
    u1, v1 = (frameX + frameW) / imageWidth, (frameY + frameH) / imageHeight
  end
  local left, right = -width / 2, width / 2
  local top, bottom = -height / 2, height / 2
  if item.kind == "shadow" then
    -- The submitted center already carries the shadow offsets.
    left, right = -width / 2, width / 2
    top, bottom = -height / 2, height / 2
  elseif hasStripCrop then
    -- Strip bands stay centered on the submitted native center: only
    -- the UV window moves, never the rectangle.
    left, right = left + xOffset, right + xOffset
    top, bottom = top + yOffset, bottom + yOffset
  elseif item.pictureVisible then
    left, right = -40 + xOffset + xOffset2, -40 + xOffset + xOffset2 + width
    top, bottom = -40 + yOffset + yOffset2, -40 + yOffset + yOffset2 + height
  else
    left, right = left + xOffset, right + xOffset
    top, bottom = top + yOffset, bottom + yOffset
  end
  top, bottom = top - (item.shadowHeight or 0), bottom - (item.shadowHeight or 0)
  local centerX, centerY = item.centerX, item.centerY
  local pivotX, pivotY = item.pivotX or 0, item.pivotY or 0
  local baseZ = item.kind == "shadow" and -1000 or item.zCenter + (item.zOffset or 0)
  local result = {}
  for _, point in ipairs({
    { left, top, u0, v0 },
    { right, top, u1, v0 },
    { right, bottom, u1, v1 },
    { left, bottom, u0, v1 },
  }) do
    local x, y, z = rotate(
      point[1] - pivotX,
      point[2] - pivotY,
      0,
      item.kind == "shadow" and { rotation = 0, rotationX = 0, rotationY = 0, rotationZ = 0 } or item
    )
    local screenX, screenY = centerX + pivotX + x, centerY + pivotY + y
    local depth = math.max(0, math.min(1, -((baseZ + z) / DEPTH_RANGE)))
    local clipZ = depth * 2 - 1
    result[#result + 1] = vertex(screenX, screenY, clipZ, point[3], point[4])
  end
  return result
end

-- Screen-space quad behind one collected picture submission: four
-- corner points as {x, y, z, u, v} in native pixels with normalized UVs.
-- The battle renderer adapts these onto typed clip-space primitives for
-- the shared 3D target; the legacy pictures-array path consumes them
-- directly. Pure in the submission record.
---@param item table<string, unknown> collected picture submission
---@return table<integer, table<integer, number>> four screen-space corner points
function BattlePicturePass.screenVertices(item)
  return vertices(item)
end

function BattlePicturePass.new(graphics)
  assert(type(graphics) == "table", "Pokepic rendering requires host graphics")
  local color = graphics.newCanvas(WIDTH, HEIGHT, { format = "rgba8", readable = true, dpiscale = 1 })
  local depth, mesh, shader
  local ok, failure = pcall(function()
    depth = graphics.newCanvas(WIDTH, HEIGHT, { format = "depth24stencil8", readable = false, dpiscale = 1 })
    mesh = graphics.newMesh(VERTEX_FORMAT, {
      vertex(-40, -40, 0, 0, 0),
      vertex(40, -40, 0, 1, 0),
      vertex(40, 40, 0, 1, 1),
      vertex(-40, 40, 0, 0, 1),
    }, "fan", "dynamic")
    -- Indexed staged pages resolve through the shared exact-sampling
    -- rule: the source stays the mesh texture while the palette rides
    -- per-item uniforms, exactly like the map renderer borrows.
    shader = graphics.newShader(ImageSampling.withSharedSampling(SHADER))
  end)
  if not ok then
    if shader then
      shader:release()
    end
    if mesh then
      mesh:release()
    end
    if depth then
      depth:release()
    end
    color:release()
    error(failure, 0)
  end
  color:setFilter("nearest", "nearest")
  return setmetatable(
    { graphics = graphics, color = color, depth = depth, mesh = mesh, shader = shader },
    BattlePicturePass
  )
end

-- Reads one private shader source through the same filesystem fallback
-- the shared renderer uses: love mount first, source directory second.
---@param path string repo-relative shader path
---@return string shader source
local function readCompositeSource(path)
  if love ~= nil and love.filesystem ~= nil then
    local source = love.filesystem.read(path)
    if source then
      return source
    end
    local base = love.filesystem.getSourceBaseDirectory()
    if base ~= nil then
      local file = io.open(base .. "/" .. path, "rb")
      if file then
        local contents = file:read("*a")
        file:close()
        return contents
      end
    end
  end
  error("cannot read battle composite shader source: " .. path)
end

local COMPOSITE_SHADER_PATH = "libs/hgss/src/presentation/shaders/battle_composite.glsl"

-- Merges one rasterized object into its accumulator: first opaque pixel
-- wins for color/metadata (u_mode 0), union-max for OBJ-window coverage
-- (u_mode 1). Mosaic block sampling applies at merge time so mosaic
-- objects sample their block origin exactly.
local MERGE_SHADER = [[
#ifdef PIXEL
uniform Image u_acc;
uniform Image u_src;
uniform vec2 u_size;
uniform vec2 u_offset;
uniform float u_block;
uniform float u_mode;
vec4 effect(vec4 color, Image image, vec2 texture_coords, vec2 screen_coords)
{
  vec2 uv = texture_coords;
  vec2 base = uv * u_size - u_offset;
  vec2 block = floor(base / u_block) * u_block;
  vec2 suv = (block + vec2(0.5)) / u_size;
  vec4 acc = Texel(u_acc, uv);
  vec4 src = Texel(u_src, suv);
  if (u_mode < 0.5) {
    return (acc.a > 0.0) ? acc : src;
  }
  return vec4(1.0, 1.0, 1.0, max(acc.a, src.a));
}
#endif
]]

-- Tags every opaque texel of a rasterized object with its constant
-- metadata (semitransparent flag, priority): transparent texels stay
-- absent so they never win selection.
local META_SHADER = [[
#ifdef PIXEL
uniform Image u_src;
uniform vec4 u_meta;
vec4 effect(vec4 color, Image image, vec2 texture_coords, vec2 screen_coords)
{
  vec4 src = Texel(u_src, texture_coords);
  if (src.a <= 0.0) discard;
  return vec4(u_meta.rgb, 1.0);
}
#endif
]]

-- Copies one rasterized plane through per-row offsets and mosaic block
-- sampling: destination texel (x, y) samples the block origin of
-- (x - ox, y - oy), so scrolled mosaic blocks stay exact and
-- out-of-range rows wrap through the swap repeat mode.
local ROW_SHADER = [[
#ifdef PIXEL
uniform Image u_src;
uniform vec2 u_size;
uniform vec2 u_offset;
uniform float u_block;
vec4 effect(vec4 color, Image image, vec2 texture_coords, vec2 screen_coords)
{
  vec2 base = texture_coords * u_size - u_offset;
  vec2 block = floor(base / u_block) * u_block;
  return Texel(u_src, (block + vec2(0.5)) / u_size);
}
#endif
]]

-- Releases the namespace-bound composition resources without touching
-- the pass-owned legacy mesh: a new graphics namespace rebuilds its
-- own Gx target, canvases, shaders and mesh pool on next use.
---@param self table<string, unknown> pass owning the resolve scratch
local function releaseCompositionResources(self)
  if self._compositionGx ~= nil then
    self._compositionGx:release()
    self._compositionGx = nil
  end
  if self._compositionStaging ~= nil then
    self._compositionStaging:release()
    self._compositionStaging = nil
  end
  if self._compositionMeshes ~= nil then
    for _, mesh in ipairs(self._compositionMeshes) do
      mesh:release()
    end
    self._compositionMeshes = nil
  end
  for _, field in ipairs({
    "_planeWorld",
    "_planeMenu",
    "_planeWindow",
    "_planeTransition",
    "_planeBattlefield",
    "_planeSwap",
    "_objColor",
    "_objMeta",
    "_objCoverage",
    "_objTemp",
    "_objTempMeta",
    "_objStage",
    "_compositionResolved",
  }) do
    if self[field] ~= nil then
      self[field]:release()
      self[field] = nil
    end
  end
  for _, field in ipairs({ "_compositeShader", "_mergeShader", "_metaShader", "_rowShader" }) do
    if self[field] ~= nil then
      self[field]:release()
      self[field] = nil
    end
  end
  self._compositionScratch = nil
  self._compositionGraphics = nil
end

-- Lazily owns the shared native 3D target plus the private six-plane 2D
-- resolve: one exact GxRenderer, one manual queue scratch, one native-size
-- world staging canvas, one canvas per 2D plane, OBJ color/metadata/
-- coverage scratch, the composite/merge/meta shaders and a reusable mesh
-- pool. Capacity reuses across frames; nothing allocates per particle.
-- The set binds the graphics namespace it was built with: production
-- draws through one namespace, while recording doubles arrive fresh
-- per draw, so a changed namespace releases its set and rebuilds.
---@param self table<string, unknown> pass owning the resolve scratch
---@param graphics table<string, unknown> host graphics namespace
local function ensureCompositionResources(self, graphics)
  if self._compositionGx ~= nil and self._compositionGraphics ~= graphics then
    releaseCompositionResources(self)
  end
  if self._compositionGx ~= nil then
    return
  end
  self._compositionGraphics = graphics
  local gx = GxRenderer.new({ graphics = graphics, translucencyMode = GxRenderer.TRANSLUCENCY_EXACT })
  local scratch = RenderQueue.newScratch({ sortMode = "manual" })
  local function canvas()
    -- Every composition canvas is sampled by the resolve shaders, so all
    -- stay readable; the final borrowed canvas is read by the test and
    -- production presentation paths alike.
    local target = graphics.newCanvas(WIDTH, HEIGHT, { format = "rgba8", readable = true, dpiscale = 1 })
    target:setFilter("nearest", "nearest")
    return target
  end
  local staging = canvas()
  local composite = graphics.newShader(assert(readCompositeSource(COMPOSITE_SHADER_PATH)))
  local merge = graphics.newShader(MERGE_SHADER)
  local meta = graphics.newShader(META_SHADER)
  local row = graphics.newShader(ROW_SHADER)
  local swap = canvas()
  swap:setWrap("repeat", "repeat")
  self._compositionGx = gx
  self._compositionScratch = scratch
  self._compositionStaging = staging
  self._compositionMeshes = {}
  self._planeWorld = canvas()
  self._planeMenu = canvas()
  self._planeWindow = canvas()
  self._planeTransition = canvas()
  self._planeBattlefield = canvas()
  self._planeSwap = swap
  self._objColor = canvas()
  self._objMeta = canvas()
  self._objCoverage = canvas()
  self._objTemp = canvas()
  self._objTempMeta = canvas()
  self._objStage = canvas()
  self._compositionResolved = canvas()
  self._compositeShader = composite
  self._mergeShader = merge
  self._metaShader = meta
  self._rowShader = row
end

---@param primitive table<string, unknown> native polygon primitive
---@return number topY
---@return number bottomY
local function compositionProjectedBounds(primitive)
  local topY, bottomY = nil, nil
  for _, corner in ipairs(primitive.vertices or {}) do
    local w = corner.clipW
    if type(w) ~= "number" or w == 0 then
      w = 1
    end
    if w > 0 then
      local ndcY = corner.clipY / w
      if ndcY == ndcY and ndcY ~= math.huge and ndcY ~= -math.huge then
        local screenY = 0.5 * (1 - ndcY)
        if topY == nil or bottomY == nil then
          topY, bottomY = screenY, screenY
        else
          topY = math.min(topY, screenY)
          bottomY = math.max(bottomY, screenY)
        end
      end
    end
  end
  if topY == nil or bottomY == nil then
    return 0, 0
  end
  return topY, bottomY
end

-- Resolves the Gx texture behind a composition primitive: raw host images
-- draw directly, pool leases unwrap to their staged image/palette pair,
-- and single-level wrappers unwrap once. Anything else fails loudly
-- instead of drawing a substitute.
---@param primitive table<string, unknown> native polygon primitive
---@return table<string, unknown> Gx material fields
local function compositionMaterial(primitive)
  local handle = primitive.image or primitive.material
  local image, palette, indexed = nil, nil, false
  if handle ~= nil then
    if type(handle.getDimensions) == "function" or type(handle.getWidth) == "function" then
      image = handle
    elseif type(handle.drawQuad) == "function" then
      image = assert(handle.image, "particle lease carries its staged image")
      palette = handle.palette
      indexed = handle.kind == "r8"
    elseif type(handle) == "table" and handle.image ~= nil then
      local inner = handle.image
      if type(inner.getDimensions) == "function" or type(inner.getWidth) == "function" then
        image = inner
        palette = handle.palette
        indexed = handle.kind == "r8" or handle.imageKind == "r8"
      else
        image = handle
      end
    else
      image = handle
    end
  end
  if primitive.palette ~= nil then
    palette = primitive.palette
  end
  if primitive.imageKind == "r8" then
    indexed = true
  end
  if indexed then
    assert(palette ~= nil, "indexed composition polygon carries its palette")
  end
  return {
    image = image,
    palette = palette,
    indexed = indexed,
    texMatrix = IDENTITY_TEXMATRIX,
    alphaUsage = primitive.alphaUsage,
    sampler = primitive.sampler,
  }
end

-- Adapts one native polygon primitive to a manual-queue Gx item: homogeneous
-- float4 vertices preserve clip W, identity matrices keep the prepared
-- coordinates, and the existing alpha classifier selects the pass.
---@param graphics table<string, unknown> host graphics namespace
---@param meshes table<integer, unknown> reusable mesh pool
---@param index integer 1-based primitive position in native submission order
---@param primitive table<string, unknown> native polygon primitive
---@return table<string, unknown> queue item
local function adaptCompositionPrimitive(graphics, meshes, index, primitive)
  local clipVertices = assert(primitive.vertices, "composition primitive carries its clip vertices")
  assert(#clipVertices >= 3, "composition primitive carries a polygon")
  local color5 = primitive.color5 or { r = 31, g = 31, b = 31 }
  local alpha5 = primitive.alpha5 or 31
  assert(alpha5 >= 0 and alpha5 <= 31, "composition polygon alpha is five-bit")
  local red, green, blue = (color5.r or 31) / 31, (color5.g or 31) / 31, (color5.b or 31) / 31
  local rows = {}
  for _, corner in ipairs(clipVertices) do
    rows[#rows + 1] = {
      corner.clipX,
      corner.clipY,
      corner.clipZ,
      corner.clipW,
      corner.u or 0,
      corner.v or 0,
      0,
      0,
      1,
      red,
      green,
      blue,
      1,
      0,
    }
  end
  local mesh = meshes[index]
  if mesh == nil then
    mesh = graphics.newMesh(COMPOSITION_VERTEX_FORMAT, rows, "fan", "dynamic")
    meshes[index] = mesh
  else
    mesh:setVertices(rows)
  end
  local material = compositionMaterial(primitive)
  mesh:setTexture(material.image)
  local topY, bottomY = compositionProjectedBounds(primitive)
  return {
    alphaClass = AlphaClassifier.classify(alpha5, "modulation", nil, material.alphaUsage),
    transform = IDENTITY_MODEL,
    modelNormal = IDENTITY_NORMAL,
    mesh = mesh,
    material = material,
    polygonAlpha = alpha5 / 31,
    polygonMode = "modulation",
    lightMask = 0,
    cullMode = (primitive.flags or {}).cullMode or "none",
    polygonId = primitive.polygonId or 5,
    fogEnabled = (primitive.flags or {}).fogEnabled == true,
    center = { 0, 0, 0 },
    sortBounds = nil,
    projectedBounds = { topY = topY, bottomY = bottomY },
  }
end

-- Typed composition frame contract (this entry owns the frame delegation
-- seam; producers arrive already in native coordinates, callbacks never
-- change targets, blend policy, source state or RNG):
--   frame.engine: "main" or "sub".
--   frame.animation: detached engine state with visible/priority/
--     firstTarget/secondTarget per role, backdrop {r,g,b}, windows
--     {win0,win1,objWindow,outside}, blend {mode,eva,evb,evy} and
--     brightness {mode,coefficient}. Roles are world3d (main) or menu
--     (sub), window, transition, battlefield, objects.
--   frame.primitives: ordered native polygon array for the shared 3D target.
--   frame.planes: 2D content per role (window/transition/battlefield, plus
--     sub-only menu): nil clears to transparent, {color={r,g,b}} fills
--     solid, {draw=function(graphics)} paints native 256x192 content.
--   frame.objects: ordered OBJ fragments {objPriority 0..3,
--     submissionOrder, oamMode ("normal", "translucent",
--     "semitransparent" or "object-window"), mosaicEnabled, draw}.
--     Window-mode fragments feed coverage only, never visible color.
--   frame.layout: {scale, offsetX, offsetY}; the native lattice fits
--     uniformly inside it, padding keeps the backdrop.
--   frame.scanlines: optional 192 {x,y} pixel rows applied to
--     frame.scanlineLayer (a 2D role, "battlefield" when absent).
--   frame.mosaic: optional {size=1..16 block, layers={role=true}}; each
--     enabled 2D role samples its block-origin texel. The 3D world plane
--     never takes mosaic.
-- A window record is {x,y,width,height,mask,effect}: mask names visible
-- roles (absent mask shows every plane), effect nil allows color effects
-- while false/"none" disables them for that window. objWindow carries
-- mask/effect only; coverage comes from window-mode fragments.
---@param engine string "main" or "sub"
---@return string world role for the engine
local function compositionWorldRole(engine)
  if engine == "sub" then
    return "menu"
  end
  assert(engine == "main", "composition engines are main or sub")
  return "world3d"
end

---@param value { [integer]: number|nil, r: number|nil, g: number|nil, b: number|nil }|nil color record
---@return number red
---@return number green
---@return number blue
local function compositionColor(value)
  assert(type(value) == "table", "plane colors carry their channels")
  local red = value[1] ~= nil and value[1] or value.r
  local green = value[2] ~= nil and value[2] or value.g
  local blue = value[3] ~= nil and value[3] or value.b
  assert(
    type(red) == "number" and type(green) == "number" and type(blue) == "number",
    "plane colors carry numeric channels"
  )
  return red, green, blue
end

---@param record { x: number|nil, y: number|nil, width: number|nil, height: number|nil }|nil window record
---@return number x
---@return number y
---@return number width
---@return number height
local function compositionWindowRect(record)
  if type(record) ~= "table" then
    return 0, 0, 0, 0
  end
  local x, y = record.x or 0, record.y or 0
  local width, height = record.width or 0, record.height or 0
  assert(
    type(x) == "number" and type(y) == "number" and type(width) == "number" and type(height) == "number",
    "window rectangles carry numeric bounds"
  )
  return x, y, width, height
end

-- Resolves one window mask to world/window/transition/battlefield presence:
-- absent records and absent role keys keep every plane visible.
---@param record { mask: table<string, boolean>|nil }|nil window record
---@param worldRole string engine world role name
---@return number world
---@return number window
---@return number transition
---@return number battlefield
local function compositionWindowMask(record, worldRole)
  local function bit(role)
    if type(record) ~= "table" or type(record.mask) ~= "table" or record.mask[role] == nil then
      return 1
    end
    return record.mask[role] and 1 or 0
  end
  return bit(worldRole), bit("window"), bit("transition"), bit("battlefield")
end

-- Resolves one window OBJ gate plus its color-effect allow: absent records
-- show OBJ and allow effects; only false/"none" disables.
---@param record { mask: { objects: boolean|nil }|nil, effect: boolean|string|nil }|nil window record
---@return number objGate
---@return number fxAllow
local function compositionWindowFlags(record)
  if type(record) ~= "table" then
    return 1, 1
  end
  local objGate = 1
  if type(record.mask) == "table" and record.mask.objects == false then
    objGate = 0
  end
  local fxAllow = 1
  if record.effect == false or record.effect == "none" then
    fxAllow = 0
  end
  return objGate, fxAllow
end

-- Copies and validates the OBJ fragments into native winning order:
-- lower priority number first, native submission order breaking ties.
---@param objects table<integer, table<string, unknown>>|nil ordered OBJ fragments
---@return table<integer, table<string, unknown>> ordered fragment copies
local function compositionSortedObjects(objects)
  local sorted = {}
  if objects == nil then
    return sorted
  end
  assert(type(objects) == "table", "composition OBJ fragments arrive ordered")
  for index, fragment in ipairs(objects) do
    assert(type(fragment) == "table", "OBJ fragments carry their records")
    local priority = fragment.objPriority
    assert(
      type(priority) == "number" and priority % 1 == 0 and priority >= 0 and priority <= 3,
      "OBJ fragments carry priority 0..3"
    )
    local order = fragment.submissionOrder
    if order == nil then
      order = index
    end
    assert(type(order) == "number", "OBJ fragments carry submission order")
    local mode = fragment.oamMode or "normal"
    assert(
      mode == "normal" or mode == "translucent" or mode == "semitransparent" or mode == "object-window",
      "OBJ fragments carry a known display mode"
    )
    assert(type(fragment.draw) == "function", "OBJ fragments draw their own coverage")
    sorted[#sorted + 1] = {
      priority = priority,
      order = order,
      mode = mode,
      mosaic = fragment.mosaicEnabled == true,
      draw = fragment.draw,
    }
  end
  table.sort(sorted, function(a, b)
    if a.priority ~= b.priority then
      return a.priority < b.priority
    end
    return a.order < b.order
  end)
  return sorted
end

-- Rasterizes one 2D plane entry into its native target: nil clears to
-- transparent, {color} fills solid, {draw} paints caller content.
---@param graphics table<string, unknown> host graphics namespace
---@param target unknown native plane canvas
---@param entry { color: { [integer]: number|nil, r: number|nil, g: number|nil, b: number|nil }|nil, draw: fun(graphics: table<string, unknown>)|nil, [integer]: fun(graphics: table<string, unknown>)|nil }|nil plane content entry
local function rasterizePlaneContent(graphics, target, entry)
  graphics.setCanvas(target)
  graphics.setShader()
  graphics.setBlendMode("replace", "premultiplied")
  graphics.setScissor()
  graphics.setColor(1, 1, 1, 1)
  graphics.clear(0, 0, 0, 0)
  if entry == nil then
    return
  end
  assert(type(entry) == "table", "plane entries are content records")
  if entry.color ~= nil then
    local red, green, blue = compositionColor(entry.color)
    graphics.setColor(red, green, blue, 1)
    graphics.rectangle("fill", 0, 0, WIDTH, HEIGHT)
    return
  end
  local draw = entry.draw
  if type(entry) == "table" and draw == nil and type(entry[1]) == "function" then
    draw = entry[1]
  end
  assert(type(draw) == "function", "plane entries without color draw their content")
  graphics.setColor(1, 1, 1, 1)
  draw(graphics)
end

-- Applies per-row scanline offsets and mosaic block sampling to one
-- rasterized plane through its swap canvas. Rows sample
-- floor((x - ox) / size) * size + ox so block origins stay exact under
-- scroll; out-of-range rows wrap through the swap repeat mode.
---@param graphics table<string, unknown> host graphics namespace
---@param self table<string, unknown> pass owning the resolve scratch
---@param target unknown destination plane canvas
---@param rows table<integer, table<string, number>>|nil 192 {x,y} pixel offsets, nil for mosaic-only
---@param block integer mosaic block size, 1 disables
local function processPlaneRows(graphics, self, target, rows, block)
  local swap = assert(self._planeSwap, "composition owns its plane swap canvas")
  local rowShader = assert(self._rowShader, "composition owns its row resolve shader")
  graphics.setCanvas(swap)
  graphics.setShader()
  graphics.setBlendMode("replace", "premultiplied")
  graphics.setScissor()
  graphics.setColor(1, 1, 1, 1)
  graphics.draw(target, 0, 0)
  graphics.setCanvas(target)
  graphics.clear(0, 0, 0, 0)
  graphics.setShader(rowShader)
  graphics.setBlendMode("replace", "premultiplied")
  graphics.setColor(1, 1, 1, 1)
  rowShader:send("u_src", swap)
  rowShader:send("u_size", { WIDTH, HEIGHT })
  rowShader:send("u_block", block)
  for row = 0, HEIGHT - 1 do
    local ox, oy = 0, 0
    if rows ~= nil then
      local entry = rows[row + 1]
      assert(type(entry) == "table", "scanline rows carry their offsets")
      ox = entry.x or 0
      oy = entry.y or 0
    end
    rowShader:send("u_offset", { ox, oy })
    graphics.setScissor(0, row, WIDTH, 1)
    graphics.draw(swap, 0, 0)
  end
  graphics.setScissor()
  graphics.setShader()
end

-- Rasterizes the ordered OBJ fragments into winning color/metadata plus
-- OBJ-window coverage: winning order keeps the first opaque fragment per
-- pixel, window-mode fragments feed coverage only, semitransparent
-- fragments tag the metadata red channel.
---@param graphics table<string, unknown> host graphics namespace
---@param self table<string, unknown> pass owning the resolve scratch
---@param sorted table<integer, table<string, unknown>> ordered fragment copies
---@param mosaicSize integer active mosaic block, 1 disables
local function rasterizeObjects(graphics, self, sorted, mosaicSize)
  local colorAcc = assert(self._objColor, "composition owns its OBJ color target")
  local metaAcc = assert(self._objMeta, "composition owns its OBJ metadata target")
  local coverage = assert(self._objCoverage, "composition owns its OBJ coverage target")
  local temp = assert(self._objTemp, "composition owns its OBJ raster target")
  local tempMeta = assert(self._objTempMeta, "composition owns its OBJ metadata raster")
  local stage = assert(self._objStage, "composition owns its OBJ merge stage")
  local merge = assert(self._mergeShader, "composition owns its OBJ merge shader")
  local metaShader = assert(self._metaShader, "composition owns its OBJ metadata shader")
  local dummy = assert(self._planeSwap, "composition owns its plane swap canvas")
  for _, target in ipairs({ colorAcc, metaAcc, coverage }) do
    graphics.setCanvas(target)
    graphics.setShader()
    graphics.setBlendMode("replace", "premultiplied")
    graphics.setScissor()
    graphics.clear(0, 0, 0, 0)
  end
  graphics.setColor(1, 1, 1, 1)
  for _, fragment in ipairs(sorted) do
    graphics.setCanvas(temp)
    graphics.setShader()
    graphics.setBlendMode("replace", "premultiplied")
    graphics.setScissor()
    graphics.setColor(1, 1, 1, 1)
    graphics.clear(0, 0, 0, 0)
    -- One fragment's quads composite over each other exactly like direct
    -- draws: overlapping art (party balls, multi-part sprites) stacks
    -- instead of letting a transparent overdraw erase what is below.
    graphics.setBlendMode("alpha", "alphamultiply")
    fragment.draw(graphics)
    local block = 1
    if fragment.mosaic and mosaicSize > 1 then
      block = mosaicSize
    end
    if fragment.mode == "object-window" then
      graphics.setCanvas(stage)
      graphics.setShader(merge)
      merge:send("u_acc", coverage)
      merge:send("u_src", temp)
      merge:send("u_size", { WIDTH, HEIGHT })
      merge:send("u_offset", { 0, 0 })
      merge:send("u_block", block)
      merge:send("u_mode", 1)
      graphics.setBlendMode("replace", "premultiplied")
      graphics.setColor(1, 1, 1, 1)
      graphics.setScissor()
      graphics.draw(dummy, 0, 0)
      graphics.setShader()
      graphics.setCanvas(coverage)
      graphics.setBlendMode("replace", "premultiplied")
      graphics.draw(stage, 0, 0)
    else
      local semi = (fragment.mode == "translucent" or fragment.mode == "semitransparent") and 1 or 0
      graphics.setCanvas(tempMeta)
      graphics.setShader(metaShader)
      graphics.setBlendMode("replace", "premultiplied")
      graphics.setColor(1, 1, 1, 1)
      graphics.setScissor()
      metaShader:send("u_src", temp)
      metaShader:send("u_meta", { semi, fragment.priority / 3, 0, 0 })
      graphics.draw(temp, 0, 0)
      graphics.setShader(merge)
      merge:send("u_size", { WIDTH, HEIGHT })
      merge:send("u_offset", { 0, 0 })
      merge:send("u_block", block)
      merge:send("u_mode", 0)
      graphics.setBlendMode("replace", "premultiplied")
      graphics.setColor(1, 1, 1, 1)
      graphics.setScissor()
      merge:send("u_acc", colorAcc)
      merge:send("u_src", temp)
      graphics.setCanvas(stage)
      graphics.draw(dummy, 0, 0)
      graphics.setShader()
      graphics.setCanvas(colorAcc)
      graphics.draw(stage, 0, 0)
      graphics.setShader(merge)
      merge:send("u_acc", metaAcc)
      merge:send("u_src", tempMeta)
      graphics.setCanvas(stage)
      graphics.draw(dummy, 0, 0)
      graphics.setShader()
      graphics.setCanvas(metaAcc)
      graphics.draw(stage, 0, 0)
    end
  end
  graphics.setShader()
end

-- Resolves the rasterized planes and OBJ targets through the private
-- six-plane shader into the pass-owned native resolve canvas.
---@param graphics table<string, unknown> host graphics namespace
---@param self table<string, unknown> pass owning the resolve scratch
---@param frame table<string, unknown> typed composition frame
---@param worldRole string engine world role name
local function driveComposite(graphics, self, frame, worldRole)
  local animation = frame.animation or {}
  local resolved = assert(self._compositionResolved, "composition owns its resolve canvas")
  local shader = assert(self._compositeShader, "composition owns its composite shader")
  local visible = animation.visible or {}
  local priority = animation.priority or {}
  local first = animation.firstTarget or {}
  local second = animation.secondTarget or {}
  local defaults = { world3d = 1, menu = 1, window = 0, transition = 2, battlefield = 3 }
  local function roleVisible(role)
    if visible[role] == nil then
      return 1
    end
    return visible[role] and 1 or 0
  end
  local function rolePriority(role)
    if priority[role] ~= nil then
      return priority[role]
    end
    return defaults[role] or 3
  end
  local function roleFlag(record, role)
    if record[role] == nil then
      return 0
    end
    return record[role] and 1 or 0
  end
  local blend = animation.blend or {}
  local blendMode = blend.mode or "none"
  local brightness = animation.brightness or {}
  local brightnessMode = brightness.mode or "none"
  local coefficient = brightness.coefficient or 0
  assert(type(coefficient) == "number", "brightness carries its coefficient")
  local backdrop = { 0, 0, 0 }
  if animation.backdrop ~= nil then
    local red, green, blue = compositionColor(animation.backdrop)
    backdrop = { red, green, blue }
  end
  local windows = animation.windows or {}
  local win0x, win0y, win0w, win0h = compositionWindowRect(windows.win0)
  local win1x, win1y, win1w, win1h = compositionWindowRect(windows.win1)
  local win0m1, win0m2, win0m3, win0m4 = compositionWindowMask(windows.win0, worldRole)
  local win1m1, win1m2, win1m3, win1m4 = compositionWindowMask(windows.win1, worldRole)
  local objWinm1, objWinm2, objWinm3, objWinm4 = compositionWindowMask(windows.objWindow, worldRole)
  local outm1, outm2, outm3, outm4 = compositionWindowMask(windows.outside, worldRole)
  local win0Obj, win0Fx = compositionWindowFlags(windows.win0)
  local win1Obj, win1Fx = compositionWindowFlags(windows.win1)
  local objWinObj, objWinFx = compositionWindowFlags(windows.objWindow)
  local outsideObj, outsideFx = compositionWindowFlags(windows.outside)
  local objVisible = 1
  if type(animation.visible) == "table" and animation.visible.objects == false then
    objVisible = 0
  end
  local objTargets = animation.objTargets or {}
  graphics.setCanvas(resolved)
  graphics.setShader(shader)
  graphics.setBlendMode("replace", "premultiplied")
  graphics.setScissor()
  graphics.setColor(1, 1, 1, 1)
  shader:send("u_planeWorld", worldRole == "menu" and self._planeMenu or self._planeWorld)
  shader:send("u_planeWindow", self._planeWindow)
  shader:send("u_planeTransition", self._planeTransition)
  shader:send("u_planeBattlefield", self._planeBattlefield)
  shader:send("u_objColor", self._objColor)
  shader:send("u_objMeta", self._objMeta)
  shader:send("u_objWindowCoverage", self._objCoverage)
  shader:send("u_size", { WIDTH, HEIGHT })
  shader:send("u_backdrop", { backdrop[1], backdrop[2], backdrop[3], 1 })
  shader:send("u_visibility", {
    roleVisible(worldRole),
    roleVisible("window"),
    roleVisible("transition"),
    roleVisible("battlefield"),
  })
  shader:send("u_objVisible", objVisible)
  shader:send("u_priorityA", {
    rolePriority(worldRole),
    rolePriority("window"),
    rolePriority("transition"),
    rolePriority("battlefield"),
  })
  shader:send("u_firstTargets", {
    roleFlag(first, worldRole),
    roleFlag(first, "window"),
    roleFlag(first, "transition"),
    roleFlag(first, "battlefield"),
  })
  shader:send("u_secondTargets", {
    roleFlag(second, worldRole),
    roleFlag(second, "window"),
    roleFlag(second, "transition"),
    roleFlag(second, "battlefield"),
  })
  shader:send("u_objTargets", { roleFlag(objTargets, "first"), roleFlag(objTargets, "second") })
  shader:send("u_worldIs3D", worldRole == "menu" and 0 or 1)
  shader:send("u_win0Rect", { win0x, win0y, win0w, win0h })
  shader:send("u_win1Rect", { win1x, win1y, win1w, win1h })
  shader:send("u_win0Mask", { win0m1, win0m2, win0m3, win0m4 })
  shader:send("u_win1Mask", { win1m1, win1m2, win1m3, win1m4 })
  shader:send("u_objWinMask", { objWinm1, objWinm2, objWinm3, objWinm4 })
  shader:send("u_outsideMask", { outm1, outm2, outm3, outm4 })
  shader:send("u_winObj", { win0Obj, win1Obj, objWinObj, outsideObj })
  shader:send("u_winFx", { win0Fx, win1Fx, objWinFx, outsideFx })
  shader:send("u_blendCoefficients", { blend.eva or 0, blend.evb or 0, blend.evy or 0, 0 })
  shader:send("u_blendMode", {
    blendMode == "alpha" and 1 or 0,
    blendMode == "brighten" and 1 or 0,
    blendMode == "darken" and 1 or 0,
    0,
  })
  local direction = 0
  if brightnessMode == "up" then
    direction = 1
  elseif brightnessMode == "down" then
    direction = -1
  end
  shader:send("u_brightness", { coefficient, direction })
  local worldCanvas = worldRole == "menu" and self._planeMenu or self._planeWorld
  graphics.draw(worldCanvas, 0, 0)
  graphics.setShader()
end
function BattlePicturePass:renderComposition(graphics, frame)
  ensureCompositionResources(self, graphics)
  assert(type(frame) == "table", "composition renders its typed frame")
  local saved = {
    canvas = { graphics.getCanvas() },
    shader = graphics.getShader(),
    blend = { graphics.getBlendMode() },
    depth = { graphics.getDepthMode() },
    color = { graphics.getColor() },
    scissor = { graphics.getScissor() },
    wireframe = graphics.isWireframe(),
    cullMode = graphics.getMeshCullMode(),
  }
  -- Native targets resolve in 256x192 canvas coordinates, never in the
  -- caller's pane placement: a translated caller (the lower pane draws
  -- 192 rows down, fitted hosts scale) would otherwise shift every
  -- plane, resolve and present out of bounds. The push pairs with the
  -- pop below on every path, including a failed frame.
  graphics.push("all")
  local ok, err = pcall(function()
    graphics.origin()
    local engine = frame.engine or "main"
    local worldRole = compositionWorldRole(engine)
    -- Shared 3D target: native primitives in submission order through the
    -- exact Gx MANUAL/Z path with no field postprocessing. The raw world
    -- layer stages into the pass-owned canvas before any 2D resolve.
    local primitives = frame.primitives or {}
    local items = {}
    for _, primitive in ipairs(primitives) do
      -- Alpha-zero SPL polygons append nothing; picture alpha zero keeps
      -- the source polygon convention and still submits.
      if primitive.alpha5 ~= 0 or primitive.kind == "picture" then
        items[#items + 1] = adaptCompositionPrimitive(graphics, self._compositionMeshes, #items + 1, primitive)
      end
    end
    local gx = assert(self._compositionGx, "composition owns its exact Gx target")
    local scratch = assert(self._compositionScratch, "composition owns its manual queue scratch")
    local staging = assert(self._compositionStaging, "composition owns its world staging canvas")
    local queue = RenderQueue.buildInto({ items }, IDENTITY_VIEW, IDENTITY_PROJECTION, IDENTITY_PROJECTION, scratch)
    graphics.setCanvas(staging)
    graphics.setShader()
    graphics.setBlendMode("replace", "premultiplied")
    graphics.setScissor()
    graphics.clear(0, 0, 0, 0)
    gx:draw({
      queue = queue,
      viewMatrix = IDENTITY_VIEW,
      worldProjection = IDENTITY_PROJECTION,
      billboardProjection = IDENTITY_PROJECTION,
      viewport = { worldViewport = { x = 0, y = 0, width = WIDTH, height = HEIGHT } },
      clearColor = { 0, 0, 0, 0 },
      postprocess = false,
      captureLayers = true,
    })
    -- 2D planes: the world lattice copies the staged 3D layer, every
    -- other role rasterizes its content entry, then the designated
    -- scanline/mosaic roles resolve per-row sampling through the swap.
    local planes = frame.planes or {}
    assert(planes.world3d == nil, "the 3D world plane arrives from the shared target")
    if worldRole == "main" then
      assert(planes.menu == nil, "the menu plane belongs to the sub engine")
    end
    local planeTargets = {
      world3d = self._planeWorld,
      menu = self._planeMenu,
      window = self._planeWindow,
      transition = self._planeTransition,
      battlefield = self._planeBattlefield,
    }
    local worldTarget = worldRole == "menu" and self._planeMenu or self._planeWorld
    graphics.setCanvas(worldTarget)
    graphics.setShader()
    graphics.setBlendMode("replace", "premultiplied")
    graphics.setScissor()
    graphics.setColor(1, 1, 1, 1)
    if worldRole == "menu" then
      graphics.clear(0, 0, 0, 0)
    else
      graphics.draw(staging, 0, 0)
    end
    local mosaic = frame.mosaic or {}
    local mosaicSize = mosaic.size or 1
    assert(
      type(mosaicSize) == "number" and mosaicSize % 1 == 0 and mosaicSize >= 1 and mosaicSize <= 16,
      "mosaic blocks are 1..16 native pixels"
    )
    -- The assert pins an integral block; flooring after it only informs
    -- the type checker, never the value.
    mosaicSize = math.floor(mosaicSize)
    local mosaicLayers = mosaic.layers or {}
    local scanlines = frame.scanlines
    if scanlines ~= nil then
      assert(type(scanlines) == "table" and #scanlines == HEIGHT, "scanline rows cover every native row")
    end
    local scanlineLayer = frame.scanlineLayer or "battlefield"
    local scanlinesActive = false
    if scanlines ~= nil then
      for row = 1, HEIGHT do
        local entry = scanlines[row]
        if type(entry) == "table" and ((entry.x or 0) ~= 0 or (entry.y or 0) ~= 0) then
          scanlinesActive = true
          break
        end
      end
    end
    for _, role in ipairs({ "menu", "window", "transition", "battlefield" }) do
      if not (worldRole ~= "menu" and role == "menu") then
        rasterizePlaneContent(graphics, planeTargets[role], planes[role])
        local wantsMosaic = mosaicSize > 1 and mosaicLayers[role] == true
        local wantsScan = scanlinesActive and scanlineLayer == role
        if wantsMosaic or wantsScan then
          processPlaneRows(
            graphics,
            self,
            planeTargets[role],
            wantsScan and scanlines or nil,
            wantsMosaic and mosaicSize or 1
          )
        end
      end
    end
    if worldRole == "menu" and (mosaicLayers.menu == true and mosaicSize > 1) then
      processPlaneRows(graphics, self, planeTargets.menu, nil, mosaicSize)
    end
    -- OBJ: winning fragments resolve per pixel before plane selection;
    -- window-mode fragments feed coverage only.
    local sorted = compositionSortedObjects(frame.objects)
    rasterizeObjects(graphics, self, sorted, mosaicSize)
    -- Six-plane resolve into the scratch canvas; only the final
    -- presentation below touches the borrowed canvas, so a failed frame
    -- keeps the last good pixels.
    driveComposite(graphics, self, frame, worldRole)
    -- Final host presentation: the native lattice maps onto the layout
    -- rectangle by the one uniform scale and offset, so every settled
    -- position lands on its fitted coordinate. Integer-snapping the
    -- blit bounds would re-scale the lattice and move settled content
    -- off those coordinates; padding keeps the backdrop.
    local layout = frame.layout or {}
    local scale = layout.scale or 1
    local offsetX = layout.offsetX or 0
    local offsetY = layout.offsetY or 0
    local animation = frame.animation or {}
    local backdrop = { 0, 0, 0 }
    if animation.backdrop ~= nil then
      local red, green, blue = compositionColor(animation.backdrop)
      backdrop = { red, green, blue }
    end
    local resolved = assert(self._compositionResolved, "composition owns its resolve canvas")
    graphics.setCanvas(self.color)
    graphics.setShader()
    graphics.setBlendMode("replace", "premultiplied")
    graphics.setScissor()
    graphics.setColor(backdrop[1], backdrop[2], backdrop[3], 1)
    graphics.rectangle("fill", 0, 0, WIDTH, HEIGHT)
    graphics.setColor(1, 1, 1, 1)
    graphics.draw(resolved, offsetX, offsetY, 0, scale, scale)
  end)
  graphics.pop()
  graphics.setCanvas(unpack(saved.canvas))
  graphics.setShader(saved.shader)
  graphics.setBlendMode(unpack(saved.blend))
  graphics.setDepthMode(unpack(saved.depth))
  graphics.setColor(unpack(saved.color))
  graphics.setScissor(unpack(saved.scissor))
  graphics.setWireframe(saved.wireframe)
  graphics.setMeshCullMode(saved.cullMode)
  if not ok then
    error(err, 0)
  end
  return self.color
end

function BattlePicturePass:render(graphics, items)
  if type(items) == "table" and items.primitives ~= nil then
    return self:renderComposition(graphics, items)
  end
  local saved = {
    canvas = { graphics.getCanvas() },
    shader = graphics.getShader(),
    blend = { graphics.getBlendMode() },
    depth = { graphics.getDepthMode() },
    color = { graphics.getColor() },
    scissor = { graphics.getScissor() },
    wireframe = graphics.isWireframe(),
    cullMode = graphics.getMeshCullMode(),
  }
  local ok, err = pcall(function()
    graphics.setCanvas({ self.color, depthstencil = self.depth })
    graphics.setScissor()
    graphics.clear(0, 0, 0, 0, false, true)
    graphics.setWireframe(false)
    graphics.setMeshCullMode("none")
    graphics.setShader(self.shader)
    graphics.setBlendMode("alpha", "alphamultiply")
    for _, item in ipairs(items) do
      self.mesh:setVertices(vertices(item))
      self.mesh:setTexture(item.image)
      graphics.setColor(item.tintR, item.tintG, item.tintB, item.alpha)
      local fadeColor, fadeAmount = paletteFade(item.paletteFade)
      ImageSampling.sendMaterialSampling(self.shader, {
        image = item.image,
        palette = item.palette,
        indexed = item.imageKind == "r8",
      })
      self.shader:send("paletteFadeColor", fadeColor)
      self.shader:send("paletteFadeAmount", fadeAmount)
      graphics.setDepthMode("less", item.alpha >= 1)
      graphics.draw(self.mesh)
    end
  end)
  graphics.setCanvas(unpack(saved.canvas))
  graphics.setShader(saved.shader)
  graphics.setBlendMode(unpack(saved.blend))
  graphics.setDepthMode(unpack(saved.depth))
  graphics.setColor(unpack(saved.color))
  graphics.setScissor(unpack(saved.scissor))
  graphics.setWireframe(saved.wireframe)
  graphics.setMeshCullMode(saved.cullMode)
  if not ok then
    error(err, 0)
  end
  return self.color
end

function BattlePicturePass:release()
  if self._released then
    return
  end
  self._released = true
  self.mesh:release()
  self.shader:release()
  self.depth:release()
  self.color:release()
  releaseCompositionResources(self)
end

return BattlePicturePass
