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

    Assert.equal(#music, 0, "host cover does not invent a transition music operation")
    Assert.isNil(envelope:musicNote(), "no transition music result exists without a selected effect")
    Assert.equal(envelope:cover().coefficient, 2, "the host safety cover still advances")
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

-- The presented envelope starts battle music synchronously with transition
-- initialization, before any native tick completes, and unloads only after
-- the native done condition. One launch voices exactly one start.
function T.transition_init_starts_music_before_ticks_done_and_unload_exactly_once()
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
  local decoded = {
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
  local cacheFs = { versionId = "heartgold" }
  function cacheFs:loadLua(path)
    if tostring(path):find("battle_presentation.lua", 1, true) ~= nil then
      return manifest
    end
    return decoded[tostring(path):match("([^/]+)%.lua$")]
  end
  function cacheFs:read(_)
    return nil
  end
  local music = {}
  local host = {}
  function host.status()
    return { phase = "covering" }
  end
  function host.advance() end
  function host.notify(_, _) end
  function host.submit(...)
    return true
  end
  local uploaded = {}
  local graphics = {}
  function graphics.newImage(_)
    local handle = {}
    function handle:setFilter(_, _) end
    function handle:release() end
    uploaded[#uploaded + 1] = handle
    return handle
  end
  local envelope = FieldBattlePresentation.new({
    cacheFs = cacheFs,
    windows = {},
    text = {},
    measureDisplay = function()
      return { width = 256, height = 384, topology = {}, pixelRatio = 1, signature = "transition-timing" }
    end,
    graphics = graphics,
    derivedAssets = {
      requestBattleScene = function()
        return true
      end,
    },
    fieldRenderer = {},
    captureFieldLayers = function()
      return {
        dispose = function() end,
      }
    end,
  })
  local descriptor = {
    launchId = "ordering-probe",
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
  -- Admission through the live screen builder is a separate composition
  -- contract; ordering is proven from the admitted launch state downward.
  envelope._launchId = descriptor.launchId
  envelope._descriptor = descriptor
  envelope._musicRole = descriptor.musicRole
  local ok, failure = xpcall(function()
    envelope:_startTransition(descriptor)
    envelope:_stepTransition()
    Assert.deepEqual(music, { "trainer" }, "battle music starts synchronously with transition init")
    Assert.equal(envelope:musicNote(), "started:trainer", "the staged track result is retained")
    local status = assert(envelope:transitionStatus())
    Assert.equal(status.phase, "running", "music starts before any native tick completes")
    Assert.equal(status.routeKey, "trainer/red", "the selected source route reaches its effect")
    local ticks = 0
    while envelope:transitionStatus().phase == "running" and ticks < 500 do
      envelope:_stepTransition()
      ticks = ticks + 1
    end
    Assert.equal(envelope:transitionStatus().phase, "complete", "native done completes the task")
    Assert.deepEqual(music, { "trainer" }, "ticks and done voice no second start")
    Assert.notNil(envelope._transition, "the launch retains its transition until done")
    envelope:_disposeTransition()
    Assert.isNil(envelope:transitionStatus(), "unload releases the transition")
    Assert.deepEqual(music, { "trainer" }, "unload voices no second start")
    Assert.isTrue(#uploaded > 0, "the selected effect owns uploaded sprite images")
  end, debug.traceback)
  pcall(function()
    envelope:dispose()
  end)
  if not ok then
    error(failure, 0)
  end
end

return { tests = T }
