-- WaveOut fixed-channel lifecycle over the shared NNS VoiceMixer.

local Assert = require("tests.support.Assert")
local AudioFixture = require("tests.support.AudioFixture")
local VoiceMixer = require("libs.nds.src.nitro.sound.VoiceMixer")
local WaveOutPlayer = require("libs.nds.src.nitro.sound.WaveOutPlayer")

local T = {}

local function sample()
  return {
    metadata = { loop = { startFrame = 0, endFrame = 4 } },
    pcm = AudioFixture.packed({ 101, 202, 303, 404 }),
  }
end

-- Reads the stored frame values through either packed representation.
local function storedValues(pcm)
  local values = {}
  for index = 0, pcm.frames - 1 do
    values[#values + 1] = pcm:read(index)
  end
  return values
end

local function options(speed)
  return { volume = 100, pan = 64, speed = speed or 0x8600, reverse = true }
end

function T.reverses_private_samples_and_preserves_the_provider_sample()
  local source = sample()
  local mixer = VoiceMixer.new({ sampleRate = 48000 })
  local player = WaveOutPlayer.new({ mixer = mixer })
  local handle = assert(player:start(14, source, options()))

  Assert.isTrue(handle.sample == source, "a reversed start borrows the provider sample without copying")
  Assert.deepEqual(storedValues(source.pcm), { 101, 202, 303, 404 }, "the provider sample remains unchanged")
  Assert.isTrue(mixer:isSampleActive(source.pcm), "the reversed voice borrows its sample")
  Assert.equal(handle.channel, 14)
  Assert.equal(handle.generation, 0)
  Assert.isTrue(player:isPlaying(handle), "a newly started WaveOut voice is live")
end

function T.fixed_channels_share_generation_controls_and_liveness()
  local observed = {}
  local mixer = VoiceMixer.new({
    sampleRate = 48000,
    observer = {
      onChannelState = function(_, event)
        if event.active then
          observed[event.channel] = event
        end
      end,
    },
  })
  local player = WaveOutPlayer.new({ mixer = mixer })
  local first = assert(player:start(14, sample(), options()))
  local other = assert(player:start(15, sample(), options(0x6800)))
  local replacement = assert(player:start(14, sample(), options()))

  Assert.isFalse(player:isPlaying(first), "a fixed-channel replacement retires the stale generation")
  Assert.isTrue(player:isPlaying(replacement), "the replacement generation is live")
  Assert.equal(replacement.generation, 1)
  Assert.isTrue(player:isPlaying(other), "the other fixed channel remains independent")

  player:setVolume(other, 80)
  player:setPan(other, 100)
  player:setSpeed(other, 0x7000)
  mixer:controlStep()
  Assert.equal(observed[15].panRegister, 100, "WaveOut pan reaches the mixer control step")
  Assert.equal(observed[15].timer, 0x7000, "WaveOut speed reaches the mixer control step")

  player:stop(other)
  Assert.isFalse(player:isPlaying(other), "stopping a WaveOut voice removes its live resource")
end

function T.one_shot_wave_liveness_ends_at_the_source_boundary()
  local mixer = VoiceMixer.new({ sampleRate = 48000 })
  local player = WaveOutPlayer.new({ mixer = mixer })
  local handle = assert(player:start(14, sample(), options(0xFFFF)))
  mixer:render(1000)
  mixer:controlStep()
  Assert.isFalse(player:isPlaying(handle), "a non-looping WaveOut sample ends at its source boundary")
end

return { tests = T }
