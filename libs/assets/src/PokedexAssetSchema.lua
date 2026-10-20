-- Strict closed semantic schemas for the HGSS Pokedex family: the compact
-- data catalog (orders, policies, measurements, areas, text bindings) and
-- the presentation manifest (page roles, cells, animations, windows,
-- sprites, pictures, footprints, area maps, Spinda personalization, text
-- projection). Producer and writer boundaries use validate; warm runtime
-- reads trust the published receipt plus the cache loader identity.

local Contract = require("libs.assets.src.DerivedAssetContract")
local Errors = require("libs.errors.src.Errors")

local PokedexAssetSchema = {
  CATALOG_SCHEMA = Contract.pokedex.catalogSchema,
  SCHEMA = Contract.pokedex.schema,
}

PokedexAssetSchema.ERROR = {
  SCHEMA_MISMATCH = "POKEDEX_SCHEMA_MISMATCH",
  SHAPE_INVALID = "POKEDEX_SHAPE_INVALID",
  DUPLICATE_KEY = "POKEDEX_DUPLICATE_KEY",
  DANGLING_REFERENCE = "POKEDEX_DANGLING_REFERENCE",
}

local CATALOG_FIELDS = {
  schema = true,
  versionId = true,
  nativeLanguage = true,
  species = true,
  dexOrders = true,
  completionSets = true,
  sortOrders = true,
  measurementProfiles = true,
  criteria = true,
  sliderSteps = true,
  areaGeometry = true,
  areaOrder = true,
  habitats = true,
  allAreaSets = true,
  evaluation = true,
  pictures = true,
  textBindings = true,
  searchText = true,
  entryText = true,
  formNames = true,
}

local MANIFEST_FIELDS = {
  schema = true,
  versionId = true,
  fonts = true,
  pages = true,
  chrome = true,
  cells = true,
  animations = true,
  windows = true,
  sprites = true,
  pictures = true,
  footprints = true,
  areaMaps = true,
  spinda = true,
  text = true,
}

local REQUIRED_PAGES = {
  "cover",
  "grid",
  "results",
  "search.criteria",
  "search.order",
  "search.name",
  "search.type",
  "search.height",
  "search.weight",
  "search.area",
  "search.shape",
  "entry.area",
  "entry.size",
  "entry.forms",
  "entry.compare",
  "entry.return",
  "registration",
}

local NATIVE_LANGUAGES = {
  japanese = true,
  english = true,
  french = true,
  german = true,
  italian = true,
  spanish = true,
}

local TYPE_KEYS = {
  "normal",
  "fighting",
  "flying",
  "poison",
  "ground",
  "rock",
  "bug",
  "ghost",
  "steel",
  "fire",
  "water",
  "grass",
  "electric",
  "psychic",
  "ice",
  "dragon",
  "dark",
}

local SHAPE_KEYS = {
  "quadruped",
  "bipedal without tail",
  "bipedal with tail",
  "serpentine",
  "multiple wings",
  "two wings",
  "insectoid",
  "head/torso",
  "head/arms",
  "head/legs",
  "tentacles",
  "fins",
  "head only",
  "multiple bodies",
}

local FORM_POLICY_KINDS = { ordinary = true, ordered = true, automatic = true }

local ASSET_PREFIX = "assets/generated/pokedex/"
local COMPACT_CROP = { x = 56, y = 40, width = 200, height = 136 }

local function fail(code, message, context)
  return Errors.new(code, message, context or {})
end

local function isInteger(value)
  return type(value) == "number" and value % 1 == 0
end

local function isNonNegativeInteger(value)
  return isInteger(value) and value >= 0
end

---@param value unknown
---@return boolean
local function checkRgba(value)
  if type(value) ~= "table" then
    return false
  end
  for _, key in ipairs({ "r", "g", "b" }) do
    if type(value[key]) ~= "number" or value[key] % 1 ~= 0 or value[key] < 0 or value[key] > 255 then
      return false
    end
  end
  if value.a ~= nil and (type(value.a) ~= "number" or value.a % 1 ~= 0 or value.a < 0 or value.a > 255) then
    return false
  end
  return true
end

---@param path unknown
---@param label string
---@return Errors.Error?
local function checkAssetPath(path, label)
  if type(path) ~= "string" or path:sub(1, #ASSET_PREFIX) ~= ASSET_PREFIX then
    return fail(
      PokedexAssetSchema.ERROR.SHAPE_INVALID,
      label .. " must reference a pokedex-owned asset",
      { label = label }
    )
  end
  if path:find("\\", 1, true) then
    return fail(
      PokedexAssetSchema.ERROR.SHAPE_INVALID,
      label .. " must use canonical asset path separators",
      { label = label }
    )
  end
  for component in (path:sub(#ASSET_PREFIX + 1) .. "/"):gmatch("(.-)/") do
    if component == "" or component == "." or component == ".." or component:find("\0", 1, true) then
      return fail(
        PokedexAssetSchema.ERROR.SHAPE_INVALID,
        label .. " must stay within the pokedex asset family",
        { label = label }
      )
    end
  end
  if path:sub(-4) ~= ".png" then
    return fail(
      PokedexAssetSchema.ERROR.SHAPE_INVALID,
      label .. " must reference a generated PNG image",
      { label = label }
    )
  end
  return nil
end

---@param value unknown
---@param label string
---@param resolve fun(key: string): boolean|nil
---@return Errors.Error?
local function checkKeyList(value, label, resolve)
  if type(value) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " must be a dense key list", { label = label })
  end
  local seen = {}
  for index = 1, #value do
    local key = value[index]
    if type(key) ~= "string" or key == "" then
      return fail(
        PokedexAssetSchema.ERROR.SHAPE_INVALID,
        label .. " carries a non-string entry",
        { label = label, index = index }
      )
    end
    if seen[key] then
      return fail(
        PokedexAssetSchema.ERROR.DUPLICATE_KEY,
        label .. " carries a duplicated entry " .. key,
        { label = label, key = key }
      )
    end
    seen[key] = true
    if not resolve(key) then
      return fail(
        PokedexAssetSchema.ERROR.DANGLING_REFERENCE,
        label .. " references an unknown species " .. key,
        { label = label, key = key }
      )
    end
  end
  for key in pairs(value) do
    if not isInteger(key) then
      return fail(
        PokedexAssetSchema.ERROR.SHAPE_INVALID,
        label .. " has a non-sequence key",
        { label = label, key = key }
      )
    end
  end
  return nil
end

---@param value unknown
---@param label string
---@return Errors.Error?
local function checkRect(value, label)
  if type(value) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " must be a rectangle", { label = label })
  end
  for _, key in ipairs({ "x", "y", "width", "height" }) do
    if not isInteger(value[key]) then
      return fail(
        PokedexAssetSchema.ERROR.SHAPE_INVALID,
        label .. "." .. key .. " must be an integer",
        { label = label }
      )
    end
  end
  if value.width <= 0 or value.height <= 0 then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " must have a positive size", { label = label })
  end
  return nil
end

local function deepEqual(left, right)
  if type(left) ~= type(right) then
    return false
  end
  if type(left) ~= "table" then
    return left == right
  end
  for key, value in pairs(left) do
    if not deepEqual(value, right[key]) then
      return false
    end
  end
  for key in pairs(right) do
    if left[key] == nil then
      return false
    end
  end
  return true
end

