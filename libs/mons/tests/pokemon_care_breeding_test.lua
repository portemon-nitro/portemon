-- Generation-IV breeding through the pure domain leaf: the source
-- compatibility scores, the exact Everstone and personality draw order, the
-- offspring resolution through the PMSing care tables, the power-item
-- individual-value order, the source move insertion order, and the
-- different-language personality mixer. Every draw arrives through an
-- injected trace, so each vector pins the source order as well as the result.

local Assert = require("tests.support.Assert")
local Breeding = require("libs.mons.src.gen4.Breeding")
local Personality = require("libs.mons.src.gen4.Personality")
local U32 = require("libs.codec.src.U32")

local T = {}

-- A hand-written catalog with the same lookup surface the real MonCatalog
-- publishes: species records with egg groups and gender ratios, form records
-- with a learnset and machine compatibility, and move records with base power
-- points.
local function buildCatalog()
  local moves = {
    THUNDERSHOCK = { basePp = 30 },
    CHARM = { basePp = 20 },
    TAIL_WHIP = { basePp = 30 },
    THUNDER_WAVE = { basePp = 20 },
    SWEET_KISS = { basePp = 10 },
    NASTY_PLOT = { basePp = 20 },
    VOLT_TACKLE = { basePp = 15 },
    IRON_TAIL = { basePp = 15 },
    GROWL = { basePp = 40 },
    TACKLE = { basePp = 35 },
    DOUBLE_SLAP = { basePp = 15 },
  }
  local species = {
    PIKACHU = {
      eggGroups = { "field", "fairy" },
      genderRatio = 127,
      forms = {
        [0] = {
          levelUpMoves = {
            { level = 1, move = "THUNDERSHOCK" },
            { level = 1, move = "CHARM" },
            { level = 5, move = "TAIL_WHIP" },
            { level = 10, move = "THUNDER_WAVE" },
            { level = 13, move = "SWEET_KISS" },
          },
          tmhm = { "IRON_TAIL", "THUNDER_WAVE" },
        },
      },
    },
    PICHU = {
      eggGroups = { "undiscovered", "undiscovered" },
      genderRatio = 127,
      forms = {
        [0] = {
          levelUpMoves = {
            { level = 1, move = "THUNDERSHOCK" },
            { level = 1, move = "CHARM" },
            { level = 5, move = "TAIL_WHIP" },
            { level = 10, move = "THUNDER_WAVE" },
            { level = 13, move = "SWEET_KISS" },
          },
          tmhm = { "IRON_TAIL", "THUNDER_WAVE" },
        },
      },
    },
    DITTO = {
      eggGroups = { "ditto", "ditto" },
      genderRatio = 255,
      forms = { [0] = { levelUpMoves = { { level = 1, move = "TACKLE" } }, tmhm = {} } },
    },
    RATTATA = {
      eggGroups = { "field", "field" },
      genderRatio = 127,
      forms = { [0] = { levelUpMoves = { { level = 1, move = "TACKLE" } }, tmhm = {} } },
    },
    CATERPIE = {
      eggGroups = { "bug", "bug" },
      genderRatio = 127,
      forms = { [0] = { levelUpMoves = { { level = 1, move = "TACKLE" } }, tmhm = {} } },
    },
    MEWTWO = {
      eggGroups = { "undiscovered", "undiscovered" },
      genderRatio = 255,
      forms = { [0] = { levelUpMoves = { { level = 1, move = "TACKLE" } }, tmhm = {} } },
    },
    MILTANK = {
      eggGroups = { "field", "field" },
      genderRatio = 254,
      forms = { [0] = { levelUpMoves = { { level = 1, move = "TACKLE" } }, tmhm = {} } },
    },
    NIDORAN_F = {
      eggGroups = { "monster", "field" },
      genderRatio = 254,
      forms = { [0] = { levelUpMoves = { { level = 1, move = "TACKLE" } }, tmhm = {} } },
    },
    NIDORAN_M = {
      eggGroups = { "monster", "field" },
      genderRatio = 0,
      forms = { [0] = { levelUpMoves = { { level = 1, move = "TACKLE" } }, tmhm = {} } },
    },
    ILLUMISE = {
      eggGroups = { "bug", "human_like" },
      genderRatio = 254,
      forms = { [0] = { levelUpMoves = { { level = 1, move = "TACKLE" } }, tmhm = {} } },
    },
    MANAPHY = {
      eggGroups = { "water_1", "fairy" },
      genderRatio = 255,
      forms = { [0] = { levelUpMoves = { { level = 1, move = "TACKLE" } }, tmhm = {} } },
    },
    SNORLAX = {
      eggGroups = { "monster", "monster" },
      genderRatio = 127,
      forms = { [0] = { levelUpMoves = { { level = 1, move = "TACKLE" } }, tmhm = {} } },
    },
  }
  return {
    species = function(_, key)
      local record = species[key]
      assert(record ~= nil, "unknown species " .. tostring(key))
      return record
    end,
    form = function(_, key, form)
      local record = assert(species[key], "unknown species " .. tostring(key))
      return assert(record.forms[form], "unknown form")
    end,
    move = function(_, key)
      return assert(moves[key], "unknown move " .. tostring(key))
    end,
  }
