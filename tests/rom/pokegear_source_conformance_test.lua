-- Source conformance for the pocket-gear family against owned dumps: the
-- published archive selection opens with its closed member ranges, the
-- phonebook payload keeps its published length, and the compiled catalog
-- carries the native program and place closure with independent
-- expectations transcribed from the decomp-derived anchors rather than
-- from the producer under test. HeartGold is verified; SoulSilver stays
-- explicitly unverified until owned SoulSilver bytes arrive, and no
-- HeartGold physical identity is ever substituted for a SoulSilver one.
-- Member bytes are never committed to the repository.

local Assert = require("tests.support.Assert")
local Narc = require("libs.nds.src.nitro.Narc")
local RomImporter = require("romdump.src.source.RomImporter")
local RomSuite = require("tests.rom.support.RomSuite")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")

local T = {}

-- Evidence anchors for the five core graphics archives: source path plus
-- the closed member range the family selects, carried from the validated
-- asset-family closure. Physical identities stay version-local; they are
-- never cross-version constants.
local EXPECTED_ARCHIVES = {
  { role = "common shell", path = "a/1/4/3", members = 60 },
  { role = "map and standalone fly", path = "a/1/4/4", members = 70 },
  { role = "setup", path = "a/1/4/5", members = 28 },
  { role = "phone", path = "a/1/4/6", members = 52 },
  { role = "radio", path = "a/1/4/7", members = 46 },
}

-- Sprite descriptor bindings: CHAR/PLTT/CELL/ANIM descriptor members in
-- the sprite archive plus the header member binding each set, carried
-- from the decomp-derived sprite bindings.
local SPRITE_ARCHIVE_PATH = "a/1/7/5"
local EXPECTED_SPRITE_BINDINGS = {
  { set = "map", members = { 32, 33, 34, 35, 80 } },
  { set = "setup", members = { 40, 41, 42, 43, 82 } },
  { set = "phone", members = { 44, 45, 46, 47, 83 } },
  { set = "radio", members = { 36, 37, 38, 39, 81 } },
}

local PHONEBOOK_PATH = "tel/pmtel_book.dat"
local PHONEBOOK_HG_BYTES = 1504

-- Native closures from the source basis: twelve broadcast programs, and
-- the curated map place table covering outdoor, indoor, fallback, and
-- the four special locations (Mt Silver, Indigo Plateau, Sinjoh,
-- S.S. Aqua) by their source identities.
local NATIVE_SHOW_COUNT = 12
local SPECIAL_LOCATION_FRAGMENTS = { "mount-silver", "indigo-plateau", "sinjoh-ruins", "ss-aqua" }

---@param _ unknown
local function void(_) end

---@param romFs table<string, unknown>
---@param path string
---@return table archive
local function openArchive(romFs, path)
  local reader = romFs --[[@as { readSourcePath: fun(self: table, path: string): string? }]]
  local bytes = reader:readSourcePath(path)
  Assert.notNil(bytes, "the dump must expose archive " .. path)
  local archive = Narc.open(assert(bytes), path)
  Assert.notNil(archive, "archive " .. path .. " must open")
  return assert(archive)
end

---@param context table?
---@param versionId string
local function requireHeartGold(context, versionId)
  if versionId ~= "heartgold" then
    assert(context ~= nil, "version-gated conformance needs its runner context")
    context:skip(versionId .. " awaits its own owned-byte vectors; HeartGold identities are never substituted")
  end
end

-- The published archive selection opens with its closed member ranges,
-- and every sprite descriptor binding names a member the archive
-- actually carries.
function T.heartgold_archives_cover_the_published_selection(romFs, versionId, context)
  requireHeartGold(context, versionId)
  local selected = 0
  for _, archive in ipairs(EXPECTED_ARCHIVES) do
    local opened = openArchive(romFs, archive.path)
    Assert.equal(
      opened:memberCount(),
      archive.members,
      versionId .. " " .. archive.role .. " (" .. archive.path .. ") keeps its closed member range"
    )
    selected = selected + archive.members
  end
  local sprites = openArchive(romFs, SPRITE_ARCHIVE_PATH)
  local spriteMembers = sprites:memberCount()
  for _, binding in ipairs(EXPECTED_SPRITE_BINDINGS) do
    for _, member in ipairs(binding.members) do
      Assert.isTrue(
        member < spriteMembers,
        versionId .. " sprite set " .. binding.set .. " keeps member " .. member .. " inside " .. SPRITE_ARCHIVE_PATH
      )
    end
    selected = selected + #binding.members
  end
  Assert.equal(selected, 276, versionId .. " keeps the full 276-member research closure selected")
end

