-- ROM-conformance facts for the banner's eligibility projection and native
-- section labels: the generated field-entry manifest admits exactly the
-- non-building map headers, projecting each header's area-window icon to its
-- zero-based style, and the native section-name bank resolves a non-empty
-- label for every admitted section. Asserts only structural facts, never
-- retail text.

local Assert = require("tests.support.Assert")
local FieldEntryAssetCache = require("libs.assets.src.field.FieldEntryAssetCache")
local FieldEntryAssetCompiler = require("romdump.src.digest.ui.FieldEntryAssetCompiler")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local charmap = require("romdump.src.catalog.hgss.charmap")
local maps = require("romdump.src.catalog.hgss.maps")

local T = {}

-- The source bank that indexes one location name per native MAPSEC_* id.
local SECTION_MESSAGE_BANK = 279

-- Compiling the class is the expensive ROM read; one bundle per source dump is
-- reused across this suite's facts.
local bundles = {}
local function manifest(romFs)
  local sha1 = romFs:metadata().sha1
  local bundle = bundles[sha1]
  if bundle == nil then
    bundle = assert(FieldEntryAssetCompiler.compile(romFs))
    bundles[sha1] = bundle
  end
  return bundle.manifest
end

function T.eligibility_projects_the_area_icon_and_suppresses_buildings(romFs, _)
  local m = manifest(romFs)
  Assert.isTrue(FieldEntryAssetCache.validateManifest(m), "the compiled manifest validates")

  -- Eligible outdoor headers project areaIcon - 1.
  for _, case in ipairs({
    { symbol = "MAP_NEW_BARK", style = 1 },
    { symbol = "MAP_CHERRYGROVE", style = 0 },
    { symbol = "MAP_ROUTE_29", style = 2 },
  }) do
    local mapId = assert(MapCatalog.idForSymbol(case.symbol), case.symbol)
    Assert.equal(m.bannerStyleByMapId[mapId], case.style, case.symbol .. " projects its area-window style")
    Assert.notNil(m.bannerStyles[case.style], case.symbol .. " has a compiled banner skin")
  end

  -- A building is suppressed even though its header carries a nonzero area
  -- icon: eligibility is the source's area-icon-plus-map-kind rule, not the
  -- icon value alone.
  local buildingId = assert(MapCatalog.idForSymbol("MAP_NEW_BARK_PLAYER_HOUSE_1F"))
  Assert.isTrue(maps.byId[buildingId].areaIcon ~= 0, "the sampled building carries an area icon")
  Assert.isNil(m.bannerStyleByMapId[buildingId], "a building map header never announces a banner")

  -- Every admitted style names a compiled skin in the source's 0..8 range.
  for mapId, style in pairs(m.bannerStyleByMapId) do
    local record = assert(maps.byId[mapId], "a banner style names a frozen map header")
    Assert.isTrue(style >= 0 and style <= 8, record.symbol .. " carries a valid style index")
    Assert.notNil(m.bannerStyles[style], record.symbol .. " resolves its compiled skin")
  end
end

function T.every_admitted_section_resolves_a_native_label(romFs, _)
  local m = manifest(romFs)
  local messages = assert(romFs:openNarc("messages"))
  local bank = assert(FieldMessageBank.decode(messages:readMember(SECTION_MESSAGE_BANK), {}))

  local sectionIds = {}
  for mapId in pairs(m.bannerStyleByMapId) do
    local record = assert(maps.byId[mapId], "a banner style names a frozen map header")
    sectionIds[record.mapSectionNativeId] = true
  end

  local resolved = 0
  for sectionId in pairs(sectionIds) do
    local message = bank.messages[sectionId + 1]
    Assert.notNil(message, "the section-name bank carries message " .. sectionId)
    local tokens = assert(FieldMessageTokenizer.tokenize(message.raw, charmap, {}))
    local text = FieldMessageText.tokensToText(tokens)
    Assert.isTrue(type(text) == "string" and #text > 0, "section " .. sectionId .. " resolves a native label")
    resolved = resolved + 1
  end
  Assert.isTrue(resolved > 0, "at least one announced section resolves a label")

  -- The sampled seams name the exact native section identities the runtime
  -- requests (`messageProvider:get(279, mapSectionNativeId)`).
  Assert.notNil(bank.messages[maps.byId[60].mapSectionNativeId + 1], "New Bark resolves its native section name")
  Assert.notNil(bank.messages[maps.byId[33].mapSectionNativeId + 1], "Route 29 resolves its native section name")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
