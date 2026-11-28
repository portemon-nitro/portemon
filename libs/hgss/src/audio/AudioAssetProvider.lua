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
-- failures, never silence.
--
-- Samples are acquired, never retained privately: `acquireSample` resolves one
-- content key to an active record holding one resident source lease over the
-- compact packed PCM16 bytes, the immutable playback metadata and a reference
-- count. Every acquisition hands out a distinct lease, and the last return
-- drops the record and gives the source back, so packed PCM lives exactly as
-- long as a physical voice sounds it and no sample outlives its leases.
-- Sequence, bank, and instrument-closure metadata stay memoized for the
-- provider lifetime. The completion marker is not consulted (there is no
-- expected marker value at runtime; readiness is the cache builder's
-- business).

local Errors = require("libs.errors.src.Errors")
local AudioErrors = require("libs.hgss.src.audio.AudioErrors")
local AssetErrors = require("libs.assets.src.audio.AudioErrors")
local AudioBank = require("libs.assets.src.audio.AudioBank")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local Pcm16 = require("libs.nds.src.nitro.sound.Pcm16")

---@class AudioAssetSample
---@field metadata table<string, unknown>
---@field pcm Pcm16

---@class AudioAssetSampleLease
---@field value AudioAssetSample? cleared on release, so a returned lease cannot retain PCM
---@field release fun(self: AudioAssetSampleLease): boolean

---@class AudioAssetProviderSourceLease
---@field value love.Data? resident compact bytes, cleared on release
---@field release fun(self: AudioAssetProviderSourceLease)

---@class AudioAssetProviderOptions
---@field acquireSource fun(reference: ResidentCache.BlobRef|CacheFs.PackageRef): AudioAssetProviderSourceLease resident source acquirer of the selected epoch
---@field assetPreparation table<string, unknown>? shared preparation queue this provider's payload interest routes through

---@class AudioAssetProvider.SampleRecord
---@field sourceLease AudioAssetProviderSourceLease one resident source interest over the compact PCM
---@field sourceId string resident source identity of the backing bytes
---@field contentId string resident content identity of the backing bytes
---@field metadata table<string, unknown> immutable playback metadata
---@field pcm Pcm16 packed PCM16 over the borrowed bytes
---@field byteSize integer compact backing bytes attributed to this record
---@field references integer outstanding acquisitions

---@class AudioAssetStatus
---@field activeSamples integer active sample records backed by one or more acquisitions
---@field activeSourceBytes integer distinct active resident backing bytes attributed within this provider
---@field acquisitions integer successful SampleLease acquisitions
---@field misses integer first active-record constructions, not disk reads

---@class AudioAssetProvider
---@field private _cacheFs CacheFs
---@field private _index table<string, unknown>
---@field private _acquireSource fun(reference: ResidentCache.BlobRef|CacheFs.PackageRef): AudioAssetProviderSourceLease
---@field private _queue table<string, unknown>?
---@field private _sequences table<integer, table<string, unknown>>
---@field private _banks table<integer, table<string, unknown>>
---@field private _activeSamples table<string, AudioAssetProvider.SampleRecord>
---@field private _sampleSources table<string, integer> predicted sample key to its pending selected-source token
---@field private _bankKeysMemo table<string, string[]>
---@field private _bankKeysOrder string[]
---@field private _acquisitions integer
---@field private _misses integer
---@field new fun(cacheFs: CacheFs, opts: AudioAssetProviderOptions): AudioAssetProvider
---@field sequence fun(self: AudioAssetProvider, idOrSymbol: integer|string): table<string, unknown>
---@field bank fun(self: AudioAssetProvider, idOrSymbol: integer|string): table<string, unknown>
---@field player fun(self: AudioAssetProvider, id: integer): table<string, unknown>
---@field acquireSample fun(self: AudioAssetProvider, key: string): AudioAssetSampleLease
---@field prewarmBank fun(self: AudioAssetProvider, idOrSymbol: integer|string): AudioAssetSample[]
---@field prewarmBankBackground fun(self: AudioAssetProvider, idOrSymbol: integer|string): integer
---@field requireBankSources fun(self: AudioAssetProvider, idOrSymbol: integer|string): (boolean?, string?)
---@field releaseBankSources fun(self: AudioAssetProvider, idOrSymbol: integer|string): integer
---@field bindQueue fun(self: AudioAssetProvider, queue: table<string, unknown>?)
---@field drainReadySamples fun(self: AudioAssetProvider): integer
---@field cancelUnpredicted fun(self: AudioAssetProvider, predictedSet: table<string, boolean>): integer
---@field status fun(self: AudioAssetProvider): AudioAssetStatus
---@field dispose fun(self: AudioAssetProvider)
---@field private _closureKeys fun(self: AudioAssetProvider, idOrSymbol: integer|string): string[]
---@field private _openSample fun(self: AudioAssetProvider, key: string): AudioAssetProvider.SampleRecord
---@field private _leaseSample fun(self: AudioAssetProvider, key: string, record: AudioAssetProvider.SampleRecord): AudioAssetSampleLease
---@field private _returnSample fun(self: AudioAssetProvider, key: string, record: AudioAssetProvider.SampleRecord)

