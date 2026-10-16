-- Playback timelines through packed samples: music, fanfare, radio, and a
-- scripted fade render bit-identical interleaved output at both output
-- rates, and a live voice keeps its borrowed sample after the provider
-- reference is released. The archive is synthetic and instant-attack so
-- the pins capture storage and mixing fidelity, never envelope ballistics;
-- nothing here touches a ROM.

local Assert = require("tests.support.Assert")
local AudioFixture = require("tests.support.AudioFixture")
local AudioAssetProvider = require("libs.hgss.src.audio.AudioAssetProvider")
local VoiceMixer = require("libs.nds.src.nitro.sound.VoiceMixer")
local AudioRuntime = require("libs.hgss.src.audio.AudioRuntime")

local T = {}

local TRACKS = {
  bgm = { id = 4, symbol = "SEQ_BGM_TEST", playerId = 1, program = 0, finite = false },
  fanfare = { id = 6, symbol = "SEQ_FANFARE_TEST", playerId = 3, program = 0, finite = true },
  radio = { id = 41, symbol = "SEQ_RADIO_TEST", playerId = 1, program = 1, finite = false },
}

-- A small synthetic archive over the frozen fixture bank: a looping music
-- sequence on the direct sample voice, a finite fanfare on the same
-- voice, and a looping radio sequence on the key-split voice so both
-- fixture samples sound. Every voice opens at the full register on the
-- first control interval.
local function timelineBundle()
  local bundle = AudioFixture.bundle()
  local keyA, keyB = AudioFixture.key(1), AudioFixture.key(2)
  local function streamVoice(key)
    return {
      generator = { kind = "sample", sample = key },
      originalKey = 60,
      envelope = { attack = 127, decay = 127, sustain = 127, release = 127 },
      pan = 64,
    }
  end
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
  for _, entry in pairs(TRACKS) do
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

local function composeAt(rate)
  local composed = AudioRuntime.compose({ cacheFs = AudioFixture.readyCache(timelineBundle()), outputRate = rate })
  Assert.notNil(composed.sound, "the composition owns the semantic facade at " .. rate .. " Hz")
  Assert.notNil(composed.renderer, "the composition owns the rendering engine at " .. rate .. " Hz")
  return composed.sound, composed.renderer
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
  return out, frames
end

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

local function maxAbs(frames)
  local peak = 0
  for index = 1, #frames do
    local value = math.abs(frames[index])
    if value > peak then
      peak = value
    end
  end
  return peak
end

