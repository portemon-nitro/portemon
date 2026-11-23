-- Reusable Rare Candy planning through the shared owners: one level with
-- the retail health arithmetic, the before and after stat facts, and the
-- ordered learning chances of the new level. Capped mons stage nothing.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Experience = require("libs.mons.src.gen4.Experience")
local ItemFixture = require("libs.items.tests.item_fixture")
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

-- The level sweet, re-keyed from a deterministic placeholder so counts and
-- pockets stay unchanged.
---@return table item catalog resolving the sweet
local function testItemCatalog()
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local root = ItemFixture.buildAssetRoot()
  local swaps = {
    { from = "ITEM_43", to = "RARE_CANDY" },
  }
  for _, swap in ipairs(swaps) do
    local record = root.items[swap.from]
    assert(record ~= nil, "the item fixture carries placeholder " .. swap.from)
    root.items[swap.from] = nil
    root.items[swap.to] = record
  end
  return ItemCatalog.new(root)
end

---@return table mon catalog resolving the vector species and items
local function vectorCatalog()
  return MonCatalog.new(CatalogFixture.buildAssetRoot(), testItemCatalog())
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
---@return table<string, unknown> item-use context
local function vectorContext(catalog)
  return { catalog = catalog }
end

---@param mon table<string, unknown>
---@param catalog table mon catalog under test
---@return table<string, unknown> derived stats of the staged mon facts
local function derive(mon, catalog)
  return MonStats.derive(mon, catalog)
end

-- Sweets raise exactly one level through the shared progression and the
-- input never moves.
function T.sweets_raise_exactly_one_level_through_shared_progression()
  local ItemUse = requirePresent("libs.hgss.src.mons.ProgressionItemUse", "reusable progression item use owns planning")
  local catalog = vectorCatalog()
  local mon = pinLevel(makeMon(catalog, 401, {}), catalog, 9)
  local before = copy(mon)
  local curve = catalog:growthCurve("medium_slow")
  local result = ItemUse.planLevelItem(mon, "RARE_CANDY", vectorContext(catalog))
  Assert.isTrue(result.applied, "a sweet applies below the cap")
  Assert.equal(result.mon.experience, Experience.expFor(curve, 10), "the staged record carries next-level experience")
  Assert.equal(result.level, 10, "the new level is reported")
  Assert.isTrue(result.evolution == nil and result.consumed == nil, "planning decides neither evolution nor spend")
  Assert.deepEqual(mon, before, "planning never mutates its input")
end

-- The stat windows read the derived stats before and after the level.
function T.sweets_report_the_stats_before_and_after()
  local ItemUse = requirePresent("libs.hgss.src.mons.ProgressionItemUse", "reusable progression item use owns planning")
  local catalog = vectorCatalog()
  local mon = pinLevel(makeMon(catalog, 409, {}), catalog, 9)
  local result = ItemUse.planLevelItem(mon, "RARE_CANDY", vectorContext(catalog))
  local old = derive(mon, catalog)
  local new = derive(result.mon, catalog)
  for _, key in ipairs({ "maxHp", "attack", "defense", "specialAttack", "specialDefense", "speed" }) do
    Assert.equal(result.statsBefore[key], old[key], key .. " before")
    Assert.equal(result.statsAfter[key], new[key], key .. " after")
  end
  Assert.isTrue(new.maxHp > old.maxHp, "the level raises the maximum")
end

