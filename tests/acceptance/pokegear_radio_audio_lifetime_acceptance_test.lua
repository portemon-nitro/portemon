-- Radio against explicit audio events: scripted stops, explicit music
-- changes, map entries, battle holds, and fanfares each take the behavior
-- their original audio branch dictates, and the nonradio behavior is
-- identical with radio absent. The journey runs the composed production
-- audio stack (runtime composition over the real sequence engine with an
-- in-memory mixer) through its field policy owner; only the host output
-- boundary is headless, muted output still advances the semantic timeline,
-- and every wait is bounded so the run always terminates. No audio device
-- is used and no ROM data is required.

local Assert = require("tests.support.Assert")
local AudioFixture = require("tests.support.AudioFixture")
local AudioRuntime = require("libs.hgss.src.audio.AudioRuntime")
local AudioAssetProvider = require("libs.hgss.src.audio.AudioAssetProvider")
local FieldAudioController = require("libs.hgss.src.audio.FieldAudioController")

local T = { tests = {} }

local SAMPLE_RATE = 48000

local MAP_A_MUSIC_ID = 4
local MAP_A_MUSIC_SYMBOL = "SEQ_FIELD_MAP_A_MUSIC"
local MAP_B_MUSIC_ID = 5
local MAP_B_MUSIC_SYMBOL = "SEQ_FIELD_MAP_B_MUSIC"
local FANFARE_ID = 6
local FANFARE_SYMBOL = "SEQ_FANFARE_TEST"
local RADIO_SEQUENCE_ID = 41
local RADIO_SEQUENCE_SYMBOL = "SEQ_RADIO_MUSIC_TEST"
local BANK_ID = 12

-- Upper bound for every completion poll below: fanfares and fades close in
-- tens of frames, so hundreds of frames can only mean a stuck wait.
local COMPLETION_BUDGET_FRAMES = 900

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

local function finiteProgram(program)
  return {
    entry = 1,
    initialTrackMask = 0x0001,
    instructions = {
      { op = "program", program = program },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    },
  }
end

