-- Native standard-trainer engagement and partner battles through the real
-- field composition: source map objects see the player along their own
-- directional rays, approach, speak and fight through the common trainer
-- script, the Ecruteak candles follow the trainer the field actually
-- engaged, and the Lance partner battle plus the single-opponent
-- heal-on-loss branch run their authored source scenes. Only the audio,
-- fade and clock host boundaries are recorded; maps, actors, scripts and
-- battles stay production-owned, and the render trap stays active.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local CacheFs = require("libs.storage.src.CacheFs")
local GeneratedCacheFixture = require("tests.support.GeneratedCacheFixture")
local EcruteakGym = require("libs.hgss.src.field.gymmick.EcruteakGym")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FinalizedGameFixture = require("tests.support.FinalizedGameFixture")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local SessionFixture = require("libs.battle.tests.session_fixture")

-- Derived closure: the shared field runtime, the audio banks the driven maps
-- and their cutscenes play, every generated map and message bank the scenarios
-- boot, and the outdoor Route 37 physical-cell window (its own and its
-- neighbours' committed and halo cells) the player is placed inside.
local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "audio-bank:705",
      "audio-bank:706",
      "audio-bank:728",
      "audio-bank:736",
      -- Route 37's own cell window reaches one more neighbour record.
      "map:39",
      "map-data:39",
      "map:40",
      "map-data:40",
      -- The source trainer field speech every engaged trainer prints.
      "message-bank:728",
      "message-bank:390",
      "map:41",
      "map-data:41",
      "message-bank:393",
      "map:42",
      "map-data:42",
      "message-bank:394",
      "map:43",
      "map-data:43",
      "message-bank:396",
      "map:44",
      "map-data:44",
      "message-bank:399",
      "map:73",
      "map-data:73",
      "message-bank:556",
      "map:78",
      "map-data:78",
      "message-bank:612",
      "map:113",
      "map-data:113",
      "message-bank:72",
      "field-cell:0-198",
      "field-cell:0-199",
      "field-cell:0-200",
      "field-cell:0-201",
      "field-cell:0-202",
      "field-cell:0-245",
      "field-cell:0-246",
      "field-cell:0-247",
      "field-cell:0-248",
      "field-cell:0-249",
      "field-cell:0-292",
      "field-cell:0-293",
      "field-cell:0-294",
      "field-cell:0-295",
      "field-cell:0-296",
      "field-cell:0-339",
      "field-cell:0-340",
      "field-cell:0-341",
      "field-cell:0-342",
      "field-cell:0-343",
      "field-cell:0-386",
      "field-cell:0-387",
      "field-cell:0-388",
      "field-cell:0-389",
      "field-cell:0-390",
      "map:177",
      "map-data:177",
      "message-bank:91",
      "map:80",
      "map-data:80",
      "message-bank:614",
      "map:248",
      "map-data:248",
      "message-bank:113",
      "map:298",
      "map-data:298",
      "message-bank:131",
    },
    tags = { "field", "script", "battle", "trainer", "acceptance" },
  },
  tests = {},
}

-- include/constants/flags.h::TRAINER_FLAG_BASE: a defeated trainer's own
-- event flag is this offset plus its native trainer number.
local TRAINER_FLAG_BASE = 0x550

local ROUTE_37 = "MAP_ROUTE_37"
local SLOWPOKE_WELL = "MAP_SLOWPOKE_WELL_B1F"
local ECRUTEAK_GYM = "MAP_ECRUTEAK_GYM"
local ROCKET_HQ_B2F = "MAP_TEAM_ROCKET_HEADQUARTERS_B2F"
local TOHJO_HIDDEN_ROOM = "MAP_TOHJO_FALLS_HIDDEN_ROOM"

-- MAP_ROUTE_37's compiled coordinate origin: a finalized new-game location
-- is local to its map's origin, so the scenario states its tiles globally
-- and converts them here.
local ROUTE_37_ORIGIN = { x = 384, z = 192 }

local FOLLOWER_FLAG = FieldScriptSymbols.flagsByName.FLAG_HAVE_FOLLOWER
local FOLLOWER_TRAINER_VAR = FieldScriptSymbols.variablesByName.VAR_FOLLOWER_TRAINER_NUM
local ECRUTEAK_ENTRY_SCENE_VAR = FieldScriptSymbols.variablesByName.VAR_UNK_4079
local HIDEOUT_PROGRESS_VAR = FieldScriptSymbols.variablesByName.VAR_UNK_40AC
local HIDEOUT_STAGE_VAR = FieldScriptSymbols.variablesByName.VAR_UNK_40A9
local HIDEOUT_ARIANA_HIDDEN_FLAG = FieldScriptSymbols.flagsByName.FLAG_HIDE_ROCKET_HIDEOUT_B2F_ARIANA
local TIME_TRAVEL_PROGRESS_VAR = FieldScriptSymbols.variablesByName.VAR_UNK_40FE

