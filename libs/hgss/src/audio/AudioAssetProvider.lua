-- Runtime owner of the derived audio cache. It loads the audio index
-- eagerly at construction, resolves sequences and banks by numeric id
-- or symbolic name through the index's per-class symbol maps
-- (sequenceBySymbol/bankBySymbol), and loads sequence, bank, and sample
-- assets lazily with per-asset memoization. The cache is a TRUSTED runtime
-- input: generated audio files are deep-validated exactly once by the
-- authoritative cross-file readiness walk (AudioCacheValidator, the same
-- walk the cache writer's staged readback runs), so load-time re-validation
-- is deliberately absent -- there is no runtime mod-injection path that
-- bypasses the builder. Missing or unreadable artifacts are still structured
-- failures, never silence. Samples arrive as metadata plus the
-- packed PCM16 sample, packed exactly once per key and shared across
-- consumers: they live in a byte-budgeted idle kernel keyed by content key
-- at two bytes per frame, while sequence, bank, and index metadata stay
-- memoized for the process lifetime. A sample a mixer voice still sounds is
-- never evicted for budget. The completion marker is not consulted (there
-- is no expected marker value at runtime; readiness is the cache builder's
-- business).

local Errors = require("libs.errors.src.Errors")
local AudioErrors = require("libs.hgss.src.audio.AudioErrors")
local AssetErrors = require("libs.assets.src.audio.AudioErrors")
local AudioBank = require("libs.assets.src.audio.AudioBank")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local Pcm16 = require("libs.nds.src.nitro.sound.Pcm16")
local ResidentAssetCache = require("libs.hgss.src.field.ResidentAssetCache")

-- First-pass idle budget for decoded samples: 32 MiB of unborrowed PCM.
-- Sounding samples are never evicted for budget; overflow stays visible in
-- status until a later pass admits or trims it.
local DEFAULT_IDLE_SAMPLE_BYTES = 32 * 1024 * 1024

---@class AudioAssetSample
---@field metadata table<string, unknown>
---@field pcm Pcm16

---@class AudioAssetProviderOptions
---@field idleByteLimit number?
---@field busy (fun(sample: AudioAssetSample): boolean)?
---@field queue table<string, unknown>? shared background preparation queue for sample payloads (nil keeps synchronous loads)

---@class AudioAssetStatus
---@field uniqueSamples integer
---@field retainedPcmFrames integer
---@field retainedPcmBytes integer
---@field misses integer
---@field reloads integer
---@field activePinnedBytes integer
---@field overBudgetBytes number
---@field predictedBytes integer distinct predicted sample bytes enrolled so far
---@field warmedBytes integer predicted bytes currently resident in RAM
---@field uncoveredBytes integer predicted bytes not currently resident

---@class AudioAssetProvider
---@field private _cacheFs CacheFs
---@field private _index table<string, unknown>
---@field private _sequences table<integer, table<string, unknown>>
---@field private _banks table<integer, table<string, unknown>>
---@field private _samples ResidentAssetCache
---@field private _idleByteLimit number
---@field private _busyPredicate (fun(sample: AudioAssetSample): boolean)?
---@field private _queue table<string, unknown>?
---@field private _pendingAudio table<string, { token: integer, generation: integer }>
---@field private _bankKeysMemo table<string, string[]>
---@field private _bankKeysOrder string[]
---@field private _predictedSizes table<string, integer>
---@field private _predictedBytes integer
---@field private _seenKeys table<string, boolean>
---@field private _demands table<string, integer>
---@field private _misses integer
---@field private _reloads integer
---@field private _retainedSamples integer
---@field private _retainedFrames integer
---@field private _retainedBytes integer
---@field private _busyBytes integer
---@field new fun(cacheFs: CacheFs, opts?: AudioAssetProviderOptions): AudioAssetProvider
---@field sequence fun(self: AudioAssetProvider, idOrSymbol: integer|string): table<string, unknown>
---@field bank fun(self: AudioAssetProvider, idOrSymbol: integer|string): table<string, unknown>
---@field player fun(self: AudioAssetProvider, id: integer): table<string, unknown>
---@field loadSample fun(self: AudioAssetProvider, key: string): AudioAssetSample
---@field warmSample fun(self: AudioAssetProvider, key: string): AudioAssetSample
---@field prewarmBank fun(self: AudioAssetProvider, idOrSymbol: integer|string): AudioAssetSample[]
---@field requestSample fun(self: AudioAssetProvider, key: string): integer
---@field adoptSample fun(self: AudioAssetProvider, key: string, generation: integer?, data: Pcm16Data|userdata): boolean
---@field setBusyPredicate fun(self: AudioAssetProvider, predicate: (fun(sample: AudioAssetSample): boolean)?)
---@field bindQueue fun(self: AudioAssetProvider, queue: table<string, unknown>?)
---@field prewarmBankBackground fun(self: AudioAssetProvider, idOrSymbol: integer|string): integer
---@field drainReadySamples fun(self: AudioAssetProvider): integer
---@field notePredictedSamples fun(self: AudioAssetProvider, keys: string[])
---@field cancelUnpredicted fun(self: AudioAssetProvider, predictedSet: table<string, boolean>)
---@field trim fun(self: AudioAssetProvider, keepKeys: table<string, boolean>|string[]|nil): integer
---@field predictedKeySet fun(self: AudioAssetProvider): string[]
---@field status fun(self: AudioAssetProvider): AudioAssetStatus
---@field private _decodeSample fun(self: AudioAssetProvider, key: string): AudioAssetSample
---@field private _admit fun(self: AudioAssetProvider, key: string, sample: AudioAssetSample): AudioAssetSample
---@field private _enforceBudget fun(self: AudioAssetProvider)

local AudioAssetProvider = {}
AudioAssetProvider.__index = AudioAssetProvider

local function unavailable(path)
  Errors.raise(AudioErrors.AUDIO_PROVIDER_INDEX_UNAVAILABLE, "no usable audio cache index at " .. path, { path = path })
end

-- The kernel's exact-once release hook: drops the evicted sample's share of
-- the retained census. Sounding voices hold their own packed reference, so
-- eviction never frees bytes a voice still reads.
local function forgetSample(provider, sample)
  provider._retainedSamples = provider._retainedSamples - 1
  provider._retainedFrames = provider._retainedFrames - sample.pcm.frames
  provider._retainedBytes = provider._retainedBytes - sample.pcm.frames * 2
end

-- Answers whether a retained sample still sounds, through the composer
-- supplied predicate (a mixer liveness query). Unset while headless: with
-- no predicate nothing counts as busy.
local function sampleIsBusy(provider, sample)
  local predicate = provider._busyPredicate
  if predicate == nil then
    return false
  end
  return predicate(sample) == true
end

---@param cacheFs CacheFs
---@param opts AudioAssetProviderOptions?
---@return AudioAssetProvider
function AudioAssetProvider.new(cacheFs, opts)
  assert(cacheFs, "AudioAssetProvider requires a CacheFs")
  opts = opts or {}
  local index = cacheFs:loadLua(AudioCache.indexPath())
  if type(index) ~= "table" or index.schema ~= AudioCache.INDEX_SCHEMA then
    unavailable(AudioCache.indexPath())
  end
  local limit = opts.idleByteLimit or DEFAULT_IDLE_SAMPLE_BYTES
  assert(type(limit) == "number" and limit >= 0, "audio sample idle budget must be a non-negative byte count")
  ---@type AudioAssetProvider
  local provider
  local function onSampleRelease(sample)
    forgetSample(provider, sample)
  end
  local function isBusy(sample)
    return sampleIsBusy(provider, sample)
  end
  provider = setmetatable({
    _cacheFs = cacheFs,
    _index = index,
    _sequences = {},
    _banks = {},
    _samples = ResidentAssetCache.new({
      idleByteLimit = limit,
      release = onSampleRelease,
      busy = isBusy,
    }),
    _idleByteLimit = limit,
    _busyPredicate = opts.busy,
    _queue = opts.queue,
    _pendingAudio = {},
    _bankKeysMemo = {},
    _bankKeysOrder = {},
    _predictedSizes = {},
    _predictedBytes = 0,
    _seenKeys = {},
    _demands = {},
    _misses = 0,
    _reloads = 0,
    _retainedSamples = 0,
    _retainedFrames = 0,
    _retainedBytes = 0,
    _busyBytes = 0,
  }, AudioAssetProvider) --[[@as AudioAssetProvider]]
  return provider
end

-- Resolves a numeric id or a per-class symbol-map name to a numeric id in
-- `section`, or nil when the reference is unknown.
---@param section table<string, unknown>
---@param symbolMap table<string, unknown>?
---@param idOrSymbol integer|string
---@return integer?
local function resolveId(section, symbolMap, idOrSymbol)
  if type(idOrSymbol) == "number" then
    if section[idOrSymbol] ~= nil then
      return idOrSymbol
    end
    return nil
  end
  if type(idOrSymbol) == "string" and symbolMap and symbolMap[idOrSymbol] ~= nil then
    local id = symbolMap[idOrSymbol]
    if section[id] ~= nil then
      return id
    end
  end
  return nil
end

-- Loads the asset file at `path` once, memoized by id. A missing or
-- unreadable file is a structured failure; the file's content itself is
-- trusted (see the module header: readiness validates the whole cache).
---@param memo table<integer, table<string, unknown>>
---@param cacheFs CacheFs
---@param id integer
---@param path string
---@param invalidCode string
---@return table<string, unknown>
local function loadAsset(memo, cacheFs, id, path, invalidCode)
  local asset = memo[id]
  if asset ~= nil then
    return asset
  end
  local value = cacheFs:loadLua(path)
  if type(value) ~= "table" then
    Errors.raise(invalidCode, "missing or unreadable audio asset at " .. path, { path = path, id = id })
  end
  value = value --[[@as table]]
  memo[id] = value
  return value
end

function AudioAssetProvider:sequence(idOrSymbol)
  local id = resolveId(self._index.sequences, self._index.sequenceBySymbol, idOrSymbol)
  if id == nil then
    Errors.raise(
      AudioErrors.AUDIO_PROVIDER_SEQUENCE_UNKNOWN,
      "no indexed audio sequence for reference " .. tostring(idOrSymbol),
      {
        reference = idOrSymbol,
      }
    )
  end
  return loadAsset(
    self._sequences,
    self._cacheFs,
    id --[[@as integer]],
    AudioCache.sequencePath(id),
    AssetErrors.AUDIO_SEQUENCE_INVALID
  )
end

function AudioAssetProvider:bank(idOrSymbol)
  local id = resolveId(self._index.banks, self._index.bankBySymbol, idOrSymbol)
  if id == nil then
    Errors.raise(
      AudioErrors.AUDIO_PROVIDER_BANK_UNKNOWN,
      "no indexed audio bank for reference " .. tostring(idOrSymbol),
      {
        reference = idOrSymbol,
      }
    )
  end
  return loadAsset(
    self._banks,
    self._cacheFs,
    id --[[@as integer]],
    AudioCache.bankPath(id),
    AssetErrors.AUDIO_BANK_INVALID
  )
end

function AudioAssetProvider:player(id)
  local player = self._index.players and self._index.players[id]
  if type(player) ~= "table" then
    Errors.raise(AudioErrors.AUDIO_PROVIDER_PLAYER_UNKNOWN, "no indexed audio player " .. tostring(id), { id = id })
  end
  return player
end

-- Replaces the mixer liveness predicate the idle kernel consults on trim
-- passes. Set once by the audio composition after the mixer exists.
---@param predicate (fun(sample: AudioAssetSample): boolean)?
function AudioAssetProvider:setBusyPredicate(predicate)
  assert(predicate == nil or type(predicate) == "function", "sample busy predicate must be a function")
  self._busyPredicate = predicate
end

-- Stages a sample's metadata and packed PCM16 sample by content key,
-- without publishing: a failed stage never enters the kernel. Both files
-- must exist and the payload must hold a non-empty even byte count; a
-- missing, unreadable, or malformed artifact is
-- AUDIO_PROVIDER_SAMPLE_UNKNOWN. The packed sample is created once per
-- admission and shared (consumers borrow it; they must not mutate it).
---@param key string
---@return AudioAssetSample
function AudioAssetProvider:_decodeSample(key)
  local metadata = self._cacheFs:loadLua(AudioCache.sampleMetadataPath(key))
  if type(metadata) ~= "table" then
    Errors.raise(AudioErrors.AUDIO_PROVIDER_SAMPLE_UNKNOWN, "no audio sample metadata for key " .. key, { key = key })
  end
  local bytes = self._cacheFs:read(AudioCache.samplePath(key))
  if type(bytes) ~= "string" or #bytes == 0 or #bytes % 2 ~= 0 then
    Errors.raise(AudioErrors.AUDIO_PROVIDER_SAMPLE_UNKNOWN, "no audio sample payload for key " .. key, { key = key })
  end
  local pcm = Pcm16.fromBytes(bytes --[[@as string]])
  assert(metadata.frames == pcm.frames, "sample metadata frame count must match the packed payload")
  return {
    metadata = metadata,
    pcm = pcm,
  }
end

-- Records one predicted candidate's byte size for the admission census.
-- Distinct keys enroll once; re-enrollment keeps the first size so the
-- predicted total stays deterministic across rounds.
---@param key string
---@param byteSize integer
function AudioAssetProvider:_notePredicted(key, byteSize)
  if self._predictedSizes[key] ~= nil then
    return
  end
  assert(type(byteSize) == "number" and byteSize > 0, "predicted sample size must be a positive byte count")
  self._predictedSizes[key] = byteSize
  self._predictedBytes = self._predictedBytes + byteSize
end

-- Enrolls predicted sample keys for admission accounting without loading
-- them: every candidate is counted, only affordable ones stay resident.
-- Sizes come from the trusted sample metadata frame counts.
---@param keys string[]
function AudioAssetProvider:notePredictedSamples(keys)
  assert(type(keys) == "table", "predicted sample keys are required")
  for _, key in ipairs(keys) do
    if self._predictedSizes[key] == nil then
      local metadata = self._cacheFs:loadLua(AudioCache.sampleMetadataPath(key))
      if type(metadata) == "table" and type(metadata.frames) == "number" and metadata.frames > 0 then
        self:_notePredicted(key, metadata.frames * 2)
      end
    end
  end
end

-- The memoized instrument-closure walk for one bank: closure order is the
-- admission order, and the memo stays bounded so repeated prediction
-- rounds never accumulate an unbounded bank history.
---@param idOrSymbol integer|string
---@return string[]
function AudioAssetProvider:_closureKeys(idOrSymbol)
  local bank = self:bank(idOrSymbol)
  local bankId = assert(bank.id, "audio bank carries its numeric identity")
  local memoKey = tostring(bankId)
  local memoized = self._bankKeysMemo[memoKey]
  if memoized ~= nil then
    return memoized
  end
  local keys = AudioBank.sampleKeys(bank)
  if keys == nil then
    Errors.raise(
      AssetErrors.AUDIO_BANK_INVALID,
      "no readable sample closure for audio bank " .. tostring(idOrSymbol),
      { reference = idOrSymbol }
    )
  end
  keys = keys --[[@as string[] ]]
  self._bankKeysMemo[memoKey] = keys
  self._bankKeysOrder[#self._bankKeysOrder + 1] = memoKey
  while #self._bankKeysOrder > 32 do
    local oldest = table.remove(self._bankKeysOrder, 1)
    self._bankKeysMemo[oldest] = nil
  end
  return keys
end

-- Admits a fully staged sample unless it alone exceeds the idle budget: an
-- oversize candidate is still decoded and usable for its caller, but it is
-- never published over fitting residents, so one large prediction cannot
-- evict the current set only to be evicted itself on the next pass. The
-- caller counts the decode miss; this marks the reload when seen before and
-- enrolls the predicted bytes, keeping the admission gap explicit.
---@param key string
---@param sample AudioAssetSample
---@return AudioAssetSample
function AudioAssetProvider:_admitOrSkip(key, sample)
  local byteSize = sample.pcm.frames * 2
  self:_notePredicted(key, byteSize)
  if byteSize > self._idleByteLimit then
    if self._seenKeys[key] == true then
      self._reloads = self._reloads + 1
    end
    self._seenKeys[key] = true
    return sample
  end
  return self:_admit(key, sample)
end

-- Publishes a fully staged sample under its content key at its real packed
-- byte cost (two bytes per frame), then enforces the idle budget.
-- Internal: prefer _admitOrSkip so oversize candidates skip retention.
---@param key string
---@param sample AudioAssetSample
---@return AudioAssetSample
function AudioAssetProvider:_admit(key, sample)
  local reload = self._seenKeys[key] == true
  self._samples:publish(key, sample, sample.pcm.frames * 2)
  self._seenKeys[key] = true
  self._retainedSamples = self._retainedSamples + 1
  self._retainedFrames = self._retainedFrames + sample.pcm.frames
  self._retainedBytes = self._retainedBytes + sample.pcm.frames * 2
  if reload then
    self._reloads = self._reloads + 1
  end
  self:_enforceBudget()
  return sample
end

-- Enforces the idle byte budget now; the busy-shielded bytes observed by
-- the pass feed status until the next trim. Admission-time only, never in
-- the mix loop.
function AudioAssetProvider:_enforceBudget()
  local _, busyBytes = self._samples:trim()
  self._busyBytes = busyBytes
end

-- Loads a sample's metadata and packed PCM16 sample by content key. A hit
-- returns the one memoized backing for the key; a miss stages and counts
-- itself (a miss for a previously evicted key also counts as a reload), so
-- a disk reload after eviction is an ordinary cache miss. A sample larger
-- than the whole idle budget is decoded for the caller but never retained
-- over fitting residents; demand correctness never depends on retention.
function AudioAssetProvider:loadSample(key)
  local hit = self._samples:find(key)
  if hit ~= nil then
    return hit --[[@as AudioAssetSample]]
  end
  self:_drainAudioReady()
  local retried = self._samples:find(key)
  if retried ~= nil then
    return retried --[[@as AudioAssetSample]]
  end
  self._misses = self._misses + 1
  return self:_admitOrSkip(key, self:_decodeSample(key))
end

-- Admits a sample to the resident set, loading it synchronously on a miss:
-- the admission half of prewarm. Background scheduling arrives later; the
-- call itself never blocks on a worker.
---@param key string
---@return AudioAssetSample
function AudioAssetProvider:warmSample(key)
  return self:loadSample(key)
end

-- Admits every sample a bank's instrument closure references, in closure
-- order, reusing the shared bank reference walk instead of a second
-- instrument grammar. With a bound background queue, missing samples
-- enroll as background prefetch work and only already-ready completions
-- adopt synchronously, so the call never decodes on the audio path;
-- without one the bank warms synchronously as before.
---@param idOrSymbol integer|string
---@return AudioAssetSample[]
function AudioAssetProvider:prewarmBank(idOrSymbol)
  local keys = self:_closureKeys(idOrSymbol)
  for _, key in ipairs(keys) do
    self:_enrollKeySize(key)
  end
  if self._queue ~= nil then
    self:_enqueueMissing(keys)
    self:_drainAudioReady()
    local warmed = {} ---@type AudioAssetSample[]
    for _, key in ipairs(keys) do
      local hit = self._samples:find(key)
      if hit ~= nil then
        warmed[#warmed + 1] = hit
      end
    end
    return warmed
  end
  local warmed = {} ---@type AudioAssetSample[]
  for _, key in ipairs(keys) do
    warmed[#warmed + 1] = self:warmSample(key)
  end
  return warmed
end

-- Enrolls one bank's closure as background prefetch work without decoding:
-- missing samples enqueue at prefetch priority and only already-ready
-- completions adopt. Without a bound queue this enrolls sizes only and
-- decodes nothing, so map entry never pays a synchronous decode on the
-- audio path; the explicit prewarm path stays the synchronous admission.
---@param idOrSymbol integer|string
---@return integer enrolled key count
function AudioAssetProvider:prewarmBankBackground(idOrSymbol)
  local keys = self:_closureKeys(idOrSymbol)
  for _, key in ipairs(keys) do
    self:_enrollKeySize(key)
  end
  if self._queue ~= nil then
    self:_enqueueMissing(keys)
  end
  return #keys
end

-- Binds (or unbinds) the shared background preparation queue. With a queue,
-- bank prewarming enrolls sample payloads as background work and adopts
-- only already-ready completions; without one every prewarm warms
-- synchronously. Headless audio stays queue-free and synchronous-safe.
---@param queue table<string, unknown>?
function AudioAssetProvider:bindQueue(queue)
  assert(queue == nil or type(queue.request) == "function", "sample queue must offer the preparation request shape")
  self._queue = queue
  if queue == nil then
    self._pendingAudio = {}
  end
end

-- Enrolls one key's predicted size from its trusted metadata when not yet
-- enrolled. Resident keys enroll without rereading payloads.
---@param key string
function AudioAssetProvider:_enrollKeySize(key)
  if self._predictedSizes[key] ~= nil then
    return
  end
  local metadata = self._cacheFs:loadLua(AudioCache.sampleMetadataPath(key))
  if type(metadata) == "table" and type(metadata.frames) == "number" and metadata.frames > 0 then
    self:_notePredicted(key, metadata.frames * 2)
  end
end

-- Enrolls every missing closure key as one background sample payload at
-- prefetch priority. Already-resident and already-pending keys enroll
-- nothing new; each enrollment takes a fresh demand generation so a newer
-- round invalidates work already in flight.
---@param keys string[]
function AudioAssetProvider:_enqueueMissing(keys)
  local queue = assert(self._queue, "sample background enrollment requires its queue")
  for _, key in ipairs(keys) do
    if self._samples:find(key) == nil and self._pendingAudio[key] == nil then
      local generation = self:requestSample(key)
      local ok, token = pcall(function()
        return queue:request("audio-sample", AudioCache.samplePath(key), "prefetch")
      end)
      if ok and type(token) == "number" then
        self._pendingAudio[key] = { token = token, generation = generation }
      else
        self._pendingAudio[key] = nil
      end
    end
  end
end

-- Adopts every already-ready background sample payload without blocking:
-- a matching generation publishes its ByteData as packed PCM with no copy,
-- a stale or failed delivery is discarded and its interest dropped. Late
-- replies for cancelled interest never publish.
---@return integer adopted count
function AudioAssetProvider:drainReadySamples()
  return self:_drainAudioReady()
end

---@return integer
function AudioAssetProvider:_drainAudioReady()
  local queue = self._queue
  if queue == nil then
    return 0
  end
  local adopted = 0
  for key, pending in pairs(self._pendingAudio) do
    local record = pending --[[@as { token: integer, generation: integer } ]]
    local ok, status = pcall(function()
      return queue:poll(record.token)
    end)
    if ok and status == "ready" then
      local takeOk, payload = pcall(function()
        return queue:take(record.token)
      end)
      self._pendingAudio[key] = nil
      if takeOk and type(payload) == "table" then
        local data = payload.byteData
        if data ~= nil and self:adoptSample(key, record.generation, data) then
          adopted = adopted + 1
        end
      end
    elseif ok and status == "failed" then
      self._pendingAudio[key] = nil
      pcall(function()
        queue:take(record.token)
      end)
    end
  end
  return adopted
end

-- Drops background interest for keys outside the current predicted set.
-- Running worker jobs are never preempted; their late replies simply find
-- no pending interest and publish nothing.
---@param predictedSet table<string, boolean>
function AudioAssetProvider:cancelUnpredicted(predictedSet)
  local queue = self._queue
  for key, pending in pairs(self._pendingAudio) do
    if predictedSet[key] ~= true then
      self._pendingAudio[key] = nil
      if queue ~= nil then
        pcall(function()
          queue:cancel(pending.token)
        end)
      end
    end
  end
end

-- The distinct predicted sample keys enrolled so far, in stable sorted
-- order. A read-only copy for admission-aware trimming; the driver applies
-- its own current-first priority on top when it trims.
---@return string[]
function AudioAssetProvider:predictedKeySet()
  local ordered = {} ---@type string[]
  for key in pairs(self._predictedSizes) do
    ordered[#ordered + 1] = key
  end
  table.sort(ordered)
  return ordered
end

-- Records demand for a sample key and hands the background schedule its
-- generation token: only an adoption carrying the current generation
-- lands, so a newer demand invalidates work already in flight.
---@param key string
---@return integer
function AudioAssetProvider:requestSample(key)
  local generation = (self._demands[key] or 0) + 1
  self._demands[key] = generation
  return generation
end

-- Adopts a worker-prepared Data beside its read pointer without copying,
-- but only for the current demand generation and only when the key is not
-- already resident: stale and duplicate deliveries report false and keep
-- no second backing. A staged failure never enters the kernel.
---@param key string
---@param generation integer?
---@param data Pcm16Data|userdata
---@return boolean
function AudioAssetProvider:adoptSample(key, generation, data)
  if generation ~= self._demands[key] then
    return false
  end
  if self._samples:find(key) ~= nil then
    return false
  end
  local metadata = self._cacheFs:loadLua(AudioCache.sampleMetadataPath(key))
  if type(metadata) ~= "table" then
    Errors.raise(AudioErrors.AUDIO_PROVIDER_SAMPLE_UNKNOWN, "no audio sample metadata for key " .. key, { key = key })
  end
  local pcm = Pcm16.fromData(data)
  assert(metadata.frames == pcm.frames, "sample metadata frame count must match the packed payload")
  self:_notePredicted(key, pcm.frames * 2)
  if pcm.frames * 2 > self._idleByteLimit then
    if self._seenKeys[key] == true then
      self._reloads = self._reloads + 1
    end
    self._seenKeys[key] = true
    self._misses = self._misses + 1
    return true
  end
  self._misses = self._misses + 1
  self:_admit(key, {
    metadata = metadata,
    pcm = pcm,
  })
  return true
end

-- Enforces the idle byte budget now and reports the evicted count; the
-- busy-shielded bytes observed by the pass feed status until the next trim.
-- With a keep set, predicted keys are refreshed to most-recently-used
-- first, so the pass trims the non-predicted idle tail before touching
-- predicted entries. An array expresses protection priority in order: its
-- first key is touched last and stays most-recently-used. Live and busy
-- entries are never freed either way.
---@param keepKeys table<string, boolean>|string[]|nil
---@return integer
function AudioAssetProvider:trim(keepKeys)
  if keepKeys ~= nil then
    local function refresh(key)
      if type(key) == "string" then
        pcall(function()
          self._samples:find(key)
        end)
      end
    end
    if keepKeys[1] ~= nil then
      local ordered = keepKeys --[[@as string[] ]]
      for index = #ordered, 1, -1 do
        refresh(ordered[index])
      end
    else
      for key in
        pairs(keepKeys --[[@as table<string, boolean> ]])
      do
        refresh(key)
      end
    end
  end
  local evicted, busyBytes = self._samples:trim()
  self._busyBytes = busyBytes
  return evicted
end

-- Current census: retained distinct samples with their packed frame and
-- byte totals, cumulative misses and post-eviction reloads, the
-- busy-shielded bytes observed by the most recent trim, and the idle bytes
-- over budget right now.
---@return AudioAssetStatus
function AudioAssetProvider:status()
  local resident = self._samples:stats()
  local over = resident.idleBytes - self._idleByteLimit
  if over < 0 then
    over = 0
  end
  local uncovered = self._predictedBytes - self._retainedBytes
  if uncovered < 0 then
    uncovered = 0
  end
  return {
    uniqueSamples = self._retainedSamples,
    retainedPcmFrames = self._retainedFrames,
    retainedPcmBytes = self._retainedBytes,
    misses = self._misses,
    reloads = self._reloads,
    activePinnedBytes = self._busyBytes,
    overBudgetBytes = over,
    predictedBytes = self._predictedBytes,
    warmedBytes = self._retainedBytes,
    uncoveredBytes = uncovered,
  }
end

return AudioAssetProvider
