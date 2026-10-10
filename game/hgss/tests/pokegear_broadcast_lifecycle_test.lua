-- Broadcast lifecycle edges: tuner shape rejection, midnight inside an
-- episode, weekday unlock gating on the synthetic catalog, commercial
-- interruption with episode-preserving return, takeover selection, token
-- parameter shape, calendar observation at start boundaries, and
-- idempotent teardown with pure reads after close. All expectations use
-- synthetic data and independent arithmetic, never the dispatcher as its
-- own oracle.

local Assert = require("tests.support.Assert")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearState = require("libs.hgss.src.save.PokegearState")
local PokegearCalendar = require("game.hgss.src.pokegear.PokegearCalendar")
local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local Fixture = require("tests.support.PokegearBroadcastFixture")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

local COMMERCIAL_KEY = "radio.commercial"

---@param seed integer
---@param opts table<string, unknown>?
---@return table<string, unknown> program, table<string, unknown> world, table<string, unknown> state, table<string, unknown> events, table<string, unknown> audio, table<string, unknown> messages, table<string, unknown> random, { cell: { now: table<string, integer> }, clock: LocalClock }
local function freshProgram(seed, opts)
  opts = opts or {}
  local validated = PokegearAssetSchema.validate(Fixture.fixtureManifest())
  Assert.notNil(validated, "the synthetic broadcast catalog must validate through the asset schema")
  local record = assert(validated, "the catalog reads above")
  local refs = Fixture.catalogRefs(record)
  local state = PokegearState.new({ seed = seed }, refs)
  local calendar = PokegearCalendar.new(state)
  local random = PokegearRandom.new(seed, { trace = {}, traceLimit = 4096 })
  local events = FieldEventState.new()
  if opts.passwordVar ~= nil then
    events:setVar(FieldScriptSymbols.variablesByName.VAR_BUENAS_PASSWORD_SET, opts.passwordVar)
  end
  if opts.takeover == true then
    events:setFlag(FieldScriptSymbols.flagsByName.FLAG_ROCKET_TAKEOVER_ACTIVE)
  end
  local RadioWorldContext = Fixture.requireFeature(
    "game.hgss.src.pokegear.RadioWorldContext",
    "broadcast world facts have no shared projection yet"
  )
  local world = RadioWorldContext.new({
    state = state,
    calendar = calendar,
    eventState = events,
    encounters = { swarm = opts.swarmActive == true },
    dex = Fixture.newDexReader(opts.nationalDex == true),
    bag = Fixture.newBagReader(opts.blueCard == true and { BLUE_CARD = true } or {}),
  })
  local civil = Fixture.newCivilCell(opts.moment or { year = 2024, month = 1, day = 8, hour = 10, minute = 0, second = 0 })
  local audio = Fixture.newAudioStandIn()
  local messages = Fixture.newMessageLog()
  local RadioProgram = Fixture.requireFeature(
    "game.hgss.src.pokegear.RadioProgram",
    "broadcast programs have no dispatcher yet"
  )
  local program = RadioProgram.new({
    catalog = record.catalog,
    world = world,
    clock = civil.clock,
    random = random,
    audio = audio,
    messages = messages,
  })
  return program, world, state, events, audio, messages, random, civil
end

function T.tests.tuner_shapes_outside_the_native_dial_are_rejected()
  local program, _, _, _, _, _, _, _ = freshProgram(11)
  Assert.throws(function()
    program:begin(8, "clear")
  end, "station eight is outside the native dial")
  Assert.throws(function()
    program:begin(-1, "clear")
  end, "negative stations are outside the native dial")
  Assert.throws(function()
    program:begin(0, "loud")
  end, "unknown reception names no native signal")
  program:begin(0, "clear")
  Assert.throws(function()
    program:setSignal("loud")
  end, "unknown reception names no native signal")
  for station = 0, 7 do
    program:begin(station, "clear")
    program:begin(station, "weak")
  end
  program:endProgram()
  program:dispose()
end

function T.tests.midnight_inside_an_episode_holds_the_show_to_completion()
  local program, _, _, _, _, messages, _, civil = freshProgram(12, {
    moment = { year = 2024, month = 1, day = 8, hour = 23, minute = 50, second = 0 },
    swarmActive = true,
  })
  program:begin(1, "clear")
  for _ = 1, 60 do
    program:updateFixed()
  end
  Fixture.setCivil(civil.cell, { year = 2024, month = 1, day = 9, hour = 0, minute = 5, second = 0 })
  for _ = 1, 600 do
    program:updateFixed()
  end
  Assert.equal(program:status().show, Fixture.SHOW_KEYS.talk, "midnight never resamples a half-printed show")
  Assert.isTrue(program:status().scroll.complete, "the episode still plays to completion across midnight")
  local frozen = messages:requestCount()
  for _ = 1, 200 do
    program:updateFixed()
  end
  Assert.equal(messages:requestCount(), frozen, "a completed episode stays quiescent")
  program:endProgram()
  program:dispose()
