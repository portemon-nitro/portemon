-- Radio teardown and transport: silent exits restore the field music
-- through one ordered fade/wait/restore pass, while pause keeps the latch
-- frozen and stop clears the latch at once even while a fade tail finishes.
-- Playback runs on the real sequence engine with an in-memory mixer; muted
-- output still advances the semantic timeline and every wait is bounded, so
-- no audio device is used and headless runs always terminate.

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

-- Upper bound for every completion poll below: the silent-exit path is a
-- short fade plus a wait, so hundreds of frames can only mean a stuck wait.
local COMPLETION_BUDGET_FRAMES = 600

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

local function newComposition()
  local provider = AudioAssetProvider.new(AudioFixture.readyCache(engineBundle()))
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local player = SequencePlayer.new({
    sampleRate = SAMPLE_RATE,
    mixer = mixer,
    provider = provider,
  })
  local sound = GameSound.new({
    provider = provider,
    player = player,
    mapMusic = function()
      return MAP_MUSIC_ID
    end,
  })
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

-- Runs the silent-exit transition to completion: the polled completion
-- closes within the frame budget while muted output still advances.
local function runToCompletion(sound, player, controller)
  local frames = 0
  while not controller:isRadioUiTransitionComplete() do
    assert(frames < COMPLETION_BUDGET_FRAMES, "silent radio exit must complete within its frame budget")
    sound:updateSoundFrame()
    player:render(4)
    frames = frames + 4
  end
end

local function startRadio(sound, player)
  sound:playRadio(RADIO_SEQUENCE_SYMBOL)
  player:render(250)
  Assert.isTrue(sound:radioIsPlaying(), "radio music is playing before the interface closes")
end

