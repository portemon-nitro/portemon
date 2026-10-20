-- Synthetic mon and generated catalog fixtures for the persistent dex
-- knowledge owner: a small resolved mon root covering every source
-- policy family plus outside custom keys, and a matching generated dex
-- catalog with explicit display and completion sets. No ROM, GPU, or
-- product cache is touched; the catalog mirrors the locked generated
-- shape so owner construction sees the same references production
-- composes.

local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local PokedexSources = require("romdump.src.config.PokedexSources")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonFactory = require("libs.mons.src.gen4.MonFactory")

local PokedexDexFixture = {}

PokedexDexFixture.GAMES = {}
for key, value in pairs(CatalogFixture.GAMES) do
  PokedexDexFixture.GAMES[key] = value
end

PokedexDexFixture.LANGUAGES = {
  japanese = 1,
  english = 2,
  french = 3,
  german = 4,
  italian = 5,
  spanish = 6,
  korean = 8,
}

PokedexDexFixture.CANONICAL_LANGUAGES = { "japanese", "english", "french", "german", "italian", "spanish" }

PokedexDexFixture.DISPLAY_ORDER = {
  "CHIKORITA",
  "TOTODILE",
  "CUSTOM_IN",
  "EEVEE",
  "PICHU",
  "SHEDINJA",
  "SPINDA",
  "UNOWN",
  "CASTFORM",
  "CHERRIM",
  "SHELLOS",
  "GASTRODON",
  "SHAYMIN",
  "GIRATINA",
  "BURMY",
  "WORMADAM",
  "DEOXYS",
  "ROTOM",
}

PokedexDexFixture.JOHTO_ORDER = { "CHIKORITA", "TOTODILE", "CUSTOM_IN" }
PokedexDexFixture.COMPLETION_JOHTO = { "CHIKORITA", "CUSTOM_IN" }
PokedexDexFixture.COMPLETION_NATIONAL = { "CHIKORITA", "TOTODILE", "EEVEE", "CUSTOM_IN" }
PokedexDexFixture.OUTSIDE_KEYS = { "CUSTOM_OUT_A", "CUSTOM_OUT_B" }

-- Policy-family identities use their true ROM species identities (decomp
-- species.h at the pinned pokeheartgold snapshot, mirrored by the
-- producer MonSources table): ROM-gated legs resolve entry text, cries,
-- and portraits behind these numbers, so synthetic 901+ identities would
-- fall outside every owned bank range. Coverage intent is unchanged:
-- personalities, forms, and policies below carry the test meaning, and
-- the CUSTOM_* boundary keys keep synthetic out-of-range identities.
local EXTRA_SPECIES = {
  { name = "SPINDA", nativeId = 327, genderRatio = 127, forms = 1 },
  { name = "UNOWN", nativeId = 201, genderRatio = 255, forms = 28 },
  { name = "CASTFORM", nativeId = 903, genderRatio = 127, forms = 4 },
  { name = "CHERRIM", nativeId = 904, genderRatio = 127, forms = 2 },
  { name = "SHELLOS", nativeId = 905, genderRatio = 127, forms = 2 },
  { name = "GASTRODON", nativeId = 906, genderRatio = 127, forms = 2 },
  { name = "SHAYMIN", nativeId = 907, genderRatio = 255, forms = 2 },
  { name = "GIRATINA", nativeId = 908, genderRatio = 255, forms = 2 },
  { name = "BURMY", nativeId = 909, genderRatio = 0, forms = 3 },
  { name = "WORMADAM", nativeId = 910, genderRatio = 254, forms = 3 },
  { name = "DEOXYS", nativeId = 911, genderRatio = 255, forms = 4 },
  { name = "ROTOM", nativeId = 912, genderRatio = 255, forms = 6 },
  { name = "CUSTOM_IN", nativeId = 913, genderRatio = 127, forms = 1 },
  { name = "CUSTOM_OUT_A", nativeId = 914, genderRatio = 127, forms = 1 },
  { name = "CUSTOM_OUT_B", nativeId = 915, genderRatio = 255, forms = 1 },
}

---@param value unknown
---@return unknown
local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = deepCopy(item)
  end
  return out
end

