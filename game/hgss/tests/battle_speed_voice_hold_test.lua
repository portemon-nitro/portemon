-- Battle speed collapses real-time voice holds: at single rate the screen
-- holds timeline and evolution progress on unfinished cry/fanfare voices,
-- while above single rate the same voices never gate source progress (the
-- envelope already steps every other quantum per virtual tick, so only
-- real-time audio completion is left unscaled). Synthetic screen rig with a
-- controllable voice sink; no ROM.

local Assert = require("tests.support.Assert")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local BattleScreenState = require("game.hgss.src.battle.BattleScreenState")
local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")
local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")

local T = {}

---@param state table<string, boolean> controllable voice completion facts
---@return table non-legacy voice sink answering the fact pattern
local function voiceSink(state)
  local sink = {}
  function sink.play(_)
    return true
  end
  function sink.playPanned(_, _, _)
    return true
  end
  function sink.playCry(...)
    return true
  end
  function sink.playFanfare(_, _)
    return true
  end
  function sink.playMusic(_, _)
    return true
  end
  function sink.stop(_, _)
    return true
  end
  function sink.isCryFinished()
    return state.cryDone == true
  end
  function sink.isFanfarePlaying()
    return state.fanfarePlaying == true
  end
  function sink.isEffectWaitComplete()
    return state.effectDone == true
  end
  return sink
end

---@return table stub preparation services behind screen construction
local function stubServices()
  local services = { hold = {}, images = {} }
  function services.prepare(_)
    return true
  end
  function services.drawable(key)
    if services.images[key] == nil then
      services.images[key] = { handle = key }
    end
    return services.images[key]
  end
  function services.release(_)
  end
  return services
end

---@param battleSpeed integer? frozen launch factor under test, nil for the default
---@param state table<string, boolean>? controllable voice facts, defaulting to unfinished
---@return table live synthetic battle screen
---@return table controllable voice facts behind the screen sink
local function newScreen(battleSpeed, state)
  state = state or {}
  local opts = {
    launchId = "voice-hold-probe",
    splRandomState = { state = 0 },
    manifest = ManifestFixture.launchView(
      { "back:PKMN_TRAINER_ETHAN", "front:YOUNGSTER" },
      { "ball:POKE_BALL" }
    ),
    model = BattlePresentationModel,
    submit = function()
      return true
    end,
    measureDisplay = function()
      return { width = 256, height = 384, topology = {}, pixelRatio = 1, signature = "voice-hold" }
    end,
    assets = stubServices(),
    text = {},
    windows = {},
    audio = voiceSink(state),
    overrides = { sceneKey = "general/grass/day" },
  }
  if battleSpeed ~= nil then
    opts.battleSpeed = battleSpeed
  end
  return BattleScreenState.new(opts), state
end

---@param screen table live synthetic screen under test driving
---@return table live cry voice handle behind the waiting slot
local function startCry(screen)
  local handle = screen._battleAudio:playCry({
    species = 1,
    speciesKey = "EEVEE",
    pattern = 0,
    form = 0,
    mode = 0,
    pan = 0,
    volume = 100,
    pitch = 0,
  })
  screen._waitingCueVoice = handle
  return handle
end

---@param screen table live synthetic screen under test driving
---@return table live fanfare voice handle behind the waiting slot
local function startFanfare(screen, state)
  state.fanfarePlaying = true
  local handle = screen._battleAudio:playFanfare("SEQ_SE_DP_LEVELUP")
  screen._waitingCueVoice = handle
  return handle
end

function T.single_rate_holds_timeline_sound_cues_on_unfinished_voices()
  for _, speed in ipairs({ nil, 1 }) do
    local state = { cryDone = false, fanfarePlaying = true, effectDone = false }
    local screen = newScreen(speed, state)
    local ok, failure = xpcall(function()
      startCry(screen)
      Assert.isFalse(
        screen:_soundCueComplete({ kind = "cry", waitForVoice = true }),
        "single rate holds the faint cry until its voice finishes"
      )
      startFanfare(screen, state)
      Assert.isFalse(
        screen:_soundCueComplete({ kind = "fanfare", waitForVoice = true }),
        "single rate holds the level-up jingle until its voice finishes"
      )
    end, debug.traceback)
    pcall(function()
      screen:dispose()
    end)
    if not ok then
      error(failure, 0)
    end
  end
end

function T.fast_rate_releases_timeline_sound_cues_without_waiting_for_voices()
  local screen = newScreen(4, { cryDone = false, fanfarePlaying = true, effectDone = false })
  local ok, failure = xpcall(function()
    startCry(screen)
    Assert.isTrue(
      screen:_soundCueComplete({ kind = "cry", waitForVoice = true }),
      "quadruple rate never gates the faint on its unfinished cry"
    )
    screen._waitingCueVoice = screen._battleAudio:playFanfare("SEQ_SE_DP_LEVELUP")
    Assert.isTrue(
      screen:_soundCueComplete({ kind = "fanfare", waitForVoice = true }),
      "quadruple rate never gates the level-up on its unfinished jingle"
    )
  end, debug.traceback)
  pcall(function()
    screen:dispose()
  end)
  if not ok then
    error(failure, 0)
  end