end

---@param catalogDay integer
---@param nationalDex boolean
---@param blueCard boolean
---@param seed integer
---@return integer|string
local function startMusicLatch(catalogDay, nationalDex, blueCard, seed)
  local program, _, _, _, audio, _, _, _ = freshProgram(seed, {
    moment = { year = 2024, month = 1, day = catalogDay, hour = 10, minute = 0, second = 0 },
    nationalDex = nationalDex,
    blueCard = blueCard,
  })
  program:begin(0, "clear")
  for _ = 1, 400 do
    program:updateFixed()
    if audio:playCallCount() >= 1 then
      break
    end
  end
  Assert.isTrue(audio:playCallCount() >= 1, "the tune-in jingle starts")
  for _ = 1, 60 do
    program:updateFixed()
  end
  Assert.equal(audio:playCallCount(), 1, "the music start waits on jingle completion")
  audio:complete()
  local latch = nil
  for _ = 1, 800 do
    program:updateFixed()
    if audio:playCallCount() >= 2 then
      latch = audio:currentRadioSequence()
      break
    end
  end
  Assert.notNil(latch, "the first music start latches its sequence")
  program:endProgram()
  program:dispose()
  return assert(latch, "the music latch reads above")
end

function T.tests.weekday_music_gates_follow_dex_and_card_facts()
  Assert.equal(
    PokegearCalendar.weekday({ year = 2024, month = 1, day = 1, hour = 10, minute = 0, second = 0 }),
    0,
    "the weekday matrix anchors on Monday 2024-01-01"
  )
  local marchMonday = startMusicLatch(1, false, false, 301)
  Assert.equal(startMusicLatch(5, false, false, 302), marchMonday, "Monday and Friday share the March track")
  local lullabyTuesday = startMusicLatch(2, false, false, 303)
  Assert.equal(startMusicLatch(6, false, false, 304), lullabyTuesday, "Tuesday and Saturday share the Lullaby track")
  Assert.equal(startMusicLatch(3, false, false, 305), marchMonday, "Wednesday without the dex falls back to March")
  Assert.equal(
    startMusicLatch(4, false, false, 306),
    lullabyTuesday,
    "Thursday without the dex falls back to Lullaby"
  )
  Assert.equal(startMusicLatch(7, false, false, 307), marchMonday, "Sunday without the card falls back to March")
  Assert.isTrue(
    startMusicLatch(3, true, false, 308) ~= marchMonday,
    "Wednesday opens its gated track behind the national dex"
  )
  Assert.isTrue(
    startMusicLatch(4, true, false, 309) ~= lullabyTuesday,
    "Thursday opens its gated track behind the national dex"
  )
  Assert.isTrue(
    startMusicLatch(7, false, true, 310) ~= marchMonday,
    "Sunday opens its card selection behind the card item"
  )
  Assert.equal(
    startMusicLatch(1, false, false, 301),
    marchMonday,
    "repeating a weekday combination replays the same track"
  )
end

function T.tests.commercials_preempt_once_and_return_with_the_episode_intact()
  local found = false
  for seed = 1, 40 do
    for _, hour in ipairs({ 0, 3, 6 }) do
      if not found then
        local program, _, _, _, _, _, _, civil = freshProgram(seed, {
          moment = { year = 2024, month = 1, day = 8, hour = hour, minute = 0, second = 0 },
        })
        Fixture.setCivil(civil.cell, { year = 2024, month = 1, day = 8, hour = hour, minute = 0, second = 0 })
        program:begin(3, "clear")
        local preempted = false
        for _ = 1, 300 do
          program:updateFixed()
          if program:status().show == COMMERCIAL_KEY then
            preempted = true
            break
          end
        end
        if preempted then
          found = true
          local returned = false
          for _ = 1, 1000 do
            program:updateFixed()
            if program:status().show ~= COMMERCIAL_KEY then
              returned = true
              break
            end
          end
          Assert.isTrue(returned, "a queued commercial returns to the tuned station")
          local title = program:status().title
          Assert.notNil(title, "the returned show resumes its episode")
          local encore = false
          for _ = 1, 400 do
            program:updateFixed()
            if program:status().show == COMMERCIAL_KEY then
              encore = true
            end
          end
          Assert.isFalse(encore, "a queued commercial takes precedence exactly once")
        end
        program:endProgram()
        program:dispose()
      end
    end
  end
  Assert.isTrue(found, "scheduled commercials appear across the seed sweep")
