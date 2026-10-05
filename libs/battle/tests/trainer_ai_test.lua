-- Session-owned trainer decisions: move scores open at the shared
-- opening points with slot-ordered initialization draws on the battle
-- stream, per-flag programs adjust scores through the command
-- interpreter, equal-top ties break uniformly through one selection
-- draw, the switch gate answers before the item path, trainer items
-- follow source slot order and conditions rather than a health gate with
-- a random pick, selected slots stay consumed until the serving
-- executes, learned and slot state rides the native snapshot with
-- entry reset, and production trainer answers route through the native
-- session seam.

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
  local values = {}
  local stream = {}
  function stream:nextU16(label, cause)
    labels[#labels + 1] = label
    local value = inner:nextU16(label, cause)
    values[#values + 1] = value
    return value
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
  function stream:drawValues()
    local out = {}
    for index, value in ipairs(values) do
      out[index] = value
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
    id = 33,
    moveType = "normal",
    power = 35,
    category = "physical",
    accuracy = 95,
    effect = 0,
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
    slotWith({ key = "RAZOR_LEAF", id = 75, moveType = "grass", power = 55, accuracy = 95 }),
    slotWith({ key = "GROWL", id = 45, moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "EMBER", id = 52, moveType = "fire", power = 40, category = "special", accuracy = 100, usable = false }),
  }
end

-- Move scoring opens at the shared baseline: every usable slot starts at
-- one hundred points, the spent slot stays at zero, and exactly four
-- initialization draws precede flag evaluation in slot order. A fixed
-- seed replays the same scores.
function T.move_scores_open_at_the_shared_baseline_before_flag_evaluation()
  local TrainerAi = trainerPolicy()
  local stream = spyStream(FIXED_SEED)
  local scored = TrainerAi.scoreSlots(
    nativeChart(),
    fourSlots(),
    fighterWith({ types = { "grass" } }),
    fighterWith({ types = { "rock", "ground" } }),
    14,
    {},
    false,
    stream
  )
  Assert.equal(#scored, 4, "scoring covers every move slot")
  Assert.equal(scored[1].score, 100, "the first usable slot opens at the baseline")
  Assert.equal(scored[2].score, 100, "the second usable slot opens at the baseline")
  Assert.equal(scored[3].score, 100, "the third usable slot opens at the baseline")
  Assert.equal(scored[4].score, 0, "the spent slot stays excluded at zero")
  Assert.equal(#stream:drawLabels(), 4, "initialization draws once per move slot and nothing else")
  local probe = BattleRng.new(FIXED_SEED)
  local expectedValues = {}
  for _ = 1, 4 do
    expectedValues[#expectedValues + 1] = probe:nextU16("init_probe", { slot = #expectedValues })
  end
  Assert.deepEqual(
    stream:drawValues(),
    expectedValues,
    "initialization consumes the shared stream head in slot order"
  )
  local second = TrainerAi.scoreSlots(
    nativeChart(),
    fourSlots(),
    fighterWith({ types = { "grass" } }),
    fighterWith({ types = { "rock", "ground" } }),
    14,
    {},
    false,
    spyStream(FIXED_SEED)
  )
  Assert.deepEqual(second, scored, "a fixed seed replays the same scores")
end

-- Pass names outside the supported set fail closed: unknown bits and
-- malformed names all raise naming the offending pass, while repeats
-- collapse and dispatch runs in ascending bit order.
function T.pass_names_outside_the_supported_set_fail_before_any_draw()
  local TrainerAi = trainerPolicy()
  Assert.deepEqual(TrainerAi.parsePasses({}), {}, "flagless trainers carry no bits")
  Assert.deepEqual(
    TrainerAi.parsePasses({ "ai_pass_9", "ai_pass_2", "ai_pass_0", "ai_pass_2" }),
    { 0, 2, 9 },
    "passes dispatch in ascending bit order without repeats"
  )
  Assert.deepEqual(
    TrainerAi.parsePasses({ "ai_pass_7", "ai_pass_0" }),
    { 0, 7 },
    "the doubles pass parses alongside the stored passes"
  )
  for _, pass in ipairs({ "ai_pass_4", "ai_pass_8", "ai_pass_10", "bogus", "", "ai_pass_" }) do
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

-- Equal-top ties break uniformly through exactly one selection draw: the
-- pick follows the draw remainder over the tied slots in source order,
-- and a fixed seed replays the pick. The lone-leader path spends that
-- same draw exactly as the singles selector does on every normal return,
-- so the downstream stream never shifts with the margin.
function T.tied_top_scores_break_uniformly_through_one_selection_draw()
  local TrainerAi = trainerPolicy()
  local tied = {
    { slot = 0, key = "TACKLE", score = 100 },
    { slot = 1, key = "RAZOR_LEAF", score = 100 },
    { slot = 2, key = "GROWL", score = 100 },
    { slot = 3, key = "SPENT", score = 0 },
  }
  local stream = spyStream(FIXED_SEED)
  local callsBefore = stream:capture().calls
  local pick = TrainerAi.selectMove(tied, stream)
  Assert.equal(stream:capture().calls, callsBefore + 1, "tied selection draws exactly once")
  local probe = BattleRng.new(FIXED_SEED)
  local expected = probe:nextU16("tie_probe", { tied = 3 })
  Assert.equal(pick, tied[(expected % 3) + 1].slot, "the pick follows the draw remainder over the tied slots")
  Assert.equal(TrainerAi.selectMove(tied, spyStream(FIXED_SEED)), pick, "a fixed seed replays the same pick")
  local lone = {
    { slot = 0, key = "TACKLE", score = 110 },
    { slot = 1, key = "RAZOR_LEAF", score = 100 },
    { slot = 2, key = "GROWL", score = 100 },
    { slot = 3, key = "SPENT", score = 0 },
  }
  Assert.equal(TrainerAi.selectMove(lone, spyStream(FIXED_SEED)), 0, "the lone leader answers")
  local loneStream = spyStream(FIXED_SEED)
  local loneBefore = loneStream:capture().calls
  Assert.equal(TrainerAi.selectMove(lone, loneStream), 0, "the lone leader answers its slot")
  Assert.equal(
    loneStream:capture().calls,
    loneBefore + 1,
    "a lone leader still spends its selection draw"
  )
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

---@return table<string, unknown> detached generated-style sleep-cure facts
local function sleepCureFacts()
  return {
    kind = "medicine",
    cures = { sleep = true, poison = false, burn = false, freeze = false, paralysis = false },
    revive = "none",
    mood = 0,
  }
end

---@param pack table battle inventory seed for the trainer side
---@param trainerMons table[] trainer combatant seeds in scenario order
---@param foeMons table[] opposing combatant seeds in scenario order
---@param moveKeys string[] move identities under fact resolution
---@param opts table<string, unknown>? pass and fact overrides for the trainer side
---@return table detached native battle setup carrying the trainer stock
local function trainerStockScenario(pack, trainerMons, foeMons, moveKeys, opts)
  local Executor = sessionOwner()
  local options = opts or {}
  local scenarioSeed = options.seed or NATIVE_SEED
  local trainer = SessionFixture.participant(2, 2, "trainer:1", trainerMons)
  trainer.inventoryId = (pack --[[@as table<string, unknown>]]).id
  trainer.context = { aiPasses = options.passes or { "ai_pass_0", "ai_pass_1" } }
  if options.trainerItems ~= nil then
    local ordered = {}
    for _, key in ipairs(options.trainerItems --[[@as string[] ]]) do
      ordered[#ordered + 1] = key
    end
    trainer.context.trainerItems = ordered
  end
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
    random = { seed = scenarioSeed },
    formatState = {},
    moveFacts = scenarioMoveFacts(moveKeys),
    speciesFacts = scenarioSpeciesFacts(seeds),
    itemFacts = options.itemFacts or { POTION = { partyUse = potionFacts() } },
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

-- The switch gate answers before the item path: a wounded lead with an
-- answering reserve and a stocked cure yields its reserve through an
-- ordinary reply the kernel accepts, even though the bag could serve.
-- Without the reserve the same wounded lead takes the stocked cure,
-- proving the bag was available and the exchange won on order.
function T.a_wounded_lead_without_a_native_trigger_takes_the_stocked_cure()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(1, 23, "CHIKORITA", 5)
  lead.mon.moves = {
    { move = "GROWL", pp = 40, ppUps = 0 },
    { move = "TAIL_WHIP", pp = 30, ppUps = 0 },
  };
  (lead.mon --[[@as table<string, unknown>]]).condition.currentHp = 4
  local reserve = leveledCombatant(3, 24, "TOTODILE", 5)
  reserve.mon.moves = {
    { move = "WATER_GUN", pp = 25, ppUps = 0 },
    { move = "TACKLE", pp = 35, ppUps = 0 },
  }
  local foe = leveledCombatant(2, 41, "EEVEE", 5)
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, { POTION = 1 }),
      { lead, reserve },
      { foe },
      { "TACKLE", "GROWL", "TAIL_WHIP", "WATER_GUN" },
      { trainerItems = { "POTION", "NONE", "NONE", "NONE" } }
    )
  )
  local held = session:capture().inventories["trainer-stock"].quantities
  Assert.equal(held.POTION, 1, "the session holds a serving the gate must pass over")
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "item", "without a native trigger the wounded lead stays")
  Assert.equal(reply.choices[1].payload.item, "POTION", "the stay serves the stocked cure")
  local accepted, acceptErr = session:submit(reply)
  Assert.isTrue(accepted, "the cure submits: " .. tostring(acceptErr))
  session:dispose()
end

-- Without a reserve the same wounded lead takes the stocked cure: the bag
-- was available, so the exchange in the neighboring state wins on order
-- rather than on missing stock.
function T.without_a_reserve_the_same_wound_takes_the_stocked_cure()
  local contracts = SessionFixture.sessionContracts()
  local loneLead = leveledCombatant(1, 23, "CHIKORITA", 5)
  loneLead.mon.moves = {
    { move = "GROWL", pp = 40, ppUps = 0 },
    { move = "TAIL_WHIP", pp = 30, ppUps = 0 },
  };
  (loneLead.mon --[[@as table<string, unknown>]]).condition.currentHp = 4
  local loneFoe = leveledCombatant(2, 41, "EEVEE", 5)
  local loneSession = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, { POTION = 1 }),
      { loneLead },
      { loneFoe },
      { "TACKLE", "GROWL", "TAIL_WHIP" },
      { trainerItems = { "POTION", "NONE", "NONE", "NONE" } }
    )
  )
  local loneReply = loneSession:answerTrainer(openRequest(loneSession, "trainer:1"))
  Assert.equal(loneReply.choices[1].kind, "item", "without a reserve the same wound takes the stocked cure")
  Assert.equal(loneReply.choices[1].payload.item, "POTION", "the cure is the one actually stocked")
  loneSession:dispose()
end

-- A sleeping holder at full health still considers the bag: with a sleep
-- cure and a full-health heal in stock the trainer serves the cure that
-- matches the ailment instead of striking or wasting the heal.
function T.full_health_status_ailments_consider_the_bag_before_striking()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(1, 23, "EEVEE", 20);
  (lead.mon --[[@as table<string, unknown>]]).condition.effects = { { key = "sleep" } }
  local foe = leveledCombatant(2, 41, "EEVEE", 5)
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, { REMEDY = 1, POTION = 1 }),
      { lead },
      { foe },
      nil,
      {
        passes = {},
        itemFacts = { REMEDY = { partyUse = sleepCureFacts() }, POTION = { partyUse = potionFacts() } },
        trainerItems = { "REMEDY", "POTION", "NONE", "NONE" },
      }
    )
  )
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "item", "the stocked cure answers the ailment at full health")
  Assert.equal(reply.choices[1].payload.item, "REMEDY", "the served cure is the one actually stocked")
  local accepted, acceptErr = session:submit(reply)
  Assert.isTrue(accepted, "the cure submits: " .. tostring(acceptErr))
  session:dispose()
end

-- Selected item slots stay consumed until the serving executes: answering
-- twice without submitting never serves the same slot twice, while the
-- session stock is untouched until the ordinary item path consumes it.
function T.selected_item_slots_stay_consumed_until_the_serving_executes()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(1, 23, "EEVEE", 20);
  (lead.mon --[[@as table<string, unknown>]]).condition.currentHp = 4
  local foe = leveledCombatant(2, 41, "EEVEE", 5)
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, { POTION = 1 }),
      { lead },
      { foe },
      nil,
      { trainerItems = { "POTION", "NONE", "NONE", "NONE" } }
    )
  )
  local first = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(first.choices[1].kind, "item", "the stocked cure answers first")
  Assert.equal(first.choices[1].payload.item, "POTION", "the first serving names the stocked cure")
  local second = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(second.choices[1].kind, "attack", "the consumed slot cannot be served again before it executes")
  local held = session:capture().inventories["trainer-stock"].quantities
  Assert.equal(held.POTION, 1, "answering alone consumes no stock")
  local accepted, acceptErr = session:submit(first)
  Assert.isTrue(accepted, "the first serving submits: " .. tostring(acceptErr))
  session:dispose()
end

-- Trainer memory rides the native snapshot: answering clears the served
-- source slot in persistent memory without moving stock or drawing,
-- executing decrements the served stock exactly once, and a capture taken
-- after the serving replays the next-turn answer with the same stream
-- progress; a capture without the record fails as incompatible instead of
-- guessing fresh state.
function T.ai_memory_rides_the_native_snapshot_and_restores_exactly()
  local Executor = sessionOwner()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(1, 23, "EEVEE", 20);
  (lead.mon --[[@as table<string, unknown>]]).condition.currentHp = 4
  local foe = leveledCombatant(2, 41, "EEVEE", 5)
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, { POTION = 1 }),
      { lead },
      { foe },
      nil,
      { trainerItems = { "POTION", "NONE", "NONE", "NONE" } }
    )
  )
  local function slotsOf(captured)
    local memory = captured.trainerAi --[[@as table<string, unknown>]]
    local controllers = memory.controllers --[[@as table<string, unknown>]]
    local owned = controllers["trainer:1"] --[[@as table<string, unknown>]]
    return owned.slots
  end
  local callsBefore = session:capture().rng.calls
  local first = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(first.choices[1].kind, "item", "the stocked cure answers first")
  Assert.equal(first.choices[1].payload.item, "POTION", "the serving names the stocked cure")
  Assert.equal(session:capture().rng.calls, callsBefore, "selection moves no stream draws")
  Assert.deepEqual(
    slotsOf(session:capture()),
    { "NONE", "NONE", "NONE", "NONE" },
    "selection clears the served source slot in place"
  )
  SessionFixture.assertPlainData(session:capture().trainerAi, "captured trainer memory")
  Assert.equal(
    session:capture().inventories["trainer-stock"].quantities.POTION,
    1,
    "answering alone consumes no stock"
  )
  local foeRequest = openRequest(session, "player")
  local foeActor = assert(foeRequest.actors[1], "the opposing request addresses its lead")
  Assert.isTrue(session:submit(first), "the serving binds")
  local bound, bindErr = session:submit(SessionFixture.replyFor(foeRequest, {
    SessionFixture.attackChoice(foeActor, 0, SessionFixture.positionTarget(2)),
  }))
  Assert.isTrue(bound, "the opposing strike binds: " .. tostring(bindErr))
  session:advance(1024)
  Assert.equal(
    session:capture().inventories["trainer-stock"].quantities.POTION,
    0,
    "execution decrements the served stock exactly once"
  )
  local held = session:capture()
  Assert.equal(type(held.trainerAi), "table", "the capture carries the detached trainer record")
  Assert.equal(
    (held.trainerAi --[[@as table<string, unknown>]]).version,
    1,
    "the record carries its schema mark"
  )
  local nextUninterrupted = session:answerTrainer(openRequest(session, "trainer:1"))
  local uninterruptedCalls = session:capture().rng.calls
  session:dispose()
  local restored = Executor.restore(held, trainerContent())
  local nextRestored = restored:answerTrainer(openRequest(restored, "trainer:1"))
  Assert.deepEqual(nextRestored, nextUninterrupted, "the restored snapshot answers the next turn identically")
  Assert.equal(
    restored:capture().rng.calls - held.rng.calls,
    uninterruptedCalls - held.rng.calls,
    "the restored snapshot advances the stream identically"
  )
  restored:dispose()
end

-- A native snapshot without the trainer record never restores: missing or
-- malformed memory fails incompatible instead of seeding fresh guesses.
function T.malformed_ai_memory_fails_restore_as_incompatible()
  local Executor = sessionOwner()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(1, 23, "EEVEE", 20)
  local foe = leveledCombatant(2, 41, "EEVEE", 5)
  local session = waitingSession(
    contracts,
    trainerStockScenario(SessionFixture.inventory("trainer-stock", { 2 }, {}), { lead }, { foe })
  )
  local held = session:capture()
  session:dispose()
  held.trainerAi = nil
  local failure = Assert.throws(function()
    Executor.restore(held, trainerContent())
  end, "a snapshot without the trainer record fails instead of guessing")
  Assert.isTrue(
    string.find(string.lower(tostring(failure)), "incompatible", 1, true) ~= nil
      or string.find(tostring(failure), "trainerAi", 1, true) ~= nil,
    "the failure names the incompatible snapshot"
  )
end

-- Canonical sibling facts pass through trainer consideration: the same
-- stocked cure answers identically with and without held-behavior, fling,
-- and natural-gift riders beside its use facts.
function T.sibling_item_records_pass_through_trainer_consideration()
  local contracts = SessionFixture.sessionContracts()
  local function servedWith(extra)
    local facts = { partyUse = potionFacts() }
    for key, value in pairs(extra) do
      facts[key] = value
    end
    local lead = leveledCombatant(1, 23, "EEVEE", 20);
    (lead.mon --[[@as table<string, unknown>]]).condition.currentHp = 4
    local foe = leveledCombatant(2, 41, "EEVEE", 5)
    local session = waitingSession(
      contracts,
      trainerStockScenario(
        SessionFixture.inventory("trainer-stock", { 2 }, { POTION = 1 }),
        { lead },
        { foe },
        nil,
        { itemFacts = { POTION = facts }, trainerItems = { "POTION", "NONE", "NONE", "NONE" } }
      )
    )
    local reply = session:answerTrainer(openRequest(session, "trainer:1"))
    session:dispose()
    return reply
  end
  local plain = servedWith({})
  Assert.equal(plain.choices[1].kind, "item", "the stocked cure answers")
  local sibling = servedWith({
    heldBehavior = { key = "heal_hp", params = {} },
    fling = { power = 30 },
    naturalGift = { power = 60, moveType = "normal" },
  })
  Assert.deepEqual(sibling, plain, "sibling records leave the trainer serving unchanged")
end

-- Answering never mutates battle state: combatants, inventories,
-- positions, and participants read identically before and after the
-- decision, while the decision draws replay deterministically from a
-- restored capture.
function T.answering_never_mutates_battle_state()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(1, 23, "EEVEE", 20)
  local foe = leveledCombatant(2, 41, "EEVEE", 5)
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, { POTION = 1 }),
      { lead },
      { foe },
      nil,
      { trainerItems = { "POTION", "NONE", "NONE", "NONE" } }
    )
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
  Assert.isTrue(after.rng.calls > callsBefore, "the decision draws from the shared stream")
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
function T.trainer_and_wild_answers_advance_the_single_battle_stream()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(1, 23, "EEVEE", 20)
  local trainerFoe = leveledCombatant(2, 41, "EEVEE", 5)
  local wildFoe = leveledCombatant(3, 55, "TOTODILE", 5)
  local seeds = { lead, trainerFoe, wildFoe }
  local trainer = SessionFixture.participant(2, 2, "trainer:1", { lead })
  trainer.context = { aiPasses = {} }
  local scenario = {
    ruleset = sessionOwner().RULESET,
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
  local afterTrainer = session:capture().rng.calls
  Assert.isTrue(afterTrainer > callsBefore, "the trainer answer advances the session stream")
  local wild = openRequest(session, "wild")
  session:withDecisionStream(wild, function(stream)
    stream:nextU16("wild_strike", { controller = wild.controller, request = wild.requestId })
    return { requestId = wild.requestId }
  end)
  Assert.isTrue(session:capture().rng.calls > afterTrainer, "the wild answer advances the same session stream")
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
  local callsBefore = held.rng.calls
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(#reply.choices, 2, "both trainer actors answer")
  for _, choice in ipairs(reply.choices) do
    Assert.equal(choice.kind, "attack", "the flagless doubles line strikes")
    local position = choice.payload.target.position
    Assert.isTrue(position == 1 or position == 2, "strikes address a live opposing position")
  end
  Assert.isTrue(session:capture().rng.calls > callsBefore, "the doubles answer draws from the shared stream")
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
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x22222222):capture()),
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
    profile = { name = "RED", gender = 0, trainerId = 1, money = money, badges = 0, nationalDex = false },
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

