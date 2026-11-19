-- AudioCacheWriter contract: one staged transaction per class — index,
-- sequences, banks, unique content-addressed sample payloads/metadata,
-- readback validation of shape and references, then publish. Completion is
-- the producer job receipt, so the writer emits no marker of its own. A
-- failed rebuild must never destroy a previously usable audio cache; publish
-- failures keep the stage as recovery material.

local Assert = require("tests.support.Assert")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local AudioCacheValidator = require("libs.assets.src.audio.AudioCacheValidator")
local AudioCacheWriter = require("romdump.src.digest.audio.AudioCacheWriter")
local ArtifactState = require("romdump.src.build.ArtifactState")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local AudioFixture = require("tests.support.AudioFixture")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")

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

local function catalogArtifact(cache, stageName)
  return PreparedArtifact.new({
    cacheFs = cache,
    generationId = GENERATION,
    epoch = 1,
    kind = "audio-catalog",
    key = "global",
    jobKey = "audio-catalog:global",
    stageName = stageName or "audio-catalog",
  })
end

local function versionCache()
  return CacheFs.forVersion("heartgold", FakeCache.new())
end

-- The writer publishes the index, every indexed sequence and bank, every
-- sample payload with its metadata, and the class then passes the
-- authoritative walk.
T["write publishes index assets and samples"] = function()
  local cache = versionCache()
  local bundle = AudioFixture.bundle()
  Assert.isTrue(AudioCacheWriter.write(cache, bundle))
  local index = cache:loadLua(AudioCache.indexPath())
  index = index --[[@as { schema: string, version: string }]]
  Assert.equal(index.schema, AudioCache.INDEX_SCHEMA)
  Assert.equal(index.version, "heartgold")
  local sequence = cache:loadLua(AudioCache.sequencePath(0))
  sequence = sequence --[[@as { schema: string, id: integer }]]
  Assert.equal(sequence.schema, AudioCache.SEQUENCE_SCHEMA)
  Assert.equal(sequence.id, 0)
  local bank = cache:loadLua(AudioCache.bankPath(12))
  bank = bank --[[@as { schema: string, id: integer }]]
  Assert.equal(bank.schema, AudioCache.BANK_SCHEMA)
  Assert.equal(bank.id, 12)
  local key = AudioFixture.key(1)
  Assert.equal(cache:read(AudioCache.samplePath(key)), AudioFixture.pcm16le({ 1000, 2000, 3000, 4000 }))
  local metadata = cache:loadLua(AudioCache.sampleMetadataPath(key))
  metadata = metadata --[[@as { schema: string, key: string }]]
  Assert.equal(metadata.schema, AudioCache.SAMPLE_SCHEMA)
  Assert.equal(metadata.key, key)
  Assert.isNil(AudioCacheValidator.validate(cache), "the published audio cache passes the authoritative walk")
end

-- The bundle shape is required; a missing section is a programming fault,
-- never an empty default.
T["write requires the full bundle shape"] = function()
  local cache = versionCache()
  local bundle = AudioFixture.bundle()
  Assert.throws(function()
    AudioCacheWriter.write(cache, {
      marker = bundle.marker,
      index = bundle.index,
      sequences = bundle.sequences,
      banks = bundle.banks,
      samples = bundle.samples,
    })
  end, "sampleMetadata is a required bundle section")
  Assert.throws(function()
    AudioCacheWriter.write(cache, {
      index = bundle.index,
      sequences = bundle.sequences,
      banks = bundle.banks,
      samples = bundle.samples,
      sampleMetadata = bundle.sampleMetadata,
    })
  end, "marker is a required bundle section")
end

-- Samples are content-addressed: several bank voices sharing one key produce
-- exactly one payload and one metadata file.
T["shared sample keys are written once"] = function()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local bundle = AudioFixture.bundle()
  bundle.banks[12].instruments[0].voice.generator.sample = AudioFixture.key(2)
  Assert.isTrue(AudioCacheWriter.write(cache, bundle))
  local payloads = backend:getDirectoryItems("heartgold/data/generated/audio/samples")
  Assert.deepEqual(payloads, { AudioFixture.key(1) .. ".pcm16le", AudioFixture.key(2) .. ".pcm16le" })
  local metadata = backend:getDirectoryItems("heartgold/data/generated/audio/sample-metadata")
  Assert.deepEqual(metadata, { AudioFixture.key(1) .. ".lua", AudioFixture.key(2) .. ".lua" })
end

-- Readback validates every reference: a sequence whose bank id does not
-- resolve into the staged index fails the write and leaves no partial cache.
T["unresolvable sequence bank reference rolls back"] = function()
  local cache = versionCache()
  local bundle = AudioFixture.bundle()
  bundle.index.sequences[37].bankId = 99
  Assert.throws(function()
    AudioCacheWriter.write(cache, bundle)
  end)
  Assert.isNil(cache:read(AudioCache.indexPath()), "a failed write leaves no live index")
end

-- The readback runs the asset validators: a malformed sequence fails the
-- write with a full rollback.
T["sequence content is validated at the write boundary"] = function()
  local cache = versionCache()
  local bundle = AudioFixture.bundle()
  bundle.sequences[37].program = nil
  Assert.throws(function()
    AudioCacheWriter.write(cache, bundle)
  end)
  Assert.isNil(cache:read(AudioCache.indexPath()))
end

T["sample metadata is validated at the write boundary"] = function()
  local cache = versionCache()
  local bundle = AudioFixture.bundle()
  bundle.sampleMetadata[AudioFixture.key(1)].key = AudioFixture.key(9)
  Assert.throws(function()
    AudioCacheWriter.write(cache, bundle)
  end)
  Assert.isNil(cache:read(AudioCache.indexPath()))
end

