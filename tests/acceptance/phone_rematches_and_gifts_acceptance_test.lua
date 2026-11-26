-- Source phone invitations, contact gifts and Day Care notifications through the
-- production field. The shared standard trainer script asks the saved invitation
-- for a real source trainer tier and fights that tier; only a won rematch ends
-- the invitation; the contact gift commands read the loaded phonebook entry and
-- consume the pending item in the same read; a durable Day Care or Elm call
-- trigger schedules exactly one incoming call whose status queries never replay
-- it. Production boot with the real catalog, saved phone state, calendar, draw
-- streams and ROM scripts: maps, actors, battles and saves stay
-- production-owned, and the render trap stays active.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local CacheFs = require("libs.storage.src.CacheFs")
local GeneratedCacheFixture = require("tests.support.GeneratedCacheFixture")
local CivilDate = require("libs.hgss.src.field.CivilDate")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FinalizedGameFixture = require("tests.support.FinalizedGameFixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local LocalClock = require("game.src.LocalClock")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local PokegearCache = require("libs.assets.src.PokegearCache")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local Personality = require("libs.mons.src.gen4.Personality")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local SessionFixture = require("libs.battle.tests.session_fixture")
local U32 = require("libs.codec.src.U32")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      -- Route 30 and every map its physical window reaches.
      "map:33",
      "map-data:33",
      "map:34",
      "map-data:34",
      "map:35",
      "map-data:35",
      "map:48",
      "map-data:48",
      "map:67",
      "map-data:67",
      "map:73",
      "map-data:73",
      -- The Route 30 physical-cell window around the trainer this scenario
      -- answers.
      "field-cell:0-391",
      "field-cell:0-392",
      "field-cell:0-393",
      "field-cell:0-394",
      "field-cell:0-395",
      "field-cell:0-438",
      "field-cell:0-439",
      "field-cell:0-440",
      "field-cell:0-441",
      "field-cell:0-442",
      "field-cell:0-485",
      "field-cell:0-486",
      "field-cell:0-487",
      "field-cell:0-488",
      "field-cell:0-489",
      "field-cell:0-532",
      "field-cell:0-533",
      "field-cell:0-534",
      "field-cell:0-535",
      "field-cell:0-536",
      "field-cell:0-579",
      "field-cell:0-580",
      "field-cell:0-581",
      "field-cell:0-582",
      "field-cell:0-583",
      -- The Day Care room, the Route 34 maps around it and the physical cell in
      -- front of the Day Care door.
      "map:38",
      "map-data:38",
      "map:74",
      "map-data:74",
      "map:76",
      "map-data:76",
      "map:331",
      "map-data:331",
      "field-cell:0-529",
      -- The Day-Care Man's and Elm's own call banks, the generic phone label
      -- banks and the Day Care room's message banks.
      "message-bank:661",
      "message-bank:716",
      "message-bank:271",
      "message-bank:279",
      "message-bank:280",
      "message-bank:640",
      "message-bank:730",
      "message-bank:660",
      "message-bank:662",
      "message-bank:663",
      "message-bank:664",
      "message-bank:665",
      "message-bank:666",
      "message-bank:667",
      "message-bank:675",
      "message-bank:728",
      "message-bank:384",
      "message-bank:435",
      "message-bank:439",
    },
    tags = { "pokegear", "phone", "field", "script" },
  },
  tests = {},
}

local ROUTE_30 = "MAP_ROUTE_30"
local ROUTE_34_DAYCARE = "MAP_ROUTE_34_DAYCARE"
-- The Day Care room's open floor tile, the same approach the custody and
-- breeding journeys use.
local DAYCARE_TILE = { fieldX = 3, fieldZ = 7 }
local DAYCARE_TRIGGER = "gear.trigger.5"
local ELM_TRIGGER = "gear.trigger.0"
-- The Day-Care Man's and Elm's generated phone trigger owners.
local DAYCARE_MAN_CONTACT = "hg.trainer.204.map.0.contact.6"
local ELM_CONTACT = "hg.trainer.201.map.0.contact.1"
local DAYCARE_BUCKET_SCHEMA = "hgss-daycare-v1"
-- The saved generator whose first draw passes the source maximum-compatibility
-- roll.
local SEED_STEP = 1

