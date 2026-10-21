-- Persisted Pokedex knowledge bucket: strict v2 shape, canonical detached
-- output, and evidence-preserving migration from legacy buckets. v2 keeps
-- sorted seen/caught bits, four capability flags, bounded per-species
-- history (first/other gender arrival, ordered logical variants, caught
-- Unown order, caught languages in canonical order, first Spinda
-- personality) and minimal resume state. Migration never invents gender,
-- variant, language, or personality facts from bare bits, and valid v2
-- buckets stay authoritative over stale legacy seeds. Pure data owner: no
-- live state, no love dependency.

local Errors = require("libs.errors.src.Errors")

---@class PokedexSave
local PokedexSave = {}

PokedexSave.SCHEMA = "hgss-pokedex-v2"
PokedexSave.STATE_VERSION = 2

local LEGACY_SCHEMA = "hgss-pokedex-v1"
local LEGACY_STATE_VERSION = 1

local MAX_U32 = 4294967295

local FLAG_FIELDS = { "dexEnabled", "nationalDex", "enabledInternational", "canDetectForms" }
local TOP_FIELDS = {
  schema = true,
  stateVersion = true,
  seen = true,
  caught = true,
  flags = true,
  history = true,
  resume = true,
}
local LEGACY_FIELDS = { schema = true, stateVersion = true, seen = true, caught = true }
local HISTORY_FIELDS =
  { genders = true, variants = true, caughtVariants = true, languages = true, firstPersonality = true }
local RESUME_MODES = { johto = true, national = true }
local GENDER_VALUES = { male = true, female = true, genderless = true }
local SUPPORTED_LANGUAGES = {
  japanese = true,
  english = true,
  french = true,
  german = true,
  italian = true,
  spanish = true,
}
local LANGUAGE_ORDER_INDEX = { japanese = 1, english = 2, french = 3, german = 4, italian = 5, spanish = 6 }

---@param message string
---@param context table<string, unknown>
local function fail(message, context)
  Errors.raise("POKEDEX_INVALID", message, context)
end

---@param refs unknown
local function checkRefs(refs)
  if type(refs) ~= "table" then
    fail("dex validation requires a reference record", {})
  end
  assert(type(refs) == "table", "reference checks read the refs record")
  if type(refs.species) ~= "table" then
    fail("dex validation requires a species reference set", {})
  end
  if type(refs.monCatalog) ~= "table" or type(refs.monCatalog.species) ~= "function" then
    fail("dex validation requires the resolved mon catalog", {})
  end
  if type(refs.pokedexCatalog) ~= "table" or type(refs.pokedexCatalog.species) ~= "table" then
    fail("dex validation requires the generated dex catalog", {})
  end
end

---@param value unknown
---@param what string
---@return integer entry count
local function checkDenseList(value, what)
  if type(value) ~= "table" then
    fail("dex bucket " .. what .. " must be an array", {})
  end
  assert(type(value) == "table", "dense checks read the array record")
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
      fail("dex bucket " .. what .. " must be a dense array", {})
    end
    count = count + 1
  end
  for index = 1, count do
    if value[index] == nil then
      fail("dex bucket " .. what .. " must be a dense array", {})
    end
  end
  return count
end

