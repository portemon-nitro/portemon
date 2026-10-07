-- Encounter service behavior: semantic movement events driving the
-- opportunity, selection, and generation pipeline with exact labeled-draw
-- traces, every modifier applied at its source stage, repel and step
-- counters, static and roaming paths, and exactly-once consumption of
-- prepared encounters. Streams, tables, and expected draws are fixed here
-- from the native branches; nothing is produced by the service under test.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Fixture = require("libs.hgss.tests.encounter_fixture")
local Personality = require("libs.mons.src.gen4.Personality")

local T = {}

local CATALOG_MODULE = "libs.hgss.src.encounters.HgssEncounterCatalog"
local SERVICE_MODULE = "libs.hgss.src.encounters.HgssEncounterService"
local ROAMER_MODULE = "libs.hgss.src.encounters.HgssRoamerState"
local WILD_MODULE = "libs.hgss.src.encounters.WildMonFactory"

local function service(extra)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local Catalog = Fixture.requirePresent(CATALOG_MODULE, "validated encounter-table lookup owns ordered slots")
  local Service = Fixture.requirePresent(SERVICE_MODULE, "encounter opportunity and retained preparation")
  local WildMonFactory = Fixture.requirePresent(WILD_MODULE, "source wild identity and held-item generation")
  local args = {
    catalog = Catalog.new(Fixture.vectorCatalog()),
    wildFactory = WildMonFactory.new({
      catalog = CatalogFixture.makeCatalog(),
      items = ItemFixture.makeCatalog(),
      charmap = CatalogFixture.CHARMAP,
      games = CatalogFixture.GAMES,
      languages = CatalogFixture.LANGUAGES,
      game = "soulsilver",
      language = "english",
    }),
  }
  for key, value in pairs(extra or {}) do
    args[key] = value
  end
  return Service.new(args)
end

local function attemptResult(service, context, stream)
  local result = service:attempt(context, stream)
  Assert.isTrue(type(result) == "table", "attempts return a result record")
  return result
end

local function rejectionCode(fn, expected)
  local err = Assert.throws(fn, "the invalid attempt must fail")
  Assert.isTrue(Errors.is(err), "rejection uses the structured error path")
  Assert.equal(assert(err).code, expected, "rejection names its contract")
  return assert(err)
end

local function leadTotodile()
  return Fixture.mon("TOTODILE", 10, 11)
end

function T.grass_attempt_traces_opportunity_selection_and_generation()
  local host = service()
  local stream = Fixture.spyStream(0)
  -- Seed 0 draws: opportunity 0, slot 59774, level 21105, then the
  -- generation draws 12720/36418/58060/44997 plus two held draws.
  local result = attemptResult(host, Fixture.context(), stream)
  Assert.equal(result.kind, "prepared")
  Assert.equal(result.attemptId, 1)
  Assert.equal(result.stateRevision, 1)
  Assert.equal(result.reason, "triggered")
  local encounter = assert(result.encounter, "prepared attempts carry their encounter")
  Assert.equal(encounter.id, 1)
  Assert.equal(encounter.ruleset, "hgss-wild")
  Assert.equal(encounter.format, "wild-single")
  Assert.equal(encounter.provenance.method, "grass")
  Assert.equal(encounter.provenance.mapId, 11)
  Assert.equal(encounter.provenance.attemptId, 1)
  Assert.equal(encounter.environment.weather, "none")
  local mon = assert(encounter.mons[1].mon, "the encounter carries its wild mon")
  Assert.equal(mon.species, "EEVEE", "roll 74 selects the sixth land slot")
  Assert.equal(mon.met.level, 8)
  Assert.equal(mon.personality, 2386702768)
  Assert.deepEqual(mon.ivs, { hp = 12, attack = 22, defense = 24, speed = 5, specialAttack = 30, specialDefense = 11 })
  Assert.equal(mon.heldItem, "NONE")
  Assert.equal(stream:calls(), 9, "grass success consumes nine labeled draws")
  Assert.deepEqual(stream:labels(), {
    "opportunity",
    "slot",
    "level",
    "personality_low",
    "personality_high",
    "iv_first",
    "iv_second",
    "held_common",
    "held_rare",
  })
  for _, cause in ipairs(stream:causes()) do
    Assert.isTrue(type(cause) == "table" and cause.kind == "encounter", "every draw carries its semantic cause")
  end
  local replay = attemptResult(service(), Fixture.context(), Fixture.spyStream(0))
  Assert.equal(replay.encounter.mons[1].mon.personality, 2386702768, "identical inputs replay identically")
