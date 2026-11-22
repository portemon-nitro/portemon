-- Transactional writer for the normalized directional entrance field effect.

local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local Writer = {}

---@param stage PreparedArtifact
---@param bundle table<string, unknown>
local function persist(stage, bundle)
  for key, bank in pairs(bundle.meshes) do
    stage:write(FieldEffectAssetCache.geometryPath(key), bank)
  end
  for key, texture in pairs(bundle.textures) do
    -- 3D texture banks travel as their bytes; rasterized cinematic layers keep
    -- the readable PNG beside them under their own path.
    if type(texture) == "table" then
      stage:write(FieldEffectAssetCache.imagePath(key), assert(texture.data, "compiled effect image is missing"))
    else
      stage:write(FieldEffectAssetCache.texturePath(key), texture)
    end
  end
  for kind, definition in pairs(bundle.effects) do
    stage:writeLua(FieldEffectAssetCache.definitionPath(kind), definition)
    local descriptors = FieldEffectAssetCache.modelDescriptors(kind, definition, function(partKind)
      return assert(bundle.effects[partKind], "field-effect part is missing from the bundle: " .. partKind)
    end)
    assert(
      #descriptors >= 1 or FieldEffectAssetCache.isPartKind(kind) or FieldEffectAssetCache.isModellessKind(kind),
      "field-effect definition carries no model"
    )
    for _, descriptor in ipairs(descriptors) do
      ModelAsset.validate(descriptor)
      for _, path in ipairs(ModelAsset.referencedPaths(descriptor)) do
        assert(stage:exists(path), "field-effect referenced asset is missing: " .. path)
      end
    end
  end
  stage:writeLua(FieldEffectAssetCache.indexPath(), bundle.index)
  stage:write(FieldEffectAssetCache.markerPath(), bundle.marker)
end

---@param artifact PreparedArtifact
---@param bundle table<string, unknown>
---@return string
function Writer.stage(artifact, bundle)
  assert(artifact and artifact.write, "field-effects staging requires a PreparedArtifact")
  assert(type(bundle) == "table" and bundle.marker, "invalid field-effects bundle")
  artifact:addOwnedRoot("assets/generated/field/effects")
  artifact:addOwnedRoot("data/generated/field/effects")
  persist(artifact, bundle)
  return bundle.marker
end

return Writer