---@param value unknown
---@return boolean
local function isU32(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= MAX_U32
end

---@param value unknown
---@param refs table<string, unknown>
---@param what string
---@return string[] validated copy
local function checkSpeciesList(value, refs, what)
  checkDenseList(value, what)
  assert(type(value) == "table", "species checks read the validated array")
  local known = {}
  local checked = {}
  for _, species in ipairs(value) do
    if type(species) ~= "string" or refs.species[species] ~= true then
      fail("dex bucket " .. what .. " names an unknown species", { species = species })
    end
    if known[species] == true then
      fail("dex bucket " .. what .. " names a duplicate species", { species = species })
    end
    known[species] = true
    checked[#checked + 1] = species
  end
  return checked
end

---@param value unknown
---@return table<string, boolean> validated copy
local function checkFlags(value)
  if type(value) ~= "table" then
    fail("dex bucket flags must be a record", {})
  end
  assert(type(value) == "table", "flag checks read the flags record")
  for key in pairs(value) do
    local known = false
    for _, field in ipairs(FLAG_FIELDS) do
      if key == field then
        known = true
      end
    end
    if not known then
      fail("dex bucket flags contain an unknown field", { field = key })
    end
  end
  local flags = {}
  for _, field in ipairs(FLAG_FIELDS) do
    if type(value[field]) ~= "boolean" then
      fail("dex bucket flag " .. field .. " must be a boolean", { field = field })
    end
    flags[field] = value[field]
  end
  return flags
end

---@param value unknown
---@param refs table<string, unknown>
---@return table<string, unknown> validated detached copy
local function checkResume(value, refs)
  if type(value) ~= "table" then
    fail("dex bucket resume must be a record", {})
  end
  assert(type(value) == "table", "resume checks read the resume record")
  for key in pairs(value) do
    if key ~= "mode" and key ~= "species" then
      fail("dex bucket resume contains an unknown field", { field = key })
    end
  end
  local resume = {}
  if value.mode ~= nil then
    if RESUME_MODES[value.mode] ~= true then
      fail("dex bucket resume names an unknown mode", { mode = value.mode })
    end
    resume.mode = value.mode
  end
  if value.species ~= nil then
    if type(value.species) ~= "string" or refs.species[value.species] ~= true then
      fail("dex bucket resume names an unknown species", { species = value.species })
    end
    resume.species = value.species
  end
  return resume
end

---@param speciesKey string
---@param refs table<string, unknown>
---@return table<string, unknown> generated form policy
local function formPolicy(speciesKey, refs)
  local speciesRecords = refs.pokedexCatalog.species --[[@as table<string, unknown>]]
  local record = speciesRecords[speciesKey]
  local policy = type(record) == "table" and record.formPolicy or nil
  if
    type(policy) ~= "table"
    or (policy.kind ~= "ordinary" and policy.kind ~= "ordered" and policy.kind ~= "automatic")
    or type(policy.variants) ~= "table"
  then
    fail("dex history names a species without a generated form policy", { species = speciesKey })
  end
  assert(type(policy) == "table", "policy checks read the generated policy")
  return policy --[[@as table<string, unknown>]]
end

---@param ratio integer
---@return table<string, boolean> reachable genders
local function reachableGenders(ratio)
  if ratio == 255 then
    return { genderless = true }
  end
  if ratio == 0 then
    return { male = true }
  end
  if ratio == 254 then
    return { female = true }
  end
  return { male = true, female = true }
end

---@param value unknown
---@param reachable table<string, boolean>
---@param speciesKey string
---@return string[] validated copy
local function checkGenders(value, reachable, speciesKey)
  if value == nil then
    return {}
  end
  checkDenseList(value, "history genders")
  assert(type(value) == "table", "gender checks read the validated array")
  local known = {}
  local checked = {}
  for _, gender in ipairs(value) do
    if GENDER_VALUES[gender] ~= true then
      fail("dex history names an unknown gender", { species = speciesKey, gender = gender })
    end
    if reachable[gender] ~= true then
      fail("dex history names an impossible gender", { species = speciesKey, gender = gender })
    end
    if known[gender] == true then
      fail("dex history names a duplicate gender", { species = speciesKey, gender = gender })
    end
    known[gender] = true
    checked[#checked + 1] = gender
  end
  return checked
end

---@param value unknown
---@param policy table<string, unknown>
---@param speciesKey string
---@param what string
---@return integer[] validated copy
local function checkVariantList(value, policy, speciesKey, what)
  if value == nil then
    return {}
  end
  checkDenseList(value, "history " .. what)
  assert(type(value) == "table", "variant checks read the validated array")
  local declared = {}
  for _, variant in ipairs(policy.variants) do
    if type(variant) == "table" and type(variant.id) == "number" then
      declared[variant.id] = true
    end
  end
  local known = {}
  local checked = {}
  for _, id in ipairs(value) do
    if type(id) ~= "number" or id % 1 ~= 0 or id < 0 then
      fail("dex history " .. what .. " must hold logical variant ids", { species = speciesKey })
    end
    if declared[id] ~= true then
      fail("dex history " .. what .. " names a variant outside the generated policy", { species = speciesKey })
    end
    if known[id] == true then
      fail("dex history " .. what .. " names a duplicate variant", { species = speciesKey })
    end
    known[id] = true
    checked[#checked + 1] = id
  end
  return checked
end

---@param value unknown
---@param speciesKey string
---@return string[] validated copy in canonical language order
local function checkLanguages(value, speciesKey)
  if value == nil then
    return {}
  end
  checkDenseList(value, "history languages")
  assert(type(value) == "table", "language checks read the validated array")
  local known = {}
  local checked = {}
  for _, language in ipairs(value) do
    if SUPPORTED_LANGUAGES[language] ~= true then
      fail("dex history names an unsupported language bank", { species = speciesKey, language = language })
    end
    if known[language] == true then
      fail("dex history names a duplicate language", { species = speciesKey, language = language })
    end
    known[language] = true
    checked[#checked + 1] = language
  end
  table.sort(checked, function(left, right)
    return LANGUAGE_ORDER_INDEX[left] < LANGUAGE_ORDER_INDEX[right]
  end)
  return checked
end

---@param speciesKey string
---@param row unknown
---@param seenSet table<string, boolean>
---@param caughtSet table<string, boolean>
---@param refs table<string, unknown>
---@return table<string, unknown>? canonical row, or nil when the row is empty
local function checkHistoryRow(speciesKey, row, seenSet, caughtSet, refs)
  if type(speciesKey) ~= "string" or refs.species[speciesKey] ~= true then
    fail("dex history names an unknown species", { species = speciesKey })
  end
  if type(row) ~= "table" then
    fail("dex history row must be a record", { species = speciesKey })
  end
  assert(type(row) == "table", "history checks read the row record")
  for key in pairs(row) do
    if HISTORY_FIELDS[key] ~= true then
      fail("dex history row contains an unknown field", { species = speciesKey, field = key })
    end
  end
  local monCatalog = refs.monCatalog --[[@as table<string, unknown>]]
  local speciesOf = monCatalog.species --[[@as fun(self: table<string, unknown>, key: string): table<string, unknown>]]
  local ok, definition = pcall(speciesOf, monCatalog, speciesKey)
  if not ok or type(definition) ~= "table" then
    fail("dex history names a species outside the resolved catalog", { species = speciesKey })
  end
  assert(type(definition) == "table", "history checks read the resolved species")
  local ratio = definition.genderRatio
  if type(ratio) ~= "number" or ratio % 1 ~= 0 or ratio < 0 or ratio > 255 then
    fail("dex history names a species without a gender ratio", { species = speciesKey })
  end
  local policy = formPolicy(speciesKey, refs)
  local genders = checkGenders(row.genders, reachableGenders(ratio), speciesKey)
  local variants = checkVariantList(row.variants, policy, speciesKey, "variants")
  if #variants > 0 and policy.kind ~= "ordered" then
    fail("dex history stores variants for a policy that never remembers them", { species = speciesKey })
  end
  local caughtVariants = checkVariantList(row.caughtVariants, policy, speciesKey, "caughtVariants")
  if #caughtVariants > 0 and policy.rememberCaughtVariants ~= true then
    fail("dex history stores caught variants for a policy that never remembers them", { species = speciesKey })
  end
  local observed = {}
  for _, id in ipairs(variants) do
    observed[id] = true
  end
  for _, id in ipairs(caughtVariants) do
    if observed[id] ~= true then
      fail("dex history stores a caught variant outside the observed set", { species = speciesKey })
    end
  end
  local languages = checkLanguages(row.languages, speciesKey)
  local firstPersonality = row.firstPersonality
  if firstPersonality ~= nil then
    if not isU32(firstPersonality) then
      fail("dex history first personality must be an unsigned 32-bit integer", { species = speciesKey })
    end
    if policy.rememberFirstPersonality ~= true then
      fail("dex history stores a first personality for a policy that never remembers it", { species = speciesKey })
    end
  end
  local nonempty = #genders > 0 or #variants > 0 or #caughtVariants > 0 or #languages > 0 or firstPersonality ~= nil
  if nonempty and seenSet[speciesKey] ~= true then
    fail("dex history belongs to an unseen species", { species = speciesKey })
  end
  if (#languages > 0 or #caughtVariants > 0) and caughtSet[speciesKey] ~= true then
    fail("dex history languages and caught variants require a caught species", { species = speciesKey })
  end
  if not nonempty then
    return nil
  end
  local canonical = {}
  if #genders > 0 then
    canonical.genders = genders
  end
  if #variants > 0 then
    canonical.variants = variants
  end
  if #caughtVariants > 0 then
    canonical.caughtVariants = caughtVariants
  end
  if #languages > 0 then
    canonical.languages = languages
  end
  if firstPersonality ~= nil then
    canonical.firstPersonality = firstPersonality
  end
  return canonical
end

---@param bucket table<string, unknown> validated shape record
---@param refs table<string, unknown>
---@return table<string, unknown> detached canonical v2 bucket
local function canonicalize(bucket, refs)
  local seen = checkSpeciesList(bucket.seen, refs, "seen")
  local caught = checkSpeciesList(bucket.caught, refs, "caught")
  local flags = checkFlags(bucket.flags)
  local resume = checkResume(bucket.resume, refs)
  if type(bucket.history) ~= "table" then
    fail("dex bucket history must be a table", {})
  end
  local seenSet, caughtSet = {}, {}
  for _, key in ipairs(seen) do
    seenSet[key] = true
  end
  for _, key in ipairs(caught) do
    if seenSet[key] ~= true then
      fail("dex bucket records a caught species without its sighting", { species = key })
    end
    caughtSet[key] = true
  end
  local history = {}
  for key, row in pairs(bucket.history) do
    local canonical = checkHistoryRow(key, row, seenSet, caughtSet, refs)
    if canonical ~= nil then
      history[key] = canonical
    end
  end
  table.sort(seen)
  table.sort(caught)
  return {
    schema = PokedexSave.SCHEMA,
    stateVersion = PokedexSave.STATE_VERSION,
    seen = seen,
    caught = caught,
    flags = flags,
    history = history,
    resume = resume,
  }
end

---@param bucket table<string, unknown>
---@param refs table<string, unknown>
---@return table<string, unknown> detached canonical v2 bucket
function PokedexSave.validate(bucket, refs)
  checkRefs(refs)
  if type(bucket) ~= "table" then
    fail("dex bucket must be a table", {})
  end
  assert(type(bucket) == "table", "validation reads the bucket record")
  for key in pairs(bucket) do
    if TOP_FIELDS[key] ~= true then
      fail("dex bucket contains an unknown field", { field = key })
    end
  end
  if bucket.schema ~= PokedexSave.SCHEMA then
    fail("dex schema must be " .. PokedexSave.SCHEMA, { schema = bucket.schema })
  end
  if bucket.stateVersion ~= PokedexSave.STATE_VERSION then
    fail("dex bucket carries an incompatible state version", { stateVersion = bucket.stateVersion })
  end
  return canonicalize(bucket, refs)
end

---@param refs table<string, unknown>
---@return table<string, boolean> capability seeds for a legacy bucket
local function legacyFlagSeeds(refs)
  local seeds = refs.legacyFlags
  if seeds == nil then
    return { dexEnabled = false, nationalDex = false, enabledInternational = false, canDetectForms = false }
  end
  if type(seeds) ~= "table" then
    fail("dex migration legacy seeds must be a record", {})
  end
  return {
    dexEnabled = seeds.dexEnabled == true,
    nationalDex = seeds.nationalDex == true,
    enabledInternational = false,
    canDetectForms = false,
  }
end

---@param bucket table<string, unknown>?
---@param refs table<string, unknown>
---@return table<string, unknown> detached canonical v2 bucket
function PokedexSave.migrate(bucket, refs)
  checkRefs(refs)
  if bucket == nil then
    return canonicalize({
      schema = PokedexSave.SCHEMA,
      stateVersion = PokedexSave.STATE_VERSION,
      seen = {},
      caught = {},
      flags = legacyFlagSeeds(refs),
      history = {},
      resume = {},
    }, refs)
  end
  if type(bucket) ~= "table" then
    fail("dex bucket must be a table", {})
  end
  assert(type(bucket) == "table", "migration reads the bucket record")
  if bucket.schema == PokedexSave.SCHEMA and bucket.stateVersion == PokedexSave.STATE_VERSION then
    return canonicalize(bucket, refs)
  end
  if bucket.schema ~= LEGACY_SCHEMA or bucket.stateVersion ~= LEGACY_STATE_VERSION then
    fail("dex bucket carries an unsupported schema", { schema = bucket.schema })
  end
  assert(
    bucket.schema == LEGACY_SCHEMA and bucket.stateVersion == LEGACY_STATE_VERSION,
    "migration reads the legacy bucket record"
  )
  for key in pairs(bucket) do
    if LEGACY_FIELDS[key] ~= true then
      fail("dex bucket contains an unknown field", { field = key })
    end
  end
  local seen = checkSpeciesList(bucket.seen, refs, "seen")
  local caught = checkSpeciesList(bucket.caught, refs, "caught")
  local unionSet = {}
  for _, key in ipairs(seen) do
    unionSet[key] = true
  end
  for _, key in ipairs(caught) do
    unionSet[key] = true
  end
  local union = {}
  for key in pairs(unionSet) do
    union[#union + 1] = key
  end
  table.sort(union)
  return canonicalize({
    schema = PokedexSave.SCHEMA,
    stateVersion = PokedexSave.STATE_VERSION,
    seen = union,
    caught = caught,
    flags = legacyFlagSeeds(refs),
    history = {},
    resume = {},
  }, refs)
end

---@return table<string, unknown> the defined source initial state
function PokedexSave.initial()
  return {
    schema = PokedexSave.SCHEMA,
    stateVersion = PokedexSave.STATE_VERSION,
    seen = {},
    caught = {},
    flags = { dexEnabled = false, nationalDex = false, enabledInternational = false, canDetectForms = false },
    history = {},
    resume = {},
  }
end

return PokedexSave
