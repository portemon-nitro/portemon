-- Persists compiled field-message banks one at a time through staged
-- publication: each bank's compact payload is written into a disposable stage
-- and published, so a failed bank never poisons its siblings. A successful
-- write is not reopened: the encoder validated its own output, and the bank
-- job's own receipt is its durable completion proof, so no marker, provenance
-- or family summary copies it again. The family index is a separate small
-- stage that attests complete coverage without retaining any bank payload: it
-- refuses partial coverage and never replaces bank children. Publication
-- happens outside the staging step's error handler, so a publish failure never
-- triggers writer-level stage cleanup that could delete the last remaining
-- copy of the previous artifact.

local Errors = require("libs.errors.src.Errors")
local FieldMessageAsset = require("libs.assets.src.field.FieldMessageAsset")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local Hashing = require("romdump.src.digest.Hashing")
local Validate = require("libs.assets.src.Validate")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")

local FieldMessageCacheWriter = {}

function FieldMessageCacheWriter.isReady(cacheFs)
  return FieldMessageCache.isReady(cacheFs)
end

---@param bundle unknown
---@return FieldMessageCompiler.BankBundle
local function checkBankBundle(bundle)
  assert(type(bundle) == "table", "stageBank requires a one-bank bundle")
  ---@cast bundle FieldMessageCompiler.BankBundle
  assert(Validate.isNonNegativeInteger(bundle.bankId), "one-bank bundle carries an invalid bankId")
  local data = bundle.data
  assert(
    (type(data) == "table" or type(data) == "userdata")
      and type(data.getFFIPointer) == "function"
      and type(data.getSize) == "function",
    "one-bank bundle carries no rooted compact payload"
  )
  assert(type(bundle.marker) == "string" and bundle.marker ~= "", "one-bank bundle carries no marker")
  -- The payload must open as this bank before any stage ownership changes, so
  -- a bundle/encoder mismatch never reaches the live cache.
  local opened, view = pcall(FieldMessageAsset.open, data, bundle.bankId)
  assert(opened, "one-bank payload is not bank " .. tostring(bundle.bankId) .. ": " .. tostring(view))
  return bundle
end

-- The one staging step every bank entry point shares: write exactly this
-- bank's payload bytes into the given stage filesystem. Never touches a
-- sibling bank and never reopens what it wrote.
---@param stage CacheFs
---@param bundle FieldMessageCompiler.BankBundle
---@return string
local function persistBank(stage, bundle)
  stage:write(FieldMessageCache.bankPath(bundle.bankId), bundle.data)
  return bundle.marker
end

-- Stage one normalized bank through a caller-owned prepared artifact: the
-- stage owns exactly this bank's payload, so per-bank jobs never overlap.
-- Publication stays with the caller; a stage failure leaves the previous live
-- record untouched once the caller aborts the disposable stage.
---@param artifact PreparedArtifact
---@param bundle FieldMessageCompiler.BankBundle
---@return string
function FieldMessageCacheWriter.stageBank(artifact, bundle)
  assert(artifact and artifact.stageFs, "bank staging requires a PreparedArtifact")
  local owned = checkBankBundle(bundle)
  artifact:addOwnedRoot(FieldMessageCache.bankPath(owned.bankId))
  return persistBank(artifact:stageFs(), owned)
end

function FieldMessageCacheWriter.writeBank(cacheFs, bundle)
  local owned = checkBankBundle(bundle)
  local tx = ArtifactPublisher.begin(cacheFs, "field-message-bank-" .. owned.bankId, {
    FieldMessageCache.bankPath(owned.bankId),
  })
  local ok, result = pcall(persistBank, tx.stage, owned)
  if not ok then
    tx:abort()
    error(result, 0)
  end
  tx:publish()
  return result
end