-- Learning chances cover the new level only, in learnset order.
function T.sweets_offer_only_the_moves_of_the_new_level()
  local ItemUse = requirePresent("libs.hgss.src.mons.ProgressionItemUse", "reusable progression item use owns planning")
  local catalog = vectorCatalog()
  local mon = pinLevel(makeMon(catalog, 601, {}), catalog, 11)
  mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  local result = ItemUse.planLevelItem(mon, "RARE_CANDY", vectorContext(catalog))
  Assert.deepEqual(result.learningOpportunities, { { level = 12, move = "SYNTHESIS" } }, "the level-12 move is offered")
  Assert.equal(#result.mon.moves, 1, "planning learns nothing on its own")
  local later = pinLevel(makeMon(catalog, 603, {}), catalog, 11)
  later.moves = { { move = "TACKLE", pp = 35, ppUps = 0 }, { move = "SYNTHESIS", pp = 5, ppUps = 0 } }
  Assert.deepEqual(
    ItemUse.planLevelItem(later, "RARE_CANDY", vectorContext(catalog)).learningOpportunities,
    {},
    "a known move is not offered again"
  )
end

-- A level-one-hundred mon stages nothing and a foreign item fails.
function T.capped_mons_keep_their_sweets()
  local ItemUse = requirePresent("libs.hgss.src.mons.ProgressionItemUse", "reusable progression item use owns planning")
  local catalog = vectorCatalog()
  local curve = catalog:growthCurve("medium_slow")
  local capped = pinLevel(makeMon(catalog, 443, {}), catalog, 100)
  capped.experience = curve[100]
  local before = copy(capped)
  local refused = ItemUse.planLevelItem(capped, "RARE_CANDY", vectorContext(catalog))
  Assert.deepEqual(refused, { applied = false }, "a capped mon stages nothing")
  Assert.deepEqual(capped, before, "refusing touches no input")
  local ordinary = pinLevel(makeMon(catalog, 449, {}), catalog, 9)
  Assert.throws(function()
    ItemUse.planLevelItem(ordinary, "POTION", vectorContext(catalog))
  end, "a non-progressing item fails")
end

-- The final sweet lands exactly on the cap through the shared owner.
function T.final_sweets_land_exactly_on_the_cap()
  local ItemUse = requirePresent("libs.hgss.src.mons.ProgressionItemUse", "reusable progression item use owns planning")
  local catalog = vectorCatalog()
  local curve = catalog:growthCurve("medium_slow")
  local mon = pinLevel(makeMon(catalog, 503, {}), catalog, 99)
  local result = ItemUse.planLevelItem(mon, "RARE_CANDY", vectorContext(catalog))
  Assert.isTrue(result.applied, "the final sweet applies")
  Assert.equal(result.level, 100, "exactly the cap is reached")
  Assert.equal(result.mon.experience, Experience.expFor(curve, 100), "experience lands exactly on the cap")
end

-- Retail CalcMonStats keeps a living mon's damage by adding the maximum
-- change; a fainted mon stays at zero there and then RestoreMonHPBy raises
-- it by the maximum change, capped at the new maximum.
function T.staged_health_follows_the_retail_order()
  local ItemUse = requirePresent("libs.hgss.src.mons.ProgressionItemUse", "reusable progression item use owns planning")
  local catalog = vectorCatalog()
  local function stage(seed, hp)
    local mon = pinLevel(makeMon(catalog, seed, {}), catalog, 9)
    mon.condition.currentHp = hp(mon.condition.currentHp)
    local result = ItemUse.planLevelItem(mon, "RARE_CANDY", vectorContext(catalog))
    return result.mon.condition.currentHp, result.statsAfter.maxHp - result.statsBefore.maxHp, result.statsAfter.maxHp
  end
  local healthy, delta, newMax = stage(701, function(full)
    return full
  end)
  Assert.equal(healthy, newMax, "a healthy mon stays full")
  local damaged = stage(701, function(full)
    return full - 4
  end)
  Assert.equal(damaged, newMax - 4, "a damaged mon keeps its damage")
  local fainted = stage(701, function()
    return 0
  end)
  Assert.equal(fainted, delta, "a fainted mon is raised by the maximum change")
  Assert.isTrue(delta > 0, "the vector changes the maximum")

  local shedinja = pinLevel(makeMon(catalog, 709, {}), catalog, 9)
  shedinja.species = "SHEDINJA"
  shedinja.condition.currentHp = 1
  local living = ItemUse.planLevelItem(shedinja, "RARE_CANDY", vectorContext(catalog))
  Assert.equal(living.mon.condition.currentHp, 1, "a living one-health mon stays at one")
  Assert.equal(living.statsAfter.maxHp, living.statsBefore.maxHp, "the maximum does not change")
  shedinja.condition.currentHp = 0
  local down = ItemUse.planLevelItem(shedinja, "RARE_CANDY", vectorContext(catalog))
  Assert.equal(down.mon.condition.currentHp, 1, "a fainted one-health mon is restored to one")
end

-- A missing sweet identity fails before staging anything.
function T.missing_sweet_identities_fail()
  local ItemUse = requirePresent("libs.hgss.src.mons.ProgressionItemUse", "reusable progression item use owns planning")
  local bare = MonCatalog.new(CatalogFixture.buildAssetRoot(), ItemFixture.makeCatalog())
  local mon = pinLevel(makeMon(bare, 509, {}), bare, 9)
  Assert.throws(function()
    ItemUse.planLevelItem(mon, "RARE_CANDY", vectorContext(bare))
  end, "a sweet missing from selected content fails")
end

return { tests = T }
