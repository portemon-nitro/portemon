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

---@param mapId integer
---@param mods table<string, unknown>|nil
---@param lead table<string, unknown>|nil
---@return table<string, unknown> roamer step context over the tile facts
local function roamerAttemptContext(mapId, mods, lead)
  local merged = { roamerKey = "roamer-eevee", tileMethod = "grass" }
  for key, value in pairs(mods or {}) do
    merged[key] = value
  end
  local context = Fixture.context({ method = "roamer", mapId = mapId, lead = lead })
  context.modifiers = Fixture.modifiers(merged)
  return context
end

function T.grass_attempt_traces_opportunity_selection_and_generation()
  local host = service()
  Fixture.pastGrace(host)
  local stream = Fixture.spyStream(0)
  -- Seed 0 draws: movement 0, opportunity 59774, slot 21105; land
  -- takes no level roll, so generation opens on the fourth draw
  -- (personality 12720/36418, then 58060/44997 plus two held draws).
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
  Assert.equal(mon.species, "CHIKORITA", "roll 5 selects the first land slot")
  Assert.equal(mon.met.level, 4)
  Assert.equal(mon.personality, 2386702768)
  Assert.deepEqual(mon.ivs, { hp = 12, attack = 22, defense = 24, speed = 5, specialAttack = 30, specialDefense = 11 })
  Assert.equal(mon.heldItem, "NONE")
  Assert.equal(stream:calls(), 8, "grass success consumes eight labeled draws")
  Assert.deepEqual(stream:labels(), {
    "movement",
    "opportunity",
    "slot",
    "personality_low",
    "personality_high",
    "iv_first",
    "iv_second",
    "held_item",
  })
  for _, cause in ipairs(stream:causes()) do
    Assert.isTrue(type(cause) == "table" and cause.kind == "encounter", "every draw carries its semantic cause")
  end
  local replayHost = service()
  Fixture.pastGrace(replayHost)
  local replay = attemptResult(replayHost, Fixture.context(), Fixture.spyStream(0))
  Assert.equal(replay.encounter.mons[1].mon.personality, 2386702768, "identical inputs replay identically")
end

function T.land_selection_uses_the_fixed_slot_level_without_a_roll()
  local host = service()
  Fixture.pastGrace(host)
  -- Seed 0: movement 0 under the walking twenty, opportunity 74 under
  -- the full rate, slot roll 5 into the first land slot (CHIKORITA,
  -- fixed level 4). Native land tables carry one level per slot, so the
  -- slot maximum answers the level with no level roll: generation opens
  -- on the fourth draw (personality 12720/36418).
  local stream = Fixture.spyStream(0)
  local result = attemptResult(host, Fixture.context(), stream)
  Assert.equal(result.kind, "prepared")
  local mon = assert(result.encounter.mons[1].mon, "the encounter carries its wild mon")
  Assert.equal(mon.species, "CHIKORITA")
  Assert.equal(mon.met.level, 4)
  Assert.equal(mon.personality, 2386702768)
  Assert.deepEqual(mon.ivs, { hp = 12, attack = 22, defense = 24, speed = 5, specialAttack = 30, specialDefense = 11 })
  Assert.equal(mon.heldItem, "NONE")
  Assert.equal(stream:calls(), 8, "land success consumes eight labeled draws")
  Assert.deepEqual(stream:labels(), {
    "movement",
    "opportunity",
    "slot",
    "personality_low",
    "personality_high",
    "iv_first",
    "iv_second",
    "held_item",
  })
end

function T.missed_rolls_stop_after_their_own_draw()
  local host = service()
  Fixture.pastGrace(host)
  -- Seeds 1 and 12345 refuse the walking movement rate of 20 (seed 1
  -- opens with roll 38), drawing once and never reaching the table rate.
  for _, seed in ipairs({ 1, 12345 }) do
    local stream = Fixture.spyStream(seed)
    local result = attemptResult(host, Fixture.context({ mapId = 11 }), stream)
    Assert.equal(result.kind, "none")
    Assert.equal(result.reason, "no_opportunity")
    Assert.isNil(result.encounter)
    Assert.equal(stream:calls(), 1, "a failed movement roll draws once and stops")
    Assert.deepEqual(stream:labels(), { "movement" })
  end
  -- Seed 0 passes the movement roll (roll 0) on the mid-rate member 13,
  -- but its table roll 74 refuses the rate of 30, stopping after the two
  -- opportunity draws.
  local tableStream = Fixture.spyStream(0)
  local tableMiss = attemptResult(host, Fixture.context({ mapId = 13 }), tableStream)
  Assert.equal(tableMiss.kind, "none")
  Assert.equal(tableMiss.reason, "no_opportunity")
  Assert.isNil(tableMiss.encounter)
  Assert.equal(tableStream:calls(), 2, "a failed table roll stops after the movement draw")
  Assert.deepEqual(tableStream:labels(), { "movement", "opportunity" })
  -- An empty table rate misses before any draw or tracker update.
  local zeroStream = Fixture.spyStream(0)
  local zeroMiss = attemptResult(host, Fixture.context({ mapId = 12 }), zeroStream)
  Assert.equal(zeroMiss.kind, "none")
  Assert.equal(zeroMiss.reason, "no_opportunity")
  Assert.isNil(zeroMiss.encounter)
  Assert.equal(zeroStream:calls(), 0, "an empty rate draws nothing")
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
  Assert.equal(stream:calls(), 8)
  Assert.equal(stream:labels()[1], "opportunity", "the bite check opens the trace")
  local calm = Fixture.spyStream(0)
  local calmContext = Fixture.context({ method = "fish", movement = "fish", mapId = 12 })
  calmContext.modifiers = Fixture.modifiers({ rod = "old_rod" })
  local missed = attemptResult(service(), calmContext, calm)
  Assert.equal(missed.kind, "none")
  Assert.equal(missed.reason, "no_bite")
  Assert.equal(calm:calls(), 0, "an empty bite rate draws nothing")
  local rodless = Fixture.spyStream(0)
  local before = rodless:calls()
  rejectionCode(function()
    host:attempt(Fixture.context({ method = "fish", movement = "fish", mapId = 14 }), rodless)
  end, "ENCOUNTER_INVALID_INPUT")
  Assert.equal(rodless:calls(), before, "rod fishing without a rod consumes no draws")
end

function T.repel_blocks_low_wilds_without_resampling()
  local host = service()
  Fixture.pastGrace(host)
  local lead = leadTotodile()
  local context = Fixture.context({ lead = lead })
  context.modifiers = Fixture.modifiers({ repel = true })
  local stream = Fixture.spyStream(0)
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "none")
  Assert.equal(result.reason, "repel", "the level-4 selection falls below the level-10 lead")
  Assert.equal(stream:calls(), 3, "a repelled attempt stops after slot selection")
  Assert.deepEqual(stream:labels(), { "movement", "opportunity", "slot" })
  local controlHost = service()
  Fixture.pastGrace(controlHost)
  local control = attemptResult(controlHost, Fixture.context({ lead = lead }), Fixture.spyStream(0))
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
  Fixture.pastGrace(host)
  local context = Fixture.context({ lead = leadTotodile() })
  context.modifiers = Fixture.modifiers({ repel = true })
  local stream = Fixture.spyStream(58)
  -- Seed 58 draws: movement 59118, opportunity 597 into the full table
  -- rate, slot 28397 into slot ten at its fixed level 12; land takes no
  -- level roll, so identity opens on the fourth draw (61644/58040,
  -- then 55770 plus two held draws).
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "prepared", "the level-12 selection survives repel")
  local mon = assert(result.encounter.mons[1].mon)
  Assert.equal(mon.species, "EEVEE")
  Assert.equal(mon.met.level, 12)
  Assert.equal(mon.personality, 4039909161)
  Assert.deepEqual(mon.ivs, { hp = 24, attack = 21, defense = 24, speed = 26, specialAttack = 14, specialDefense = 22 })
  Assert.equal(stream:calls(), 8)
end