function T.tests.silent_exits_restore_field_music_once_through_fade_wait_and_restore()
  local silentExits = {
    { tuned = false, kind = nil, label = "untuned" },
    { tuned = true, kind = "jingle", label = "jingle" },
    { tuned = true, kind = "commercial", label = "commercial" },
  }
  for _, exit in ipairs(silentExits) do
    local sound, player, controller = newComposition()
    startRadio(sound, player)

    local calls = {}
    local realPlayMusic = sound.playMusic
    sound.playMusic = function(self, idOrSymbol)
      calls[#calls + 1] = idOrSymbol
      return realPlayMusic(self, idOrSymbol)
    end
    local silenced = 0
    local realFadeOut = sound.fadeMusicOut
    sound.fadeMusicOut = function(self, spec)
      silenced = silenced + 1
      return realFadeOut(self, spec)
    end
    local realMoveVolume = sound.moveSequenceVolume
    sound.moveSequenceVolume = function(self, ref, target, duration)
      if target == 0 then
        silenced = silenced + 1
      end
      return realMoveVolume(self, ref, target, duration)
    end

    controller:finishRadioUi({ tuned = exit.tuned, kind = exit.kind, mapMusic = MAP_MUSIC_ID })
    runToCompletion(sound, player, controller)

    player:render(250)
    Assert.isNil(sound:currentRadioSequence(), exit.label .. " exit clears the radio latch")
    Assert.isFalse(sound:radioIsPlaying(), exit.label .. " exit leaves no radio playing")
    Assert.isTrue(silenced >= 1, exit.label .. " exit silences through the fade path first")
    Assert.deepEqual(calls, { MAP_MUSIC_ID }, exit.label .. " exit restores the field music exactly once")
    Assert.equal(sound:currentMusic(), MAP_MUSIC_ID, exit.label .. " exit leaves the field music current")
  end

  local sound, player, controller = newComposition()
  startRadio(sound, player)
  local restores = 0
  local realPlayMusic = sound.playMusic
  sound.playMusic = function(self, idOrSymbol)
    restores = restores + 1
    return realPlayMusic(self, idOrSymbol)
  end
  controller:finishRadioUi({ tuned = true, kind = "music", mapMusic = MAP_MUSIC_ID })
  player:render(250)
  Assert.isTrue(sound:radioIsPlaying(), "ordinary music exit keeps radio playing instead of restoring")
  Assert.equal(sound:currentRadioSequence(), RADIO_SEQUENCE_ID, "ordinary music exit keeps the radio latch")
  Assert.equal(restores, 0, "ordinary music exit never runs the field-music restore")
end

function T.tests.pause_keeps_the_latch_while_stop_clears_it_before_the_tail_ends()
  local sound, player = newComposition()

  sound:playRadio(RADIO_SEQUENCE_SYMBOL)
  player:render(250)
  Assert.isTrue(sound:radioIsPlaying(), "radio music is playing before transport changes")

  sound:pauseRadio()
  Assert.equal(sound:currentRadioSequence(), RADIO_SEQUENCE_ID, "pause retains the radio latch")
  Assert.isFalse(sound:radioIsPlaying(), "pause freezes radio playback")
  player:render(500)
  Assert.equal(sound:currentRadioSequence(), RADIO_SEQUENCE_ID, "frozen radio keeps its latch across frames")
  Assert.isFalse(sound:radioIsPlaying(), "frozen radio stays silent across frames")

  sound:resumeRadio()
  player:render(250)
  Assert.equal(sound:currentRadioSequence(), RADIO_SEQUENCE_ID, "resume keeps the same radio identity")
  Assert.isTrue(sound:radioIsPlaying(), "resume restarts radio playback without reselecting")

  sound:stopRadio(4)
  Assert.isNil(sound:currentRadioSequence(), "stop clears the radio latch immediately")
  player:render(120)
  sound:updateSoundFrame()
  player:render(480)
  Assert.isNil(sound:currentRadioSequence(), "the latch stays clear while the stop tail finishes")
  Assert.isFalse(sound:radioIsPlaying(), "radio falls silent once the stop tail finishes")

  sound:playRadio(RADIO_SEQUENCE_SYMBOL)
  player:render(250)
  Assert.isTrue(sound:radioIsPlaying(), "radio restarts cleanly after a stopped tail releases its handle")
  Assert.equal(sound:currentRadioSequence(), RADIO_SEQUENCE_ID, "a fresh start latches the sequence again")
end

-- The traced audio-branch transition table: each entry runs against live
-- radio and records whether the latch and playback keep, pause, resume, or
-- stop. Map entries, battle holds, and fanfares keep their own authored
-- scenarios; this table pins every remaining script-audio branch in one
-- place so a future branch cannot silently change sides.
function T.tests.explicit_audio_branches_follow_the_traced_transition_table()
  local transitions = {
    {
      name = "same-sequence music",
      run = function(sound)
        sound:playMusic(RADIO_SEQUENCE_SYMBOL)
      end,
      latch = RADIO_SEQUENCE_ID,
      playing = true,
    },
    {
      name = "changed music",
      run = function(sound)
        sound:playMusic(MAP_MUSIC_SYMBOL)
      end,
      latch = nil,
      playing = false,
    },
    {
      name = "scripted stop",
      run = function(sound)
        sound:stopMusic()
      end,
      latch = nil,
      playing = false,
    },
    {
      name = "scripted special music",
      run = function(sound)
        sound:temporaryMusic(MAP_MUSIC_SYMBOL)
      end,
      latch = nil,
      playing = false,
    },
    {
      name = "pause",
      run = function(sound)
        sound:pauseRadio()
      end,
      latch = RADIO_SEQUENCE_ID,
      playing = false,
    },
    {
      name = "pause then resume",
      run = function(sound)
        sound:pauseRadio()
        sound:resumeRadio()
      end,
      latch = RADIO_SEQUENCE_ID,
      playing = true,
    },
    {
      name = "effect playback",
      run = function(sound)
        sound:play(MAP_MUSIC_SYMBOL)
      end,
      latch = RADIO_SEQUENCE_ID,
      playing = true,
    },
    {
      name = "volume moves",
      run = function(sound)
        sound:moveSequenceVolume(MAP_MUSIC_SYMBOL, 64, 4)
      end,
      latch = RADIO_SEQUENCE_ID,
      playing = true,
    },
  }
  for _, transition in ipairs(transitions) do
    local sound, player = newComposition()
    startRadio(sound, player)
    transition.run(sound)
    player:render(250)
    if transition.latch == nil then
      Assert.isNil(sound:currentRadioSequence(), transition.name .. " clears the latch")
    else
      Assert.equal(sound:currentRadioSequence(), transition.latch, transition.name .. " keeps the latch")
    end
    if transition.playing then
      Assert.isTrue(sound:radioIsPlaying(), transition.name .. " keeps playback")
    else
      Assert.isFalse(sound:radioIsPlaying(), transition.name .. " leaves silence")
    end
  end
end

function T.tests.silent_interface_close_orders_fade_stop_and_single_restore()
  local sound, player, controller = newComposition()
  startRadio(sound, player)

  local order = {}
  local realFadeOut = sound.fadeMusicOut
  sound.fadeMusicOut = function(self, spec)
    order[#order + 1] = "fade"
    return realFadeOut(self, spec)
  end
  local realStopRadio = sound.stopRadio
  sound.stopRadio = function(self, fadeFrames)
    order[#order + 1] = "stop"
    return realStopRadio(self, fadeFrames)
  end
  local restores = {}
  local realPlayMusic = sound.playMusic
  sound.playMusic = function(self, idOrSymbol)
    order[#order + 1] = "restore"
    restores[#restores + 1] = idOrSymbol
    return realPlayMusic(self, idOrSymbol)
  end

  controller:finishRadioUi({ tuned = false, kind = nil, mapMusic = MAP_MUSIC_ID })
  Assert.deepEqual(order, { "fade", "stop", "restore" }, "the silent exit orders fade, stop, then restore")
  Assert.deepEqual(restores, { MAP_MUSIC_ID }, "the silent exit restores the given field music once")
  Assert.equal(sound:currentMusic(), MAP_MUSIC_ID, "the restore carries the given field music")
  Assert.isNil(sound:currentRadioSequence(), "the silent exit clears the radio latch")
end

return T
