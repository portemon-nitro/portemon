-- Pure mon progression is caller-neutral arithmetic: the same record
-- and gain always yield the same levels, ordered learning chances, and
-- refreshed maximum, while prompts stay with the caller. Awards never
-- mutate their input, learned moves reset power points, and the helper
-- carries no recipient selection of its own.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")

local T = {}

---@param name string module path under test
---@param behavior string missing owner under test
---@return table the loaded pure-progression owner
local function requirePresent(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing mon behavior: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the mon module loads")
  return loaded --[[@as table]]
end

---@return table mon catalog built once from the fixed synthetic asset root
local function catalog()
  return CatalogFixture.makeCatalog()
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

---@param seed integer fixed generator state for this roster member
---@param overrides table<string, unknown>|nil generation request overrides
---@return table persistent mon record owned by the mon domain
local function makeMon(seed, overrides)
  local factory = CatalogFixture.makeFactory(seed, catalog())
  return factory:createNormal(CatalogFixture.normalRequest(overrides or {}))
end

---@param mon table mon record under test
---@param experience integer pinned cumulative experience under test
---@param hp integer pinned current health under test
local function pinBaseline(mon, experience, hp)
  mon.experience = experience
  mon.hp = hp
  mon.personality = 0
  for _, key in ipairs({ "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }) do
    mon.ivs[key] = 10
    mon.evs[key] = 0
  end
end

-- One award crosses exactly the levels its experience reaches: from 419
-- with 600 more the record rests at 1019, levels ten through twelve are
-- crossed in order, only level twelve teaches anything, and the maximum
-- moves from the level-nine value of 28 to the level-twelve value of 34.
function T.an_award_crosses_exactly_the_levels_its_experience_reaches()
  local LevelProgression = requirePresent(
    "libs.mons.src.gen4.LevelProgression",
    "pure incremental mon progression owns awards and learning chances"
  )
  Assert.isTrue(type(LevelProgression.award) == "function", "the progression owner awards experience")
  Assert.isTrue(type(LevelProgression.learn) == "function", "the progression owner fills free slots")
  Assert.isTrue(type(LevelProgression.replace) == "function", "the progression owner replaces moves")
  Assert.isTrue(type(LevelProgression.decline) == "function", "the progression owner declines moves")
  local mon = makeMon(11, {})
  pinBaseline(mon, 419, 28)
  local before = copy(mon)
  local result = LevelProgression.award(mon, 600, catalog())
  Assert.keySet(
    result,
    "crossedLevels,learningOpportunities,maxHpAfter,maxHpBefore,mon",
    "awards carry exactly their documented facts"
  )
  Assert.equal(result.mon.experience, 1019, "the award adds experience exactly once")
  Assert.deepEqual(result.crossedLevels, { 10, 11, 12 }, "crossed levels arrive in order")
  Assert.deepEqual(
    result.learningOpportunities,
    { { level = 12, move = "SYNTHESIS" } },
    "only crossed levels with new entries teach"
  )
  Assert.equal(result.maxHpBefore, 28, "the refresh opens from the level-nine maximum")
  Assert.equal(result.maxHpAfter, 34, "the refresh lands on the level-twelve maximum")
  Assert.equal(result.mon.hp, 28, "the award keeps current health instead of healing")
  Assert.deepEqual(mon, before, "the award never mutates its input")
end

-- Slot operations keep exact power-point behavior: a free slot fills with
-- base points, a full set refuses the fill, the named replacement lands
-- with reset points while every other slot keeps its points, and a
-- decline names its move without touching the set.
function T.slot_operations_keep_exact_power_point_behavior()
  local LevelProgression = requirePresent(
    "libs.mons.src.gen4.LevelProgression",
    "pure incremental mon progression owns awards and learning chances"
  )
  local small = makeMon(23, { level = 5 })
  pinBaseline(small, 135, 20)
  local filled = LevelProgression.learn(small, "RAZOR_LEAF", catalog())
  Assert.isTrue(filled.applied, "a free slot accepts the new move")
  Assert.equal(filled.mon.moves[3].move, "RAZOR_LEAF", "the new move fills the first free slot")
  Assert.equal(filled.mon.moves[3].pp, 25, "a filled move resets to its base power points")
  Assert.equal(filled.mon.moves[3].ppUps, 0, "a filled move carries no power-point ups")

  local full = makeMon(37, {})
  pinBaseline(full, 419, 28)
  local refused = LevelProgression.learn(full, "SYNTHESIS", catalog())
  Assert.isFalse(refused.applied, "a full set refuses the fill")
  Assert.equal(#refused.mon.moves, 4, "a refused fill keeps all four moves")
  local replaced = LevelProgression.replace(full, 3, "SYNTHESIS", catalog())
  Assert.equal(replaced.moves[4].move, "SYNTHESIS", "the replacement lands in the named slot")
  Assert.equal(replaced.moves[4].pp, 5, "a replaced move resets to its base power points")
  Assert.equal(replaced.moves[4].ppUps, 0, "a replaced move carries no power-point ups")
  Assert.equal(replaced.moves[1].move, "TACKLE", "untouched slots keep their moves")
  Assert.equal(replaced.moves[1].pp, full.moves[1].pp, "untouched slots keep their power points")
  local declined = LevelProgression.decline(full, "SYNTHESIS")
  Assert.equal(declined.declined, "SYNTHESIS", "a decline names its move")
  Assert.deepEqual(declined.mon.moves, full.moves, "a decline touches no move")
end

-- The helper serves every caller identically: a battle-shaped caller and
-- a direct caller reach the same record, and the module carries exactly
-- its four operations with no recipient selection of its own.
function T.the_helper_serves_every_caller_identically()
  local LevelProgression = requirePresent(
    "libs.mons.src.gen4.LevelProgression",
    "pure incremental mon progression owns awards and learning chances"
  )
  Assert.keySet(LevelProgression, "award,decline,learn,replace", "the helper carries exactly its four operations")
  local function battleShapedCall(mon, gain)
    return LevelProgression.award(mon, gain, catalog())
  end
  local first = makeMon(51, {})
  pinBaseline(first, 419, 28)
  local second = copy(first)
  local viaBattle = battleShapedCall(first, 600)
  local direct = LevelProgression.award(second, 600, catalog())
  Assert.deepEqual(direct, viaBattle, "battle and out-of-battle callers reach identical results")
  Assert.deepEqual(first, second, "neither caller leaks state into the shared helper")
  local again = LevelProgression.award(copy(second), 600, catalog())
  Assert.deepEqual(again.learningOpportunities, viaBattle.learningOpportunities, "repeated awards never diverge")
end

-- Excess gains saturate at the level cap and invalid gains fail: an
-- unbounded award rests exactly on the level-100 entry having crossed
-- every level, while a negative gain never stages.
function T.excess_gains_saturate_at_the_level_cap()
  local LevelProgression = requirePresent(
    "libs.mons.src.gen4.LevelProgression",
    "pure incremental mon progression owns awards and learning chances"
  )
  local mon = makeMon(71, {})
  pinBaseline(mon, 419, 28)
  local ceiling = catalog():growthCurve("medium_slow")[100]
  local result = LevelProgression.award(mon, 99999999, catalog())
  Assert.equal(result.mon.experience, ceiling, "the award saturates at the level-100 entry")
  Assert.equal(result.crossedLevels[#result.crossedLevels], 100, "crossed levels end at the cap")
  Assert.equal(mon.experience, 419, "the saturating award never mutates its input")
  Assert.throws(function()
    LevelProgression.award(mon, -1, catalog())
  end, "a negative gain fails")
  Assert.throws(function()
    LevelProgression.replace(mon, 9, "SYNTHESIS", catalog())
  end, "a replacement outside the held set fails")
end

return { tests = T }
