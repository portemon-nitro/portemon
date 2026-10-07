-- Field, trainer, and wild sources mapped to one detached scenario: wild
-- descriptors and records copy once without rerolling, trainer parties are
-- never invented, scripted fights pass through verbatim, and malformed
-- sources fail loudly.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")

local T = {}

---@return HgssMonService live party holding a fainted lead, an egg, and two conscious mons
local function mixedParty()
  local catalog = CatalogFixture.makeCatalog()
  local service = HgssMonService.new({
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
  local factory = CatalogFixture.makeFactory(0x33333333, catalog)
  local fainted = factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA", level = 5 }))
  fainted.condition.currentHp = 0
  Assert.isTrue(service:addMon(fainted), "the fainted lead enters the live party")
  local egg = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 5 }))
  egg.isEgg = true
  Assert.isTrue(service:addMon(egg), "the egg enters the live party")
  Assert.isTrue(
    service:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 5 }))),
    "the first conscious mon enters the live party"
  )
  Assert.isTrue(
    service:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "EEVEE", level = 5 }))),
    "the second conscious mon enters the live party"
  )
  return service
end

---@return HgssMonService live party holding a lone conscious member behind a fainted lead
local function singleConsciousParty()
  local catalog = CatalogFixture.makeCatalog()
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x66666666):capture()),
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
  local factory = CatalogFixture.makeFactory(0x77777777, catalog)
  local fainted = factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA", level = 5 }))
  fainted.condition.currentHp = 0
  Assert.isTrue(service:addMon(fainted), "the fainted lead enters the live party")
  Assert.isTrue(
    service:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 5 }))),
    "the lone conscious mon enters the live party"
  )
  return service
end

---@return HgssBagService live bag holding potion and ball stock
local function stockedBag()
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  Assert.isTrue(bag:add("POTION", 3), "setup potion stock enters the live bag")
  Assert.isTrue(bag:add("POKE_BALL", 2), "setup ball stock enters the live bag")
  return bag
end

---@param scenario table detached scenario under inspection
---@return table the player participant
local function playerOf(scenario)
  return scenario.participants[1]
end

---@param scenario table detached scenario under inspection
---@param inventoryId string battle inventory identity under lookup
---@return table the named battle inventory
local function inventoryOf(scenario, inventoryId)
  for _, entry in ipairs(scenario.inventories) do
    if entry.id == inventoryId then
      return entry
    end
  end
  error("scenario carries no inventory named " .. inventoryId)
end

local function wildPayload(overrides)
  local payload = {
    attemptId = "attempt-7",
    species = "TOTODILE",
    form = 0,
    level = 4,
    personality = 0x12345678,
    ability = "TORRENT",
  }
  for key, value in pairs(overrides or {}) do
    payload[key] = value
  end
  return payload
end

local function fullRecord()
  return {
    schema = "g4-mon-v2",
    species = "TOTODILE",
    level = 4,
    condition = { currentHp = 18 },
  }
end

local function faintedRecord()
  local record = fullRecord()
  record.condition.currentHp = 0
  return record
end

