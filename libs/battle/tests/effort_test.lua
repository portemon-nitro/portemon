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

-- A stored doubling mark reaches the staged award: flagging the record
-- doubles the lone special-defense point to two, while an explicit miss
-- and the bare mapping keep the current single point.
function T.stored_mark_doubles_the_staged_yield()
  local Effort = effortOwner("knockout effort owns modifier order and caps")
  local flagged = Effort.modifiersFor("NONE", true)
  Assert.isTrue(flagged.pokerus, "the flagged record carries the doubling")
  Assert.deepEqual(
    Effort.calculate(yield({ specialDefense = 1 }), flagged),
    yield({ specialDefense = 2 }),
    "the flagged yield doubles"
  )
  local unflagged = Effort.modifiersFor("NONE", false)
  Assert.isFalse(unflagged.pokerus, "an explicit miss carries no doubling")
  Assert.deepEqual(
    Effort.calculate(yield({ specialDefense = 1 }), unflagged),
    yield({ specialDefense = 1 }),
    "the unflagged yield passes through"
  )
  Assert.isFalse(Effort.modifiersFor("NONE").pokerus, "the bare mapping keeps current behavior")
end

-- The training-item bonus stages before the mark doubling: the
-- special-defense band adds four to the lone point first, then the mark
-- doubles the sum to ten, while the unmarked band still stages five.
function T.training_item_bonus_stages_before_the_mark_doubling()
  local Effort = effortOwner("knockout effort owns modifier order and caps")
  local flagged = Effort.modifiersFor("POWER_BAND", true)
  Assert.equal(flagged.powerStat, "specialDefense", "the band still bonuses its stat")
  Assert.isTrue(flagged.pokerus, "the flagged record carries the doubling")
  Assert.deepEqual(
    Effort.calculate(yield({ specialDefense = 1 }), flagged),
    yield({ specialDefense = 10 }),
    "the bonus stages before the doubling"
  )
  Assert.deepEqual(
    Effort.calculate(yield({ specialDefense = 1 }), Effort.modifiersFor("POWER_BAND", false)),
    yield({ specialDefense = 5 }),
    "the unmarked band keeps current staging"
  )
end

-- The brace multiplies after the mark doubling from the carried item:
-- the flagged brace stages the lone point to four, while the unmarked
-- brace still stages two.
function T.brace_multiplies_after_the_mark_doubling()
  local Effort = effortOwner("knockout effort owns modifier order and caps")
  local flagged = Effort.modifiersFor("MACHO_BRACE", true)
  Assert.isTrue(flagged.machoBrace, "the brace still doubles")
  Assert.isTrue(flagged.pokerus, "the flagged record carries the doubling")
  Assert.isNil(flagged.powerStat, "the brace bonuses no stat")
  Assert.deepEqual(
    Effort.calculate(yield({ specialDefense = 1 }), flagged),
    yield({ specialDefense = 4 }),
    "the mark and the brace multiply in order"
  )
  Assert.deepEqual(
    Effort.calculate(yield({ specialDefense = 1 }), Effort.modifiersFor("MACHO_BRACE", false)),
    yield({ specialDefense = 2 }),
    "the unmarked brace keeps current staging"
  )
end

-- Only an explicit mark doubles: a missing flag and loosely truthy
-- shapes stage flat, so the record never guesses from unvalidated input.
function T.only_an_explicit_mark_doubles_the_yield()
  local Effort = effortOwner("knockout effort owns modifier order and caps")
  Assert.isFalse(Effort.modifiersFor("NONE", nil).pokerus, "a missing flag stages flat")
  Assert.isFalse(Effort.modifiersFor("NONE", 1).pokerus, "a numeric shape stages flat")
  Assert.isFalse(Effort.modifiersFor("NONE", "yes").pokerus, "a string shape stages flat")
  Assert.isTrue(Effort.modifiersFor("NONE", true).pokerus, "the explicit mark doubles")
  Assert.deepEqual(
    Effort.calculate(yield({ attack = 1 }), Effort.modifiersFor("POWER_BRACER", 1)),
    yield({ attack = 5 }),
    "a loosely truthy flag never doubles the bonus"
  )