end

function T.missed_opportunity_consumes_one_draw()
  local host = service()
  for _, seed in ipairs({ 0, 1, 12345 }) do
    local stream = Fixture.spyStream(seed)
    local result = attemptResult(host, Fixture.context({ mapId = 12 }), stream)
    Assert.equal(result.kind, "none")
    Assert.equal(result.reason, "no_opportunity")
    Assert.isNil(result.encounter)
    Assert.equal(stream:calls(), 1, "a failed rate check draws once and stops")
  end
end

function T.non_checking_events_never_draw()
  local host = service()
  local movements = { still = "idle", menu = "idle", forced = "forced_movement", scripted = "scripted_movement" }
  local attemptId = 0
  for movement, reason in pairs(movements) do
    attemptId = attemptId + 1
    local stream = Fixture.spyStream(0)
    local result = attemptResult(host, Fixture.context({ movement = movement }), stream)
    Assert.equal(result.kind, "none")
    Assert.equal(result.reason, reason)
    Assert.equal(result.attemptId, attemptId)
    Assert.equal(stream:calls(), 0, movement .. " steps never consult the stream")
  end
end

function T.fishing_distinguishes_bite_and_no_bite()
  local host = service()
  local stream = Fixture.spyStream(0)
  -- Seed 0 draws: bite 0, slot 59774 into the rod ladder, level 21105.
  local context = Fixture.context({ method = "fish", movement = "fish", mapId = 14 })
  context.modifiers = Fixture.modifiers({ rod = "old_rod" })
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "prepared")
  local mon = assert(result.encounter.mons[1].mon)
  Assert.equal(mon.species, "CHIKORITA", "roll 74 selects the third rod slot")
  Assert.equal(mon.met.level, 5, "the 5-9 window resolves on roll 21105")
  Assert.equal(mon.personality, 2386702768)
  Assert.equal(stream:calls(), 9)
  Assert.equal(stream:labels()[1], "opportunity", "the bite check opens the trace")
  local calm = Fixture.spyStream(0)
  local calmContext = Fixture.context({ method = "fish", movement = "fish", mapId = 12 })
  calmContext.modifiers = Fixture.modifiers({ rod = "old_rod" })
  local missed = attemptResult(service(), calmContext, calm)
  Assert.equal(missed.kind, "none")
  Assert.equal(missed.reason, "no_bite")
  Assert.equal(calm:calls(), 1)
  local rodless = Fixture.spyStream(0)
  local before = rodless:calls()
  rejectionCode(function()
    host:attempt(Fixture.context({ method = "fish", movement = "fish", mapId = 14 }), rodless)
  end, "ENCOUNTER_INVALID_INPUT")
  Assert.equal(rodless:calls(), before, "rod fishing without a rod consumes no draws")
end

function T.repel_blocks_low_wilds_without_resampling()
  local host = service()
  local lead = leadTotodile()
  local context = Fixture.context({ lead = lead })
  context.modifiers = Fixture.modifiers({ repel = true })
  local stream = Fixture.spyStream(0)
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "none")
  Assert.equal(result.reason, "repel", "the level-8 selection falls below the level-10 lead")
  Assert.equal(stream:calls(), 3, "a repelled attempt stops after level selection")
  Assert.deepEqual(stream:labels(), { "opportunity", "slot", "level" })
  local control = attemptResult(service(), Fixture.context({ lead = lead }), Fixture.spyStream(0))
  Assert.equal(control.kind, "prepared", "the same draws succeed without repel")
  Assert.equal(control.encounter.mons[1].mon.personality, 2386702768)
  local rodless = Fixture.spyStream(0)
  local before = rodless:calls()
  local noLead = Fixture.context()
  noLead.modifiers = Fixture.modifiers({ repel = true })
  rejectionCode(function()
    host:attempt(noLead, rodless)
  end, "ENCOUNTER_INVALID_INPUT")
  Assert.equal(rodless:calls(), before, "repel without a lead consumes no draws")
