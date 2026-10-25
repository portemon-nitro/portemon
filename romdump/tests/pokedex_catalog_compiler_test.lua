-- The Pokedex catalog compiler projects bounded synthetic source bytes
-- into the semantic catalog: source order survives without host
-- re-sorting, outdoor and dungeon namespaces stay distinct even when
-- their numeric indices match, the base and origin measurement archives
-- map to their numeric profiles, all slider rows survive, the
-- show-everything row stays separate from species rows, and malformed
-- source fails with attributed errors instead of plausible records.

local Assert = require("tests.support.Assert")
local Narc = require("libs.nds.src.nitro.Narc")
local NarcBuilder = require("tests.support.NarcBuilder")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local MonSources = require("romdump.src.config.MonSources")
local MonCache = require("libs.assets.src.MonCache")
local PokedexSources = require("romdump.src.config.PokedexSources")

local T = {}

local MEASURES_A = "a/0/7/4"
local MEASURES_B = "a/2/1/4"
local SLIDER_PATH = "a/0/7/5"
local HABITAT_PATH = "a/1/3/3"
local JOHTO_INVERSE_PATH = "a/1/3/8"
local PORTRAIT_Y_PATH = "a/0/0/5"
local PORTRAIT_Y_ALT_PATH = "a/1/1/7"

local function requireCompiler()
  local loaded, PokedexCatalogCompiler = pcall(require, "romdump.src.digest.ui.PokedexCatalogCompiler")
  Assert.isTrue(loaded, "the pokedex catalog compiler must be published before the semantic projection can be proven")
  return assert(PokedexCatalogCompiler)
end

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

local function s16(value)
  return u16(value % 65536)
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
  for id = 440, 451 do
    species[MonSources.speciesKeys[id]].genderRatio = 0
  end
  for id = 452, 467 do
    species[MonSources.speciesKeys[id]].genderRatio = 254
  end
  for id = 280, 333 do
    species[MonSources.speciesKeys[id]].genderRatio = 255
  end
  return { species = species, version = { id = "heartgold", language = "english" } }
end

-- Distinct synthetic measurement values per profile so the test can tell
-- which archive fed which profile. Giratina carries the pinned numeric
-- mapping: base 45dm/7500hg, origin 69dm/6500hg.
local function measurementValues(profile)
  local heights, weights = {}, {}
  for id = 1, 493 do
    heights[id] = 1000 + id
    weights[id] = 1000 + id * 10
  end
  if profile == "base" then
    heights[1], weights[1] = 41, 320
    heights[487], weights[487] = 45, 7500
  else
    heights[1], weights[1] = 42, 330
    heights[487], weights[487] = 69, 6500
  end
  heights[25], weights[25] = 4, 60
  return heights, weights
end

