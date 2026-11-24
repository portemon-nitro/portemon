-- Egg hatching through the production field. The committed walking step that
-- ends an egg's last cycle claims that step before any other step effect, runs
-- the source hatch scene (its own message and fades, the egg shakes and the
-- burst, the cry, the fanfare and the nickname question), reconstructs the
-- hatched mon with the identity the egg carried, publishes the source meeting
-- memo, the Dex receipt and the hatch statistics once, and keeps the field
-- unsavable until the child application closes. The same field runs the
-- original Togepi gift from Elm's assistant and the Elm call that the matured
-- gift raises.
--
-- The party, the Day Care state, the encounter counters, the statistics and the
-- Dex are canonical saved owners, so the scenarios Continue the real runtime
-- from a prepared game record instead of replaying hundreds of identical
-- steps; the egg cycle ownership itself is proven by the breeding suite. Only
-- audio, screen fades, the wall clock and the save root are host boundaries;
-- maps, scripts, actors, the field save gate and every owning domain stay
-- production-owned, and the render trap stays active throughout.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local DaycareState = require("libs.hgss.src.save.DaycareState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FinalizedGameFixture = require("tests.support.FinalizedGameFixture")
local LocalClock = require("game.src.LocalClock")
local Mon = require("libs.mons.src.Mon")
local Personality = require("libs.mons.src.gen4.Personality")
local U32 = require("libs.codec.src.U32")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map:331",
      "map-data:331",
      "map:157",
      "map-data:157",
      -- The Day Care room's own banks (the custody suite establishes the
      -- first two), the standard hatch script's bank and the Violet Poké Mart
      -- assistant's bank.
      "message-bank:384",
      "message-bank:435",
      "message-bank:439",
      "message-bank:40",
      "message-bank:557",
    },
    tags = { "field", "script", "daycare", "mons", "hatch" },
  },
  tests = {},
}

local DAYCARE_MAP = "MAP_ROUTE_34_DAYCARE"
-- The room's open floor tile, the same approach the custody and breeding
-- suites walk from.
local DAYCARE_TILE = { fieldX = 3, fieldZ = 7 }
-- include/constants/std_script.h: std_hatch_egg 2021 is the standard-bank
-- hatch script the field starts when an egg finishes its last cycle.
local HATCH_SCRIPT = "common.hatch_egg"
-- The hatch script's own bank/message (vanilla scr_seq 0003 script 021).
local HATCH_MESSAGE_BANK = 40
local HATCH_MESSAGE_ID = 62
-- CALL_TRIGGER_ELM_EGG_HATCHED (include/constants/phone_constants.h).
local ELM_EGG_TRIGGER = "gear.trigger.0"
local HATCHED_FLAG = FieldScriptSymbols.flagsByName.FLAG_SYS_HATCHED_TOGEPI_EGG
-- SCORE_EVENT_HATCHED_EGG is source event 15; sScoreMods[15] awards seven
-- points (src/game_stats.c).
local HATCH_SCORE = 7
-- Daycare_GetEggCycleLength: an ordinary date is not on the source
-- special-date list, so the cycle is 255 steps.
local CYCLE_LENGTH = 255
local ORDINARY_DATE = { year = 2000, month = 1, day = 1, hour = 12, minute = 0, second = 0 }
-- Source hatch-scene sound effects (romdump/src/catalog/hgss/sndseq.lua).
local EGG_SHAKE_SE = "audio:SEQ_SE_DP_EGG01"
local EGG_BURST_SE = "audio:SEQ_SE_DP_BOWA3"
local HATCH_MUSIC = "music:SEQ_GS_SHINKA"
local HATCH_FANFARE = "fanfare:SEQ_ME_SHINKAOME"
local MANAPHY_SE = {
  "audio:SEQ_SE_DP_W278",
  "audio:SEQ_SE_DP_W080C",
  "audio:SEQ_SE_DP_W361",
}
local HIGH_IVS = { hp = 31, attack = 30, defense = 29, speed = 28, specialAttack = 27, specialDefense = 26 }

-- The Violet Poké Mart's assistant object (map 157, object 4) is hidden by
-- this story flag until the gift scene; the field answers him north of the
-- counter tile the scenario stands on.
local MART_MAP = "MAP_VIOLET_POKEMART"
local MART_TILE = { fieldX = 6, fieldZ = 9 }
local AIDE_SCRIPT = "vanilla.hgss.scr_seq.0858.script_002"
-- msg_0557_T22FS0101: 2/3 the opening gender pair, 4 the receipt, 5/6 the
-- follow-up pair, 7 the refusal of a full party.
local AIDE_MESSAGE_OPEN = 2
local AIDE_MESSAGE_RECEIPT = 4
local AIDE_MESSAGE_FOLLOW_UP = 5
local AIDE_MESSAGE_FULL_PARTY = 7
local AIDE_FANFARE = "fanfare:SEQ_ME_TAMAGO_GET"
local AIDE_HIDE_FLAG = FieldScriptSymbols.flagsByName.FLAG_HIDE_VIOLET_SHOP_LAB_AIDE
local AIDE_GIFT_FLAG = FieldScriptSymbols.flagsByName.FLAG_GOT_EGG_FROM_ELMS_ASSISTANT
-- METLOC_DAY_CARE_COUPLE (2000) is the Day Care receipt base; the Ranger
-- species egg location is METLOC_POKEMON_RANGER (3001).
local DAYCARE_LOCATION_OFFSET = 14
local RANGER_LOCATION_OFFSET = 1001

---@param value unknown
---@return unknown
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copy(item)
  end
  return out
end

---@param game table
---@param scriptId string
---@return string[] the named script's own published faults
local function scriptFaults(game, scriptId)
  local list = {}
  for _, record in ipairs(game:recordsForScript(scriptId, "script.error")) do
    local payload = record.payload or {}
    local context = payload.context or {}
    list[#list + 1] = string.format(
      "%s/%s/%s",
      tostring(payload.code),
      tostring(context.command or context.originalName or "unknown"),
      tostring(payload.message)
    )
  end
  return list
end

---@param game table
---@return string[] every published script fault
local function faults(game)
  local list = {}
  for _, record in ipairs(game:recordsNamed("script.error")) do
    local payload = record.payload or {}
    local context = payload.context or {}
    list[#list + 1] = string.format(
      "%s/%s/%s/%s",
      tostring(payload.scriptId),
      tostring(payload.code),
      tostring(context.command or context.originalName or "unknown"),
      tostring(payload.message)
    )
  end
  return list
