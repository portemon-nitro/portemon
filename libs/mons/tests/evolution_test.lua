-- Ordered evolution eligibility and candidate planning over native slots.
-- Earlier matching slots win, each trigger context answers only its own
-- trigger family, held and world restrictions hold, side products need a
-- free party slot and a spare ball, custom names survive while default
-- names follow the new species, and every staged result recalculates
-- through the shared stat owners without touching its input.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Experience = require("libs.mons.src.gen4.Experience")
local ItemFixture = require("libs.items.tests.item_fixture")
local Mon = require("libs.mons.src.Mon")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonStats = require("libs.mons.src.gen4.MonStats")
local Personality = require("libs.mons.src.gen4.Personality")

local T = {}

---@param name string module path under test
---@param behavior string missing owner under test
---@return table the loaded evolution owner
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

-- Item identities the vectors need beyond the shared fixture: level and
-- evolution consumables plus the evolution blocker, re-keyed from
-- deterministic placeholders so counts and pockets stay unchanged.
---@return table item catalog resolving the vector item keys
local function testItemCatalog()
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local root = ItemFixture.buildAssetRoot()
  local swaps = {
    { from = "ITEM_43", to = "RARE_CANDY" },
    { from = "ITEM_204", to = "EVERSTONE" },
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

---@param root table<string, unknown> mutable synthetic mon asset root
local function addNincadaLine(root)
  local species = root.species --[[@as table<string, table<string, unknown>>]]
  local function stats(hp, attack, defense, speed, specialAttack, specialDefense)
    return {
      hp = hp,
      attack = attack,
      defense = defense,
      speed = speed,
      specialAttack = specialAttack,
      specialDefense = specialDefense,
    }
  end
  local function form(baseStats, abilities, learnset, evolutions)
    return {
      baseStats = baseStats,
      types = { "bug", "ground" },
      abilities = abilities,
      tmhm = {},
      levelUpMoves = learnset,
      evolutions = evolutions,
      icon = "NINCADA/f0",
      portrait = "NINCADA/f0/male/plain",
    }
  end
  local held = {
    common = { item = "NONE", nativeId = 0 },
    rare = { item = "NONE", nativeId = 0 },
  }
  species.NINCADA = {
    nativeId = 290,
    name = "NINCADA",
    growthCurve = "erratic",
    baseFriendship = 70,
    genderRatio = 31,
    eggCycles = 15,
    eggGroups = { "bug", "bug" },
    catchRate = 255,
    baseExpYield = 65,
    evYield = stats(0, 0, 1, 0, 0, 0),
    heldItems = copy(held),
    color = 3,
    flip = false,
    forms = {
      [0] = form(stats(31, 45, 90, 40, 30, 30), { "COMPOUND_EYES" }, {
        { level = 1, move = "SCRATCH" },
        { level = 1, move = "HARDEN" },
      }, {
        { method = "level_ninjask", level = 20, target = "NINJASK", form = 0 },
        { method = "level_shedinja", level = 20, target = "SHEDINJA", form = 0 },
      }),
    },
  }
  species.NINJASK = {
    nativeId = 291,
    name = "NINJASK",
    growthCurve = "erratic",
    baseFriendship = 70,
    genderRatio = 31,
    eggCycles = 15,
    eggGroups = { "bug", "bug" },
    catchRate = 120,
    baseExpYield = 155,
    evYield = stats(0, 0, 0, 2, 0, 0),
    heldItems = copy(held),
    color = 3,
    flip = false,
    forms = {
      [0] = form(stats(61, 90, 45, 160, 50, 50), { "SPEED_BOOST" }, {
        { level = 1, move = "SCRATCH" },
        { level = 1, move = "HARDEN" },
      }, {}),
    },
  }
  local abilities = root.abilities --[[@as table<string, table<string, unknown>>]]
  abilities.COMPOUND_EYES = { nativeId = 14, name = "Compound Eyes", description = "Compound Eyes" }
  abilities.SPEED_BOOST = { nativeId = 3, name = "Speed Boost", description = "Speed Boost" }
end

-- Exception species for the native eligibility gates: one baby species
-- with a plain form and a marked form carrying identical matching slots,
-- plus one trade-evolving species with level, trade, and stone slots.
---@param root table<string, unknown> mutable synthetic mon asset root
local function addExceptionSpecies(root)
  local species = root.species --[[@as table<string, table<string, unknown>>]]
  local function stats(hp, attack, defense, speed, specialAttack, specialDefense)
    return {
      hp = hp,
      attack = attack,
      defense = defense,
      speed = speed,
      specialAttack = specialAttack,
      specialDefense = specialDefense,
    }
  end
  local function form(evolutions)
    return {
      baseStats = stats(20, 40, 15, 60, 35, 35),
      types = { "electric" },
      abilities = { "STATIC" },
      tmhm = {},
      levelUpMoves = {
        { level = 1, move = "TACKLE" },
        { level = 1, move = "GROWL" },
      },
      evolutions = evolutions,
      icon = "PICHU/f0",
      portrait = "PICHU/f0/male/plain",
    }
  end
  local held = {
    common = { item = "NONE", nativeId = 0 },
    rare = { item = "NONE", nativeId = 0 },
  }
  local babySlots = {
    { method = "level", level = 10, target = "TOTODILE", form = 0 },
    { method = "stone", item = "FIRE_STONE", target = "EEVEE", form = 0 },
    { method = "trade", target = "SHEDINJA", form = 0 },
  }
  species.PICHU = {
    nativeId = 172,
    name = "PICHU",
    growthCurve = "medium_fast",
    baseFriendship = 70,
    genderRatio = 31,
    eggCycles = 10,
    eggGroups = { "undiscovered", "undiscovered" },
    catchRate = 190,
    baseExpYield = 42,
    evYield = stats(0, 0, 0, 1, 0, 0),
    heldItems = copy(held),
    color = 3,
    flip = false,
    forms = {
      [0] = form(copy(babySlots)),
      [1] = form(copy(babySlots)),
    },
  }
  species.KADABRA = {
    nativeId = 64,
    name = "KADABRA",
    growthCurve = "medium_slow",
    baseFriendship = 70,
    genderRatio = 31,
    eggCycles = 20,
    eggGroups = { "human_like", "human_like" },
    catchRate = 100,
    baseExpYield = 145,
    evYield = stats(0, 0, 0, 0, 2, 0),
    heldItems = copy(held),
    color = 3,
    flip = false,
    forms = {
      [0] = form({
        { method = "level", level = 10, target = "TOTODILE", form = 0 },
        { method = "stone", item = "FIRE_STONE", target = "EEVEE", form = 0 },
        { method = "trade", target = "SHEDINJA", form = 0 },
      }),
    },
  }
  local abilities = root.abilities --[[@as table<string, table<string, unknown>>]]
  abilities.STATIC = { nativeId = 9, name = "Static", description = "Static" }
end

---@param mutate fun(root: table<string, unknown>)|nil slot and species edits for one vector
---@return table mon catalog carrying exactly the vector slots
local function buildCatalog(mutate)
  local root = CatalogFixture.buildAssetRoot()
  if mutate ~= nil then
    mutate(root)
  end
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

---@param overrides table<string, unknown>|nil world and trigger facts for one vector
---@return table trigger context with frozen clock, location, and party facts
local function vectorContext(overrides)
  local context = {
    game = "heartgold",
    timeOfDay = "day",
    location = "route_29",
    party = {},
    inventory = {},
    trigger = { kind = "level" },
  }
  for key, value in pairs(overrides or {}) do
    context[key] = value
  end
  return context
end

-- Ordered level slots answer the first match: a level-sixteen mon takes
-- the earlier sixteen slot even though the later ten slot also matches, a
-- level-twelve mon takes the ten slot, and a level-nine mon takes nothing.
function T.level_slots_match_in_order_with_first_match_winning()
  local Evolution = requirePresent("libs.mons.src.gen4.Evolution", "pure native evolution planning owns eligibility")
  Assert.isTrue(type(Evolution.check) == "function", "the evolution owner checks eligibility")
  Assert.isTrue(type(Evolution.plan) == "function", "the evolution owner stages candidate results")
  Assert.isTrue(type(Evolution.applyNamePolicy) == "function", "the evolution owner stages naming")
  local catalog = buildCatalog(function(root)
    local species = root.species --[[@as table<string, table<string, unknown>>]]
    local forms = species.CHIKORITA.forms --[[@as table<integer, table<string, unknown>>]]
    forms[0].evolutions = {
      { method = "level", level = 16, target = "TOTODILE", form = 0 },
      { method = "level", level = 10, target = "EEVEE", form = 0 },
    }
  end)
  local grown = pinLevel(makeMon(catalog, 11, {}), catalog, 16)
  local found = Evolution.check(grown, vectorContext(), catalog)
  Assert.notNil(found, "a level-sixteen mon matches a level slot")
  Assert.equal(found.method, "level", "the match reports its native method")
  Assert.equal(found.target, "TOTODILE", "the earlier matching slot wins")
  local middle = pinLevel(makeMon(catalog, 23, {}), catalog, 12)
  local second = Evolution.check(middle, vectorContext(), catalog)
  Assert.notNil(second, "a level-twelve mon still matches")
  Assert.equal(second.target, "EEVEE", "the later slot answers once the earlier stops matching")
  local young = pinLevel(makeMon(catalog, 37, {}), catalog, 9)
  Assert.isTrue(Evolution.check(young, vectorContext(), catalog) == nil, "a level-nine mon matches no slot")
  Assert.isTrue(Evolution.plan(young, vectorContext(), catalog) == nil, "planning nothing stages no plan")
  local staged = Evolution.plan(grown, vectorContext(), catalog)
  Assert.notNil(staged, "a matching mon stages a plan")
  Assert.equal(staged.monAfter.species, "TOTODILE", "the staged result carries the winning target")
end

-- Each trigger family answers only its own context: a friendly daytime
-- mon matches the daytime bond slot but neither the night slot nor a low
-- bond, a stone matches only its own kind under item use, trade matches
-- only trade context, a known move and a present party species match
-- under level context, and plain bonds ignore the clock.
function T.each_trigger_family_answers_only_its_own_context()
  local Evolution = requirePresent("libs.mons.src.gen4.Evolution", "pure native evolution planning owns eligibility")
  local catalog = buildCatalog(function(root)
    local species = root.species --[[@as table<string, table<string, unknown>>]]
    local forms = species.CHIKORITA.forms --[[@as table<integer, table<string, unknown>>]]
    forms[0].evolutions = {
      { method = "friendship_day", target = "TOTODILE", form = 0 },
      { method = "friendship", target = "EEVEE", form = 0 },
      { method = "friendship_night", target = "SHEDINJA", form = 0 },
      { method = "stone", item = "FIRE_STONE", target = "EEVEE", form = 0 },
      { method = "trade", target = "SHEDINJA", form = 0 },
      { method = "has_move", move = "CUT", target = "TOTODILE", form = 0 },
      { method = "other_party_mon", species = "TOTODILE", target = "SHEDINJA", form = 0 },
    }
  end)
  local bonded = pinLevel(makeMon(catalog, 51, {}), catalog, 12)
  bonded.friendship = 220
  local day = Evolution.check(bonded, vectorContext({ timeOfDay = "day" }), catalog)
  Assert.notNil(day, "a bonded daytime mon matches")
  Assert.equal(day.target, "TOTODILE", "the daytime bond slot answers first in order")
  Assert.isTrue(
    Evolution.check(bonded, vectorContext({ timeOfDay = "night" }), catalog) ~= nil,
    "a bonded night mon still matches a bond slot"
  )
  local night = Evolution.check(bonded, vectorContext({ timeOfDay = "night" }), catalog)
  Assert.notNil(night, "the night vector matches")
  Assert.equal(night.target, "EEVEE", "the clock-free bond slot answers at night")
  local nightOnly = buildCatalog(function(root)
    local species = root.species --[[@as table<string, table<string, unknown>>]]
    local forms = species.CHIKORITA.forms --[[@as table<integer, table<string, unknown>>]]
    forms[0].evolutions = {
      { method = "friendship_night", target = "SHEDINJA", form = 0 },
    }
  end)
  local owl = pinLevel(makeMon(nightOnly, 53, {}), nightOnly, 12)
  owl.friendship = 220
  local owlFound = Evolution.check(owl, vectorContext({ timeOfDay = "night" }), nightOnly)
  Assert.notNil(owlFound, "a bonded night mon matches the night slot")
  Assert.equal(owlFound.target, "SHEDINJA", "the night bond slot answers")
  Assert.isTrue(
    Evolution.check(owl, vectorContext({ timeOfDay = "day" }), nightOnly) == nil,
    "the night slot waits for nightfall"
  )
  local cool = pinLevel(makeMon(catalog, 61, {}), catalog, 12)
  cool.friendship = 219
  Assert.isTrue(
    Evolution.check(cool, vectorContext({ timeOfDay = "day" }), catalog) == nil,
    "a bond one point short matches nothing"
  )
  local stoned = pinLevel(makeMon(catalog, 71, {}), catalog, 12)
  local stone = Evolution.check(stoned, vectorContext({ trigger = { kind = "item", item = "FIRE_STONE" } }), catalog)
  Assert.notNil(stone, "the matching stone matches under item use")
  Assert.equal(stone.target, "EEVEE", "the stone slot carries its own target")
  Assert.isTrue(
    Evolution.check(stoned, vectorContext({ trigger = { kind = "item", item = "WATER_STONE" } }), catalog) == nil,
    "a different stone matches nothing"
  )
  Assert.isTrue(
    Evolution.check(stoned, vectorContext(), catalog) == nil,
    "a stone slot never answers plain level context"
  )
  local traded = Evolution.check(stoned, vectorContext({ trigger = { kind = "trade" } }), catalog)
  Assert.notNil(traded, "trade context matches the trade slot")
  Assert.equal(traded.target, "SHEDINJA", "the trade slot carries its own target")
  local cutter = pinLevel(makeMon(catalog, 83, {}), catalog, 12)
  cutter.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "CUT", pp = 30, ppUps = 0 },
  }
  local known = Evolution.check(cutter, vectorContext(), catalog)
  Assert.notNil(known, "a mon knowing the named move matches")
  Assert.equal(known.target, "TOTODILE", "the move slot carries its own target")
  local plain = pinLevel(makeMon(catalog, 97, {}), catalog, 12)
  Assert.isTrue(Evolution.check(plain, vectorContext(), catalog) == nil, "a mon missing the move matches nothing")
  local companion = pinLevel(makeMon(catalog, 101, { species = "TOTODILE" }), catalog, 12)
  local hosted = pinLevel(makeMon(catalog, 103, {}), catalog, 12)
  local party = Evolution.check(hosted, vectorContext({ party = { hosted, companion } }), catalog)
  Assert.notNil(party, "a party carrying the named species matches")
  Assert.equal(party.target, "SHEDINJA", "the party slot carries its own target")
  Assert.isTrue(
    Evolution.check(hosted, vectorContext({ party = { hosted } }), catalog) == nil,
    "a party missing the named species matches nothing"
  )
