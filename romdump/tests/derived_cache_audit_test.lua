-- The generation audit proves one exact generation usable: every job in the
-- complete canonical inventory must carry a committed artifact fact for that
-- generation and pass its family validator. Markers alone prove nothing,
-- expected membership is never inferred from published entries, and the
-- full-build attestation is published only after the audit passes, so it is
-- never consulted here. The walk is read-only.

local Assert = require("tests.support.Assert")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local ArtifactState = require("romdump.src.build.ArtifactState")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local DerivedCacheAudit = require("romdump.src.DerivedCacheAudit")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldCameraCache = require("libs.assets.src.field.FieldCameraCache")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local FieldMessageFixture = require("tests.support.FieldMessageFixture")
local ItemCache = require("libs.assets.src.ItemCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MonCache = require("libs.assets.src.MonCache")

local T = {}

local IDENTITY = {
  versionId = "heartgold",
  generationId = "current-generation",
  producerId = "audit-producer",
}

-- The smallest well-formed inventory the walk accepts: no cells, no maps,
-- no members, no banks, no pages, so the first global job decides.
local function minimalPlans()
  return {
    indexBundle = { index = { matrices = {} } },
    scriptPlan = { generationKey = string.rep("e", 40), members = {}, resources = {} },
    messageBankIds = {},
    audioBankIds = {},
    scriptMemberIds = {},
    iconPageIds = {},
    portraitPageIds = {},
    mapDataIds = {},
    mapIds = {},
  }
end

local function newFacts(identity)
  return ArtifactState.new((identity or IDENTITY).generationId)
end

local function commitFact(facts, kind, key, marker)
  ArtifactState.commitFact(facts, {
    kind = kind,
    key = key,
    marker = marker or ("marker-" .. kind .. "-" .. key),
    dependencies = {},
    ownedRoots = {},
    sharedPaths = {},
    files = {},
  })
end

-- Completion markers without committed facts never read as usable, no matter
-- how many families left them behind.
local function publishedMarkers()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  for _, path in ipairs({
    FieldActorCache.markerPath(),
    FieldCameraCache.markerPath(),
    FieldCellCache.indexMarkerPath(),
    MonCache.markerPath(),
    ItemCache.markerPath(),
    FieldMapDataCache.spawnIndexMarkerPath(),
  }) do
    cache:write(path, "complete")
  end
  cache:writeLua(MapAssetCache.worldPath(), { maps = { { id = 7 } } })
  return cache
end

local function snapshot(backend)
  local copy = {}
  for path, data in pairs(backend.files) do
    copy[path] = data
  end
  return copy
end

function T.availability_requires_an_identity_and_an_inventory()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  Assert.isFalse(pcall(DerivedCacheAudit.isAvailable, cache))
  Assert.isFalse(pcall(DerivedCacheAudit.isAvailable, cache, newFacts(), IDENTITY))
end

-- Without any committed fact the walk refuses the first canonical job and
-- writes nothing.
function T.an_empty_cache_is_unavailable_and_names_its_first_job()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local before = snapshot(backend)
  local available, reason = DerivedCacheAudit.isAvailable(cache, newFacts(), IDENTITY, minimalPlans())
  Assert.isFalse(available)
  Assert.isTrue(
    reason ~= nil and reason:find("actors:global", 1, true) ~= nil,
    "the failure names the first exact job, got: " .. tostring(reason)
  )
  Assert.deepEqual(snapshot(backend), before, "a read-only audit performs no writes")
end

function T.markers_alone_never_prove_usability()
  local cache = publishedMarkers()
  local available, reason = DerivedCacheAudit.isAvailable(cache, newFacts(), IDENTITY, minimalPlans())
  Assert.isFalse(available, "markers without committed facts must not read usable")
  Assert.isTrue(reason ~= nil and reason ~= "", "a refused proof names its cause")
end

-- The audit never consults the attestation file itself: with a mismatching
-- attestation on disk, the failure names the missing fact instead.
function T.a_stale_attestation_is_never_consulted()
  local DerivedCacheState = require("romdump.src.DerivedCacheState")
  local cache = publishedMarkers()
  cache:writeLua(DerivedCacheState.path, {
    schema = DerivedCacheState.schema,
    versionId = "heartgold",
    romSha1 = string.rep("a", 40),
    mode = "development",
    producerId = "d" .. string.rep("1", 64),
    assetRevision = 11,
    scriptApi = 1,
    generationId = "stale-generation",
  })
  local available, reason = DerivedCacheAudit.isAvailable(cache, newFacts(), IDENTITY, minimalPlans())
  Assert.isFalse(available)
  assert(reason, "a refused proof names its cause")
  Assert.isTrue(reason:find("has no committed artifact fact", 1, true) ~= nil, tostring(reason))
  Assert.isNil(reason:find("build.lua", 1, true), "the attestation is never evidence: " .. tostring(reason))
end

-- A malformed inventory is unavailable data, not a programming fault that
-- escapes the read-only boundary.
function T.a_malformed_inventory_is_unavailable()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local available, reason = DerivedCacheAudit.isAvailable(cache, newFacts(), IDENTITY, {})
  Assert.isFalse(available)
  Assert.isTrue(reason ~= nil and reason ~= "", "a refused proof names its cause")
end

-- A declared leaf without a committed fact refuses that exact leaf and writes
-- nothing; a present-but-rejected payload still refuses the same leaf; a fully
-- committed and validated inventory passes even with a mismatching attestation
-- on disk, which the walk never consults.
function T.a_missing_declared_leaf_is_unavailable_read_only_and_repairable()
  local generationId = "leaf-repair-generation"
  local identity = { versionId = "heartgold", generationId = generationId, producerId = "audit-producer" }
  local facts = newFacts(identity)
  local plans = minimalPlans()
  plans.messageBankIds = { 4 }
  local jobs = assert(ArtifactJobs.completeJobs(plans))
  local target = assert(jobs[#jobs], "the canonical inventory has a last declared leaf")
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  for _, job in ipairs(jobs) do
    if job.jobKey ~= target.jobKey then
      commitFact(facts, job.kind, job.key)
    end
  end
  local realValidate = ArtifactJobs.validate
  local function withValidator(stub, fn)
    ArtifactJobs.validate = stub
    local ok, first, second = pcall(fn)
    ArtifactJobs.validate = realValidate
    if not ok then
      error(first, 0)
    end
    return first, second
  end
  local before = snapshot(backend)
  local available, reason = withValidator(function()
    return true
  end, function()
    return DerivedCacheAudit.isAvailable(cache, facts, identity, plans)
  end)
  Assert.isFalse(available)
  Assert.isTrue(
    reason ~= nil and reason:find(target.jobKey, 1, true) ~= nil,
    "the refusal names the missing leaf, got: " .. tostring(reason)
  )
  Assert.deepEqual(snapshot(backend), before, "a read-only audit performs no writes")

  commitFact(facts, target.kind, target.key)
  local stillUnavailable, payloadReason = withValidator(function(_, _, kind, key)
    if kind == target.kind and key == target.key then
      return false
    end
    return true
  end, function()
    return DerivedCacheAudit.isAvailable(cache, facts, identity, plans)
  end)
  Assert.isFalse(stillUnavailable)
  Assert.isTrue(
    payloadReason ~= nil and payloadReason:find(target.jobKey, 1, true) ~= nil,
    "the refusal names the invalid leaf, got: " .. tostring(payloadReason)
  )
  local accepted = withValidator(function()
    return true
  end, function()
    return DerivedCacheAudit.isAvailable(cache, facts, identity, plans)
  end)
  Assert.isTrue(accepted, "a fully committed and validated inventory is usable")
end

-- The explicit audit stays deeper than ordinary reuse: every fact is current
-- so ordinary reuse would trust each job, yet one unusable payload still fails
-- the diagnostic without repairing anything.
function T.a_committed_fact_with_an_unusable_payload_still_fails_the_explicit_audit()
  local generationId = "trusted-but-damaged-generation"
  local identity = { versionId = "heartgold", generationId = generationId, producerId = "audit-producer" }
  local facts = newFacts(identity)
  local plans = minimalPlans()
  local jobs = assert(ArtifactJobs.completeJobs(plans))
  local target = assert(jobs[1], "the canonical inventory is never empty")
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  for _, job in ipairs(jobs) do
    commitFact(facts, job.kind, job.key)
  end
  local realValidate = ArtifactJobs.validate
  ArtifactJobs.validate = function(_, _, kind, key)
    if kind == target.kind and key == target.key then
      return false
    end
    return true
  end
  local before = snapshot(backend)
  local ok, available, reason = pcall(DerivedCacheAudit.isAvailable, cache, facts, identity, plans)
  ArtifactJobs.validate = realValidate
  Assert.isTrue(ok, "the explicit audit resolves: " .. tostring(available))
  Assert.isFalse(available, "the explicit audit still detects the damaged payload")
  Assert.isTrue(
    reason ~= nil and reason:find(target.jobKey, 1, true) ~= nil,
    "the refusal names the damaged leaf, got: " .. tostring(reason)
  )
  Assert.deepEqual(snapshot(backend), before, "a read-only audit performs no writes")
end

-- The explicit audit validates real published payload semantics, not just
-- facts: a message bank that is missing or unreadable behind a committed fact
-- fails the walk until its exact payload is restored.
function T.a_corrupt_real_payload_fails_the_explicit_audit()
  local generationId = "real-payload-generation"
  local identity = { versionId = "heartgold", generationId = generationId, producerId = "audit-producer" }
  local facts = newFacts(identity)
  local plans = minimalPlans()
  plans.messageBankIds = { 4 }
  local jobs = assert(ArtifactJobs.completeJobs(plans))
  local target
  for _, job in ipairs(jobs) do
    if job.kind == "message-bank" and job.key == "4" then
      target = job
    end
  end
  assert(target, "the canonical inventory carries the demanded bank")
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  for _, job in ipairs(jobs) do
    commitFact(facts, job.kind, job.key)
  end
  local realValidate = ArtifactJobs.validate
  local function audit()
    ArtifactJobs.validate = function(cacheFs, factMap, kind, key, sessionPlans, expectedIdentity)
      if kind == target.kind and key == target.key then
        return realValidate(cacheFs, factMap, kind, key, sessionPlans, expectedIdentity)
      end
      return true
    end
    local ok, available, reason = pcall(DerivedCacheAudit.isAvailable, cache, facts, identity, plans)
    ArtifactJobs.validate = realValidate
    Assert.isTrue(ok, "the explicit audit resolves: " .. tostring(available))
    return available, reason
  end

  local available, reason = audit()
  Assert.isFalse(available, "a missing real payload fails the audit")
  Assert.isTrue(
    reason ~= nil and reason:find(target.jobKey, 1, true) ~= nil,
    "the refusal names the missing payload, got: " .. tostring(reason)
  )

  cache:write(FieldMessageCache.bankPath(4), "return {")
  local corrupt, corruptReason = audit()
  Assert.isFalse(corrupt, "a corrupt real payload fails the audit")
  Assert.isTrue(
    corruptReason ~= nil and corruptReason:find(target.jobKey, 1, true) ~= nil,
    "the refusal names the corrupt payload, got: " .. tostring(corruptReason)
  )

  FieldMessageFixture.write(cache, 4, { { FieldMessageFixture.glyph(0x0141, "first"), FieldMessageFixture.eos() } })
  local restored = audit()
  Assert.isTrue(restored, "the restored real payload makes the job usable")
end

return { tests = T }
