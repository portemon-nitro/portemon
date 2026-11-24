-- Generation-IV Day Care breeding. Source: the retail ROM (src/get_egg.c:
-- ComputeCompatibilityBetweenBoxMons, Daycare_EverstoneCheck,
-- GenerateEggPID, Daycare_GetEggSpecies, Daycare_BreedingIncenseCheck,
-- InheritIVs, Daycare_TryGetForcedInheritedIV, InheritMoves,
-- Daycare_LightBallCheck, Daycare_GetEggCyclesToSubtract, and
-- Daycare_GetEggCycleLength). Every calculation here is pure: parents are
-- detached canonical mon records, the random streams arrive as injected
-- source-ordered draw functions, and the bulk source tables (PMS egg species
-- and the personal egg-move list) arrive as the compiled care catalog.
-- Nothing here owns live or saved state; the caller decides what to publish.

local Errors = require("libs.errors.src.Errors")
local MonsErrors = require("libs.mons.src.errors")
local Moves = require("libs.mons.src.gen4.Moves")
local Personality = require("libs.mons.src.gen4.Personality")
local U32 = require("libs.codec.src.U32")

---@class Breeding
local Breeding = {}

-- PARENTS_INCOMPATIBLE / PARENTS_LOW_COMPATIBILITY /
-- PARENTS_MED_COMPATIBILITY / PARENTS_MAX_COMPATIBILITY
-- (include/constants/daycare.h).
Breeding.INCOMPATIBLE = 0
Breeding.LOW = 20
Breeding.MEDIUM = 50
Breeding.MAXIMUM = 70

-- The source's converted compatibility categories, lowest score first:
-- 70 -> 0, 50 -> 1, 20 -> 2, 0 -> 3 (ConvertDaycareCompatibilityScore).
Breeding.CATEGORY_BY_SCORE = {
  [Breeding.MAXIMUM] = 0,
  [Breeding.MEDIUM] = 1,
  [Breeding.LOW] = 2,
  [Breeding.INCOMPATIBLE] = 3,
}

Breeding.EVERSTONE = "EVERSTONE"
Breeding.LIGHT_BALL = "LIGHT_BALL"
Breeding.VOLT_TACKLE = "VOLT_TACKLE"
Breeding.DITTO = "DITTO"
Breeding.UNDISCOVERED = "undiscovered"
Breeding.EGG_GROUP_DITTO = "ditto"

-- EGG_GENDER_MALE: the pending egg personality bit the Nidoran and
-- Illumise families read as their offspring's gender split.
Breeding.EGG_GENDER_MALE = 0x8000
-- The source's Everstone acceptance threshold: an activated inheritance
-- needs a draw strictly below 0x7FFF.
Breeding.EVERSTONE_ACTIVATION_LIMIT = 0x7FFF
-- The source's nature-search bound: after this many failed draws the last
-- drawn personality is kept.
Breeding.NATURE_DRAW_LIMIT = 2400
-- LANE_DIFFERENT_LANGUAGE_PERSONALITY_DRAWS: SetBreedEggStats advances the
-- drawn personality at most four times towards a shiny value.
Breeding.LANGUAGE_PERSONALITY_DRAWS = 4
Breeding.PERSONALITY_MIXER = 1812433253
-- The source's shared-parental-move list is a MAX_MON_MOVES array, so only
-- its first four entries reach the offspring.
Breeding.MAX_SHARED_MOVES = Moves.MAX_SLOTS