--- Extends the shared mon-domain asset root with every dex policy family.
---@return table<string, unknown> borrowed-root-shaped asset root the caller owns
function PokedexDexFixture.buildMonRoot()
  local root = CatalogFixture.buildAssetRoot()
  assert(type(root.species) == "table", "the mon root carries its species table")
  local species = root.species --[[@as table<string, table<string, unknown>>]]
  local template = assert(species.CHIKORITA, "the mon root carries its template species")
  for _, extra in ipairs(EXTRA_SPECIES) do
    local record = deepCopy(template) --[[@as table<string, unknown>]]
    record.nativeId = extra.nativeId
    record.name = extra.name
    record.genderRatio = extra.genderRatio
    local formTemplate = deepCopy(assert(template.forms[0], "the template species carries form zero"))
    local forms = {}
    for form = 0, extra.forms - 1 do
      forms[form] = deepCopy(formTemplate)
    end
    record.forms = forms
    species[extra.name] = record
  end
  return root
end

---@param root table<string, unknown>?
---@return MonCatalog
function PokedexDexFixture.makeCatalog(root)
  return MonCatalog.new(root or PokedexDexFixture.buildMonRoot(), CatalogFixture.makeItemCatalog())
end

local seedCounter = 0

--- Dex-local charmap: the shared fixture charmap plus the underscore
--- the CUSTOM_IN specimen key requires. Used only by makeMon so no
--- shared fixture or product file changes.
local DEX_CHARMAP = {}
for glyph, code in pairs(CatalogFixture.CHARMAP) do
  DEX_CHARMAP[glyph] = code
end
DEX_CHARMAP["_"] = 0x1DF

--- Builds one admitted mon with a pinned personality so gender and shiny
--- outcomes are deterministic.
---@param monCatalog table<string, unknown>
---@param fields { species: string, personality: integer, form?: integer, level?: integer, language?: string, isEgg?: boolean }
---@return table<string, unknown>
function PokedexDexFixture.makeMon(monCatalog, fields)
  assert(type(fields) == "table" and type(fields.species) == "string", "dex specimens name their species")
  assert(type(fields.personality) == "number", "dex specimens pin their personality")
  seedCounter = seedCounter + 1
  local factory = MonFactory.new({
    catalog = monCatalog,
    rng = Lcrng.new(seedCounter),
    charmap = DEX_CHARMAP,
    games = PokedexDexFixture.GAMES,
    languages = PokedexDexFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    game = "heartgold",
    language = fields.language or "english",
  })
  local record = factory:createNormal({
    species = fields.species,
    level = fields.level or 9,
    form = fields.form or 0,
    profile = CatalogFixture.profile(),
    ball = "POKE_BALL",
    location = 7,
    terrain = 4,
    date = CatalogFixture.metDate(),
    personality = fields.personality,
  })
  if fields.isEgg == true then
    record.isEgg = true
  end
  return record
end

---@param extra table<string, unknown>?
---@return table<string, unknown>
local function ordinaryPolicy(extra)
  local policy = {
    kind = "ordinary",
    variants = { { id = 0, form = 0 } },
    defaultVariant = 0,
    rememberCaughtVariants = false,
    rememberFirstPersonality = false,
  }
  if extra ~= nil then
    for key, value in pairs(extra) do
      policy[key] = value
    end
  end
  return policy
end