function T.table_rate_staging_applies_before_the_rolls()
  local host = service()
  Fixture.pastGrace(host)
  -- Seed 10 passes movement (roll 11) while its table roll 52 refuses
  -- the raw mid rate of 30. Arena trap doubles the staged rate to 60,
  -- so the same draws trigger: slot 62 into the fifth land slot at its
  -- fixed level 7, then identity from the fourth draw on.
  local context = Fixture.context({ mapId = 13, lead = leadTotodile() })
  context.modifiers = Fixture.modifiers({ leadAbility = "arena_trap" })
  local stream = Fixture.spyStream(10)
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "prepared", "the staged rate opens the table roll")
  local mon = assert(result.encounter.mons[1].mon)
  Assert.equal(mon.species, "EEVEE")
  Assert.equal(mon.met.level, 7)
  Assert.equal(mon.personality, 3264183793)
  Assert.deepEqual(mon.ivs, { hp = 8, attack = 11, defense = 10, speed = 26, specialAttack = 30, specialDefense = 15 })
  Assert.equal(mon.heldItem, "NONE")
  Assert.equal(stream:calls(), 8, "staging draws no extra rolls")
  Assert.deepEqual(stream:labels(), {
    "movement",
    "opportunity",
    "slot",
    "personality_low",
    "personality_high",
    "iv_first",
    "iv_second",
    "held_item",
  })
end

function T.black_flute_halves_before_the_table_roll()
  local host = service()
  Fixture.pastGrace(host)
  -- Seed 24 passes movement (roll 3) and the raw mid rate (roll 28).
  -- A black flute halves the staged rate to 15, so the same table roll
  -- misses after the two opportunity draws.
  local context = Fixture.context({ mapId = 13 })
  context.modifiers = Fixture.modifiers({ flute = "black" })
  local stream = Fixture.spyStream(24)
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "none")
  Assert.equal(result.reason, "no_opportunity")
  Assert.equal(stream:calls(), 2, "a staged-out table roll stops after the movement draw")
  Assert.deepEqual(stream:labels(), { "movement", "opportunity" })
end

function T.held_items_take_two_thirds_before_the_table_roll()
  local host = service()
  Fixture.pastGrace(host)
  -- Seed 24 clears the raw mid rate (roll 28). A cleanse tag on the
  -- lead stages two thirds of thirty to twenty, refusing the roll.
  local lead = leadTotodile()
  lead.heldItem = "CLEANSE_TAG"
  local context = Fixture.context({ mapId = 13, lead = lead })
  local stream = Fixture.spyStream(24)
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "none", "the held item stages the table rate down")
  Assert.equal(result.reason, "no_opportunity")
  Assert.equal(stream:calls(), 2)
end

function T.repel_never_arms_off_the_step_path()
  local host = service()
  -- Seed 0 bites the full old-rod rate and selects the third rod slot
  -- at level 5: below the level-10 lead, but fishing never arms repel.
  local fishContext = Fixture.context({ method = "fish", movement = "fish", mapId = 14, lead = leadTotodile() })
  fishContext.modifiers = Fixture.modifiers({ rod = "old_rod", repel = true })
  local fish = attemptResult(host, fishContext, Fixture.spyStream(0))
  Assert.equal(fish.kind, "prepared", "fishing ignores an armed repel")
  Assert.equal(fish.encounter.mons[1].mon.met.level, 5)
  -- Seed 0 consults the full rock rate and selects the first rock slot
  -- at level 18: below the level-25 lead, but rock smash never arms repel.
  local smashContext =
    Fixture.context({ method = "rock_smash", movement = "field_move", mapId = 15, lead = Fixture.mon("TOTODILE", 25, 11) })
  smashContext.modifiers = Fixture.modifiers({ repel = true })
  local smashed = attemptResult(host, smashContext, Fixture.spyStream(0))
  Assert.equal(smashed.kind, "prepared", "rock smash ignores an armed repel")
  Assert.equal(smashed.encounter.mons[1].mon.met.level, 18)
end

function T.fishing_friendship_reaches_through_follow_facts()
  local host = service()
  -- Seed 5 bites 55 against the mid old-rod rate of 50 and misses.
  -- A follower with friendship 250 boosts the staged bite to the full
  -- rate, so the same bite selects the second rod slot at level 4.
  local lead = leadTotodile()
  lead.friendship = 250
  local context = Fixture.context({ method = "fish", movement = "fish", mapId = 16, lead = lead })
  context.modifiers = Fixture.modifiers({ rod = "old_rod", followActive = true })
  local stream = Fixture.spyStream(5)
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "prepared", "the friendship boost opens the bite")
  local mon = assert(result.encounter.mons[1].mon)
  Assert.equal(mon.species, "TOTODILE")
  Assert.equal(mon.met.level, 4)
  Assert.equal(mon.personality, 677959633)
  Assert.deepEqual(mon.ivs, { hp = 26, attack = 16, defense = 1, speed = 16, specialAttack = 30, specialDefense = 13 })
  Assert.equal(mon.heldItem, "NONE")
  Assert.equal(stream:calls(), 8)
  host:consume(result.attemptId)
  -- Without the follower the same bite misses after one draw.
  local loneContext = Fixture.context({ method = "fish", movement = "fish", mapId = 16, lead = lead })
  loneContext.modifiers = Fixture.modifiers({ rod = "old_rod", followActive = false })
  local loneStream = Fixture.spyStream(5)
  local lone = attemptResult(host, loneContext, loneStream)
  Assert.equal(lone.kind, "none")
  Assert.equal(lone.reason, "no_bite")
  Assert.equal(loneStream:calls(), 1)
end

function T.repel_compares_against_the_first_alive_mon()
  local host = service()
  Fixture.pastGrace(host)
  -- Seed 0 selects the first land slot at level 4. The slot-0 lead sits
  -- at level 3 while the first alive mon sits at level 10: the repel
  -- reads the first alive mon and suppresses.
  local blockedContext = Fixture.context({
    lead = Fixture.mon("TOTODILE", 3, 11),
    firstAlive = Fixture.mon("TOTODILE", 10, 11),
  })
  blockedContext.modifiers = Fixture.modifiers({ repel = true })
  local blocked = attemptResult(host, blockedContext, Fixture.spyStream(0))
  Assert.equal(blocked.kind, "none")
  Assert.equal(blocked.reason, "repel", "repel reads the first alive level, not the slot-0 level")
  -- Reversed fortunes pass: the slot-0 lead at level 10 cannot suppress
  -- a wild the first alive mon at level 3 would admit. Misses hold no
  -- preparation, so the next attempt supersedes without consuming.
  local passedContext = Fixture.context({
    lead = Fixture.mon("TOTODILE", 10, 11),
    firstAlive = Fixture.mon("TOTODILE", 3, 11),
  })
  passedContext.modifiers = Fixture.modifiers({ repel = true })
  local passedStream = Fixture.spyStream(0)
  local passed = attemptResult(host, passedContext, passedStream)
  Assert.equal(passed.kind, "prepared", "a low first alive mon admits the wild")
  Assert.equal(passedStream:calls(), 8)
end

function T.lead_hustle_reselects_the_slot_level_on_land()
  local host = service()
  Fixture.pastGrace(host)
  -- Seed 65 passes movement (roll 14) and the full table rate (roll 3),
  -- selecting the third land slot (TOTODILE 5). The odd slot-level check
  -- (41303) reseats the ninth slot (TOTODILE 11) with no extra level roll.
  local reselectContext = Fixture.context({ lead = leadTotodile() })
  reselectContext.modifiers = Fixture.modifiers({ leadAbility = "hustle" })
  local reselectStream = Fixture.spyStream(65)
  local reselected = attemptResult(host, reselectContext, reselectStream)
  Assert.equal(reselected.kind, "prepared")
  local reselectMon = assert(reselected.encounter.mons[1].mon)
  Assert.equal(reselectMon.species, "TOTODILE")
  Assert.equal(reselectMon.met.level, 11, "the check reseats the highest sibling")
  Assert.equal(reselectMon.personality, 2914935349)
  Assert.deepEqual(reselectMon.ivs, { hp = 15, attack = 2, defense = 6, speed = 17, specialAttack = 25, specialDefense = 11 })
  Assert.equal(reselectStream:calls(), 9, "the reselect draws its check after slot selection")
  Assert.deepEqual(reselectStream:labels(), {
    "movement",
    "opportunity",
    "slot",
    "slot_level",
    "personality_low",
    "personality_high",
    "iv_first",
    "iv_second",
    "held_item",
  })
  -- Seed 48 selects the same third slot, but the even check (53992)
  -- keeps the rolled level 5.
  local keepContext = Fixture.context({ lead = leadTotodile() })
  keepContext.modifiers = Fixture.modifiers({ leadAbility = "vital_spirit" })
  local keepStream = Fixture.spyStream(48)
  local kept = attemptResult(host, keepContext, keepStream)
  Assert.equal(kept.kind, "prepared")
  local keptMon = assert(kept.encounter.mons[1].mon)
  Assert.equal(keptMon.species, "TOTODILE")
  Assert.equal(keptMon.met.level, 5, "a passed check keeps the selected slot")
  Assert.equal(keptMon.personality, 2619194495)
  Assert.equal(keepStream:calls(), 9)
