-- Authoritative Pokedex knowledge: the single durable owner of observed
-- Pokedex history, independent of present party or box possession. It keeps
-- seen/caught bits, first-gender arrival order, ordered logical form
-- variants (including the separate caught Unown order), caught-language
-- acquisition in canonical order, the first Spinda personality, four
-- capability flags, and minimal resume state over explicit generated
-- membership sets, so unrelated custom species can never substitute for a
-- missing required member. describe projects one detached specimen record
-- from an admitted mon for acquisition and battle producers; changes stage
-- as one-use revision-based candidates and publish exactly once through
-- the same prepared-candidate convention as the party and bag owners.

local Errors = require("libs.errors.src.Errors")
local Personality = require("libs.mons.src.gen4.Personality")

---@class PokedexKnowledge
---@field private _allowed table<string, boolean>
---@field private _monCatalog table<string, unknown>
---@field private _pokedexCatalog table<string, unknown>
---@field private _nativeLanguage string
---@field private _seen table<string, boolean>
---@field private _caught table<string, boolean>
---@field private _history table<string, table<string, unknown>>
---@field private _flags table<string, boolean>
---@field private _resume table<string, unknown>
---@field private _revision integer
local PokedexKnowledge = {}
PokedexKnowledge.__index = PokedexKnowledge

local FLAG_FIELDS = { "dexEnabled", "nationalDex", "enabledInternational", "canDetectForms" }
local MODES = { johto = true, national = true }
local LANGUAGE_ORDER_INDEX = { japanese = 1, english = 2, french = 3, german = 4, italian = 5, spanish = 6 }
local GENDER_VALUES = { male = true, female = true, genderless = true }
local DESCRIPTOR_FIELDS = {
  species = true,
  form = true,
  gender = true,
  personality = true,
  language = true,
  isEgg = true,
  shiny = true,
}

---@param message string
---@param context table<string, unknown>
local function fail(message, context)
  Errors.raise("POKEDEX_INVALID", message, context)
end