local AudioAssetProvider = {}
AudioAssetProvider.__index = AudioAssetProvider

local function unavailable(path)
  Errors.raise(AudioErrors.AUDIO_PROVIDER_INDEX_UNAVAILABLE, "no usable audio cache index at " .. path, { path = path })
end

---@param cacheFs CacheFs
---@param opts AudioAssetProviderOptions
---@return AudioAssetProvider
function AudioAssetProvider.new(cacheFs, opts)
  assert(cacheFs, "AudioAssetProvider requires a CacheFs")
  assert(type(opts) == "table", "AudioAssetProvider requires its selected source acquirer")
  assert(type(opts.acquireSource) == "function", "AudioAssetProvider requires the resident source acquirer")
  local index = cacheFs:loadLua(AudioCache.indexPath())
  if type(index) ~= "table" or index.schema ~= AudioCache.INDEX_SCHEMA then
    unavailable(AudioCache.indexPath())
  end
  return setmetatable({
    _cacheFs = cacheFs,
    _index = index,
    _acquireSource = opts.acquireSource,
    _queue = opts.assetPreparation,
    _sequences = {},
    _banks = {},
    _activeSamples = {},
    _sampleSources = {},
    _requiredSources = {},
    _bankKeysMemo = {},
    _bankKeysOrder = {},
    _acquisitions = 0,
    _misses = 0,
  }, AudioAssetProvider) --[[@as AudioAssetProvider]]
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

-- The memoized instrument-closure walk for one bank: closure order is the
-- prediction order, and the memo stays bounded so repeated prediction
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

-- Stages one sample's active record: playback metadata first, then one
-- resident source interest over the compact packed PCM16 bytes, then the
-- packed-frame check that must hold before anything becomes reachable. A
-- malformed or unreadable artifact (including an odd byte count or a frame
-- count the metadata contradicts) is AUDIO_PROVIDER_SAMPLE_UNKNOWN, and a
-- staged source interest is always returned before the failure propagates.
---@param key string
---@return AudioAssetProvider.SampleRecord
function AudioAssetProvider:_openSample(key)
  local metadata = self._cacheFs:loadLua(AudioCache.sampleMetadataPath(key))
  if type(metadata) ~= "table" then
    Errors.raise(AudioErrors.AUDIO_PROVIDER_SAMPLE_UNKNOWN, "no audio sample metadata for key " .. key, { key = key })
  end
  local path = AudioCache.samplePath(key)
  local reference = self._cacheFs:resolveAsset(path)
  if reference == nil then
    Errors.raise(AudioErrors.AUDIO_PROVIDER_SAMPLE_UNKNOWN, "no audio sample payload for key " .. key, { key = key })
  end
  ---@cast reference -nil
  local sourceLease = self._acquireSource(reference)
  local source = sourceLease.value
  local pcm, openError
  if source == nil then
    openError = "the staged source lease carries no bytes"
  else
    local opened, decoded = pcall(Pcm16.fromData, source)
    if not opened then
      openError = decoded
    elseif metadata.frames ~= decoded.frames then
      openError = "sample metadata frame count does not match the packed payload"
    else
      pcm = decoded
    end
  end
  if pcm == nil then
    sourceLease:release()
    Errors.raise(
      AudioErrors.AUDIO_PROVIDER_SAMPLE_UNKNOWN,
      "unreadable audio sample payload for key " .. key .. ": " .. tostring(openError),
      { key = key }
    )
  end
  ---@cast source -nil
  return {
    sourceLease = sourceLease,
    sourceId = reference.sourceId,
    contentId = reference.contentId,
    metadata = metadata,
    pcm = pcm,
    byteSize = source:getSize(),
    references = 0,
  }