end

function T.repel_passes_wilds_at_or_above_the_lead()
  local host = service()
  local context = Fixture.context({ lead = leadTotodile() })
  context.modifiers = Fixture.modifiers({ repel = true })
  local stream = Fixture.spyStream(58)
  -- Seed 58 draws: opportunity 59118, slot 597 into slot ten, level
  -- 28397, then identity 7977/61644/58040/55770 plus two held draws.
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "prepared", "the level-12 selection survives repel")
  local mon = assert(result.encounter.mons[1].mon)
  Assert.equal(mon.species, "EEVEE")
  Assert.equal(mon.met.level, 12)
  Assert.equal(mon.personality, 4039909161)
  Assert.deepEqual(mon.ivs, { hp = 24, attack = 21, defense = 24, speed = 26, specialAttack = 14, specialDefense = 22 })
  Assert.equal(stream:calls(), 9)
end

function T.lead_intimidate_halves_the_opportunity_rate()
  local lead = leadTotodile()
  local plainContext = Fixture.context({ mapId = 13 })
  -- Seed 3 opens with roll 15 against the mid rate of 30.
  local plain = attemptResult(service(), plainContext, Fixture.spyStream(3))
  Assert.equal(plain.kind, "prepared")
  local mon = assert(plain.encounter.mons[1].mon)
  Assert.equal(mon.species, "TOTODILE", "roll 46 selects the third land slot")
  Assert.equal(mon.personality, 1361509316)
  Assert.deepEqual(mon.ivs, { hp = 1, attack = 19, defense = 23, speed = 5, specialAttack = 11, specialDefense = 0 })
  local host = service()
  local waryContext = Fixture.context({ mapId = 13, lead = lead })
  waryContext.modifiers = Fixture.modifiers({ leadAbility = "intimidate" })
  local waryStream = Fixture.spyStream(3)
  local wary = attemptResult(host, waryContext, waryStream)
  Assert.equal(wary.kind, "none", "the halved rate of 15 rejects roll 15")
  Assert.equal(wary.reason, "no_opportunity")
  Assert.equal(waryStream:calls(), 1, "rate abilities apply at the opportunity stage")
  local stray = Fixture.spyStream(3)
  local before = stray:calls()
  local strayContext = Fixture.context({ mapId = 13 })
  strayContext.modifiers = Fixture.modifiers({ leadAbility = "intimidate" })
  rejectionCode(function()
    host:attempt(strayContext, stray)
  end, "ENCOUNTER_INVALID_INPUT")
  Assert.equal(stray:calls(), before, "lead abilities without a lead consume no draws")
end

function T.lead_synchronize_reaches_generation()
  local lead = Fixture.mon("EEVEE", 12, 21)
  local leadNature = Personality.nature(lead.personality)
  local host = service()
  -- Seed 1 spends its check draw on 8119, an odd roll, so identity is drawn.
  local missedContext = Fixture.context({ lead = lead })
  missedContext.modifiers = Fixture.modifiers({ leadAbility = "synchronize", leadNature = leadNature })
  local missedStream = Fixture.spyStream(1)
  local missed = attemptResult(host, missedContext, missedStream)
  Assert.equal(missed.kind, "prepared")
  local missedMon = assert(missed.encounter.mons[1].mon)
  Assert.equal(missedMon.personality, 3064494563)
  Assert.equal(Personality.nature(missedMon.personality), 13)
  Assert.equal(missedMon.ability, "ADAPTABILITY")
  Assert.equal(missedStream:calls(), 10)
  Assert.equal(missedStream:labels()[4], "synchronize", "coercion draws after level selection")
  -- Seed 0 spends its check draw on 12720, an even roll, forcing the nature.
  local forcedContext = Fixture.context({ lead = lead })
  forcedContext.modifiers = Fixture.modifiers({ leadAbility = "synchronize", leadNature = leadNature })
  local forcedStream = Fixture.spyStream(0)
  local forced = attemptResult(service(), forcedContext, forcedStream)
  local forcedMon = assert(forced.encounter.mons[1].mon)
  Assert.equal(Personality.nature(forcedMon.personality), leadNature, "a passed check forces the lead nature")
  Assert.equal(forcedStream:calls(), 10)
end

