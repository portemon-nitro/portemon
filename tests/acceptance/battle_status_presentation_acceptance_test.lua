-- A real HGSS battle projects a successful sleep condition into the detached
-- presentation packet without invoking GPU rendering.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local MAP = "MAP_NEW_BARK_ELMS_LAB_1F"

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map-data:7", "map-data:61", "map-data:111", "map:7", "map:61", "map:111" },
    tags = { "battle", "status", "journey" },
  },
  tests = {},
}

local function harness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      return {
        saveId = "save-status-presentation",
        versionId = versionId,
        location = { mapSymbol = map or MAP, fieldX = 4, fieldZ = 13, facing = "north" },
        playerData = {
          profile = {
            name = "GOLD",
            gender = 0,
            trainerId = 1,
            money = 3000,
            badges = 0,
            nationalDex = false,
            runningShoes = false,
            runningShoesLock = false,
            rivalName = "Silver",
          },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
        fashionCase = require("libs.hgss.src.save.FashionCaseState").empty(),
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
        mons = require("tests.support.MonBucket").emptyForVersion(versionId, 7),
        bag = require("libs.hgss.src.save.BagSave").empty(),
        mart = require("libs.hgss.src.save.MartSave").empty(),
      }
    end,
  })
end

local function recordingPort(packets)
  return {
    enter = function(_plan)
      return true
    end,
    present = function(packet)
      packets[#packets + 1] = packet
    end,
    ready = function()
      return true
    end,
    leave = function(_plan)
      return true
    end,
    dispose = function() end,
  }
end

local function sleepPacket(packets)
  for _, packet in ipairs(packets) do
    for _, event in ipairs(packet.events) do
      local payload = event.payload
      if event.kind == "status" and type(payload) == "table" and payload.key == "sleep" then
        return packet
      end
    end
  end
  return nil
end

function T.tests.hypnosis_sleep_reaches_the_live_battle_presentation_view()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness():boot({
    versionId = versionId,
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local battle = nil
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local service = game.runtime.monService
    Assert.isTrue(service:giveMon({ species = "GASTLY", level = 20, heldItem = "NONE", form = 0 }))
    service:setMove(0, 0, "HYPNOSIS")

    local CatalogFixture = require("libs.mons.tests.catalog_fixture")
    local enemy = CatalogFixture.makeFactory(0xD03A51E, service:catalog())
      :createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 20 }))
    enemy.moves = { { move = "GROWL", pp = 40, ppUps = 0 } }

    local launch = {
      id = "launch-battle-status-presentation",
      kind = "wild",
      payload = { species = "TOTODILE", level = 20, mon = enemy },
    }
    local scenario = require("libs.hgss.src.battle.HgssBattleScenarioFactory").fromEncounter(launch.payload, {
      party = service,
      player = { trainerId = 99, trainerName = "MINT", language = "french" },
    })
    local packets = {}
    battle = require("game.hgss.src.battle.BattleRuntime").new({
      request = launch,
      scenario = scenario,
      presentation = recordingPort(packets),
      party = service,
      seed = 0xD03A51E,
    })

    local ticks = 0
    while sleepPacket(packets) == nil and battle:status().phase ~= "failed" and ticks < 600 do
      game:step()
      battle:update()
      local current = battle:status()
      if current.phase == "running" and current.request ~= nil then
        local SessionFixture = require("libs.battle.tests.session_fixture")
        local actor = assert(current.request.actors, "the move request names its actor")[1]
        local reply = SessionFixture.replyFor(current.request, {
          SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2)),
        })
        local accepted, replyErr = battle:submit(reply)
        Assert.isTrue(accepted, "the Hypnosis decision is accepted: " .. tostring(replyErr))
      end
      ticks = ticks + 1
    end

    Assert.isTrue(battle:status().phase ~= "failed", "the battle stays live: " .. tostring(battle:status().error))
    local packet = sleepPacket(packets)
    Assert.isTrue(packet ~= nil, "a successful Hypnosis publishes the canonical sleep event")
    local after = packet.after
    local foundSleepingOpponent = false
    for _, combatant in ipairs(assert(after.foes, "the packet carries its detached foe view")) do
      if combatant.condition == "sleep" then
        foundSleepingOpponent = true
      end
    end
    Assert.isTrue(foundSleepingOpponent, "the same production packet projects the foe as asleep")
    Assert.equal(game.trap.attempts, 0, "the acceptance journey stops before GPU rendering")
  end, debug.traceback)
  if battle ~= nil then
    battle:dispose()
  end
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