end

-- Gender, stat-comparison, and personality branches follow their source
-- predicates: the male and female slots split on the personality low byte
-- against the species ratio, the attack/defense slots split on derived
-- battle stats, and the personality slots split on the high-half residue.
function T.conditional_level_branches_follow_gender_stats_and_personality()
  local Evolution = requirePresent("libs.mons.src.gen4.Evolution", "pure native evolution planning owns eligibility")
  local genders = buildCatalog(function(root)
    local species = root.species --[[@as table<string, table<string, unknown>>]]
    local forms = species.CHIKORITA.forms --[[@as table<integer, table<string, unknown>>]]
    forms[0].evolutions = {
      { method = "level_male", level = 20, target = "TOTODILE", form = 0 },
      { method = "level_female", level = 20, target = "EEVEE", form = 0 },
    }
  end)
  local lass = pinLevel(makeMon(genders, 111, {}), genders, 20)
  lass.personality = 12
  Assert.equal(Personality.gender(31, lass.personality), "female", "the vector personality reads female")
  local lassFound = Evolution.check(lass, vectorContext(), genders)
  Assert.notNil(lassFound, "a female mon matches the female slot")
  Assert.equal(lassFound.target, "EEVEE", "the female slot answers")
  local lad = pinLevel(makeMon(genders, 127, {}), genders, 20)
  lad.personality = 50
  Assert.equal(Personality.gender(31, lad.personality), "male", "the vector personality reads male")
  local ladFound = Evolution.check(lad, vectorContext(), genders)
  Assert.notNil(ladFound, "a male mon matches the male slot")
  Assert.equal(ladFound.target, "TOTODILE", "the ordered male slot answers first")
  local stats = buildCatalog(function(root)
    local species = root.species --[[@as table<string, table<string, unknown>>]]
    local forms = species.CHIKORITA.forms --[[@as table<integer, table<string, unknown>>]]
    forms[0].evolutions = {
      { method = "level_atk_gt_def", level = 20, target = "TOTODILE", form = 0 },
      { method = "level_atk_eq_def", level = 20, target = "EEVEE", form = 0 },
      { method = "level_atk_lt_def", level = 20, target = "SHEDINJA", form = 0 },
    }
  end)
  local striker = pinLevel(makeMon(stats, 131, {}), stats, 20)
  striker.personality = 12
  striker.ivs.attack = 31
  striker.ivs.defense = 0
  striker.evs.attack = 252
  local heavy = Evolution.check(striker, vectorContext(), stats)
  Assert.notNil(heavy, "a hard-hitting mon matches the comparison slots")
  Assert.equal(heavy.target, "TOTODILE", "greater attack answers first")
  local balanced = pinLevel(makeMon(stats, 137, {}), stats, 20)
  balanced.personality = 12
  balanced.ivs.attack = 31
  balanced.ivs.defense = 31
  balanced.evs.attack = 252
  balanced.evs.defense = 124
  local derived = MonStats.derive(balanced, stats)
  Assert.equal(derived.attack, derived.defense, "the vector stats tie exactly")
  local even = Evolution.check(balanced, vectorContext(), stats)
  Assert.notNil(even, "a tied mon matches the comparison slots")
  Assert.equal(even.target, "EEVEE", "equal stats skip the greater slot")
  local guard = pinLevel(makeMon(stats, 139, {}), stats, 20)
  guard.personality = 12
  guard.ivs.attack = 0
  guard.ivs.defense = 31
  local soft = Evolution.check(guard, vectorContext(), stats)
  Assert.notNil(soft, "a frail mon matches the comparison slots")
  Assert.equal(soft.target, "SHEDINJA", "lesser attack falls to the final slot")
  local residues = buildCatalog(function(root)
    local species = root.species --[[@as table<string, table<string, unknown>>]]
    local forms = species.CHIKORITA.forms --[[@as table<integer, table<string, unknown>>]]
    forms[0].evolutions = {
      { method = "level_pid_lo", level = 20, target = "TOTODILE", form = 0 },
      { method = "level_pid_hi", level = 20, target = "EEVEE", form = 0 },
    }
  end)
  local low = pinLevel(makeMon(residues, 149, {}), residues, 20)
  low.personality = 0
  local lowFound = Evolution.check(low, vectorContext(), residues)
  Assert.notNil(lowFound, "a low-residue personality matches")
  Assert.equal(lowFound.target, "TOTODILE", "the low branch answers")
  local high = pinLevel(makeMon(residues, 151, {}), residues, 20)
  high.personality = 327680
  local highFound = Evolution.check(high, vectorContext(), residues)
  Assert.notNil(highFound, "a high-residue personality matches")
  Assert.equal(highFound.target, "EEVEE", "the high branch answers")
