-- Lower-level producer vectors the behavior suites do not pin down:
-- native form policies for custom species, exact completion exclusions,
-- alternate portrait-height member formulas, closed-schema mutation
-- rejection, and the static message-bank closure. Uses compact synthetic
-- archives; no ROM, GPU, or product cache is touched.

local Assert = require("tests.support.Assert")
local Narc = require("libs.nds.src.nitro.Narc")
local NarcBuilder = require("tests.support.NarcBuilder")
local MonSources = require("romdump.src.config.MonSources")
local PokedexAssetSchema = require("libs.assets.src.PokedexAssetSchema")

local T = {}

local function u16(value)
  value = value % 65536
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function u32(value)
  value = value % 4294967296
  local b0 = value % 256
  local b1 = math.floor(value / 256) % 256
  local b2 = math.floor(value / 65536) % 256
  local b3 = math.floor(value / 16777216) % 256
  return string.char(b0, b1, b2, b3)
end

local function u16List(values)
  local parts = {}
  for _, value in ipairs(values) do
    parts[#parts + 1] = u16(value)
  end
  return table.concat(parts)
end

local function u32List(values)
  local parts = {}
  for _, value in ipairs(values) do
    parts[#parts + 1] = u32(value)
  end
  return table.concat(parts)
end

local function allSpeciesIds()
  local ids = {}
  for id = 1, 493 do
    ids[#ids + 1] = id
  end
  return ids
end

local function fixtureMonCatalog()
  local species = {}
  for id = 1, 493 do
    species[MonSources.speciesKeys[id]] = { forms = { [0] = {} }, genderRatio = 127 }
  end
  species.UNOWN.forms = { [0] = {}, [28] = {} }
  species.PICHU.forms = { [0] = {}, [1] = {}, [2] = {} }
  species["custom.alpha"] = { forms = { [0] = {}, [1] = {} }, genderRatio = 127 }
  species["custom.beta"] = { forms = { [0] = {} }, genderRatio = 255 }
  return { species = species, version = { id = "heartgold", language = "english" } }
end

local function measuresArchive()
  local members = {}
  local zeros494 = {}
  for _ = 1, 494 do
    zeros494[#zeros494 + 1] = 0
  end
  members[1] = u32List(zeros494)
  members[2] = u32List(zeros494)
  members[3] = string.rep("\0", 494)
  for member = 4, 11 do
    local scales = {}
    for _ = 1, 494 do
      scales[#scales + 1] = u16(0)
    end
    members[member] = table.concat(scales)
  end
  local ids = allSpeciesIds()
  members[12] = u16List(ids)
  local johto = {}
  for id = 1, 256 do
    johto[#johto + 1] = id
  end
  members[13] = u16List(johto)
  members[14] = u16List(ids)
  members[15] = u16List(ids)
  members[16] = u16List(ids)
  members[17] = u16List(ids)
  members[18] = u16List(ids)
  for member = 19, 102 do
    members[member] = ""
  end
  local ordered = {}
  for member = 1, 102 do
    ordered[member] = members[member]
  end
  return NarcBuilder.build(ordered)
end

local function sliderArchive()
  local rows = {}
  for _ = 1, 153 do
    rows[#rows + 1] = u16(0) .. u16(0)
  end
  return NarcBuilder.build({ table.concat(rows), string.rep("\0", 494) })
end

local function habitatArchive()
  local members = {}
  members[1] = string.rep("\0", 26 * 4)
  members[2] = string.rep("\0", 70 * 36)
  local bases = { 2, 497, 992, 1487, 1982, 2477, 2972, 3467 }
  for group = 0, 7 do
    for slot = 0, 494 do
      members[bases[group + 1] + slot + 1] = u32(0)
    end
  end
  local ordered = {}
  for member = 1, 3962 do
    ordered[member] = members[member]
  end
  return NarcBuilder.build(ordered)
end

local function johtoInverseArchive()
  -- Mapping-B layout: Lua index i carries species i - 1's position
  -- (entry 1 is the unused species 0 slot), so the show-everything
  -- row stays separate from the first johto position.
  local entries = {}
  for id = 1, 494 do
    entries[id] = 0
  end
  entries[1] = 0
  for position = 1, 256 do
    entries[position + 1] = position
  end
  return NarcBuilder.build({ u16List(entries) })
end

local function portraitYArchive()
  local members = {}
  for _ = 1, 1976 do
    members[#members + 1] = string.char(7)
  end
  return NarcBuilder.build(members)
end

local function portraitYAltArchive()
  local members = {}
  for _ = 1, 160 do
    members[#members + 1] = string.char(9)
  end
  return NarcBuilder.build(members)
end

local function fixtureRomFs()
  local archives = {
    ["a/0/7/4"] = measuresArchive(),
    ["a/2/1/4"] = measuresArchive(),
    ["a/0/7/5"] = sliderArchive(),
    ["a/1/3/3"] = habitatArchive(),
    ["a/1/3/8"] = johtoInverseArchive(),
    ["a/0/0/5"] = portraitYArchive(),
    ["a/1/1/7"] = portraitYAltArchive(),
  }
  return {
    readSourcePath = function(_, path)
      return archives[path]
    end,
    openNarc = function(_, alias)
      local bytes = archives[alias]
      if bytes == nil then
        error("fixture has no archive " .. tostring(alias), 0)
      end
      return assert(Narc.open(bytes, alias))
    end,
    version = function()
      return "heartgold"
    end,
    metadata = function()
      return { sha1 = "rom-sha" }
    end,
  }
end

local function requireCompiler()
  local loaded, PokedexCatalogCompiler = pcall(require, "romdump.src.digest.ui.PokedexCatalogCompiler")
  Assert.isTrue(loaded, "the pokedex catalog compiler must be published before policies can be proven")
  return assert(PokedexCatalogCompiler)
end

local function compileCatalog()
  local PokedexCatalogCompiler = requireCompiler()
  local catalog, err = PokedexCatalogCompiler.compile(fixtureRomFs(), "heartgold", fixtureMonCatalog())
  Assert.notNil(catalog, "the vector fixture must compile")
  Assert.isNil(err, "the vector fixture compiles without error")
  return catalog
end

function T.custom_species_gain_policy_without_invented_membership()
  local catalog = compileCatalog()
  local alpha = assert(catalog.species["custom.alpha"], "custom species resolve a catalog record")
  Assert.isNil(alpha.nationalNumber, "custom species acquire no invented national number")
  Assert.isNil(alpha.johtoNumber, "custom species acquire no invented johto number")
  Assert.isNil(alpha.shape, "custom species acquire no invented body shape")
  Assert.equal(alpha.formPolicy.kind, "ordinary", "custom species use the ordinary policy kind")
  Assert.deepEqual(
    alpha.formPolicy.variants,
    { { id = 0, form = 0 } },
    "custom ordinary policy keeps a single placeholder variant"
  )
  local beta = assert(catalog.species["custom.beta"], "genderless custom species resolve")
  Assert.equal(beta.formPolicy.kind, "ordinary", "genderless custom species stay ordinary")
  for _, order in ipairs({ catalog.dexOrders.johto, catalog.dexOrders.national }) do
    for _, key in ipairs(order) do
      Assert.isTrue(key ~= "custom.alpha" and key ~= "custom.beta", "custom species never join display orders")
    end
  end
  for _, set in ipairs({ catalog.completionSets.johto, catalog.completionSets.national }) do
    for _, key in ipairs(set) do
      Assert.isTrue(key ~= "custom.alpha" and key ~= "custom.beta", "custom species never join completion sets")
    end
  end
  Assert.isNil(catalog.habitats["custom.alpha"], "custom species acquire no habitat rows")
end

function T.native_ordered_families_extend_without_renumbering()
  local catalog = compileCatalog()
  local unown = assert(catalog.species.UNOWN, "unown resolves")
  Assert.equal(unown.formPolicy.kind, "ordered", "unown keeps its ordered kind")
  Assert.isTrue(unown.formPolicy.rememberCaughtVariants, "unown alone persists caught variants")
  Assert.isFalse(unown.formPolicy.rememberFirstPersonality, "unown never persists personalities")
  local ids = {}
  for _, variant in ipairs(unown.formPolicy.variants) do
    ids[#ids + 1] = variant.id
  end
  Assert.equal(ids[#ids], 28, "the extra resolved unown form appends without renumbering")
  local pichu = assert(catalog.species.PICHU, "pichu resolves")
  Assert.equal(pichu.formPolicy.kind, "ordered", "pichu keeps its ordered kind")
  local last = pichu.formPolicy.variants[#pichu.formPolicy.variants]
  Assert.deepEqual({ id = last.id, form = last.form }, { id = 3, form = 2 }, "pichu extras use id form+1")
  local spinda = assert(catalog.species.SPINDA, "spinda resolves")
  Assert.isTrue(spinda.formPolicy.rememberFirstPersonality, "spinda alone persists its first personality")
end

function T.completion_sets_exclude_exactly_the_event_mythicals()
  local catalog = compileCatalog()
  Assert.equal(#catalog.completionSets.national, 484, "national completion excludes nine mythicals")
  Assert.equal(#catalog.completionSets.johto, 254, "johto completion excludes mew and celebi")
  local excluded = { MEW = true, CELEBI = true, JIRACHI = true, DEOXYS = true, PHIONE = true, MANAPHY = true, DARKRAI = true, SHAYMIN = true, ARCEUS = true }
  local required = {}
  for _, key in ipairs(catalog.completionSets.national) do
    required[key] = true
  end
  for key in pairs(excluded) do
    Assert.isNil(required[key], key .. " is not a completion requirement")
    Assert.notNil(catalog.species[key], key .. " still resolves a catalog record")
  end
  local johtoRequired = {}
  for _, key in ipairs(catalog.completionSets.johto) do
    johtoRequired[key] = true
  end
  Assert.isNil(johtoRequired.MEW, "mew is not a johto requirement")
  Assert.isNil(johtoRequired.CELEBI, "celebi is not a johto requirement")
end

function T.alternate_height_members_follow_native_branches()
  local PokedexSources = require("romdump.src.config.PokedexSources")
  Assert.equal(PokedexSources.altHeightMember("DEOXYS", 0, 0), 0, "deoxys base takes the alternate branch")
  Assert.equal(PokedexSources.altHeightMember("UNOWN", 5, 2), 0x08 + 1 + 10, "unown forms stride by two")
  Assert.equal(PokedexSources.altHeightMember("GIRATINA", 1, 0), 0x98 + 2, "giratina origin takes its branch")
  Assert.equal(PokedexSources.altHeightMember("PICHU", 1, 2), 0x9C + 1 + 2, "pichu form one takes its branch")
  Assert.isNil(PokedexSources.altHeightMember("PICHU", 2, 0), "extra pichu forms fall back to ordinary")
  Assert.isNil(PokedexSources.altHeightMember("BULBASAUR", 0, 0), "ordinary species never take the alternate branch")
  Assert.equal(PokedexSources.ordinaryHeightMember(1, 0, false), 5, "ordinary male back member arithmetic")
  Assert.equal(PokedexSources.ordinaryHeightMember(1, 0, true), 4, "ordinary female back member arithmetic")
  Assert.equal(PokedexSources.ordinaryHeightMember(1, 2, false), 7, "ordinary male front member arithmetic")
end

function T.message_bank_closure_covers_every_named_role()
  local PokedexSources = require("romdump.src.config.PokedexSources")
  local ids = PokedexSources.messageBankIds()
  Assert.equal(#ids, 30, "the presentation closure names every fixed bank once: 28 pre-existing plus the landmarks name/fallback banks behind AREA location rows")
  local wanted = {
    [802] = true,
    [237] = true,
    [816] = true,
    [803] = true,
    [804] = true,
    [197] = true,
    [815] = true,
    [812] = true,
  }
  for bank in pairs(wanted) do
    local found = false
    for _, id in ipairs(ids) do
      if id == bank then
        found = true
      end
    end
    Assert.isTrue(found, "bank " .. bank .. " belongs to the presentation closure")
  end
end

local function mutateCatalog(mutator)
  local catalog = compileCatalog()
  mutator(catalog)
  return catalog
end

-- Editor option orders transcribed from the original search declaration
-- sequence: every source class in declaration order with the
-- unrestricted choice last, never alphabetically sorted.
local SOURCE_TYPE_SEQUENCE = {
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
  "unrestricted",
}
local SOURCE_SHAPE_SEQUENCE = {
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
  "unrestricted",
}

function T.editor_option_arrays_follow_source_declaration_order_with_unrestricted_last()
  local catalog = compileCatalog()
  Assert.deepEqual(
    catalog.criteria.typeOptionOrder,
    SOURCE_TYPE_SEQUENCE,
    "the type editor keeps the source declaration order"
  )
  Assert.deepEqual(
    catalog.criteria.shapeOptionOrder,
    SOURCE_SHAPE_SEQUENCE,
    "the shape editor keeps the source declaration order"
  )
  Assert.equal(catalog.criteria.typeOptionOrder[1], "normal", "the type editor does not sort alphabetically")
  Assert.equal(
    catalog.criteria.shapeOptionOrder[1],
    "quadruped",
    "the shape editor does not sort alphabetically"
  )
  for index = 1, 17 do
    Assert.notNil(
      catalog.criteria.types[SOURCE_TYPE_SEQUENCE[index]],
      "every ordered type stays a search member: " .. SOURCE_TYPE_SEQUENCE[index]
    )
  end
  for index = 1, 14 do
    Assert.notNil(
      catalog.criteria.shapes[SOURCE_SHAPE_SEQUENCE[index]],
      "every ordered shape stays a search member: " .. SOURCE_SHAPE_SEQUENCE[index]
    )
  end
end

function T.malformed_editor_option_arrays_fail_closed_validation()
  local monCatalog = fixtureMonCatalog()
  local catalog = compileCatalog()
  Assert.notNil(
    catalog.criteria.typeOptionOrder,
    "the compiled catalog carries source-ordered type options"
  )
  Assert.notNil(
    catalog.criteria.shapeOptionOrder,
    "the compiled catalog carries source-ordered shape options"
  )
  local fresh = compileCatalog()
  fresh.criteria.typeOptionOrder[1], fresh.criteria.typeOptionOrder[2] =
    fresh.criteria.typeOptionOrder[2], fresh.criteria.typeOptionOrder[1]
  Assert.isNil(
    PokedexAssetSchema.validateCatalog(fresh, monCatalog),
    "a swapped type option order must not validate"
  )
  local duplicated = compileCatalog()
  duplicated.criteria.typeOptionOrder[18] = duplicated.criteria.typeOptionOrder[1]
  Assert.isNil(
    PokedexAssetSchema.validateCatalog(duplicated, monCatalog),
    "a duplicated type option must not validate"
  )
  local truncated = compileCatalog()
  truncated.criteria.shapeOptionOrder[15] = nil
  Assert.isNil(
    PokedexAssetSchema.validateCatalog(truncated, monCatalog),
    "a truncated shape option order must not validate"
  )
  local unknown = compileCatalog()
  unknown.criteria.shapeOptionOrder[15] = "mystery"
  Assert.isNil(
    PokedexAssetSchema.validateCatalog(unknown, monCatalog),
    "an unknown shape option must not validate"
  )
end

function T.closed_catalog_rejects_unknown_fields_and_holes()
  local monCatalog = fixtureMonCatalog()
  local withExtra = mutateCatalog(function(catalog)
    catalog.extraField = true
  end)
  Assert.isNil(
    PokedexAssetSchema.validateCatalog(withExtra, monCatalog),
    "an unknown catalog field must not validate"
  )
  local withHole = mutateCatalog(function(catalog)
    catalog.dexOrders.national[5] = nil
  end)
  Assert.isNil(PokedexAssetSchema.validateCatalog(withHole, monCatalog), "a sparse dex order must not validate")
  local withDup = mutateCatalog(function(catalog)
    catalog.completionSets.national[#catalog.completionSets.national + 1] = catalog.completionSets.national[1]
  end)
  Assert.isNil(
    PokedexAssetSchema.validateCatalog(withDup, monCatalog),
    "a duplicated completion member must not validate"
  )
  local withBadForm = mutateCatalog(function(catalog)
    catalog.species.BULBASAUR.formPolicy.variants[1].form = 9
  end)
  Assert.isNil(
    PokedexAssetSchema.validateCatalog(withBadForm, monCatalog),
    "an unresolved variant form must not validate"
  )
  local withBadBank = mutateCatalog(function(catalog)
    catalog.textBindings.ui.bankId = nil
  end)
  Assert.isNil(
    PokedexAssetSchema.validateCatalog(withBadBank, monCatalog),
    "a missing UI bank must not validate"
  )
end

return { tests = T }