end

function T.lead_pressure_pins_windowed_levels_to_the_maximum()
  local host = service()
  Fixture.pastGrace(host)
  -- Seed 10 passes movement (roll 11) and the full surf rate (roll 52),
  -- selecting the second surf slot (10-12). The rolled level is 10, but
  -- the odd slot-level check pins the window maximum of 12.
  local context = Fixture.context({ mapId = 15, method = "surf", lead = leadTotodile() })
  context.modifiers = Fixture.modifiers({ leadAbility = "pressure" })
  local stream = Fixture.spyStream(10)
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "prepared")
  local mon = assert(result.encounter.mons[1].mon)
  Assert.equal(mon.species, "CHIKORITA")
  Assert.equal(mon.met.level, 12, "the failed check pins the window maximum")
  Assert.equal(mon.personality, 3218745704)
  Assert.deepEqual(mon.ivs, { hp = 6, attack = 20, defense = 1, speed = 23, specialAttack = 31, specialDefense = 6 })
  Assert.equal(stream:calls(), 10, "the windowed check draws after the level roll")
  Assert.deepEqual(stream:labels(), {
    "movement",
    "opportunity",
    "slot",
    "level",
    "slot_level",
    "personality_low",
    "personality_high",
    "iv_first",
    "iv_second",
    "held_item",
  })
  -- Seed 0 rolls the same slot at level 10, and the even check (36418)
  -- keeps it.
  local keepContext = Fixture.context({ mapId = 15, method = "surf", lead = leadTotodile() })
  keepContext.modifiers = Fixture.modifiers({ leadAbility = "pressure" })
  local keepStream = Fixture.spyStream(0)
  local kept = attemptResult(host, keepContext, keepStream)
  Assert.equal(kept.kind, "prepared")
  Assert.equal(kept.encounter.mons[1].mon.met.level, 10, "a passed check keeps the rolled level")
  Assert.equal(keepStream:calls(), 10)
end

function T.cute_charm_reaches_generation()
  local host = service()
  Fixture.pastGrace(host)
  -- Seed 24 passes movement (roll 3) and the full table rate (roll 28),
  -- selecting the second land slot at level 4. The cute-charm check
  -- (roll 21) coerces the wild male against the female lead: the low
  -- personality byte sets to 255 on the sixth draw.
  local context = Fixture.context({ lead = leadTotodile() })
  context.modifiers = Fixture.modifiers({ leadAbility = "cute_charm", leadGender = "female" })
  local stream = Fixture.spyStream(24)
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "prepared", "the charming lead coerces the wild gender")
  local mon = assert(result.encounter.mons[1].mon)
  Assert.equal(mon.species, "CHIKORITA")
  Assert.equal(mon.met.level, 4)
  Assert.equal(mon.personality, 3212092927)
  Assert.deepEqual(mon.ivs, { hp = 5, attack = 6, defense = 15, speed = 8, specialAttack = 5, specialDefense = 25 })
  Assert.equal(mon.heldItem, "NONE")
  Assert.equal(stream:calls(), 9, "coercion draws its check after slot selection")
  Assert.deepEqual(stream:labels(), {
    "movement",
    "opportunity",
    "slot",
    "cute_charm",
    "personality_low",
    "personality_high",
    "iv_first",
    "iv_second",
    "held_item",
  })
  local stray = Fixture.spyStream(0)
  local before = stray:calls()
  local strayContext = Fixture.context({ lead = leadTotodile() })
  strayContext.modifiers = Fixture.modifiers({ leadAbility = "cute_charm" })
  rejectionCode(function()
    host:attempt(strayContext, stray)
  end, "ENCOUNTER_INVALID_INPUT")
  Assert.equal(stray:calls(), before, "coercion without a lead gender consumes no draws")
end

function T.roamer_steps_stage_the_tile_rate()
  local Roamers = Fixture.requirePresent(ROAMER_MODULE, "stable roaming state and lifecycle")
  local refs = Fixture.refs()
  local stored = Fixture.roamerMon()
  local host = service({
    roamers = Roamers.new({
      records = { Fixture.roamerRecord(stored, 11, "roaming", 0) },
      species = refs.species,
      maps = refs.maps,
    }),
  })
  Fixture.pastGrace(host)
  -- Seed 10 passes movement (roll 11) while its table roll 52 refuses
  -- the raw mid rate of 30. Arena trap doubles the staged tile rate to
  -- 60, so the roamer borrows after the two opportunity draws.
  local context = roamerAttemptContext(13, { leadAbility = "arena_trap" }, leadTotodile())
  local stream = Fixture.spyStream(10)
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "prepared")
  Assert.equal(result.reason, "roamer")
  Assert.equal(result.encounter.mons[1].mon.personality, stored.personality)
  Assert.equal(stream:calls(), 2)
  Assert.deepEqual(stream:labels(), { "movement", "opportunity" })
end

function T.sweet_scent_ignores_rate_staging()
  local host = service()
  -- Seed 10 selects the first land slot (roll 11) at level 4 without
  -- any roll. Arena trap would double a staged rate, but the scripted
  -- path never stages one: identity opens on the second draw.
  local context = Fixture.context({ mapId = 13, method = "grass", movement = "field_move", lead = leadTotodile() })
  context.modifiers = Fixture.modifiers({ sweetScent = true, leadAbility = "arena_trap" })
  local stream = Fixture.spyStream(10)
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "prepared", "sweet scent draws without staging")
  local mon = assert(result.encounter.mons[1].mon)
  Assert.equal(mon.species, "CHIKORITA")
  Assert.equal(mon.met.level, 4)
  Assert.equal(mon.personality, 1465549784)
  Assert.deepEqual(mon.ivs, { hp = 17, attack = 15, defense = 31, speed = 15, specialAttack = 20, specialDefense = 16 })
  Assert.equal(mon.heldItem, "NONE")
  Assert.equal(stream:calls(), 6)
  Assert.equal(stream:labels()[1], "slot", "the slot roll opens the scripted trace")
end

function T.fishing_ignores_flute_staging()
  local host = service()
  -- Seed 42 bites 49 against the mid old-rod rate of 50. A black flute
  -- would halve a staged rate to 25 and refuse the bite, but the fishing
  -- path never stages one: the bite selects the first rod slot at level 4.
  local context = Fixture.context({ method = "fish", movement = "fish", mapId = 16 })
  context.modifiers = Fixture.modifiers({ rod = "old_rod", flute = "black" })
  local stream = Fixture.spyStream(42)
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "prepared", "fishing ignores the flute")
  local mon = assert(result.encounter.mons[1].mon)
  Assert.equal(mon.species, "CHIKORITA")
  Assert.equal(mon.met.level, 4, "the 3-5 window resolves on roll 26386")
  Assert.equal(mon.personality, 918044353)
  Assert.deepEqual(mon.ivs, { hp = 19, attack = 7, defense = 9, speed = 5, specialAttack = 20, specialDefense = 9 })
  Assert.equal(stream:calls(), 8)
end

function T.rock_smash_ignores_held_staging()
  local host = service()
  -- Seed 99 consults the full rock rate with roll 92. A cleanse tag
  -- would stage two thirds of one hundred to sixty-six and refuse it,
  -- but rock smash never stages one: the roll selects the first rock
  -- slot at level 20.
  local lead = leadTotodile()
  lead.heldItem = "CLEANSE_TAG"
  local context = Fixture.context({ method = "rock_smash", movement = "field_move", mapId = 15, lead = lead })
  local stream = Fixture.spyStream(99)
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "prepared", "rock smash ignores the held item")
  local mon = assert(result.encounter.mons[1].mon)
  Assert.equal(mon.species, "TOTODILE")
  Assert.equal(mon.met.level, 20)
  Assert.equal(mon.personality, 2913025588)
  Assert.deepEqual(mon.ivs, { hp = 2, attack = 8, defense = 20, speed = 4, specialAttack = 11, specialDefense = 13 })
  Assert.equal(stream:calls(), 8)
end

