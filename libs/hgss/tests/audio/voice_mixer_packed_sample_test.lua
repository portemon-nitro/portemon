-- Packed sample values: the provider hands the mixer one immutable packed
-- sample per content key instead of a per-key Lua number array. A packed
-- sample carries its frame count, keeps its single byte backing beside the
-- read pointer, and answers every frame through a zero-based indexed read,
-- so the mixer never indexes a Lua array and accounted bytes always come
-- from frame counts. Every acquisition is one release-capable lease over the
-- resident backing, and a sounding voice owns its lease until physical
-- removal. Synthetic bytes only; nothing here touches a ROM.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local AudioFixture = require("tests.support.AudioFixture")
local AudioAssetProvider = require("libs.hgss.src.audio.AudioAssetProvider")
local VoiceMixer = require("libs.nds.src.nitro.sound.VoiceMixer")
local ffi = require("ffi")

local T = {}

-- The int16 edge/commitment set: the domain bounds plus the values around
-- zero whose byte patterns discriminate a little-endian misread.
local EDGE_VALUES = { -32768, -1, 0, 1, 32767 }
local EDGE_KEY_NUMBER = 7

-- A byte-order witness: 0x1234 little-endian must read 4660, never the
-- swapped 0x3412.
local ENDIAN_VALUES = { 4660, -4661 }
local ENDIAN_KEY_NUMBER = 8