---@param policy unknown
---@param key string
---@param monCatalog table<string, unknown>?
---@return Errors.Error?
local function checkFormPolicy(policy, key, monCatalog)
  if type(policy) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "form policy for " .. key .. " must be a record", { key = key })
  end
  if not FORM_POLICY_KINDS[policy.kind] then
    return fail(
      PokedexAssetSchema.ERROR.SHAPE_INVALID,
      "form policy for " .. key .. " names an unknown kind",
      { key = key, kind = policy.kind }
    )
  end
  if type(policy.variants) ~= "table" or #policy.variants == 0 then
    return fail(
      PokedexAssetSchema.ERROR.SHAPE_INVALID,
      "form policy for " .. key .. " carries no variants",
      { key = key }
    )
  end
  local seen, ids = {}, {}
  for index, variant in ipairs(policy.variants) do
    if type(variant) ~= "table" then
      return fail(
        PokedexAssetSchema.ERROR.SHAPE_INVALID,
        "form policy variant carries no record",
        { key = key, index = index }
      )
    end
    if not isNonNegativeInteger(variant.id) then
      return fail(
        PokedexAssetSchema.ERROR.SHAPE_INVALID,
        "form policy variant id must be a nonnegative integer",
        { key = key, index = index }
      )
    end
    if not isNonNegativeInteger(variant.form) then
      return fail(
        PokedexAssetSchema.ERROR.SHAPE_INVALID,
        "form policy variant form must be a nonnegative integer",
        { key = key, index = index }
      )
    end
    if variant.gender ~= nil and variant.gender ~= "male" and variant.gender ~= "female" then
      return fail(
        PokedexAssetSchema.ERROR.SHAPE_INVALID,
        "form policy variant gender must be male or female",
        { key = key, index = index }
      )
    end
    if seen[variant.id] then
      return fail(
        PokedexAssetSchema.ERROR.DUPLICATE_KEY,
        "form policy for " .. key .. " repeats variant id " .. variant.id,
        { key = key, id = variant.id }
      )
    end
    seen[variant.id] = true
    ids[#ids + 1] = variant.id
    if monCatalog ~= nil then
      local species = monCatalog.species
      local record = type(species) == "table" and species[key] or nil
      local forms = type(record) == "table" and record.forms or nil
      if type(forms) ~= "table" or forms[variant.form] == nil then
        return fail(
          PokedexAssetSchema.ERROR.DANGLING_REFERENCE,
          "form policy for " .. key .. " references an unresolved form " .. variant.form,
          { key = key, form = variant.form }
        )
      end
    end
  end
  local defaultFound = false
  for _, id in ipairs(ids) do
    if id == policy.defaultVariant then
      defaultFound = true
    end
  end
  if not defaultFound then
    return fail(
      PokedexAssetSchema.ERROR.DANGLING_REFERENCE,
      "form policy for " .. key .. " names an unknown default variant",
      { key = key, defaultVariant = policy.defaultVariant }
    )
  end
  for field in pairs(policy) do
    if
      field ~= "kind"
      and field ~= "variants"
      and field ~= "defaultVariant"
      and field ~= "rememberCaughtVariants"
      and field ~= "rememberFirstPersonality"
    then
      return fail(
        PokedexAssetSchema.ERROR.SHAPE_INVALID,
        "form policy for " .. key .. " has an unexpected field",
        { key = key, field = field }
      )
    end
  end
  if type(policy.rememberCaughtVariants) ~= "boolean" or type(policy.rememberFirstPersonality) ~= "boolean" then
    return fail(
      PokedexAssetSchema.ERROR.SHAPE_INVALID,
      "form policy for " .. key .. " carries non-boolean history flags",
      { key = key }
    )
  end
  if policy.rememberCaughtVariants == true and key ~= "UNOWN" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "only Unown persists separate caught variants", { key = key })
  end
  if policy.rememberFirstPersonality == true and key ~= "SPINDA" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "only Spinda persists its first personality", { key = key })
  end
  return nil
end

---@param catalog table<string, unknown>
---@return Errors.Error?
local function checkCatalogPictures(catalog)
  -- Back-height corrections ride the catalog for the presentation
  -- projection; hand-built publication fixtures may omit them, in which
  -- case there is nothing to validate.
  if catalog.pictures == nil then
    return nil
  end
  if type(catalog.pictures.backYOffset) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no back-height corrections", {})
  end
  for selector, offset in pairs(catalog.pictures.backYOffset) do
    if type(selector) ~= "string" or selector:find("/back", 1, true) == nil then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "back-height correction names no back selector", {})
    end
    if not isInteger(offset) then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "back-height correction is not an integer", {})
    end
  end
  return nil
end

---@param catalog unknown
---@param monCatalog table<string, unknown>?
---@return Errors.Error?
local function checkSpecies(catalog, monCatalog)
  local species = catalog.species
  if type(species) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no species table", {})
  end
  local shapeSet = {}
  for _, name in ipairs(SHAPE_KEYS) do
    shapeSet[name] = true
  end
  for key, record in pairs(species) do
    if type(key) ~= "string" or key == "" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "species table carries an invalid key", { key = key })
    end
    if type(record) ~= "table" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "species record is not a table", { key = key })
    end
    if record.nationalNumber ~= nil then
      if not isInteger(record.nationalNumber) or record.nationalNumber < 1 then
        return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "species national number must be positive", { key = key })
      end
    end
    if record.johtoNumber ~= nil then
      if not isInteger(record.johtoNumber) or record.johtoNumber < 1 then
        return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "species johto number must be positive", { key = key })
      end
    end
    if record.shape ~= nil and not shapeSet[record.shape] then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "species shape is unknown", { key = key })
    end
    if record.nationalNumber ~= nil and record.shape == nil then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "displayed species carry a body shape", { key = key })
    end
    for field in pairs(record) do
      if field ~= "nationalNumber" and field ~= "johtoNumber" and field ~= "shape" and field ~= "formPolicy" then
        return fail(
          PokedexAssetSchema.ERROR.SHAPE_INVALID,
          "species record has an unexpected field",
          { key = key, field = field }
        )
      end
    end
    if record.formPolicy == nil then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "species carries no form policy", { key = key })
    end
    local policyErr = checkFormPolicy(record.formPolicy, key, monCatalog)
    if policyErr then
      return policyErr
    end
    if monCatalog ~= nil then
      local catalogSpecies = monCatalog.species
      if type(catalogSpecies) ~= "table" or catalogSpecies[key] == nil then
        return fail(
          PokedexAssetSchema.ERROR.DANGLING_REFERENCE,
          "catalog species resolves to no mon catalog entry",
          { key = key }
        )
      end
    end
  end
  return nil
end