function T.lead_intimidate_and_keen_eye_suppress_low_wilds_half_the_time()
  local lead = leadTotodile()
  local host = service()
  Fixture.pastGrace(host)
  -- Seed 41 passes movement (roll 10) and the unhalved table rate of 30
  -- (roll 13), selecting the second land slot at level 4. Land takes no
  -- level roll, so the odd suppression check (20667) lets the level-4
  -- wild below the level-10 lead through after ten draws.
  local plainContext = Fixture.context({ mapId = 13, lead = lead })
  plainContext.modifiers = Fixture.modifiers({ leadAbility = "intimidate" })
  local plainStream = Fixture.spyStream(41)
  local plain = attemptResult(host, plainContext, plainStream)
  Assert.equal(plain.kind, "prepared")
  local mon = assert(plain.encounter.mons[1].mon)
  Assert.equal(mon.species, "CHIKORITA", "roll 28 selects the second land slot")
  Assert.equal(mon.met.level, 4)
  Assert.equal(mon.personality, 3507899158)
  Assert.equal(Personality.nature(mon.personality), 8)
  Assert.equal(mon.ability, "OVERGROW")
  Assert.deepEqual(mon.ivs, { hp = 15, attack = 26, defense = 2, speed = 4, specialAttack = 19, specialDefense = 12 })
  Assert.equal(mon.heldItem, "NONE")
  Assert.equal(plainStream:calls(), 9, "a passed suppression check draws once")
  Assert.deepEqual(plainStream:labels(), {
    "movement",
    "opportunity",
    "slot",
    "suppress",
    "personality_low",
    "personality_high",
    "iv_first",
    "iv_second",
    "held_item",
  })
  host:consume(plain.attemptId)
  -- Consuming re-arms the entry grace like the native post-battle
  -- return, so the deterrence legs prime past it again.
  Fixture.pastGrace(host)
  -- Seed 0 on the full-rate table selects the first land slot at level
  -- 4: the even suppression check (12720) deters it after four draws.
  for _, ability in ipairs({ "intimidate", "keen_eye" }) do
    local waryContext = Fixture.context({ mapId = 11, lead = lead })
    waryContext.modifiers = Fixture.modifiers({ leadAbility = ability })
    local waryStream = Fixture.spyStream(0)
    local wary = attemptResult(host, waryContext, waryStream)
    Assert.equal(wary.kind, "none", ability .. " deters the low wild on an even check")
    Assert.equal(wary.reason, "suppressed")
    Assert.equal(waryStream:calls(), 4, "a failed suppression check stops after slot selection")
    Assert.deepEqual(waryStream:labels(), { "movement", "opportunity", "slot", "suppress" })
  end
  -- A wild above the lead's level never reaches the check: seed 58
  -- selects the tenth land slot at level 12, past the level-10 lead,
  -- with no suppression draw. Land takes no level roll, so identity
  -- opens on the fourth draw (7977/61644, then 58040 plus two held).
  local highContext = Fixture.context({ mapId = 11, lead = lead })
  highContext.modifiers = Fixture.modifiers({ leadAbility = "intimidate" })
  local highStream = Fixture.spyStream(58)
  local high = attemptResult(host, highContext, highStream)
  Assert.equal(high.kind, "prepared", "a wild above the lead escapes suppression")
  local highMon = assert(high.encounter.mons[1].mon)
  Assert.equal(highMon.species, "EEVEE")
  Assert.equal(highMon.met.level, 12)
  Assert.equal(highMon.personality, 4039909161)
  Assert.deepEqual(
    highMon.ivs,
    { hp = 24, attack = 21, defense = 24, speed = 26, specialAttack = 14, specialDefense = 22 }
  )
  Assert.equal(highStream:calls(), 8, "an escaped wild draws no suppression check")
  Assert.equal(highStream:labels()[4], "personality_low")
  host:consume(high.attemptId)
  Fixture.pastGrace(host)
  -- A lead at level 5 or below never deters: the check stays undrawn.
  local youngContext = Fixture.context({ mapId = 11, lead = Fixture.mon("TOTODILE", 5, 11) })
  youngContext.modifiers = Fixture.modifiers({ leadAbility = "intimidate" })
  local youngStream = Fixture.spyStream(0)
  local young = attemptResult(host, youngContext, youngStream)
  Assert.equal(young.kind, "prepared", "a young lead never deters")
  Assert.equal(youngStream:calls(), 8)
  local stray = Fixture.spyStream(0)
  local before = stray:calls()
  local strayContext = Fixture.context({ mapId = 13 })
  strayContext.modifiers = Fixture.modifiers({ leadAbility = "keen_eye" })
  rejectionCode(function()
    host:attempt(strayContext, stray)
  end, "ENCOUNTER_INVALID_INPUT")
  Assert.equal(stray:calls(), before, "lead abilities without a lead consume no draws")
end

function T.lead_synchronize_reaches_generation()
  local lead = Fixture.mon("EEVEE", 12, 21)
  local leadNature = Personality.nature(lead.personality)
  local host = service()
  Fixture.pastGrace(host)
  local missedContext = Fixture.context({ lead = lead })
  missedContext.modifiers = Fixture.modifiers({ leadAbility = "synchronize", leadNature = leadNature })
  local missedStream = Fixture.spyStream(10)
  local missed = attemptResult(host, missedContext, missedStream)
  Assert.equal(missed.kind, "prepared")
  local missedMon = assert(missed.encounter.mons[1].mon)
  -- Seed 10 spends its check draw on 32241, an odd roll, so identity is
  -- drawn from the fifth draw on (personality 49807/10600, then
  -- 49114/34438 plus two held draws). Land takes no level roll.
  Assert.equal(missedMon.personality, 694731407)
  Assert.equal(missedMon.species, "EEVEE", "roll 62 selects the fifth land slot")
  Assert.equal(missedMon.met.level, 7)
  Assert.equal(Personality.nature(missedMon.personality), 7)
  Assert.equal(missedMon.ability, "ADAPTABILITY")
  Assert.deepEqual(
    missedMon.ivs,
    { hp = 26, attack = 30, defense = 15, speed = 6, specialAttack = 20, specialDefense = 1 }
  )
  Assert.equal(missedMon.heldItem, "NONE")
  Assert.equal(missedStream:calls(), 9)
  Assert.equal(missedStream:labels()[4], "synchronize", "coercion draws after slot selection")
  -- Seed 0 spends its check draw on 12720, an even roll, forcing the nature.
  local forcedContext = Fixture.context({ lead = lead })
  forcedContext.modifiers = Fixture.modifiers({ leadAbility = "synchronize", leadNature = leadNature })
  local forcedStream = Fixture.spyStream(0)
  local forcedHost = service()
  Fixture.pastGrace(forcedHost)
  local forced = attemptResult(forcedHost, forcedContext, forcedStream)
  local forcedMon = assert(forced.encounter.mons[1].mon)
  Assert.equal(Personality.nature(forcedMon.personality), leadNature, "a passed check forces the lead nature")
  -- The forced personality is the drawn one (36418/58060) with its
  -- nature replaced by the lead nature: no wrap can bite below 2^32.
  local drawnForced = 36418 + 58060 * 65536
  Assert.equal(forcedMon.personality, drawnForced - (drawnForced % 25) + leadNature)
  Assert.equal(forcedStream:calls(), 9)
end

function T.step_events_advance_counters_while_idle_events_do_not()
  local host = service()
  Fixture.pastGrace(host)
  -- The field owns the repel counter and decrements it once per committed
  -- step; the service only echoes the field-supplied value while advancing
  -- its own step counter on checking movements.
  local context = Fixture.context({ mapId = 12 })
  context.modifiers = Fixture.modifiers({ repel = true, repelSteps = 3 })
  local first = attemptResult(host, context, Fixture.spyStream(0))
  Assert.deepEqual({ first.stateDelta.steps, first.stateDelta.repelSteps }, { 1, 3 })
  local secondContext = Fixture.context({ mapId = 12 })
  secondContext.modifiers = Fixture.modifiers({ repel = true, repelSteps = 2 })
  local second = attemptResult(host, secondContext, Fixture.spyStream(0))
  Assert.deepEqual({ second.stateDelta.steps, second.stateDelta.repelSteps }, { 2, 2 })
  local thirdContext = Fixture.context({ mapId = 12 })
  thirdContext.modifiers = Fixture.modifiers({ repel = true, repelSteps = 1 })
  local third = attemptResult(host, thirdContext, Fixture.spyStream(0))
  Assert.deepEqual({ third.stateDelta.steps, third.stateDelta.repelSteps }, { 3, 1 })
  local idle = attemptResult(host, Fixture.context({ mapId = 12, movement = "menu" }), Fixture.spyStream(0))
  Assert.equal(idle.stateDelta.steps, 3, "menu events never advance the step counter")
  Assert.equal(idle.stateDelta.repelSteps, 0, "idle events echo no repel")
  local exhaustedContext = Fixture.context({ lead = leadTotodile() })
  exhaustedContext.modifiers = Fixture.modifiers({ repel = true, repelSteps = 0 })
  local exhausted = attemptResult(host, exhaustedContext, Fixture.spyStream(0))
  Assert.equal(exhausted.kind, "prepared", "expired repel no longer blocks")
