-- Compiles animated model descriptors and their content-addressed model bank.

local MaterialCompiler = require("romdump.src.digest.model.MaterialCompiler")
local DsPolygonAttr = require("libs.nds.src.gx.DsPolygonAttr")
local Hashing = require("romdump.src.digest.Hashing")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapUnits = require("romdump.src.digest.map.MapUnits")
local NativeGxFormat = require("libs.assets.src.model.NativeGxFormat")
local PoseContract = require("libs.assets.src.model.PoseContract")
local NsbmdStaticTransforms = require("romdump.src.digest.model.NsbmdStaticTransforms")
local AnimationClip = require("libs.assets.src.model.AnimationClip")
local NsbmdDynamicModel = require("romdump.src.digest.model.NsbmdDynamicModel")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local PolygonState = require("libs.assets.src.model.PolygonState")

local DynamicModelCompiler = {}

local function patternVariants(clips, materials)
  local modelMaterials, byMaterial = {}, {}
  for _, material in ipairs(materials) do
    modelMaterials[material.name] = true
  end
  for _, clip in ipairs(clips) do
    if clip.kind == AnimationClip.KINDS.PATTERN then
      local names = clip.compiled.textureNames
      local pltts = clip.compiled.paletteNames
      for _, target in ipairs(clip.compiled.targets) do
        -- NNSi_G3dAnmObjInitNsBtp binds PAT0 target dictionary entries to
        -- model material IDs by exact name and leaves absent names unmapped.
        if modelMaterials[target.name] then
          local set = byMaterial[target.name] or {}
          for _, key in ipairs(target.keys) do
            local texName = names[key.texIdx + 1]
            local plttName
            if key.plttIdx ~= 0xFF then
              plttName = pltts[key.plttIdx + 1]
            end
            local variantName = plttName and (texName .. "+" .. plttName) or texName
            if not set[variantName] then
              set[variantName] = { texName = texName, plttName = plttName }
            end
          end
          byMaterial[target.name] = set
        end
      end
    end
  end
  return byMaterial
end

local function resolvePatternVariants(embeddedTex, variantSets, textures, unresolved, context)
  local byMaterial = {}
  for materialName, set in pairs(variantSets) do
    local variants = {}
    for variantName, pair in pairs(set) do
      local fakeMat = { name = variantName, textureName = pair.texName, paletteName = pair.plttName }
      local resolved =
        MaterialCompiler.resolveTexture(fakeMat, embeddedTex, textures, unresolved, { context = context })
      local variant = { name = variantName }
      if resolved.texture then
        variant.texture = resolved.texture
        variant.width = resolved.texWidth
        variant.height = resolved.texHeight
        variant.textureFormat = resolved.textureFormat
        variant.alphaUsage = resolved.alphaUsage
      end
      variants[variantName] = variant
    end
    byMaterial[materialName] = variants
  end
  return byMaterial
end

