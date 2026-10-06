-- Knockout effort follows the native modifier and cap order: power
-- items add before the pokerus and brace doublings, each stat caps at
-- 255, the six-stat total caps at 510, and fainted battlers and eggs
-- gain nothing while level-capped battlers still gain.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

---@param behavior string missing owner under test
---@return table the loaded knockout-effort owner
local function effortOwner(behavior)
  return SessionFixture.requirePresent("libs.battle.src.gen4.Effort", behavior)
end

---@return table<string, integer> empty six-stat effort record
local function blank()
  return { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 }
end

---@param overrides table<string, integer>|nil stat replacements for this yield
---@return table<string, integer> six-stat knockout yield under test
local function yield(overrides)
  local record = blank()
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      record[key] = value
    end
  end
  return record
end

---@param overrides table<string, unknown>|nil field replacements for these modifiers
---@return table effort modifiers under test
local function modifiers(overrides)
  local record = { powerStat = nil, pokerus = false, machoBrace = false }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      record[key] = value
    end
  end
  return record
end

---@param overrides table<string, unknown>|nil field replacements for this subject
---@return table award subject under test
local function subject(overrides)
  local record = { fainted = false, isEgg = false, level = 9 }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      record[key] = value
    end
  end
  return record
end

-- Modifiers apply in source order: the power item adds four to its stat
-- first, then pokerus doubles, then the brace doubles. A lone special
-- defense yield of one stays one; with the defense power item the award
-- is four defense and one special defense; pokerus doubles both to eight
-- and two; the brace doubles again to sixteen and four.
function T.power_pokerus_and_brace_apply_in_source_order()
  local Effort = effortOwner("knockout effort owns modifier order and caps")
  Assert.isTrue(type(Effort.calculate) == "function", "the effort owner stages awards")
  Assert.isTrue(type(Effort.apply) == "function", "the effort owner applies awards")
  Assert.deepEqual(
    Effort.calculate(yield({ specialDefense = 1 }), modifiers()),
    yield({ specialDefense = 1 }),
    "a lone yield passes through unchanged"
  )
  Assert.deepEqual(
    Effort.calculate(yield({ specialDefense = 1 }), modifiers({ powerStat = "defense" })),
    yield({ defense = 4, specialDefense = 1 }),
    "the power item adds four to its stat before any doubling"
  )
  Assert.deepEqual(
    Effort.calculate(yield({ specialDefense = 1 }), modifiers({ powerStat = "defense", pokerus = true })),
    yield({ defense = 8, specialDefense = 2 }),
    "pokerus doubles the yield plus the power bonus"
  )
  Assert.deepEqual(
    Effort.calculate(
      yield({ specialDefense = 1 }),
      modifiers({ powerStat = "defense", pokerus = true, machoBrace = true })
    ),
    yield({ defense = 16, specialDefense = 4 }),
    "the brace doubles after pokerus"
  )
end

-- Caps follow the native boundaries: a stat already at 254 absorbs only
-- one more of four, a stat at 251 with a doubled eight stops at 255, and
-- a total at 508 absorbs only two of four so the total rests at 510.
function T.per_stat_and_total_caps_hold_at_native_boundaries()
  local Effort = effortOwner("knockout effort owns modifier order and caps")
  local capped = Effort.apply(yield({ defense = 254 }), yield({ defense = 4 }), subject())
  Assert.equal(capped.defense, 255, "a stat caps at 255 instead of overflowing")
  local doubled = Effort.apply(
    yield({ defense = 251 }),
    Effort.calculate(yield({ defense = 2 }), modifiers({ pokerus = true, machoBrace = true })),
    subject()
  )
  Assert.equal(doubled.defense, 255, "a doubled award still caps at 255, never 252")
  local total = Effort.apply(
    yield({ hp = 100, attack = 100, defense = 100, speed = 100, specialAttack = 100, specialDefense = 8 }),
    yield({ attack = 4 }),
    subject()
  )
  Assert.equal(total.attack, 102, "the total cap admits only what fits below 510")
  local sum = total.hp + total.attack + total.defense + total.speed + total.specialAttack + total.specialDefense
  Assert.equal(sum, 510, "the six-stat total rests exactly at 510")