end

function T.unknown_tables_and_methods_fail_without_draws()
  local host = service()
  Fixture.pastGrace(host)
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

function T.field_move_rock_smash_consults_its_table_without_counting_a_step()
  local host = service()
  local stream = Fixture.spyStream(0)
  local result = attemptResult(
    host,
    Fixture.context({ mapId = 15, method = "rock_smash", movement = "field_move" }),
    stream
  )
  Assert.equal(result.kind, "prepared")
  Assert.equal(result.stateDelta.steps, 0, "field-move attempts never advance the step counter")
  Assert.deepEqual({ stream:labels()[1], stream:labels()[2], stream:labels()[3] }, { "opportunity", "slot", "level" })
  local species = result.encounter.mons[1].mon.species
  Assert.isTrue(species == "TOTODILE" or species == "CHIKORITA", "rock smash draws from the map's rock slots")
  -- A map whose rock smash rate is zero never triggers.
  local none = attemptResult(
    host,
    Fixture.context({ mapId = 11, method = "rock_smash", movement = "field_move" }),
    Fixture.spyStream(0)
  )
  Assert.equal(none.kind, "none")
end

function T.sweet_scent_skips_the_opportunity_roll_but_needs_a_table_rate()
  local host = service()
  local stream = Fixture.spyStream(0)
  local context = Fixture.context({ mapId = 15, method = "grass", movement = "field_move" })
  context.modifiers = Fixture.modifiers({ sweetScent = true })
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "prepared")
  Assert.equal(result.stateDelta.steps, 0)
  Assert.equal(stream:labels()[1], "slot", "the opportunity roll is skipped")
  host:consume(result.attemptId)
  local surfStream = Fixture.spyStream(0)
  local surfContext = Fixture.context({ mapId = 15, method = "surf", movement = "field_move" })
  surfContext.modifiers = Fixture.modifiers({ sweetScent = true })
  local surf = attemptResult(host, surfContext, surfStream)
  Assert.equal(surf.kind, "prepared")
  Assert.equal(surfStream:labels()[1], "slot")
  host:consume(surf.attemptId)
  local zeroStream = Fixture.spyStream(0)
  local zeroContext = Fixture.context({ mapId = 12, method = "grass", movement = "field_move" })
  zeroContext.modifiers = Fixture.modifiers({ sweetScent = true })
  local zero = attemptResult(host, zeroContext, zeroStream)
  Assert.equal(zero.kind, "none")
  Assert.equal(zeroStream:calls(), 0, "a zero-rate table consumes no draws")
  -- Sweet Scent ignores deterrence and repel: the scripted check never
  -- arms either suppression flag, so a deterring lead and an active
  -- repel leave the prepared mon and its draw trace untouched.
  local deterredContext =
    Fixture.context({ mapId = 15, method = "grass", movement = "field_move", lead = leadTotodile() })
  deterredContext.modifiers = Fixture.modifiers({ sweetScent = true, leadAbility = "intimidate" })
  local deterredStream = Fixture.spyStream(0)
  local deterred = attemptResult(host, deterredContext, deterredStream)
  Assert.equal(deterred.kind, "prepared", "sweet scent ignores deterrence")
  Assert.deepEqual(deterredStream:labels(), stream:labels(), "deterrence draws nothing on sweet scent")
  host:consume(deterred.attemptId)
  local repelledContext =
    Fixture.context({ mapId = 15, method = "grass", movement = "field_move", lead = leadTotodile() })
  repelledContext.modifiers = Fixture.modifiers({ sweetScent = true, repel = true })
  local repelledStream = Fixture.spyStream(0)
  local repelled = attemptResult(host, repelledContext, repelledStream)
  Assert.equal(repelled.kind, "prepared", "sweet scent ignores repel")
  Assert.deepEqual(repelledStream:labels(), stream:labels(), "repel draws nothing on sweet scent")
end

function T.headbutt_draws_its_slot_and_level_from_the_supplied_slots()
  local host = service()
  local slots = {}
  for index, weight in ipairs({ 50, 15, 15, 10, 5, 5 }) do
    slots[index] = { species = "EEVEE", minLevel = 5, maxLevel = 7, weight = weight }
  end
  local stream = Fixture.spyStream(0)
  local context = Fixture.context({ method = "headbutt", movement = "field_move" })
  context.modifiers = Fixture.modifiers({ headbutt = { slots = slots } })
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "prepared")
  Assert.equal(result.stateDelta.steps, 0)
  Assert.deepEqual({ stream:labels()[1], stream:labels()[2] }, { "slot", "level" })
  local mon = result.encounter.mons[1].mon
  Assert.equal(mon.species, "EEVEE")
  Assert.isTrue(mon.met.level >= 5 and mon.met.level <= 7)
  -- Deterrence reaches headbutt: a level-12 intimidating lead deters
  -- the level-7 wild on an even check after three draws.
  local waryContext = Fixture.context({ method = "headbutt", movement = "field_move", lead = Fixture.mon("TOTODILE", 12, 11) })
  waryContext.modifiers = Fixture.modifiers({ headbutt = { slots = slots }, leadAbility = "intimidate" })
  local waryStream = Fixture.spyStream(10)
  local wary = attemptResult(host, waryContext, waryStream)
  Assert.equal(wary.kind, "none")
  Assert.equal(wary.reason, "suppressed")
  Assert.equal(waryStream:calls(), 3, "a deterred headbutt stops after level selection")
  Assert.deepEqual(waryStream:labels(), { "slot", "level", "suppress" })
  -- Repel never arms off the step path: an armed repel against a lower
  -- wild still prepares.
  local repelledContext =
    Fixture.context({ method = "headbutt", movement = "field_move", lead = Fixture.mon("TOTODILE", 25, 11) })
  repelledContext.modifiers = Fixture.modifiers({ headbutt = { slots = slots }, repel = true })
  local repelledStream = Fixture.spyStream(10)
  local repelled = attemptResult(host, repelledContext, repelledStream)
  Assert.equal(repelled.kind, "prepared", "headbutt ignores an armed repel")
  local repelledMon = assert(repelled.encounter.mons[1].mon)
  Assert.equal(repelledMon.species, "EEVEE")
  Assert.equal(repelledMon.met.level, 7)
  Assert.equal(repelledMon.personality, 2112968538)
  Assert.deepEqual(repelledMon.ivs, { hp = 15, attack = 20, defense = 16, speed = 8, specialAttack = 11, specialDefense = 10 })
  Assert.equal(repelledStream:calls(), 7)
  Assert.deepEqual(repelledStream:labels(), {
    "slot",
    "level",
    "personality_low",
    "personality_high",
    "iv_first",
    "iv_second",
    "held_item",
  })
  rejectionCode(function()
    local missing = Fixture.context({ method = "headbutt", movement = "field_move" })
    host:attempt(missing, Fixture.spyStream(0))
  end, "ENCOUNTER_MISSING_TABLE")
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
  Assert.equal(stream:calls(), 5, "scripted encounters skip opportunity and selection")
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