-- Per-flag programs adjust scores through nontrivial commands: the
-- bad-move check earns matchup points with ten off a negated strike,
-- faint-seeking drops weaker strikes and rewards doubly effective ones
-- on a favored threshold, effectiveness emphasis moves two points each
-- way, same-type preference splits two up and one down, knockout
-- awareness adds three for a finishing preview, setup continuation
-- keeps four on the pivot strike beside matchup points, and
-- unpredictability adds one to the lowest usable slot without drawing.
-- Source programs score through translated commands: each supported
-- pass executes its native word program with control-flow-exact draws.
-- The vectors below pair hand-derived program paths (guard ladders,
-- routine gates, score adjustments) with fixed seeds; changing scores or
-- draw counts without a program change fails them.
local function programSlots()
  return {
    slotWith({ key = "TACKLE" }),
    slotWith({ key = "TACKLE", id = 34 }),
    slotWith({ key = "GROWL", id = 45, moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }),
  }
end

-- The bad-move program routes listed effects through its routine gate
-- (one draw, then a conditional two-point deduction) while unlisted
-- effects skip the gate entirely without drawing.
function T.bad_move_program_routes_listed_effects_through_its_gate()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local user = fighterWith({ types = { "normal" } })
  local foe = fighterWith({ types = { "normal" } })
  local listed = {
    slotWith({ key = "P7", id = 100, moveType = "normal", power = 40, category = "physical", accuracy = 100, effect = 7 }),
    slotWith({ key = "TACKLE", id = 34 }),
    slotWith({ key = "GROWL", id = 45, moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }),
  }
  local stream = spyStream(FIXED_SEED)
  local scored = TrainerAi.scoreSlots(chart, listed, user, foe, 14, { 0 }, false, stream)
  Assert.equal(#stream:drawLabels(), 5, "the listed effect draws its routine gate")
  Assert.equal(scored[1].score, 98, "the gate deducts two on its fall-through")
  Assert.equal(scored[4].score, 0, "the spent slot stays excluded")
  local plainStream = spyStream(FIXED_SEED)
  local plain = TrainerAi.scoreSlots(chart, programSlots(), user, foe, 14, { 0 }, false, plainStream)
  Assert.equal(#plainStream:drawLabels(), 4, "unlisted effects skip the gate without drawing")
  Assert.deepEqual(
    { plain[1].score, plain[2].score, plain[3].score, plain[4].score },
    { 100, 100, 100, 0 },
    "unlisted effects leave every score at the baseline"
  )
end

-- The faint-seeking dispatch reaches routine commands only for listed
-- effects; unlisted effects fall through the ladder to the shared end
-- with initialization draws alone.
function T.faint_seeking_dispatch_reaches_routine_commands_for_listed_effects()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local user = fighterWith({ types = { "normal" } })
  local foe = fighterWith({ types = { "normal" } })
  local listed = {
    slotWith({ key = "SCREECH", id = 103, moveType = "normal", power = 0, category = "status", accuracy = 100, effect = 7 }),
    slotWith({ key = "TACKLE", id = 34 }),
    slotWith({ key = "GROWL", id = 45, moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }),
  }
  local parties = {
    [0] = { { hp = 10, maxHp = 10, species = "EEVEE", status = 0, moves = {} } },
    [1] = { { hp = 10, maxHp = 10, species = "EEVEE", status = 0, moves = {} } },
  }
  local extra = {
    parties = parties,
    partyIndex = { [0] = 0, [1] = 0 },
    partyPartner = { [0] = 0, [1] = 0 },
  }
  local stream = spyStream(FIXED_SEED)
  local scored = TrainerAi.scoreSlots(chart, listed, user, foe, 14, { 1 }, false, stream, extra)
  Assert.equal(#stream:drawLabels(), 6, "the listed effect reaches two routine draws")
  Assert.deepEqual(
    { scored[1].score, scored[2].score, scored[3].score, scored[4].score },
    { 100, 100, 100, 0 },
    "the traversed branches move no points on this state"
  )
  local plainStream = spyStream(FIXED_SEED)
  TrainerAi.scoreSlots(chart, programSlots(), user, foe, 14, { 1 }, false, plainStream, extra)
  Assert.equal(#plainStream:drawLabels(), 4, "unlisted effects fall through without drawing")
end

-- The effectiveness program gates on the opening turn and the effect
-- list before its routine draw; the draw then conditionally adds two.
function T.effectiveness_program_gates_on_turn_and_effect_list()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local user = fighterWith({ types = { "normal" } })
  local foe = fighterWith({ types = { "normal" } })
  local listed = {
    slotWith({ key = "LEER", id = 43, moveType = "normal", power = 0, category = "status", accuracy = 100, effect = 19 }),
    slotWith({ key = "TACKLE", id = 34 }),
    slotWith({ key = "GROWL", id = 45, moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }),
  }
  local openStream = spyStream(FIXED_SEED)
  local open = TrainerAi.scoreSlots(chart, listed, user, foe, 14, { 2 }, true, openStream)
  Assert.equal(#openStream:drawLabels(), 5, "the opening turn draws the listed routine")
  Assert.equal(open[1].score, 102, "the routine draw below threshold adds two")
  local laterStream = spyStream(FIXED_SEED)
  local later = TrainerAi.scoreSlots(chart, listed, user, foe, 14, { 2 }, false, laterStream)
  Assert.equal(#laterStream:drawLabels(), 4, "later turns skip the program without drawing")
  Assert.deepEqual(
    { later[1].score, later[2].score, later[3].score, later[4].score },
    { 100, 100, 100, 0 },
    "the skipped program moves no points"
  )
  local plainStream = spyStream(FIXED_SEED)
  TrainerAi.scoreSlots(chart, programSlots(), user, foe, 14, { 2 }, true, plainStream)
  Assert.equal(#plainStream:drawLabels(), 4, "unlisted effects draw nothing even on the opening turn")
end

-- Same-type and unpredictability programs follow the same
-- list-gate-draw shape with their own effect lists and bonuses.
function T.preference_programs_follow_the_list_gate_draw_shape()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local user = fighterWith({ types = { "normal" } })
  local foe = fighterWith({ types = { "normal" } })
  local listed38 = {
    slotWith({ key = "P38", id = 200, moveType = "normal", power = 40, category = "physical", accuracy = 100, effect = 38 }),
    slotWith({ key = "TACKLE", id = 34 }),
    slotWith({ key = "GROWL", id = 45, moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }),
  }
  local stream = spyStream(12345)
  local scored = TrainerAi.scoreSlots(chart, listed38, user, foe, 14, { 3 }, false, stream)
  Assert.equal(#stream:drawLabels(), 5, "the listed effect draws its routine")
  Assert.equal(scored[1].score, 102, "the routine draw at threshold adds two")
  local nine = {
    slotWith({ key = "LEER", id = 43, moveType = "normal", power = 0, category = "status", accuracy = 100, effect = 19 }),
    slotWith({ key = "TACKLE", id = 34 }),
    slotWith({ key = "GROWL", id = 45, moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }),
  }
  local nineStream = spyStream(12345)
  local ninth = TrainerAi.scoreSlots(chart, nine, user, foe, 14, { 9 }, false, nineStream)
  Assert.equal(#nineStream:drawLabels(), 5, "the listed unpredictability effect draws once")
  Assert.equal(ninth[1].score, 102, "its routine adds two at threshold")
end


-- Fresh trainer memory opens zeroed: the schema mark rides version
-- one, ordered slots mirror the scenario list, learned knowledge
-- starts empty, and the record is plain snapshot-safe data.
function T.fresh_trainer_memory_opens_zeroed_beside_the_session()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(1, 23, "EEVEE", 20)
  local foe = leveledCombatant(2, 41, "EEVEE", 5)
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, { POTION = 1 }),
      { lead },
      { foe },
      nil,
      { trainerItems = { "POTION", "NONE", "NONE", "NONE" } }
    )
  )
  local held = session:capture()
  local memory = held.trainerAi --[[@as table<string, unknown>]]
  Assert.equal(type(memory), "table", "the capture carries the trainer record")
  Assert.equal(memory.version, 1, "the record carries its schema mark")
  local controllers = memory.controllers --[[@as table<string, unknown>]]
  local owned = controllers["trainer:1"] --[[@as table<string, unknown>]]
  Assert.deepEqual(
    owned.slots,
    { "POTION", "NONE", "NONE", "NONE" },
    "ordered slots mirror the stocked list with explicit gaps"
  )
  Assert.deepEqual(owned.knownMoves, {}, "learned knowledge starts empty")
  SessionFixture.assertPlainData(memory, "fresh trainer memory")
  session:dispose()
end

-- A stocked trainer without ordered slots fails closed: session
-- construction names the trainer instead of recovering order from the
-- stock map, while an empty stock needs no order and still opens.
function T.stocked_trainers_without_ordered_slots_fail_closed()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(1, 23, "EEVEE", 20)
  local foe = leveledCombatant(2, 41, "EEVEE", 5)
  local failure = Assert.throws(function()
    waitingSession(
      contracts,
      trainerStockScenario(SessionFixture.inventory("trainer-stock", { 2 }, { POTION = 1 }), { lead }, { foe })
    )
  end, "a stocked trainer without ordered slots fails instead of guessing order")
  Assert.isTrue(
    string.find(tostring(failure), "trainer:1", 1, true) ~= nil,
    "the failure names the trainer missing its order"
  )
  local quiet = waitingSession(
    contracts,
    trainerStockScenario(SessionFixture.inventory("trainer-stock", { 2 }, {}), { lead }, { foe })
  )
  quiet:dispose()
end

-- Malformed trainer records never restore: a missing record, a foreign
-- schema mark, a misshapen slot list, and compact or overlong slot
-- lists all fail incompatible instead of seeding fresh guesses.
function T.malformed_trainer_records_fail_restore_as_incompatible()
  local TrainerAi = trainerPolicy()
  Assert.isTrue(
    TrainerAi.validateMemory({
      version = 1,
      controllers = { ["trainer:1"] = { slots = { "POTION", "NONE", "NONE", "NONE" }, knownMoves = {} } },
    }),
    "a well-formed record validates"
  )
  for _, broken in
    ipairs({
      { version = 2, controllers = {} },
      { version = 1, controllers = { ["trainer:1"] = { slots = { "" }, knownMoves = {} } } },
      { version = 1, controllers = { ["trainer:1"] = { slots = {}, knownMoves = { [0] = {} } } } },
      { version = 1, controllers = { ["trainer:1"] = { slots = { "POTION" }, knownMoves = {} } } },
      {
        version = 1,
        controllers = { ["trainer:1"] = { slots = { "POTION", "NONE", "NONE", "NONE", "POTION" }, knownMoves = {} } },
      },
    })
  do
    local failure = Assert.throws(function()
      TrainerAi.validateMemory(broken)
    end, "a malformed record fails instead of guessing")
    Assert.isTrue(
      string.find(string.lower(tostring(failure)), "incompatible", 1, true) ~= nil,
      "the failure names the incompatible snapshot"
    )
  end
  local absent = Assert.throws(function()
    TrainerAi.validateMemory(nil)
  end, "a missing record fails instead of guessing")
  Assert.isTrue(
    string.find(string.lower(tostring(absent)), "incompatible", 1, true) ~= nil
      or string.find(tostring(absent), "trainerAi", 1, true) ~= nil,
    "the failure names the incompatible snapshot"
  )
end

-- Ordered slots win over alphabetical stock: with two eligible
-- servings the first source slot answers, the proposal consumes
-- nothing, and the next answer moves to the second slot.
function T.ordered_slots_win_over_alphabetical_stock()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(1, 23, "EEVEE", 20);
  (lead.mon --[[@as table<string, unknown>]]).condition.currentHp = 10
  local foe = leveledCombatant(2, 41, "EEVEE", 5)
  local superFacts = {
    kind = "medicine",
    restore = { kind = "fixed", amount = 50 },
    cures = { sleep = false, poison = false, burn = false, freeze = false, paralysis = false },
    revive = "none",
    mood = 0,
  }
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, { SUPER_POTION = 1, POTION = 1 }),
      { lead },
      { foe },
      nil,
      {
        passes = {},
        itemFacts = { SUPER_POTION = { partyUse = superFacts }, POTION = { partyUse = potionFacts() } },
        trainerItems = { "SUPER_POTION", "POTION", "NONE", "NONE" },
      }
    )
  )
  local memory = session:capture().trainerAi --[[@as table<string, unknown>]]
  local controllers = memory.controllers --[[@as table<string, unknown>]]
  local owned = controllers["trainer:1"] --[[@as table<string, unknown>]]
  Assert.deepEqual(
    owned.slots,
    { "SUPER_POTION", "POTION", "NONE", "NONE" },
    "memory slots mirror the source order with explicit gaps"
  )
  local first = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(first.choices[1].kind, "item", "an eligible serving answers")
  Assert.equal(
    first.choices[1].payload.item,
    "SUPER_POTION",
    "the first source slot wins over alphabetical stock"
  )
  local second = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(second.choices[1].kind, "item", "the second slot still serves")
  Assert.equal(second.choices[1].payload.item, "POTION", "the proposal moves down the ordered slots")
  local held = session:capture().inventories["trainer-stock"].quantities
  Assert.deepEqual(held, { SUPER_POTION = 1, POTION = 1 }, "answering alone consumes no stock")
  local accepted, acceptErr = session:submit(first)
  Assert.isTrue(accepted, "the first serving submits: " .. tostring(acceptErr))
  session:dispose()
end

-- Duplicate item slots serve in source order across turns: with two
-- servings of the first identity around a second, the opening answer
-- takes the first slot, execution decrements that stock exactly once,
-- and the next-turn answer takes the middle slot without drawing.
function T.duplicate_item_slots_serve_in_source_order_across_turns()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(1, 23, "EEVEE", 100);
  (lead.mon --[[@as table<string, unknown>]]).condition.currentHp = 4
  local foe = leveledCombatant(2, 41, "EEVEE", 5)
  local superFacts = {
    kind = "medicine",
    restore = { kind = "fixed", amount = 50 },
    cures = { sleep = false, poison = false, burn = false, freeze = false, paralysis = false },
    revive = "none",
    mood = 0,
  }
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, { POTION = 2, SUPER_POTION = 1 }),
      { lead },
      { foe },
      nil,
      {
        passes = {},
        itemFacts = { POTION = { partyUse = potionFacts() }, SUPER_POTION = { partyUse = superFacts } },
        trainerItems = { "POTION", "SUPER_POTION", "POTION", "NONE" },
      }
    )
  )
  local function slotsOf(captured)
    local memory = captured.trainerAi --[[@as table<string, unknown>]]
    local controllers = memory.controllers --[[@as table<string, unknown>]]
    local owned = controllers["trainer:1"] --[[@as table<string, unknown>]]
    return owned.slots
  end
  local callsBefore = session:capture().rng.calls
  local first = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(first.choices[1].kind, "item", "the opening answer serves")
  Assert.equal(first.choices[1].payload.item, "POTION", "the first source slot answers first")
  Assert.equal(session:capture().rng.calls, callsBefore, "the opening selection moves no stream draws")
  Assert.deepEqual(
    slotsOf(session:capture()),
    { "NONE", "SUPER_POTION", "POTION", "NONE" },
    "selection clears only the first matching slot in place"
  )
  local foeRequest = openRequest(session, "player")
  local foeActor = assert(foeRequest.actors[1], "the opposing request addresses its lead")
  Assert.isTrue(session:submit(first), "the opening serving binds")
  local bound, bindErr = session:submit(SessionFixture.replyFor(foeRequest, {
    SessionFixture.attackChoice(foeActor, 0, SessionFixture.positionTarget(2)),
  }))
  Assert.isTrue(bound, "the opposing strike binds: " .. tostring(bindErr))
  session:advance(1024)
  Assert.deepEqual(
    session:capture().inventories["trainer-stock"].quantities,
    { POTION = 1, SUPER_POTION = 1 },
    "execution decrements the served stock exactly once"
  )
  local nextCallsBefore = session:capture().rng.calls
  local second = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(second.choices[1].kind, "item", "the next turn still serves")
  Assert.equal(second.choices[1].payload.item, "SUPER_POTION", "the middle slot answers next")
  Assert.equal(session:capture().rng.calls, nextCallsBefore, "the next selection moves no stream draws")
  Assert.deepEqual(
    slotsOf(session:capture()),
    { "NONE", "NONE", "POTION", "NONE" },
    "the middle slot clears in turn without shifting"
  )
  session:dispose()
end

-- Candidate stream seeds for post-strike branch prediction: the first draw
-- after the exchange turn selects the reserve, so each candidate runs the
-- full opening turn before its head is probed.
local POST_STRIKE_SEEDS = {}
for offset = 0, 7 do
  POST_STRIKE_SEEDS[#POST_STRIKE_SEEDS + 1] = NATIVE_SEED + offset
end

---@param contracts table session owners under test driving
---@param seeds integer[] candidate stream seeds in trial order
---@param build fun(seed: integer): table detached native battle setup under test driving
---@param predict fun(first: integer): boolean true when the post-strike gate draw selects the reserve
---@return table live native session waiting on the predicted exchange
---@return table post-strike capture behind the prediction
local function sessionWithPredictedPostStrike(contracts, seeds, build, predict)
  for _, seed in ipairs(seeds) do
    local session = waitingSession(contracts, build(seed))
    local trainerRequest = openRequest(session, "trainer:1")
    local trainerActor = assert(trainerRequest.actors[1], "the trainer request addresses its lead")
    local foeRequest = openRequest(session, "player")
    local foeActor = assert(foeRequest.actors[1], "the opposing request addresses its lead")
    Assert.isTrue(
      session:submit(
        SessionFixture.replyFor(trainerRequest, {
          SessionFixture.attackChoice(trainerActor, 0, SessionFixture.positionTarget(1)),
        })
      ),
      "the opening trainer strike binds"
    )
    Assert.isTrue(
      session:submit(
        SessionFixture.replyFor(foeRequest, {
          SessionFixture.attackChoice(foeActor, 0, SessionFixture.positionTarget(2)),
        })
      ),
      "the opening foe strike binds"
    )
    session:advance(1024)
    local held = session:capture()
    local probe = BattleRng.restore(held.rng --[[@as table<string, integer>]])
    if predict(probe:nextU16("exchange_probe", {})) then
      return session, held
    end
    session:dispose()
  end
  error("no candidate seed predicts the exchange")
end

-- A genuinely missing received-hit table fails the next answer closed:
-- a post-strike state predating the history table raises naming the
-- fact, while the same state with an empty table answers from
-- never-struck knowledge instead of guessing. Used-strike history alone
-- never satisfies the read.
function T.unknown_hit_history_fails_the_next_answer_closed()
  local TrainerAi = trainerPolicy()
  local contracts = SessionFixture.sessionContracts()
  local holder = leveledCombatant(11, 23, "TOTODILE", 10)
  holder.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } };
  (holder.mon --[[@as table<string, unknown>]]).condition.currentHp = 22
  local reserve = leveledCombatant(12, 24, "CHIKORITA", 10)
  local foe = leveledCombatant(13, 41, "EEVEE", 10)
  foe.mon.moves = { { move = "RAZOR_LEAF", pp = 25, ppUps = 0 } }
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, {}),
      { holder, reserve },
      { foe },
      { "TACKLE", "RAZOR_LEAF" },
      { passes = {} }
    )
  )
  local opening = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(opening.choices[1].kind, "attack", "the opening answer strikes without knowledge")
  local foeRequest = openRequest(session, "player")
  local foeActor = assert(foeRequest.actors[1], "the opposing request addresses its lead")
  local stored, storeErr = session:submit(
    SessionFixture.replyFor(openRequest(session, "trainer:1"), {
      SessionFixture.attackChoice(opening.choices[1].actor, 0, SessionFixture.positionTarget(1)),
    })
  )
  Assert.isTrue(stored, "the trainer strike binds: " .. tostring(storeErr))
  local storedFoe, foeErr = session:submit(
    SessionFixture.replyFor(foeRequest, {
      SessionFixture.attackChoice(foeActor, 0, SessionFixture.positionTarget(2)),
    })
  )
  Assert.isTrue(storedFoe, "the revealing strike binds: " .. tostring(foeErr))
  session:advance(1024)
  local learned = session:capture().trainerAi --[[@as table<string, unknown>]]
  local controllers = learned.controllers --[[@as table<string, unknown>]]
  local owned = controllers["trainer:1"] --[[@as table<string, unknown>]]
  local known = owned.knownMoves --[[@as table<integer, unknown>]]
  Assert.deepEqual(known[13], { RAZOR_LEAF = true }, "the executed strike is learned")
  local EffectBag = require("libs.battle.src.EffectBag")
  local function syntheticState(history)
    local held = session:capture()
    -- Used-strike history rides both halves: only the received-hit
    -- table differs, proving which read the gate answers from.
    held.lastMoves = { [13] = "RAZOR_LEAF" }
    held.lastHits = history
    held.effectBag = EffectBag.new()
    return held
  end
  local authorities = {
    chart = nativeChart(),
    moveFacts = scenarioMoveFacts({ "TACKLE", "RAZOR_LEAF" }),
    speciesFacts = scenarioSpeciesFacts({ holder, reserve, foe }),
    itemFacts = {},
  }
  local activation =
    (session:capture().combatants --[[@as table<integer, table<string, unknown>>]])[11].active.activation
  local request = {
    requestId = 1,
    epoch = 1,
    controller = "trainer:1",
    actors = { { combatant = 11, activation = activation } },
  }
  local failure = Assert.throws(function()
    TrainerAi.answer(syntheticState(nil), authorities, request, spyStream(FIXED_SEED), {})
  end, "the next answer needs its received-hit history")
  Assert.isTrue(
    string.find(string.lower(tostring(failure)), "hit", 1, true) ~= nil,
    "the failure names the missing hit history"
  )
  local stream = spyStream(FIXED_SEED)
  local reply = TrainerAi.answer(syntheticState({}), authorities, request, stream, {})
  Assert.equal(
    reply.choices[1].kind,
    "attack",
    "an empty history answers from never-struck knowledge"
  )
  Assert.equal(stream:capture().calls, 5, "the never-struck answer spends only its strike draws")
  session:dispose()
