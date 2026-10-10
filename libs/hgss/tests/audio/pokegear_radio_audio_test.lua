-- Radio audio routing: the radio show plays through the dedicated radio
-- player without mutating the borrowed generated records. Starting radio
-- builds a detached routing record (radio player, radio priority) that keeps
-- the original sequence bank, program, and initial volume, while the cached
-- sequence keeps its ordinary player binding and the ordinary playback path
-- for the same base sequence is unchanged. Playback runs on the real
-- sequence engine with an in-memory mixer; no audio device is used.

local Assert = require("tests.support.Assert")
local AudioFixture = require("tests.support.AudioFixture")
local AudioAssetProvider = require("libs.hgss.src.audio.AudioAssetProvider")
local SequencePlayer = require("libs.nds.src.nitro.sound.SequencePlayer")
local VoiceMixer = require("libs.nds.src.nitro.sound.VoiceMixer")
local GameSound = require("libs.hgss.src.audio.GameSound")

local T = {}

local SAMPLE_RATE = 48000

-- Source radio player configuration: logical player 9, priority 65, one
-- simultaneous radio sequence, channels masked to 0xA7FE.
local RADIO_PLAYER_ID = 9
local RADIO_PRIORITY = 65
local RADIO_MAX_SEQUENCES = 1
local RADIO_CHANNEL_MASK = 0xA7FE

local RADIO_SEQUENCE_ID = 41
local RADIO_SEQUENCE_SYMBOL = "SEQ_RADIO_MUSIC_TEST"
local RADIO_BANK_ID = 12

local function voice(key)
  return {
    generator = { kind = "sample", sample = key },
    originalKey = 60,
    envelope = { attack = 127, decay = 0, sustain = 127, release = 127 },
    pan = 0,
  }
end

local function bank()
  return AudioFixture.bank(12, "BANK_TEST", { AudioFixture.key(1), AudioFixture.key(2) }, {
    [0] = { kind = "direct", voice = voice(AudioFixture.key(1)) },
    [1] = { kind = "direct", voice = voice(AudioFixture.key(2)) },
  })
end

local function loopingProgram()
  return {
    entry = 1,
    initialTrackMask = 0x0001,
    instructions = {
      { op = "program", program = 4 },
      { op = "note", key = 60, velocity = 96, duration = 24 },
      { op = "wait", duration = 12 },
      { op = "jump", target = 2 },
    },
  }
end

-- The production HGSS runtime supplies the radio player record through its
-- local audio provider adapter; this synthetic archive carries the same
-- record shape so the routing contract is provable without an audio device.
local function engineBundle()
  local keyA = AudioFixture.key(1)
  local keyB = AudioFixture.key(2)
  local bundle = AudioFixture.bundle()
  local radioSequence =
    AudioFixture.sequence(RADIO_SEQUENCE_ID, RADIO_SEQUENCE_SYMBOL, RADIO_BANK_ID, 1, loopingProgram(), {
      id = 1,
      initialVolume = 127,
      playerPriority = 64,
      channelPriority = 64,
    })
  bundle.index.sequences[RADIO_SEQUENCE_ID] =
    { id = RADIO_SEQUENCE_ID, symbol = RADIO_SEQUENCE_SYMBOL, bankId = RADIO_BANK_ID, playerId = 1 }
  bundle.index.sequenceBySymbol[RADIO_SEQUENCE_SYMBOL] = RADIO_SEQUENCE_ID
  bundle.index.players[RADIO_PLAYER_ID] =
    { id = RADIO_PLAYER_ID, maxSequences = RADIO_MAX_SEQUENCES, channelMask = RADIO_CHANNEL_MASK }
  bundle.sequences[RADIO_SEQUENCE_ID] = radioSequence
  bundle.banks[RADIO_BANK_ID] = bank()
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

local function newComposition()
  local provider = AudioAssetProvider.new(AudioFixture.readyCache(engineBundle()))
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local player = SequencePlayer.new({
    sampleRate = SAMPLE_RATE,
    mixer = mixer,
    provider = provider,
  })
  local sound = GameSound.new({ provider = provider, player = player })
  return sound, player, provider
end