-- The seeded fixed-tick tracks render their exact timelines at both
-- output rates: looping music, a finite fanfare over music and over
-- radio, and the key-split radio voice, each with its completion frame
-- count and a determinism double-run.
function T.music_fanfare_and_radio_match_their_timelines_at_both_rates()
  local pins = {
    [48000] = {
      music = 3603820576,
      fanfareOverMusic = 3691276832,
      fanfareOverMusicFrames = 812,
      radio = 4059610112,
      fanfareOverRadio = 2755067968,
      fanfareOverRadioFrames = 812,
    },
    [32768] = {
      music = 3969365824,
      fanfareOverMusic = 780525248,
      fanfareOverMusicFrames = 440,
      radio = 1822734208,
      fanfareOverRadio = 3134199648,
      fanfareOverRadioFrames = 440,
    },
  }
  for _, rate in ipairs({ 48000, 32768 }) do
    local pin = pins[rate]
    local tag = "at " .. rate .. " Hz"
    local sound, player = composeAt(rate)
    sound:playMusic(TRACKS.bgm.symbol)
    local bgm = renderSpan(sound, player, 1500)
    Assert.equal(#bgm, 3000, "the music span holds one stereo pair per frame " .. tag)
    assertAudible(bgm, "the music stream " .. tag)
    Assert.equal(fingerprint16(bgm), pin.music, "the music timeline " .. tag)
    local repeatSound, repeatPlayer = composeAt(rate)
    repeatSound:playMusic(TRACKS.bgm.symbol)
    Assert.equal(
      fingerprint16(renderSpan(repeatSound, repeatPlayer, 1500)),
      fingerprint16(bgm),
      "the music timeline is deterministic " .. tag
    )
    sound:playFanfare(TRACKS.fanfare.symbol)
    local overMusic, overMusicFrames = renderFanfareToCompletion(sound, player)
    assertAudible(overMusic, "the fanfare-over-music stream " .. tag)
    Assert.equal(overMusicFrames, pin.fanfareOverMusicFrames, "the fanfare completes on its tick boundary " .. tag)
    Assert.equal(fingerprint16(overMusic), pin.fanfareOverMusic, "the fanfare-over-music timeline " .. tag)

    local radioSound, radioPlayer = composeAt(rate)
    radioSound:playRadio(TRACKS.radio.symbol)
    local radio = renderSpan(radioSound, radioPlayer, 1500)
    assertAudible(radio, "the radio stream " .. tag)
    Assert.isTrue(radioSound:radioIsPlaying(), "the radio latch holds while its stream renders " .. tag)
    Assert.equal(fingerprint16(radio), pin.radio, "the radio timeline " .. tag)
    radioSound:playFanfare(TRACKS.fanfare.symbol)
    local overRadio, overRadioFrames = renderFanfareToCompletion(radioSound, radioPlayer)
    assertAudible(overRadio, "the fanfare-over-radio stream " .. tag)
    Assert.equal(
      overRadioFrames,
      pin.fanfareOverRadioFrames,
      "the radio fanfare completes on its tick boundary " .. tag
    )
    Assert.isTrue(radioSound:radioIsPlaying(), "the fanfare completes around radio without stopping it " .. tag)
    Assert.equal(fingerprint16(overRadio), pin.fanfareOverRadio, "the fanfare-over-radio timeline " .. tag)
  end
end

-- A scripted fade-out runs its exact tick count at both rates: the music
-- stays the current reference, the fade reports active through its ticks,
-- and the faded stream ends in silence.
function T.a_fade_out_runs_its_ticks_and_leaves_the_music_silent()
  local pins = {
    [48000] = { pre = 374144224, faded = 4290469280 },
    [32768] = { pre = 3932691936, faded = 3920752128 },
  }
  for _, rate in ipairs({ 48000, 32768 }) do
    local pin = pins[rate]
    local tag = "at " .. rate .. " Hz"
    local sound, player = composeAt(rate)
    sound:playMusic(TRACKS.bgm.symbol)
    local pre = renderSpan(sound, player, 500)
    assertAudible(pre, "the pre-fade music " .. tag)
    Assert.equal(fingerprint16(pre), pin.pre, "the pre-fade timeline " .. tag)
    sound:fadeMusicOut({ target = 0, durationTicks = 30 })
    Assert.isTrue(sound:isMusicFadeActive(), "the fade reports active through its ticks " .. tag)
    local faded = renderSpan(sound, player, 120)
    Assert.equal(#faded, 240, "the fade span holds one stereo pair per frame " .. tag)
    Assert.equal(fingerprint16(faded), pin.faded, "the fade ramp timeline " .. tag)
    Assert.isFalse(sound:isMusicFadeActive(), "the fade completes at exactly its tick count " .. tag)
    Assert.equal(sound:currentMusic(), TRACKS.bgm.id, "the faded music keeps its reference " .. tag)
    local drain = renderSpan(sound, player, 250)
    Assert.isTrue(maxAbs(drain) > 0, "the faded voice rings its release tail out " .. tag)
    Assert.equal(maxAbs(renderSpan(sound, player, 500)), 0, "the faded music ends in silence " .. tag)
  end
end

-- The composed voices borrow their samples: after every provider-side
-- reference is released and collected, the sounding voice still renders
-- its exact trace, and the mixer tracks the borrowing until the voice
-- is stopped.
function T.sounding_voices_keep_their_borrowed_sample_after_provider_release()
  local provider = AudioAssetProvider.new(AudioFixture.readyCache(timelineBundle()))
  local sample = provider:loadSample(AudioFixture.key(1))
  local borrowed = sample.pcm
  local function startBorrowedVoice(mixer)
    local handle = mixer:noteOn({
      generator = { kind = "sample", sample = AudioFixture.key(1) },
      pcm = borrowed,
      baseTimer = 8006,
      loopEnabled = true,
      loop = { startFrame = 0, endFrame = 4 },
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
    return handle
  end
  local voice = VoiceMixer.new({ sampleRate = 48000 })
  local handle = startBorrowedVoice(voice)
  local firstHalf = voice:render(250)
  -- Only the voice still reaches the borrowed sample: the provider and
  -- its memo wrapper are released before the collection below.
  provider = nil
  sample = nil
  collectgarbage("collect")
  Assert.isTrue(voice:isVoiceAlive(handle), "the sounding voice outlives the released provider")
  local secondHalf = voice:render(250)
  local twin = VoiceMixer.new({ sampleRate = 48000 })
  startBorrowedVoice(twin)
  Assert.deepEqual(firstHalf, twin:render(250), "the pre-collection span renders its exact trace")
  Assert.deepEqual(secondHalf, twin:render(250), "collection changes nothing in the rendered trace")
  Assert.equal(
    type(voice.isSampleActive),
    "function",
    "the mixer answers whether a borrowed sample still sounds on any of its 16 channels"
  )
  Assert.isTrue(voice:isSampleActive(borrowed), "the borrowed sample stays live while its voice sounds")
  voice:stopVoice(handle)
  Assert.isFalse(voice:isSampleActive(borrowed), "a stopped voice releases its borrowed sample")
end

return { tests = T }