---@param value unknown
---@return boolean
local function isU32(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 4294967295
end

---@param species unknown
---@return table<string, boolean>
local function checkSpeciesSet(species)
  if type(species) ~= "table" then
    fail("dex knowledge requires a resolved species set", {})
  end
  assert(type(species) == "table", "dex knowledge reads its species set")
  local allowed = {}
  for key, known in pairs(species) do
    if type(key) ~= "string" or key == "" or known ~= true then
      fail("dex knowledge species must map keys to true", { species = key })
    end
    allowed[key] = true
  end
  if next(allowed) == nil then
    fail("dex knowledge requires a non-empty species set", {})
  end
  return allowed
end

---@param allowed table<string, boolean>
---@param species unknown
---@return string
local function checkKey(allowed, species)
  if type(species) ~= "string" or allowed[species] ~= true then
    fail("dex knowledge names an unknown species", { species = species })
  end
  return species
end

---@param allowed table<string, boolean>
---@param keys unknown
---@param what string
---@return string[]
local function checkKeys(allowed, keys, what)
  if type(keys) ~= "table" then
    fail("dex knowledge " .. what .. " must be an array", {})
  end
  assert(type(keys) == "table", "dex knowledge reads its staged arrays")
  local checked = {}
  local seen = {}
  for _, key in ipairs(keys) do
    local species = checkKey(allowed, key)
    if seen[species] == true then
      fail("dex knowledge " .. what .. " names a duplicate species", { species = species })
    end
    seen[species] = true
    checked[#checked + 1] = species
  end
  return checked
end

---@param value unknown
---@param what string
local function checkDenseList(value, what)
  if type(value) ~= "table" then
    fail("dex knowledge " .. what .. " must be an array", {})
  end
  assert(type(value) == "table", "dex knowledge reads its staged arrays")
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
      fail("dex knowledge " .. what .. " must be a dense array", {})
    end
    count = count + 1
  end
  for index = 1, count do
    if value[index] == nil then
      fail("dex knowledge " .. what .. " must be a dense array", {})
    end
  end
end

---@param args unknown
---@return table<string, unknown> validated construction refs
local function checkConstructionRefs(args)
  if type(args) ~= "table" then
    fail("dex knowledge requires a construction record", {})
  end
  assert(type(args) == "table", "dex knowledge reads its construction record")
  local refs = args --[[@as table<string, unknown>]]
  local allowed = checkSpeciesSet(refs.species)
  local monCatalog = refs.monCatalog
  if
    type(monCatalog) ~= "table"
    or type(monCatalog.species) ~= "function"
    or type(monCatalog.speciesKeys) ~= "function"
  then
    fail("dex knowledge requires the resolved mon catalog", {})
  end
  assert(type(monCatalog) == "table", "dex knowledge borrows the mon catalog")
  local pokedexCatalog = refs.pokedexCatalog
  if type(pokedexCatalog) ~= "table" or type(pokedexCatalog.species) ~= "table" then
    fail("dex knowledge requires the generated dex catalog", {})
  end
  assert(type(pokedexCatalog) == "table", "dex knowledge borrows the generated catalog")
  if type(refs.nativeLanguage) ~= "string" or refs.nativeLanguage == "" then
    fail("dex knowledge requires the native language key", {})
  end
  local catalog = pokedexCatalog --[[@as table<string, unknown>]]
  local speciesRecords = catalog.species --[[@as table<string, unknown>]]
  local catalogKeys = monCatalog:speciesKeys()
  local catalogSet = {}
  for _, key in ipairs(catalogKeys) do
    catalogSet[key] = true
  end
  for key in pairs(allowed) do
    if catalogSet[key] ~= true then
      fail("dex knowledge species is missing from the resolved catalog", { species = key })
    end
    local record = speciesRecords[key]
    local policy = type(record) == "table" and record.formPolicy or nil
    if
      type(policy) ~= "table"
      or (policy.kind ~= "ordinary" and policy.kind ~= "ordered" and policy.kind ~= "automatic")
      or type(policy.variants) ~= "table"
    then
      fail("dex knowledge species has no generated form policy", { species = key })
    end
  end
  for _, key in ipairs(catalogKeys) do
    if allowed[key] ~= true then
      fail("dex knowledge species set drops a resolved catalog species", { species = key })
    end
  end
  for _, field in ipairs({ "dexOrders", "completionSets" }) do
    local sets = catalog[field]
    if type(sets) ~= "table" then
      fail("dex knowledge catalog is missing its " .. field, {})
    end
    for _, mode in ipairs({ "johto", "national" }) do
      local list = sets[mode]
      if type(list) ~= "table" then
        fail("dex knowledge catalog is missing its " .. field .. " " .. mode .. " set", {})
      end
      checkDenseList(list, field .. " " .. mode)
      for _, key in ipairs(list) do
        if type(key) ~= "string" or allowed[key] ~= true then
          fail("dex knowledge " .. field .. " names an unknown species", { species = key })
        end
      end
    end
  end
  return {
    species = allowed,
    monCatalog = monCatalog,
    pokedexCatalog = pokedexCatalog,
    nativeLanguage = refs.nativeLanguage,
  }
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

---@param monCatalog table<string, unknown> resolved mon catalog
---@param speciesKey string
---@return integer gender ratio
local function genderRatioOf(monCatalog, speciesKey)
  local speciesOf = monCatalog.species --[[@as fun(self: table<string, unknown>, key: string): table<string, unknown>]]
  local ok, definition = pcall(speciesOf, monCatalog, speciesKey)
  if not ok or type(definition) ~= "table" then
    fail("dex knowledge names a species outside the resolved catalog", { species = speciesKey })
  end
  assert(type(definition) == "table", "dex knowledge reads the resolved species")
  local ratio = definition.genderRatio
  if type(ratio) ~= "number" or ratio % 1 ~= 0 or ratio < 0 or ratio > 255 then
    fail("dex knowledge names a species without a gender ratio", { species = speciesKey })
  end
  return ratio --[[@as integer]]
end

---@param pokedexCatalog table<string, unknown> generated dex catalog
---@param speciesKey string
---@return table<string, unknown> generated form policy
local function policyOf(pokedexCatalog, speciesKey)
  local records = pokedexCatalog.species --[[@as table<string, unknown>]]
  local record = records[speciesKey]
  return record.formPolicy --[[@as table<string, unknown>]]
end

---@param policy table<string, unknown>
---@param form integer
---@param gender string
---@return integer? matching logical variant id, or nil for untracked policies
local function resolveVariantId(policy, form, gender)
  if policy.kind ~= "ordered" then
    return nil
  end
  local variants = policy.variants --[[@as table[] ]]
  for _, variant in ipairs(variants) do
    local entry = variant --[[@as table<string, unknown>]]
    if entry.form == form and (entry.gender == nil or entry.gender == gender) then
      return entry.id --[[@as integer]]
    end
  end
  return nil
end

---@param allowed table<string, boolean> resolved species allow-set
---@param monCatalog table<string, unknown> resolved mon catalog
---@param pokedexCatalog table<string, unknown> generated dex catalog
---@param specimen unknown
---@return table<string, unknown> detached validated descriptor copy
local function checkDescriptor(allowed, monCatalog, pokedexCatalog, specimen)
  if type(specimen) ~= "table" then
    fail("dex observations carry specimen descriptors", {})
  end
  assert(type(specimen) == "table", "dex knowledge reads its staged descriptors")
  for key in pairs(specimen) do
    if DESCRIPTOR_FIELDS[key] ~= true then
      fail("dex descriptor contains an unknown field", { field = key })
    end
  end
  local record = specimen --[[@as table<string, unknown>]]
  local speciesKey = record.species
  if type(speciesKey) ~= "string" or allowed[speciesKey] ~= true then
    fail("dex descriptor names an unknown species", { species = speciesKey })
  end
  if type(record.form) ~= "number" or record.form % 1 ~= 0 or record.form < 0 then
    fail("dex descriptor names an unknown form", { species = speciesKey, form = record.form })
  end
  local form = record.form --[[@as integer]]
  local formOf = monCatalog.form --[[@as fun(self: table<string, unknown>, key: string, form: integer): table<string, unknown>]]
  if not pcall(formOf, monCatalog, speciesKey, form) then
    fail("dex descriptor names an unknown form", { species = speciesKey, form = form })
  end
  if GENDER_VALUES[record.gender] ~= true then
    fail("dex descriptor names an unknown gender", { species = speciesKey, gender = record.gender })
  end
  if reachableGenders(genderRatioOf(monCatalog, speciesKey))[record.gender] ~= true then
    fail("dex descriptor names an impossible gender", { species = speciesKey, gender = record.gender })
  end
  if not isU32(record.personality) then
    fail("dex descriptor personality must be an unsigned 32-bit integer", { species = speciesKey })
  end
  local personality = record.personality --[[@as integer]]
  if type(record.language) ~= "string" or record.language == "" then
    fail("dex descriptor language must be a non-empty language key", { species = speciesKey })
  end
  if type(record.isEgg) ~= "boolean" then
    fail("dex descriptor egg flag must be a boolean", { species = speciesKey })
  end
  if type(record.shiny) ~= "boolean" then
    fail("dex descriptor shiny flag must be a boolean", { species = speciesKey })
  end
  local policy = policyOf(pokedexCatalog, speciesKey)
  local variantId = resolveVariantId(policy, form, record.gender)
  if policy.kind == "ordered" and variantId == nil then
    fail("dex descriptor matches no generated variant", { species = speciesKey })
  end
  return {
    species = speciesKey,
    form = form,
    gender = record.gender,
    personality = personality,
    language = record.language,
    isEgg = record.isEgg,
    shiny = record.shiny,
    variantId = variantId,
  }
end

---@param set table<string, boolean>
---@return table<string, boolean> detached copy
local function copySet(set)
  local copy = {}
  for key in pairs(set) do
    copy[key] = true
  end
  return copy
end

---@param history table<string, table<string, unknown>>
---@return table<string, table<string, unknown>> detached copy
local function copyHistory(history)
  local copy = {}
  for key, row in pairs(history) do
    local entry = row --[[@as table<string, unknown>]]
    local fresh = {}
    for _, field in ipairs({ "genders", "variants", "caughtVariants", "languages" }) do
      local list = entry[field]
      if type(list) == "table" then
        local kept = {}
        for _, item in ipairs(list) do
          kept[#kept + 1] = item
        end
        fresh[field] = kept
      end
    end
    if entry.firstPersonality ~= nil then
      fresh.firstPersonality = entry.firstPersonality
    end
    copy[key] = fresh
  end
  return copy
end

---@param resume table<string, unknown>
---@return table<string, unknown> detached copy
local function copyResume(resume)
  local copy = {}
  if resume.mode ~= nil then
    copy.mode = resume.mode
  end
  if resume.species ~= nil then
    copy.species = resume.species
  end
  return copy
end

---@param left table<string, unknown>
---@param right table<string, unknown>
---@return boolean
local function resumeEqual(left, right)
  return left.mode == right.mode and left.species == right.species
end

---@param list unknown[]
---@param value unknown
---@return boolean
local function contains(list, value)
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

-- Builds fresh knowledge over the resolved species set with every
-- capability locked and no history. The catalog roots stay borrowed and
-- immutable; the owner never copies them wholesale.
---@param args { species: table<string, boolean>, monCatalog: table<string, unknown>, pokedexCatalog: table<string, unknown>, nativeLanguage: string }
---@return PokedexKnowledge
function PokedexKnowledge.new(args)
  local refs = checkConstructionRefs(args)
  return setmetatable({
    _allowed = refs.species,
    _monCatalog = refs.monCatalog,
    _pokedexCatalog = refs.pokedexCatalog,
    _nativeLanguage = refs.nativeLanguage,
    _seen = {},
    _caught = {},
    _history = {},
    _flags = { dexEnabled = false, nationalDex = false, enabledInternational = false, canDetectForms = false },
    _resume = {},
    _revision = 0,
  }, PokedexKnowledge)
end

-- Rebuilds knowledge from a validated or migrated persisted bucket over
-- the same resolved references. Unknown saved references fail; nothing is
-- inferred from the current party, and a missing legacy bucket starts
-- empty with its story and profile seeds.
---@param bucket table<string, unknown>?
---@param refs { species: table<string, boolean>, monCatalog: table<string, unknown>, pokedexCatalog: table<string, unknown>, nativeLanguage: string, legacyFlags?: table<string, boolean> }
---@return PokedexKnowledge
function PokedexKnowledge.restore(bucket, refs)
  if type(refs) ~= "table" then
    fail("dex restore requires a reference record", {})
  end
  local PokedexSave = require("libs.hgss.src.save.PokedexSave")
  local valid = PokedexSave.migrate(bucket, refs)
  local knowledge = PokedexKnowledge.new({
    species = refs.species,
    monCatalog = refs.monCatalog,
    pokedexCatalog = refs.pokedexCatalog,
    nativeLanguage = refs.nativeLanguage,
  })
  for _, key in ipairs(valid.seen) do
    knowledge._seen[key] = true
  end
  for _, key in ipairs(valid.caught) do
    knowledge._caught[key] = true
  end
  knowledge._flags = {
    dexEnabled = valid.flags.dexEnabled == true,
    nationalDex = valid.flags.nationalDex == true,
    enabledInternational = valid.flags.enabledInternational == true,
    canDetectForms = valid.flags.canDetectForms == true,
  }
  knowledge._history = copyHistory(valid.history)
  knowledge._resume = copyResume(valid.resume)
  return knowledge
end

-- Projects one detached specimen record from an admitted mon: semantic
-- species, resolved form, derived gender, raw personality, origin
-- language, egg state, and derived shininess. Reads primitives only; the
-- mon is never mutated, copied wholesale, or revalidated.
---@param mon table<string, unknown>
---@return { species: string, form: integer, gender: string, personality: integer, language: string, isEgg: boolean, shiny: boolean }
function PokedexKnowledge:describe(mon)
  if type(mon) ~= "table" then
    fail("dex description requires an admitted mon", {})
  end
  local record = mon --[[@as table<string, unknown>]]
  local speciesKey = record.species
  if type(speciesKey) ~= "string" or self._allowed[speciesKey] ~= true then
    fail("dex description names an unknown species", { species = speciesKey })
  end
  if type(record.form) ~= "number" or record.form % 1 ~= 0 or record.form < 0 then
    fail("dex description names an unknown form", { species = speciesKey, form = record.form })
  end
  local catalog = self._monCatalog --[[@as table<string, unknown>]]
  local formOf = catalog.form --[[@as fun(self: table<string, unknown>, key: string, form: integer): table<string, unknown>]]
  if not pcall(formOf, catalog, speciesKey, record.form) then
    fail("dex description names an unknown form", { species = speciesKey, form = record.form })
  end
  if not isU32(record.personality) then
    fail("dex description personality must be an unsigned 32-bit integer", { species = speciesKey })
  end
  local personality = record.personality --[[@as integer]]
  local form = record.form --[[@as integer]]
  if type(record.isEgg) ~= "boolean" then
    fail("dex description egg flag must be a boolean", { species = speciesKey })
  end
  local origin = record.origin
  if type(origin) ~= "table" then
    fail("dex description requires the mon origin record", { species = speciesKey })
  end
  local provenance = origin --[[@as table<string, unknown>]]
  if not isU32(provenance.trainerId) then
    fail("dex description trainer identity must be an unsigned 32-bit integer", { species = speciesKey })
  end
  local trainerId = provenance.trainerId --[[@as integer]]
  if type(provenance.language) ~= "string" or provenance.language == "" then
    fail("dex description language must be a non-empty language key", { species = speciesKey })
  end
  return {
    species = speciesKey,
    form = form,
    gender = Personality.gender(genderRatioOf(self._monCatalog, speciesKey), personality),
    personality = personality,
    language = provenance.language,
    isEgg = record.isEgg,
    shiny = Personality.shiny(trainerId, personality),
  }
end

---@param key string
---@return boolean
function PokedexKnowledge:isSeen(key)
  checkKey(self._allowed, key)
  return self._seen[key] == true
end

---@param key string
---@return boolean
function PokedexKnowledge:isCaught(key)
  checkKey(self._allowed, key)
  return self._caught[key] == true
end

---@return boolean
function PokedexKnowledge:hasPokedex()
  return self._flags.dexEnabled == true
end

---@return boolean
function PokedexKnowledge:hasNationalDex()
  return self._flags.nationalDex == true
end

---@return boolean
function PokedexKnowledge:hasInternationalDex()
  return self._flags.enabledInternational == true
end

---@return boolean
function PokedexKnowledge:canDetectForms()
  return self._flags.canDetectForms == true
end

---@param mode string
---@return integer
function PokedexKnowledge:countSeen(mode)
  if MODES[mode] ~= true then
    fail("dex counts read exactly johto or national mode", { mode = mode })
  end
  local catalog = self._pokedexCatalog --[[@as table<string, unknown>]]
  local orders = catalog.dexOrders --[[@as table<string, string[]>]]
  local count = 0
  for _, key in ipairs(orders[mode]) do
    if self._seen[key] == true then
      count = count + 1
    end
  end
  return count
end

---@param mode string
---@return integer
function PokedexKnowledge:countCaught(mode)
  if MODES[mode] ~= true then
    fail("dex counts read exactly johto or national mode", { mode = mode })
  end
  local catalog = self._pokedexCatalog --[[@as table<string, unknown>]]
  local orders = catalog.dexOrders --[[@as table<string, string[]>]]
  local count = 0
  for _, key in ipairs(orders[mode]) do
    if self._caught[key] == true then
      count = count + 1
    end
  end
  return count
end

---@return boolean
function PokedexKnowledge:isJohtoDexComplete()
  local catalog = self._pokedexCatalog --[[@as table<string, unknown>]]
  local sets = catalog.completionSets --[[@as table<string, string[]>]]
  for _, key in ipairs(sets.johto) do
    if self._caught[key] ~= true then
      return false
    end
  end
  return true
end

---@return boolean
function PokedexKnowledge:isNationalDexComplete()
  local catalog = self._pokedexCatalog --[[@as table<string, unknown>]]
  local sets = catalog.completionSets --[[@as table<string, string[]>]]
  for _, key in ipairs(sets.national) do
    if self._caught[key] ~= true then
      return false
    end
  end
  return true
end

---@param key string
---@return string[] detached ordered genders, empty when provenance is unknown
function PokedexKnowledge:observedGenders(key)
  checkKey(self._allowed, key)
  local row = self._history[key]
  if row == nil then
    return {}
  end
  local genders = {}
  for _, gender in ipairs(row.genders or {}) do
    genders[#genders + 1] = gender
  end
  return genders
end

---@param key string
---@return integer[] detached ordered logical variant ids
function PokedexKnowledge:observedVariants(key)
  checkKey(self._allowed, key)
  local row = self._history[key]
  if row == nil then
    return {}
  end
  local variants = {}
  for _, id in ipairs(row.variants or {}) do
    variants[#variants + 1] = id
  end
  return variants
end

---@param key string
---@return integer[] detached ordered caught logical variant ids
function PokedexKnowledge:caughtVariants(key)
  checkKey(self._allowed, key)
  local row = self._history[key]
  if row == nil then
    return {}
  end
  local variants = {}
  for _, id in ipairs(row.caughtVariants or {}) do
    variants[#variants + 1] = id
  end
  return variants
end

---@param key string
---@return string[] detached caught languages in canonical order
function PokedexKnowledge:caughtLanguages(key)
  checkKey(self._allowed, key)
  local row = self._history[key]
  if row == nil then
    return {}
  end
  local languages = {}
  for _, language in ipairs(row.languages or {}) do
    languages[#languages + 1] = language
  end
  return languages
end

---@param key string
---@return integer? stored first Spinda personality, or nil when unknown
function PokedexKnowledge:firstPersonality(key)
  checkKey(self._allowed, key)
  local row = self._history[key]
  if row == nil then
    return nil
  end
  return row.firstPersonality
end

---@return table<string, unknown> detached resume record; a missing mode stays unset
function PokedexKnowledge:resume()
  return copyResume(self._resume)
end

---@return integer
function PokedexKnowledge:revision()
  return self._revision
end

-- Stages an ordered observation batch plus legacy bits, flag changes, and
-- a whole resume replacement without touching live knowledge. Caught
-- observations also record the sighting and can enrich already-caught
-- history with a new gender, variant, or language; eggs are rejected at
-- the semantic boundary. Validation completes before any field of the
-- live owner mutates; a later invalid observation cannot partially add an
-- earlier valid one. The one-use candidate publishes exactly once and only
-- while current, advancing the revision exactly when the batch changed
-- anything; a repeated or stale publication fails before touching state.
---@class DexPreparation
---@field changed boolean
---@field isCurrent fun(): boolean
---@field publish fun()
---@param changes { observations: { kind: string, specimen: table<string, unknown> }[]?, seen: string[]?, caught: string[]?, flags: table<string, boolean>?, resume: table<string, unknown>? }
---@return DexPreparation
function PokedexKnowledge:prepareChanges(changes)
  if type(changes) ~= "table" then
    fail("dex changes must be a record", {})
  end
  for key in pairs(changes) do
    if key ~= "observations" and key ~= "seen" and key ~= "caught" and key ~= "flags" and key ~= "resume" then
      fail("dex changes contain an unknown field", { field = key })
    end
  end
  local request = changes --[[@as table<string, unknown>]]
  local allowed = self._allowed
  local monCatalog = self._monCatalog
  local pokedexCatalog = self._pokedexCatalog
  local seen = {}
  if request.seen ~= nil then
    seen = checkKeys(allowed, request.seen, "seen")
  end
  local caught = {}
  if request.caught ~= nil then
    caught = checkKeys(allowed, request.caught, "caught")
  end
  local observations = {}
  if request.observations ~= nil then
    checkDenseList(request.observations, "observations")
    for index, entry in ipairs(request.observations) do
      if type(entry) ~= "table" then
        fail("dex observations carry kind and specimen records", {})
      end
      local staged = entry --[[@as table<string, unknown>]]
      for key in pairs(staged) do
        if key ~= "kind" and key ~= "specimen" then
          fail("dex observations carry kind and specimen records", { field = key })
        end
      end
      if staged.kind ~= "seen" and staged.kind ~= "caught" then
        fail("dex observation names an unknown kind", { kind = staged.kind })
      end
      local descriptor = checkDescriptor(allowed, monCatalog, pokedexCatalog, staged.specimen)
      if descriptor.isEgg == true then
        fail("dex observations never record eggs", { species = descriptor.species })
      end
      observations[index] = { kind = staged.kind, specimen = descriptor }
    end
  end
  local flagSets = {}
  if request.flags ~= nil then
    if type(request.flags) ~= "table" then
      fail("dex flag changes must be a record", {})
    end
    local staged = request.flags --[[@as table<string, unknown>]]
    for key, value in pairs(staged) do
      local known = false
      for _, field in ipairs(FLAG_FIELDS) do
        if key == field then
          known = true
        end
      end
      if not known then
        fail("dex flag changes contain an unknown field", { field = key })
      end
      if type(value) ~= "boolean" then
        fail("dex flag changes set explicit boolean values", { field = key })
      end
      flagSets[key] = value
    end
  end
  local resumeSet = false
  local resumeValue = {}
  if request.resume ~= nil then
    if type(request.resume) ~= "table" then
      fail("dex resume changes must be a record", {})
    end
    local staged = request.resume --[[@as table<string, unknown>]]
    for key in pairs(staged) do
      if key ~= "mode" and key ~= "species" then
        fail("dex resume changes contain an unknown field", { field = key })
      end
    end
    if staged.mode ~= nil and MODES[staged.mode] ~= true then
      fail("dex resume changes name an unknown mode", { mode = staged.mode })
    end
    if staged.species ~= nil then
      checkKey(allowed, staged.species)
    end
    resumeSet = true
    if staged.mode ~= nil then
      resumeValue.mode = staged.mode
    end
    if staged.species ~= nil then
      resumeValue.species = staged.species
    end
  end
  local scratchSeen = copySet(self._seen)
  local scratchCaught = copySet(self._caught)
  local scratchHistory = copyHistory(self._history)
  local scratchFlags = {
    dexEnabled = self._flags.dexEnabled,
    nationalDex = self._flags.nationalDex,
    enabledInternational = self._flags.enabledInternational,
    canDetectForms = self._flags.canDetectForms,
  }
  local scratchResume = copyResume(self._resume)
  local nativeLanguage = self._nativeLanguage
  local changed = false
  local function markSeen(key)
    if scratchSeen[key] ~= true then
      scratchSeen[key] = true
      changed = true
    end
  end
  local function markCaught(key)
    if scratchCaught[key] ~= true then
      scratchCaught[key] = true
      changed = true
    end
  end
  local function applyObservation(kind, descriptor)
    local speciesKey = descriptor.species --[[@as string]]
    markSeen(speciesKey)
    if kind == "caught" then
      markCaught(speciesKey)
    end
    local row = scratchHistory[speciesKey]
    if row == nil then
      row = { genders = {}, variants = {}, caughtVariants = {}, languages = {} }
      scratchHistory[speciesKey] = row
    end
    local genders = row.genders --[[@as unknown[] ]]
    if not contains(genders, descriptor.gender) then
      genders[#genders + 1] = descriptor.gender
      changed = true
    end
    local policy = policyOf(pokedexCatalog, speciesKey)
    local variantId = descriptor.variantId
    if variantId ~= nil then
      local variants = row.variants --[[@as unknown[] ]]
      if not contains(variants, variantId) then
        variants[#variants + 1] = variantId
        changed = true
      end
      if kind == "caught" and policy.rememberCaughtVariants == true then
        local remembered = row.caughtVariants --[[@as unknown[] ]]
        if not contains(remembered, variantId) then
          remembered[#remembered + 1] = variantId
          changed = true
        end
      end
    end
    if policy.rememberFirstPersonality == true and row.firstPersonality == nil then
      row.firstPersonality = descriptor.personality
      changed = true
    end
    if kind == "caught" then
      if LANGUAGE_ORDER_INDEX[descriptor.language] ~= nil then
        local languages = row.languages --[[@as unknown[] ]]
        if not contains(languages, descriptor.language) then
          languages[#languages + 1] = descriptor.language
          table.sort(languages, function(left, right)
            return LANGUAGE_ORDER_INDEX[left] < LANGUAGE_ORDER_INDEX[right]
          end)
          changed = true
        end
      end
      if descriptor.language ~= nativeLanguage and scratchFlags.enabledInternational ~= true then
        scratchFlags.enabledInternational = true
        changed = true
      end
    end
  end
  for _, key in ipairs(seen) do
    markSeen(key)
  end
  for _, key in ipairs(caught) do
    markSeen(key)
    markCaught(key)
  end
  for _, observation in ipairs(observations) do
    applyObservation(observation.kind, observation.specimen)
  end
  for key, value in pairs(flagSets) do
    if scratchFlags[key] ~= value then
      scratchFlags[key] = value
      changed = true
    end
  end
  if resumeSet and not resumeEqual(scratchResume, resumeValue) then
    scratchResume = resumeValue
    changed = true
  end
  local capturedRevision = self._revision
  local consumed = false
  local function isCurrent()
    return (not consumed) and self._revision == capturedRevision
  end
  local function publish()
    if consumed then
      fail("dex preparation already published", {})
    end
    if self._revision ~= capturedRevision then
      fail("dex preparation is stale", {})
    end
    consumed = true
    self._seen = scratchSeen
    self._caught = scratchCaught
    self._history = scratchHistory
    self._flags = scratchFlags
    self._resume = scratchResume
    if changed then
      self._revision = self._revision + 1
    end
  end
  return { changed = changed, isCurrent = isCurrent, publish = publish }
end

-- Stages one caught registration: the species counts as both seen and
-- caught once published. Bits-only compatibility entry point; new specimen
-- producers stage ordered observations instead so no history is invented.
---@param species string
---@return DexPreparation
function PokedexKnowledge:capture(species)
  return self:prepareChanges({ caught = { checkKey(self._allowed, species) } })
end

-- Reads the persistable bucket: sorted seen/caught arrays, capability
-- flags, bounded per-species histories without invented provenance, and
-- minimal resume state. The result is detached; callers cannot mutate live
-- owner state through it.
---@return table<string, unknown> detached canonical v2 bucket
function PokedexKnowledge:bucket()
  local PokedexSave = require("libs.hgss.src.save.PokedexSave")
  local seen = {}
  for key in pairs(self._seen) do
    seen[#seen + 1] = key
  end
  table.sort(seen)
  local caught = {}
  for key in pairs(self._caught) do
    caught[#caught + 1] = key
  end
  table.sort(caught)
  local history = {}
  for key, row in pairs(self._history) do
    local entry = row --[[@as table<string, unknown>]]
    local canonical = {}
    local nonempty = false
    for _, field in ipairs({ "genders", "variants", "caughtVariants", "languages" }) do
      local list = entry[field]
      if type(list) == "table" and #list > 0 then
        local kept = {}
        for _, item in ipairs(list) do
          kept[#kept + 1] = item
        end
        canonical[field] = kept
        nonempty = true
      end
    end
    if entry.firstPersonality ~= nil then
      canonical.firstPersonality = entry.firstPersonality
      nonempty = true
    end
    if nonempty then
      history[key] = canonical
    end
  end
  return {
    schema = PokedexSave.SCHEMA,
    stateVersion = PokedexSave.STATE_VERSION,
    seen = seen,
    caught = caught,
    flags = {
      dexEnabled = self._flags.dexEnabled == true,
      nationalDex = self._flags.nationalDex == true,
      enabledInternational = self._flags.enabledInternational == true,
      canDetectForms = self._flags.canDetectForms == true,
    },
    history = history,
    resume = copyResume(self._resume),
  }
end

return PokedexKnowledge
