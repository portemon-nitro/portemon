-- Radio field lifetime: closing the radio interface while ordinary radio
-- music plays leaves the music alive. The surviving handle and latch ride
-- through the UI teardown, a same-map field policy step never restarts the
-- map music behind it, and opening another interface still finds the music
-- playing. Playback runs on the real sequence engine with an in-memory
-- mixer; no audio device is used.

local Assert = require("tests.support.Assert")
local AudioFixture = require("tests.support.AudioFixture")
local AudioAssetProvider = require("libs.hgss.src.audio.AudioAssetProvider")
local SequencePlayer = require("libs.nds.src.nitro.sound.SequencePlayer")
local VoiceMixer = require("libs.nds.src.nitro.sound.VoiceMixer")
local GameSound = require("libs.hgss.src.audio.GameSound")
local FieldAudioController = require("libs.hgss.src.audio.FieldAudioController")

local T = { tests = {} }

local SAMPLE_RATE = 48000

local MAP_MUSIC_ID = 4
local MAP_MUSIC_SYMBOL = "SEQ_FIELD_MAP_MUSIC"
local RADIO_SEQUENCE_ID = 41
local RADIO_SEQUENCE_SYMBOL = "SEQ_RADIO_MUSIC_TEST"
local BANK_ID = 12

local function voice(key)
  return {
    generator = { kind = "sample", sample = key },
    originalKey = 60,
    envelope = { attack = 127, decay = 0, sustain = 127, release = 127 },
    pan = 0,
  }
end

local function bank()
  return AudioFixture.bank(BANK_ID, "BANK_TEST", { AudioFixture.key(1), AudioFixture.key(2) }, {
    [0] = { kind = "direct", voice = voice(AudioFixture.key(1)) },
    [1] = { kind = "direct", voice = voice(AudioFixture.key(2)) },
  })
end

local function loopingProgram(program)
  return {
    entry = 1,
    initialTrackMask = 0x0001,
    instructions = {
      { op = "program", program = program },
      { op = "note", key = 60, velocity = 96, duration = 24 },
      { op = "wait", duration = 12 },
      { op = "jump", target = 2 },
    },
  }
end

local function engineBundle()
  local keyA = AudioFixture.key(1)
  local keyB = AudioFixture.key(2)
  local bundle = AudioFixture.bundle()
  local sequences = {
    [MAP_MUSIC_ID] = AudioFixture.sequence(MAP_MUSIC_ID, MAP_MUSIC_SYMBOL, BANK_ID, 1, loopingProgram(0), {
      id = 1,
      initialVolume = 127,
      playerPriority = 64,
      channelPriority = 64,
    }),
    [RADIO_SEQUENCE_ID] = AudioFixture.sequence(
      RADIO_SEQUENCE_ID,
      RADIO_SEQUENCE_SYMBOL,
      BANK_ID,
      1,
      loopingProgram(4),
      {
        id = 1,
        initialVolume = 127,
        playerPriority = 64,
        channelPriority = 64,
      }
    ),
  }
  bundle.index.sequences = {
    [MAP_MUSIC_ID] = { id = MAP_MUSIC_ID, symbol = MAP_MUSIC_SYMBOL, bankId = BANK_ID, playerId = 1 },
    [RADIO_SEQUENCE_ID] = { id = RADIO_SEQUENCE_ID, symbol = RADIO_SEQUENCE_SYMBOL, bankId = BANK_ID, playerId = 1 },
  }
  bundle.index.sequenceBySymbol = {
    [MAP_MUSIC_SYMBOL] = MAP_MUSIC_ID,
    [RADIO_SEQUENCE_SYMBOL] = RADIO_SEQUENCE_ID,
  }
  -- The engine requires its radio player record for this direct composition
  -- (the same configuration the production runtime adapter serves when the
  -- catalog omits it); without it no radio sequence can attach to the
  -- dedicated radio player.
  bundle.index.players[9] = { id = 9, maxSequences = 1, channelMask = 0xA7FE }
  bundle.sequences = sequences
  bundle.banks = { [BANK_ID] = bank() }
  bundle.samples = {
    [keyA] = AudioFixture.pcm16le({ 1000, 2000, 3000, 4000 }),
    [keyB] = AudioFixture.pcm16le({ 5000, 6000 }),
  }
  bundle.sampleMetadata = {
    [keyA] = AudioFixture.sampleMetadata(keyA, { frames = 4 }),
    [keyB] = AudioFixture.sampleMetadata(keyB, { frames = 2 }),
  }
  return bundle
