-- AudioAssetProvider contract: the runtime owner of the generated audio cache.
-- It loads the index eagerly at construction, resolves sequences/banks by
-- numeric id or per-class symbol map (sequenceBySymbol/bankBySymbol), and
-- loads sequence/bank/sample assets lazily and memoized. The cache is a
-- trusted runtime input (the readiness walk validates the whole cache at
-- build time), so load-time content re-validation is not part of the
-- provider contract -- missing, unreadable, or malformed files are, and stay
-- structured failures. Samples arrive as metadata plus one packed PCM16
-- sample, packed exactly once per key. The contract is authored against
-- hand-written project-owned synthetic assets; nothing
-- here touches a ROM. Loading policy: index eager, sequence/bank/
-- sample descriptors lazy + memoized, loaded assets stay cached for the
-- process lifetime.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local AudioFixture = require("tests.support.AudioFixture")
local FakeCache = require("tests.support.FakeCache")
local AudioAssetProvider = require("libs.hgss.src.audio.AudioAssetProvider")

local T = {}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code)
end

local function provider(bundle)
  local cache = AudioFixture.readyCache(bundle)
  return AudioAssetProvider.new(cache), cache
end

-- A backend proxy counting every read by version-relative path (the backend
-- sees version-prefixed full paths, but the assertions count with
-- AudioCache's relative paths), so lazy+memoized loading is observable: an
-- asset is read exactly once no matter how often it is asked for, and never
-- read until it is asked for.
local function countingBackend(backend)
  local reads = {}
  local proxy = setmetatable({}, {
    __index = function(_, key)
      if key == "read" then
        return function(_, path)
          local relative = path:gsub("^[^/]+/", "")
          reads[relative] = (reads[relative] or 0) + 1
          return backend:read(path)
        end
      end
      return backend[key]
    end,
  })
  proxy.reads = reads
  return proxy
end

function T.constructs_from_a_ready_cache_and_resolves_ids_and_symbols()
  local p = provider(AudioFixture.bundle())
  local sequence = p:sequence(0)
  Assert.equal(sequence.schema, AudioCache.SEQUENCE_SCHEMA)
  Assert.equal(sequence.id, 0)
  Assert.equal(p:sequence("SEQ_TEST_A"), sequence, "symbol resolution shares the memoized asset")
  Assert.equal(p:sequence(37).symbol, "SEQ_TEST_B")
  Assert.equal(p:sequence("SEQ_TEST_B").id, 37)
  local bank = p:bank(12)
  Assert.equal(bank.schema, AudioCache.BANK_SCHEMA)
  Assert.equal(bank.id, 12)
  Assert.equal(p:bank("BANK_TEST"), bank, "symbol resolution shares the memoized asset")
  Assert.equal(p:player(1).channelMask, 0xFFFF)
  Assert.equal(p:player(1).maxSequences, 16)
end

-- Symbols resolve per asset class: the same symbol may name a sequence and
-- a bank, and each lookup walks its own map, so a cross-class collision is
-- never ambiguous.
function T.symbol_collisions_across_classes_resolve_per_class()
  local bundle = AudioFixture.bundle()
  bundle.index.sequences[37].symbol = "SHARED"
  bundle.index.banks[12].symbol = "SHARED"
  bundle.index.sequenceBySymbol.SHARED = 37
  bundle.index.bankBySymbol.SHARED = 12
  bundle.sequences[37].symbol = "SHARED"
  bundle.banks[12].symbol = "SHARED"
  local p = provider(bundle)
  Assert.equal(p:sequence("SHARED").id, 37)
  Assert.equal(p:bank("SHARED").id, 12)
end

function T.unknown_references_raise_structured_errors()
  local p = provider(AudioFixture.bundle())
  throwsCode("AUDIO_PROVIDER_SEQUENCE_UNKNOWN", function()
    p:sequence(99)
  end)
  throwsCode("AUDIO_PROVIDER_SEQUENCE_UNKNOWN", function()
    p:sequence("SEQ_MISSING")
  end)
  throwsCode("AUDIO_PROVIDER_BANK_UNKNOWN", function()
    p:bank(99)
  end)
  throwsCode("AUDIO_PROVIDER_PLAYER_UNKNOWN", function()
    p:player(99)
  end)
end

function T.samples_load_by_content_key_with_metadata_and_decoded_pcm()
  local p = provider(AudioFixture.bundle())
  local key = AudioFixture.key(1)
  local sample = p:loadSample(key)
  Assert.equal(sample.metadata.key, key)
  Assert.equal(sample.metadata.schema, AudioCache.SAMPLE_SCHEMA)
  Assert.equal(sample.pcm.frames, 4, "the packed sample counts frames, not array length")
  local frames = {}
  for index = 0, sample.pcm.frames - 1 do
    frames[#frames + 1] = sample.pcm:read(index)
  end
  Assert.deepEqual(frames, { 1000, 2000, 3000, 4000 }, "the provider hands over the packed PCM sample")
end

function T.unknown_sample_keys_and_missing_payloads_fail()
  local bundle = AudioFixture.bundle()
  local p, cache = provider(bundle)
  throwsCode("AUDIO_PROVIDER_SAMPLE_UNKNOWN", function()
    p:loadSample(AudioFixture.key(99))
  end)
  cache:remove(AudioCache.samplePath(AudioFixture.key(1)))
  throwsCode("AUDIO_PROVIDER_SAMPLE_UNKNOWN", function()
    p:loadSample(AudioFixture.key(1))
  end)
end

function T.loading_is_lazy_and_memoized()
  local backend = countingBackend(FakeCache.new())
  local counted = AudioFixture.readyCache(AudioFixture.bundle(), backend)
  local baseline = {}
  for path, reads in pairs(backend.reads) do
    baseline[path] = reads
  end
  local p = AudioAssetProvider.new(counted)
  local reads = backend.reads
  local function count(path)
    return (reads[path] or 0) - (baseline[path] or 0)
  end
  Assert.equal(count(AudioCache.indexPath()), 1, "the index loads once, eagerly")
  local sequence = p:sequence(0)
  Assert.equal(count(AudioCache.sequencePath(0)), 1, "the sequence loads on first access")
  Assert.equal(p:sequence(0), sequence, "memoized: same table, no second read")
  Assert.equal(count(AudioCache.sequencePath(0)), 1)
  local bank = p:bank(12)
  Assert.equal(count(AudioCache.bankPath(12)), 1, "the bank loads on first access")
  Assert.equal(p:bank(12), bank)
  Assert.equal(count(AudioCache.bankPath(12)), 1)
  local key = AudioFixture.key(1)
  local first = p:loadSample(key)
  local second = p:loadSample(key)
  Assert.equal(type(first.pcm), "table", "the provider packs the payload once")
  Assert.isTrue(second.pcm == first.pcm, "the decoded array is shared; loading twice decodes once")
  Assert.equal(count(AudioCache.sampleMetadataPath(key)), 1, "sample metadata is read once")
  Assert.equal(count(AudioCache.samplePath(key)), 1, "the PCM payload is read once")
  Assert.equal(count(AudioCache.sequencePath(37)), 0, "unrequested assets are never read")
  Assert.equal(count(AudioCache.bankPath(12)), 1)
end

function T.missing_or_malformed_index_fails_construction()
  throwsCode("AUDIO_PROVIDER_INDEX_UNAVAILABLE", function()
    local cache = AudioFixture.readyCache(AudioFixture.bundle())
    cache:remove(AudioCache.indexPath())
    AudioAssetProvider.new(cache)
  end)
  throwsCode("AUDIO_PROVIDER_INDEX_UNAVAILABLE", function()
    local bundle = AudioFixture.bundle()
    bundle.index.schema = "g4-audio-index-wrong"
    AudioAssetProvider.new(AudioFixture.readyCache(bundle))
  end)
end

-- Idle retention for decoded samples: the shared lease kernel holds one entry
-- per sample key at its real packed byte cost, the mixer liveness query
-- shields the sounding sample through a zero-byte idle budget, and the
-- shielded voice still renders its exact frames. Stopping the voice lifts the
-- shield so the next trim takes the sample, while the provider keeps serving
-- its one packed backing per key instead of decoding a duplicate. The kernel
-- module is required lazily so this scenario fails on the missing ownership
-- behavior rather than failing the suite load.
function T.active_samples_survive_a_zero_idle_budget_and_reload_after_stop()
  local ok, ResidentAssetCache = pcall(require, "libs.hgss.src.field.ResidentAssetCache")
  Assert.isTrue(
    ok and type(ResidentAssetCache) == "table",
    "bounded sample retention needs the shared idle lease kernel"
  )
  local VoiceMixer = require("libs.nds.src.nitro.sound.VoiceMixer")
  local p = provider(AudioFixture.bundle())
  local firstKey = AudioFixture.key(1)
  local secondKey = AudioFixture.key(2)
  local first = p:loadSample(firstKey)
  local second = p:loadSample(secondKey)
  Assert.isNil(first.pcm[1], "a retained sample is a packed buffer, never a one-based frame table")
  Assert.equal(first.pcm.frames, 4, "the first fixture sample carries four packed frames")
  Assert.equal(second.pcm.frames, 2, "the second fixture sample carries two packed frames")

  local released = {}
  local mixer = VoiceMixer.new({ sampleRate = 16756991 })
  local retained = ResidentAssetCache.new({
    idleByteLimit = 0,
    release = function(value)
      released[#released + 1] = value
    end,
    busy = function(value)
      return mixer:isSampleActive(value.pcm)
    end,
  })
  retained:publish(firstKey, first, first.pcm.frames * 2)
  retained:publish(secondKey, second, second.pcm.frames * 2)
  local handle = mixer:noteOn({
    generator = { kind = "sample", sample = firstKey },
    pcm = first.pcm,
    baseTimer = first.metadata.baseTimer,
    loop = first.metadata.loop,
    loopEnabled = first.metadata.loopEnabled,
    key = 60,
    originalKey = 60,
    velocity = 127,
    trackVolume = 127,
    expression = 127,
    sequenceVolume = 127,
    envelope = { attack = 127, decay = 127, sustain = 127, release = 127 },
    pan = 0,
    channelMask = 0xFFFF,
    trackPriority = 64,
    channelPriority = 64,
  })
  Assert.notNil(handle, "the guard voice starts on the first sample")
  mixer:controlStep()
  retained:trim()
  Assert.equal(#released, 1, "a zero idle budget releases only the sample no voice sounds")
  Assert.isTrue(released[1] == second, "the released sample is the idle one")
  Assert.isTrue(retained:find(firstKey) == first, "the sounding sample survives the trim")
  Assert.isTrue(mixer:isSampleActive(first.pcm), "the mixer still sounds the surviving sample")
  local out = mixer:render(2)
  Assert.deepEqual(out, { 1000, 0, 1000, 0 }, "the surviving voice renders its exact packed frames")
  mixer:stopVoice(handle)
  Assert.isFalse(mixer:isSampleActive(first.pcm), "the stopped voice drops the sample")
  retained:trim()
  Assert.equal(#released, 2, "the stopped sample becomes evictable")
  Assert.isTrue(released[2] == first, "the evicted sample is the stopped one")
  Assert.isNil(retained:find(firstKey), "the evicted sample leaves the retention set")
  local again = p:loadSample(firstKey)
  Assert.isTrue(again == first, "the provider still serves one memoized sample per key")
  Assert.isTrue(again.pcm == first.pcm, "no duplicate backing appears for the reloaded key")
end

return { tests = T }
