-- Data-only host cover carries no guessed encounter effect or music event.

local Assert = require("tests.support.Assert")
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

return { tests = T }