end

-- A recorded last hit no longer fails the next answer: after the
-- trainer withdraws into a strike the foe reveals, the holder answers
-- with a strike instead of faulting.
function T.recorded_last_hits_answer_instead_of_faulting()
  local contracts = SessionFixture.sessionContracts()
  local holder = leveledCombatant(11, 23, "TOTODILE", 10)
  holder.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } };
  (holder.mon --[[@as table<string, unknown>]]).condition.currentHp = 22
  local reserve = leveledCombatant(12, 24, "CHIKORITA", 10)
  local foe = leveledCombatant(13, 41, "EEVEE", 10)
  foe.mon.moves = { { move = "RAZOR_LEAF", pp = 25, ppUps = 0 } }
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, {}),
      { holder, reserve },
      { foe },
      { "TACKLE", "RAZOR_LEAF" },
      { passes = {} }
    )
  )
  local trainerRequest = openRequest(session, "trainer:1")
  local trainerActor = assert(trainerRequest.actors[1], "the trainer request addresses its lead")
  local foeRequest = openRequest(session, "player")
  local foeActor = assert(foeRequest.actors[1], "the opposing request addresses its lead")
  Assert.isTrue(
    session:submit(
      SessionFixture.replyFor(trainerRequest, { SessionFixture.switchChoice(trainerActor, 12) })
    ),
    "the withdrawal binds"
  )
  Assert.isTrue(
    session:submit(
      SessionFixture.replyFor(foeRequest, {
        SessionFixture.attackChoice(foeActor, 0, SessionFixture.positionTarget(2)),
      })
    ),
    "the revealing strike binds"
  )
  session:advance(1024)
  Assert.deepEqual(
    (session:capture().lastHits --[[@as table<integer, unknown>]])[12],
    { move = "RAZOR_LEAF", user = 13 },
    "the struck arrival carries its received hit"
  )
  local held = session:capture()
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "attack", "the recorded last hit answers with a strike")
  Assert.equal(
    session:capture().rng.calls - held.rng.calls,
    5,
    "the strike spends only its selection draws"
  )
  session:dispose()
end

-- The absorb tail exchanges for a covering reserve: after a damaging
-- water strike lands on a holder without the guard, the first benched
-- water-guard answers on an odd branch draw.
function T.absorb_tail_exchanges_for_a_covering_reserve()
  local contracts = SessionFixture.sessionContracts()
  local function build(seed)
    local holder = leveledCombatant(11, 23, "EEVEE", 20)
    holder.mon.moves = { { move = "GROWL", pp = 40, ppUps = 0 } }
    local guard = leveledCombatant(12, 24, "TOTODILE", 10);
    (guard.mon --[[@as table<string, unknown>]]).ability = "WATER_ABSORB"
    local foe = leveledCombatant(13, 41, "TOTODILE", 5)
    foe.mon.moves = { { move = "WATER_GUN", pp = 25, ppUps = 0 } };
    (foe.mon --[[@as table<string, unknown>]]).ability = "RUN_AWAY"
    return trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, {}),
      { holder, guard },
      { foe },
      { "TACKLE", "GROWL", "WATER_GUN" },
      { passes = {}, seed = seed }
    )
  end
  local session, held = sessionWithPredictedPostStrike(contracts, POST_STRIKE_SEEDS, build, function(first)
    return first % 2 == 1
  end)
  Assert.deepEqual(
    (session:capture().lastHits --[[@as table<integer, unknown>]])[11],
    { move = "WATER_GUN", user = 13 },
    "the struck holder carries its received hit"
  )
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "switch", "the guard reserve answers the water strike")
  Assert.equal(reply.choices[1].payload.replacement, 12, "the water guard takes the field")
  Assert.equal(
    session:capture().rng.calls - held.rng.calls,
    1,
    "the exchange spends only its branch draw"
  )
  session:dispose()
end

-- A holder carrying the guard stays: the same water strike answered by
-- a guard holder falls through the tails to a strike with no gate
-- draws.
function T.absorb_tail_holds_when_the_holder_carries_the_guard()
  local contracts = SessionFixture.sessionContracts()
  local holder = leveledCombatant(11, 23, "EEVEE", 20)
  holder.mon.moves = { { move = "GROWL", pp = 40, ppUps = 0 } };
  (holder.mon --[[@as table<string, unknown>]]).ability = "WATER_ABSORB"
  local guard = leveledCombatant(12, 24, "TOTODILE", 10);
  (guard.mon --[[@as table<string, unknown>]]).ability = "WATER_ABSORB"
  local foe = leveledCombatant(13, 41, "TOTODILE", 5)
  foe.mon.moves = { { move = "WATER_GUN", pp = 25, ppUps = 0 } };
  (foe.mon --[[@as table<string, unknown>]]).ability = "RUN_AWAY"
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, {}),
      { holder, guard },
      { foe },
      { "TACKLE", "GROWL", "WATER_GUN" },
      { passes = {} }
    )
  )
  local trainerRequest = openRequest(session, "trainer:1")
  local trainerActor = assert(trainerRequest.actors[1], "the trainer request addresses its lead")
  local foeRequest = openRequest(session, "player")
  local foeActor = assert(foeRequest.actors[1], "the opposing request addresses its lead")
  Assert.isTrue(
    session:submit(
      SessionFixture.replyFor(trainerRequest, {
        SessionFixture.attackChoice(trainerActor, 0, SessionFixture.positionTarget(1)),
      })
    ),
    "the holder status strike binds"
  )
  Assert.isTrue(
    session:submit(
      SessionFixture.replyFor(foeRequest, {
        SessionFixture.attackChoice(foeActor, 0, SessionFixture.positionTarget(2)),
      })
    ),
    "the water strike binds"
  )
  session:advance(1024)
  local held = session:capture()
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "attack", "the guard holder stays and strikes")
  Assert.equal(
    session:capture().rng.calls - held.rng.calls,
    5,
    "the stay spends only its strike draws"
  )
  session:dispose()
end

-- The immunity tail exchanges for a covering reserve: a normal last hit
-- immune into the benched ghost answers through its selective reach on
-- an even branch draw.
function T.immunity_tail_exchanges_for_a_covering_reserve()
  local contracts = SessionFixture.sessionContracts()
  local function build(seed)
    local holder = leveledCombatant(11, 23, "EEVEE", 20)
    holder.mon.moves = { { move = "GROWL", pp = 40, ppUps = 0 } }
    local cover = leveledCombatant(12, 24, "SHEDINJA", 5)
    cover.mon.moves = {
      { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
      { move = "SCRATCH", pp = 35, ppUps = 0 },
    }
    local foe = leveledCombatant(13, 41, "TOTODILE", 5)
    foe.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } };
    (foe.mon --[[@as table<string, unknown>]]).ability = "RUN_AWAY"
    return trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, {}),
      { holder, cover },
      { foe },
      { "TACKLE", "GROWL", "RAZOR_LEAF", "SCRATCH" },
      { passes = {}, seed = seed }
    )
  end
  local session, held = sessionWithPredictedPostStrike(contracts, POST_STRIKE_SEEDS, build, function(first)
    return first % 2 == 0
  end)
  Assert.deepEqual(
    (session:capture().lastHits --[[@as table<integer, unknown>]])[11],
    { move = "TACKLE", user = 13 },
    "the struck holder carries its received hit"
  )
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "switch", "the covering reserve answers the immune strike")
  Assert.equal(reply.choices[1].payload.replacement, 12, "the immune reserve takes the field")
  Assert.equal(
    session:capture().rng.calls - held.rng.calls,
    1,
    "the exchange spends only its branch draw"
  )
  session:dispose()
end

-- The resist tail exchanges for a covering reserve: a water last hit
-- resisted by the benched water answers through its selective reach
-- when the branch draw falls on three.
function T.resist_tail_exchanges_for_a_covering_reserve()
  local contracts = SessionFixture.sessionContracts()
  local function build(seed)
    local holder = leveledCombatant(11, 23, "EEVEE", 20)
    holder.mon.moves = { { move = "GROWL", pp = 40, ppUps = 0 } }
    local cover = leveledCombatant(12, 24, "TOTODILE", 10)
    cover.mon.moves = {
      { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
      { move = "SCRATCH", pp = 35, ppUps = 0 },
    }
    local foe = leveledCombatant(13, 41, "TOTODILE", 5)
    foe.mon.moves = { { move = "WATER_GUN", pp = 25, ppUps = 0 } };
    (foe.mon --[[@as table<string, unknown>]]).ability = "RUN_AWAY"
    return trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, {}),
      { holder, cover },
      { foe },
      { "TACKLE", "GROWL", "WATER_GUN", "RAZOR_LEAF", "SCRATCH" },
      { passes = {}, seed = seed }
    )
  end
  local session, held = sessionWithPredictedPostStrike(contracts, POST_STRIKE_SEEDS, build, function(first)
    return first % 3 == 0
  end)
  Assert.deepEqual(
    (session:capture().lastHits --[[@as table<integer, unknown>]])[11],
    { move = "WATER_GUN", user = 13 },
    "the struck holder carries its received hit"
  )
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "switch", "the covering reserve answers the resisted strike")
  Assert.equal(reply.choices[1].payload.replacement, 12, "the resisting reserve takes the field")
  Assert.equal(
    session:capture().rng.calls - held.rng.calls,
    1,
    "the exchange spends only its branch draw"
  )
  session:dispose()
end

-- Relief with a damaging last hit probes before its final coin: the
-- sleeping cure holder finds no immune or resisting cover, so the
-- closing coin alone decides.
function T.relief_with_a_damaging_last_hit_probes_before_its_final_coin()
  local contracts = SessionFixture.sessionContracts()
  local function build(seed)
    local holder = leveledCombatant(31, 23, "EEVEE", 20);
    (holder.mon --[[@as table<string, unknown>]]).ability = "NATURAL_CURE"
    ;(holder.mon --[[@as table<string, unknown>]]).condition.effects =
      { { key = "sleep", state = { turns = 5 } } }
    holder.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
    local reserve = leveledCombatant(32, 24, "TOTODILE", 10)
    local foe = leveledCombatant(33, 41, "TOTODILE", 5)
    foe.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } };
    (foe.mon --[[@as table<string, unknown>]]).ability = "RUN_AWAY"
    return trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, {}),
      { holder, reserve },
      { foe },
      { "TACKLE" },
      { passes = {}, seed = seed }
    )
  end
  local session, held = sessionWithPredictedPostStrike(contracts, POST_STRIKE_SEEDS, build, function(first)
    return first % 2 == 1
  end)
  Assert.deepEqual(
    (session:capture().lastHits --[[@as table<integer, unknown>]])[31],
    { move = "TACKLE", user = 33 },
    "the struck sleeper carries its received hit"
  )
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "switch", "the relief coin answers with the first reserve")
  Assert.equal(reply.choices[1].payload.replacement, 32, "the first living reserve takes the field")
  Assert.equal(
    session:capture().rng.calls - held.rng.calls,
    1,
    "the exchange spends only its branch draw"
  )
  session:dispose()
end

-- Relief with a powerless last hit still exchanges: the sleeping cure
-- holder spends its status-move coin, and the immune probe behind it
-- answers through the covering reach, so either path names the same
-- reserve with no fault.
function T.relief_with_a_powerless_last_hit_still_exchanges()
  local contracts = SessionFixture.sessionContracts()
  local function build(seed)
    local holder = leveledCombatant(31, 23, "EEVEE", 20);
    (holder.mon --[[@as table<string, unknown>]]).ability = "NATURAL_CURE"
    ;(holder.mon --[[@as table<string, unknown>]]).condition.effects =
      { { key = "sleep", state = { turns = 5 } } }
    holder.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
    local reserve = leveledCombatant(32, 24, "SHEDINJA", 5)
    reserve.mon.moves = {
      { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
      { move = "SCRATCH", pp = 35, ppUps = 0 },
    }
    local foe = leveledCombatant(33, 41, "TOTODILE", 5)
    foe.mon.moves = { { move = "GROWL", pp = 40, ppUps = 0 } };
    (foe.mon --[[@as table<string, unknown>]]).ability = "RUN_AWAY"
    return trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, {}),
      { holder, reserve },
      { foe },
      { "TACKLE", "GROWL", "RAZOR_LEAF", "SCRATCH" },
      { passes = {}, seed = seed }
    )
  end
  local session = waitingSession(contracts, build(NATIVE_SEED))
  local trainerRequest = openRequest(session, "trainer:1")
  local trainerActor = assert(trainerRequest.actors[1], "the trainer request addresses its lead")
  local foeRequest = openRequest(session, "player")
  local foeActor = assert(foeRequest.actors[1], "the opposing request addresses its lead")
  Assert.isTrue(
    session:submit(
      SessionFixture.replyFor(trainerRequest, {
        SessionFixture.attackChoice(trainerActor, 0, SessionFixture.positionTarget(1)),
      })
    ),
    "the sleeper strike binds"
  )
  Assert.isTrue(
    session:submit(
      SessionFixture.replyFor(foeRequest, {
        SessionFixture.attackChoice(foeActor, 0, SessionFixture.positionTarget(2)),
      })
    ),
    "the status strike binds"
  )
  session:advance(1024)
  Assert.deepEqual(
    (session:capture().lastHits --[[@as table<integer, unknown>]])[31],
    { move = "GROWL", user = 33 },
    "the struck sleeper carries its received hit"
  )
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "switch", "the powerless last hit still exchanges")
  Assert.equal(reply.choices[1].payload.replacement, 32, "the covering reserve takes the field")
  session:dispose()
end

-- Distinct used moves record in first-use order: three strikes across
-- three turns with a repeated opener ledger exactly the two distinct
-- identities in the order they first executed.
function T.used_move_history_records_first_use_order()
  local contracts = SessionFixture.sessionContracts()
  local holder = leveledCombatant(11, 23, "EEVEE", 10)
  holder.mon.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "GROWL", pp = 40, ppUps = 0 },
  }
  local foe = leveledCombatant(13, 41, "EEVEE", 10)
  foe.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, {}),
      { holder },
      { foe },
      { "TACKLE", "GROWL" },
      { passes = {} }
    )
  )
  for turn, moveSlot in ipairs({ 0, 1, 0 }) do
    local trainerRequest = openRequest(session, "trainer:1")
    local trainerActor = assert(trainerRequest.actors[1], "the trainer request addresses its lead")
    local foeRequest = openRequest(session, "player")
    local foeActor = assert(foeRequest.actors[1], "the opposing request addresses its lead")
    Assert.isTrue(
      session:submit(
        SessionFixture.replyFor(trainerRequest, {
          SessionFixture.attackChoice(trainerActor, moveSlot, SessionFixture.positionTarget(1)),
        })
      ),
      "the turn " .. turn .. " trainer strike binds"
    )
    Assert.isTrue(
      session:submit(
        SessionFixture.replyFor(foeRequest, {
          SessionFixture.attackChoice(foeActor, 0, SessionFixture.positionTarget(2)),
        })
      ),
      "the turn " .. turn .. " foe strike binds"
    )
    session:advance(1024)
  end
  local combatants = session:capture().combatants --[[@as table<integer, table<string, unknown>>]]
  local activation = combatants[11].active.activation
  Assert.deepEqual(
    (session:capture().usedMoves --[[@as table<integer, unknown>]])[activation],
    { "TACKLE", "GROWL" },
    "the ledger carries distinct moves in first-use order without repeats"
  )
  session:dispose()
end

-- The third used move drives matchup scaling: with three distinct
-- mixed-band strikes behind it, the bad-move program scores the next
-- answer instead of faulting on the unordered ledger.
function T.third_used_move_drives_matchup_scaling()
  local contracts = SessionFixture.sessionContracts()
  local holder = leveledCombatant(11, 23, "CHIKORITA", 10)
  holder.mon.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "GROWL", pp = 40, ppUps = 0 },
    { move = "LEER", pp = 30, ppUps = 0 },
  }
  local foe = leveledCombatant(13, 41, "TOTODILE", 5)
  foe.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, {}),
      { holder },
      { foe },
      { "TACKLE", "GROWL", "LEER" },
      { passes = { "ai_pass_0" } }
    )
  )
  for turn, moveSlot in ipairs({ 0, 1, 2 }) do
    local trainerRequest = openRequest(session, "trainer:1")
    local trainerActor = assert(trainerRequest.actors[1], "the trainer request addresses its lead")
    local foeRequest = openRequest(session, "player")
    local foeActor = assert(foeRequest.actors[1], "the opposing request addresses its lead")
    Assert.isTrue(
      session:submit(
        SessionFixture.replyFor(trainerRequest, {
          SessionFixture.attackChoice(trainerActor, moveSlot, SessionFixture.positionTarget(1)),
        })
      ),
      "the turn " .. turn .. " trainer strike binds"
    )
    Assert.isTrue(
      session:submit(
        SessionFixture.replyFor(foeRequest, {
          SessionFixture.attackChoice(foeActor, 0, SessionFixture.positionTarget(2)),
        })
      ),
      "the turn " .. turn .. " foe strike binds"
    )
    session:advance(1024)
  end
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(
    reply.choices[1].kind,
    "attack",
    "the ordered history scores instead of faulting"
  )
  session:dispose()
end

-- First-use order selects the scaling band: the same three distinct
-- moves score the second slot differently depending on which identity
-- the order puts third.
function T.first_use_order_selects_the_scaling_band()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local slots = {
    slotWith({ key = "PROBE", id = 264, moveType = "fighting", power = 150, effect = 0, accuracy = 100 }),
    slotWith({}),
    slotWith({ key = "GROWL", id = 45, moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }),
  }
  local user = fighterWith({ types = { "grass" } })
  local foe = fighterWith({ types = { "water" } })
  local members = { { hp = 10, maxHp = 10, species = "EEVEE", status = 0, moves = {} } }
  local function scoredWith(order)
    local extra = {
      parties = { [0] = members, [1] = members },
      partyIndex = { [0] = 0, [1] = 0 },
      partyPartner = { [0] = 0, [1] = 0 },
      usedIds = { [0] = order, [1] = order },
      lastMove = { [0] = 0, [1] = 0 },
    }
    return TrainerAi.scoreSlots(chart, slots, user, foe, 14, { 0 }, false, spyStream(FIXED_SEED), extra)
  end
  Assert.equal(
    scoredWith({ 33, 45, 64 })[2].score,
    100,
    "a band-zero third move zeroes the matchup scaling"
  )
  Assert.equal(
    scoredWith({ 33, 45, 43 })[2].score,
    99,
    "a band-five third move scales the matchup fully"
  )
end

-- Ledgers predating the order fail the history read closed: a restored
-- snapshot carrying the old presence-set shape raises naming the
-- ordered history instead of guessing fresh.
function T.predated_unordered_ledgers_fail_the_history_read_closed()
  local Executor = sessionOwner()
  local contracts = SessionFixture.sessionContracts()
  local holder = leveledCombatant(11, 23, "CHIKORITA", 10)
  holder.mon.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "GROWL", pp = 40, ppUps = 0 },
    { move = "LEER", pp = 30, ppUps = 0 },
  }
  local foe = leveledCombatant(13, 41, "TOTODILE", 5)
  foe.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, {}),
      { holder },
      { foe },
      { "TACKLE", "GROWL", "LEER" },
      { passes = { "ai_pass_0" } }
    )
  )
  for turn, moveSlot in ipairs({ 0, 1, 2 }) do
    local trainerRequest = openRequest(session, "trainer:1")
    local trainerActor = assert(trainerRequest.actors[1], "the trainer request addresses its lead")
    local foeRequest = openRequest(session, "player")
    local foeActor = assert(foeRequest.actors[1], "the opposing request addresses its lead")
    Assert.isTrue(
      session:submit(
        SessionFixture.replyFor(trainerRequest, {
          SessionFixture.attackChoice(trainerActor, moveSlot, SessionFixture.positionTarget(1)),
        })
      ),
      "the turn " .. turn .. " trainer strike binds"
    )
    Assert.isTrue(
      session:submit(
        SessionFixture.replyFor(foeRequest, {
          SessionFixture.attackChoice(foeActor, 0, SessionFixture.positionTarget(2)),
        })
      ),
      "the turn " .. turn .. " foe strike binds"
    )
    session:advance(1024)
  end
  local held = session:capture()
  session:dispose()
  local combatants = held.combatants --[[@as table<integer, table<string, unknown>>]]
  local activation = combatants[11].active.activation
  held.usedMoves[activation] = { TACKLE = true, GROWL = true, LEER = true }
  local restored = Executor.restore(held, trainerContent())
  local failure = Assert.throws(function()
    restored:answerTrainer(openRequest(restored, "trainer:1"))
  end, "the predated ledger fails instead of guessing fresh")
  Assert.isTrue(
    string.find(string.lower(tostring(failure)), "ordered", 1, true) ~= nil,
    "the failure names the ordered history"
  )
  restored:dispose()