end

function T.single_rate_holds_evolution_voices_until_they_finish()
  local state = { cryDone = false }
  local screen = newScreen(nil, state)
  local ok, failure = xpcall(function()
    local completion = { waitingVoice = startCry(screen) }
    Assert.isFalse(
      screen:_evolutionVoiceComplete(completion),
      "single rate holds evolution on its unfinished cry"
    )
    state.cryDone = true
    Assert.isTrue(
      screen:_evolutionVoiceComplete(completion),
      "a finished cry still releases evolution at single rate"
    )
  end, debug.traceback)
  pcall(function()
    screen:dispose()
  end)
  if not ok then
    error(failure, 0)
  end
end

function T.fast_rate_releases_evolution_voices_without_waiting()
  local screen = newScreen(4, { cryDone = false })
  local ok, failure = xpcall(function()
    local completion = { waitingVoice = startCry(screen) }
    Assert.isTrue(
      screen:_evolutionVoiceComplete(completion),
      "quadruple rate never gates evolution on its unfinished cry"
    )
  end, debug.traceback)
  pcall(function()
    screen:dispose()
  end)
  if not ok then
    error(failure, 0)
  end
end

function T.single_rate_holds_evolution_message_waits_on_unfinished_voices()
  local state = { effectDone = false, fanfarePlaying = true }
  local screen = newScreen(nil, state)
  local ok, failure = xpcall(function()
    local effectVoice = screen._battleAudio:playEffect("SEQ_SE_DP_SELECT")
    local completion = { printerMessageId = 7, printerCallbackVoices = { [1] = effectVoice } }
    Assert.isFalse(
      screen:_evolutionPrinterCallback(completion, 7, 1, 1),
      "single rate holds the evolution message on its unfinished effect"
    )
    state.effectDone = true
    Assert.isTrue(
      screen:_evolutionPrinterCallback(completion, 7, 1, 1),
      "a finished effect still releases the evolution message at single rate"
    )
    local fanfareVoice = screen._battleAudio:playFanfare("SEQ_ME_SHINKAOME")
    local jingle = { printerMessageId = 9, printerCallbackVoices = { [1] = fanfareVoice } }
    Assert.isFalse(
      screen:_evolutionPrinterCallback(jingle, 9, 2, 1),
      "single rate holds the evolution message on its playing jingle"
    )
  end, debug.traceback)
  pcall(function()
    screen:dispose()
  end)
  if not ok then
    error(failure, 0)
  end
end

function T.fast_rate_releases_evolution_message_waits_without_waiting()
  local screen = newScreen(4, { effectDone = false, fanfarePlaying = true })
  local ok, failure = xpcall(function()
    local effectVoice = screen._battleAudio:playEffect("SEQ_SE_DP_SELECT")
    local completion = { printerMessageId = 7, printerCallbackVoices = { [1] = effectVoice } }
    Assert.isTrue(
      screen:_evolutionPrinterCallback(completion, 7, 1, 1),
      "quadruple rate never gates the evolution message on its unfinished effect"
    )
    local fanfareVoice = screen._battleAudio:playFanfare("SEQ_ME_SHINKAOME")
    local jingle = { printerMessageId = 9, printerCallbackVoices = { [1] = fanfareVoice } }
    Assert.isTrue(
      screen:_evolutionPrinterCallback(jingle, 9, 2, 1),
      "quadruple rate never gates the evolution message on its playing jingle"
    )
  end, debug.traceback)
  pcall(function()
    screen:dispose()
  end)
  if not ok then
    error(failure, 0)
  end
end

function T.single_rate_holds_native_effect_voices_until_they_finish()
  local screen = newScreen(nil, { effectDone = false })
  local ok, failure = xpcall(function()
    local key = screen._player._audio.play("probe-native-se")
    Assert.isFalse(
      screen._player._audio.isFinished(key),
      "single rate holds native occurrences on unfinished effect voices"
    )
  end, debug.traceback)
  pcall(function()
    screen:dispose()
  end)
  if not ok then
    error(failure, 0)
  end
end

function T.fast_rate_releases_native_effect_voices_without_waiting()
  local screen = newScreen(4, { effectDone = false })
  local ok, failure = xpcall(function()
    local key = screen._player._audio.play("probe-native-se")
    Assert.isFalse(
      screen._player._audio.isFinished(key),
      "quadruple rate arms each fresh voice for a single tick so sound tasks observe it alive"
    )
    Assert.isTrue(
      screen._player._audio.isFinished(key),
      "quadruple rate never gates native occurrences past the single arming tick"
    )
  end, debug.traceback)
  pcall(function()
    screen:dispose()
  end)
  if not ok then
    error(failure, 0)
  end
end

