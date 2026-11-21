-- WaveOut fixed-channel lifecycle over the shared NNS VoiceMixer.

local Assert = require("tests.support.Assert")
local AudioFixture = require("tests.support.AudioFixture")
local VoiceMixer = require("libs.nds.src.nitro.sound.VoiceMixer")
local WaveOutPlayer = require("libs.nds.src.nitro.sound.WaveOutPlayer")

local T = {}

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

-- The engine takes an opaque sample lease, not a second sample owner: a
-- successful start transfers it to the voice, a rejected start leaves it with
-- the caller, the returned handle keeps only channel/generation identity, and
-- physical death returns the lease exactly once. Reverse playback still reads
-- the original backing.
local function sampleLease(values)
  local source = { metadata = { loop = { startFrame = 0, endFrame = #values } }, pcm = AudioFixture.packed(values) }
  local lease = { value = source, returns = 0 }
  function lease:release()
    if self.value == nil then
      return false
    end
    self.value = nil
    self.returns = self.returns + 1
    return true
  end
  return lease, source
end

local function startChannel(player, channel, lease, opts)
  local ok, handleOrError = pcall(player.start, player, channel, lease, opts)
  Assert.isTrue(
    ok,
    "a WaveOut start must accept an accountable sample lease instead of an unleased sample: " .. tostring(handleOrError)
  )
  return handleOrError
end

function T.reverses_private_samples_and_preserves_the_provider_sample()
  local mixer = VoiceMixer.new({ sampleRate = 48000 })
  local player = WaveOutPlayer.new({ mixer = mixer })
  local lease, source = sampleLease({ 101, 202, 303, 404 })
  local handle = assert(player:start(14, lease, options()))

  Assert.isNil(handle.sample, "a handle keeps only channel/generation identity")
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
  local first = startChannel(player, 14, sampleLease({ 101, 202, 303, 404 }), options())
  local other = startChannel(player, 15, sampleLease({ 101, 202, 303, 404 }), options(0x6800))
  local replacement = startChannel(player, 14, sampleLease({ 101, 202, 303, 404 }), options())

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
  local handle = startChannel(player, 14, sampleLease({ 101, 202, 303, 404 }), options(0xFFFF))
  mixer:render(1000)
  mixer:controlStep()
  Assert.isFalse(player:isPlaying(handle), "a non-looping WaveOut sample ends at its source boundary")
end

function T.each_sounding_channel_owns_exactly_one_sample_lease()
  local mixer = VoiceMixer.new({ sampleRate = 48000 })
  local player = WaveOutPlayer.new({ mixer = mixer })
  local first, firstSource = sampleLease({ 101, 202, 303, 404 })
  local second, secondSource = sampleLease({ 101, 202, 303, 404 })

  local forward = startChannel(player, 14, first, options(0x8600))
  local reversed = startChannel(player, 15, second, options())
  Assert.equal(first.returns, 0, "a successful start transfers the acquisition to the voice")
  Assert.equal(second.returns, 0, "a successful start transfers the acquisition to the voice")
  Assert.isNil(forward.sample, "a handle never keeps its own sample reference")
  Assert.deepEqual(storedValues(firstSource.pcm), { 101, 202, 303, 404 }, "the source backing is never rewritten")
  Assert.equal(forward.generation, reversed.generation, "both channels start at the same generation counter")

  player:stop(reversed)
  Assert.equal(second.returns, 1, "stopping a channel returns exactly one acquisition")
  Assert.equal(first.returns, 0, "the other channel keeps its own acquisition")
  Assert.isFalse(mixer:isSampleActive(secondSource.pcm), "a stopped channel stops sounding")
  Assert.isTrue(mixer:isSampleActive(firstSource.pcm), "the remaining channel still sounds")

  player:stop(forward)
  Assert.equal(first.returns, 1, "the last stop returns the remaining acquisition")
  Assert.isFalse(mixer:isSampleActive(firstSource.pcm), "no voice sounds after the final stop")

  -- A rejected start has no voice to own the acquisition: the caller keeps it.
  local rejected, rejectedSource = sampleLease({ 101, 202, 303, 404 })
  local ok = pcall(function()
    startChannel(player, 13, rejected, options())
  end)
  Assert.isFalse(ok, "an unsupported fixed channel is rejected")
  Assert.notNil(rejected.value, "a rejected start leaves the acquisition with its caller")
  rejected:release()
  Assert.equal(rejected.returns, 1, "the caller releases the rejected acquisition")
  Assert.isFalse(mixer:isSampleActive(rejectedSource.pcm), "the rejected acquisition sounds nowhere")
end

function T.live_shutdown_returns_every_sounding_acquisition_once()
  local mixer = VoiceMixer.new({ sampleRate = 48000 })
  local player = WaveOutPlayer.new({ mixer = mixer })
  local first, firstSource = sampleLease({ 101, 202, 303, 404 })
  local second = sampleLease({ 101, 202, 303, 404 })
  local forward = startChannel(player, 14, first, options(0x8600))
  local reversed = startChannel(player, 15, second, options())
  Assert.equal(type(mixer.dispose), "function", "the mixer must dispose its sounding resources on shutdown")

  mixer:dispose()
  Assert.equal(first.returns, 1, "shutdown returns each sounding acquisition exactly once")
  Assert.equal(second.returns, 1, "shutdown returns each sounding acquisition exactly once")
  Assert.isFalse(mixer:isSampleActive(firstSource.pcm), "shutdown leaves no sounding sample behind")
  Assert.isFalse(player:isPlaying(forward) and player:isPlaying(reversed), "shutdown ends the channel handles")
  mixer:dispose()
  Assert.equal(first.returns, 1, "a repeated shutdown never returns an acquisition twice")
end

return { tests = T }
