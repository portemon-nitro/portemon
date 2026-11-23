-- Party progression actions over the live mon and bag services: a Rare
-- Candy publishes its level and spends once, an evolution item stages
-- nothing until the completed evolution publishes with its spend, and
-- level-up learning decisions publish one move change each.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local EvolutionFlow = require("libs.hgss.src.mons.EvolutionFlow")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PartyActions = require("libs.hgss.src.field.PartyActions")

local function itemRecord(nativeId, key, partyUse)
  return {
    nativeId = nativeId,
    price = 0,
    pocket = "items",
    name = key,
    nameIndefinite = "a " .. key,
    namePlural = key .. "s",
    description = key .. " description",
    preventToss = false,
    selectable = true,
    isBall = false,
    friendshipBoost = false,
    icon = key,
    isHm = false,
    canHold = true,
    heldFormEffect = "none",
    partyUse = partyUse,
    battlePocket = 4,
    battleUseFunc = 0,
  }
end

local function openServices()
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local itemRoot = ItemFixture.buildAssetRoot()
  itemRoot.items.ITEM_50 = nil
  itemRoot.items.ITEM_82 = nil
  itemRoot.items.RARE_CANDY = itemRecord(50, "RARE_CANDY", {
    kind = "deferred",
    reason = "level_up",
    friendship = { lo = 5, med = 3, hi = 2 },
  })
  itemRoot.items.FIRE_STONE = itemRecord(82, "FIRE_STONE", { kind = "deferred", reason = "evolution" })
  local itemCatalog = ItemCatalog.new(itemRoot)
  local monRoot = CatalogFixture.buildAssetRoot()
  monRoot.species.CHIKORITA.forms[0].evolutions = {
    { method = "stone", target = "TOTODILE", form = 0, item = "FIRE_STONE" },
  }
  local catalog = MonCatalog.new(monRoot, itemCatalog)
  local mons = require("libs.hgss.src.mons.HgssMonService").new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x33333333):capture()),
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
  local bag = require("libs.hgss.src.items.HgssBagService").new({ catalog = itemCatalog })
  local factory = CatalogFixture.makeFactory(0x44444444, catalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA", level = 9 }))
  Assert.isTrue(mons:addMon(mon), "setup mon must enter the party")
  return mons, bag, PartyActions.new({ mons = mons, bag = bag }), catalog
end

local function request(mons, bag, fields)
  local out = { slot = 0, partyRevision = mons:partyRevision(), bagRevision = bag:revision() }
  for key, value in pairs(fields) do
    out[key] = value
  end
  return out
end

local T = {}

function T.rare_candy_levels_once_and_reports_its_learning()
  local mons, bag, actions = openServices()
  Assert.isTrue(bag:add("RARE_CANDY", 2))
  local before = mons:derive(mons:partyMon(0))
  local friendshipBefore = mons:partyMon(0).friendship
  local outcome = actions:commit(request(mons, bag, { kind = "use_item", item = "RARE_CANDY" }))
  Assert.equal(outcome.kind, "changed")
  Assert.equal(mons:derive(mons:partyMon(0)).level, before.level + 1, "one candy raises exactly one level")
  Assert.equal(bag:quantity("RARE_CANDY"), 1, "one candy is spent")
  Assert.equal(outcome.feedback.textKey, "level_up")
  Assert.equal(outcome.feedback.statsBefore.maxHp, before.maxHp, "the stat window reads the prior totals")
  Assert.equal(mons:partyMon(0).friendship, friendshipBefore + 5, "the low friendship band applies")
end

function T.rare_candy_at_level_one_hundred_spends_nothing()
  local mons, bag, actions = openServices()
  local mon = mons:partyMon(0)
  local catalog = mons:catalog()
  mon.experience = catalog:growthCurve(catalog:species("CHIKORITA").growthCurve)[100]
  local change = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 0, mon = mon } }))
  change.publish()
  Assert.isTrue(bag:add("RARE_CANDY", 1))
  local outcome = actions:commit(request(mons, bag, { kind = "use_item", item = "RARE_CANDY" }))
  Assert.equal(outcome.kind, "no_effect")
  Assert.equal(bag:quantity("RARE_CANDY"), 1, "a refused candy is not spent")
end

function T.learning_fills_free_slots_and_replaces_full_sets()
  local mons, bag, actions = openServices()
  local known = mons:partyMon(0).moves
  Assert.equal(#known, 4, "the level-nine fixture knows four moves")
  Assert.equal(
    actions:commit(request(mons, bag, { kind = "learn_move", move = known[1].move })).kind,
    "known",
    "a known move is refused"
  )
  Assert.equal(
    actions:preview(request(mons, bag, { kind = "learn_move", move = "SYNTHESIS" })).kind,
    "needs_replacement",
    "a full set needs a replacement slot"
  )
  local replaced = actions:commit(request(mons, bag, { kind = "learn_move", move = "SYNTHESIS", moveSlot = 1 }))
  Assert.equal(replaced.kind, "changed")
  Assert.equal(replaced.feedback.bindings.forgotten, known[2].move, "the replacement names the forgotten move")
  Assert.equal(mons:partyMon(0).moves[2].move, "SYNTHESIS")
end

function T.evolution_items_spend_only_with_the_published_evolution()
  local mons, bag, actions, catalog = openServices()
  Assert.isTrue(bag:add("FIRE_STONE", 1))
  local use = request(mons, bag, { kind = "use_item", item = "FIRE_STONE" })
  Assert.equal(actions:commit(use).kind, "evolution", "a matching stone hands off to the evolution scene")
  Assert.equal(bag:quantity("FIRE_STONE"), 1, "the handoff spends nothing")

  local flow = assert(EvolutionFlow.start(mons:partyMon(0), {
    trigger = { kind = "item", item = "FIRE_STONE" },
    party = { mons:partyMon(0) },
    inventory = { FIRE_STONE = 1 },
  }, catalog))
  EvolutionFlow.respond(flow, { choice = "accept" })
  while EvolutionFlow.step(flow).prompt ~= "complete" do
    EvolutionFlow.respond(flow, { choice = "continue" })
  end
  local result = assert(EvolutionFlow.capture(flow))
  local evolve = request(mons, bag, { kind = "evolve", item = "FIRE_STONE", evolution = result })
  Assert.equal(actions:commit(evolve).kind, "changed")
  Assert.equal(mons:partyMon(0).species, "TOTODILE", "the evolved mon publishes")
  Assert.equal(bag:quantity("FIRE_STONE"), 0, "the stone is spent with the evolution")
  Assert.equal(actions:commit(evolve).kind, "stale", "a replayed publication is refused")
end

return { tests = T }
