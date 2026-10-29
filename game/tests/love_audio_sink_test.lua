-- LoveAudioSink contract: the thin LÖVE output adapter. It owns queue
-- management -- request PCM frames from the renderer, build host SoundData
-- buffers (output sample rate, 16-bit, 2 channels) populated with the rendered
-- stereo PCM, queue them into the host QueueableSource, keep the host source
-- started/restarted, and release host resources exactly once -- and
-- understands nothing else: no notes, no sequence ids, no fades, no asset
-- parsing. The love.audio and love.sound namespaces are injected (no audio
-- device in CI); the renderer is injected as a callable so the sink is
-- testable without the whole playback stack. The renderer contract is exact
-- (#pcm == requestedFrames * 2) and the host-error policy is one policy: every
-- host failure propagates from the update and releases exactly what that
-- update acquired, leaving the sink usable.
--
-- SoundData's first argument is the per-channel frame count, NOT the total
-- interleaved scalar count: a render of 512 frames returns 1024 scalars and
-- must build a 512-frame SoundData (getSampleCount() == 512). The queue depth
-- is equally explicit: two 512-frame buffers at the 32768 Hz output rate is
-- 62.5 ms of queued PCM, within the 70 ms project budget, and the source is
-- constructed with that buffer count instead of LÖVE's accidental default
-- depth. A refused queue (the real binding returns false rather than throwing)
-- must fail the update -- a rendered chunk is never silently discarded. The
-- real-LÖVE smoke test verifies the constructed frame count where the API
-- permits.

local ffi = require("ffi")

local Assert = require("tests.support.Assert")
local LoveAudioSink = require("game.src.audio.LoveAudioSink")

local T = {}

local SAMPLE_RATE = 32768
local CHANNELS = 2
local BIT_DEPTH = 16

-- The explicit low-latency queue budget the sink must configure: two 512-frame
-- stereo chunks at 32768 Hz are 62.5 ms of queued PCM, within the project
-- budget. The chunk size is a FRAME count; the renderer returns twice that
-- many interleaved scalar values.
local CHUNK_FRAMES = 512
local QUEUE_BUFFER_COUNT = 4
local MAX_LATENCY_MS = 70

-- A SoundData-shaped recording object mirroring the LÖVE contract the sink
-- consumes: the constructor's first argument is a per-channel frame count
-- (real love.sound.newSoundData allocates frames * bytesPerSample * channels),
-- channels are 1-based, getSampleCount reports frames per channel, sample
-- values are floats in [-1, 1] (int16 divided by 32768), and release is
-- explicit. The samples live in one stable int16 backing the sink writes
-- through the live-pointer accessor, exactly like the real host memory;
-- getSize reports the exact byte count. A per-buffer pointer refusal models
-- a host that cannot expose its memory. setSample stays available as part
-- of the observable sample interface and writes the same backing, and its
-- call count proves the sink never falls back to per-sample population.
local function newFakeSoundData(frames, sampleRate, bitDepth, channels)
  local backing = ffi.new("int16_t[?]", frames * channels)
  local data = {
    constructorFrames = frames,
    sampleRate = sampleRate,
    bitDepth = bitDepth,
    channels = channels,
    sampleCount = frames,
    setSampleCalls = 0,
    failPointer = false,
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
    if self.failPointer then
      return nil
    end
    return backing
  end
  function data:getSample(i, channel)
    assert(i >= 0 and channel >= 1 and channel <= self.channels and i < self.sampleCount, "sample out of range")
    return tonumber(backing[i * self.channels + (channel - 1)]) / 32768
  end
  function data:setSample(i, channel, sample)
    assert(i >= 0 and channel >= 1 and channel <= self.channels and i < self.sampleCount, "sample out of range")
    self.setSampleCalls = self.setSampleCalls + 1
    backing[i * self.channels + (channel - 1)] = math.floor(sample * 32768 + 0.5)
  end
  function data:release()
    self.releaseCalls = self.releaseCalls + 1
  end
  return data
end

-- A love.audio + love.sound-shaped namespace with scriptable buffer
-- availability and injection points for source construction, SoundData
-- construction, queue failure/refusal, and play/free-query failures. The queue
-- rejects any payload that is not SoundData-shaped, exactly like the real
-- LÖVE binding. `freeBufferCount` overrides the source's advertised free
-- count; a nil value makes the source advertise its own explicit buffer
-- count, and `source.free` can still be adjusted between updates to simulate
-- the host playback head freeing buffers.
local function fakeHost(freeBufferCount)
  local host = {
    sources = {},
    soundData = {},
    free = freeBufferCount,
    failSource = false,
    failSoundData = false,
    failPointerOnSoundData = nil,
    failQueue = false,
    refuseQueue = false,
    failFreeBufferCount = false,
    failPlay = false,
  }
  function host.newSoundData(frames, sampleRate, bitDepth, channels)
    if host.failSoundData then
      host.failSoundData = false
      error("injected SoundData construction failure")
    end
    local data = newFakeSoundData(frames, sampleRate, bitDepth, channels)
    data.failPointer = (#host.soundData + 1) == host.failPointerOnSoundData
    host.soundData[#host.soundData + 1] = data
    return data
  end
  function host.newQueueableSource(sampleRate, bitDepth, channels, bufferCount)
    if host.failSource then
      host.failSource = false
      error("injected source construction failure")
    end
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
    }
    function source:queue(data)
      assert(
        type(data) == "table"
          and type(data.getSample) == "function"
          and type(data.getSampleCount) == "function"
          and type(data.getChannelCount) == "function",
        "queued payload must be SoundData-shaped (a Lua byte string is not queueable)"
      )
      if host.failQueue then
        host.failQueue = false
        error("injected queue failure")
      end
      if host.refuseQueue then
        host.refuseQueue = false
        return false
      end
      self.queueCalls[#self.queueCalls + 1] = data
      self.free = math.max(self.free - 1, 0)
    end
    function source:play()
      if host.failPlay then
        host.failPlay = false
        error("injected play failure")
      end
      self.playCalls = self.playCalls + 1
      self.playing = true
    end
    function source:stop()
      self.playing = false
    end
    function source:isPlaying()
      return self.playing
    end
    function source:getFreeBufferCount()
      if host.failFreeBufferCount then
        host.failFreeBufferCount = false
        error("injected free-buffer query failure")
      end
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

-- A renderer that writes frames * 2 samples through the typed seam, word
-- `index` (0-based flat index) = `pattern(index + 1)`, and records the first
-- requested frame count so tests can pin the sink's chunk size.
local function rendererReturning(pattern)
  local calls = 0
  local requested
  return {
    calls = function()
      return calls
    end,
    requestedFrameCount = function()
      return requested
    end,
    renderIntoInt16 = function(_, ptr, frames)
      assert(type(frames) == "number" and frames > 0, "the sink must request a positive frame count")
      calls = calls + 1
      requested = requested or frames
      for index = 0, frames * CHANNELS - 1 do
        ptr[index] = pattern(index + 1)
      end
    end,
  }
end

local function rendererReturningChunkMarkers()
  local chunk = 0
  local calls = 0
  return {
    calls = function()
      return calls
    end,
    renderIntoInt16 = function(_, ptr, frames)
      calls = calls + 1
      chunk = chunk + 1
      for index = 0, frames * CHANNELS - 1 do
        ptr[index] = chunk
      end
    end,
  }
end

local function queuedChunkMarkers(source)
  local markers = {}
  for _, data in ipairs(source.queueCalls) do
    markers[#markers + 1] = data:getSample(0, 1) * 32768
  end
  return markers
end


local function sinkFor(host, renderer)
  return LoveAudioSink.new({
    audio = host,
    sound = host,
    renderer = renderer,
    sampleRate = SAMPLE_RATE,
  })
end

function T.update_builds_the_queueable_source_with_the_output_format_and_explicit_buffer_count()
  local host = fakeHost(1)
  local renderer = rendererReturning(function()
    return 0
  end)
  local sink = sinkFor(host, renderer)
  sink:update()
  local source = host.sources[1]
  Assert.notNil(source, "one update must construct the queueable source")
  Assert.equal(source.sampleRate, SAMPLE_RATE)
  Assert.equal(source.bitDepth, BIT_DEPTH)
  Assert.equal(source.channels, CHANNELS)
  -- The queue depth is explicit, never LÖVE's accidental default depth.
  Assert.equal(
    source.bufferCount,
    QUEUE_BUFFER_COUNT,
    "the source must be constructed with the explicit queue-buffer count"
  )
  Assert.equal(renderer:calls(), 1, "one update must render exactly one chunk per free buffer")
  Assert.equal(source.playCalls, 1, "the sink must start the host source after queueing")
end

-- The central frame-count contract: a render of CHUNK_FRAMES frames returns
-- CHUNK_FRAMES * 2 interleaved scalars, and the SoundData is constructed with
-- the FRAME count, not the scalar count, so getSampleCount() reports the
-- frames per channel and no silent second half exists.
function T.sound_data_is_constructed_with_the_frame_count_and_every_frame_is_written()
  local host = fakeHost(1)
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = sinkFor(host, renderer)
  sink:update()
  local chunk = host.sources[1].queueCalls[1]
  -- Every queued object is SoundData-shaped, never a Lua byte string.
  Assert.equal(type(chunk.getSample), "function")
  Assert.equal(type(chunk.setSample), "function")
  Assert.equal(type(chunk.getSampleCount), "function")
  Assert.equal(type(chunk.getFFIPointer), "function")
  Assert.equal(type(chunk.getSize), "function")
  Assert.equal(type(chunk.release), "function")
  -- The buffer matches the required sample format.
  Assert.equal(chunk:getSampleRate(), SAMPLE_RATE)
  Assert.equal(chunk:getBitDepth(), BIT_DEPTH)
  Assert.equal(chunk:getChannelCount(), CHANNELS)
  -- CHUNK_FRAMES stereo frames are 2 * CHUNK_FRAMES interleaved scalars, but
  -- the constructor argument (and getSampleCount) is the per-channel FRAME
  -- count, and the byte size is exact.
  Assert.equal(
    chunk.constructorFrames,
    CHUNK_FRAMES,
    "newSoundData must receive the per-channel frame count, not the interleaved scalar count"
  )
  Assert.equal(chunk:getSampleCount(), CHUNK_FRAMES, "getSampleCount must report frames per channel")
  Assert.equal(chunk:getSize(), CHUNK_FRAMES * CHANNELS * 2, "the host buffer holds exactly the chunk bytes")
  Assert.notNil(chunk:getFFIPointer(), "the host buffer exposes its sample memory")
  -- Renderer interleaving maps to frame/channel exactly: frame 0 L/R are
  -- scalar values 1/2, frame CHUNK_FRAMES-1 L/R are scalars 2F-1/2F, and
  -- every word in between is exact, so no silent second half remains.
  for frame = 0, CHUNK_FRAMES - 1 do
    for channel = 1, CHANNELS do
      local word = frame * CHANNELS + channel
      Assert.equal(chunk:getSample(frame, channel), word / 32768, "buffer word " .. word .. " is exact")
    end
  end
  -- The whole buffer arrived through the typed seam: no per-sample fallback.
  Assert.equal(chunk.setSampleCalls, 0, "the sink never populates the buffer sample by sample")
  Assert.throws(function()
    chunk:getSample(CHUNK_FRAMES, 1)
  end, "no additional frame may exist beyond the requested frame count")
end

function T.free_buffer_count_controls_how_many_chunks_are_queued()
  local host = fakeHost(3)
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = sinkFor(host, renderer)
  sink:update()
  local source = host.sources[1]
  Assert.equal(renderer:calls(), 3, "the sink must queue one chunk per free buffer")
  Assert.equal(#source.queueCalls, 3)
  for index = 1, 3 do
    Assert.equal(
      host.soundData[index].releaseCalls,
      1,
      "the host copies the SoundData at queue time, so a queued buffer is released right after queueing"
    )
  end
  sink:update()
  Assert.equal(renderer:calls(), 3, "a full host queue must stop the pump")
  Assert.equal(#source.queueCalls, 3)
end

-- The required partial-availability scenarios in terms of the free count: a
-- brand-new source with two free buffers renders exactly two chunks, a full
-- source causes no renderer calls, and a single freed buffer yields exactly
-- one new chunk.
function T.a_brand_new_source_pumps_one_chunk_per_free_buffer()
  local host = fakeHost(2)
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = sinkFor(host, renderer)
  sink:update()
  local source = host.sources[1]
  Assert.equal(renderer:calls(), 2, "a source with two free buffers must queue exactly two chunks")
  Assert.equal(#source.queueCalls, 2)
  sink:update()
  Assert.equal(renderer:calls(), 2, "a full source must cause no renderer calls")
  Assert.equal(#source.queueCalls, 2)
  -- Simulate the host playback head freeing one buffer: exactly one chunk.
  source.free = 1
  sink:update()
  Assert.equal(renderer:calls(), 3, "one freed buffer must render exactly one new chunk")
  Assert.equal(#source.queueCalls, 3)
end

function T.a_stopped_host_source_is_restarted_without_rebuilding_it()
  local host = fakeHost(1)
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = sinkFor(host, renderer)
  sink:update()
  local source = host.sources[1]
  source:stop()
  sink:update()
  Assert.equal(source.playCalls, 2, "the sink must restart a host source that stopped")
  Assert.equal(#host.sources, 1, "restarting a healthy existing source must not rebuild it")
end

function T.release_releases_the_host_source_exactly_once_and_stops_the_pump()
  local host = fakeHost(1)
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = sinkFor(host, renderer)
  sink:update()
  local source = host.sources[1]
  sink:release()
  sink:release()
  Assert.equal(source.releaseCalls, 1, "the host source must be released exactly once")
  local callsAfterRelease = renderer:calls()
  sink:update()
  Assert.equal(renderer:calls(), callsAfterRelease, "an update after release must not request more PCM")
  Assert.equal(#host.sources, 1, "an update after release must not reacquire a source")
end

function T.a_sound_data_construction_failure_releases_the_partially_acquired_source()
  local host = fakeHost(1)
  host.failSoundData = true
  local renderer = rendererReturningChunkMarkers()
  local sink = sinkFor(host, renderer)
  local err = Assert.throws(function()
    sink:update()
  end)
  Assert.isTrue(
    tostring(err):find("injected SoundData construction failure", 1, true) ~= nil,
    "the construction failure must propagate: " .. tostring(err)
  )
  Assert.equal(#host.sources, 1, "the source must have been constructed before the buffer step")
  Assert.equal(host.sources[1].releaseCalls, 1, "the partially acquired source must not leak")
  sink:update()
  Assert.equal(#host.sources, 2, "the sink must stay usable and reacquire the source after the failure")
  Assert.equal(host.sources[2].releaseCalls, 0)
  Assert.equal(host.sources[2].playCalls, 1)
  Assert.equal(renderer:calls(), 1, "a rendered chunk must be retried after construction failure")
  Assert.equal(queuedChunkMarkers(host.sources[2])[1], 1, "retry must publish the original rendered chunk")
end

-- A thrown queue failure parks the already-rendered buffer instead of
-- leaking it: the next update retries the same buffer without advancing
-- the renderer.
function T.a_queue_failure_parks_the_rendered_buffer_for_retry()
  local host = fakeHost(1)
  host.failQueue = true
  local renderer = rendererReturningChunkMarkers()
  local sink = sinkFor(host, renderer)
  local err = Assert.throws(function()
    sink:update()
  end)
  Assert.isTrue(
    tostring(err):find("injected queue failure", 1, true) ~= nil,
    "the queue failure must propagate: " .. tostring(err)
  )
  Assert.equal(#host.soundData, 1, "the buffer must have been built before the queue step")
  Assert.equal(host.soundData[1].releaseCalls, 0, "the parked buffer is retained for the retry, not released")
  Assert.equal(renderer:calls(), 1, "the failed queue never consumed a replacement render")
  sink:update()
  Assert.equal(renderer:calls(), 1, "retrying publication must not advance the renderer")
  Assert.equal(#host.sources[1].queueCalls, 1)
  Assert.equal(queuedChunkMarkers(host.sources[1])[1], 1, "retry publishes the original chunk marker")
  Assert.equal(host.soundData[1].releaseCalls, 1, "the queued host copy is released right after queueing")
end

-- The real LÖVE binding signals a full/refused queue by returning false rather
-- than throwing. The sink must assert that success boolean: a refused chunk is
-- never silently considered delivered, and the uniform failure policy releases
-- the in-flight SoundData while the update propagates.
function T.a_refused_queue_is_never_silently_delivered_and_fails_fast()
  local host = fakeHost(1)
  host.refuseQueue = true
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = sinkFor(host, renderer)
  local err = Assert.throws(function()
    sink:update()
  end, "a refused queue must fail the update instead of silently discarding the chunk")
  Assert.isTrue(tostring(err):find("queue", 1, true) ~= nil, "the failure must name the queue step")
  Assert.equal(#host.sources, 1, "the source must have been constructed before the queue step")
  Assert.equal(#host.sources[1].queueCalls, 0, "a refused chunk must not be recorded as delivered")
  Assert.equal(#host.soundData, 1, "the buffer must have been built before the queue step")
  Assert.equal(host.soundData[1].releaseCalls, 0, "the parked buffer is retained for the retry, not released")
  sink:update()
  Assert.equal(#host.sources[1].queueCalls, 1, "the sink must stay usable and queue on the next update")
end

function T.a_refused_chunk_is_retried_without_rendering_a_replacement()
  local host = fakeHost(1)
  host.refuseQueue = true
  local renderer = rendererReturningChunkMarkers()
  local sink = sinkFor(host, renderer)
  Assert.throws(function()
    sink:update()
  end)
  Assert.equal(renderer:calls(), 1, "a refused chunk must be retained instead of rendering a replacement")
  Assert.equal(host.soundData[1].releaseCalls, 0, "the parked buffer is retained for the retry, not released")

  sink:update()
  Assert.equal(renderer:calls(), 1, "retrying publication must not advance the renderer")
  Assert.equal(#host.sources[1].queueCalls, 1)
  Assert.equal(queuedChunkMarkers(host.sources[1])[1], 1, "retry must publish the original chunk marker")
  Assert.equal(host.soundData[1].releaseCalls, 1, "the queued host copy is released right after queueing")
end

-- A host buffer that cannot expose its memory fails the update before any
-- render into it: the first chunk stays published, the fresh buffer is
-- released once, and the source stays owned by the sink.
function T.a_later_population_failure_keeps_published_source_and_pending_timeline()
  local host = fakeHost(3)
  host.failPointerOnSoundData = 2
  local renderer = rendererReturningChunkMarkers()
  local sink = sinkFor(host, renderer)
  Assert.throws(function()
    sink:update()
  end, "a buffer without exposed memory must fail the update")

  local source = host.sources[1]
  Assert.equal(renderer:calls(), 1, "the failed buffer is rejected before any render into it")
  Assert.equal(#source.queueCalls, 1, "the first chunk must already be published")
  Assert.equal(source.releaseCalls, 0, "a source that published audio must not be released")
  Assert.equal(host.soundData[2].releaseCalls, 1, "the failed transient SoundData must be released once")

  sink:update()
  Assert.equal(#host.sources, 1, "recovery must reuse the source that published the first chunk")
  Assert.equal(renderer:calls(), 3, "recovery must publish the pending chunk before rendering the next one")
  Assert.deepEqual(queuedChunkMarkers(source), { 1, 2, 3 })
end

-- The host buffer contract is exact: a buffer that cannot expose its sample
-- memory is a programming fault that must fail loudly before any render
-- into it, and the failure must not leak the fresh buffer.
function T.a_nil_host_pointer_fails_loudly_without_leaking_the_fresh_buffer()
  local host = fakeHost(1)
  host.failPointerOnSoundData = 1
  local renderer = rendererReturningChunkMarkers()
  local sink = sinkFor(host, renderer)
  local err = Assert.throws(function()
    sink:update()
  end)
  Assert.isTrue(
    tostring(err):find("sample memory", 1, true) ~= nil,
    "the fault must name the exposed-memory contract: " .. tostring(err)
  )
  Assert.equal(#host.soundData, 1, "the buffer must have been built before the pointer check")
  Assert.equal(host.soundData[1].releaseCalls, 1, "the fresh SoundData must not leak")
  Assert.equal(renderer:calls(), 0, "no render may run without exposed host memory")
  Assert.equal(#host.sources, 1, "the source must have been constructed before the buffer step")
  Assert.equal(host.sources[1].releaseCalls, 1, "the partially acquired source must not leak")
  sink:update()
  Assert.equal(#host.sources, 2, "the sink must stay usable and reacquire the source after the failure")
  Assert.equal(host.sources[2].releaseCalls, 0)
  Assert.equal(host.sources[2].playCalls, 1)
  Assert.equal(renderer:calls(), 1, "a fresh chunk renders after the pointer failure")
  Assert.equal(queuedChunkMarkers(host.sources[2])[1], 1, "retry must publish the freshly rendered chunk")
end

-- The host buffer contract is exact: a buffer whose byte size is not exactly
-- one 512-frame stereo int16 chunk is rejected before any render into it.
function T.a_wrong_sized_host_buffer_fails_before_any_render()
  for _, sizeOffset in ipairs({ -2, 2 }) do
    local host = fakeHost(1)
    local originalNewSoundData = host.newSoundData
    host.newSoundData = function(frames, sampleRate, bitDepth, channels)
      return originalNewSoundData(frames + sizeOffset, sampleRate, bitDepth, channels)
    end
    local renderer = rendererReturningChunkMarkers()
    local sink = sinkFor(host, renderer)
    local err = Assert.throws(function()
      sink:update()
    end)
    Assert.isTrue(
      tostring(err):find(string.format("%d stereo int16 samples", CHUNK_FRAMES * CHANNELS), 1, true) ~= nil,
      "the fault must name the exact expected sample count: " .. tostring(err)
    )
    Assert.equal(renderer:calls(), 0, "a wrong-sized buffer must never see a render")
    Assert.equal(#host.sources[1].queueCalls, 0, "a wrong-sized buffer must never reach the host queue")
    Assert.equal(host.soundData[1].releaseCalls, 1, "the fresh SoundData must not leak")
  end
end

-- The host-error policy is one policy across the whole pump: a failure outside
-- the per-chunk transaction -- the free-buffer query on a source acquired by
-- this update -- propagates and releases exactly what the failed update
-- acquired, leaving the sink usable for the next update.
function T.a_free_buffer_query_failure_releases_the_acquired_source()
  local host = fakeHost(1)
  host.failFreeBufferCount = true
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = sinkFor(host, renderer)
  local err = Assert.throws(function()
    sink:update()
  end)
  Assert.isTrue(
    tostring(err):find("injected free-buffer query failure", 1, true) ~= nil,
    "the free-buffer query failure must propagate: " .. tostring(err)
  )
  Assert.equal(host.sources[1].releaseCalls, 1, "the acquired source must not leak on the failed update")
  sink:update()
  Assert.equal(#host.sources, 2, "the sink must stay usable and reacquire the source")
  Assert.equal(host.sources[2].releaseCalls, 0)
  Assert.equal(host.sources[2].playCalls, 1)
end

-- A play failure after publication propagates, but the source remains owned by
-- the sink so the next update can retry starting the same queued source.
function T.a_play_failure_after_publication_keeps_the_queued_source()
  local host = fakeHost(1)
  host.failPlay = true
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = sinkFor(host, renderer)
  local err = Assert.throws(function()
    sink:update()
  end)
  Assert.isTrue(
    tostring(err):find("injected play failure", 1, true) ~= nil,
    "the play failure must propagate: " .. tostring(err)
  )
  Assert.equal(#host.sources[1].queueCalls, 1, "the chunk was queued before the start step")
  Assert.equal(host.sources[1].releaseCalls, 0, "a source with published audio must not be released")
  sink:update()
  Assert.equal(#host.sources, 1, "the sink must retry the same source")
  Assert.equal(host.sources[1].playCalls, 1)
  Assert.equal(renderer:calls(), 1, "a failed start must not re-render already queued audio")
end

-- The failure policy releases exactly what the failed update acquired: a
-- failure on a later update (the source pre-exists) must never release the
-- sink's own source, and the sink keeps pumping with the same source.
function T.a_later_failure_keeps_the_preexisting_source()
  local host = fakeHost(1)
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = sinkFor(host, renderer)
  sink:update()
  host.failFreeBufferCount = true
  local err = Assert.throws(function()
    sink:update()
  end)
  Assert.isTrue(
    tostring(err):find("injected free-buffer query failure", 1, true) ~= nil,
    "the later free-buffer query failure must propagate: " .. tostring(err)
  )
  Assert.equal(host.sources[1].releaseCalls, 0, "a pre-existing source is never released by a later failed update")
  sink:update()
  Assert.equal(#host.sources, 1, "the sink must keep the same source across the failure")
end

-- The explicit queue configuration must satisfy the project latency budget:
-- observed queue depth times observed chunk frames over the output rate stays
-- within MAX_LATENCY_MS of queued PCM.
function T.the_configured_queue_stays_within_the_latency_budget()
  local host = fakeHost(1)
  local renderer = rendererReturning(function(index)
    return index
  end)
  local sink = sinkFor(host, renderer)
  sink:update()
  local source = host.sources[1]
  local observedFrames = renderer:requestedFrameCount()
  local observedBuffers = source.bufferCount or 0
  Assert.equal(observedFrames, CHUNK_FRAMES, "each chunk must be exactly CHUNK_FRAMES frames")
  Assert.equal(observedBuffers, QUEUE_BUFFER_COUNT, "the queue depth must be exactly QUEUE_BUFFER_COUNT buffers")
  local budgetMs = observedBuffers * observedFrames / SAMPLE_RATE * 1000
  Assert.isTrue(
    budgetMs <= MAX_LATENCY_MS,
    string.format("queued PCM %.2f ms must stay within the %d ms budget", budgetMs, MAX_LATENCY_MS)
  )
end

-- A successfully queued and started chunk reports primed output: the host
-- owns at least one submitted current-track buffer and the source plays.
function T.successful_queue_and_start_reports_primed_output()
  local host = fakeHost(1)
  local renderer = rendererReturning(function()
    return 0
  end)
  local sink = sinkFor(host, renderer)
  local primed = sink:update()
  Assert.isTrue(primed, "a queued and started chunk must report primed output")
  Assert.isTrue(host.sources[1]:isPlaying(), "the host source plays after priming")
end

-- A host that refuses to start is never reported as primed, even when it
-- later claims to play: the explicit start result decides, not a stale flag.
function T.rejected_host_start_is_never_reported_as_primed()
  local host = fakeHost(1)
  local renderer = rendererReturning(function()
    return 0
  end)
  local sink = sinkFor(host, renderer)
  local source = nil
  local originalNewSource = host.newQueueableSource
  host.newQueueableSource = function(sampleRate, bitDepth, channels, bufferCount)
    source = originalNewSource(sampleRate, bitDepth, channels, bufferCount)
    function source:play()
      self.playCalls = self.playCalls + 1
      return false
    end
    return source
  end
  -- The fake host namespace doubles as both audio and sound namespaces, so
  -- patch both aliases that the sink captured at construction.
  local primed = sink:update()
  Assert.equal(primed, false, "a refused host start must not report primed output")
end

-- Starting a new track discards prior queue evidence: a failed new queue
-- cannot be acknowledged by old buffer occupancy.
function T.new_track_reset_discards_prior_queue_evidence()
  local host = fakeHost(1)
  local renderer = rendererReturning(function()
    return 0
  end)
  local sink = sinkFor(host, renderer)
  Assert.isTrue(sink:update(), "the first track primes")
  sink:resetForNewTrack()
  host.refuseQueue = true
  local ok, primed = pcall(sink.update, sink)
  Assert.isFalse(ok and primed == true, "a refused new queue must not inherit the prior track")
end

-- The sink renders straight into the host buffer through the typed seam:
-- one update asks the renderer for a single 512-frame pointer span and the
-- queued buffer reads back the exact written words.
function T.update_renders_directly_into_the_host_buffer_through_the_typed_seam()
  local ffi = require("ffi")
  local frames = CHUNK_FRAMES
  local backing = ffi.new("int16_t[?]", frames * CHANNELS)
  local soundData = { released = 0 }
  function soundData:getSampleRate()
    return SAMPLE_RATE
  end
  function soundData:getBitDepth()
    return BIT_DEPTH
  end
  function soundData:getChannelCount()
    return CHANNELS
  end
  function soundData:getSampleCount()
    return frames
  end
  function soundData:getSize()
    return frames * CHANNELS * 2
  end
  function soundData:getFFIPointer()
    return backing
  end
  function soundData:getSample(i, channel)
    return tonumber(backing[i * CHANNELS + (channel - 1)]) / 32768
  end
  function soundData:release()
    self.released = self.released + 1
  end
  local host = { sources = {} }
  function host.newSoundData(requestedFrames, sampleRate, bitDepth, channels)
    Assert.equal(requestedFrames, frames, "the host buffer is one 512-frame chunk")
    Assert.equal(sampleRate, SAMPLE_RATE)
    Assert.equal(bitDepth, BIT_DEPTH)
    Assert.equal(channels, CHANNELS)
    return soundData
  end
  function host.newQueueableSource(sampleRate, bitDepth, channels, bufferCount)
    local source = {
      sampleRate = sampleRate,
      bitDepth = bitDepth,
      channels = channels,
      bufferCount = bufferCount,
      free = 1,
      queueCalls = {},
      playCalls = 0,
      playing = false,
      releaseCalls = 0,
    }
    function source:queue(data)
      self.queueCalls[#self.queueCalls + 1] = data
      self.free = self.free - 1
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
  local renderer = { calls = 0, spans = {} }
  function renderer:renderIntoInt16(ptr, requestedFrames)
    self.calls = self.calls + 1
    Assert.equal(requestedFrames, frames, "the renderer fills one 512-frame span")
    for index = 0, requestedFrames * CHANNELS - 1 do
      ptr[index] = (index * 7) % 20001 - 10000
    end
  end
  local sink = sinkFor(host, renderer)
  Assert.isTrue(sink:update(), "the directly rendered chunk primes")
  Assert.equal(renderer.calls, 1, "one update renders exactly one span")
  local queued = host.sources[1].queueCalls[1]
  Assert.notNil(queued, "the rendered buffer reaches the host queue")
  for frame = 0, frames - 1 do
    for channel = 1, CHANNELS do
      local index = frame * CHANNELS + (channel - 1)
      local expected = ((index * 7) % 20001 - 10000) / 32768
      Assert.equal(queued:getSample(frame, channel), expected, "buffer word " .. index .. " is exact")
    end
  end
  Assert.equal(soundData.released, 1, "the queued host copy is released right after queueing")
end

return { tests = T }
