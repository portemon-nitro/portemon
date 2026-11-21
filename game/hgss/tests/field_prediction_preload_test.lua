-- Near-map working-set prediction for the field.
--
-- The field predicts the current map plus its one-hop neighbors (adjacent
-- outdoor coverage and indoor warp destinations) from the already computed
-- residency/loader membership: published day/night music, flag and traversal
-- overrides, soundplates, and the transitive script-audio closure resolve to
-- audio banks whose sample keys the selected resident store already carries,
-- while scene and menu images resolve through the one shared image owner. A
-- new prediction round supersedes the previous one, live music and radio
-- survive, and prediction itself retains no PCM: every sounding sample holds
-- one accountable acquisition over the resident bytes. Synthetic fixtures
-- only; the single live leg below compares against the producer closure on a
-- user-owned dump and skips loudly without one. No proximity scoring and no
-- recursive reachability.

local GeneratedCacheFixture = require("tests.support.GeneratedCacheFixture")
local Assert = require("tests.support.Assert")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local AudioBank = require("libs.assets.src.audio.AudioBank")
local AudioFixture = require("tests.support.AudioFixture")
local AudioAssetProvider = require("libs.hgss.src.audio.AudioAssetProvider")
local FieldAudioController = require("libs.hgss.src.audio.FieldAudioController")
local ResidentAssetCache = require("libs.hgss.src.field.ResidentAssetCache")

local T = { tests = {} }

local KEY_A = AudioFixture.key(1)
local KEY_B = AudioFixture.key(2)
local KEY_C = AudioFixture.key(3)
local KEY_D = AudioFixture.key(4)

local function direct(instruments, slot, key)
  instruments[slot] = { kind = "direct", voice = AudioFixture.sampleVoice(key) }
end

-- Synthetic audio world: day/night tunes on separate banks, a flag-override
-- tune sharing the day bank's first sample, a soundplate tune on the day
-- bank, and an unpredicted radio tune on its own bank.
local function predictionBundle()
  local bundle = AudioFixture.bundle()
  bundle.index.sequences = {
    [10] = { id = 10, symbol = "SEQ_DAY_TUNE", bankId = 12, playerId = 1 },
    [11] = { id = 11, symbol = "SEQ_NIGHT_TUNE", bankId = 13, playerId = 1 },
    [12] = { id = 12, symbol = "SEQ_FLAG_TUNE", bankId = 14, playerId = 1 },
    [13] = { id = 13, symbol = "SEQ_PLATE_TUNE", bankId = 12, playerId = 1 },
    [14] = { id = 14, symbol = "SEQ_RADIO_TUNE", bankId = 15, playerId = 1 },
  }
  bundle.index.sequenceBySymbol = {
    SEQ_DAY_TUNE = 10,
    SEQ_NIGHT_TUNE = 11,
    SEQ_FLAG_TUNE = 12,
    SEQ_PLATE_TUNE = 13,
    SEQ_RADIO_TUNE = 14,
  }
  bundle.index.banks = {
    [12] = { id = 12, symbol = "BANK_DAY" },
    [13] = { id = 13, symbol = "BANK_NIGHT" },
    [14] = { id = 14, symbol = "BANK_FLAG" },
    [15] = { id = 15, symbol = "BANK_RADIO" },
  }
  bundle.index.bankBySymbol = {
    BANK_DAY = 12,
    BANK_NIGHT = 13,
    BANK_FLAG = 14,
    BANK_RADIO = 15,
  }
  local dayInstruments = {}
  direct(dayInstruments, 0, KEY_A)
  direct(dayInstruments, 1, KEY_B)
  local nightInstruments = {}
  direct(nightInstruments, 0, KEY_C)
  local flagInstruments = {}
  direct(flagInstruments, 0, KEY_A)
  local radioInstruments = {}
  direct(radioInstruments, 0, KEY_D)
  bundle.sequences = {
    [10] = AudioFixture.sequence(10, "SEQ_DAY_TUNE", 12, 1),
    [11] = AudioFixture.sequence(11, "SEQ_NIGHT_TUNE", 13, 1),
    [12] = AudioFixture.sequence(12, "SEQ_FLAG_TUNE", 14, 1),
    [13] = AudioFixture.sequence(13, "SEQ_PLATE_TUNE", 12, 1),
    [14] = AudioFixture.sequence(14, "SEQ_RADIO_TUNE", 15, 1),
  }
  bundle.banks = {
    [12] = AudioFixture.bank(12, "BANK_DAY", { KEY_A }, dayInstruments),
    [13] = AudioFixture.bank(13, "BANK_NIGHT", { KEY_C }, nightInstruments),
    [14] = AudioFixture.bank(14, "BANK_FLAG", { KEY_A }, flagInstruments),
    [15] = AudioFixture.bank(15, "BANK_RADIO", { KEY_D }, radioInstruments),
  }
  bundle.samples = {
    [KEY_A] = AudioFixture.pcm16le({ 1000, 2000, 3000, 4000 }),
    [KEY_B] = AudioFixture.pcm16le({ 5000, 6000 }),
    [KEY_C] = AudioFixture.pcm16le({ 7000, 8000, 9000, 10000, 11000, 12000, 13000, 14000 }),
    [KEY_D] = AudioFixture.pcm16le({ 15000, 16000 }),
  }
  bundle.sampleMetadata = {
    [KEY_A] = AudioFixture.sampleMetadata(KEY_A, { frames = 4 }),
    [KEY_B] = AudioFixture.sampleMetadata(KEY_B, { frames = 2 }),
    [KEY_C] = AudioFixture.sampleMetadata(KEY_C, { frames = 8 }),
    [KEY_D] = AudioFixture.sampleMetadata(KEY_D, { frames = 2 }),
  }
  return bundle
end

-- The provider over the selected epoch's resident bytes: prediction resolves
-- bank metadata only, and an acquisition borrows the store's own compact PCM.
---@param bundle table?
---@return AudioAssetProvider provider
---@return ResidentCache store
local function readyProvider(bundle)
  local reader, store = AudioFixture.residentCache(bundle or predictionBundle())
  return AudioAssetProvider.new(reader, { acquireSource = AudioFixture.acquireSource() }), store