---@param formCount integer
---@param extra table<string, unknown>?
---@return table<string, unknown>
local function orderedPolicy(formCount, extra)
  local variants = {}
  for id = 0, formCount - 1 do
    variants[#variants + 1] = { id = id, form = id }
  end
  local policy = {
    kind = "ordered",
    variants = variants,
    defaultVariant = 0,
    rememberCaughtVariants = false,
    rememberFirstPersonality = false,
  }
  if extra ~= nil then
    for key, value in pairs(extra) do
      policy[key] = value
    end
  end
  return policy
end

---@param formCount integer
---@return table<string, unknown>
local function automaticPolicy(formCount)
  local policy = orderedPolicy(formCount)
  policy.kind = "automatic"
  return policy
end

---@param key string
---@return table<string, unknown>
local function policyFor(key)
  if key == "SPINDA" then
    return ordinaryPolicy({ rememberFirstPersonality = true })
  end
  if key == "UNOWN" then
    return orderedPolicy(28, { rememberCaughtVariants = true })
  end
  if key == "PICHU" then
    return {
      kind = "ordered",
      variants = {
        { id = 0, form = 0, gender = "male" },
        { id = 1, form = 0, gender = "female" },
        { id = 2, form = 1, gender = "female" },
      },
      defaultVariant = 0,
      rememberCaughtVariants = false,
      rememberFirstPersonality = false,
    }
  end
  if key == "CASTFORM" then
    return automaticPolicy(4)
  end
  if key == "CHERRIM" then
    return automaticPolicy(2)
  end
  if key == "SHELLOS" or key == "GASTRODON" or key == "SHAYMIN" or key == "GIRATINA" then
    return orderedPolicy(2)
  end
  if key == "BURMY" or key == "WORMADAM" then
    return orderedPolicy(3)
  end
  if key == "DEOXYS" then
    return orderedPolicy(4)
  end
  if key == "ROTOM" then
    return orderedPolicy(6)
  end
  return ordinaryPolicy()
end

---@param heightDm integer
---@param weightHg integer
---@return table<string, unknown>
local function measurementEntry(heightDm, weightHg)
  return {
    heightDm = heightDm,
    weightHg = weightHg,
    scale = { male = { trainer = 256, mon = 256 }, female = { trainer = 256, mon = 256 } },
    yOffset = { male = { trainer = 0, mon = 0 }, female = { trainer = 0, mon = 0 } },
  }
end

---@param keys string[]
---@param heights table<string, integer>
---@param weights table<string, integer>
---@return table<string, unknown>
local function measurementProfile(keys, heights, weights)
  local measurements = {}
  for _, key in ipairs(keys) do
    measurements[key] = measurementEntry(heights[key], weights[key])
  end
  local function sortedBy(projection, reverse)
    local ordered = {}
    for _, key in ipairs(keys) do
      ordered[#ordered + 1] = key
    end
    table.sort(ordered, function(left, right)
      if projection[left] == projection[right] then
        return left < right
      end
      if reverse then
        return projection[left] > projection[right]
      end
      return projection[left] < projection[right]
    end)
    return ordered
  end
  return {
    measurements = measurements,
    sorts = {
      heaviest = sortedBy(weights, true),
      lightest = sortedBy(weights, false),
      tallest = sortedBy(heights, true),
      shortest = sortedBy(heights, false),
    },
  }
end

---@return table<string, unknown> valid generated dex catalog over the fixture species
function PokedexDexFixture.buildPokedexCatalog()
  local displayed = PokedexDexFixture.DISPLAY_ORDER
  local johtoIndex = {}
  for index, key in ipairs(PokedexDexFixture.JOHTO_ORDER) do
    johtoIndex[key] = index
  end
  local species = {}
  for index, key in ipairs(displayed) do
    local record = { nationalNumber = index, shape = "quadruped", formPolicy = policyFor(key) }
    if johtoIndex[key] ~= nil then
      record.johtoNumber = johtoIndex[key]
    end
    species[key] = record
  end
  for _, key in ipairs(PokedexDexFixture.OUTSIDE_KEYS) do
    species[key] = { formPolicy = ordinaryPolicy() }
  end
  local national = {}
  for _, key in ipairs(displayed) do
    national[#national + 1] = key
  end
  local heights, weights = {}, {}
  for index, key in ipairs(displayed) do
    heights[key] = 3 + index
    weights[key] = 50 + index * 11
  end
  local originHeights, originWeights = {}, {}
  for key, value in pairs(heights) do
    originHeights[key] = value
  end
  for key, value in pairs(weights) do
    originWeights[key] = value
  end
  originHeights.GIRATINA = 69
  originWeights.GIRATINA = 6500
  local letters = {}
  for _, key in ipairs(displayed) do
    local letter = key:sub(1, 1):lower()
    letters[letter] = letters[letter] or {}
    letters[letter][#letters[letter] + 1] = key
  end
  local function areaSet()
    return { outdoor = { "custom.route-29" }, dungeon = {} }
  end
  local habitats = {}
  for key in pairs(species) do
    habitats[key] = { morning = areaSet(), day = areaSet(), night = areaSet(), other = areaSet() }
  end
  local sliderSteps = {}
  for step = 1, 152 do
    sliderSteps[step] = { heightDm = step - 1, weightHg = step - 1 }
  end
  sliderSteps[153] = { heightDm = 999, weightHg = 9999 }
  local alphabetical = {}
  for _, key in ipairs(displayed) do
    alphabetical[#alphabetical + 1] = key
  end
  table.sort(alphabetical)
  return {
    schema = "g4-pokedex-catalog-v1",
    versionId = "heartgold",
    nativeLanguage = "english",
    species = species,
    dexOrders = { johto = PokedexDexFixture.JOHTO_ORDER, national = national },
    completionSets = {
      johto = PokedexDexFixture.COMPLETION_JOHTO,
      national = PokedexDexFixture.COMPLETION_NATIONAL,
    },
    sortOrders = { alphabetical = alphabetical },
    measurementProfiles = {
      base = measurementProfile(displayed, heights, weights),
      giratina_origin = measurementProfile(displayed, originHeights, originWeights),
    },
    criteria = {
      letters = letters,
      types = { normal = national },
      shapes = { quadruped = national },
      areas = { johto = national, kanto = {}, unknown = {} },
    },
    sliderSteps = sliderSteps,
    areaGeometry = {
      ["custom.route-29"] = {
        kind = "outdoor",
        region = "johto",
        mapKey = "custom.route-29",
        name = { bankId = 802, messageId = 65 },
        rect = { x = 0, y = 0, width = 8, height = 8 },
        markerMask = {},
      },
      ["custom.dark-cave"] = {
        kind = "dungeon",
        region = "johto",
        mapKey = "custom.dark-cave",
        name = { bankId = 802, messageId = 66 },
        position = { x = 3, y = 4 },
      },
    },
    areaOrder = { "custom.route-29", "custom.dark-cave" },
    habitats = habitats,
    allAreaSets = { morning = areaSet(), day = areaSet(), night = areaSet(), other = areaSet() },
    evaluation = {
      johto = {
        bands = { { max = 1, messageId = 10 } },
        complete = { maleMessageId = 11, femaleMessageId = 12 },
        incompleteMusicId = 1,
        completeMusicId = 2,
      },
      national = {
        bands = { { max = 1, messageId = 10 } },
        complete = { maleMessageId = 11, femaleMessageId = 12 },
        incompleteMusicId = 1,
        completeMusicId = 2,
      },
    },
    textBindings = {
      ui = { bankId = 802 },
      entryByLanguage = {
        native = { nameBankId = 237, categoryBankId = 816, flavorBankId = 803 },
        japanese = { nameBankId = 822, categoryBankId = 828, flavorBankId = 810 },
        english = { nameBankId = 817, categoryBankId = 823, flavorBankId = 805 },
        french = { nameBankId = 818, categoryBankId = 824, flavorBankId = 806 },
        german = { nameBankId = 819, categoryBankId = 825, flavorBankId = 807 },
        italian = { nameBankId = 820, categoryBankId = 826, flavorBankId = 808 },
        spanish = { nameBankId = 821, categoryBankId = 827, flavorBankId = 809 },
      },
      measureByProfile = {
        base = { heightBankId = 815, weightBankId = 813 },
        giratina_origin = { heightBankId = 814, weightBankId = 812 },
      },
      registrationAnnouncement = { bankId = 197, messageId = 871 },
      landmarks = { bankId = 279, fallbackBankId = 280, fallbackMessageId = 2 },
    },
    searchText = PokedexSources.searchText(),
    entryText = PokedexSources.entryText(),
    formNames = PokedexSources.formNameMessages(),
  }
end

--- Builds the owner construction references over the fixture catalogs.
---@param monCatalog table<string, unknown>
---@param pokedexCatalog table<string, unknown>?
---@param nativeLanguage string?
---@return { species: table<string, boolean>, monCatalog: table<string, unknown>, pokedexCatalog: table<string, unknown>, nativeLanguage: string }
function PokedexDexFixture.refs(monCatalog, pokedexCatalog, nativeLanguage)
  local catalog = assert(monCatalog, "dex refs require their mon catalog")
  local species = {}
  for _, key in ipairs(catalog:speciesKeys()) do
    species[key] = true
  end
  return {
    species = species,
    monCatalog = monCatalog,
    pokedexCatalog = pokedexCatalog or PokedexDexFixture.buildPokedexCatalog(),
    nativeLanguage = nativeLanguage or "english",
  }
end

--- Builds owner construction references over exactly the named fixture
--- species: both the mon root and the generated catalog prune every other
--- key, and the display/completion sets filter to the kept keys. Lets
--- narrow owner consumers (battle commit, resolution, placement) pin a
--- small explicit allow-set without relaxing production metadata rules.
---@param keys string[] resolved species keys the owner accepts
---@return { species: table<string, boolean>, monCatalog: table<string, unknown>, pokedexCatalog: table<string, unknown>, nativeLanguage: string }
function PokedexDexFixture.refsForSpecies(keys)
  assert(type(keys) == "table" and #keys > 0, "dex subset refs name their species")
  local keep = {}
  for _, key in ipairs(keys) do
    assert(type(key) == "string" and key ~= "", "dex subset refs name species keys")
    keep[key] = true
  end
  local root = PokedexDexFixture.buildMonRoot()
  for key in pairs(root.species) do
    if keep[key] ~= true then
      root.species[key] = nil
    end
  end
  for _, key in ipairs(keys) do
    assert(root.species[key] ~= nil, "dex subset refs name a known fixture species: " .. key)
  end
  local monCatalog = PokedexDexFixture.makeCatalog(root)
  local pokedexCatalog = PokedexDexFixture.buildPokedexCatalog()
  for key in pairs(pokedexCatalog.species) do
    if keep[key] ~= true then
      pokedexCatalog.species[key] = nil
    end
  end
  local function filter(list)
    local kept = {}
    for _, key in ipairs(list) do
      if keep[key] == true then
        kept[#kept + 1] = key
      end
    end
    return kept
  end
  pokedexCatalog.dexOrders = {
    johto = filter(PokedexDexFixture.JOHTO_ORDER),
    national = filter(PokedexDexFixture.DISPLAY_ORDER),
  }
  pokedexCatalog.completionSets = {
    johto = filter(PokedexDexFixture.COMPLETION_JOHTO),
    national = filter(PokedexDexFixture.COMPLETION_NATIONAL),
  }
  return PokedexDexFixture.refs(monCatalog, pokedexCatalog)
end

--- Builds owner construction references over the fixture species plus
--- extra synthetic ordinary species, with an explicit completion override.
--- Lets completion tests pin a large required set (mythical-named keys
--- that must never substitute for required members) while every accepted
--- key still carries a generated form policy.
---@param extraKeys string[] additional species keys to register as ordinary single-form content
---@param completion { johto: string[], national: string[] }? explicit completion sets for the owner
---@return { species: table<string, boolean>, monCatalog: table<string, unknown>, pokedexCatalog: table<string, unknown>, nativeLanguage: string }
function PokedexDexFixture.refsWithExtraSpecies(extraKeys, completion)
  assert(type(extraKeys) == "table" and #extraKeys > 0, "dex refs name their extra species")
  local root = PokedexDexFixture.buildMonRoot()
  local template = assert(root.species.CHIKORITA, "the mon root carries its template species")
  for index, key in ipairs(extraKeys) do
    assert(type(key) == "string" and key ~= "", "dex refs name species keys")
    if root.species[key] == nil then
      local record = deepCopy(template)
      record.nativeId = 3000 + index
      record.name = key
      root.species[key] = record
    end
  end
  local monCatalog = PokedexDexFixture.makeCatalog(root)
  local pokedexCatalog = PokedexDexFixture.buildPokedexCatalog()
  for _, key in ipairs(extraKeys) do
    if pokedexCatalog.species[key] == nil then
      pokedexCatalog.species[key] = { formPolicy = ordinaryPolicy() }
    end
  end
  if completion ~= nil then
    assert(type(completion.johto) == "table", "completion overrides carry their johto set")
    assert(type(completion.national) == "table", "completion overrides carry their national set")
    pokedexCatalog.completionSets = { johto = completion.johto, national = completion.national }
  end
  return PokedexDexFixture.refs(monCatalog, pokedexCatalog)
end

return PokedexDexFixture