---@param catalog table<string, unknown>
---@return Errors.Error?
local function checkOrders(catalog)
  local function resolve(key)
    return catalog.species[key] ~= nil
  end
  local orders = catalog.dexOrders
  if type(orders) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no dex orders", {})
  end
  for _, field in ipairs({ "johto", "national" }) do
    local err = checkKeyList(orders[field], "dexOrders." .. field, resolve)
    if err then
      return err
    end
  end
  for field in pairs(orders) do
    if field ~= "johto" and field ~= "national" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "dex orders carry an unexpected field", { field = field })
    end
  end
  local completion = catalog.completionSets
  if type(completion) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no completion sets", {})
  end
  for _, field in ipairs({ "johto", "national" }) do
    local err = checkKeyList(completion[field], "completionSets." .. field, resolve)
    if err then
      return err
    end
    local orderSet = {}
    for _, key in ipairs(orders[field]) do
      orderSet[key] = true
    end
    for _, key in ipairs(completion[field]) do
      if not orderSet[key] then
        return fail(
          PokedexAssetSchema.ERROR.DANGLING_REFERENCE,
          "completion member is outside the " .. field .. " order",
          { key = key }
        )
      end
    end
  end
  for field in pairs(completion) do
    if field ~= "johto" and field ~= "national" then
      return fail(
        PokedexAssetSchema.ERROR.SHAPE_INVALID,
        "completion sets carry an unexpected field",
        { field = field }
      )
    end
  end
  local sorts = catalog.sortOrders
  if type(sorts) ~= "table" or type(sorts.alphabetical) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no alphabetical sort order", {})
  end
  local err = checkKeyList(sorts.alphabetical, "sortOrders.alphabetical", resolve)
  if err then
    return err
  end
  for field in pairs(sorts) do
    if field ~= "alphabetical" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "sort orders carry an unexpected field", { field = field })
    end
  end
  return nil
end

---@param value unknown
---@param measured table<string, boolean>
---@param label string
---@return Errors.Error?
local function checkMeasurements(value, measured, label)
  if type(value) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " carries no measurements", { label = label })
  end
  for key, entry in pairs(value) do
    if not measured[key] then
      return fail(
        PokedexAssetSchema.ERROR.DANGLING_REFERENCE,
        label .. " measures an unknown species " .. key,
        { label = label, key = key }
      )
    end
    if type(entry) ~= "table" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " entry is not a record", { key = key })
    end
    if not isNonNegativeInteger(entry.heightDm) or not isNonNegativeInteger(entry.weightHg) then
      return fail(
        PokedexAssetSchema.ERROR.SHAPE_INVALID,
        label .. " entry carries non-integer measurements",
        { key = key }
      )
    end
    for _, role in ipairs({ "male", "female" }) do
      for _, group in ipairs({ "scale", "yOffset" }) do
        local record = entry[group]
        if type(record) ~= "table" or type(record[role]) ~= "table" then
          return fail(
            PokedexAssetSchema.ERROR.SHAPE_INVALID,
            label .. " entry misses " .. group .. "." .. role,
            { key = key }
          )
        end
        local pair = record[role]
        if not isInteger(pair.trainer) or not isInteger(pair.mon) then
          return fail(
            PokedexAssetSchema.ERROR.SHAPE_INVALID,
            label .. " entry carries non-integer geometry",
            { key = key }
          )
        end
      end
    end
    for field in pairs(entry) do
      if field ~= "heightDm" and field ~= "weightHg" and field ~= "scale" and field ~= "yOffset" then
        return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " entry has an unexpected field", { key = key })
      end
    end
  end
  return nil
end

---@param catalog table<string, unknown>
---@return Errors.Error?
local function checkProfiles(catalog)
  local profiles = catalog.measurementProfiles
  if type(profiles) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no measurement profiles", {})
  end
  local measured = {}
  for key, record in pairs(catalog.species) do
    if type(record) == "table" and record.nationalNumber ~= nil then
      measured[key] = true
    end
  end
  for _, name in ipairs({ "base", "giratina_origin" }) do
    local profile = profiles[name]
    if type(profile) ~= "table" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "catalog misses the " .. name .. " profile", {})
    end
    local err = checkMeasurements(profile.measurements, measured, "measurementProfiles." .. name)
    if err then
      return err
    end
    for key in pairs(profile.measurements) do
      if not measured[key] then
        return fail(
          PokedexAssetSchema.ERROR.DANGLING_REFERENCE,
          "measurement profile covers an undisplayed species " .. key,
          { key = key }
        )
      end
    end
    if type(profile.sorts) ~= "table" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "profile carries no sorts", { profile = name })
    end
    local function resolve(key)
      return profile.measurements[key] ~= nil
    end
    for _, sort in ipairs({ "heaviest", "lightest", "tallest", "shortest" }) do
      local list = profile.sorts[sort]
      local listErr = checkKeyList(list, "measurementProfiles." .. name .. ".sorts." .. sort, resolve)
      if listErr then
        return listErr
      end
      if
        #list
        ~= (function()
          local count = 0
          for _ in pairs(profile.measurements) do
            count = count + 1
          end
          return count
        end)()
      then
        return fail(
          PokedexAssetSchema.ERROR.SHAPE_INVALID,
          "profile sort does not cover every measured species",
          { profile = name, sort = sort }
        )
      end
    end
    for field in pairs(profile.sorts) do
      if field ~= "heaviest" and field ~= "lightest" and field ~= "tallest" and field ~= "shortest" then
        return fail(
          PokedexAssetSchema.ERROR.SHAPE_INVALID,
          "profile sorts carry an unexpected field",
          { field = field }
        )
      end
    end
    for field in pairs(profile) do
      if field ~= "measurements" and field ~= "sorts" then
        return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "profile carries an unexpected field", { field = field })
      end
    end
  end
  for field in pairs(profiles) do
    if field ~= "base" and field ~= "giratina_origin" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "profiles carry an unexpected profile", { field = field })
    end
  end
  return nil
end

---@param catalog table<string, unknown>
---@return Errors.Error?
local function checkCriteria(catalog)
  local criteria = catalog.criteria
  if type(criteria) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no search criteria", {})
  end
  local function resolve(key)
    return catalog.species[key] ~= nil
  end
  if type(criteria.letters) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "criteria carry no letter lists", {})
  end
  for letter, list in pairs(criteria.letters) do
    if type(letter) ~= "string" or #letter ~= 1 or letter < "a" or letter > "z" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "letter lists carry an invalid letter", { letter = letter })
    end
    local err = checkKeyList(list, "criteria.letters." .. letter, resolve)
    if err then
      return err
    end
  end
  local typeSet = {}
  for _, name in ipairs(TYPE_KEYS) do
    typeSet[name] = true
  end
  if type(criteria.types) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "criteria carry no type lists", {})
  end
  for name, list in pairs(criteria.types) do
    if not typeSet[name] then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "type lists carry an unknown type", { type = name })
    end
    local err = checkKeyList(list, "criteria.types." .. name, resolve)
    if err then
      return err
    end
  end
  local shapeSet = {}
  for _, name in ipairs(SHAPE_KEYS) do
    shapeSet[name] = true
  end
  if type(criteria.shapes) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "criteria carry no shape lists", {})
  end
  for name, list in pairs(criteria.shapes) do
    if not shapeSet[name] then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "shape lists carry an unknown shape", { shape = name })
    end
    local err = checkKeyList(list, "criteria.shapes." .. name, resolve)
    if err then
      return err
    end
  end
  if type(criteria.areas) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "criteria carry no area sets", {})
  end
  for _, field in ipairs({ "johto", "kanto", "unknown" }) do
    local err = checkKeyList(criteria.areas[field], "criteria.areas." .. field, resolve)
    if err then
      return err
    end
  end
  for field in pairs(criteria.areas) do
    if field ~= "johto" and field ~= "kanto" and field ~= "unknown" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "area sets carry an unexpected field", { field = field })
    end
  end
  for field in pairs(criteria) do
    if field ~= "letters" and field ~= "types" and field ~= "shapes" and field ~= "areas" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "criteria carry an unexpected field", { field = field })
    end
  end
  return nil
end