end

local function outdoorFieldData()
  return {
    music = {
      day = "SEQ_DAY_TUNE",
      night = "SEQ_NIGHT_TUNE",
      flagOverrides = { { flagId = 7, sequence = "SEQ_FLAG_TUNE" } },
    },
    soundplates = {
      { x = 0, xBounds = 31, z = 0, zBounds = 31, sequence = "SEQ_PLATE_TUNE" },
    },
  }
end

local function indoorFieldData()
  return {
    music = { day = "SEQ_NIGHT_TUNE", night = "SEQ_NIGHT_TUNE", flagOverrides = {} },
    soundplates = {},
  }
end

local function eventState(flags)
  local set = flags or {}
  return {
    isFlagSet = function(_, flagId)
      return set[flagId] == true
    end,
  }
end

local function stubSound()
  local state = { music = nil, radio = nil, plays = 0, stops = 0 }
  local sound = {}
  function sound:currentMusic()
    return state.music
  end
  function sound:playMusic(id)
    state.music = id
    state.plays = state.plays + 1
  end
  function sound:stopMusic()
    state.music = nil
    state.stops = state.stops + 1
  end
  function sound:currentRadioSequence()
    return state.radio
  end
  function sound:isMusicFadeActive()
    return false
  end
  function sound:stopSequenceWithFade(_, _) end
  function sound:moveSequenceVolume(_, _, _) end
  function sound:play(_) end
  function sound:stop(_) end
  return sound, state
end

local function predictionController(provider, sound, opts)
  opts = opts or {}
  local dayNight = opts.dayNight or "day"
  local flags = opts.flags or {}
  return FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState(flags),
    fieldPosition = function()
      return 0, 0
    end,
    dayNight = function()
      if type(dayNight) == "function" then
        return dayNight()
      end
      return dayNight
    end,
    fieldDataForMap = function()
      return nil
    end,
  })
end