function T.wild_descriptors_copy_once_without_rerolling()
  local payload = wildPayload()
  local scenario = ScenarioFactory.fromEncounter(payload, {})
  Assert.equal(scenario.attemptId, "attempt-7")
  Assert.equal(scenario.kind, "wild")
  Assert.equal(scenario.mon.personality, 0x12345678)
  Assert.equal(scenario.mon.species, "TOTODILE")
  payload.level = 99
  payload.personality = 0x1
  Assert.equal(scenario.mon.level, 4, "later caller mutations never reach the scenario")
  Assert.equal(scenario.mon.personality, 0x12345678, "the prepared identity never rerolls")
  Assert.equal(#scenario.participants, 2)
  Assert.equal(#scenario.positions, 2)
  Assert.equal(scenario.random.seed, 0x12345678, "the prepared personality anchors the seed")
end

function T.wild_records_ride_through_untouched()
  local mon = fullRecord()
  local scenario = ScenarioFactory.fromEncounter({ attemptId = "attempt-9", mon = mon }, {})
  Assert.deepEqual(scenario.mon, mon)
  Assert.equal(scenario.participants[2].roster[1].mon.condition.currentHp, 18)
  mon.condition.currentHp = 1
  Assert.equal(
    scenario.participants[2].roster[1].mon.condition.currentHp,
    18,
    "live record mutations never reach the scenario"
  )
end

function T.wild_sources_reject_malformed_input()
  Assert.isTrue(not pcall(ScenarioFactory.fromEncounter, { species = "MISSING_NO" }, {}))
  Assert.isTrue(not pcall(ScenarioFactory.fromEncounter, { species = "TOTODILE", level = 0 }, {}))
  Assert.isTrue(not pcall(ScenarioFactory.fromEncounter, { species = "TOTODILE", level = 101 }, {}))
  Assert.isTrue(not pcall(ScenarioFactory.fromEncounter, { level = 4 }, {}))
end

function T.trainer_parties_are_never_invented()
  Assert.isTrue(not pcall(ScenarioFactory.fromTrainer, { trainer = "rival" }, {}))
  local party = { fullRecord(), fullRecord() }
  local scenario = ScenarioFactory.fromTrainer({ trainer = "rival", party = party }, {})
  Assert.equal(scenario.kind, "trainer")
  Assert.equal(#scenario.participants[2].roster, 2)
  party[1].condition.currentHp = 1
  Assert.equal(scenario.participants[2].roster[1].mon.condition.currentHp, 18, "trainer records copy once")
  Assert.equal(scenario.participants[2].controller, "trainer:rival")
end

function T.simultaneous_trainers_keep_their_double_engagement()
  local scenario = ScenarioFactory.fromTrainer({
    trainers = {
      { id = "a", party = { fullRecord() } },
      { id = "b", party = { fullRecord() } },
    },
  }, {})
  Assert.equal(#scenario.participants, 3)
  Assert.equal(#scenario.positions, 4)
  Assert.equal(scenario.format, "double")
  Assert.equal(scenario.participants[2].controller, "trainer:a")
  Assert.equal(scenario.participants[3].controller, "trainer:b")
  Assert.equal(scenario.positions[1].side, 1)
  Assert.equal(scenario.positions[2].side, 1)
  Assert.equal(scenario.positions[3].side, 2)
  Assert.equal(scenario.positions[4].side, 2)
  Assert.deepEqual(scenario.positions[1].eligibleParticipants, { 1 })
  Assert.deepEqual(scenario.positions[2].eligibleParticipants, { 1 })
  Assert.deepEqual(scenario.positions[3].eligibleParticipants, { 2 })
  Assert.deepEqual(scenario.positions[4].eligibleParticipants, { 3 })
end

function T.production_scenarios_carry_the_full_eligible_roster_with_a_conscious_lead()
  local party = mixedParty()
  local bag = stockedBag()
  local revision = party:partyRevision()
  local live = { party = party, bag = bag }
  local wild = ScenarioFactory.fromEncounter(wildPayload(), live)
  local trainer = ScenarioFactory.fromTrainer({ trainer = "rival", party = { fullRecord(), fullRecord() } }, live)
  for _, scenario in ipairs({ wild, trainer }) do
    local player = playerOf(scenario)
    Assert.equal(#player.roster, 3, "every non-egg party member reaches the roster")
    Assert.equal(player.roster[1].source.slot, 1, "the fainted lead keeps its source slot")
    Assert.equal(player.roster[2].source.slot, 3, "roster order follows party order past the egg")
    Assert.equal(player.roster[3].source.slot, 4, "roster order follows party order")
    for _, seed in ipairs(player.roster) do
      Assert.equal(seed.source.kind, "party")
      Assert.equal(seed.source.owner, "player")
      Assert.equal(seed.source.key, "party")
      Assert.equal(seed.source.revision, revision, "one party revision stamps every seed")
    end
    Assert.equal(
      scenario.positions[1].occupant,
      player.roster[2].id,
      "the first conscious member holds the opening position"
    )
    local stock = inventoryOf(scenario, assert(player.inventoryId, "the player draws on its battle stock"))
    Assert.deepEqual(stock.owners, { 1 }, "the player stock is owned by the player participant")
    Assert.deepEqual(stock.quantities, { POTION = 3, POKE_BALL = 2 }, "the player stock mirrors the live bag")
  end
  Assert.equal(
    trainer.participants[2].roster[1].id,
    4,
    "enemy combatant identities begin after the expanded player roster"
  )
end

function T.production_player_context_carries_reward_identity()
  local party = mixedParty()
  local live = {
    party = party,
    bag = stockedBag(),
    player = { trainerId = 99, trainerName = "MINT", language = "french" },
  }
  local wild = ScenarioFactory.fromEncounter(wildPayload(), live)
  local trainer = ScenarioFactory.fromTrainer({ trainer = "rival", party = { fullRecord(), fullRecord() } }, live)
  for _, scenario in ipairs({ wild, trainer }) do
    Assert.deepEqual(
      playerOf(scenario).context,
      { productionPlayer = true, trainerId = 99, trainerName = "MINT", language = "french" },
      "the player participant carries its detached reward identity"
    )
  end
  local bare = ScenarioFactory.fromEncounter(wildPayload(), { party = party, bag = stockedBag() })
  Assert.deepEqual(
    playerOf(bare).context,
    { productionPlayer = true },
    "production builds without player facts still mark their composition"
  )
  local headless = ScenarioFactory.fromEncounter(wildPayload(), {})
  Assert.deepEqual(playerOf(headless).context, {}, "scenarios without a live party keep an empty context")
end

function T.production_half_wired_facts_keep_only_the_production_marker()
  local party = mixedParty()
  local live = {
    party = party,
    bag = stockedBag(),
    player = { trainerId = 99, trainerName = "MINT" },
  }
  local wild = ScenarioFactory.fromEncounter(wildPayload(), live)
  local trainer = ScenarioFactory.fromTrainer({ trainer = "rival", party = { fullRecord(), fullRecord() } }, live)
  for _, scenario in ipairs({ wild, trainer }) do
    Assert.deepEqual(
      playerOf(scenario).context,
      { productionPlayer = true },
      "half-wired facts never guess an identity"
    )
  end
end

function T.production_builds_fail_without_a_conscious_combatant()
  local catalog = CatalogFixture.makeCatalog()
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x44444444):capture()),
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
  local factory = CatalogFixture.makeFactory(0x55555555, catalog)
  local wiped = factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA", level = 5 }))
  wiped.condition.currentHp = 0
  Assert.isTrue(service:addMon(wiped), "the wiped lead enters the live party")
  local live = { party = service, bag = stockedBag() }
  Assert.isTrue(not pcall(ScenarioFactory.fromEncounter, wildPayload(), live), "a wiped party builds no wild scenario")
  Assert.isTrue(
    not pcall(ScenarioFactory.fromTrainer, { trainer = "rival", party = { fullRecord() } }, live),
    "a wiped party builds no trainer scenario"
  )
end

function T.trainer_item_lists_become_finite_per_trainer_stock()
  local party = mixedParty()
  local scenario = ScenarioFactory.fromTrainer({
    trainers = {
      { id = "a", party = { fullRecord() }, items = { "POTION", "POTION", "POKE_BALL" } },
      { id = "b", party = { fullRecord() }, items = { "POTION" } },
    },
  }, { party = party, bag = stockedBag() })
  local first = scenario.participants[2]
  local second = scenario.participants[3]
  Assert.isTrue(first.inventoryId ~= nil, "the first trainer draws on its own stock")
  Assert.isTrue(second.inventoryId ~= nil, "the second trainer draws on its own stock")
  Assert.isTrue(first.inventoryId ~= second.inventoryId, "simultaneous trainers never share stock")
  Assert.deepEqual(
    inventoryOf(scenario, first.inventoryId).quantities,
    { POTION = 2, POKE_BALL = 1 },
    "duplicate trainer items count their multiplicity"
  )
  Assert.deepEqual(
    inventoryOf(scenario, second.inventoryId).quantities,
    { POTION = 1 },
    "each trainer stock counts only its own list"
  )
  Assert.isNil(first.context.items, "carried items never enter the decision context")
  Assert.isNil(first.context.program, "selection programs never enter the decision context")
  Assert.isNil(second.context.items, "carried items never enter the decision context")
end

-- Gap sentinels are not carried items: a trainer list holding one fails
-- the build instead of riding the decision context or counting stock.
function T.trainer_gap_entries_fail_instead_of_riding_through()
  local party = mixedParty()
  Assert.isTrue(
    not pcall(ScenarioFactory.fromTrainer, {
      trainers = {
        { id = "a", party = { fullRecord() }, items = { "POTION", "NONE", "NONE", "NONE" } },
      },
    }, { party = party, bag = stockedBag() }),
    "a gap entry fails the trainer build"
  )
  Assert.isTrue(
    not pcall(ScenarioFactory.fromTrainer, {
      trainers = {
        { id = "a", party = { fullRecord() }, items = { "NONE" } },
      },
    }, { party = party, bag = stockedBag() }),
    "a lone gap entry fails the trainer build"
  )
end

function T.trainer_pass_facts_ride_the_decision_context()
  local party = mixedParty()
  local scenario = ScenarioFactory.fromTrainer({
    trainers = {
      { id = "a", party = { fullRecord() }, aiPasses = { "ai_pass_0", "ai_pass_1" } },
    },
  }, { party = party, bag = stockedBag() })
  Assert.deepEqual(
    scenario.participants[2].context,
    { aiPasses = { "ai_pass_0", "ai_pass_1" } },
    "the decision context keeps only the pass facts"
  )
end

-- Trainer item identities keep their source-relative order beside finite
-- stock: duplicates preserve multiplicity in the decision context while
-- the battle inventory counts quantities, and later caller mutations
-- never reach either record.
function T.trainer_item_lists_keep_source_order_beside_finite_stock()
  local party = mixedParty()
  local items = { "POTION", "POKE_BALL", "POTION" }
  local scenario = ScenarioFactory.fromTrainer({
    trainers = {
      { id = "a", party = { fullRecord() }, items = items },
    },
  }, { party = party, bag = stockedBag() })
  local foe = scenario.participants[2]
  Assert.deepEqual(
    foe.context.trainerItems,
    { "POTION", "POKE_BALL", "POTION" },
    "the decision context preserves source-relative order and multiplicity"
  )
  local stock = inventoryOf(scenario, assert(foe.inventoryId, "the trainer keeps its stock identity"))
  Assert.deepEqual(
    stock.quantities,
    { POTION = 2, POKE_BALL = 1 },
    "the battle inventory counts quantities separately"
  )
  Assert.isNil(foe.context.quantities, "no mutable quantity field rides the decision context")
  items[1] = "FULL_RESTORE"
  items[3] = "FULL_RESTORE"
  Assert.deepEqual(
    foe.context.trainerItems,
    { "POTION", "POKE_BALL", "POTION" },
    "later caller mutations never reach the ordered context"
  )
end

-- Simultaneous trainers keep compact, detached, isolated stock: ordered
-- lists with multiplicity reach each decision context unchanged, each
-- stock counts only its own trainer, and later caller mutations leak
-- into neither record.
function T.simultaneous_trainer_lists_stay_compact_detached_and_isolated()
  local party = mixedParty()
  local firstItems = { "POTION", "POKE_BALL", "POTION" }
  local secondItems = { "POTION" }
  local scenario = ScenarioFactory.fromTrainer({
    trainers = {
      { id = "a", party = { fullRecord() }, items = firstItems },
      { id = "b", party = { fullRecord() }, items = secondItems },
    },
  }, { party = party, bag = stockedBag() })
  local first = scenario.participants[2]
  local second = scenario.participants[3]
  Assert.deepEqual(
    first.context.trainerItems,
    { "POTION", "POKE_BALL", "POTION" },
    "the first context preserves compact order and multiplicity"
  )
  Assert.deepEqual(
    second.context.trainerItems,
    { "POTION" },
    "the second context preserves its compact list"
  )
  Assert.deepEqual(
    inventoryOf(scenario, assert(first.inventoryId, "the first trainer keeps its stock identity")).quantities,
    { POTION = 2, POKE_BALL = 1 },
    "the first stock counts multiplicity separately"
  )
  Assert.deepEqual(
    inventoryOf(scenario, assert(second.inventoryId, "the second trainer keeps its stock identity")).quantities,
    { POTION = 1 },
    "the second stock counts only its own list"
  )
  Assert.isTrue(first.inventoryId ~= second.inventoryId, "simultaneous trainers never share stock")
  firstItems[1] = "FULL_RESTORE"
  firstItems[3] = "FULL_RESTORE"
  secondItems[1] = "FULL_RESTORE"
  Assert.deepEqual(
    first.context.trainerItems,
    { "POTION", "POKE_BALL", "POTION" },
    "later caller mutations never reach the first context"
  )
  Assert.deepEqual(
    second.context.trainerItems,
    { "POTION" },
    "later caller mutations never reach the second context"
  )
end

function T.an_empty_live_bag_still_yields_a_valid_player_stock()
  local party = mixedParty()
  local empty = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local scenario = ScenarioFactory.fromEncounter(wildPayload(), { party = party, bag = empty })
  local player = playerOf(scenario)
  local stock = inventoryOf(scenario, assert(player.inventoryId, "the player keeps its stock identity"))
  Assert.deepEqual(stock.quantities, {}, "no positive stock yields no battle units")
  Assert.deepEqual(stock.owners, { 1 })
end

-- One source-marked double trainer fields two slots per side: the lone
-- enemy participant stays eligible in both enemy slots and each side
-- opens with its first two conscious members in roster order.
function T.single_double_marked_trainer_opens_with_both_sides_doubled()
  local party = mixedParty()
  local live = { party = party, bag = stockedBag() }
  local scenario = ScenarioFactory.fromTrainer({
    trainers = {
      {
        id = "rival-double",
        party = { fullRecord(), fullRecord() },
        aiPasses = { "ai_pass_0" },
        doubleBattle = true,
      },
    },
  }, live)
  Assert.equal(scenario.format, "double")
  Assert.equal(#scenario.positions, 4)
  Assert.equal(#scenario.participants, 2)
  local player = playerOf(scenario)
  local foe = scenario.participants[2]
  Assert.equal(foe.controller, "trainer:rival-double")
  Assert.equal(scenario.positions[1].side, 1)
  Assert.equal(scenario.positions[2].side, 1)
  Assert.equal(scenario.positions[3].side, 2)
  Assert.equal(scenario.positions[4].side, 2)
  Assert.deepEqual(scenario.positions[1].eligibleParticipants, { 1 })
  Assert.deepEqual(scenario.positions[2].eligibleParticipants, { 1 })
  Assert.deepEqual(scenario.positions[3].eligibleParticipants, { 2 })
  Assert.deepEqual(scenario.positions[4].eligibleParticipants, { 2 })
  Assert.equal(scenario.positions[1].occupant, player.roster[2].id)
  Assert.equal(scenario.positions[2].occupant, player.roster[3].id)
  Assert.equal(scenario.positions[3].occupant, foe.roster[1].id)
  Assert.equal(scenario.positions[4].occupant, foe.roster[2].id)
  local seen = {}
  for _, position in ipairs(scenario.positions) do
    Assert.isTrue(seen[position.occupant] == nil, "each opening slot fields its own combatant")
    seen[position.occupant] = true
  end
  Assert.isTrue(player.roster[2].mon.condition.currentHp > 0, "the first opener stands conscious")
  Assert.isTrue(player.roster[3].mon.condition.currentHp > 0, "the second opener stands conscious")
  Assert.isTrue(foe.roster[1].mon.condition.currentHp > 0, "the first enemy opener stands conscious")
  Assert.isTrue(foe.roster[2].mon.condition.currentHp > 0, "the second enemy opener stands conscious")
end

-- Two simultaneous trainers still field two slots per side: the player
-- keeps both of its slots while each enemy slot answers to exactly one
-- of the two trainer participants.
function T.two_trainers_each_hold_one_enemy_slot_while_the_player_holds_two()
  local party = mixedParty()
  local live = { party = party, bag = stockedBag() }
  local scenario = ScenarioFactory.fromTrainer({
    trainers = {
      { id = "a", party = { fullRecord(), fullRecord() } },
      { id = "b", party = { fullRecord(), fullRecord() } },
    },
  }, live)
  Assert.equal(scenario.format, "double")
  Assert.equal(#scenario.positions, 4)
  Assert.equal(#scenario.participants, 3)
  Assert.equal(scenario.participants[2].controller, "trainer:a")
  Assert.equal(scenario.participants[3].controller, "trainer:b")
  local player = playerOf(scenario)
  local first = scenario.participants[2]
  local second = scenario.participants[3]
  Assert.equal(scenario.positions[1].side, 1)
  Assert.equal(scenario.positions[2].side, 1)
  Assert.equal(scenario.positions[3].side, 2)
  Assert.equal(scenario.positions[4].side, 2)
  Assert.deepEqual(scenario.positions[1].eligibleParticipants, { 1 })
  Assert.deepEqual(scenario.positions[2].eligibleParticipants, { 1 })
  Assert.deepEqual(scenario.positions[3].eligibleParticipants, { 2 })
  Assert.deepEqual(scenario.positions[4].eligibleParticipants, { 3 })
  Assert.equal(scenario.positions[1].occupant, player.roster[2].id)
  Assert.equal(scenario.positions[2].occupant, player.roster[3].id)
  Assert.equal(scenario.positions[3].occupant, first.roster[1].id)
  Assert.equal(scenario.positions[4].occupant, second.roster[1].id)
end

-- A source-marked double never fields a lone opener and never lets an
-- explicit single downgrade it: both builds fail before any session
-- exists.
function T.source_doubles_fail_without_two_conscious_player_openers()
  local live = { party = singleConsciousParty(), bag = stockedBag() }
  local doubled = {
    trainers = {
      { id = "rival-double", party = { fullRecord(), fullRecord() }, doubleBattle = true },
    },
  }
  Assert.isTrue(
    not pcall(ScenarioFactory.fromTrainer, doubled, live),
    "a source-marked double never fields a lone opener"
  )
  local downgraded = {
    trainers = {
      { id = "rival-double", party = { fullRecord(), fullRecord() }, doubleBattle = true },
    },
    format = "single",
  }
  Assert.isTrue(
    not pcall(ScenarioFactory.fromTrainer, downgraded, live),
    "an explicit single never downgrades a source-marked double"
  )
end

-- A lone trainer without the source double mark stays a single: one
-- slot per side, opening with the first conscious non-egg while the
-- fainted lead keeps its roster seat.
function T.single_trainers_keep_their_single_opening()
  local party = mixedParty()
  local scenario =
    ScenarioFactory.fromTrainer({ trainer = "rival", party = { fullRecord(), fullRecord() } }, {
      party = party,
      bag = stockedBag(),
    })
  Assert.equal(scenario.format, "single")
  Assert.equal(#scenario.positions, 2)
  local player = playerOf(scenario)
  Assert.equal(#player.roster, 3, "fainted non-eggs stay rostered past the egg")
  Assert.equal(player.roster[1].mon.condition.currentHp, 0, "the fainted lead keeps its roster seat")
  Assert.equal(scenario.positions[1].occupant, player.roster[2].id, "the first conscious member opens")
  Assert.deepEqual(scenario.positions[1].eligibleParticipants, { 1 })
  Assert.deepEqual(scenario.positions[2].eligibleParticipants, { 2 })
end

-- A marked trainer with only one conscious member fields no double:
-- composition fails instead of opening a short side.
function T.marked_doubles_need_two_conscious_enemies()
  local live = { party = mixedParty(), bag = stockedBag() }
  Assert.isTrue(
    not pcall(ScenarioFactory.fromTrainer, {
      trainers = {
        { id = "rival-double", party = { fullRecord(), faintedRecord() }, doubleBattle = true },
      },
    }, live),
    "a marked trainer with one conscious member fields no battle"
  )
end

-- Paired trainers open with their first conscious member each: a
-- fainted lead yields its slot to the living reserve behind it.
function T.paired_trainers_open_with_their_first_conscious_member()
  local live = { party = mixedParty(), bag = stockedBag() }
  local scenario = ScenarioFactory.fromTrainer({
    trainers = {
      { id = "a", party = { faintedRecord(), fullRecord() } },
      { id = "b", party = { fullRecord() } },
    },
  }, live)
  Assert.equal(scenario.format, "double")
  Assert.equal(#scenario.positions, 4)
  local first = scenario.participants[2]
  local second = scenario.participants[3]
  Assert.equal(scenario.positions[3].occupant, first.roster[2].id, "the living reserve opens past its fainted lead")
  Assert.equal(scenario.positions[4].occupant, second.roster[1].id)
end

-- A mark on one of two paired trainers never widens the field: the
-- pair still holds exactly two enemy slots, one per participant.
function T.paired_trainers_share_two_enemy_slots_even_when_marked()
  local live = { party = mixedParty(), bag = stockedBag() }
  local scenario = ScenarioFactory.fromTrainer({
    trainers = {
      { id = "a", party = { fullRecord(), fullRecord() }, doubleBattle = true },
      { id = "b", party = { fullRecord() } },
    },
  }, live)
  Assert.equal(scenario.format, "double")
  Assert.equal(#scenario.positions, 4)
  Assert.equal(#scenario.participants, 3)
  Assert.deepEqual(scenario.positions[3].eligibleParticipants, { 2 })
  Assert.deepEqual(scenario.positions[4].eligibleParticipants, { 3 })
end

-- Paired trainers each need a conscious lead: a trainer whose whole
-- party is fainted fails the pair instead of opening short.
function T.paired_trainers_need_a_conscious_lead_each()
  local live = { party = mixedParty(), bag = stockedBag() }
  Assert.isTrue(
    not pcall(ScenarioFactory.fromTrainer, {
      trainers = {
        { id = "a", party = { fullRecord() } },
        { id = "b", party = { faintedRecord() } },
      },
    }, live),
    "a wholly fainted partner fails the pair"
  )
end

-- A third simultaneous trainer has no native topology here: explicit
-- staged fights own larger fields.
function T.a_third_trainer_has_no_native_topology()
  local live = { party = mixedParty(), bag = stockedBag() }
  Assert.isTrue(
    not pcall(ScenarioFactory.fromTrainer, {
      trainers = {
        { id = "a", party = { fullRecord() } },
        { id = "b", party = { fullRecord() } },
        { id = "c", party = { fullRecord() } },
      },
    }, live),
    "three trainers fail instead of guessing a field"
  )
end

-- An explicit doubles request with full rosters on both sides fields
-- both slots even without a source mark; the mark is only required to
-- forbid the opposite downgrade.
function T.staged_double_format_fields_both_slots_when_rosters_allow()
  local live = { party = mixedParty(), bag = stockedBag() }
  local scenario = ScenarioFactory.fromTrainer({
    format = "double",
    trainers = {
      { id = "rival", party = { fullRecord(), fullRecord() } },
    },
  }, live)
  Assert.equal(scenario.format, "double")
  Assert.equal(#scenario.positions, 4)
  local player = playerOf(scenario)
  local foe = scenario.participants[2]
  Assert.equal(scenario.positions[1].occupant, player.roster[2].id)
  Assert.equal(scenario.positions[2].occupant, player.roster[3].id)
  Assert.equal(scenario.positions[3].occupant, foe.roster[1].id)
  Assert.equal(scenario.positions[4].occupant, foe.roster[2].id)
end

function T.scripted_fights_pass_through_verbatim()
  local sides = { { id = 1, participants = { 1 } }, { id = 2, participants = { 2 } } }
  local participants = {
    { id = 1, side = 1, controller = "player", roster = { { id = 1, mon = fullRecord() } }, context = {} },
    { id = 2, side = 2, controller = "scripted", roster = { { id = 2, mon = fullRecord() } }, context = {} },
  }
  local positions = {
    { id = 1, side = 1, eligibleParticipants = { 1 }, occupant = 1 },
    { id = 2, side = 2, eligibleParticipants = { 2 }, occupant = 2 },
  }
  local scenario = ScenarioFactory.fromScript({
    attemptId = "tutorial-1",
    sides = sides,
    participants = participants,
    positions = positions,
  }, {})
  Assert.equal(scenario.kind, "scripted")
  Assert.equal(scenario.attemptId, "tutorial-1")
  Assert.deepEqual(scenario.sides, sides)
  participants[1].id = 99
  Assert.equal(scenario.participants[1].id, 1, "staged fights detach")
  Assert.isTrue(not pcall(ScenarioFactory.fromScript, { sides = sides }, {}))
end

function T.scripted_inventories_pass_through_without_projection()
  local sides = { { id = 1, participants = { 1 } }, { id = 2, participants = { 2 } } }
  local participants = {
    {
      id = 1,
      side = 1,
      controller = "player",
      roster = { { id = 1, mon = fullRecord() } },
      context = {},
      inventoryId = "staged-supply",
    },
    { id = 2, side = 2, controller = "scripted", roster = { { id = 2, mon = fullRecord() } }, context = {} },
  }
  local positions = {
    { id = 1, side = 1, eligibleParticipants = { 1 }, occupant = 1 },
    { id = 2, side = 2, eligibleParticipants = { 2 }, occupant = 2 },
  }
  local staged = { { id = "staged-supply", owners = { 1 }, quantities = { POTION = 1 } } }
  local scenario = ScenarioFactory.fromScript({
    attemptId = "tutorial-2",
    sides = sides,
    participants = participants,
    positions = positions,
    inventories = staged,
  }, { party = mixedParty(), bag = stockedBag() })
  Assert.deepEqual(scenario.inventories, staged, "staged fights keep their authored stock")
  Assert.equal(#scenario.participants[1].roster, 1, "staged fights gain no live reserves")
end

return { tests = T }
