-- The trade scene's Poke Ball model: the generated trade manifest carries one
-- compiled static descriptor (trade_sequence's NARC_a_0_8_9 member 27), and
-- this module realizes it through the shared model stack (GpuAssetPool,
-- ModelDefinition, ModelInstance, FieldRenderer) into its own source-sized
-- target, then composites that target at the trade scene's reference frame.
-- The placement and the scene camera arrive in the renderer's snapshot, so a
-- draw never advances a clock, loads an asset, or mutates shared state.
--
-- Camera facts are the source's own: TradeSequence_InitCamera builds the look-at
-- from the target at the origin, distance 300 and the scene's half-FOV index,
-- and the arrive/depart fly-through switches the same camera to the source's
-- orthographic type. Lighting follows the other modal generated-model scenes:
-- the trade scene configures no field light profile, so every material emits
-- its texture flat.
--
-- Retail sources (tmp/refs/pokeheartgold): src/application/trade_sequence/
-- trade_sequence.c (TradeSequence_InitCamera, TradeSequence_DrawModel,
-- TradeSequence_ApplyBgZoom's camera) and src/camera.c.

local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local FixedPoint = require("libs.math.src.FixedPoint")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")
local Matrix3 = require("libs.math.src.Matrix3")
local Matrix4 = require("libs.math.src.Matrix4")
local Rgb555 = require("libs.codec.src.Rgb555")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")

local REFERENCE_WIDTH = 256
local REFERENCE_HEIGHT = 192
-- Compiled meshes carry the engine's tile-space vertices (MapUnits.
-- MODEL_UNITS_PER_TILE = 16 model units per tile), while the app71 camera and
-- the scenes' model placements are in source model units: the model matrix
-- scales the tile-space mesh back into the scene's units, exactly like the
-- producer's unit conversion.
local MODEL_UNITS_PER_TILE = 16
local TAU = math.pi * 2
local ANGLE_UNIT = TAU / 65536

-- White emissive register: the trade scene carries no field light profile, so
-- every material emits its texture (or its base color) instead of resolving
-- lighting it was never given.
local EMISSIVE_WHITE = Rgb555.encode(31, 31, 31)

---@param index integer binary angle index
---@return number
local function sinIdx(index)
  return math.sin((index % 65536) * ANGLE_UNIT)
end

---@param index integer binary angle index
---@return number
local function cosIdx(index)
  return math.cos((index % 65536) * ANGLE_UNIT)
end

---@param balloon table<string, unknown>
---@return table<string, unknown>
local function sceneRuntime(balloon)
  local fogTable = {}
  for index = 1, 32 do
    fogTable[index] = 0
  end
  return {
    lighting = {
      records = {
        {
          endHalfSeconds = 0,
          lights = {},
          diffuseRgb555 = 0,
          ambientRgb555 = 0,
          specularRgb555 = 0,
          emissionRgb555 = EMISSIVE_WHITE,
        },
      },
    },
    -- TradeSequenceDepart/Recede/Arrive set their own edge color tables; the
    -- compiled batches carry the model's own edge flags, and the trade scenes'
    -- tables are all the same near-black, so the surface keeps the renderer's
    -- default table.
    edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
    fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = fogTable },
    balloon = balloon,
  }
end

-- The model matrix: translate, then the source's Rz * Ry * Rx rotation
-- (TradeSequence_DrawModel), then the source's uniform scale.
---@param balloon table<string, unknown>
---@return number[]
local function modelTransform(balloon)
  local cx, sx = cosIdx(balloon.rotX --[[@as integer]]), sinIdx(balloon.rotX --[[@as integer]])
  local cy, sy = cosIdx(balloon.rotY --[[@as integer]]), sinIdx(balloon.rotY --[[@as integer]])
  local cz, sz = cosIdx(balloon.rotZ --[[@as integer]]), sinIdx(balloon.rotZ --[[@as integer]])
  -- Rz * Ry * Rx in row-major order.
  local r11, r12, r13 = cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx
  local r21, r22, r23 = sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx
  local r31, r32, r33 = -sy, cy * sx, cy * cx
  local scale = balloon.scale --[[@as number]] * MODEL_UNITS_PER_TILE
  local linear = {
    r11 * scale,
    r21 * scale,
    r31 * scale,
    0,
    r12 * scale,
    r22 * scale,
    r32 * scale,
    0,
    r13 * scale,
    r23 * scale,
    r33 * scale,
    0,
    0,
    0,
    0,
    1,
  }
  return Matrix4.multiply(
    Matrix4.translate(balloon.x --[[@as number]], balloon.y --[[@as number]], balloon.z --[[@as number]]),
    linear
  )