end

-- One distinct lease over an active sample record. The lease exposes the
-- immutable metadata/PCM pair while it is outstanding and clears it on the
-- first return, so a returned lease can never keep PCM alive by accident.
---@param key string
---@param record AudioAssetProvider.SampleRecord
---@return AudioAssetSampleLease
function AudioAssetProvider:_leaseSample(key, record)
  local provider = self
  local lease = {
    value = { metadata = record.metadata, pcm = record.pcm },
  }
  ---@cast lease AudioAssetSampleLease
  function lease:release()
    if self.value == nil then
      return false
    end
    self.value = nil
    provider:_returnSample(key, record)
    return true
  end
  return lease
end

-- Returns one acquisition. The last return drops the active record and gives
-- the resident source back, so no private sample backing survives its
-- sounding voices.
---@param key string
---@param record AudioAssetProvider.SampleRecord
function AudioAssetProvider:_returnSample(key, record)
  record.references = record.references - 1
  if record.references > 0 then
    return
  end
  if self._activeSamples[key] == record then
    self._activeSamples[key] = nil
  end
  local sourceLease = record.sourceLease
  record.sourceLease = nil
  record.metadata = nil
  record.pcm = nil
  record.byteSize = 0
  sourceLease:release()
end

-- Borrows one active sample record by content key. Repeated acquisitions of a
-- key share that record's single decoded backing while each acquisition stays
-- an independent lease; the first acquisition of a key constructs the record
-- and counts as this provider's miss.
---@param key string
---@return AudioAssetSampleLease
function AudioAssetProvider:acquireSample(key)
  assert(type(key) == "string" and key ~= "", "sample acquisition requires a content key")
  local record = self._activeSamples[key]
  if record == nil then
    record = self:_openSample(key)
    self._activeSamples[key] = record
    self._misses = self._misses + 1
  end
  record.references = record.references + 1
  self._acquisitions = self._acquisitions + 1
  return self:_leaseSample(key, record)
end

-- The selected source of one sample's compact bytes, or nil when the key
-- names no generated payload (acquisition raises its own structured failure)
-- or the epoch's resident base store already owns those bytes, for which
-- prediction needs no read, lease, or preparation.
---@param key string
---@return CacheFs.PackageRef?
function AudioAssetProvider:_sampleSource(key)
  local reference = self._cacheFs:resolveAsset(AudioCache.samplePath(key))
  if reference == nil or reference.data ~= nil then
    return nil
  end
  return reference --[[@as CacheFs.PackageRef]]
end

-- Resolves every sample a bank's instrument closure references, in closure
-- order, reusing the shared bank reference walk instead of a second
-- instrument grammar. Base resident samples need no work; a selected package
-- sample joins the same source interest actual acquisition uses and is released
-- again as soon as it is retained, so prediction adds no private PCM backing.
---@param idOrSymbol integer|string
---@return AudioAssetSample[]
function AudioAssetProvider:prewarmBank(idOrSymbol)
  for _, key in ipairs(self:_closureKeys(idOrSymbol)) do
    local reference = self:_sampleSource(key)
    if reference ~= nil then
      local lease = self._acquireSource(reference)
      lease:release()
    end
  end
  return {}
end

-- Resolves one bank's closure for prediction without blocking: a selected
-- sample's source read is requested at prefetch priority and its token stays
-- pending for drain/cancel. The reported count is still the predicted key
-- count, never the number of scheduled jobs.
---@param idOrSymbol integer|string
---@return integer predicted key count
function AudioAssetProvider:prewarmBankBackground(idOrSymbol)
  local keys = self:_closureKeys(idOrSymbol)
  local queue = self._queue
  for _, key in ipairs(keys) do
    self:_scheduleBackgroundSource(key, queue)
  end
  return #keys
end

