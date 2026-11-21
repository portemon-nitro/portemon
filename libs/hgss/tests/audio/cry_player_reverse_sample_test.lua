-- Reversed cries without a full copy: a reversed direct-wave voice borrows
-- the provider sample and indexes it backwards instead of allocating a
-- second reversed buffer. The fixture's loop window ends before the full
-- sample so the tests discriminate a whole-buffer reversal from a
-- loop-window reversal. Synthetic bytes only; nothing here touches a ROM.

local Assert = require("tests.support.Assert")
local AudioFixture = require("tests.support.AudioFixture")
local AudioAssetProvider = require("libs.hgss.src.audio.AudioAssetProvider")
local VoiceMixer = require("libs.nds.src.nitro.sound.VoiceMixer")
local SequencePlayer = require("libs.nds.src.nitro.sound.SequencePlayer")
local WaveOutPlayer = require("libs.nds.src.nitro.sound.WaveOutPlayer")
local CryPlayer = require("libs.hgss.src.audio.CryPlayer")

local T = {}

-- Eight frames with a five-frame loop window: a whole-buffer reversal
-- starts from the last frame, a loop-window reversal would start from the
-- fifth.
local CRY_VALUES = { 1000, -2000, 3000, -4000, 5000, -6000, 7000, -8000 }
local CRY_KEY_NUMBER = 9
local CRY_BANK_ID = 183