end

-- The source's view and projection matrices for one scene camera.
---@param camera table<string, unknown>
---@return number[] view
---@return number[] projection
local function cameraMatrices(camera)
  local angleX = camera.angleX --[[@as integer]]
  local angleY = camera.angleY --[[@as integer]]
  local distance = camera.distance --[[@as number]]
  local cosX = cosIdx(angleX)
  local eye = {
    sinIdx(angleY) * distance * cosX,
    -sinIdx(angleX) * distance,
    cosIdx(angleY) * distance * cosX,
  }
  local view = Matrix4.lookAt(eye, { 0, 0, 0 }, { 0, 1, 0 })
  local halfFov = camera.fov --[[@as integer]] * ANGLE_UNIT
  local aspect = REFERENCE_WIDTH / REFERENCE_HEIGHT
  -- The source's own clipping plane is (0, 1000) (Camera_SetPerspective
  -- ClippingPlane(0, FX32_CONST(1000))). A zero near plane is degenerate for
  -- the shared renderer's clip-space depth mapping, so the port uses the
  -- source camera's default near plane (Camera_InitInternal's FX32_CONST(150));
  -- every trade placement sits far beyond it, so nothing the scene draws
  -- changes.
  local near = camera.near --[[@as number]]
  if near <= 0 then
    near = 150
  end
  local far = camera.far --[[@as number]]
  if camera.perspectiveType == 1 then
    local halfHeight = math.tan(halfFov) * distance
    local halfWidth = halfHeight * aspect
    return view, Matrix4.orthographic(-halfWidth, halfWidth, -halfHeight, halfHeight, near, far)
  end
  return view, Matrix4.perspective(halfFov * 2, aspect, near, far)
end

---@class TradeBalloonModel
---@field private _graphics table<string, unknown>
---@field private _images table<string, unknown>
---@field private _pool table<string, unknown>
---@field private _prepared table<string, unknown>
---@field private _renderer table<string, unknown>
---@field private _canvas table<string, unknown>
---@field private _view number[]
---@field private _projection number[]
---@field private _released boolean
local TradeBalloonModel = {}
TradeBalloonModel.__index = TradeBalloonModel

---@param opts { graphics: table<string, unknown>, cacheFs: table<string, unknown>, model: table<string, unknown> }
---@return TradeBalloonModel
function TradeBalloonModel.new(opts)
  assert(type(opts) == "table", "the trade balloon model requires its options")
  local graphics = assert(opts.graphics, "the trade balloon model draws through the graphics namespace")
  local cacheFs = assert(opts.cacheFs, "the trade balloon model reads its generated assets")
  assert(type(opts.model) == "table", "the trade balloon model requires its compiled descriptor")
  local self = setmetatable({
    _graphics = graphics,
    _view = Matrix4.identity(),
    _projection = Matrix4.identity(),
    _released = false,
  }, TradeBalloonModel)
  local poolWasOwned = false
  local ok, failure = pcall(function()
    -- The model's own textures realize through a private image owner: the
    -- trade overlay composes this model outside the field's session pool.
    local images = ImageAssetPool.new(cacheFs, { graphics = graphics })
    self._images = images
    local pool = GpuAssetPool.new(cacheFs, { graphics = graphics, imageAssets = images })
    self._pool = pool
    poolWasOwned = true
    local model = opts.model --[[@as table<string, unknown>]]
    self._prepared = pool:build(function()
      local materialById = {}
      for _, record in ipairs(assert(model.materials --[[@as table[] ]])) do
        local wrap = SceneDescriptor.wrap(record)
        local handle = pool:sharedImage(record.texture, wrap.x, wrap.y)
        materialById[record.id] = {
          id = record.id,
          name = record.name,
          image = handle and handle.image or nil,
          palette = handle and handle.palette or nil,
          indexed = handle and handle.indexed or nil,
          texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
          wrap = wrap,
        }
      end
      local batches = {}
      for _, batch in ipairs(assert(model.batches --[[@as table[] ]])) do
        local mesh = pool:meshFor(batch.geometry)
        batches[#batches + 1] = {
          mesh = mesh.mesh,
          material = assert(materialById[batch.material], "the trade balloon batch names its material"),
          center = mesh.center,
          sortBounds = mesh.bounds,
          alphaClass = batch.alphaClass,
          cullMode = batch.cullMode,
          polygonAlpha = (batch.polygonAlpha --[[@as number]]) / FixedPoint.RGB5_MAX,
          polygonMode = batch.polygonMode,
          polygonId = batch.polygonId,
          translucentDepthWrite = batch.translucentDepthWrite,
          depthEqual = batch.depthEqual,
          lightMask = batch.lightMask,
          fogEnabled = batch.fogEnabled,
        }
      end
      return { batches = batches }
    end)
    self._renderer = FieldRenderer.new({ clearColor = { 0, 0, 0, 0 }, graphics = graphics })
    self._canvas = graphics.newCanvas(REFERENCE_WIDTH, REFERENCE_HEIGHT, { format = "rgba8", dpiscale = 1 })
    self._canvas:setFilter("nearest", "nearest")
  end)
  if not ok then
    if self._canvas ~= nil then
      self._canvas:release()
      self._canvas = nil
    end
    if self._renderer ~= nil then
      self._renderer:release()
      self._renderer = nil
    end
    if poolWasOwned and self._pool ~= nil then
      self._pool:release()
      self._pool = nil
    end
    if self._images ~= nil then
      self._images:dispose()
      self._images = nil
    end
    error(failure, 0)
  end
  return self