function T.roamer_step_attempts_take_the_tile_opportunity_rolls()
  local Roamers = Fixture.requirePresent(ROAMER_MODULE, "stable roaming state and lifecycle")
  local refs = Fixture.refs()
  local stored = Fixture.roamerMon()
  local newcomers = function()
    return Roamers.new({
      records = { Fixture.roamerRecord(stored, 11, "roaming", 0) },
      species = refs.species,
      maps = refs.maps,
    })
  end
  -- The entry grace refuses roaming step checks before any draw, like
  -- land and water.
  local gated = service({ roamers = newcomers() })
  for _ = 1, 3 do
    local refusedStream = Fixture.spyStream(0)
    local refused = attemptResult(
      gated,
      roamerAttemptContext(11, { roamerKey = "roamer-eevee", tileMethod = "grass" }),
      refusedStream
    )
    Assert.equal(refused.kind, "none")
    Assert.equal(refused.reason, "grace")
    Assert.equal(refusedStream:calls(), 0, "grace refusals draw nothing")
  end
  local host = service({ roamers = newcomers() })
  Fixture.pastGrace(host)
  -- Seed 1 refuses the walking movement rate of 20 (roll 38) after a
  -- single draw, before any borrow.
  local refusedStream = Fixture.spyStream(1)
  local refused = attemptResult(host, roamerAttemptContext(11, {}), refusedStream)
  Assert.equal(refused.kind, "none")
  Assert.equal(refused.reason, "no_opportunity")
  Assert.equal(refusedStream:calls(), 1, "a failed movement roll draws once and stops")
  Assert.deepEqual(refusedStream:labels(), { "movement" })
  -- Seed 0 passes movement (roll 0) and the full table rate (roll 74),
  -- then borrows the stored identity with no further draws.
  local stream = Fixture.spyStream(0)
  local result = attemptResult(host, roamerAttemptContext(11, {}), stream)
  Assert.equal(result.kind, "prepared")
  Assert.equal(result.reason, "roamer")
  local mon = assert(result.encounter.mons[1].mon)
  Assert.equal(mon.species, "EEVEE")
  Assert.equal(mon.personality, stored.personality, "roamer construction reuses the stored identity")
  Assert.deepEqual(mon.ivs, stored.ivs)
  Assert.equal(stream:calls(), 2, "a roaming step consumes the two opportunity draws")
  Assert.deepEqual(stream:labels(), { "movement", "opportunity" })
  host:consume(result.attemptId)
  Fixture.pastGrace(host)
  -- The mid-rate member refuses the table roll (74 against 30) after
  -- the movement draw, mirroring the table path.
  local tableStream = Fixture.spyStream(0)
  local tableMiss = attemptResult(host, roamerAttemptContext(13, {}), tableStream)
  Assert.equal(tableMiss.kind, "none")
  Assert.equal(tableMiss.reason, "no_opportunity")
  Assert.equal(tableStream:calls(), 2, "a failed table roll stops after the movement draw")
  Assert.deepEqual(tableStream:labels(), { "movement", "opportunity" })
  -- A surf tile stages its own table rate: member 11 carries no surf
  -- rate, so the attempt misses before any draw.
  local surfStream = Fixture.spyStream(0)
  local surfMiss =
    attemptResult(host, roamerAttemptContext(11, { tileMethod = "surf" }), surfStream)
  Assert.equal(surfMiss.kind, "none")
  Assert.equal(surfMiss.reason, "no_opportunity")
  Assert.equal(surfStream:calls(), 0, "an empty tile rate draws nothing")
  -- Repel suppresses a roamer below the lead without deterrence draws:
  -- the stored EEVEE at 20 falls below a level-25 lead.
  local highStream = Fixture.spyStream(0)
  local high = attemptResult(
    host,
    roamerAttemptContext(11, { repel = true }, Fixture.mon("TOTODILE", 25, 11)),
    highStream
  )
  Assert.equal(high.kind, "none", "repel suppresses the lower roamer")
  Assert.equal(high.reason, "repel")
  Assert.equal(highStream:calls(), 2, "roamer repel draws no suppression check")
  Assert.deepEqual(highStream:labels(), { "movement", "opportunity" })
  -- A roamer at or above the lead passes: the stored EEVEE at 20
  -- escapes a level-10 lead.
  local lowStream = Fixture.spyStream(0)
  local low = attemptResult(host, roamerAttemptContext(11, { repel = true }, leadTotodile()), lowStream)
  Assert.equal(low.kind, "prepared", "a roamer above the lead escapes repel")
  Assert.equal(low.encounter.mons[1].mon.personality, stored.personality)
  Assert.equal(lowStream:calls(), 2)
  host:consume(low.attemptId)
  Fixture.pastGrace(host)
  -- The roamer repel reads the first alive mon too: a level-10 lead
  -- would admit the stored EEVEE, but a level-25 first alive mon
  -- suppresses it.
  local splitStream = Fixture.spyStream(0)
  local splitContext = Fixture.context({
    method = "roamer",
    mapId = 11,
    lead = leadTotodile(),
    firstAlive = Fixture.mon("TOTODILE", 25, 11),
  })
  splitContext.modifiers = Fixture.modifiers({ roamerKey = "roamer-eevee", tileMethod = "grass", repel = true })
  local split = attemptResult(host, splitContext, splitStream)
  Assert.equal(split.kind, "none")
  Assert.equal(split.reason, "repel")
  Assert.equal(splitStream:calls(), 2)
  -- Sweet Scent borrows without rolls or deterrence: even an armed
  -- repel against a lower roamer never fires on the scripted path.
  local sweetStream = Fixture.spyStream(0)
  local sweet = attemptResult(
    host,
    roamerAttemptContext(11, { sweetScent = true, repel = true }, Fixture.mon("TOTODILE", 25, 11)),
    sweetStream
  )
  Assert.equal(sweet.kind, "prepared", "sweet scent ignores roamer opportunity and repel")
  Assert.equal(sweet.encounter.mons[1].mon.personality, stored.personality)
  Assert.equal(sweetStream:calls(), 0, "a scripted roamer draws nothing")
  -- Roamer facts stay strict: a missing tile method, an unknown tile
  -- method, and an unknown roamer key all fail without draws.
  do
    local stray = Fixture.spyStream(0)
    local before = stray:calls()
    rejectionCode(function()
      local missing = Fixture.context({ method = "roamer", mapId = 11 })
      missing.modifiers = Fixture.modifiers({ roamerKey = "roamer-eevee" })
      host:attempt(missing, stray)
    end, "ENCOUNTER_INVALID_INPUT")
    Assert.equal(stray:calls(), before, "a missing tile method consumes no draws")
  end
  for _, mods in ipairs({
    { roamerKey = "roamer-eevee", tileMethod = "cave" },
    { roamerKey = "bogus-key", tileMethod = "grass" },
  }) do
    local stray = Fixture.spyStream(0)
    local before = stray:calls()
    rejectionCode(function()
      host:attempt(roamerAttemptContext(11, mods), stray)
    end, "ENCOUNTER_INVALID_INPUT")
    Assert.equal(stray:calls(), before, "rejected roamer facts consume no draws")
  end
  -- A stored roamer past its roaming lifecycle refuses before any draw:
  -- borrowing validates the record ahead of the rolls.
  local settled = newcomers()
  settled:prepareResult("roamer-eevee", "captured", 0, {})
  local settledHost = service({ roamers = settled })
  Fixture.pastGrace(settledHost)
  local settledStream = Fixture.spyStream(0)
  local settledBefore = settledStream:calls()
  rejectionCode(function()
    settledHost:attempt(roamerAttemptContext(11, {}), settledStream)
  end, "ENCOUNTER_INVALID_INPUT")
  Assert.equal(settledStream:calls(), settledBefore, "a settled roamer consumes no draws")
end

function T.prepared_encounters_are_consumed_exactly_once()
  local host = service()
  Fixture.pastGrace(host)
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
  Fixture.pastGrace(host)
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
  Fixture.pastGrace(host)
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

function T.step_attempts_honor_the_native_entry_grace()
  local host = service()
  -- A fresh service refuses the first three step attempts before any
  -- draw: the native entry grace counts completed steps, not rolls.
  for _ = 1, 3 do
    local refusedStream = Fixture.spyStream(0)
    local refused = attemptResult(host, Fixture.context({ mapId = 11 }), refusedStream)
    Assert.equal(refused.kind, "none")
    Assert.equal(refused.reason, "grace")
    Assert.isNil(refused.encounter)
    Assert.equal(refusedStream:calls(), 0, "grace refusals draw nothing")
  end
  -- The fourth step rolls: seed 0 passes movement and the full table rate.
  local stream = Fixture.spyStream(0)
  local result = attemptResult(host, Fixture.context({ mapId = 11 }), stream)
  Assert.equal(result.kind, "prepared")
  Assert.equal(result.reason, "triggered")
  Assert.equal(stream:calls(), 8, "the first rolling attempt draws the full trace")
end

