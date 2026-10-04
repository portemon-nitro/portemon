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
    slotWith({ key = "RAZOR_LEAF", moveType = "grass", power = 55, accuracy = 95 }),
    slotWith({ key = "GROWL", moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "EMBER", moveType = "fire", power = 40, category = "special", accuracy = 100, usable = false }),
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
  for _, pass in ipairs({ "ai_pass_4", "ai_pass_7", "ai_pass_8", "ai_pass_10", "bogus", "", "ai_pass_" }) do
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
    random = { seed = NATIVE_SEED },
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
function T.switch_gate_answers_before_the_item_path()
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
      { trainerItems = { "POTION" } }
    )
  )
  local held = session:capture().inventories["trainer-stock"].quantities
  Assert.equal(held.POTION, 1, "the session holds a serving the gate must pass over")
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "switch", "the answering reserve wins over the stocked cure")
  Assert.equal(reply.choices[1].payload.replacement, 3, "the answering reserve takes the field")
  local accepted, acceptErr = session:submit(reply)
  Assert.isTrue(accepted, "the switch submits: " .. tostring(acceptErr))
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
      { trainerItems = { "POTION" } }
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
        trainerItems = { "REMEDY", "POTION" },
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
      { trainerItems = { "POTION" } }
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
      { trainerItems = { "POTION" } }
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
  Assert.deepEqual(slotsOf(session:capture()), {}, "selection clears the served source slot")
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
        { itemFacts = { POTION = facts }, trainerItems = { "POTION" } }
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
      { trainerItems = { "POTION" } }
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
function T.flag_programs_adjust_scores_through_their_commands()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local TypeEffectiveness = require("libs.battle.src.gen4.TypeEffectiveness")
  local waterFire = TypeEffectiveness.resolve(chart, "water", { "fire" }, {})
  Assert.deepEqual({ waterFire.numerator, waterFire.denominator }, { 2, 1 }, "water answers fire double")
  local normalFire = TypeEffectiveness.resolve(chart, "normal", { "fire" }, {})
  Assert.deepEqual({ normalFire.numerator, normalFire.denominator }, { 1, 1 }, "normal answers fire neutrally")
  Assert.isTrue(TypeEffectiveness.stab("water", { "water" }), "matching types earn the bonus")
  local waterSlots = {
    slotWith({ key = "WATER_GUN", moveType = "water", power = 40, category = "special", accuracy = 100 }),
    slotWith({ key = "TACKLE" }),
    slotWith({ key = "GROWL", moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "EMBER", moveType = "fire", power = 40, category = "special", accuracy = 100, usable = false }),
  }
  local scored = TrainerAi.scoreSlots(
    chart,
    waterSlots,
    fighterWith({ types = { "water" } }),
    fighterWith({ types = { "fire" } }),
    14,
    { 0 },
    false,
    spyStream(FIXED_SEED)
  )
  -- Water strike: 100 + floor(40 * 3 * 2 / (2 * 1)); tackle: 100 + 35;
  -- status: 100 + 0; spent slot stays excluded.
  Assert.deepEqual(
    { scored[1].score, scored[2].score, scored[3].score, scored[4].score },
    { 220, 135, 100, 0 },
    "the bad-move check earns matchup points and drops the negated strike"
  )
  local faintSlots = {
    slotWith({ key = "MACH_PUNCH", moveType = "fighting", power = 40 }),
    slotWith({ key = "ROCK_THROW", moveType = "rock", power = 50 }),
    slotWith({ key = "GROWL", moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "SPENT", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
  }
  local fightingRock = TypeEffectiveness.resolve(chart, "fighting", { "normal", "rock" }, {})
  Assert.deepEqual(
    { fightingRock.numerator, fightingRock.denominator },
    { 4, 1 },
    "fighting answers the dual type fourfold"
  )
  local probe = BattleRng.new(FIXED_SEED)
  local first = probe:nextU16("faint_probe", {})
  local firstThreshold = 100 - (first % 16)
  local fainted = TrainerAi.scoreSlots(
    chart,
    faintSlots,
    fighterWith({ types = { "fighting" } }),
    fighterWith({ types = { "normal", "rock" } }),
    60,
    { 1 },
    false,
    spyStream(FIXED_SEED)
  )
  -- Weaker strike loses one; the doubly effective strike earns two
  -- exactly when its stored threshold favors the slot.
  local machExpected = 99
  if firstThreshold < 93 then
    machExpected = 101
  end
  Assert.deepEqual(
    { fainted[1].score, fainted[2].score, fainted[3].score, fainted[4].score },
    { machExpected, 100, 100, 0 },
    "faint-seeking drops weaker strikes and rewards the finishing line"
  )
  local emphasized = TrainerAi.scoreSlots(
    chart,
    waterSlots,
    fighterWith({ types = { "normal" } }),
    fighterWith({ types = { "fire" } }),
    14,
    { 2 },
    false,
    spyStream(FIXED_SEED)
  )
  local grassFire = TypeEffectiveness.resolve(chart, "grass", { "fire" }, {})
  Assert.deepEqual({ grassFire.numerator, grassFire.denominator }, { 1, 2 }, "grass resists into fire")
  Assert.equal(emphasized[1].score, 102, "the doubly resisted line never claims emphasis")
  local leafSlots = {
    slotWith({ key = "RAZOR_LEAF", moveType = "grass", power = 55 }),
    slotWith({ key = "TACKLE" }),
    slotWith({ key = "GROWL", moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "SPENT", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
  }
  local resisted = TrainerAi.scoreSlots(
    chart,
    leafSlots,
    fighterWith({ types = { "normal" } }),
    fighterWith({ types = { "fire" } }),
    14,
    { 2 },
    false,
    spyStream(FIXED_SEED)
  )
  Assert.deepEqual(
    { resisted[1].score, resisted[2].score, resisted[3].score, resisted[4].score },
    { 98, 100, 100, 0 },
    "effectiveness emphasis moves two points each way"
  )
  local stabbed = TrainerAi.scoreSlots(
    chart,
    waterSlots,
    fighterWith({ types = { "fire" } }),
    fighterWith({ types = { "fire" } }),
    14,
    { 3 },
    false,
    spyStream(FIXED_SEED)
  )
  Assert.isTrue(TypeEffectiveness.stab("fire", { "fire" }), "matching fire earns the bonus")
  Assert.isTrue(not TypeEffectiveness.stab("normal", { "fire" }), "off-type earns nothing")
  Assert.deepEqual(
    { stabbed[1].score, stabbed[2].score, stabbed[3].score, stabbed[4].score },
    { 99, 99, 100, 0 },
    "same-type preference splits two up and one down"
  )
  local knockout = TrainerAi.scoreSlots(
    chart,
    waterSlots,
    fighterWith({ types = { "water" } }),
    fighterWith({ types = { "fire" } }),
    1,
    { 5 },
    false,
    spyStream(FIXED_SEED)
  )
  Assert.deepEqual(
    { knockout[1].score, knockout[2].score, knockout[3].score, knockout[4].score },
    { 103, 103, 100, 0 },
    "knockout awareness adds three for a finishing preview"
  )
  local setupSlots = {
    slotWith({ key = "TACKLE" }),
    slotWith({ key = "BATON_PASS", moveType = "normal", power = 0, category = "status", accuracy = 0 }),
    slotWith({ key = "EMBER", moveType = "fire", power = 40, category = "special", accuracy = 100 }),
    slotWith({ key = "SPENT", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
  }
  local normalRock = TypeEffectiveness.resolve(chart, "normal", { "rock" }, {})
  Assert.deepEqual({ normalRock.numerator, normalRock.denominator }, { 1, 2 }, "normal is half into rock")
  local fireRock = TypeEffectiveness.resolve(chart, "fire", { "rock" }, {})
  Assert.deepEqual({ fireRock.numerator, fireRock.denominator }, { 1, 2 }, "fire is half into rock")
  local continued = TrainerAi.scoreSlots(
    chart,
    setupSlots,
    fighterWith({ types = { "normal" } }),
    fighterWith({ types = { "rock" } }),
    40,
    { 6 },
    false,
    spyStream(FIXED_SEED)
  )
  -- Tackle: 100 + floor(35 * 3 * 1 / (2 * 2)); pivot: 100 + 0 + 4;
  -- ember: 100 + floor(40 * 1 * 1 / (1 * 2)).
  Assert.deepEqual(
    { continued[1].score, continued[2].score, continued[3].score, continued[4].score },
    { 126, 104, 120, 0 },
    "setup continuation keeps four on the pivot beside matchup points"
  )
  Assert.equal(
    TrainerAi.selectMove(continued, spyStream(FIXED_SEED)),
    0,
    "the winning strike answers the doubled line"
  )
  local unpredictable = TrainerAi.scoreSlots(
    chart,
    waterSlots,
    fighterWith({ types = { "water" } }),
    fighterWith({ types = { "fire" } }),
    14,
    { 9 },
    false,
    spyStream(FIXED_SEED)
  )
  Assert.deepEqual(
    { unpredictable[1].score, unpredictable[2].score, unpredictable[3].score, unpredictable[4].score },
    { 101, 100, 100, 0 },
    "unpredictability adds one to the lowest usable slot without drawing"
  )
end

-- Unknown commands and unsupported flags fail closed: a synthetic
-- command outside the transcribed set and a flag without program data
-- both raise missing behavior before any fallback choice.
function T.unknown_commands_fail_closed_before_any_fallback()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local vm = {
    bit = 0,
    scores = { 100, 100, 100, 100 },
    thresholds = { 100, 100, 100, 100 },
    slots = fourSlots(),
    user = fighterWith({ types = { "grass" } }),
    foe = fighterWith({ types = { "rock", "ground" } }),
    foeHp = 14,
    bestPower = 55,
    chart = chart,
    stream = spyStream(FIXED_SEED),
  }
  local failure = Assert.throws(function()
    TrainerAi.runCommand(vm, 1, { op = "bogus_command" })
  end, "an unknown command fails instead of falling back")
  Assert.isTrue(
    string.find(tostring(failure), "bogus_command", 1, true) ~= nil,
    "the failure names the offending command"
  )
  Assert.deepEqual(vm.scores, { 100, 100, 100, 100 }, "the failed command moves no points")
  TrainerAi.runCommand(vm, 1, { op = "bonus_first_slot", amount = 1 })
  Assert.deepEqual(vm.scores, { 101, 100, 100, 100 }, "a known command still applies")
  local unsupported = Assert.throws(function()
    TrainerAi.scoreSlots(
      chart,
      fourSlots(),
      fighterWith({ types = { "grass" } }),
      fighterWith({ types = { "rock", "ground" } }),
      14,
      { 4 },
      false,
      spyStream(FIXED_SEED)
    )
  end, "a flag without program data fails instead of falling back")
  Assert.isTrue(string.find(tostring(unsupported), "4", 1, true) ~= nil, "the failure names the flag")
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
      { trainerItems = { "POTION" } }
    )
  )
  local held = session:capture()
  local memory = held.trainerAi --[[@as table<string, unknown>]]
  Assert.equal(type(memory), "table", "the capture carries the trainer record")
  Assert.equal(memory.version, 1, "the record carries its schema mark")
  local controllers = memory.controllers --[[@as table<string, unknown>]]
  local owned = controllers["trainer:1"] --[[@as table<string, unknown>]]
  Assert.deepEqual(owned.slots, { "POTION" }, "ordered slots mirror the stocked list")
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
-- schema mark, and a misshapen slot list all fail incompatible instead
-- of seeding fresh guesses.
function T.malformed_trainer_records_fail_restore_as_incompatible()
  local TrainerAi = trainerPolicy()
  Assert.isTrue(
    TrainerAi.validateMemory({ version = 1, controllers = { ["trainer:1"] = { slots = {}, knownMoves = {} } } }),
    "a well-formed record validates"
  )
  for _, broken in
    ipairs({
      { version = 2, controllers = {} },
      { version = 1, controllers = { ["trainer:1"] = { slots = { "" }, knownMoves = {} } } },
      { version = 1, controllers = { ["trainer:1"] = { slots = {}, knownMoves = { [0] = {} } } } },
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
        trainerItems = { "SUPER_POTION", "POTION" },
      }
    )
  )
  local memory = session:capture().trainerAi --[[@as table<string, unknown>]]
  local controllers = memory.controllers --[[@as table<string, unknown>]]
  local owned = controllers["trainer:1"] --[[@as table<string, unknown>]]
  Assert.deepEqual(
    owned.slots,
    { "SUPER_POTION", "POTION" },
    "memory slots mirror the source order"
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
        trainerItems = { "POTION", "SUPER_POTION", "POTION" },
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
    { "SUPER_POTION", "POTION" },
    "selection clears only the first matching slot"
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
  Assert.deepEqual(slotsOf(session:capture()), { "POTION" }, "the middle slot clears in turn")
  session:dispose()
end

-- Learned threats switch the holder out: the opening answer strikes
-- with no knowledge, and once the foe reveals a lethal strike the next
-- answer exchanges for the first reserve that takes it better.
function T.learned_threats_switch_the_holder_out()
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
  local answer = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(answer.choices[1].kind, "switch", "the learned lethal threat exchanges")
  Assert.equal(answer.choices[1].payload.replacement, 12, "the safer reserve takes the field")
  local accepted, acceptErr = session:submit(answer)
  Assert.isTrue(accepted, "the exchange submits: " .. tostring(acceptErr))
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
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(#reply.choices, 1, "the lone trainer actor answers")
  Assert.equal(reply.choices[1].kind, "attack", "the doubles evaluation strikes")
  Assert.equal(reply.choices[1].payload.target.position, 1, "the strike answers the weaker line")
  Assert.equal(reply.choices[1].payload.moveSlot, 0, "the winning move answers the weaker line")
  Assert.equal(
    session:capture().rng.calls - held.rng.calls,
    7,
    "one initialization feeds two targets with two picks and one selection"
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

-- Routine draws follow their transcribed guards: the opening-turn
-- effectiveness program draws once per listed-effect slot on the first
-- turn only, while later turns and unlisted effects draw nothing.
function T.routine_draws_follow_effect_lists_and_the_opening_turn()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local user = fighterWith({ types = { "normal" } })
  local foe = fighterWith({ types = { "normal" } })
  local slots = {
    slotWith({ key = "LEER", moveType = "normal", power = 0, category = "status", accuracy = 100, effect = 19 }),
    slotWith({ key = "FOCUS", moveType = "normal", power = 0, category = "status", accuracy = 100, effect = 47 }),
    slotWith({ key = "TACKLE" }),
    slotWith({ key = "SPENT", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
  }
  local first = TrainerAi.scoreSlots(chart, slots, user, foe, 14, { 2 }, true, spyStream(FIXED_SEED))
  Assert.equal(#first, 4, "scoring covers every move slot")
  local firstStream = spyStream(FIXED_SEED)
  TrainerAi.scoreSlots(chart, slots, user, foe, 14, { 2 }, true, firstStream)
  Assert.equal(#firstStream:drawLabels(), 6, "the opening turn draws init plus two routine draws")
  Assert.equal(firstStream:drawLabels()[5], "program_chance", "the first routine draw names its site")
  Assert.equal(firstStream:drawLabels()[6], "program_chance", "the second routine draw names its site")
  local probe = BattleRng.new(FIXED_SEED)
  for _ = 1, 4 do
    probe:nextU16("init_probe", {})
  end
  local firstChance = probe:nextU16("chance_probe", {})
  local secondChance = probe:nextU16("chance_probe", {})
  Assert.deepEqual(
    firstStream:drawValues(),
    { firstStream:drawValues()[1], firstStream:drawValues()[2], firstStream:drawValues()[3], firstStream:drawValues()[4], firstChance, secondChance },
    "routine draws continue the shared stream in slot order"
  )
  local laterStream = spyStream(FIXED_SEED)
  local later = TrainerAi.scoreSlots(chart, slots, user, foe, 14, { 2 }, false, laterStream)
  Assert.deepEqual(later, first, "the turn gate moves no points")
  Assert.equal(#laterStream:drawLabels(), 4, "later turns draw init only")
  local plainStream = spyStream(FIXED_SEED)
  TrainerAi.scoreSlots(chart, fourSlots(), user, foe, 14, { 2 }, true, plainStream)
  Assert.equal(#plainStream:drawLabels(), 4, "unlisted effects draw nothing even on the opening turn")
  local replayed = TrainerAi.scoreSlots(chart, slots, user, foe, 14, { 2 }, true, spyStream(FIXED_SEED))
  Assert.deepEqual(replayed, first, "a fixed seed replays the gated scores")
end

-- Knockout branches route the faint-seeking draw: a listed effect below
-- the knockout preview draws through the main site, a tail-only effect
-- draws nothing below it and draws through the knockout branch at it.
function T.knockout_branches_route_the_faint_seeking_draw()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local user = fighterWith({ types = { "dark" } })
  local foe = fighterWith({ types = { "normal" } })
  local sucker = {
    slotWith({ key = "SUCKER", moveType = "dark", power = 80, effect = 248 }),
    slotWith({ key = "TACKLE" }),
    slotWith({ key = "GROWL", moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "SPENT", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
  }
  local mildStream = spyStream(FIXED_SEED)
  TrainerAi.scoreSlots(chart, sucker, user, foe, 1000, { 0 }, false, mildStream)
  Assert.equal(#mildStream:drawLabels(), 5, "a listed effect below the knockout draws once")
  Assert.equal(mildStream:drawLabels()[5], "program_chance", "the faint-seeking draw names its site")
  local quick = {
    slotWith({ key = "QUICK", moveType = "normal", power = 40, effect = 103 }),
    slotWith({ key = "TACKLE" }),
    slotWith({ key = "GROWL", moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "SPENT", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
  }
  local quickMildStream = spyStream(FIXED_SEED)
  TrainerAi.scoreSlots(chart, quick, user, fighterWith({ types = { "normal" } }), 1000, { 0 }, false, quickMildStream)
  Assert.equal(#quickMildStream:drawLabels(), 4, "a tail-only effect below the knockout draws nothing")
  local quickKoStream = spyStream(FIXED_SEED)
  TrainerAi.scoreSlots(chart, quick, user, fighterWith({ types = { "normal" } }), 1, { 0 }, false, quickKoStream)
  Assert.equal(#quickKoStream:drawLabels(), 5, "a tail-only effect at the knockout draws once")
  Assert.equal(quickKoStream:drawLabels()[5], "program_chance", "the knockout-branch draw names its site")
end

-- Membership draws fire per listed effect: same-type preference and
-- unpredictability each draw once for a listed slot and never otherwise.
function T.membership_draws_fire_per_listed_effect()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local user = fighterWith({ types = { "normal" } })
  local foe = fighterWith({ types = { "normal" } })
  local focusPunch = {
    slotWith({ key = "FOCUS_PUNCH", moveType = "fighting", power = 150, effect = 170 }),
    slotWith({ key = "TACKLE" }),
    slotWith({ key = "GROWL", moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "SPENT", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
  }
  local stabStream = spyStream(FIXED_SEED)
  TrainerAi.scoreSlots(chart, focusPunch, user, foe, 14, { 3 }, false, stabStream)
  Assert.equal(#stabStream:drawLabels(), 5, "a listed same-type effect draws once")
  local plainStabStream = spyStream(FIXED_SEED)
  TrainerAi.scoreSlots(chart, fourSlots(), user, foe, 14, { 3 }, false, plainStabStream)
  Assert.equal(#plainStabStream:drawLabels(), 4, "an unlisted same-type line draws nothing")
  local leerNine = {
    slotWith({ key = "LEER", moveType = "normal", power = 0, category = "status", accuracy = 100, effect = 19 }),
    slotWith({ key = "TACKLE" }),
    slotWith({ key = "GROWL", moveType = "normal", power = 0, category = "status", accuracy = 100 }),
    slotWith({ key = "SPENT", moveType = "normal", power = 0, category = "status", accuracy = 0, usable = false }),
  }
  local nineStream = spyStream(FIXED_SEED)
  TrainerAi.scoreSlots(chart, fourSlots(), user, foe, 14, { 9 }, false, nineStream)
  Assert.equal(#nineStream:drawLabels(), 4, "unpredictability draws nothing without its listed effect")
  local nineEffectStream = spyStream(FIXED_SEED)
  TrainerAi.scoreSlots(chart, leerNine, user, foe, 14, { 9 }, false, nineEffectStream)
  Assert.equal(#nineEffectStream:drawLabels(), 5, "a listed unpredictability effect draws once")
end

-- Covering stays spend gate draws before selection: a flagless foe with
-- super-effective coverage and a living reserve spends the coverage check
-- plus one stay draw ahead of initialization and selection, while neutral
-- coverage spends nothing. Both answers replay deterministically.
function T.covering_stays_spend_gate_draws_before_selection()
  local Executor = sessionOwner()
  local contracts = SessionFixture.sessionContracts()
  local function coverScenario(playerSpecies, foeMoves)
    local player = leveledCombatant(1, 41, playerSpecies, 5)
    local lead = leveledCombatant(2, 23, "EEVEE", 10)
    lead.mon.moves = foeMoves
    local reserve = leveledCombatant(3, 24, "EEVEE", 5)
    local seeds = { player, lead, reserve }
    local striker = SessionFixture.participant(2, 2, "trainer:1", { lead, reserve })
    striker.context = { aiPasses = {} }
    return {
      ruleset = Executor.RULESET,
      format = "single",
      sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
      participants = {
        SessionFixture.participant(1, 1, "player", { player }),
        striker,
      },
      positions = {
        SessionFixture.position(1, 1, { 1 }, player.id),
        SessionFixture.position(2, 2, { 2 }, lead.id),
      },
      inventories = {},
      environment = { weather = "none" },
      random = { seed = NATIVE_SEED },
      formatState = {},
      moveFacts = scenarioMoveFacts({ "TACKLE", "RAZOR_LEAF" }),
      speciesFacts = scenarioSpeciesFacts(seeds),
      itemFacts = {},
    }, seeds
  end
  local covered, _ = coverScenario("TOTODILE", {
    { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
    { move = "TACKLE", pp = 35, ppUps = 0 },
  })
  local session = waitingSession(contracts, covered)
  local held = session:capture()
  local reply = session:answerTrainer(openRequest(session, "trainer:1"))
  Assert.equal(reply.choices[1].kind, "attack", "the covering foe still strikes")
  Assert.equal(
    session:capture().rng.calls - held.rng.calls,
    7,
    "coverage spends two gate draws plus init and selection"
  )
  session:dispose()
  local replayed = Executor.restore(held, trainerContent())
  Assert.deepEqual(
    replayed:answerTrainer(openRequest(replayed, "trainer:1")),
    reply,
    "a fixed seed replays the covering answer"
  )
  replayed:dispose()
  local neutral, _ = coverScenario("EEVEE", {
    { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
    { move = "TACKLE", pp = 35, ppUps = 0 },
  })
  local calm = waitingSession(contracts, neutral)
  local calmHeld = calm:capture()
  local calmReply = calm:answerTrainer(openRequest(calm, "trainer:1"))
  Assert.equal(calmReply.choices[1].kind, "attack", "the neutral foe still strikes")
  Assert.equal(
    calm:capture().rng.calls - calmHeld.rng.calls,
    5,
    "neutral coverage spends init and selection only"
  )
  calm:dispose()
end

-- Missing move effects fail closed before any draw: scoring names the
-- offending move instead of guessing membership.
function T.missing_effects_fail_closed_before_any_draw()
  local TrainerAi = trainerPolicy()
  local chart = nativeChart()
  local bare = slotWith({})
  bare.effect = nil
  local slots = { bare, slotWith({}), slotWith({}), slotWith({ key = "SPENT", usable = false }) }
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

return { tests = T }
