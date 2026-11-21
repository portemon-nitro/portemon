-- AudioCacheWriter contract: each audio job stages its own private output
-- through a caller-owned artifact — the catalog owns the runtime index, a bank
-- closure owns its bank and sequence records plus its shared sample payloads,
-- and the family summary owns only its marker. Staging validates its own
-- closure before it returns a marker, and the explicit audit walks the same
-- cross-file relations over whatever is published.

local Assert = require("tests.support.Assert")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local AudioCacheValidator = require("libs.assets.src.audio.AudioCacheValidator")
local AudioCacheWriter = require("romdump.src.digest.audio.AudioCacheWriter")
local ArtifactState = require("romdump.src.build.ArtifactState")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local AudioFixture = require("tests.support.AudioFixture")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local ResidentArtifactFixture = require("tests.support.ResidentArtifactFixture")

local T = {}

local GENERATION = "audio-catalog-generation"

local function catalogPlan(bundle)
  return {
    index = bundle.index,
    bankPlans = { { bankId = 12, sequenceIds = { 0, 37 } } },
  }
end

local function soundIdentity()
  return { romSha1 = "rom-sha", sdatSha1 = "archive-sha", sdatFileId = 13 }
end

local function catalogArtifact(cache)
  return PreparedArtifact.new({
    cacheFs = cache,
    generationId = GENERATION,
    epoch = 1,
    kind = "audio-catalog",
    key = "global",
    jobKey = "audio-catalog:global",
  })
end

local function versionCache()
  return CacheFs.forVersion("heartgold", FakeCache.new())
end

-- The writer publishes the index, every indexed sequence and bank, every
-- sample payload with its metadata, and the class then passes the
-- authoritative walk.

-- The bundle shape is required; a missing section is a programming fault,
-- never an empty default.

-- Samples are content-addressed: several bank voices sharing one key produce
-- exactly one payload and one metadata file.

-- A published closure passes the authoritative walk, and the explicit audit
-- reports every malformed cross-file relation: an unknown sequence reference,
-- a sequence whose bank id does not resolve, a bank sample reference without
-- metadata, a sample payload whose byte count disagrees with its metadata, a
-- mis-keyed metadata record, and a sequence record that fails its own schema.
T["a published family passes the walk and the audit reports malformed relations"] = function()
  local complete = AudioFixture.readyCache(AudioFixture.bundle())
  Assert.isNil(AudioCacheValidator.validate(complete), "the complete published family passes the walk")
  local relations = {
    {
      name = "unknown sequence reference",
      breakBundle = function(bundle)
        bundle.sequences[37] = nil
      end,
    },
    {
      name = "sequence bank id does not resolve",
      breakBundle = function(bundle)
        bundle.index.sequences[37].bankId = 99
      end,
    },
    {
      name = "bank sample reference without metadata",
      breakBundle = function(bundle)
        bundle.banks[12].instruments[0].voice.generator.sample = AudioFixture.key(99)
      end,
    },
    {
      name = "sample payload byte count mismatch",
      breakBundle = function(bundle)
        local key = AudioFixture.key(1)
        bundle.samples[key] = bundle.samples[key] .. "\0"
      end,
    },
    {
      name = "sample metadata key does not match its address",
      breakBundle = function(bundle)
        bundle.sampleMetadata[AudioFixture.key(1)].key = AudioFixture.key(2)
      end,
    },
    {
      name = "sequence record without its program",
      breakBundle = function(bundle)
        bundle.sequences[37].program = nil
      end,
    },
  }
  for _, relation in ipairs(relations) do
    local broken = AudioFixture.bundle()
    relation.breakBundle(broken)
    Assert.notNil(
      AudioCacheValidator.validate(AudioFixture.readyCache(broken)),
      relation.name .. " is reported by the explicit audit"
    )
  end
end

-- The catalog stages the runtime index apart from every bank payload: the
-- staged index passes catalog validation while the full audio family is still
-- incomplete, and the runtime provider constructs from the staged index alone.
T["stageCatalog publishes the runtime index before any bank closure"] = function()
  local bundle = AudioFixture.bundle()
  local cache = versionCache()
  local artifact = catalogArtifact(cache)
  local marker = AudioCacheWriter.stageCatalog(artifact, catalogPlan(bundle), soundIdentity())
  Assert.equal(type(marker), "string", "catalog staging returns its marker")
  local stage = artifact
  Assert.isNil(
    AudioCacheValidator.validateCatalog(stage:loadLua(AudioCache.indexPath())),
    "the staged index passes catalog validation"
  )
  Assert.notNil(AudioCacheValidator.validate(stage), "a catalog alone is never a complete audio family")
  local AudioAssetProvider = require("libs.hgss.src.audio.AudioAssetProvider")
  Assert.notNil(AudioAssetProvider.new(stage), "the runtime provider constructs from the catalog stage")
  artifact:abort()
end

-- The family summary owns no payload and never republishes the runtime index:
-- it hashes the catalog receipt marker into one marker for its own receipt,
-- which the caller has already gated on the current bank and catalog
-- receipts.
T["stageSummary owns only its receipt"] = function()
  local bundle = AudioFixture.bundle()
  local cache = versionCache()
  local plan = catalogPlan(bundle)
  local identity = soundIdentity()
  local catalogMarker = AudioCacheWriter.catalogMarker(plan, identity)
  local marker = AudioCacheWriter.summaryMarker(plan, catalogMarker)
  Assert.equal(AudioCacheWriter.summaryMarker(plan, catalogMarker), marker, "the summary marker is deterministic")
  local otherIdentity = { romSha1 = "other-rom", sdatSha1 = "archive-sha", sdatFileId = 13 }
  local otherMarker = AudioCacheWriter.summaryMarker(plan, AudioCacheWriter.catalogMarker(plan, otherIdentity))
  Assert.isTrue(otherMarker ~= marker, "the summary marker binds the adopted source identity through the catalog")
  local summary = PreparedArtifact.new({
    cacheFs = cache,
    generationId = GENERATION,
    epoch = 1,
    kind = "audio-summary",
    key = "global",
    jobKey = "audio-summary:global",
  })
  Assert.equal(
    AudioCacheWriter.stageSummary(summary, plan, catalogMarker),
    marker,
    "summary staging returns its marker"
  )
  Assert.isNil(summary:loadLua(AudioCache.indexPath()), "the summary never republishes the catalog index")
  local sealed = summary:finishSuccess({ marker = marker })
  Assert.deepEqual(sealed.ownedRoots, {}, "the summary owns no payload root")
  Assert.deepEqual(sealed.entries, {}, "the summary stages no payload of its own")
  local facts = ArtifactState.new(GENERATION)
  ResidentArtifactFixture.commitFact(facts, sealed)
  local fact = ArtifactState.read(facts, "audio-summary", "global")
  Assert.notNil(fact, "the summary commits its current fact")
  Assert.equal(fact.marker, marker, "the fact carries the summary marker")
end

return { tests = T }
