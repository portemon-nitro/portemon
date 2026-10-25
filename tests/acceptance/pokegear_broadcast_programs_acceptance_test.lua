-- Daily broadcast and field agreement: the password show and the swarm
-- report speak the same shared daily identity the field script consults,
-- listening awards no points or items, a save/load round trip never
-- rerolls the answer, and both sides still agree after a day boundary with
-- the source daily password update. The scenario composes the real durable
-- owners (companion state and calendar, field event state, encounter
-- bucket) with the real broadcast projection and dispatcher, stopping
-- before any rendering; audio is the completion-controlled facade surface
-- and every wait is bounded. No broadcast prose enters the repository.

local Assert = require("tests.support.Assert")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearState = require("libs.hgss.src.save.PokegearState")
local PokegearCalendar = require("game.hgss.src.pokegear.PokegearCalendar")
local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local EncounterSave = require("libs.hgss.src.save.EncounterSave")
local Fixture = require("tests.support.PokegearBroadcastFixture")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

local COMMERCIAL_KEY = "radio.commercial"
local BUENA_KEY = "radio.buena"
local MONDAY = { year = 2024, month = 1, day = 8, hour = 10, minute = 0, second = 0 }

---@param catalog table<string, unknown>
---@param opts table<string, unknown>
---@return table<string, unknown> setup
local function setup(catalog, opts)
  local seed = assert(opts.seed, "broadcast scenarios start from an explicit seed")
  local state = PokegearState.new({ seed = seed }, { catalog = catalog })
  local calendar = PokegearCalendar.new(state)
  local random = PokegearRandom.new(seed, { trace = {}, traceLimit = 8192 })
  local events = FieldEventState.new()
  events:setVar(FieldScriptSymbols.variablesByName.VAR_BUENAS_PASSWORD_SET, opts.passwordVar or 47)
  local bucket = EncounterSave.initial()
  bucket.swarm = true
  local encounters = EncounterSave.restore(bucket, { species = {}, maps = {} })
  local RadioWorldContext = Fixture.requireFeature(
    "game.hgss.src.pokegear.RadioWorldContext",
    "broadcast world facts have no shared projection yet: the daily password and swarm have no common identity"
  )
  local world = RadioWorldContext.new({
    state = state,
    calendar = calendar,
    eventState = events,
    encounters = encounters,
    dex = Fixture.newDexReader(false),
    bag = Fixture.newBagReader({ BLUE_CARD = true }),
  })
  local civil = Fixture.newCivilCell(opts.moment or MONDAY)
  local audio = Fixture.newAudioStandIn()
  local messages = Fixture.newMessageLog()
  local RadioProgram = Fixture.requireFeature(
    "game.hgss.src.pokegear.RadioProgram",
    "broadcast programs have no dispatcher yet: the password show cannot be heard"
  )
  local program = RadioProgram.new({
    catalog = catalog,
    world = world,
    clock = civil.clock,
    random = random,
    audio = audio,
    messages = messages,
  })
  return {
    state = state,
    calendar = calendar,
    events = events,
    world = world,
    program = program,
    audio = audio,
    messages = messages,
    civil = civil,
  }
end

-- Finds the hour whose cycling-station show is the password broadcast.
---@param catalog table<string, unknown>
---@param first table<string, unknown>
---@return integer hour
local function findPasswordHour(first)
  local program = first.program
  local civil = first.civil
  for hour = 0, 23 do
    Fixture.setCivil(
      civil.cell,
      { year = MONDAY.year, month = MONDAY.month, day = MONDAY.day, hour = hour, minute = 0, second = 0 }
    )
    program:begin(3, "clear")
    for _ = 1, 800 do
      program:updateFixed()
      if program:status().show ~= COMMERCIAL_KEY then
        break
      end
    end
    local show = program:status().show
    program:endProgram()
    if show == BUENA_KEY then
      return hour
    end
  end
  error("the password broadcast never tunes on the cycling station", 0)
end