end

-- Draws the model for one snapshot placement onto the caller's target, then
-- composites it at the reference frame with the source's polygon alpha.
---@param balloon table<string, unknown>
---@param camera table<string, unknown>
function TradeBalloonModel:draw(balloon, camera)
  assert(not self._released, "the trade balloon model is released")
  local graphics = self._graphics
  self._view, self._projection = cameraMatrices(camera)
  local transform = modelTransform(balloon)
  local modelNormal = Matrix3.modelNormal(transform)
  local items = {}
  for _, batch in ipairs(assert(self._prepared, "the trade balloon batches are realized").batches) do
    items[#items + 1] = {
      mesh = batch.mesh,
      material = batch.material,
      transform = transform,
      modelNormal = modelNormal,
      center = batch.center,
      sortBounds = batch.sortBounds,
      alphaClass = batch.alphaClass,
      cullMode = batch.cullMode,
      polygonAlpha = batch.polygonAlpha,
      polygonMode = batch.polygonMode,
      polygonId = batch.polygonId,
      translucentDepthWrite = batch.translucentDepthWrite,
      depthEqual = batch.depthEqual,
      lightMask = batch.lightMask,
      fogEnabled = batch.fogEnabled,
      worldSpace = true,
    }
  end
  local canvas = assert(self._canvas, "the trade balloon target is realized")
  local callerCanvas = graphics.getCanvas()
  graphics.push("all")
  graphics.setCanvas(canvas)
  graphics.setScissor()
  graphics.setShader()
  graphics.setDepthMode()
  graphics.setColor(1, 1, 1, 1)
  graphics.clear(0, 0, 0, 0)
  local view, projection = self._view, self._projection
  ---@return number[]
  local function cameraView()
    return view
  end
  ---@return number[]
  local function cameraProjection()
    return projection
  end
  assert(self._renderer, "the trade balloon renderer is realized"):draw(
    sceneRuntime(balloon),
    {
      far = camera.far,
      zoom = 1,
      view = cameraView,
      projection = cameraProjection,
      billboardProjection = cameraProjection,
    },
    { items },
    nil,
    {
      worldViewport = { x = 0, y = 0, width = REFERENCE_WIDTH, height = REFERENCE_HEIGHT },
      referenceFrame = { x = 0, y = 0, width = REFERENCE_WIDTH, height = REFERENCE_HEIGHT },
    },
    1
  )
  graphics.setCanvas(callerCanvas)
  graphics.setShader()
  graphics.setDepthMode()
  graphics.setBlendMode("alpha", "alphamultiply")
  graphics.setColor(1, 1, 1, (balloon.alpha --[[@as integer]]) / 31)
  graphics.draw(canvas, 0, 0)
  graphics.setColor(1, 1, 1, 1)
  graphics.pop()
end

-- Idempotent release of the model's own GPU resources; borrowed graphics and
-- cache stay with their owners.
function TradeBalloonModel:release()
  if self._released then
    return
  end
  self._released = true
  if self._canvas ~= nil then
    self._canvas:release()
    self._canvas = nil
  end
  if self._renderer ~= nil then
    self._renderer:release()
    self._renderer = nil
  end
  if self._pool ~= nil then
    self._pool:release()
    self._pool = nil
  end
  if self._images ~= nil then
    self._images:dispose()
    self._images = nil
  end
  self._prepared = nil
end

return TradeBalloonModel