local function dynamicMaterials(dynamicModel, matCompiled, variantsByName)
  local out = {}
  for _, base in ipairs(dynamicModel.materials) do
    local merged = {}
    for k, v in pairs(base) do
      merged[k] = v
    end
    local m = matCompiled.materials[base.id + 1]
    if m then
      if m.texture then
        merged.texture = m.texture
        merged.textureFormat = m.textureFormat
        merged.alphaUsage = m.alphaUsage
      end
      merged.wrap = m.wrap
      merged.flip = m.flip
      merged.diffuse = m.diffuse
    end
    local variants = variantsByName[base.name]
    if variants then
      local list = {}
      for _, variant in pairs(variants) do
        list[#list + 1] = variant
      end
      table.sort(list, function(a, b)
        return a.name < b.name
      end)
      merged.variants = list
    end
    out[#out + 1] = merged
  end
  return out
end

-- One native bank draw per visible pose segment: the source display-list
-- command bytes plus the segment position the transform-preserving replay keeps,
-- so the runtime re-derives the same pose segments instead of loading expanded
-- triangles. Command bytes are shared by the segments of one draw.
---@param dynamicModel table<string, unknown>
---@param model table<string, unknown>
---@param meshes table<string, unknown>
---@return table[] batches
local function dynamicBatches(dynamicModel, model, meshes)
  local draws = NsbmdStaticTransforms.evaluate(model)
  -- The UV divisor the runtime replay divides the draw's texel-unit UVs by:
  -- the material's authored texture extent, the same base the compile above
  -- normalized against (a material with no bound texture authors none).
  local textureSizes = dynamicModel.textureSizes
  local shapeByIndex = {}
  for _, shape in ipairs(model.shapes) do
    shapeByIndex[shape.index] = shape
  end
  local out, bankDraws = {}, {}
  for _, mesh in
    ipairs(dynamicModel.meshes --[[@as table[] ]])
  do
    local poly = DsPolygonAttr.decode(mesh.polygonAttrRaw)
    if poly.polygonMode ~= "modulation" and poly.polygonMode ~= "decal" then
      require("libs.errors.src.Errors").raise(
        "MAP_COMPILE_UNSUPPORTED_POLYGON_MODE",
        "polygon mode " .. poly.polygonMode .. " is not supported",
        { polygonMode = poly.polygonMode, meshId = mesh.id }
      )
    end
    if poly.cullMode ~= "all" then
      local source = assert(draws[mesh.drawIndex + 1], "dynamic mesh references a draw that is not in the model")
      local shape = assert(shapeByIndex[source.shapeIndex], "dynamic draw references a missing shape")
      local textureSize = textureSizes[mesh.materialIndex]
      bankDraws[#bankDraws + 1] = {
        commands = shape.displayListBytes,
        nodeIndex = mesh.nodeIndex,
        materialIndex = mesh.materialIndex,
        shapeIndex = source.shapeIndex,
        transformMode = mesh.transformMode,
        segmentIndex = mesh.segmentIndex,
        texWidth = textureSize and textureSize.width or nil,
        texHeight = textureSize and textureSize.height or nil,
        positionScale = 1 / MapUnits.MODEL_UNITS_PER_TILE,
      }
      local record = {
        id = mesh.id,
        drawIndex = mesh.drawIndex,
        segmentIndex = mesh.segmentIndex,
        nodeIndex = mesh.nodeIndex,
        materialIndex = mesh.materialIndex,
        transformMode = mesh.transformMode,
        -- A billboard segment's own source resolves the live post-BB draw
        -- matrix (the billboard base stays in the pose program), so the
        -- runtime never needs a compile-time bake for it.
        positionSource = mesh.positionSource or PoseContract.DRAW,
      }
      for _, field in ipairs(PolygonState.FIELDS) do
        record[field] = poly[field]
      end
      if mesh.straddle then
        record.straddle = mesh.straddle
      end
      out[#out + 1] = record
    end
  end
  local bankBytes = NativeGxFormat.encode({ draws = bankDraws })
  local bankKey = Hashing.sha1hex(bankBytes)
  meshes[bankKey] = bankBytes
  local bankFile = MapAssetCache.modelBankPath(bankKey)
  for index, record in ipairs(out) do
    record.geometry = { file = bankFile, drawIndex = index - 1 }
  end
  return out
end

---@param buildingModel table<string, unknown>
---@param buildingNsbmd table<string, unknown>
---@param texPack table<string, unknown>
---@param animResult table<string, unknown>
---@param context table<string, unknown>
---@param memberId integer
---@param textures table<string, table<string, unknown>>
---@param meshes table<string, table<string, unknown>>
---@return table<string, unknown>, table[]
function DynamicModelCompiler.compile(
  buildingModel,
  buildingNsbmd,
  texPack,
  animResult,
  context,
  memberId,
  textures,
  meshes
)
  if context.finalizeMeshes and context.geometryArena then
    context.geometryArena:reset()
  end
  local dynamicModel = NsbmdDynamicModel.compile(buildingModel, context)
  local base = MaterialCompiler.compile(buildingModel.materials, texPack, { context = context })
  for sha1, tex in pairs(base.textures) do
    textures[sha1] = tex
  end

  local unresolved = {}
  local variantsByName = {}
  local embeddedTex = buildingNsbmd.embeddedTextures
  local variants = patternVariants(animResult.clips, buildingModel.materials)
  if embeddedTex then
    variantsByName = resolvePatternVariants(embeddedTex, variants, textures, unresolved, context)
  elseif next(variants) then
    unresolved[#unresolved + 1] = {
      material = buildingModel.name,
      kind = "texture",
      name = "<pattern variants>",
      source = "model has no embedded TEX0",
    }
  end

  local wrapped = {}
  for _, entry in ipairs(unresolved) do
    wrapped[#wrapped + 1] = {
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

  return {
    schema = ModelAsset.SCHEMA,
    memberId = memberId,
    kind = "nitro-dynamic",
    dynamic = {
      nodes = dynamicModel.program.nodes,
      transformProgram = dynamicModel.program,
      batches = dynamicBatches(dynamicModel, buildingModel, meshes),
    },
    materials = dynamicMaterials(dynamicModel, base, variantsByName),
    animations = animResult.clips,
    doorSoundType = animResult.doorSoundType,
  },
    wrapped
end

return DynamicModelCompiler