-- Real-shaped archive with no radio player record: the composed runtime
-- supplies the radio player configuration itself, never the catalog.
local function engineBundle()
  local keyA = AudioFixture.key(1)
  local keyB = AudioFixture.key(2)
  local bundle = AudioFixture.bundle()
  local function musicSequence(id, symbol, playerId, program)
    return AudioFixture.sequence(id, symbol, BANK_ID, playerId, program, {
      id = playerId,
      initialVolume = 127,
      playerPriority = 64,
      channelPriority = 64,
    })
  end
  bundle.index.sequences = {
    [MAP_A_MUSIC_ID] = { id = MAP_A_MUSIC_ID, symbol = MAP_A_MUSIC_SYMBOL, bankId = BANK_ID, playerId = 1 },
    [MAP_B_MUSIC_ID] = { id = MAP_B_MUSIC_ID, symbol = MAP_B_MUSIC_SYMBOL, bankId = BANK_ID, playerId = 1 },
    [FANFARE_ID] = { id = FANFARE_ID, symbol = FANFARE_SYMBOL, bankId = BANK_ID, playerId = 3 },
    [RADIO_SEQUENCE_ID] = { id = RADIO_SEQUENCE_ID, symbol = RADIO_SEQUENCE_SYMBOL, bankId = BANK_ID, playerId = 1 },
  }
  bundle.index.sequenceBySymbol = {
    [MAP_A_MUSIC_SYMBOL] = MAP_A_MUSIC_ID,
    [MAP_B_MUSIC_SYMBOL] = MAP_B_MUSIC_ID,
    [FANFARE_SYMBOL] = FANFARE_ID,
    [RADIO_SEQUENCE_SYMBOL] = RADIO_SEQUENCE_ID,
  }
  -- The engine requires the fanfare player record for this direct archive;
  -- the fanfare sequence above is bound to player 3, whose record the base
  -- bundle does not carry. The radio player record stays omitted on
  -- purpose: only the production runtime adapter may supply it.
  bundle.index.players[3] = { id = 3, maxSequences = 16, channelMask = 0xFFFF }
  bundle.sequences = {
    [MAP_A_MUSIC_ID] = musicSequence(MAP_A_MUSIC_ID, MAP_A_MUSIC_SYMBOL, 1, loopingProgram(0)),
    [MAP_B_MUSIC_ID] = musicSequence(MAP_B_MUSIC_ID, MAP_B_MUSIC_SYMBOL, 1, loopingProgram(1)),
    [FANFARE_ID] = musicSequence(FANFARE_ID, FANFARE_SYMBOL, 3, finiteProgram(2)),
    [RADIO_SEQUENCE_ID] = musicSequence(RADIO_SEQUENCE_ID, RADIO_SEQUENCE_SYMBOL, 1, loopingProgram(4)),
  }
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
  local cacheFs = AudioFixture.readyCache(engineBundle())
  local runtime = AudioRuntime.compose({
    cacheFs = cacheFs,
    outputRate = SAMPLE_RATE,
  })
  local sound, player = runtime.sound, runtime.renderer
  local eventState = {
    isFlagSet = function()
      return false
    end,
  }
  local controller = FieldAudioController.new({
    sound = sound,
    provider = AudioAssetProvider.new(cacheFs),
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

local function runFanfareToCompletion(sound, player)
  local frames = 0
  while sound:isFanfarePlaying() do
    assert(frames < COMPLETION_BUDGET_FRAMES, "fanfare must complete within its frame budget")
    sound:updateSoundFrame()
    player:render(4)
    frames = frames + 4
  end
end

local function startRadio(sound, player)
  sound:playRadio(RADIO_SEQUENCE_SYMBOL)
  player:render(250)
  Assert.isTrue(sound:radioIsPlaying(), "radio music is playing before the audio event")
  Assert.equal(sound:currentRadioSequence(), RADIO_SEQUENCE_ID, "radio latch is set before the audio event")
end

function T.tests.explicit_audio_events_dominate_radio_while_battle_and_fanfare_preserve_it()
  local sound, player, controller = newComposition()

  controller:enterMap({ fieldData = fieldData(MAP_A_MUSIC_ID) }, { play = true })
  player:render(250)
  Assert.equal(sound:currentMusic(), MAP_A_MUSIC_ID, "map entry establishes the field music")

  startRadio(sound, player)

  -- Scripted StopBGM stops radio and clears its latch.
  sound:stopMusic()
  player:render(250)
  Assert.isNil(sound:currentRadioSequence(), "scripted stop clears the radio latch")
  Assert.isFalse(sound:radioIsPlaying(), "scripted stop leaves no radio playing")

  -- An explicit music change takes the BGM branch, which stops radio.
  startRadio(sound, player)
  sound:playMusic(MAP_B_MUSIC_SYMBOL)
  player:render(250)
  Assert.isNil(sound:currentRadioSequence(), "explicit music change clears the radio latch")
  Assert.isFalse(sound:radioIsPlaying(), "explicit music change leaves no radio playing")
  Assert.equal(sound:currentMusic(), MAP_B_MUSIC_ID, "explicit music change installs the new music")

  -- A map entry with different music follows the same explicit branch.
  startRadio(sound, player)
  controller:enterMap({ fieldData = fieldData(MAP_B_MUSIC_ID) }, { play = true })
  player:render(250)
  Assert.isNil(sound:currentRadioSequence(), "map entry with new music clears the radio latch")
  Assert.isFalse(sound:radioIsPlaying(), "map entry with new music leaves no radio playing")
  Assert.equal(sound:currentMusic(), MAP_B_MUSIC_ID, "map entry installs the destination music")

  -- A battle policy hold never steals radio and never keeps its token.
  startRadio(sound, player)
  local battleToken = {}
  controller:suspendFieldPolicy(battleToken)
  player:render(250)
  Assert.isTrue(sound:radioIsPlaying(), "battle suspension keeps radio playing")
  controller:resumeFieldPolicy(battleToken, true)
  player:render(250)
  Assert.isTrue(sound:radioIsPlaying(), "battle recovery keeps radio playing")
  Assert.equal(sound:currentRadioSequence(), RADIO_SEQUENCE_ID, "battle recovery keeps the radio latch")
  local laterToken = {}
  controller:suspendFieldPolicy(laterToken)
  controller:resumeFieldPolicy(laterToken, false)
  player:render(120)
  Assert.isTrue(sound:radioIsPlaying(), "the battle token is released instead of held for radio")

  -- A fanfare completes around radio without stopping it and without leaks.
  sound:playFanfare(FANFARE_SYMBOL)
  runFanfareToCompletion(sound, player)
  Assert.equal(sound:currentRadioSequence(), RADIO_SEQUENCE_ID, "fanfare completion keeps the radio latch")
  Assert.isTrue(sound:radioIsPlaying(), "fanfare completion leaves radio playing")
  Assert.isFalse(sound:isFanfarePlaying(), "the fanfare wait terminates headlessly")

  -- With radio absent the same events behave exactly as before.
  local plainSound, plainPlayer, plainController = newComposition()
  plainController:enterMap({ fieldData = fieldData(MAP_A_MUSIC_ID) }, { play = true })
  plainPlayer:render(250)
  plainSound:stopMusic()
  plainPlayer:render(120)
  Assert.isNil(plainSound:currentMusic(), "scripted stop still clears music with radio absent")
  plainSound:playMusic(MAP_B_MUSIC_SYMBOL)
  plainPlayer:render(250)
  Assert.equal(plainSound:currentMusic(), MAP_B_MUSIC_ID, "explicit music still installs with radio absent")
  plainSound:playFanfare(FANFARE_SYMBOL)
  runFanfareToCompletion(plainSound, plainPlayer)
  Assert.isFalse(plainSound:isFanfarePlaying(), "fanfare still terminates with radio absent")
  Assert.equal(plainSound:currentMusic(), MAP_B_MUSIC_ID, "fanfare still preserves music with radio absent")
  Assert.isNil(plainSound:currentRadioSequence(), "no radio latch ever appears with radio absent")
end

return T