end

-- Executed strikes record their received hit per struck combatant: after
-- both leads exchange strikes, the session carries the striking move and
-- its user under each taker, and a restored snapshot replays the same
-- record.
function T.executed_strikes_record_their_received_hit_per_struck_combatant()
  local Executor = sessionOwner()
  local contracts = SessionFixture.sessionContracts()
  local holder = leveledCombatant(11, 23, "TOTODILE", 10)
  holder.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } };
  (holder.mon --[[@as table<string, unknown>]]).condition.currentHp = 22
  local reserve = leveledCombatant(12, 24, "CHIKORITA", 10)
  local foe = leveledCombatant(13, 41, "EEVEE", 10)
  foe.mon.moves = { { move = "RAZOR_LEAF", pp = 25, ppUps = 0 } }
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, {}),
      { holder, reserve },
      { foe },
      { "TACKLE", "RAZOR_LEAF" },
      { passes = {} }
    )
  )
  local opening = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(opening.choices[1].kind, "attack", "the opening answer strikes without knowledge")
  local foeRequest = openRequest(session, "player")
  local foeActor = assert(foeRequest.actors[1], "the opposing request addresses its lead")
  local stored, storeErr = session:submit(
    SessionFixture.replyFor(openRequest(session, "trainer:1"), {
      SessionFixture.attackChoice(opening.choices[1].actor, 0, SessionFixture.positionTarget(1)),
    })
  )
  Assert.isTrue(stored, "the trainer strike binds: " .. tostring(storeErr))
  local storedFoe, foeErr = session:submit(
    SessionFixture.replyFor(foeRequest, {
      SessionFixture.attackChoice(foeActor, 0, SessionFixture.positionTarget(2)),
    })
  )
  Assert.isTrue(storedFoe, "the revealing strike binds: " .. tostring(foeErr))
  session:advance(1024)
  -- The foe outruns the holder, so the holder acts after being struck:
  -- its own record clears at its action while the foe's record survives.
  Assert.deepEqual(
    session:capture().lastHits,
    { [13] = { move = "TACKLE", user = 11 } },
    "each struck combatant carries the striking move and its user"
  )
  local held = session:capture()
  session:dispose()
  local restored = Executor.restore(held, trainerContent())
  Assert.deepEqual(
    restored:capture().lastHits,
    { [13] = { move = "TACKLE", user = 11 } },
    "the restored snapshot replays the received-hit record"
  )
  restored:dispose()
end

-- Received hits clear when their holder acts unstruck: after the
-- exchange turn both leads carry a record, then the trainer strikes
-- while the foe withdraws, leaving neither the acting holder nor the
-- departing foe with a record.
function T.received_hit_clears_when_its_holder_acts_unstruck()
  local contracts = SessionFixture.sessionContracts()
  local holder = leveledCombatant(11, 23, "TOTODILE", 10)
  holder.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } };
  (holder.mon --[[@as table<string, unknown>]]).condition.currentHp = 22
  local reserve = leveledCombatant(12, 24, "CHIKORITA", 10)
  local foe = leveledCombatant(13, 41, "EEVEE", 10)
  foe.mon.moves = { { move = "RAZOR_LEAF", pp = 25, ppUps = 0 } }
  local foeReserve = leveledCombatant(14, 42, "TOTODILE", 10)
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, {}),
      { holder, reserve },
      { foe, foeReserve },
      { "TACKLE", "RAZOR_LEAF" },
      { passes = {} }
    )
  )
  local opening = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(opening.choices[1].kind, "attack", "the opening answer strikes without knowledge")
  local foeRequest = openRequest(session, "player")
  local foeActor = assert(foeRequest.actors[1], "the opposing request addresses its lead")
  Assert.isTrue(
    session:submit(
      SessionFixture.replyFor(openRequest(session, "trainer:1"), {
        SessionFixture.attackChoice(opening.choices[1].actor, 0, SessionFixture.positionTarget(1)),
      })
    ),
    "the trainer strike binds"
  )
  Assert.isTrue(
    session:submit(
      SessionFixture.replyFor(foeRequest, {
        SessionFixture.attackChoice(foeActor, 0, SessionFixture.positionTarget(2)),
      })
    ),
    "the revealing strike binds"
  )
  session:advance(1024)
  -- The foe outruns the holder, so only the foe carries a record here.
  Assert.deepEqual(
    (session:capture().lastHits --[[@as table<integer, unknown>]])[13],
    { move = "TACKLE", user = 11 },
    "the struck foe carries its received hit"
  )
  local trainerRequest = openRequest(session, "trainer:1")
  local trainerActor = assert(trainerRequest.actors[1], "the trainer request addresses its lead")
  local nextFoeRequest = openRequest(session, "player")
  local nextFoeActor = assert(nextFoeRequest.actors[1], "the opposing request addresses its lead")
  Assert.isTrue(
    session:submit(
      SessionFixture.replyFor(trainerRequest, {
        SessionFixture.attackChoice(trainerActor, 0, SessionFixture.positionTarget(1)),
      })
    ),
    "the holder strike binds"
  )
  Assert.isTrue(
    session:submit(
      SessionFixture.replyFor(nextFoeRequest, { SessionFixture.switchChoice(nextFoeActor, 14) })
    ),
    "the foe withdrawal binds"
  )
  session:advance(1024)
  local received = session:capture().lastHits --[[@as table<integer, unknown>]]
  Assert.isTrue(type(received) == "table", "the session carries a received-hit table")
  Assert.isNil(received[11], "acting without being restruck clears the holder record")
  Assert.isNil(received[13], "withdrawing clears the departed record")
  session:dispose()
end

-- Fresh entries fight unknown again: after the foe reveals a strike
-- the player exchange clears the entering record while the departed
-- record survives, and a later return clears it too.
function T.fresh_entries_fight_unknown_again()
  local contracts = SessionFixture.sessionContracts()
  local first = leveledCombatant(21, 23, "EEVEE", 20)
  local second = leveledCombatant(22, 24, "EEVEE", 20)
  local foe = leveledCombatant(23, 41, "EEVEE", 20)
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, {}),
      { foe },
      { first, second },
      nil,
      { passes = {} }
    )
  )
  local function knownOf(captured)
    local memory = captured.trainerAi --[[@as table<string, unknown>]]
    local controllers = memory.controllers --[[@as table<string, unknown>]]
    local owned = controllers["trainer:1"] --[[@as table<string, unknown>]]
    return owned.knownMoves
  end
  local function answerBoth(attackTurn)
    local trainerReply = session:answerTrainer(openRequest(session, "trainer:1"))
    Assert.equal(trainerReply.choices[1].kind, "attack", "the trainer strikes")
    local playerRequest = openRequest(session, "player")
    local playerActor = assert(playerRequest.actors[1], "the opposing request addresses its lead")
    local choices
    if attackTurn == nil then
      choices = { SessionFixture.attackChoice(playerActor, 0, SessionFixture.positionTarget(2)) }
    else
      choices = { SessionFixture.switchChoice(playerActor, attackTurn) }
    end
    Assert.isTrue(session:submit(trainerReply), "the trainer reply binds")
    local ok, err = session:submit(SessionFixture.replyFor(playerRequest, choices))
    Assert.isTrue(ok, "the player reply binds: " .. tostring(err))
    session:advance(1024)
  end
  answerBoth(nil)
  local revealed = knownOf(session:capture()) --[[@as table<integer, unknown>]]
  Assert.deepEqual(revealed[21], { TACKLE = true }, "the opening strike is learned")
  answerBoth(22)
  local exchanged = knownOf(session:capture()) --[[@as table<integer, unknown>]]
  Assert.deepEqual(exchanged[21], { TACKLE = true }, "the departed record survives")
  Assert.isNil(exchanged[22], "the entering record starts unknown")
  answerBoth(21)
  local returned = knownOf(session:capture()) --[[@as table<integer, unknown>]]
  Assert.isNil(returned[21], "the returning record starts unknown again")
  session:dispose()
end

-- Doubles bids pick the highest target: the top bid answers even
-- alone, equal bids break uniformly through one draw, and a
-- target-dependent session answers the weaker line with its strike.
---@param held table pre-answer capture carrying the stream snapshot
---@param count integer answer draws to replay in stream order
---@return integer[] first draw values of the trainer answer
local function answerDraws(held, count)
  local stream = BattleRng.restore(held.rng --[[@as table<string, integer>]])
  local values = {}
  for _ = 1, count do
    values[#values + 1] = stream:nextU16("answer_probe", {})
  end
  return values
end

function T.doubles_bids_pick_the_highest_target()
  local TrainerAi = trainerPolicy()
  local stream = spyStream(FIXED_SEED)
  local target, slot = TrainerAi.selectDoubles({
    { target = 1, slot = 0, score = 100 },
    { target = 2, slot = 1, score = 110 },
  }, stream)
  Assert.equal(target, 2, "the top bid answers")
  Assert.equal(slot, 1, "the top bid names its move")
  Assert.equal(stream:capture().calls, 1, "the lone leader still spends its selection draw")
  local tied = {
    { target = 1, slot = 0, score = 110 },
    { target = 2, slot = 1, score = 110 },
  }
  local tieStream = spyStream(FIXED_SEED)
  local tieTarget = TrainerAi.selectDoubles(tied, tieStream)
  local probe = BattleRng.new(FIXED_SEED)
  local expected = probe:nextU16("doubles_probe", { tied = 2 })
  Assert.equal(tieTarget, tied[(expected % 2) + 1].target, "tied bids break over the draw remainder")
  Assert.equal(TrainerAi.selectDoubles(tied, spyStream(FIXED_SEED)), tieTarget, "a fixed seed replays the bid")
  local Executor = sessionOwner()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(31, 23, "CHIKORITA", 20)
  lead.mon.moves = {
    { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
    { move = "TACKLE", pp = 35, ppUps = 0 },
  }
  local first = leveledCombatant(32, 41, "TOTODILE", 10)
  local second = leveledCombatant(33, 42, "EEVEE", 10)
  local seeds = { lead, first, second }
  local striker = SessionFixture.participant(2, 2, "trainer:1", { lead })
  striker.context = { aiPasses = { "ai_pass_0" } }
  local scenario = {
    ruleset = Executor.RULESET,
    format = "double",
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "player", { first, second }),
      striker,
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, first.id),
      SessionFixture.position(2, 1, { 1 }, second.id),
      SessionFixture.position(3, 2, { 2 }, lead.id),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = NATIVE_SEED },
    formatState = {},
    moveFacts = scenarioMoveFacts({ "TACKLE", "RAZOR_LEAF" }),
    speciesFacts = scenarioSpeciesFacts(seeds),
    itemFacts = {},
  }
  local session = waitingSession(contracts, scenario)
  local held = session:capture()
  local values = answerDraws(held, 16)
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(#reply.choices, 1, "the lone trainer actor answers")
  Assert.equal(reply.choices[1].kind, "attack", "the doubles evaluation strikes")
  local target = ({ 1, 2 })[(values[16] % 2) + 1]
  local pick = values[10]
  if target == 2 then
    pick = values[15]
  end
  Assert.equal(reply.choices[1].payload.target.position, target, "the tied bid answers the drawn target")
  Assert.equal(
    reply.choices[1].payload.moveSlot,
    ({ 0, 1 })[(pick % 2) + 1],
    "the tied slots answer the drawn move"
  )
  Assert.equal(
    session:capture().rng.calls - held.rng.calls,
    16,
    "per-target initialization feeds two picks and one selection behind the leading draws"
  )
  session:dispose()
  local replayed = Executor.restore(held, trainerContent())
  Assert.deepEqual(
    replayed:answerTrainer(openRequest(replayed, "trainer:1")),
    reply,
    "a fixed seed replays the doubles answer"
  )
  replayed:dispose()
end

-- Doubles vector move facts with source move identities and real effects:
-- TACKLE carries effect 0, SWORDS_DANCE effect 50, HELPING_HAND effect 176,
-- and RAZOR_LEAF effect 43. Ranges ride along for target validation.
---@return table<string, table<string, unknown>> move facts with real effects and ranges
local function doublesMoveFacts()
  return {
    TACKLE = {
      nativeId = 33,
      effect = 0,
      power = 35,
      moveType = "normal",
      category = "physical",
      accuracy = 95,
      range = 0,
    },
    SWORDS_DANCE = {
      nativeId = 14,
      effect = 50,
      power = 0,
      moveType = "normal",
      category = "status",
      accuracy = 0,
      range = 16,
    },
    HELPING_HAND = {
      nativeId = 270,
      effect = 176,
      power = 0,
      moveType = "normal",
      category = "status",
      accuracy = 0,
      range = 256,
    },
    RAZOR_LEAF = {
      nativeId = 75,
      effect = 43,
      power = 55,
      moveType = "grass",
      category = "physical",
      accuracy = 95,
      range = 4,
    },
    STRUGGLE = { power = 50, accuracy = 100, category = "physical", moveType = "normal", priority = 0 },
  }
end

---@param combatant table combatant seed under ability assignment
local function runAway(combatant)
  (combatant.mon --[[@as table<string, unknown>]]).ability = "RUN_AWAY"
end

---@param lead table answering trainer lead seed under scenario construction
---@param mate table? passive ally seed on its own controller, absent for lone-lead lines
---@param foeA table first opposing seed
---@param foeB table second opposing seed
---@param seed integer stream seed for the scenario
---@return table detached double battle setup for the vector
local function doublesVectorScenario(lead, mate, foeA, foeB, seed)
  local Executor = sessionOwner()
  local first = SessionFixture.participant(2, 2, "trainer:1", { lead })
  first.context = { aiPasses = {} }
  local participants = {
    SessionFixture.participant(1, 1, "player", { foeA, foeB }),
    first,
  }
  local positions = {
    SessionFixture.position(1, 1, { 1 }, foeA.id),
    SessionFixture.position(2, 1, { 1 }, foeB.id),
    SessionFixture.position(3, 2, { 2 }, lead.id),
  }
  local sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) }
  local seeds = { lead, foeA, foeB }
  if mate ~= nil then
    local second = SessionFixture.participant(3, 2, "trainer:2", { mate })
    second.context = { aiPasses = {} }
    participants[#participants + 1] = second
    positions[#positions + 1] = SessionFixture.position(4, 2, { 3 }, mate.id --[[@as integer]])
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2, 3 }) }
    seeds[#seeds + 1] = mate
  end
  return {
    ruleset = Executor.RULESET,
    format = "double",
    sides = sides,
    participants = participants,
    positions = positions,
    inventories = {},
    environment = { weather = "none" },
    random = { seed = seed },
    formatState = {},
    moveFacts = doublesMoveFacts(),
    speciesFacts = scenarioSpeciesFacts(seeds),
    itemFacts = {},
  }
end

local VECTOR_SEEDS = {}
for offset = 0, 7 do
  VECTOR_SEEDS[#VECTOR_SEEDS + 1] = NATIVE_SEED + offset
end

---@param contracts table session owners under test driving
---@param seeds integer[] candidate stream seeds in trial order
---@param build fun(seed: integer): table detached battle setup under test driving
---@param total integer answer draws replayed per trial
---@param accept fun(values: integer[]): boolean true when the trace branches as designed
---@return table live native session waiting on the designed branch
---@return table pre-answer capture behind the branch
---@return integer[] answer draw values behind the branch
local function sessionWithDoublesBranch(contracts, seeds, build, total, accept)
  for _, seed in ipairs(seeds) do
    local session = waitingSession(contracts, build(seed))
    local held = session:capture()
    local values = answerDraws(held, total)
    if accept(values) then
      return session, held, values
    end
    session:dispose()
  end
  error("no candidate seed takes the designed doubles branch")
end

-- Doubles forces the doubles pass without a stored mark: with no stored
-- passes at all, the setup slot still draws its attacker-side and
-- target-side effect gates and loses outright to the plain strike, so the
-- answer costs two initializations, four pass draws, two picks, and one
-- selection while the tied top bids break over the final draw.
function T.doubles_forces_the_doubles_pass_without_a_stored_mark()
  local contracts = SessionFixture.sessionContracts()
  local function build(seed)
    local lead = leveledCombatant(31, 23, "CHIKORITA", 20)
    lead.mon.moves = {
      { move = "TACKLE", pp = 35, ppUps = 0 },
      { move = "SWORDS_DANCE", pp = 30, ppUps = 0 },
    }
    runAway(lead)
    local foeA = leveledCombatant(32, 41, "TOTODILE", 10)
    runAway(foeA)
    local foeB = leveledCombatant(33, 42, "EEVEE", 10)
    runAway(foeB)
    return doublesVectorScenario(lead, nil, foeA, foeB, seed)
  end
  local session, held, values = sessionWithDoublesBranch(contracts, VECTOR_SEEDS, build, 20, function(draws)
    return draws[10] % 256 >= 50
      and draws[11] % 256 >= 50
      and draws[17] % 256 >= 50
      and draws[18] % 256 >= 50
  end)
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "attack", "the doubles evaluation strikes")
  Assert.equal(reply.choices[1].payload.moveSlot, 0, "the forced pass demotes the setup slot")
  Assert.equal(
    reply.choices[1].payload.target.position,
    ({ 1, 2 })[(values[20] % 2) + 1],
    "tied bids break over the final draw"
  )
  Assert.equal(
    session:capture().rng.calls - held.rng.calls,
    20,
    "two candidates cost five leading draws, two initializations, four pass draws, two picks, and one selection"
  )
  session:dispose()
  local replayed = sessionOwner().restore(held, trainerContent())
  Assert.deepEqual(
    replayed:answerTrainer(openRequest(replayed, "trainer:1")),
    reply,
    "a fixed seed replays the doubles answer"
  )
  replayed:dispose()
end

-- Doubles scratch initializes once per candidate: with an ally on the
-- field the evaluation pays a fresh four-draw initialization for each of
-- the three candidates plus only the pass draws the source reaches, and
-- the losing ally bid leaves the foe tie to the final draw.
function T.doubles_scratch_initializes_once_per_candidate()
  local contracts = SessionFixture.sessionContracts()
  local function build(seed)
    local lead = leveledCombatant(31, 23, "CHIKORITA", 20)
    lead.mon.moves = {
      { move = "TACKLE", pp = 35, ppUps = 0 },
      { move = "SWORDS_DANCE", pp = 30, ppUps = 0 },
    }
    runAway(lead)
    local mate = leveledCombatant(34, 24, "EEVEE", 20)
    runAway(mate)
    local foeA = leveledCombatant(32, 41, "TOTODILE", 10)
    runAway(foeA)
    local foeB = leveledCombatant(33, 42, "EEVEE", 10)
    runAway(foeB)
    return doublesVectorScenario(lead, mate, foeA, foeB, seed)
  end
  local session = waitingSession(contracts, build(NATIVE_SEED))
  local held = session:capture()
  local values = answerDraws(held, 25)
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "attack", "the doubles evaluation strikes")
  local target = ({ 1, 2 })[(values[25] % 2) + 1]
  local pick = values[12]
  if target == 2 then
    pick = values[19]
  end
  Assert.equal(
    reply.choices[1].payload.target.position,
    target,
    "the foe tie breaks over the final draw"
  )
  Assert.equal(
    reply.choices[1].payload.moveSlot,
    ({ 0, 1 })[(pick % 2) + 1],
    "each foe pick breaks its own slot tie"
  )
  Assert.equal(
    session:capture().rng.calls - held.rng.calls,
    25,
    "three candidates cost five leading draws, three initializations, four pass draws, three picks, and one selection"
  )
  session:dispose()
  local replayed = sessionOwner().restore(held, trainerContent())
  Assert.deepEqual(
    replayed:answerTrainer(openRequest(replayed, "trainer:1")),
    reply,
    "a fixed seed replays the doubles answer"
  )
  replayed:dispose()
end