-- Forecast one sample's selected source without decoding it. The queue
-- coalesces the request with any pending read or actual acquisition of the same
-- content key; only this provider's own token is remembered, so cancel and
-- disposal never drop another consumer's interest.
---@param key string
---@param queue table<string, unknown>?
function AudioAssetProvider:_scheduleBackgroundSource(key, queue)
  if queue == nil then
    return
  end
  local reference = self:_sampleSource(key)
  if reference == nil then
    return
  end
  local pending = self._sampleSources[key]
  if pending ~= nil then
    local state = queue:poll(pending)
    if state == "pending" or state == "ready" then
      return
    end
    queue:cancel(pending)
    self._sampleSources[key] = nil
  end
  local token = queue:request("source", AudioCache.samplePath(key), "prefetch")
  self._sampleSources[key] = token --[[@as integer]]
end

-- Binds (or unbinds) the shared preparation queue this provider's payload
-- interest routes through; the selected runtime supplies the same queue that
-- answers its source acquisition.
---@param queue table<string, unknown>?
function AudioAssetProvider:bindQueue(queue)
  assert(queue == nil or type(queue.request) == "function", "sample queue must offer the preparation request shape")
  self._queue = queue
end

-- Adopt whatever predicted sample source work has completed. A ready token is
-- dropped through cancel, which returns its kernel lease to the shared owner
-- and trims it exactly once; the retained allocation stays available to the
-- next acquisition. The provider holds no decoded-owner handle, so it never
-- takes a lease it could not return. A failed prediction is dropped the same
-- way; real playback acquisition raises the selected source's failure.
---@return integer adopted count
function AudioAssetProvider:drainReadySamples()
  local queue = self._queue
  if queue == nil then
    return 0
  end
  local adopted = 0
  for key, token in pairs(self._sampleSources) do
    local state = queue:poll(token)
    if state == "ready" then
      queue:cancel(token)
      self._sampleSources[key] = nil
      adopted = adopted + 1
    elseif state == "failed" then
      queue:cancel(token)
      self._sampleSources[key] = nil
    end
  end
  return adopted
end

-- Returns one bank's outstanding required interests exactly once: pending
-- tokens cancel, and every taken source lease releases through the shared
-- decoded owner. A returned state is spent.
---@param queue table<string, unknown>?
---@param state {tokens: table<string, integer>, holds: table<string, AssetPreparationQueueSourceLease>}
---@return integer released hold count
local function returnRequiredState(queue, state)
  for key, token in pairs(state.tokens) do
    state.tokens[key] = nil
    assert(queue ~= nil, "pending required tokens imply a bound queue")
    queue:cancel(token)
  end
  local released = 0
  for key, lease in pairs(state.holds) do
    state.holds[key] = nil
    lease:release()
    released = released + 1
  end
  return released
end

-- Stages the required sample sources of one bank without voicing early:
-- true once every closure sample is base resident or retained, false while
-- any selected read is unsettled, nil plus a bank-and-key failure on a
-- terminal read or a sample whose payload was never published. The bank and
-- its closure must already resolve through the derived-bank paths; an
-- unresolvable bank raises instead of reporting ready. Missing interests
-- schedule at demand priority and rejoin instead of duplicating; ready reads
-- transfer into retained source leases that survive until
-- releaseBankSources, so eviction cannot reintroduce a synchronous disk
-- wait. Never cancels a ready read to idle.
---@param idOrSymbol integer|string
---@return boolean? ready true when every required source is held, false while pending, nil on failure
---@return string? terminal failure naming the bank and sample key, nil otherwise
function AudioAssetProvider:requireBankSources(idOrSymbol)
  local bank = self:bank(idOrSymbol)
  local bankId = assert(bank.id, "audio bank carries its numeric identity")
  local keys = self:_closureKeys(idOrSymbol)
  local memoKey = tostring(bankId)
  local state = self._requiredSources[memoKey]
  if state == nil then
    state = { tokens = {}, holds = {} }
    self._requiredSources[memoKey] = state
  end
  if state.failed ~= nil then
    return nil, state.failed
  end
  local queue = self._queue
  local pending = false
  ---@param key string
  ---@param cause unknown
  ---@return nil
  ---@return string
  local function fail(key, cause)
    local failure = "battle audio bank "
      .. tostring(bankId)
      .. " sample "
      .. tostring(key)
      .. " is not staged: "
      .. tostring(cause)
    if queue ~= nil then
      returnRequiredState(queue, state)
    end
    state.failed = failure
    return nil, failure
  end
  for _, key in ipairs(keys) do
    if state.holds[key] == nil then
      local reference = self._cacheFs:resolveAsset(AudioCache.samplePath(key))
      if reference == nil then
        return fail(key, "no published sample payload")
      end
      if reference.data == nil then
        if queue == nil then
          pending = true
        else
          local token = state.tokens[key]
          if token == nil then
            local background = self._sampleSources[key]
            if background ~= nil then
              local backgroundState = queue:poll(background)
              if backgroundState == "pending" or backgroundState == "ready" then
                queue:promote(background, "demand")
                self._sampleSources[key] = nil
                token = background
              else
                queue:cancel(background)
                self._sampleSources[key] = nil
              end
            end
            if token == nil then
              token = queue:request("source", AudioCache.samplePath(key), "demand")
            end
            state.tokens[key] = token --[[@as integer]]
          end
          local status, cause = queue:poll(token)
          if status == "ready" then
            state.tokens[key] = nil
            state.holds[key] = queue:takeSource(token)
          elseif status == "failed" then
            return fail(key, cause or "selected source read failed")
          else
            queue:promote(token, "demand")
            pending = true
          end
        end
      end
    end
  end
  if pending then
    return false, nil
  end
  return true, nil