end

---@param draws integer[]
---@return fun(): integer, table
local function lcTrace(draws)
  local trace = { index = 0 }
  local function draw()
    trace.index = trace.index + 1
    return assert(draws[trace.index], "the linear trace runs out at draw " .. trace.index)
  end
  return draw, trace
end

---@param values integer[]
---@return fun(): integer, table
local function mtTrace(values)
  local trace = { index = 0 }
  local function draw()
    trace.index = trace.index + 1
    local value = values[trace.index]
    if value == nil then
      return 0x10000000 + trace.index
    end
    return value
  end
  return draw, trace
end

-- A personality whose low byte resolves the requested gender for one ratio.
---@param ratio integer
---@param gender string
---@return integer
local function personalityFor(ratio, gender)
  for candidate = 0, 600 do
    if Personality.gender(ratio, candidate) == gender then
      return candidate
    end
  end
  error("no personality resolves " .. gender, 0)
end

---@param fields table<string, unknown>
---@return table
local function parent(fields)
  local record = {
    species = fields.species,
    form = fields.form or 0,
    heldItem = fields.heldItem or "NONE",
    personality = fields.personality or 0,
    moves = fields.moves or {},
    ivs = fields.ivs or {},
    origin = { trainerId = fields.trainerId or 1, language = fields.language or "english" },
  }
  return record
end

---@param keys string[]
---@return table[]
local function moveEntries(keys)
  local entries = {}
  for index, key in ipairs(keys) do
    entries[index] = { move = key, pp = 1, ppUps = 0 }
  end
  return entries
end

---@param moves table[]
---@return string[]
local function moveKeys(moves)
  local keys = {}
  for index, entry in ipairs(moves) do
    keys[index] = entry.move
  end
  return keys
end

local function careTables()
  return {
    eggSpecies = {
      PIKACHU = "PICHU",
      NIDORAN_F = "NIDORAN_F",
      ILLUMISE = "ILLUMISE",
      MANAPHY = "MANAPHY",
      SNORLAX = "MUNCHLAX",
      RATTATA = "RATTATA",
    },
    eggMoves = { PICHU = { "DOUBLE_SLAP", "IRON_TAIL" } },
    incense = { { baby = "MUNCHLAX", item = "FULL_INCENSE", parent = "SNORLAX" } },
  }
end

local CATALOG = buildCatalog()

-- ComputeCompatibilityBetweenBoxMons: every source score and the exact
-- rejection order.
function T.compatibility_scores_follow_the_source_table()
  local female = parent({
    species = "PIKACHU",
    personality = personalityFor(127, "female"),
    trainerId = 41,
  })
  local male = parent({ species = "PIKACHU", personality = personalityFor(127, "male"), trainerId = 41 })
  local otherMale = parent({ species = "PIKACHU", personality = personalityFor(127, "male"), trainerId = 42 })
  local rattata = parent({ species = "RATTATA", personality = personalityFor(127, "male"), trainerId = 41 })
  local ditto = parent({ species = "DITTO", personality = 0, trainerId = 41 })
  local otherDitto = parent({ species = "DITTO", personality = 0, trainerId = 42 })
  local mewtwo = parent({ species = "MEWTWO", personality = 0, trainerId = 41 })
  local miltank = parent({ species = "MILTANK", personality = 0, trainerId = 41 })
  local caterpie = parent({ species = "CATERPIE", personality = personalityFor(127, "male"), trainerId = 41 })

  Assert.equal(Breeding.compatibility({ female, male }, CATALOG), 50, "the same species and one OT is medium")
  Assert.equal(Breeding.compatibility({ female, otherMale }, CATALOG), 70, "the same species and two OTs is maximum")
  Assert.equal(
    Breeding.compatibility({ female, rattata }, CATALOG),
    20,
    "a matching egg group with one OT is low"
  )
  Assert.equal(
    Breeding.compatibility({ female, parent({ species = "RATTATA", personality = 200, trainerId = 42 }) }, CATALOG),
    50,
    "a matching egg group with two OTs is medium"
  )
  Assert.equal(Breeding.compatibility({ ditto, male }, CATALOG), 20, "one Ditto and one OT is low")
  Assert.equal(Breeding.compatibility({ ditto, otherMale }, CATALOG), 50, "one Ditto and two OTs is medium")
  Assert.equal(Breeding.compatibility({ ditto, otherDitto }, CATALOG), 0, "two Ditto never breed")
  Assert.equal(Breeding.compatibility({ mewtwo, ditto }, CATALOG), 0, "an undiscovered parent never breeds")
  Assert.equal(Breeding.compatibility({ miltank, miltank }, CATALOG), 0, "two females never breed")
  Assert.equal(Breeding.compatibility({ mewtwo, miltank }, CATALOG), 0, "a genderless pair never breeds")
  Assert.equal(Breeding.compatibility({ caterpie, female }, CATALOG), 0, "different egg groups never breed")