-- Ally support targeting can win the bidding: the helping slot scores
-- above both foe lines against the wounded ally while the plain strike
-- answers the foe lines, so the ally bid takes the decision outright.
function T.doubles_ally_support_targeting_can_win_the_bidding()
  local contracts = SessionFixture.sessionContracts()
  local function build(seed)
    local lead = leveledCombatant(31, 23, "CHIKORITA", 20)
    lead.mon.moves = {
      { move = "HELPING_HAND", pp = 20, ppUps = 0 },
      { move = "TACKLE", pp = 35, ppUps = 0 },
    }
    runAway(lead)
    local mate = leveledCombatant(34, 24, "EEVEE", 20);
    (mate.mon --[[@as table<string, unknown>]]).condition.currentHp = 4
    runAway(mate)
    local foeA = leveledCombatant(32, 41, "TOTODILE", 10)
    runAway(foeA)
    local foeB = leveledCombatant(33, 42, "EEVEE", 10)
    runAway(foeB)
    return doublesVectorScenario(lead, mate, foeA, foeB, seed)
  end
  local session, held, _ = sessionWithDoublesBranch(contracts, VECTOR_SEEDS, build, 22, function(draws)
    return draws[20] % 256 >= 64
  end)
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "attack", "the doubles evaluation strikes")
  Assert.equal(reply.choices[1].payload.target.position, 4, "the ally bid answers the ally position")
  Assert.equal(reply.choices[1].payload.moveSlot, 0, "the helping slot answers the ally")
  Assert.equal(
    session:capture().rng.calls - held.rng.calls,
    22,
    "three candidates cost five leading draws, three initializations, one pass draw, three picks, and one selection"
  )
  session:dispose()
  local replayed = sessionOwner().restore(held, trainerContent())
  Assert.deepEqual(
    replayed:answerTrainer(openRequest(replayed, "trainer:1")),
    reply,
    "a fixed seed replays the doubles answer"
  )
  replayed:dispose()
end

-- Tied top bids consume the final selection draw in source order: quiet
-- lines tie on every candidate, the ally bid loses, and the foe tie breaks
-- over the draw after three initializations and three picks.
function T.doubles_tied_bids_consume_the_final_selection_draw()
  local contracts = SessionFixture.sessionContracts()
  local function build(seed)
    local lead = leveledCombatant(31, 23, "CHIKORITA", 20)
    lead.mon.moves = {
      { move = "TACKLE", pp = 35, ppUps = 0 },
      { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
    }
    runAway(lead)
    local mate = leveledCombatant(34, 24, "EEVEE", 20)
    runAway(mate)
    local foeA = leveledCombatant(32, 41, "TOTODILE", 10)
    runAway(foeA)
    local foeB = leveledCombatant(33, 42, "EEVEE", 10)
    runAway(foeB)
    return doublesVectorScenario(lead, mate, foeA, foeB, seed)
  end
  local session = waitingSession(contracts, build(NATIVE_SEED))
  local held = session:capture()
  local values = answerDraws(held, 21)
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "attack", "the doubles evaluation strikes")
  local target = ({ 1, 2 })[(values[21] % 2) + 1]
  local pick = values[10]
  if target == 2 then
    pick = values[15]
  end
  Assert.equal(
    reply.choices[1].payload.target.position,
    target,
    "the foe tie breaks over the final draw"
  )
  Assert.equal(
    reply.choices[1].payload.moveSlot,
    ({ 0, 1 })[(pick % 2) + 1],
    "the winning pick breaks its own slot tie"
  )
  Assert.equal(
    session:capture().rng.calls - held.rng.calls,
    21,
    "three quiet candidates cost five leading draws, three initializations, three picks, and one selection"
  )
  session:dispose()
  local replayed = sessionOwner().restore(held, trainerContent())
  Assert.deepEqual(
    replayed:answerTrainer(openRequest(replayed, "trainer:1")),
    reply,
    "a fixed seed replays the doubles answer"
  )
  replayed:dispose()
end



-- The doubles pass draws in source order per slot: initialization precedes
-- flag evaluation, the setup slot spends its attacker-side and target-side
-- effect gates, and scores follow the rolls exactly.
function T.doubles_pass_draws_follow_the_source_order_per_slot()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local slots = {
    slotWith({ key = "TACKLE" }),
    slotWith({
      key = "SWORDS_DANCE",
      id = 14,
      moveType = "normal",
      power = 0,
      category = "status",
      accuracy = 0,
      effect = 50,
    }),
    slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }),
    slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }),
  }
  local extra = {
    doublesBattlers = {
      atk = 1,
      tgt = 0,
      records = {
        [0] = { hp = 100, maxHp = 100 },
        [1] = { hp = 100, maxHp = 100 },
      },
    },
    liveBattlers = { [0] = true, [1] = true },
  }
  local stream = spyStream(FIXED_SEED)
  local scored =
    TrainerAi.scoreSlots(chart, slots, fighterWith({}), fighterWith({}), 100, { 7 }, false, stream, extra)
  Assert.deepEqual(
    stream:drawLabels(),
    { "score_init_0", "score_init_1", "score_init_2", "score_init_3", "program_chance", "program_chance" },
    "initialization precedes the two effect gates"
  )
  local probe = BattleRng.new(FIXED_SEED)
  local rolls = {}
  for _ = 1, 6 do
    rolls[#rolls + 1] = probe:nextU16("order_probe", {})
  end
  local setup = 100
  if rolls[5] % 256 >= 50 then
    setup = setup - 2
  end
  if rolls[6] % 256 >= 50 then
    setup = setup - 2
  end
  Assert.equal(scored[1].score, 100, "the plain strike survives the foe line")
  Assert.equal(scored[2].score, setup, "the setup slot pays each reached gate")
  Assert.equal(scored[3].score, 0, "spent slots stay excluded")
end

-- The ally branch scores helping hands above the baseline: against a
-- wounded ally the helping slot spends its single gate for a bonus while
-- the setup slot falls through to the ally penalty.
function T.doubles_ally_branch_scores_helping_hands_above_the_baseline()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local slots = {
    slotWith({
      key = "HELPING_HAND",
      id = 270,
      moveType = "normal",
      power = 0,
      category = "status",
      accuracy = 0,
      effect = 176,
    }),
    slotWith({
      key = "SWORDS_DANCE",
      id = 14,
      moveType = "normal",
      power = 0,
      category = "status",
      accuracy = 0,
      effect = 50,
    }),
    slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }),
    slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }),
  }
  local extra = {
    doublesBattlers = {
      atk = 1,
      tgt = 3,
      records = {
        [1] = { hp = 100, maxHp = 100 },
        [3] = { hp = 4, maxHp = 50 },
      },
    },
    liveBattlers = { [1] = true, [3] = true },
    switchIn = { [1] = false, [3] = false },
  }
  local stream = spyStream(FIXED_SEED)
  local scored = TrainerAi.scoreSlots(chart, slots, fighterWith({}), fighterWith({}), 4, { 7 }, false, stream, extra)
  Assert.deepEqual(
    stream:drawLabels(),
    { "score_init_0", "score_init_1", "score_init_2", "score_init_3", "program_chance" },
    "initialization precedes the single helping gate"
  )
  local probe = BattleRng.new(FIXED_SEED)
  local rolls = {}
  for _ = 1, 5 do
    rolls[#rolls + 1] = probe:nextU16("order_probe", {})
  end
  local helping = 100
  if rolls[5] % 256 >= 64 then
    helping = helping + 2
  else
    helping = helping - 1
  end
  Assert.equal(scored[1].score, helping, "the helping slot takes the ally bonus")
  Assert.equal(scored[2].score, 70, "other slots pay the ally penalty")
end

-- Fainted candidates never bid: with one foe down the evaluation pays for
-- the standing foe and the ally only, and the answer never names the
-- fainted position.
function T.doubles_fainted_candidates_never_bid()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(31, 23, "CHIKORITA", 20)
  lead.mon.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
  }
  runAway(lead)
  local mate = leveledCombatant(34, 24, "EEVEE", 20)
  runAway(mate)
  local foeA = leveledCombatant(32, 41, "TOTODILE", 10)
  runAway(foeA)
  local foeB = leveledCombatant(33, 42, "EEVEE", 10);
  (foeB.mon --[[@as table<string, unknown>]]).condition.currentHp = 0
  runAway(foeB)
  local session = waitingSession(contracts, doublesVectorScenario(lead, mate, foeA, foeB, NATIVE_SEED))
  local held = session:capture()
  local values = answerDraws(held, 16)
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "attack", "the doubles evaluation strikes")
  Assert.equal(reply.choices[1].payload.target.position, 1, "the standing foe answers alone")
  Assert.equal(
    reply.choices[1].payload.moveSlot,
    ({ 0, 1 })[(values[10] % 2) + 1],
    "the standing pick breaks its own slot tie"
  )
  Assert.equal(
    session:capture().rng.calls - held.rng.calls,
    16,
    "two live candidates cost five leading draws, two initializations, two picks, and one selection"
  )
  session:dispose()
  local replayed = sessionOwner().restore(held, trainerContent())
  Assert.deepEqual(
    replayed:answerTrainer(openRequest(replayed, "trainer:1")),
    reply,
    "a fixed seed replays the doubles answer"
  )
  replayed:dispose()
end

-- User-side winners aimed across the field retarget to the holder: the
-- single-target user-side line wins every bid and answers the own position.
function T.doubles_user_side_winners_retarget_to_the_holder()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(31, 23, "CHIKORITA", 20)
  lead.mon.moves = {
    { move = "ACUPRESSURE", pp = 30, ppUps = 0 },
    { move = "TACKLE", pp = 0, ppUps = 0 },
  }
  runAway(lead)
  local foeA = leveledCombatant(32, 41, "TOTODILE", 10)
  runAway(foeA)
  local foeB = leveledCombatant(33, 42, "EEVEE", 10)
  runAway(foeB)
  local facts = doublesMoveFacts()
  facts.ACUPRESSURE =
    { nativeId = 367, effect = 226, power = 0, moveType = "normal", category = "status", accuracy = 0, range = 512 }
  local scenario = doublesVectorScenario(lead, nil, foeA, foeB, NATIVE_SEED)
  scenario.moveFacts = facts
  local session = waitingSession(contracts, scenario)
  local held = session:capture()
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "attack", "the doubles evaluation strikes")
  Assert.equal(reply.choices[1].payload.target.position, 3, "the user-side winner answers the holder")
  Assert.equal(reply.choices[1].payload.moveSlot, 0, "the user-side slot answers")
  Assert.equal(
    session:capture().rng.calls - held.rng.calls,
    20,
    "two candidates cost five leading draws, two initializations, four pass draws, two picks, and one selection"
  )
  session:dispose()
  local replayed = sessionOwner().restore(held, trainerContent())
  Assert.deepEqual(
    replayed:answerTrainer(openRequest(replayed, "trainer:1")),
    reply,
    "a fixed seed replays the doubles answer"
  )
  replayed:dispose()
end

-- Non-ghost Curse winners retarget to the holder: the quiet curse lines tie
-- on every candidate and the tied winner answers the own position.
function T.doubles_non_ghost_curse_winners_retarget_to_the_holder()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(31, 23, "CHIKORITA", 20)
  lead.mon.moves = {
    { move = "CURSE", pp = 10, ppUps = 0 },
    { move = "TACKLE", pp = 0, ppUps = 0 },
  }
  runAway(lead)
  local foeA = leveledCombatant(32, 41, "TOTODILE", 10)
  runAway(foeA)
  local foeB = leveledCombatant(33, 42, "EEVEE", 10)
  runAway(foeB)
  local facts = doublesMoveFacts()
  facts.CURSE =
    { nativeId = 174, effect = 109, power = 0, moveType = "mystery", category = "status", accuracy = 0, range = 0 }
  local scenario = doublesVectorScenario(lead, nil, foeA, foeB, NATIVE_SEED)
  scenario.moveFacts = facts
  local session = waitingSession(contracts, scenario)
  local held = session:capture()
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "attack", "the doubles evaluation strikes")
  Assert.equal(reply.choices[1].payload.target.position, 3, "the curse winner answers the holder")
  Assert.equal(reply.choices[1].payload.moveSlot, 0, "the curse slot answers")
  Assert.equal(
    session:capture().rng.calls - held.rng.calls,
    16,
    "two quiet candidates cost five leading draws, two initializations, two picks, and one selection"
  )
  session:dispose()
  local replayed = sessionOwner().restore(held, trainerContent())
  Assert.deepEqual(
    replayed:answerTrainer(openRequest(replayed, "trainer:1")),
    reply,
    "a fixed seed replays the doubles answer"
  )
  replayed:dispose()
end

-- Membership draws fire per listed effect: same-type preference and
-- unpredictability each draw once for a listed slot and never otherwise.
function T.membership_draws_fire_per_listed_effect()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local user = fighterWith({ types = { "normal" } })
  local foe = fighterWith({ types = { "normal" } })
  local focusPunch = {
    slotWith({ key = "FOCUS_PUNCH", id = 264, moveType = "fighting", power = 150, effect = 170 }),
    slotWith({ key = "TACKLE" }),
    slotWith({ key = "GROWL", id = 45, moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }),
  }
  local stabStream = spyStream(FIXED_SEED)
  TrainerAi.scoreSlots(chart, focusPunch, user, foe, 14, { 3 }, false, stabStream)
  Assert.equal(#stabStream:drawLabels(), 5, "a listed same-type effect draws once")
  local plainStabStream = spyStream(FIXED_SEED)
  TrainerAi.scoreSlots(chart, fourSlots(), user, foe, 14, { 3 }, false, plainStabStream)
  Assert.equal(#plainStabStream:drawLabels(), 4, "an unlisted same-type line draws nothing")
  local leerNine = {
    slotWith({ key = "LEER", id = 43, moveType = "normal", power = 0, category = "status", accuracy = 100, effect = 19 }),
    slotWith({ key = "TACKLE" }),
    slotWith({ key = "GROWL", id = 45, moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }),
  }
  local nineStream = spyStream(FIXED_SEED)
  TrainerAi.scoreSlots(chart, fourSlots(), user, foe, 14, { 9 }, false, nineStream)
  Assert.equal(#nineStream:drawLabels(), 4, "unpredictability draws nothing without its listed effect")
  local nineEffectStream = spyStream(FIXED_SEED)
  TrainerAi.scoreSlots(chart, leerNine, user, foe, 14, { 9 }, false, nineEffectStream)
  Assert.equal(#nineEffectStream:drawLabels(), 5, "a listed unpredictability effect draws once")
end

---@return table<string, unknown> detached generated-style full-serving facts
local function fullRestoreFacts()
  return {
    kind = "medicine",
    restore = { kind = "full" },
    cures = { sleep = true, poison = true, burn = true, freeze = true, paralysis = true },
    revive = "none",
    mood = 0,
  }
end

---@param captured table detached battle capture under inspection
---@return string[] ordered trainer item slots for the single trainer
local function memorySlotsOf(captured)
  local memory = captured.trainerAi --[[@as table<string, unknown>]]
  local controllers = memory.controllers --[[@as table<string, unknown>]]
  local owned = controllers["trainer:1"] --[[@as table<string, unknown>]]
  return owned.slots --[[@as string[] ]]
end

-- Consumed item slots clear in place: with a gap between servings the
-- opening answer takes the first slot, the committed turn leaves later
-- source positions untouched, and the next answer serves the original
-- third slot while stock moves exactly once.
function T.consumed_item_slots_clear_in_place_without_shifting_later_slots()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(1, 23, "EEVEE", 100);
  (lead.mon --[[@as table<string, unknown>]]).condition.currentHp = 4
  local foe = leveledCombatant(2, 41, "EEVEE", 5)
  local superFacts = {
    kind = "medicine",
    restore = { kind = "fixed", amount = 50 },
    cures = { sleep = false, poison = false, burn = false, freeze = false, paralysis = false },
    revive = "none",
    mood = 0,
  }
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, { POTION = 1, SUPER_POTION = 1 }),
      { lead },
      { foe },
      nil,
      {
        passes = {},
        itemFacts = { POTION = { partyUse = potionFacts() }, SUPER_POTION = { partyUse = superFacts } },
        trainerItems = { "POTION", "NONE", "SUPER_POTION", "POTION" },
      }
    )
  )
  local first = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(first.choices[1].kind, "item", "the opening answer serves")
  Assert.equal(first.choices[1].payload.item, "POTION", "the first source slot answers first")
  Assert.deepEqual(
    memorySlotsOf(session:capture()),
    { "NONE", "NONE", "SUPER_POTION", "POTION" },
    "the consumed slot clears in place without shifting later slots"
  )
  local foeRequest = openRequest(session, "player")
  local foeActor = assert(foeRequest.actors[1], "the opposing request addresses its lead")
  Assert.isTrue(session:submit(first), "the opening serving binds")
  local bound, bindErr = session:submit(SessionFixture.replyFor(foeRequest, {
    SessionFixture.attackChoice(foeActor, 0, SessionFixture.positionTarget(2)),
  }))
  Assert.isTrue(bound, "the opposing strike binds: " .. tostring(bindErr))
  session:advance(1024)
  local held = session:capture().inventories["trainer-stock"].quantities
  Assert.equal(held.SUPER_POTION, 1, "the unserved stock stays untouched")
  Assert.equal(held.POTION or 0, 0, "execution consumes the served stock exactly once")
  Assert.deepEqual(
    memorySlotsOf(session:capture()),
    { "NONE", "NONE", "SUPER_POTION", "POTION" },
    "the committed turn keeps the cleared positions"
  )
  local second = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(second.choices[1].kind, "item", "the next turn still serves")
  Assert.equal(second.choices[1].payload.item, "SUPER_POTION", "the original third slot answers next")
  Assert.deepEqual(
    memorySlotsOf(session:capture()),
    { "NONE", "NONE", "NONE", "POTION" },
    "only the newly served slot clears"
  )
  session:dispose()
end

-- Duplicate servings clear independently at their source positions: the
-- opening answer takes the first matching slot, the committed turn keeps
-- the twin slot, and the later turn serves the twin from its original
-- position.
function T.duplicate_item_slots_clear_independently_at_their_source_positions()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(1, 23, "EEVEE", 100);
  (lead.mon --[[@as table<string, unknown>]]).condition.currentHp = 4
  local foe = leveledCombatant(2, 41, "EEVEE", 5)
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, { POTION = 2 }),
      { lead },
      { foe },
      nil,
      {
        passes = {},
        itemFacts = { POTION = { partyUse = potionFacts() } },
        trainerItems = { "POTION", "POTION", "NONE", "NONE" },
      }
    )
  )
  local first = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(first.choices[1].kind, "item", "the opening answer serves")
  Assert.equal(first.choices[1].payload.item, "POTION", "the first matching slot answers first")
  Assert.deepEqual(
    memorySlotsOf(session:capture()),
    { "NONE", "POTION", "NONE", "NONE" },
    "only the first matching position clears"
  )
  local foeRequest = openRequest(session, "player")
  local foeActor = assert(foeRequest.actors[1], "the opposing request addresses its lead")
  Assert.isTrue(session:submit(first), "the opening serving binds")
  local bound, bindErr = session:submit(SessionFixture.replyFor(foeRequest, {
    SessionFixture.attackChoice(foeActor, 0, SessionFixture.positionTarget(2)),
  }))
  Assert.isTrue(bound, "the opposing strike binds: " .. tostring(bindErr))
  session:advance(1024)
  local held = session:capture().inventories["trainer-stock"].quantities
  Assert.equal(held.POTION or 0, 1, "execution consumes exactly one twin serving")
  local second = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(second.choices[1].kind, "item", "the later turn still serves")
  Assert.equal(second.choices[1].payload.item, "POTION", "the twin slot answers from its position")
  Assert.deepEqual(
    memorySlotsOf(session:capture()),
    { "NONE", "NONE", "NONE", "NONE" },
    "the twin position clears on its own turn"
  )
  session:dispose()
end

