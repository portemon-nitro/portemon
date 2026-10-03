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
  Assert.equal(
    scenario.participants[2].roster[1].mon.condition.currentHp,
    18,
    "trainer records copy once"
  )
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
  Assert.equal(#scenario.positions, 3)
  Assert.equal(scenario.format, "double")
  Assert.equal(scenario.participants[2].controller, "trainer:a")
  Assert.equal(scenario.participants[3].controller, "trainer:b")
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

function T.production_builds_fail_without_a_conscious_combatant()
  local catalog = CatalogFixture.makeCatalog()
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x44444444):capture(), catalog:fingerprint()),
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
  Assert.isTrue(
    not pcall(ScenarioFactory.fromEncounter, wildPayload(), live),
    "a wiped party builds no wild scenario"
  )
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
  Assert.deepEqual(
    first.context.items,
    { "POTION", "POTION", "POKE_BALL" },
    "the decision context keeps the carried item list"
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
