-- Stages the generated follower interaction catalog inside one artifact.

local Errors = require("libs.errors.src.Errors")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local Cache = require("libs.assets.src.field.FollowerInteractionCache")

local Writer = {}
local PROVENANCE = Cache.dir() .. "/provenance.lua"

local function stageBundle(stage, bundle)
  stage:writeLua(PROVENANCE, bundle.provenance)
  stage:writeLua(Cache.catalogPath(), bundle.catalog)
  local catalog = stage:loadLua(Cache.catalogPath())
  if type(catalog) ~= "table" then
    Errors.raise("FOLLOWER_INTERACTION_READBACK_FAILED", "catalog readback failed", {})
  end
  local valid, err = Cache.validateCatalog(catalog)
  if not valid then
    Errors.raise("FOLLOWER_INTERACTION_READBACK_FAILED", "catalog readback is invalid", {
      cause = err and err.message or "invalid catalog",
    })
  end
  stage:write(Cache.markerPath(), bundle.marker)
end

---@param artifact PreparedArtifact
---@param bundle table<string, unknown>
---@return string
function Writer.stage(artifact, bundle)
  assert(artifact and artifact.stageFs, "interaction staging requires a PreparedArtifact")
  assert(bundle and bundle.marker and bundle.catalog and bundle.provenance, "stage requires a complete bundle")
  assert(bundle.catalog.schema == Cache.SCHEMA, "interaction catalog schema mismatch")
  artifact:addOwnedRoot(Cache.dir())
  stageBundle(artifact:stageFs(), bundle)
  return bundle.marker
end

function Writer.isReady(cacheFs, expectedMarker)
  return Cache.isReady(cacheFs, expectedMarker)
end

function Writer.write(cacheFs, bundle)
  assert(bundle and bundle.marker and bundle.catalog and bundle.provenance, "write requires a complete bundle")
  assert(bundle.catalog.schema == Cache.SCHEMA, "interaction catalog schema mismatch")
  local transaction = ArtifactPublisher.begin(cacheFs, "follower-interactions", { Cache.dir() })
  local ok, err = pcall(stageBundle, transaction.stage, bundle)
  if not ok then
    transaction:abort()
    error(err, 0)
  end
  transaction:publish()
  return true
end

return Writer
