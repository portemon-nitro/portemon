-- Publishes startup visuals and title resources through the worker's staged artifact.

local Errors = require("libs.errors.src.Errors")
local PngWriter = require("libs.assets.src.PngWriter")
local StartupAssetCache = require("libs.assets.src.StartupAssetCache")
local Hashing = require("romdump.src.digest.Hashing")

local StartupCacheWriter = {}

local function copyManifest(manifest, generationId)
  local copy = {}
  for key, value in pairs(manifest) do
    copy[key] = value
  end
  copy.generationId = generationId
  return copy
end

local function writeFiles(stage, files, root)
  for path, bytes in pairs(files) do
    local dataObject = (type(bytes) == "table" or type(bytes) == "userdata") and type(bytes.getSize) == "function"
    assert(
      type(path) == "string" and path:sub(1, #root + 1) == root .. "/" and (type(bytes) == "string" or dataObject),
      "startup files must be binary data under their family's asset root"
    )
    stage:write(path, bytes)
  end
end

local function stageFamily(artifact, family, bundle, generationId)
  assert(artifact and type(artifact.stageFs) == "function", "startup staging requires a PreparedArtifact")
  assert(type(bundle) == "table" and type(bundle.manifest) == "table", "startup compiler bundle is invalid")
  assert(type(generationId) == "string" and generationId ~= "", "startup generation identity is required")
  local manifest = copyManifest(bundle.manifest, generationId)
  local assetRoot = "assets/generated/startup/" .. family
  local manifestPath = family == "loader" and StartupAssetCache.loaderPath() or StartupAssetCache.titlePath()
  local stage = artifact:stageFs()

  artifact:addOwnedRoot(manifestPath)
  artifact:addOwnedRoot(assetRoot)
  writeFiles(stage, bundle.assets or {}, assetRoot)
  writeFiles(stage, bundle.files or {}, assetRoot)
  stage:writeLua(manifestPath, manifest)

  local validator = family == "loader" and StartupAssetCache.loadLoader or StartupAssetCache.loadTitle
  local readback, readError
  if family == "loader" then
    readback, readError = validator(stage)
  else
    readback, readError = validator(stage, manifest.versionId)
  end
  if readback == nil or readback.generationId ~= generationId then
    Errors.raise("STARTUP_ASSET_STAGE_INVALID", "staged startup " .. family .. " manifest failed validation", {
      cause = readError and tostring(readError) or "generation mismatch",
    })
  end
  return "startup-" .. family .. ":" .. generationId .. ":" .. Hashing.hashLua(bundle.dependencies or bundle.manifest)
end

---@param artifact PreparedArtifact
---@param bundle table<string, unknown>
---@param generationId string
---@return string
function StartupCacheWriter.stageLoader(artifact, bundle, generationId)
  assert(type(bundle.atlases) == "table", "loader bundle requires compiled atlases")
  local files = {}
  for path, atlas in pairs(bundle.atlases) do
    assert(type(atlas) == "table", "loader atlas must contain pixel dimensions")
    files[path] = PngWriter.encode(atlas.width, atlas.height, atlas.pixels)
  end
  local manifest = copyManifest(bundle.manifest, generationId)
  assert(type(bundle.backdrop) == "table", "loader bundle requires its backdrop")
  local backdropPath = "assets/generated/startup/loader/backdrop.png"
  manifest.backdrop = {
    kind = bundle.manifest.backdrop.kind,
    width = bundle.backdrop.width,
    height = bundle.backdrop.height,
    image = backdropPath,
  }
  files[backdropPath] = PngWriter.encode(bundle.backdrop.width, bundle.backdrop.height, bundle.backdrop.pixels)
  return stageFamily(artifact, "loader", {
    manifest = manifest,
    files = files,
    dependencies = bundle.dependencies,
  }, generationId)
end

---@param artifact PreparedArtifact
---@param bundle table<string, unknown>
---@param generationId string
---@return string
function StartupCacheWriter.stageTitle(artifact, bundle, generationId)
  assert(type(bundle.files) == "table", "title bundle requires finalized asset files")
  return stageFamily(artifact, "title", {
    manifest = bundle.manifest,
    files = bundle.files,
    dependencies = bundle.dependencies,
  }, generationId)
end

return StartupCacheWriter