-- STAT_HP..STAT_SPDEF in source order; InheritIVs walks this list.
Breeding.STAT_KEYS = { "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }

-- SetStatIdToPowerItemStat: one power item per stat.
Breeding.POWER_ITEM_STATS = {
  POWER_WEIGHT = "hp",
  POWER_BRACER = "attack",
  POWER_BELT = "defense",
  POWER_ANKLET = "speed",
  POWER_LENS = "specialAttack",
  POWER_BAND = "specialDefense",
}

---@param message string
---@param context table<string, unknown>
local function reject(message, context)
  Errors.raise(MonsErrors.RECORD_INVALID, message, context)
end

---@param personality integer
---@return boolean whether the pending egg personality asks for a male
local function maleSplit(personality)
  return personality % (Breeding.EGG_GENDER_MALE * 2) >= Breeding.EGG_GENDER_MALE
end

---@param parents table[]
---@return table, table
local function requirePair(parents)
  if type(parents) ~= "table" or #parents ~= 2 then
    reject("breeding needs exactly two parent records", {})
  end
  local first = parents[1] --[[@as table]]
  local second = parents[2] --[[@as table]]
  for index, parent in ipairs({ first, second }) do
    if type(parent) ~= "table" or type(parent.species) ~= "string" then
      reject("breeding parent " .. index .. " is not a stored mon record", {})
    end
    if type(parent.personality) ~= "number" then
      reject("breeding parent " .. index .. " carries no personality", {})
    end
  end
  return first, second
end

---@param groups string[]
---@param otherGroups string[]
---@return boolean
local function eggGroupsMatch(groups, otherGroups)
  for _, group in ipairs(groups) do
    for _, other in ipairs(otherGroups) do
      if group == other then
        return true
      end
    end
  end
  return false
end

-- ComputeCompatibilityBetweenBoxMons: the source's four compatibility scores
-- in source test order, with the Ditto pair treated as two different species.
---@param parents table[] the two stored parents in source slot order
---@param catalog MonCatalog
---@return integer compatibility score (0, 20, 50 or 70)
function Breeding.compatibility(parents, catalog)
  local first, second = requirePair(parents)
  local firstSpecies = catalog:species(first.species)
  local secondSpecies = catalog:species(second.species)
  local firstGroups = firstSpecies.eggGroups
  local secondGroups = secondSpecies.eggGroups
  if firstGroups[1] == Breeding.UNDISCOVERED or secondGroups[1] == Breeding.UNDISCOVERED then
    return Breeding.INCOMPATIBLE
  end
  if firstGroups[1] == Breeding.EGG_GROUP_DITTO and secondGroups[1] == Breeding.EGG_GROUP_DITTO then
    return Breeding.INCOMPATIBLE
  end
  local sameTrainer = first.origin.trainerId == second.origin.trainerId
  if firstGroups[1] == Breeding.EGG_GROUP_DITTO or secondGroups[1] == Breeding.EGG_GROUP_DITTO then
    return sameTrainer and Breeding.LOW or Breeding.MEDIUM
  end
  local firstGender = Personality.gender(firstSpecies.genderRatio, first.personality)
  local secondGender = Personality.gender(secondSpecies.genderRatio, second.personality)
  if firstGender == secondGender then
    return Breeding.INCOMPATIBLE
  end
  if firstGender == "genderless" or secondGender == "genderless" then
    return Breeding.INCOMPATIBLE
  end
  if not eggGroupsMatch(firstGroups, secondGroups) then
    return Breeding.INCOMPATIBLE
  end
  if first.species == second.species then
    return sameTrainer and Breeding.MEDIUM or Breeding.MAXIMUM
  end
  return sameTrainer and Breeding.LOW or Breeding.MEDIUM
end

-- Daycare_GetEggCycleLength: the native day number (day + month * 100) selects
-- the shortened cycle on the source's special dates; every other date keeps
-- the full 255 step cycle. The caller owns the clock-penalty override.
Breeding.cycleLength = 255
Breeding.SPECIAL_CYCLE_LENGTH = 230
Breeding.SPECIAL_DATE_NUMBERS = {
  112, -- January 12
  214, -- February 14
  303, -- March 3
  401, -- April 1
  501, -- May 1
  611, -- June 11
  707, -- July 7
  821, -- August 21
  907, -- September 7
  928, -- September 28
  1031, -- October 31
  1121, -- November 21
  1214, -- December 14
  1224, -- December 24
  1225, -- December 25
}

---@param date { day: integer, month: integer }
---@return integer egg cycle length in steps
function Breeding.cycleLengthFor(date)
  assert(type(date) == "table", "the egg cycle length needs a native date")
  local number = date.day + date.month * 100
  for _, special in ipairs(Breeding.SPECIAL_DATE_NUMBERS) do
    if number == special then
      return Breeding.SPECIAL_CYCLE_LENGTH
    end
  end
  return Breeding.cycleLength
end

-- GetEggCyclesToSubtract: any non-Egg party member whose current ability is
-- Magma Armor or Flame Body doubles the cycle decrement; fainting does not
-- disable the source check.
Breeding.CYCLE_ABILITIES = { MAGMA_ARMOR = true, FLAME_BODY = true }

---@param party table[] the party records in party order
---@return integer cycle steps subtracted per completed cycle (1 or 2)
function Breeding.cycleDecrement(party)
  assert(type(party) == "table", "the egg cycle decrement reads the party")
  for _, mon in ipairs(party) do
    if mon.isEgg ~= true and Breeding.CYCLE_ABILITIES[mon.ability] == true then
      return 2
    end
  end
  return 1
end

-- Daycare_EverstoneCheck: the number of holders selects the contributing
-- parent; with two holders one parity draw picks the parent and a second draw
-- decides whether the inheritance happens at all. Answers the one-based parent
-- slot, or nil when the nature is not inherited.
---@param parents table[]
---@param lc fun(): integer
---@return integer?
function Breeding.everstoneParent(parents, lc)
  local holders, count = nil, 0
  for slot = 1, 2 do
    if parents[slot].heldItem == Breeding.EVERSTONE then
      holders = slot
      count = count + 1
    end
  end
  if count == 2 then
    -- The source inverts its own parity: an even draw selects the second
    -- parent.
    local selected = lc() % 2 == 0 and 2 or 1
    if lc() >= Breeding.EVERSTONE_ACTIVATION_LIMIT then
      return nil
    end
    return selected
  end
  if count == 1 then
    if lc() >= Breeding.EVERSTONE_ACTIVATION_LIMIT then
      return nil
    end
    return holders
  end
  return nil
end

-- GenerateEggPID: an activated Everstone inheritance draws source random
-- values until the personality matches the holder's nature with a nonzero
-- value, keeping the last draw once the source bound is passed. Otherwise one
-- source random value becomes the pending personality. A zero result is a
-- legal outcome: the caller still attempts the phone trigger.
---@param opts { parents: table[], lc: fun(): integer, mt: fun(): integer }
---@return integer pending egg personality
function Breeding.generateEggPid(opts)
  assert(type(opts) == "table", "egg personality generation requires its draws")
  local parents = opts.parents
  local lc = assert(opts.lc, "egg personality generation requires the linear draw")
  local mt = assert(opts.mt, "egg personality generation requires the source draw")
  requirePair(parents)
  local holder = Breeding.everstoneParent(parents, lc)
  if holder == nil then
    return mt()
  end
  local nature = Personality.nature(parents[holder].personality)
  local draws = 0
  local personality = nil
  while true do
    personality = mt()
    if Personality.nature(personality) == nature and personality ~= 0 then
      break
    end
    draws = draws + 1
    if draws > Breeding.NATURE_DRAW_LIMIT then
      break
    end
  end
  assert(type(personality) == "number", "the nature search always keeps its last draw")
  return personality
end

-- Save_Daycare_MasudaCheck: the source compares the two stored languages.
---@param parents table[]
---@return boolean
function Breeding.differentLanguages(parents)
  requirePair(parents)
  return parents[1].origin.language ~= parents[2].origin.language
end

-- SetBreedEggStats' different-language path: when the parent languages differ
-- and the stored personality is not already shiny for the receiving trainer,
-- up to four PRandom steps advance the value that becomes the egg's own
-- personality. The pending identity itself is never rewritten.
---@param opts { pendingEggPid: integer, parents: table[], trainerId: integer }
---@return integer egg personality
function Breeding.eggPersonality(opts)
  assert(type(opts) == "table", "the egg personality needs its pending identity")
  local personality = assert(opts.pendingEggPid, "the egg personality needs the pending identity")
  if not Breeding.differentLanguages(opts.parents) then
    return personality
  end
  if Personality.shiny(opts.trainerId, personality) then
    return personality
  end
  for _ = 1, Breeding.LANGUAGE_PERSONALITY_DRAWS do
    personality = U32.add(U32.mul(personality, Breeding.PERSONALITY_MIXER), 1)
    if Personality.shiny(opts.trainerId, personality) then
      break
    end
  end
  return personality
end

-- Daycare_GetEggSpecies plus Daycare_BreedingIncenseCheck: the non-Ditto
-- parent selects the mother, whose PMS entry names the offspring; the Nidoran
-- and Illumise families split on the pending personality's 0x8000 bit, Manaphy
-- always produces Phione, and a baby that only exists with its incense is
-- replaced by its evolved parent when neither parent holds that incense. The
-- mother's form rides the egg. Answers the resolved species, form, and the
-- parent slots the offspring inherits from (mother first).
---@param opts { parents: table[], pendingEggPid: integer, catalog: MonCatalog, care: table<string, unknown> }
---@return { species: string, form: integer, motherSlot: integer, fatherSlot: integer }
function Breeding.offspring(opts)
  assert(type(opts) == "table", "offspring resolution requires its sources")
  local parents = opts.parents
  local catalog = assert(opts.catalog, "offspring resolution requires the mon catalog")
  local care = assert(opts.care, "offspring resolution requires the care catalog")
  requirePair(parents)
  local pendingEggPid = assert(opts.pendingEggPid, "offspring resolution requires the pending identity")
  local motherSlot, fatherSlot = nil, nil
  for slot = 1, 2 do
    local species = catalog:species(parents[slot].species)
    if parents[slot].species == Breeding.DITTO then
      motherSlot = slot == 1 and 2 or 1
      fatherSlot = slot
    elseif Personality.gender(species.genderRatio, parents[slot].personality) == "female" then
      motherSlot = slot
      fatherSlot = slot == 1 and 2 or 1
    end
  end
  if motherSlot == nil or fatherSlot == nil then
    reject("the breeding pair names no mother", {})
  end
  assert(motherSlot ~= nil and fatherSlot ~= nil, "the breeding pair resolves both parents")
  local motherSpecies = parents[motherSlot].species
  local eggSpecies = care.eggSpecies[motherSpecies]
  if eggSpecies == nil then
    reject("the care catalog carries no egg species for " .. motherSpecies, { species = motherSpecies })
  end
  assert(eggSpecies ~= nil, "the care catalog owns every source egg species")
  if eggSpecies == "NIDORAN_F" then
    eggSpecies = maleSplit(pendingEggPid) and "NIDORAN_M" or "NIDORAN_F"
  elseif eggSpecies == "ILLUMISE" then
    eggSpecies = maleSplit(pendingEggPid) and "VOLBEAT" or "ILLUMISE"
  elseif eggSpecies == "MANAPHY" then
    eggSpecies = "PHIONE"
  end
  for _, row in ipairs(care.incense) do
    if row.baby == eggSpecies then
      local incense = row.item
      if parents[1].heldItem ~= incense and parents[2].heldItem ~= incense then
        eggSpecies = row.parent
      end
      break
    end
  end
  local motherGender = Personality.gender(
    catalog:species(motherSpecies).genderRatio,
    parents[motherSlot].personality
  )
  if parents[fatherSlot].species == Breeding.DITTO and motherGender ~= "female" then
    motherSlot, fatherSlot = fatherSlot, motherSlot
  end
  return {
    species = eggSpecies,
    form = parents[motherSlot].form,
    motherSlot = motherSlot,
    fatherSlot = fatherSlot,
  }
end

-- Daycare_TryGetForcedInheritedIV: one power item forces its holder's stat, and
-- two holders spend one parity draw on which of them contributes. Answers the
-- forced stat and its one-based parent slot, or nil.
---@param parents table[]
---@param lc fun(): integer
---@return { stat: string, slot: integer }?
function Breeding.forcedIvStat(parents, lc)
  local statBySlot, count, lastSlot = {}, 0, nil
  for slot = 1, 2 do
    local stat = Breeding.POWER_ITEM_STATS[parents[slot].heldItem]
    if stat ~= nil then
      statBySlot[slot] = stat
      count = count + 1
      lastSlot = slot
    end
  end
  if count == 2 then
    local slot = lc() % 2 ~= 0 and 1 or 2
    return { stat = assert(statBySlot[slot]), slot = slot }
  end
  if count == 1 then
    assert(lastSlot ~= nil, "the single power item names its holder")
    return { stat = assert(statBySlot[lastSlot]), slot = lastSlot }
  end
  return nil
end

-- InheritIVs: exactly three distinct stats come from the parents. The forced
-- power-item stat (when present) takes the first slot, the remaining stat
-- indices are chosen first, and only then are their parent choices drawn.
---@param opts { parents: table[], lc: fun(): integer }
---@return { stat: string, slot: integer }[] inherited assignments in source order
function Breeding.inheritedIvs(opts)
  assert(type(opts) == "table", "individual-value inheritance requires its draws")
  local parents = opts.parents
  requirePair(parents)
  local lc = assert(opts.lc, "individual-value inheritance requires the linear draw")
  local statList = {}
  for index, key in ipairs(Breeding.STAT_KEYS) do
    statList[index] = key
  end
  local assignments = {}
  local startIndex = 1
  local forced = Breeding.forcedIvStat(parents, lc)
  if forced ~= nil then
    assignments[1] = forced
    startIndex = 2
    for index, key in ipairs(statList) do
      if key == forced.stat then
        table.remove(statList, index)
        break
      end
    end
  end
  local count = #Breeding.STAT_KEYS
  for index = startIndex, 3 do
    local position = lc() % (count - (index - 1)) + 1
    assignments[index] = { stat = assert(statList[position]), slot = 0 }
    table.remove(statList, position)
  end
  for index = startIndex, 3 do
    local assignment = assert(assignments[index])
    assignment.slot = lc() % 2 + 1
  end
  return assignments
end

---@param mon table<string, unknown>
---@return string[]
local function knownMoves(mon)
  local keys = {}
  for index, entry in ipairs(mon.moves) do
    if entry.move == nil then
      break
    end
    keys[index] = entry.move
  end
  return keys
end

-- TryAppendMonMove with MOVE_APPEND_FULL's DeleteMonFirstMoveAndAppend: a known
-- move appends nothing, a free slot takes the move at its base power points,
-- and a full set drops its first move before appending the new one last.
---@param moves table<string, unknown>[]
---@param moveKey string
---@param catalog MonCatalog
local function appendMove(moves, moveKey, catalog)
  for _, entry in ipairs(moves) do
    if entry.move == moveKey then
      return
    end
  end
  local appended = { move = moveKey, pp = catalog:move(moveKey).basePp, ppUps = 0 }
  if #moves < Moves.MAX_SLOTS then
    moves[#moves + 1] = appended
    return
  end
  for index = 1, Moves.MAX_SLOTS - 1 do
    moves[index] = moves[index + 1]
  end
  moves[Moves.MAX_SLOTS] = appended
end

-- InheritMoves: the offspring's level-one defaults, then the father's egg moves
-- in father slot order, then the father's compatible TM/HMs, then the parental
-- moves that are shared and appear in the offspring's own level-up list; a
-- Pichu adds Volt Tackle when either parent holds a Light Ball. Every insertion
-- skips a move the offspring already knows.
---@param opts { offspring: { species: string, form: integer }, mother: table, father: table, catalog: MonCatalog, care: table<string, unknown> }
---@return table<string, unknown>[] the inherited move set in slot order
function Breeding.inheritedMoves(opts)
  assert(type(opts) == "table", "move inheritance requires its sources")
  local catalog = assert(opts.catalog, "move inheritance requires the mon catalog")
  local care = assert(opts.care, "move inheritance requires the care catalog")
  local offspring = assert(opts.offspring, "move inheritance names the offspring")
  local mother = assert(opts.mother, "move inheritance needs the mother record")
  local father = assert(opts.father, "move inheritance needs the father record")
  local form = catalog:form(offspring.species, offspring.form)
  local moves = Moves.initial(form.levelUpMoves, 1, catalog)
  local eggMoves = care.eggMoves[offspring.species] or {}
  local fatherMoves = knownMoves(father)
  local motherMoves = knownMoves(mother)
  for _, moveKey in ipairs(fatherMoves) do
    for _, eggMoveKey in ipairs(eggMoves) do
      if moveKey == eggMoveKey then
        appendMove(moves, moveKey, catalog)
        break
      end
    end
  end
  for _, moveKey in ipairs(fatherMoves) do
    for _, machineMoveKey in ipairs(form.tmhm) do
      if moveKey == machineMoveKey then
        appendMove(moves, moveKey, catalog)
        break
      end
    end
  end
  local shared = {}
  for _, moveKey in ipairs(fatherMoves) do
    for _, motherMoveKey in ipairs(motherMoves) do
      if moveKey == motherMoveKey and #shared < Breeding.MAX_SHARED_MOVES then
        shared[#shared + 1] = moveKey
      end
    end
  end
  for _, moveKey in ipairs(shared) do
    for _, entry in ipairs(form.levelUpMoves) do
      if entry.move == moveKey then
        appendMove(moves, moveKey, catalog)
        break
      end
    end
  end
  if offspring.species == "PICHU" then
    local lightBall = false
    for _, parent in ipairs({ mother, father }) do
      lightBall = lightBall or parent.heldItem == Breeding.LIGHT_BALL
    end
    if lightBall then
      appendMove(moves, Breeding.VOLT_TACKLE, catalog)
    end
  end
  return moves
end

return Breeding