end

-- Returns every retained required hold of one bank exactly once and forgets
-- the bank's requirement state. Pending required interests cancel without
-- counting toward the returned holds.
---@param idOrSymbol integer|string
---@return integer released hold count
function AudioAssetProvider:releaseBankSources(idOrSymbol)
  local bank = self:bank(idOrSymbol)
  local memoKey = tostring(assert(bank.id, "audio bank carries its numeric identity"))
  local state = self._requiredSources[memoKey]
  if state == nil then
    return 0
  end
  self._requiredSources[memoKey] = nil
  return returnRequiredState(self._queue, state)
end

-- Drops this provider's predicted source interests outside the caller's key
-- set. Voices and other consumers keep their own interests, and a physically
-- running read still settles before its bytes are released.
---@param predictedSet table<string, boolean>
---@return integer cancelled count
function AudioAssetProvider:cancelUnpredicted(predictedSet)
  local queue = self._queue
  if queue == nil then
    return 0
  end
  local cancelled = 0
  for key, token in pairs(self._sampleSources) do
    if not predictedSet[key] then
      queue:cancel(token)
      self._sampleSources[key] = nil
      cancelled = cancelled + 1
    end
  end
  return cancelled
end

-- Active sample interests only: how many records are backed by outstanding
-- acquisitions, the distinct resident backing bytes they attribute within this
-- provider, and the cumulative acquisition/miss counts. Shared residency is
-- the selected CPU owner's business, not this provider's.
---@return AudioAssetStatus
function AudioAssetProvider:status()
  local activeSamples = 0
  local attributed = {} ---@type table<string, integer>
  for _, record in pairs(self._activeSamples) do
    activeSamples = activeSamples + 1
    attributed[record.sourceId .. "\0" .. record.contentId] = record.byteSize
  end
  local activeSourceBytes = 0
  for _, byteSize in pairs(attributed) do
    activeSourceBytes = activeSourceBytes + byteSize
  end
  return {
    activeSamples = activeSamples,
    activeSourceBytes = activeSourceBytes,
    acquisitions = self._acquisitions,
    misses = self._misses,
  }
end

-- Releases the provider's metadata memos and any prediction token of its own.
-- Disposal requires every sounder stopped: the composition disposes its mixer
-- first, which returns each physical voice's acquisition, so no active sample
-- record may remain here. A queue already released by its owner discards its
-- own tokens, so a stale prediction token cannot block teardown.
function AudioAssetProvider:dispose()
  assert(
    next(self._activeSamples) == nil,
    "audio sample provider disposal requires every sample voice stopped and returned"
  )
  local queue = self._queue
  for key, token in pairs(self._sampleSources) do
    self._sampleSources[key] = nil
    if queue ~= nil then
      pcall(queue.cancel, queue, token)
    end
  end
  for _, state in pairs(self._requiredSources) do
    for key, token in pairs(state.tokens) do
      state.tokens[key] = nil
      if queue ~= nil then
        pcall(queue.cancel, queue, token)
      end
    end
    returnRequiredState(queue, state)
  end
  self._requiredSources = {}
  self._sequences = {}
  self._banks = {}
  self._bankKeysMemo = {}
  self._bankKeysOrder = {}
end

return AudioAssetProvider
