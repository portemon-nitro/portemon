-- A native battle ability remains observable through the composed HGSS
-- battle lifetime: entry weather is established and contact retaliation
-- occurs when the foe strikes the party mon.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local MAP = "MAP_NEW_BARK_ELMS_LAB_1F"

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map-data:7", "map-data:61", "map-data:111", "map:7", "map:61", "map:111" },
    tags = { "battle", "ability", "journey" },
  },
  tests = {},
}

local function harness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      return {
        saveId = "save-ability-fidelity",
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

---@param record table presentation event recorder
local function headlessPort(record)
  return {
    enter = function(_plan)
      return true
    end,
    present = function(packet)
      for _, event in ipairs(packet.events) do
        record[#record + 1] = event
      end
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

---@param events table[] battle events delivered by the production presentation port
---@param ability string expected ability identity
---@return boolean
local function sawAbility(events, ability)
  for _, event in ipairs(events) do
    local payload = event.payload
    if type(payload) == "table" and (payload.ability == ability or payload.key == ability) then
      return true
    end
  end
  return false
end

function T.tests.native_entry_and_contact_abilities_reach_the_battle_lifetime()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness():boot({ versionId = versionId, map = MAP, save = "fresh" })
  local battle = nil
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local service = game.runtime.monService
    Assert.isTrue(
      service:giveMon({ species = "CARVANHA", level = 12, heldItem = "NONE", form = 0, ability = "ROUGH_SKIN" }),
      "the party needs a contact retaliation ability"
    )
    service:setMove(0, 0, "TACKLE")

    local catalog = service:catalog()
    local nativeTackle = catalog:move("TACKLE")
    Assert.isTrue(
      nativeTackle.battle.flags.contact,
      "the compiled Tackle facts project the source contact flag into the session"
    )
    local CatalogFixture = require("libs.mons.tests.catalog_fixture")
    local enemy = CatalogFixture.makeFactory(0xD12A11E, catalog)
      :createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 20 }))
    enemy.ability = "DRIZZLE"
    enemy.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }

    local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
    local launch = {
      id = "launch-battle-ability-fidelity",
      kind = "wild",
      payload = { species = "TOTODILE", level = 20, mon = enemy },
    }
    local scenario = ScenarioFactory.fromEncounter(launch.payload, {
      party = service,
      player = { trainerId = 99, trainerName = "MINT", language = "french" },
    })
    local events = {}
    local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
    battle = BattleRuntime.new({
      request = launch,
      scenario = scenario,
      presentation = headlessPort(events),
      party = service,
    })

    local ticks = 0
    while battle:status().phase ~= "failed" and battle:status().phase ~= "complete" and ticks < 300 do
      game:step()
      battle:update()
      local current = battle:status()
      if current.phase == "running" and current.request ~= nil then
        local SessionFixture = require("libs.battle.tests.session_fixture")
        local actors = assert(current.request.actors, "a player request names its actors")
        local choices = {}
        for _, actor in ipairs(actors) do
          choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
        end
        local reply = SessionFixture.replyFor(current.request, choices)
        local accepted, replyErr = battle:submit(reply)
        Assert.isTrue(accepted, "the contact move decision is accepted: " .. tostring(replyErr))
      end
      ticks = ticks + 1
    end

    Assert.isTrue(
      battle:status().phase ~= "failed",
      "the ability journey does not fail: " .. tostring(battle:status().error)
    )
    Assert.isTrue(sawAbility(events, "DRIZZLE"), "the wild entrant establishes rain through its entry ability")
    Assert.isTrue(sawAbility(events, "ROUGH_SKIN"), "the party ability responds when the wild mon makes contact")
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