-- ---------------------------------------------------------------------------
-- Generated source facts the scenarios read instead of restating them.
-- ---------------------------------------------------------------------------

---@param versionId string
---@param mapSymbol string
---@return { x: integer, z: integer } the map's generated field tile origin
local function mapOrigin(versionId, mapSymbol)
  local world = assert(
    GeneratedCacheFixture.reader(versionId):loadLua(MapAssetCache.worldPath()),
    "the generated world catalog is available"
  )
  for _, record in pairs(world.maps) do
    local entry = record --[[@as table<string, unknown>]]
    if entry.symbol == mapSymbol then
      return { x = entry.worldOriginX --[[@as integer]], z = entry.worldOriginZ --[[@as integer]] }
    end
  end
  error("the generated world catalog carries no origin for " .. mapSymbol, 0)
end

---@param versionId string
---@param mapSymbol string
---@return table the map's generated event objects
local function generatedObjects(versionId, mapSymbol)
  local mapId = MapCatalog.require(mapSymbol).id
  local field = assert(
    GeneratedCacheFixture.reader(versionId):loadLua(FieldMapDataCache.fieldPath(mapId)),
    "the map's generated field record is available"
  )
  return assert(field.events.objects, "the generated field record carries its object events")
end

---@param versionId string
---@return table[] the generated phonebook contacts
local function generatedContacts(versionId)
  local manifest = PokegearCache.loadManifest(GeneratedCacheFixture.reader(versionId))
  local catalog = assert(manifest.catalog, "the generated companion manifest carries its catalog")
  return assert(catalog.contacts, "the generated companion catalog carries its contacts")
end

-- The phonebook trainer standing on one map and the tile a player answers it
-- from, both read from generated artifacts before the boot so the scenario
-- starts in front of the very trainer it drives.
---@param versionId string
---@param mapSymbol string
---@return table contact, table object, { fieldX: integer, fieldZ: integer } standing tile
local function generatedMapTrainer(versionId, mapSymbol)
  local trainerObjects = {}
  for _, object in ipairs(generatedObjects(versionId, mapSymbol)) do
    if type(object.trainer) == "table" and object.trainer.trainerId ~= nil then
      trainerObjects[object.trainer.trainerId] = object
    end
  end
  for _, record in ipairs(generatedContacts(versionId)) do
    local contact = record --[[@as table<string, unknown>]]
    local object = contact.family == "trainer" and trainerObjects[contact.trainerId] or nil
    if object ~= nil then
      return contact, object, { fieldX = object.x, fieldZ = object.z + 1 }
    end
  end
  error("the generated phonebook knows no trainer on " .. mapSymbol, 0)
end

---@param game table
---@param name string
---@return table the catalogued phonebook contact with that key
local function contactByKey(game, name)
  local catalog = assert(game.runtime.pokegearCatalog, "the field runtime owns the ROM-derived phone catalog")
  for _, record in ipairs(assert(catalog.contacts, "the phone catalog carries its contacts")) do
    local entry = record --[[@as table<string, unknown>]]
    if entry.key == name then
      return entry
    end
  end
  error("the phonebook carries no contact " .. name, 0)
end

---@param game table
---@param family string
---@return table the first catalogued contact of the named conversation family
local function contactOfFamily(game, family)
  local catalog = assert(game.runtime.pokegearCatalog, "the field runtime owns the ROM-derived phone catalog")
  for _, record in ipairs(assert(catalog.contacts, "the phone catalog carries its contacts")) do
    local entry = record --[[@as table<string, unknown>]]
    if entry.family == family then
      return entry
    end
  end
  error("the phonebook carries no " .. family .. " contact", 0)
end

-- The phonebook contact of one source trainer object.
---@param game table
---@param object table
---@return table contact
local function contactForObject(game, object)
  local subject = assert(object.trainer, "a trainer object carries its produced trainer subject")
  local trainerId = assert(subject.trainerId, "the trainer subject carries its native identity")
  local catalog = assert(game.runtime.pokegearCatalog, "the field runtime owns the ROM-derived phone catalog")
  for _, record in ipairs(assert(catalog.contacts, "the phone catalog carries its contacts")) do
    local entry = record --[[@as table<string, unknown>]]
    if entry.trainerId == trainerId and entry.family == "trainer" then
      return entry
    end
  end
  error("the phonebook carries no trainer contact for native trainer " .. tostring(trainerId), 0)