-- Listens at the password hour until the heard flag commits, then returns
-- the broadcast-side reported password index.
---@param setupRecord table<string, unknown>
---@param hour integer
---@return integer password
local function listenUntilHeard(setupRecord, hour)
  local program = setupRecord.program
  local events = setupRecord.events
  local civil = setupRecord.civil
  local now = civil.cell.now
  Fixture.setCivil(
    civil.cell,
    { year = now.year, month = now.month, day = now.day, hour = hour, minute = 0, second = 0 }
  )
  program:begin(3, "clear")
  for _ = 1, 1200 do
    program:updateFixed()
    if events:isFlagSet(FieldScriptSymbols.flagsByName.FLAG_DAILY_HEARD_BUENAS_PASSWORD) then
      break
    end
  end
  Assert.isTrue(
    events:isFlagSet(FieldScriptSymbols.flagsByName.FLAG_DAILY_HEARD_BUENAS_PASSWORD),
    "hearing the password show commits the heard flag"
  )
  local world = setupRecord.world
  local password = world:buenaPassword()
  Assert.isTrue(
    type(password) == "number" and password % 1 == 0 and password >= 0 and password < 30,
    "the broadcast password is a thirty-entry index"
  )
  return password
end

---@param events table<string, unknown>
local function checkNoRewards(events)
  Assert.equal(
    events:getVar(FieldScriptSymbols.variablesByName.VAR_BLUE_CARD_POINTS),
    0,
    "listening awards no card points"
  )
  Assert.equal(
    events:getVar(FieldScriptSymbols.variablesByName.VAR_NUM_TIMES_GIVEN_BLUE_CARD),
    0,
    "listening awards no card items"
  )
end

