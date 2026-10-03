-- Native trainer decisions owned by the battle session: move scores open
-- at the source baseline with slot-ordered initialization draws, equal-top
-- ties break uniformly through one selection draw, reserve
-- choice weighs moves and damage instead of exposure alone, item
-- availability follows session inventory, and production trainer answers
-- route through the native session seam.

local Assert = require("tests.support.Assert")
local BattleRng = require("libs.battle.src.gen4.BattleRng")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

local FIXED_SEED = 984260731
local NATIVE_SEED = 0x1BADB002

---@param name string module path under test
---@param behavior string observable behavior the module owns
---@return table the loaded module
local function requirePresent(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing battle behavior: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the battle module loads")
  return loaded --[[@as table]]
end

---@return table the native trainer policy under test
local function trainerPolicy()
  return requirePresent("libs.battle.src.gen4.TrainerAi", "the native session owns trainer decisions")
end

---@return table the native session owner under test
local function sessionOwner()
  return SessionFixture.requirePresent(
    "libs.battle.src.gen4.HgssSessionExecutor",
    "the private native lifecycle owns HGSS ruleset sessions"
  )
end

---@param seed integer
---@return table labeled native stream recording every draw site
local function spyStream(seed)
  local inner = BattleRng.new(seed)
  local labels = {}
  local stream = {}
  function stream:nextU16(label, cause)
    labels[#labels + 1] = label
    return inner:nextU16(label, cause)
  end
  function stream:capture()
    return inner:capture()
  end
  function stream:drawLabels()
    local out = {}
    for index, label in ipairs(labels) do
      out[index] = label
    end
    return out
  end
  return stream
end

---@return table frozen battle content carrying the native ruleset binding
local function trainerContent()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local Executor = sessionOwner()
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "native-trainer-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "native-trainer-tests"
  )
  behaviors:registerFormat("single", { key = "single" }, "native-trainer-tests")
  behaviors:registerFormat("double", { key = "double" }, "native-trainer-tests")
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

---@return table session chart resolving directed pairs through the native matrix
local function nativeChart()
  return trainerContent():typeChart(sessionOwner().RULESET)
end

---@param overrides table<string, string|number|boolean> explicit slot fields under test construction
---@return table explicit move slot facts for scoring
local function slotWith(overrides)
  local slot = {
    key = "TACKLE",
    moveType = "normal",
    power = 35,
    category = "physical",
    accuracy = 95,
    usable = true,
  }
  for key, value in pairs(overrides) do
    slot[key] = value
  end
  return slot
end

---@param overrides table<string, string|number|boolean|string[]> explicit stat fields under test construction
---@return table explicit battle stats for scoring
local function fighterWith(overrides)
  local fighter = {
    types = { "normal" },
    level = 5,
    attack = 12,
    defense = 10,
    specialAttack = 12,
    specialDefense = 10,
  }
  for key, value in pairs(overrides) do
    fighter[key] = value
  end
  return fighter
end

---@return table four explicit move slots, one of them spent
local function fourSlots()
  return {
    slotWith({ key = "TACKLE" }),
    slotWith({ key = "RAZOR_LEAF", moveType = "grass", power = 55, accuracy = 95 }),
    slotWith({ key = "GROWL", moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "EMBER", moveType = "fire", power = 40, category = "special", accuracy = 100, usable = false }),
  }
end

-- Move scoring opens at the source baseline: every usable slot starts at
-- one hundred points, the spent slot stays at zero, and the four
-- initialization draws precede flag evaluation in slot order. A fixed
-- seed replays the same scores.
function T.move_scores_open_at_the_source_baseline_in_slot_order()
  local TrainerAi = trainerPolicy()
  local stream = spyStream(FIXED_SEED)
  local scored = TrainerAi.scoreSlots(
    nativeChart(),
    fourSlots(),
    fighterWith({ types = { "grass" } }),
    fighterWith({ types = { "rock", "ground" } }),
    14,
    {},
    stream
  )
  Assert.equal(#scored, 4, "scoring covers every native move slot")
  Assert.equal(scored[1].score, 100, "the first usable slot opens at the source baseline")
  Assert.equal(scored[2].score, 100, "the second usable slot opens at the source baseline")
  Assert.equal(scored[3].score, 100, "the third usable slot opens at the source baseline")
  Assert.equal(scored[4].score, 0, "the spent slot stays excluded at zero")
  local labels = stream:drawLabels()
  Assert.isTrue(#labels >= 4, "initialization draws once per native move slot")
  Assert.deepEqual(
    { labels[1], labels[2], labels[3], labels[4] },
    { "score_init_0", "score_init_1", "score_init_2", "score_init_3" },
    "initialization draws precede evaluation in slot order"
  )
  local second = TrainerAi.scoreSlots(
    nativeChart(),
    fourSlots(),
    fighterWith({ types = { "grass" } }),
    fighterWith({ types = { "rock", "ground" } }),
    14,
    {},
    spyStream(FIXED_SEED)
  )
  Assert.deepEqual(second, scored, "a fixed seed replays the same scores")
end

-- Pass names outside the native set fail closed: an unknown bit, the
-- doubles bit, and malformed names all raise naming the offending pass,
-- while repeats collapse and dispatch runs in ascending bit order.
function T.pass_names_outside_the_native_set_fail_before_any_draw()
  local TrainerAi = trainerPolicy()
  Assert.deepEqual(TrainerAi.parsePasses({}), {}, "flagless trainers carry no bits")
  Assert.deepEqual(
    TrainerAi.parsePasses({ "ai_pass_9", "ai_pass_2", "ai_pass_0", "ai_pass_2" }),
    { 0, 2, 9 },
    "passes dispatch in ascending bit order without repeats"
  )
  for _, pass in ipairs({ "ai_pass_4", "ai_pass_7", "ai_pass_10", "bogus", "", "ai_pass_" }) do
    local failure = Assert.throws(function()
      TrainerAi.parsePasses({ pass })
    end, "pass " .. tostring(pass) .. " fails instead of falling back")
    Assert.isTrue(
      string.find(tostring(failure), tostring(pass), 1, true) ~= nil,
      "the failure names the offending pass"
    )
  end
  local malformed = Assert.throws(function()
    TrainerAi.parsePasses({ 42 })
  end, "non-string passes fail instead of falling back")
  Assert.isTrue(string.find(tostring(malformed), "42", 1, true) ~= nil, "the failure names the offending pass")
end

-- The bad-move check scores every usable slot by its matchup and
-- withholds points from negated strikes: a move the foe is immune to
-- falls below scoreless status attempts instead of tying them.
function T.negated_strikes_fall_below_status_attempts()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local slots = {
    slotWith({ key = "TACKLE", moveType = "normal", power = 35 }),
    slotWith({ key = "SLEEP_POWDER", moveType = "grass", power = 0, category = "status", accuracy = 75 }),
    slotWith({ key = "SPENT_A", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
    slotWith({ key = "SPENT_B", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
  }
  local scored = TrainerAi.scoreSlots(
    chart,
    slots,
    fighterWith({ types = { "grass" } }),
    fighterWith({ types = { "ghost" } }),
    14,
    { 0 },
    spyStream(FIXED_SEED)
  )
  Assert.equal(scored[1].score, 90, "the negated strike keeps its matchup minus the penalty")
  Assert.equal(scored[2].score, 100, "the status attempt holds the baseline")
end

-- Equal-top ties break uniformly through exactly one selection draw: the
-- pick follows the draw remainder over the tied slots in source order, a
-- lone leader still spends the draw, and a fixed seed replays the pick.
function T.tied_top_scores_break_uniformly_through_one_selection_draw()
  local TrainerAi = trainerPolicy()
  local tied = {
    { slot = 0, key = "TACKLE", score = 100 },
    { slot = 1, key = "RAZOR_LEAF", score = 100 },
    { slot = 2, key = "GROWL", score = 100 },
    { slot = 3, key = "SPENT", score = 0 },
  }
  local stream = spyStream(FIXED_SEED)
  local pick = TrainerAi.selectMove(tied, stream)
  Assert.deepEqual(stream:drawLabels(), { "selection_roll" }, "selection draws exactly once with its stable label")
  local probe = BattleRng.new(FIXED_SEED)
  local expected = probe:nextU16("selection_roll", { tied = 3 })
  Assert.equal(pick, tied[(expected % 3) + 1].slot, "the pick follows the draw remainder over the tied slots")
  Assert.equal(TrainerAi.selectMove(tied, spyStream(FIXED_SEED)), pick, "a fixed seed replays the same pick")
  local lone = {
    { slot = 0, key = "TACKLE", score = 110 },
    { slot = 1, key = "RAZOR_LEAF", score = 100 },
    { slot = 2, key = "GROWL", score = 100 },
    { slot = 3, key = "SPENT", score = 0 },
  }
  local loneStream = spyStream(FIXED_SEED)
  Assert.equal(TrainerAi.selectMove(lone, loneStream), 0, "the lone leader answers")
  Assert.deepEqual(loneStream:drawLabels(), { "selection_roll" }, "a lone leader still spends its selection draw")
end

-- Faint-seeking prefers the finishing blow: the most powerful neutral
-- strike wins outright without needing a tiebreak draw.
function T.faint_seeking_prefers_the_strongest_neutral_strike()
  local TrainerAi = trainerPolicy()
  local stream = spyStream(FIXED_SEED)
  local scored = TrainerAi.scoreSlots(nativeChart(), {
    slotWith({ key = "EMBER", moveType = "fire", power = 40, accuracy = 100 }),
    slotWith({ key = "SCRATCH", moveType = "normal", power = 60, accuracy = 100 }),
    slotWith({ key = "SPENT_A", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
    slotWith({ key = "SPENT_B", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
  }, fighterWith({ types = { "fire" } }), fighterWith({ types = { "normal", "flying" } }), 14, { 1 }, stream)
  Assert.equal(scored[1].score, 99, "the weaker strike loses a point")
  Assert.equal(scored[2].score, 100, "the strongest strike holds the baseline")
  Assert.deepEqual(
    stream:drawLabels(),
    { "score_init_0", "score_init_1", "score_init_2", "score_init_3", "faint_bonus" },
    "the single routine draw fires even without a doubly-effective candidate"
  )
end

-- Effectiveness emphasis favors clearly super-effective strikes and
-- withholds points from resisted ones.
function T.effectiveness_emphasis_moves_scores_both_ways()
  local TrainerAi = trainerPolicy()
  local scored = TrainerAi.scoreSlots(
    nativeChart(),
    {
      slotWith({ key = "RAZOR_LEAF", moveType = "grass", power = 55 }),
      slotWith({ key = "TACKLE", moveType = "normal", power = 35 }),
      slotWith({ key = "SPENT_A", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
      slotWith({ key = "SPENT_B", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
    },
    fighterWith({ types = { "grass" } }),
    fighterWith({ types = { "rock", "ground" } }),
    14,
    { 2 },
    spyStream(FIXED_SEED)
  )
  Assert.equal(scored[1].score, 102, "the super-effective strike gains points")
  Assert.equal(scored[2].score, 98, "the resisted strike loses points")
end

-- Same-type preference backs the reliable strike while off-type
-- attempts lose a point.
function T.same_type_preference_backs_the_reliable_strike()
  local TrainerAi = trainerPolicy()
  local scored = TrainerAi.scoreSlots(nativeChart(), {
    slotWith({ key = "RAZOR_LEAF", moveType = "grass", power = 55 }),
    slotWith({ key = "TACKLE", moveType = "normal", power = 35 }),
    slotWith({ key = "SPENT_A", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
    slotWith({ key = "SPENT_B", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
  }, fighterWith({ types = { "grass" } }), fighterWith({ types = { "normal" } }), 14, { 3 }, spyStream(FIXED_SEED))
  Assert.equal(scored[1].score, 102, "the same-type strike gains points")
  Assert.equal(scored[2].score, 99, "the off-type strike loses a point")
end

-- Health awareness seeks the knockout: only moves whose damage preview
-- reaches the remaining health gain points for the finish.
function T.health_awareness_seeks_only_the_finish()
  local TrainerAi = trainerPolicy()
  local slots = {
    slotWith({ key = "RAZOR_LEAF", moveType = "grass", power = 55 }),
    slotWith({ key = "TACKLE", moveType = "normal", power = 35 }),
    slotWith({ key = "SPENT_A", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
    slotWith({ key = "SPENT_B", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
  }
  local user = fighterWith({ types = { "grass" } })
  local foe = fighterWith({ types = { "rock", "ground" } })
  local finishing = TrainerAi.scoreSlots(nativeChart(), slots, user, foe, 30, { 5 }, spyStream(FIXED_SEED))
  Assert.equal(finishing[1].score, 103, "the finishing strike gains points")
  Assert.equal(finishing[2].score, 100, "the short strike holds the baseline")
  local healthy = TrainerAi.scoreSlots(nativeChart(), slots, user, foe, 200, { 5 }, spyStream(FIXED_SEED))
  Assert.equal(healthy[1].score, 100, "no bonus lands while the foe stands clear")
  Assert.equal(healthy[2].score, 100, "no bonus lands while the foe stands clear")
end

-- Accuracy preference avoids shaky strikes only while a reliable
-- damaging move exists.
function T.accuracy_preference_avoids_shaky_strikes()
  local TrainerAi = trainerPolicy()
  local slots = {
    slotWith({ key = "TACKLE", moveType = "normal", power = 35, accuracy = 95 }),
    slotWith({ key = "LOW_KICK", moveType = "fighting", power = 70, accuracy = 80 }),
    slotWith({ key = "SPENT_A", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
    slotWith({ key = "SPENT_B", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
  }
  local user = fighterWith({})
  local foe = fighterWith({})
  local scored = TrainerAi.scoreSlots(nativeChart(), slots, user, foe, 14, { 6 }, spyStream(FIXED_SEED))
  Assert.equal(scored[1].score, 100, "the reliable strike holds the baseline")
  Assert.equal(scored[2].score, 98, "the shaky strike loses points")
  local shakyOnly = TrainerAi.scoreSlots(
    nativeChart(),
    { slots[2], slots[2], slots[2], slots[2] },
    user,
    foe,
    14,
    { 6 },
    spyStream(FIXED_SEED)
  )
  for _, entry in ipairs(shakyOnly) do
    Assert.equal(entry.score, 100, "no penalty lands without a reliable alternative")
  end
end

-- Unpredictability applies its bonus deterministically to the
-- lowest-index usable slot with no flag draw, and replays identically.
function T.unpredictability_backs_the_lowest_usable_slot()
  local TrainerAi = trainerPolicy()
  local stream = spyStream(FIXED_SEED)
  local scored = TrainerAi.scoreSlots(
    nativeChart(),
    fourSlots(),
    fighterWith({ types = { "grass" } }),
    fighterWith({ types = { "rock", "ground" } }),
    14,
    { 9 },
    stream
  )
  Assert.deepEqual(
    stream:drawLabels(),
    { "score_init_0", "score_init_1", "score_init_2", "score_init_3" },
    "no flag draw follows initialization"
  )
  Assert.equal(scored[1].score, 101, "the lowest-index usable slot earns the bonus")
  Assert.equal(scored[2].score, 100, "the later usable slot holds the baseline")
  Assert.equal(scored[3].score, 100, "the status attempt holds the baseline")
  Assert.equal(scored[4].score, 0, "the spent slot never earns the bonus")
  local second = TrainerAi.scoreSlots(
    nativeChart(),
    fourSlots(),
    fighterWith({ types = { "grass" } }),
    fighterWith({ types = { "rock", "ground" } }),
    14,
    { 9 },
    spyStream(FIXED_SEED)
  )
  Assert.deepEqual(second, scored, "a fixed seed replays the same bonus")
end

-- Enabled flags dispatch in ascending bit order: the bit-1 routine draw
-- precedes the bit-2 draw regardless of pass order.
function T.enabled_flags_dispatch_in_ascending_bit_order()
  local TrainerAi = trainerPolicy()
  Assert.deepEqual(TrainerAi.parsePasses({ "ai_pass_2", "ai_pass_1" }), { 1, 2 }, "passes sort into bit order")
  local stream = spyStream(FIXED_SEED)
  local ordered = TrainerAi.parsePasses({ "ai_pass_2", "ai_pass_1" })
  TrainerAi.scoreSlots(nativeChart(), {
    slotWith({ key = "RAZOR_LEAF", moveType = "grass", power = 55 }),
    slotWith({ key = "TACKLE", moveType = "normal", power = 35 }),
    slotWith({ key = "GROWL", moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "SPLASH", moveType = "normal", power = 0, category = "status", accuracy = 100, usable = false }),
  }, fighterWith({ types = { "grass" } }), fighterWith({ types = { "rock", "ground" } }), 14, ordered, stream)
  Assert.deepEqual(
    stream:drawLabels(),
    { "score_init_0", "score_init_1", "score_init_2", "score_init_3", "faint_bonus", "flag_2" },
    "flag draws follow ascending bit order after initialization"
  )
end

-- Matchups resolve through the session chart: steel resists ghost and
-- dark, and poison cannot touch steel.
function T.session_chart_drives_matchups_including_resistances_and_immunities()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local resisted = TrainerAi.scoreSlots(chart, {
    slotWith({ key = "NIGHT_SHADE", moveType = "ghost", power = 50, category = "special", accuracy = 100 }),
    slotWith({ key = "BITE", moveType = "dark", power = 60, accuracy = 100 }),
    slotWith({ key = "SPENT_A", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
    slotWith({ key = "SPENT_B", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
  }, fighterWith({ types = { "ghost" } }), fighterWith({ types = { "steel" } }), 14, { 0 }, spyStream(FIXED_SEED))
  Assert.equal(resisted[1].score, 137, "the resisted ghost strike scores through the chart")
  Assert.equal(resisted[2].score, 130, "the resisted off-type strike scores through the chart")
  local immune = TrainerAi.scoreSlots(chart, {
    slotWith({ key = "POISON_STING", moveType = "poison", power = 40, accuracy = 100 }),
    slotWith({ key = "GROWL", moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "SPENT_A", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
    slotWith({ key = "SPENT_B", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
  }, fighterWith({ types = { "poison" } }), fighterWith({ types = { "steel" } }), 14, { 0 }, spyStream(FIXED_SEED))
  Assert.equal(immune[1].score, 90, "the negated strike falls below the baseline")
  Assert.equal(immune[2].score, 100, "the status attempt holds the baseline")
end

---@return table stats and types shared by the exposure-tied reserves
local function grassReserveStats()
  return { types = { "grass" }, level = 5, attack = 8, defense = 10, specialAttack = 8, specialDefense = 10 }
end

-- Reserve choice weighs moves and damage instead of exposure alone: with
-- identical incoming exposure on both reserves, only the move and
-- damage checks can prefer the damaging reserve over the harmless one
-- listed first.
function T.reserve_choice_weighs_moves_not_exposure_alone()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local harmless = {
    slotWith({ key = "GROWL", moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "SPLASH", moveType = "normal", power = 0, category = "status", accuracy = 100 }),
  }
  local damaging = {
    slotWith({ key = "RAZOR_LEAF", moveType = "grass", power = 55 }),
    slotWith({ key = "TACKLE", moveType = "normal", power = 35 }),
  }
  local candidates = {
    { id = 3, stats = grassReserveStats(), moves = harmless },
    { id = 4, stats = grassReserveStats(), moves = damaging },
  }
  local foe =
    { types = { "rock", "ground" }, level = 5, attack = 12, defense = 10, specialAttack = 12, specialDefense = 10 }
  local foeMoves = {
    slotWith({ key = "ROCK_THROW", moveType = "rock", power = 50, accuracy = 90 }),
  }
  local stream = spyStream(FIXED_SEED)
  local choice = TrainerAi.chooseReserve(chart, candidates, foe, foeMoves, stream)
  Assert.equal(choice, 4, "the damaging reserve answers when exposure ties")
  local repeated = TrainerAi.chooseReserve(chart, candidates, foe, foeMoves, spyStream(FIXED_SEED))
  Assert.equal(repeated, 4, "a fixed seed replays the same replacement")
  Assert.deepEqual(stream:drawLabels(), {}, "reserve selection draws nothing")
  Assert.isNil(
    TrainerAi.chooseReserve(chart, {}, foe, foeMoves, spyStream(FIXED_SEED)),
    "an empty bench answers no switch"
  )
end

-- Target selection draws only with more than one live opponent: a lone
-- foe is addressed with no draw while two opponents stay deterministic
-- for a fixed seed.
function T.target_selection_stays_deterministic_with_two_opponents()
  local TrainerAi = trainerPolicy()
  local loneStream = spyStream(FIXED_SEED)
  Assert.equal(TrainerAi.selectTarget({ 2 }, loneStream), 2, "a lone foe is addressed")
  Assert.deepEqual(loneStream:drawLabels(), {}, "a lone foe costs no draw")
  local stream = spyStream(FIXED_SEED)
  local first = TrainerAi.selectTarget({ 3, 5 }, stream)
  Assert.isTrue(first == 3 or first == 5, "the choice names a live opponent")
  Assert.deepEqual(stream:drawLabels(), { "target_foe" }, "two opponents draw exactly once")
  Assert.equal(TrainerAi.selectTarget({ 3, 5 }, spyStream(FIXED_SEED)), first, "a fixed seed replays the same target")
end

---@param id integer nonreused positive combatant identity
---@param seed integer fixed generator state for the underlying mon
---@param species string catalog species key
---@param level integer battle level for the underlying mon
---@return table combatant seed with one usable move entry
local function leveledCombatant(id, seed, species, level)
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
  mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return { id = id, mon = mon }
end

---@param keys string[]? move identities under fact resolution
---@return table<string, table<string, unknown>> immutable move facts for the keys
local function scenarioMoveFacts(keys)
  local catalog = CatalogFixture.makeCatalog()
  local facts = {}
  for _, key in ipairs(keys or { "TACKLE" }) do
    if key ~= "STRUGGLE" then
      facts[key] = catalog:move(key)
    end
  end
  facts.STRUGGLE = { power = 50, accuracy = 100, category = "physical", moveType = "normal", priority = 0 }
  return facts
end

---@param formRecord table<string, unknown> catalog form record carrying its semantic types
---@return string[] detached semantic types for the form
local function copyFormTypes(formRecord)
  local types = {} ---@type string[]
  for _, key in
    ipairs(formRecord.types --[[@as string[] ]])
  do
    types[#types + 1] = key --[[@as string]]
  end
  return types
end

---@param seeds table<integer, table<string, unknown>> combatant seeds under fact resolution
---@return table<string, table<integer, table<string, unknown>>> static species facts
local function scenarioSpeciesFacts(seeds)
  local catalog = CatalogFixture.makeCatalog()
  local facts = {}
  for _, seed in ipairs(seeds) do
    local mon = seed.mon --[[@as table<string, unknown>]]
    local species = mon.species --[[@as string]]
    local form = mon.form --[[@as integer]]
    local speciesRecord = catalog:species(species)
    local bucket = facts[species]
    if bucket == nil then
      bucket = {}
      facts[species] = bucket
    end
    bucket[form] = {
      baseStats = catalog:form(species, form).baseStats,
      growthCurve = catalog:growthCurve(speciesRecord.growthCurve --[[@as string]]),
      types = copyFormTypes(catalog:form(species, form)),
      levelUpMoves = catalog:form(species, form).levelUpMoves,
      baseExpYield = speciesRecord.baseExpYield,
      evYield = speciesRecord.evYield,
    }
  end
  return facts
end

---@return table<string, unknown> detached generated-style medicine facts
local function potionFacts()
  return {
    kind = "medicine",
    restore = { kind = "fixed", amount = 20 },
    cures = { sleep = false, poison = false, burn = false, freeze = false, paralysis = false },
    revive = "none",
    mood = 0,
  }
end

---@param pack table battle inventory seed for the trainer side
---@param trainerMons table[] trainer combatant seeds in scenario order
---@param foeMons table[] opposing combatant seeds in scenario order
---@param moveKeys string[] move identities under fact resolution
---@return table detached native battle setup carrying the trainer stock
local function trainerStockScenario(pack, trainerMons, foeMons, moveKeys)
  local Executor = sessionOwner()
  local trainer = SessionFixture.participant(2, 2, "trainer:1", trainerMons)
  trainer.inventoryId = (pack --[[@as table<string, unknown>]]).id
  trainer.context = { aiPasses = { "ai_pass_0", "ai_pass_1" } }
  local seeds = {}
  for _, seed in ipairs(trainerMons) do
    seeds[#seeds + 1] = seed
  end
  for _, seed in ipairs(foeMons) do
    seeds[#seeds + 1] = seed
  end
  return {
    ruleset = Executor.RULESET,
    format = "single",
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "player", foeMons),
      trainer,
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, foeMons[1].id --[[@as integer]]),
      SessionFixture.position(2, 2, { 2 }, trainerMons[1].id --[[@as integer]]),
    },
    inventories = { pack },
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts(moveKeys),
    speciesFacts = scenarioSpeciesFacts(seeds),
    itemFacts = { POTION = { partyUse = potionFacts() } },
  }
end

---@param contracts table session owners under test
---@param scenario table detached native battle setup under test driving
---@return table live native session waiting on its opening decisions
local function waitingSession(contracts, scenario)
  local session = contracts.Battle.newSession(scenario, trainerContent())
  local frame = SessionFixture.driveUntilSettled(session)
  Assert.equal(frame.status, "waiting", "the trainer duel opens its decision batch")
  return session
end

---@param session table live native session under inspection
---@param controller string controller owning the request
---@return table the open request for the controller
local function openRequest(session, controller)
  local frame = SessionFixture.driveUntilSettled(session)
  Assert.equal(frame.status, "waiting", "the batch stays open while requests wait")
  for _, request in ipairs(frame.request.requests) do
    if request.controller == controller then
      return request
    end
  end
  error("no open request for controller " .. controller)
end

-- Trainer item availability follows session stock in both directions: an
-- empty session inventory refuses the bag even though the trainer side
-- carries pass facts, and a stocked session inventory heals without any
-- controller-side copy. Executing the turn consumes the unit through the
-- shared item owner, and the next decision observes the empty stock.
function T.trainer_item_availability_follows_session_stock()
  local contracts = SessionFixture.sessionContracts()

  local woundedLead = leveledCombatant(1, 23, "EEVEE", 20);
  (woundedLead.mon --[[@as table<string, unknown>]]).condition.currentHp = 4
  local foe = leveledCombatant(2, 41, "EEVEE", 5)
  local emptySession = waitingSession(
    contracts,
    trainerStockScenario(SessionFixture.inventory("trainer-stock", { 2 }, {}), { woundedLead }, { foe })
  )
  local emptyStock = emptySession:capture().inventories["trainer-stock"].quantities
  Assert.isNil(emptyStock.POTION, "the session holds no cure for this trainer")
  local refused = emptySession:answerTrainer(openRequest(emptySession, "trainer:1"))
  Assert.equal(refused.choices[1].kind, "attack", "an empty session stock refuses the bag")
  emptySession:dispose()

  local hurtLead = leveledCombatant(1, 23, "EEVEE", 20);
  (hurtLead.mon --[[@as table<string, unknown>]]).condition.currentHp = 4
  local stockedFoe = leveledCombatant(2, 41, "EEVEE", 5)
  local stockedSession = waitingSession(
    contracts,
    trainerStockScenario(SessionFixture.inventory("trainer-stock", { 2 }, { POTION = 1 }), { hurtLead }, { stockedFoe })
  )
  local heldStock = stockedSession:capture().inventories["trainer-stock"].quantities
  Assert.equal(heldStock.POTION, 1, "the session holds exactly one cure for this trainer")
  local trainerRequest = openRequest(stockedSession, "trainer:1")
  local served = stockedSession:answerTrainer(trainerRequest)
  Assert.equal(served.choices[1].kind, "item", "a stocked session heals without a controller-side copy")
  Assert.equal(served.choices[1].payload.item, "POTION", "the session cure is the one actually stocked")
  local playerRequest = openRequest(stockedSession, "player")
  local playerActor = assert(playerRequest.actors[1], "the player request addresses its lead")
  local accepted, acceptErr = stockedSession:submit(served)
  Assert.isTrue(accepted, "the trainer serving submits: " .. tostring(acceptErr))
  local playerAccepted, playerErr = stockedSession:submit(
    SessionFixture.replyFor(
      playerRequest,
      { SessionFixture.attackChoice(playerActor, 0, SessionFixture.positionTarget(2)) }
    )
  )
  Assert.isTrue(playerAccepted, "the player strike submits: " .. tostring(playerErr))
  local settled = SessionFixture.driveUntilSettled(stockedSession)
  Assert.isTrue(
    settled.status == "waiting" or settled.status == "ended",
    "the answered turn executes through the kernel"
  )
  local spentStock = stockedSession:capture().inventories["trainer-stock"].quantities
  Assert.equal(spentStock.POTION, 0, "serving consumes the session unit")
  Assert.equal(settled.status, "waiting", "the answered turn leaves the duel open")
  local second = stockedSession:answerTrainer(openRequest(stockedSession, "trainer:1"))
  Assert.equal(second.choices[1].kind, "attack", "the spent stock cannot be reused")
  stockedSession:dispose()
end

-- Answering never mutates battle state: combatants, inventories,
-- positions, and participants read identically before and after the
-- decision while the battle stream advances by exactly the decision
-- draws.
function T.answering_never_mutates_battle_state()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(1, 23, "EEVEE", 20)
  local foe = leveledCombatant(2, 41, "EEVEE", 5)
  local session = waitingSession(
    contracts,
    trainerStockScenario(SessionFixture.inventory("trainer-stock", { 2 }, { POTION = 1 }), { lead }, { foe })
  )
  local before = session:capture()
  local callsBefore = before.rng.calls
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.notNil(reply, "the trainer request answers")
  local after = session:capture()
  Assert.deepEqual(after.combatants, before.combatants, "answering moves no health or records")
  Assert.deepEqual(after.inventories, before.inventories, "answering consumes no stock")
  Assert.deepEqual(after.positions, before.positions, "answering moves no positions")
  Assert.deepEqual(after.participants, before.participants, "answering rewrites no participants")
  Assert.equal(after.rng.calls, callsBefore + 7, "the decision draws exactly its source sequence")
  local accepted, acceptErr = session:submit(reply)
  Assert.isTrue(accepted, "the answering reply submits: " .. tostring(acceptErr))
  session:dispose()
end

-- A fixed seed replays identically after snapshot restore: the same
-- capture answered twice yields the same reply with the same stream
-- progression.
function T.fixed_seed_replays_identically_after_snapshot_restore()
  local Executor = sessionOwner()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(1, 23, "EEVEE", 20)
  local foe = leveledCombatant(2, 41, "EEVEE", 5)
  local session = waitingSession(
    contracts,
    trainerStockScenario(SessionFixture.inventory("trainer-stock", { 2 }, {}), { lead }, { foe })
  )
  local held = session:capture()
  local first = session:answerTrainer(openRequest(session, "trainer:1"))
  local firstCalls = session:capture().rng.calls
  session:dispose()
  local content = trainerContent()
  local restored = Executor.restore(held, content)
  local second = restored:answerTrainer(openRequest(restored, "trainer:1"))
  Assert.deepEqual(second, first, "the restored snapshot answers identically")
  Assert.equal(
    restored:capture().rng.calls - held.rng.calls,
    firstCalls - held.rng.calls,
    "the restored snapshot advances the stream identically"
  )
  restored:dispose()
end

-- Trainer and wild answers share the single battle stream: both advance
-- the same session counter with no second generator anywhere.
function T.trainer_and_wild_answers_share_the_single_battle_stream()
  local Executor = sessionOwner()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(1, 23, "EEVEE", 20)
  local trainerFoe = leveledCombatant(2, 41, "EEVEE", 5)
  local wildFoe = leveledCombatant(3, 55, "TOTODILE", 5)
  local seeds = { lead, trainerFoe, wildFoe }
  local trainer = SessionFixture.participant(2, 2, "trainer:1", { lead })
  trainer.context = { aiPasses = {} }
  local scenario = {
    ruleset = Executor.RULESET,
    format = "single",
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2, 3 }) },
    participants = {
      SessionFixture.participant(1, 1, "player", { trainerFoe }),
      trainer,
      SessionFixture.participant(3, 2, "wild", { wildFoe }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, trainerFoe.id),
      SessionFixture.position(2, 2, { 2 }, lead.id),
      SessionFixture.position(3, 2, { 3 }, wildFoe.id),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts(),
    speciesFacts = scenarioSpeciesFacts(seeds),
    itemFacts = {},
  }
  local session = waitingSession(contracts, scenario)
  local callsBefore = session:capture().rng.calls
  local trainerReply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.notNil(trainerReply, "the trainer request answers")
  Assert.equal(session:capture().rng.calls, callsBefore + 5, "the trainer answer advances the session stream")
  local wild = openRequest(session, "wild")
  session:withDecisionStream(wild, function(stream)
    stream:nextU16("wild_strike", { controller = wild.controller, request = wild.requestId })
    return { requestId = wild.requestId }
  end)
  Assert.equal(session:capture().rng.calls, callsBefore + 6, "the wild answer advances the same session stream")
  session:dispose()
end

-- The trainer seam rejects foreign requests before drawing: player and
-- wild requests, unknown identities, stale epochs, and nested leases
-- all fail with the stream untouched.
function T.trainer_seam_rejects_foreign_requests_without_drawing()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(1, 23, "EEVEE", 20)
  local trainerFoe = leveledCombatant(2, 41, "EEVEE", 5)
  local wildFoe = leveledCombatant(3, 55, "TOTODILE", 5)
  local seeds = { lead, trainerFoe, wildFoe }
  local Executor = sessionOwner()
  local trainer = SessionFixture.participant(2, 2, "trainer:1", { lead })
  trainer.context = { aiPasses = {} }
  local scenario = {
    ruleset = Executor.RULESET,
    format = "single",
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2, 3 }) },
    participants = {
      SessionFixture.participant(1, 1, "player", { trainerFoe }),
      trainer,
      SessionFixture.participant(3, 2, "wild", { wildFoe }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, trainerFoe.id),
      SessionFixture.position(2, 2, { 2 }, lead.id),
      SessionFixture.position(3, 2, { 3 }, wildFoe.id),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts(),
    speciesFacts = scenarioSpeciesFacts(seeds),
    itemFacts = {},
  }
  local session = waitingSession(contracts, scenario)
  local trainerRequest = openRequest(session, "trainer:1")
  local callsBefore = session:capture().rng.calls
  local function callsHeld()
    Assert.equal(session:capture().rng.calls, callsBefore, "rejected answers draw nothing")
  end
  Assert.throws(function()
    session:answerTrainer(openRequest(session, "player"))
  end, "player requests never borrow the trainer seam")
  callsHeld()
  Assert.throws(function()
    session:answerTrainer(openRequest(session, "wild"))
  end, "wild requests never borrow the trainer seam")
  callsHeld()
  Assert.throws(function()
    session:answerTrainer({
      requestId = 9999,
      epoch = trainerRequest.epoch,
      controller = "trainer:1",
      actors = trainerRequest.actors,
    })
  end, "unknown requests never borrow the trainer seam")
  callsHeld()
  Assert.throws(function()
    session:answerTrainer({
      requestId = trainerRequest.requestId,
      epoch = trainerRequest.epoch + 1,
      controller = "trainer:1",
      actors = trainerRequest.actors,
    })
  end, "stale epochs never borrow the trainer seam")
  callsHeld()
  Assert.throws(function()
    session:withDecisionStream(trainerRequest, function(_)
      return session:answerTrainer(trainerRequest)
    end)
  end, "trainer answers never nest inside a lease")
  callsHeld()
  session:dispose()
end

-- Doubles targeting draws from topology: two live opponents resolve to
-- a declared foe position and replay identically for a fixed seed.
function T.doubles_targeting_draws_from_topology()
  local Executor = sessionOwner()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(3, 23, "EEVEE", 20)
  local mate = leveledCombatant(4, 24, "EEVEE", 20)
  local foeA = leveledCombatant(1, 41, "TOTODILE", 5)
  local foeB = leveledCombatant(2, 42, "TOTODILE", 5)
  local seeds = { lead, mate, foeA, foeB }
  local trainer = SessionFixture.participant(2, 2, "trainer:1", { lead, mate })
  trainer.context = { aiPasses = {} }
  local scenario = {
    ruleset = Executor.RULESET,
    format = "double",
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "player", { foeA, foeB }),
      trainer,
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, foeA.id),
      SessionFixture.position(2, 1, { 1 }, foeB.id),
      SessionFixture.position(3, 2, { 2 }, lead.id),
      SessionFixture.position(4, 2, { 2 }, mate.id),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts(),
    speciesFacts = scenarioSpeciesFacts(seeds),
    itemFacts = {},
  }
  local session = waitingSession(contracts, scenario)
  local held = session:capture()
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(#reply.choices, 2, "both trainer actors answer")
  for _, choice in ipairs(reply.choices) do
    Assert.equal(choice.kind, "attack", "the flagless doubles line strikes")
    local position = choice.payload.target.position
    Assert.isTrue(position == 1 or position == 2, "strikes address a live opposing position")
  end
  session:dispose()
  local replayed = Executor.restore(held, trainerContent())
  local second = replayed:answerTrainer(openRequest(replayed, "trainer:1"))
  Assert.deepEqual(second, reply, "a fixed seed replays the same reply")
  replayed:dispose()
end

-- Separate trainer controllers answer their own doubles slot from
-- topology: each trainer holds one enemy position and decides its lone
-- actor without any doubles mark in its pass facts.
function T.separate_trainer_controllers_answer_their_own_doubles_slot()
  local Executor = sessionOwner()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(3, 23, "EEVEE", 20)
  local mate = leveledCombatant(4, 24, "EEVEE", 20)
  local foeA = leveledCombatant(1, 41, "TOTODILE", 5)
  local foeB = leveledCombatant(2, 42, "TOTODILE", 5)
  local seeds = { lead, mate, foeA, foeB }
  local first = SessionFixture.participant(2, 2, "trainer:1", { lead })
  first.context = { aiPasses = {} }
  local second = SessionFixture.participant(3, 2, "trainer:2", { mate })
  second.context = { aiPasses = {} }
  local scenario = {
    ruleset = Executor.RULESET,
    format = "double",
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2, 3 }) },
    participants = {
      SessionFixture.participant(1, 1, "player", { foeA, foeB }),
      first,
      second,
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, foeA.id),
      SessionFixture.position(2, 1, { 1 }, foeB.id),
      SessionFixture.position(3, 2, { 2 }, lead.id),
      SessionFixture.position(4, 2, { 3 }, mate.id),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts(),
    speciesFacts = scenarioSpeciesFacts(seeds),
    itemFacts = {},
  }
  Assert.deepEqual(first.context, { aiPasses = {} }, "the first trainer carries no doubles mark")
  Assert.deepEqual(second.context, { aiPasses = {} }, "the second trainer carries no doubles mark")
  local session = waitingSession(contracts, scenario)
  local held = session:capture()
  local firstReply = session:answerTrainer(openRequest(session, "trainer:1"))
  local secondReply = session:answerTrainer(openRequest(session, "trainer:2"))
  Assert.equal(#firstReply.choices, 1, "the first trainer answers only its own actor")
  Assert.equal(#secondReply.choices, 1, "the second trainer answers only its own actor")
  for _, reply in ipairs({ firstReply, secondReply }) do
    Assert.equal(reply.choices[1].kind, "attack", "the flagless doubles line strikes")
    local position = reply.choices[1].payload.target.position
    Assert.isTrue(position == 1 or position == 2, "strikes address a live opposing position")
  end
  session:dispose()
  local replayed = Executor.restore(held, trainerContent())
  Assert.deepEqual(
    replayed:answerTrainer(openRequest(replayed, "trainer:1")),
    firstReply,
    "a fixed seed replays the first trainer"
  )
  Assert.deepEqual(
    replayed:answerTrainer(openRequest(replayed, "trainer:2")),
    secondReply,
    "a fixed seed replays the second trainer"
  )
  replayed:dispose()
end

-- Switch answers ride the seam when a reserve strictly outranks the
-- holder: the harmless lead yields to its damaging reserve through an
-- ordinary reply the kernel accepts.
function T.switch_answers_ride_the_seam_when_a_reserve_outranks_the_holder()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(1, 23, "CHIKORITA", 5)
  lead.mon.moves = {
    { move = "GROWL", pp = 40, ppUps = 0 },
    { move = "TAIL_WHIP", pp = 30, ppUps = 0 },
  }
  local reserve = leveledCombatant(3, 24, "TOTODILE", 5)
  reserve.mon.moves = {
    { move = "WATER_GUN", pp = 25, ppUps = 0 },
    { move = "TACKLE", pp = 35, ppUps = 0 },
  }
  local foe = leveledCombatant(2, 41, "EEVEE", 5)
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, {}),
      { lead, reserve },
      { foe },
      { "TACKLE", "GROWL", "TAIL_WHIP", "WATER_GUN" }
    )
  )
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "switch", "the exposed lead yields to its reserve")
  Assert.equal(reply.choices[1].payload.replacement, 3, "the damaging reserve answers the foe")
  local accepted, acceptErr = session:submit(reply)
  Assert.isTrue(accepted, "the switch submits: " .. tostring(acceptErr))
  session:dispose()
end

---@param record table<string, unknown> full mon-domain record under test preparation
---@return table the same record striking with a single known move
local function tackleOnly(record)
  record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return record
end

---@param species string catalog species key for the foe record
---@param level integer foe battle level
---@param seed integer fixed generator state for the foe record
---@return table full mon-domain record
local function foeRecord(species, level, seed)
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  return tackleOnly(factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level })))
end

---@return table party owner holding one fixed lead
local function newPartyOwner()
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local Lcrng = require("libs.mons.src.gen4.Lcrng")
  local MonsSave = require("libs.mons.src.MonsSave")
  local Party = require("libs.mons.src.Party")
  local catalog = CatalogFixture.makeCatalog()
  local owner = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x22222222):capture(), catalog:fingerprint()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
  Assert.isTrue(owner:addMon(foeRecord("CHIKORITA", 5, 0x33333333)), "the production path needs its live party lead")
  return owner
end

---@param money integer pocket money the player record carries
---@return table player record and its validation context
local function playerFacts(money)
  local record = {
    profile = { name = "RED", gender = 0, trainerId = 1, money = money, badges = 0 },
    options = { textFrame = 0, textSpeed = "fastest" },
  }
  local context = { charmap = CatalogFixture.CHARMAP, frameIndexes = { [0] = true } }
  return { record = record, context = context }
end

---@param battle table<string, unknown> live application battle under test driving
---@param budget integer maximum update ticks before the driver gives up
local function driveBattleToSettlement(battle, budget)
  for _ = 1, budget do
    battle:update()
    local current = battle:status()
    if current.phase == "complete" or current.phase == "failed" then
      return
    end
    if current.phase == "running" and current.request ~= nil then
      local choices = {}
      for _, actor in ipairs(assert(current.request.actors, "a decision request names its actors")) do
        choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
      end
      local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, choices))
      Assert.isTrue(accepted, "a legal production decision is accepted: " .. tostring(replyErr))
    end
  end
  error("the trainer battle never settled")
end

-- Production trainer answers route through the native session seam: the
-- battle settles through the ordinary application lifetime while every
-- trainer-owned request is answered by the session method, never by an
-- application-side projection or a library controller.
function T.trainer_answers_route_through_the_native_session_seam()
  local Executor = sessionOwner()
  local BattleRuntime =
    requirePresent("game.hgss.src.battle.BattleRuntime", "the application battle lifetime routes owned requests")
  local ScenarioFactory =
    requirePresent("libs.hgss.src.battle.HgssBattleScenarioFactory", "field sources mapped to one detached scenario")
  local calls = 0
  local original = Executor.answerTrainer
  Executor.answerTrainer = function(self, request)
    calls = calls + 1
    if type(original) == "function" then
      return original(self, request)
    end
    error("the native trainer seam is absent", 0)
  end
  local party = newPartyOwner()
  local facts = playerFacts(3000)
  local foe = foeRecord("TOTODILE", 4, 0x5EED0001)
  local scenario = ScenarioFactory.fromTrainer({
    id = "trainer-seam",
    trainers = {
      {
        id = "rival-seam",
        class = 2,
        party = { foe },
        partyLevels = { 4 },
        prizeMoney = { trainerClass = 2, classRate = 4 },
        aiPasses = {},
      },
    },
  }, { party = party, player = { trainerId = 99, trainerName = "MINT", language = "french" } })
  local battle = BattleRuntime.new({
    request = { id = "launch-trainer-seam", kind = "trainer", payload = { trainer = "rival-seam" } },
    scenario = scenario,
    party = party,
    player = facts,
  })
  local ok, err = pcall(driveBattleToSettlement, battle, 1200)
  local phase = battle:status().phase
  battle:dispose()
  Executor.answerTrainer = original
  Assert.isTrue(ok, "the trainer battle settles through the application lifetime")
  Assert.equal(phase, "complete", "answered trainer decisions finish the battle")
  Assert.isTrue(calls > 0, "trainer answers route through the native session seam")
end

return { tests = T }