---@param catalog table<string, unknown>
---@return Errors.Error?
local function checkSlider(catalog)
  if type(catalog.sliderSteps) ~= "table" or #catalog.sliderSteps ~= 153 then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no 153 slider rows", {})
  end
  for index = 1, 153 do
    local row = catalog.sliderSteps[index]
    if type(row) ~= "table" or not isNonNegativeInteger(row.heightDm) or not isNonNegativeInteger(row.weightHg) then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "slider row carries invalid thresholds", { row = index })
    end
    for field in pairs(row) do
      if field ~= "heightDm" and field ~= "weightHg" then
        return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "slider row has an unexpected field", { row = index })
      end
    end
  end
  return nil
end

---@param geometry unknown
---@param label string
---@return Errors.Error?
local function checkAreaGeometryRecord(geometry, label)
  if type(geometry) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " is not a record", { label = label })
  end
  if geometry.kind ~= "outdoor" and geometry.kind ~= "dungeon" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " names an unknown area kind", { label = label })
  end
  if geometry.region ~= "johto" and geometry.region ~= "kanto" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " names an unknown region", { label = label })
  end
  if type(geometry.mapKey) ~= "string" or geometry.mapKey == "" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " carries no map key", { label = label })
  end
  local name = geometry.name
  if type(name) ~= "table" or not isNonNegativeInteger(name.bankId) or not isNonNegativeInteger(name.messageId) then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " carries an invalid name binding", { label = label })
  end
  if geometry.kind == "outdoor" then
    -- Outdoor rects carry source padding: unused trailing records are
    -- all zeros, so zero width/height is a faithful degenerate record
    -- rather than corrupt geometry.
    local rect = geometry.rect
    if type(rect) ~= "table" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " carries no rect", { label = label })
    end
    for _, key in ipairs({ "x", "y", "width", "height" }) do
      if not isInteger(rect[key]) then
        return fail(
          PokedexAssetSchema.ERROR.SHAPE_INVALID,
          label .. ".rect." .. key .. " must be an integer",
          { label = label }
        )
      end
    end
    if rect.width < 0 or rect.height < 0 then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " rect has a negative size", { label = label })
    end
    if type(geometry.markerMask) ~= "table" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " carries no marker mask", { label = label })
    end
    if #geometry.markerMask ~= 0 and #geometry.markerMask ~= 32 then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " carries no 32-byte marker mask", { label = label })
    end
    for index, byte in ipairs(geometry.markerMask) do
      if not isInteger(byte) or byte < 0 or byte > 255 then
        return fail(
          PokedexAssetSchema.ERROR.SHAPE_INVALID,
          label .. " marker mask carries an invalid byte",
          { label = label, index = index }
        )
      end
    end
  else
    if
      type(geometry.position) ~= "table"
      or not isInteger(geometry.position.x)
      or not isInteger(geometry.position.y)
    then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " carries no dungeon position", { label = label })
    end
  end
  return nil
end

---@param areas unknown
---@param geometry table<string, unknown>
---@param label string
---@param resolveArea fun(key: string): boolean
---@return Errors.Error?
local function checkAreaSets(areas, geometry, label, resolveArea)
  if type(areas) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " is not a record", { label = label })
  end
  for _, field in ipairs({ "morning", "day", "night", "other" }) do
    local set = areas[field]
    if type(set) ~= "table" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " misses its " .. field .. " set", { label = label })
    end
    for _, namespace in ipairs({ "outdoor", "dungeon" }) do
      local list = set[namespace]
      if type(list) ~= "table" then
        return fail(
          PokedexAssetSchema.ERROR.SHAPE_INVALID,
          label .. " misses its " .. field .. "." .. namespace .. " list",
          { label = label }
        )
      end
      local seen = {}
      for index = 1, #list do
        local key = list[index]
        if type(key) ~= "string" or key == "" then
          return fail(
            PokedexAssetSchema.ERROR.SHAPE_INVALID,
            label .. " carries an invalid area key",
            { label = label }
          )
        end
        if seen[key] then
          return fail(
            PokedexAssetSchema.ERROR.DUPLICATE_KEY,
            label .. " repeats area " .. key,
            { label = label, key = key }
          )
        end
        seen[key] = true
        if not resolveArea(key) then
          return fail(
            PokedexAssetSchema.ERROR.DANGLING_REFERENCE,
            label .. " references unknown geometry " .. key,
            { label = label, key = key }
          )
        end
        local record = geometry[key]
        assert(type(record) == "table", "resolved geometry is missing")
        if record.kind ~= namespace then
          return fail(
            PokedexAssetSchema.ERROR.SHAPE_INVALID,
            label .. " mixes the " .. namespace .. " namespace with " .. key,
            { label = label, key = key }
          )
        end
      end
    end
  end
  return nil
end

---@param catalog table<string, unknown>
---@return Errors.Error?
local function checkAreas(catalog)
  if type(catalog.areaGeometry) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no area geometry", {})
  end
  local count = 0
  for key, record in pairs(catalog.areaGeometry) do
    count = count + 1
    if type(key) ~= "string" or key == "" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "area geometry carries an invalid key", { key = key })
    end
    local err = checkAreaGeometryRecord(record, "areaGeometry." .. key)
    if err then
      return err
    end
  end
  if count == 0 then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "area geometry is empty", {})
  end
  local function resolveArea(key)
    return catalog.areaGeometry[key] ~= nil
  end
  if type(catalog.areaOrder) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no area order", {})
  end
  local seen = {}
  for index = 1, #catalog.areaOrder do
    local key = catalog.areaOrder[index]
    if type(key) ~= "string" or not resolveArea(key) then
      return fail(PokedexAssetSchema.ERROR.DANGLING_REFERENCE, "area order references unknown geometry", { key = key })
    end
    if seen[key] then
      return fail(PokedexAssetSchema.ERROR.DUPLICATE_KEY, "area order repeats " .. key, { key = key })
    end
    seen[key] = true
  end
  for key in pairs(catalog.areaGeometry) do
    if not seen[key] then
      return fail(PokedexAssetSchema.ERROR.DANGLING_REFERENCE, "area geometry misses its order entry", { key = key })
    end
  end
  if type(catalog.habitats) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no habitats", {})
  end
  for key, sets in pairs(catalog.habitats) do
    if catalog.species[key] == nil then
      return fail(PokedexAssetSchema.ERROR.DANGLING_REFERENCE, "habitats cover an unknown species", { key = key })
    end
    local err = checkAreaSets(sets, catalog.areaGeometry, "habitats." .. key, resolveArea)
    if err then
      return err
    end
  end
  local allErr = checkAreaSets(catalog.allAreaSets, catalog.areaGeometry, "allAreaSets", resolveArea)
  if allErr then
    return allErr
  end
  return nil
end

---@param value unknown
---@param label string
---@return Errors.Error?
local function checkRating(value, label)
  if type(value) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " is not a rating", { label = label })
  end
  if type(value.bands) ~= "table" or #value.bands == 0 then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " carries no rating bands", { label = label })
  end
  for index, band in ipairs(value.bands) do
    if type(band) ~= "table" or not isNonNegativeInteger(band.max) or not isNonNegativeInteger(band.messageId) then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " band is invalid", { index = index })
    end
  end
  local complete = value.complete
  if
    type(complete) ~= "table"
    or not isNonNegativeInteger(complete.maleMessageId)
    or not isNonNegativeInteger(complete.femaleMessageId)
  then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " carries no completion messages", { label = label })
  end
  if not isNonNegativeInteger(value.incompleteMusicId) or not isNonNegativeInteger(value.completeMusicId) then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " carries no music selectors", { label = label })
  end
  return nil