end

-- The first source trainer object on the live map whose trainer the phonebook
-- knows: the one contact this scenario drives.
---@param game table
---@return table object, table contact
local function phoneTrainerOnMap(game)
  for _, candidate in ipairs(game.runtime.runtimeMap.fieldData.events.objects) do
    if type(candidate.trainer) == "table" then
      local ok, contact = pcall(contactForObject, game, candidate)
      if ok then
        return candidate, contact
      end
    end
  end
  error("the live map carries no trainer the phonebook knows", 0)
end

-- ---------------------------------------------------------------------------
-- Production boot and driving helpers.
-- ---------------------------------------------------------------------------

---@param sample table<string, integer>
---@return table clock the production host clock over the mutable sample
local function clockAt(sample)
  return LocalClock.new(function()
    return {
      year = sample.year,
      month = sample.month,
      day = sample.day,
      hour = sample.hour,
      minute = sample.minute,
      second = sample.second,
    }
  end)
end

---@param versionId string
---@param mapSymbol string
---@param spawn { fieldX: integer, fieldZ: integer } global field tile
---@param fieldOptions table<string, unknown>?
---@return table acceptance game
local function bootAt(versionId, mapSymbol, spawn, fieldOptions)
  local origin = mapOrigin(versionId, mapSymbol)
  local options = { recordingScriptHosts = true, audioHost = "recording" }
  for key, value in pairs(fieldOptions or {}) do
    options[key] = value
  end
  local harness = AcceptanceHarness.new({
    gameFactory = function(id, requestedMap)
      return FinalizedGameFixture.build(id, {
        location = {
          mapSymbol = requestedMap or mapSymbol,
          fieldX = spawn.fieldX - origin.x,
          fieldZ = spawn.fieldZ - origin.z,
          facing = "north",
        },
        worldState = FieldEventState.new(),
      })
    end,
  })
  local game = harness:boot({ versionId = versionId, map = mapSymbol, save = "fresh", fieldOptions = options })
  game:waitForFieldEntry()
  game:waitForFieldReady(480)
  return game
end

---@param game table
---@return table? active battle lifetime
local function activeBattle(game)
  local coordinator = game.runtime.battleCoordinator
  if coordinator == nil then
    return nil
  end
  return coordinator:activeBattle()
end

-- Foe positions in the source's position order; a single battle fields
-- position two.
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

---@param battle table
local function answerBattle(battle)
  local status = battle:status()
  if status.phase ~= "running" or status.request == nil then
    return
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
      return
    end
    lastErr = replyErr
  end
  Assert.isTrue(false, "the production battle accepts a legal decision: " .. tostring(lastErr))
end

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
      .. "; state="
      .. tostring(game:snapshot().mapSymbol)
      .. ":"
      .. tostring(game:snapshot().foregroundScript)
      .. "/locked="
      .. tostring(game:snapshot().fieldLocked)
      .. "; faults="
      .. table.concat(faults, ",")
  )
end

---@param game table
---@param label string
---@return table battle receipt once the field released the battle
local function fightToEnd(game, label)
  driveUntil(game, label, 9000, function()
    return activeBattle(game) == nil
  end)
  return assert(game.runtime.battleCoordinator:lastBattleResult(), "the settled battle published its result")
end

---@param game table
---@param label string
---@param budget integer
local function settleField(game, label, budget)
  return driveUntil(game, label, budget, function(snapshot)
    return activeBattle(game) == nil and not snapshot.fieldLocked and not snapshot.dialogue.modal
  end)
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

-- The tier the saved invitation currently offers through the same field
-- companion query the source invitation command reads.
---@param game table
---@param contact table
---@return integer the offered trainer tier, or zero when the invitation offers none
local function offeredTrainer(game, contact)
  local host = assert(game.runtime.pokegear and game.runtime.pokegear.scriptHost, "the field owns the script host")
  local offered = host:queryRematch(contact.key).trainerId
  Assert.equal(
    type(offered),
    "number",
    "the invitation answers a native trainer identity for " .. tostring(contact.key)
  )
  return offered --[[@as integer]]
end

