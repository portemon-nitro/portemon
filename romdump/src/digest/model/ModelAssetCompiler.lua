-- The one model-compilation core producing content-addressed model banks and
-- texture banks for one decoded model bound to one texture pack. MapAssetCompiler
-- (map and placed-building models) and NeighborChunkCompiler (terrain models)
-- both call compileModel; each caller owns its bundle accumulators and
-- continues from the returned batches/materials/unresolved records. One source
-- model persists one native model bank of ordered draw command spans, and each
-- draw is selected from it by its zero-based draw index; the batch record's
-- polygon draw state rides the shared PolygonState schema and the
-- transform-mode vocabulary comes from PoseContract, so the serialized model
-- descriptor has exactly one authority.

local DsPolygonAttr = require("libs.nds.src.gx.DsPolygonAttr")
local Errors = require("libs.errors.src.Errors")
local GxDisplayList = require("libs.nds.src.gx.GxDisplayList")
local Hashing = require("romdump.src.digest.Hashing")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapUnits = require("romdump.src.digest.map.MapUnits")
local MaterialCompiler = require("romdump.src.digest.model.MaterialCompiler")
local MeshCompiler = require("romdump.src.digest.model.MeshCompiler")
local NativeGxFormat = require("libs.assets.src.model.NativeGxFormat")
local NsbmdStaticTransforms = require("romdump.src.digest.model.NsbmdStaticTransforms")
local PoseContract = require("libs.assets.src.model.PoseContract")
local PolygonState = require("libs.assets.src.model.PolygonState")
local AlphaClassifier = require("libs.nds.src.gx.AlphaClassifier")
local TextureMatrixState = require("romdump.src.digest.model.TextureMatrixState")

local ModelAssetCompiler = {}

-- One model unit in runtime tiles: the draw commands stay in source model
-- units, so the bank tells the runtime how to convert the positions it decodes.
local POSITION_SCALE = 1 / MapUnits.MODEL_UNITS_PER_TILE

-- A compiled draw takes part in terrain boundary conformance only when its
-- role is terrain and it is drawn as a filled surface: culled draws render
-- nothing and polygon-alpha-zero draws render as host wireframe, so neither can
-- own the filled-surface sampling disagreement repair addresses, and non-terrain
-- roles never repair at all.
local function isTerrainEligible(poly, isTerrain)
  return isTerrain and poly.cullMode ~= "all" and poly.polygonAlpha ~= 0
end