end

local BINDING_LANGUAGES = { "native", "japanese", "english", "french", "german", "italian", "spanish" }

-- Validates the projected search text bindings: every criterion caption,
-- sort label, letter mark, type mark, area scope, button, and the
-- daypart/return anchors must name a non-negative bank-802 entry id.
-- Counts are exact so a dropped option fails instead of painting a
-- partially labeled editor.
---@param search unknown
---@return Errors.Error?
local function checkSearchText(search)
  if type(search) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no search text", {})
  end
  local groups = {
    { name = "criteria", expected = 7 },
    { name = "orders", expected = 6 },
    { name = "letters", expected = 27 },
    { name = "types", expected = 18 },
    { name = "areas", expected = 4 },
    { name = "buttons", expected = 3 },
    { name = "editorButtons", expected = 2 },
  }
  for _, group in ipairs(groups) do
    local records = search[group.name]
    if type(records) ~= "table" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "search text misses its " .. group.name, {})
    end
    local count = 0
    for key, id in pairs(records) do
      if type(key) ~= "string" or key == "" or not isNonNegativeInteger(id) then
        return fail(
          PokedexAssetSchema.ERROR.SHAPE_INVALID,
          "search text carries a malformed " .. group.name .. " entry",
          {}
        )
      end
      count = count + 1
    end
    if count ~= group.expected then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "search text carries an incomplete " .. group.name, {})
    end
  end
  for _, field in ipairs({ "timeBase", "returnCancel", "returnAction" }) do
    if not isNonNegativeInteger(search[field]) then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "search text misses its " .. field, {})
    end
  end
  for field in pairs(search) do
    if
      field ~= "criteria"
      and field ~= "orders"
      and field ~= "letters"
      and field ~= "types"
      and field ~= "areas"
      and field ~= "buttons"
      and field ~= "editorButtons"
      and field ~= "timeBase"
      and field ~= "returnCancel"
      and field ~= "returnAction"
    then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "search text carries an unexpected field", {})
    end
  end
  return nil
end

---@param entry unknown
---@return Errors.Error?
local function checkEntryText(entry)
  if type(entry) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no entry text", {})
  end
  local count = 0
  for key, id in pairs(entry) do
    if type(key) ~= "string" or key == "" or not isNonNegativeInteger(id) then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "entry text carries a malformed entry", {})
    end
    count = count + 1
  end
  if count ~= 20 then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "entry text carries an incomplete entry set", {})
  end
  for _, field in ipairs({
    "areaTitle",
    "areaCaption",
    "areaUnknown",
    "areaRegionJohto",
    "areaRegionKanto",
    "sizeTitle",
    "sizeCaptionHeight",
    "sizeMarkHeight",
    "sizeMaleHeight",
    "sizeFemaleHeight",
    "sizeCaptionWeight",
    "sizeMarkWeight",
    "sizeMaleWeight",
    "sizeFemaleWeight",
    "formsTitle",
    "formsHeader",
    "formsCaption",
    "formsCompareHeader",
    "formsCompareLeft",
    "formsCompareRight",
  }) do
    if not isNonNegativeInteger(entry[field]) then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "entry text misses its " .. field, {})
    end
  end
  return nil
end

---@param names unknown
---@return Errors.Error?
local function checkFormNames(names)
  if type(names) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no form names", {})
  end
  if type(names.fixed) ~= "table" or not isNonNegativeInteger(names.fixed.UNOWN) then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "form names miss the unown entry", {})
  end
  for _, group in ipairs({ "base", "count" }) do
    local records = names[group]
    if type(records) ~= "table" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "form names miss their " .. group, {})
    end
    for _, species in ipairs({
      "SHELLOS",
      "GASTRODON",
      "BURMY",
      "WORMADAM",
      "DEOXYS",
      "SHAYMIN",
      "GIRATINA",
      "ROTOM",
      "CASTFORM",
      "CHERRIM",
    }) do
      if not isNonNegativeInteger(records[species]) then
        return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "form names miss " .. species .. " " .. group, {})
      end
    end
  end
  if type(names.pichu) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "form names miss the pichu entries", {})
  end
  for _, field in ipairs({ 0, 1, "other" }) do
    if not isNonNegativeInteger(names.pichu[field]) then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "form names miss a pichu entry", {})
    end
  end
  for _, field in ipairs({ "male", "female", "generic" }) do
    if not isNonNegativeInteger(names[field]) then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "form names miss their " .. field, {})
    end
  end
  for field in pairs(names) do
    if
      field ~= "fixed"
      and field ~= "base"
      and field ~= "count"
      and field ~= "pichu"
      and field ~= "male"
      and field ~= "female"
      and field ~= "generic"
    then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "form names carry an unexpected field", {})
    end
  end
  return nil
end

---@param bindings unknown
---@return Errors.Error?
local function checkTextBindings(bindings)
  if type(bindings) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no text bindings", {})
  end
  if type(bindings.ui) ~= "table" or not isNonNegativeInteger(bindings.ui.bankId) then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "text bindings carry no UI bank", {})
  end
  if type(bindings.entryByLanguage) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "text bindings carry no entry banks", {})
  end
  for _, language in ipairs(BINDING_LANGUAGES) do
    local entry = bindings.entryByLanguage[language]
    if
      type(entry) ~= "table"
      or not isNonNegativeInteger(entry.nameBankId)
      or not isNonNegativeInteger(entry.categoryBankId)
      or not isNonNegativeInteger(entry.flavorBankId)
    then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "text bindings miss the " .. language .. " entry", {})
    end
  end
  for language in pairs(bindings.entryByLanguage) do
    local known = false
    for _, expected in ipairs(BINDING_LANGUAGES) do
      if language == expected then
        known = true
      end
    end
    if not known then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "text bindings carry an unknown language", {})
    end
  end
  if type(bindings.measureByProfile) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "text bindings carry no measure banks", {})
  end
  for _, profile in ipairs({ "base", "giratina_origin" }) do
    local entry = bindings.measureByProfile[profile]
    if
      type(entry) ~= "table"
      or not isNonNegativeInteger(entry.heightBankId)
      or not isNonNegativeInteger(entry.weightBankId)
    then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "text bindings miss the " .. profile .. " measures", {})
    end
  end
  local announcement = bindings.registrationAnnouncement
  if
    type(announcement) ~= "table"
    or not isNonNegativeInteger(announcement.bankId)
    or not isNonNegativeInteger(announcement.messageId)
  then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "text bindings carry no registration announcement", {})
  end
  local landmarks = bindings.landmarks
  if
    type(landmarks) ~= "table"
    or not isNonNegativeInteger(landmarks.bankId)
    or not isNonNegativeInteger(landmarks.fallbackBankId)
    or not isNonNegativeInteger(landmarks.fallbackMessageId)
  then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "text bindings carry no landmark banks", {})
  end
  for field in pairs(bindings) do
    if
      field ~= "ui"
      and field ~= "entryByLanguage"
      and field ~= "measureByProfile"
      and field ~= "landmarks"
      and field ~= "registrationAnnouncement"
    then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "text bindings carry an unexpected field", {})
    end
  end
  return nil
end