function T.radio_routes_through_dedicated_player_without_mutating_cached_assets()
  local sound, player, provider = newComposition()

  local cached = provider:sequence(RADIO_SEQUENCE_SYMBOL)
  local cachedPlayerId = cached.player.id
  local cachedPriority = cached.player.playerPriority
  local cachedVolume = cached.player.initialVolume
  local cachedBankId = cached.bankId

  local radioConfig = provider:player(RADIO_PLAYER_ID)
  Assert.equal(radioConfig.maxSequences, RADIO_MAX_SEQUENCES, "radio player carries one sequence slot")
  Assert.equal(radioConfig.channelMask, RADIO_CHANNEL_MASK, "radio player carries the radio channel mask")

  local started = {}
  local realPlay = player.play
  player.play = function(self, handle, sequence, bank)
    started[#started + 1] = sequence
    return realPlay(self, handle, sequence, bank)
  end

  sound:playRadio(RADIO_SEQUENCE_SYMBOL)
  Assert.equal(#started, 1, "starting radio starts one engine sequence")
  local routed = started[1]
  Assert.equal(routed.player.id, RADIO_PLAYER_ID, "radio starts on the dedicated radio player")
  Assert.equal(routed.player.playerPriority, RADIO_PRIORITY, "radio starts at radio priority")
  Assert.equal(routed.bankId, cachedBankId, "radio keeps the original sequence bank identity")
  Assert.equal(routed.player.initialVolume, cachedVolume, "radio keeps the original initial volume")
  Assert.deepEqual(routed.program, cached.program, "radio keeps the immutable program")

  local fresh = provider:sequence(RADIO_SEQUENCE_SYMBOL)
  Assert.equal(fresh.player.id, cachedPlayerId, "cached sequence keeps its ordinary player binding")
  Assert.equal(fresh.player.playerPriority, cachedPriority, "cached sequence keeps its ordinary priority")

  player:render(250)
  Assert.isTrue(player:isPlayerPlaying(RADIO_PLAYER_ID), "radio is audible on the radio player headlessly")
  Assert.isTrue(sound:radioIsPlaying(), "radio liveness reports the active radio handle")
  Assert.equal(sound:currentRadioSequence(), RADIO_SEQUENCE_ID, "radio latch reports the selected sequence")

  sound:playMusic(RADIO_SEQUENCE_SYMBOL)
  player:render(250)
  Assert.isTrue(
    player:isPlayerPlaying(cachedPlayerId),
    "the ordinary path for the same base sequence still uses its own player"
  )
  Assert.isTrue(player:isPlayerPlaying(RADIO_PLAYER_ID), "ordinary playback does not steal the radio handle")
  local afterOrdinary = provider:sequence(RADIO_SEQUENCE_SYMBOL)
  Assert.equal(afterOrdinary.player.id, cachedPlayerId, "ordinary playback leaves cached metadata unchanged")
end

function T.radio_retune_to_the_same_station_keeps_playing_without_restart()
  local sound, player = newComposition()

  local starts = 0
  local realPlay = player.play
  player.play = function(self, handle, sequence, bank)
    starts = starts + 1
    return realPlay(self, handle, sequence, bank)
  end

  sound:playRadio(RADIO_SEQUENCE_SYMBOL)
  player:render(250)
  Assert.isTrue(sound:radioIsPlaying(), "radio is playing before the retune")

  sound:playRadio(RADIO_SEQUENCE_SYMBOL)
  player:render(250)
  Assert.equal(starts, 1, "retuning the same station never restarts the engine sequence")
  Assert.isTrue(sound:radioIsPlaying(), "the same station keeps playing across the retune")
  Assert.equal(sound:currentRadioSequence(), RADIO_SEQUENCE_ID, "the same station keeps its latch")
end

local BROKEN_SEQUENCE_ID = 43
local BROKEN_SEQUENCE_SYMBOL = "SEQ_RADIO_BROKEN_TEST"
local MISSING_BANK_ID = 99

local function brokenBundle()
  local bundle = engineBundle()
  bundle.index.sequences[BROKEN_SEQUENCE_ID] =
    { id = BROKEN_SEQUENCE_ID, symbol = BROKEN_SEQUENCE_SYMBOL, bankId = MISSING_BANK_ID, playerId = 1 }
  bundle.index.sequenceBySymbol[BROKEN_SEQUENCE_SYMBOL] = BROKEN_SEQUENCE_ID
  bundle.sequences[BROKEN_SEQUENCE_ID] = AudioFixture.sequence(
    BROKEN_SEQUENCE_ID,
    BROKEN_SEQUENCE_SYMBOL,
    MISSING_BANK_ID,
    1,
    loopingProgram(),
    {
      id = 1,
      initialVolume = 127,
      playerPriority = 64,
      channelPriority = 64,
    }
  )
  return bundle
end

function T.radio_start_with_a_missing_bank_fails_without_changing_playback()
  local provider = AudioAssetProvider.new(AudioFixture.readyCache(brokenBundle()))
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local player = SequencePlayer.new({
    sampleRate = SAMPLE_RATE,
    mixer = mixer,
    provider = provider,
  })
  local sound = GameSound.new({ provider = provider, player = player })

  sound:playMusic(RADIO_SEQUENCE_SYMBOL)
  player:render(120)

  Assert.throws(
    function()
      sound:playRadio(BROKEN_SEQUENCE_SYMBOL)
    end,
    "a missing radio bank is an attributed failure"
  )
  Assert.isNil(sound:currentRadioSequence(), "a failed radio start latches nothing")
  Assert.isFalse(sound:radioIsPlaying(), "a failed radio start plays nothing")
  Assert.isFalse(player:isPlayerPlaying(RADIO_PLAYER_ID), "a failed radio start attaches no radio instance")
  Assert.equal(sound:currentMusic(), RADIO_SEQUENCE_ID, "a failed radio start keeps the committed music")
  Assert.isTrue(player:isPlayerPlaying(1), "a failed radio start keeps the committed music playing")

  sound:playRadio(RADIO_SEQUENCE_SYMBOL)
  player:render(250)
  Assert.isTrue(sound:radioIsPlaying(), "radio still starts cleanly after a failed acquisition")
  Assert.equal(sound:currentRadioSequence(), RADIO_SEQUENCE_ID, "the later start latches its own sequence")
end

function T.radio_handle_is_acquired_once_and_survives_stop_cycles()
  local sound, player = newComposition()

  local handles = 0
  local realCreateHandle = player.createHandle
  player.createHandle = function(self)
    handles = handles + 1
    return realCreateHandle(self)
  end

  sound:playRadio(RADIO_SEQUENCE_SYMBOL)
  player:render(120)
  sound:stopRadio()
  sound:playRadio(RADIO_SEQUENCE_SYMBOL)
  player:render(120)
  sound:stopRadio(4)
  sound:updateSoundFrame()
  sound:playRadio(RADIO_SEQUENCE_SYMBOL)
  player:render(120)
  Assert.equal(handles, 1, "every radio start reuses the one runtime handle")
  Assert.isTrue(sound:radioIsPlaying(), "the reused handle plays after stop cycles")
  Assert.equal(sound:currentRadioSequence(), RADIO_SEQUENCE_ID, "the reused handle latches again")

  sound:stopRadio()
  sound:stopRadio()
  Assert.isNil(sound:currentRadioSequence(), "repeated stops stay clear")
  Assert.isFalse(sound:radioIsPlaying(), "repeated stops stay silent")
end

function T.radio_stop_tail_completes_on_the_semantic_timeline_without_output()
  local sound, player = newComposition()

  sound:playRadio(RADIO_SEQUENCE_SYMBOL)
  Assert.isTrue(player:isPlayerPlaying(RADIO_PLAYER_ID), "radio attaches without any rendered output")

  sound:stopRadio(4)
  Assert.isNil(sound:currentRadioSequence(), "stop clears the latch before the tail")
  Assert.isTrue(player:isPlayerPlaying(RADIO_PLAYER_ID), "the faded instance is still attached mid-tail")

  for _ = 1, 4 do
    sound:updateSoundFrame()
  end
  Assert.isFalse(
    player:isPlayerPlaying(RADIO_PLAYER_ID),
    "the tail retires the instance on sound frames alone"
  )
  Assert.isFalse(sound:radioIsPlaying(), "radio is silent once the tail finishes")
end

return { tests = T }
