-- Pure generation identity of one derived-cache build: the strict record
-- { schema, versionId, romSha1, mode, producerId, assetRevision, scriptApi,
-- generationId }. Development producer identity is `d` plus the SHA-256 digest
-- of the actual producer working-tree bytes; release producer identity is `r`
-- plus the explicit per-game release counter and never enumerates sources. The
-- generation token `g4:<version>:<romSha1>:<producerId>:a<revision>:s<api>`
-- is a comparison token, not a save fingerprint and not a path. The committed
-- snapshot's manifest carries the same identity fields, so this module derives
-- and compares the identity only; it never persists or reads a separate
-- attestation file. A stored record from a previous schema never matches the
-- current identity; it is cold, not a migration error.

local Errors = require("libs.errors.src.Errors")
local GameVersion = require("romdump.src.source.GameVersion")
local Hashing = require("romdump.src.digest.Hashing")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local DerivedCacheVersions = require("romdump.src.config.DerivedCacheVersions")
local Schema = require("libs.script.src.Schema")

local DerivedCacheState = {}

-- Schema of the identity record itself; bump when its shape changes.
DerivedCacheState.schema = 2

local GENERATION_KEYS = {
  schema = true,
  versionId = true,
  romSha1 = true,
  mode = true,
  producerId = true,
  assetRevision = true,
  scriptApi = true,
  generationId = true,
}

local LEGACY_KEYS = {
  schema = true,
  dump = true,
  producer = true,
  assetContract = true,
  scriptApi = true,
}

local function invalidIdentity(field, expectation)
  Errors.raise("INVALID_GENERATION_IDENTITY", "invalid generation identity: " .. field .. " " .. expectation, {})
end

local function checkVersion(versionId)
  if type(versionId) ~= "string" or GameVersion.VERSIONS[versionId] == nil then
    Errors.raise("UNSUPPORTED_VERSION", "unsupported version: " .. tostring(versionId), { versionId = versionId })
  end
end

local function checkRomSha1(romSha1)
  if type(romSha1) ~= "string" or #romSha1 ~= 40 or romSha1:find("[^0-9a-f]") ~= nil then
    invalidIdentity("romSha1", "must be 40 lowercase hex characters")
  end
end

local function checkMode(mode)
  if mode ~= "development" and mode ~= "release" then
    invalidIdentity("mode", "must be development or release")
  end
end

local function checkProducerId(mode, producerId)
  if type(producerId) ~= "string" then
    invalidIdentity("producerId", "must be a string")
  end
  if mode == "development" then
    local body = producerId:sub(1, 1) == "d" and producerId:sub(2) or nil
    if body == nil or #producerId ~= 65 or body:find("[^0-9a-f]") ~= nil then
      invalidIdentity("producerId", "development producer identity must be d followed by 64 lowercase hex characters")
    end
    return
  end
  local counter = producerId:match("^r(%d+)$")
  if counter == nil or tonumber(counter) == nil or (tonumber(counter) or 0) < 1 then
    invalidIdentity("producerId", "release producer identity must be r followed by a positive integer")
  end
end

local function checkInteger(field, value)
  if type(value) ~= "number" or value ~= math.floor(value) then
    invalidIdentity(field, "must be an integer")
  end
end

local function generationIdFor(versionId, romSha1, producerId, assetRevision, scriptApi)
  return "g4:"
    .. versionId
    .. ":"
    .. romSha1
    .. ":"
    .. producerId
    .. ":a"
    .. tostring(assetRevision)
    .. ":s"
    .. tostring(scriptApi)
end

---@param inputs { versionId: string, romSha1: string, mode: string, producerId: string, assetRevision: number, scriptApi: number, dump?: unknown, producer?: unknown, assetContract?: unknown }
---@return table<string, unknown>
local function currentGeneration(inputs)
  if inputs.dump ~= nil or inputs.producer ~= nil or inputs.assetContract ~= nil then
    Errors.raise(
      "INVALID_GENERATION_IDENTITY",
      "generation identity mixes previous-schema and current-schema inputs",
      {}
    )
  end
  checkVersion(inputs.versionId)
  checkRomSha1(inputs.romSha1)
  checkMode(inputs.mode)
  checkProducerId(inputs.mode, inputs.producerId)
  checkInteger("assetRevision", inputs.assetRevision)
  checkInteger("scriptApi", inputs.scriptApi)
  return {
    schema = DerivedCacheState.schema,
    versionId = inputs.versionId,
    romSha1 = inputs.romSha1,
    mode = inputs.mode,
    producerId = inputs.producerId,
    assetRevision = inputs.assetRevision,
    scriptApi = inputs.scriptApi,
    generationId = generationIdFor(
      inputs.versionId,
      inputs.romSha1,
      inputs.producerId,
      inputs.assetRevision,
      inputs.scriptApi
    ),
  }
