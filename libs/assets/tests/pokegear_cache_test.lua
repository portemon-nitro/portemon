-- The Pokegear cache owns its family paths, marker identity, and readiness:
-- a receipt plus complete output reads ready, a stale marker or a missing
-- asset refuses without raising, and asset paths stay inside the family.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local function visualRef(path)
  return { image = path, width = 32, height = 32, anchorX = 0, anchorY = 0 }
end

local function fixtureManifest()
  return {
    schema = "g4-pokegear-assets-v2",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png") },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png") },
    phone = { panel = visualRef("assets/generated/pokegear/phone-panel.png") },
    map = { base = visualRef("assets/generated/pokegear/map-base.png") },
    fly = { base = visualRef("assets/generated/pokegear/fly-base.png") },
    radio = { dial = visualRef("assets/generated/pokegear/radio-dial.png") },
    catalog = {
      contacts = {},
      contactOrder = {},
      callDefinitions = {},
      callTriggers = {},
      rematches = {},
      gifts = {},
      momPurchases = {},
      locations = {},
      flypoints = {},
      regionMap = require("tests.support.PokegearRegionMapFixture").build(),
      reception = {},
      shows = {},
      radioEffects = {},
    },
    text = {},
    sequences = {},
  }
end

local function stagedCache(manifest, marker, assetManifest)
  local PokegearCache = require("libs.assets.src.PokegearCache")
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  for _, path in ipairs(PokegearCache.referencedPaths(assetManifest or manifest or fixtureManifest())) do
    cache:write(path, "fixture asset")
  end
  cache:writeLua(PokegearCache.manifestPath(), manifest or fixtureManifest())
  cache:writeLua(PokegearCache.provenancePath(), { staged = true })
  cache:write(PokegearCache.markerPath(), marker)
  return cache, backend
end

function T.complete_publication_reads_ready_and_loads_its_manifest()
  local PokegearCache = require("libs.assets.src.PokegearCache")
  local marker = PokegearCache.marker("rom-sha", "deps-sha")
  local cache = stagedCache(nil, marker)
  Assert.isTrue(PokegearCache.isReady(cache, marker), "a complete publication must read ready")
  local manifest = PokegearCache.loadManifest(cache)
  Assert.equal(manifest.schema, "g4-pokegear-assets-v2", "the loaded manifest keeps its schema identity")
end

function T.stale_markers_and_missing_assets_refuse_without_raising()
  local PokegearCache = require("libs.assets.src.PokegearCache")
  local marker = PokegearCache.marker("rom-sha", "deps-sha")
  local cache, backend = stagedCache(nil, marker)
  local stale = PokegearCache.marker("rom-sha", "other-deps")
  local staleOk, staleReady = pcall(PokegearCache.isReady, cache, stale)
  Assert.isTrue(staleOk, "a stale marker is a readiness refusal, not an exception")
  Assert.isFalse(staleReady, "a stale marker must not read ready")

  local firstPath = PokegearCache.referencedPaths(fixtureManifest())[1]
  cache:remove(firstPath)
  local missingOk, missingReady = pcall(PokegearCache.isReady, cache, marker)
  Assert.isTrue(missingOk, "a missing asset is a readiness refusal, not an exception")
  Assert.isFalse(missingReady, "a publication missing an asset must not read ready")
  Assert.isTrue(backend ~= nil, "the fixture backend exists for the next stage")
end

function T.incomplete_manifests_never_read_ready()
  local PokegearCache = require("libs.assets.src.PokegearCache")
  local marker = PokegearCache.marker("rom-sha", "deps-sha")
  local cache = stagedCache({ schema = "g4-pokegear-assets-v2" }, marker, fixtureManifest())
  local ok, ready = pcall(PokegearCache.isReady, cache, marker)
  Assert.isTrue(ok, "an incomplete manifest is a readiness refusal, not an exception")
  Assert.isFalse(ready, "a marker cannot make an incomplete family ready")
end

