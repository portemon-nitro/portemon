-- Publishes the League ending's complete bundle: the registration, showcase and
-- credit-roll sections plus every rasterized source background the roll draws.
-- The writer owns the bundle's own directory root and marker; a partial bundle
-- never publishes.

local Errors = require("libs.errors.src.Errors")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local EndingAssetCache = require("libs.assets.src.ending.EndingAssetCache")
local Validate = require("libs.assets.src.Validate")

local EndingCacheWriter = {}
EndingCacheWriter.ERROR = {
  BUNDLE_INVALID = "ENDING_CACHE_BUNDLE_INVALID",
  READBACK_FAILED = "ENDING_CACHE_READBACK_FAILED",
}

local SECTIONS = { "registration", "showcase", "credits" }

---@param bundle table<string, unknown>
local function validateBundle(bundle)
  if
    type(bundle) ~= "table"
    or type(bundle.marker) ~= "string"
    or type(bundle.sections) ~= "table"
    or type(bundle.images) ~= "table"
    or type(bundle.provenance) ~= "table"
  then
    Errors.raise(EndingCacheWriter.ERROR.BUNDLE_INVALID, "bundle is incomplete", {})
  end
  local provenance = assert(bundle.provenance --[[@as table<string, unknown>]])
  if
    not Validate.isSha1Key(provenance.versionRomSha1)
    or not Validate.isSha1Key(provenance.dependencyHash)
    or type(provenance.dependencies) ~= "table"
  then
    Errors.raise(EndingCacheWriter.ERROR.BUNDLE_INVALID, "bundle provenance is invalid", {})
  end
  if provenance.cacheFormat ~= EndingAssetCache.FORMAT or provenance.schema ~= EndingAssetCache.SCHEMA then
    Errors.raise(EndingCacheWriter.ERROR.BUNDLE_INVALID, "bundle provenance names another schema", {})
  end
  for _, name in ipairs(SECTIONS) do
    if type(bundle.sections[name]) ~= "table" then
      Errors.raise(EndingCacheWriter.ERROR.BUNDLE_INVALID, "bundle is missing its section", { section = name })
    end
  end
end

---@param bundle table<string, unknown>
---@return table<string, unknown> the published index record
local function indexFor(bundle)
  local paths = {}
  for _, name in ipairs(SECTIONS) do
    paths[name] = EndingAssetCache.DIR .. "/" .. name .. ".lua"
  end
  return {
    schema = EndingAssetCache.SCHEMA,
    marker = bundle.marker,
    sections = paths,
    provenance = bundle.provenance,
  }
end

---@param stage table<string, unknown>
---@param bundle table<string, unknown>
local function stageBundle(stage, bundle)
  local sections = assert(bundle.sections --[[@as table<string, unknown>]])
  local images = assert(bundle.images --[[@as table<string, unknown>]])
  for _, name in ipairs(SECTIONS) do
    stage:writeLua(EndingAssetCache.DIR .. "/" .. name .. ".lua", sections[name])
  end
  for path, image in pairs(images) do
    local record = assert(image --[[@as table<string, unknown>]])
    local bytes = assert(record.data, "a bundle image carries its bytes: " .. tostring(path))
    stage:write(assert(path, "a bundle image names its path"), bytes)
  end
  stage:writeLua(EndingAssetCache.indexPath(), indexFor(bundle))
  -- Read each published section and image back: a bundle that cannot be
  -- admitted from its own staged files must never publish its marker.
  local index = assert(stage:loadLua(EndingAssetCache.indexPath()))
  for _, name in ipairs(SECTIONS) do
    local path = assert(assert(index.sections)[name])
    if stage:loadLua(path) == nil then
      Errors.raise(EndingCacheWriter.ERROR.READBACK_FAILED, "section is missing after stage", { path = path })
    end
  end
  stage:write(EndingAssetCache.markerPath(), bundle.marker)
end

---@param artifact table<string, unknown>
---@param bundle table<string, unknown>
---@return string marker
function EndingCacheWriter.stage(artifact, bundle)
  assert(artifact and artifact.stageFs, "ending staging requires a PreparedArtifact")
  validateBundle(bundle)
  artifact:addOwnedRoot(EndingAssetCache.DIR)
  stageBundle(artifact:stageFs(), bundle)
  return bundle.marker
end

---@param cacheFs table<string, unknown>
---@param bundle table<string, unknown>
---@return string marker
function EndingCacheWriter.write(cacheFs, bundle)
  validateBundle(bundle)
  local tx = ArtifactPublisher.begin(cacheFs, "ending", { EndingAssetCache.DIR })
  local ok, err = pcall(stageBundle, tx.stage, bundle)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  tx:publish()
  return bundle.marker
end

return EndingCacheWriter