function T.step_events_advance_counters_while_idle_events_do_not()
  local host = service()
  local context = Fixture.context({ mapId = 12 })
  context.modifiers = Fixture.modifiers({ repel = true, repelSteps = 3 })
  local first = attemptResult(host, context, Fixture.spyStream(0))
  Assert.deepEqual({ first.stateDelta.steps, first.stateDelta.repelSteps }, { 1, 2 })
  local secondContext = Fixture.context({ mapId = 12 })
  secondContext.modifiers = Fixture.modifiers({ repel = true, repelSteps = first.stateDelta.repelSteps })
  local second = attemptResult(host, secondContext, Fixture.spyStream(0))
  Assert.deepEqual({ second.stateDelta.steps, second.stateDelta.repelSteps }, { 2, 1 })
  local thirdContext = Fixture.context({ mapId = 12 })
  thirdContext.modifiers = Fixture.modifiers({ repel = true, repelSteps = second.stateDelta.repelSteps })
  local third = attemptResult(host, thirdContext, Fixture.spyStream(0))
  Assert.deepEqual({ third.stateDelta.steps, third.stateDelta.repelSteps }, { 3, 0 })
  local idle = attemptResult(host, Fixture.context({ mapId = 12, movement = "menu" }), Fixture.spyStream(0))
  Assert.equal(idle.stateDelta.steps, 3, "menu events never advance the step counter")
  local exhaustedContext = Fixture.context({ lead = leadTotodile() })
  exhaustedContext.modifiers = Fixture.modifiers({ repel = true, repelSteps = 0 })
  local exhausted = attemptResult(host, exhaustedContext, Fixture.spyStream(0))
  Assert.equal(exhausted.kind, "prepared", "expired repel no longer blocks")
end

function T.unknown_tables_and_methods_fail_without_draws()
  local host = service()
  local stream = Fixture.spyStream(0)
  local before = stream:calls()
  rejectionCode(function()
    host:attempt(Fixture.context({ mapId = 999 }), stream)
  end, "ENCOUNTER_MISSING_TABLE")
  rejectionCode(function()
    host:attempt(Fixture.context({ method = "warp" }), stream)
  end, "ENCOUNTER_INVALID_INPUT")
  rejectionCode(function()
    host:attempt(Fixture.context({ method = "headbutt" }), stream)
  end, "ENCOUNTER_MISSING_TABLE")
  rejectionCode(function()
    host:attempt(Fixture.context({ method = "safari" }), stream)
  end, "ENCOUNTER_MISSING_TABLE")
  rejectionCode(function()
    host:attempt(Fixture.context({ method = "static" }), stream)
  end, "ENCOUNTER_INVALID_INPUT")
  Assert.equal(stream:calls(), before, "rejected attempts consume no draws")
end

function T.static_attempts_generate_without_a_table_check()
  local host = service()
  local context = Fixture.context({ method = "static", movement = "still" })
  context.modifiers = Fixture.modifiers({ static = { species = "TOTODILE", level = 5 } })
  local stream = Fixture.spyStream(0)
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "prepared")
  Assert.equal(result.reason, "static")
  local mon = assert(result.encounter.mons[1].mon)
  Assert.equal(mon.species, "TOTODILE")
  Assert.equal(mon.met.level, 5)
  Assert.equal(mon.personality, 3917348864)
  Assert.equal(stream:calls(), 6, "scripted encounters skip opportunity and selection")
  Assert.equal(stream:labels()[1], "personality_low")
  local stray = Fixture.spyStream(0)
  local before = stray:calls()
  local strayContext = Fixture.context({ method = "static", movement = "still" })
  strayContext.modifiers = Fixture.modifiers({ static = { species = "BOGUS_SPECIES", level = 5 } })
  rejectionCode(function()
    host:attempt(strayContext, stray)
  end, "ENCOUNTER_INVALID_INPUT")
  Assert.equal(stray:calls(), before)
end