function T.referenced_paths_cover_every_published_visual_once()
  local PokegearCache = require("libs.assets.src.PokegearCache")
  local manifest = fixtureManifest()
  local paths = PokegearCache.referencedPaths(manifest)
  Assert.isTrue(#paths >= 6, "every section contributes its visuals")
  local seen = {}
  for _, path in ipairs(paths) do
    Assert.isNil(seen[path], "referenced paths carry no duplicates: " .. path)
    seen[path] = true
    Assert.equal(path:sub(1, #"assets/generated/pokegear/"), "assets/generated/pokegear/", "assets stay in the family")
  end
end

function T.marker_binds_format_and_source_identities()
  local PokegearCache = require("libs.assets.src.PokegearCache")
  local marker = PokegearCache.marker("rom-sha", "deps-sha")
  Assert.equal(marker:sub(1, #PokegearCache.FORMAT + 1), PokegearCache.FORMAT .. ":", "the marker names its format")
  Assert.isTrue(marker:find("rom-sha", 1, true) ~= nil, "the marker binds the source identity")
  Assert.isTrue(marker:find("deps-sha", 1, true) ~= nil, "the marker binds the dependency identity")
  Assert.equal(PokegearCache.manifestPath(), "data/generated/pokegear/manifest.lua", "the manifest path is stable")
  Assert.equal(PokegearCache.assetDir(), "assets/generated/pokegear", "the asset directory is stable")
end

local WORD_BANKS = { 237, 751, 735, 721, 285, 286, 287, 288, 289, 290, 291 }
local GROUP_COUNTS = { 496, 468, 18, 124, 38, 38, 107, 104, 47, 32, 23 }
local GROUP_BASES = { 0, 496, 964, 982, 1106, 1144, 1182, 1289, 1393, 1440, 1472 }

local function wordEntrySection()
  local groups = {}
  for index = 1, 11 do
    groups[index] =
      { group = index - 1, bank = WORD_BANKS[index], count = GROUP_COUNTS[index], firstWordId = GROUP_BASES[index] }
  end
  return {
    groups = groups,
    cursor = {
      sequences = {
        {
          frames = {
            {
              image = "assets/generated/pokegear/word-entry-cursor-1-1.png",
              width = 16,
              height = 16,
              anchorX = 0,
              anchorY = 0,
              duration = 4,
            },
          },
          playMode = "forward",
          loopStartFrameIdx = 0,
        },
      },
    },
    background = { screenMember = 0, charMember = 1, layers = { 0, 4 } },
    text = { interfaceBanks = { 282, 283, 284 }, interfaceCounts = { 14, 15, 3 } },
    input = { hitboxes = 5, touchYMin = 28, touchYMax = 226, confirmSound = 1500 },
  }
end

local function stagedWordEntry(section, marker)
  local PokegearCache = require("libs.assets.src.PokegearCache")
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  for _, path in ipairs(PokegearCache.wordEntryReferencedPaths(section)) do
    cache:write(path, "fixture asset")
  end
  cache:writeLua(PokegearCache.wordEntryManifestPath(), section)
  cache:writeLua(PokegearCache.wordEntryProvenancePath(), { staged = true })
  cache:write(PokegearCache.wordEntryMarkerPath(), marker)
  return cache
end

function T.word_entry_readiness_is_tracked_separately_from_core()
  local PokegearCache = require("libs.assets.src.PokegearCache")
  Assert.isFalse(
    PokegearCache.wordEntryManifestPath() == PokegearCache.manifestPath(),
    "the word-entry section stages outside the core manifest"
  )
  Assert.isFalse(
    PokegearCache.wordEntryMarkerPath() == PokegearCache.markerPath(),
    "the word-entry marker stages outside the core marker"
  )
  local marker = PokegearCache.wordEntryMarker("rom-sha", "deps-sha")
  Assert.isTrue(marker:find("rom-sha", 1, true) ~= nil, "the word-entry marker binds the source identity")
  local section = wordEntrySection()
  local cache = stagedWordEntry(section, marker)
  Assert.isTrue(PokegearCache.isWordEntryReady(cache, marker), "a complete word-entry publication must read ready")
  local stale = PokegearCache.wordEntryMarker("rom-sha", "other-deps")
  local staleOk, staleReady = pcall(PokegearCache.isWordEntryReady, cache, stale)
  Assert.isTrue(staleOk, "a stale word-entry marker is a readiness refusal, not an exception")
  Assert.isFalse(staleReady, "a stale word-entry marker must not read ready")

  local coreMarker = PokegearCache.marker("rom-sha", "deps-sha")
  local coreReady = pcall(PokegearCache.isReady, cache, coreMarker)
  Assert.isTrue(coreReady, "word-entry staging alone never raises core readiness")
  Assert.isFalse(PokegearCache.isReady(cache, coreMarker), "word-entry staging alone never completes the core family")
end

return { tests = T }