end

local function pressAction(game)
  game.runtime:pressAction()
  game:step()
  game.runtime:releaseAction()
end

local function pressCancel(game)
  game.runtime:pressCancel()
  game:step()
  game.runtime:releaseCancel()
end

local function pressDirection(game, direction)
  game.runtime:press(direction)
  game:step()
  game.runtime:release(direction)
end

---@param game table
---@param label string
---@return table the settled captured game save
local function settledCapture(game, label)
  local lastError = nil
  for _ = 1, 480 do
    local ok, record, reason = pcall(game.runtime.captureGameSave, game.runtime)
    if ok and record ~= nil then
      return record
    end
    lastError = ok and tostring(reason or "capture returned no record") or tostring(record)
    game:step()
  end
  error("the settled field never accepted its save: " .. label .. "; last failure: " .. tostring(lastError), 0)
end

---@param game table
---@return string? the reason the live field refuses its save
local function deniedSaveReason(game)
  local record, reason = game.runtime:captureGameSave()
  if record ~= nil then
    return nil
  end
  return tostring(reason or "capture returned no record")
end

---@param game table
---@return table the live mon service
local function mons(game)
  return assert(game.runtime.monService, "the field runtime owns its mon service")
end

---@param game table
---@return MonCatalog the catalog behind the live service
local function catalog(game)
  return assert(mons(game):catalog(), "the mon service owns the validated catalog")
end

---@param game table
---@param slot0 integer
---@param change fun(mon: table)
local function stageMon(game, slot0, change)
  local service = mons(game)
  local mon = service:partyMon(slot0)
  change(mon)
  -- Staged individual values change the derived maximum, so the record keeps
  -- its own derived full health instead of the health the creation draw left.
  mon.condition = { currentHp = service:derive(mon).maxHp, effects = {} }
  local preparation, reason = service:preparePartyChanges(service:partyRevision(), { { slot = slot0, mon = mon } })
  Assert.isNil(reason, "the prepared party change stages cleanly")
  assert(preparation).publish()
end

---@param withDate table
---@return table a recording clock host boundary
local function clockAt(withDate)
  return LocalClock.new(function()
    return copy(withDate)
  end)
end

---@param envelope table a production-captured game record
---@param clock table?
---@return table acceptance game continuing from the record
local function bootContinue(envelope, clock)
  local harness = AcceptanceHarness.new({
    gameFactory = function()
      return copy(envelope)
    end,
  })
  local fieldOptions = { recordingScriptHosts = true, audioHost = "recording" }
  if clock ~= nil then
    fieldOptions.localClock = clock
  end
  local game = harness:boot({
    versionId = envelope.versionId or AcceptanceHarness.defaultVersion(),
    save = "continue",
    fieldOptions = fieldOptions,
  })
  Assert.isTrue(game.runtime.savePublished, "the scenario continues from its own saved record")
  game:waitForFieldEntry()
  return game
end

---@param map string
---@param location { fieldX: integer, fieldZ: integer }
---@param withDate table?
---@return table acceptance game standing on a fresh finalized field
local function bootFresh(map, location, withDate)
  local harness = AcceptanceHarness.new({
    gameFactory = function(versionId, _)
      return FinalizedGameFixture.build(versionId, {
        location = { mapSymbol = map, fieldX = location.fieldX, fieldZ = location.fieldZ, facing = "north" },
      })
    end,
  })
  local fieldOptions = { recordingScriptHosts = true, audioHost = "recording" }
  if withDate ~= nil then
    fieldOptions.localClock = clockAt(withDate)
  end
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = map,
    save = "fresh",
    fieldOptions = fieldOptions,
  })
  game:waitForFieldEntry()
  return game
end

---@class EggSpec
---@field species string
---@field locationOffset integer
---@field change fun(mon: table)

