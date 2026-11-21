-- Transactional writer for the normalized movement-emote billboard descriptor.

local FieldEmoteAssetCache = require("libs.assets.src.field.FieldEmoteAssetCache")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local Writer = {}

---@param stage PreparedArtifact
---@param bundle table<string, unknown>
local function persist(stage, bundle)
  for key, bank in pairs(bundle.meshes) do
    stage:write(FieldEmoteAssetCache.geometryPath(key), bank)
  end
  for key, bank in pairs(bundle.textures) do
    stage:write(FieldEmoteAssetCache.texturePath(key), bank)
  end
  stage:writeLua(FieldEmoteAssetCache.exclamationDescriptorPath(), bundle.model)
  local descriptor = assert(stage:loadLua(FieldEmoteAssetCache.exclamationDescriptorPath()))
  local valid, validationErr = FieldEmoteAssetCache.validateDescriptor(descriptor)
  if not valid then
    error(validationErr, 0)
  end
  for _, path in ipairs(ModelAsset.referencedPaths(descriptor.model)) do
    assert(stage:exists(path), "field-emote referenced asset is missing: " .. path)
  end
  stage:write(FieldEmoteAssetCache.markerPath(), bundle.marker)
end

---@param artifact PreparedArtifact
---@param bundle table<string, unknown>
---@return string
function Writer.stage(artifact, bundle)
  assert(artifact and artifact.write, "field-emotes staging requires a PreparedArtifact")
  assert(type(bundle) == "table" and bundle.marker, "invalid field-emotes bundle")
  artifact:addOwnedRoot("assets/generated/field/emotes")
  artifact:addOwnedRoot("data/generated/field/emotes")
  persist(artifact, bundle)
  return bundle.marker
end

return Writer
