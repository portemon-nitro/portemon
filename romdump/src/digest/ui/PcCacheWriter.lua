-- Stages one complete PC family through the generation-owned PreparedArtifact.

local PcAssetSchema = require("libs.assets.src.PcAssetSchema")
local PcCache = require("libs.assets.src.PcCache")

local PcCacheWriter = {}

---@param artifact table<string, unknown>
---@param bundle table<string, unknown>
---@return string
function PcCacheWriter.stage(artifact, bundle)
  assert(
    artifact and artifact.stageFs and artifact.cacheFs and artifact.addOwnedRoot,
    "PC staging requires PreparedArtifact"
  )
  assert(type(bundle) == "table" and type(bundle.manifest) == "table", "PC bundle carries a manifest")
  assert(
    type(bundle.assets) == "table" and type(bundle.provenance) == "table",
    "PC bundle carries assets and provenance"
  )
  assert(type(bundle.dependencyHash) == "string" and bundle.dependencyHash ~= "", "PC bundle carries dependency hash")
  PcAssetSchema.assertManifest(bundle.manifest)
  assert(bundle.provenance.dependencyHash == bundle.dependencyHash, "PC provenance matches its dependency hash")
  local marker = PcCache.marker(
    assert(bundle.provenance.versionRomSha1, "PC provenance carries source ROM identity"),
    bundle.dependencyHash
  )
  local paths = PcCache.referencedPaths(bundle.manifest)
  for _, path in ipairs(paths) do
    assert(bundle.assets[path] ~= nil, "PC bundle is missing referenced image " .. path)
  end
  artifact:addOwnedRoot(PcCache.assetDir())
  artifact:addOwnedRoot(PcCache.dir())
  local stage = artifact:stageFs()
  for _, path in ipairs(paths) do
    stage:write(path, bundle.assets[path])
  end
  stage:writeLua(PcCache.manifestPath(), bundle.manifest)
  stage:writeLua(PcCache.provenancePath(), bundle.provenance)
  local readback = stage:loadLua(PcCache.manifestPath())
  PcAssetSchema.assertManifest(readback)
  for _, path in ipairs(PcCache.referencedPaths(readback)) do
    assert(stage:exists(path, "file"), "staged PC image is missing: " .. path)
  end
  stage:write(PcCache.markerPath(), marker)
  return marker
end

return PcCacheWriter