-- A deterministic fake love.thread: records every push and construction but
-- never executes worker code. Tests drive completion explicitly by pushing
-- a response record, then calling a queue method documented to drain.
local function fakeThreadHost()
  local state = { channels = {}, allPushes = {}, threads = {} }
  local function newChannel()
    local values = {}
    local channel = {}
    function channel:push(value)
      values[#values + 1] = value
      state.allPushes[#state.allPushes + 1] = { channel = channel, value = value }
      return true
    end
    function channel:pop()
      if #values == 0 then
        return nil
      end
      return table.remove(values, 1)
    end
    function channel:demand(_)
      return channel:pop()
    end
    function channel:getCount()
      return #values
    end
    state.channels[#state.channels + 1] = channel
    return channel
  end
  local function newThread(_)
    local thread = { starts = 0, waits = 0, alive = true, errorText = nil }
    function thread:start()
      self.starts = self.starts + 1
    end
    function thread:wait()
      self.waits = self.waits + 1
    end
    function thread:getError()
      return self.errorText
    end
    function thread:isRunning()
      return self.alive and self.starts > 0 and self.waits == 0
    end
    state.threads[#state.threads + 1] = thread
    return thread
  end
  state.love = { thread = { newChannel = newChannel, newThread = newThread } }
  return state
end

local function fakeCacheFs()
  return {
    versionId = "near-ram-probe",
    resolve = function(_, relativePath)
      return "confined/" .. relativePath
    end,
    -- The queue resolves one immutable payload reference per request; this
    -- probe states only that shape, and a main-thread byte read stays an error.
    resolveAsset = function(_, relativePath)
      return {
        path = relativePath,
        sourceId = "base:near-ram-probe",
        contentId = "near-ram-probe\0" .. relativePath,
        size = 2,
        data = love.data.newByteData("{}"),
      }
    end,
    read = function()
      error("the preparation queue must not read cache bytes on the main thread", 0)
    end,
  }
end

-- The selected CPU owners a scene image owner or the prediction queue borrows:
-- one decoded kernel with no idle retention and one queue over the probe reader.
---@param host table the injected thread host
---@return table queue
---@return table decoded
local function sessionPreparation(host)
  local ok, mod = pcall(require, "libs.hgss.src.presentation.AssetPreparationQueue")
  Assert.isTrue(ok, "background preparation needs its shared queue boundary: " .. tostring(mod))
  local decoded = ResidentAssetCache.new({ idleByteLimit = 0, release = function() end })
  return mod.new(fakeCacheFs(), { decoded = decoded, thread = host.love.thread }), decoded
end

local function preparationQueue()
  local host = fakeThreadHost()
  local queue, decoded = sessionPreparation(host)
  return queue, host, decoded
end

-- The reply channel is the queue's second created channel; the first carries
-- outgoing requests.
local function replyTo(host, token, response)
  response.token = token
  host.channels[2]:push(response)
end

local function requestedJobToken(host, kind, seen)
  seen = seen or {}
  for _, entry in ipairs(host.allPushes) do
    local value = entry.value
    if type(value) == "table" and value.kind == kind and value.token ~= nil and not seen[value.token] then
      seen[value.token] = true
      return value.token
    end
  end
  return nil
end

local function fakeByteData(bytes)
  return love.data.newByteData(bytes)
end

local function imageDerivativeReply(width, height, pixelTag)
  return {
    ok = true,
    sourceHash = "source-" .. pixelTag,
    pixelHash = "pixels-" .. pixelTag,
    width = width,
    height = height,
    representation = "r8",
    colors = 2,
    indexData = fakeByteData(string.char(0, 1)),
    paletteData = fakeByteData(string.char(200, 10, 20, 255, 10, 200, 30, 255)),
  }
end

local function fakeGraphics()
  local graphics = { created = {} }
  function graphics.getImageFormats()
    return { r8 = true }
  end
  function graphics.newImage(_)
    local image = { released = false, releaseCount = 0 }
    function image:setFilter(_, _) end
    function image:setWrap(_, _) end
    function image:release()
      self.released = true
      self.releaseCount = self.releaseCount + 1
    end
    graphics.created[#graphics.created + 1] = image
    return image
  end
  return graphics
end

local function imagePool(graphics, host)
  local ok, mod = pcall(require, "libs.hgss.src.presentation.ImageAssetPool")
  Assert.isTrue(ok, "scene and menu images need the one shared image owner: " .. tostring(mod))
  local queue, decoded = sessionPreparation(host)
  return mod.new(fakeCacheFs(), { graphics = graphics, queue = queue, decoded = decoded })
end

-- A shared image owner with an explicit idle budget for budget-trim
-- assertions. Production budgets arrive with the driver that sets the
-- prune cadence; tests always pass their budget explicitly and never
-- rely on the pool default.
local function budgetedImagePool(graphics, host, idleByteLimit)
  local ok, mod = pcall(require, "libs.hgss.src.presentation.ImageAssetPool")
  Assert.isTrue(ok, "scene and menu images need the one shared image owner: " .. tostring(mod))
  local queue, decoded = sessionPreparation(host)
  return mod.new(fakeCacheFs(), {
    graphics = graphics,
    queue = queue,
    decoded = decoded,
    idleByteLimit = idleByteLimit,
  })
end

local function matchingSampler()
  return { wrapX = "repeat", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }
end

-- Scenario 1: nearby predicted sounds and images rest in RAM before first
-- use. Outdoor map plus adjacent coverage, an indoor one-hop warp
-- destination, the published script closure, and day/night alternates all
-- join one prediction; affordable predicted samples are actual packed RAM
-- buffers (no synchronous decode on first note) and image demand resolves
-- through the single shared owner. The live leg compares the same predicted
-- bank set against the producer closure on a user-owned dump.
function T.tests.predicted_near_sounds_and_images_rest_in_ram_before_first_use(context)
  local provider, store = readyProvider()
  local sound = stubSound()
  local night = { value = false }
  local controller = predictionController(provider, sound, {
    dayNight = function()
      if night.value then
        return "night"
      end
      return "day"
    end,
  })

  -- The published script closure joins the map-derived banks through the
  -- same sequence resolution, so shared banks collapse to one entry.
  local scriptSequences = { "SEQ_PLATE_TUNE" }
  local seenBank = {}
  local predictedBanks = {}
  local function noteBank(idOrSymbol)
    local bank = provider:bank(idOrSymbol)
    if not seenBank[bank.id] then
      seenBank[bank.id] = true
      predictedBanks[#predictedBanks + 1] = bank
    end
  end
  noteBank(provider:sequence("SEQ_DAY_TUNE").bankId)
  noteBank(provider:sequence("SEQ_NIGHT_TUNE").bankId)
  for _, symbol in ipairs(scriptSequences) do
    noteBank(provider:sequence(symbol).bankId)
  end
  Assert.equal(#predictedBanks, 2, "day/plate share one bank beside the night bank")

  -- Advance prediction while gameplay continues: outdoor day, outdoor night,
  -- then the indoor warp destination. Prediction enrolls bank metadata and
  -- sample keys only, so it pins no PCM; the first use of a predicted key
  -- borrows the resident bytes instead of decoding a private copy.
  controller:prewarmMapMusic({ fieldData = outdoorFieldData() })
  night.value = true
  controller:prewarmMapMusic({ fieldData = outdoorFieldData() })
  controller:prewarmMapMusic({ fieldData = indoorFieldData() })
  Assert.equal(provider:status().activeSamples, 0, "prediction retains no PCM of its own")
  for _, key in ipairs({ KEY_A, KEY_B, KEY_C }) do
    local missesBefore = provider:status().misses
    local lease = provider:acquireSample(key)
    local sample = assert(lease.value)
    Assert.equal(
      provider:status().misses,
      missesBefore + 1,
      "predicted sample " .. key .. " becomes one active record on first use"
    )
    Assert.isNil(sample.pcm[1], "a resident sample is a packed buffer, never a per-frame Lua table")
    Assert.isTrue(sample.pcm.frames > 0, "a resident sample carries its packed frames")
    Assert.isTrue(
      sample.pcm.data == store:readData(AudioCache.samplePath(key)),
      "the acquisition borrows the resident sample bytes instead of copying them"
    )
    lease:release()
  end
  Assert.equal(provider:status().activeSamples, 0, "returning every acquisition retains no PCM again")

  -- Bank sizes and key sharing stay profiled through the census: the flag
  -- bank reuses the day sample, so the predicted set counts it once.
  local dayKeys = AudioBank.sampleKeys(provider:bank(12))
  Assert.notNil(dayKeys, "bank sample enumeration is the input to predicted-size accounting")
  Assert.equal(#dayKeys, 2, "the day bank enumerates exactly its two samples")
  local flagKeys = AudioBank.sampleKeys(provider:bank(14))
  Assert.notNil(flagKeys, "flag-override banks enumerate through the same key walk")
  local distinct = {}
  for _, bank in ipairs({ provider:bank(12), provider:bank(13), provider:bank(14) }) do
    for _, key in ipairs(AudioBank.sampleKeys(bank) or {}) do
      distinct[key] = true
    end
  end
  local distinctCount = 0
  for _ in pairs(distinct) do
    distinctCount = distinctCount + 1
  end
  Assert.equal(distinctCount, 3, "the day/night/flag prediction holds three distinct samples, not four")

  -- Near image demand resolves through the single shared owner: the same
  -- logical path under the same sampler state is one physical image, and a
  -- neighboring scene reuses it instead of building a second graph.
  local graphics = fakeGraphics()
  local host = fakeThreadHost()
  local pool = imagePool(graphics, host)
  local sampler = matchingSampler()
  local nearToken = pool:request("gen/field/near-a.png", sampler, "prefetch")
  local job = requestedJobToken(host, "image-derivative")
  Assert.notNil(job, "near image interest enrolls background classification work")
  replyTo(host, job, imageDerivativeReply(2, 1, "near-a"))
  Assert.equal(pool:poll(nearToken), "ready", "near image classification stages without blocking gameplay")
  local nearLease = pool:acquire(nearToken)
  local againToken = pool:request("gen/field/near-a.png", sampler, "prefetch")
  local againJob = requestedJobToken(host, "image-derivative", { [job] = true })
  replyTo(host, againJob, imageDerivativeReply(2, 1, "near-a"))
  Assert.equal(pool:poll(againToken), "ready", "the repeated near request stages as well")
  local againLease = pool:acquire(againToken)
  Assert.isTrue(againLease.image == nearLease.image, "one logical near image is one physical image")
  Assert.isTrue(pool:release(nearLease), "first near lease returns its borrow")
  Assert.isTrue(pool:release(againLease), "second near lease returns its borrow")
  pool:dispose()

  -- Live leg: the same predicted bank set must match the producer closure
  -- for a real map. Needs a user-owned dump and prepared field records;
  -- anything else skips loudly instead of passing silently.
  local hasRom = context ~= nil and type(context.hasCapability) == "function" and context:hasCapability("rom_dump")
  if not hasRom then
    context:skip("the live closure comparison needs a user-owned dump; synthetic prediction coverage ran above")
  end
  local romOk, GameVersion = pcall(require, "romdump.src.source.GameVersion")
  Assert.isTrue(romOk, "the live comparison needs the dump version set: " .. tostring(GameVersion))
  local importerOk, RomImporter = pcall(require, "romdump.src.source.RomImporter")
  Assert.isTrue(importerOk, "the live comparison needs dump readiness: " .. tostring(RomImporter))
  local readyVersion = nil
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      readyVersion = versionId
      break
    end
  end
  if readyVersion == nil then
    context:skip("no ready game dump behind the capability gate")
  end
  local cacheOk, CacheFs = pcall(require, "libs.storage.src.CacheFs")
  Assert.isTrue(cacheOk, "the live comparison needs the versioned cache: " .. tostring(CacheFs))
  local planOk, LogicalFieldPlan = pcall(require, "romdump.src.build.LogicalFieldPlan")
  Assert.isTrue(planOk, "the live comparison needs the producer closure reference: " .. tostring(LogicalFieldPlan))
  local fieldOk, FieldMapDataCache = pcall(require, "libs.assets.src.field.FieldMapDataCache")
  Assert.isTrue(fieldOk, "the live comparison needs published field records: " .. tostring(FieldMapDataCache))
  local scriptOk, ScriptCache = pcall(require, "libs.assets.src.ScriptCache")
  Assert.isTrue(scriptOk, "the live comparison needs the published script index: " .. tostring(ScriptCache))
  local cacheFs = GeneratedCacheFixture.reader(readyVersion)
  local audioIndex = cacheFs:loadLua(AudioCache.indexPath())
  if audioIndex == nil then
    context:skip("the prepared scope carries no audio artifacts; synthetic prediction coverage ran above")
  end
  local liveProvider = AudioAssetProvider.new(cacheFs, { acquireSource = AudioFixture.acquireSource() })
  local mapId = nil
  local fieldRecord = nil
  for candidate = 1, 64 do
    local record = cacheFs:loadLua(FieldMapDataCache.fieldPath(candidate))
    if record ~= nil then
      mapId = candidate
      fieldRecord = record
      break
    end
  end
  if mapId == nil then
    context:skip("the prepared scope has no field records; seed a field scope to run the live comparison")
  end
  local closure = {}
  local scriptIndex = cacheFs:loadLua(ScriptCache.activeIndexPath())
  if scriptIndex ~= nil then
    closure = ScriptCache.audioSequencesForMember(scriptIndex, 1) or {}
  end
  local members = LogicalFieldPlan.members(mapId, fieldRecord, closure, {
    sequences = audioIndex.sequences,
    sequenceBySymbol = audioIndex.sequenceBySymbol,
  })
  local referenceBanks = {}
  for _, member in ipairs(members) do
    if member.kind == "audio-bank" then
      referenceBanks[#referenceBanks + 1] = tonumber(member.key)
    end
  end
  Assert.isTrue(#referenceBanks > 0, "the producer closure names audio banks for the live map")
  -- Only banks the prepared scope actually carries can be compared: a scope
  -- prepared for another suite leaves a bank out, and naming it is not this
  -- suite's failure.
  local compared = 0
  for _, bankId in ipairs(referenceBanks) do
    if cacheFs:resolveAsset(AudioCache.bankPath(bankId)) ~= nil then
      compared = compared + 1
      liveProvider:prewarmBank(bankId)
      local keys = AudioBank.sampleKeys(liveProvider:bank(bankId)) or {}
      for _, key in ipairs(keys) do
        local lease = liveProvider:acquireSample(key)
        Assert.isTrue(
          assert(lease.value).pcm.data == cacheFs:readData(AudioCache.samplePath(key)),
          "the predicted sample for bank " .. tostring(bankId) .. " is borrowed from the installed bytes"
        )
        lease:release()
      end
    end
  end
  Assert.isTrue(compared > 0, "the prepared scope must carry at least one predicted audio bank for comparison")
end

-- Scenario 2: new predictions supersede stale preparation work without
-- dropping live sound. A time/flag/override change plus a warp walk issues a
-- new prediction round while earlier background work is still pending: the
-- new current work takes demand priority, stale replies never publish, and
-- the sounding music plus latched radio survive until their own stop.
function T.tests.new_predictions_supersede_stale_audio_work_without_dropping_live_sound(_)
  local provider = readyProvider()
  local sound, soundState = stubSound()
  local flags = {}
  local controller = predictionController(provider, sound, { flags = flags })

  -- Gameplay enters the outdoor map and its day music starts; a latched
  -- radio on unchanged music survives re-entry instead of restarting.
  controller:enterMap({ fieldData = outdoorFieldData() }, { play = true })
  local dayTrack = controller:effectiveMusic()
  Assert.notNil(dayTrack, "outdoor entry selects a day track")
  Assert.equal(soundState.music, dayTrack, "outdoor entry starts the selected track")
  local playsAfterEntry = soundState.plays
  soundState.radio = "SEQ_RADIO_TUNE"
  controller:enterMap({ fieldData = outdoorFieldData() }, { play = true })
  Assert.equal(soundState.plays, playsAfterEntry, "a surviving radio is never restarted behind unchanged music")

  -- Prediction resolves the closure of every predicted bank without holding
  -- a payload; repeated acquisitions of one key share the single backing.
  for _, bankId in ipairs(controller:predictedBankIds()) do
    Assert.equal(provider:prewarmBankBackground(bankId), #(AudioBank.sampleKeys(provider:bank(bankId)) or {}))
  end
  Assert.equal(provider:status().activeSamples, 0, "a superseding round holds no sample payload")
  local firstAcquisition = provider:acquireSample(KEY_A)
  local secondAcquisition = provider:acquireSample(KEY_A)
  Assert.isTrue(
    secondAcquisition.value.pcm == firstAcquisition.value.pcm,
    "one key keeps one backing across acquisitions"
  )
  Assert.equal(provider:status().activeSamples, 1, "repeated acquisitions share one active record")
  firstAcquisition:release()
  secondAcquisition:release()

  -- An unpredicted radio tune stays acquirable on demand: playback outside
  -- the field prediction reads exact samples through the same path.
  local radioLease = provider:acquireSample(KEY_D)
  local radioSample = assert(radioLease.value)
  Assert.equal(radioSample.pcm.frames, 2, "the on-demand radio sample carries its packed frames")
  local first = radioSample.pcm:read(0)
  local second = radioSample.pcm:read(1)
  Assert.equal(first, 15000, "the on-demand radio sample renders its exact first frame")
  Assert.equal(second, 16000, "the on-demand radio sample renders its exact second frame")
  radioLease:release()

  -- Walking across the warp under a flag plus persisted override changes
  -- the effective track; the radio latch still governs the transition.
  flags[7] = true
  controller:setMusicOverride("SEQ_NIGHT_TUNE")
  Assert.equal(controller:effectiveMusic(), provider:sequence("SEQ_NIGHT_TUNE").id, "the override wins over headers")
  controller:enterMap({ fieldData = indoorFieldData() }, { play = true })
  Assert.equal(soundState.music, dayTrack, "the latched radio survives the warp walk behind changed music")

  -- The new round's work travels as background demand ahead of leftover
  -- prefetch: demand dispatches before queued prefetch, cancelled stale
  -- work never transfers, and the current round takes exactly its payload.
  local queue, host, decoded = preparationQueue()
  local prefetchToken = queue:request("image-derivative", "gen/field/stale.png", "prefetch")
  local demandToken = queue:request("image-derivative", "gen/audio/current.png", "demand")
  local firstDispatched = nil
  for _, entry in ipairs(host.allPushes) do
    local value = entry.value
    if type(value) == "table" and value.token ~= nil and value.path ~= nil then
      firstDispatched = value.token
      break
    end
  end
  Assert.equal(firstDispatched, prefetchToken, "the first enrolled job dispatches while the worker is idle")
  Assert.equal(queue:poll(demandToken), "pending", "demand work waits for the physical worker slot")
  queue:cancel(prefetchToken)
  replyTo(host, prefetchToken, { ok = true })
  Assert.equal(queue:poll(demandToken), "pending", "the freed worker slot dispatches the demand round")
  replyTo(host, demandToken, imageDerivativeReply(3, 1, "current"))
  Assert.equal(queue:poll(demandToken), "ready", "the current round completes once the worker frees")
  local lease = queue:take(demandToken)
  local payload = assert(lease.value).payload
  Assert.equal(payload.width, 3, "the current round takes exactly its own payload")
  Assert.equal(payload.pixelHash, "pixels-current", "a stale reply never overwrites the current payload")
  Assert.isFalse(pcall(queue.take, queue, prefetchToken), "cancelled stale work never transfers a payload")
  Assert.isTrue(decoded:returnLease(lease), "the current round returns its decoded interest")
  decoded:trim()
  queue:release()
end

function T.tests.image_idle_budget_trims_oldest_first_and_reuse_shields_the_predicted_tail(_)
  local graphics = fakeGraphics()
  local host = fakeThreadHost()
  local pool = budgetedImagePool(graphics, host, 25)
  local sampler = matchingSampler()
  local otherSampler = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }
  local seen = {}
  local function warm(tag, width, height)
    local token = pool:request("gen/field/" .. tag .. ".png", sampler, "prefetch")
    local job = requestedJobToken(host, "image-derivative", seen)
    Assert.notNil(job, "image interest enrolls classification work for " .. tag)
    replyTo(host, job, imageDerivativeReply(width or 2, height or 1, tag))
    Assert.equal(pool:poll(token), "ready", "image " .. tag .. " stages without blocking")
    return pool:acquire(token)
  end
  -- Re-enroll resident interest without acquiring: the enrollment itself
  -- refreshes the resident pair. A still-resident path resolves its cached
  -- ticket without worker work, so the reuse token polls ready at once; a
  -- genuine miss still enrolls classification work, and the pushed job is
  -- consumed so later demand resolves its own token.
  local function reuse(tag, useSampler)
    local path = "gen/field/" .. tag .. ".png"
    local token = pool:request(path, useSampler, "prefetch")
    local job = requestedJobToken(host, "image-derivative", seen)
    if job == nil then
      Assert.equal(
        pool:poll(token),
        "ready",
        "resident reuse resolves its cached ticket without worker work for " .. path
      )
      -- A ready cached ticket reserves its physical pair until consumed,
      -- so terminate the enrollment-only interest once readiness is shown.
      Assert.isTrue(pool:cancel(token), "reuse releases its cached ticket for " .. path)
    else
      replyTo(host, job, imageDerivativeReply(2, 1, tag))
    end
  end

  -- Three idle images total 30 bytes against the 25-byte budget: the trim
  -- evicts exactly the oldest one and reports the surviving census.
  local first = warm("trim-a")
  local second = warm("trim-b")
  local third = warm("trim-c")
  Assert.isTrue(pool:release(first), "the oldest lease returns its borrow")
  Assert.isTrue(pool:release(second), "the middle lease returns its borrow")
  Assert.isTrue(pool:release(third), "the newest lease returns its borrow")
  Assert.equal(pool:prune(), 1, "the over-budget trim evicts exactly the oldest unleased image")
  Assert.isTrue(first.image.released, "the oldest unleased image leaves first")
  Assert.isFalse(second.image.released, "a fitting newer image survives the trim")
  Assert.isFalse(third.image.released, "the newest image survives the trim")
  Assert.equal(pool:stats().idleBytes, 20, "the census counts the two surviving idle images")

  -- Request-time reuse beats pure age order: re-requesting the oldest
  -- resident path refreshes it, so the trim takes the non-reused tail
  -- first instead.
  local fourth = warm("trim-d")
  Assert.isTrue(pool:release(fourth), "the newest lease returns its borrow")
  reuse("trim-b", sampler)
  Assert.equal(pool:prune(), 1, "reuse shields the oldest entry and trims the historical idle tail first")
  Assert.isTrue(third.image.released, "the non-reused tail leaves before reused entries")
  Assert.isFalse(second.image.released, "the reused oldest entry survives its own trim round")
  Assert.isFalse(fourth.image.released, "the newest image survives the reuse-shielded trim")

  -- A different sampler state refreshes nothing: the shared identity
  -- includes the sampler, so cross-sampler interest never shields. The
  -- cross-sampler target is the oldest entry, so a shielding bug would
  -- evict the middle entry instead.
  local fifth = warm("trim-e")
  Assert.isTrue(pool:release(fifth), "the round lease returns its borrow")
  reuse("trim-d", otherSampler)
  Assert.equal(pool:prune(), 1, "cross-sampler reuse shields nothing")
  Assert.isTrue(fourth.image.released, "the oldest entry leaves when only cross-sampler interest exists")
  Assert.isFalse(second.image.released, "the middle entry survives the trim")
  Assert.isFalse(fifth.image.released, "the newest image survives the trim")

  -- Borrowed pairs never leave for budget.
  local sixth = warm("trim-f")
  Assert.equal(pool:prune(), 0, "a fitting trim evicts nothing while a pair is borrowed")
  Assert.isFalse(sixth.image.released, "a borrowed pair survives prune passes")
  Assert.equal(pool:stats().pinnedBytes, 10, "the census counts the borrowed image as pinned")
  Assert.isTrue(pool:release(sixth), "the borrowed lease returns its borrow")
  Assert.equal(pool:prune(), 1, "the released pair trims once it no longer fits beside the survivors")

  -- An oversize candidate is evicted singly and re-warms deterministically:
  -- no oscillation, no demand failure, the same physical identity.
  local overGraphics = fakeGraphics()
  local overHost = fakeThreadHost()
  local overPool = budgetedImagePool(overGraphics, overHost, 25)
  local overSeen = {}
  local function warmBig(tag)
    local token = overPool:request("gen/field/" .. tag .. ".png", sampler, "prefetch")
    local job = requestedJobToken(overHost, "image-derivative", overSeen)
    Assert.notNil(job, "oversize interest enrolls classification work for " .. tag)
    replyTo(overHost, job, {
      ok = true,
      sourceHash = "source-" .. tag,
      pixelHash = "pixels-" .. tag,
      width = 20,
      height = 1,
      representation = "r8",
      colors = 2,
      indexData = fakeByteData(string.rep("\0", 20)),
      paletteData = fakeByteData(string.char(200, 10, 20, 255, 10, 200, 30, 255)),
    })
    Assert.equal(overPool:poll(token), "ready", "oversize image " .. tag .. " stages without blocking")
    return overPool:acquire(token)
  end
  local big = warmBig("trim-big")
  local bigKey = big.physicalKey
  Assert.isTrue(overPool:release(big), "the oversize lease returns its borrow")
  Assert.equal(overPool:prune(), 1, "the oversize idle image is evicted singly")
  Assert.equal(overPool:stats().idleBytes, 0, "nothing resident survives the oversize eviction")
  local bigAgain = warmBig("trim-big")
  Assert.equal(bigAgain.physicalKey, bigKey, "re-warming resolves the same physical identity")
  Assert.isTrue(overPool:release(bigAgain), "the re-warmed lease returns its borrow")
  Assert.equal(overPool:prune(), 1, "the re-warmed oversize image evicts exactly once again")
  overPool:dispose()
  pool:dispose()
end

local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local AssetNeedsRegistry = require("libs.hgss.src.field.AssetNeedsRegistry")
local ScriptCache = require("libs.assets.src.ScriptCache")

-- A minimal production-shaped runtime for the private prediction driver:
-- fixed map, music, audio round, day band, coverage anchor, and stable
-- membership, with a toggling hold sensor behind the existing session
-- method and counters for background demand actions.
local function holdPredictionRuntime(initialHold)
  local hold = { value = initialHold }
  local counters = { holdCalls = 0, prewarms = 0, drains = 0, prunes = 0 }
  local audio = {
    effectiveMusic = function()
      return 42
    end,
    predictionEpoch = function()
      return 7
    end,
    predictedBanksFor = function()
      return {}
    end,
    prewarmAudioBanks = function()
      counters.prewarms = counters.prewarms + 1
    end,
    drainBackgroundSamples = function()
      counters.drains = counters.drains + 1
    end,
    bankSampleKeys = function()
      return {}
    end,
    cancelUnpredictedSamples = function() end,
  }
  local residency = {
    coverage = { anchorX = 3, anchorZ = 5 },
    predictionMembership = function()
      return {}, {}
    end,
    mapForId = function()
      return { fieldData = {} }
    end,
  }
  local session = {
    currentMap = { mapId = 11 },
  }
  function session:isForegroundHoldActive()
    counters.holdCalls = counters.holdCalls + 1
    if hold.error ~= nil then
      error(hold.error, 0)
    end
    return hold.value
  end
  local runtime = setmetatable({
    assetPreparation = {},
    assetNeeds = AssetNeedsRegistry.new(),
    audio = audio,
    residency = residency,
    runtimeMap = { mapId = 11 },
    session = session,
    mapMusicDayNight = function()
      return "day"
    end,
    imageAssets = {
      prune = function()
        counters.prunes = counters.prunes + 1
      end,
    },
  }, FieldRuntime)
  return runtime, hold, counters
end

local function predictionDriverOf(runtime)
  local driver = runtime._predictionDriver
  Assert.notNil(driver, "prediction refresh owns its fingerprint driver")
  Assert.notNil(driver.fingerprint, "prediction refresh commits a fingerprint")
  return driver
end

local function assertHoldMarker(fingerprint, marker, message)
  Assert.isTrue(fingerprint:find("|" .. marker .. "|", 1, true) ~= nil, message .. " (got " .. fingerprint .. ")")
end

-- The predicted working-set fingerprint records the actual hold state:
-- released -> held -> released with every other factor fixed drives one
-- epoch per real transition and none for steady repeats, while background
-- demand, idle trim, and image prune actions track committed epochs only.
function T.tests.foreground_hold_transitions_drive_prediction_epochs_without_spurious_recommits()
  local runtime, hold, counters = holdPredictionRuntime(false)

  runtime:_refreshPrediction()
  local driver = predictionDriverOf(runtime)
  assertHoldMarker(driver.fingerprint, "h0", "a hold sensor returning false records the released marker")
  Assert.equal(driver.epoch, 1, "the first prediction round commits one epoch")
  Assert.isTrue(counters.holdCalls > 0, "the fingerprint consults the hold sensor")
  local prewarms = counters.prewarms

  runtime:_refreshPrediction()
  Assert.equal(driver.epoch, 1, "an unchanged released hold commits no new epoch")
  Assert.equal(counters.prewarms, prewarms, "a steady hold enrolls no new background demand")

  hold.value = true
  runtime:_refreshPrediction()
  assertHoldMarker(driver.fingerprint, "h1", "a hold sensor returning true records the held marker")
  Assert.equal(driver.epoch, 2, "entering the hold commits exactly one epoch")
  Assert.equal(counters.prewarms, prewarms + 1, "entering the hold re-enrolls background demand once")

  runtime:_refreshPrediction()
  Assert.equal(driver.epoch, 2, "an unchanged held state commits no new epoch")
  Assert.equal(counters.prewarms, prewarms + 1, "a steady held state enrolls no further demand")

  hold.value = false
  runtime:_refreshPrediction()
  assertHoldMarker(driver.fingerprint, "h0", "leaving the hold records the released marker again")
  Assert.equal(driver.epoch, 3, "leaving the hold commits exactly one epoch")

  runtime:_refreshPrediction()
  Assert.equal(driver.epoch, 3, "settling back to released commits no further epoch")
  Assert.equal(counters.prunes, driver.epoch, "every committed epoch prunes idle images exactly once")
end

-- A failing hold sensor must surface instead of settling on either marker:
-- the refresh propagates the original failure and commits nothing.
function T.tests.foreground_hold_sensor_failure_propagates_instead_of_encoding_a_state()
  local runtime, hold = holdPredictionRuntime(false)
  runtime:_refreshPrediction()
  Assert.equal(runtime._predictionDriver.epoch, 1, "the released baseline commits first")

  hold.error = "foreground hold sensor failed"
  local ok, err = pcall(function()
    runtime:_refreshPrediction()
  end)
  Assert.isFalse(ok, "a failing hold sensor must propagate instead of encoding a hold state")
  Assert.isTrue(
    tostring(err):find("foreground hold sensor failed", 1, true) ~= nil,
    "the propagated failure retains its original diagnostic"
  )
  Assert.equal(runtime._predictionDriver.epoch, 1, "a failed sensor commits no new epoch")
end

-- The hold report is a strict boolean: anything else fails loudly instead
-- of coercing to a marker, and commits nothing.
function T.tests.foreground_hold_sensor_must_report_a_boolean()
  local runtime, hold = holdPredictionRuntime(false)
  runtime:_refreshPrediction()
  Assert.equal(runtime._predictionDriver.epoch, 1, "the released baseline commits first")

  hold.value = "held"
  local ok = pcall(function()
    runtime:_refreshPrediction()
  end)
  Assert.isFalse(ok, "a nonboolean hold report must fail loudly instead of coercing")
  Assert.equal(runtime._predictionDriver.epoch, 1, "a malformed hold report commits no new epoch")
end

-- A steady hold never masks the other fingerprint signals: a music change
-- still commits exactly once with the hold marker untouched, and a
-- pre-composition runtime without a session still predicts.
function T.tests.steady_hold_preserves_other_prediction_signals()
  local runtime = holdPredictionRuntime(false)
  runtime:_refreshPrediction()
  local driver = predictionDriverOf(runtime)
  local epoch = driver.epoch
  local before = driver.fingerprint:match("|(h%d)|")
  Assert.notNil(before, "the baseline fingerprint carries a hold marker")

  runtime.audio.effectiveMusic = function()
    return 99
  end
  runtime:_refreshPrediction()
  Assert.equal(driver.epoch, epoch + 1, "a music change under a steady hold still commits")
  Assert.equal(driver.fingerprint:match("|(h%d)|"), before, "a music change leaves the steady hold marker untouched")

  runtime.session = nil
  local ok, err = pcall(function()
    runtime:_refreshPrediction()
  end)
  Assert.isTrue(ok, "a pre-composition runtime without a session still predicts (got " .. tostring(err) .. ")")
end

-- A runtime whose current map's script member carries asset needs through the
-- published script index, with a recording preparer for the "probe" kind.
local function assetNeedsRuntime(spec)
  local runtime = holdPredictionRuntime(false)
  local log = {}
  -- The published layout: one active index names the generation and carries
  -- the per-member closures.
  local generation, marker = string.rep("a", 40), "script-cache-v6:rom:dep"
  local resources = {}
  local emptyClosures = {}
  for position, entry in ipairs(spec.resources or {}) do
    resources[position] = { id = entry.id, member = entry.member, scriptIndex = entry.scriptIndex or 0 }
    emptyClosures[tostring(entry.member)] = {}
  end
  local memberAudio = spec.memberAudioSequences or {}
  for member, closure in pairs(emptyClosures) do
    memberAudio[member] = memberAudio[member] or closure
  end
  local memberNeeds = spec.memberAssetNeeds or {}
  for member, closure in pairs(emptyClosures) do
    memberNeeds[member] = memberNeeds[member] or closure
  end
  local index = {
    schema = ScriptCache.INDEX_SCHEMA,
    version = "heartgold",
    generation = generation,
    marker = marker,
    memberCount = 1,
    scriptMemberCount = 1,
    skippedMemberCount = 0,
    scriptCount = #resources,
    resourceCount = #resources,
    memberAssetNeeds = memberNeeds,
    memberAudioSequences = memberAudio,
    resources = resources,
  }
  runtime.cacheFs = {
    versionId = "heartgold",
    -- The prediction runtime resolves each demanded payload as one immutable
    -- reference, the same shape an installed epoch serves.
    resolveAsset = function(_, path)
      return {
        path = path,
        sourceId = "base:prediction-fixture",
        contentId = "prediction-fixture\0" .. path,
        size = 2,
        data = love.data.newByteData("{}"),
      }
    end,
    read = function(_, path)
      if path == ScriptCache.memberPath(generation, 0) then
        return "return {}\n"
      end
      return nil
    end,
    exists = function(_, path)
      return path == ScriptCache.memberPath(generation, 0)
    end,
    loadLua = function(_, path)
      if path == ScriptCache.activeIndexPath() then
        return index
      end
      return nil
    end,
  }
  runtime.residency.mapForId = function(_, mapId)
    return { fieldData = { scriptBankId = spec.memberByMap[mapId] } }
  end
  runtime.scripts = { registry = { overrideAssetNeeds = spec.overrideAssetNeeds or function() end } }
  if spec.withPreparer ~= false then
    runtime.assetNeeds:register("probe", {
      start = function(id)
        log[#log + 1] = "start:" .. id
        return {
          step = function()
            return true
          end,
          cancel = function()
            log[#log + 1] = "cancel:" .. id
          end,
        }
      end,
    })
  end
  return runtime, log
end

-- The prediction commit enrolls the current map's script member needs from
-- the published index with the asset-needs registry.
function T.tests.commit_enrolls_the_current_maps_member_needs()
  local runtime, log = assetNeedsRuntime({
    memberAssetNeeds = { ["5"] = { "probe:a" }, ["6"] = { "probe:b" } },
    memberByMap = { [11] = 5 },
  })
  runtime:_refreshPrediction()
  Assert.deepEqual(log, { "start:a" })
  runtime.session.currentMap = { mapId = 11 }
  runtime:_refreshPrediction()
  Assert.deepEqual(log, { "start:a" }, "an unchanged map enrolls nothing again")
end

-- The closures live in the active generation's index, not in the small
-- selector the cache publishes next to it: the commit reads the script audio
-- closure of the current map's member from there.
function T.tests.commit_reads_closures_through_the_active_generation()
  local runtime = assetNeedsRuntime({
    memberAssetNeeds = { ["5"] = {} },
    memberAudioSequences = { ["5"] = { "SEQ_CLOSURE" } },
    memberByMap = { [11] = 5 },
  })
  local captured
  runtime.audio.predictedBanksFor = function(_, _, symbols)
    captured = captured or symbols
    return {}
  end
  runtime:_refreshPrediction()
  Assert.deepEqual(captured, { "SEQ_CLOSURE" }, "the current member's audio closure reaches the bank prediction")
end

function T.tests.commit_unions_override_needs_for_member_resources()
  local runtime, log = assetNeedsRuntime({
    memberAssetNeeds = { ["5"] = { "probe:a" } },
    memberByMap = { [11] = 5 },
    resources = {
      { id = "s.in", member = 5, scriptIndex = 0 },
      { id = "s.out", member = 6, scriptIndex = 0 },
    },
    overrideAssetNeeds = function(_, id)
      if id == "s.in" then
        return { "probe:override" }
      end
      return { "probe:elsewhere" }
    end,
  })
  runtime:_refreshPrediction()
  table.sort(log)
  Assert.deepEqual(log, { "start:a", "start:override" }, "only the member's own override resources count")
end

function T.tests.map_change_retains_only_the_new_maps_needs()
  local runtime, log = assetNeedsRuntime({
    memberAssetNeeds = { ["5"] = { "probe:a" }, ["6"] = { "probe:b" } },
    memberByMap = { [11] = 5, [12] = 6 },
  })
  runtime:_refreshPrediction()
  runtime.session.currentMap = { mapId = 12 }
  runtime.runtimeMap = { mapId = 12 }
  runtime:_refreshPrediction()
  table.sort(log)
  Assert.deepEqual(log, { "cancel:a", "start:a", "start:b" }, "the old map's need is dropped, the new one starts")
end

function T.tests.malformed_index_needs_are_skipped_without_error()
  local runtime, log = assetNeedsRuntime({
    memberAssetNeeds = { ["5"] = { "probe:b", "probe:a" } },
    memberByMap = { [11] = 5 },
  })
  local ok, err = pcall(function()
    runtime:_refreshPrediction()
  end)
  Assert.isTrue(ok, tostring(err))
  Assert.deepEqual(log, {})
end

function T.tests.a_runtime_without_preparers_enrolls_nothing()
  local runtime, log = assetNeedsRuntime({
    memberAssetNeeds = { ["5"] = { "probe:a" } },
    memberByMap = { [11] = 5 },
    withPreparer = false,
  })
  local ok, err = pcall(function()
    runtime:_refreshPrediction()
  end)
  Assert.isTrue(ok, tostring(err))
  Assert.deepEqual(log, {})
end

return { tests = T.tests }