function T.roamer_attempts_borrow_the_stored_identity()
  local Roamers = Fixture.requirePresent(ROAMER_MODULE, "stable roaming state and lifecycle")
  local refs = Fixture.refs()
  local stored = Fixture.roamerMon()
  local roamers = Roamers.new({
    records = { Fixture.roamerRecord(stored, 11, "roaming", 0) },
    species = refs.species,
    maps = refs.maps,
  })
  local host = service({ roamers = roamers })
  local context = Fixture.context({ method = "roamer", movement = "step" })
  context.modifiers = Fixture.modifiers({ roamerKey = "roamer-eevee" })
  local stream = Fixture.spyStream(0)
  local before = stream:calls()
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "prepared")
  Assert.equal(result.reason, "roamer")
  local mon = assert(result.encounter.mons[1].mon)
  Assert.equal(mon.species, "EEVEE")
  Assert.equal(mon.personality, stored.personality, "roamer construction reuses the stored identity")
  Assert.deepEqual(mon.ivs, stored.ivs)
  Assert.equal(stream:calls(), before, "roamer encounters regenerate nothing")
end

function T.prepared_encounters_are_consumed_exactly_once()
  local host = service()
  local result = attemptResult(host, Fixture.context(), Fixture.spyStream(0))
  local revision = result.stateRevision
  local prepared = host:consume(1)
  Assert.equal(prepared.id, 1)
  Assert.equal(prepared.mons[1].mon.personality, 2386702768, "consumption never rerolls")
  rejectionCode(function()
    host:consume(1)
  end, "ENCOUNTER_ALREADY_CONSUMED")
  rejectionCode(function()
    host:consume(999)
  end, "ENCOUNTER_INVALID_INPUT")
  local resumed = attemptResult(host, Fixture.context(), Fixture.spyStream(0))
  Assert.equal(resumed.attemptId, 2, "a consumed encounter releases the service")
  Assert.isTrue(resumed.stateRevision > revision, "consumption advances the revision")
end

---@param value unknown
local function assertPlainData(value)
  local seen = {}
  local function visit(node, trail)
    local kind = type(node)
    Assert.isTrue(kind ~= "function", trail .. " must not capture a function")
    Assert.isTrue(kind ~= "thread", trail .. " must not capture a thread")
    Assert.isTrue(kind ~= "userdata", trail .. " must not capture userdata")
    if kind == "table" then
      Assert.isNil(seen[node], trail .. " must not loop back on itself")
      seen[node] = true
      for key, item in pairs(node) do
        visit(item, trail .. "." .. tostring(key))
      end
    end
  end
  visit(value, "snapshot")
end

function T.restore_polls_the_pending_encounter_without_reroll()
  local host = service()
  local result = attemptResult(host, Fixture.context(), Fixture.spyStream(0))
  local snapshot = host:capture()
  assertPlainData(snapshot)
  local pending = host:restore(snapshot)
  Assert.equal(pending.attemptId, 1, "restoration retains the attempt identity")
  Assert.equal(pending.encounter.mons[1].mon.personality, 2386702768, "restoration never rerolls")
  local stream = Fixture.spyStream(99)
  local before = stream:calls()
  rejectionCode(function()
    host:attempt(Fixture.context(), stream)
  end, "ENCOUNTER_PENDING")
  Assert.equal(stream:calls(), before, "a pending encounter blocks new attempts without draws")
  local prepared = host:consume(1)
  Assert.equal(prepared.mons[1].mon.personality, 2386702768)
  rejectionCode(function()
    host:restore({ bogus = true })
  end, "ENCOUNTER_INVALID_INPUT")
  Assert.equal(result.stateRevision, 1)
end

function T.identities_stay_monotonic_across_mixed_results()
  local host = service()
  local first = attemptResult(host, Fixture.context(), Fixture.spyStream(0))
  Assert.equal(first.attemptId, 1)
  local second = attemptResult(host, Fixture.context({ mapId = 12 }), Fixture.spyStream(0))
  Assert.equal(second.attemptId, 2)
  Assert.equal(second.stateRevision, 2)
  local stream = Fixture.spyStream(0)
  local before = stream:calls()
  rejectionCode(function()
    host:attempt(Fixture.context({ method = "warp" }), stream)
  end, "ENCOUNTER_INVALID_INPUT")
  Assert.equal(stream:calls(), before)
  local third = attemptResult(host, Fixture.context(), Fixture.spyStream(0))
  Assert.equal(third.attemptId, 3, "rejected input never consumes an attempt identity")
  Assert.equal(third.stateRevision, 3)
end

return { tests = T }
