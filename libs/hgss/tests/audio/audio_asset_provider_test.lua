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
local AssetPreparationQueue = require("libs.hgss.src.presentation.AssetPreparationQueue")
local CacheFs = require("libs.storage.src.CacheFs")
local ResidentAssetCache = require("libs.hgss.src.field.ResidentAssetCache")
local ResidentCache = require("libs.storage.src.ResidentCache")

local T = {}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code)
end

-- The selected runtime's base source boundary: one lease roots the store's own
-- bytes, and its release clears that reference.
---@param cacheFs CacheFs
---@return { acquireSource: fun(reference: table): table }
local function sourceAcquirer(cacheFs)
  return {
    acquireSource = function(reference)
      local lease = { value = reference.data }
      function lease:release()
        self.value = nil
      end
      return lease
    end,
  }
end

---@param bundle AudioFixture.Bundle?
---@return AudioAssetProvider provider
---@return CacheFs reader
local function provider(bundle)
  local cache, store = AudioFixture.residentCache(bundle)
  return AudioAssetProvider.new(cache, sourceAcquirer(cache)), cache, store
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
  local lease = p:acquireSample(key)
  local sample = assert(lease.value)
  Assert.equal(sample.metadata.key, key)
  Assert.equal(sample.metadata.schema, AudioCache.SAMPLE_SCHEMA)
  Assert.equal(sample.pcm.frames, 4, "the packed sample counts frames, not array length")
  local frames = {}
  for index = 0, sample.pcm.frames - 1 do
    frames[#frames + 1] = sample.pcm:read(index)
  end
  Assert.deepEqual(frames, { 1000, 2000, 3000, 4000 }, "the provider hands over the packed PCM sample")
  Assert.isTrue(lease:release(), "the acquisition returns once")
  Assert.isNil(lease.value, "a returned acquisition keeps no sample")
end

function T.unknown_sample_keys_and_missing_payloads_fail()
  local missingPayload = AudioFixture.bundle()
  missingPayload.samples[AudioFixture.key(1)] = nil
  local p = provider(missingPayload)
  throwsCode("AUDIO_PROVIDER_SAMPLE_UNKNOWN", function()
    p:acquireSample(AudioFixture.key(99))
  end)
  throwsCode("AUDIO_PROVIDER_SAMPLE_UNKNOWN", function()
    p:acquireSample(AudioFixture.key(1))
  end)
  Assert.equal(p:status().activeSamples, 0, "a failed acquisition installs no active record")
end

function T.loading_is_lazy_and_memoized()
  local bundle = AudioFixture.bundle()
  local cache = AudioFixture.residentCache(bundle)
  local loads = {}
  local loadLuaOnReader = cache.loadLua
  function cache:loadLua(path)
    loads[path] = (loads[path] or 0) + 1
    return loadLuaOnReader(self, path)
  end
  local p = AudioAssetProvider.new(cache, sourceAcquirer(cache))
  local function count(path)
    return loads[path] or 0
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
  local firstLease = p:acquireSample(key)
  local secondLease = p:acquireSample(key)
  local first = assert(firstLease.value)
  Assert.equal(type(first.pcm), "table", "the provider packs the resident payload once")
  Assert.isTrue(secondLease.value.pcm == first.pcm, "a repeated acquisition shares the decoded backing")
  Assert.equal(count(AudioCache.sampleMetadataPath(key)), 1, "sample metadata is read once")
  Assert.equal(count(AudioCache.sequencePath(37)), 0, "unrequested assets are never read")
  Assert.equal(count(AudioCache.bankPath(12)), 1)
  firstLease:release()
  secondLease:release()
end

function T.missing_or_malformed_index_fails_construction()
  throwsCode("AUDIO_PROVIDER_INDEX_UNAVAILABLE", function()
    local empty = CacheFs.forVersion("heartgold", FakeCache.new())
    AudioAssetProvider.new(empty, sourceAcquirer(empty))
  end)
  throwsCode("AUDIO_PROVIDER_INDEX_UNAVAILABLE", function()
    local bundle = AudioFixture.bundle()
    bundle.index.schema = "g4-audio-index-wrong"
    local cache = AudioFixture.residentCache(bundle)
    AudioAssetProvider.new(cache, sourceAcquirer(cache))
  end)
end

-- Sample ownership follows physical voice lifetime: an acquired sample stays
-- active while its voice sounds, the voice's physical death returns exactly
-- that acquisition, and a later acquisition of the same key borrows the same
-- resident backing instead of decoding a duplicate.
function T.active_samples_follow_voice_lifetime_and_share_one_backing()
  local VoiceMixer = require("libs.nds.src.nitro.sound.VoiceMixer")
  local p = provider(AudioFixture.bundle())
  local firstKey = AudioFixture.key(1)
  local secondKey = AudioFixture.key(2)
  local firstLease = p:acquireSample(firstKey)
  local secondLease = p:acquireSample(secondKey)
  local first = assert(firstLease.value)
  local second = assert(secondLease.value)
  Assert.isNil(first.pcm[1], "an active sample is a packed buffer, never a one-based frame table")
  Assert.equal(first.pcm.frames, 4, "the first fixture sample carries four packed frames")
  Assert.equal(second.pcm.frames, 2, "the second fixture sample carries two packed frames")
  Assert.equal(p:status().activeSamples, 2, "each acquired key is one active record")

  local mixer = VoiceMixer.new({ sampleRate = 16756991 })
  local handle = mixer:noteOn({
    generator = { kind = "sample", sample = firstKey },
    sampleLease = firstLease,
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
  Assert.notNil(handle, "the sounding voice starts on the first sample")
  mixer:controlStep()
  Assert.isTrue(mixer:isSampleActive(first.pcm), "the mixer sounds the acquired sample")
  local out = mixer:render(2)
  Assert.deepEqual(out, { 1000, 0, 1000, 0 }, "the sounding voice renders its exact packed frames")

  secondLease:release()
  Assert.equal(p:status().activeSamples, 1, "returning an idle acquisition drops only its own record")
  Assert.notNil(firstLease.value, "the sounding acquisition stays valid beside the returned one")

  mixer:stopVoice(handle)
  Assert.isNil(firstLease.value, "the physical voice's death returns its acquisition")
  Assert.isFalse(mixer:isSampleActive(first.pcm), "the stopped voice drops the sample")
  Assert.equal(p:status().activeSamples, 0, "no active record survives the final return")

  local again = p:acquireSample(firstKey)
  Assert.isTrue(assert(again.value).pcm.data == first.pcm.data, "a later acquisition borrows the same backing")
  again:release()
  p:dispose()
end

-- The compiled audio bundle as the selected epoch's resident bytes: every
-- logical path the provider resolves already lives in one immutable store, so
-- PCM acquisition can borrow the exact Data the store owns.
local function residentAudioCache(bundle)
  local version = "heartgold"
  local sourceId = "base:audio-fixture"
  local physical = AudioFixture.readyCache(bundle)
  local files = assert(physical.backend.files, "the audio fixture writes through a FakeCache backend")
  local prefix = version .. "/"
  local entries = {}
  for fullPath, value in pairs(files) do
    local text = type(value) == "string" and value or value:getString()
    local path = fullPath:sub(#prefix + 1)
    entries[#entries + 1] = {
      path = path,
      data = assert(love.data.newByteData(text)),
      size = #text,
      sourceId = sourceId,
      contentId = version .. "\0" .. path,
    }
  end
  local store = ResidentCache.new(version, sourceId)
  store:commit(store:prepare(entries))
  return CacheFs.fromStore(store), store
end

-- The production provider over its selected queue: sample acquisition borrows
-- the resident source through acquireSource, that is the same capability the
-- composition injects, so a lease the provider hands out is accountable to the
-- shared owner rather than to a private sample cache.
local function sharedProvider(bundle)
  local cache, store = residentAudioCache(bundle)
  local decoded = ResidentAssetCache.new({ idleByteLimit = 0, release = function() end })
  local queue = AssetPreparationQueue.new(cache, { decoded = decoded })
  local provider = AudioAssetProvider.new(cache, {
    acquireSource = function(reference)
      return queue:acquireSource(reference)
    end,
  })
  return provider, { queue = queue, decoded = decoded, store = store, cache = cache }
end

local function sampleVoiceSpec(lease, key)
  return {
    generator = { kind = "sample", sample = key },
    sampleLease = lease,
    pcm = lease.value.pcm,
    baseTimer = lease.value.metadata.baseTimer,
    loop = lease.value.metadata.loop,
    loopEnabled = lease.value.metadata.loopEnabled,
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
  }
end

-- Two independent mixers sound one resident sample: the acquisition leases
-- share one decoded backing (the store's own bytes), one voice's stop leaves
-- the other sounding, and each physical voice returns exactly one acquisition
-- on its own death. A rejected voice leaves its acquisition with the caller.
function T.two_mixers_share_one_sample_and_return_their_acquisitions_once()
  local VoiceMixer = require("libs.nds.src.nitro.sound.VoiceMixer")
  local bundle = AudioFixture.bundle()
  local key = AudioFixture.key(1)
  bundle.sampleMetadata[key] = AudioFixture.sampleMetadata(key, { frames = 4, loopEnabled = false })
  local provider, runtime = sharedProvider(bundle)
  local resident = assert(runtime.store:readData(AudioCache.samplePath(key)), "the bundle publishes its PCM bytes")

  Assert.equal(
    type(provider.acquireSample),
    "function",
    "sample acquisition must hand out an accountable lease instead of an unleased sample object"
  )
  local first = provider:acquireSample(key)
  local second = provider:acquireSample(key)
  Assert.notNil(first, "the provider hands out a sample lease")
  Assert.notNil(second, "a repeated acquisition hands out its own lease")
  Assert.isTrue(first ~= second, "every acquisition is an independent lease")
  Assert.isTrue(first.value.pcm == second.value.pcm, "both acquisitions share one decoded sample")
  Assert.isTrue(
    first.value.pcm.data == resident,
    "the shared PCM backing is the resident sample bytes, not a second copy"
  )
  local status = provider:status()
  Assert.equal(status.activeSamples, 1, "one active sample record backs both acquisitions")
  Assert.equal(status.activeSourceBytes, resident:getSize(), "active source bytes attribute the resident PCM once")
  Assert.equal(status.acquisitions, 2, "acquisitions count every successful lease")
  Assert.equal(status.misses, 1, "misses count the first active-record construction only")

  local mixerA = VoiceMixer.new({ sampleRate = 16756991 })
  local mixerB = VoiceMixer.new({ sampleRate = 16756991 })
  local handleA = assert(mixerA:noteOn(sampleVoiceSpec(first, key)), "the first mixer starts the sample")
  local handleB = assert(mixerB:noteOn(sampleVoiceSpec(second, key)), "the second mixer starts the same sample")
  Assert.isTrue(mixerA:isVoiceAlive(handleA) and mixerB:isVoiceAlive(handleB), "both voices sound")

  mixerA:stopVoice(handleA)
  Assert.isFalse(mixerA:isVoiceAlive(handleA), "the stopped voice is physically gone")
  Assert.isNil(first.value, "the stopped voice returned its acquisition")
  Assert.notNil(second.value, "the other mixer keeps its own acquisition")
  Assert.isTrue(mixerB:isVoiceAlive(handleB), "one mixer cannot invalidate another")
  mixerB:controlStep()
  local rendered = mixerB:render(2)
  Assert.equal(#rendered, 4, "the surviving voice renders its frames")
  Assert.equal(provider:status().activeSamples, 1, "the shared sample record stays active for the survivor")

  mixerB:noteOff(handleB)
  for _ = 1, 64 do
    mixerB:controlStep()
    mixerB:render(1)
    if not mixerB:isVoiceAlive(handleB) then
      break
    end
  end
  Assert.isFalse(mixerB:isVoiceAlive(handleB), "the release tail ends at physical death within its budget")
  Assert.isNil(second.value, "physical death returns the remaining acquisition")
  local settled = provider:status()
  Assert.equal(settled.activeSamples, 0, "no active sample record survives the final acquisition")
  Assert.equal(settled.activeSourceBytes, 0, "no resident source bytes stay attributed after the final return")

  local rejected = provider:acquireSample(key)
  local ok = pcall(function()
    mixerA:noteOn({ generator = { kind = "sample", sample = key }, sampleLease = rejected })
  end)
  Assert.isFalse(ok, "a rejected voice construction fails loudly")
  Assert.notNil(rejected.value, "a rejected voice leaves its acquisition with the caller")
  rejected:release()
  Assert.isNil(rejected.value, "the caller returns the rejected acquisition")
  Assert.equal(provider:status().activeSamples, 0, "the returned rejection leaves no active record")

  provider:dispose()
  runtime.queue:release()
end

return { tests = T }
