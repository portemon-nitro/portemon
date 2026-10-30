-- Production-composed retail field-move script: pressing A on a Route 30 cut
-- tree runs the generated common.field_cut script through the real field
-- scheduler, dialogue host, party and follower services. Answering Yes plays
-- the cut-in and effect cues and hides the tree without a script fault.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local PartyActions = require("libs.hgss.src.field.PartyActions")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local PlayerProgression = require("libs.hgss.src.save.PlayerProgression")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map-data:33",
      "map:33",
      "map-data:48",
      "map:48",
      "map-data:34",
      "map:34",
      "map-data:35",
      "map:35",
      "map-data:67",
      "map:67",
      "map-data:73",
      "map:73",
      "message-bank:23",
      "message-bank:150",
      "audio-bank:152",
      "message-bank:211",
      "audio-bank:702",
      "audio-bank:703",
      "audio-bank:709",
    },
    tags = { "field", "field-move", "acceptance" },
  },
  tests = {},
}

local ROUTE_30_ID = MapCatalog.require("MAP_ROUTE_30").id
local ADJACENT = {
  { facing = "south", dx = 0, dz = -1 },
  { facing = "north", dx = 0, dz = 1 },
  { facing = "east", dx = -1, dz = 0 },
  { facing = "west", dx = 1, dz = 0 },
}

local function withGame(fn)
  local game = AcceptanceHarness.new({
    gameFactory = function(versionId)
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = { mapSymbol = "MAP_ROUTE_30", fieldX = 10, fieldZ = 10, facing = "south" },
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
        mons = require("tests.support.MonBucket").emptyForVersion(versionId),
        bag = require("libs.hgss.src.save.BagSave").empty(),
        mart = require("libs.hgss.src.save.MartSave").empty(),
      }
    end,
  }):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_ROUTE_30",
    save = "fresh",
    fieldOptions = {
      audioHost = "production",
      audioOutput = FakeAudioOutput.new(),
      recordingScriptHosts = true,
    },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "field-move acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The party leader knows Cut (taught through the real HM action) and the
-- Hive Badge is held.
local function equipCut(game)
  local runtime = game.runtime
  local mons = assert(runtime.monService, "live mon service required")
  local bag = assert(runtime.bagService, "live bag service required")
  Assert.isTrue(
    mons:giveMon({ species = "CHIKORITA", level = 5, heldItem = "NONE", form = 0, location = 7 }),
    "setup gift must enter the party"
  )
  Assert.isTrue(bag:add("HM01", 1), "setup must stock the Cut machine")
  local outcome = PartyActions.new({ mons = mons, bag = bag }):commit({
    kind = "teach_move",
    slot = 0,
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
    item = "HM01",
  })
  Assert.equal(outcome.kind, "changed", "HM01 must teach Cut, got " .. tostring(outcome.kind))
  PlayerProgression.new(runtime.playerData.profile):awardBadge("hive")
end

local function cutTree(game)
  for _, event in ipairs(game.runtime.runtimeMap.fieldData.events.objects) do
    if event.scriptId == "common.field_cut" then
      return event
    end
  end
  error("generated Route 30 data has no cut tree", 0)
end

local function standAtTree(game, event)
  local actorId = "map:" .. ROUTE_30_ID .. ":object:" .. event.objectEventId
  local actor = assert(game:actor(actorId), "the source tree actor is present")
  game.runtime.player:setScriptPosition({ fieldX = actor.fieldX, fieldZ = actor.fieldZ + 1 })
  game:step()
  game:face("north")
  return actorId
end

-- Confirms dialogue until the named script ends; a script fault fails the
-- scenario with the fault's own message. The harness stands in for the
-- presentation by finishing the field-move cue each tick, so the blocking
-- cut-in and the polled effect observe the same one-tick completion
-- production reports.
local function pumpCue(game)
  local scheduler = game.runtime.scripts.scheduler
  local cue = scheduler ~= nil and scheduler._services.fieldMoveCue or nil
  if cue ~= nil then
    cue:finishBlockingCue()
    cue:finishEffects()
  end
end

local function runScriptToEnd(game, scriptId, firstEvent)
  for _ = 1, 600 do
    for index = firstEvent + 1, #game:hostEvents().records do
      local event = game:hostEvents().records[index]
      Assert.isTrue(event.name ~= "script.error", scriptId .. " must not fault: " .. tostring(event.payload.message))
      if event.name == "script.ended" and event.payload.scriptId == scriptId then
        return event.payload
      end
    end
    if game:snapshot().dialogue.waiting or game:snapshot().dialogue.modal then
      game.runtime:pressAction()
      game:step()
      pumpCue(game)
      game.runtime:releaseAction()
    else
      game:step()
      pumpCue(game)
    end
  end
  error(scriptId .. " did not end", 0)
end

function T.tests.cut_tree_and_menu_strength_complete_through_the_real_scheduler()
  withGame(function(game)
    -- Pressing A on the Route 30 cut tree runs the generated retail script
    -- through the real scheduler, dialogue host, and party services; both
    -- scenarios launch no battle, so they share one boot with the tree
    -- scenario first (it needs the visible tree).
    equipCut(game)
    local actorId = standAtTree(game, cutTree(game))
    local events = #game:hostEvents().records
    game:pressAction()
    Assert.equal(game:interaction().scriptId, "common.field_cut", "A on the tree runs the retail Cut script")
    local ended = runScriptToEnd(game, "common.field_cut", events)
    Assert.isTrue(ended.completed, "the Cut script completes after Yes")
    local actor = game:actor(actorId)
    Assert.isTrue(actor == nil or actor.visible == false, "the retail script hides the cut tree")
    game:setWorldState({ flag = "FLAG_STRENGTH_ACTIVE" })
    local strengthEvents = #game:hostEvents().records
    game.runtime:_admitFieldAction("pokemon.field_move", { move = "strength", slot = 0 })
    local strengthEnded = runScriptToEnd(game, "common.menu_strength", strengthEvents)
    Assert.isTrue(strengthEnded.completed, "the menu Strength script reports the permission and releases the field")
  end)
end

return T