local function bundleWithEdgeSamples()
  local bundle = AudioFixture.bundle()
  local edgeKey = AudioFixture.key(EDGE_KEY_NUMBER)
  bundle.samples[edgeKey] = AudioFixture.pcm16le(EDGE_VALUES)
  bundle.sampleMetadata[edgeKey] = AudioFixture.sampleMetadata(
    edgeKey,
    { frames = #EDGE_VALUES, baseTimer = 16, loop = { startFrame = 0, endFrame = 5 } }
  )
  local endianKey = AudioFixture.key(ENDIAN_KEY_NUMBER)
  bundle.samples[endianKey] = AudioFixture.pcm16le(ENDIAN_VALUES)
  bundle.sampleMetadata[endianKey] = AudioFixture.sampleMetadata(endianKey, { frames = #ENDIAN_VALUES })
  return bundle
end

-- The production provider over one resident store, with the base source
-- acquisition capability a selected runtime injects: a lease roots the store's
-- own bytes and its release clears that reference.
---@param bundle table
---@return AudioAssetProvider
local function residentProvider(bundle)
  local cache = AudioFixture.residentCache(bundle)
  return AudioAssetProvider.new(cache, {
    acquireSource = function(reference)
      local lease = { value = reference.data }
      function lease:release()
        self.value = nil
      end
      return lease
    end,
  })
end

---@param provider AudioAssetProvider
---@param key string
---@return table lease
---@return AudioAssetSample sample
local function acquire(provider, key)
  local lease = provider:acquireSample(key)
  return lease, assert(lease.value)
end

local function sampleValue(pcm, index)
  Assert.equal(
    type(pcm.read),
    "function",
    "a packed sample answers frames through a zero-based indexed read, never a Lua array"
  )
  return pcm:read(index)
end

-- The single backing behind a packed sample: a retained byte object whose
-- size is exactly twice the frame count, whether the runtime adopted
-- worker bytes or decoded plain input.
local function backingBytes(pcm)
  local data = pcm.data
  Assert.notNil(data, "a packed sample retains its byte backing beside the read pointer")
  local ok, size = pcall(function()
    return data:getSize()
  end)
  if ok then
    return size
  end
  return ffi.sizeof(data)
end

local function leftAt(pcm, frame)
  return pcm[frame * 2 - 1]
end

local function fingerprint16(values)
  local hash = 0
  for index = 1, #values do
    hash = (hash * 31 + (values[index] + 32768)) % 4294967296
  end
  return hash
end

function T.loads_edge_values_into_one_packed_backing_of_twice_the_frame_count()
  local provider = residentProvider(bundleWithEdgeSamples())
  local _, sample = acquire(provider, AudioFixture.key(EDGE_KEY_NUMBER))
  Assert.equal(sample.metadata.frames, #EDGE_VALUES, "the fixture carries five frames")
  Assert.equal(sample.pcm.frames, #EDGE_VALUES, "the packed sample counts frames, not array length")
  Assert.isNil(sample.pcm[1], "a packed sample is not a one-based Lua array")
  Assert.equal(backingBytes(sample.pcm), 2 * #EDGE_VALUES, "one backing holds exactly two bytes per frame")
  for index, expected in ipairs(EDGE_VALUES) do
    Assert.equal(sampleValue(sample.pcm, index - 1), expected, "edge value at zero-based frame " .. (index - 1))
  end
  local _, endian = acquire(provider, AudioFixture.key(ENDIAN_KEY_NUMBER))
  Assert.equal(sampleValue(endian.pcm, 0), 4660, "little-endian bytes read in host order")
  Assert.equal(sampleValue(endian.pcm, 1), -4661, "little-endian bytes read in host order")
  Assert.equal(backingBytes(endian.pcm), 2 * #ENDIAN_VALUES, "every key owns exactly one backing")
end

function T.rejects_odd_and_empty_payloads_under_the_provider_error_contract()
  local bundle = AudioFixture.bundle()
  local oddKey = AudioFixture.key(11)
  bundle.samples[oddKey] = "abc"
  bundle.sampleMetadata[oddKey] = AudioFixture.sampleMetadata(oddKey, { frames = 1 })
  local emptyKey = AudioFixture.key(12)
  bundle.samples[emptyKey] = ""
  bundle.sampleMetadata[emptyKey] = AudioFixture.sampleMetadata(emptyKey, { frames = 0 })
  local provider = residentProvider(bundle)
  local odd = Assert.throws(function()
    provider:acquireSample(oddKey)
  end)
  Assert.isTrue(Errors.is(odd), "a malformed payload stays a structured audio failure")
  Assert.equal(odd.code, "AUDIO_PROVIDER_SAMPLE_UNKNOWN", "a malformed payload keeps the sample error identity")
  local empty = Assert.throws(function()
    provider:acquireSample(emptyKey)
  end)
  Assert.isTrue(Errors.is(empty), "an empty payload stays a structured audio failure")
  Assert.equal(empty.code, "AUDIO_PROVIDER_SAMPLE_UNKNOWN", "an absent (empty) payload keeps the sample error identity")
end

-- The mixer plays the packed backing bit-identically: a deterministic
-- voice over the edge sample renders every edge value at its exact frame
-- through the whole loop window, with the untouched channel silent.
function T.plays_every_packed_frame_through_a_deterministic_voice()
  local provider = residentProvider(bundleWithEdgeSamples())
  local lease, sample = acquire(provider, AudioFixture.key(EDGE_KEY_NUMBER))
  local mixer = VoiceMixer.new({ sampleRate = 16756991 })
  mixer:noteOn({
    generator = { kind = "sample", sample = AudioFixture.key(EDGE_KEY_NUMBER) },
    sampleLease = lease,
    pcm = sample.pcm,
    baseTimer = 16,
    loopEnabled = true,
    loop = { startFrame = 0, endFrame = 5 },
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
  mixer:controlStep()
  local out = mixer:render(80)
  Assert.equal(#out, 160, "one interleaved stereo span per rendered frame")
  local pins = {
    { 1, -32768 },
    { 16, -32768 },
    { 17, -1 },
    { 32, -1 },
    { 33, 0 },
    { 48, 0 },
    { 49, 1 },
    { 64, 1 },
    { 65, 32767 },
    { 80, 32767 },
  }
  for _, pin in ipairs(pins) do
    Assert.equal(leftAt(out, pin[1]), pin[2], "packed frame " .. pin[1] .. " renders the edge value")
  end
  Assert.equal(out[2], 0, "the untouched channel stays silent")
  Assert.equal(fingerprint16(out), 1270087696, "the deterministic voice renders its exact trace")
end

function T.counts_retained_bytes_from_frame_counts_with_shared_acquisitions()
  local provider = residentProvider(bundleWithEdgeSamples())
  local edgeLease, edge = acquire(provider, AudioFixture.key(EDGE_KEY_NUMBER))
  local plainLease, plain = acquire(provider, AudioFixture.key(1))
  Assert.equal(edge.pcm.frames, #EDGE_VALUES, "frame totals come from the packed count, not array length")
  Assert.equal(plain.pcm.frames, 4, "every key carries its own frame total")
  local status = provider:status()
  Assert.equal(
    status.activeSourceBytes,
    edge.pcm.frames * 2 + plain.pcm.frames * 2,
    "active source bytes count two bytes per packed frame"
  )
  Assert.equal(status.activeSamples, 2, "each acquired key is one active sample record")
  local sharedLease, shared = acquire(provider, AudioFixture.key(EDGE_KEY_NUMBER))
  Assert.isTrue(shared.pcm == edge.pcm, "a repeated key shares one backing")
  Assert.equal(provider:status().activeSamples, 2, "a repeated acquisition adds no active record")
  Assert.equal(provider:status().acquisitions, 3, "every successful acquisition is counted")
  sharedLease:release()
  Assert.notNil(edgeLease.value, "one return leaves the other acquisition valid")
  edgeLease:release()
  plainLease:release()
  Assert.equal(provider:status().activeSamples, 0, "returning every acquisition drops the active records")
  Assert.equal(provider:status().activeSourceBytes, 0, "no resident source bytes stay attributed")
  provider:dispose()
end

-- A live voice owns its backing: releasing the provider and collecting
-- keeps the voice sounding bit-identically, and the mixer reports the
-- borrowed sample live until the voice is stopped.
function T.voices_retain_their_sample_after_provider_release_and_collection()
  local function playOnce(rate)
    local provider = residentProvider(bundleWithEdgeSamples())
    local lease, sample = acquire(provider, AudioFixture.key(EDGE_KEY_NUMBER))
    local pcm = sample.pcm
    local mixer = VoiceMixer.new({ sampleRate = rate })
    local handle = mixer:noteOn({
      generator = { kind = "sample", sample = AudioFixture.key(EDGE_KEY_NUMBER) },
      sampleLease = lease,
      pcm = pcm,
      baseTimer = 16,
      loopEnabled = true,
      loop = { startFrame = 0, endFrame = 5 },
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
    mixer:controlStep()
    return mixer, handle, pcm
  end
  local firstMixer, firstHandle = playOnce(16756991)
  local reference = firstMixer:render(80)
  Assert.isTrue(firstMixer:isVoiceAlive(firstHandle), "the reference voice sounds")

  -- playOnce's provider is unreachable after it returns: the voice alone
  -- carries the borrowed sample into the collection below.
  local mixer, handle, pcm = playOnce(16756991)
  collectgarbage("collect")
  Assert.isTrue(mixer:isVoiceAlive(handle), "the voice outlives the released provider")
  Assert.deepEqual(mixer:render(80), reference, "collection changes nothing in the rendered trace")
  Assert.equal(
    type(mixer.isSampleActive),
    "function",
    "the mixer answers whether a borrowed sample still sounds on any of its 16 channels"
  )
  Assert.isTrue(mixer:isSampleActive(pcm), "the borrowed sample stays live while its voice sounds")
  mixer:stopVoice(handle)
  Assert.isFalse(mixer:isSampleActive(pcm), "a stopped voice releases its borrowed sample")
end

-- The shared shape packs plain input bytes and adopts worker bytes
-- without recopying: the adopted object keeps the caller's Data beside
-- the pointer with the same frame count and the same indexed values.
function T.packs_plain_bytes_and_adopts_worker_data_through_the_shared_shape()
  local okPcm, Pcm16 = pcall(require, "libs.nds.src.nitro.sound.Pcm16")
  Assert.isTrue(okPcm, "one shared sample representation packs plain bytes and adopts worker bytes")
  local bytes = AudioFixture.pcm16le(EDGE_VALUES)
  local packed = Pcm16.fromBytes(bytes)
  Assert.equal(packed.frames, #EDGE_VALUES, "plain bytes pack to the frame count")
  Assert.equal(backingBytes(packed), 2 * #EDGE_VALUES, "plain bytes pack into one backing")
  for index, expected in ipairs(EDGE_VALUES) do
    Assert.equal(sampleValue(packed, index - 1), expected, "packed byte frame " .. (index - 1))
  end
  Assert.throws(function()
    Pcm16.fromBytes("abc")
  end, "an odd byte count never becomes a partial sample")
  local workerData = love.data.newByteData(bytes)
  local adopted = Pcm16.fromData(workerData)
  Assert.isTrue(adopted.data == workerData, "worker bytes are adopted beside the pointer, never recopied")
  Assert.equal(adopted.frames, #EDGE_VALUES, "adopted bytes carry the frame count")
  for index, expected in ipairs(EDGE_VALUES) do
    Assert.equal(sampleValue(adopted, index - 1), expected, "adopted byte frame " .. (index - 1))
  end
end

-- The render loop never resolves the backing: adopting bytes takes one
-- pointer resolution, and hundreds of rendered frames across control
-- steps take none, while the adopted bytes mix exactly like packed input.
function T.rendering_never_resolves_the_backing_pointer()
  local okPcm, Pcm16 = pcall(require, "libs.nds.src.nitro.sound.Pcm16")
  Assert.isTrue(okPcm, "one shared sample representation owns the backing pointer")
  local backing = ffi.new("int16_t[?]", #EDGE_VALUES)
  for index, value in ipairs(EDGE_VALUES) do
    backing[index - 1] = value
  end
  local resolutions, strings = 0, 0
  local workerData = {
    getSize = function()
      return #EDGE_VALUES * 2
    end,
    getFFIPointer = function()
      resolutions = resolutions + 1
      return ffi.cast("const int16_t *", backing)
    end,
    getString = function()
      strings = strings + 1
      return ""
    end,
  }
  local adopted = Pcm16.fromData(workerData)
  Assert.equal(resolutions, 1, "adoption resolves the pointer once, outside the render loop")
  local mixer = VoiceMixer.new({ sampleRate = 16756991 })
  mixer:noteOn({
    generator = { kind = "sample", sample = "adopted" },
    sampleLease = AudioFixture.sampleLease(adopted),
    pcm = adopted,
    baseTimer = 16,
    loopEnabled = true,
    loop = { startFrame = 0, endFrame = 5 },
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
  Assert.equal(resolutions, 1, "starting the voice reuses the adopted pointer")
  mixer:controlStep()
  local out = mixer:render(400)
  mixer:controlStep()
  local tail = mixer:render(80)
  for index = 1, #tail do
    out[#out + 1] = tail[index]
  end
  Assert.equal(resolutions, 1, "rendering hundreds of frames resolves no pointer")
  Assert.equal(strings, 0, "rendering copies no byte strings out of the backing")
  Assert.equal(fingerprint16(out), 2205761632, "adopted bytes mix exactly like packed input")
end

return { tests = T }
