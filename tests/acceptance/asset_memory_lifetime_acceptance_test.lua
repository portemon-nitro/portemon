-- Retained-session asset memory baseline. A single deterministic harness
-- replay (one derived-cache generation, one scripted travel state) captures
-- attributed memory snapshots at field, travel, Bag, and return boundaries
-- through the bounded trace helper. Audio, Lua-heap, GPU, and external RSS
-- figures stay in separate fields; whatever the process cannot observe
-- in-process is an explicit unavailable marker, never a fabricated zero.
-- Missing ROM or graphics capabilities skip the replay leg explicitly.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local AssetMemoryTrace = require("tests.support.AssetMemoryTrace")
local AudioAssetProvider = require("libs.hgss.src.audio.AudioAssetProvider")
local AudioFixture = require("tests.support.AudioFixture")
local AudioRuntime = require("libs.hgss.src.audio.AudioRuntime")
local VoiceMixer = require("libs.nds.src.nitro.sound.VoiceMixer")
local WaveOutPlayer = require("libs.nds.src.nitro.sound.WaveOutPlayer")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local FieldMovement = require("tests.acceptance.support.FieldMovement")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local FLAG_GOT_BAG = FieldScriptSymbols.flagsByName.FLAG_GOT_BAG

local T = {
  metadata = {
    derivedAssets = { "field-runtime", "map:7" },
    tags = { "asset-memory" },
  },
  tests = {},
}