end

-- GenerateEggPID: the Everstone draws come first and the nature search keeps
-- the source bound and the zero-PID rejection.
function T.egg_personality_draws_follow_the_everstone_rules()
  local female = parent({ species = "PIKACHU", personality = 0, trainerId = 41 })
  local male = parent({ species = "PIKACHU", personality = 200, trainerId = 42 })
  Assert.equal(Personality.nature(0), 0, "the first parent carries nature zero")
  Assert.equal(Personality.nature(200), 0, "the second parent carries nature zero")

  do
    local lc, lcState = lcTrace({})
    local mt, mtState = mtTrace({ 0x12345678 })
    local pid = Breeding.generateEggPid({ parents = { female, male }, lc = lc, mt = mt })
    Assert.equal(pid, 0x12345678, "a pair without Everstones keeps the drawn personality")
    Assert.equal(lcState.index, 0, "no Everstone spends no linear draw")
    Assert.equal(mtState.index, 1, "a pair without Everstones draws one personality")
  end

  do
    -- One Everstone: one linear activation draw, then the nature search.
    local holder = parent({ species = "PIKACHU", personality = 0, trainerId = 41, heldItem = "EVERSTONE" })
    local lc, lcState = lcTrace({ 0x7FFE })
    local mt, mtState = mtTrace({ 0, 25 })
    local pid = Breeding.generateEggPid({ parents = { holder, male }, lc = lc, mt = mt })
    Assert.equal(lcState.index, 1, "one Everstone spends exactly one activation draw")
    Assert.equal(pid, 25, "the search skips a zero personality and keeps the matching one")
    Assert.equal(mtState.index, 2, "the search draws until the nature matches with a nonzero value")
  end

  do
    local holder = parent({ species = "PIKACHU", personality = 0, trainerId = 41, heldItem = "EVERSTONE" })
    local lc = lcTrace({ Breeding.EVERSTONE_ACTIVATION_LIMIT })
    local mt, mtState = mtTrace({ 0x0F0F0F0F })
    local pid = Breeding.generateEggPid({ parents = { holder, male }, lc = lc, mt = mt })
    Assert.equal(pid, 0x0F0F0F0F, "the activation limit rejects the inheritance")
    Assert.equal(mtState.index, 1, "a rejected inheritance draws one personality")
  end

  do
    -- Two Everstones: the parity draw selects the parent, then activation.
    local first = parent({ species = "PIKACHU", personality = 0, trainerId = 41, heldItem = "EVERSTONE" })
    local second = parent({ species = "PIKACHU", personality = 203, trainerId = 42, heldItem = "EVERSTONE" })
    local lc, lcState = lcTrace({ 4, 0x1000 })
    local mt = mtTrace({ 203 })
    local pid = Breeding.generateEggPid({ parents = { first, second }, lc = lc, mt = mt })
    Assert.equal(lcState.index, 2, "two Everstones spend a parity draw and an activation draw")
    Assert.equal(Personality.nature(pid), 3, "the parity draw selects the second holder's nature")
  end

  do
    local first = parent({ species = "PIKACHU", personality = 0, trainerId = 41, heldItem = "EVERSTONE" })
    local second = parent({ species = "PIKACHU", personality = 200, trainerId = 42, heldItem = "EVERSTONE" })
    local lc = lcTrace({ 5, 0x1000 })
    local mt = mtTrace({ 0, 25 })
    local pid = Breeding.generateEggPid({ parents = { first, second }, lc = lc, mt = mt })
    Assert.equal(Personality.nature(pid), 0, "an odd parity draw selects the first holder's nature")
  end

  do
    -- The source bound: an unmatched nature keeps the last drawn value.
    local holder = parent({ species = "PIKACHU", personality = 1, trainerId = 41, heldItem = "EVERSTONE" })
    local lc = lcTrace({ 0 })
    local draws = { index = 0 }
    local function mt()
      draws.index = draws.index + 1
      return 2 -- nature 2 never matches nature 1
    end
    local pid = Breeding.generateEggPid({ parents = { holder, male }, lc = lc, mt = mt })
    Assert.equal(pid, 2, "the source keeps the last drawn personality after its bound")
    Assert.equal(draws.index, Breeding.NATURE_DRAW_LIMIT + 1, "the nature search stops one draw past its bound")
  end