function T.step_attempts_count_reverse_turns_for_the_movement_boost()
  local host = service()
  Fixture.pastGrace(host)
  -- Facing south first counts against the cleared tracker, which reads as
  -- north: the first reversal stages no boost, so seed 1 (roll 38) misses
  -- the walking twenty after a single draw.
  local firstStream = Fixture.spyStream(1)
  local firstContext = Fixture.context({ mapId = 11 })
  firstContext.modifiers = Fixture.modifiers({ facing = "south" })
  local first = attemptResult(host, firstContext, firstStream)
  Assert.equal(first.kind, "none")
  Assert.equal(first.reason, "no_opportunity")
  Assert.equal(firstStream:calls(), 1, "an unboosted movement roll draws once")
  -- Turning back north is the second reversal: the boost of thirty paces
  -- movement at fifty, so the same roll clears it and triggers the full
  -- table rate.
  local stream = Fixture.spyStream(1)
  local context = Fixture.context({ mapId = 11 })
  context.modifiers = Fixture.modifiers({ facing = "north" })
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "prepared")
  Assert.equal(result.reason, "triggered")
  local mon = assert(result.encounter.mons[1].mon, "the boosted attempt carries its wild mon")
  Assert.equal(mon.species, "SHEDINJA", "roll 98 selects the eleventh land slot")
  Assert.equal(mon.met.level, 13)
  Assert.equal(stream:calls(), 8, "a boosted trigger draws the full trace")
  Assert.deepEqual(stream:labels(), {
    "movement",
    "opportunity",
    "slot",
    "personality_low",
    "personality_high",
    "iv_first",
    "iv_second",
    "held_item",
  })
  host:consume(result.attemptId)
  -- Consuming ends the step-driven counting like the native post-battle
  -- return: past the re-armed grace, facing south counts one fresh turn,
  -- so seed 1 misses the unboosted walking twenty again.
  Fixture.pastGrace(host)
  local freshStream = Fixture.spyStream(1)
  local freshContext = Fixture.context({ mapId = 11 })
  freshContext.modifiers = Fixture.modifiers({ facing = "south" })
  local fresh = attemptResult(host, freshContext, freshStream)
  Assert.equal(fresh.kind, "none", "consumption clears the accrued turns")
  Assert.equal(fresh.reason, "no_opportunity")
  Assert.equal(freshStream:calls(), 1)
end

function T.map_entry_resets_the_step_driven_counters()
  local host = service()
  Fixture.pastGrace(host)
  -- Accrue two turns that both miss: facing south counts one, turning
  -- north counts two, and seed 5 (roll 55) refuses even the boosted
  -- fifty after a single draw each time.
  for _, facing in ipairs({ "south", "north" }) do
    local stream = Fixture.spyStream(5)
    local context = Fixture.context({ mapId = 11 })
    context.modifiers = Fixture.modifiers({ facing = facing })
    local accrued = attemptResult(host, context, stream)
    Assert.equal(accrued.kind, "none")
    Assert.equal(accrued.reason, "no_opportunity")
    Assert.equal(stream:calls(), 1)
  end
  host:resetStepCounters()
  -- The grace re-arms at once: the next step refuses before any draw.
  local graceStream = Fixture.spyStream(5)
  local graceContext = Fixture.context({ mapId = 11 })
  graceContext.modifiers = Fixture.modifiers({ facing = "south" })
  local grace = attemptResult(host, graceContext, graceStream)
  Assert.equal(grace.kind, "none")
  Assert.equal(grace.reason, "grace")
  Assert.equal(graceStream:calls(), 0, "a reset entry refuses before any draw")
  -- Past the re-armed grace, facing south counts one fresh turn: had the
  -- accrued two survived, the third would boost movement to sixty and
  -- trigger seed 5, but the unboosted twenty refuses it.
  Fixture.pastGrace(host)
  local freshStream = Fixture.spyStream(5)
  local freshContext = Fixture.context({ mapId = 11 })
  freshContext.modifiers = Fixture.modifiers({ facing = "south" })
  local fresh = attemptResult(host, freshContext, freshStream)
  Assert.equal(fresh.kind, "none", "entry clears the accrued turns")
  Assert.equal(fresh.reason, "no_opportunity")
  Assert.equal(freshStream:calls(), 1)
end

function T.map_entry_preserves_the_turn_trackers_facing()
  local host = service()
  Fixture.pastGrace(host)
  -- Facing south counts one turn against the cleared tracker.
  local firstStream = Fixture.spyStream(1)
  local firstContext = Fixture.context({ mapId = 11 })
  firstContext.modifiers = Fixture.modifiers({ facing = "south" })
  local first = attemptResult(host, firstContext, firstStream)
  Assert.equal(first.kind, "none")
  Assert.equal(first.reason, "no_opportunity")
  host:resetStepCounters()
  -- The entry clears the count but never the facing: past the re-armed
  -- grace, south meets south for no count and north counts one, so seed
  -- 1 still misses the unboosted twenty twice. Had the entry cleared
  -- the facing to north, the south would count one and the north two,
  -- boosting movement to fifty and triggering seed 1.
  Fixture.pastGrace(host)
  for _, facing in ipairs({ "south", "north" }) do
    local stream = Fixture.spyStream(1)
    local context = Fixture.context({ mapId = 11 })
    context.modifiers = Fixture.modifiers({ facing = facing })
    local result = attemptResult(host, context, stream)
    Assert.equal(result.kind, "none", "facing " .. facing .. " stays unboosted after entry")
    Assert.equal(result.reason, "no_opportunity")
    Assert.equal(stream:calls(), 1)
  end
end

function T.step_attempts_check_the_movement_roll_before_the_table_rate()
  local host = service()
  Fixture.pastGrace(host)
  -- Member 11 answers every table roll (rate 100), so only the native
  -- movement roll can refuse it. Seed 1 opens with movement roll 38,
  -- refused by the walking movement rate of 20 after a single draw.
  local refusedStream = Fixture.spyStream(1)
  local refused = attemptResult(host, Fixture.context({ mapId = 11 }), refusedStream)
  Assert.equal(refused.kind, "none")
  Assert.equal(refused.reason, "no_opportunity")
  Assert.equal(refusedStream:calls(), 1, "a failed movement roll draws once and stops")
  Assert.deepEqual(refusedStream:labels(), { "movement" })
  -- Seed 0 passes the movement roll (roll 0) on the mid-rate member 13,
  -- but its table roll 74 refuses the rate of 30, stopping after two draws.
  local tableStream = Fixture.spyStream(0)
  local tableMiss = attemptResult(host, Fixture.context({ mapId = 13 }), tableStream)
  Assert.equal(tableMiss.kind, "none")
  Assert.equal(tableMiss.reason, "no_opportunity")
  Assert.equal(tableStream:calls(), 2, "a failed table roll stops after the movement draw")
  Assert.deepEqual(tableStream:labels(), { "movement", "opportunity" })
end

--- The test type provider behind slot coercion. TOTODILE answers a
--- caller-chosen target type so the picker has a partial match against
--- the vector ladders; every other vector species answers its
--- catalog-fixture types. The mapping is mechanical test input, never a
--- claim about the species.
---@param species string
---@param form integer
---@return string[] lower-case type keys
local function coercionTypes(species, form)
  assert(form == 0, "coercion reads the base form")
  if species == "TOTODILE" then
    return { "electric", "steel" }
  end
  if species == "CHIKORITA" then
    return { "grass" }
  end
  if species == "EEVEE" then
    return { "normal" }
  end
  if species == "SHEDINJA" then
    return { "bug", "ghost" }
  end
  if species == "PICHU" then
    return { "electric" }
  end
  return {}
end

local function steelTypes(species, form)
  assert(form == 0, "coercion reads the base form")
  if species == "TOTODILE" then
    return { "steel" }
  end
  return coercionTypes(species, form)
end

---@param overrides table<string, unknown>|nil
---@return table<string, unknown> grass step context with a leveled lead
local function leadAbilityContext(ability, overrides)
  local merged = { leadAbility = ability }
  for key, value in pairs(overrides or {}) do
    merged[key] = value
  end
  local context = Fixture.context({ lead = leadTotodile() })
  context.modifiers = Fixture.modifiers(merged)
  return context
end

function T.static_coercion_replaces_the_grass_slot_roll()
  local host = service({ speciesTypes = coercionTypes })
  Fixture.pastGrace(host)
  local stream = Fixture.spyStream(3)
  -- Seed 3 draws: movement 15 under the walking twenty, opportunity 46,
  -- gate 54250 even, pick 64452 into the three TOTODILE slots
  -- (1-based 3, 4, 9): 64452 mod 3 is 0, so the first match wins. Land
  -- carries no level roll; the fixed slot level 5 answers directly.
  local result = attemptResult(host, leadAbilityContext("static"), stream)
  Assert.equal(result.kind, "prepared")
  Assert.equal(result.reason, "triggered")
  local mon = assert(result.encounter.mons[1].mon, "the encounter carries its wild mon")
  Assert.equal(mon.species, "TOTODILE")
  Assert.equal(mon.met.level, 5)
  Assert.equal(mon.personality, 1583436070, "personality 20774 + 24161*65536")
  Assert.deepEqual(
    mon.ivs,
    { hp = 5, attack = 11, defense = 0, speed = 21, specialAttack = 27, specialDefense = 21 },
    "IVs split from 33125/55157"
  )
  Assert.equal(mon.heldItem, "NONE")
  Assert.equal(stream:calls(), 9, "coercion consumes gate and pick draws instead of the slot roll")
  Assert.deepEqual(stream:labels(), {
    "movement",
    "opportunity",
    "slot_coerce",
    "slot_coerce_pick",
    "personality_low",
    "personality_high",
    "iv_first",
    "iv_second",
    "held_item",
  })
