-- Channel-mode output through the production sink seam: stereo PCM stays
-- byte-identical, mono averages each freshly rendered pair into both
-- channels, retries reuse the once-transformed pending buffer, mode changes
-- never touch pending PCM, and transport keeps running while muted. The
-- confirmed per-save mode also reaches the live sink through the validated
-- player-options closure. Headless: a scriptable audio-output double stands
-- in for the host device, and a minimal coordinator harness stands in for
-- the field runtime.

local ffi = require("ffi")

local Assert = require("tests.support.Assert")
local BadgeSets = require("tests.support.BadgeSets")
local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldMenuCompositionCoordinator = require("game.hgss.src.field.FieldMenuCompositionCoordinator")
local LoveAudioSink = require("game.src.audio.LoveAudioSink")
local PlayerData = require("libs.hgss.src.save.PlayerData")

local T = {}

local SAMPLE_RATE = 32768
local CHANNELS = 2
local BIT_DEPTH = 16
local CHUNK_FRAMES = 512
local QUEUE_BUFFER_COUNT = 4

-- A SoundData-shaped recording object mirroring the host contract the sink
-- consumes: the constructor's first argument is the per-channel frame count,
-- samples live in one stable int16 backing written through the live-pointer
-- accessor, and release is explicit.
local function newFakeSoundData(frames, sampleRate, bitDepth, channels)
  local backing = ffi.new("int16_t[?]", frames * channels)
  local data = {
    constructorFrames = frames,
    sampleRate = sampleRate,
    bitDepth = bitDepth,
    channels = channels,
    sampleCount = frames,
    releaseCalls = 0,
  }
  function data:getSampleRate()
    return self.sampleRate
  end
  function data:getBitDepth()
    return self.bitDepth
  end
  function data:getChannelCount()
    return self.channels
  end
  function data:getSampleCount()
    return self.sampleCount
  end
  function data:getSize()
    return self.sampleCount * self.channels * 2
  end
  function data:getFFIPointer()
    return backing
  end
  function data:getSample(i, channel)
    assert(i >= 0 and channel >= 1 and channel <= self.channels and i < self.sampleCount, "sample out of range")
    return tonumber(backing[i * self.channels + (channel - 1)]) / 32768
  end
  function data:release()
    self.releaseCalls = self.releaseCalls + 1
  end
  return data
end