-- The source objects this acceptance drives, each named by the map's own
-- event data. Sight geometry and the native trainer number are read back
-- from those records instead of restated here.
local BEAUTY_EAST = { actorId = "map:41:object:7", objectEventId = 7 }
local BEAUTY_WEST = { actorId = "map:41:object:8", objectEventId = 8 }
local TWIN_LEAD = { actorId = "map:41:object:0", objectEventId = 0 }
local TWIN_PARTNER = { actorId = "map:41:object:1", objectEventId = 1 }
local WELL_ROCKET = { actorId = "map:177:object:2", objectEventId = 2 }
local MEDIUM_TRAINER = { actorId = "map:80:object:5", objectEventId = 5 }
local SUNGLASSES_TRAINER = { actorId = "map:80:object:3", objectEventId = 3 }

---@param mapSymbol string
---@param fieldX integer global field X
---@param fieldZ integer global field Z
---@param facing string
---@return table finalized new-game location
local function routeLocation(mapSymbol, fieldX, fieldZ, facing)
  return {
    mapSymbol = mapSymbol,
    fieldX = fieldX - ROUTE_37_ORIGIN.x,
    fieldZ = fieldZ - ROUTE_37_ORIGIN.z,
    facing = facing,
  }
end

---@param mapSymbol string
---@param fieldX integer
---@param fieldZ integer
---@param facing string
---@return table finalized new-game location
local function entryLocation(mapSymbol, fieldX, fieldZ, facing)
  if mapSymbol == ROUTE_37 then
    return routeLocation(mapSymbol, fieldX, fieldZ, facing)
  end
  return { mapSymbol = mapSymbol, fieldX = fieldX, fieldZ = fieldZ, facing = facing }
end

---@param seeds table[]?
---@param follower boolean?
---@return FieldEventState
local function worldStateWith(seeds, follower)
  local worldState = FieldEventState.new()
  for _, seed in ipairs(seeds or {}) do
    if seed.flag ~= nil then
      worldState:setFlag(seed.flag)
    end
    if seed.variable ~= nil then
      worldState:setVar(seed.variable, seed.value)
    end
  end
  if follower == true then
    worldState:setFlag(FOLLOWER_FLAG)
    worldState:setVar(FOLLOWER_TRAINER_VAR, 7)
  end
  return worldState
end

---@param options { map: string, spawn: table, seeds: table[]?, follower: boolean?, entryScene: boolean? }
---@return AcceptanceHarness
local function harness(options)
  return AcceptanceHarness.new({
    gameFactory = function(versionId, requestedMap)
      return FinalizedGameFixture.build(versionId, {
        location = entryLocation(
          requestedMap or options.map,
          options.spawn.fieldX,
          options.spawn.fieldZ,
          options.spawn.facing
        ),
        worldState = worldStateWith(options.seeds, options.follower),
      })
    end,
  })
end

---@param options { map: string, spawn: table, seeds: table[]?, follower: boolean?, entryScene: boolean? }
---@param context table
---@param fn fun(game: table)
local function withGame(options, context, fn)
  if context ~= nil and type(context.hasCapability) == "function" and not context:hasCapability("rom_dump") then
    context:skip("requires rom_dump and prepared derived assets")
  end
  local game = harness(options):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = options.map,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    if options.entryScene ~= true then
      game:waitForFieldReady(480)
    end
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "the trainer acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

---@param game table
---@param objectEventId integer
---@return table the map's own generated object event
local function sourceObject(game, objectEventId)
  for _, object in ipairs(game.runtime.runtimeMap.fieldData.events.objects) do
    if object.objectEventId == objectEventId then
      return object
    end
  end
  error("the map carries no source object event " .. tostring(objectEventId))
end

---@param game table
---@param actorId string
---@return table the actor's own source object event
local function sourceEventOf(game, actorId)
  local actor = assert(game.runtime.actors:getById(actorId), "the source actor is published: " .. actorId)
  return assert(actor.sourceEvent, "the source actor carries its object event")
end

-- include/constants/std_script.h: a trainer object's raw standard-script id
-- names FIRST_TRAINER_INDEX plus its number inside its own std range, and the
-- producer resolves that into the object's own trainer subject because every
-- entry of a trainer group aliases one shared behaviour.
local FIRST_TRAINER_INDEX = 1

---@param object table a source object event the map's own data declares
---@return integer native trainer number
local function trainerNumberOf(object)
  local subject = assert(object.trainer, "a trainer object carries its produced trainer subject")
  local trainerNumber = assert(subject.trainerId, "the trainer subject carries its native identity")
  Assert.isTrue(trainerNumber >= FIRST_TRAINER_INDEX, "a trainer subject names a native trainer")
  return trainerNumber
end

local function trainerFlag(trainer)
  return TRAINER_FLAG_BASE + trainer
end

-- The source's own sight test, stated as the relationship the scenario
-- relies on: the player stands on the trainer object's exact facing row,
-- inside the range that object's own record declares.
local SIGHT_STEPS = {
  north = { x = 0, z = -1 },
  south = { x = 0, z = 1 },
  west = { x = -1, z = 0 },
  east = { x = 1, z = 0 },
}