local function sortedByValue(ids, values, descending)
  local ordered = {}
  for _, id in ipairs(ids) do
    ordered[#ordered + 1] = id
  end
  table.sort(ordered, function(a, b)
    if values[a] ~= values[b] then
      if descending then
        return values[a] > values[b]
      end
      return values[a] < values[b]
    end
    return a < b
  end)
  return ordered
end

local function measuresArchive(profile)
  local heightsBySpecies, weightsBySpecies = measurementValues(profile)
  -- Height and weight tables are entry-indexed in the source archives:
  -- entry 0 is padding and species s reads entry s.
  local heights, weights = { 0 }, { 0 }
  for id = 1, 493 do
    heights[id + 1] = heightsBySpecies[id]
    weights[id + 1] = weightsBySpecies[id]
  end
  local members = {}
  members[1] = u32List(heights)
  members[2] = u32List(weights)
  local shapes = {}
  for _ = 1, 494 do
    shapes[#shapes + 1] = string.char(0)
  end
  members[3] = table.concat(shapes)
  for member = 4, 11 do
    local scales = {}
    for _ = 1, 494 do
      scales[#scales + 1] = s16(0)
    end
    members[member] = table.concat(scales)
  end
  local national = allSpeciesIds()
  national[1], national[2] = national[2], national[1]
  members[12] = u16List(national)
  local johto = {}
  for id = 1, 256 do
    johto[#johto + 1] = id
  end
  members[13] = u16List(johto)
  local alphabetical = allSpeciesIds()
  table.sort(alphabetical, function(a, b)
    return MonSources.speciesKeys[a] < MonSources.speciesKeys[b]
  end)
  members[14] = u16List(alphabetical)
  members[15] = u16List(sortedByValue(allSpeciesIds(), weightsBySpecies, true))
  members[16] = u16List(sortedByValue(allSpeciesIds(), weightsBySpecies, false))
  members[17] = u16List(sortedByValue(allSpeciesIds(), heightsBySpecies, true))
  members[18] = u16List(sortedByValue(allSpeciesIds(), heightsBySpecies, false))
  for letter = 1, 26 do
    members[18 + letter] = ""
  end
  members[18 + 2] = u16List({ 1, 25 })
  for member = 45, 62 do
    members[member] = ""
  end
  -- Type lists skip the unused mystery slot: member 62 + type id holds
  -- every type except mystery, so grass lives at member 73.
  for member = 62, 79 do
    members[member] = ""
  end
  members[66] = u16List({ 1 })
  members[73] = u16List({ 1 })
  members[74] = u16List({ 1 })
  members[75] = u16List({ 25 })
  members[80] = u16List(allSpeciesIds())
  for member = 81, 93 do
    members[member] = ""
  end
  for member = 94, 102 do
    members[member] = ""
  end
  local ordered = {}
  for member = 1, 102 do
    ordered[member] = members[member]
  end
  return NarcBuilder.build(ordered)
end

local function sliderArchive(maskOverrides)
  local rows = {}
  for step = 1, 152 do
    rows[#rows + 1] = u16(step) .. u16(step * 10)
  end
  local anchors = {
    [1] = { 0, 0 },
    [2] = { 1, 2 },
    [11] = { 3, 20 },
    [41] = { 10, 125 },
    [81] = { 20, 325 },
    [101] = { 30, 425 },
    [121] = { 40, 1000 },
    [141] = { 50, 3000 },
    [152] = { 100, 9000 },
  }
  for row, values in pairs(anchors) do
    rows[row] = u16(values[1]) .. u16(values[2])
  end
  rows[153] = u16(999) .. u16(9999)
  local masks = {}
  for _ = 1, 494 do
    masks[#masks + 1] = string.char(0)
  end
  -- The mask member is entry-indexed: byte 1 is the padding slot and
  -- species s carries byte s + 1.
  for id, bits in pairs(maskOverrides or { [1] = 0x02, [25] = 0x04, [151] = 0x10, [2] = 0x80 }) do
    masks[id + 1] = string.char(bits)
  end
  return NarcBuilder.build({ table.concat(rows), table.concat(masks) })
end

local function habitatArchive(options)
  options = options or {}
  local members = {}
  local dungeons = {}
  for index = 0, 25 do
    dungeons[#dungeons + 1] = string.char(index, index + 1, 0, 0)
  end
  members[1] = table.concat(dungeons)
  local outdoor = {}
  for index = 0, 69 do
    outdoor[#outdoor + 1] = string.char(index, index, 2, 2) .. string.rep("\0", 32)
  end
  members[2] = table.concat(outdoor)
  local function row(values, unterminated)
    local parts = {}
    for _, area in ipairs(values) do
      parts[#parts + 1] = u32(area)
    end
    if not unterminated then
      parts[#parts + 1] = u32(0)
    end
    return table.concat(parts)
  end
  local bases = { 2, 497, 992, 1487, 1982, 2477, 2972, 3467 }
  for group = 0, 7 do
    for slot = 0, 494 do
      local values = {}
      if slot == 1 and group == 0 and not options.emptyBulbasaur then
        values = { 3 }
      elseif slot == 1 and group == 3 and not options.emptyBulbasaur then
        values = { 5 }
      elseif slot == 0 and group == 3 then
        values = { 7 }
      end
      local missingTerminator = options.unterminated and slot == 1 and group == 3
      members[bases[group + 1] + slot + 1] = row(values, missingTerminator)
    end
  end
  local ordered = {}
  for member = 1, 3962 do
    ordered[member] = members[member]
  end
  return NarcBuilder.build(ordered)
end

local function johtoInverseArchive(holes)
  -- The inverse member is entry-indexed: entry 0 is padding and
  -- species s reads entry s, which carries its johto position.
  local entries = { 0 }
  for id = 1, 493 do
    entries[id + 1] = 0
  end
  local nonzero = 0
  for position = 1, 256 do
    if not (holes and holes[position]) then
      entries[position + 1] = position
      nonzero = nonzero + 1
    end
  end
  assert(nonzero == (holes and 255 or 256))
  return NarcBuilder.build({ u16List(entries) })
end

local function emptyPortraitSlots()
  local empty = {}
  for id = 440, 451 do
    empty[4 * id] = true
    empty[4 * id + 2] = true
  end
  for id = 452, 467 do
    empty[4 * id + 1] = true
    empty[4 * id + 3] = true
  end
  for id = 280, 333 do
    empty[4 * id] = true
    empty[4 * id + 2] = true
  end
  return empty
end

local function portraitYArchive()
  local empty = emptyPortraitSlots()
  local members = {}
  for slot = 0, 1975 do
    if empty[slot] then
      members[slot + 1] = ""
    else
      members[slot + 1] = string.char((slot % 250) + 1)
    end
  end
  return NarcBuilder.build(members)
end

local function portraitYAltArchive(memberCount)
  local members = {}
  for slot = 1, memberCount or 160 do
    members[slot] = string.char((slot % 250) + 1)
  end
  return NarcBuilder.build(members)
end

local function fixtureRomFs(overrides)
  overrides = overrides or {}
  local archives = {
    [MEASURES_A] = overrides.measuresA or measuresArchive("origin"),
    [MEASURES_B] = overrides.measuresB or measuresArchive("base"),
    [SLIDER_PATH] = overrides.slider or sliderArchive(),
    [HABITAT_PATH] = overrides.habitat or habitatArchive(),
    [JOHTO_INVERSE_PATH] = overrides.johtoInverse or johtoInverseArchive(),
    [PORTRAIT_Y_PATH] = overrides.portraitY or portraitYArchive(),
    [PORTRAIT_Y_ALT_PATH] = overrides.portraitYAlt or portraitYAltArchive(),
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

local function compileFixture(overrides, versionId)
  local PokedexCatalogCompiler = requireCompiler()
  return PokedexCatalogCompiler.compile(fixtureRomFs(overrides), versionId or "heartgold", fixtureMonCatalog())
end

-- Native dungeon marker classes transcribed from the original area-sprite
-- cases: the narrow-marker maps keep shape 6 with a (0, 4) shift, the
-- diagonally shifted maps keep shape 0 with a (4, 4) shift, and every
-- other map (including areas with no retail map) keeps zeros.
local NARROW_MARKER_MAPS = {
  [0x7C] = true,
  [0xB2] = true,
  [0xB3] = true,
  [0x71] = true,
  [0x13B] = true,
  [0x1EA] = true,
  [0x1EB] = true,
  [0x1EC] = true,
}
local SHIFTED_MARKER_MAPS = { [0x60] = true, [0x1E7] = true }

local function expectedMarker(nativeMapId)
  if nativeMapId == nil then
    return 0, { x = 0, y = 0 }
  end
  if NARROW_MARKER_MAPS[nativeMapId] then
    return 6, { x = 0, y = 4 }
  end
  if SHIFTED_MARKER_MAPS[nativeMapId] then
    return 0, { x = 4, y = 4 }
  end
  return 0, { x = 0, y = 0 }
end

function T.source_order_survives_without_host_resorting()
  local catalog = assert(compileFixture())
  Assert.equal(#catalog.dexOrders.national, 493, "the national order keeps all source entries")
  Assert.equal(#catalog.dexOrders.johto, 256, "the johto order keeps all source entries")
  Assert.equal(catalog.dexOrders.national[1], "IVYSAUR", "the source national order is preserved, not resorted")
  Assert.equal(catalog.dexOrders.national[2], "BULBASAUR", "the swapped source pair keeps its source positions")
  Assert.equal(
    catalog.dexOrders.johto[256],
    MonSources.speciesKeys[256],
    "the johto order keeps its trailing source entry"
  )
  local alphabetical = catalog.sortOrders.alphabetical
  Assert.equal(#alphabetical, 493, "the alphabetical order keeps all source entries")
  for index = 2, #alphabetical do
    Assert.isTrue(
      alphabetical[index - 1] < alphabetical[index],
      "the alphabetical order preserves source collation at position " .. index
    )
  end
end

function T.outdoor_and_dungeon_namespaces_stay_distinct_and_all_area_sets_stay_separate()
  local catalog = assert(compileFixture())
  local morning = assert(catalog.habitats.BULBASAUR, "the compiled habitats cover the fixture species").morning
  Assert.equal(#morning.dungeon, 1, "the fixture dungeon encounter survives")
  Assert.equal(#morning.outdoor, 1, "the fixture outdoor encounter survives")
  Assert.isTrue(morning.dungeon[1] ~= morning.outdoor[1], "equal numeric indices in the two namespaces must not merge")
  Assert.equal(
    catalog.areaGeometry[morning.dungeon[1]].kind,
    "dungeon",
    "the dungeon encounter resolves to dungeon geometry"
  )
  Assert.equal(
    catalog.areaGeometry[morning.outdoor[1]].kind,
    "outdoor",
    "the outdoor encounter resolves to outdoor geometry"
  )
  local geometryCount = 0
  for _ in pairs(catalog.areaGeometry) do
    geometryCount = geometryCount + 1
  end
  Assert.equal(geometryCount, 96, "all dungeon and outdoor geometry records survive")
  Assert.equal(#catalog.areaOrder, 96, "the area order covers every geometry record")
  local showAll = catalog.allAreaSets.morning.outdoor
  Assert.isTrue(#showAll >= 1, "the show-everything row compiles its own area set")
  local found = false
  for _, key in ipairs(showAll) do
    if key == morning.outdoor[1] then
      found = true
    end
  end
  Assert.isFalse(found, "the show-everything set is not a copy of a species row")
  Assert.equal(#catalog.habitats.BULBASAUR.other.outdoor, 0, "untouched timed groups stay empty")
end

function T.numeric_giratina_mapping_selects_profiles_and_slider_keeps_every_row()
  local catalog = assert(compileFixture())
  local base = assert(catalog.measurementProfiles.base, "the base profile compiles")
  local origin = assert(catalog.measurementProfiles.giratina_origin, "the origin profile compiles")
  Assert.equal(base.measurements.BULBASAUR.heightDm, 41, "the base profile uses its own archive values")
  Assert.equal(origin.measurements.BULBASAUR.heightDm, 42, "the origin profile uses its own archive values")
  Assert.equal(base.measurements.GIRATINA.heightDm, 45, "the base profile carries the numeric base height")
  Assert.equal(base.measurements.GIRATINA.weightHg, 7500, "the base profile carries the numeric base weight")
  Assert.equal(origin.measurements.GIRATINA.heightDm, 69, "the origin profile carries the numeric origin height")
  Assert.equal(origin.measurements.GIRATINA.weightHg, 6500, "the origin profile carries the numeric origin weight")
  Assert.isNil(
    catalog.species.BULBASAUR.measurements,
    "species records must not duplicate the single measurement authority"
  )
  Assert.equal(#catalog.sliderSteps, 153, "every slider row survives")
  Assert.deepEqual(catalog.sliderSteps[1], { heightDm = 0, weightHg = 0 }, "the first slider anchor survives")
  Assert.deepEqual(catalog.sliderSteps[11], { heightDm = 3, weightHg = 20 }, "a middle slider anchor survives")
  Assert.deepEqual(
    catalog.sliderSteps[153],
    { heightDm = 999, weightHg = 9999 },
    "the terminal slider sentinel survives"
  )
  Assert.deepEqual(catalog.criteria.letters.b, { "BULBASAUR", "PIKACHU" }, "letter lists keep source order")
  Assert.deepEqual(catalog.criteria.types.poison, { "BULBASAUR" }, "type lists keep their members")
  Assert.deepEqual(catalog.criteria.types.grass, { "BULBASAUR" }, "shared members join every matching type list")
  Assert.deepEqual(catalog.criteria.types.electric, { "PIKACHU" }, "single-type members land in one list")
  local johtoAreas, kantoAreas, unknownAreas =
    catalog.criteria.areas.johto, catalog.criteria.areas.kanto, catalog.criteria.areas.unknown
  local function contains(list, key)
    for _, entry in ipairs(list) do
      if entry == key then
        return true
      end
    end
    return false
  end
  Assert.isTrue(contains(johtoAreas, "BULBASAUR"), "the johto mask bit lands in the johto set")
  Assert.isFalse(contains(johtoAreas, "PIKACHU"), "the kanto-only species stays out of the johto set")
  Assert.isTrue(contains(kantoAreas, "PIKACHU"), "the kanto mask bit lands in the kanto set")
  Assert.isTrue(contains(unknownAreas, "MEW"), "the unknown mask bit lands in the unknown set")
  local backSelector = MonCache.portraitSelector("BULBASAUR", 0, "male", false, "back")
  Assert.equal(
    catalog.pictures.backYOffset[backSelector],
    (5 % 250) + 1,
    "the ordinary male back height resolves through the native selector"
  )
  local femaleBack = MonCache.portraitSelector("BULBASAUR", 0, "female", false, "back")
  Assert.equal(
    catalog.pictures.backYOffset[femaleBack],
    (4 % 250) + 1,
    "the ordinary female back height resolves through its own slot"
  )
end

function T.truncated_measurement_archive_fails_with_source_context()
  local PokedexCatalogCompiler = requireCompiler()
  local short = {}
  local full = measuresArchive("base")
  local archive = assert(Narc.open(full, MEASURES_B))
  for member = 0, 100 do
    short[#short + 1] = archive:readMember(member)
  end
  local catalog, err = PokedexCatalogCompiler.compile(
    fixtureRomFs({ measuresB = NarcBuilder.build(short) }),
    "heartgold",
    fixtureMonCatalog()
  )
  Assert.isNil(catalog, "a truncated measurement archive must not compile")
  local typed = assert(err, "a truncated measurement archive must carry an error")
  Assert.notNil(
    tostring(typed.message or typed):find("102", 1, true),
    "the truncation failure must name the expected member count"
  )
end

function T.unterminated_area_list_fails_with_source_context()
  local PokedexCatalogCompiler = requireCompiler()
  local catalog, err = PokedexCatalogCompiler.compile(
    fixtureRomFs({ habitat = habitatArchive({ unterminated = true }) }),
    "heartgold",
    fixtureMonCatalog()
  )
  Assert.isNil(catalog, "an unterminated area list must not compile")
  Assert.notNil(err, "an unterminated area list must carry an error")
end

function T.duplicate_order_membership_fails_on_the_offending_species()
  local PokedexCatalogCompiler = requireCompiler()
  local archive = assert(Narc.open(measuresArchive("base"), MEASURES_B))
  local members = {}
  for member = 0, 101 do
    members[#members + 1] = archive:readMember(member)
  end
  local national = {}
  for id = 1, 492 do
    national[#national + 1] = u16(id)
  end
  national[#national + 1] = u16(1)
  members[12] = table.concat(national)
  local catalog, err = PokedexCatalogCompiler.compile(
    fixtureRomFs({ measuresB = NarcBuilder.build(members) }),
    "heartgold",
    fixtureMonCatalog()
  )
  Assert.isNil(catalog, "a duplicated order member must not compile")
  local typed = assert(err, "a duplicated order member must carry an error")
  Assert.notNil(
    tostring(typed.message or typed):find("BULBASAUR", 1, true),
    "the duplication failure must name the offending species"
  )
end

function T.unmapped_species_reference_and_short_slider_fail()
  local PokedexCatalogCompiler = requireCompiler()
  local archive = assert(Narc.open(measuresArchive("base"), MEASURES_B))
  local members = {}
  for member = 0, 101 do
    members[#members + 1] = archive:readMember(member)
  end
  local national = {}
  for id = 1, 492 do
    national[#national + 1] = u16(id)
  end
  national[#national + 1] = u16(600)
  members[12] = table.concat(national)
  local catalog, err = PokedexCatalogCompiler.compile(
    fixtureRomFs({ measuresB = NarcBuilder.build(members) }),
    "heartgold",
    fixtureMonCatalog()
  )
  Assert.isNil(catalog, "an unmapped species reference must not compile")
  Assert.notNil(err, "an unmapped species reference must carry an error")

  local rows = {}
  for step = 1, 152 do
    rows[#rows + 1] = u16(step) .. u16(step * 10)
  end
  local shortCatalog, shortErr = PokedexCatalogCompiler.compile(
    fixtureRomFs({ slider = NarcBuilder.build({ table.concat(rows), string.rep("\0", 494) }) }),
    "heartgold",
    fixtureMonCatalog()
  )
  Assert.isNil(shortCatalog, "a short slider member must not compile")
  Assert.notNil(shortErr, "a short slider member must carry an error")
end

function T.johto_inverse_hole_fails_before_publication()
  local PokedexCatalogCompiler = requireCompiler()
  local catalog, err = PokedexCatalogCompiler.compile(
    fixtureRomFs({ johtoInverse = johtoInverseArchive({ [7] = true }) }),
    "heartgold",
    fixtureMonCatalog()
  )
  Assert.isNil(catalog, "a johto inverse with a hole must not compile")
  Assert.notNil(err, "a johto inverse hole must carry an error")
end

function T.compiled_catalog_projects_source_measurement_templates_with_full_slider_table()
  for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
    local catalog = assert(compileFixture(nil, versionId))
    Assert.deepEqual(
      catalog.searchText.measureTemplates,
      { height = 175, weight = 38 },
      versionId .. " projects the source height/weight message templates"
    )
    Assert.equal(catalog.textBindings.ui.bankId, 802, versionId .. " keeps the templates under the existing UI bank")
    Assert.equal(#catalog.sliderSteps, 153, versionId .. " keeps every physical slider row")
    Assert.deepEqual(
      catalog.sliderSteps[153],
      { heightDm = 999, weightHg = 9999 },
      versionId .. " keeps the terminal slider sentinel"
    )
  end
end

function T.dungeon_records_carry_source_marker_shapes_and_offsets_without_shifting_positions()
  local symbols = PokedexSources.areaMapSymbols().dungeon
  for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
    local catalog = assert(compileFixture(nil, versionId))
    for id = 1, 26 do
      local key = "dex-dungeon-" .. id
      local record = assert(catalog.areaGeometry[key], versionId .. " publishes " .. key)
      Assert.equal(record.kind, "dungeon", versionId .. " " .. key .. " stays a dungeon record")
      Assert.deepEqual(
        record.position,
        { x = id - 1, y = id },
        versionId .. " " .. key .. " keeps its unshifted source position"
      )
      local nativeMapId = nil
      if symbols[id] ~= nil then
        nativeMapId = MapCatalog.idForSymbol(symbols[id])
        Assert.notNil(nativeMapId, versionId .. " " .. key .. " resolves its retail map " .. symbols[id])
      end
      local shape, offset = expectedMarker(nativeMapId)
      Assert.equal(record.markerShape, shape, versionId .. " " .. key .. " carries its source marker shape")
      Assert.deepEqual(record.markerOffsetPx, offset, versionId .. " " .. key .. " carries its source marker offset")
    end
  end
end

return { tests = T }