-- Creates the requested eggs through the production mon service on the Day
-- Care room floor and answers the captured game record, so the hatch scenarios
-- start from the exact party an earlier play session would have saved.
---@param specs EggSpec[]
---@return table the captured game record
local function stagedEggRecord(specs)
  local game = bootFresh(DAYCARE_MAP, DAYCARE_TILE, ORDINARY_DATE)
  local record = nil
  local ok, err = xpcall(function()
    for index, spec in ipairs(specs) do
      Assert.isTrue(
        mons(game):giveEgg({ species = spec.species, locationOffset = spec.locationOffset }),
        "the party accepts the staged " .. spec.species .. " egg"
      )
      stageMon(game, index - 1, spec.change)
    end
    record = settledCapture(game, "the staged eggs")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
  return record
end

---@param record table the prepared game record
---@param eggCycleCounter integer
---@param repelSteps integer
---@return table the prepared game record
local function withHatchProgress(record, eggCycleCounter, repelSteps)
  record.daycare.eggCycleCounter = eggCycleCounter
  local encounters = assert(record.encounters, "a saved game carries its encounter bucket")
  encounters.repelSteps = repelSteps or 0
  return record
end

---@param mon table
---@return string[] the move keys in slot order
local function moveKeys(mon)
  local keys = {}
  for index, entry in ipairs(mon.moves) do
    keys[index] = entry.move
  end
  return keys
end

---@param mon table
---@return integer[] the current PP in slot order
local function currentPp(mon)
  local values = {}
  for index, entry in ipairs(mon.moves) do
    values[index] = entry.pp
  end
  return values
end

---@param effects string[]
---@param wanted string
---@return integer count
local function countEffect(effects, wanted)
  local total = 0
  for _, effect in ipairs(effects) do
    if effect == wanted then
      total = total + 1
    end
  end
  return total
end

---@param effects string[]
---@param wanted string
---@return integer? first position of the effect in emission order
local function effectPosition(effects, wanted)
  for index, effect in ipairs(effects) do
    if effect == wanted then
      return index
    end
  end
  return nil
end

-- The shared recording audio adapter acknowledges every call but only names
-- play/playMusic/playFanfare; wrap playCry so the reveal's own cry stays
-- observable without changing the shared host for other suites.
---@param game table
---@return table[] recorded cries in call order
local function recordCries(game)
  local audio = assert(game.hosts.audio, "the recording hosts supply the audio adapter")
  local cries = {}
  local playCry = audio.playCry
  audio.playCry = function(self, ...)
    cries[#cries + 1] = { ... }
    return playCry(self, ...)
  end
  return cries
end

-- Turns the player without walking: the same facing-only domain operation a
-- script's turn performs, so no committed step is claimed.
---@param game table
---@param direction string
local function faceTile(game, direction)
  if game:snapshot().player.facing ~= direction then
    game:face(direction)
  end
end

---@param game table
---@param direction string
---@return boolean committed whether production movement left the tile
local function tryStep(game, direction)
  faceTile(game, direction)
  local before = game:snapshot().player
  game:move(direction)
  local after = game:advanceUntil("movement resolves", function(snapshot)
    return snapshot.player.motion == "idle"
  end, 120)
  return after.player.fieldX ~= before.fieldX or after.player.fieldZ ~= before.fieldZ
end

-- Drives the hatch application with one source button held each tick until the
-- caller's semantic state appears. Input outside the scene's own admitted
-- states is ignored, so a repeated press is the production way to answer its
-- single question; the cancel button is the source's own "no" answer.
---@param game table
---@param button "action"|"cancel"
---@param label string
---@param predicate fun(): boolean
local function driveScene(game, button, label, predicate)
  local press = button == "cancel" and pressCancel or pressAction
  for _ = 1, 6000 do
    if predicate() then
      return
    end
    press(game)
  end
  error(
    "timed out waiting for "
      .. label
      .. "; foreground="
      .. tostring(game:snapshot().foregroundScript)
      .. "; faults="
      .. table.concat(faults(game), ","),
    0
  )
end

---@param game table
---@param label string
local function waitForHatchClaim(game, label)
  game:advanceUntil(label, function(snapshot)
    return snapshot.foregroundScript == HATCH_SCRIPT
  end, 240)
end

---@param game table
---@param label string
local function waitForHatchEnd(game, label)
  game:advanceUntil(label, function()
    return #game:recordsForScript(HATCH_SCRIPT, "script.ended") > 0
      and game:snapshot().foregroundScript == nil
      and not game:snapshot().fieldLocked
  end, 600)
end

-- Presses the action button until the hatch application alone owns the field
-- (the script's own message is dismissed the way a player dismisses it, the
-- scene is running): the point where the field must refuse a save for the care
-- application's reason.
---@param game table
---@param label string
local function waitForHatchApplication(game, label)
  driveScene(game, "action", label, function()
    local snapshot = game:snapshot()
    return snapshot.foregroundScript == HATCH_SCRIPT and not snapshot.dialogue.modal
  end)
end

---@param game table
---@return integer the live hatch count
local function liveEggsHatched(game)
  return assert(game.runtime.gameStats, "the runtime owns its statistics"):bucket().eggsHatched
end

---@param game table
---@return integer the live trainer-card score
local function liveScore(game)
  return assert(game.runtime.gameStats, "the runtime owns its statistics"):score()
end

---@param game table
---@return integer|nil the live repel counter
local function liveRepelSteps(game)
  local roamers = game.runtime.roamerState
  if roamers == nil then
    return nil
  end
  return roamers:repelSteps()
end

-- Committed step effects after a hatch finished, taken from the recorded audio
-- trace past the point the caller marks.
---@param game table
---@param fromIndex integer
---@return string[]
local function effectsAfter(game, fromIndex)
  local list = {}
  for index = fromIndex + 1, #game:hostEffects() do
    list[#list + 1] = game:hostEffects()[index]
  end
  return list
end

-- The committed last cycle of an egg's life claims the step before any other
-- step effect, starts the source hatch scene and reconstructs the first ready
-- egg while a later one keeps its own progress.
function T.tests.the_last_egg_cycle_claims_the_step_and_starts_the_hatch_scene()
  local record = stagedEggRecord({
    {
      species = "PICHU",
      locationOffset = DAYCARE_LOCATION_OFFSET,
      change = function(mon)
        mon.friendship = 0
      end,
    },
    {
      species = "PICHU",
      locationOffset = DAYCARE_LOCATION_OFFSET,
      change = function(mon)
        mon.friendship = 120
      end,
    },
  })
  withHatchProgress(record, CYCLE_LENGTH - 2, 4)
  local game = bootContinue(record, clockAt(ORDINARY_DATE))
  local ok, err = xpcall(function()
    local scoreBefore = liveScore(game)
    -- An ordinary committed step that ends no cycle still spends the repel
    -- count: the control the hatch step must not decrement.
    Assert.isTrue(tryStep(game, "south"), "the day care room offers its first committed step")
    local walked = settledCapture(game, "the step before the last cycle")
    Assert.equal(walked.daycare.eggCycleCounter, CYCLE_LENGTH - 1, "one committed step advances the cycle counter")
    Assert.equal(walked.encounters.repelSteps, 3, "an ordinary committed step decrements the repel counter")
    Assert.equal(walked.gameStats.eggsHatched, 0, "a step without a ready egg hatches nothing")
    Assert.isTrue(tryStep(game, "north"), "the day care room offers the last-cycle step")

    waitForHatchClaim(game, "the committed last cycle starts the source hatch scene")
    Assert.equal(
      #game:recordsForScript(HATCH_SCRIPT, "script.started"),
      1,
      "the field starts the source hatch script exactly once"
    )
    local hatchFaults = scriptFaults(game, HATCH_SCRIPT)
    Assert.equal(
      #hatchFaults,
      0,
      "the source hatch script completes every native operation: " .. table.concat(hatchFaults, ",")
    )
    Assert.equal(liveEggsHatched(game), 1, "the claimed step counts one hatched egg")
    Assert.equal(liveScore(game) - scoreBefore, HATCH_SCORE, "the claimed step awards the source hatch score")
    Assert.equal(liveRepelSteps(game), 3, "a claimed hatch step spends no repel count")
    Assert.isFalse(
      game.runtime.battleCoordinator:hasBattleWork(),
      "a claimed hatch step starts no delayed encounter"
    )
    -- The conversion is committed before the application runs, and the later
    -- egg keeps its own cycle progress.
    Assert.isFalse(mons(game):partyMon(0).isEgg, "the first ready egg is converted before the application")
    Assert.isTrue(mons(game):partyMon(1).isEgg, "a later egg keeps its own unhatched state")
    Assert.equal(mons(game):partyMon(1).friendship, 120, "a later egg keeps its own friendship")

    -- The standard script prints its own line before the application takes
    -- over, so the scene is the field's own source flow, not a bare renderer.
    game:advanceUntil("the hatch script prints its own message", function(snapshot)
      return snapshot.dialogue.modal
        and snapshot.dialogue.bankId == HATCH_MESSAGE_BANK
        and snapshot.dialogue.messageId == HATCH_MESSAGE_ID
    end, 240)

    local effectsFrom = #game:hostEffects()
    waitForHatchApplication(game, "the hatch application owns the field")
    driveScene(game, "cancel", "the source hatch application to finish", function()
      return #game:recordsForScript(HATCH_SCRIPT, "script.ended") > 0
    end)
    waitForHatchEnd(game, "the hatch scene returns the field")
    local effects = effectsAfter(game, effectsFrom)
    local music = effectPosition(effects, HATCH_MUSIC)
    local firstShake = effectPosition(effects, EGG_SHAKE_SE)
    local burst = effectPosition(effects, EGG_BURST_SE)
    local fanfare = effectPosition(effects, HATCH_FANFARE)
    Assert.notNil(music, "the hatch scene starts the source hatch music: " .. table.concat(effects, ","))
    Assert.notNil(firstShake, "the hatch scene plays the source egg shake")
    Assert.equal(countEffect(effects, EGG_SHAKE_SE), 4, "the egg shakes exactly four times before it cracks")
    Assert.notNil(burst, "the egg bursts with the source hatch sound")
    Assert.notNil(fanfare, "the hatch scene plays the source hatch fanfare")
    Assert.isTrue(
      music < firstShake and firstShake < burst and burst < fanfare,
      "the hatch frames keep the source order music, shakes, burst, fanfare"
    )
    Assert.equal(#scriptFaults(game, HATCH_SCRIPT), 0, "the whole hatch scene runs without a script fault")
    Assert.equal(#faults(game), 0, "the hatch step publishes no unrelated script fault")

    local settled = settledCapture(game, "the finished hatch")
    Assert.equal(settled.gameStats.eggsHatched, 1, "the finished hatch keeps one hatched egg")
    Assert.equal(settled.daycare.eggCycleCounter, 0, "the last cycle resets the cycle counter")
    Assert.isFalse(settled.mons.party.mons[1].isEgg, "the hatched record is no longer an egg")
    Assert.isTrue(settled.mons.party.mons[2].isEgg, "the later egg stays an unhatched egg")
    Assert.equal(game:renderAttempts(), 0, "the hatch scenario stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The hatched record is the same mon: the species at level one keeps the
-- egg's personality, retained individual values, moves and current PP, its
-- origin and progress facts, the receipt record, and the fresh-record
-- defaults the source assigns.
function T.tests.the_hatched_mon_keeps_its_native_egg_identity()
  local record = stagedEggRecord({
    {
      species = "PICHU",
      locationOffset = DAYCARE_LOCATION_OFFSET,
      change = function(mon)
        mon.friendship = 0
        mon.ivs = copy(HIGH_IVS)
        mon.moves = {
          { move = "THUNDER_SHOCK", pp = 27, ppUps = 2 },
          { move = "CHARM", pp = 17, ppUps = 1 },
        }
        mon.markings = 31
        mon.pokerus = 5
        mon.fatefulEncounter = true
        mon.origin.trainerId = 4321
        mon.origin.trainerName = "SILVER"
        mon.origin.trainerGender = 1
        mon.origin.language = "japanese"
        mon.egg = { location = 2014, date = { year = 2020, month = 12, day = 31 } }
      end,
    },
  })
  local egg = copy(record.mons.party.mons[1])
  withHatchProgress(record, CYCLE_LENGTH - 1, 0)
  local game = bootContinue(record, clockAt(ORDINARY_DATE))
  local ok, err = xpcall(function()
    local drawsBefore = settledCapture(game, "the staged egg").mons.rng.calls
    Assert.isTrue(tryStep(game, "south"), "the day care room offers the last-cycle step")
    waitForHatchClaim(game, "the committed last cycle starts the source hatch scene")
    waitForHatchApplication(game, "the hatch application owns the field")
    driveScene(game, "cancel", "the source hatch application to finish", function()
      return #game:recordsForScript(HATCH_SCRIPT, "script.ended") > 0
    end)
    waitForHatchEnd(game, "the hatch scene returns the field")
    Assert.equal(#scriptFaults(game, HATCH_SCRIPT), 0, "the hatch scene runs without a script fault")

    local settled = settledCapture(game, "the hatched mon")
    local mon = settled.mons.party.mons[1]
    Assert.equal(mon.species, egg.species, "the hatch keeps the egg's species")
    Assert.equal(mon.experience, 0, "the hatched species starts at level one")
    Assert.equal(mon.personality, egg.personality, "the hatch keeps the egg's personality")
    Assert.equal(
      settled.mons.rng.calls - drawsBefore,
      2,
      "the reconstruction consumes the source's two base individual-value draws"
    )
    Assert.deepEqual(mon.ivs, egg.ivs, "the retained individual values are restored after those draws")
    Assert.deepEqual(moveKeys(mon), moveKeys(egg), "the hatch keeps the egg's moves in order")
    Assert.deepEqual(currentPp(mon), currentPp(egg), "the hatch keeps the egg's current PP")
    for _, entry in ipairs(mon.moves) do
      Assert.equal(entry.ppUps, 0, "a fresh hatched record resets PP Ups")
    end
    Assert.equal(mon.origin.language, egg.origin.language, "the hatch keeps the record's language")
    Assert.equal(mon.origin.game, egg.origin.game, "the hatch keeps the record's game")
    Assert.equal(mon.markings, egg.markings, "the hatch keeps the markings")
    Assert.equal(mon.pokerus, egg.pokerus, "the hatch keeps the Pokerus state")
    Assert.equal(mon.fatefulEncounter, egg.fatefulEncounter, "the hatch keeps the fateful status")
    Assert.equal(mon.origin.trainerId, egg.origin.trainerId, "the hatch keeps the original trainer id")
    Assert.equal(mon.origin.trainerName, egg.origin.trainerName, "the hatch keeps the original trainer name")
    Assert.equal(mon.origin.trainerGender, egg.origin.trainerGender, "the hatch keeps the original trainer gender")
    Assert.equal(mon.form, egg.form, "the hatch keeps the form")
    Assert.deepEqual(mon.egg, egg.egg, "the hatch keeps the egg receipt record")
    Assert.equal(mon.friendship, 120, "a hatched mon starts at the source friendship")
    Assert.equal(mon.origin.ball, "POKE_BALL", "a hatched mon is in a Poke Ball")
    Assert.equal(mon.met.level, 0, "a hatched mon keeps the source met level")
    Assert.isFalse(mon.isEgg, "the hatched record is no longer an egg")
    Assert.isNil(mon.nickname, "the hatched record keeps the default species name")

    -- Memo strategy six: the meeting record becomes the map section the mon
    -- hatched in on the current date.
    local mapSection = assert(game.runtime.runtimeMap.mapSectionNativeId, "the active map names its map section")
    Assert.equal(mon.met.location, mapSection, "the hatch writes the current map section as the meeting place")
    Assert.deepEqual(
      mon.met.date,
      { year = ORDINARY_DATE.year, month = ORDINARY_DATE.month, day = ORDINARY_DATE.day },
      "the hatch records the receiving date as the meeting date"
    )
    Assert.notNil(mon.egg.location, "the hatch keeps the egg receipt location")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

---@param trainerId integer
---@return integer a personality the trainer sees as shiny
local function shinyPersonality(trainerId)
  for candidate = 1, 200000 do
    local pid = (candidate * 2654435761) % U32.MAX
    if Personality.shiny(trainerId, pid) then
      return pid
    end
  end
  error("no shiny personality found", 0)
end

---@param pid integer
---@return integer the source PRandom personality mixer
local function prandom(pid)
  return U32.add(U32.mul(pid, 1812433253), 1)
end

-- A Ranger-origin Manaphy egg runs the source Manaphy scene instead of the
-- egg-shake scene, and its personality is advanced until the receiver no
-- longer sees a shiny. Answering the scene's own question with "no" keeps the
-- default species name and opens no naming screen.
function T.tests.the_ranger_manaphy_hatch_runs_its_own_scene_and_rerolls_shiny()
  local record = stagedEggRecord({
    {
      species = "MANAPHY",
      locationOffset = RANGER_LOCATION_OFFSET,
      change = function(mon)
        mon.friendship = 0
        mon.personality = shinyPersonality(1)
      end,
    },
  })
  local egg = copy(record.mons.party.mons[1])
  Assert.equal(egg.egg.location, 3001, "the staged egg carries the Ranger receipt location")
  withHatchProgress(record, CYCLE_LENGTH - 1, 0)
  local game = bootContinue(record, clockAt(ORDINARY_DATE))
  local ok, err = xpcall(function()
    local cries = recordCries(game)
    local effectsFrom = #game:hostEffects()
    Assert.isTrue(tryStep(game, "south"), "the day care room offers the last-cycle step")
    waitForHatchClaim(game, "the committed last cycle starts the source hatch scene")
    waitForHatchApplication(game, "the hatch application owns the field")
    driveScene(game, "cancel", "the source Manaphy hatch application to finish", function()
      return #game:recordsForScript(HATCH_SCRIPT, "script.ended") > 0
    end)
    waitForHatchEnd(game, "the Manaphy hatch scene returns the field")
    Assert.equal(#scriptFaults(game, HATCH_SCRIPT), 0, "the Manaphy hatch scene runs without a script fault")
    Assert.isFalse(game.runtime.monNaming:isActive(), "the refused nickname question opens no naming screen")

    local settled = settledCapture(game, "the hatched Manaphy")
    local mon = settled.mons.party.mons[1]
    Assert.equal(mon.species, "MANAPHY", "the hatched mon keeps the Manaphy species")
    Assert.isFalse(mon.isEgg, "the Manaphy record is no longer an egg")
    Assert.isNil(mon.nickname, "the refused nickname keeps the default species name")
    Assert.equal(
      Mon.displayName(mon, catalog(game)),
      catalog(game):species("MANAPHY").name,
      "the default species name survives the refused nickname"
    )
    local expected = egg.personality
    if Personality.shiny(mon.origin.trainerId, expected) then
      repeat
        expected = prandom(expected)
      until not Personality.shiny(mon.origin.trainerId, expected)
    end
    Assert.equal(
      mon.personality,
      expected,
      "a shiny Ranger Manaphy is advanced with the source personality mixer until it is no longer shiny"
    )
    Assert.isFalse(Personality.shiny(mon.origin.trainerId, mon.personality), "the hatched Manaphy is not shiny")

    local effects = effectsAfter(game, effectsFrom)
    local positions = {}
    for index, wanted in ipairs(MANAPHY_SE) do
      positions[index] = effectPosition(effects, wanted)
      Assert.notNil(positions[index], "the Manaphy scene plays " .. wanted)
    end
    Assert.isTrue(
      positions[1] < positions[2] and positions[2] < positions[3],
      "the Manaphy scene plays its three source effects in order"
    )
    Assert.equal(countEffect(effects, EGG_SHAKE_SE), 0, "the Manaphy scene runs no egg-shake effect")
    Assert.notNil(effectPosition(effects, HATCH_MUSIC), "the Manaphy scene starts the source hatch music")
    Assert.notNil(effectPosition(effects, HATCH_FANFARE), "the Manaphy scene plays the source hatch fanfare")
    Assert.equal(#cries, 1, "the reveal plays the hatched mon's own cry once")
    Assert.equal(game:renderAttempts(), 0, "the Manaphy hatch scenario stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- Drives the naming screen to its OK control, the same keyboard path a player
-- takes.
---@param game table
local function submitNaming(game)
  for _ = 1, 6 do
    local status = assert(game.runtime.monNaming:status(), "the naming screen remains active")
    if status.snapshot.cursor.row == 1 then
      break
    end
    game:move("north")
  end
  for _ = 1, 6 do
    local status = assert(game.runtime.monNaming:status(), "the naming screen remains active")
    if status.snapshot.cursor.controlId == "ok" then
      break
    end
    game:move("east")
  end
  local status = assert(game.runtime.monNaming:status(), "the naming screen remains active")
  Assert.equal(status.snapshot.cursor.controlId, "ok", "the naming cursor reaches the OK control")
  game:pressAction()
end

-- The source nickname question opens the real blank naming screen; the chosen
-- name is committed, the field is restored only after that child closes, and
-- nothing can be saved while the hatch application owns the field.
function T.tests.the_hatch_application_names_the_new_mon_and_blocks_saving()
  local record = stagedEggRecord({
    {
      species = "PICHU",
      locationOffset = DAYCARE_LOCATION_OFFSET,
      change = function(mon)
        mon.friendship = 0
      end,
    },
  })
  withHatchProgress(record, CYCLE_LENGTH - 1, 0)
  local game = bootContinue(record, clockAt(ORDINARY_DATE))
  local ok, err = xpcall(function()
    local startSnapshot = game:snapshot()
    Assert.isTrue(tryStep(game, "south"), "the day care room offers the last-cycle step")
    -- The committed step that ends the egg's last cycle is the walk that
    -- reached this tile; the hatch scene must return the field exactly there.
    local before = game:snapshot().player
    waitForHatchClaim(game, "the committed last cycle starts the source hatch scene")
    -- Between the script's own message and the nickname question the hatch
    -- application alone owns the field and nothing may serialize it.
    waitForHatchApplication(game, "the hatch application owns the field without a dialogue")
    Assert.notNil(
      deniedSaveReason(game),
      "the field refuses to save while the hatch application owns it"
    )

    driveScene(game, "action", "the source nickname question opens the naming screen", function()
      return game.runtime.monNaming:isActive()
    end)
    local naming = assert(game.runtime.monNaming:status(), "the naming screen publishes its state")
    Assert.equal(naming.text, "", "the source naming screen starts blank")
    Assert.equal(naming.snapshot.subject.kind, "pokemon", "the naming screen names the hatched mon")
    local species = catalog(game):species("PICHU")
    Assert.equal(naming.snapshot.subject.species, species.nativeId, "the naming subject keeps the species")
    Assert.equal(
      naming.snapshot.subject.gender,
      Personality.gender(species.genderRatio, mons(game):partyMon(0).personality),
      "the naming subject derives the gender from the hatched personality"
    )
    Assert.notNil(deniedSaveReason(game), "the field refuses to save while the naming screen is open")
    Assert.equal(game:snapshot().foregroundScript, HATCH_SCRIPT, "the hatch application still owns the field")

    -- Type one real glyph and submit it.
    game:move("south")
    game:pressAction()
    Assert.equal(assert(game.runtime.monNaming:status()).text, "K", "the naming keyboard accepts a real glyph")
    submitNaming(game)
    game:advanceUntil("the naming screen commits the chosen name", function()
      return not game.runtime.monNaming:isActive() and mons(game):partyMon(0).nickname == "K"
    end, 600)
    Assert.equal(mons(game):partyMon(0).nickname, "K", "the chosen name is committed to the hatched mon")

    waitForHatchEnd(game, "the hatch scene returns the field")
    Assert.equal(#scriptFaults(game, HATCH_SCRIPT), 0, "the whole hatch scene runs without a script fault")
    local after = game:snapshot()
    Assert.equal(after.fieldLocked, false, "the field is usable again only after the child closed")
    Assert.equal(after.mapId, startSnapshot.mapId, "the field returns to the same map")
    Assert.equal(after.player.fieldX, before.fieldX, "the field restores the player's own tile")
    Assert.equal(after.player.fieldZ, before.fieldZ, "the field restores the player's own tile")

    local settled = settledCapture(game, "the named hatch")
    local mon = settled.mons.party.mons[1]
    Assert.equal(mon.nickname, "K", "the saved mon keeps the chosen name")
    Assert.equal(settled.gameStats.eggsHatched, 1, "the saved field counts one hatched egg")
    Assert.isTrue(game.runtime.dexKnowledge:isCaught("PICHU"), "the hatch registers the species as caught")
    Assert.equal(
      mon.met.location,
      assert(game.runtime.runtimeMap.mapSectionNativeId, "the active map names its map section"),
      "the saved hatch keeps its meeting memo"
    )

    -- The receipt publishes once: further ticks change no statistic.
    local eggs = settled.gameStats.eggsHatched
    local score = settled.gameStats.score
    for _ = 1, 8 do
      game:step()
    end
    local again = settledCapture(game, "the hatch after further ticks")
    Assert.equal(again.gameStats.eggsHatched, eggs, "no later tick republishes the hatch count")
    Assert.equal(again.gameStats.score, score, "no later tick republishes the hatch score")

    -- Continue restores the committed hatch instead of replaying it.
    game:restart()
    game:waitForFieldEntry()
    local continued = settledCapture(game, "the continued field")
    Assert.equal(continued.mons.party.mons[1].nickname, "K", "a continued field keeps the named mon")
    Assert.equal(continued.gameStats.eggsHatched, 1, "a continued field keeps the hatch count exactly once")
    Assert.isFalse(continued.mons.party.mons[1].isEgg, "a continued field keeps the hatched record")
    Assert.equal(game:renderAttempts(), 0, "the naming scenario stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- Submitting the source naming screen blank keeps the default species name:
-- the source only writes the nickname when the player typed one.
function T.tests.a_blank_nickname_keeps_the_species_name()
  local record = stagedEggRecord({
    {
      species = "PICHU",
      locationOffset = DAYCARE_LOCATION_OFFSET,
      change = function(mon)
        mon.friendship = 0
      end,
    },
  })
  withHatchProgress(record, CYCLE_LENGTH - 1, 0)
  local game = bootContinue(record, clockAt(ORDINARY_DATE))
  local ok, err = xpcall(function()
    Assert.isTrue(tryStep(game, "south"), "the day care room offers the last-cycle step")
    waitForHatchClaim(game, "the committed last cycle starts the source hatch scene")
    driveScene(game, "action", "the source nickname question opens the naming screen", function()
      return game.runtime.monNaming:isActive()
    end)
    Assert.equal(assert(game.runtime.monNaming:status()).text, "", "the naming screen starts blank")
    submitNaming(game)
    game:advanceUntil("the blank naming screen closes", function()
      return not game.runtime.monNaming:isActive()
    end, 600)
    waitForHatchEnd(game, "the hatch scene returns the field")
    local settled = settledCapture(game, "the hatched mon with no nickname")
    local mon = settled.mons.party.mons[1]
    Assert.isNil(mon.nickname, "a blank submission writes no nickname")
    Assert.equal(
      Mon.displayName(mon, catalog(game)),
      catalog(game):species("PICHU").name,
      "a blank submission keeps the default species name"
    )
    Assert.equal(#scriptFaults(game, HATCH_SCRIPT), 0, "the blank-nickname hatch runs without a script fault")
    Assert.equal(game:renderAttempts(), 0, "the blank-nickname scenario stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- An interrupted hatch owns a converted mon and a spent count already, so the
-- source receipt must still be finalized exactly once before the field can be
-- saved again, and the field must come back usable with no leaked lease.
function T.tests.an_interrupted_hatch_finalizes_once_and_reopens_saving()
  local record = stagedEggRecord({
    {
      species = "PICHU",
      locationOffset = DAYCARE_LOCATION_OFFSET,
      change = function(mon)
        mon.friendship = 0
      end,
    },
  })
  withHatchProgress(record, CYCLE_LENGTH - 1, 0)
  local game = bootContinue(record, clockAt(ORDINARY_DATE))
  local ok, err = xpcall(function()
    Assert.isTrue(tryStep(game, "south"), "the day care room offers the last-cycle step")
    waitForHatchClaim(game, "the committed last cycle starts the source hatch scene")
    waitForHatchApplication(game, "the hatch application owns the field without a dialogue")
    Assert.isFalse(mons(game):partyMon(0).isEgg, "the interrupted hatch already converted the mon")
    Assert.equal(liveEggsHatched(game), 1, "the interrupted hatch already spent its count")
    Assert.notNil(deniedSaveReason(game), "the interrupted hatch still owns the field")

    local scheduler = assert(game.runtime.scripts and game.runtime.scripts.scheduler, "the field owns its scheduler")
    local environmentId = assert(scheduler:foregroundEnvironmentId(), "the hatch application owns the foreground")
    scheduler:cancelEnvironment(environmentId, "acceptance interrupted the hatch application")

    -- The field reopens for saving only after the torn-down child published
    -- the source receipt once.
    game:advanceUntil("the interrupted hatch releases the field", function(snapshot)
      return snapshot.foregroundScript == nil and not snapshot.fieldLocked
    end, 600)
    local settled = settledCapture(game, "the interrupted hatch")
    local mon = settled.mons.party.mons[1]
    Assert.isFalse(mon.isEgg, "the interrupted hatch keeps its converted mon")
    Assert.equal(mon.friendship, 120, "the interrupted hatch keeps the source hatch friendship")
    Assert.equal(settled.gameStats.eggsHatched, 1, "the interrupted hatch publishes its count exactly once")
    Assert.isTrue(game.runtime.dexKnowledge:isCaught("PICHU"), "the interrupted hatch still publishes its Dex receipt")
    Assert.equal(
      mon.met.location,
      assert(game.runtime.runtimeMap.mapSectionNativeId, "the active map names its map section"),
      "the interrupted hatch still publishes its meeting memo"
    )

    -- No lease survives the interruption: the field walks and keeps its books.
    local eggs = settled.gameStats.eggsHatched
    Assert.isTrue(tryStep(game, "north"), "the released field accepts an ordinary committed step after the hatch")
    local walked = settledCapture(game, "the step after the interrupted hatch")
    Assert.equal(walked.gameStats.eggsHatched, eggs, "the released field keeps the single hatch count")
    Assert.equal(#faults(game), 0, "the interrupted hatch publishes no unrelated script fault")
    Assert.equal(game:renderAttempts(), 0, "the interrupted hatch scenario stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

---@param mon table
---@return integer the Extrasensory slot
local function extrasensorySlot(mon)
  for index, entry in ipairs(mon.moves) do
    if entry.move == "EXTRASENSORY" then
      return index
    end
  end
  error("the Togepi egg carries no Extrasensory", 0)
end

---@param printed integer[]
---@param messageId integer
---@return boolean
local function printedLine(printed, messageId)
  for _, value in ipairs(printed) do
    if value == messageId then
      return true
    end
  end
  return false
end

-- Talks to Elm's assistant and drives the whole source gift script; the
-- scenario's answer selects the source menu row (0 accepts the egg).
---@param game table
---@param answer integer
---@return integer[] printed message ids
local function runAideScript(game, answer)
  local ended = #game:recordsForScript(AIDE_SCRIPT, "script.ended")
  game:pressAction()
  local interaction = game:interaction()
  Assert.equal(interaction.scriptId, AIDE_SCRIPT, "Elm's assistant owns the interaction the script answers")
  local printed, last = {}, nil
  for _ = 1, 6000 do
    local now = scriptFaults(game, AIDE_SCRIPT)
    Assert.equal(
      #now,
      0,
      "Elm's assistant's script completes every native operation: " .. table.concat(now, ",")
    )
    local choice = game:contextChoiceStatus()
    local snapshot = game:snapshot()
    if choice ~= nil and choice.state == "active" then
      if choice.selected ~= answer then
        pressDirection(game, answer == 0 and "up" or "down")
      else
        pressAction(game)
      end
    elseif snapshot.dialogue.modal then
      local messageId = snapshot.dialogue.messageId
      if messageId ~= nil and messageId ~= last then
        printed[#printed + 1] = messageId
        last = messageId
      end
      pressAction(game)
    else
      game:step()
    end
    if
      #game:recordsForScript(AIDE_SCRIPT, "script.ended") > ended
      and game:contextChoiceStatus() == nil
      and not game:snapshot().dialogue.modal
    then
      return printed
    end
  end
  error(
    "Elm's assistant's script never returned to the field: " .. table.concat(scriptFaults(game, AIDE_SCRIPT), ","),
    0
  )
end

-- The original gift: the source command adds the level-one Togepi egg with
-- Extrasensory in the source slot, records its identity before the egg can be
-- released, and sets the story flags. A full party refuses before any draw.
function T.tests.the_aide_gives_the_original_togepi_egg()
  local refused = bootFresh(MART_MAP, MART_TILE, ORDINARY_DATE)
  local refusedOk, refusedErr = xpcall(function()
    for _ = 1, 6 do
      Assert.isTrue(
        mons(refused):giveMon({ species = "RATTATA", level = 5, form = 0, heldItem = "NONE" }),
        "the party fills with a carrier"
      )
    end
    local before = settledCapture(refused, "the full party")
    local printed = runAideScript(refused, 0)
    Assert.isTrue(printedLine(printed, AIDE_MESSAGE_FULL_PARTY), "the assistant refuses because the party is full")
    local after = settledCapture(refused, "the full-party refusal")
    Assert.equal(#after.mons.party.mons, 6, "the full party keeps its six carriers")
    Assert.equal(after.mons.rng.calls, before.mons.rng.calls, "the full-party refusal draws no random value")
    Assert.isNil(after.daycare.togepiGift, "the full-party refusal records no gift identity")
    for _, mon in ipairs(after.mons.party.mons) do
      Assert.isTrue(mon.isEgg ~= true, "the full-party refusal appends no egg")
    end
    Assert.equal(refused:renderAttempts(), 0, "the refusal scenario stops before GPU rendering")
  end, debug.traceback)
  refused:close()
  if not refusedOk then
    error(refusedErr, 0)
  end

  local game = bootFresh(MART_MAP, MART_TILE, ORDINARY_DATE)
  local ok, err = xpcall(function()
    local before = settledCapture(game, "the empty party")
    local printed = runAideScript(game, 0)
    Assert.isTrue(printedLine(printed, AIDE_MESSAGE_OPEN), "the assistant opens with the source line")
    Assert.isTrue(printedLine(printed, AIDE_MESSAGE_RECEIPT), "the assistant hands the egg over with the receipt line")
    Assert.isTrue(printedLine(printed, AIDE_MESSAGE_FOLLOW_UP), "the assistant follows up after the gift")
    local after = settledCapture(game, "the gifted egg")
    Assert.equal(#after.mons.party.mons, 1, "the gift appends exactly one mon")
    local egg = after.mons.party.mons[1]
    Assert.equal(egg.species, "TOGEPI", "the gift is the source Togepi egg")
    Assert.isTrue(egg.isEgg, "the gift is still an unhatched egg")
    Assert.equal(egg.experience, 0, "the gift egg starts at level one")
    Assert.equal(
      after.mons.rng.calls - before.mons.rng.calls,
      4,
      "the source egg record consumes its four creation draws"
    )
    Assert.equal(egg.moves[extrasensorySlot(egg)].move, "EXTRASENSORY", "the gift carries Extrasensory")
    for index = 1, extrasensorySlot(egg) - 1 do
      Assert.isTrue(egg.moves[index].move ~= "NONE", "the source fills the first empty move slot")
    end
    Assert.equal(
      egg.moves[extrasensorySlot(egg)].pp,
      catalog(game):move("EXTRASENSORY").basePp,
      "the inserted move starts at its base PP"
    )
    local gift = assert(after.daycare.togepiGift, "the gift records its identity in the saved Day Care state")
    Assert.equal(gift.personality, egg.personality, "the recorded gift identity is the egg's personality")
    local recordedGender = gift.gender
    local derivedGender = Personality.gender(catalog(game):species("TOGEPI").genderRatio, egg.personality)
    Assert.isTrue(
      recordedGender == derivedGender or recordedGender == (derivedGender == "female" and 1 or 0),
      "the recorded gift gender is the personality's derived gender"
    )
    Assert.isTrue(game.runtime.eventState:isFlagSet(AIDE_GIFT_FLAG), "the gift sets the source story flag")
    Assert.isTrue(game.runtime.eventState:isFlagSet(AIDE_HIDE_FLAG), "the assistant hides after the gift")
    Assert.isNil(game.runtime.actors:getById("map:157:object:4"), "the hidden assistant leaves the field")
    Assert.notNil(effectPosition(game:hostEffects(), AIDE_FANFARE), "the gift plays the source egg fanfare")
    Assert.equal(#faults(game), 0, "the gift publishes no unrelated script fault")

    -- The matured gift raises Elm's call exactly once, and a Togepi egg that
    -- was never the gift raises none.
    local giftRecord = copy(after)
    giftRecord.mons.party.mons[1].friendship = 0
    withHatchProgress(giftRecord, CYCLE_LENGTH - 1, 0)
    local giftGame = bootContinue(giftRecord, clockAt(ORDINARY_DATE))
    local giftOk, giftErr = xpcall(function()
      Assert.isTrue(tryStep(giftGame, "south"), "the day care room offers the last-cycle step")
      waitForHatchClaim(giftGame, "the mature gift egg starts the source hatch scene")
      waitForHatchApplication(giftGame, "the gift hatch application owns the field")
      driveScene(giftGame, "cancel", "the source hatch application to finish", function()
        return #giftGame:recordsForScript(HATCH_SCRIPT, "script.ended") > 0
      end)
      waitForHatchEnd(giftGame, "the gift hatch returns the field")
      Assert.equal(#scriptFaults(giftGame, HATCH_SCRIPT), 0, "the gift hatch runs without a script fault")
      local phone = assert(giftGame.runtime.pokegearState, "the runtime owns the phone state"):readPhone()
      Assert.isTrue(phone.triggers[ELM_EGG_TRIGGER] == true, "the hatched original egg raises Elm's egg call")
      Assert.isTrue(
        giftGame.runtime.eventState:isFlagSet(HATCHED_FLAG),
        "the hatched original egg sets the source hatched flag"
      )
      local settledGift = settledCapture(giftGame, "the hatched gift")
      Assert.equal(settledGift.mons.party.mons[1].species, "TOGEPI", "the gift hatches into Togepi")
      Assert.equal(giftGame:renderAttempts(), 0, "the gift hatch stops before GPU rendering")
    end, debug.traceback)
    giftGame:close()
    if not giftOk then
      error(giftErr, 0)
    end

    local legacyRecord = copy(after)
    legacyRecord.mons.party.mons[1].friendship = 0
    legacyRecord.daycare = DaycareState.initial()
    withHatchProgress(legacyRecord, CYCLE_LENGTH - 1, 0)
    local legacyGame = bootContinue(legacyRecord, clockAt(ORDINARY_DATE))
    local legacyOk, legacyErr = xpcall(function()
      Assert.isTrue(tryStep(legacyGame, "south"), "the day care room offers the last-cycle step")
      waitForHatchClaim(legacyGame, "the Togepi egg starts the source hatch scene")
      waitForHatchApplication(legacyGame, "the Togepi hatch application owns the field")
      driveScene(legacyGame, "cancel", "the source hatch application to finish", function()
        return #legacyGame:recordsForScript(HATCH_SCRIPT, "script.ended") > 0
      end)
      waitForHatchEnd(legacyGame, "the Togepi hatch returns the field")
      local phone = assert(legacyGame.runtime.pokegearState, "the runtime owns the phone state"):readPhone()
      Assert.isNil(
        phone.triggers[ELM_EGG_TRIGGER],
        "a Togepi egg without the recorded gift identity never raises Elm's egg call"
      )
      Assert.isFalse(
        legacyGame.runtime.eventState:isFlagSet(HATCHED_FLAG),
        "a Togepi egg without the recorded gift identity never sets the source hatched flag"
      )
      Assert.equal(legacyGame:renderAttempts(), 0, "the legacy Togepi hatch stops before GPU rendering")
    end, debug.traceback)
    legacyGame:close()
    if not legacyOk then
      error(legacyErr, 0)
    end
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