-- The full low-health serving answers below quarter health: a living
-- holder under the bound takes its source slot, the committed turn
-- restores and cures through the ordinary item path, and a fainted
-- holder never serves it.
function T.full_low_health_servings_answer_below_quarter_health()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(1, 23, "EEVEE", 20);
  (lead.mon --[[@as table<string, unknown>]]).condition.currentHp = 4;
  (lead.mon --[[@as table<string, unknown>]]).condition.effects = { { key = "poison" } }
  local foe = leveledCombatant(2, 41, "EEVEE", 5)
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, { FULL_RESTORE = 1 }),
      { lead },
      { foe },
      nil,
      {
        passes = {},
        itemFacts = { FULL_RESTORE = { partyUse = fullRestoreFacts(), lowHpOnly = true } },
        trainerItems = { "FULL_RESTORE", "NONE", "NONE", "NONE" },
      }
    )
  )
  local maxHp = session:capture().combatants[1].maxHp
  Assert.isTrue(type(maxHp) == "number", "the holder carries its health ceiling")
  Assert.isTrue(4 * 4 < maxHp, "the wound sits below quarter health")
  local first = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(first.choices[1].kind, "item", "the low holder serves")
  Assert.equal(first.choices[1].payload.item, "FULL_RESTORE", "the low-health slot answers")
  Assert.deepEqual(
    memorySlotsOf(session:capture()),
    { "NONE", "NONE", "NONE", "NONE" },
    "the served slot clears in place"
  )
  local foeRequest = openRequest(session, "player")
  local foeActor = assert(foeRequest.actors[1], "the opposing request addresses its lead")
  Assert.isTrue(session:submit(first), "the serving binds")
  local bound, bindErr = session:submit(SessionFixture.replyFor(foeRequest, {
    SessionFixture.attackChoice(foeActor, 0, SessionFixture.positionTarget(2)),
  }))
  Assert.isTrue(bound, "the opposing strike binds: " .. tostring(bindErr))
  session:advance(1024)
  local after = session:capture()
  Assert.equal((after.inventories["trainer-stock"].quantities.FULL_RESTORE or 0), 0, "execution consumes the serving")
  Assert.isTrue(after.combatants[1].hp > 4, "the serving restores through the ordinary item path")
  Assert.deepEqual(after.combatants[1].mon.condition.effects, {}, "the serving cures through the ordinary item path")
  session:dispose()
  local fainted = leveledCombatant(1, 23, "EEVEE", 20);
  (fainted.mon --[[@as table<string, unknown>]]).condition.currentHp = 0
  local faintedSession = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, { FULL_RESTORE = 1 }),
      { fainted },
      { leveledCombatant(2, 41, "EEVEE", 5) },
      nil,
      {
        passes = {},
        itemFacts = { FULL_RESTORE = { partyUse = fullRestoreFacts(), lowHpOnly = true } },
        trainerItems = { "FULL_RESTORE", "NONE", "NONE", "NONE" },
      }
    )
  )
  local faintedAnswer = faintedSession:answerTrainer(openRequest(faintedSession, "trainer:1"))
  Assert.equal(faintedAnswer.choices[1].kind, "attack", "a fainted holder never serves")
  faintedSession:dispose()
end

-- High-health ailments alone never serve the low-health serving: a
-- poisoned holder at full health skips its low-health slot and strikes,
-- leaving slots and stock untouched.
function T.high_health_ailments_alone_never_serve_the_low_health_serving()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(1, 23, "EEVEE", 20);
  (lead.mon --[[@as table<string, unknown>]]).condition.effects = { { key = "poison" } }
  local foe = leveledCombatant(2, 41, "EEVEE", 5)
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, { FULL_RESTORE = 1 }),
      { lead },
      { foe },
      nil,
      {
        passes = {},
        itemFacts = { FULL_RESTORE = { partyUse = fullRestoreFacts(), lowHpOnly = true } },
        trainerItems = { "FULL_RESTORE", "NONE", "NONE", "NONE" },
      }
    )
  )
  local answer = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(answer.choices[1].kind, "attack", "the healthy holder strikes instead of serving")
  Assert.deepEqual(
    memorySlotsOf(session:capture()),
    { "FULL_RESTORE", "NONE", "NONE", "NONE" },
    "no slot clears without a serving"
  )
  Assert.equal(
    session:capture().inventories["trainer-stock"].quantities.FULL_RESTORE,
    1,
    "consideration alone consumes no stock"
  )
  session:dispose()
end

-- Missing move effects fail closed before any draw: scoring names the
-- offending move instead of guessing membership.
function T.missing_effects_fail_closed_before_any_draw()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local bare = slotWith({})
  bare.effect = nil
  local slots = { bare, slotWith({}), slotWith({}), slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }) }
  local stream = spyStream(FIXED_SEED)
  local failure = Assert.throws(function()
    TrainerAi.scoreSlots(chart, slots, fighterWith({}), fighterWith({}), 14, { 2 }, true, stream)
  end, "an effect-less slot fails instead of guessing membership")
  Assert.isTrue(
    string.find(tostring(failure), "effect", 1, true) ~= nil,
    "the failure names the missing effect"
  )
  Assert.equal(#stream:drawLabels(), 0, "the failed evaluation draws nothing")
end

-- Wonder-guard pressure exchanges for a covering reserve: with the foe
-- ability marking wonder guard, a neutral holder, and a reserve whose
-- opening strike is selective, the branch spends exactly one draw and
-- exchanges iff that draw falls in the selective two thirds.
local EXCHANGE_SEEDS = {}
for offset = 0, 7 do
  EXCHANGE_SEEDS[#EXCHANGE_SEEDS + 1] = NATIVE_SEED + offset
end

---@param seed integer stream seed for the scenario under test driving
---@param foeAbility string battle ability carried by the opposing lead
---@return table detached native battle setup with a wonder-guard-shaped gate
local function wonderExchangeScenario(seed, foeAbility)
  local holder = leveledCombatant(11, 23, "EEVEE", 10)
  local reserve = leveledCombatant(12, 24, "CHIKORITA", 10)
  reserve.mon.moves = {
    { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
    { move = "CUT", pp = 30, ppUps = 0 },
  }
  local foe = leveledCombatant(13, 41, "TOTODILE", 10);
  (foe.mon --[[@as table<string, unknown>]]).ability = foeAbility
  return trainerStockScenario(
    SessionFixture.inventory("trainer-stock", { 2 }, {}),
    { holder, reserve },
    { foe },
    { "TACKLE", "RAZOR_LEAF", "CUT" },
    { passes = {}, seed = seed }
  )
end

---@param contracts table session owners under test driving
---@param seeds integer[] candidate stream seeds in trial order
---@param build fun(seed: integer): table detached native battle setup under test driving
---@param predict fun(first: integer): boolean true when the opening gate draw selects the reserve
---@return table live native session waiting on the predicted exchange
---@return table pre-answer capture behind the prediction
local function sessionWithPredictedExchange(contracts, seeds, build, predict)
  for _, seed in ipairs(seeds) do
    local session = waitingSession(contracts, build(seed))
    local held = session:capture()
    local probe = BattleRng.restore(held.rng --[[@as table<string, integer>]])
    if predict(probe:nextU16("exchange_probe", {})) then
      return session, held
    end
    session:dispose()
  end
  error("no candidate seed predicts the exchange")
end

function T.wonder_guard_exchange_answers_a_covering_reserve()
  local contracts = SessionFixture.sessionContracts()
  local function build(seed)
    return wonderExchangeScenario(seed, "WONDER_GUARD")
  end
  local session, held = sessionWithPredictedExchange(contracts, EXCHANGE_SEEDS, build, function(first)
    return first % 3 < 2
  end)
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "switch", "the covering reserve answers the wonder-guard foe")
  Assert.equal(reply.choices[1].payload.replacement, 12, "the selective reserve takes the field")
  Assert.equal(
    session:capture().rng.calls - held.rng.calls,
    1,
    "the exchange spends only its branch draw"
  )
  session:dispose()
end

---@param seed integer stream seed for the scenario under test driving
---@return table detached native battle setup with an all-immune holder line
local function ineffectiveExchangeScenario(seed)
  local holder = leveledCombatant(21, 23, "EEVEE", 10)
  holder.mon.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "QUICK_ATTACK", pp = 30, ppUps = 0 },
  }
  local reserve = leveledCombatant(22, 24, "TOTODILE", 10)
  reserve.mon.moves = {
    { move = "WATER_GUN", pp = 25, ppUps = 0 },
    { move = "SCRATCH", pp = 35, ppUps = 0 },
  }
  local foe = leveledCombatant(23, 41, "SHEDINJA", 5);
  (foe.mon --[[@as table<string, unknown>]]).ability = "RUN_AWAY"
  return trainerStockScenario(
    SessionFixture.inventory("trainer-stock", { 2 }, {}),
    { holder, reserve },
    { foe },
    { "TACKLE", "QUICK_ATTACK", "WATER_GUN", "SCRATCH" },
    { passes = {}, seed = seed }
  )
end

-- Immune-only coverage exchanges for a neutral reserve: with both holder
-- strikes immune and no selective reserve strike, the neutral scan draws
-- once and exchanges on an even draw while the holder strikes otherwise.
function T.ineffective_coverage_exchanges_for_a_neutral_reserve()
  local contracts = SessionFixture.sessionContracts()
  local session, held =
    sessionWithPredictedExchange(contracts, EXCHANGE_SEEDS, ineffectiveExchangeScenario, function(first)
      return first % 2 == 0
    end)
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "switch", "the neutral reserve answers the immune holder line")
  Assert.equal(reply.choices[1].payload.replacement, 22, "the neutral reserve takes the field")
  Assert.equal(
    session:capture().rng.calls - held.rng.calls,
    1,
    "the exchange spends only its branch draw"
  )
  session:dispose()
end

-- Branch draws follow their predicate: the wonder-guard vector always
-- spends its gate draw before continuing, while the same line against an
-- ordinary ability spends none and strikes with selection draws only.
function T.wonder_branch_draws_only_where_the_predicate_holds()
  local contracts = SessionFixture.sessionContracts()
  local session = waitingSession(contracts, wonderExchangeScenario(NATIVE_SEED, "WONDER_GUARD"))
  local held = session:capture()
  local probe = BattleRng.restore(held.rng --[[@as table<string, integer>]])
  local first = probe:nextU16("exchange_probe", {})
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  local delta = session:capture().rng.calls - held.rng.calls
  if first % 3 < 2 then
    Assert.equal(reply.choices[1].kind, "switch", "the predicted exchange answers")
    Assert.equal(delta, 1, "the exchange spends only its branch draw")
  else
    Assert.equal(reply.choices[1].kind, "attack", "the missed branch falls through to the strike")
    Assert.equal(delta, 6, "the missed branch spends its draw plus the strike draws")
  end
  session:dispose()
  local calm = waitingSession(contracts, wonderExchangeScenario(NATIVE_SEED, "RUN_AWAY"))
  local calmHeld = calm:capture()
  local calmReply = calm:answerTrainer(openRequest(calm, "trainer:1"))
  Assert.equal(calmReply.choices[1].kind, "attack", "without the predicate the holder strikes")
  Assert.equal(
    calm:capture().rng.calls - calmHeld.rng.calls,
    5,
    "without the predicate no gate draw fires"
  )
  Assert.isTrue(delta ~= 5, "the predicate vector costs its branch draw either way")
  calm:dispose()
end

-- Early exchanges preempt the stocked cure: a wounded holder with an
-- eligible serving still exchanges when the wonder-guard branch fires,
-- spending exactly one draw with no item or attack selection after it.
function T.early_exchange_preempts_the_stocked_cure()
  local contracts = SessionFixture.sessionContracts()
  local function build(seed)
    local holder = leveledCombatant(11, 23, "EEVEE", 10);
    (holder.mon --[[@as table<string, unknown>]]).condition.currentHp = 4
    local reserve = leveledCombatant(12, 24, "CHIKORITA", 10)
    reserve.mon.moves = {
      { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
      { move = "CUT", pp = 30, ppUps = 0 },
    }
    local foe = leveledCombatant(13, 41, "TOTODILE", 10);
    (foe.mon --[[@as table<string, unknown>]]).ability = "WONDER_GUARD"
    return trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, { POTION = 1 }),
      { holder, reserve },
      { foe },
      { "TACKLE", "RAZOR_LEAF", "CUT" },
      { passes = {}, seed = seed, trainerItems = { "POTION", "NONE", "NONE", "NONE" } }
    )
  end
  local session, held = sessionWithPredictedExchange(contracts, EXCHANGE_SEEDS, build, function(first)
    return first % 3 < 2
  end)
  local heldStock = held.inventories["trainer-stock"].quantities
  Assert.equal(heldStock.POTION, 1, "the session holds a serving the exchange must pass over")
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "switch", "the early exchange wins over the stocked cure")
  Assert.equal(reply.choices[1].payload.replacement, 12, "the selective reserve takes the field")
  Assert.equal(
    session:capture().rng.calls - held.rng.calls,
    1,
    "no later helper, item, or attack draws after the exchange"
  )
  local accepted, acceptErr = session:submit(reply)
  Assert.isTrue(accepted, "the exchange submits: " .. tostring(acceptErr))
  session:dispose()
end

-- Missing ability facts fail the exchange closed: with the opposing
-- ability erased the trap scan cannot evaluate and the answer raises
-- naming the fact instead of guessing stay or switch.
function T.unknown_opposing_ability_fails_the_exchange_closed()
  local contracts = SessionFixture.sessionContracts()
  local holder = leveledCombatant(11, 23, "EEVEE", 10)
  local reserve = leveledCombatant(12, 24, "CHIKORITA", 10)
  local foe = leveledCombatant(13, 41, "TOTODILE", 10);
  (foe.mon --[[@as table<string, unknown>]]).ability = nil
  local session = waitingSession(
    contracts,
    trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, {}),
      { holder, reserve },
      { foe },
      { "TACKLE" },
      { passes = {} }
    )
  )
  local failure = Assert.throws(function()
    session:answerTrainer(openRequest(session, "trainer:1"))
  end, "the exchange needs its opposing ability")
  Assert.isTrue(
    string.find(string.lower(tostring(failure)), "ability", 1, true) ~= nil,
    "the failure names the missing ability fact"
  )
  session:dispose()
end

-- Relief exchanges wake a sleeping holder: asleep at full health with
-- natural cure and no hit history, the opening coin exchanges for the
-- first living reserve while tails falls through to the strike.
function T.relief_coin_exchanges_a_sleeping_holder()
  local contracts = SessionFixture.sessionContracts()
  local function build(seed)
    local holder = leveledCombatant(31, 23, "EEVEE", 20);
    (holder.mon --[[@as table<string, unknown>]]).ability = "NATURAL_CURE"
    ;(holder.mon --[[@as table<string, unknown>]]).condition.effects = { { key = "sleep" } }
    local reserve = leveledCombatant(32, 24, "TOTODILE", 10)
    local foe = leveledCombatant(33, 41, "EEVEE", 10)
    return trainerStockScenario(
      SessionFixture.inventory("trainer-stock", { 2 }, {}),
      { holder, reserve },
      { foe },
      { "TACKLE" },
      { passes = {}, seed = seed }
    )
  end
  local session, held = sessionWithPredictedExchange(contracts, EXCHANGE_SEEDS, build, function(first)
    return first % 2 == 1
  end)
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "switch", "the relief coin answers with the first reserve")
  Assert.equal(reply.choices[1].payload.replacement, 32, "the first living reserve takes the field")
  Assert.equal(
    session:capture().rng.calls - held.rng.calls,
    1,
    "the exchange spends only its branch draw"
  )
  session:dispose()
end

-- Passes whose routine branches have no draw sites still reach routine
-- randomness in ordinary battle states: initialization draws four times in
-- slot order, and every routine command the program executes adds its own
-- program draw afterwards. A pass that never draws beyond initialization
-- executes no routine branch at all.
function T.passes_without_draw_sites_still_reach_routine_randomness()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local states = {
    {
      user = fighterWith({ types = { "normal" } }),
      foe = fighterWith({ types = { "normal" } }),
      foeHp = 14,
      firstTurn = true,
    },
    {
      user = fighterWith({ types = { "water" } }),
      foe = fighterWith({ types = { "fire" } }),
      foeHp = 1,
      firstTurn = false,
    },
    {
      user = fighterWith({ types = { "fighting" } }),
      foe = fighterWith({ types = { "normal", "rock" } }),
      foeHp = 60,
      firstTurn = false,
    },
  }
  local variants = {
    fourSlots(),
    {
      slotWith({ key = "SCREECH", id = 103, moveType = "normal", power = 0, category = "status", accuracy = 100, effect = 7 }),
      slotWith({ key = "TACKLE" }),
      slotWith({ key = "GROWL", id = 45, moveType = "normal", power = 0, category = "status", accuracy = 100 }),
      slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }),
    },
  }
  local members = {
    { hp = 10, maxHp = 10, species = "EEVEE", status = 0, moves = {} },
    { hp = 12, maxHp = 12, species = "EEVEE", status = 0, moves = {} },
  }
  local extra = {
    parties = { [0] = members, [1] = members },
    partyIndex = { [0] = 0, [1] = 0 },
    partyPartner = { [0] = 0, [1] = 0 },
  }
  for _, bit in ipairs({ 1, 5, 6 }) do
    local most = 0
    for _, state in ipairs(states) do
      for _, slots in ipairs(variants) do
        local stream = spyStream(FIXED_SEED)
        TrainerAi.scoreSlots(chart, slots, state.user, state.foe, state.foeHp, { bit }, state.firstTurn, stream, extra)
        if #stream:drawLabels() > most then
          most = #stream:drawLabels()
        end
      end
    end
    Assert.isTrue(most > 4, "pass " .. bit .. " reaches a routine draw in some ordinary state")
  end
end

-- Guarded random commands draw only when reached: paired battle states that
-- differ only in a move effect checked by the pass program consume different
-- draw sequences, because the guard sends execution either through or past
-- the routine random commands. Identical sequences prove the guard never
-- reaches a draw on either path.
function T.guarded_random_commands_draw_only_when_reached()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local user = fighterWith({ types = { "normal" } })
  local foe = fighterWith({ types = { "normal" } })
  local function labelsFor(effect)
    local slots = {
      slotWith({ key = "PROBE", id = 264, moveType = "fighting", power = 150, effect = effect }),
      slotWith({ key = "TACKLE" }),
      slotWith({ key = "GROWL", id = 45, moveType = "normal", power = 0, category = "status", accuracy = 100 }),
      slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }),
    }
    local stream = spyStream(FIXED_SEED)
    TrainerAi.scoreSlots(chart, slots, user, foe, 14, { 6 }, false, stream)
    return stream:drawLabels()
  end
  local differed = false
  for _, pair in ipairs({ { 41, 0 }, { 88, 0 }, { 38, 19 } }) do
    local first = labelsFor(pair[1])
    local second = labelsFor(pair[2])
    if #first ~= #second then
      differed = true
    else
      for index, label in ipairs(first) do
        if second[index] ~= label then
          differed = true
          break
        end
      end
    end
  end
  Assert.isTrue(differed, "an effect guard changes the routine draw sequence")
end

-- The knockout-aware and setup-continuation passes execute genuine branches:
-- traversing states consume routine draws, and their random-gated branches
-- can move scores between seeds. Fully deterministic scores across seeds
-- prove no random branch executed on any traversed path.
function T.knockout_and_setup_passes_execute_genuine_branches()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local states = {
    {
      user = fighterWith({ types = { "water" } }),
      foe = fighterWith({ types = { "fire" } }),
      foeHp = 1,
      firstTurn = false,
    },
    {
      user = fighterWith({ types = { "normal" } }),
      foe = fighterWith({ types = { "rock" } }),
      foeHp = 40,
      firstTurn = false,
    },
    {
      user = fighterWith({ types = { "fighting" } }),
      foe = fighterWith({ types = { "normal", "rock" } }),
      foeHp = 60,
      firstTurn = true,
    },
  }
  local slots = {
    slotWith({ key = "WATER_GUN", id = 55, moveType = "water", power = 40, category = "special", accuracy = 100 }),
    slotWith({ key = "TACKLE" }),
    slotWith({ key = "SCREECH", id = 103, moveType = "normal", power = 0, category = "status", accuracy = 100, effect = 7 }),
    slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }),
  }
  local members = {
    { hp = 10, maxHp = 10, species = "EEVEE", status = 0, moves = {} },
    { hp = 12, maxHp = 12, species = "EEVEE", status = 0, moves = {} },
  }
  local extra = {
    parties = { [0] = members, [1] = members },
    partyIndex = { [0] = 0, [1] = 0 },
    partyPartner = { [0] = 0, [1] = 0 },
    attacker = { ability = "RUN_AWAY" },
    defender = { ability = "RUN_AWAY" },
  }
  local function scoresFor(bit, seed)
    local scored = TrainerAi.scoreSlots(chart, slots, states[1].user, states[1].foe, states[1].foeHp, { bit }, false, spyStream(seed), extra)
    local points = {}
    for index, entry in ipairs(scored) do
      points[index] = entry.score
    end
    return points
  end
  for _, bit in ipairs({ 5, 6 }) do
    local most = 0
    for _, state in ipairs(states) do
      local stream = spyStream(FIXED_SEED)
      TrainerAi.scoreSlots(chart, slots, state.user, state.foe, state.foeHp, { bit }, state.firstTurn, stream, extra)
      if #stream:drawLabels() > most then
        most = #stream:drawLabels()
      end
    end
    Assert.isTrue(most > 4, "pass " .. bit .. " reaches a routine draw in some traversing state")
    local diverged = false
    for _, seed in ipairs({ FIXED_SEED, FIXED_SEED + 1, NATIVE_SEED }) do
      local first = scoresFor(bit, FIXED_SEED)
      local second = scoresFor(bit, seed)
      for index, points in ipairs(first) do
        if second[index] ~= points then
          diverged = true
          break
        end
      end
      if diverged then
        break
      end
    end
    Assert.isTrue(diverged, "pass " .. bit .. " moves scores between seeds on some traversing state")
  end