end

-- Day/night stones, gendered stones, held trade items, and beauty use
-- the present context, while world-gated triggers never open inside
-- either game: no location string makes them available.
function T.day_night_and_world_gated_methods_use_present_context()
  local Evolution = requirePresent("libs.mons.src.gen4.Evolution", "pure native evolution planning owns eligibility")
  local catalog = buildCatalog(function(root)
    local species = root.species --[[@as table<string, table<string, unknown>>]]
    local forms = species.CHIKORITA.forms --[[@as table<integer, table<string, unknown>>]]
    forms[0].evolutions = {
      { method = "item_day", item = "SUN_STONE", target = "TOTODILE", form = 0 },
      { method = "item_night", item = "MOON_STONE", target = "EEVEE", form = 0 },
      { method = "stone_male", item = "DAWN_STONE", target = "TOTODILE", form = 0 },
      { method = "stone_female", item = "DAWN_STONE", target = "EEVEE", form = 0 },
      { method = "coronet", target = "TOTODILE", form = 0 },
      { method = "eterna", target = "EEVEE", form = 0 },
      { method = "route217", target = "SHEDINJA", form = 0 },
      { method = "trade_item", item = "FIRE_STONE", target = "TOTODILE", form = 0 },
      { method = "beauty", threshold = 170, target = "EEVEE", form = 0 },
    }
  end)
  local function stoneVector(seed, item)
    return Evolution.check(
      pinLevel(makeMon(catalog, seed, {}), catalog, 12),
      vectorContext({ trigger = { kind = "item", item = item } }),
      catalog
    )
  end
  local sunNight = Evolution.check(
    pinLevel(makeMon(catalog, 163, {}), catalog, 12),
    vectorContext({ timeOfDay = "night", trigger = { kind = "item", item = "SUN_STONE" } }),
    catalog
  )
  Assert.isTrue(sunNight == nil, "the day stone waits for daylight")
  local sunDay = Evolution.check(
    pinLevel(makeMon(catalog, 163, {}), catalog, 12),
    vectorContext({ timeOfDay = "day", trigger = { kind = "item", item = "SUN_STONE" } }),
    catalog
  )
  Assert.notNil(sunDay, "the day stone matches by day")
  Assert.equal(sunDay.target, "TOTODILE", "the day slot carries its own target")
  local moon = Evolution.check(
    pinLevel(makeMon(catalog, 167, {}), catalog, 12),
    vectorContext({ timeOfDay = "night", trigger = { kind = "item", item = "MOON_STONE" } }),
    catalog
  )
  Assert.notNil(moon, "the night stone matches by night")
  Assert.equal(moon.target, "EEVEE", "the night slot carries its own target")
  Assert.isTrue(stoneVector(167, "MOON_STONE") == nil, "the night stone waits for nightfall")
  local lad = pinLevel(makeMon(catalog, 173, {}), catalog, 12)
  lad.personality = 50
  local dawnLad = Evolution.check(
    lad,
    vectorContext({ trigger = { kind = "item", item = "DAWN_STONE" } }),
    catalog
  )
  Assert.notNil(dawnLad, "a male mon matches the gendered stone")
  Assert.equal(dawnLad.target, "TOTODILE", "the male stone slot answers")
  local lass = pinLevel(makeMon(catalog, 179, {}), catalog, 12)
  lass.personality = 12
  local dawnLass = Evolution.check(
    lass,
    vectorContext({ trigger = { kind = "item", item = "DAWN_STONE" } }),
    catalog
  )
  Assert.notNil(dawnLass, "a female mon matches the gendered stone")
  Assert.equal(dawnLass.target, "EEVEE", "the female stone slot answers")
  local holder = pinLevel(makeMon(catalog, 181, {}), catalog, 12)
  holder.heldItem = "FIRE_STONE"
  local heldTrade = Evolution.check(holder, vectorContext({ trigger = { kind = "trade" } }), catalog)
  Assert.notNil(heldTrade, "trade while holding the named item matches")
  Assert.equal(heldTrade.target, "TOTODILE", "the held trade slot answers")
  local bare = pinLevel(makeMon(catalog, 183, {}), catalog, 12)
  Assert.isTrue(
    Evolution.check(bare, vectorContext({ trigger = { kind = "trade" } }), catalog) == nil,
    "trade without the held item matches nothing"
  )
  Assert.isTrue(
    Evolution.check(holder, vectorContext(), catalog) == nil,
    "a held trade item never answers plain level context"
  )
  local lovely = pinLevel(makeMon(catalog, 191, {}), catalog, 12)
  lovely.contest.beauty = 170
  local pretty = Evolution.check(lovely, vectorContext(), catalog)
  Assert.notNil(pretty, "threshold beauty matches")
  Assert.equal(pretty.target, "EEVEE", "the beauty slot answers")
  local plain = pinLevel(makeMon(catalog, 193, {}), catalog, 12)
  plain.contest.beauty = 169
  Assert.isTrue(Evolution.check(plain, vectorContext(), catalog) == nil, "beauty one point short matches nothing")
  for _, game in ipairs({ "heartgold", "soulsilver" }) do
    local traveler = pinLevel(makeMon(catalog, 197, {}), catalog, 30)
    Assert.isTrue(
      Evolution.check(traveler, vectorContext({ game = game, location = "mt_coronet" }), catalog) == nil,
      "world-gated triggers stay closed in " .. game
    )
  end