-- The phonebook payload keeps its published byte length on HeartGold.
function T.heartgold_phonebook_keeps_its_published_length(romFs, versionId, context)
  requireHeartGold(context, versionId)
  local reader = romFs --[[@as { readSourcePath: fun(self: table, path: string): string? }]]
  local bytes = reader:readSourcePath(PHONEBOOK_PATH)
  Assert.notNil(bytes, versionId .. " must expose " .. PHONEBOOK_PATH)
  Assert.equal(#assert(bytes), PHONEBOOK_HG_BYTES, versionId .. " keeps the published phonebook length")
end

-- The compiled catalog carries the native program and place closure:
-- schema-valid, all twelve broadcast programs, all one hundred map
-- locations, and a non-empty contact table.
function T.heartgold_catalog_carries_the_native_program_and_place_closure(romFs, versionId, context)
  requireHeartGold(context, versionId)
  local loaded, PokegearAssetCompiler = pcall(require, "romdump.src.digest.ui.PokegearAssetCompiler")
  Assert.isTrue(loaded, "the family compiler must be published before the closure can be proven")
  assert(type(PokegearAssetCompiler) == "table", "the family compiler loads above")
  local bundle = PokegearAssetCompiler.compile(romFs, versionId)
  local compiled = assert(bundle, versionId .. " must compile the family")
  local manifest = assert(compiled.manifest, versionId .. " must publish its manifest")
  Assert.notNil(PokegearAssetSchema.validate(manifest), versionId .. " publishes a schema-valid catalog")
  local catalog = assert(manifest.catalog, versionId .. " publishes its catalog")
  Assert.equal(#catalog.shows, NATIVE_SHOW_COUNT, versionId .. " carries all twelve native broadcast programs")
  local locations = assert(catalog.locations, versionId .. " publishes its location table")
  Assert.isTrue(#locations > 0, versionId .. " compiles a non-empty location table")
  for _, entry in ipairs(locations) do
    Assert.isTrue(type(entry.key) == "string", versionId .. " locations carry semantic keys")
    Assert.isTrue(type(entry.mapRef) == "number", versionId .. " locations carry header map references")
    Assert.isTrue(type(entry.matrix) == "table", versionId .. " locations carry world anchors")
  end
  for _, fragment in ipairs(SPECIAL_LOCATION_FRAGMENTS) do
    local found = false
    for _, entry in ipairs(locations) do
      if (entry.key .. " " .. (entry.location or "")):find(fragment, 1, true) ~= nil then
        found = true
      end
    end
    Assert.isTrue(found, versionId .. " keeps its special location " .. fragment)
  end
  Assert.isTrue(#catalog.contacts > 0, versionId .. " carries its native contact table")
end

-- The region-map tables compile whole and keep hand-copied source rows:
-- the first location, an overlay-bearing location, and two flypoints
-- (including one whose warp map differs from its name map).
function T.heartgold_region_map_carries_the_source_location_and_flypoint_tables(romFs, versionId, context)
  requireHeartGold(context, versionId)
  local PokegearAssetCompiler = require("romdump.src.digest.ui.PokegearAssetCompiler")
  local compiled = assert(PokegearAssetCompiler.compile(romFs, versionId), versionId .. " must compile the family")
  local regionMap = assert(compiled.manifest.catalog.regionMap, versionId .. " publishes its region map")
  Assert.equal(#regionMap.locations, 100, versionId .. " carries all one hundred region-map locations")
  Assert.equal(#regionMap.flypoints, 27, versionId .. " carries all twenty-seven region-map flypoints")
  Assert.deepEqual(regionMap.locations[1], {
    mapId = 521,
    mapSymbol = "MAP_SINJOH_RUINS_EXTERIOR",
    x = 19,
    y = 2,
    width = 3,
    height = 3,
    objXOffset = 0,
    objYOffset = 12,
    flavorEntry = 65,
    previewBlock = 0,
    sectionEntry = 231,
    overlay = { srcX = 0, srcY = 0, width = 0, height = 0 },
  }, versionId .. " keeps the first source location")
  Assert.deepEqual(regionMap.locations[3], {
    mapId = 120,
    mapSymbol = "MAP_ICE_PATH_1F",
    x = 21,
    y = 6,
    width = 1,
    height = 1,
    objXOffset = 0,
    objYOffset = 0,
    flavorEntry = 55,
    previewBlock = 0,
    sectionEntry = 217,
    overlay = { srcX = 5, srcY = 40, width = 1, height = 1 },
  }, versionId .. " keeps a location with an overlay copy")
  Assert.deepEqual(regionMap.flypoints[1], {
    nameMapId = 49,
    nameSectionEntry = 138,
    warpMapId = 49,
    flypoint = 0,
    x = 32,
    y = 11,
    width = 1,
    height = 1,
    overlay = { srcX = 0, srcY = 20, destX = 1, destY = 1, width = 3, height = 3 },
  }, versionId .. " keeps the first source flypoint")
  Assert.deepEqual(regionMap.flypoints[26], {
    nameMapId = 96,
    nameSectionEntry = 207,
    warpMapId = 280,
    flypoint = 35,
    x = 10,
    y = 6,
    width = 2,
    height = 2,
    overlay = { srcX = 0, srcY = 0, destX = 0, destY = 0, width = 0, height = 0 },
  }, versionId .. " keeps a flypoint whose warp map differs from its name map")
end

-- SoulSilver parity waits on owned SoulSilver bytes: reported as an
-- explicit skip with its reason, never as a HeartGold-substituted pass.
-- If a SoulSilver dump ever becomes ready, this leg turns red until its
-- own vectors are transcribed.
function T.soulsilver_parity_waits_on_owned_bytes(romFs, versionId, context)
  void(romFs)
  if versionId ~= "heartgold" then
    return
  end
  assert(context ~= nil, "parity reporting needs its runner context")
  if not RomImporter.isReady("soulsilver") then
    context:skip("soulsilver dump not owned; parity unverified")
  end
  error("a soulsilver dump is ready but its selector vectors are still untranscribed", 0)
end

local suite = RomSuite.fromFacts(T)
suite.metadata.tags = { "pokegear" }
return suite