---@param catalog unknown
---@param monCatalog table<string, unknown>?
---@return table<string, unknown>?
---@return Errors.Error?
function PokedexAssetSchema.validateCatalog(catalog, monCatalog)
  if type(catalog) ~= "table" then
    return nil, fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "catalog is not a table", {})
  end
  if catalog.schema ~= PokedexAssetSchema.CATALOG_SCHEMA then
    return nil,
      fail(PokedexAssetSchema.ERROR.SCHEMA_MISMATCH, "catalog schema is not current", { schema = catalog.schema })
  end
  if catalog.versionId ~= "heartgold" and catalog.versionId ~= "soulsilver" then
    return nil, fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "catalog names an unknown version", {})
  end
  if not NATIVE_LANGUAGES[catalog.nativeLanguage] then
    return nil, fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "catalog names an unknown native language", {})
  end
  for field in pairs(catalog) do
    if not CATALOG_FIELDS[field] then
      return nil, fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "catalog has an unexpected field", { field = field })
    end
  end
  for field in pairs(CATALOG_FIELDS) do
    -- Back-height corrections are optional on hand-built fixtures; the
    -- compiler always emits them and they validate when present.
    if catalog[field] == nil and field ~= "pictures" then
      return nil, fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "catalog is missing " .. field, { field = field })
    end
  end
  -- Sequential boundary validation: results are never collected into a
  -- sparse list, which ipairs would stop traversing at the first success.
  do
    local err = checkSpecies(catalog, monCatalog)
      or checkOrders(catalog)
      or checkProfiles(catalog)
      or checkCriteria(catalog)
      or checkSlider(catalog)
      or checkAreas(catalog)
      or checkCatalogPictures(catalog)
    if err then
      return nil, err
    end
  end
  if type(catalog.evaluation) ~= "table" then
    return nil, fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no evaluation", {})
  end
  for _, field in ipairs({ "johto", "national" }) do
    local err = checkRating(catalog.evaluation[field], "evaluation." .. field)
    if err then
      return nil, err
    end
  end
  local bindingsErr = checkTextBindings(catalog.textBindings)
  if bindingsErr then
    return nil, bindingsErr
  end
  local searchErr = checkSearchText(catalog.searchText)
  if searchErr then
    return nil, searchErr
  end
  local entryErr = checkEntryText(catalog.entryText)
  if entryErr then
    return nil, entryErr
  end
  local formErr = checkFormNames(catalog.formNames)
  if formErr then
    return nil, formErr
  end
  return catalog --[[@as table<string, unknown>]]
end

---@param manifest unknown
---@return Errors.Error?
local function checkChrome(manifest)
  if type(manifest.chrome) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "manifest carries no chrome inventory", {})
  end
  for role, record in pairs(manifest.chrome) do
    if type(role) ~= "string" or role == "" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "chrome inventory carries an invalid role", {})
    end
    if type(record) ~= "table" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "chrome record is not a table", { role = role })
    end
    local pathErr = checkAssetPath(record.path, "chrome." .. role)
    if pathErr then
      return pathErr
    end
    if not isInteger(record.width) or record.width <= 0 or not isInteger(record.height) or record.height <= 0 then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "chrome record carries invalid dimensions", { role = role })
    end
    for field in pairs(record) do
      if field ~= "path" and field ~= "width" and field ~= "height" then
        return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "chrome record has an unexpected field", { role = role })
      end
    end
  end
  return nil
end

---@param manifest unknown
---@return Errors.Error?
local function checkCells(manifest)
  if type(manifest.cells) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "manifest carries no cell inventory", {})
  end
  local chrome = manifest.chrome
  for role, record in pairs(manifest.cells) do
    if type(record) ~= "table" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "cell record is not a table", { role = role })
    end
    local boundsErr = checkRect(record.bounds, "cells." .. role .. ".bounds")
    if boundsErr then
      return boundsErr
    end
    if type(record.parts) ~= "table" or #record.parts == 0 then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "cell record carries no parts", { role = role })
    end
    for index, part in ipairs(record.parts) do
      if type(part) ~= "table" then
        return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "cell part is not a record", { role = role })
      end
      local chromeRecord = chrome[part.chrome]
      if type(chromeRecord) ~= "table" then
        return fail(
          PokedexAssetSchema.ERROR.DANGLING_REFERENCE,
          "cell part references unknown chrome",
          { role = role, chrome = part.chrome }
        )
      end
      local sourceErr = checkRect(part.source, "cells." .. role .. ".parts[" .. index .. "].source")
      if sourceErr then
        return sourceErr
      end
      if
        part.source.x < 0
        or part.source.y < 0
        or part.source.x + part.source.width > chromeRecord.width
        or part.source.y + part.source.height > chromeRecord.height
      then
        return fail(
          PokedexAssetSchema.ERROR.SHAPE_INVALID,
          "cell part reads outside its chrome image",
          { role = role, index = index }
        )
      end
      if not isInteger(part.x) or not isInteger(part.y) then
        return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "cell part carries a non-integer anchor", { role = role })
      end
      if type(part.flipX) ~= "boolean" or type(part.flipY) ~= "boolean" then
        return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "cell part carries non-boolean flips", { role = role })
      end
      if not isInteger(part.priority) or part.priority < 0 or part.priority > 3 then
        return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "cell part carries an invalid BG priority", { role = role })
      end
      if type(part.paletteGroup) ~= "string" or part.paletteGroup == "" then
        return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "cell part carries no palette group", { role = role })
      end
    end
  end
  return nil
end

---@param manifest unknown
---@return Errors.Error?
local function checkAnimations(manifest)
  if type(manifest.animations) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "manifest carries no animation inventory", {})
  end
  for role, record in pairs(manifest.animations) do
    if type(record) ~= "table" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "animation record is not a table", { role = role })
    end
    if type(record.frames) ~= "table" or #record.frames == 0 then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "animation carries no frames", { role = role })
    end
    for index, frame in ipairs(record.frames) do
      if type(frame) ~= "table" then
        return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "animation frame is not a record", { role = role })
      end
      if manifest.cells[frame.cell] == nil then
        return fail(
          PokedexAssetSchema.ERROR.DANGLING_REFERENCE,
          "animation frame references an unknown cell",
          { role = role, cell = frame.cell }
        )
      end
      if not isNonNegativeInteger(frame.duration) then
        return fail(
          PokedexAssetSchema.ERROR.SHAPE_INVALID,
          "animation frame carries an invalid duration",
          { role = role, index = index }
        )
      end
      local offsetX = frame.offsetX == nil and 0 or frame.offsetX
      local offsetY = frame.offsetY == nil and 0 or frame.offsetY
      local rotation = frame.rotation == nil and 0 or frame.rotation
      local scaleX = frame.scaleX == nil and 1 or frame.scaleX
      local scaleY = frame.scaleY == nil and 1 or frame.scaleY
      if
        type(offsetX) ~= "number"
        or type(offsetY) ~= "number"
        or type(rotation) ~= "number"
        or type(scaleX) ~= "number"
        or type(scaleY) ~= "number"
      then
        return fail(
          PokedexAssetSchema.ERROR.SHAPE_INVALID,
          "animation frame carries a non-finite transform",
          { role = role, index = index }
        )
      end
      if offsetX ~= offsetX or offsetY ~= offsetY or rotation ~= rotation or scaleX ~= scaleX or scaleY ~= scaleY then
        return fail(
          PokedexAssetSchema.ERROR.SHAPE_INVALID,
          "animation frame carries a non-finite transform",
          { role = role, index = index }
        )
      end
    end
    if not isInteger(record.loopFrom) or record.loopFrom < 1 or record.loopFrom > #record.frames then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "animation carries an invalid loop index", { role = role })
    end
    if record.direction ~= "forward" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "animation carries an unsupported direction", { role = role })
    end
    if type(record.once) ~= "boolean" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "animation carries a non-boolean once flag", { role = role })
    end
    if record.once == false then
      local total = 0
      for index = record.loopFrom, #record.frames do
        total = total + record.frames[index].duration
      end
      if total <= 0 then
        return fail(
          PokedexAssetSchema.ERROR.SHAPE_INVALID,
          "animation loop can never advance past zero-duration frames",
          { role = role }
        )
      end
    end
  end
  return nil