end

-- A held blocker stops level triggers cold: the same mon matches bare
-- but matches nothing while holding it.
function T.held_blockers_stop_level_triggers()
  local Evolution = requirePresent("libs.mons.src.gen4.Evolution", "pure native evolution planning owns eligibility")
  local catalog = buildCatalog(function(root)
    local species = root.species --[[@as table<string, table<string, unknown>>]]
    local forms = species.CHIKORITA.forms --[[@as table<integer, table<string, unknown>>]]
    forms[0].evolutions = {
      { method = "level", level = 16, target = "TOTODILE", form = 0 },
    }
  end)
  local bare = pinLevel(makeMon(catalog, 211, {}), catalog, 16)
  Assert.notNil(Evolution.check(bare, vectorContext(), catalog), "the bare mon matches its level slot")
  local held = pinLevel(makeMon(catalog, 223, {}), catalog, 16)
  held.heldItem = "EVERSTONE"
  Assert.isTrue(
    Evolution.check(held, vectorContext(), catalog) == nil,
    "the held blocker stops the same level trigger"
  )
end

-- The side product needs both a free party slot and a spare ball: with
-- room and a ball the plan stages the extra mon and spends one ball,
-- while a full party or an empty bag still evolves the primary alone
-- with no fallback placement anywhere else.
function T.side_products_need_a_free_slot_and_a_spare_ball()
  local Evolution = requirePresent("libs.mons.src.gen4.Evolution", "pure native evolution planning owns eligibility")
  local catalog = buildCatalog(addNincadaLine)
  local function partyMon(seed)
    return pinLevel(makeMon(catalog, seed, { species = "NINCADA" }), catalog, 20)
  end
  local mon = partyMon(227)
  local mate = pinLevel(makeMon(catalog, 229, {}), catalog, 9)
  local roomy = vectorContext({ party = { mon, mate }, inventory = { POKE_BALL = 5 } })
  local staged = Evolution.plan(mon, roomy, catalog)
  Assert.notNil(staged, "a level-twenty line member stages a plan")
  Assert.equal(staged.monAfter.species, "NINJASK", "the primary result carries the line target")
  Assert.equal(#staged.additionalMons, 1, "room plus a ball stages exactly one extra mon")
  local extra = staged.additionalMons[1]
  Assert.equal(extra.species, "SHEDINJA", "the extra mon is the shed side product")
  Assert.equal(extra.form, 0, "the extra mon takes the slotted form")
  Assert.equal(
    Experience.level(catalog:growthCurve("erratic"), extra.experience),
    Experience.level(catalog:growthCurve("erratic"), staged.monAfter.experience),
    "the extra mon shares the primary level"
  )
  Assert.equal(extra.condition.currentHp, 1, "the single-health extra arrives full")
  Assert.isTrue(extra.nickname == nil, "the extra mon starts under the species default name")
  Mon.validate(extra, CatalogFixture.domainContext(catalog))
  local spent = false
  for _, delta in ipairs(staged.inventoryDeltas) do
    if delta.item == "POKE_BALL" then
      Assert.equal(delta.delta, -1, "the side product spends exactly one ball")
      spent = true
    end
  end
  Assert.isTrue(spent, "the ball spend is staged explicitly")
  Assert.deepEqual(mon, partyMon(227), "planning never mutates its input")
  local crowded = { mon }
  for seed = 231, 235 do
    crowded[#crowded + 1] = pinLevel(makeMon(catalog, seed, {}), catalog, 9)
  end
  Assert.equal(#crowded, 6, "the crowded vector fills the party")
  local full = Evolution.plan(mon, vectorContext({ party = crowded, inventory = { POKE_BALL = 5 } }), catalog)
  Assert.notNil(full, "a full party still evolves the primary")
  Assert.equal(#full.additionalMons, 0, "a full party stages no side product")
  for _, delta in ipairs(full.inventoryDeltas) do
    Assert.isTrue(delta.item ~= "POKE_BALL", "a full party spends no ball")
  end
  local broke = Evolution.plan(mon, vectorContext({ party = { mon, mate }, inventory = {} }), catalog)
  Assert.notNil(broke, "an empty bag still evolves the primary")
  Assert.equal(#broke.additionalMons, 0, "no spare ball means no side product")
  local young = partyMon(241)
  young.experience = Experience.expFor(catalog:growthCurve("erratic"), 19)
  Assert.isTrue(
    Evolution.plan(young, roomy, catalog) == nil,
    "a line member below the slot level stages nothing"
  )
end

-- Naming is staged atomically with the species change: a custom name
-- survives onto the evolved mon while a default name follows the new
-- species, and the policy copies instead of mutating.
function T.naming_keeps_custom_names_and_follows_new_species_by_default()
  local Evolution = requirePresent("libs.mons.src.gen4.Evolution", "pure native evolution planning owns eligibility")
  local catalog = buildCatalog(function(root)
    local species = root.species --[[@as table<string, table<string, unknown>>]]
    local forms = species.CHIKORITA.forms --[[@as table<integer, table<string, unknown>>]]
    forms[0].evolutions = {
      { method = "level", level = 16, target = "TOTODILE", form = 0 },
    }
  end)
  local named = pinLevel(makeMon(catalog, 251, {}), catalog, 16)
  named.nickname = "LEAFY"
  local kept = Evolution.plan(named, vectorContext(), catalog)
  Assert.notNil(kept, "a nicknamed mon stages a plan")
  Assert.equal(kept.monAfter.nickname, "LEAFY", "the custom name survives evolution")
  Assert.equal(kept.monAfter.species, "TOTODILE", "the species still changes underneath the custom name")
  local plain = pinLevel(makeMon(catalog, 257, {}), catalog, 16)
  local followed = Evolution.plan(plain, vectorContext(), catalog)
  Assert.notNil(followed, "an unnamed mon stages a plan")
  Assert.isTrue(followed.monAfter.nickname == nil, "the default name follows the new species")
  local renamed = Evolution.applyNamePolicy(followed.monAfter, plain)
  Assert.isTrue(renamed.nickname == nil, "the policy keeps default naming default")
  Assert.isTrue(renamed ~= followed.monAfter, "the policy returns a copy")
  Assert.deepEqual(followed.monAfter, Evolution.plan(plain, vectorContext(), catalog).monAfter, "planning stays pure")
  local direct = Evolution.applyNamePolicy(kept.monAfter, named)
  Assert.equal(direct.nickname, "LEAFY", "the policy keeps custom naming directly")
  local fresh = pinLevel(makeMon(catalog, 251, {}), catalog, 16)
  Assert.equal(named.nickname, "LEAFY", "planning keeps the custom name on the input")
  named.nickname = nil
  Assert.deepEqual(named, fresh, "planning mutates nothing else on the input")
end

-- Staged results recalculate through the shared owners: experience is
-- untouched, health follows the shared maximum adjustment, ability
-- follows the personality slot of the new form, associated learning is
-- listed in learnset order, and malformed calls fail loudly.
function T.planned_results_recalculate_through_the_shared_owners()
  local Evolution = requirePresent("libs.mons.src.gen4.Evolution", "pure native evolution planning owns eligibility")
  local catalog = buildCatalog(function(root)
    local species = root.species --[[@as table<string, table<string, unknown>>]]
    local forms = species.CHIKORITA.forms --[[@as table<integer, table<string, unknown>>]]
    forms[0].evolutions = {
      { method = "level", level = 10, target = "EEVEE", form = 0 },
    }
  end)
  local mon = pinLevel(makeMon(catalog, 263, {}), catalog, 12)
  mon.condition.currentHp = MonStats.derive(mon, catalog).maxHp - 5
  local before = copy(mon)
  local staged = Evolution.plan(mon, vectorContext(), catalog)
  Assert.notNil(staged, "a matching mon stages a plan")
  Assert.keySet(
    staged,
    "additionalMons,canCancel,inventoryDeltas,learningOpportunities,monAfter,monBefore,reason",
    "plans carry exactly the shared result fields"
  )
  Assert.deepEqual(mon, before, "planning never mutates its input")
  Assert.isTrue(staged.monBefore ~= mon, "the staged before-image is a copy")
  Assert.deepEqual(staged.monBefore, before, "the staged before-image matches the input")
  Assert.equal(staged.reason, "level", "the plan names its native method")
  Assert.isTrue(staged.canCancel, "level results stay cancellable")
  Assert.deepEqual(staged.additionalMons, {}, "an ordinary plan stages no extra mons")
  Assert.deepEqual(staged.inventoryDeltas, {}, "an ordinary plan spends nothing")
  Assert.equal(staged.monAfter.experience, before.experience, "evolution keeps experience")
  local probe = copy(before)
  probe.species = "EEVEE"
  local expectedHp =
    MonStats.adjustHpForMaxChange(MonStats.derive(before, catalog).maxHp, MonStats.derive(probe, catalog).maxHp, before.condition.currentHp)
  Assert.equal(staged.monAfter.condition.currentHp, expectedHp, "health follows the shared maximum adjustment")
  local target = catalog:form("EEVEE", 0)
  local abilities = target.abilities --[[@as string[] ]]
  local expectedAbility = abilities[Personality.abilitySlot(#abilities, before.personality)]
  Assert.equal(staged.monAfter.ability, expectedAbility, "ability follows the personality slot of the new form")
  Assert.deepEqual(
    staged.learningOpportunities,
    { { level = 1, move = "TAIL_WHIP" }, { level = 8, move = "SAND_ATTACK" } },
    "associated learning lists unlearned entries in learnset order"
  )
  Mon.validate(staged.monAfter, CatalogFixture.domainContext(catalog))
  local trade = buildCatalog(function(root)
    local species = root.species --[[@as table<string, table<string, unknown>>]]
    local forms = species.CHIKORITA.forms --[[@as table<integer, table<string, unknown>>]]
    forms[0].evolutions = {
      { method = "trade", target = "TOTODILE", form = 0 },
    }
  end)
  local partner = pinLevel(makeMon(trade, 269, {}), trade, 12)
  local exchanged = Evolution.plan(partner, vectorContext({ trigger = { kind = "trade" } }), trade)
  Assert.notNil(exchanged, "trade context stages a plan")
  Assert.isFalse(exchanged.canCancel, "traded results are not cancellable")
  Assert.equal(exchanged.reason, "trade", "the trade plan names its method")
  Assert.throws(function()
    Evolution.check(nil, vectorContext(), catalog)
  end, "a missing mon fails")
  Assert.throws(function()
    Evolution.check(mon, nil, catalog)
  end, "a missing context fails")
end

-- Day/night items also answer a level-up while held: the same slot a bag
-- use opens matches when the mon holds the item at the right time of day,
-- and stays shut at the wrong time or with the wrong held item.
function T.held_day_night_items_answer_level_context()
  local Evolution = requirePresent("libs.mons.src.gen4.Evolution", "pure native evolution planning owns eligibility")
  local catalog = buildCatalog(function(root)
    local species = root.species --[[@as table<string, table<string, unknown>>]]
    local forms = species.CHIKORITA.forms --[[@as table<integer, table<string, unknown>>]]
    forms[0].evolutions = {
      { method = "item_day", item = "SUN_STONE", target = "TOTODILE", form = 0 },
      { method = "item_night", item = "MOON_STONE", target = "EEVEE", form = 0 },
    }
  end)
  local holder = pinLevel(makeMon(catalog, 501, {}), catalog, 12)
  holder.heldItem = "SUN_STONE"
  local day = Evolution.check(holder, vectorContext({ timeOfDay = "day" }), catalog)
  Assert.notNil(day, "a held day item matches by day")
  Assert.equal(day.target, "TOTODILE", "the held day slot answers")
  Assert.isTrue(
    Evolution.check(holder, vectorContext({ timeOfDay = "night" }), catalog) == nil,
    "the held day item waits for daylight"
  )
  holder.heldItem = "MOON_STONE"
  local night = Evolution.check(holder, vectorContext({ timeOfDay = "night" }), catalog)
  Assert.notNil(night, "a held night item matches by night")
  Assert.equal(night.target, "EEVEE", "the held night slot answers")
  holder.heldItem = "NONE"
  Assert.isTrue(
    Evolution.check(holder, vectorContext({ timeOfDay = "day" }), catalog) == nil,
    "a bare holder matches nothing"
  )
end

-- The blocker stops trade checks while bag-item use bypasses it entirely.
function T.held_blockers_stop_trade_but_not_bag_use()
  local Evolution = requirePresent("libs.mons.src.gen4.Evolution", "pure native evolution planning owns eligibility")
  local catalog = buildCatalog(function(root)
    local species = root.species --[[@as table<string, table<string, unknown>>]]
    local forms = species.CHIKORITA.forms --[[@as table<integer, table<string, unknown>>]]
    forms[0].evolutions = {
      { method = "trade", target = "TOTODILE", form = 0 },
      { method = "stone", item = "FIRE_STONE", target = "EEVEE", form = 0 },
    }
  end)
  local held = pinLevel(makeMon(catalog, 521, {}), catalog, 12)
  held.heldItem = "EVERSTONE"
  Assert.isTrue(
    Evolution.check(held, vectorContext({ trigger = { kind = "trade" } }), catalog) == nil,
    "the held blocker stops trade checks"
  )
  local stoned = Evolution.check(
    held,
    vectorContext({ trigger = { kind = "item", item = "FIRE_STONE" } }),
    catalog
  )
  Assert.notNil(stoned, "bag-item use bypasses the blocker")
  Assert.equal(stoned.target, "EEVEE", "the stone slot answers")
end

-- Held trade items are consumed by the staged result alone: the evolved
-- mon arrives barehanded with no bag spend, and the input keeps its item.
function T.held_trade_items_are_consumed_by_the_plan()
  local Evolution = requirePresent("libs.mons.src.gen4.Evolution", "pure native evolution planning owns eligibility")
  local catalog = buildCatalog(function(root)
    local species = root.species --[[@as table<string, table<string, unknown>>]]
    local forms = species.CHIKORITA.forms --[[@as table<integer, table<string, unknown>>]]
    forms[0].evolutions = {
      { method = "trade_item", item = "FIRE_STONE", target = "TOTODILE", form = 0 },
    }
  end)
  local holder = pinLevel(makeMon(catalog, 541, {}), catalog, 12)
  holder.heldItem = "FIRE_STONE"
  local staged = Evolution.plan(holder, vectorContext({ trigger = { kind = "trade" } }), catalog)
  Assert.notNil(staged, "trade while holding the named item stages a plan")
  Assert.equal(staged.monAfter.heldItem, "NONE", "the held item is consumed")
  Assert.deepEqual(staged.inventoryDeltas, {}, "held consumption stages no bag spend")
  Assert.equal(holder.heldItem, "FIRE_STONE", "planning keeps the input held item")
end

-- The shed slot never matches on its own and a lone line slot stages no
-- side product: the extra needs its sibling slot, room, and a ball.
function T.shed_slots_need_their_line_sibling()
  local Evolution = requirePresent("libs.mons.src.gen4.Evolution", "pure native evolution planning owns eligibility")
  local lone = buildCatalog(function(root)
    addNincadaLine(root)
    local species = root.species --[[@as table<string, table<string, unknown>>]]
    local forms = species.NINCADA.forms --[[@as table<integer, table<string, unknown>>]]
    forms[0].evolutions = {
      { method = "level_shedinja", level = 20, target = "SHEDINJA", form = 0 },
    }
  end)
  local line = buildCatalog(function(root)
    addNincadaLine(root)
    local species = root.species --[[@as table<string, table<string, unknown>>]]
    local forms = species.NINCADA.forms --[[@as table<integer, table<string, unknown>>]]
    forms[0].evolutions = {
      { method = "level_ninjask", level = 20, target = "NINJASK", form = 0 },
    }
  end)
  local function lineMon(catalog, seed)
    return pinLevel(makeMon(catalog, seed, { species = "NINCADA" }), catalog, 20)
  end
  local solitary = lineMon(lone, 557)
  Assert.isTrue(
    Evolution.check(solitary, vectorContext(), lone) == nil,
    "the shed slot never matches on its own"
  )
  Assert.isTrue(
    Evolution.plan(solitary, vectorContext(), lone) == nil,
    "the shed slot stages nothing alone"
  )
  local primary = lineMon(line, 563)
  local mate = pinLevel(makeMon(line, 569, {}), line, 9)
  local staged = Evolution.plan(primary, vectorContext({ party = { primary, mate }, inventory = { POKE_BALL = 5 } }), line)
  Assert.notNil(staged, "the lone line slot still evolves its primary")
  Assert.equal(staged.monAfter.species, "NINJASK", "the primary carries the line target")
  Assert.deepEqual(staged.additionalMons, {}, "no sibling slot means no side product")
  Assert.deepEqual(staged.inventoryDeltas, {}, "no side product spends no ball")
end

-- Unknown trigger kinds fail loudly instead of guessing a family.
function T.unknown_trigger_kinds_fail()
  local Evolution = requirePresent("libs.mons.src.gen4.Evolution", "pure native evolution planning owns eligibility")
  local catalog = buildCatalog(nil)
  local mon = pinLevel(makeMon(catalog, 601, {}), catalog, 12)
  Assert.throws(function()
    Evolution.check(mon, vectorContext({ trigger = { kind = "link" } }), catalog)
  end, "an unknown trigger kind fails")
end

-- Party-species slots read the whole party, matching the source membership
-- check even when the evolving mon itself carries the named species.
function T.party_species_slots_read_the_whole_party()
  local Evolution = requirePresent("libs.mons.src.gen4.Evolution", "pure native evolution planning owns eligibility")
  local catalog = buildCatalog(function(root)
    local species = root.species --[[@as table<string, table<string, unknown>>]]
    local forms = species.CHIKORITA.forms --[[@as table<integer, table<string, unknown>>]]
    forms[0].evolutions = {
      { method = "other_party_mon", species = "CHIKORITA", target = "TOTODILE", form = 0 },
    }
  end)
  local mon = pinLevel(makeMon(catalog, 613, {}), catalog, 12)
  local found = Evolution.check(mon, vectorContext({ party = { mon } }), catalog)
  Assert.notNil(found, "the membership check reads every party member")
  Assert.equal(found.target, "TOTODILE", "the party slot answers")
end

-- The marked baby form never evolves even with matching slots in every
-- trigger family, while the plain form of the same species follows its
-- own identical slots.
function T.marked_baby_forms_never_evolve_while_plain_forms_follow_slots()
  local Evolution = requirePresent("libs.mons.src.gen4.Evolution", "pure native evolution planning owns eligibility")
  local catalog = buildCatalog(addExceptionSpecies)
  local marked = pinLevel(makeMon(catalog, 701, { species = "PICHU", form = 1 }), catalog, 12)
  Assert.isTrue(
    Evolution.check(marked, vectorContext(), catalog) == nil,
    "the marked form ignores its matching level slot"
  )
  Assert.isTrue(
    Evolution.check(marked, vectorContext({ trigger = { kind = "item", item = "FIRE_STONE" } }), catalog) == nil,
    "the marked form ignores its matching stone slot"
  )
  Assert.isTrue(
    Evolution.check(marked, vectorContext({ trigger = { kind = "trade" } }), catalog) == nil,
    "the marked form ignores its matching trade slot"
  )
  Assert.isTrue(
    Evolution.plan(marked, vectorContext(), catalog) == nil,
    "the marked form stages no plan"
  )
  local plain = pinLevel(makeMon(catalog, 703, { species = "PICHU", form = 0 }), catalog, 12)
  local grown = Evolution.check(plain, vectorContext(), catalog)
  Assert.notNil(grown, "the plain form matches its level slot")
  Assert.equal(grown.target, "TOTODILE", "the plain level slot answers")
  local stoned = Evolution.check(
    plain,
    vectorContext({ trigger = { kind = "item", item = "FIRE_STONE" } }),
    catalog
  )
  Assert.notNil(stoned, "the plain form matches its stone slot")
  Assert.equal(stoned.target, "EEVEE", "the plain stone slot answers")
  local traded = Evolution.check(plain, vectorContext({ trigger = { kind = "trade" } }), catalog)
  Assert.notNil(traded, "the plain form matches its trade slot")
  Assert.equal(traded.target, "SHEDINJA", "the plain trade slot answers")
end

-- The evolution blocker stops trade and level checks for ordinary species
-- but one source-named species still matches those slots while holding
-- it; bag-item use bypasses the blocker for every species.
function T.trade_blocker_exempts_one_source_species_while_controls_stay_blocked()
  local Evolution = requirePresent("libs.mons.src.gen4.Evolution", "pure native evolution planning owns eligibility")
  local catalog = buildCatalog(function(root)
    addExceptionSpecies(root)
    local species = root.species --[[@as table<string, table<string, unknown>>]]
    local forms = species.CHIKORITA.forms --[[@as table<integer, table<string, unknown>>]]
    forms[0].evolutions = {
      { method = "level", level = 10, target = "TOTODILE", form = 0 },
      { method = "trade", target = "EEVEE", form = 0 },
    }
  end)
  local held = pinLevel(makeMon(catalog, 727, { species = "KADABRA" }), catalog, 12)
  held.heldItem = "EVERSTONE"
  local traded = Evolution.check(held, vectorContext({ trigger = { kind = "trade" } }), catalog)
  Assert.notNil(traded, "the exempt species matches its trade slot while holding the blocker")
  Assert.equal(traded.target, "SHEDINJA", "the trade slot answers")
  local grown = Evolution.check(held, vectorContext(), catalog)
  Assert.notNil(grown, "the exempt species matches its level slot while holding the blocker")
  Assert.equal(grown.target, "TOTODILE", "the level slot answers")
  local stoned = Evolution.check(
    held,
    vectorContext({ trigger = { kind = "item", item = "FIRE_STONE" } }),
    catalog
  )
  Assert.notNil(stoned, "bag-item use still answers while holding the blocker")
  Assert.equal(stoned.target, "EEVEE", "the stone slot answers")
  local control = pinLevel(makeMon(catalog, 733, {}), catalog, 12)
  control.heldItem = "EVERSTONE"
  Assert.isTrue(
    Evolution.check(control, vectorContext({ trigger = { kind = "trade" } }), catalog) == nil,
    "the blocker still stops an ordinary trade evolution"
  )
  Assert.isTrue(
    Evolution.check(control, vectorContext(), catalog) == nil,
    "the blocker still stops an ordinary level evolution"
  )
  control.heldItem = "NONE"
  local freed = Evolution.check(control, vectorContext({ trigger = { kind = "trade" } }), catalog)
  Assert.notNil(freed, "removing the blocker restores the ordinary trade evolution")
  Assert.equal(freed.target, "EEVEE", "the ordinary trade slot answers")
end

return { tests = T }