-- A love.audio + love.sound-shaped namespace with scriptable buffer
-- availability and queue refusal. A nil free count advertises the full
-- explicit buffer count.
local function fakeHost(freeBufferCount)
  local host = {
    sources = {},
    soundData = {},
    free = freeBufferCount,
    refuseQueue = false,
  }
  function host.newSoundData(frames, sampleRate, bitDepth, channels)
    local data = newFakeSoundData(frames, sampleRate, bitDepth, channels)
    host.soundData[#host.soundData + 1] = data
    return data
  end
  function host.newQueueableSource(sampleRate, bitDepth, channels, bufferCount)
    local source = {
      sampleRate = sampleRate,
      bitDepth = bitDepth,
      channels = channels,
      bufferCount = bufferCount,
      free = host.free ~= nil and host.free or bufferCount or 0,
      queueCalls = {},
      playCalls = 0,
      playing = false,
      releaseCalls = 0,
      queuedPayloads = {},
    }
    function source:queue(data)
      if host.refuseQueue then
        host.refuseQueue = false
        return false
      end
      self.queueCalls[#self.queueCalls + 1] = data
      self.queuedPayloads[#self.queuedPayloads + 1] = data
      self.free = math.max(self.free - 1, 0)
    end
    function source:play()
      self.playCalls = self.playCalls + 1
      self.playing = true
    end
    function source:isPlaying()
      return self.playing
    end
    function source:getFreeBufferCount()
      return self.free
    end
    function source:release()
      self.releaseCalls = self.releaseCalls + 1
    end
    host.sources[#host.sources + 1] = source
    return source
  end
  return host
end

-- Asymmetric stereo content with an odd sum, int16 extremes, and a
-- mixed-sign extreme pair: frame 0 saturates positive, frame 1 saturates
-- negative, frame 2 mixes the extremes (sum -1, average floor -1), and
-- later frames carry an odd sum so truncation would be visible.
local function asymmetricStereo(_, ptr, frames)
  for frame = 0, frames - 1 do
    local left, right
    if frame == 0 then
      left, right = 32767, 32767
    elseif frame == 1 then
      left, right = -32768, -32768
    elseif frame == 2 then
      left, right = 32767, -32768
    else
      left, right = 1000 + frame, 999 + frame
    end
    ptr[2 * frame] = left
    ptr[2 * frame + 1] = right
  end
end

local function expectedMono(frame)
  if frame == 0 then
    return 32767
  elseif frame == 1 then
    return -32768
  elseif frame == 2 then
    return -1
  end
  return 999 + frame
end

local function expectedStereo(frame)
  if frame == 0 then
    return 32767, 32767
  elseif frame == 1 then
    return -32768, -32768
  elseif frame == 2 then
    return 32767, -32768
  end
  return 1000 + frame, 999 + frame
end

local function renderingCalls()
  local state = { calls = 0 }
  local renderer = {}
  function renderer:renderIntoInt16(ptr, frames)
    state.calls = state.calls + 1
    asymmetricStereo(self, ptr, frames)
  end
  return renderer, state
end

local function sinkFor(host, renderer, channelMode)
  return LoveAudioSink.new({
    audio = host,
    sound = host,
    renderer = renderer,
    sampleRate = SAMPLE_RATE,
    channelMode = channelMode,
  })
end

local function queuedWord(chunk, frame, channel)
  return math.floor(chunk:getSample(frame, channel) * 32768 + 0.5)
end

function T.stereo_leaves_rendered_pcm_byte_identical()
  for _, mode in ipairs({ nil, "stereo" }) do
    local host = fakeHost(1)
    local renderer, state = renderingCalls()
    local sink = sinkFor(host, renderer, mode)
    Assert.isTrue(sink:update(), "a queued and started chunk reports primed output")
    Assert.equal(state.calls, 1, "one update renders exactly one chunk")
    local chunk = host.sources[1].queueCalls[1]
    Assert.notNil(chunk, "the rendered buffer reaches the host queue")
    for _, frame in ipairs({ 0, 1, 2, 3, 100, CHUNK_FRAMES - 1 }) do
      local left, right = expectedStereo(frame)
      Assert.equal(queuedWord(chunk, frame, 1), left, "stereo keeps the left word of frame " .. frame)
      Assert.equal(queuedWord(chunk, frame, 2), right, "stereo keeps the right word of frame " .. frame)
    end
  end
end

function T.mono_averages_each_fresh_pair_into_both_channels()
  local host = fakeHost(1)
  local renderer, _ = renderingCalls()
  local sink = sinkFor(host, renderer, "mono")
  Assert.isTrue(sink:update(), "a mono chunk primes like a stereo one")
  local chunk = host.sources[1].queueCalls[1]
  Assert.notNil(chunk, "the mono buffer reaches the host queue")
  for _, frame in ipairs({ 0, 1, 2, 3, 100, CHUNK_FRAMES - 1 }) do
    local mono = expectedMono(frame)
    Assert.equal(queuedWord(chunk, frame, 1), mono, "mono carries the average on the left of frame " .. frame)
    Assert.equal(queuedWord(chunk, frame, 2), mono, "mono carries the average on the right of frame " .. frame)
  end
end

function T.a_refused_mono_queue_retries_the_once_transformed_buffer()
  local host = fakeHost(1)
  host.refuseQueue = true
  local renderer, state = renderingCalls()
  local sink = sinkFor(host, renderer, "mono")
  local err = Assert.throws(function()
    sink:update()
  end, "a refused queue must fail the update")
  Assert.isTrue(tostring(err):find("queue", 1, true) ~= nil, "the failure names the queue step")
  Assert.equal(state.calls, 1, "the refused chunk is retained instead of rerendered")
  local parked = host.soundData[1]
  Assert.notNil(parked, "the rendered buffer is parked for the retry")
  Assert.equal(parked.releaseCalls, 0, "the parked buffer is retained, not released")
  Assert.isTrue(sink:update(), "the retry publishes the parked buffer")
  Assert.equal(state.calls, 1, "retrying publication must not advance the renderer")
  local queued = host.sources[1].queueCalls[1]
  Assert.isTrue(queued == parked, "the retry queues the same once-transformed buffer")
  for _, frame in ipairs({ 0, 1, 2, 3, CHUNK_FRAMES - 1 }) do
    local mono = expectedMono(frame)
    Assert.equal(queuedWord(queued, frame, 1), mono, "the retried buffer averages frame " .. frame .. " exactly once")
    Assert.equal(queuedWord(queued, frame, 2), mono, "the retried buffer averages frame " .. frame .. " exactly once")
  end
  Assert.equal(parked.releaseCalls, 1, "the queued host copy is released right after queueing")
end

function T.mode_change_with_pending_audio_affects_only_fresh_buffers()
  local host = fakeHost(1)
  host.refuseQueue = true
  local renderer, state = renderingCalls()
  local sink = sinkFor(host, renderer, "stereo")
  Assert.throws(function()
    sink:update()
  end, "the first queue is refused")
  Assert.equal(state.calls, 1, "one stereo chunk is parked")
  sink:setChannelMode("mono")
  Assert.isTrue(sink:update(), "the retry publishes the parked stereo buffer")
  Assert.equal(state.calls, 1, "the pending buffer is never reprocessed after the mode change")
  local retried = host.sources[1].queueCalls[1]
  local left, right = expectedStereo(3)
  Assert.equal(queuedWord(retried, 3, 1), left, "the pending buffer keeps its stereo left word")
  Assert.equal(queuedWord(retried, 3, 2), right, "the pending buffer keeps its stereo right word")
  host.sources[1].free = 1
  Assert.isTrue(sink:update(), "a fresh buffer renders after the mode change")
  Assert.equal(state.calls, 2, "the next free buffer renders exactly one fresh chunk")
  local fresh = host.sources[1].queueCalls[2]
  Assert.equal(queuedWord(fresh, 3, 1), expectedMono(3), "fresh buffers use the new mode on the left")
  Assert.equal(queuedWord(fresh, 3, 2), expectedMono(3), "fresh buffers use the new mode on the right")
end

function T.reset_for_new_track_and_release_keep_the_mono_lifetime()
  local host = fakeHost(1)
  local renderer, state = renderingCalls()
  local sink = sinkFor(host, renderer, "mono")
  Assert.isTrue(sink:update(), "the first track primes")
  sink:resetForNewTrack()
  host.free = 1
  Assert.isTrue(sink:update(), "a fresh track primes again without resetting the mode")
  Assert.equal(state.calls, 2, "the new track renders a fresh mono chunk")
  local fresh = host.sources[#host.sources].queueCalls[1]
  Assert.equal(queuedWord(fresh, 3, 1), expectedMono(3), "the new track still averages")
  sink:release()
  sink:release()
  local callsAfterRelease = state.calls
  sink:update()
  Assert.equal(state.calls, callsAfterRelease, "an update after release renders nothing")
end

function T.channel_mode_rejects_anything_but_stereo_or_mono()
  local host = fakeHost(1)
  local renderer, _ = renderingCalls()
  for _, mode in ipairs({ "Stereo", "MONO", "", "quad", 5, true }) do
    Assert.throws(function()
      sinkFor(host, renderer, mode)
    end, "construction must reject channel mode " .. tostring(mode))
  end
  local sink = sinkFor(host, renderer, "stereo")
  for _, mode in ipairs({ "quad", "", 5 }) do
    Assert.throws(function()
      sink:setChannelMode(mode)
    end, "setChannelMode must reject " .. tostring(mode))
  end
  Assert.throws(function()
    sink:setChannelMode(nil)
  end, "setChannelMode must reject nil")
  sink:setChannelMode("mono")
  sink:setChannelMode("stereo")
end

function T.muted_master_gain_leaves_transport_and_voice_completion_running()
  -- The master gain lives outside the sink: muting applies at the host
  -- volume boundary while the sink keeps pumping rendered PCM.
  local appliedGains = {}
  local function setMasterGain(gain)
    appliedGains[#appliedGains + 1] = gain
  end
  setMasterGain(0 / 100)
  local host = fakeHost(1)
  local voiceChunks, rendered = 3, 0
  local voiceDone = false
  local renderer = {}
  function renderer:renderIntoInt16(ptr, frames)
    rendered = rendered + 1
    if rendered <= voiceChunks then
      for index = 0, frames * CHANNELS - 1 do
        ptr[index] = 1000 + index
      end
    else
      for index = 0, frames * CHANNELS - 1 do
        ptr[index] = 0
      end
      voiceDone = true
    end
  end
  local sink = sinkFor(host, renderer, "stereo")
  local primed = false
  for _ = 1, voiceChunks + 2 do
    if host.sources[1] ~= nil then
      host.sources[1].free = 1
    end
    primed = sink:update()
  end
  Assert.isTrue(voiceDone, "the finite voice completes while the master gain stays muted")
  Assert.isTrue(primed, "transport stays primed while muted")
  Assert.equal(rendered, voiceChunks + 2, "muting never pauses rendering")
  Assert.deepEqual(appliedGains, { 0 / 100 }, "the test holds the mute at the external gain boundary")
end

-- The validated player-options closure carries the confirmed channel mode
-- to the live sink: the same preparation that adopts the six player fields
-- updates the one output scalar, while the headless no-sink path stays
-- valid and malformed modes fail at validation.

local CHARMAP = { A = 1, B = 2 }
local FRAME_INDEXES = { [0] = true, [1] = true }

local function validatedPlayerData(soundMode)
  return assert(PlayerData.validate({
    profile = {
      name = "A",
      rivalName = "B",
      gender = 0,
      trainerId = 0,
      money = 3000,
      badges = BadgeSets.empty(),
      nationalDex = false,
      runningShoes = false,
      runningShoesLock = false,
    },
    options = {
      textSpeed = "mid",
      textFrame = 0,
      battleStyle = "shift",
      battleScene = true,
      soundMode = soundMode or "stereo",
      battleSpeed = 1,
    },
  }, { charmap = CHARMAP, frameIndexes = FRAME_INDEXES }))
end

local function coordinatorHarness(playerData, audioSink)
  local harness = {
    playerData = playerData,
    playerDataContext = { charmap = CHARMAP, frameIndexes = FRAME_INDEXES },
    audioSink = audioSink,
  }
  harness.coordinator = FieldMenuCompositionCoordinator.new(harness)
  return harness
end

local function recordingSink()
  local sink = { modes = {} }
  function sink:setChannelMode(mode)
    self.modes[#self.modes + 1] = mode
  end
  return sink
end

local function confirmedOptions(soundMode)
  return {
    textSpeed = "mid",
    textFrame = 0,
    battleStyle = "shift",
    battleScene = true,
    soundMode = soundMode,
    battleSpeed = 1,
  }
end

-- The validated closure carries the confirmed channel mode to the live
-- sink in both directions, while the headless no-sink path stays valid
-- and still adopts the confirmed options.
function T.confirmed_channel_mode_reaches_the_live_sink_and_nil_sink_stays_valid()
  local sink = recordingSink()
  local harness = coordinatorHarness(validatedPlayerData("stereo"), sink)
  local attempt = assert(harness.coordinator:preparePlayerOptions(confirmedOptions("mono")))
  attempt.apply()
  Assert.equal(harness.playerData.options.soundMode, "mono", "the closure adopts the confirmed mode")
  Assert.deepEqual(sink.modes, { "mono" }, "the closure updates the live sink scalar exactly once")
  local back = coordinatorHarness(validatedPlayerData("mono"), sink)
  local backAttempt = assert(back.coordinator:preparePlayerOptions(confirmedOptions("stereo")))
  backAttempt.apply()
  Assert.deepEqual(sink.modes, { "mono", "stereo" }, "the closure carries stereo back to the live sink")
  local headless = coordinatorHarness(validatedPlayerData("stereo"), nil)
  local headlessAttempt = assert(headless.coordinator:preparePlayerOptions(confirmedOptions("mono")))
  headlessAttempt.apply()
  Assert.equal(headless.playerData.options.soundMode, "mono", "the headless path adopts options without a sink")
end

function T.malformed_mode_fails_at_validation_before_any_sink_update()
  local sink = recordingSink()
  local harness = coordinatorHarness(validatedPlayerData("stereo"), sink)
  local attempt, err = harness.coordinator:preparePlayerOptions(confirmedOptions("quad"))
  Assert.isNil(attempt, "a malformed mode prepares nothing")
  Assert.isTrue(
    err ~= nil and Errors.is(err) and err.code == FieldErrors.PLAYER_DATA_INVALID,
    "a malformed mode fails at option validation, got " .. tostring(err)
  )
  Assert.deepEqual(sink.modes, {}, "validation failure never touches the sink")
  Assert.equal(harness.playerData.options.soundMode, "stereo", "validation failure mutates no live options")
end

return { tests = T }
