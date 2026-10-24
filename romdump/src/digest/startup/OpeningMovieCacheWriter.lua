-- Transactional staging for one independently cached opening-movie scene.
-- The writer owns only the numbered scene manifest and its scene asset
-- root: staging or failing one scene never touches its siblings, the title,
-- or any previous last-known-good output. Files stage first, the manifest
-- stages last, and a strict readback through StartupAssetCache proves the
-- staged package ready before the job receipt can publish.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local StartupAssetCache = require("libs.assets.src.StartupAssetCache")

local OpeningMovieCacheWriter = {}

---@param artifact PreparedArtifact
---@param bundle table<string, unknown>
---@param generationId string
---@param sceneNumber integer
---@return string compiler marker for the receipt
function OpeningMovieCacheWriter.stageScene(artifact, bundle, generationId, sceneNumber)
  assert(artifact and type(artifact.stageFs) == "function", "opening scene staging requires a PreparedArtifact")
  assert(
    type(sceneNumber) == "number" and sceneNumber % 1 == 0 and sceneNumber >= 1 and sceneNumber <= 5,
    "opening scene number must be an integer 1..5"
  )
  assert(type(bundle) == "table" and type(bundle.manifest) == "table", "opening scene bundle requires its manifest")
  assert(type(bundle.files) == "table", "opening scene bundle requires staged asset files")
  assert(type(generationId) == "string" and generationId ~= "", "opening scene generation identity is required")
  assert(bundle.manifest.sceneNumber == sceneNumber, "opening scene bundle names another scene")
  assert(
    bundle.manifest.schema == "g4-startup-opening-scene-v3",
    "opening scene bundle carries the closed scene schema"
  )
  local sceneRoot = "assets/generated/startup/opening/" .. tostring(sceneNumber)
  local manifestPath = StartupAssetCache.openingScenePath(sceneNumber)
  local manifest = {}
  for key, value in pairs(bundle.manifest) do
    manifest[key] = value
  end
  manifest.generationId = generationId
  for path, bytes in pairs(bundle.files) do
    local dataObject = (type(bytes) == "table" or type(bytes) == "userdata") and type(bytes.getSize) == "function"
    assert(
      type(path) == "string"
        and path:sub(1, #sceneRoot + 1) == sceneRoot .. "/"
        and (type(bytes) == "string" or dataObject),
      "opening scene files must be binary data under their numbered scene root"
    )
  end
  local stage = artifact:stageFs()
  artifact:addOwnedRoot(manifestPath)
  artifact:addOwnedRoot(sceneRoot)
  for path, bytes in pairs(bundle.files) do
    stage:write(path, bytes)
  end
  assert(type(manifest.versionId) == "string", "opening scene bundle carries its edition")
  stage:writeLua(manifestPath, manifest)
  local readback, readError = StartupAssetCache.loadOpeningScene(stage, sceneNumber, manifest.versionId)
  if readback == nil or readback.generationId ~= generationId then
    Errors.raise("OPENING_SCENE_STAGE_INVALID", "staged opening scene manifest failed validation", {
      scene = sceneNumber,
      cause = readError and tostring(readError) or "generation mismatch",
    })
  end
  return "opening-scene:"
    .. tostring(sceneNumber)
    .. ":"
    .. generationId
    .. ":"
    .. Hashing.hashLua(bundle.dependencies or bundle.manifest)
end

return OpeningMovieCacheWriter