end

---@param manifest unknown
---@return Errors.Error?
local function checkWindows(manifest)
  if type(manifest.windows) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "manifest carries no window inventory", {})
  end
  for role, record in pairs(manifest.windows) do
    if type(record) ~= "table" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "window record is not a table", { role = role })
    end
    if record.pane ~= "information" and record.pane ~= "controls" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "window names an unknown pane", { role = role })
    end
    for _, field in ipairs({ "layer", "x", "y", "width", "height" }) do
      if not isInteger(record[field]) then
        return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "window carries a non-integer " .. field, { role = role })
      end
    end
    if record.layer < 0 or record.layer > 3 then
      return fail(
        PokedexAssetSchema.ERROR.SHAPE_INVALID,
        "window layer must be a native BG layer 0..3",
        { role = role }
      )
    end
    if record.width <= 0 or record.height <= 0 then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "window carries a non-positive size", { role = role })
    end
    if record.font ~= 0 and record.font ~= 4 then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "window references an unknown font", { role = role })
    end
    for _, field in ipairs({ "foreground", "shadow", "background" }) do
      if not checkRgba(record[field]) then
        return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "window carries invalid colors", { role = role })
      end
    end
    if record.align ~= "left" and record.align ~= "center" and record.align ~= "right" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "window names an unknown alignment", { role = role })
    end
    if type(record.paletteGroup) ~= "string" or record.paletteGroup == "" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "window carries no palette group", { role = role })
    end
  end
  return nil
end

---@param manifest unknown
---@return Errors.Error?
local function checkSprites(manifest)
  if type(manifest.sprites) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "manifest carries no sprite inventory", {})
  end
  for role, record in pairs(manifest.sprites) do
    if type(record) ~= "table" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "sprite record is not a table", { role = role })
    end
    if record.pane ~= "information" and record.pane ~= "controls" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "sprite names an unknown pane", { role = role })
    end
    if manifest.animations[record.animation] == nil then
      return fail(
        PokedexAssetSchema.ERROR.DANGLING_REFERENCE,
        "sprite references an unknown animation",
        { role = role, animation = record.animation }
      )
    end
    if not isInteger(record.x) or not isInteger(record.y) then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "sprite carries a non-integer anchor", { role = role })
    end
    if not isInteger(record.priority) or record.priority < 0 or record.priority > 3 then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "sprite carries an invalid BG priority", { role = role })
    end
    if not isNonNegativeInteger(record.drawPriority) then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "sprite carries an invalid draw priority", { role = role })
    end
    if type(record.paletteGroup) ~= "string" or record.paletteGroup == "" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "sprite carries no palette group", { role = role })
    end
  end
  return nil
end

---@param manifest unknown
---@return Errors.Error?
local function checkPages(manifest)
  if type(manifest.pages) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "manifest carries no pages", {})
  end
  for _, role in ipairs(REQUIRED_PAGES) do
    local page = manifest.pages[role]
    if type(page) ~= "table" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "manifest misses the " .. role .. " page", { role = role })
    end
    if not checkRgba(page.backdrop and page.backdrop.information) then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "page misses its information backdrop", { role = role })
    end
    if not checkRgba(page.backdrop.controls) then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "page misses its controls backdrop", { role = role })
    end
    for _, pane in ipairs({ "information", "controls" }) do
      local backgrounds = page.backgrounds and page.backgrounds[pane]
      if type(backgrounds) ~= "table" then
        return fail(
          PokedexAssetSchema.ERROR.SHAPE_INVALID,
          "page misses its " .. pane .. " backgrounds",
          { role = role }
        )
      end
      for _, background in ipairs(backgrounds) do
        if type(background) ~= "table" or manifest.chrome[background.chrome] == nil then
          return fail(
            PokedexAssetSchema.ERROR.DANGLING_REFERENCE,
            "page background references unknown chrome",
            { role = role }
          )
        end
        if not isInteger(background.layer) or background.layer < 0 or background.layer > 3 then
          return fail(
            PokedexAssetSchema.ERROR.SHAPE_INVALID,
            "page background layer must be a native BG layer 0..3",
            { role = role }
          )
        end
        if not isInteger(background.x) or not isInteger(background.y) then
          return fail(
            PokedexAssetSchema.ERROR.SHAPE_INVALID,
            "page background carries invalid geometry",
            { role = role }
          )
        end
        if
          not isInteger(background.priority)
          or background.priority < 0
          or background.priority > 3
          or type(background.paletteGroup) ~= "string"
          or background.paletteGroup == ""
        then
          return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "page background carries invalid blend", { role = role })
        end
      end
    end
    for _, field in ipairs({ "cells", "sprites", "windows" }) do
      local list = page[field]
      if type(list) ~= "table" then
        return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "page misses its " .. field, { role = role })
      end
      local inventory = manifest[field]
      for _, name in ipairs(list) do
        if inventory[name] == nil then
          return fail(
            PokedexAssetSchema.ERROR.DANGLING_REFERENCE,
            "page references an unknown " .. field .. " role",
            { role = role, name = name }
          )
        end
      end
    end
  end
  return nil
end

---@param manifest unknown
---@return Errors.Error?
local function checkPictures(manifest)
  if type(manifest.pictures) ~= "table" or type(manifest.pictures.backYOffset) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "manifest carries no back-height corrections", {})
  end
  for selector, offset in pairs(manifest.pictures.backYOffset) do
    if type(selector) ~= "string" or selector:find("/back", 1, true) == nil then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "back-height correction names no back selector", {})
    end
    if not isInteger(offset) then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "back-height correction is not an integer", {})
    end
  end
  return nil
end

---@param manifest unknown
---@return Errors.Error?
local function checkFootprints(manifest)
  if type(manifest.footprints) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "manifest carries no footprints", {})
  end
  for key, record in pairs(manifest.footprints) do
    if type(record) ~= "table" or manifest.chrome[record.chrome] == nil then
      return fail(PokedexAssetSchema.ERROR.DANGLING_REFERENCE, "footprint references unknown chrome", { key = key })
    end
    local sourceErr = checkRect(record.source, "footprints." .. key .. ".source")
    if sourceErr then
      return sourceErr
    end
    if record.source.width ~= 16 or record.source.height ~= 16 then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "footprint source is not a 16x16 assembly", { key = key })
    end
  end
  return nil
end

