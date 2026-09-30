-- Validation for composed mon catalog roots. The shape contract mirrors
-- the generated mon asset catalog, with two deliberate policy differences:
-- native identities are optional (custom entries resolve semantically with
-- no numeric identity), and form type keys are open (custom types validate
-- through the battle chart, not a native whitelist). Declared native
-- identities must still be unique integers in their native ranges, every
-- species, move, and ability cross-reference must resolve, and growth
-- curves keep their exact native contract. The strict generated-asset
-- validator is untouched: this schema never validates ROM-produced roots.

local Errors = require("libs.errors.src.Errors")
local Validate = require("libs.assets.src.Validate")
local BattleDataSchema = require("libs.assets.src.battle.BattleDataSchema")

---@class ResolvedMonSchema
local ResolvedMonSchema = {}

local STAT_SET = { hp = true, attack = true, defense = true, speed = true, specialAttack = true, specialDefense = true }

local STAT_KEYS = { "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }

local GROWTH_KEYS = {
  medium_fast = true,
  erratic = true,
  fluctuating = true,
  medium_slow = true,
  fast = true,
  slow = true,
  unused_6 = true,
  unused_7 = true,
}

local CATEGORY_KEYS = { physical = true, special = true, status = true }

local EVO_METHODS = {
  friendship = true,
  friendship_day = true,
  friendship_night = true,
  level = true,
  trade = true,
  trade_item = true,
  stone = true,
  level_atk_gt_def = true,
  level_atk_eq_def = true,
  level_atk_lt_def = true,
  level_pid_lo = true,
  level_pid_hi = true,
  level_ninjask = true,
  level_shedinja = true,
  beauty = true,
  stone_male = true,
  stone_female = true,
  item_day = true,
  item_night = true,
  has_move = true,
  other_party_mon = true,
  level_male = true,
  level_female = true,
  coronet = true,
  eterna = true,
  route217 = true,
}

local FORM_FIELDS = {
  baseStats = true,
  types = true,
  abilities = true,
  tmhm = true,
  levelUpMoves = true,
  evolutions = true,
  icon = true,
  portrait = true,
  follower = true,
  performance = true,
}

local function fail(message, context)
  Errors.raise("MON_RESOLVED_INVALID", message, context or {})
end

---@param record unknown
---@param allowed table<string, boolean>
---@param context table<string, unknown>
local function checkKeys(record, allowed, context)
  for key in pairs(record) do
    if allowed[key] == nil then
      fail("unknown field " .. tostring(key), context)
    end
  end
end

---@param value unknown
---@param lower integer
---@param upper integer?
---@param context table<string, unknown>
---@param field string
local function checkInt(value, lower, upper, context, field)
  if type(value) ~= "number" or value % 1 ~= 0 or value < lower or (upper ~= nil and value > upper) then
    if upper == nil then
      fail(field .. " must be an integer at least " .. tostring(lower), context)
    else
      fail(field .. " must be an integer in " .. tostring(lower) .. ".." .. tostring(upper), context)
    end
  end
end

---@param value unknown
---@param context table<string, unknown>
---@param field string
local function checkText(value, context, field)
  if type(value) ~= "string" or value == "" then
    fail(field .. " must be a non-empty string", context)
  end
end

---@param value unknown
---@param upper integer
---@param context table<string, unknown>
---@param field string
local function checkOptionalNativeId(value, upper, context, field)
  if value == nil then
    return
  end
  checkInt(value, 0, upper, context, field)
end

---@param values table<string, unknown>
---@param context table<string, unknown>
---@param field string
local function checkStats(values, context, field)
  if type(values) ~= "table" then
    fail(field .. " must be a record", context)
  end
  checkKeys(values, STAT_SET, context)
  for _, key in ipairs(STAT_KEYS) do
    checkInt(values[key], 0, 255, context, field .. "." .. key)
  end
end

---@param values table<string, unknown>
---@param context table<string, unknown>
---@param field string
local function checkEvYield(values, context, field)
  if type(values) ~= "table" then
    fail(field .. " must be a record", context)
  end
  checkKeys(values, STAT_SET, context)
  for _, key in ipairs(STAT_KEYS) do
    checkInt(values[key], 0, 3, context, field .. "." .. key)
  end
end

---@param identity table<string, unknown>
---@param context table<string, unknown>
---@param field string
local function checkItemIdentity(identity, context, field)
  if type(identity) ~= "table" then
    fail(field .. " must be a record", context)
  end
  checkKeys(identity, { item = true, nativeId = true }, context)
  checkText(identity.item, context, field .. ".item")
  checkInt(identity.nativeId, 0, 536, context, field .. ".nativeId")
end

---@param form table<string, unknown>
---@param context table<string, unknown>
local function assertForm(form, context)
  if type(form) ~= "table" then
    fail("form must be a record", context)
  end
  checkKeys(form, FORM_FIELDS, context)
  checkStats(form.baseStats, context, "baseStats")
  -- Type keys stay open: native and custom types alike are non-empty
  -- strings, and chart membership is the battle composition's check.
  if not Validate.isArray(form.types) or (#form.types ~= 1 and #form.types ~= 2) then
    fail("types must carry one or two entries", context)
  end
  for _, typeKey in ipairs(form.types) do
    checkText(typeKey, context, "type")
  end
  if not Validate.isArray(form.abilities) or #form.abilities < 1 or #form.abilities > 2 then
    fail("abilities must carry one or two entries", context)
  end
  local seenAbilities = {}
  for _, abilityKey in ipairs(form.abilities) do
    checkText(abilityKey, context, "ability")
    if seenAbilities[abilityKey] then
      fail("duplicate ability entry " .. abilityKey, context)
    end
    seenAbilities[abilityKey] = true
  end
  if not Validate.isArray(form.tmhm) then
    fail("tmhm must be an array", context)
  end
  local lastMachine = nil
  local seenMachines = {}
  for _, moveKey in ipairs(form.tmhm) do
    checkText(moveKey, context, "tmhm move")
    if seenMachines[moveKey] then
      fail("duplicate tmhm move " .. moveKey, context)
    end
    seenMachines[moveKey] = true
    if lastMachine ~= nil and moveKey <= lastMachine then
      fail("tmhm moves must be sorted", context)
    end
    lastMachine = moveKey
  end
  if not Validate.isArray(form.levelUpMoves) then
    fail("levelUpMoves must be an array", context)
  end
  for _, entry in ipairs(form.levelUpMoves) do
    if type(entry) ~= "table" then
      fail("learnset entry must be a record", context)
    end
    checkKeys(entry, { level = true, move = true }, context)
    checkInt(entry.level, 1, 100, context, "learnset level")
    checkText(entry.move, context, "learnset move")
  end
  if not Validate.isArray(form.evolutions) then
    fail("evolutions must be an array", context)
  end
  for _, entry in ipairs(form.evolutions) do
    if type(entry) ~= "table" or type(entry.method) ~= "string" or EVO_METHODS[entry.method] == nil then
      fail("evolution method is unknown", context)
    end
    checkText(entry.target, context, "evolution target")
    checkInt(entry.form, 0, nil, context, "evolution form")
  end
  checkText(form.icon, context, "icon selector")
  checkText(form.portrait, context, "portrait selector")
  -- Source contest performance rides the native forms; custom entries may
  -- omit it, while declared bands stay in the source 0..7 domain with
  -- min <= base <= max.
  if form.performance ~= nil then
    if type(form.performance) ~= "table" then
      fail("performance must be a record", context)
    end
    checkKeys(form.performance, { power = true, skill = true, speed = true, jump = true, stamina = true }, context)
    for _, stat in ipairs({ "power", "skill", "speed", "jump", "stamina" }) do
      local value = form.performance[stat]
      if type(value) ~= "table" then
        fail("performance." .. stat .. " must be a record", context)
      end
      checkKeys(value, { base = true, min = true, max = true }, context)
      checkInt(value.base, 0, 7, context, "performance." .. stat .. ".base")
      checkInt(value.min, 0, 7, context, "performance." .. stat .. ".min")
      checkInt(value.max, 0, 7, context, "performance." .. stat .. ".max")
      if value.min > value.base or value.base > value.max then
        fail("performance." .. stat .. " must satisfy min <= base <= max", context)
      end
    end
  end
end

---@param key string
---@param species table<string, unknown>
---@param context table<string, unknown>
local function assertSpecies(key, species, context)
  if type(species) ~= "table" then
    fail("species " .. key .. " must be a record", context)
  end
  checkKeys(species, {
    nativeId = true,
    name = true,
    growthCurve = true,
    baseFriendship = true,
    genderRatio = true,
    eggCycles = true,
    eggGroups = true,
    catchRate = true,
    baseExpYield = true,
    evYield = true,
    heldItems = true,
    color = true,
    flip = true,
    forms = true,
    weight = true,
  }, context)
  checkOptionalNativeId(species.nativeId, 495, context, "species " .. key .. " nativeId")
  checkText(species.name, context, "species " .. key .. " name")
  if GROWTH_KEYS[species.growthCurve] == nil then
    fail("species " .. key .. " has an unknown growth curve", context)
  end
  checkInt(species.baseFriendship, 0, 255, context, "species " .. key .. " baseFriendship")
  checkInt(species.genderRatio, 0, 255, context, "species " .. key .. " genderRatio")
  checkInt(species.eggCycles, 0, 255, context, "species " .. key .. " eggCycles")
  checkInt(species.catchRate, 0, 255, context, "species " .. key .. " catchRate")
  checkInt(species.baseExpYield, 0, 255, context, "species " .. key .. " baseExpYield")
  if not Validate.isArray(species.eggGroups) or #species.eggGroups ~= 2 then
    fail("species " .. key .. " must carry two egg groups", context)
  end
  checkEvYield(species.evYield, context, "species " .. key .. " evYield")
  if type(species.heldItems) ~= "table" then
    fail("species " .. key .. " heldItems must be a record", context)
  end
  checkKeys(species.heldItems, { common = true, rare = true }, context)
  checkItemIdentity(species.heldItems.common, context, "species " .. key .. " heldItems.common")
  checkItemIdentity(species.heldItems.rare, context, "species " .. key .. " heldItems.rare")
  checkInt(species.color, 0, 127, context, "species " .. key .. " color")
  if type(species.flip) ~= "boolean" then
    fail("species " .. key .. " flip must be a boolean", context)
  end
  if species.weight ~= nil then
    checkInt(species.weight, 0, 2147483647, context, "species " .. key .. " weight")
  end
  if type(species.forms) ~= "table" or species.forms[0] == nil then
    fail("species " .. key .. " must carry its base form", context)
  end
  for formId, form in pairs(species.forms) do
    checkInt(formId, 0, nil, context, "species " .. key .. " form id")
    assertForm(form, { species = key, form = formId })
  end
end

---@param key string
---@param move table<string, unknown>
---@param context table<string, unknown>
local function assertMove(key, move, context)
  if type(move) ~= "table" then
    fail("move " .. key .. " must be a record", context)
  end
  checkKeys(move, {
    nativeId = true,
    name = true,
    description = true,
    effect = true,
    category = true,
    power = true,
    moveType = true,
    accuracy = true,
    basePp = true,
    effectChance = true,
    range = true,
    priority = true,
    flags = true,
    unknownC = true,
    contestType = true,
    battle = true,
  }, context)
  checkOptionalNativeId(move.nativeId, 467, context, "move " .. key .. " nativeId")
  checkText(move.name, context, "move " .. key .. " name")
  if type(move.description) ~= "string" then
    fail("move " .. key .. " description must be a string", context)
  end
  checkInt(move.effect, 0, 65535, context, "move " .. key .. " effect")
  if CATEGORY_KEYS[move.category] == nil then
    fail("move " .. key .. " has an unknown category", context)
  end
  checkInt(move.power, 0, 255, context, "move " .. key .. " power")
  checkText(move.moveType, context, "move " .. key .. " moveType")
  checkInt(move.accuracy, 0, 100, context, "move " .. key .. " accuracy")
  checkInt(move.basePp, 0, 40, context, "move " .. key .. " basePp")
  checkInt(move.effectChance, 0, 100, context, "move " .. key .. " effectChance")
  checkInt(move.range, 0, 65535, context, "move " .. key .. " range")
  checkInt(move.priority, -128, 127, context, "move " .. key .. " priority")
  checkInt(move.flags, 0, 255, context, "move " .. key .. " flags")
  checkInt(move.unknownC, 0, 255, context, "move " .. key .. " unknownC")
  checkInt(move.contestType, 0, 255, context, "move " .. key .. " contestType")
  if move.battle ~= nil then
    BattleDataSchema.assertBattleRecord(move.battle, context, "move " .. key .. " battle")
  end
end

---@param key string
---@param ability table<string, unknown>
---@param context table<string, unknown>
local function assertAbility(key, ability, context)
  if type(ability) ~= "table" then
    fail("ability " .. key .. " must be a record", context)
  end
  checkKeys(ability, { nativeId = true, name = true, description = true }, context)
  checkOptionalNativeId(ability.nativeId, 123, context, "ability " .. key .. " nativeId")
  checkText(ability.name, context, "ability " .. key .. " name")
  if type(ability.description) ~= "string" then
    fail("ability " .. key .. " description must be a string", context)
  end
end

---@param section table<string, unknown>
---@param what string
---@param context table<string, unknown>
---@return table<string, boolean> the section keys
local function collectKeys(section, what, context)
  if type(section) ~= "table" then
    fail(what .. " must be a record", context)
  end
  local keys = {}
  for key, record in pairs(section) do
    if type(key) ~= "string" or key == "" then
      fail(what .. " keys must be non-empty strings", context)
    end
    if type(record) ~= "table" then
      fail(what .. " " .. key .. " must be a record", context)
    end
    keys[key] = true
  end
  return keys
end

---@param section table<string, table<string, unknown>>
---@param field string
---@param what string
---@param context table<string, unknown>
local function collectNativeIds(section, field, what, context)
  local ids = {}
  for key, record in pairs(section) do
    local id = record[field]
    if id ~= nil then
      if ids[id] then
        fail("duplicate " .. what .. " native identity " .. tostring(id), context)
      end
      ids[id] = key
    end
  end
end

---@param key string
---@param curve unknown
---@param context table<string, unknown>
local function assertGrowthCurve(key, curve, context)
  if not Validate.isArray(curve) or #curve ~= 100 then
    fail("growth curve " .. key .. " must carry levels 1..100", context)
  end
  if curve[1] ~= 0 then
    fail("growth curve " .. key .. " level 1 must be zero", context)
  end
  for level = 1, 100 do
    local value = curve[level]
    checkInt(value, 0, 4294967295, context, "growth curve " .. key .. " level " .. level)
    if level > 1 and value < curve[level - 1] then
      fail("growth curve " .. key .. " must be non-decreasing", context)
    end
  end
end

---@param key string
---@param species table<string, unknown>
---@param speciesKeys table<string, boolean>
---@param moveKeys table<string, boolean>
---@param abilityKeys table<string, boolean>
---@param context table<string, unknown>
local function checkSpeciesReferences(key, species, speciesKeys, moveKeys, abilityKeys, context)
  for _, form in pairs(species.forms) do
    for _, abilityKey in ipairs(form.abilities) do
      if abilityKeys[abilityKey] == nil then
        fail("species " .. key .. " references unknown ability " .. abilityKey, context)
      end
    end
    for _, moveKey in ipairs(form.tmhm) do
      if moveKeys[moveKey] == nil then
        fail("species " .. key .. " references unknown tmhm move " .. moveKey, context)
      end
    end
    for _, entry in ipairs(form.levelUpMoves) do
      if moveKeys[entry.move] == nil then
        fail("species " .. key .. " references unknown learnset move " .. entry.move, context)
      end
    end
    for _, entry in ipairs(form.evolutions) do
      if speciesKeys[entry.target] == nil then
        fail("species " .. key .. " evolves into unknown species " .. entry.target, context)
      end
      if entry.move ~= nil and moveKeys[entry.move] == nil then
        fail("species " .. key .. " references unknown evolution move " .. entry.move, context)
      end
      if entry.species ~= nil and speciesKeys[entry.species] == nil then
        fail("species " .. key .. " references unknown evolution species " .. entry.species, context)
      end
    end
  end
end

-- Full composed-catalog validation: shapes plus every species, move, and
-- ability cross-reference. Native identities stay optional and custom type
-- keys pass; declared native identities must be unique.
---@param catalog table<string, unknown>
---@return boolean true when the composed catalog is valid
function ResolvedMonSchema.assertCatalog(catalog)
  local context = {}
  if type(catalog) ~= "table" then
    fail("catalog must be a record", context)
  end
  checkKeys(catalog, {
    schema = true,
    version = true,
    species = true,
    moves = true,
    abilities = true,
    growthCurves = true,
  }, context)
  if catalog.schema ~= "g4-mon-catalog-v4" then
    fail("catalog schema must be g4-mon-catalog-v4", context)
  end
  if type(catalog.version) ~= "table" then
    fail("catalog version must be a record", context)
  end
  checkKeys(catalog.version, { id = true, language = true }, context)
  checkText(catalog.version.id, context, "catalog version id")
  checkText(catalog.version.language, context, "catalog version language")
  local speciesKeys = collectKeys(catalog.species, "species", context)
  local moveKeys = collectKeys(catalog.moves, "moves", context)
  local abilityKeys = collectKeys(catalog.abilities, "abilities", context)
  collectNativeIds(catalog.species, "nativeId", "species", context)
  collectNativeIds(catalog.moves, "nativeId", "moves", context)
  collectNativeIds(catalog.abilities, "nativeId", "abilities", context)
  for key, species in pairs(catalog.species) do
    assertSpecies(key, species, context)
    checkSpeciesReferences(key, species, speciesKeys, moveKeys, abilityKeys, context)
  end
  for key, move in pairs(catalog.moves) do
    assertMove(key, move, context)
  end
  for key, ability in pairs(catalog.abilities) do
    assertAbility(key, ability, context)
  end
  if type(catalog.growthCurves) ~= "table" then
    fail("growthCurves must be a record", context)
  end
  for key in pairs(catalog.growthCurves) do
    if GROWTH_KEYS[key] == nil then
      fail("unknown growth curve " .. tostring(key), context)
    end
  end
  for key in pairs(GROWTH_KEYS) do
    assertGrowthCurve(key, catalog.growthCurves[key], context)
  end
  return true
end

return ResolvedMonSchema