---@param game table
---@param fieldX integer global field X
---@param fieldZ integer global field Z
---@return table? the live actor standing on that tile
local function actorAt(game, fieldX, fieldZ)
  for _, actor in ipairs(game.runtime.actors:actorsOf(game.runtime.runtimeMap.mapId)) do
    local committed = actor:getFieldPosition()
    if committed.fieldX == fieldX and committed.fieldZ == fieldZ then
      return actor
    end
  end
  return nil
end

---@param game table
---@param object table the generated trainer object the scenario answers
local function answerTrainer(game, object)
  local standing = game:snapshot().player
  Assert.deepEqual(
    { standing.fieldX, standing.fieldZ },
    { object.x, object.z + 1 },
    "the player starts on the tile a trainer is answered from"
  )
  local expected = assert(actorAt(game, object.x, object.z), "the source trainer actor stands on its object tile")
  game:face("north")
  game:pressAction()
  local interaction = game:interaction()
  Assert.equal(interaction.kind, "object", "the faced tile holds the source trainer")
  Assert.equal(
    interaction.actorId,
    expected.actorId,
    "the interaction names the source trainer, got " .. tostring(interaction.actorId)
  )
  return interaction.scriptId
end

-- ---------------------------------------------------------------------------
-- A saved invitation offers the source trainer tier of that contact (never a
-- readiness flag or the contact's call window), the shared trainer script
-- fights exactly that tier, and only a won rematch ends the invitation.
-- ---------------------------------------------------------------------------

function T.tests.a_staged_invitation_offers_the_source_rematch_tier_and_only_a_win_ends_it()
  local versionId = AcceptanceHarness.defaultVersion()
  local _, _, spawn = generatedMapTrainer(versionId, ROUTE_30)
  local game = bootAt(versionId, ROUTE_30, spawn)
  local ok, err = xpcall(function()
    local world = assert(game.runtime.scripts and game.runtime.scripts.worldState, "field scripts are composed")
    local state = assert(game.runtime.pokegearState, "the field runtime owns the phone state")
    local trainer, contact = phoneTrainerOnMap(game)
    -- The invitation is the source's own saved record for a registered
    -- contact that has asked for a rematch.
    state:registerContact(contact.key)

    -- Without a staged invitation the source offers no trainer at all.
    Assert.equal(offeredTrainer(game, contact), 0, "a contact that never asked for a rematch offers no trainer")

    -- A phonebook entry only exists for a trainer the player already beat, so
    -- his own defeat flag stands before any invitation resolves.
    world:setFlag(RuntimeValues.trainerFlagId(contact.trainerId))
    state:setRematch(contact.key, { stage = 1, wins = 0 })
    -- The source resolves the contact's first unbeaten rematch entry: the base
    -- trainer is beaten and the next tier's group is still locked, so the
    -- invitation falls back to the previous tier.
    Assert.equal(
      offeredTrainer(game, contact),
      contact.trainerId,
      "a locked rematch group falls back to the contact's own trainer tier"
    )

    -- The field clock stands outside the contact's own call window, and the
    -- invitation still resolves: the source command reads the saved
    -- invitation, never the outgoing call gates.
    local _, weekday = CivilDate.parts(game.runtime.localClock:nowLocal())
    Assert.isTrue(weekday ~= contact.rematchWeekday, "the field clock stands outside the contact's call window")

    -- Unlocking the next rematch group offers that later tier of the same
    -- trainer instead.
    world:setFlag(FieldScriptSymbols.flagsByName.FLAG_UNK_97D)
    local offered = offeredTrainer(game, contact)
    Assert.isTrue(offered >= 1, "a staged invitation offers a real source trainer identity")
    Assert.isTrue(offered ~= contact.trainerId, "an unlocked rematch group offers its own later trainer tier")

    giveMon(game, "TYPHLOSION", 100)
    giveMon(game, "QUILAVA", 90)
    local trainerScript = answerTrainer(game, trainer)
    Assert.notNil(trainerScript, "the trainer's shared source script is composed for the interaction")
    driveUntil(game, "the source rematch battle", 6000, function()
      return activeBattle(game) ~= nil
    end)
    local receipt = fightToEnd(game, "the source rematch battle settles")
    Assert.equal(receipt.result, "win", "the prepared party wins the source rematch battle")
    Assert.notNil(trainerScript, "the shared trainer script owns the interaction")

    -- The battle resolved the tier the invitation named: the source script
    -- marks that trainer tier defeated.
    local rematchFlag = RuntimeValues.trainerFlagId(offered)
    driveUntil(game, "the rematch trainer's defeat flag", 600, function()
      return world:isFlagSet(rematchFlag)
    end)
    Assert.isTrue(world:isFlagSet(rematchFlag), "the won rematch marks the offered trainer tier as defeated")

    -- Only the win ends the invitation.
    local cleared = state:queryRematch(contact.key)
    Assert.isTrue(cleared == nil or cleared.stage == 0, "the won rematch ends the saved invitation")
    Assert.equal(offeredTrainer(game, contact), 0, "a resolved invitation offers no trainer afterwards")
    settleField(game, "the rematch script ends", 2400)
    Assert.equal(game:renderAttempts(), 0, "the rematch journey stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- ---------------------------------------------------------------------------
-- A lost rematch never ends the saved invitation.
-- ---------------------------------------------------------------------------

function T.tests.a_lost_rematch_keeps_the_staged_invitation()
  local versionId = AcceptanceHarness.defaultVersion()
  local _, _, spawn = generatedMapTrainer(versionId, ROUTE_30)
  local game = bootAt(versionId, ROUTE_30, spawn)
  local ok, err = xpcall(function()
    local world = assert(game.runtime.scripts and game.runtime.scripts.worldState, "field scripts are composed")
    local state = assert(game.runtime.pokegearState, "the field runtime owns the phone state")
    local trainer, contact = phoneTrainerOnMap(game)
    state:registerContact(contact.key)
    state:setRematch(contact.key, { stage = 1, wins = 0 })
    world:setFlag(FieldScriptSymbols.flagsByName.FLAG_UNK_97D)
    local offered = offeredTrainer(game, contact)
    Assert.isTrue(offered >= 1, "the staged invitation offers a source trainer tier")

    -- A lead that cannot win the source rematch: the battle settles on the
    -- loss branch, which never reaches the invitation clear.
    giveMon(game, "TYPHLOSION", 2)
    answerTrainer(game, trainer)
    driveUntil(game, "the source rematch battle", 6000, function()
      return activeBattle(game) ~= nil
    end)
    local receipt = fightToEnd(game, "the lost rematch battle settles")
    Assert.equal(receipt.result, "loss", "the fragile lead loses the source rematch battle")

    local kept = state:queryRematch(contact.key)
    Assert.notNil(kept, "a lost rematch keeps its saved invitation")
    Assert.isTrue(kept.stage > 0, "a lost rematch keeps the invitation seeking")
    Assert.isFalse(
      world:isFlagSet(RuntimeValues.trainerFlagId(offered)),
      "a lost rematch never marks the offered trainer tier defeated"
    )
    Assert.equal(
      game.runtime.bagService:quantityNative(contact.gift),
      0,
      "a lost rematch hands over no contact gift"
    )
    Assert.equal(game:renderAttempts(), 0, "the lost rematch stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- ---------------------------------------------------------------------------
-- The contact gift commands read the loaded phonebook entry: a pending gift is
-- handed over once, and the same read consumes it.
-- ---------------------------------------------------------------------------

function T.tests.a_contact_gift_reads_the_loaded_entry_and_consumes_the_pending_item_once()
  local versionId = AcceptanceHarness.defaultVersion()
  local _, _, spawn = generatedMapTrainer(versionId, ROUTE_30)
  local game = bootAt(versionId, ROUTE_30, spawn)
  local ok, err = xpcall(function()
    local world = assert(game.runtime.scripts and game.runtime.scripts.worldState, "field scripts are composed")
    local state = assert(game.runtime.pokegearState, "the field runtime owns the phone state")
    local bag = assert(game.runtime.bagService, "the field runtime owns the Bag")
    local trainer, contact = phoneTrainerOnMap(game)
    -- The trainer is already beaten and no invitation waits, so the shared
    -- trainer script asks the contact gift commands for its caller.
    world:setFlag(RuntimeValues.trainerFlagId(contact.trainerId))
    state:registerContact(contact.key)
    local pending = "POTION"
    state:setContactReward(contact.key, { item = pending, quantity = 1 })
    Assert.equal(bag:quantity(pending), 0, "the pending gift is not in the Bag before the call")

    answerTrainer(game, trainer)
    settleField(game, "the pending gift script ends", 1200)
    local phone = state:readPhone()
    local entry = assert(phone.contacts[contact.key], "the contact stays registered")
    Assert.isNil(entry.reward, "the contact gift consumes the pending item in the same read")
    Assert.equal(bag:quantity(pending), 1, "the contact gift hands the pending item over exactly once")

    -- Answering again reaches the same commands with nothing pending, so no
    -- second reward appears.
    game:face("north")
    game:pressAction()
    settleField(game, "the second gift script ends", 1200)
    Assert.equal(bag:quantity(pending), 1, "a collected contact gift never rewards a second time")
    Assert.equal(game:renderAttempts(), 0, "the gift journey stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- ---------------------------------------------------------------------------
-- Kenji's invitation waits for its own daytime, and a contact without a
-- rematch row never offers a trainer.
-- ---------------------------------------------------------------------------

function T.tests.a_kenji_invitation_waits_for_daytime_and_a_plain_contact_offers_none()
  local versionId = AcceptanceHarness.defaultVersion()
  local sample = { year = 2000, month = 1, day = 3, hour = 22, minute = 0, second = 0 }
  local game = bootAt(versionId, ROUTE_34_DAYCARE, DAYCARE_TILE, { localClock = clockAt(sample) })
  local ok, err = xpcall(function()
    local state = assert(game.runtime.pokegearState, "the field runtime owns the phone state")
    local kenji = contactOfFamily(game, "kenji")
    local elm = contactByKey(game, ELM_CONTACT)
    state:registerContact(kenji.key)
    state:registerContact(elm.key)
    state:setRematch(kenji.key, { stage = 1, wins = 0 })
    state:setRematch(elm.key, { stage = 1, wins = 0 })

    Assert.equal(offeredTrainer(game, kenji), 0, "Kenji's invitation waits for its own daytime")
    Assert.equal(offeredTrainer(game, elm), 0, "a contact without a rematch row never offers a trainer")

    -- The same saved invitation a few field hours later: the source daytime
    -- gate opens and offers Kenji's own tier.
    sample.hour = 12
    Assert.equal(
      offeredTrainer(game, kenji),
      kenji.trainerId,
      "Kenji's invitation offers his own trainer tier during the day"
    )
    Assert.equal(offeredTrainer(game, elm), 0, "a plain contact never offers a trainer at any hour")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- ---------------------------------------------------------------------------
-- A durable Day Care breeding trigger and the hatched original egg's trigger
-- each schedule exactly one incoming call through the existing incoming-call
-- owner, and a status query never replays one.
-- ---------------------------------------------------------------------------

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
---@return table the live mon service
local function mons(game)
  return assert(game.runtime.monService, "the field runtime owns its mon service")
end

---@param game table
---@param label string
---@return table the settled captured game save
local function settledCapture(game, label)
  local lastError = nil
  for _ = 1, 480 do
    local ok, record = pcall(game.runtime.captureGameSave, game.runtime)
    if ok and record ~= nil then
      return record
    end
    lastError = ok and "capture returned no record" or tostring(record)
    game:step()
  end
  error("the settled field never accepted its save: " .. label .. "; last failure: " .. tostring(lastError), 0)
end

-- A deterministic personality the species' own ratio resolves to the requested
-- gender, so the stored pair is the source's compatible male/female couple.
---@param ratio integer
---@param gender string
---@return integer
local function personalityFor(ratio, gender)
  for index = 1, 800 do
    local candidate = (index * 7919 + 13) % U32.MAX
    if Personality.gender(ratio, candidate) == gender then
      return candidate
    end
  end
  error("no personality resolves to " .. gender, 0)
end

-- Two same-species parents owned by different trainers reach the source
-- maximum compatibility; the Day Care then owns their stored records.
---@param versionId string
---@return { records: table[], mons: table } the prepared parents and the party-free mons bucket
local function stageParents(versionId)
  local game = AcceptanceHarness.new():boot({
    versionId = versionId,
    map = ROUTE_34_DAYCARE,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local prepared = nil
  local ok, err = xpcall(function()
    Assert.isTrue(
      mons(game):giveMon({ species = "SNORLAX", level = 20, form = 0, heldItem = "NONE" }),
      "the staging party takes its first parent"
    )
    Assert.isTrue(
      mons(game):giveMon({ species = "SNORLAX", level = 20, form = 0, heldItem = "NONE" }),
      "the staging party takes its second parent"
    )
    for index = 0, 1 do
      local mon = assert(mons(game):partyMon(index), "the staged parent is in the party")
      local genderRatio = mons(game):catalog():species("SNORLAX").genderRatio
      mon.personality = personalityFor(genderRatio, index == 0 and "female" or "male")
      mon.origin.trainerId = 41 + index
      mon.condition = { currentHp = mons(game):derive(mon).maxHp, effects = {} }
      local preparation, reason =
        mons(game):preparePartyChanges(mons(game):partyRevision(), { { slot = index, mon = mon } })
      Assert.isNil(reason, "the prepared parent change stages cleanly")
      assert(preparation).publish()
    end
    local capture = settledCapture(game, "the staged parents")
    local records = {}
    for index = 1, 2 do
      records[index] = copy(capture.mons.party.mons[index])
    end
    capture.mons.party.mons = {}
    prepared = { records = records, mons = capture.mons }
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
  return prepared
end

---@param prepared { records: table[], mons: table }
---@param sample table<string, integer> mutable host clock sample
---@return table acceptance game in the Day Care room
local function bootCareRoom(prepared, sample)
  local monsBucket = copy(prepared.mons)
  monsBucket.rng = Lcrng.new(SEED_STEP):capture()
  local slots = {}
  for index, record in ipairs(prepared.records) do
    -- One committed step is all the source breeding check still needs.
    slots[index] = { mon = copy(record), steps = 254 }
  end
  local daycare = {
    schema = DAYCARE_BUCKET_SCHEMA,
    slots = slots,
    pendingEggPid = 0,
    -- The source check runs on the 255th cycle value, so one committed step
    -- completes it.
    eggCycleCounter = 254,
  }
  local harness = AcceptanceHarness.new({
    gameFactory = function(id, requestedMap)
      local worldState = FieldEventState.new()
      -- The Route 34 map frame script alternates two policeman objects by time
      -- of day; the daytime state keeps exactly one of them.
      worldState:setFlag(FieldScriptSymbols.flagsByName.FLAG_UNK_1D2)
      local game = FinalizedGameFixture.build(id, {
        location = {
          mapSymbol = requestedMap or ROUTE_34_DAYCARE,
          fieldX = DAYCARE_TILE.fieldX,
          fieldZ = DAYCARE_TILE.fieldZ,
          facing = "south",
        },
        worldState = worldState,
        mons = monsBucket,
      })
      game.daycare = daycare
      return game
    end,
  })
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = ROUTE_34_DAYCARE,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording", localClock = clockAt(sample) },
  })
  game:waitForFieldEntry()
  game.runtime:bindPartyIconPreparation(function()
    return true
  end, function() end)
  return game
end

---@param game table
---@param direction string
---@return boolean committed whether production movement left the tile
local function tryStep(game, direction)
  if game:snapshot().player.facing ~= direction then
    game:face(direction)
  end
  local before = game:snapshot().player
  game:move(direction)
  local after = game:advanceUntil("movement resolves", function(snapshot)
    return snapshot.player.motion == "idle"
  end, 120)
  return after.player.fieldX ~= before.fieldX or after.player.fieldZ ~= before.fieldZ
end

-- Faces away from everything interactable so an action edge answers the ringing
-- call instead of talking to a neighbour.
---@param game table
local function faceAwayFromInteractables(game)
  for _, direction in ipairs({ "north", "south", "west", "east" }) do
    game:face(direction)
    if game:interaction().kind == nil then
      return
    end
  end
end

-- Plays the live call to its source hangup.
---@param game table
---@param host table companion script host
---@return boolean sawText
local function playCallToHangup(game, host)
  local sawText = false
  for _ = 1, 2000 do
    if not host:isActive() then
      break
    end
    local view = assert(host:status(), "the live call keeps its status").view.call
    if type(view) == "table" and type(view.lines) == "table" and #view.lines > 0 then
      sawText = true
    end
    game:pressAction()
  end
  return sawText
end

-- Advances one live field minute per fixed tick: the incoming-call owner
-- accumulates its eligibility minutes from the field clock.
---@param game table
---@param sample table<string, integer> mutable host clock sample
---@param calls table incoming-call owner
---@param minutes integer
---@return boolean rang
local function ringAfterMinutes(game, sample, calls, minutes)
  for _ = 1, minutes do
    sample.minute = sample.minute + 1
    if sample.minute >= 60 then
      sample.minute = 0
      sample.hour = (sample.hour + 1) % 24
    end
    game:step()
    if calls:notification() ~= false then
      return true
    end
  end
  return false
end

function T.tests.a_durable_phone_trigger_rings_once_and_a_query_never_replays_it()
  local versionId = AcceptanceHarness.defaultVersion()
  local prepared = stageParents(versionId)
  local sample = { year = 2000, month = 1, day = 5, hour = 12, minute = 0, second = 0 }
  local game = bootCareRoom(prepared, sample)
  local ok, err = xpcall(function()
    local state = assert(game.runtime.pokegearState, "the field runtime owns the phone state")
    local calls = assert(game.runtime.incomingCalls, "the field runtime owns the incoming-call policy")
    local host = assert(game.runtime.pokegear.scriptHost, "the companion host owns the call")
    local man = contactByKey(game, DAYCARE_MAN_CONTACT)
    local elm = contactByKey(game, ELM_CONTACT)

    -- The real breeding check on the source step raises the durable Day-Care
    -- trigger; nothing has rung yet.
    Assert.isTrue(tryStep(game, "south"), "the Day Care room offers the committed step")
    Assert.isTrue(
      state:readPhone().triggers[DAYCARE_TRIGGER] == true,
      "the breeding roll raises the durable Day-Care trigger"
    )
    Assert.isFalse(calls:notification(), "no call rings before its eligibility minutes elapse")

    -- The Day-Care Man's number is not registered yet, so the existing owner
    -- never rings his trigger.
    Assert.isFalse(ringAfterMinutes(game, sample, calls, 15), "an unregistered Day-Care Man never rings")

    -- Registration opens the source gate: the same durable trigger now rings
    -- its owner exactly once.
    state:registerContact(man.key)
    Assert.isTrue(ringAfterMinutes(game, sample, calls, 30), "the durable Day-Care trigger rings once registered")
    Assert.equal(calls:notification().contactKey, man.key, "the ring names the Day-Care Man")

    -- Status queries never replay or duplicate the notification.
    for _ = 1, 5 do
      Assert.equal(calls:notification().contactKey, man.key, "the same ring keeps its caller")
      Assert.isTrue(calls:hasPendingCall(), "status queries keep the one pending call")
      Assert.isTrue(
        state:readPhone().triggers[DAYCARE_TRIGGER] == true,
        "status queries never clear the trigger"
      )
    end

    -- Answering plays the call to its source hangup and consumes the trigger.
    faceAwayFromInteractables(game)
    game:pressAction()
    Assert.isTrue(playCallToHangup(game, host), "the Day-Care call prints its source text")
    Assert.isFalse(host:isActive(), "the Day-Care call reaches its hangup")
    Assert.isNil(state:readPhone().triggers[DAYCARE_TRIGGER], "the answered call consumes its trigger")
    Assert.isFalse(ringAfterMinutes(game, sample, calls, 40), "the answered Day-Care call never rings again")

    -- The hatched original egg's trigger follows the same one-call rule for a
    -- caller the story has already put in the phonebook.
    state:registerContact(elm.key)
    calls:setTrigger(ELM_TRIGGER, true)
    Assert.isTrue(ringAfterMinutes(game, sample, calls, 30), "the hatched egg's trigger rings its owner")
    Assert.equal(calls:notification().contactKey, elm.key, "the hatched egg's call names Elm")
    for _ = 1, 5 do
      Assert.equal(calls:notification().contactKey, elm.key, "the egg ring keeps its caller")
      Assert.isTrue(calls:hasPendingCall(), "the egg ring stays the one pending call")
    end
    faceAwayFromInteractables(game)
    game:pressAction()
    playCallToHangup(game, host)
    Assert.isFalse(host:isActive(), "the egg call reaches its hangup")
    Assert.isNil(state:readPhone().triggers[ELM_TRIGGER], "the answered egg call consumes its trigger")
    Assert.isFalse(ringAfterMinutes(game, sample, calls, 40), "the answered egg call never rings again")
    Assert.equal(game:renderAttempts(), 0, "the notification journey stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