local function cryBundle()
  local bundle = AudioFixture.bundle()
  local key = AudioFixture.key(CRY_KEY_NUMBER)
  bundle.samples[key] = AudioFixture.pcm16le(CRY_VALUES)
  bundle.sampleMetadata[key] = AudioFixture.sampleMetadata(
    key,
    { frames = #CRY_VALUES, loopEnabled = false, loop = { startFrame = 0, endFrame = 5 } }
  )
  bundle.banks[CRY_BANK_ID] = AudioFixture.bank(CRY_BANK_ID, "BANK_CRY_TEST", { key }, {
    [0] = { kind = "direct", voice = AudioFixture.sampleVoice(key) },
  })
  bundle.index.banks[CRY_BANK_ID] = { id = CRY_BANK_ID, symbol = "BANK_CRY_TEST" }
  bundle.index.bankBySymbol["BANK_CRY_TEST"] = CRY_BANK_ID
  return bundle
end

-- The production provider over the selected epoch's resident bytes: every
-- direct-wave action acquires its own release-capable lease over the store's
-- single compact PCM backing.
local function residentProvider()
  local cache = AudioFixture.residentCache(cryBundle())
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

local function reverseOptions(speed)
  return { volume = 127, pan = 0, speed = speed or 8006, reverse = true }
end

-- The stored frame values through either representation: indexed reads on
-- a packed sample, a plain copy of a stored array otherwise.
local function storedValues(pcm)
  if type(pcm.read) == "function" then
    local values = {}
    for index = 0, pcm.frames - 1 do
      values[#values + 1] = pcm:read(index)
    end
    return values
  end
  local values = {}
  for index = 1, #pcm do
    values[#values + 1] = pcm[index]
  end
  return values
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

-- A reversed voice borrows the provider sample instead of copying it, and
-- its first rendered frame is the buffer's last frame -- the whole buffer
-- backwards, not the shorter loop window. A second reversed start shares
-- the same borrowed object, and the provider sample is never rewritten.
function T.reversed_playback_borrows_the_whole_buffer_not_the_loop_window()
  local provider = residentProvider()
  local key = AudioFixture.key(CRY_KEY_NUMBER)
  local firstLease = provider:acquireSample(key)
  local secondLease = provider:acquireSample(key)
  local source = assert(firstLease.value)
  local mixer = VoiceMixer.new({ sampleRate = 48000 })
  local player = WaveOutPlayer.new({ mixer = mixer })
  local handle = assert(player:start(14, firstLease, reverseOptions()))
  local second = assert(player:start(15, secondLease, reverseOptions()))
  mixer:controlStep()
  local out = mixer:render(64)
  Assert.equal(#out, 128, "one interleaved stereo span per rendered frame")
  Assert.equal(leftAt(out, 1), -16000, "reversal starts from the buffer's last frame, past the loop end")
  Assert.equal(out[2], 0, "the untouched channel stays silent")
  Assert.equal(fingerprint16(out), 4072570224, "the reversed trace matches the exact old reversal")
  Assert.deepEqual(storedValues(source.pcm), CRY_VALUES, "reversal never rewrites the provider sample")
  Assert.isNil(handle.sample, "a handle keeps only channel/generation identity")
  Assert.isNil(second.sample, "a handle keeps only channel/generation identity")
  Assert.equal(provider:status().activeSamples, 1, "both voices share one active sample record")
  Assert.isTrue(player:isPlaying(handle), "the first reversed voice stays live beside the second")
  Assert.isTrue(player:isPlaying(second), "the second reversed voice stays live")
end

-- Stealing and stopping touch playback handles, never the borrowed
-- backing: the stolen generation retires, the stopped voice goes quiet,
-- the mixer stops reporting the sample once no voice borrows it, and the
-- provider bytes are intact throughout.
function T.stealing_and_stopping_keep_the_borrowed_backing_intact()
  local provider = residentProvider()
  local key = AudioFixture.key(CRY_KEY_NUMBER)
  local sourceLease = provider:acquireSample(key)
  local source = assert(sourceLease.value)
  local mixer = VoiceMixer.new({ sampleRate = 48000 })
  Assert.equal(
    type(mixer.isSampleActive),
    "function",
    "the mixer answers whether a borrowed sample still sounds on any of its 16 channels"
  )
  local player = WaveOutPlayer.new({ mixer = mixer })
  local firstVoiceLease = provider:acquireSample(key)
  local first = assert(player:start(14, firstVoiceLease, reverseOptions()))
  local secondVoiceLease = provider:acquireSample(key)
  local replacement = assert(player:start(14, secondVoiceLease, reverseOptions()))
  Assert.isFalse(player:isPlaying(first), "a fixed-channel replacement retires the stolen generation")
  Assert.isNil(firstVoiceLease.value, "the stolen generation returns its own acquisition")
  Assert.isTrue(player:isPlaying(replacement), "the replacement generation is live")
  player:stop(replacement)
  Assert.isNil(secondVoiceLease.value, "the stopped generation returns its own acquisition")
  Assert.isFalse(player:isPlaying(replacement), "stopping a reversed voice removes its live resource")
  mixer:controlStep()
  Assert.deepEqual(storedValues(source.pcm), CRY_VALUES, "steals and stops never rewrite the provider sample")
  Assert.equal(
    type(mixer.isSampleActive),
    "function",
    "the mixer answers whether a borrowed sample still sounds on any of its 16 channels"
  )
  Assert.isFalse(mixer:isSampleActive(source.pcm), "the stopped sample reports no borrowers")
  local liveLease = provider:acquireSample(key)
  local live = assert(player:start(14, liveLease, reverseOptions()))
  Assert.isTrue(mixer:isSampleActive(source.pcm), "a new start borrows the sample again")
  player:stop(live)
  mixer:controlStep()
  Assert.isFalse(mixer:isSampleActive(source.pcm), "no voice borrows the sample after the stop")
  Assert.isNil(liveLease.value, "the stopped voice returned its acquisition")
  Assert.notNil(sourceLease.value, "the caller's own acquisition stays valid")
  sourceLease:release()
end

-- The retail reversed-cry pattern sounds the borrowed sample through the
-- real cry composition: both fixed channels stay busy on the same
-- provider object, the overlap renders its exact trace, and completion
-- follows the voices instead of stranding the borrowing.
function T.special_cries_sound_the_borrowed_reversed_sample_through_the_retail_pattern()
  local provider = residentProvider()
  local sourceLease = provider:acquireSample(AudioFixture.key(CRY_KEY_NUMBER))
  local source = assert(sourceLease.value)
  local mixer = VoiceMixer.new({ sampleRate = 48000 })
  local engine = SequencePlayer.new({ sampleRate = 48000, mixer = mixer, provider = provider })
  local wave = WaveOutPlayer.new({ mixer = mixer })
  local cry = CryPlayer.new({ player = engine, provider = provider, waveOut = wave })
  cry:play(CRY_BANK_ID, 4)
  Assert.isFalse(cry:isFinished(), "the reversed cry is busy while both fixed channels sound")
  Assert.equal(
    provider:status().acquisitions,
    3,
    "each direct-wave action took its own acquisition beside the caller's keeper"
  )
  mixer:controlStep()
  local out = mixer:render(64)
  Assert.equal(fingerprint16(out), 1503969280, "the cry overlap renders its exact reversed trace")
  local steps = 0
  while not cry:isFinished() do
    assert(steps < 20, "the reversed cry completes within its frame budget")
    mixer:render(250)
    mixer:controlStep()
    steps = steps + 1
  end
  Assert.deepEqual(storedValues(source.pcm), CRY_VALUES, "the cry never rewrites the provider sample")
  Assert.equal(
    type(mixer.isSampleActive),
    "function",
    "the mixer answers whether a borrowed sample still sounds on any of its 16 channels"
  )
  cry:play(CRY_BANK_ID, 4)
  Assert.isTrue(mixer:isSampleActive(source.pcm), "the cry keeps its borrowed sample live")
  local replaySteps = 0
  while not cry:isFinished() do
    assert(replaySteps < 20, "the replayed cry completes within its frame budget")
    mixer:render(250)
    mixer:controlStep()
    replaySteps = replaySteps + 1
  end
  Assert.isFalse(mixer:isSampleActive(source.pcm), "completion returns every voice's acquisition")
  Assert.equal(provider:status().activeSamples, 1, "only the caller's keeper acquisition remains")
  Assert.notNil(sourceLease.value, "the sounding actions never took the caller's acquisition")
  sourceLease:release()
  provider:dispose()
end

return { tests = T }
