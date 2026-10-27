-- Publishes startup visuals and title resources through the worker's staged artifact.

local Errors = require("libs.errors.src.Errors")
local PngWriter = require("romdump.src.digest.PngEncoder")
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
  local manifestPath = StartupAssetCache.titlePath()
  local stage = artifact:stageFs()

  artifact:addOwnedRoot(manifestPath)
  artifact:addOwnedRoot(assetRoot)
  writeFiles(stage, bundle.assets or {}, assetRoot)
  writeFiles(stage, bundle.files or {}, assetRoot)
  stage:writeLua(manifestPath, manifest)

  local readback, readError = StartupAssetCache.loadTitle(stage, manifest.versionId)
  if readback == nil or readback.generationId ~= generationId then
    Errors.raise("STARTUP_ASSET_STAGE_INVALID", "staged startup " .. family .. " manifest failed validation", {
      cause = readError and tostring(readError) or "generation mismatch",
    })
  end
  return "startup-" .. family .. ":" .. generationId .. ":" .. Hashing.hashLua(bundle.dependencies or bundle.manifest)
end

local function hasTransparentTexel(pixels)
  if type(pixels) ~= "string" or #pixels % 4 ~= 0 then
    return false
  end
  for offset = 4, #pixels, 4 do
    if pixels:byte(offset) == 0 then
      return true
    end
  end
  return false
end

---@param artifact PreparedArtifact
---@param bundle table<string, unknown>
---@param generationId string
---@param pairIndex integer?
---@return string
function StartupCacheWriter.stageLoader(artifact, bundle, generationId, pairIndex)
  assert(artifact and type(artifact.stageFs) == "function", "startup staging requires a PreparedArtifact")
  assert(type(bundle) == "table" and type(bundle.manifest) == "table", "loader bundle requires its manifest")
  assert(type(bundle.atlases) == "table", "loader bundle requires compiled atlases")
  assert(type(generationId) == "string" and generationId ~= "", "startup generation identity is required")
  local selected = pairIndex ~= nil and pairIndex or bundle.manifest.pairIndex
  assert(
    type(selected) == "number" and selected % 1 == 0 and selected >= 1 and selected <= 32,
    "walking pair index must be an integer 1..32"
  )
  assert(bundle.manifest.pairIndex == selected, "loader bundle names another walking pair")
  assert(bundle.manifest.schema == "g4-startup-walker-v1", "loader bundle carries the keyed pair schema")
  local pairRoot = "assets/generated/startup/loader/pairs/" .. tostring(selected)
  local manifestPath = StartupAssetCache.walkerPath(selected)
  local manifest = copyManifest(bundle.manifest, generationId)
  local count = 0
  local files = {}
  for path, atlas in pairs(bundle.atlases) do
    assert(type(atlas) == "table", "loader atlas must contain pixel dimensions")
    assert(
      type(path) == "string" and path:sub(1, #pairRoot + 1) == pairRoot .. "/",
      "loader atlas escapes its walking pair root"
    )
    if not hasTransparentTexel(atlas.pixels) then
      Errors.raise("STARTUP_ASSET_STAGE_INVALID", "staged walking pair atlas has no transparent pixels", {
        path = path,
      })
    end
    files[path] = PngWriter.encode(atlas.width, atlas.height, atlas.pixels)
    count = count + 1
  end
  assert(count == 2, "one walking pair stages exactly two atlases")
  local stage = artifact:stageFs()
  artifact:addOwnedRoot(manifestPath)
  artifact:addOwnedRoot(pairRoot)
  writeFiles(stage, files, pairRoot)
  stage:writeLua(manifestPath, manifest)
  local readback, readError = StartupAssetCache.loadWalker(stage, selected)
  if readback == nil or readback.generationId ~= generationId then
    Errors.raise("STARTUP_ASSET_STAGE_INVALID", "staged walking pair manifest failed validation", {
      cause = readError and tostring(readError) or "generation mismatch",
    })
  end
  return "startup-loader:"
    .. tostring(selected)
    .. ":"
    .. generationId
    .. ":"
    .. Hashing.hashLua(bundle.dependencies or bundle.manifest)
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