function T.tracked_send_out_cries_stage_the_single_voice_slot()
  local voiceState = {}
  local screen = newScreen(1, voiceState)
  screen._monCatalog = {
    species = function(_)
      return { nativeId = 25 }
    end,
  }
  local ok, failure = xpcall(function()
    screen:_playCryCue({ species = "EEVEE", speciesKey = "EEVEE", foe = false })
    Assert.isNil(screen._waitingCueVoice, "untracked cries leave the voice slot alone")
    screen:_playCryCue({ species = "EEVEE", speciesKey = "EEVEE", foe = false, waitForVoice = true })
    Assert.notNil(screen._waitingCueVoice, "held cries stage the single voice slot")
    screen._waitingCueVoice = nil
    screen:_playCryCue({ species = "EEVEE", speciesKey = "EEVEE", foe = false, trackVoice = true })
    Assert.notNil(
      screen._waitingCueVoice,
      "tracked send-out cries stage the slot without gating the queue"
    )
    Assert.isTrue(
      screen:_soundCueComplete({ kind = "cry" }),
      "the tracked stage never gates a cue that waits on nothing"
    )
    Assert.isFalse(
      screen:_soundCueComplete({ kind = "cry", waitForVoice = true }),
      "the staged slot still holds a waiter while the cry is unfinished"
    )
    voiceState.cryDone = true
    Assert.isTrue(
      screen:_soundCueComplete({ kind = "cry", waitForVoice = true }),
      "a finished cry releases the tracked slot through the same poll"
    )
    Assert.isNil(screen._waitingCueVoice, "the release consumes the single voice slot")
  end, debug.traceback)
  pcall(function()
    screen:dispose()
  end)
  if not ok then
    error(failure, 0)
  end
end

function T.fast_rate_retires_positioned_sound_tasks_without_arming_escape()
  local BattleEffectTasks = require("libs.hgss.src.presentation.BattleEffectTasks")
  local screen = newScreen(4, { effectDone = false })
  local ok, failure = xpcall(function()
    for _, symbol in ipairs({ "SEQ_SE_DP_209", "SEQ_SE_DP_209" }) do
      local task = assert(
        BattleEffectTasks.create("positioned-sound-motion", {
          sound = symbol,
          values = { 0, 0, 0, 0 },
        }, {}, { audio = screen._player._audio })
      )
      for _ = 1, 100 do
        task:stepSourceTick({ tick = 1 })
        if task:status() == "complete" then
          break
        end
      end
      Assert.equal(
        task:status(),
        "complete",
        "quadruple rate retires the positioned voice " .. symbol .. " instead of escaping"
      )
      task:dispose()
    end
  end, debug.traceback)
  pcall(function()
    screen:dispose()
  end)
  if not ok then
    error(failure, 0)
  end
end

---@return table versioned derived-cache double behind the wiring probe
local function wiringCache()
  local cache = { versionId = "voice-hold-wiring" }
  function cache:loadLua(path)
    if tostring(path):find("battle_presentation", 1, true) ~= nil then
      return ManifestFixture.manifest()
    end
    return nil
  end
  function cache:read(_)
    return nil
  end
  return cache
end

---@param speed integer? frozen launch factor under test, nil for the default
---@return table live presented-battle screen behind the admitted launch
---@return table envelope owning the launch lifetime
local function admitWithSpeed(speed)
  local envelope = FieldBattlePresentation.new({
    splRandomState = { state = 0 },
    cacheFs = wiringCache(),
    windows = {},
    text = {},
    measureDisplay = function()
      return { width = 256, height = 384, topology = {}, pixelRatio = 1, signature = "voice-hold-wiring" }
    end,
    derivedAssets = {},
    audio = {
      play = function()
        return true
      end,
    },
  })
  local host = {
    phase = "active",
    advances = 0,
  }
  function host.status()
    return { phase = host.phase }
  end
  function host.advance()
    host.advances = host.advances + 1
  end
  function host.submit(_)
    return true
  end
  function host.notify(_, _)
  end
  local descriptor = {
    launchId = "voice-hold-wiring",
    kind = "wild",
    environment = { sceneKey = "general/grass/day" },
    host = host,
    audio = {
      playMusic = function()
        return true
      end,
    },
  }
  if speed ~= nil then
    descriptor.battleSpeed = speed
  end
  local port = envelope:factory()(descriptor)
  Assert.notNil(port, "admission hands back its pending port")
  local screen = assert(envelope._screen, "a graphics-free launch builds its screen at admission")
  return screen, envelope
end

function T.envelope_builds_screens_with_the_frozen_launch_factor()
  local screen, envelope = admitWithSpeed(4)
  local ok, failure = xpcall(function()
    Assert.equal(screen._battleSpeed, 4, "the admitted screen carries the frozen quadruple factor")
  end, debug.traceback)
  pcall(function()
    envelope:dispose()
  end)
  if not ok then
    error(failure, 0)
  end
  local defaultScreen, defaultEnvelope = admitWithSpeed(nil)
  local defaultOk, defaultFailure = xpcall(function()
    Assert.equal(defaultScreen._battleSpeed, 1, "a launch without a factor screens at single rate")
  end, debug.traceback)
  pcall(function()
    defaultEnvelope:dispose()
  end)
  if not defaultOk then
    error(defaultFailure, 0)
  end
end

return { tests = T }
