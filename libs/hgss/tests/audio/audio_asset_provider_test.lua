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

-- The selected overlay's answer for a package-supplied audio family: index,
-- banks, sequences and metadata stay resident metadata reads, while every
-- compact PCM payload is a disk-backed selected source with no resident bytes.
---@param bundle AudioFixture.Bundle
---@return CacheFs cache
---@return table<string, table> references by logical sample path
local function selectedSampleCache(bundle)
  local cache = AudioFixture.residentCache(bundle)
  local references = {}
  local samplePaths = {}
  for key in pairs(bundle.samples) do
    samplePaths[AudioCache.samplePath(key)] = true
  end
  local resolveAsset = cache.resolveAsset
  function cache:resolveAsset(path)
    local reference = resolveAsset(self, path)
    if reference == nil or not samplePaths[path] then
      return reference
    end
    local selected = references[path]
    if selected == nil then
      selected = {
        path = path,
        size = reference.size,
        sourceId = "mod:selected-audio\0package",
        contentId = "mod:selected-audio\0package\0" .. path,
        physicalPath = "__mod/selected-audio/" .. path,
      }
      references[path] = selected
    end
    return selected
  end
  return cache, references
end

-- A stand-in for the shared preparation queue's source interface: requests are
-- recorded, tokens complete only when the test says so, and cancellation is
-- observable. Source reads themselves belong to the queue suite.
local function recordingQueue()
  local queue = { requests = {}, states = {}, cancelled = {}, takes = {}, promoted = {}, nextToken = 0 }
  function queue:request(kind, path, priority)
    assert(kind == "source", "prediction must request the selected source kind")
    self.nextToken = self.nextToken + 1
    self.requests[#self.requests + 1] = { token = self.nextToken, path = path, priority = priority }
    return self.nextToken
  end
  function queue:poll(token)
    return self.states[token] or "pending"
  end
  function queue:cancel(token)
    self.cancelled[#self.cancelled + 1] = token
    self.states[token] = nil
  end
  function queue:take(token)
    assert(self.states[token] == "ready", "takes transfer ready tokens")
    self.takes[#self.takes + 1] = token
    self.states[token] = nil
    local lease = { value = "selected-bytes:" .. tostring(token), released = 0 }
    function lease:release()
      self.value = nil
      self.released = self.released + 1
    end
    return lease
  end
  function queue:promote(token, priority)
    self.promoted[#self.promoted + 1] = { token = token, priority = priority }
  end
  return queue
end

-- The selected runtime's source acquisition as the provider sees it: one lease
-- over the exact reference the caller asked for, released by its consumer.
---@param cache CacheFs
---@return { acquireSource: fun(reference: table): table }, table[]
local function recordingAcquirer(cache)
  local acquired = {}
  local api = {
    acquireSource = function(reference)
      local lease = { value = assert(cache:readData(reference.path)) }
      acquired[#acquired + 1] = { reference = reference, lease = lease }
      function lease:release()
        self.value = nil
      end
      return lease
    end,
  }
  return api, acquired
end

-- Package prediction is source work, never a private PCM copy: each closure key
-- requests the selected source at prefetch priority, actual acquisition joins
-- the same reference, ready/failed predictions are adopted by returning their
-- kernel lease, and only this provider's own interests are cancelled.
function T.package_prediction_schedules_sources_and_adopts_them_without_a_pcm_copy()
  local bundle = AudioFixture.bundle()
  local cache, references = selectedSampleCache(bundle)
  local queue = recordingQueue()
  local api, acquired = recordingAcquirer(cache)
  local p = AudioAssetProvider.new(cache, { acquireSource = api.acquireSource, assetPreparation = queue })
  local firstKey = AudioFixture.key(1)
  local secondKey = AudioFixture.key(2)
  local firstPath = AudioCache.samplePath(firstKey)
  local secondPath = AudioCache.samplePath(secondKey)

  local predicted = p:prewarmBankBackground(12)
  Assert.equal(predicted, 2, "the bank closure predicts both fixture samples")
  Assert.equal(#queue.requests, 2, "each predicted sample requests its selected source once")
  Assert.equal(queue.requests[1].priority, "prefetch", "background prediction stays prefetch work")
  Assert.isTrue(
    references[queue.requests[1].path] == references[firstPath]
      or references[queue.requests[1].path] == references[secondPath],
    "the request names a selected sample payload"
  )
  Assert.equal(#acquired, 0, "background prediction creates no PCM backing")

  -- A repeated prediction round joins the same pending tokens.
  p:prewarmBankBackground(12)
  Assert.equal(#queue.requests, 2, "repeated prediction joins the pending source interest")

  -- A ready prediction is adopted by returning its kernel lease; a failed one
  -- is dropped the same way.
  queue.states[queue.requests[1].token] = "ready"
  queue.states[queue.requests[2].token] = "failed"
  Assert.equal(p:drainReadySamples(), 1, "one ready prediction is adopted")
  Assert.equal(#queue.cancelled, 2, "both settled prediction tokens are returned")

  -- Acquisition of the same content key joins the reference the prediction
  -- named and keeps no wrapper over the shared bytes.
  local lease = p:acquireSample(firstKey)
  Assert.isTrue(
    acquired[#acquired].reference == references[firstPath],
    "actual acquisition uses the selected source reference prediction named"
  )
  Assert.equal(assert(lease.value).pcm.frames, 4, "the selected source decodes in place")
  Assert.equal(p:status().activeSamples, 1, "the acquisition holds one active record")
  lease:release()
  Assert.equal(p:status().activeSamples, 0, "returning the acquisition drops the record")

  -- Synchronous prediction retains the selected source only long enough to
  -- schedule it, then returns the lease immediately.
  local acquiredBefore = #acquired
  Assert.deepEqual(p:prewarmBank(12), {}, "synchronous prediction returns no PCM wrapper")
  Assert.equal(#acquired, acquiredBefore + 2, "synchronous prediction reads each selected sample once")
  for index = acquiredBefore + 1, #acquired do
    Assert.isNil(acquired[index].lease.value, "the synchronous prediction lease is returned")
  end

  -- Only this provider's own interests are cancelled.
  p:prewarmBankBackground(12)
  local firstPending, secondPending = queue.requests[#queue.requests - 1], queue.requests[#queue.requests]
  Assert.equal(p:cancelUnpredicted({ [firstKey] = true, [secondKey] = true }), 0, "predicted keys stay pending")
  Assert.equal(p:cancelUnpredicted({ [firstKey] = true }), 1, "the unpredicted key's own interest is dropped")
  local cancelledBeforeDispose = #queue.cancelled
  p:dispose()
  Assert.equal(#queue.cancelled, cancelledBeforeDispose + 1, "disposal drops its remaining prediction token")
  Assert.isTrue(
    queue.cancelled[#queue.cancelled] == firstPending.token or queue.cancelled[#queue.cancelled] == secondPending.token,
    "the disposed token is this provider's own request"
  )
end

-- Base resident samples need no read, lease, or preparation: prediction stays
-- the metadata-only no-op it was before selected sources existed.
function T.base_resident_prediction_stays_a_no_op()
  local bundle = AudioFixture.bundle()
  local cache = AudioFixture.residentCache(bundle)
  local queue = recordingQueue()
  local api, acquired = recordingAcquirer(cache)
  local p = AudioAssetProvider.new(cache, { acquireSource = api.acquireSource, assetPreparation = queue })

  Assert.deepEqual(p:prewarmBank(12), {}, "base prediction returns no sample wrapper")
  Assert.equal(p:prewarmBankBackground(12), 2, "the predicted key count is unchanged")
  Assert.equal(#acquired, 0, "base resident samples schedule no source lease")
  Assert.equal(#queue.requests, 0, "base resident samples schedule no source read")
  Assert.equal(p:drainReadySamples(), 0, "nothing is in flight to adopt")
  Assert.equal(p:cancelUnpredicted({}), 0, "nothing is in flight to cancel")
end

-- Required battle music waits for its selected sample sources instead of
-- voicing early or reintroducing a synchronous disk wait: the provider
-- promotes the bank closure to demand work, reports pending while any
-- selected read is unsettled, retains the ready source holds through the
-- admission boundary, names terminal failures with their bank and sample
-- key, and returns every hold exactly once.
function T.required_bank_sources_gate_music_start_until_selected_bytes_are_held()
  local bundle = AudioFixture.bundle()
  local cache, _ = selectedSampleCache(bundle)
  local queue = recordingQueue()
  local api, _ = recordingAcquirer(cache)
  local p = AudioAssetProvider.new(cache, { acquireSource = api.acquireSource, assetPreparation = queue })
  Assert.isTrue(
    type(p.requireBankSources) == "function" and type(p.releaseBankSources) == "function",
    "required battle music waits for its selected sample sources instead of voicing early: "
      .. "the provider stages required bank source holds with an exact pending/ready/failed contract"
  )
  local firstKey = AudioFixture.key(1)
  local firstPath = AudioCache.samplePath(firstKey)

  local ready, failure = p:requireBankSources(12)
  Assert.equal(ready, false, "the unsettled selected closure reports pending, never ready")
  Assert.isNil(failure, "pending carries no terminal cause")
  Assert.equal(#queue.requests, 2, "every closure sample enrolls its selected source")
  for _, request in ipairs(queue.requests) do
    Assert.equal(request.priority, "demand", "required sources outrank speculative prediction")
  end
  ready, failure = p:requireBankSources(12)
  Assert.equal(ready, false, "a repeated query joins instead of duplicating the pending reads")
  Assert.isNil(failure, "repeated pending carries no terminal cause")
  Assert.equal(#queue.requests, 2, "the repeated query schedules no second read")

  for _, request in ipairs(queue.requests) do
    queue.states[request.token] = "ready"
  end
  ready, failure = p:requireBankSources(12)
  Assert.isTrue(ready == true, "the settled selected closure reports ready")
  Assert.isNil(failure, "readiness carries no terminal cause")
  Assert.equal(#queue.takes, 2, "ready selected reads transfer into retained holds")
  Assert.equal(#queue.cancelled, 0, "required holds are retained, never cancelled to idle")
  Assert.equal(p:releaseBankSources(12), 2, "release returns every retained hold exactly once")
  Assert.equal(p:releaseBankSources(12), 0, "a second release returns nothing")
  p:dispose()

  local sadCache, _ = selectedSampleCache(bundle)
  local sadQueue = recordingQueue()
  local sadApi, _ = recordingAcquirer(sadCache)
  local sad = AudioAssetProvider.new(sadCache, { acquireSource = sadApi.acquireSource, assetPreparation = sadQueue })
  ready, failure = sad:requireBankSources(12)
  Assert.equal(ready, false, "the failing closure starts pending like any unsettled read")
  local failedToken, survivorToken = nil, nil
  for _, request in ipairs(sadQueue.requests) do
    if request.path == firstPath then
      failedToken = request.token
    else
      survivorToken = request.token
    end
  end
  Assert.notNil(failedToken, "the probed sample enrolls its own read")
  sadQueue.states[failedToken] = "failed"
  sadQueue.states[survivorToken] = "ready"
  ready, failure = sad:requireBankSources(12)
  Assert.isNil(ready, "a terminal selected read never reports ready")
  Assert.isTrue(
    type(failure) == "string"
      and tostring(failure):find("12", 1, true) ~= nil
      and tostring(failure):find(firstKey, 1, true) ~= nil,
    "the failure names its bank and sample key: " .. tostring(failure)
  )
  Assert.equal(sad:releaseBankSources(12), 0, "a failed requirement retains no partial hold")
  sad:dispose()

  local residentCache = AudioFixture.residentCache(bundle)
  local residentQueue = recordingQueue()
  local residentApi, _ = recordingAcquirer(residentCache)
  local resident = AudioAssetProvider.new(
    residentCache,
    { acquireSource = residentApi.acquireSource, assetPreparation = residentQueue }
  )
  ready, failure = resident:requireBankSources(12)
  Assert.isTrue(ready == true, "base resident samples are ready with no selected read")
  Assert.isNil(failure, "resident readiness carries no terminal cause")
  Assert.equal(#residentQueue.requests, 0, "base resident samples schedule no source read")
  resident:dispose()
end

return { tests = T }
