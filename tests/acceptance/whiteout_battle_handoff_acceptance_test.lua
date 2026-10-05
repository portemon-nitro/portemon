-- Retail trainer loss reaches the blocking whiteout recovery path.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local MonBucket = require("tests.support.MonBucket")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = {
      "field-runtime",
      "map-data:7",
      "map:7",
      "map-data:61",
      "map:61",
      "map-data:63",
      "map:63",
      "map-data:69",
      "map:69",
      "message-bank:40",
      "message-bank:126",
      "message-bank:552",
      "message-bank:203",
      "audio-bank:702",
      "encounters:global",
      "trainers:global",
    },
    tags = { "field", "battle", "whiteout", "acceptance" },
  },
  tests = {},
}

local MOTHER_MAP = "MAP_NEW_BARK_ELMS_LAB_1F"
local MOTHER_RECOVERY_MAP = "MAP_NEW_BARK_PLAYER_HOUSE_1F"
local CENTER_MAP = "MAP_CHERRYGROVE_POKECENTER_1F"
local LOSS_SCRIPT = "vanilla.hgss.scr_seq.0107.script_000"
local SPAWN_NEW_BARK = "SPAWN_NEW_BARK"
local SPAWN_CHERRYGROVE = "SPAWN_CHERRYGROVE"
local FLAG_HAVE_FOLLOWER = FieldScriptSymbols.flagsByName.FLAG_HAVE_FOLLOWER
local VAR_FOLLOWER_TRAINER_NUM = FieldScriptSymbols.variablesByName.VAR_FOLLOWER_TRAINER_NUM

local function harness(spawnKey, map, textSpeed)
  return AcceptanceHarness.new({
    gameFactory = function(versionId)
      local worldState = FieldEventState.new()
      worldState:setFlag(FLAG_HAVE_FOLLOWER)
      worldState:setVar(VAR_FOLLOWER_TRAINER_NUM, 7)
      if map == CENTER_MAP then
        worldState:setFlag(789)
      end
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = { mapSymbol = map, fieldX = 4, fieldZ = 13, facing = "north" },
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0 },
          options = { textSpeed = textSpeed or "fastest", textFrame = 0 },
        },
        fieldTravel = { lastHealSpawn = spawnKey },
        playTime = PlayTime.new(),
        worldState = worldState,
        mons = MonBucket.emptyForVersion(versionId),
        bag = require("libs.hgss.src.save.BagSave").empty(),
      }
    end,
  })
end

local function prepareCertainLoss(game)
  local mons = game.runtime.monService
  mons:createStarter("CHIKORITA", {
    location = game.runtime.runtimeMap.mapId,
    date = { year = 2000, month = 1, day = 1 },
  })
  local mon = assert(mons:removeMon(0), "the test party contains its prepared lead")
  mon.condition.currentHp = 1
  Assert.isTrue(mons:addMon(mon), "the one-HP lead returns through the party owner")
end

local function advanceRetailLoss(game, observeStaticBlackout)
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local ticks = 0
  local battleResult = nil
  local scriptCompletion = nil
  local messageFadeBoundaryPending = false
  local tickLimit = observeStaticBlackout and 8000 or 1600
  while ticks < tickLimit and scriptCompletion == nil and game.runtime.errorText == nil do
    local blackout = game.runtime.blackoutFlow:status()
    if observeStaticBlackout and messageFadeBoundaryPending then
      Assert.equal(
        blackout.phase,
        "message_wait",
        "blackout reaches its input gate on the tick after the white fade completes"
      )
      messageFadeBoundaryPending = false
    end
    if
      observeStaticBlackout
      and (blackout.phase == "message_in" or blackout.phase == "message_wait" or blackout.phase == "message_out")
    then
      Assert.notNil(blackout.message, "blackout retains the complete formatted recovery message")
      Assert.isFalse(game:snapshot().dialogue.modal, "blackout presentation does not open the normal dialogue modal")
    end
    local messageFadeCompletesThisTick = observeStaticBlackout
      and blackout.phase == "message_in"
      and blackout.coverAlpha == 0
    local battle = game.runtime.battleRuntime
    if battle ~= nil then
      local status = battle:status()
      if status.phase == "running" and status.request ~= nil then
        local request = status.request
        local choices = {}
        for _, actor in ipairs(assert(request.actors, "player requests address their actors")) do
          choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
        end
        local accepted, replyErr = battle:submit(SessionFixture.replyFor(request, choices))
        Assert.isTrue(accepted, "the production battle accepts a legal move: " .. tostring(replyErr))
      end
      battleResult = battleResult or status.result
    elseif observeStaticBlackout and blackout.phase == "message_in" then
      -- Let the source fade advance without accelerating a normal printer.
    elseif game:snapshot().dialogue.modal then
      game:pressAction()
    else
      -- Repeated semantic confirm edges advance only a foreground prompt or
      -- the retail blackout input gate; the source fades remain tick-owned.
      game:pressAction()
    end
    game:step()
    ticks = ticks + 1
    if messageFadeCompletesThisTick then
      local nextBlackout = game.runtime.blackoutFlow:status()
      Assert.equal(nextBlackout.phase, "message_wait", "the completed fade alone advances blackout to its input gate")
      messageFadeBoundaryPending = true
    end
    for _, record in ipairs(game:recordsNamed("script.ended")) do
      if record.payload.scriptId == LOSS_SCRIPT then
        scriptCompletion = record.payload
      end
    end
    if scriptCompletion ~= nil then
      break
    end
  end
  return {
    ticks = ticks,
    battleResult = battleResult,
    scriptCompletion = scriptCompletion,
    runtimeError = game.runtime.errorText,
    scriptErrors = game:recordsNamed("script.error"),
  }