end

-- Eligibility follows the native gates: fainted battlers, eggs, and
-- level-capped battlers keep their prior values untouched, because the
-- source experience task skips its whole per-recipient block at zero
-- health or level one hundred. Application copies, so the incoming record
-- is never mutated.
function T.fainted_eggs_and_capped_gain_nothing()
  local Effort = effortOwner("knockout effort owns modifier order and caps")
  local before = yield({ defense = 10 })
  local award = yield({ defense = 4 })
  Assert.deepEqual(Effort.apply(before, award, subject({ fainted = true })), before, "a fainted battler gains nothing")
  Assert.deepEqual(Effort.apply(before, award, subject({ isEgg = true })), before, "an egg gains nothing")
  Assert.deepEqual(
    Effort.apply(before, award, subject({ level = 100 })),
    before,
    "a level-capped battler banks nothing"
  )
  Assert.deepEqual(before, yield({ defense = 10 }), "application never mutates the incoming record")
end

-- Held items map to effort modifiers by key: each power training item
-- names its bonus stat, Macho Brace names its doubling, and anything
-- else -- empty hands included -- carries no modifier.
function T.held_items_map_to_effort_modifiers_by_key()
  local Effort = effortOwner("knockout effort owns modifier order and caps")
  local cases = {
    POWER_BRACER = "attack",
    POWER_BELT = "defense",
    POWER_LENS = "specialAttack",
    POWER_BAND = "specialDefense",
    POWER_ANKLET = "speed",
    POWER_WEIGHT = "hp",
  }
  for key, stat in pairs(cases) do
    local modifiers = Effort.modifiersFor(key)
    Assert.equal(modifiers.powerStat, stat, key .. " bonuses " .. stat)
    Assert.isFalse(modifiers.machoBrace, key .. " doubles nothing itself")
  end
  local brace = Effort.modifiersFor("MACHO_BRACE")
  Assert.isNil(brace.powerStat, "the brace bonuses no stat")
  Assert.isTrue(brace.machoBrace, "the brace doubles")
  for _, key in ipairs({ "NONE", "LEFTOVERS", "LUCKY_EGG" }) do
    local plain = Effort.modifiersFor(key)
    Assert.isNil(plain.powerStat, key .. " bonuses no stat")
    Assert.isFalse(plain.machoBrace, key .. " doubles nothing")
  end
  local empty = Effort.modifiersFor(nil)
  Assert.isNil(empty.powerStat, "an empty hand bonuses no stat")
  Assert.isFalse(empty.machoBrace, "an empty hand doubles nothing")
  Assert.deepEqual(
    Effort.calculate(yield({ attack = 1 }), Effort.modifiersFor("POWER_BRACER")),
    yield({ attack = 5 }),
    "the mapped modifiers stage through the award"
  )
end

-- The owner exposes exactly its three operations, so no modern per-stat
-- ceiling or alternate award path hides beside the native one.
function T.effort_exposes_only_calculate_apply_and_modifiers()
  local Effort = effortOwner("knockout effort owns modifier order and caps")
  Assert.keySet(Effort, "apply,calculate,modifiersFor", "effort carries exactly its three operations")
end

-- Malformed records fail before application: partial awards and negative
-- values never bank, so a typo cannot silently drop a stat.
function T.malformed_records_fail_before_application()
  local Effort = effortOwner("knockout effort owns modifier order and caps")
  Assert.throws(function()
    Effort.apply(yield({ defense = 10 }), { defense = 4 }, subject())
  end, "a partial award fails instead of dropping stats")
  Assert.throws(function()
    Effort.calculate({ hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = -1 }, modifiers())
  end, "a negative yield fails")
  Assert.deepEqual(
    Effort.apply(yield(), yield(), {}),
    yield(),
    "a subject without eligibility fields applies cleanly"
  )
end

return { tests = T }