end

-- Daycare_GetEggSpecies with the incense check: the mother's PMS entry, the
-- personality gender split, the Manaphy override, the Ditto role swap, the
-- mother's form, and the incense pair.
function T.offspring_resolution_follows_the_source_tables()
  local care = careTables()
  local function resolve(first, second, pendingEggPid)
    return Breeding.offspring({
      parents = { first, second },
      pendingEggPid = pendingEggPid,
      catalog = CATALOG,
      care = care,
    })
  end

  local female = parent({ species = "PIKACHU", personality = personalityFor(127, "female"), form = 0 })
  local male = parent({ species = "PIKACHU", personality = personalityFor(127, "male") })
  do
    local resolved = resolve(female, male, 0x10)
    Assert.equal(resolved.species, "PICHU", "the mother's PMS entry names the offspring")
    Assert.equal(resolved.motherSlot, 1, "the female parent is the mother")
    Assert.equal(resolved.fatherSlot, 2, "the male parent is the father")
    Assert.equal(resolved.form, 0, "the mother's form rides the egg")
  end
  do
    local formed = parent({ species = "PIKACHU", personality = personalityFor(127, "female"), form = 1 })
    Assert.equal(resolve(formed, male, 0x10).form, 1, "the mother's alternate form rides the egg")
  end
  do
    local nidoranFemale = parent({ species = "NIDORAN_F", personality = 0 })
    local nidoranMale = parent({ species = "NIDORAN_M", personality = 0 })
    Assert.equal(resolve(nidoranFemale, nidoranMale, 0x8000).species, "NIDORAN_M", "bit 0x8000 splits to male")
    Assert.equal(resolve(nidoranFemale, nidoranMale, 0x4000).species, "NIDORAN_F", "a clear bit keeps the female")
  end
  do
    local illumise = parent({ species = "ILLUMISE", personality = 0 })
    local partner = parent({ species = "CATERPIE", personality = personalityFor(127, "male") })
    Assert.equal(
      resolve(illumise, partner, 0x8000).species,
      "VOLBEAT",
      "the Illumise family splits on the same bit"
    )
  end
  do
    local manaphy = parent({ species = "MANAPHY", personality = 0 })
    local ditto = parent({ species = "DITTO", personality = 0 })
    local resolved = resolve(manaphy, ditto, 0x10)
    Assert.equal(resolved.species, "PHIONE", "a Manaphy parent always produces Phione")
    Assert.equal(resolved.motherSlot, 2, "a genderless non-Ditto parent hands the mother role to Ditto")
    Assert.equal(resolved.fatherSlot, 1, "the role swap makes the non-Ditto parent the father")
  end
  do
    local snorlaxFemale = parent({ species = "SNORLAX", personality = 0 })
    local snorlaxMale = parent({ species = "SNORLAX", personality = 200 })
    Assert.equal(resolve(snorlaxFemale, snorlaxMale, 1).species, "SNORLAX", "a missing incense restores the parent")
    local held = parent({ species = "SNORLAX", personality = 200, heldItem = "FULL_INCENSE" })
    Assert.equal(resolve(snorlaxFemale, held, 1).species, "MUNCHLAX", "the source incense keeps the baby")
  end
end

