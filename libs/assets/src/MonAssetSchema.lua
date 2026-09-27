-- Authoritative validation for the generated mon asset class. Catalogs,
-- class indexes, and icon/portrait manifests are plain source-independent
-- data: every loader, producer writer, and test calls these validators, so
-- no second interpretation of the shapes exists. Unknown fields, duplicate
-- identities, out-of-range values, and dangling cross-references fail loudly.
-- Order is significant only for level-up learnsets and evolution slots, which
-- the source consumes positionally. Per-form checks are structural (they take
-- only an error context); catalog checks additionally resolve every
-- species/move/ability reference against the catalog's own keys. Love-free
-- and filesystem-free.

local Errors = require("libs.errors.src.Errors")
local Validate = require("libs.assets.src.Validate")

---@class MonAssetSchema
local MonAssetSchema = {}

local STAT_KEYS = { "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }

local STAT_SET = { hp = true, attack = true, defense = true, speed = true, specialAttack = true, specialDefense = true }

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

local TYPE_KEYS = {
  normal = true,
  fighting = true,
  flying = true,
  poison = true,
  ground = true,
  rock = true,
  bug = true,
  ghost = true,
  steel = true,
  mystery = true,
  fire = true,
  water = true,
  grass = true,
  electric = true,
  psychic = true,
  ice = true,
  dragon = true,
  dark = true,
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

local LEVEL_METHODS = {
  level = true,
  level_atk_gt_def = true,
  level_atk_eq_def = true,
  level_atk_lt_def = true,
  level_pid_lo = true,
  level_pid_hi = true,
  level_ninjask = true,
  level_shedinja = true,
  level_male = true,
  level_female = true,
}

local ITEM_METHODS = {
  trade_item = true,
  stone = true,
  stone_male = true,
  stone_female = true,
  item_day = true,
  item_night = true,
}

local NO_PARAM_METHODS = {
  friendship = true,
  friendship_day = true,
  friendship_night = true,
  trade = true,
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
}

local function fail(code, message, context)
  Errors.raise(code, message, context or {})
end

local function checkKeys(record, allowed, context, code)
  for key in pairs(record) do
    if allowed[key] == nil then
      fail(code, "unknown field " .. tostring(key), context)
    end
  end
end

local function checkRecord(record, allowed, context, code, field)
  if type(record) ~= "table" then
    fail(code, field .. " must be a record", context)
  end
  if allowed ~= nil then
    checkKeys(record, allowed, context, code)
  end
end

local function checkInt(value, lower, upper, context, code, field)
  if type(value) ~= "number" or value % 1 ~= 0 or value < lower or (upper ~= nil and value > upper) then
    if upper == nil then
      fail(code, field .. " must be an integer at least " .. tostring(lower), context)
    else
      fail(code, field .. " must be an integer in " .. tostring(lower) .. ".." .. tostring(upper), context)
    end
  end
end

local function checkU8(value, context, code, field)
  checkInt(value, 0, 255, context, code, field)
end

local function checkNonEmptyString(value, context, code, field)
  if type(value) ~= "string" or value == "" then
    fail(code, field .. " must be a non-empty string", context)
  end
end

local function checkEvValue(value, context, code, field)
  checkInt(value, 0, 3, context, code, field)
end

local function checkStatRecord(values, field, context, code, checkValue)
  checkRecord(values, STAT_SET, context, code, field)
  for _, key in ipairs(STAT_KEYS) do
    checkValue(values[key], context, code, field .. "." .. key)
  end
end

local function checkStats(stats, context, code)
  checkStatRecord(stats, "stats", context, code, checkU8)
end

local function checkEvYield(evYield, context, code)
  checkStatRecord(evYield, "evYield", context, code, checkEvValue)
end

local function checkItemIdentity(identity, context, code, field)
  checkRecord(identity, { item = true, nativeId = true }, context, code, field)
  checkNonEmptyString(identity.item, context, code, field .. ".item")
  checkInt(identity.nativeId, 0, 536, context, code, field .. ".nativeId")
end

local function checkStringArray(values, context, code, field, minCount, maxCount)
  if not Validate.isArray(values) or #values < minCount or #values > maxCount then
    fail(code, field .. " must carry " .. minCount .. ".." .. maxCount .. " entries", context)
  end
  local seen = {}
  for _, value in ipairs(values) do
    checkNonEmptyString(value, context, code, field)
    if seen[value] then
      fail(code, "duplicate " .. field .. " entry " .. value, context)
    end
    seen[value] = true
  end
end

local function checkEvolutionShape(entry, context, code)
  checkRecord(entry, nil, context, code, "evolution")
  local method = entry.method
  if type(method) ~= "string" or EVO_METHODS[method] == nil then
    fail(code, "evolution method is unknown: " .. tostring(method), context)
  end
  checkNonEmptyString(entry.target, context, code, "evolution target")
  checkInt(entry.form, 0, nil, context, code, "evolution form")
  if LEVEL_METHODS[method] then
    checkKeys(entry, { method = true, level = true, target = true, form = true }, context, code)
    checkInt(entry.level, 1, 100, context, code, "evolution level")
  elseif ITEM_METHODS[method] then
    checkKeys(entry, { method = true, item = true, target = true, form = true }, context, code)
    checkNonEmptyString(entry.item, context, code, "evolution item")
  elseif method == "beauty" then
    checkKeys(entry, { method = true, threshold = true, target = true, form = true }, context, code)
    checkInt(entry.threshold, 1, 255, context, code, "evolution threshold")
  elseif method == "has_move" then
    checkKeys(entry, { method = true, move = true, target = true, form = true }, context, code)
    checkNonEmptyString(entry.move, context, code, "evolution move")
  elseif method == "other_party_mon" then
    checkKeys(entry, { method = true, species = true, target = true, form = true }, context, code)
    checkNonEmptyString(entry.species, context, code, "evolution species")
  elseif NO_PARAM_METHODS[method] then
    checkKeys(entry, { method = true, target = true, form = true }, context, code)
  else
    fail(code, "evolution method has no parameter rule: " .. method, context)
  end
end

local function checkFollowerTriple(visual, context, code, field)
  checkInt(visual.visualId, 1, nil, context, code, field .. ".visualId")
  checkU8(visual.size, context, code, field .. ".size")
  checkInt(visual.objectParam, 0, 65535, context, code, field .. ".objectParam")
end

local function checkFollowerShape(follower, context, code)
  checkRecord(follower, { visualId = true, size = true, objectParam = true, female = true }, context, code, "follower")
  checkFollowerTriple(follower, context, code, "follower")
  if follower.female ~= nil then
    checkRecord(follower.female, { visualId = true, size = true, objectParam = true }, context, code, "follower.female")
    checkFollowerTriple(follower.female, context, code, "follower.female")
  end
end

-- Structural form validation: shapes, ranges, and field sets. Reference
-- membership (species/move/ability keys, manifest selectors) is the catalog
-- and writer cross-reference step, which owns the full key universes.
function MonAssetSchema.assertForm(form, context)
  context = context or {}
  checkRecord(form, FORM_FIELDS, context, "MON_FORM_INVALID", "form")
  checkStats(form.baseStats, context, "MON_FORM_INVALID")
  if not Validate.isArray(form.types) or (#form.types ~= 1 and #form.types ~= 2) then
    fail("MON_FORM_INVALID", "types must carry one or two entries", context)
  end
  for _, typeKey in ipairs(form.types) do
    if TYPE_KEYS[typeKey] == nil then
      fail("MON_FORM_INVALID", "unknown type " .. tostring(typeKey), context)
    end
  end
  checkStringArray(form.abilities, context, "MON_FORM_INVALID", "abilities", 1, 2)
  if not Validate.isArray(form.tmhm) then
    fail("MON_FORM_INVALID", "tmhm must be an array", context)
  end
  local lastMachine = nil
  local seenMachines = {}
  for _, moveKey in ipairs(form.tmhm) do
    checkNonEmptyString(moveKey, context, "MON_FORM_INVALID", "tmhm move")
    if seenMachines[moveKey] then
      fail("MON_FORM_INVALID", "duplicate tmhm move " .. moveKey, context)
    end
    seenMachines[moveKey] = true
    if lastMachine ~= nil and moveKey <= lastMachine then
      fail("MON_FORM_INVALID", "tmhm moves must be sorted", context)
    end
    lastMachine = moveKey
  end
  if not Validate.isArray(form.levelUpMoves) then
    fail("MON_FORM_INVALID", "levelUpMoves must be an array", context)
  end
  for _, entry in ipairs(form.levelUpMoves) do
    checkRecord(entry, { level = true, move = true }, context, "MON_FORM_INVALID", "learnset entry")
    checkInt(entry.level, 1, 100, context, "MON_FORM_INVALID", "learnset level")
    checkNonEmptyString(entry.move, context, "MON_FORM_INVALID", "learnset move")
  end
  if not Validate.isArray(form.evolutions) then
    fail("MON_FORM_INVALID", "evolutions must be an array", context)
  end
  for _, entry in ipairs(form.evolutions) do
    checkEvolutionShape(entry, context, "MON_FORM_INVALID")
  end
  checkNonEmptyString(form.icon, context, "MON_FORM_INVALID", "icon selector")
  checkNonEmptyString(form.portrait, context, "MON_FORM_INVALID", "portrait selector")
  if form.follower ~= nil then
    checkFollowerShape(form.follower, context, "MON_FORM_INVALID")
  end
  return true
end

function MonAssetSchema.isValidForm(form, context)
  return pcall(MonAssetSchema.assertForm, form, context)
end

local SPECIES_FIELDS = {
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
}

local function assertSpecies(key, species, context)
  checkRecord(species, SPECIES_FIELDS, context, "MON_CATALOG_INVALID", "species " .. key)
  checkInt(species.nativeId, 0, 495, context, "MON_CATALOG_INVALID", "species " .. key .. " nativeId")
  checkNonEmptyString(species.name, context, "MON_CATALOG_INVALID", "species " .. key .. " name")
  if GROWTH_KEYS[species.growthCurve] == nil then
    fail("MON_CATALOG_INVALID", "species " .. key .. " has an unknown growth curve", context)
  end
  checkU8(species.baseFriendship, context, "MON_CATALOG_INVALID", "species " .. key .. " baseFriendship")
  checkU8(species.genderRatio, context, "MON_CATALOG_INVALID", "species " .. key .. " genderRatio")
  checkU8(species.eggCycles, context, "MON_CATALOG_INVALID", "species " .. key .. " eggCycles")
  checkU8(species.catchRate, context, "MON_CATALOG_INVALID", "species " .. key .. " catchRate")
  checkU8(species.baseExpYield, context, "MON_CATALOG_INVALID", "species " .. key .. " baseExpYield")
  if not Validate.isArray(species.eggGroups) or #species.eggGroups ~= 2 then
    fail("MON_CATALOG_INVALID", "species " .. key .. " must carry two egg groups", context)
  end
  checkEvYield(species.evYield, context, "MON_CATALOG_INVALID")
  checkRecord(
    species.heldItems,
    { common = true, rare = true },
    context,
    "MON_CATALOG_INVALID",
    "species " .. key .. " heldItems"
  )
  checkItemIdentity(species.heldItems.common, context, "MON_CATALOG_INVALID", "species " .. key .. " heldItems.common")
  checkItemIdentity(species.heldItems.rare, context, "MON_CATALOG_INVALID", "species " .. key .. " heldItems.rare")
  checkInt(species.color, 0, 127, context, "MON_CATALOG_INVALID", "species " .. key .. " color")
  if type(species.flip) ~= "boolean" then
    fail("MON_CATALOG_INVALID", "species " .. key .. " flip must be a boolean", context)
  end
  if type(species.forms) ~= "table" or species.forms[0] == nil then
    fail("MON_CATALOG_INVALID", "species " .. key .. " must carry its base form", context)
  end
  for formId, form in pairs(species.forms) do
    checkInt(formId, 0, nil, context, "MON_CATALOG_INVALID", "species " .. key .. " form id")
    MonAssetSchema.assertForm(form, { species = key, form = formId })
  end
end

local MOVE_FIELDS = {
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
}

local function assertMove(key, move, context)
  checkRecord(move, MOVE_FIELDS, context, "MON_CATALOG_INVALID", "move " .. key)
  checkInt(move.nativeId, 0, 467, context, "MON_CATALOG_INVALID", "move " .. key .. " nativeId")
  checkNonEmptyString(move.name, context, "MON_CATALOG_INVALID", "move " .. key .. " name")
  if type(move.description) ~= "string" then
    fail("MON_CATALOG_INVALID", "move " .. key .. " description must be a string", context)
  end
  checkInt(move.effect, 0, 65535, context, "MON_CATALOG_INVALID", "move " .. key .. " effect")
  if CATEGORY_KEYS[move.category] == nil then
    fail("MON_CATALOG_INVALID", "move " .. key .. " has an unknown category", context)
  end
  checkU8(move.power, context, "MON_CATALOG_INVALID", "move " .. key .. " power")
  if TYPE_KEYS[move.moveType] == nil then
    fail("MON_CATALOG_INVALID", "move " .. key .. " has an unknown type", context)
  end
  checkInt(move.accuracy, 0, 100, context, "MON_CATALOG_INVALID", "move " .. key .. " accuracy")
  checkInt(move.basePp, 0, 40, context, "MON_CATALOG_INVALID", "move " .. key .. " basePp")
  checkInt(move.effectChance, 0, 100, context, "MON_CATALOG_INVALID", "move " .. key .. " effectChance")
  checkInt(move.range, 0, 65535, context, "MON_CATALOG_INVALID", "move " .. key .. " range")
  checkInt(move.priority, -128, 127, context, "MON_CATALOG_INVALID", "move " .. key .. " priority")
  checkU8(move.flags, context, "MON_CATALOG_INVALID", "move " .. key .. " flags")
  checkU8(move.unknownC, context, "MON_CATALOG_INVALID", "move " .. key .. " unknownC")
  checkU8(move.contestType, context, "MON_CATALOG_INVALID", "move " .. key .. " contestType")
end

local function collectKeys(section, context, code, what)
  checkRecord(section, nil, context, code, what)
  local keys = {}
  for key, record in pairs(section) do
    if type(key) ~= "string" or key == "" then
      fail(code, what .. " keys must be non-empty strings", context)
    end
    if type(record) ~= "table" then
      fail(code, what .. " " .. key .. " must be a record", context)
    end
    keys[key] = true
  end
  return keys
end

local function collectNativeIds(section, field, context, code, what)
  local ids = {}
  for key, record in pairs(section) do
    local id = record[field]
    if type(id) ~= "number" then
      fail(code, what .. " " .. key .. " is missing its native identity", context)
    end
    if ids[id] then
      fail(code, "duplicate " .. what .. " native identity " .. tostring(id), context)
    end
    ids[id] = key
  end
  return ids
end

local function assertAbility(key, ability, context)
  checkRecord(
    ability,
    { nativeId = true, name = true, description = true },
    context,
    "MON_CATALOG_INVALID",
    "ability " .. key
  )
  checkInt(ability.nativeId, 0, 123, context, "MON_CATALOG_INVALID", "ability " .. key .. " nativeId")
  checkNonEmptyString(ability.name, context, "MON_CATALOG_INVALID", "ability " .. key .. " name")
  if type(ability.description) ~= "string" then
    fail("MON_CATALOG_INVALID", "ability " .. key .. " description must be a string", context)
  end
end

local function assertGrowthCurve(key, curve, context)
  if not Validate.isArray(curve) or #curve ~= 100 then
    fail("MON_CATALOG_INVALID", "growth curve " .. key .. " must carry levels 1..100", context)
  end
  if curve[1] ~= 0 then
    fail("MON_CATALOG_INVALID", "growth curve " .. key .. " level 1 must be zero", context)
  end
  for level = 1, 100 do
    local value = curve[level]
    checkInt(value, 0, 4294967295, context, "MON_CATALOG_INVALID", "growth curve " .. key .. " level " .. level)
    if level > 1 and value < curve[level - 1] then
      fail("MON_CATALOG_INVALID", "growth curve " .. key .. " must be non-decreasing", context)
    end
  end
end

local function checkSpeciesReferences(key, species, speciesKeys, moveKeys, abilityKeys, context)
  for _, form in pairs(species.forms) do
    for _, abilityKey in ipairs(form.abilities) do
      if abilityKeys[abilityKey] == nil then
        fail("MON_CATALOG_INVALID", "species " .. key .. " references unknown ability " .. abilityKey, context)
      end
    end
    for _, moveKey in ipairs(form.tmhm) do
      if moveKeys[moveKey] == nil then
        fail("MON_CATALOG_INVALID", "species " .. key .. " references unknown tmhm move " .. moveKey, context)
      end
    end
    for _, entry in ipairs(form.levelUpMoves) do
      if moveKeys[entry.move] == nil then
        fail("MON_CATALOG_INVALID", "species " .. key .. " references unknown learnset move " .. entry.move, context)
      end
    end
    for _, entry in ipairs(form.evolutions) do
      if speciesKeys[entry.target] == nil then
        fail("MON_CATALOG_INVALID", "species " .. key .. " evolves into unknown species " .. entry.target, context)
      end
      if entry.move ~= nil and moveKeys[entry.move] == nil then
        fail("MON_CATALOG_INVALID", "species " .. key .. " references unknown evolution move " .. entry.move, context)
      end
      if entry.species ~= nil and speciesKeys[entry.species] == nil then
        fail(
          "MON_CATALOG_INVALID",
          "species " .. key .. " references unknown evolution species " .. entry.species,
          context
        )
      end
    end
  end
end

-- The generated item collection left this catalog: item identity and
-- Bag-relevant metadata live in the generated item class now, so extending
-- them never invalidates persisted mon buckets. Species held-item
-- references still carry their semantic item key plus native identity for
-- codec compatibility, validated as references only.

-- Full catalog validation: shapes plus every species/move/ability cross
-- reference. Growth curves cover levels 1..100 exactly. Held-item references
-- resolve their shape only; item identity itself is owned by the generated
-- item class and never duplicated here.
function MonAssetSchema.assertCatalog(catalog)
  local context = {}
  checkRecord(catalog, {
    schema = true,
    version = true,
    species = true,
    moves = true,
    abilities = true,
    growthCurves = true,
  }, context, "MON_CATALOG_INVALID", "catalog")
  if catalog.schema ~= "g4-mon-catalog-v3" then
    fail("MON_CATALOG_INVALID", "catalog schema must be g4-mon-catalog-v3", context)
  end
  checkRecord(catalog.version, { id = true, language = true }, context, "MON_CATALOG_INVALID", "catalog version")
  checkNonEmptyString(catalog.version.id, context, "MON_CATALOG_INVALID", "catalog version id")
  checkNonEmptyString(catalog.version.language, context, "MON_CATALOG_INVALID", "catalog version language")
  local speciesKeys = collectKeys(catalog.species, context, "MON_CATALOG_INVALID", "species")
  local moveKeys = collectKeys(catalog.moves, context, "MON_CATALOG_INVALID", "moves")
  local abilityKeys = collectKeys(catalog.abilities, context, "MON_CATALOG_INVALID", "abilities")
  collectNativeIds(catalog.species, "nativeId", context, "MON_CATALOG_INVALID", "species")
  collectNativeIds(catalog.moves, "nativeId", context, "MON_CATALOG_INVALID", "moves")
  collectNativeIds(catalog.abilities, "nativeId", context, "MON_CATALOG_INVALID", "abilities")
  for key, species in pairs(catalog.species) do
    assertSpecies(key, species, context)
    checkSpeciesReferences(key, species, speciesKeys, moveKeys, abilityKeys, context)
  end
  for key, move in pairs(catalog.moves) do
    assertMove(key, move, context)
  end
  checkRecord(catalog.abilities, nil, context, "MON_CATALOG_INVALID", "abilities")
  for key, ability in pairs(catalog.abilities) do
    assertAbility(key, ability, context)
  end
  checkRecord(catalog.growthCurves, nil, context, "MON_CATALOG_INVALID", "growthCurves")
  for key in pairs(catalog.growthCurves) do
    if GROWTH_KEYS[key] == nil then
      fail("MON_CATALOG_INVALID", "unknown growth curve " .. tostring(key), context)
    end
  end
  for key in pairs(GROWTH_KEYS) do
    assertGrowthCurve(key, catalog.growthCurves[key], context)
  end
  return true
end

function MonAssetSchema.isValidCatalog(catalog)
  return pcall(MonAssetSchema.assertCatalog, catalog)
end

local function checkHash(value, context, code, field)
  if type(value) ~= "string" or #value ~= 40 or value:match("^[0-9a-f]+$") == nil then
    fail(code, field .. " must be a 40-character hex digest", context)
  end
end

-- Class index validation: schema identity, version, the catalog content
-- hash, cache-relative payload paths, and one marker per declared icon and
-- portrait page in ascending page order. The index binds the summary, never
-- the pixels: page images stay page-owned.
function MonAssetSchema.assertIndex(index)
  local context = {}
  checkRecord(index, {
    schema = true,
    version = true,
    catalogHash = true,
    catalog = true,
    iconManifest = true,
    portraitManifest = true,
    iconPages = true,
    portraitPages = true,
  }, context, "MON_INDEX_INVALID", "index")
  if index.schema ~= "g4-mon-index-v2" then
    fail("MON_INDEX_INVALID", "index schema must be g4-mon-index-v2", context)
  end
  checkRecord(index.version, { id = true, language = true }, context, "MON_INDEX_INVALID", "index version")
  checkNonEmptyString(index.version.id, context, "MON_INDEX_INVALID", "index version id")
  checkNonEmptyString(index.version.language, context, "MON_INDEX_INVALID", "index version language")
  checkHash(index.catalogHash, context, "MON_INDEX_INVALID", "catalogHash")
  checkNonEmptyString(index.catalog, context, "MON_INDEX_INVALID", "catalog path")
  checkNonEmptyString(index.iconManifest, context, "MON_INDEX_INVALID", "iconManifest path")
  checkNonEmptyString(index.portraitManifest, context, "MON_INDEX_INVALID", "portraitManifest path")
  for _, field in ipairs({ "iconPages", "portraitPages" }) do
    local markers = index[field]
    if not Validate.isArray(markers) or #markers == 0 then
      fail("MON_INDEX_INVALID", field .. " must carry one marker per page", context)
    end
    for position, marker in ipairs(markers) do
      if type(marker) ~= "string" or marker == "" then
        fail("MON_INDEX_INVALID", field .. " marker " .. position .. " must be a non-empty string", context)
      end
    end
  end
  return true
end

function MonAssetSchema.isValidIndex(index)
  return pcall(MonAssetSchema.assertIndex, index)
end

local function checkManifestRect(rect, context, code, field)
  checkRecord(rect, nil, context, code, field)
  for _, axis in ipairs({ "x", "y", "width", "height" }) do
    checkInt(rect[axis], 0, nil, context, code, field .. "." .. axis)
  end
  if rect.width == 0 or rect.height == 0 then
    fail(code, field .. " must have positive dimensions", context)
  end
end

local function checkRectInPage(rect, page, context, code, field)
  checkManifestRect(rect, context, code, field)
  if rect.x + rect.width > page.width or rect.y + rect.height > page.height then
    fail(code, field .. " escapes its page bounds", context)
  end
end

-- Page inventory validation: every page carries its own id with a named
-- image and positive dimensions, and the pageIds array inventories exactly
-- those pages consecutively from zero so staged page markers stay aligned
-- with the published inventory.
---@param manifest table<string, unknown>
---@param context table<string, unknown>
local function checkManifestPages(manifest, context)
  checkRecord(manifest.pages, nil, context, "MON_MANIFEST_INVALID", "manifest pages")
  local pageCount = 0
  for pageId, page in pairs(manifest.pages) do
    checkInt(pageId, 0, nil, context, "MON_MANIFEST_INVALID", "manifest page ids")
    checkRecord(
      page,
      { pageId = true, image = true, width = true, height = true },
      context,
      "MON_MANIFEST_INVALID",
      "manifest page " .. pageId
    )
    if page.pageId ~= pageId then
      fail("MON_MANIFEST_INVALID", "manifest page " .. pageId .. " must carry its own id", context)
    end
    checkNonEmptyString(page.image, context, "MON_MANIFEST_INVALID", "manifest page " .. pageId .. " image")
    for _, axis in ipairs({ "width", "height" }) do
      checkInt(page[axis], 1, nil, context, "MON_MANIFEST_INVALID", "manifest page " .. pageId .. " " .. axis)
    end
    pageCount = pageCount + 1
  end
  if pageCount == 0 then
    fail("MON_MANIFEST_INVALID", "manifest must declare pages", context)
  end
  if not Validate.isArray(manifest.pageIds) or #manifest.pageIds ~= pageCount then
    fail("MON_MANIFEST_INVALID", "manifest pageIds must inventory every declared page", context)
  end
  for position, pageId in ipairs(manifest.pageIds) do
    if pageId ~= position - 1 then
      fail("MON_MANIFEST_INVALID", "manifest page ids must be consecutive from zero", context)
    end
    if manifest.pages[pageId] == nil then
      fail("MON_MANIFEST_INVALID", "manifest page inventory names undeclared page " .. pageId, context)
    end
  end
end

-- Entry and frame validation: every selector names a declared page, every
-- entry and frame rectangle stays inside its page bounds, and the entry
-- rectangle matches its first frame so the reported dimensions and the
-- default realized quad never disagree.
---@param manifest table<string, unknown>
---@param context table<string, unknown>
local function checkManifestEntries(manifest, context)
  checkRecord(manifest.entries, nil, context, "MON_MANIFEST_INVALID", "manifest entries")
  local entryCount = 0
  for selector, entry in pairs(manifest.entries) do
    entryCount = entryCount + 1
    if type(selector) ~= "string" or selector == "" then
      fail("MON_MANIFEST_INVALID", "manifest selectors must be non-empty strings", context)
    end
    checkRecord(
      entry,
      { x = true, y = true, width = true, height = true, frames = true, pageId = true },
      context,
      "MON_MANIFEST_INVALID",
      "manifest entry " .. selector
    )
    checkInt(entry.pageId, 0, nil, context, "MON_MANIFEST_INVALID", "manifest entry " .. selector .. " page id")
    local page = manifest.pages[entry.pageId]
    if page == nil then
      fail("MON_MANIFEST_INVALID", "manifest entry " .. selector .. " names undeclared page " .. entry.pageId, context)
    end
    assert(page ~= nil, "the manifest carries the entry page")
    checkRectInPage(entry, page, context, "MON_MANIFEST_INVALID", "manifest entry " .. selector)
    if not Validate.isArray(entry.frames) or #entry.frames == 0 then
      fail("MON_MANIFEST_INVALID", "manifest entry " .. selector .. " must carry frames", context)
    end
    for frameIndex, frame in ipairs(entry.frames) do
      checkRecord(
        frame,
        { x = true, y = true, width = true, height = true, duration = true },
        context,
        "MON_MANIFEST_INVALID",
        "manifest entry " .. selector .. " frame " .. frameIndex
      )
      if frame.duration ~= nil then
        checkInt(
          frame.duration,
          1,
          nil,
          context,
          "MON_MANIFEST_INVALID",
          "manifest entry " .. selector .. " frame duration"
        )
      end
      checkRectInPage(
        frame,
        page,
        context,
        "MON_MANIFEST_INVALID",
        "manifest entry " .. selector .. " frame " .. frameIndex
      )
    end
    local first = entry.frames[1]
    if entry.x ~= first.x or entry.y ~= first.y or entry.width ~= first.width or entry.height ~= first.height then
      fail("MON_MANIFEST_INVALID", "manifest entry " .. selector .. " must match its first frame", context)
    end
  end
  if entryCount == 0 then
    fail("MON_MANIFEST_INVALID", "manifest must carry entries", context)
  end
end

-- Representative validation: every representative selector resolves to a
-- validated entry.
---@param manifest table<string, unknown>
---@param context table<string, unknown>
local function checkManifestRepresentatives(manifest, context)
  if not Validate.isArray(manifest.representative) or #manifest.representative == 0 then
    fail("MON_MANIFEST_INVALID", "manifest must carry representative selectors", context)
  end
  for _, selector in ipairs(manifest.representative) do
    if manifest.entries[selector] == nil then
      fail("MON_MANIFEST_INVALID", "representative selector has no entry: " .. tostring(selector), context)
    end
  end
end

-- Presentation manifest validation: the manifest names every page with
-- its image and dimensions, every entry carries its page id with
-- page-local rectangles and animation frames, and every representative
-- selector resolves. No source archive, member, or palette identity may
-- appear here: pages are source-independent.
function MonAssetSchema.assertManifest(manifest, expectedSchema)
  local context = {}
  checkRecord(manifest, {
    schema = true,
    version = true,
    pages = true,
    pageIds = true,
    entries = true,
    representative = true,
  }, context, "MON_MANIFEST_INVALID", "manifest")
  if manifest.schema ~= expectedSchema then
    fail("MON_MANIFEST_INVALID", "manifest schema must be " .. expectedSchema, context)
  end
  checkRecord(manifest.version, { id = true, language = true }, context, "MON_MANIFEST_INVALID", "manifest version")
  checkNonEmptyString(manifest.version.id, context, "MON_MANIFEST_INVALID", "manifest version id")
  checkNonEmptyString(manifest.version.language, context, "MON_MANIFEST_INVALID", "manifest version language")
  checkManifestPages(manifest, context)
  checkManifestEntries(manifest, context)
  checkManifestRepresentatives(manifest, context)
  return true
end

function MonAssetSchema.assertIconManifest(manifest)
  return MonAssetSchema.assertManifest(manifest, "g4-mon-icon-manifest-v2")
end

function MonAssetSchema.assertPortraitManifest(manifest)
  return MonAssetSchema.assertManifest(manifest, "g4-mon-portrait-manifest-v2")
end

function MonAssetSchema.isValidIconManifest(manifest)
  return pcall(MonAssetSchema.assertIconManifest, manifest)
end

function MonAssetSchema.isValidPortraitManifest(manifest)
  return pcall(MonAssetSchema.assertPortraitManifest, manifest)
end

return MonAssetSchema