-- Convert MaterialCompiler records (texture = native bank selector) into
-- scene material records. Polygon state (alpha class, cull mode, polygon
-- alpha/mode) lives on the batch, not the material.
-- `terrainStateById` supplies the shared decoded-material texture-matrix
-- fields (texWidth/texHeight/texMtxMode and the normalized static srt) for
-- terrain scene materials; building models compile without it.
local function sceneMaterials(records, terrainStateById)
  local out = {}
  for _, m in ipairs(records) do
    local record = {
      id = m.id,
      name = m.name,
      texture = m.texture,
      textureFormat = m.textureFormat,
      alphaUsage = m.alphaUsage,
      wrap = m.wrap,
      flip = m.flip,
      diffuse = m.diffuse,
    }
    local terrain = terrainStateById and terrainStateById[m.id]
    if terrain then
      record.texWidth = terrain.texWidth
      record.texHeight = terrain.texHeight
      record.texMtxMode = terrain.texMtxMode
      record.srt = terrain.srt
    end
    out[#out + 1] = record
  end
  return out
end

-- Replay one model's draw submissions into native bank draw records plus the
-- per-draw scene batches that select them. The producer resolves only what the
-- runtime cannot derive from source-independent bytes: the tile-space draw and
-- restore matrices, the geometry-engine color state each draw starts under, and
-- the UV normalization divisor. Geometry stays as source command bytes.
---@class ModelAssetCompiler.BankDraw
---@field commands string source display-list command bytes
---@field nodeIndex integer
---@field materialIndex integer
---@field shapeIndex integer
---@field transformMode "static"|"billboard"
---@field terrainBoundaryEligible boolean
---@field texWidth integer? UV divisor; absent when the material binds no texture
---@field texHeight integer?
---@field matrix number[]? tile-space draw matrix the producer resolved
---@field restoreStack { [integer]: number[] }?
---@field positionScale number
---@field seedColorSource integer?
---@field seedColor number[]?

-- One selectable draw of the compiled bank: the bank record itself, the decoded
-- polygon state that classifies it, and its zero-based index in the bank.
---@class ModelAssetCompiler.Selectable
---@field draw ModelAssetCompiler.BankDraw
---@field poly { polygonMode: string, cullMode: string, polygonAlpha: integer, farClipEnabled: boolean, oneDotEnabled: boolean }
---@field index integer
---@field baseTransform number[]?

---@param model table<string, unknown>
---@param textureSizes table<integer, { width: number, height: number }>
---@param isTerrain boolean whether the role repairs terrain boundaries at all
---@return ModelAssetCompiler.BankDraw[] bankDraws
---@return ModelAssetCompiler.Selectable[] selectable
local function compileDraws(model, textureSizes, isTerrain)
  local shapeByIndex = {}
  for _, shp in
    ipairs(model.shapes --[[@as table[] ]])
  do
    shapeByIndex[shp.index] = shp
  end
  local materialByIndex = {}
  for _, mat in
    ipairs(model.materials --[[@as table[] ]])
  do
    materialByIndex[mat.index] = mat
  end

  local draws = NsbmdStaticTransforms.evaluate(model)
  local bankDraws, selectable = {}, {}
  local carriedState
  for _, draw in ipairs(draws) do
    local shape = shapeByIndex[draw.shapeIndex]
    if not shape then
      Errors.raise(
        "MAP_COMPILE_MISSING_SHAPE",
        "SBC draw references shape index " .. tostring(draw.shapeIndex) .. " not in the model",
        { shapeIndex = draw.shapeIndex, materialIndex = draw.materialIndex }
      )
    end
    local rawMaterial = materialByIndex[draw.materialIndex]
    assert(rawMaterial, "SBC draw references material " .. tostring(draw.materialIndex) .. " not in the model")
    local matState = MeshCompiler.materialState(rawMaterial)
    local poly = DsPolygonAttr.decode(matState.polygonAttrRaw)
    local drawContext = { model = model.name, shape = shape.name, material = draw.materialIndex }
    -- The geometry engine keeps color/normal state across shape calls; a
    -- reapplied material reseeds it. Resolve the seed first and scan the shape
    -- as inheriting it, so a shape that issues no COLOR/NORMAL leaves the
    -- carried state intact instead of reporting a default.
    local seed = carriedState or matState.seed
    if draw.materialReapplied then
      seed = matState.seed
    end
    local scan = GxDisplayList.scanState(shape.displayListBytes, drawContext, seed)
    MeshCompiler.assertSupportedShape(scan, drawContext)
    if draw.transformMode == PoseContract.BILLBOARD then
      MeshCompiler.assertWholeShapeBillboard(scan, drawContext)
    end
    if poly.polygonMode ~= "modulation" and poly.polygonMode ~= "decal" then
      Errors.raise("MAP_COMPILE_UNSUPPORTED_POLYGON_MODE", "polygon mode " .. poly.polygonMode .. " is not supported", {
        model = model.name,
        material = draw.materialIndex,
        shape = shape.name,
        polygonMode = poly.polygonMode,
        polygonAttrRaw = matState.polygonAttrRaw,
      })
    end

    -- Recording the resolved seed per draw lets the runtime replay the very
    -- same state without the source model.
    carriedState = scan.finalState

    if poly.cullMode ~= "all" then
      local textureSize = textureSizes[draw.materialIndex]
      local bankDraw = {
        commands = shape.displayListBytes,
        nodeIndex = draw.nodeIndex,
        materialIndex = draw.materialIndex,
        shapeIndex = draw.shapeIndex,
        transformMode = draw.transformMode,
        terrainBoundaryEligible = isTerrainEligible(poly, isTerrain),
        texWidth = textureSize and textureSize.width or nil,
        texHeight = textureSize and textureSize.height or nil,
        matrix = draw.matrix,
        restoreStack = draw.restoreStack and next(draw.restoreStack) and draw.restoreStack or nil,
        positionScale = POSITION_SCALE,
        seedColorSource = seed and seed.colorSource or nil,
        seedColor = seed and seed.color or nil,
        seedNormal = seed and seed.normal or nil,
      }
      bankDraws[#bankDraws + 1] = bankDraw
      selectable[#selectable + 1] = {
        draw = bankDraw,
        poly = poly,
        index = #bankDraws - 1,
        baseTransform = draw.baseTransform and MapUnits.matrixToTiles(draw.baseTransform) or nil,
      }
    end
  end
  return bankDraws, selectable
end

-- Compile one model into batches; append bank bytes to the shared bundle
-- accumulators; return { batches (scene refs), materials, unresolved } -- the
-- last being the materials whose names the bound pack does not define, tagged
-- with the model they came from so a caller can report them. When the caller
-- passes a map-scoped terrain-animation compiler in
-- `context.terrainAnimationCompiler` and the role is a terrain role (map or
-- neighbor), every material whose texture name an fldtanime record names gets
-- a textureSwap record and its alternate frames join the shared texture
-- accumulator; other roles never gain terrain annotation.
---@param model table<string, unknown>
---@param texturePack table<string, unknown>
---@param meshes table<string, unknown>
---@param textures table<string, string> texture-bank accumulator: bank key to encoded bytes
---@param context table<string, unknown>
---@return { batches: table[], materials: table[], unresolved: table[] }
local function compileModel(model, texturePack, meshes, textures, context)
  local mat = MaterialCompiler.compile(model.materials, texturePack, { context = context })
  for key, bank in pairs(mat.textures) do
    textures[key] = bank
  end

  local unresolved = {}
  for _, entry in ipairs(mat.unresolved) do
    unresolved[#unresolved + 1] = {
      role = context.role,
      modelArchive = context.modelArchive,
      modelMemberId = context.modelMemberId,
      modelName = context.modelName,
      material = entry.material,
      kind = entry.kind,
      name = entry.name,
      source = entry.source,
    }
  end

  -- Per-material texture info needed for draw classification and UV normalization.
  local matInfoById = {}
  local textureSizes = {}
  for _, m in ipairs(mat.materials) do
    matInfoById[m.id] = {
      texWidth = m.texWidth,
      texHeight = m.texHeight,
      textureFormat = m.textureFormat or 0,
      alphaUsage = m.alphaUsage,
    }
    if m.texWidth then
      textureSizes[m.id] = { width = m.texWidth, height = m.texHeight }
    end
  end

  -- Terrain scene materials (map and neighbor roles) carry the decoded
  -- texture-matrix fields, the same conversion the dynamic model base
  -- materials use; placed-building models never gain them.
  local isTerrain = context.role == "map" or context.role == "neighbor"

  local terrainStateById
  if isTerrain then
    terrainStateById = {}
    for _, material in
      ipairs(model.materials --[[@as table[] ]])
    do
      terrainStateById[material.index] = TextureMatrixState.fromMaterial(material, model.info.texMtxMode)
    end
  end

  local materials = sceneMaterials(mat.materials, terrainStateById)
  if isTerrain and context.terrainAnimationCompiler then
    for i, m in ipairs(mat.materials) do
      -- A matched record yields a textureSwap record; an unmatched material
      -- or one that failed texture binding leaves the field omitted.
      local swap = context.terrainAnimationCompiler:annotateMaterial(model.materials[i], m, texturePack, textures)
      if swap then
        materials[i].textureSwap = swap
      end
    end
  end

  local bankDraws, selectable = compileDraws(model, textureSizes, isTerrain)
  local bankBytes = NativeGxFormat.encode({ draws = bankDraws })
  local bankKey = Hashing.sha1hex(bankBytes)
  meshes[bankKey] = bankBytes
  local bankFile = MapAssetCache.modelBankPath(bankKey)

  local batches = {}
  for _, entry in ipairs(selectable) do
    local poly = entry.poly
    local info = matInfoById[entry.draw.materialIndex]
    local fmt = info and info.textureFormat or 0
    local alphaClass =
      AlphaClassifier.classify(poly.polygonAlpha, poly.polygonMode, fmt, info and info.alphaUsage or nil)
    local record = {
      geometry = { file = bankFile, drawIndex = entry.index },
      material = entry.draw.materialIndex,
      node = entry.draw.nodeIndex,
      -- A billboard batch's geometry is in billboard-local space and its
      -- matrix is only resolvable against a live camera; the runtime rebuilds
      -- it from baseTransform every frame. The static mode is the default and
      -- is left off, so it does not repeat on every batch of every scene.
      transformMode = entry.draw.transformMode ~= PoseContract.STATIC and entry.draw.transformMode or nil,
      baseTransform = entry.baseTransform,
      alphaClass = alphaClass,
    }
    -- The shared polygon draw-state field set (PolygonState.FIELDS).
    for _, field in ipairs(PolygonState.FIELDS) do
      record[field] = poly[field]
    end
    -- The static-only extras stay outside the shared draw-state schema:
    -- they are authoring metadata the runtime does not consume.
    record.farClipEnabled = poly.farClipEnabled
    record.oneDotEnabled = poly.oneDotEnabled
    batches[#batches + 1] = record
  end
  return { batches = batches, materials = materials, unresolved = unresolved }
end

ModelAssetCompiler.compileModel = compileModel

return ModelAssetCompiler