-- InheritIVs: three distinct stats, the power-item override, the parity draw,
-- and the source order of stat choices before parent choices.
function T.individual_values_inherit_in_source_order()
  local high = { hp = 31, attack = 31, defense = 31, speed = 31, specialAttack = 31, specialDefense = 31 }
  local low = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 }
  local first = parent({ species = "PIKACHU", personality = 0, ivs = high, trainerId = 41 })
  local second = parent({ species = "PIKACHU", personality = 200, ivs = low, trainerId = 42 })

  do
    -- No power items: three stat indices over 6/5/4, then three parent picks.
    local lc, state = lcTrace({ 0, 0, 0, 0, 0, 1 })
    local assignments = Breeding.inheritedIvs({ parents = { first, second }, lc = lc })
    Assert.equal(state.index, 6, "three inherited stats spend six linear draws")
    Assert.deepEqual(assignments, {
      { stat = "hp", slot = 1 },
      { stat = "attack", slot = 1 },
      { stat = "defense", slot = 2 },
    }, "the stat indices are chosen before their parent choices")
  end

  do
    local weighted = parent({
      species = "PIKACHU",
      personality = 0,
      ivs = high,
      trainerId = 41,
      heldItem = "POWER_WEIGHT",
    })
    local lc, state = lcTrace({ 1, 1, 0, 0 })
    local assignments = Breeding.inheritedIvs({ parents = { weighted, second }, lc = lc })
    Assert.equal(state.index, 4, "a single power item spends four linear draws")
    Assert.deepEqual(assignments[1], { stat = "hp", slot = 1 }, "the power item forces its holder's stat")
    Assert.equal(assignments[2].stat, "defense", "the remaining indices skip the forced stat")
    Assert.equal(assignments[3].stat, "speed", "each inherited stat is distinct")
  end

  do
    local weight = parent({
      species = "PIKACHU",
      personality = 0,
      ivs = high,
      trainerId = 41,
      heldItem = "POWER_WEIGHT",
    })
    local lens = parent({
      species = "PIKACHU",
      personality = 200,
      ivs = low,
      trainerId = 42,
      heldItem = "POWER_LENS",
    })
    local lc, state = lcTrace({ 0, 0, 0, 0, 0 })
    local assignments = Breeding.inheritedIvs({ parents = { weight, lens }, lc = lc })
    Assert.equal(state.index, 5, "two power items spend a parity draw before the stat choices")
    Assert.deepEqual(assignments[1], { stat = "specialAttack", slot = 2 }, "an even parity draw selects the second holder")
    Assert.equal(assignments[2].stat, "hp", "the second holder's stat is removed from the candidate list")
  end
end

-- InheritMoves: level-one defaults, the father's egg moves in slot order, the
-- father's compatible machines, the shared level-up moves, duplicate skips,
-- the full-set drop, and Pichu's Light Ball.
function T.moves_inherit_in_source_order()
  local care = careTables()
  local function inherit(mother, father, offspringSpecies, form)
    return Breeding.inheritedMoves({
      offspring = { species = offspringSpecies or "PICHU", form = form or 0 },
      mother = mother,
      father = father,
      catalog = CATALOG,
      care = care,
    })
  end

  do
    local mother = parent({
      species = "PIKACHU",
      personality = 0,
      moves = moveEntries({ "TAIL_WHIP", "SWEET_KISS", "THUNDER_WAVE", "THUNDERSHOCK" }),
    })
    local father = parent({
      species = "PIKACHU",
      personality = 200,
      moves = moveEntries({ "THUNDERSHOCK", "THUNDER_WAVE", "SWEET_KISS", "TAIL_WHIP" }),
    })
    -- Level-one defaults first, then the father's compatible machine, then the
    -- shared learn-up moves; a full set drops its first move for every further
    -- insertion.
    Assert.deepEqual(
      moveKeys(inherit(mother, father)),
      { "CHARM", "THUNDER_WAVE", "SWEET_KISS", "TAIL_WHIP" },
      "machines precede shared learn-up moves and duplicates are skipped"
    )
  end

  do
    local mother = parent({ species = "PIKACHU", personality = 0, moves = {} })
    local father = parent({
      species = "PIKACHU",
      personality = 200,
      moves = moveEntries({ "DOUBLE_SLAP", "TACKLE", "GROWL", "IRON_TAIL" }),
    })
    Assert.deepEqual(
      moveKeys(inherit(mother, father)),
      { "THUNDERSHOCK", "CHARM", "DOUBLE_SLAP", "IRON_TAIL" },
      "the father's egg moves come after the level-one defaults"
    )
  end

  do
    local mother = parent({ species = "PIKACHU", personality = 0, moves = moveEntries({ "TAIL_WHIP" }) })
    local father = parent({ species = "PIKACHU", personality = 200, moves = moveEntries({ "TAIL_WHIP" }) })
    local moves = inherit(mother, father)
    Assert.deepEqual(
      moveKeys(moves),
      { "THUNDERSHOCK", "CHARM", "TAIL_WHIP" },
      "a shared move already known appends nothing"
    )
  end

  do
    local mother = parent({
      species = "PIKACHU",
      personality = 0,
      moves = moveEntries({ "TAIL_WHIP", "SWEET_KISS", "THUNDER_WAVE", "NASTY_PLOT" }),
    })
    local father = parent({
      species = "PIKACHU",
      personality = 200,
      moves = moveEntries({ "NASTY_PLOT", "THUNDER_WAVE", "SWEET_KISS", "IRON_TAIL" }),
      heldItem = "LIGHT_BALL",
    })
    Assert.deepEqual(
      moveKeys(inherit(mother, father)),
      { "IRON_TAIL", "THUNDER_WAVE", "SWEET_KISS", "VOLT_TACKLE" },
      "a full set drops its first move and Volt Tackle lands last"
    )
  end

  do
    local mother = parent({ species = "PIKACHU", personality = 0, moves = {} })
    local father = parent({ species = "PIKACHU", personality = 200, moves = {}, heldItem = "LIGHT_BALL" })
    Assert.deepEqual(
      moveKeys(inherit(mother, father, "RATTATA")),
      { "TACKLE" },
      "only a Pichu inherits Volt Tackle"
    )
  end