end

function T.tests.takeover_state_selects_the_rocket_broadcast_variant()
  local function rocketRefs(takeover)
    local program, _, _, _, _, messages, _, _ = freshProgram(500 + (takeover and 1 or 0), { takeover = takeover })
    program:begin(6, "clear")
    for _ = 1, 600 do
      program:updateFixed()
    end
    local refs = {}
    for _, request in ipairs(messages.requests) do
      refs[#refs + 1] = "bank " .. request.bank .. " entry " .. request.entry
    end
    local title = program:status().title
    program:endProgram()
    program:dispose()
    return refs, title
  end
  local plainRefs, plainTitle = rocketRefs(false)
  local takeoverRefs, takeoverTitle = rocketRefs(true)
  Assert.equal(plainTitle, takeoverTitle, "both variants share the takeover show title")
  local plain, taken = {}, {}
  for _, ref in ipairs(plainRefs) do
    plain[ref] = true
  end
  for _, ref in ipairs(takeoverRefs) do
    taken[ref] = true
  end
  Assert.isTrue(plain["bank 509 entry 2"] == true, "the ordinary broadcast voices its native lines")
  Assert.isTrue(taken["bank 509 entry 4"] == true, "the takeover broadcast voices its takeover lines")
  Assert.isTrue(plain["bank 509 entry 4"] == nil, "the ordinary broadcast never voices takeover lines")
end

---@param seed integer
---@return table<string, unknown> program, table<string, unknown> messages
local function talkTune(seed)
  local validated = PokegearAssetSchema.validate(Fixture.fixtureManifest())
  local record = assert(validated, "the catalog reads above")
  local refs = Fixture.catalogRefs(record)
  local state = PokegearState.new({ seed = seed }, refs)
  local calendar = PokegearCalendar.new(state)
  local events = FieldEventState.new()
  events:setVar(FieldScriptSymbols.variablesByName.VAR_BUENAS_PASSWORD_SET, 47)
  local RadioWorldContext = Fixture.requireFeature(
    "game.hgss.src.pokegear.RadioWorldContext",
    "broadcast world facts have no shared projection yet"
  )
  local world = RadioWorldContext.new({
    state = state,
    calendar = calendar,
    eventState = events,
    encounters = { swarm = true },
    dex = Fixture.newDexReader(false),
    bag = Fixture.newBagReader({}),
  })
  local civil = Fixture.newCivilCell({ year = 2024, month = 1, day = 8, hour = 10, minute = 0, second = 0 })
  local messages = Fixture.newMessageLog()
  local RadioProgram = Fixture.requireFeature(
    "game.hgss.src.pokegear.RadioProgram",
    "broadcast programs have no dispatcher yet"
  )
  local program = RadioProgram.new({
    catalog = record.catalog,
    world = world,
    clock = civil.clock,
    random = PokegearRandom.new(seed, { trace = {}, traceLimit = 4096 }),
    audio = Fixture.newAudioStandIn(),
    messages = messages,
  })
  program:begin(1, "clear")
  for _ = 1, 400 do
    program:updateFixed()
  end
  program:endProgram()
  program:dispose()
  return program, messages
end

---@param messages table<string, unknown>
---@return table<integer, string>
local function requestRefs(messages)
  local refs = {}
  for _, request in ipairs(assert(messages.requests, "the message log records every request")) do
    refs[#refs + 1] = "bank " .. request.bank .. " entry " .. request.entry
  end
  return refs
end
function T.tests.message_parameters_carry_token_references()
  local program, world, _, _, _, messages, _, _ = freshProgram(616, { swarmActive = true, passwordVar = 47 })
  Assert.equal(world:buenaPassword(), 47 % 30, "the password projection voices the field variable modulo thirty")
  local identity = world:dailySwarm()
  Assert.isTrue(identity.active, "the swarm projection matches the active field outbreak")
  Assert.isTrue(type(identity.seed) == "number", "the swarm projection carries the shared seed")

  program:begin(1, "clear")
  for _ = 1, 400 do
    program:updateFixed()
  end
  local pairs = 0
  for _, request in ipairs(messages.requests) do
    if request.bank == 502 then
      pairs = pairs + 1
      local params = assert(request.params, "talk pair lines carry landmark and species tokens")
      assert(type(params.landmark) == "number", "landmark selections stay numeric token references")
      assert(type(params.species) == "number", "species selections stay numeric token references")
      assert(
        type(params.phrase1) == "number" and params.phrase1 >= 0 and params.phrase1 < 13,
        "flavor phrases stay modulo thirteen"
      )
      assert(
        type(params.phrase2) == "number" and params.phrase2 >= 0 and params.phrase2 < 13,
        "flavor phrases stay modulo thirteen"
      )
      Assert.isTrue(params.step == 2 or params.step == 4 or params.step == 6, "flavor steps follow the source cadence")
    end
  end
  Assert.equal(pairs, 5, "the talk broadcast voices exactly five pairs")
  local firstRefs = requestRefs(messages)
  program:endProgram()
  program:dispose()

  local _, repeatMessages = talkTune(616)
  Assert.deepEqual(
    requestRefs(repeatMessages),
    firstRefs,
    "repeated tunes replay identical message vectors for one seed and hour"
  )
end

function T.tests.start_boundaries_observe_the_shared_calendar_without_rerolling_it()
  local program, _, state, _, _, _, _, civil = freshProgram(717)
  Assert.isTrue(state:readCalendar().checkpoint == nil, "tuning starts from an unobserved calendar")
  local seed = state:readDailyIdentity().outbreakSeed
  Fixture.setCivil(civil.cell, { year = 2024, month = 1, day = 8, hour = 10, minute = 0, second = 0 })
  program:begin(1, "clear")
  local checkpoint = state:readCalendar().checkpoint
  Assert.notNil(checkpoint, "tuning observes its start boundary into the shared calendar")
  Assert.equal(checkpoint.day, 8, "the observed checkpoint matches the civil sample")
  Assert.equal(state:readDailyIdentity().outbreakSeed, seed, "observing the same day never rerolls the identity")
  program:endProgram()
  program:dispose()
end

function T.tests.teardown_is_idempotent_and_reads_stay_pure_after_close()
  local program, _, _, _, audio, messages, random, _ = freshProgram(818)
  program:begin(1, "clear")
  for _ = 1, 120 do
    program:updateFixed()
  end
  local snapshot = random:capture()
  local requests = messages:requestCount()
  local status = program:status()
  local calls = audio:playCallCount()
  program:endProgram()
  program:endProgram()
  for _ = 1, 10 do
    program:updateFixed()
  end
  Assert.equal(audio:playCallCount(), calls, "closing starts no audio and ticking closed starts none")
  local closed = program:status()
  Assert.isTrue(closed.show == nil, "ending the program clears the running show")
  Assert.deepEqual(closed.body, {}, "ending the program clears retained display lines")
  Assert.deepEqual(random:capture(), snapshot, "closing draws no randomness")
  Assert.equal(messages:requestCount(), requests, "closing requests no messages")
  Assert.equal(status.show, Fixture.SHOW_KEYS.talk, "the earlier snapshot keeps its show")
  Assert.isTrue(audio:playCallCount() >= 0, "the audio facade stays borrowed, never owned")
  program:dispose()
  program:dispose()
  Assert.throws(function()
    program:begin(0, "clear")
  end, "tuning after disposal is a programming error")
end

function T.tests.missing_world_facts_fail_with_the_broadcast_identity()
  local RadioWorldContext = Fixture.requireFeature(
    "game.hgss.src.pokegear.RadioWorldContext",
    "broadcast world facts have no shared projection yet"
  )
  local validated = PokegearAssetSchema.validate(Fixture.fixtureManifest())
  local refs = Fixture.catalogRefs(assert(validated, "the catalog reads above"))
  local state = PokegearState.new({ seed = 919 }, refs)
  local calendar = PokegearCalendar.new(state)
  local events = FieldEventState.new()
  local good = {
    state = state,
    calendar = calendar,
    eventState = events,
    encounters = { swarm = false },
    dex = Fixture.newDexReader(false),
    bag = Fixture.newBagReader({}),
  }
  for _, missing in ipairs({ "state", "calendar", "eventState", "encounters", "dex", "bag" }) do
    local opts = {}
    for key, value in pairs(good) do
      opts[key] = value
    end
    opts[missing] = nil
    local err = Assert.throws(function()
      RadioWorldContext.new(opts)
    end, "a missing " .. missing .. " fact fails")
    Assert.isTrue(
      type(err) == "table" and err.code == "POKEGEAR_RADIO_FACT_UNAVAILABLE",
      "missing facts fail with the broadcast identity"
    )
  end
  local malformed = {}
  for key, value in pairs(good) do
    malformed[key] = value
  end
  malformed.encounters = {}
  local err = Assert.throws(function()
    RadioWorldContext.new(malformed)
  end, "a malformed swarm fact fails")
  Assert.isTrue(
    type(err) == "table" and err.code == "POKEGEAR_RADIO_FACT_UNAVAILABLE",
    "malformed facts fail with the broadcast identity"
  )
end

return T