---@param index unknown
---@return FieldMessageCache.Index
local function checkIndex(index)
  assert(type(index) == "table", "summary staging requires the family index")
  ---@cast index FieldMessageCache.Index
  assert(index.schema == FieldMessageCache.INDEX_SCHEMA, "family index schema mismatch")
  assert(type(index.version) == "string" and index.version ~= "", "family index carries no version")
  assert(Validate.isArray(index.bankIds) and #index.bankIds > 0, "family index carries no bank selection")
  local seen = {}
  for position, bankId in ipairs(index.bankIds) do
    assert(Validate.isNonNegativeInteger(bankId), "family index carries an invalid bankId")
    assert(seen[bankId] == nil, "family index selects bank " .. tostring(bankId) .. " twice")
    assert(position == 1 or index.bankIds[position - 1] < bankId, "family index bankIds must be ascending")
    seen[bankId] = true
  end
  return index
end

-- The deterministic completion marker for one covered family: the selected
-- bank markers already bind each bank's source identity, so the summary binds
-- the index selection to those markers.
---@param index FieldMessageCache.Index
---@param bankMarkers table<integer, string>
---@return string
function FieldMessageCacheWriter.summaryMarker(index, bankMarkers)
  local ownedIndex = checkIndex(index)
  assert(type(bankMarkers) == "table", "summary staging requires one marker per bank")
  local firstMarker = nil
  local entries = {}
  for _, bankId in ipairs(ownedIndex.bankIds) do
    local marker = bankMarkers[bankId]
    assert(type(marker) == "string" and marker ~= "", "family summary is missing the marker for bank " .. bankId)
    if firstMarker == nil then
      firstMarker = marker
    end
    entries[#entries + 1] = bankId .. "=" .. marker
  end
  assert(firstMarker ~= nil, "unreachable: a nonempty index always selects a first bank")
  local romSha1 = firstMarker:match("^[^:]+:([^:]+):.+$")
  assert(type(romSha1) == "string", "bank markers carry no ROM identity")
  return FieldMessageCache.marker(romSha1, Hashing.hashLua({ index = ownedIndex, banks = entries }))
end

-- The one staging step every summary entry point shares: prove every selected
-- bank's payload is readable in the live cache under its expected receipt
-- marker, then write only the index into the stage. Bank children are never
-- staged here, so the summary cannot erase them.
---@param stage CacheFs
---@param liveFs CacheFs
---@param index FieldMessageCache.Index
---@param bankMarkers table<integer, string>
---@return string
local function persistSummary(stage, liveFs, index, bankMarkers)
  local missing = {}
  for _, bankId in ipairs(index.bankIds) do
    local expected = bankMarkers[bankId]
    if type(expected) ~= "string" or not FieldMessageCache.isBankReady(liveFs, bankId) then
      missing[#missing + 1] = bankId
    end
  end
  if #missing > 0 then
    Errors.raise(
      "FIELD_MESSAGE_SUMMARY_INCOMPLETE",
      "family summary refuses incomplete bank coverage",
      { missingBankIds = missing }
    )
  end
  local marker = FieldMessageCacheWriter.summaryMarker(index, bankMarkers)
  stage:writeLua(
    FieldMessageCache.indexPath(),
    { schema = index.schema, version = index.version, bankIds = index.bankIds }
  )
  local readIndex = stage:loadLua(FieldMessageCache.indexPath())
  if type(readIndex) ~= "table" or readIndex.schema ~= FieldMessageCache.INDEX_SCHEMA then
    Errors.raise("FIELD_MESSAGE_CACHE_READBACK_FAILED", "index readback failed", {})
  end
  return marker
end

-- Stage the family summary through a caller-owned prepared artifact: the
-- stage owns exactly the index, never the bank directories. Publication stays
-- with the caller.
---@param artifact PreparedArtifact
---@param index FieldMessageCache.Index
---@param bankMarkers table<integer, string>
---@return string
function FieldMessageCacheWriter.stageSummary(artifact, index, bankMarkers)
  assert(artifact and artifact.stageFs and artifact.cacheFs, "summary staging requires a PreparedArtifact")
  local ownedIndex = checkIndex(index)
  artifact:addOwnedRoot(FieldMessageCache.indexPath())
  return persistSummary(artifact:stageFs(), artifact:cacheFs(), ownedIndex, bankMarkers)
end

function FieldMessageCacheWriter.writeSummary(cacheFs, index, bankMarkers)
  local ownedIndex = checkIndex(index)
  local tx = ArtifactPublisher.begin(cacheFs, "field-messages", {
    FieldMessageCache.indexPath(),
  })
  local ok, result = pcall(persistSummary, tx.stage, cacheFs, ownedIndex, bankMarkers)
  if not ok then
    tx:abort()
    error(result, 0)
  end
  tx:publish()
  return result
end

return FieldMessageCacheWriter
