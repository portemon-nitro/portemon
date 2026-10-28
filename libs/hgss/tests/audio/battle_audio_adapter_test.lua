-- Launch-scoped battle voice operations behind the adapter: strict
-- typed dispatch over the borrowed voice service, normalized source
-- ranges, launch/generation handle scope with pure completion queries,
-- and real audible dispatch through the normalized engine. Synthetic
-- fixtures only: no commercial bytes enter the repository.

local Assert = require("tests.support.Assert")
local AudioAssetProvider = require("libs.hgss.src.audio.AudioAssetProvider")
local AudioFixture = require("tests.support.AudioFixture")
local BattleAudio = require("libs.hgss.src.audio.BattleAudio")
local Errors = require("libs.errors.src.Errors")
local GameSound = require("libs.hgss.src.audio.GameSound")
local SequencePlayer = require("libs.nds.src.nitro.sound.SequencePlayer")
local VoiceMixer = require("libs.nds.src.nitro.sound.VoiceMixer")

local T = {}

local SAMPLE_RATE = 48000

-- A full-port voice double: every operation records its receiver and
-- arguments, playing voices stay observable, and every port answers
-- with the success contract the adapter requires.
---@param log table recorded operations under inspection
---@return table voice double with the full engine port surface
local function fullSink(log)
  local sink = { log = log, playing = {}, cry = nil, cryFinished = true, fanfare = false }
  function sink:play(symbol)
    log[#log + 1] = { op = "play", receiver = self, symbol = symbol }
    sink.playing[symbol] = true
    return true
  end
  function sink:playPanned(symbol, pan)
    log[#log + 1] = { op = "playPanned", receiver = self, symbol = symbol, pan = pan }
    sink.playing[symbol] = true
    return true
  end
  function sink:playCry(species, pattern, form, mode, pan, volume, pitch)
    log[#log + 1] = {
      op = "playCry",
      receiver = self,
      species = species,
      pattern = pattern,
      form = form,
      mode = mode,
      pan = pan,
      volume = volume,
      pitch = pitch,
    }
    sink.cry = { species = species, pattern = pattern }
    sink.cryFinished = false
    return true
  end
  function sink:playMusic(symbol)
    log[#log + 1] = { op = "playMusic", receiver = self, symbol = symbol }
    sink.playing[symbol] = true
    return true
  end
  function sink:playFanfare(symbol)
    log[#log + 1] = { op = "playFanfare", receiver = self, symbol = symbol }
    sink.fanfare = true
    return true
  end
  function sink:stop(symbol)
    log[#log + 1] = { op = "stop", receiver = self, symbol = symbol }
    sink.playing[symbol] = nil
    return true
  end
  function sink:stopMusic()
    log[#log + 1] = { op = "stopMusic", receiver = self }
    return true
  end
  function sink:isEffectWaitComplete(symbol)
    return sink.playing[symbol] ~= true
  end
  function sink:isCryFinished()
    return sink.cryFinished
  end
  function sink:isFanfarePlaying()
    return sink.fanfare
  end
  return sink
end

---@param launchId string owning launch identity under test driving
---@return BattleAudio adapter over a fresh full-port double
---@return table recorded operations under inspection
---@return table voice double under observation
local function adapterOverDouble(launchId)
  local log = {}
  local sink = fullSink(log)
  return BattleAudio.new({ sink = sink, launchId = launchId }), log, sink
end

function T.accepted_operations_return_scoped_handles_in_order()
  local voice = adapterOverDouble("launch-handles")
  local music = voice:startMusic("SEQ_GS_VS_NORAPOKE")
  local effect = voice:playEffect("SEQ_SE_DP_KOUKA_M")
  local fanfare = voice:playFanfare("SEQ_GS_WIN1")
  local cry = voice:playCry({ species = 152 })
  Assert.equal(music.launch, "launch-handles", "music handles name their launch")
  Assert.equal(music.generation, "launch-handles", "handles default to the launch generation")
  Assert.equal(music.sequence, 1, "handles sequence operations in order")
  Assert.equal(effect.sequence, 2, "handles sequence operations in order")
  Assert.equal(fanfare.sequence, 3, "handles sequence operations in order")
  Assert.equal(cry.sequence, 4, "handles sequence operations in order")
  Assert.equal(music.kind, "music", "handles name their operation kind")
  Assert.equal(cry.detail.species, 152, "cry handles carry their voice identity")
end

function T.source_panned_effects_use_the_panned_audio_port()
  local voice, log = adapterOverDouble("launch-pan")
  voice:playEffect("SEQ_SE_DP_POKE_DEAD3", 117)
  Assert.equal(log[1].op, "playPanned", "source panned effects reach the dedicated panned port")
  Assert.equal(log[1].symbol, "SEQ_SE_DP_POKE_DEAD3", "the panned port receives the exact effect symbol")
  Assert.equal(log[1].pan, 117, "the panned port receives the source pan")
end

function T.distinct_generations_scope_their_handles()
  local log = {}
  local sink = fullSink(log)
  local first = BattleAudio.new({ sink = sink, launchId = "launch-gen", generation = "gen-1" })
  local second = BattleAudio.new({ sink = sink, launchId = "launch-gen", generation = "gen-2" })
  local handle = first:playEffect("SEQ_SE_DP_KOUKA_M")
  Assert.isFalse(second:stopVoice(handle), "a newer generation never stops an older voice")
  Assert.isTrue(second:voiceComplete(handle), "a stale handle never blocks a newer generation")
  Assert.equal(#log, 1, "stale operations never reach the sink")
end

function T.throwing_and_flat_answers_fail_with_operation_and_launch_identity()
  local throwing = {
    play = function(_)
      error("injected voice fault", 0)
    end,
  }
  local throwingVoice = BattleAudio.new({ sink = throwing, launchId = "launch-throw" })
  local ok, err = pcall(throwingVoice.playEffect, throwingVoice, "SEQ_SE_DP_KOUKA_M")
  Assert.isFalse(ok, "a throwing sink never reads as played")
  Assert.isTrue(Errors.is(err), "rejections carry structured identity")
  Assert.isTrue(
    tostring(err):find("launch-throw", 1, true) ~= nil and tostring(err):find("effect-start", 1, true) ~= nil,
    "rejections name their launch and operation: " .. tostring(err)
  )
  local flat = {
    play = function(_)
      return false
    end,
  }
  local flatVoice = BattleAudio.new({ sink = flat, launchId = "launch-flat" })
  local flatOk, flatErr = pcall(flatVoice.playEffect, flatVoice, "SEQ_SE_DP_KOUKA_M")
  Assert.isFalse(flatOk, "a non-throwing rejection never reads as played")
  Assert.isTrue(
    tostring(flatErr):find("launch-flat", 1, true) ~= nil,
    "rejections name their launch: " .. tostring(flatErr)
  )
  local nilSink = {
    play = function(_)
      return nil
    end,
  }
  local nilVoice = BattleAudio.new({ sink = nilSink, launchId = "launch-nil" })
  local nilOk = pcall(nilVoice.playEffect, nilVoice, "SEQ_SE_DP_KOUKA_M")
  Assert.isFalse(nilOk, "a nil answer never reads as played")
end

function T.cry_ranges_normalize_once_with_documented_defaults()
  local voice, log, _ = adapterOverDouble("launch-ranges")
  voice:playCry({ species = 152 })
  local entry = log[1]
  Assert.equal(entry.pattern, 0, "cries default to the plain pattern")
  Assert.equal(entry.form, 0, "cries default to the species bank")
  Assert.equal(entry.mode, 0, "cries default to the voice mode slot")
  Assert.equal(entry.pan, 0, "cries default to the centered track pan")
  Assert.equal(entry.volume, 127, "cries default to the source primary volume")
  Assert.equal(entry.pitch, 0, "cries default to the unshifted pitch")
  voice:playCry({ species = 152, pattern = 12, form = 1, mode = 3, pan = -16, volume = 90, pitch = -44 })
  local varied = log[2]
  Assert.equal(varied.pattern, 12, "cry patterns ride the subsystem families")
  Assert.equal(varied.form, 1, "cry forms ride the species bank routing")
  Assert.equal(varied.pan, -16, "cry pans ride the track offset domain")
  local bad = {
    { species = 0 },
    { species = 152, pattern = 15 },
    { species = 152, volume = 128 },
    { species = 152, form = -1 },
    { species = 152, mode = 256 },
    { species = 152, pan = 0.5 },
    { species = 152, pitch = "high" },
  }
  for _, spec in ipairs(bad) do
    local ok = pcall(voice.playCry, voice, spec)
    Assert.isFalse(ok, "out-of-range cry facts never dispatch")
  end
  local emptyOk = pcall(voice.playEffect, voice, "")
  Assert.isFalse(emptyOk, "empty symbols never dispatch")
end

function T.completion_queries_observe_without_advancing()
  local voice, _, sink = adapterOverDouble("launch-queries")
  local effect = voice:playEffect("SEQ_SE_DP_KOUKA_M")
  Assert.isFalse(voice:voiceComplete(effect), "a started effect waits while active")
  sink.playing["SEQ_SE_DP_KOUKA_M"] = nil
  Assert.isTrue(voice:voiceComplete(effect), "a retired effect completes")
  local cry = voice:playCry({ species = 152 })
  Assert.isFalse(voice:voiceComplete(cry), "a started cry waits while unfinished")
  sink.cryFinished = true
  Assert.isTrue(voice:voiceComplete(cry), "a finished cry completes")
  local fanfare = voice:playFanfare("SEQ_GS_WIN1")
  Assert.isFalse(voice:voiceComplete(fanfare), "a sounding fanfare waits while playing")
  sink.fanfare = false
  Assert.isTrue(voice:voiceComplete(fanfare), "a retired fanfare completes")
  local music = voice:startMusic("SEQ_GS_VS_NORAPOKE")
  Assert.isFalse(voice:voiceComplete(music), "an owned music voice never completes on its own")
  local repeated = voice:voiceComplete(effect)
  Assert.equal(repeated, voice:voiceComplete(effect), "completion queries never advance the clock")
end

function T.owned_stops_release_only_their_own_voice()
  local voice, log, _ = adapterOverDouble("launch-stops")
  local effect = voice:playEffect("SEQ_SE_DP_KOUKA_M")
  Assert.isTrue(voice:stopVoice(effect), "an owned effect stop releases")
  local stopped = log[#log]
  Assert.equal(stopped.op, "stop", "effect stops reach the sink stop port")
  Assert.equal(stopped.symbol, "SEQ_SE_DP_KOUKA_M", "stops name their owned symbol")
  local music = voice:startMusic("SEQ_GS_VS_NORAPOKE")
  Assert.isTrue(voice:stopVoice(music), "an owned music stop releases")
  Assert.equal(log[#log].op, "stopMusic", "music stops reach the sink music port")
  local foreign =
    { launch = "another-launch", generation = "another-launch", sequence = 1, kind = "effect", detail = {} }
  local before = #log
  Assert.isFalse(voice:stopVoice(foreign), "a stale stop releases nothing")
  Assert.equal(#log, before, "stale stops never reach the sink")
end

function T.missing_ports_fail_loudly_instead_of_silence()
  local partial = {
    play = function(_)
      return true
    end,
  }
  local voice = BattleAudio.new({ sink = partial, launchId = "launch-partial" })
  local ok = pcall(voice.playFanfare, voice, "SEQ_GS_WIN1")
  Assert.isFalse(ok, "a missing fanfare port never reads as played")
  local queryOk = pcall(voice.voiceComplete, voice, {
    launch = "launch-partial",
    generation = "launch-partial",
    sequence = 1,
    kind = "effect",
    detail = { symbol = "SEQ_SE_DP_KOUKA_M" },
  })
  Assert.isFalse(queryOk, "a missing query port never reads as complete")
end

-- One synthetic normalized bundle shaped like the production audio
-- cache so adapter dispatch proves audible sample output through the
-- shared engine classes, never through a recording sink alone.
---@param symbols string[] voiced operation symbols under staging
---@return table bundle the ready-cache writer consumes
local function operationBundle(symbols)
  local bundle = AudioFixture.bundle()
  local sequences, banks, samples, metadata = {}, {}, {}, {}
  local instruments = {}
  local indexSequences, indexPlayers, bySymbol = {}, {}, {}
  for position, symbol in ipairs(symbols) do
    local playerId = position + 1
    local key = AudioFixture.key(200 + position)
    local wave = { 3000, -3000, 5000, -5000, 7000, -7000, 4000, -4000 }
    local instructions = {
      { op = "program", program = 0 },
      { op = "note", key = 60, velocity = 127, duration = 8 },
      { op = "end" },
    }
    if symbol == "synthetic-operation-silent-control" then
      wave = { 0, 0, 0, 0 }
      instructions = {
        { op = "program", program = 0 },
        { op = "end" },
      }
    end
    sequences[position - 1] = AudioFixture.sequence(position - 1, symbol, 12, playerId, {
      entry = 1,
      initialTrackMask = 0x0001,
      instructions = instructions,
    }, {
      id = playerId,
      initialVolume = 127,
      playerPriority = 64,
      channelPriority = 64,
    })
    instruments[position - 1] = {
      kind = "direct",
      voice = {
        generator = { kind = "sample", sample = key },
        originalKey = 60,
        envelope = { attack = 0, decay = 0, sustain = 127, release = 0 },
        pan = 64,
      },
    }
    samples[key] = AudioFixture.pcm16le(wave)
    metadata[key] = AudioFixture.sampleMetadata(key, {
      frames = #wave,
      loop = { startFrame = 0, endFrame = #wave },
    })
  end
  for id, sequence in pairs(sequences) do
    indexSequences[id] = { id = id, symbol = sequence.symbol, bankId = sequence.bankId, playerId = sequence.player.id }
    indexPlayers[sequence.player.id] = { id = sequence.player.id, maxSequences = 16, channelMask = 0xFFFF }
    bySymbol[sequence.symbol] = id
  end
  bundle.index.sequences = indexSequences
  bundle.index.players = indexPlayers
  bundle.index.banks = { [12] = { id = 12, symbol = "BANK_TEST" } }
  bundle.index.sequenceBySymbol = bySymbol
  bundle.index.bankBySymbol = { BANK_TEST = 12 }
  bundle.sequences = sequences
  bundle.banks = { [12] = AudioFixture.bank(12, "BANK_TEST", nil, instruments) }
  bundle.samples = samples
  bundle.sampleMetadata = metadata
  return bundle
end

---@param symbols string[] voiced operation symbols under staging
---@return BattleAudio adapter over the real normalized engine
---@return table engine player behind rendering
local function adapterOverEngine(symbols)
  local provider = AudioAssetProvider.new(AudioFixture.readyCache(operationBundle(symbols)))
  ---@cast provider AudioAssetProvider
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local player = SequencePlayer.new({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  ---@cast player SequencePlayer
  local sound = GameSound.new({ provider = provider, player = player, completionAvailable = true })
  return BattleAudio.new({ sink = sound, launchId = "launch-engine" }), player
end

---@param pcm table interleaved stereo samples under measurement
---@return number peak absolute sample
local function peakAbs(pcm)
  local peak = 0
  for _, value in ipairs(pcm) do
    local magnitude = math.abs(value)
    if magnitude > peak then
      peak = magnitude
    end
  end
  return peak
end

---@param pcm table interleaved stereo samples under measurement
---@param frames integer frames under measurement
---@return table left-channel samples
local function leftChannel(pcm, frames)
  local out = {}
  for index = 1, frames do
    out[index] = pcm[index * 2 - 1]
  end
  return out
end

function T.adapter_dispatch_voices_audible_samples_through_the_shared_engine()
  local voice, player = adapterOverEngine({
    "synthetic-operation-move",
    "synthetic-operation-impact",
    "synthetic-operation-silent-control",
  })
  voice:playEffect("synthetic-operation-silent-control")
  Assert.equal(peakAbs(leftChannel(player:render(4000), 4000)), 0, "the legitimate silent control renders silence")
  for _, symbol in ipairs({ "synthetic-operation-move", "synthetic-operation-impact" }) do
    local handle = voice:playEffect(symbol)
    local frames = player:render(4000)
    local left = {}
    for index = 1, 4000 do
      left[index] = frames[index * 2 - 1]
    end
    Assert.isTrue(peakAbs(left) > 0, "the dispatched operation voices audibly: " .. symbol)
    Assert.isTrue(voice:stopVoice(handle), "the voiced operation releases through its handle")
  end
end

function T.panned_effects_reach_the_correct_stereo_channel()
  local symbol = "synthetic-operation-impact"
  for _, pan in ipairs({ 117, -117 }) do
    local voice, player = adapterOverEngine({ symbol })
    local handle = voice:playEffect(symbol, pan)
    local samples = player:render(4000)
    local left, right = 0, 0
    for index = 1, 4000 do
      left = left + math.abs(samples[index * 2 - 1])
      right = right + math.abs(samples[index * 2])
    end
    Assert.isTrue(left + right > 0, "the panned effect is audible")
    if pan > 0 then
      Assert.isTrue(right > left, "positive source pan voices the foe effect on the right")
    else
      Assert.isTrue(left > right, "negative source pan voices the player effect on the left")
    end
    Assert.isTrue(voice:stopVoice(handle), "the effect stops before the opposite-side test")
  end
end

-- Warning and progression voices ride the same operation contract the
-- native low-HP warning and EXP/level-up jingles will drive: staged
-- symbols dispatch with handle scope while an unstaged symbol fails
-- with its identity instead of playing silently.
function T.warning_and_progression_voices_keep_their_operation_contract()
  local voice, player = adapterOverEngine({ "synthetic-operation-low-hp", "synthetic-operation-exp" })
  local warning = voice:playEffect("synthetic-operation-low-hp")
  Assert.equal(warning.kind, "effect", "warning voices scope their handles")
  Assert.isFalse(voice:voiceComplete(warning), "a started warning waits while active")
  local frames = player:render(4000)
  local left = {}
  for index = 1, 4000 do
    left[index] = frames[index * 2 - 1]
  end
  Assert.isTrue(peakAbs(left) > 0, "the warning voice renders audibly")
  Assert.isTrue(voice:stopVoice(warning), "an owned warning stop releases")
  Assert.isTrue(voice:voiceComplete(warning), "a stopped warning completes")
  local progression = voice:playEffect("synthetic-operation-exp")
  Assert.isFalse(voice:voiceComplete(progression), "a started progression waits while active")
  local ok = pcall(voice.playEffect, voice, "synthetic-operation-unstaged")
  Assert.isFalse(ok, "an unstaged progression symbol never reads as played")
end

return { tests = T }