---@param manifest unknown
---@return Errors.Error?
local function checkAreaMaps(manifest)
  if type(manifest.areaMaps) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "manifest carries no area maps", {})
  end
  for _, region in ipairs({ "johto", "kanto" }) do
    local map = manifest.areaMaps[region]
    if type(map) ~= "table" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "manifest misses its " .. region .. " map", {})
    end
    if type(map.role) ~= "string" or map.role == "" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "area map carries no visual role", {})
    end
    for _, field in ipairs({ "extent", "scrollBounds" }) do
      local err = checkRect(map[field], "areaMaps." .. region .. "." .. field)
      if err then
        return err
      end
    end
    local crop = map.crop
    if
      type(crop) ~= "table"
      or crop.x ~= COMPACT_CROP.x
      or crop.y ~= COMPACT_CROP.y
      or crop.width ~= COMPACT_CROP.width
      or crop.height ~= COMPACT_CROP.height
    then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "area map crop is not the verified compact crop", {})
    end
  end
  return nil
end

---@param rows unknown
---@param label string
---@return Errors.Error?
local function checkEligibilityRows(rows, label)
  if type(rows) ~= "table" or #rows ~= 2 then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " carries no frame pair", { label = label })
  end
  for _, frame in ipairs(rows) do
    if type(frame) ~= "table" or #frame ~= 80 then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, label .. " frame carries no 80 rows", { label = label })
    end
    for _, row in ipairs(frame) do
      if type(row) ~= "string" or #row ~= 80 or row:find("[^0123]") ~= nil then
        return fail(
          PokedexAssetSchema.ERROR.SHAPE_INVALID,
          label .. " row carries non-semantic slots",
          { label = label }
        )
      end
    end
  end
  return nil
end

---@param node unknown
---@param residue string[]
local function collectPidResidue(node, residue)
  if type(node) == "string" then
    if node:lower():find("pid", 1, true) then
      residue[#residue + 1] = node
    end
    return
  end
  if type(node) ~= "table" then
    return
  end
  for key, value in pairs(node) do
    if type(key) == "string" and key:lower():find("pid", 1, true) then
      residue[#residue + 1] = key
    end
    collectPidResidue(value, residue)
  end
end

---@param point unknown
---@return Errors.Error?
local function checkSpotPoint(point)
  if
    type(point) ~= "table"
    or not isInteger(point.x)
    or not isInteger(point.y)
    or point.x < 0
    or point.x > 79
    or point.y < 0
    or point.y > 79
  then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "spinda spot point is outside portrait space", {})
  end
  return nil
end

---@param spots unknown
---@return Errors.Error?
local function checkSpots(spots)
  if type(spots) ~= "table" or #spots ~= 4 then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "spinda carries no four spot arrays", {})
  end
  -- Each spot reads as one anchor point or a non-empty array of shape
  -- points in source portrait coordinates; both spellings resolve to
  -- the same per-spot pixel identity for the runtime placer.
  for index, entry in ipairs(spots) do
    if type(entry) ~= "table" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "spinda spot is not a record", { index = index })
    end
    if entry.x ~= nil or entry.y ~= nil then
      local pointErr = checkSpotPoint(entry)
      if pointErr then
        return pointErr
      end
    else
      if #entry == 0 then
        return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "spinda spot array is empty", { index = index })
      end
      for _, point in ipairs(entry) do
        local pointErr = checkSpotPoint(point)
        if pointErr then
          return pointErr
        end
      end
    end
  end
  return nil
end

---@param manifest unknown
---@return Errors.Error?
local function checkSpinda(manifest)
  local spinda = manifest.spinda
  if type(spinda) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "manifest carries no spinda personalization", {})
  end
  if type(spinda.eligibility) ~= "table" then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "spinda carries no eligibility rows", {})
  end
  local genders = 0
  for gender, eligibility in pairs(spinda.eligibility) do
    if gender ~= "male" and gender ~= "female" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "spinda eligibility names an unknown gender", {})
    end
    genders = genders + 1
    if type(eligibility) ~= "table" then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "spinda eligibility is not a record", {})
    end
    local err = checkEligibilityRows(eligibility.frames, "spinda.eligibility." .. gender)
    if err then
      return err
    end
  end
  if genders == 0 then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "spinda eligibility covers no gender", {})
  end
  for _, field in ipairs({ "normal", "shiny" }) do
    local colors = spinda.replacementColors and spinda.replacementColors[field]
    if type(colors) ~= "table" or #colors ~= 3 then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "spinda carries no triple replacement colors", {})
    end
    for _, color in ipairs(colors) do
      if not checkRgba(color) then
        return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "spinda replacement color is invalid", {})
      end
    end
  end
  local spotsErr = checkSpots(spinda.spots)
  if spotsErr then
    return spotsErr
  end
  if spinda.secondFrameXOffset ~= -14 then
    return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "spinda second-frame offset is not the source offset", {})
  end
  for field in pairs(spinda) do
    if
      field ~= "eligibility"
      and field ~= "replacementColors"
      and field ~= "spots"
      and field ~= "secondFrameXOffset"
    then
      return fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "spinda carries an unexpected field", {})
    end
  end
  local residue = {}
  collectPidResidue(spinda, residue)
  if #residue > 0 then
    return fail(
      PokedexAssetSchema.ERROR.SHAPE_INVALID,
      "spinda personalization carries PID-keyed residue",
      { residue = residue[1] }
    )
  end
  return nil
end

---@param manifest unknown
---@param catalog table<string, unknown>?
---@return table<string, unknown>?
---@return Errors.Error?
function PokedexAssetSchema.validateManifest(manifest, catalog)
  if type(manifest) ~= "table" then
    return nil, fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "manifest is not a table", {})
  end
  if manifest.schema ~= PokedexAssetSchema.SCHEMA then
    return nil,
      fail(PokedexAssetSchema.ERROR.SCHEMA_MISMATCH, "manifest schema is not current", { schema = manifest.schema })
  end
  for field in pairs(manifest) do
    if not MANIFEST_FIELDS[field] then
      return nil, fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "manifest has an unexpected field", { field = field })
    end
  end
  for field in pairs(MANIFEST_FIELDS) do
    if manifest[field] == nil then
      return nil, fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "manifest is missing " .. field, { field = field })
    end
  end
  if type(manifest.fonts) ~= "table" or manifest.fonts.body ~= 0 or manifest.fonts.header ~= 4 then
    return nil, fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "manifest fonts must be the shared body/header pair", {})
  end
  if catalog ~= nil then
    if manifest.versionId ~= catalog.versionId then
      return nil,
        fail(
          PokedexAssetSchema.ERROR.SCHEMA_MISMATCH,
          "manifest version does not match its catalog",
          { versionId = manifest.versionId }
        )
    end
    if not deepEqual(manifest.text, catalog.textBindings) then
      return nil,
        fail(PokedexAssetSchema.ERROR.SCHEMA_MISMATCH, "manifest text does not project the catalog bindings", {})
    end
  elseif type(manifest.versionId) ~= "string" or manifest.versionId == "" then
    return nil, fail(PokedexAssetSchema.ERROR.SHAPE_INVALID, "manifest carries no version", {})
  end
  -- Sequential boundary validation: every check runs in order and the
  -- first failure is reported. Results are never collected into a sparse
  -- list, which ipairs would stop traversing at the first success.
  do
    local err = checkChrome(manifest)
      or checkCells(manifest)
      or checkAnimations(manifest)
      or checkWindows(manifest)
      or checkSprites(manifest)
      or checkPages(manifest)
      or checkPictures(manifest)
      or checkFootprints(manifest)
      or checkAreaMaps(manifest)
      or checkSpinda(manifest)
    if err then
      return nil, err
    end
  end
  return manifest --[[@as table<string, unknown>]]
end

return PokedexAssetSchema