end

-- Rejected flag bits consume no draws: requesting a bit without program data
-- fails before initialization instead of answering from an empty program.
function T.rejected_flags_consume_no_draws()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  for _, bit in ipairs({ 4, 8 }) do
    local stream = spyStream(FIXED_SEED)
    local failure = Assert.throws(function()
      TrainerAi.scoreSlots(
        chart,
        fourSlots(),
        fighterWith({ types = { "grass" } }),
        fighterWith({ types = { "rock", "ground" } }),
        14,
        { bit },
        false,
        stream
      )
    end, "flag " .. bit .. " fails instead of answering from an empty program")
    Assert.isTrue(string.find(tostring(failure), tostring(bit), 1, true) ~= nil, "the failure names the flag")
    Assert.equal(#stream:drawLabels(), 0, "the rejected flag draws nothing")
  end
end

-- Fixed-damage strikes run the staged pipeline: a scored slot carrying a
-- fixed-damage identity evaluates its staged amount through the type
-- pipeline instead of raising a raw error, leaving the remaining slots on
-- the shared baseline.
function T.fixed_damage_strikes_run_the_staged_pipeline()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local user = fighterWith({ types = { "normal" } })
  local foe = fighterWith({ types = { "normal" } })
  local slots = {
    slotWith({
      key = "SONIC_BOOM",
      id = 49,
      moveType = "normal",
      power = 35,
      category = "special",
      accuracy = 90,
    }),
    slotWith({ key = "TACKLE", id = 34 }),
    slotWith({ key = "GROWL", id = 45, moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }),
  }
  local stream = spyStream(FIXED_SEED)
  local scored = TrainerAi.scoreSlots(chart, slots, user, foe, 14, { 0 }, false, stream)
  Assert.deepEqual(
    { scored[1].score, scored[2].score, scored[3].score, scored[4].score },
    { 100, 100, 100, 0 },
    "the fixed-damage slot follows the unlisted path without error"
  )
  Assert.equal(#stream:drawLabels(), 4, "the fixed-damage evaluation draws nothing extra")
end

-- Accuracy-gated strikes answer through live stages: a trainer lead
-- carrying an accuracy-lowering strike resolves its stage check against
-- the projected battle stages and answers with an attack instead of
-- failing on missing stage facts.
function T.accuracy_gated_strikes_answer_through_live_stages()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(1, 23, "EEVEE", 5)
  lead.mon.moves = {
    { move = "SAND_ATTACK", pp = 15, ppUps = 0 },
    { move = "TACKLE", pp = 35, ppUps = 0 },
  }
  local foe = leveledCombatant(2, 41, "EEVEE", 5)
  local scenario = trainerStockScenario(
    SessionFixture.inventory("trainer-stock", { 2 }, {}),
    { lead },
    { foe },
    { "SAND_ATTACK", "TACKLE" },
    { passes = { "ai_pass_0", "ai_pass_1" } }
  )
  scenario.moveFacts.SAND_ATTACK.effect = 23
  local session = waitingSession(contracts, scenario)
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "attack", "the accuracy check resolves and the lead strikes")
  session:dispose()
end

-- The draining-effect block scores through its own damage-class gate:
-- with a grass drainer facing a resisting foe the class gate takes and a
-- single chance roll decides between holding baseline and a three point
-- deduction, while plain strikes walk the whole dispatch ladder without
-- drawing. A second seed takes the gate the other way.
function T.draining_strike_routes_through_its_own_effect_block()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local user = fighterWith({ types = { "grass" } })
  local foe = fighterWith({ types = { "fire" } })
  local slots = {
    slotWith({
      key = "GIGA_DRAIN",
      id = 202,
      moveType = "grass",
      power = 60,
      category = "special",
      accuracy = 100,
      effect = 3,
    }),
    slotWith({ key = "TACKLE" }),
    slotWith({ key = "GROWL", id = 45, moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }),
  }
  local stream = spyStream(FIXED_SEED)
  local scored = TrainerAi.scoreSlots(chart, slots, user, foe, 14, { 1 }, false, stream)
  Assert.deepEqual(
    { scored[1].score, scored[2].score, scored[3].score, scored[4].score },
    { 97, 100, 100, 0 },
    "the resisted drain pays three points on the high roll"
  )
  Assert.deepEqual(
    stream:drawLabels(),
    { "score_init_0", "score_init_1", "score_init_2", "score_init_3", "program_chance" },
    "only the reached block draws beyond initialization"
  )
  local probe = BattleRng.new(FIXED_SEED)
  local expected = {}
  for _ = 1, 5 do
    expected[#expected + 1] = probe:nextU16("drain_probe", {})
  end
  Assert.deepEqual(stream:drawValues(), expected, "draws follow the shared stream head in order")
  local kindStream = spyStream(FIXED_SEED + 1)
  local kind = TrainerAi.scoreSlots(chart, slots, user, foe, 14, { 1 }, false, kindStream)
  Assert.deepEqual(
    { kind[1].score, kind[2].score, kind[3].score, kind[4].score },
    { 100, 100, 100, 0 },
    "the low roll leaves the drain at baseline"
  )
  Assert.equal(#kindStream:drawLabels(), 5, "the taken gate still spends its single draw")
end

-- The knockout-side program scores a status slot through both chance
-- gates: falling through both pays three points up front and ten back at
-- the health gate, while taking either gate ends the slot untouched. A
-- second seed takes the later gate and holds baseline with the same draw
-- count, proving the draws sit at the branches.
function T.knockout_program_scores_a_status_slot_through_both_chance_gates()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local user = fighterWith({ types = { "water" } })
  local foe = fighterWith({ types = { "fire" } })
  local slots = {
    slotWith({ key = "WATER_GUN", id = 55, moveType = "water", power = 40, category = "special", accuracy = 100 }),
    slotWith({ key = "TACKLE" }),
    slotWith({
      key = "SCREECH",
      id = 103,
      moveType = "normal",
      power = 0,
      category = "status",
      accuracy = 100,
      effect = 7,
    }),
    slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }),
  }
  local members = {
    { hp = 10, maxHp = 10, species = "EEVEE", status = 0, moves = {} },
    { hp = 12, maxHp = 12, species = "EEVEE", status = 0, moves = {} },
  }
  local extra = {
    parties = { [0] = members, [1] = members },
    partyIndex = { [0] = 0, [1] = 0 },
    partyPartner = { [0] = 0, [1] = 0 },
    attacker = { ability = "RUN_AWAY" },
    defender = { ability = "RUN_AWAY" },
  }
  local stream = spyStream(NATIVE_SEED)
  local scored = TrainerAi.scoreSlots(chart, slots, user, foe, 1, { 5 }, false, stream, extra)
  Assert.deepEqual(
    { scored[1].score, scored[2].score, scored[3].score, scored[4].score },
    { 100, 100, 93, 0 },
    "both gates fall through to the three-up-ten-down line"
  )
  Assert.deepEqual(
    stream:drawLabels(),
    {
      "score_init_0",
      "score_init_1",
      "score_init_2",
      "score_init_3",
      "program_chance",
      "program_chance",
    },
    "initialization precedes the two reached gates"
  )
  local probe = BattleRng.new(NATIVE_SEED)
  local expected = {}
  for _ = 1, 6 do
    expected[#expected + 1] = probe:nextU16("knockout_probe", {})
  end
  Assert.deepEqual(stream:drawValues(), expected, "draws follow the shared stream head in order")
  local heldStream = spyStream(FIXED_SEED)
  local held = TrainerAi.scoreSlots(chart, slots, user, foe, 1, { 5 }, false, heldStream, extra)
  Assert.deepEqual(
    { held[1].score, held[2].score, held[3].score, held[4].score },
    { 100, 100, 100, 0 },
    "the later gate ends the slot untouched"
  )
  Assert.equal(#heldStream:drawLabels(), 6, "the taken gate still spends its own draw")
end

-- A heavy halving-effect strike still takes the status path: the native
-- matchup tables leave effect seven at zero even at two hundred power, so
-- the strike scores through the same gates as a status move and the staged
-- halve-defense arm never fires for it here.
function T.excluded_heavy_strike_takes_the_status_path()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local user = fighterWith({ types = { "normal" } })
  local foe = fighterWith({ types = { "normal" } })
  local slots = {
    slotWith({
      key = "SELFDESTRUCT",
      id = 120,
      moveType = "normal",
      power = 200,
      category = "physical",
      accuracy = 100,
      effect = 7,
    }),
    slotWith({ key = "TACKLE" }),
    slotWith({ key = "TACKLE", id = 34 }),
    slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }),
  }
  local members = {
    { hp = 10, maxHp = 10, species = "EEVEE", status = 0, moves = {} },
    { hp = 12, maxHp = 12, species = "EEVEE", status = 0, moves = {} },
  }
  local extra = {
    parties = { [0] = members, [1] = members },
    partyIndex = { [0] = 0, [1] = 0 },
    partyPartner = { [0] = 0, [1] = 0 },
    attacker = { ability = "RUN_AWAY" },
    defender = { ability = "RUN_AWAY" },
  }
  local stream = spyStream(NATIVE_SEED)
  local scored = TrainerAi.scoreSlots(chart, slots, user, foe, 14, { 5 }, false, stream, extra)
  Assert.deepEqual(
    { scored[1].score, scored[2].score, scored[3].score, scored[4].score },
    { 93, 100, 100, 0 },
    "the excluded strike scores through the status gates"
  )
  Assert.deepEqual(
    stream:drawLabels(),
    {
      "score_init_0",
      "score_init_1",
      "score_init_2",
      "score_init_3",
      "program_chance",
      "program_chance",
    },
    "initialization precedes the two reached gates"
  )
  local probe = BattleRng.new(NATIVE_SEED)
  local expected = {}
  for _ = 1, 6 do
    expected[#expected + 1] = probe:nextU16("halving_probe", {})
  end
  Assert.deepEqual(stream:drawValues(), expected, "draws follow the shared stream head in order")
end

-- The setup-side program leaves quiet lines untouched: damaging slots
-- ranked level fall through to the chance gate and take it on these
-- rolls, then fall through every class gate to the ordered tail, while
-- status slots rejoin the tail directly; no reached command moves points.
function T.setup_program_leaves_quiet_lines_untouched()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local user = fighterWith({ types = { "normal" } })
  local foe = fighterWith({ types = { "normal" } })
  local slots = {
    slotWith({ key = "TACKLE" }),
    slotWith({ key = "TACKLE", id = 34 }),
    slotWith({ key = "GROWL", id = 45, moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }),
  }
  local members = {
    { hp = 10, maxHp = 10, species = "EEVEE", status = 0, moves = {} },
    { hp = 12, maxHp = 12, species = "EEVEE", status = 0, moves = {} },
  }
  local extra = {
    parties = { [0] = members, [1] = members },
    partyIndex = { [0] = 0, [1] = 0 },
    partyPartner = { [0] = 0, [1] = 0 },
    attacker = { ability = "RUN_AWAY" },
    defender = { ability = "RUN_AWAY" },
  }
  local stream = spyStream(FIXED_SEED)
  local scored = TrainerAi.scoreSlots(chart, slots, user, foe, 14, { 6 }, false, stream, extra)
  Assert.deepEqual(
    { scored[1].score, scored[2].score, scored[3].score, scored[4].score },
    { 100, 100, 100, 0 },
    "no reached command moves any quiet slot"
  )
  Assert.deepEqual(
    stream:drawLabels(),
    {
      "score_init_0",
      "score_init_1",
      "score_init_2",
      "score_init_3",
      "program_chance",
      "program_chance",
    },
    "each ranked line spends its own chance gate"
  )
  local probe = BattleRng.new(FIXED_SEED)
  local expected = {}
  for _ = 1, 6 do
    expected[#expected + 1] = probe:nextU16("setup_probe", {})
  end
  Assert.deepEqual(stream:drawValues(), expected, "draws follow the shared stream head in order")
end

-- Every supported flag bit owns at least one named program case below:
-- the table pairs each bit with the tests proving its program path, so a
-- bit without its case fails here instead of passing silently. The bit
-- list is declared here and never read back from the battle modules.
local FLAG_CASES = {
  [0] = {
    "bad_move_program_routes_listed_effects_through_its_gate",
    "fixed_damage_strikes_run_the_staged_pipeline",
  },
  [1] = {
    "faint_seeking_dispatch_reaches_routine_commands_for_listed_effects",
    "draining_strike_routes_through_its_own_effect_block",
    "strong_bench_member_takes_the_party_matchup_jump",
    "quiet_bench_leaves_the_party_matchup_untouched",
    "unresolved_bench_facts_fail_the_matchup_closed",
  },
  [2] = { "effectiveness_program_gates_on_turn_and_effect_list" },
  [3] = { "preference_programs_follow_the_list_gate_draw_shape" },
  [5] = {
    "knockout_program_scores_a_status_slot_through_both_chance_gates",
    "knockout_and_setup_passes_execute_genuine_branches",
    "excluded_heavy_strike_takes_the_status_path",
    "health_restore_berry_leaves_the_damage_preview_untouched",
  },
  [6] = {
    "setup_program_leaves_quiet_lines_untouched",
    "knockout_and_setup_passes_execute_genuine_branches",
  },
  [7] = { "doubles_forces_the_doubles_pass_without_a_stored_mark" },
  [9] = {
    "preference_programs_follow_the_list_gate_draw_shape",
    "membership_draws_fire_per_listed_effect",
  },
}

-- A health-restore berry on the holder leaves the staged damage preview
-- untouched: the source damage calculation reads no berry hold effects,
-- so the holder scores exactly like the bare holder with the same draws,
-- while an unlisted hold effect still fails closed instead of guessing.
function T.health_restore_berry_leaves_the_damage_preview_untouched()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local user = fighterWith({ types = { "water" } })
  local foe = fighterWith({ types = { "fire" } })
  local slots = {
    slotWith({ key = "WATER_GUN", id = 55, moveType = "water", power = 40, category = "special", accuracy = 100 }),
    slotWith({ key = "TACKLE" }),
    slotWith({
      key = "SCREECH",
      id = 103,
      moveType = "normal",
      power = 0,
      category = "status",
      accuracy = 100,
      effect = 7,
    }),
    slotWith({ key = "TACKLE", id = 33, pp = 0, usable = false }),
  }
  local members = {
    { hp = 10, maxHp = 10, species = "EEVEE", status = 0, moves = {} },
    { hp = 12, maxHp = 12, species = "EEVEE", status = 0, moves = {} },
  }
  local function extraWith(item, heldEffects)
    local extra = {
      parties = { [0] = members, [1] = members },
      partyIndex = { [0] = 0, [1] = 0 },
      partyPartner = { [0] = 0, [1] = 0 },
      attacker = { ability = "RUN_AWAY" },
      defender = { ability = "RUN_AWAY" },
    }
    if item ~= 0 then
      extra.attacker.item = item
    end
    if heldEffects ~= nil then
      extra.heldEffects = heldEffects
    end
    return extra
  end
  local plainStream = spyStream(NATIVE_SEED)
  local plain = TrainerAi.scoreSlots(chart, slots, user, foe, 1, { 5 }, false, plainStream, extraWith(0, nil))
  local heldStream = spyStream(NATIVE_SEED)
  local held =
    TrainerAi.scoreSlots(chart, slots, user, foe, 1, { 5 }, false, heldStream, extraWith(158, { [158] = 13 }))
  Assert.deepEqual(
    { held[1].score, held[2].score, held[3].score, held[4].score },
    { plain[1].score, plain[2].score, plain[3].score, plain[4].score },
    "the berry holder scores exactly like the bare holder"
  )
  Assert.deepEqual(heldStream:drawLabels(), plainStream:drawLabels(), "the berry path draws identically")
  Assert.deepEqual(heldStream:drawValues(), plainStream:drawValues(), "the berry path spends identical draws")
  local failure = Assert.throws(function()
    TrainerAi.scoreSlots(
      chart,
      slots,
      user,
      foe,
      1,
      { 5 },
      false,
      spyStream(NATIVE_SEED),
      extraWith(158, { [158] = 1 })
    )
  end, "an unlisted hold effect fails instead of guessing")
  Assert.isTrue(
    string.find(tostring(failure), "held item facts", 1, true) ~= nil,
    "the failure names the held item facts"
  )
end

---@return table four explicit move slots routing the wish block to the party scan
local function matchupSlots()
  return {
    slotWith({
      key = "HEALING_WISH",
      id = 361,
      moveType = "psychic",
      power = 0,
      category = "status",
      accuracy = 100,
      effect = 220,
    }),
    slotWith({ key = "WATER_GUN", id = 55, moveType = "water", power = 40, category = "special", accuracy = 100 }),
    slotWith({ key = "TACKLE" }),
    slotWith({ key = "TACKLE", id = 34, pp = 0, usable = false }),
  }
end

---@return table<string, unknown> shared heavy strike facts beyond the four slots
local function hydroFacts()
  return { effect = 0, power = 120, moveType = "water", category = "special", accuracy = 80, basePp = 5 }
end

---@param bench table<string, unknown> benched member under the attacker party
---@return table explicit evaluation context with the attacker party and the heavy strike maps
local function matchupExtra(bench)
  local own = { hp = 30, maxHp = 30, species = "EEVEE", status = 0, moves = {} }
  local attackerMembers = { own, bench }
  local foeMembers = {
    { hp = 60, maxHp = 60, species = "EEVEE", status = 0, moves = {} },
    { hp = 60, maxHp = 60, species = "EEVEE", status = 0, moves = {} },
  }
  return {
    parties = { [0] = foeMembers, [1] = attackerMembers },
    partyIndex = { [0] = 0, [1] = 0 },
    partyPartner = { [0] = 0, [1] = 0 },
    attacker = { ability = "RUN_AWAY" },
    defender = { ability = "RUN_AWAY" },
    fullMoveById = { [56] = hydroFacts() },
    fullMoveIdByKey = { HYDRO_PUMP = 56 },
  }
end

---@return table<string, unknown> benched member outranking the holder with a heavy strike
local function strongBench()
  return {
    hp = 30,
    maxHp = 30,
    species = "TOTODILE",
    status = 0,
    moves = { { move = "HYDRO_PUMP", pp = 5, ppUps = 0 } },
    ability = "RUN_AWAY",
    ivs = { hp = 10, attack = 10, defense = 10, speed = 10, specialAttack = 10, specialDefense = 10 },
  }
end

-- Seed reaching the party scan: the faint-seeking block routes the wish
-- carrier through the super-effective stay check into the scan on this
-- stream, proven by the taken/quiet divergence below.
local MATCHUP_SEED = 77

-- A benched member with a strictly better staged matchup takes the party
-- matchup jump: the wish carrier routes the faint-seeking block to the
-- party scan, the member's heavy super-effective strike outranks the
-- holder's best, and the taken jump pays one point over the quiet path
-- with exactly one trailing routine draw.
function T.strong_bench_member_takes_the_party_matchup_jump()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local user = fighterWith({ types = { "water" } })
  local foe = fighterWith({ types = { "fire" } })
  local stream = spyStream(MATCHUP_SEED)
  local scored =
    TrainerAi.scoreSlots(chart, matchupSlots(), user, foe, 60, { 1 }, false, stream, matchupExtra(strongBench()))
  Assert.deepEqual(
    { scored[1].score, scored[2].score, scored[3].score, scored[4].score },
    { 102, 100, 100, 0 },
    "the taken jump pays one point on the wish slot"
  )
  Assert.deepEqual(
    stream:drawLabels(),
    {
      "score_init_0",
      "score_init_1",
      "score_init_2",
      "score_init_3",
      "program_chance",
      "program_chance",
      "program_chance",
    },
    "the taken path spends one trailing routine draw"
  )
  local probe = BattleRng.new(MATCHUP_SEED)
  local expected = {}
  for _ = 1, 7 do
    expected[#expected + 1] = probe:nextU16("matchup_probe", {})
  end
  Assert.deepEqual(stream:drawValues(), expected, "draws follow the shared stream head in order")
end

-- A bench that cannot outrank the holder leaves the party scan quiet: a
-- moveless member previews zero and falls through one point below the
-- taken path with one fewer draw, while fainted, egg, and holder-side
-- members stay skipped and score exactly the same.
function T.quiet_bench_leaves_the_party_matchup_untouched()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local user = fighterWith({ types = { "water" } })
  local foe = fighterWith({ types = { "fire" } })
  local function scoredWith(bench)
    local stream = spyStream(MATCHUP_SEED)
    local scored = TrainerAi.scoreSlots(chart, matchupSlots(), user, foe, 60, { 1 }, false, stream, matchupExtra(bench))
    return scored, stream
  end
  local moveless = { hp = 30, maxHp = 30, species = "TOTODILE", status = 0, moves = {} }
  local scored, stream = scoredWith(moveless)
  Assert.deepEqual(
    { scored[1].score, scored[2].score, scored[3].score, scored[4].score },
    { 101, 100, 100, 0 },
    "the quiet path holds one point below the taken jump"
  )
  Assert.deepEqual(
    stream:drawLabels(),
    {
      "score_init_0",
      "score_init_1",
      "score_init_2",
      "score_init_3",
      "program_chance",
      "program_chance",
    },
    "the quiet path skips the taken trailing draw"
  )
  local probe = BattleRng.new(MATCHUP_SEED)
  local expected = {}
  for _ = 1, 6 do
    expected[#expected + 1] = probe:nextU16("matchup_probe", {})
  end
  Assert.deepEqual(stream:drawValues(), expected, "draws follow the shared stream head in order")
  local function quietSignature(bench)
    local runStream = spyStream(MATCHUP_SEED)
    local run = TrainerAi.scoreSlots(chart, matchupSlots(), user, foe, 60, { 1 }, false, runStream, matchupExtra(bench))
    return { run[1].score, run[2].score, run[3].score, run[4].score }, runStream:drawLabels()
  end
  local fainted = strongBench()
  fainted.hp = 0
  local faintedScores, faintedDraws = quietSignature(fainted)
  Assert.deepEqual(faintedScores, { 101, 100, 100, 0 }, "a fainted bench stays skipped")
  Assert.deepEqual(faintedDraws, stream:drawLabels(), "a fainted bench draws like the quiet path")
  local egg = strongBench()
  egg.species = "EGG"
  egg.moves = {}
  local eggScores, eggDraws = quietSignature(egg)
  Assert.deepEqual(eggScores, { 101, 100, 100, 0 }, "an egg bench stays skipped")
  Assert.deepEqual(eggDraws, stream:drawLabels(), "an egg bench draws like the quiet path")
  local holderSide = matchupExtra(moveless)
  holderSide.parties[1][1] = strongBench()
  local holderStream = spyStream(MATCHUP_SEED)
  local holder =
    TrainerAi.scoreSlots(chart, matchupSlots(), user, foe, 60, { 1 }, false, holderStream, holderSide)
  Assert.deepEqual(
    { holder[1].score, holder[2].score, holder[3].score, holder[4].score },
    { 101, 100, 100, 0 },
    "a strong member under the holder slot stays skipped"
  )
  Assert.deepEqual(holderStream:drawLabels(), stream:drawLabels(), "the skipped holder draws like the quiet path")
end

-- A benched member the scan cannot preview fails closed: an unresolvable
-- held key, an unknown move key, and an unknown ability key each raise
-- naming their missing facts instead of guessing a matchup.
function T.unresolved_bench_facts_fail_the_matchup_closed()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local user = fighterWith({ types = { "water" } })
  local foe = fighterWith({ types = { "fire" } })
  local held = strongBench()
  held.heldKey = "MYSTERY_ITEM"
  local heldFailure = Assert.throws(function()
    TrainerAi.scoreSlots(chart, matchupSlots(), user, foe, 60, { 1 }, false, spyStream(MATCHUP_SEED), matchupExtra(held))
  end, "an unresolvable bench held item fails instead of guessing")
  Assert.isTrue(
    string.find(tostring(heldFailure), "held item facts", 1, true) ~= nil,
    "the failure names the held item facts"
  )
  local moved = strongBench()
  moved.moves = { { move = "MYSTERY_MOVE", pp = 5, ppUps = 0 } }
  local movedFailure = Assert.throws(function()
    TrainerAi.scoreSlots(chart, matchupSlots(), user, foe, 60, { 1 }, false, spyStream(MATCHUP_SEED), matchupExtra(moved))
  end, "an unknown bench move fails instead of guessing")
  Assert.isTrue(
    string.find(tostring(movedFailure), "compiled move facts", 1, true) ~= nil,
    "the failure names the compiled move facts"
  )
  local skilled = strongBench()
  skilled.ability = "MYSTERY_ABILITY"
  local skilledFailure = Assert.throws(function()
    TrainerAi.scoreSlots(chart, matchupSlots(), user, foe, 60, { 1 }, false, spyStream(MATCHUP_SEED), matchupExtra(skilled))
  end, "an unknown bench ability fails instead of guessing")
  Assert.isTrue(
    string.find(tostring(skilledFailure), "ability identity", 1, true) ~= nil,
    "the failure names the ability identity"
  )
end

function T.each_supported_flag_bit_maps_to_a_program_case()
  for _, bit in ipairs({ 0, 1, 2, 3, 5, 6, 7, 9 }) do
    local cases = FLAG_CASES[bit]
    Assert.notNil(cases, "flag bit " .. bit .. " names its program cases")
    Assert.isTrue(#cases > 0, "flag bit " .. bit .. " keeps at least one program case")
    for _, name in ipairs(cases) do
      Assert.isTrue(type(T[name]) == "function", "flag bit " .. bit .. " keeps its program case " .. name)
    end
  end
end

-- The normal doubles entry consumes its own selection state before any
-- candidate bids: one opposing-slot draw followed by four initialization
-- draws, then each candidate pays its own initialization and pick with
-- the final selection closing the decision.
---@param session table live native session under test driving
---@param request table open internal trainer request under verification
---@return table reply in the shared decision shape
---@return string[] labels in stream order
local function answerWithLabels(session, request)
  local labels = {} ---@type string[]
  local original = BattleRng.nextU16
  BattleRng.nextU16 = function(self, label, cause)
    labels[#labels + 1] = label
    return original(self, label, cause)
  end
  local ok, reply = pcall(session.answerTrainer, session, request)
  BattleRng.nextU16 = original
  Assert.isTrue(ok, "the trainer answer completes: " .. tostring(reply))
  assert(type(reply) == "table", "the trainer answer replies")
  return reply --[[@as table]], labels
end

function T.doubles_normal_entry_draws_before_candidate_scoring()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(31, 23, "CHIKORITA", 20)
  lead.mon.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
  }
  runAway(lead)
  local mate = leveledCombatant(34, 24, "EEVEE", 20)
  runAway(mate)
  local foeA = leveledCombatant(32, 41, "TOTODILE", 10)
  runAway(foeA)
  local foeB = leveledCombatant(33, 42, "EEVEE", 10)
  runAway(foeB)
  local session = waitingSession(contracts, doublesVectorScenario(lead, mate, foeA, foeB, NATIVE_SEED))
  local held = session:capture()
  local request = openRequest(session, "trainer:1")
  local reply, labels = answerWithLabels(session, request)
  Assert.equal(reply.choices[1].kind, "attack", "the doubles evaluation strikes")
  Assert.deepEqual(labels, {
    "target_foe",
    "score_init_0",
    "score_init_1",
    "score_init_2",
    "score_init_3",
    "score_init_0",
    "score_init_1",
    "score_init_2",
    "score_init_3",
    "selection_roll",
    "score_init_0",
    "score_init_1",
    "score_init_2",
    "score_init_3",
    "selection_roll",
    "score_init_0",
    "score_init_1",
    "score_init_2",
    "score_init_3",
    "selection_roll",
    "doubles_selection",
  }, "the normal entry draws before candidate scoring")
  Assert.equal(
    session:capture().rng.calls - held.rng.calls,
    21,
    "three quiet candidates cost five leading draws plus their own lines"
  )
  session:dispose()
  local replayed = sessionOwner().restore(held, trainerContent())
  Assert.deepEqual(
    replayed:answerTrainer(openRequest(replayed, "trainer:1")),
    reply,
    "a fixed seed replays the doubles answer"
  )
  replayed:dispose()
end

-- A fainted opposing slot never removes the leading selection draw: the
-- entry still chooses between the two opposing slots first and only then
-- falls back to the standing foe, so the answer costs the same leading
-- five draws with two live candidates bidding.
function T.doubles_leading_draw_survives_a_fainted_opposing_slot()
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(31, 23, "CHIKORITA", 20)
  lead.mon.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
  }
  runAway(lead)
  local mate = leveledCombatant(34, 24, "EEVEE", 20)
  runAway(mate)
  local foeA = leveledCombatant(32, 41, "TOTODILE", 10)
  runAway(foeA)
  local foeB = leveledCombatant(33, 42, "EEVEE", 10);
  (foeB.mon --[[@as table<string, unknown>]]).condition.currentHp = 0
  runAway(foeB)
  local session = waitingSession(contracts, doublesVectorScenario(lead, mate, foeA, foeB, NATIVE_SEED))
  local held = session:capture()
  local request = openRequest(session, "trainer:1")
  local reply, labels = answerWithLabels(session, request)
  Assert.equal(reply.choices[1].kind, "attack", "the doubles evaluation strikes")
  Assert.equal(reply.choices[1].payload.target.position, 1, "the standing foe answers alone")
  Assert.deepEqual(labels, {
    "target_foe",
    "score_init_0",
    "score_init_1",
    "score_init_2",
    "score_init_3",
    "score_init_0",
    "score_init_1",
    "score_init_2",
    "score_init_3",
    "selection_roll",
    "score_init_0",
    "score_init_1",
    "score_init_2",
    "score_init_3",
    "selection_roll",
    "doubles_selection",
  }, "the leading draw survives the fainted slot")
  Assert.equal(
    session:capture().rng.calls - held.rng.calls,
    16,
    "two live candidates cost five leading draws plus their own lines"
  )
  session:dispose()
  local replayed = sessionOwner().restore(held, trainerContent())
  Assert.deepEqual(
    replayed:answerTrainer(openRequest(replayed, "trainer:1")),
    reply,
    "a fixed seed replays the doubles answer"
  )
  replayed:dispose()
end

-- A reached compare command decides on the previous move: a stored
-- previous strike stronger than every current slot takes its jump and
-- spends the gate draw, while a level or weaker previous strike falls
-- through with identical results. Both transcribed compare sites are
-- exercised through the existing scoring path.
function T.previous_move_preview_decides_the_compare_jump()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local user = fighterWith({ types = { "fire" } })
  local foe = fighterWith({ types = { "fire" } })
  local speeds = {
    attacker = {
      ability = "RUN_AWAY",
      base = { attack = 12, defense = 10, specialAttack = 12, specialDefense = 10, speed = 20 },
    },
    defender = {
      ability = "RUN_AWAY",
      base = { attack = 12, defense = 10, specialAttack = 12, specialDefense = 10, speed = 10 },
    },
  }
  local function scoreWith(effect, id, lastMoveId)
    local probe = slotWith({
      key = "PROBE",
      id = id,
      moveType = "water",
      power = 60,
      category = "special",
      accuracy = 100,
      effect = effect,
    })
    local spent = slotWith({ key = "TACKLE", id = 33, usable = false })
    local slots = { probe, spent, spent, spent }
    local extra = {
      attacker = speeds.attacker,
      defender = speeds.defender,
      fullMoveById = {
        [501] = { effect = 0, power = 120, moveType = "water", category = "special", accuracy = 80, basePp = 5 },
      },
      fullMoveIdByKey = { HYDRO = 501 },
      lastMove = { [0] = lastMoveId, [1] = 0 },
    }
    local stream = spyStream(FIXED_SEED)
    local scored = TrainerAi.scoreSlots(chart, slots, user, foe, 14, { 1 }, false, stream, extra)
    return scored, stream
  end
  local strong, strongStream = scoreWith(241, 500, 501)
  local level, levelStream = scoreWith(241, 500, 500)
  local weak, weakStream = scoreWith(241, 500, 33)
  local takenLabels = { "score_init_0", "score_init_1", "score_init_2", "score_init_3", "program_chance", "program_chance" }
  local quietLabels = { "score_init_0", "score_init_1", "score_init_2", "score_init_3", "program_chance" }
  Assert.deepEqual(strongStream:drawLabels(), takenLabels, "the taken jump spends its gate draw")
  Assert.deepEqual(levelStream:drawLabels(), quietLabels, "the level preview falls through")
  Assert.deepEqual(weak, level, "a weaker preview falls through exactly like a level one")
  Assert.deepEqual(weakStream:drawLabels(), levelStream:drawLabels(), "both fall-through runs draw identically")
  Assert.isTrue(strong[1].score ~= level[1].score, "the stronger preview takes the jump")
  local far, farStream = scoreWith(242, 600, 501)
  local even, evenStream = scoreWith(242, 600, 600)
  local low, lowStream = scoreWith(242, 600, 33)
  local absent, absentStream = scoreWith(242, 600, 0)
  Assert.deepEqual(farStream:drawLabels(), evenStream:drawLabels(), "both reached paths spend one gate draw")
  Assert.isTrue(far[1].score ~= even[1].score, "the stronger preview takes the later jump")
  Assert.deepEqual(low, even, "a weaker preview falls through exactly like a level one")
  Assert.deepEqual(absent, even, "an absent previous move previews zero and falls through")
  Assert.deepEqual(lowStream:drawLabels(), evenStream:drawLabels(), "both fall-through runs draw identically")
  Assert.deepEqual(absentStream:drawLabels(), evenStream:drawLabels(), "the absent run draws like the fall-through")
end

---@return table the literal program owner under test
local function programOwner()
  return requirePresent("libs.battle.src.gen4.TrainerAiProgram", "the literal program owns command dispatch")
end

---@param overrides table<string, unknown> battler preview overrides under test construction
---@return table<string, unknown> complete matchup preview record
local function previewBattler(overrides)
  local record = {
    hp = 100,
    maxHp = 100,
    level = 5,
    t1 = 0,
    t2 = 0,
    ability = 0,
    item = 0,
    status = 0,
    status2 = 0,
    moveFlags = 0,
    atk = 12,
    def = 10,
    spa = 12,
    spd = 10,
    spe = 10,
    stages = { 6, 6, 6, 6, 6, 6, 6, 6 },
    moves = { 0, 0, 0, 0 },
    pp = { 0, 0, 0, 0 },
    gender = 2,
    weightHg = 100,
    friendship = 0,
    ivs = { hp = 10, attack = 10, defense = 10, speed = 10, specialAttack = 10, specialDefense = 10 },
    lastMove = 0,
    entryMoves = { 0, 0, 0, 0 },
    entryAbility = 0,
    speciesAbilities = { 0, 0 },
    suppressed = false,
    magnetRise = false,
    roosted = false,
    miracleEye = false,
    foresight = false,
    flingPower = 0,
    w88b1 = 0,
    w88neg = false,
    w94 = 0,
  }
  for key, value in pairs(overrides) do
    record[key] = value
  end
  return record
end

-- Ally-aware ranking needs the current slot on top against both the
-- target and its partner: when another slot beats it against the partner
-- the rank drops even though the ordinary single-target rank holds, an
-- ineligible slot never draws, and the partner preview leaves shared
-- facts alone.
function T.ally_aware_rank_needs_both_targets_to_hold_the_slot()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local program = programOwner()
  local water = program.TYPE_IDS["water"] --[[@as integer]]
  local fire = program.TYPE_IDS["fire"] --[[@as integer]]
  local slots = {
    slotWith({ key = "PROBE", id = 600, moveType = "water", power = 40, category = "special", accuracy = 100, effect = 41 }),
    slotWith({ key = "VINE", id = 601, moveType = "grass", power = 55, category = "physical", accuracy = 100, effect = 0 }),
    slotWith({ key = "GROWL", id = 45, moveType = "normal", power = 0, category = "status", accuracy = 100, effect = 7 }),
    slotWith({ key = "TACKLE", id = 33, usable = false }),
  }
  local function scoreAgainst(partnerType)
    local attacker = previewBattler({ t1 = water, t2 = water, moves = { 600, 601, 45, 33 } })
    local target = previewBattler({ t1 = fire, t2 = fire })
    local partner = previewBattler({ t1 = partnerType, t2 = partnerType })
    local extra = {
      doublesBattlers = { atk = 1, tgt = 0, records = { [0] = target, [1] = attacker, [2] = partner } },
      usedIds = { [1] = { 0, 0, 16 } },
    }
    local stream = spyStream(FIXED_SEED)
    local scored = TrainerAi.scoreSlots(
      chart,
      slots,
      fighterWith({ types = { "grass" } }),
      fighterWith({ types = { "rock", "ground" } }),
      100,
      { 6 },
      false,
      stream,
      extra
    )
    return scored, stream, extra
  end
  local matched, matchedStream, matchedExtra = scoreAgainst(fire)
  local split, splitStream = scoreAgainst(water)
  Assert.isTrue(#matchedStream:drawLabels() > 4, "the matching partner reaches the rank region")
  Assert.isTrue(#splitStream:drawLabels() > 4, "the splitting partner reaches the rank region")
  local observed = (matchedExtra.doublesBattlers --[[@as table<string, unknown>]])
  Assert.equal(observed.tgt, 0, "the partner preview leaves the shared target alone")
  local records = (observed.records --[[@as table<integer, table<string, unknown>>]])
  Assert.equal(records[2].t1, fire, "the partner preview leaves the partner record alone")
  local quietSlots = {
    slotWith({ key = "GROWL", id = 45, moveType = "normal", power = 0, category = "status", accuracy = 100, effect = 7 }),
    slotWith({ key = "TACKLE", id = 33, usable = false }),
    slotWith({ key = "TACKLE", id = 34, usable = false }),
    slotWith({ key = "TACKLE", id = 35, usable = false }),
  }
  local quietStream = spyStream(FIXED_SEED)
  local quiet = TrainerAi.scoreSlots(
    chart,
    quietSlots,
    fighterWith({ types = { "grass" } }),
    fighterWith({ types = { "rock", "ground" } }),
    100,
    { 6 },
    false,
    quietStream
  )
  Assert.deepEqual(
    quietStream:drawLabels(),
    { "score_init_0", "score_init_1", "score_init_2", "score_init_3" },
    "an ineligible slot spends no routine draw"
  )
  Assert.equal(quiet[1].score, 100, "an ineligible slot holds the baseline")
  -- The rank split takes different branches at the rank gate: the
  -- leading rank-2 path spends its gate draw while the rank-1 path skips
  -- it, and the shifted downstream draw diverges the following slot.
  -- Neither rank branch adjusts the leading slot itself, so it holds its
  -- score on both runs while the partner matchup still changes the run.
  Assert.deepEqual(
    matchedStream:drawLabels(),
    { "score_init_0", "score_init_1", "score_init_2", "score_init_3", "program_chance", "program_chance" },
    "the matched run spends the rank-2 gate draw"
  )
  Assert.deepEqual(
    splitStream:drawLabels(),
    { "score_init_0", "score_init_1", "score_init_2", "score_init_3", "program_chance" },
    "the split run skips the rank-2 gate draw"
  )
  Assert.equal(matched[1].score, 99, "the leading slot holds its score on the matched run")
  Assert.equal(split[1].score, 99, "the leading slot holds its score on the split run")
  Assert.equal(matched[2].score, 100, "the following slot holds baseline past the matched gate")
  Assert.equal(split[2].score, 99, "the following slot pays past the shifted split gate")
end

-- The supported surface stays bounded while decisions stay replayable:
-- unknown passes fail before drawing, the singles baseline never moves,
-- and a restored doubles snapshot answers identically.
function T.unsupported_passes_singles_and_replay_stay_bounded()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  for _, pass in ipairs({ "ai_pass_4", "ai_pass_8" }) do
    local failure = Assert.throws(function()
      TrainerAi.parsePasses({ pass })
    end, "pass " .. pass .. " fails instead of falling back")
    Assert.isTrue(string.find(tostring(failure), pass, 1, true) ~= nil, "the failure names the offending pass")
  end
  local quietStream = spyStream(FIXED_SEED)
  local quiet = TrainerAi.scoreSlots(
    chart,
    fourSlots(),
    fighterWith({ types = { "grass" } }),
    fighterWith({ types = { "rock", "ground" } }),
    14,
    {},
    false,
    quietStream
  )
  Assert.deepEqual(
    quietStream:drawLabels(),
    { "score_init_0", "score_init_1", "score_init_2", "score_init_3" },
    "the singles line draws only its initialization"
  )
  Assert.deepEqual(
    { quiet[1].score, quiet[2].score, quiet[3].score, quiet[4].score },
    { 100, 100, 100, 0 },
    "the singles baseline stays put"
  )
  local contracts = SessionFixture.sessionContracts()
  local lead = leveledCombatant(31, 23, "CHIKORITA", 20)
  lead.mon.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
  }
  runAway(lead)
  local mate = leveledCombatant(34, 24, "EEVEE", 20)
  runAway(mate)
  local foeA = leveledCombatant(32, 41, "TOTODILE", 10)
  runAway(foeA)
  local foeB = leveledCombatant(33, 42, "EEVEE", 10)
  runAway(foeB)
  local session = waitingSession(contracts, doublesVectorScenario(lead, mate, foeA, foeB, NATIVE_SEED))
  local held = session:capture()
  local first = session:answerTrainer(openRequest(session, "trainer:1"))
  session:dispose()
  local replayed = sessionOwner().restore(held, trainerContent())
  Assert.deepEqual(
    replayed:answerTrainer(openRequest(replayed, "trainer:1")),
    first,
    "the restored snapshot answers identically"
  )
  replayed:dispose()
end

return { tests = T }