end

-- Selection identity for the interactive app shell: the caller supplies the
-- version, validated ROM SHA-1, and producer identity, while the
-- asset-contract revision and script API version resolve here. Game-side
-- composition therefore never imports producer constant owners directly;
-- the current schema-2 record is the only identity vocabulary.
---@param inputs { versionId: string, romSha1: string, producerId: string, developmentRepositoryRoot?: string }
---@return table<string, unknown>
function DerivedCacheState.currentForSelection(inputs)
  assert(type(inputs) == "table", "selection identity inputs are required")
  return currentGeneration({
    versionId = inputs.versionId,
    romSha1 = inputs.romSha1,
    mode = inputs.developmentRepositoryRoot ~= nil and "development" or "release",
    producerId = inputs.producerId,
    assetRevision = DerivedAssetContract.revision,
    scriptApi = Schema.API_VERSION,
  })
end

-- The release generation token for a version: the accepted ROM SHA-1, the
-- explicit per-game release counter, the asset-contract revision, and the
-- script API version only. Release callers derive it on the game thread
-- without a producer scan; development identity is never derived here.
---@param versionId string
---@return string generationId
function DerivedCacheState.releaseGenerationId(versionId)
  local info = GameVersion.info(versionId)
  assert(type(info) == "table" and type(info.sha1) == "string", "unknown version: " .. tostring(versionId))
  local counter = DerivedCacheVersions[versionId]
  assert(
    type(counter) == "number" and counter % 1 == 0 and counter >= 1,
    "release counter must be a positive integer for version: " .. tostring(versionId)
  )
  local identity = DerivedCacheState.currentForSelection({
    versionId = versionId,
    romSha1 = info.sha1,
    producerId = "r" .. tostring(counter),
  })
  return assert(identity.generationId, "selection identity carries no generation token")
end

-- The current identity for the given inputs: either the strict schema-2
-- generation record (version, validated ROM SHA-1, execution mode, producer
-- identity, asset-contract revision, script API version) or, for the batch
-- builder's existing attestation path, the previous schema-1 record built
-- from the published raw-dump marker, the producer digest, the shared
-- asset-contract table, and the gen4 script DSL API version. A stored
-- schema-1 record never matches a schema-2 expectation.
---@param inputs table<string, unknown>
---@return table<string, unknown>
function DerivedCacheState.current(inputs)
  assert(type(inputs) == "table", "generation identity inputs are required")
  if
    inputs.versionId ~= nil
    or inputs.mode ~= nil
    or inputs.producerId ~= nil
    or inputs.romSha1 ~= nil
    or inputs.assetRevision ~= nil
  then
    return currentGeneration(inputs)
  end
  assert(type(inputs.dump) == "string", "dump marker must be a string")
  assert(type(inputs.producer) == "string", "producer fingerprint must be a string")
  assert(type(inputs.assetContract) == "table", "asset contract must be a table")
  assert(type(inputs.scriptApi) == "number", "script API version must be a number")
  return {
    schema = 1,
    dump = inputs.dump,
    producer = inputs.producer,
    assetContract = Hashing.hashLua(inputs.assetContract),
    scriptApi = inputs.scriptApi,
  }
end

local function exactKeys(record, allowed)
  local count = 0
  for key in pairs(record) do
    if not allowed[key] then
      return false
    end
    count = count + 1
  end
  local allowedCount = 0
  for _ in pairs(allowed) do
    allowedCount = allowedCount + 1
  end
  return count == allowedCount
end

local function fieldsMatch(stored, identity, allowed)
  if not exactKeys(stored, allowed) or not exactKeys(identity, allowed) then
    return false
  end
  for key in pairs(allowed) do
    if stored[key] ~= identity[key] then
      return false
    end
  end
  return true
end

-- True when the stored state (nil when missing or malformed) carries exactly
-- the expected identity's declared fields with equal values. A previous or
-- unknown schema never matches, and any extra field on either side fails the
-- comparison.
---@param stored unknown
---@param identity table<string, unknown>
---@return boolean
function DerivedCacheState.matches(stored, identity)
  if type(stored) ~= "table" or type(identity) ~= "table" then
    return false
  end
  if type(stored.schema) ~= "number" or stored.schema ~= identity.schema then
    return false
  end
  if stored.schema == DerivedCacheState.schema then
    return fieldsMatch(stored, identity, GENERATION_KEYS)
  end
  if stored.schema == 1 then
    return fieldsMatch(stored, identity, LEGACY_KEYS)
  end
  return false
end

return DerivedCacheState