-- A metadata record whose key does not match its address is a mis-keyed
-- bundle even when the record itself is self-consistent: the payload address
-- and the record identity must agree.
T["sample metadata key must match its address"] = function()
  local cache = versionCache()
  local bundle = AudioFixture.bundle()
  local keyA, keyB = AudioFixture.key(1), AudioFixture.key(2)
  bundle.sampleMetadata[keyA].key = keyB
  Assert.throws(function()
    AudioCacheWriter.write(cache, bundle)
  end)
  Assert.isNil(cache:read(AudioCache.indexPath()))
end

-- The staged write gate and the explicit audit are one rule set: every
-- malformed cross-file relation must fail the staged write AND be reported by
-- the authoritative walk. No second inspection vocabulary may drift from the
-- staging gate.
T["readback and explicit audit agree on malformed cross-file relations"] = function()
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
  }
  for _, relation in ipairs(relations) do
    local broken = AudioFixture.bundle()
    relation.breakBundle(broken)
    Assert.throws(function()
      AudioCacheWriter.write(versionCache(), broken)
    end, relation.name .. " fails the write")
    Assert.notNil(
      AudioCacheValidator.validate(AudioFixture.readyCache(broken)),
      relation.name .. " is reported by the explicit audit"
    )
  end
end

-- A failed rebuild leaves the previous cache untouched, the stage clean,
-- and a retry publishes the new artifact.
T["failed rebuild preserves the previous audio artifact"] = function()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  AudioCacheWriter.write(cache, AudioFixture.bundle())
  local original = backend.write
  backend.write = function(self, path, data)
    if path:find(".pcm16le", 1, true) then
      error("injected write failure")
    end
    return original(self, path, data)
  end
  local second = AudioFixture.bundle()
  second.index.banks[12].symbol = "BANK_TEST_NEW"
  second.index.bankBySymbol = { ["BANK_TEST_NEW"] = 12 }
  second.banks[12].symbol = "BANK_TEST_NEW"
  Assert.throws(function()
    AudioCacheWriter.write(cache, second)
  end)
  Assert.isNil(AudioCacheValidator.validate(cache), "the previous artifact stays complete")
  local previousBank = cache:loadLua(AudioCache.bankPath(12))
  previousBank = previousBank --[[@as { symbol: string }]]
  Assert.equal(previousBank.symbol, "BANK_TEST", "the failed write never replaced a live payload")
  Assert.isNil(backend:getInfo("staging/heartgold/audio"), "the stage is cleaned on failure")
  backend.write = original
  AudioCacheWriter.write(cache, second)
  Assert.isNil(AudioCacheValidator.validate(cache), "a retry publishes the complete artifact")
  local publishedBank = cache:loadLua(AudioCache.bankPath(12))
  publishedBank = publishedBank --[[@as { symbol: string }]]
  Assert.equal(publishedBank.symbol, "BANK_TEST_NEW", "the retry publishes the new payload")
  Assert.isNil(backend:getInfo("staging/heartgold/audio"), "the stage is cleaned on success")
end

-- A rename failure after publish begins must not trigger writer-level stage
-- cleanup: the adjacent old root remains recovery material.
T["publish failure keeps the stage with recovery material"] = function()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  AudioCacheWriter.write(cache, AudioFixture.bundle())
  local liveBank = cache:read(AudioCache.bankPath(12))
  local originalReplace = backend.replace
  backend.replace = function(self, sourcePath, destinationPath)
    local nextPrefix = "heartgold/" .. AudioCache.dir() .. ".__g4next."
    local oldPrefix = "heartgold/" .. AudioCache.dir() .. ".__g4old."
    if sourcePath:sub(1, #nextPrefix) == nextPrefix or sourcePath:sub(1, #oldPrefix) == oldPrefix then
      return false, "injected publish failure"
    end
    return originalReplace(self, sourcePath, destinationPath)
  end
  local second = AudioFixture.bundle()
  second.marker = AudioCache.marker("rom-sha", "new-dep-sha")
  local err = Assert.throws(function()
    AudioCacheWriter.write(cache, second)
  end)
  Assert.equal(err.code, "CACHE_PUBLISH_ROLLBACK_INCOMPLETE")
  Assert.notNil(backend:getInfo("staging/heartgold/audio"), "the stage is not removed once publish has begun")
  local oldPrefix = "heartgold/" .. AudioCache.dir() .. ".__g4old."
  local oldBank
  for path, data in pairs(backend.files) do
    if path:sub(1, #oldPrefix) == oldPrefix and path:sub(-#"/banks/0012.lua") == "/banks/0012.lua" then
      oldBank = data
    end
  end
  Assert.equal(oldBank, liveBank, "the last-known-good audio class stays in the stage as recovery material")
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
  local stage = artifact:stageFs()
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
    stageName = "audio-summary",
  })
  Assert.equal(
    AudioCacheWriter.stageSummary(summary, plan, catalogMarker),
    marker,
    "summary staging returns its marker"
  )
  Assert.isNil(summary:stageFs():loadLua(AudioCache.indexPath()), "the summary never republishes the catalog index")
  summary:finishSuccess({ marker = marker })
  Assert.deepEqual(
    summary:manifest().ownedRoots,
    { ArtifactState.path("audio-summary", "global") },
    "the summary owns exactly its generation receipt"
  )
  summary:publish({
    generationId = GENERATION,
    epoch = 1,
    kind = "audio-summary",
    key = "global",
    jobKey = "audio-summary:global",
  })
  local receipt = ArtifactState.read(cache, GENERATION, "audio-summary", "global")
  Assert.notNil(receipt, "the summary publishes its current receipt")
  Assert.equal(receipt.marker, marker, "the receipt carries the summary marker")
end

return { tests = T }
