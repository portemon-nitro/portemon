-- Reusable out-of-battle progression through the shared owners: sweets
-- raise exactly one level with ordered learning chances and report an
-- evolution the new level earns, capped mons keep their sweet, stones
-- stage real evolution plans that spend exactly one item on accept and
-- nothing on decline, and declined stones stay retryable.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Experience = require("libs.mons.src.gen4.Experience")
local ItemFixture = require("libs.items.tests.item_fixture")
local LevelProgression = require("libs.mons.src.gen4.LevelProgression")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonStats = require("libs.mons.src.gen4.MonStats")

local T = {}

---@param name string module path under test
---@param behavior string missing owner under test
---@return table the loaded progression item owner
local function requirePresent(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing mon behavior: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the mon module loads")
  return loaded --[[@as table]]
end

---@param value unknown
---@return unknown detached copy of plain test data
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copy(item)
  end
  return out
end

-- Item identities the vectors need beyond the shared fixture: the level
-- sweet and the evolution stone, re-keyed from deterministic
-- placeholders so counts and pockets stay unchanged.
---@return table item catalog resolving the vector item keys
local function testItemCatalog()
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local root = ItemFixture.buildAssetRoot()
  local swaps = {
    { from = "ITEM_43", to = "RARE_CANDY" },
    { from = "ITEM_210", to = "FIRE_STONE" },
  }
  for _, swap in ipairs(swaps) do
    local record = root.items[swap.from]
    assert(record ~= nil, "the item fixture carries placeholder " .. swap.from)
    root.items[swap.from] = nil
    root.items[swap.to] = record
  end
  return ItemCatalog.new(root)
end

---@return table mon catalog carrying the vector evolution slots
local function vectorCatalog()
  local root = CatalogFixture.buildAssetRoot()
  local species = root.species --[[@as table<string, table<string, unknown>>]]
  local forms = species.CHIKORITA.forms --[[@as table<integer, table<string, unknown>>]]
  forms[0].evolutions = {
    { method = "level", level = 16, target = "TOTODILE", form = 0 },
    { method = "stone", item = "FIRE_STONE", target = "EEVEE", form = 0 },
  }
  return MonCatalog.new(root, testItemCatalog())
end

---@param catalog table mon catalog under test
---@param seed integer fixed generator state for this roster member
---@param overrides table<string, unknown>|nil generation request overrides
---@return table persistent mon record owned by the mon domain
local function makeMon(catalog, seed, overrides)
  local factory = CatalogFixture.makeFactory(seed, catalog)
  return factory:createNormal(CatalogFixture.normalRequest(overrides or {}))
end

---@param mon table mon record under test
---@param catalog table mon catalog under test
---@param level integer pinned level for this vector
---@return table the same mon at exactly the pinned level with full health
local function pinLevel(mon, catalog, level)
  local species = catalog:species(mon.species)
  mon.experience = Experience.expFor(catalog:growthCurve(species.growthCurve), level)
  for _, key in ipairs({ "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }) do
    mon.ivs[key] = 10
    mon.evs[key] = 0
  end
  mon.condition.currentHp = MonStats.derive(mon, catalog).maxHp
  return mon
end

---@param catalog table mon catalog under test
---@param inventory table<string, integer> bag counts visible to the vector
---@return table item-use context with frozen world facts
local function vectorContext(catalog, inventory)
  return {
    catalog = catalog,
    game = "heartgold",
    timeOfDay = "day",
    location = "route_29",
    party = {},
    inventory = inventory,
  }
end

-- Sweets raise exactly one level through the shared progression: the
-- staged record carries the next-level experience, the crossed level,
-- the shared learning chances, and a single spend, while the input
-- never moves and no evolution is reported below the slot level.
function T.sweets_raise_exactly_one_level_through_shared_progression()
  local ItemUse = requirePresent("libs.hgss.src.mons.ProgressionItemUse", "reusable progression item use owns planning")
  Assert.isTrue(type(ItemUse.planLevelItem) == "function", "the item owner plans level items")
  Assert.isTrue(type(ItemUse.planEvolutionItem) == "function", "the item owner plans evolution items")
  local catalog = vectorCatalog()
  local mon = pinLevel(makeMon(catalog, 401, {}), catalog, 9)
  local before = copy(mon)
  local curve = catalog:growthCurve("medium_slow")
  local shared = LevelProgression.award(mon, Experience.expFor(curve, 10) - mon.experience, catalog)
  local result = ItemUse.planLevelItem(mon, "RARE_CANDY", vectorContext(catalog, { RARE_CANDY = 3 }))
  Assert.isTrue(result.applied, "a sweet applies below the cap")
  Assert.equal(result.mon.experience, Experience.expFor(curve, 10), "the staged record carries next-level experience")
  Assert.deepEqual(result.crossedLevels, { 10 }, "exactly one level is crossed")
  Assert.deepEqual(
    result.learningOpportunities,
    shared.learningOpportunities,
    "learning chances match the shared progression"
  )
  Assert.equal(result.maxHpBefore, shared.maxHpBefore, "the refresh opens from the shared maximum")
  Assert.equal(result.maxHpAfter, shared.maxHpAfter, "the refresh lands on the shared maximum")
  Assert.equal(result.consumed, 1, "one sweet is staged for spending")
  Assert.isTrue(result.evolution == nil, "no evolution is reported below the slot level")
  Assert.deepEqual(mon, before, "planning never mutates its input")
end

-- A sweet crossing the slot level reports the earned evolution with the
-- same single spend: the staged record both levels and qualifies.
function T.sweets_report_evolution_when_the_new_level_qualifies()
  local ItemUse = requirePresent("libs.hgss.src.mons.ProgressionItemUse", "reusable progression item use owns planning")
  local catalog = vectorCatalog()
  local curve = catalog:growthCurve("medium_slow")
  local mon = pinLevel(makeMon(catalog, 431, {}), catalog, 15)
  local result = ItemUse.planLevelItem(mon, "RARE_CANDY", vectorContext(catalog, { RARE_CANDY = 1 }))
  Assert.isTrue(result.applied, "the sweet applies")
  Assert.equal(result.mon.experience, Experience.expFor(curve, 16), "the staged record reaches sixteen")
  Assert.equal(result.evolution, "TOTODILE", "the earned evolution is reported")
  Assert.equal(result.consumed, 1, "the qualifying sweet still spends exactly one")
end

-- Capped and empty vectors never consume: a level-one-hundred mon
-- reports no application and no spend, and planning with an empty
-- pocket reports the same.
function T.capped_mons_keep_their_sweets()
  local ItemUse = requirePresent("libs.hgss.src.mons.ProgressionItemUse", "reusable progression item use owns planning")
  local catalog = vectorCatalog()
  local curve = catalog:growthCurve("medium_slow")
  local capped = pinLevel(makeMon(catalog, 443, {}), catalog, 100)
  capped.experience = curve[100]
  local before = copy(capped)
  local refused = ItemUse.planLevelItem(capped, "RARE_CANDY", vectorContext(catalog, { RARE_CANDY = 2 }))
  Assert.isFalse(refused.applied, "a capped mon reports no application")
  Assert.equal(refused.consumed, 0, "a capped mon spends nothing")
  Assert.deepEqual(capped, before, "refusing touches no input")
  local ordinary = pinLevel(makeMon(catalog, 449, {}), catalog, 9)
  local empty = ItemUse.planLevelItem(ordinary, "RARE_CANDY", vectorContext(catalog, { RARE_CANDY = 0 }))
  Assert.isFalse(empty.applied, "an empty pocket reports no application")
  Assert.equal(empty.consumed, 0, "an empty pocket spends nothing")
  Assert.throws(function()
    ItemUse.planLevelItem(ordinary, "POTION", vectorContext(catalog, { POTION = 1 }))
  end, "a non-progressing item fails without consuming")
end

-- Stones stage real evolution plans: the staged plan carries the stone
-- target with exactly one spend on accept and none on decline, a wrong
-- stone or an empty pocket stages nothing, and unknown items fail.
function T.stones_stage_real_plans_and_consume_exactly_once_on_accept()
  local ItemUse = requirePresent("libs.hgss.src.mons.ProgressionItemUse", "reusable progression item use owns planning")
  local catalog = vectorCatalog()
  local mon = pinLevel(makeMon(catalog, 461, {}), catalog, 12)
  local before = copy(mon)
  local staged = ItemUse.planEvolutionItem(mon, "FIRE_STONE", vectorContext(catalog, { FIRE_STONE = 2 }))
  Assert.notNil(staged, "the matching stone stages a plan")
  Assert.equal(staged.plan.monAfter.species, "EEVEE", "the staged plan carries the stone target")
  Assert.equal(staged.consumedOnAccept, 1, "accepting spends exactly one stone")
  Assert.equal(staged.consumedOnCancel, 0, "declining spends nothing")
  Assert.deepEqual(staged.plan.inventoryDeltas, { { item = "FIRE_STONE", delta = -1 } }, "the spend is staged once")
  Assert.deepEqual(mon, before, "staging never mutates its input")
  Assert.isTrue(
    ItemUse.planEvolutionItem(mon, "WATER_STONE", vectorContext(catalog, { WATER_STONE = 2 })) == nil,
    "a wrong stone stages nothing"
  )
  Assert.isTrue(
    ItemUse.planEvolutionItem(mon, "FIRE_STONE", vectorContext(catalog, { FIRE_STONE = 0 })) == nil,
    "an empty pocket stages nothing"
  )
  Assert.throws(function()
    ItemUse.planEvolutionItem(mon, "NOT_AN_ITEM", vectorContext(catalog, {}))
  end, "an unknown item fails without staging")
end

-- Declined stones cost nothing and stay retryable: the bag and the mon
-- match their before-images, planning again stages the same target, and
-- no path ever stages a second spend.
function T.declined_stones_cost_nothing_and_stay_retryable()
  local ItemUse = requirePresent("libs.hgss.src.mons.ProgressionItemUse", "reusable progression item use owns planning")
  local catalog = vectorCatalog()
  local mon = pinLevel(makeMon(catalog, 479, {}), catalog, 12)
  local before = copy(mon)
  local inventory = { FIRE_STONE = 2 }
  local first = ItemUse.planEvolutionItem(mon, "FIRE_STONE", vectorContext(catalog, inventory))
  Assert.notNil(first, "the first plan stages")
  Assert.equal(first.consumedOnCancel, 0, "declining spends nothing")
  Assert.deepEqual(mon, before, "declining touches no mon")
  Assert.deepEqual(inventory, { FIRE_STONE = 2 }, "declining touches no bag")
  local second = ItemUse.planEvolutionItem(mon, "FIRE_STONE", vectorContext(catalog, inventory))
  Assert.notNil(second, "the declined stone stays retryable")
  Assert.equal(second.plan.monAfter.species, "EEVEE", "the retry stages the same target")
  Assert.deepEqual(
    second.plan.inventoryDeltas,
    { { item = "FIRE_STONE", delta = -1 } },
    "the retry stages a single spend"
  )
  Assert.deepEqual(first, second, "repeated planning never diverges")
end

-- Blockers shape sweets but not stones: a sweet crossing the slot level on
-- a blockered mon still levels without reporting an evolution, while a
-- stone bypasses the blocker entirely.
function T.blockers_shape_sweets_but_not_stones()
  local ItemUse = requirePresent("libs.hgss.src.mons.ProgressionItemUse", "reusable progression item use owns planning")
  local catalog = vectorCatalog()
  local curve = catalog:growthCurve("medium_slow")
  local sweet = pinLevel(makeMon(catalog, 491, {}), catalog, 15)
  sweet.heldItem = "EVERSTONE"
  local levelled = ItemUse.planLevelItem(sweet, "RARE_CANDY", vectorContext(catalog, { RARE_CANDY = 1 }))
  Assert.isTrue(levelled.applied, "the sweet still applies")
  Assert.equal(levelled.mon.experience, Experience.expFor(curve, 16), "the staged record still reaches sixteen")
  Assert.isTrue(levelled.evolution == nil, "the blocker suppresses the reported evolution")
  local stoned = pinLevel(makeMon(catalog, 499, {}), catalog, 12)
  stoned.heldItem = "EVERSTONE"
  local staged = ItemUse.planEvolutionItem(stoned, "FIRE_STONE", vectorContext(catalog, { FIRE_STONE = 1 }))
  Assert.notNil(staged, "stone use bypasses the blocker")
  Assert.equal(staged.plan.monAfter.species, "EEVEE", "the staged plan carries the stone target")
end

-- The final sweet lands exactly on the cap through the shared owner.
function T.final_sweets_land_exactly_on_the_cap()
  local ItemUse = requirePresent("libs.hgss.src.mons.ProgressionItemUse", "reusable progression item use owns planning")
  local catalog = vectorCatalog()
  local curve = catalog:growthCurve("medium_slow")
  local mon = pinLevel(makeMon(catalog, 503, {}), catalog, 99)
  local result = ItemUse.planLevelItem(mon, "RARE_CANDY", vectorContext(catalog, { RARE_CANDY = 1 }))
  Assert.isTrue(result.applied, "the final sweet applies")
  Assert.deepEqual(result.crossedLevels, { 100 }, "exactly the cap is crossed")
  Assert.equal(result.mon.experience, Experience.expFor(curve, 100), "experience lands exactly on the cap")
  Assert.equal(result.consumed, 1, "the final sweet spends exactly one")
end

-- A missing sweet identity fails before staging anything.
function T.missing_sweet_identities_fail()
  local ItemUse = requirePresent("libs.hgss.src.mons.ProgressionItemUse", "reusable progression item use owns planning")
  local root = CatalogFixture.buildAssetRoot()
  local bare = MonCatalog.new(root, ItemFixture.makeCatalog())
  local mon = pinLevel(makeMon(bare, 509, {}), bare, 9)
  Assert.throws(function()
    ItemUse.planLevelItem(mon, "RARE_CANDY", vectorContext(bare, { RARE_CANDY = 1 }))
  end, "a sweet missing from selected content fails")
end

return { tests = T }