---@param game table
---@param objectEventId integer
---@param fieldX integer global field X the player occupies
---@param fieldZ integer global field Z the player occupies
---@param label string
local function assertOnSightRay(game, objectEventId, fieldX, fieldZ, label)
  local object = sourceObject(game, objectEventId)
  local step = assert(SIGHT_STEPS[object.facingDirection], "a source trainer faces a cardinal direction")
  local range = assert(object.param0, "a source trainer carries its own sight range")
  local deltaX = fieldX - object.x
  local deltaZ = fieldZ - object.z
  local distance = deltaX * step.x + deltaZ * step.z
  local offAxis = deltaX * step.z - deltaZ * step.x
  Assert.equal(offAxis, 0, label .. ": the player stands on the trainer's own facing row")
  Assert.isTrue(
    distance >= 1 and distance <= range,
    label .. ": the player stands inside the trainer's own sight range"
  )
end

local function activeBattle(game)
  return game.runtime.battleCoordinator:activeBattle()
end

local function faultCount(game)
  return #game:recordsNamed("script.error")
end

---@param game table
---@return string
local function snapshotText(game)
  local snapshot = game:snapshot()
  return string.format(
    "tick=%s map=%s player=(%s,%s) locked=%s foreground=%s dialogue=%s",
    tostring(snapshot.tick),
    tostring(snapshot.mapSymbol),
    tostring(snapshot.player.fieldX),
    tostring(snapshot.player.fieldZ),
    tostring(snapshot.fieldLocked),
    tostring(snapshot.foregroundScript),
    tostring(snapshot.dialogue.modal)
  )
end

-- Foe positions in the source's own position order: the own side opens first,
-- so a single battle strikes position two and a double battle the two foe
-- positions after the own pair. The driver tries them in order until the battle
-- accepts the strike.
local STRIKE_TARGETS = { 2, 3, 4 }

---@param request table pending production decision request
---@return boolean true when the battle offers strikes
local function offersStrike(request)
  local kinds = type(request.legalChoices) == "table" and request.legalChoices.kinds or nil
  for _, kind in ipairs(type(kinds) == "table" and kinds or {}) do
    if kind == "attack" then
      return true
    end
  end
  return false
end