end

local function beginLossRecovery(spawnKey, map, textSpeed)
  local game = harness(spawnKey, map, textSpeed):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = map,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  game:waitForFieldEntry()
  prepareCertainLoss(game)
  game:startScript(LOSS_SCRIPT)
  return game
end

local function childStarted(game, scriptId)
  for _, record in ipairs(game:recordsNamed("script.started")) do
    if record.payload.scriptId == scriptId then
      return true
    end
  end
  return false
end

local function scriptErrorSummary(records)
  local messages = {}
  for _, record in ipairs(records) do
    local payload = record.payload
    local requestId = payload.context and payload.context.requestId
    messages[#messages + 1] = tostring(payload.scriptId)
      .. "/"
      .. tostring(payload.code)
      .. "["
      .. tostring(requestId)
      .. "]: "
      .. tostring(payload.message)
  end
  return table.concat(messages, " | ")
end

function T.tests.retail_static_battle_loss_recovers_at_mother_spawn_and_runs_std_2012()
  local game = beginLossRecovery(SPAWN_NEW_BARK, MOTHER_MAP, "slow")
  local ok, err = xpcall(function()
    local result = advanceRetailLoss(game, true)
    Assert.equal(
      result.battleResult,
      "loss",
      "the retail trainer battle reaches its loss path after "
        .. result.ticks
        .. " ticks; runtimeError="
        .. tostring(result.runtimeError)
    )
    Assert.isTrue(
      type(result.scriptCompletion) == "table" and result.scriptCompletion.completed == true,
      "the retail loss script completes only after blocking whiteout and std 2012; reason="
        .. tostring(type(result.scriptCompletion) == "table" and result.scriptCompletion.reason)
        .. "; runtimeError="
        .. tostring(result.runtimeError)
        .. "; scriptErrors="
        .. scriptErrorSummary(result.scriptErrors)
    )
    Assert.isNil(game.runtime.errorText, "mother recovery completes without a field or script fault")
    Assert.equal(
      game:snapshot().mapSymbol,
      MOTHER_RECOVERY_MAP,
      "mother recovery returns to the player house death destination"
    )
    Assert.isTrue(childStarted(game, "common.whited_out_to_mom"), "mother recovery queues canonical common std 2012")
    Assert.isFalse(
      game.runtime.scripts.worldState:isFlagSet(FLAG_HAVE_FOLLOWER),
      "blackout clears the retail trainer escort flag"
    )
    Assert.equal(
      game.runtime.scripts.worldState:getVar(VAR_FOLLOWER_TRAINER_NUM),
      0,
      "blackout clears the retail escort trainer variable"
    )
    local partyMon = game.runtime.monService:partyMon(0)
    Assert.notNil(partyMon, "the party remains available after recovery")
    local current = assert(partyMon).condition.currentHp
    Assert.isTrue(current > 0, "the production whiteout path revives the lead")
    Assert.equal(game:renderAttempts(), 0, "the recovery journey stops before GPU rendering")
  end, debug.traceback)
  local namespace = game.saveNamespace
  game:close()
  if not ok then
    error(err, 0)
  end
  Assert.isNil(love.filesystem.getInfo(namespace), "teardown removes the isolated save namespace")
end

function T.tests.non_mother_loss_uses_blackout_destination_separate_from_teleport()
  local game = beginLossRecovery(SPAWN_CHERRYGROVE, CENTER_MAP)
  local ok, err = xpcall(function()
    local CacheFs = require("libs.storage.src.CacheFs")
    local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
    local cache = CacheFs.forVersion(AcceptanceHarness.defaultVersion())
    local index = assert(cache:loadLua(FieldMapDataCache.spawnIndexPath()))
    Assert.isTrue(type(index.spawns) == "table", "the generated cache publishes all outdoor destinations")
    Assert.isTrue(
      type(index.blackoutSpawns) == "table",
      "the generated cache publishes its separate blackout destination namespace"
    )
    local outdoorCount, blackoutCount = 0, 0
    for _ in pairs(index.spawns) do
      outdoorCount = outdoorCount + 1
    end
    for _ in pairs(index.blackoutSpawns) do
      blackoutCount = blackoutCount + 1
    end
    Assert.equal(blackoutCount, outdoorCount, "all outdoor spawn keys have a blackout record")
    for spawnKey in pairs(index.spawns) do
      local blackout = assert(FieldMapDataCache.blackoutDestination(cache, spawnKey))
      local outdoor = assert(FieldMapDataCache.spawnDestination(cache, spawnKey))
      Assert.isTrue(type(blackout.map) == "string", spawnKey .. " blackout destination has a map symbol")
      Assert.isTrue(type(outdoor.map) == "string", spawnKey .. " outdoor destination has a map symbol")
      Assert.notNil(blackout.fieldX, spawnKey .. " blackout destination has local x")
      Assert.notNil(blackout.fieldZ, spawnKey .. " blackout destination has local z")
    end
    Assert.isTrue(
      type(FieldMapDataCache.blackoutDestination) == "function",
      "generated field map data exposes its distinct retail death destination"
    )
    local blackout = assert(FieldMapDataCache.blackoutDestination(cache, SPAWN_CHERRYGROVE))
    local outdoor = assert(FieldMapDataCache.spawnDestination(cache, SPAWN_CHERRYGROVE))
    Assert.isFalse(blackout.map == outdoor.map, "blackout and Teleport resolve different maps")
    Assert.equal(blackout.fieldX, 8, "Cherrygrove blackout uses the source interior x coordinate")
    Assert.equal(blackout.fieldZ, 13, "Cherrygrove blackout uses the source interior z coordinate")
    Assert.equal(blackout.facing, "north", "Cherrygrove blackout uses the source north facing")

    local result = advanceRetailLoss(game)
    Assert.equal(result.battleResult, "loss", "the real trainer loss reaches OverworldWhiteOut recovery")
    Assert.isTrue(
      type(result.scriptCompletion) == "table" and result.scriptCompletion.completed == true,
      "non-mother recovery waits for the canonical std 2013 child; reason="
        .. tostring(type(result.scriptCompletion) == "table" and result.scriptCompletion.reason)
        .. "; runtimeError="
        .. tostring(result.runtimeError)
        .. "; scriptErrors="
        .. scriptErrorSummary(result.scriptErrors)
    )
    Assert.isNil(game.runtime.errorText, "non-mother recovery completes without a runtime fault")
    Assert.equal(game:snapshot().mapSymbol, blackout.map, "the live field lands at the interior death map")
    Assert.equal(game:snapshot().player.fieldX, blackout.fieldX, "whiteout commits the local death x coordinate")
    Assert.equal(game:snapshot().player.fieldZ, blackout.fieldZ, "whiteout commits the local death z coordinate")
    Assert.isTrue(
      childStarted(game, "common.whited_out_to_pokecenter"),
      "non-mother recovery queues canonical common std 2013"
    )
    Assert.equal(game:renderAttempts(), 0, "the recovery journey stops before GPU rendering")
  end, debug.traceback)
  local namespace = game.saveNamespace
  game:close()
  if not ok then
    error(err, 0)
  end
  Assert.isNil(love.filesystem.getInfo(namespace), "teardown removes the isolated save namespace")
end

return T