end

-- SetBreedEggStats' different-language mixer: PRandom steps, not draws, and
-- never a rewrite of the pending identity.
function T.different_languages_mix_the_egg_personality()
  local english = parent({ species = "PIKACHU", personality = 0, language = "english" })
  local japanese = parent({ species = "PIKACHU", personality = 200, language = "japanese" })
  Assert.isFalse(Breeding.differentLanguages({ english, english }), "one language is not a Masuda pair")
  Assert.isTrue(Breeding.differentLanguages({ english, japanese }), "two languages make a Masuda pair")

  local pending = 0x12345678
  Assert.equal(
    Breeding.eggPersonality({ pendingEggPid = pending, parents = { english, english }, trainerId = 41 }),
    pending,
    "one language keeps the pending personality"
  )
  local trainerId = 41
  local expected = pending
  if not Personality.shiny(trainerId, expected) then
    for _ = 1, 4 do
      expected = U32.add(U32.mul(expected, 1812433253), 1)
      if Personality.shiny(trainerId, expected) then
        break
      end
    end
  end
  Assert.equal(
    Breeding.eggPersonality({ pendingEggPid = pending, parents = { english, japanese }, trainerId = trainerId }),
    expected,
    "two languages apply the source personality mixer"
  )
end

-- The source's compatibility conversion and the egg-cycle tables.
function T.compatibility_categories_and_cycles_match_the_source()
  Assert.equal(Breeding.CATEGORY_BY_SCORE[70], 0, "maximum compatibility reports zero")
  Assert.equal(Breeding.CATEGORY_BY_SCORE[50], 1, "medium compatibility reports one")
  Assert.equal(Breeding.CATEGORY_BY_SCORE[20], 2, "low compatibility reports two")
  Assert.equal(Breeding.CATEGORY_BY_SCORE[0], 3, "incompatible pairs report three")
  Assert.equal(Breeding.cycleLengthFor({ day = 5, month = 1 }), 255, "an ordinary date keeps the full cycle")
  Assert.equal(Breeding.cycleLengthFor({ day = 12, month = 1 }), 230, "January 12 shortens the cycle")
  Assert.equal(Breeding.cycleLengthFor({ day = 25, month = 12 }), 230, "December 25 shortens the cycle")
  Assert.equal(Breeding.cycleLengthFor({ day = 1, month = 1 }), 255, "January 1 is not a source special date")
  Assert.equal(Breeding.cycleDecrement({ { isEgg = false, ability = "STATIC" } }), 1, "an ordinary party ticks once")
  Assert.equal(
    Breeding.cycleDecrement({ { isEgg = true, ability = "MAGMA_ARMOR" }, { isEgg = false, ability = "FLAME_BODY" } }),
    2,
    "a non-Egg body ability doubles the tick"
  )
  Assert.equal(
    Breeding.cycleDecrement({ { isEgg = false, ability = "MAGMA_ARMOR" }, { isEgg = false, ability = "FLAME_BODY" } }),
    2,
    "either source ability doubles the tick"
  )
end

return { tests = T }