end

function T.failed_coercion_gate_falls_through_to_the_slot_roll()
  local host = service({ speciesTypes = coercionTypes })
  Fixture.pastGrace(host)
  local stream = Fixture.spyStream(0)
  -- Seed 0 draws: movement 0, opportunity 74, gate 21105 odd, so the
  -- coercion refuses and the normal slot roll 12720 answers slot 2
  -- (roll 20 opens the second land interval). The consumed gate draw
  -- shifts the identity stream by one, so the personality opens on the
  -- fourth table draw (36418 + 58060*65536).
  local result = attemptResult(host, leadAbilityContext("static"), stream)
  Assert.equal(result.kind, "prepared")
  local mon = assert(result.encounter.mons[1].mon, "the encounter carries its wild mon")
  Assert.equal(mon.species, "CHIKORITA")
  Assert.equal(mon.met.level, 4)
  Assert.equal(mon.personality, 3805056578, "the gate draw shifts the identity stream")
  Assert.deepEqual(
    mon.ivs,
    { hp = 5, attack = 30, defense = 11, speed = 27, specialAttack = 30, specialDefense = 25 },
    "IVs split from 44997/26587"
  )
  Assert.deepEqual(stream:labels(), {
    "movement",
    "opportunity",
    "slot_coerce",
    "slot",
    "personality_low",
    "personality_high",
    "iv_first",
    "iv_second",
    "held_item",
  })
end

function T.coercion_without_a_type_provider_skips_its_draws()
  local host = service()
  Fixture.pastGrace(host)
  -- Without slot types the 50% gate cannot evaluate, so the attempt
  -- draws no coercion labels and rolls normally: the same seed-0 draws
  -- as the unled grass trace.
  local stream = Fixture.spyStream(0)
  local result = attemptResult(host, leadAbilityContext("static"), stream)
  Assert.equal(result.kind, "prepared")
  local mon = assert(result.encounter.mons[1].mon, "the encounter carries its wild mon")
  Assert.equal(mon.species, "CHIKORITA")
  Assert.equal(mon.personality, 2386702768)
  Assert.equal(stream:calls(), 8)
  Assert.deepEqual(stream:labels(), {
    "movement",
    "opportunity",
    "slot",
    "personality_low",
    "personality_high",
    "iv_first",
    "iv_second",
    "held_item",
  })
end

function T.magnet_pull_coercion_targets_steel()
  local host = service({ speciesTypes = steelTypes })
  Fixture.pastGrace(host)
  local stream = Fixture.spyStream(3)
  -- Same seed-3 draws as the static pin: movement 15, opportunity 46,
  -- gate even, pick 64452 mod 3 is 0 into the TOTODILE slots, which the
  -- steel stub claims. Only the target type differs.
  local result = attemptResult(host, leadAbilityContext("magnet_pull"), stream)
  Assert.equal(result.kind, "prepared")
  local mon = assert(result.encounter.mons[1].mon, "the encounter carries its wild mon")
  Assert.equal(mon.species, "TOTODILE")
  Assert.equal(mon.met.level, 5)
  Assert.equal(mon.personality, 1583436070)
  Assert.deepEqual(stream:labels(), {
    "movement",
    "opportunity",
    "slot_coerce",
    "slot_coerce_pick",
    "personality_low",
    "personality_high",
    "iv_first",
    "iv_second",
    "held_item",
  })
end

function T.static_coercion_replaces_the_fishing_slot_roll()
  local host = service({ speciesTypes = coercionTypes })
  local stream = Fixture.spyStream(3)
  -- Seed 3 draws: bite 15, gate 12646 even, pick 54250 into the two
  -- TOTODILE rod slots (1-based 2, 5): 54250 mod 2 is 0, so the first
  -- match wins. The level roll 64452 resolves the 4-6 window to 4.
  local context = Fixture.context({ lead = leadTotodile(), method = "fish", movement = "fish", mapId = 14 })
  context.modifiers = Fixture.modifiers({ rod = "old_rod", leadAbility = "static" })
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "prepared")
  local mon = assert(result.encounter.mons[1].mon, "the encounter carries its wild mon")
  Assert.equal(mon.species, "TOTODILE")
  Assert.equal(mon.met.level, 4, "the picked slot window resolves on roll 64452")
  Assert.equal(mon.personality, 1583436070)
  Assert.deepEqual(stream:labels(), {
    "opportunity",
    "slot_coerce",
    "slot_coerce_pick",
    "level",
    "personality_low",
    "personality_high",
    "iv_first",
    "iv_second",
    "held_item",
  })
end

function T.static_coercion_replaces_the_headbutt_slot_roll()
  local host = service({ speciesTypes = coercionTypes })
  local stream = Fixture.spyStream(7)
  -- Seed 7 draws: gate 52332 even, pick 15344 into the two TOTODILE
  -- headbutt slots (1-based 2, 5): 15344 mod 2 is 0, so the first match
  -- wins. The level roll 54753 resolves the 4-6 window to 4.
  local slots = {
    { species = "CHIKORITA", form = 0, minLevel = 3, maxLevel = 5, weight = 50 },
    { species = "TOTODILE", form = 0, minLevel = 4, maxLevel = 6, weight = 15 },
    { species = "EEVEE", form = 0, minLevel = 6, maxLevel = 8, weight = 15 },
    { species = "CHIKORITA", form = 0, minLevel = 5, maxLevel = 9, weight = 10 },
    { species = "TOTODILE", form = 0, minLevel = 7, maxLevel = 10, weight = 5 },
    { species = "EEVEE", form = 0, minLevel = 6, maxLevel = 8, weight = 5 },
  }
  local context = Fixture.context({ lead = leadTotodile(), method = "headbutt", movement = "field_move" })
  context.modifiers = Fixture.modifiers({ headbutt = { slots = slots }, leadAbility = "static" })
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "prepared")
  Assert.equal(result.reason, "triggered")
  local mon = assert(result.encounter.mons[1].mon, "the encounter carries its wild mon")
  Assert.equal(mon.species, "TOTODILE")
  Assert.equal(mon.met.level, 4)
  Assert.equal(mon.personality, 4289442782, "personality 46046 + 65451*65536")
  Assert.deepEqual(
    mon.ivs,
    { hp = 19, attack = 14, defense = 11, speed = 26, specialAttack = 17, specialDefense = 27 },
    "IVs split from 44499/60986"
  )
  Assert.equal(mon.heldItem, "NONE")
  Assert.deepEqual(stream:labels(), {
    "slot_coerce",
    "slot_coerce_pick",
    "level",
    "personality_low",
    "personality_high",
    "iv_first",
    "iv_second",
    "held_item",
  })
end

function T.sweet_scent_inherits_slot_coercion()
  local host = service({ speciesTypes = coercionTypes })
  local stream = Fixture.spyStream(58)
  -- Seed 58 draws: gate 59118 even, pick 597 into the three TOTODILE
  -- land slots: 597 mod 3 is 0, so the first match wins. Sweet scent
  -- stages no opportunity rolls, so the gate opens the trace.
  local context = Fixture.context({ lead = leadTotodile(), movement = "field_move" })
  context.modifiers = Fixture.modifiers({ sweetScent = true, leadAbility = "static" })
  local result = attemptResult(host, context, stream)
  Assert.equal(result.kind, "prepared")
  Assert.equal(result.reason, "triggered")
  local mon = assert(result.encounter.mons[1].mon, "the encounter carries its wild mon")
  Assert.equal(mon.species, "TOTODILE")
  Assert.equal(mon.met.level, 5)
  Assert.equal(mon.personality, 522809069, "personality 28397 + 7977*65536")
  Assert.deepEqual(
    mon.ivs,
    { hp = 12, attack = 6, defense = 28, speed = 24, specialAttack = 21, specialDefense = 24 },
    "IVs split from 61644/58040"
  )
  Assert.equal(mon.heldItem, "NONE")
  Assert.deepEqual(stream:labels(), {
    "slot_coerce",
    "slot_coerce_pick",
    "personality_low",
    "personality_high",
    "iv_first",
    "iv_second",
    "held_item",
  })
end

return { tests = T }