-- No-observer production overhead: with sampling disabled, fixed simulated
-- frames retain no history, allocate no per-frame observer state, and emit
-- no logs or objects. The snapshot call itself is the observable boundary.
function T.tests.disabled_tracer_retains_nothing_across_simulated_frames()
  local tracer = AssetMemoryTrace.new({ enabled = false })
  Assert.isFalse(tracer:isEnabled(), "the fixture must start with sampling disabled")
  for _ = 1, 240 do
    tracer:observeFrameTime(16.6)
    local record = tracer:snapshot("field-entry", { luaKb = 1024, rssKb = 2048 })
    Assert.isNil(record, "a disabled tracer records nothing")
  end
  Assert.equal(tracer:snapshotCount(), 0, "a disabled tracer counts no snapshots")
  Assert.equal(#tracer:history(), 0, "a disabled tracer retains no history")
  Assert.equal(tracer:droppedSnapshots(), 0, "a disabled tracer drops nothing")
  Assert.isNil(tracer:frameSummary(), "a disabled tracer keeps no frame summary")
  Assert.isNil(tracer:framePercentile(50), "a disabled tracer keeps no percentiles")
end

-- Bounded scalar history: repeated checkpoints overwrite the oldest record
-- instead of growing, and the drop count stays exact.
function T.tests.snapshot_history_stays_bounded_under_repeated_checkpoints()
  local tracer = AssetMemoryTrace.new()
  local total = AssetMemoryTrace.HISTORY_LIMIT * 3 + 10
  for step = 1, total do
    tracer:snapshot("travel", { step = step })
  end
  Assert.equal(#tracer:history(), AssetMemoryTrace.HISTORY_LIMIT, "history stays at the bound")
  Assert.equal(tracer:snapshotCount(), total, "the ever-recorded count stays exact")
  Assert.equal(
    tracer:droppedSnapshots(),
    total - AssetMemoryTrace.HISTORY_LIMIT,
    "overwritten snapshots are counted, not lost silently"
  )
  local history = tracer:history()
  Assert.equal(
    history[1].seq,
    total - AssetMemoryTrace.HISTORY_LIMIT + 1,
    "the oldest retained record follows the bound"
  )
  Assert.equal(history[#history].seq, total, "the newest record is retained")
  Assert.equal(history[#history].facts.step, total, "stored facts keep their values")
end

-- The trace stores scalars only: live tables, functions, and userdata are
-- refused with the offending key named, and later caller mutation cannot
-- rewrite already stored facts.
function T.tests.snapshots_keep_scalars_and_refuse_live_resources()
  local tracer = AssetMemoryTrace.new()
  local record = tracer:snapshot("field-entry", { luaKb = 512.5, renderer = "test", ready = true })
  Assert.notNil(record, "an enabled tracer stores the checkpoint")
  Assert.equal(record.seq, 1, "sequences start at one")
  Assert.equal(record.label, "field-entry", "the stored label matches")
  Assert.equal(record.facts.luaKb, 512.5, "numeric facts round-trip")

  local facts = { luaKb = 10 }
  tracer:snapshot("bag", facts)
  facts.luaKb = 99
  local history = tracer:history()
  Assert.equal(history[#history].facts.luaKb, 10, "stored facts are copies, not caller references")

  local imageError = Assert.throws(function()
    tracer:snapshot("travel", { liveImage = {} })
  end, "live tables must be refused")
  Assert.isTrue(tostring(imageError):find("liveImage", 1, true) ~= nil, "the refusal names the offending key")
  Assert.throws(function()
    tracer:snapshot("travel", { callback = function() end })
  end, "functions must be refused")
  Assert.equal(tracer:snapshotCount(), 2, "refused snapshots record nothing")
end

-- Frame observations use fixed buckets, never per-frame objects: bucket
-- storage stays constant across ten thousand observations, percentiles and
-- the mean come from the buckets, and neither observation bursts nor
-- checkpoint snapshots invoke the garbage collector.
function T.tests.frame_observations_use_fixed_buckets_without_per_frame_state()
  local tracer = AssetMemoryTrace.new()
  Assert.equal(tracer:bucketCount(), AssetMemoryTrace.FRAME_BUCKETS, "bucket storage is fixed up front")
  for index = 1, 10000 do
    tracer:observeFrameTime(16 + (index % 4))
  end
  Assert.equal(
    tracer:bucketCount(),
    AssetMemoryTrace.FRAME_BUCKETS,
    "bucket storage is unchanged by ten thousand observations"
  )
  local summary = tracer:frameSummary()
  Assert.notNil(summary, "observations produce a summary")
  Assert.equal(summary.count, 10000, "every observation is counted")
  Assert.near(summary.meanMs, 17.5, 0.0001, "the mean comes from the running sum")
  Assert.near(summary.p50Ms, 17.5, 2.5, "the median lands in the populated bucket")
  Assert.near(summary.p95Ms, 17.5, 2.5, "the upper percentile lands in the populated bucket")
  Assert.equal(summary.overflowFrames, 0, "in-range frames never overflow")

  local calls = 0
  local realCollect = collectgarbage
  _G.collectgarbage = function(...)
    calls = calls + 1
    return realCollect(...)
  end
  local ok, err = xpcall(function()
    for _ = 1, 1000 do
      tracer:observeFrameTime(16.6)
    end
    tracer:snapshot("travel", { step = 1 })
    tracer:frameSummary()
    tracer:framePercentile(95)
  end, debug.traceback)
  _G.collectgarbage = realCollect
  if not ok then
    error(err, 0)
  end
  Assert.equal(calls, 0, "observation and checkpoint paths never drive collection")

  local checkpointCalls = 0
  _G.collectgarbage = function(...)
    checkpointCalls = checkpointCalls + 1
    return realCollect(...)
  end
  local heapKb
  local heapOk, heapErr = xpcall(function()
    heapKb = AssetMemoryTrace.luaKilobytes()
  end, debug.traceback)
  _G.collectgarbage = realCollect
  if not heapOk then
    error(heapErr, 0)
  end
  Assert.equal(checkpointCalls, 1, "the explicit checkpoint heap read collects exactly once")
  Assert.isTrue(type(heapKb) == "number", "the checkpoint heap read reports kilobytes")
end

-- Attribution stays separated: Lua-heap, audio, GPU, and external RSS facts
-- share no combined field, and unavailable families are explicit markers
-- rather than zeros.
function T.tests.graphics_and_rss_observations_stay_in_separate_fields()
  local fakeGraphics = {
    getStats = function()
      return { images = 3, canvases = 1, texturememory = 4096 }
    end,
    getRendererInfo = function()
      return "TestRenderer", "1.0", "TestVendor", "TestDevice"
    end,
  }
  local graphicsFacts = AssetMemoryTrace.readGraphicsStats(fakeGraphics)
  Assert.isTrue(graphicsFacts.available, "an injected graphics namespace reports available")
  Assert.equal(graphicsFacts.images, 3, "image counts pass through untouched")
  Assert.equal(graphicsFacts.canvases, 1, "canvas counts pass through untouched")
  Assert.equal(graphicsFacts.textureBytes, 4096, "texture bytes pass through untouched")

  local renderer = AssetMemoryTrace.rendererIdentity(fakeGraphics)
  Assert.isTrue(renderer.available, "renderer identity reports available")
  Assert.equal(renderer.name, "TestRenderer", "renderer identity keeps the name")
  Assert.equal(renderer.vendor, "TestVendor", "renderer identity keeps the vendor")

  local tracer = AssetMemoryTrace.new()
  local record = assert(tracer:snapshot("field-entry", {
    luaKb = 512,
    audioRetainedBytesAvailable = false,
    gpuImages = graphicsFacts.images,
    gpuTextureBytes = graphicsFacts.textureBytes,
    rssKbAvailable = false,
    rendererName = renderer.name,
  }))
  Assert.equal(record.facts.luaKb, 512, "the Lua-heap figure is stored as its own field")
  Assert.equal(record.facts.gpuTextureBytes, 4096, "the GPU figure is stored as its own field")
  Assert.equal(record.facts.audioRetainedBytesAvailable, false, "missing audio counters stay explicit")
  Assert.equal(record.facts.rssKbAvailable, false, "externally sampled RSS stays explicit")
  Assert.isNil(record.facts.totalBytes, "no family is merged into a combined total")

  Assert.isFalse(
    AssetMemoryTrace.readGraphicsStats(nil).available,
    "a headless run marks graphics unavailable instead of reporting zeros"
  )
  Assert.isFalse(
    AssetMemoryTrace.readGraphicsStats({}).available,
    "a namespace without the query marks graphics unavailable"
  )
  Assert.isFalse(AssetMemoryTrace.rendererIdentity(nil).available, "a headless run marks renderer identity unavailable")
end

-- The pinned artifact name carries the source generation and the renderer
-- so repeat runs with the same cache warmness stay comparable.
function T.tests.baseline_artifact_names_carry_source_and_renderer_identity()
  local nvidia = AssetMemoryTrace.baselineFileName("abcdef1234567890", "OpenGL 4.6 (NVIDIA GeForce RTX 4060)")
  local software = AssetMemoryTrace.baselineFileName("abcdef1234567890", "llvmpipe (LLVM 15.0.7)")
  Assert.isTrue(nvidia ~= software, "distinct renderers produce distinct artifact names")
  Assert.isTrue(nvidia:find("abcdef1", 1, true) ~= nil, "the artifact name carries the short source SHA")
  Assert.isTrue(
    nvidia:find("asset-memory-baseline-", 1, true) == 1,
    "the artifact name carries the stable baseline prefix"
  )
  Assert.isTrue(nvidia:sub(-5) == ".json", "the artifact is a JSON document")
  Assert.isNil(nvidia:find("[^A-Za-z0-9_.-]"), "the artifact name stays filename-safe")
  Assert.isTrue(
    AssetMemoryTrace.baselineFileName("abcdef1234567890", nil):find("unknown-renderer", 1, true) ~= nil,
    "a headless run names its artifact explicitly instead of dropping the renderer"
  )
end

-- The stable serialization schema round-trips retained history: sorted
-- record keys, oldest-first rows, scalars only.
function T.tests.trace_serializes_through_the_stable_schema()
  local tracer = AssetMemoryTrace.new()
  tracer:snapshot("field-entry", { luaKb = 512, rendererName = "test" })
  tracer:snapshot("bag", { luaKb = 640 })
  for _ = 1, 10 do
    tracer:observeFrameTime(16.6)
  end
  local json = tracer:toJson()
  Assert.isTrue(json:find('"field-entry"', 1, true) ~= nil, "the JSON carries checkpoint labels")
  Assert.isTrue(json:find('"luaKb":512', 1, true) ~= nil, "the JSON carries scalar facts")
  Assert.isTrue(json:find('"summary"', 1, true) ~= nil, "the JSON carries the frame summary")
  local csv = tracer:toCsv()
  Assert.isTrue(
    csv:sub(1, #"seq,label,metric,value") == "seq,label,metric,value",
    "the CSV starts with the stable header"
  )
  Assert.isTrue(csv:find("1,field-entry,luaKb,512", 1, true) ~= nil, "the CSV carries oldest-first rows")
end

-- Deterministic 32-bit rolling fingerprint over an int16 stream. Every
-- intermediate product stays far below 2^53, so the value is exact on any
-- host with plain Lua arithmetic and needs no bit library. The replay
-- never fabricates audio bytes; these fingerprints pin the exact
-- provider-decoded and mixer-rendered streams a later packed
-- representation must reproduce bit-identically.
local function fingerprint16(values)
  local hash = 0
  for index = 1, #values do
    hash = (hash * 31 + (values[index] + 32768)) % 4294967296
  end
  return hash
end

local function assertAudible(frames, what)
  local nonzero = false
  for index = 1, #frames do
    if frames[index] ~= 0 then
      nonzero = true
      break
    end
  end
  Assert.isTrue(nonzero, what .. " renders audible output")
end

-- Unique PCM keys hold one shared array each: a repeated load returns the
-- identical table, and retained-byte accounting counts each unique key
-- once at two bytes per frame. Duplicate references never inflate the
-- census the trace reports.
function T.tests.audio_retained_bytes_count_unique_sample_keys_once()
  local provider = AudioAssetProvider.new(AudioFixture.readyCache())
  local keyA, keyB = AudioFixture.key(1), AudioFixture.key(2)
  local firstA = provider:loadSample(keyA)
  local sampleB = provider:loadSample(keyB)
  local secondA = provider:loadSample(keyA)
  Assert.isTrue(firstA ~= sampleB, "distinct content keys load distinct sample objects")
  Assert.isTrue(secondA == firstA, "a repeated key shares the packed sample instead of packing twice")
  Assert.equal(firstA.pcm.frames, firstA.metadata.frames, "frame totals come from the packed count")
  Assert.equal(firstA.metadata.frames, 4, "the first fixture sample holds four frames")
  Assert.isTrue(firstA.metadata.loopEnabled, "the first fixture sample is the looped representative")
  local secondFrames = {}
  for index = 0, sampleB.pcm.frames - 1 do
    secondFrames[#secondFrames + 1] = sampleB.pcm:read(index)
  end
  Assert.deepEqual(secondFrames, { 5000, 6000 }, "the second fixture sample packs exactly")
  Assert.equal(sampleB.pcm.frames, sampleB.metadata.frames, "every key carries its own frame total")
  local seen, uniqueFrames, uniqueBytes = {}, 0, 0
  for _, sample in ipairs({ firstA, sampleB, secondA }) do
    if not seen[sample] then
      seen[sample] = true
      uniqueFrames = uniqueFrames + sample.pcm.frames
      uniqueBytes = uniqueBytes + sample.pcm.frames * 2
    end
  end
  Assert.equal(uniqueFrames, 6, "two unique keys hold six frames despite three loads")
  Assert.equal(uniqueBytes, 12, "retained PCM bytes count unique keys once at two bytes per frame")
end

-- Pre-change storage fingerprints: the exact decoded int16 arrays for a
-- looped and a one-shot sample, the reversed-cry copy through the real
-- WaveOut reverse path, and one overlapping two-voice mixer render. The
-- literals below are the before-change record, computed from
-- project-owned synthetic bytes with no ROM involved.
function T.tests.provider_decoded_pcm_fingerprints_pin_the_pre_change_storage()
  local bundle = AudioFixture.bundle()
  local oneShotKey = AudioFixture.key(3)
  bundle.samples[oneShotKey] = AudioFixture.pcm16le({ 7000, -8000, 9000, -10000 })
  bundle.sampleMetadata[oneShotKey] = AudioFixture.sampleMetadata(oneShotKey, { frames = 4, loopEnabled = false })
  local provider = AudioAssetProvider.new(AudioFixture.readyCache(bundle))
  local looped = provider:loadSample(AudioFixture.key(1))
  local oneShot = provider:loadSample(oneShotKey)
  local oneShotFrames = {}
  for index = 0, oneShot.pcm.frames - 1 do
    oneShotFrames[#oneShotFrames + 1] = oneShot.pcm:read(index)
  end
  Assert.deepEqual(oneShotFrames, { 7000, -8000, 9000, -10000 }, "the one-shot representative packs exactly")
  Assert.isFalse(oneShot.metadata.loopEnabled, "the one-shot representative carries no loop")
  local loopedFrames = {}
  for index = 0, looped.pcm.frames - 1 do
    loopedFrames[#loopedFrames + 1] = looped.pcm:read(index)
  end
  Assert.equal(fingerprint16(loopedFrames), 1040540112, "looped-sample storage fingerprint")
  Assert.equal(fingerprint16(oneShotFrames), 1209848112, "one-shot storage fingerprint")

  local mixer = VoiceMixer.new({ sampleRate = 48000 })
  local wave = WaveOutPlayer.new({ mixer = mixer })
  local forwardOptions = { volume = 127, pan = 64, speed = 8006, reverse = false }
  local forward = wave:start(14, looped, forwardOptions)
  Assert.notNil(forward, "the forward cry starts on its fixed channel")
  Assert.isTrue(forward.sample == looped, "the forward path borrows the stored array without copying")
  local backwardHandle = wave:start(15, looped, { volume = 127, pan = 64, speed = 8006, reverse = true })
  Assert.notNil(backwardHandle, "the reversed cry starts on its fixed channel")
  local backward = backwardHandle.sample
  Assert.isTrue(backward == looped, "the reversed cry borrows the stored sample without copying")
  local expectedReverse = {}
  for index = looped.pcm.frames - 1, 0, -1 do
    expectedReverse[#expectedReverse + 1] = looped.pcm:read(index)
  end
  local backwardFrames = {}
  for index = 0, backward.pcm.frames - 1 do
    backwardFrames[#backwardFrames + 1] = backward.pcm:read(index)
  end
  Assert.deepEqual(backwardFrames, loopedFrames, "the stored buffer itself is never rewritten")
  Assert.isTrue(backward.metadata == looped.metadata, "reversal shares metadata and borrows the sample")
  Assert.equal(fingerprint16(expectedReverse), 1130840112, "reversed-cry storage fingerprint")

  mixer:controlStep()
  local overlap = mixer:render(64)
  Assert.equal(#overlap, 128, "one stereo span per rendered frame")
  assertAudible(overlap, "two overlapping voices")
  Assert.equal(fingerprint16(overlap), 2798788608, "overlapping-voices mixer fingerprint")
  local mixer2 = VoiceMixer.new({ sampleRate = 48000 })
  local wave2 = WaveOutPlayer.new({ mixer = mixer2 })
  wave2:start(14, looped, forwardOptions)
  wave2:start(15, looped, { volume = 127, pan = 64, speed = 8006, reverse = true })
  mixer2:controlStep()
  Assert.equal(fingerprint16(mixer2:render(64)), fingerprint16(overlap), "the overlapping render is deterministic")
end

local STREAM_BUNDLE_SEQUENCES = {
  bgm = { id = 4, symbol = "SEQ_BGM_TEST", playerId = 1, program = 0, finite = false },
  fanfare = { id = 6, symbol = "SEQ_FANFARE_TEST", playerId = 3, program = 0, finite = true },
  radio = { id = 41, symbol = "SEQ_RADIO_TEST", playerId = 1, program = 1, finite = false },
}

-- A small synthetic archive over the frozen fixture bank: a looping music
-- sequence on the direct sample voice, a finite fanfare on the same
-- voice, and a looping radio sequence on the key-split voice so both
-- fixture samples sound. Mirrors the production audio composition only;
-- no ROM data is involved.
-- Instant-attack sample voices: the agility under test is storage and
-- mixing fidelity, not envelope ballistics, so the synthetic bank opens
-- each note at the full register on the first control interval instead
-- of spending the fingerprint window inside a slow attack ramp.
local function streamVoice(key)
  return {
    generator = { kind = "sample", sample = key },
    originalKey = 60,
    envelope = { attack = 127, decay = 127, sustain = 127, release = 127 },
    pan = 64,
  }
end

local function streamBundle()
  local bundle = AudioFixture.bundle()
  local keyA, keyB = AudioFixture.key(1), AudioFixture.key(2)
  bundle.banks = {
    [12] = AudioFixture.bank(12, "BANK_TEST", { keyA, keyB }, {
      [0] = { kind = "direct", voice = streamVoice(keyA) },
      [1] = {
        kind = "key_split",
        ranges = {
          { lowKey = 0, highKey = 59, voice = streamVoice(keyA) },
          { lowKey = 60, highKey = 127, voice = streamVoice(keyB) },
        },
      },
    }),
  }
  local sequences, bySymbol = {}, {}
  for _, entry in pairs(STREAM_BUNDLE_SEQUENCES) do
    local instructions
    if entry.finite then
      instructions = {
        { op = "program", program = entry.program },
        { op = "note", key = 60, velocity = 127, duration = 1 },
        { op = "end" },
      }
    else
      instructions = {
        { op = "program", program = entry.program },
        { op = "note", key = 60, velocity = 96, duration = 24 },
        { op = "wait", duration = 12 },
        { op = "jump", target = 2 },
      }
    end
    sequences[entry.id] = AudioFixture.sequence(entry.id, entry.symbol, 12, entry.playerId, {
      entry = 1,
      initialTrackMask = 0x0001,
      instructions = instructions,
    }, {
      id = entry.playerId,
      initialVolume = 127,
      playerPriority = 64,
      channelPriority = 64,
    })
    bundle.index.sequences[entry.id] = { id = entry.id, symbol = entry.symbol, bankId = 12, playerId = entry.playerId }
    bySymbol[entry.symbol] = entry.id
  end
  bundle.index.sequences[0] = nil
  bundle.index.sequences[37] = nil
  bundle.sequences = sequences
  bundle.index.sequenceBySymbol = bySymbol
  bundle.index.players[3] = { id = 3, maxSequences = 16, channelMask = 0xFFFF }
  return bundle
end

local function composeStreams()
  local cacheFs = AudioFixture.readyCache(streamBundle())
  local runtime = AudioRuntime.compose({ cacheFs = cacheFs, outputRate = 48000 })
  return runtime.sound, runtime.renderer
end

local function renderSpan(sound, player, frames)
  local out = {}
  local remaining = frames
  while remaining > 0 do
    local step = math.min(4, remaining)
    sound:updateSoundFrame()
    local span = player:render(step)
    for index = 1, #span do
      out[#out + 1] = span[index]
    end
    remaining = remaining - step
  end
  return out
end

local function renderFanfareToCompletion(sound, player)
  local out = {}
  local frames = 0
  while sound:isFanfarePlaying() do
    assert(frames < 6000, "a fanfare must complete within its frame budget")
    local span = renderSpan(sound, player, 4)
    for index = 1, #span do
      out[#out + 1] = span[index]
    end
    frames = frames + 4
  end
  return out
end

-- Pre-change stream fingerprints: exact mixer output for music, fanfare,
-- radio, and overlapping fanfare-over-music and fanfare-over-radio
-- through the production audio composition. Later representation work
-- must reproduce these streams bit-identically; the literals below are
-- the before-change record from project-owned synthetic bytes.
function T.tests.composed_audio_streams_fingerprint_the_pre_change_mix()
  local sound, player = composeStreams()
  sound:playMusic(STREAM_BUNDLE_SEQUENCES.bgm.symbol)
  local bgm = renderSpan(sound, player, 1500)
  assertAudible(bgm, "the music stream")
  Assert.equal(fingerprint16(bgm), 3603820576, "music stream fingerprint")
  sound:playFanfare(STREAM_BUNDLE_SEQUENCES.fanfare.symbol)
  local fanfareOverMusic = renderFanfareToCompletion(sound, player)
  assertAudible(fanfareOverMusic, "the fanfare-over-music stream")
  Assert.equal(fingerprint16(fanfareOverMusic), 3691276832, "fanfare-over-music stream fingerprint")

  local radioSound, radioPlayer = composeStreams()
  radioSound:playRadio(STREAM_BUNDLE_SEQUENCES.radio.symbol)
  local radio = renderSpan(radioSound, radioPlayer, 1500)
  assertAudible(radio, "the radio stream")
  Assert.isTrue(radioSound:radioIsPlaying(), "the radio latch holds while its stream renders")
  Assert.equal(fingerprint16(radio), 4059610112, "radio stream fingerprint")
  radioSound:playFanfare(STREAM_BUNDLE_SEQUENCES.fanfare.symbol)
  local fanfareOverRadio = renderFanfareToCompletion(radioSound, radioPlayer)
  assertAudible(fanfareOverRadio, "the fanfare-over-radio stream")
  Assert.isTrue(radioSound:radioIsPlaying(), "the fanfare completes around radio without stopping it")
  Assert.equal(fingerprint16(fanfareOverRadio), 2755067968, "fanfare-over-radio stream fingerprint")

  local repeatSound, repeatPlayer = composeStreams()
  repeatSound:playMusic(STREAM_BUNDLE_SEQUENCES.bgm.symbol)
  Assert.equal(
    fingerprint16(renderSpan(repeatSound, repeatPlayer, 1500)),
    fingerprint16(bgm),
    "the music stream is deterministic across compositions"
  )
end

local function hostPhase(game)
  return game.runtime.applicationHost:status().phase
end

-- The same FieldState callbacks production LOVE dispatches. No synthetic
-- input behavior of its own.
local function hostCallbacks(game)
  return setmetatable({
    runtime = {
      input = game.runtime.input,
      actionKeys = game.runtime.actionKeys,
      cancelKeys = game.runtime.cancelKeys,
      menuKeys = game.runtime.menuKeys,
    },
  }, FieldState)
end

local function openStartMenu(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
  game:advanceUntil("start menu becomes modal", function()
    return hostPhase(game) == FieldApplicationHost.PHASES.menu
  end, 120)
end

local function closeStartMenu(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
  game:advanceUntil("start menu closes", function(snapshot)
    return hostPhase(game) == FieldApplicationHost.PHASES.closed and not snapshot.fieldLocked
  end, 120)
end

local function menuStatus(game)
  local status = game.runtime.applicationHost:status()
  Assert.equal(status.phase, FieldApplicationHost.PHASES.menu, "the start menu must own the tick")
  return assert(status.menu, "the menu phase must expose the controller status")
end

local function cursorActionId(status)
  local position = assert(status.selectedPosition, "menu status must expose the selected position")
  for _, action in ipairs(assert(status.actions, "menu status must list actions")) do
    if action.position == position then
      return action.id
    end
  end
  error("start menu cursor does not resolve to a visible action", 0)
end

local function navigateTo(game, state, id)
  for _ = 1, #menuStatus(game).actions + 1 do
    if cursorActionId(menuStatus(game)) == id then
      return
    end
    state:keypressed("s")
    game:step()
    state:keyreleased("s")
  end
  error("start menu never focuses the wanted action", 0)
end

local function confirm(game)
  game.runtime.input:pressAction("key:return")
  game:step()
  game.runtime.input:releaseAction("key:return")
end

local function pressCancel(game)
  game.runtime:pressCancel()
  game:step()
  game.runtime:releaseCancel()
end

-- Stocks the live Bag through the production inventory boundary so the Bag
-- leg opens over real state. Copied ownership: the field runtime owns the
-- live service, the trace only observes the boundaries around it.
local function stockTwoPockets(game)
  local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
  Assert.isTrue(bag:add("POTION", 5), "setup stock must enter the bag through the production service")
  Assert.isTrue(bag:add("POKE_BALL", 3), "setup stock must enter the bag through the production service")
  Assert.equal(bag:pocketOf("POTION"), "medicine", "setup medicine must live in the medicine pocket")
  Assert.equal(bag:pocketOf("POKE_BALL"), "balls", "setup balls must live in the balls pocket")
end

local function bagView(game)
  local status = game.runtime.applicationHost:status()
  Assert.equal(
    status.phase,
    FieldApplicationHost.PHASES.application,
    "the bag application must own the tick while browsing"
  )
  Assert.equal(status.applicationId, FieldApplicationIds.BAG, "the launched application must be the bag")
  local flow = assert(status.application, "the bag application must expose its flow status")
  local view = assert(flow.child, "the bag flow must expose its live leaf status")
  assert(type(view) == "table", "the bag browse status must be a record")
  return view
end

-- Fixed script, fixed boot map: the travel leg probes the spawn's adjacent
-- tiles through the public collision seam in a fixed preference order and
-- walks at most three verified-passable steps, so the same cache generation
-- replays identically.
local function scriptedTravelSteps(game)
  local snapshot = game:snapshot()
  local map = game.runtime.runtimeMap
  local origin = assert(map.coordinateOrigin, "travel needs the map coordinate origin")
  local preference = { "east", "south", "west", "north" }
  local delta = { east = { 1, 0 }, south = { 0, 1 }, west = { -1, 0 }, north = { 0, -1 } }
  local fieldX, fieldZ = snapshot.player.fieldX, snapshot.player.fieldZ
  local chosen = {}
  for _, direction in ipairs(preference) do
    if #chosen >= 3 then
      break
    end
    local step = delta[direction]
    local localX = (fieldX + step[1]) - origin.x
    local localZ = (fieldZ + step[2]) - origin.z
    if not map.collision:isBlockedLocal(localX, localZ) then
      chosen[#chosen + 1] = direction
      fieldX = fieldX + step[1]
      fieldZ = fieldZ + step[2]
    end
  end
  if #chosen > 0 then
    FieldMovement.productionRoute(game, chosen)
  end
  return #chosen
end

-- Records one named checkpoint from public seams only: the explicit
-- checkpoint heap read, injected graphics queries, and caller-supplied
-- external figures. Missing families stay explicit unavailable markers.
local function captureCheckpoint(game, tracer, context, label, extra)
  local facts = { luaKb = AssetMemoryTrace.luaKilobytes(), luaAvailable = true }
  if extra ~= nil then
    for key, value in pairs(extra) do
      facts[key] = value
    end
  end
  if context:hasCapability("graphics") then
    local graphicsFacts = AssetMemoryTrace.readGraphicsStats(love.graphics)
    local renderer = AssetMemoryTrace.rendererIdentity(love.graphics)
    facts.gpuAvailable = graphicsFacts.available
    facts.gpuImages = graphicsFacts.images
    facts.gpuCanvases = graphicsFacts.canvases
    facts.gpuTextureBytes = graphicsFacts.textureBytes
    facts.rendererAvailable = renderer.available
    facts.rendererName = renderer.name
    facts.rendererVendor = renderer.vendor
    facts.rendererDevice = renderer.device
  else
    facts.gpuAvailable = false
    facts.rendererAvailable = false
  end
  facts.audioRetainedBytesAvailable = false
  facts.rssKbAvailable = false
  return assert(tracer:snapshot(label, facts), "replay checkpoints record while enabled")
end

-- Representatively attributed snapshot: the same derived-cache generation
-- and the same scripted travel state capture field, travel, Bag, and return
-- boundaries with audio, Lua-heap, GPU, and RSS figures in separate fields.
-- Summary, portrait, PC, and battle legs need stocked saves and travel to
-- owned flows, so the trace reserves their checkpoint names in canonical
-- order without fabricating them on a fresh-save replay.
function T.tests.scripted_travel_reports_attributed_memory_at_state_boundaries(context)
  if not context:hasCapability("rom_dump") then
    context:skip("requires a ready user-owned ROM dump and prepared derived assets")
  end
  local tracer = AssetMemoryTrace.new()
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
  })
  local ok, err = xpcall(function()
    local state = hostCallbacks(game)
    game:waitForFieldEntry()
    captureCheckpoint(game, tracer, context, "field-entry")

    stockTwoPockets(game)
    game:setWorldState({ flag = FLAG_GOT_BAG })

    local started = love.timer.getTime()
    local stepsTaken = scriptedTravelSteps(game)
    tracer:observeFrameTime((love.timer.getTime() - started) * 1000)
    captureCheckpoint(game, tracer, context, "travel", { stepsTaken = stepsTaken })

    openStartMenu(game)
    local bagOffered = false
    for _, action in ipairs(menuStatus(game).actions) do
      if action.id == "vanilla.bag" then
        bagOffered = true
      end
    end
    Assert.isTrue(bagOffered, "the unlocked bag must offer its start menu action")
    navigateTo(game, state, "vanilla.bag")
    confirm(game)
    game:advanceUntil("bag application opens over the retained menu", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.application
    end, 120)
    game:advanceUntil("the Bag opening settles", function()
      return bagView(game).phase == "interactive"
    end, 120)
    captureCheckpoint(game, tracer, context, "bag", { bagOpen = true })
    pressCancel(game)
    game:advanceUntil("bag closes back to the start menu", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.menu
    end, 120)
    closeStartMenu(game)
    captureCheckpoint(game, tracer, context, "return-to-field")

    Assert.equal(game:renderAttempts(), 0, "the replay must stop before GPU rendering")

    local history = tracer:history()
    Assert.isTrue(#history >= 4, "the replay captures every reached boundary")
    local previous = 0
    for _, record in ipairs(history) do
      local position = AssetMemoryTrace.checkpointIndex(record.label)
      Assert.notNil(position, "captured checkpoints come from the canonical order")
      Assert.isTrue(position > previous, "captured checkpoints follow canonical scenario order")
      previous = position
      Assert.isTrue(type(record.facts.luaKb) == "number", "every checkpoint carries its Lua-heap figure")
      Assert.isNil(record.facts.totalBytes, "no checkpoint merges families into a combined total")
      Assert.isTrue(
        record.facts.audioRetainedBytesAvailable == false or type(record.facts.audioRetainedBytes) == "number",
        "audio attribution is a reported figure or an explicit unavailable marker"
      )
      Assert.isTrue(
        record.facts.rssKbAvailable == false or type(record.facts.rssKb) == "number",
        "RSS attribution is an externally supplied figure or an explicit unavailable marker"
      )
    end

    local json = tracer:toJson()
    Assert.isTrue(#json > 0, "the replay trace serializes through the stable schema")
    local csv = tracer:toCsv()
    Assert.isTrue(
      csv:sub(1, #"seq,label,metric,value") == "seq,label,metric,value",
      "the replay trace keeps the stable CSV header"
    )
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The paired release-gate snapshot protocol: three warm passes, each run
-- once under the compact representation and once under the straight
-- representation through the same owner, plus one cold-cache pass. Every
-- snapshot carries its image policy and keeps externally sampled process
-- memory an explicit unavailable marker until a real external sampler
-- attaches its series offline; nothing here fabricates a high-water.
local WARM_PASS_POLICIES = { "compact", "straight", "compact", "straight", "compact", "straight" }

-- The release verdict for one paired comparison. Only a native hardware
-- renderer with a measured external high-water under the whole-process
-- ceiling passes. A software rasterizer, an unidentified renderer, or an
-- unmeasured high-water stays pending; a measured over-ceiling high-water
-- fails. The pending outcome blocks the release claim; it never approves
-- compact representations on its own.
local function releaseVerdict(rendererName, hwmKb)
  local lowered = type(rendererName) == "string" and rendererName:lower() or ""
  local native = lowered ~= ""
    and lowered:find("llvmpipe", 1, true) == nil
    and lowered:find("softpipe", 1, true) == nil
    and lowered:find("software", 1, true) == nil
    and lowered:find("unknown", 1, true) == nil
  if not native then
    return "hardware-pending", "software rasterizer cannot prove the native memory ceiling"
  end
  if type(hwmKb) ~= "number" then
    return "hardware-pending", "no externally measured process high-water"
  end
  if hwmKb < 1024 * 1024 then
    return "pass", "measured high-water fits the whole-process ceiling"
  end
  return "fail", "measured high-water exceeds the whole-process ceiling"
end

-- Paired warm/cold structure for the full-session memory comparison.
-- Passes without hardware or a ROM: the six warm snapshots and the one
-- cold snapshot record their policies and keep process memory explicit,
-- and the verdict on this host stays pending with the reason named.
function T.tests.paired_warm_and_cold_snapshots_keep_external_memory_explicit_for_the_release_gate(context)
  local tracer = AssetMemoryTrace.new()
  tracer:snapshot("field-entry", {
    coldCache = true,
    luaKb = 512,
    rssKbAvailable = false,
    hwmKbAvailable = false,
  })
  for pass = 1, #WARM_PASS_POLICIES do
    tracer:observeFrameTime(16.6)
    tracer:snapshot("travel", {
      pass = pass,
      imagePolicy = WARM_PASS_POLICIES[pass],
      luaKb = 512 + pass,
      rssKbAvailable = false,
      hwmKbAvailable = false,
    })
  end
  Assert.equal(tracer:snapshotCount(), #WARM_PASS_POLICIES + 1, "three paired warm passes plus one cold pass")
  local compact, straight = 0, 0
  for _, record in ipairs(tracer:history()) do
    if record.facts.imagePolicy == "compact" then
      compact = compact + 1
    elseif record.facts.imagePolicy == "straight" then
      straight = straight + 1
    end
    Assert.isFalse(record.facts.rssKbAvailable, "process RSS stays an explicit marker without an external sampler")
    Assert.isFalse(
      record.facts.hwmKbAvailable,
      "process high-water stays an explicit marker without an external sampler"
    )
    Assert.isNil(record.facts.totalBytes, "no snapshot merges families into a combined total")
  end
  Assert.equal(compact, 3, "three warm passes run under the compact representation")
  Assert.equal(straight, 3, "three warm passes run under the straight representation")
  local summary = assert(tracer:frameSummary(), "warm passes produce a frame summary")
  Assert.isTrue(type(summary.p95Ms) == "number", "the warm summary reports its upper tail")
  Assert.isTrue(type(summary.p99Ms) == "number", "the warm summary reports its extreme tail")

  local rendererName = "unknown-renderer"
  if context:hasCapability("graphics") then
    rendererName = AssetMemoryTrace.rendererIdentity(love.graphics).name or "unknown-renderer"
  end
  local verdict, reason = releaseVerdict(rendererName, nil)
  Assert.equal(verdict, "hardware-pending", "this host cannot pass the native memory comparison: " .. reason)
  local nativePending, _ = releaseVerdict("Native GPU Device", nil)
  Assert.equal(nativePending, "hardware-pending", "native hardware without a measured high-water stays pending")
  Assert.equal(releaseVerdict("Native GPU Device", 900 * 1024), "pass", "a measured under-ceiling high-water passes")
  Assert.equal(
    releaseVerdict("Native GPU Device", 2 * 1024 * 1024),
    "fail",
    "a measured over-ceiling high-water fails instead of manufacturing success"
  )
end

-- Release audio comparison: the pinned mix fingerprints reproduce
-- bit-identically on a second independent composition, so the paired
-- image-policy passes compare against one audio baseline. Any drift in
-- the music, fanfare-over-music, radio, or fanfare-over-radio stream
-- fails here before it can be mistaken for an image-policy effect.
function T.tests.release_audio_comparison_reproduces_the_pinned_mix_on_a_second_composition()
  local firstSound, firstPlayer = composeStreams()
  firstSound:playMusic(STREAM_BUNDLE_SEQUENCES.bgm.symbol)
  local firstBgm = renderSpan(firstSound, firstPlayer, 1500)
  firstSound:playFanfare(STREAM_BUNDLE_SEQUENCES.fanfare.symbol)
  local firstFanfare = renderFanfareToCompletion(firstSound, firstPlayer)

  local secondSound, secondPlayer = composeStreams()
  secondSound:playMusic(STREAM_BUNDLE_SEQUENCES.bgm.symbol)
  local secondBgm = renderSpan(secondSound, secondPlayer, 1500)
  secondSound:playFanfare(STREAM_BUNDLE_SEQUENCES.fanfare.symbol)
  local secondFanfare = renderFanfareToCompletion(secondSound, secondPlayer)

  Assert.equal(fingerprint16(firstBgm), 3603820576, "the music stream reproduces its pinned fingerprint")
  Assert.equal(
    fingerprint16(firstFanfare),
    3691276832,
    "the fanfare-over-music stream reproduces its pinned fingerprint"
  )
  Assert.equal(
    fingerprint16(secondBgm),
    fingerprint16(firstBgm),
    "a second composition renders the identical music stream"
  )
  Assert.equal(
    fingerprint16(secondFanfare),
    fingerprint16(firstFanfare),
    "a second composition renders the identical fanfare-over-music stream"
  )

  local radioSound, radioPlayer = composeStreams()
  radioSound:playRadio(STREAM_BUNDLE_SEQUENCES.radio.symbol)
  local radio = renderSpan(radioSound, radioPlayer, 1500)
  radioSound:playFanfare(STREAM_BUNDLE_SEQUENCES.fanfare.symbol)
  local fanfareOverRadio = renderFanfareToCompletion(radioSound, radioPlayer)
  Assert.equal(fingerprint16(radio), 4059610112, "the radio stream reproduces its pinned fingerprint")
  Assert.equal(
    fingerprint16(fanfareOverRadio),
    2755067968,
    "the fanfare-over-radio stream reproduces its pinned fingerprint"
  )
end

-- Missing trusted inputs fail loudly: an unknown sample key and an unknown
-- bank raise through the provider error contract and name the missing
-- reference instead of returning silence. Only a corrupt disposable
-- derivative may rebuild; absent trusted bytes never become a quiet
-- success on the release path.
function T.tests.missing_trusted_audio_inputs_fail_loudly_instead_of_rendering_silence()
  local provider = AudioAssetProvider.new(AudioFixture.readyCache())
  local sampleError = Assert.throws(function()
    provider:loadSample("no-such-sample-key")
  end, "an unknown sample key must fail")
  Assert.isTrue(
    tostring(sampleError):find("no-such-sample-key", 1, true) ~= nil,
    "the sample failure names the missing key"
  )
  local bankError = Assert.throws(function()
    provider:bank("no-such-bank")
  end, "an unknown bank reference must fail")
  Assert.isTrue(
    tostring(bankError):find("no-such-bank", 1, true) ~= nil,
    "the bank failure names the missing reference"
  )
end

return T