end

local function fieldData(musicId)
  return { music = { day = musicId, night = musicId }, soundplates = {} }
end

local function newComposition()
  local provider = AudioAssetProvider.new(AudioFixture.readyCache(engineBundle()))
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local player = SequencePlayer.new({
    sampleRate = SAMPLE_RATE,
    mixer = mixer,
    provider = provider,
  })
  local sound = GameSound.new({ provider = provider, player = player })
  local eventState = {
    isFlagSet = function()
      return false
    end,
  }
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState,
    fieldPosition = function()
      return 0, 0
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return nil
    end,
  })
  return sound, player, controller
end

function T.tests.closing_radio_during_ordinary_music_leaves_playback_alive_on_the_same_map()
  local sound, player, controller = newComposition()

  controller:enterMap({ fieldData = fieldData(MAP_MUSIC_ID) }, { play = true })
  player:render(250)
  Assert.equal(sound:currentMusic(), MAP_MUSIC_ID, "map entry establishes the field music")

  sound:playRadio(RADIO_SEQUENCE_SYMBOL)
  player:render(250)
  Assert.isTrue(sound:radioIsPlaying(), "radio music is playing before the interface closes")
  Assert.equal(sound:currentRadioSequence(), RADIO_SEQUENCE_ID, "radio latch is set before the interface closes")

  controller:finishRadioUi({ tuned = true, kind = "music", mapMusic = MAP_MUSIC_ID })
  player:render(250)
  Assert.isTrue(sound:radioIsPlaying(), "closing during ordinary music keeps the radio handle alive")
  Assert.equal(sound:currentRadioSequence(), RADIO_SEQUENCE_ID, "closing during ordinary music keeps the radio latch")

  local restarts = 0
  local realPlayMusic = sound.playMusic
  sound.playMusic = function(self, idOrSymbol)
    restarts = restarts + 1
    return realPlayMusic(self, idOrSymbol)
  end

  controller:enterMap({ fieldData = fieldData(MAP_MUSIC_ID) }, { play = true })
  controller:updateField()
  player:render(250)
  Assert.isTrue(sound:radioIsPlaying(), "a same-map field step does not stop surviving radio")
  Assert.equal(sound:currentRadioSequence(), RADIO_SEQUENCE_ID, "a same-map field step keeps the radio latch")
  Assert.equal(restarts, 0, "a same-map field step never restarts map music behind surviving radio")

  controller:updateField()
  player:render(250)
  Assert.isTrue(sound:radioIsPlaying(), "opening another interface still finds the radio music playing")
  Assert.equal(sound:currentRadioSequence(), RADIO_SEQUENCE_ID, "the latch survives across interface visits")
end

function T.tests.remembered_tuning_never_restarts_stopped_radio_on_field_updates()
  local sound, player, controller = newComposition()

  controller:enterMap({ fieldData = fieldData(MAP_MUSIC_ID) }, { play = true })
  player:render(250)
  controller:updateField()
  controller:enterMap({ fieldData = fieldData(MAP_MUSIC_ID) }, { play = true })
  controller:updateField()
  player:render(250)
  Assert.isNil(sound:currentRadioSequence(), "field updates never latch radio on their own")
  Assert.isFalse(sound:radioIsPlaying(), "field updates never start radio on their own")
  Assert.equal(sound:currentMusic(), MAP_MUSIC_ID, "field music still establishes without radio")
end

return T
