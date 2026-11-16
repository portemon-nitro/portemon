-- Data-only host cover carries no guessed encounter effect or music event.

local Assert = require("tests.support.Assert")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")
local SourceTick = require("libs.hgss.src.field.SourceTick")

local T = {}
local TICK = SourceTick.DT

local function cacheFs()
  local cache = { versionId = "heartgold" }
  function cache:loadLua(_)
    return nil
  end
  function cache:read(_)
    return nil
  end
  return cache
end

function T.host_cover_does_not_claim_transition_music_without_a_selected_effect()
  local music = {}
  local notifications = {}
  local host = {
    phase = "covering",
    advances = 0,
  }
  function host.status()
    return { phase = host.phase }
  end
  function host.notify(event)
    notifications[#notifications + 1] = event
  end
  function host.advance()
    host.advances = host.advances + 1
  end

  local derivedAssets = {}
  function derivedAssets.requestBattleScene(_, _)
    return false
  end

  local envelope = FieldBattlePresentation.new({
    cacheFs = cacheFs(),
    windows = {},
    text = {},
    measureDisplay = function()
      return { width = 256, height = 384, topology = {}, pixelRatio = 1, signature = "transition-timing" }
    end,
    graphics = {},
    derivedAssets = derivedAssets,
  })
  local port = envelope:factory()({
    launchId = "transition-timing",
    kind = "wild",
    environment = { sceneKey = "general/grass/day" },
    host = host,
    musicRole = "wild-battle",
    audio = {
      playMusic = function(_, role)
        music[#music + 1] = role
      end,
    },
  })

  local ok, failure = xpcall(function()
    envelope:updateFixed(TICK)

    Assert.deepEqual(music, {}, "host cover does not invent a transition music operation")
    Assert.isNil(envelope:musicNote(), "no transition music result exists without a selected effect")
    Assert.isTrue(
      envelope:cover().coefficient > 0,
      "the host safety cover still advances without a selected effect"
    )
    Assert.equal(host.advances, 1, "the coordinator advances once on the same source tick")
    Assert.equal(#notifications, 0, "no full-cover handoff is reported on the initialization tick")
  end, debug.traceback)
  pcall(port.dispose)
  pcall(function()
    envelope:dispose()
  end)
  if not ok then
    error(failure, 0)
  end
end

-- Shared PROBE route behind the transition/music coupling test: one
-- source route with inline sprite fixtures so the scenario below runs
-- the real native effect instead of a stubbed readiness flag.
local function probeManifest()
  local manifest = ManifestFixture.manifest()
  local route = assert(manifest.transitions.routes["trainer/red"])
  route.assetGroups.sprite = {
    palette = "menu/layout/bug-contest/palette",
    character = "menu/layout/bug-contest/character",
    cell = "menu/layout/bug-contest/cell",
    animation = "menu/layout/bug-contest/animation",
  }
  route.resources = {
    "menu/layout/bug-contest/palette",
    "menu/layout/bug-contest/character",
    "menu/layout/bug-contest/cell",
    "menu/layout/bug-contest/animation",
  }
  manifest.coverage["transition/trainer/red"].resources = {
    "menu/layout/bug-contest/palette",
    "menu/layout/bug-contest/character",
    "menu/layout/bug-contest/cell",
    "menu/layout/bug-contest/animation",
  }
  manifest.transitions.selection.trainerClassRoutes.PROBE = "trainer/red"
  manifest.transitions.selection.trainerClassMusicRoles.PROBE = "trainer"
  return manifest
end

local function probeDecoded()
  return {
    palette = { colors = { { r = 0, g = 0, b = 0 }, { r = 200, g = 30, b = 30 } } },
    character = { depth = 3, tiles = string.rep(string.char(0x11), 32) },
    cell = {
      cells = { { objs = { { tile = 0, width = 8, height = 8, x = -4, y = -4, palette = 0 } } } },
    },
    animation = {
      anims = {
        {
          frames = {
            { cell = 0, duration = 1, translateX = 0, translateY = 0, scaleX = 1, scaleY = 1, rotation = 0 },
          },
        },
      },
    },
  }
end

local function probeCacheFs(manifest, decoded, audioIndex)
  local AudioCache = require("libs.assets.src.audio.AudioCache")
  local fs = { versionId = "heartgold" }
  function fs:loadLua(path)
    if path == AudioCache.indexPath() then
      return audioIndex
    end
    if tostring(path):find("battle_presentation.lua", 1, true) ~= nil then
      return manifest
    end
    return decoded[tostring(path):match("([^/]+)%.lua$")]
  end
  function fs:read(_)
    return nil
  end
  return fs
end

local function probeGraphics()
  local graphics = {}
  function graphics.newImage(_)
    local handle = {}
    function handle:setFilter(_, _) end
    function handle:release() end
    return handle
  end
  return graphics
end

local function newProbeEnvelope(fs, derivedAssets, graphics)
  return FieldBattlePresentation.new({
    cacheFs = fs,
    windows = {},
    text = {},
    measureDisplay = function()
      return { width = 256, height = 384, topology = {}, pixelRatio = 1, signature = "transition-timing" }
    end,
    graphics = graphics,
    derivedAssets = derivedAssets,
    fieldRenderer = {},
    captureFieldLayers = function()
      return {
        dispose = function() end,
      }
    end,
  })
end

-- Admission through the live screen builder is a separate composition
-- contract (screen build, demand preseeding); the transition/music
-- coupling below is proven from the admitted launch state downward so
-- the screen composition cannot fail these ticks for unrelated reasons.
local function admitHeadlessTransition(envelope, descriptor)
  envelope._launchId = descriptor.launchId
  envelope._descriptor = descriptor
  envelope._musicRole = descriptor.musicRole
  envelope:_startTransition(descriptor)
end

local function probeDescriptor(host, music, launchId)
  return {
    launchId = launchId,
    kind = "trainer",
    environment = { sceneKey = "general/grass/day" },
    transitionContext = {
      kind = "trainer",
      trainerClass = "PROBE",
      doubleBattle = false,
      specialBattle = false,
      alternateTransition = false,
      playerGender = "male",
    },
    audio = {
      playMusic = function(_, role)
        music[#music + 1] = role
        return true
      end,
    },
    musicRole = "trainer",
    host = host,
  }
end

-- The encounter music voices synchronously with native effect init and
-- stays coupled while its banks build: a cold bank holds the effect in
-- ready (and the cover behind it) instead of letting the visual outrun
-- the music, and the staged start voices exactly once.
-- Native done/completion, unload-once, and sprite ownership live in the
-- transition's own suite; this test keeps only the envelope coupling.
function T.transition_music_stays_coupled_to_effect_init_across_bank_readiness()
  local manifest = probeManifest()
  local decoded = probeDecoded()
  local audioIndex = {
    sequences = { [11] = { bankId = 11 } },
    sequenceBySymbol = { trainer = 11 },
  }
  local fs = probeCacheFs(manifest, decoded, audioIndex)
  local banksReady = false
  local bankRequests = {}
  local music = {}
  local notifications = {}
  local host = {}
  function host.status()
    return { phase = "covering" }
  end
  function host.advance() end
  function host.notify(event)
    notifications[#notifications + 1] = event
  end
  function host.submit(...)
    return true
  end
  local envelope = newProbeEnvelope(fs, {
    requestBattlePresentation = function()
      return true
    end,
    requestAudioBank = function(bankId, _)
      bankRequests[#bankRequests + 1] = bankId
      return banksReady
    end,
  }, probeGraphics())
  local descriptor = probeDescriptor(host, music, "coupled-music-probe")
  admitHeadlessTransition(envelope, descriptor)
  local ok, failure = xpcall(function()
    envelope:_stepTransition()
    Assert.equal(
      envelope:transitionStatus().phase,
      "ready",
      "the native effect waits while its battle-music banks still build"
    )
    Assert.deepEqual(music, {}, "no music voices before its banks stage")
    Assert.isNil(envelope:musicNote(), "no staged track result exists before the banks stage")
    envelope:_stepCover()
    Assert.equal(envelope:cover().coefficient, 0, "cover holds while the transition waits for music")
    Assert.deepEqual(notifications, {}, "no full-cover handoff fires before the coupled start")
    banksReady = true
    envelope:_stepTransition()
    Assert.equal(
      envelope:transitionStatus().phase,
      "running",
      "the native effect starts once its battle-music banks stage"
    )
    Assert.deepEqual(music, { "trainer" }, "battle music voices synchronously with effect init")
    Assert.equal(envelope:musicNote(), "started:trainer", "the staged track result is retained")
    envelope:_stepCover()
    Assert.isTrue(
      envelope:cover().coefficient > 0,
      "cover advances only after the coupled transition and music start"
    )
    for _ = 1, 3 do
      envelope:_stepTransition()
    end
    Assert.deepEqual(music, { "trainer" }, "running ticks voice no second start")
    local sawStagedBank = false
    for _, bankId in ipairs(bankRequests) do
      if bankId == 11 then
        sawStagedBank = true
      end
    end
    Assert.isTrue(sawStagedBank, "the music gate demands its staged bank")
  end, debug.traceback)
  pcall(function()
    envelope:dispose()
  end)
  if not ok then
    error(failure, 0)
  end
end

-- Without a native effect the cover-full handoff waits for the staged
-- battle-music voice: a cold bank must delay cover-complete instead of
-- releasing the field under silence and voicing the music late (or never).
function T.cover_complete_holds_until_battle_music_voices_without_transition()
  local AudioCache = require("libs.assets.src.audio.AudioCache")
  local audioIndex = {
    sequences = { [12] = { bankId = 12 } },
    sequenceBySymbol = { ["wild-battle"] = 12 },
  }
  local cache = { versionId = "heartgold" }
  function cache:loadLua(path)
    if path == AudioCache.indexPath() then
      return audioIndex
    end
    return nil
  end
  function cache:read(_)
    return nil
  end
  local banksReady = false
  local music = {}
  local notifications = {}
  local host = {}
  function host.status()
    return { phase = "covering" }
  end
  function host.advance() end
  function host.notify(event)
    notifications[#notifications + 1] = event
  end
  local envelope = FieldBattlePresentation.new({
    cacheFs = cache,
    windows = {},
    text = {},
    measureDisplay = function()
      return { width = 256, height = 384, topology = {}, pixelRatio = 1, signature = "transition-timing" }
    end,
    graphics = {},
    derivedAssets = {
      requestAudioBank = function(_, _)
        return banksReady
      end,
    },
  })
  local descriptor = {
    launchId = "cold-bank-cover-probe",
    kind = "wild",
    environment = { sceneKey = "general/grass/day" },
    host = host,
    musicRole = "wild-battle",
    audio = {
      playMusic = function(_, role)
        music[#music + 1] = role
        return true
      end,
    },
  }
  envelope._launchId = descriptor.launchId
  envelope._descriptor = descriptor
  envelope._musicRole = descriptor.musicRole
  local ok, failure = xpcall(function()
    for _ = 1, 10 do
      envelope:_stepCover()
    end
    Assert.equal(
      envelope:cover().coefficient,
      FieldBattlePresentation.COVER_MAX,
      "cover still reaches full opacity while the banks build"
    )
    Assert.deepEqual(music, {}, "no music voices before its banks stage")
    Assert.deepEqual(notifications, {}, "cover-complete waits for the staged music voice")
    banksReady = true
    envelope:_stepCover()
    Assert.deepEqual(music, { "wild-battle" }, "the staged voice follows the bank the same tick")
    Assert.deepEqual(notifications, { "cover-complete" }, "the handoff fires with the coupled voice")
  end, debug.traceback)
  pcall(function()
    envelope:dispose()
  end)
  if not ok then
    error(failure, 0)
  end
end

return { tests = T }