-- Answers the pending request with a legal decision: a strike when the battle
-- offers one, otherwise the neutral acknowledgement (staying on the source's
-- optional shift prompt, which the default battle style opens when an opponent
-- is about to send its next mon in).
---@param battle table
---@return boolean answered true when the pending decision was submitted
local function answerBattle(battle)
  local status = battle:status()
  if status.phase ~= "running" or status.request == nil then
    return false
  end
  local request = status.request
  local actors = assert(request.actors, "battle requests address their actors")
  local strike = offersStrike(request)
  local lastErr = nil
  for _, target in ipairs(strike and STRIKE_TARGETS or { 0 }) do
    local choices = {}
    for _, actor in ipairs(actors) do
      choices[#choices + 1] = strike and SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(target))
        or SessionFixture.confirmChoice(actor)
    end
    local accepted, replyErr = battle:submit(SessionFixture.replyFor(request, choices))
    if accepted then
      return true
    end
    lastErr = replyErr
  end
  Assert.isTrue(false, "the production battle accepts a legal decision: " .. tostring(lastErr))
end

-- One semantic driver for real source scenes: it answers pending battle
-- decisions and printed dialogue, and otherwise advances the fixed tick.
-- It returns as soon as `stop` observes the requested boundary.
---@param game table
---@param label string boundary the scene must reach
---@param budget integer fixed ticks allowed
---@param stop fun(snapshot: table): boolean
---@return table snapshot at the boundary
local function driveUntil(game, label, budget, stop)
  for _ = 1, budget do
    local snapshot = game:snapshot()
    if stop(snapshot) then
      return snapshot
    end
    local battle = activeBattle(game)
    if battle ~= nil then
      answerBattle(battle)
    elseif snapshot.dialogue.modal or game:contextChoiceStatus() ~= nil then
      game:pressAction()
    end
    game:step()
  end
  local faults = {}
  for _, record in ipairs(game:recordsNamed("script.error")) do
    local payload = record.payload or {}
    local context = payload.context or {}
    faults[#faults + 1] = string.format(
      "%s/%s/%s/%s",
      tostring(payload.scriptId),
      tostring(payload.code),
      tostring(context.command or context.originalName or "unknown"),
      tostring(payload.message)
    )
  end
  error(
    "the source scene never reached "
      .. label
      .. "; battle="
      .. tostring(activeBattle(game) ~= nil and activeBattle(game):status().phase or "none")
      .. "; faults="
      .. table.concat(faults, ",")
      .. "; state="
      .. snapshotText(game)
  )
end

---@param game table
---@param label string
---@param budget integer
---@return table snapshot of the released field
local function settleField(game, label, budget)
  return driveUntil(game, label, budget, function(snapshot)
    return activeBattle(game) == nil and not snapshot.fieldLocked and not snapshot.dialogue.modal
  end)
end

---@param game table
---@param label string
---@return table battle status once the field released the battle
local function fightToEnd(game, label)
  driveUntil(game, label, 9000, function()
    return activeBattle(game) == nil
  end)
  return assert(game.runtime.battleCoordinator:lastBattleResult(), "the settled battle published its result")
end

-- A settled battle releases its launching trainer script, whose remaining
-- source commands run on the following fixed ticks: the defeated-trainer flag,
-- the candle and the phone follow-up all land there, not inside the battle
-- settlement itself.
---@param game table
---@param flagId integer the native trainer flag the continuation sets
---@param label string boundary the continuation must reach
local function waitForTrainerFlag(game, flagId, label)
  driveUntil(game, label, 240, function()
    return game.runtime.scripts.worldState:isFlagSet(flagId)
  end)
end

-- A source object event's own event flag, read before boot from the same
-- generated field record the runtime loads.
---@param versionId string
---@param mapSymbol string
---@param objectEventId integer
---@return integer flagId
local function objectEventFlag(versionId, mapSymbol, objectEventId)
  local cacheFs = GeneratedCacheFixture.reader(versionId)
  local mapId = MapCatalog.require(mapSymbol).id
  local field = assert(cacheFs:loadLua(FieldMapDataCache.fieldPath(mapId)), "the map's field record is generated")
  for _, object in ipairs(field.events.objects) do
    if object.objectEventId == objectEventId then
      Assert.isTrue(type(object.eventFlag) == "number" and object.eventFlag > 0, "the source object carries its flag")
      return object.eventFlag
    end
  end
  error("the map carries no source object event " .. tostring(objectEventId))
end

---@param game table
---@param species string
---@param level integer
local function giveMon(game, species, level)
  Assert.isTrue(
    game.runtime.monService:giveMon({ species = species, level = level, heldItem = "NONE", form = 0 }),
    "the party owner accepts its prepared " .. species
  )
end

---@param game table
local function weakenLeadToOneHitPoint(game)
  local mons = game.runtime.monService
  local mon = assert(mons:removeMon(0), "the prepared party lead leaves for its fragile preparation")
  mon.condition.currentHp = 1
  Assert.isTrue(mons:addMon(mon), "the fragile lead returns through the party owner")
end

---@param game table
---@return { party: integer, dragonites: integer }
local function partyFacts(game)
  local mons = game.runtime.monService
  local dragonites = 0
  for slot = 1, mons:partyCount() do
    local mon = mons:partyMon(slot - 1)
    local species = assert(mon and mon.species, "every party member names its species")
    if species == "DRAGONITE" then
      dragonites = dragonites + 1
    end
  end
  return { party = mons:partyCount(), dragonites = dragonites }
end

---@param game table
---@param what string
---@param budget integer fixed ticks to watch
local function assertNoEngagement(game, what, budget)
  for _ = 1, budget do
    Assert.isNil(activeBattle(game), what .. ": no trainer battle may start")
    Assert.isNil(game:snapshot().foregroundScript, what .. ": no trainer script may claim the field")
    game:step()
  end
end

-- ---------------------------------------------------------------------------
-- A source trainer sees the player along its own directional ray: mono
-- engagement, dialogue, battle, the trainer's defeated flag and its silence
-- afterwards.
-- ---------------------------------------------------------------------------

function T.tests.mono_trainer_engages_from_its_source_ray_and_stays_defeated(context)
  local case = { map = ROUTE_37, spawn = { fieldX = 387, fieldZ = 205, facing = "north" } }
  withGame(case, context, function(game)
    giveMon(game, "TYPHLOSION", 100)
    giveMon(game, "QUILAVA", 60)
    local faults = faultCount(game)
    local trainerObject = sourceObject(game, BEAUTY_EAST.objectEventId)
    Assert.equal(trainerObject.type, 1, "the source trainer sees along its own facing")
    local trainerNumber = trainerNumberOf(trainerObject)

    -- One row off the sight line: nothing engages.
    game:face("north")
    assertNoEngagement(game, "a trainer whose ray misses the player", 40)

    -- Step onto the trainer's exact sight row inside its range.
    assertOnSightRay(game, BEAUTY_EAST.objectEventId, 387, 204, "the mono engagement")
    game:moveTo({ fieldX = 387, fieldZ = 204 })
    local engaged = driveUntil(game, "the mono trainer engagement", 900, function(snapshot)
      return activeBattle(game) ~= nil or snapshot.foregroundScript ~= nil
    end)
    Assert.notNil(engaged.foregroundScript, "the trainer's common source script claims the field")
    driveUntil(game, "the trainer's own battle", 2400, function()
      return activeBattle(game) ~= nil
    end)
    local receipt = fightToEnd(game, "the trainer battle settles")
    Assert.equal(receipt.result, "win", "the prepared party wins the source trainer battle")
    Assert.equal(receipt.rewards.battleFormat, "single", "a lone trainer fields a single battle")
    Assert.equal(#receipt.rewards.trainers, 1, "a lone trainer settles exactly one prize share")
    waitForTrainerFlag(
      game,
      trainerFlag(trainerNumber),
      "the source script marks the defeated trainer with its own native flag"
    )
    Assert.isTrue(
      game.runtime.scripts.worldState:isFlagSet(trainerFlag(trainerNumber)),
      "the source script marks the defeated trainer with its own native flag"
    )
    settleField(game, "the defeated trainer's script ends", 2400)
    Assert.equal(faultCount(game), faults, "the trainer's source script runs without faults")

    -- Walking out of and back into the ray never re-engages a defeated trainer.
    -- Off the ray is one tile north of the sight row: the authored south tile
    -- lies across Route 37's ledge, which ordinary walking cannot return from.
    game:moveTo({ fieldX = 387, fieldZ = 203 })
    game:moveTo({ fieldX = 387, fieldZ = 204 })
    assertNoEngagement(game, "an already defeated trainer", 60)
    Assert.notNil(game:actor(BEAUTY_EAST.actorId), "the defeated trainer object stays on its map")
  end)
end

-- ---------------------------------------------------------------------------
-- A source double-battle trainer split across two objects: the native
-- two-usable-mon gate keeps a one-mon party from engaging, and with a second
-- usable mon the same trainer fights once as the native one-trainer double.
-- ---------------------------------------------------------------------------

function T.tests.paired_double_trainer_needs_two_usable_mons_and_settles_one_battle(context)
  local case = { map = ROUTE_37, spawn = { fieldX = 390, fieldZ = 212, facing = "north" } }
  withGame(case, context, function(game)
    giveMon(game, "TYPHLOSION", 100)
    local faults = faultCount(game)
    local lead = sourceObject(game, TWIN_LEAD.objectEventId)
    local partner = sourceObject(game, TWIN_PARTNER.objectEventId)
    Assert.equal(lead.trainer.partner, "first", "the lead object addresses the trainer group's first slot")
    Assert.equal(partner.trainer.partner, "second", "the partner object addresses the trainer group's second slot")
    Assert.equal(trainerNumberOf(partner), trainerNumberOf(lead), "both objects name the same native trainer")
    local trainerNumber = trainerNumberOf(lead)
    assertOnSightRay(game, TWIN_LEAD.objectEventId, 390, 212, "the paired double engagement")

    -- One usable mon: the native gate refuses the double engagement.
    game:face("north")
    assertNoEngagement(game, "a double trainer with a one-mon party", 60)

    -- A second usable mon lets the same actor engage.
    giveMon(game, "QUILAVA", 60)
    local engaged = driveUntil(game, "the paired double engagement", 900, function(snapshot)
      return activeBattle(game) ~= nil or snapshot.foregroundScript ~= nil
    end)
    Assert.notNil(engaged.foregroundScript, "the double trainer's approach script claims the field")
    driveUntil(game, "the double trainer battle", 3000, function()
      return activeBattle(game) ~= nil
    end)
    local receipt = fightToEnd(game, "the double trainer battle settles")
    Assert.equal(receipt.result, "win", "the prepared party wins the paired double battle")
    Assert.equal(receipt.rewards.battleFormat, "double", "a double trainer fields a double battle")
    Assert.equal(
      #receipt.rewards.trainers,
      1,
      "the same native trainer on both objects stays one trainer, not two generated copies"
    )
    waitForTrainerFlag(
      game,
      trainerFlag(trainerNumber),
      "the source script marks the defeated double trainer with its native flag"
    )
    Assert.isTrue(
      game.runtime.scripts.worldState:isFlagSet(trainerFlag(trainerNumber)),
      "the source script marks the defeated double trainer with its native flag"
    )
    settleField(game, "the double trainer's script ends", 3000)
    Assert.equal(faultCount(game), faults, "the double trainer's source script runs without faults")
  end)
end

-- ---------------------------------------------------------------------------
-- Two independent source trainers that both see the player share one native
-- double battle with two distinct opponents.
-- ---------------------------------------------------------------------------

function T.tests.two_independent_trainers_share_one_native_double_battle(context)
  local case = { map = ROUTE_37, spawn = { fieldX = 390, fieldZ = 205, facing = "north" } }
  withGame(case, context, function(game)
    giveMon(game, "TYPHLOSION", 100)
    giveMon(game, "QUILAVA", 60)
    local faults = faultCount(game)
    local eastTrainer = trainerNumberOf(sourceObject(game, BEAUTY_EAST.objectEventId))
    local westTrainer = trainerNumberOf(sourceObject(game, BEAUTY_WEST.objectEventId))
    Assert.isTrue(eastTrainer ~= westTrainer, "the two beauties are independent native trainers")
    assertOnSightRay(game, BEAUTY_EAST.objectEventId, 390, 204, "the first independent trainer")
    assertOnSightRay(game, BEAUTY_WEST.objectEventId, 390, 204, "the second independent trainer")
    game:face("north")
    assertNoEngagement(game, "two trainers whose rays miss the player", 40)

    game:moveTo({ fieldX = 390, fieldZ = 204 })
    local engaged = driveUntil(game, "the two-trainer engagement", 1200, function(snapshot)
      return activeBattle(game) ~= nil or snapshot.foregroundScript ~= nil
    end)
    Assert.notNil(engaged.foregroundScript, "the common approach script claims the field")
    driveUntil(game, "the two-trainer double battle", 3600, function()
      return activeBattle(game) ~= nil
    end)
    local receipt = fightToEnd(game, "the two-trainer battle settles")
    Assert.equal(receipt.result, "win", "the prepared party wins the two-trainer battle")
    Assert.equal(receipt.rewards.battleFormat, "double", "two trainers fight on a doubles field")
    Assert.equal(#receipt.rewards.trainers, 2, "two distinct trainers each settle their own prize share")
    waitForTrainerFlag(game, trainerFlag(eastTrainer), "the first engaged trainer keeps its native defeated flag")
    Assert.isTrue(
      game.runtime.scripts.worldState:isFlagSet(trainerFlag(eastTrainer)),
      "the first engaged trainer keeps its native defeated flag"
    )
    waitForTrainerFlag(game, trainerFlag(westTrainer), "the second engaged trainer keeps its native defeated flag")
    Assert.isTrue(
      game.runtime.scripts.worldState:isFlagSet(trainerFlag(westTrainer)),
      "the second engaged trainer keeps its native defeated flag"
    )
    settleField(game, "the two-trainer script ends", 3600)
    Assert.equal(faultCount(game), faults, "the two-trainer source script runs without faults")
  end)
end

-- ---------------------------------------------------------------------------
-- A source object hidden by its own event flag is not active, so it never
-- engages, while the same actor engages once its flag is clear.
-- ---------------------------------------------------------------------------

function T.tests.hidden_trainer_actors_do_not_engage(context)
  local versionId = AcceptanceHarness.defaultVersion()
  local hiddenFlag = objectEventFlag(versionId, SLOWPOKE_WELL, WELL_ROCKET.objectEventId)

  local visibleCase = { map = SLOWPOKE_WELL, spawn = { fieldX = 28, fieldZ = 9, facing = "west" } }
  withGame(visibleCase, context, function(game)
    giveMon(game, "TYPHLOSION", 100)
    giveMon(game, "QUILAVA", 60)
    local faults = faultCount(game)
    local trainerNumber = trainerNumberOf(sourceObject(game, WELL_ROCKET.objectEventId))
    Assert.notNil(game:actor(WELL_ROCKET.actorId), "the visible source object publishes its actor")
    assertOnSightRay(game, WELL_ROCKET.objectEventId, 28, 9, "the visible rocket")
    game:face("west")
    driveUntil(game, "the visible trainer engagement", 900, function(snapshot)
      return activeBattle(game) ~= nil or snapshot.foregroundScript ~= nil
    end)
    Assert.notNil(game:snapshot().foregroundScript, "the visible trainer runs its source script")
    driveUntil(game, "the visible trainer battle", 2400, function()
      return activeBattle(game) ~= nil
    end)
    local receipt = fightToEnd(game, "the visible trainer battle settles")
    Assert.equal(receipt.result, "win", "the prepared party wins the visible trainer battle")
    waitForTrainerFlag(game, trainerFlag(trainerNumber), "the visible trainer keeps its native defeated flag")
    Assert.isTrue(
      game.runtime.scripts.worldState:isFlagSet(trainerFlag(trainerNumber)),
      "the visible trainer keeps its native defeated flag"
    )
    settleField(game, "the visible trainer's script ends", 2400)
    Assert.equal(faultCount(game), faults, "the visible trainer's source script runs without faults")
  end)

  local hiddenCase = {
    map = SLOWPOKE_WELL,
    spawn = { fieldX = 28, fieldZ = 9, facing = "west" },
    seeds = { { flag = hiddenFlag } },
  }
  withGame(hiddenCase, context, function(game)
    giveMon(game, "TYPHLOSION", 100)
    giveMon(game, "QUILAVA", 60)
    Assert.isNil(game:actor(WELL_ROCKET.actorId), "the hidden source object publishes no actor")
    game:face("west")
    assertNoEngagement(game, "a hidden source trainer", 80)
  end)
end

-- ---------------------------------------------------------------------------
-- Ecruteak's candle follows the trainer the field actually engaged, and the
-- source's own extinguish sequence ends it.
-- ---------------------------------------------------------------------------

---@param game table
---@return boolean[] one flag per source candle: true once the gym settled it extinguished
local function extinguishedCandles(game)
  return game.runtime.gymMechanismState:ecruteakCandles()
end

function T.tests.ecruteak_medium_trainer_binds_and_extinguishes_its_own_candle(context)
  local case = {
    map = ECRUTEAK_GYM,
    spawn = { fieldX = 11, fieldZ = 21, facing = "north" },
    seeds = { { variable = ECRUTEAK_ENTRY_SCENE_VAR, value = 1 } },
  }
  withGame(case, context, function(game)
    giveMon(game, "TYPHLOSION", 100)
    giveMon(game, "QUILAVA", 60)
    local faults = faultCount(game)
    local trainerNumber = trainerNumberOf(sourceObject(game, MEDIUM_TRAINER.objectEventId))
    local medium = game:actor(MEDIUM_TRAINER.actorId)
    Assert.notNil(medium, "the medium trainer stands on the gym floor")
    Assert.equal(medium.fieldX, 11, "the medium trainer stands on its source tile")
    Assert.equal(medium.fieldZ, 19, "the medium trainer stands on its source tile")
    assertOnSightRay(game, MEDIUM_TRAINER.objectEventId, 11, 21, "the medium trainer engagement")
    local candleIndex = assert(
      EcruteakGym.candleIndexForObjectEvent(sourceEventOf(game, MEDIUM_TRAINER.actorId).objectEventId),
      "the medium trainer owns one of the gym's candles"
    )
    for _, extinguished in ipairs(extinguishedCandles(game)) do
      Assert.isFalse(extinguished, "no candle is extinguished before the engagement")
    end

    -- The sight engagement starts the source approach, which walks the
    -- medium trainer toward the player.
    local startZ = medium.fieldZ
    driveUntil(game, "the medium trainer engagement", 1800, function(snapshot)
      local actor = game:actor(MEDIUM_TRAINER.actorId)
      return snapshot.foregroundScript ~= nil and actor ~= nil and actor.fieldZ ~= startZ
    end)
    Assert.isTrue(
      game:actor(MEDIUM_TRAINER.actorId).fieldZ ~= startZ,
      "the engaged medium trainer walks toward the player during its source approach"
    )

    driveUntil(game, "the medium trainer battle", 3600, function()
      return activeBattle(game) ~= nil
    end)
    local receipt = fightToEnd(game, "the medium trainer battle settles")
    Assert.equal(receipt.result, "win", "the prepared party wins the medium trainer battle")
    waitForTrainerFlag(
      game,
      trainerFlag(trainerNumber),
      "the medium trainer's own defeated flag is set after the battle"
    )
    Assert.isTrue(
      game.runtime.scripts.worldState:isFlagSet(trainerFlag(trainerNumber)),
      "the medium trainer's own defeated flag is set after the battle"
    )

    -- The source then extinguishes the candle of the trainer it engaged: the
    -- engaged actor's own candle settles, and no other medium trainer's does.
    driveUntil(game, "the source candle extinguish", 3600, function()
      local actor = game:actor(MEDIUM_TRAINER.actorId)
      return extinguishedCandles(game)[candleIndex] == true
        and actor ~= nil
        and actor.spriteId == EcruteakGym.EXTINGUISHED_SPRITE_ID
    end)
    local candles = extinguishedCandles(game)
    for index, extinguished in ipairs(candles) do
      if index == candleIndex then
        Assert.isTrue(extinguished, "the engaged trainer's own candle is the extinguished one")
      else
        Assert.isFalse(extinguished, "a medium trainer the field did not engage keeps its candle")
      end
    end
    Assert.equal(
      game:actor(MEDIUM_TRAINER.actorId).spriteId,
      EcruteakGym.EXTINGUISHED_SPRITE_ID,
      "the extinguished trainer wears the source's burnt sprite"
    )
    settleField(game, "the gym interaction ends", 2400)
    Assert.equal(faultCount(game), faults, "the gym trainer's source script runs without faults")
  end)
end

-- ---------------------------------------------------------------------------
-- Talking to a trainer re-reads its live movement and turns the actor toward
-- the player before the source battle starts.
-- ---------------------------------------------------------------------------

function T.tests.trainer_talk_turns_the_actor_toward_the_player(context)
  local case = {
    map = ECRUTEAK_GYM,
    spawn = { fieldX = 20, fieldZ = 30, facing = "west" },
    seeds = { { variable = ECRUTEAK_ENTRY_SCENE_VAR, value = 1 } },
  }
  withGame(case, context, function(game)
    giveMon(game, "TYPHLOSION", 100)
    giveMon(game, "QUILAVA", 60)
    local faults = faultCount(game)
    local trainerNumber = trainerNumberOf(sourceObject(game, SUNGLASSES_TRAINER.objectEventId))
    local before = game:actor(SUNGLASSES_TRAINER.actorId)
    Assert.notNil(before, "the sunglasses trainer stands on the gym floor")
    Assert.equal(before.facing, "south", "the trainer's source object faces south before the talk")

    game:face("west")
    game:pressAction()
    local interaction = game:interaction()
    Assert.equal(interaction.kind, "object", "the faced tile holds the source trainer")
    Assert.equal(interaction.actorId, SUNGLASSES_TRAINER.actorId, "the interaction names the source trainer")
    Assert.notNil(interaction.scriptId, "the trainer's common source script is composed for the interaction")

    driveUntil(game, "the trainer turning toward the player", 2400, function()
      local actor = game:actor(SUNGLASSES_TRAINER.actorId)
      return actor ~= nil and actor.facing == "east"
    end)
    Assert.equal(
      game:actor(SUNGLASSES_TRAINER.actorId).facing,
      "east",
      "the talk rewrites the trainer's live movement through the source command"
    )
    Assert.equal(
      sourceEventOf(game, SUNGLASSES_TRAINER.actorId).facingDirection,
      "south",
      "the trainer's own object event keeps its authored facing"
    )

    driveUntil(game, "the talked-to trainer's battle", 3600, function()
      return activeBattle(game) ~= nil
    end)
    local receipt = fightToEnd(game, "the talked-to trainer's battle settles")
    Assert.equal(receipt.result, "win", "the prepared party wins the talked-to trainer's battle")
    waitForTrainerFlag(game, trainerFlag(trainerNumber), "the talked-to trainer keeps its own defeated flag")
    Assert.isTrue(
      game.runtime.scripts.worldState:isFlagSet(trainerFlag(trainerNumber)),
      "the talked-to trainer keeps its own defeated flag"
    )
    settleField(game, "the talked-to trainer's script ends", 2400)
    Assert.equal(faultCount(game), faults, "the talked-to trainer's source script runs without faults")
  end)
end

-- ---------------------------------------------------------------------------
-- The rocket hideout's partner scene: Lance fights beside the player without
-- ever joining the saved party.
-- ---------------------------------------------------------------------------

function T.tests.lance_fights_beside_the_player_without_joining_the_party(context)
  local case = {
    map = ROCKET_HQ_B2F,
    spawn = { fieldX = 30, fieldZ = 21, facing = "north" },
    follower = true,
    seeds = {
      { variable = HIDEOUT_STAGE_VAR, value = 1 },
      { variable = HIDEOUT_PROGRESS_VAR, value = 8 },
    },
  }
  withGame(case, context, function(game)
    giveMon(game, "TYPHLOSION", 100)
    giveMon(game, "QUILAVA", 60)
    local before = partyFacts(game)
    local faults = faultCount(game)

    -- The scene starts from the hideout's own coordinate event gate; the
    -- chapter stage seed keeps the arrival scene from claiming the field
    -- first, so the journey runs the partner beat itself.
    game:moveTo({ fieldX = 30, fieldZ = 19 })
    local launched = driveUntil(game, "the partner battle launch", 9000, function()
      return activeBattle(game) ~= nil
    end)
    Assert.notNil(launched, "the source scene reaches its partner battle")

    -- The player commands one battler: the ally fights on the same side
    -- under its own controller instead of becoming a second own monster.
    driveUntil(game, "the partner battle's first decision", 1800, function()
      local battle = activeBattle(game)
      return battle ~= nil and battle:status().request ~= nil
    end)
    local decision = assert(activeBattle(game)):status().request
    Assert.equal(
      #assert(decision.actors, "decisions address their actors"),
      1,
      "a partner battle leaves the ally to its own controller"
    )

    local receipt = fightToEnd(game, "the partner battle settles")
    Assert.equal(receipt.result, "win", "the prepared party wins the partner battle")
    Assert.equal(receipt.rewards.battleFormat, "double", "the partner battle fights as a double battle")
    Assert.equal(
      #receipt.rewards.trainers,
      2,
      "Ariana and Grunt are two distinct defeated opponents in the partner battle"
    )

    local after = partyFacts(game)
    Assert.equal(after.party, before.party, "no partner trainer joins the saved party")
    Assert.equal(after.dragonites, before.dragonites, "the ally's Dragonite never becomes a party member")
    driveUntil(game, "the authored win branch hides Ariana", 6000, function()
      return game.runtime.scripts.worldState:isFlagSet(HIDEOUT_ARIANA_HIDDEN_FLAG)
    end)
    waitForTrainerFlag(game, HIDEOUT_ARIANA_HIDDEN_FLAG, "the source scene continues on its authored win branch")
    Assert.isTrue(
      game.runtime.scripts.worldState:isFlagSet(HIDEOUT_ARIANA_HIDDEN_FLAG),
      "the source scene continues on its authored win branch"
    )
    Assert.equal(faultCount(game), faults, "the partner scene runs without new script faults")
  end)
end

-- ---------------------------------------------------------------------------
-- The single-opponent heal-on-loss byte: losing the authored Giovanni battle
-- heals the party and leaves the field under the script's own continuation.
-- ---------------------------------------------------------------------------

function T.tests.single_opponent_heal_on_loss_restores_party_and_field(context)
  local case = {
    map = TOHJO_HIDDEN_ROOM,
    spawn = { fieldX = 6, fieldZ = 9, facing = "north" },
    follower = true,
    entryScene = true,
    seeds = { { variable = TIME_TRAVEL_PROGRESS_VAR, value = 2 } },
  }
  withGame(case, context, function(game)
    giveMon(game, "CHIKORITA", 5)
    weakenLeadToOneHitPoint(game)
    Assert.equal(
      assert(game.runtime.monService:partyMon(0)).condition.currentHp,
      1,
      "the scenario starts from a one-hit-point lead"
    )

    driveUntil(game, "the authored Giovanni battle", 12000, function()
      return activeBattle(game) ~= nil
    end)
    local receipt = fightToEnd(game, "the authored Giovanni battle settles")
    Assert.equal(receipt.result, "loss", "the one-hit-point party loses the authored battle")

    local healed = assert(game.runtime.monService:partyMon(0), "the party lead returns from the battle")
    -- Maximum health is derived from the mon and its species record, so the
    -- healed state is the same fact the battle reads: full current health.
    local MonStats = require("libs.mons.src.gen4.MonStats")
    local maxHp = MonStats.derive(healed, game.runtime.monService:catalog()).maxHp
    Assert.equal(healed.condition.currentHp, maxHp, "the single-opponent heal byte restores the published party")
    Assert.equal(
      game:snapshot().mapSymbol,
      TOHJO_HIDDEN_ROOM,
      "the healed loss keeps the field where the source script continues"
    )
    Assert.equal(
      game.runtime.scripts.worldState:getVar(TIME_TRAVEL_PROGRESS_VAR),
      3,
      "the authored non-win continuation runs instead of the win branch"
    )
  end)
end

return T
