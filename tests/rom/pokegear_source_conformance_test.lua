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
local MapReference = require("romdump.src.reference.hgss.maps")
local BinaryReader = require("libs.codec.src.BinaryReader")
local PokegearCatalogCompiler = require("romdump.src.digest.ui.PokegearCatalogCompiler")

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

-- Phonebook semantics retain their native byte positions when the supplied
-- HeartGold record is compiled. The field layout is corroborated by the
-- available decomp checkout, whose revision is not the declared source pin.
function T.heartgold_phonebook_fields_match_their_native_record_offsets(romFs, versionId, context)
  requireHeartGold(context, versionId)
  local reader = romFs --[[@as { readSourcePath: fun(self: table, path: string): string? }]]
  local bytes = assert(reader:readSourcePath(PHONEBOOK_PATH))
  local source = BinaryReader.new(bytes, "heartgold-phonebook-conformance")
  local catalog = assert(PokegearCatalogCompiler.decodePhonebook(bytes))
  local record = assert(catalog.contacts[1], "the phonebook begins with one native contact record")
  local base = 4
  Assert.equal(record.trainerClass, source:u8(base + 3), "trainer class comes from byte 3")
  Assert.equal(record.trainerId, source:u16le(base + 4), "trainer ID comes from halfword 4")
  Assert.equal(record.mapId, source:u16le(base + 6), "map ID comes from halfword 6")
  Assert.equal(record.gift, source:u16le(base + 8), "gift comes from halfword 8")
  Assert.equal(record.localScript, source:u16le(base + 10), "local script comes from halfword 10")
  Assert.equal(record.rematchWeekday, source:u8(base + 13), "rematch weekday comes from byte 13")
  Assert.equal(record.rematchTime, source:u8(base + 14), "rematch time comes from byte 14")
  for weightIndex = 0, 3 do
    Assert.equal(
      record.sortWeights[weightIndex + 1],
      source:u8(base + 16 + weightIndex),
      "sort weight " .. weightIndex .. " comes from its native byte"
    )
  end
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
  local permissions = assert(catalog.callPermissions, versionId .. " publishes native phone permissions")
  Assert.equal(MapReference.count, 540, versionId .. " keeps the native map-header reference complete")
  for mapId = 0, MapReference.count - 1 do
    local source = assert(MapReference.byId[mapId], versionId .. " has native source map " .. mapId)
    local permission = assert(permissions[mapId], versionId .. " publishes phone permissions for map " .. mapId)
    Assert.equal(permission.incoming, source.incomingCalls, "map " .. mapId .. " preserves its incoming source flag")
    Assert.equal(permission.outgoing, source.outgoingCalls, "map " .. mapId .. " preserves its outgoing source flag")
  end
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

function T.heartgold_phone_catalog_carries_native_headers_and_mom_intro_parameters(romFs, versionId, context)
  requireHeartGold(context, versionId)
  local PokegearAssetCompiler = require("romdump.src.digest.ui.PokegearAssetCompiler")
  local compiled = assert(PokegearAssetCompiler.compile(romFs, versionId))
  local catalog = assert(compiled.manifest.catalog)
  local joey = nil
  for _, contact in ipairs(catalog.contacts) do
    if contact.family == "trainer" and contact.id == 10 then
      joey = contact
      break
    end
  end
  Assert.notNil(joey, "the native catalog resolves Joey's generic caller row")
  local headers = assert(joey.genericCallHeaders)
  Assert.deepEqual(headers.outgoing, {
    { type = 7, chance = 100, scriptType = 0, scriptId = 34 },
    { type = 3, chance = 100, scriptType = 0, scriptId = 33 },
    { type = 1, chance = 100, scriptType = 1, scriptId = 35 },
    { type = 255, chance = 0, scriptType = 0, scriptId = 65535 },
    { type = 255, chance = 0, scriptType = 0, scriptId = 65535 },
    { type = 255, chance = 0, scriptType = 0, scriptId = 65535 },
    { type = 255, chance = 0, scriptType = 0, scriptId = 65535 },
    { type = 255, chance = 0, scriptType = 0, scriptId = 65535 },
  }, "Joey's outgoing source rows retain order while both terminators normalize to the no-call sentinel")
  Assert.deepEqual(headers.incoming, {
    { type = 2, chance = 60, scriptType = 0, scriptId = 33 },
    { type = 1, chance = 40, scriptType = 1, scriptId = 30 },
    { type = 1, chance = 40, scriptType = 1, scriptId = 31 },
    { type = 1, chance = 100, scriptType = 1, scriptId = 32 },
    { type = 255, chance = 0, scriptType = 0, scriptId = 65535 },
    { type = 255, chance = 0, scriptType = 0, scriptId = 65535 },
    { type = 255, chance = 0, scriptType = 0, scriptId = 65535 },
    { type = 255, chance = 0, scriptType = 0, scriptId = 65535 },
  }, "Joey's incoming source header order and decisions are preserved")

  local introParameters = assert(catalog.momCallIntroParameters)
  for mapId = 0, MapReference.count - 1 do
    Assert.equal(
      introParameters[mapId],
      MapReference.byId[mapId].momCallIntroParam,
      "map " .. mapId .. " preserves the native Mom introduction parameter"
    )
  end
  local momTrigger = nil
  for _, trigger in ipairs(catalog.callTriggers) do
    if trigger.slot == 12 then
      momTrigger = trigger
      break
    end
  end
  Assert.notNil(momTrigger, "the native Mom gift trigger is present")
  Assert.equal(momTrigger.scriptedCallType, 3, "the Mom trigger keeps its native scripted-call type")
  Assert.equal(momTrigger.predefinedScriptId, 27, "the Mom trigger keeps PHONE_SCRIPT_027")
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