function T.tests.daily_broadcast_and_field_answers_share_one_identity_across_save_and_day_change()
  local validated = PokegearAssetSchema.validate(Fixture.fixtureManifest())
  Assert.notNil(validated, "the broadcast catalog validates through the asset schema")
  local catalog = assert(validated, "the catalog reads above").catalog

  local first = setup(catalog, { seed = 31337, passwordVar = 47 })
  local hour = findPasswordHour(first)
  local refs = Fixture.catalogRefs(assert(validated, "the catalog reads above"))

  -- One shared identity: the broadcast password matches the field
  -- variable modulo 30, and the broadcast swarm carries the active flag
  -- with the exact outbreak seed from the shared daily identity.
  local password = listenUntilHeard(first, hour)
  Assert.equal(password, 47 % 30, "the broadcast voices the field password identity")
  Assert.equal(
    first.events:getVar(FieldScriptSymbols.variablesByName.VAR_BUENAS_PASSWORD_SET) % 30,
    password,
    "the field answer agrees with the broadcast password"
  )
  local swarm = first.world:dailySwarm()
  Assert.isTrue(swarm.active == true, "the broadcast swarm matches the active field outbreak")
  Assert.equal(
    swarm.seed,
    first.state:readDailyIdentity().outbreakSeed,
    "the broadcast swarm draws on the shared outbreak seed, not a private reroll"
  )
  checkNoRewards(first.events)
  local seedBeforeSave = first.state:readDailyIdentity().outbreakSeed
  first.program:endProgram()

  -- Save and load round trip through the real durable owners: restoring
  -- companion state, event state, and the encounter bucket never rerolls
  -- either answer.
  local gearBucket = first.state:capture()
  local eventBucket = first.events:serialize()
  local encounterBucket = EncounterSave.initial()
  encounterBucket.swarm = true
  local restoredEncounters = EncounterSave.restore(encounterBucket, { species = {}, maps = {} })
  local state2 = PokegearState.restore(gearBucket, refs)
  local calendar2 = PokegearCalendar.new(state2)
  local events2 = FieldEventState.new(eventBucket)
  local RadioWorldContext = Fixture.requireFeature(
    "game.hgss.src.pokegear.RadioWorldContext",
    "broadcast world facts have no shared projection yet: restored facts cannot be reprojected"
  )
  local world2 = RadioWorldContext.new({
    state = state2,
    calendar = calendar2,
    eventState = events2,
    encounters = restoredEncounters,
    dex = Fixture.newDexReader(false),
    bag = Fixture.newBagReader({ BLUE_CARD = true }),
  })
  local civil2 = Fixture.newCivilCell(MONDAY)
  local RadioProgram = Fixture.requireFeature(
    "game.hgss.src.pokegear.RadioProgram",
    "broadcast programs have no dispatcher yet: restored facts cannot be reheard"
  )
  local program2 = RadioProgram.new({
    catalog = catalog,
    world = world2,
    clock = civil2.clock,
    random = PokegearRandom.new(31337, { trace = {}, traceLimit = 8192 }),
    audio = Fixture.newAudioStandIn(),
    messages = Fixture.newMessageLog(),
  })
  local second = {
    state = state2,
    calendar = calendar2,
    events = events2,
    world = world2,
    program = program2,
    civil = civil2,
  }
  Assert.equal(
    state2:readDailyIdentity().outbreakSeed,
    seedBeforeSave,
    "reloading never rerolls the shared outbreak seed"
  )
  local password2 = listenUntilHeard(second, hour)
  Assert.equal(password2, 47 % 30, "reloading never rerolls the broadcast password")
  Assert.equal(
    events2:getVar(FieldScriptSymbols.variablesByName.VAR_BUENAS_PASSWORD_SET) % 30,
    password2,
    "the field answer still agrees after the round trip"
  )
  local swarm2 = world2:dailySwarm()
  Assert.isTrue(swarm2.active == true, "the restored broadcast swarm stays active")
  Assert.equal(
    swarm2.seed,
    state2:readDailyIdentity().outbreakSeed,
    "the restored broadcast swarm keeps the shared seed"
  )
  checkNoRewards(events2)
  program2:endProgram()

  -- Day boundary: the calendar steps the shared identity once, the source
  -- daily password update lands in the field variable, and both sides
  -- agree again without any award. The stepped relations follow the locked
  -- calendar contract: the group advances, the outbreak follows the
  -- stepped group, and a second crossing moves the outbreak itself.
  local groupBefore = state2:readDailyIdentity().dailyGroupSeed
  local crossed = calendar2:observeField({ year = 2024, month = 1, day = 9, hour = 10, minute = 0, second = 0 })
  Assert.equal(crossed.dayAdvance, 1, "crossing midnight advances exactly one daily identity")
  local stepped = state2:readDailyIdentity()
  Assert.isTrue(stepped.dailyGroupSeed ~= groupBefore, "the day boundary steps the shared group seed")
  Assert.equal(stepped.outbreakSeed, stepped.dailyGroupSeed, "the outbreak follows the stepped group seed")
  events2:setVar(FieldScriptSymbols.variablesByName.VAR_BUENAS_PASSWORD_SET, 48)
  Fixture.setCivil(second.civil.cell, { year = 2024, month = 1, day = 9, hour = 10, minute = 0, second = 0 })
  local password3 = listenUntilHeard(second, hour)
  Assert.equal(password3, 48 % 30, "the broadcast follows the source daily password update")
  Assert.equal(
    events2:getVar(FieldScriptSymbols.variablesByName.VAR_BUENAS_PASSWORD_SET) % 30,
    password3,
    "the field answer agrees with the broadcast after the day boundary"
  )
  local swarm3 = world2:dailySwarm()
  Assert.equal(
    swarm3.seed,
    state2:readDailyIdentity().outbreakSeed,
    "the broadcast swarm follows the stepped identity after the day boundary"
  )
  checkNoRewards(events2)
  local crossedAgain = calendar2:observeField({ year = 2024, month = 1, day = 10, hour = 10, minute = 0, second = 0 })
  Assert.equal(crossedAgain.dayAdvance, 1, "the second crossing advances exactly one more daily identity")
  Assert.isTrue(
    state2:readDailyIdentity().outbreakSeed ~= seedBeforeSave,
    "the outbreak changes across two day boundaries"
  )
  program2:endProgram()
  program2:dispose()
  first.program:dispose()
end

return T