end

-- A marked award still trims only at the native caps: a defense at 252
-- banks a doubled four up to 255, a band-boosted twelve from 245 stops
-- at 255, and a total at 508 admits the doubled pair to exactly 510.
-- Each expectation also differs undoubled, so the trim bites the doubled
-- award rather than hiding behind an already-capped value.
function T.marked_awards_trim_only_at_native_caps()
  local Effort = effortOwner("knockout effort owns modifier order and caps")
  local nearStat = Effort.apply(
    yield({ defense = 252 }),
    Effort.calculate(yield({ defense = 2 }), Effort.modifiersFor("NONE", true)),
    subject()
  )
  Assert.equal(nearStat.defense, 255, "a marked award stops at 255 instead of overflowing")
  local banded = Effort.apply(
    yield({ defense = 245 }),
    Effort.calculate(yield({ defense = 2 }), Effort.modifiersFor("POWER_BELT", true)),
    subject()
  )
  Assert.equal(banded.defense, 255, "a marked band bonus still caps at 255")
  local nearTotal = Effort.apply(
    yield({ hp = 100, attack = 100, defense = 100, speed = 100, specialAttack = 100, specialDefense = 8 }),
    Effort.calculate(yield({ attack = 1 }), Effort.modifiersFor("NONE", true)),
    subject()
  )
  Assert.equal(nearTotal.attack, 102, "the total cap admits only what fits below 510")
  local sum = nearTotal.hp
    + nearTotal.attack
    + nearTotal.defense
    + nearTotal.speed
    + nearTotal.specialAttack
    + nearTotal.specialDefense
  Assert.equal(sum, 510, "the six-stat total rests exactly at 510")
end

-- The explicit flag preserves every held-item mapping: each power item
-- still names its stat and the brace still doubles under both flags,
-- while an explicit miss stages exactly like the bare mapping.
function T.explicit_flag_preserves_every_held_item_mapping()
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
    local missed = Effort.modifiersFor(key, false)
    local flagged = Effort.modifiersFor(key, true)
    Assert.equal(missed.powerStat, stat, key .. " still bonuses " .. stat .. " unmarked")
    Assert.equal(flagged.powerStat, stat, key .. " still bonuses " .. stat .. " marked")
    Assert.isFalse(missed.machoBrace, key .. " doubles nothing unmarked")
    Assert.isFalse(flagged.machoBrace, key .. " doubles nothing itself marked")
    Assert.isFalse(missed.pokerus, key .. " carries no doubling unmarked")
    Assert.isTrue(flagged.pokerus, key .. " carries the doubling marked")
  end
  local missedBrace = Effort.modifiersFor("MACHO_BRACE", false)
  local flaggedBrace = Effort.modifiersFor("MACHO_BRACE", true)
  Assert.isTrue(missedBrace.machoBrace, "the brace still doubles unmarked")
  Assert.isTrue(flaggedBrace.machoBrace, "the brace still doubles marked")
  Assert.isNil(missedBrace.powerStat, "the unmarked brace bonuses no stat")
  Assert.isNil(flaggedBrace.powerStat, "the marked brace bonuses no stat")
  Assert.isFalse(missedBrace.pokerus, "the unmarked brace carries no doubling")
  Assert.isTrue(flaggedBrace.pokerus, "the marked brace carries the doubling")
  local mixed = yield({ hp = 1, attack = 2, defense = 3, speed = 4, specialAttack = 5, specialDefense = 6 })
  Assert.deepEqual(
    Effort.calculate(mixed, Effort.modifiersFor("NONE", false)),
    Effort.calculate(mixed, Effort.modifiersFor("NONE")),
    "an explicit miss stages like the bare mapping"
  )
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
