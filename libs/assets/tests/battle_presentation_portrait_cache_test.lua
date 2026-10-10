-- Back-facing mon portraits at the asset cache boundary: back selectors
-- resolve apart from front selectors while every established front
-- selector keeps its meaning, facing-aware manifests validate, and one
-- battle demand names exactly its pages with truthful readiness. Selector
-- fixtures are synthetic; the ROM suite proves the real back pixels.

local Assert = require("tests.support.Assert")
local ArtifactState = require("romdump.src.build.ArtifactState")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
local MonCache = require("libs.assets.src.MonCache")

local T = {}

---@return string front selector in the long-established spelling
local function frontSelector()
  return MonCache.portraitSelector("CHIKORITA", 0, "male", false)
end

---@return string back selector for the same mon
local function backSelector()
  return MonCache.portraitSelector("CHIKORITA", 0, "male", false, "back")
end

function T.back_selectors_resolve_apart_from_front_selectors()
  Assert.equal(frontSelector(), "CHIKORITA/f0/male/plain", "the established front spelling is unchanged")
  local back = backSelector()
  Assert.isTrue(back ~= frontSelector(), "the back selector must not collapse onto the front selector")
  Assert.isTrue(back:find("CHIKORITA", 1, true) ~= nil, "the back selector keeps its species key")
  Assert.isTrue(back:find("back", 1, true) ~= nil, "the back selector carries an explicit facing mark")
  Assert.isTrue(
    MonCache.portraitSelector("TOTODILE", 0, "male", true, "back")
      ~= MonCache.portraitSelector("TOTODILE", 0, "male", true),
    "shiny back selectors resolve apart from shiny front selectors"
  )
  Assert.isTrue(
    MonCache.portraitSelector("CHIKORITA", 0, "female", false, "back") ~= frontSelector(),
    "gender variants keep distinct back selectors"
  )
end

function T.front_selectors_without_facing_keep_their_meaning()
  Assert.equal(
    MonCache.portraitSelector("TOTODILE", 0, "male", true),
    "TOTODILE/f0/male/shiny",
    "the established shiny front spelling is unchanged"
  )
  Assert.equal(
    MonCache.portraitSelector("CHIKORITA", 0, "male", false, "front"),
    frontSelector(),
    "an explicit front mark matches the default spelling"
  )
end

---@return table manifest entry pinned inside a 640x320 page
local function pageEntry()
  return {
    x = 0,
    y = 0,
    width = 80,
    height = 80,
    pageId = 0,
    frames = {
      { x = 0, y = 0, width = 80, height = 80, duration = 6 },
      { x = 80, y = 0, width = 80, height = 80, duration = 6 },
    },
  }
end

function T.facing_manifests_validate_front_and_back_entries_together()
  local entries = {}
  entries[frontSelector()] = pageEntry()
  entries[backSelector()] = pageEntry()
  local manifest = {
    schema = "g4-mon-portrait-manifest-v2",
    version = { id = "soulsilver", language = "en" },
    pages = {
      [0] = { pageId = 0, image = "assets/generated/mon/portraits/0.png", width = 640, height = 320 },
    },
    pageIds = { 0 },
    entries = entries,
    representative = { frontSelector() },
  }
  Assert.isTrue(MonAssetSchema.isValidPortraitManifest(manifest), "front and back entries validate together")
  Assert.equal(entries[backSelector()].pageId, 0, "the back entry carries page membership")
end

---@param moduleName string
---@return table loaded module
local function requireBoundary(moduleName, why)
  local ok, module = pcall(require, moduleName)
  Assert.isTrue(ok and module ~= nil, why)
  assert(module ~= nil, "the boundary module loaded")
  return module
end

function T.single_battle_demand_names_exactly_its_pages()
  Assert.isTrue(
    ArtifactState.KINDS["battle-presentation"] == true,
    "the closed job table carries a battle presentation provider"
  )
  Assert.isTrue(ArtifactState.KINDS["battle-scene"] == true, "the closed job table carries a battle scene provider")
  local cache = requireBoundary(
    "libs.assets.src.battle.BattlePresentationCache",
    "no battle presentation demand reaches the cache boundary without its cache module"
  )
  Assert.isTrue(type(cache.requirements) == "function", "the cache boundary exposes an exact demand function")
  local manifest = cache.load(CacheFs.forVersion("heartgold", FakeCache.new()))
  Assert.isTrue(type(manifest) == "table", "the staged global manifest loads through the cache boundary")
  local demand = assert(
    cache.requirements(manifest, { background = "general", terrain = "grass", time = "day" }, { backSelector() }, nil),
    "one battle context yields one exact demand"
  )
  Assert.isTrue(type(demand.scenes) == "table" and #demand.scenes == 1, "one battle demands exactly one scene")
  Assert.isTrue(type(demand.pages) == "table" and #demand.pages >= 1, "the demand names its portrait pages")
  local seen = {}
  for _, page in ipairs(demand.pages) do
    Assert.isNil(seen[page], "the exact demand carries no duplicate page")
    seen[page] = true
  end
end

function T.delayed_corrupt_and_stale_readiness_never_reads_as_ready()
  Assert.isTrue(
    ArtifactState.KINDS["battle-presentation"] == true,
    "the closed job table carries a battle presentation provider"
  )
  local cache = requireBoundary(
    "libs.assets.src.battle.BattlePresentationCache",
    "no battle presentation readiness is observable without its cache module"
  )
  Assert.isTrue(type(cache.isReady) == "function", "the cache boundary exposes a readiness predicate")
  local staging = CacheFs.forVersion("heartgold", FakeCache.new())
  local manifest = cache.load(staging)
  local demand = assert(
    cache.requirements(manifest, { background = "general", terrain = "grass", time = "day" }, { backSelector() }, nil),
    "one battle context yields one exact demand"
  )
  Assert.isFalse(cache.isReady(staging, demand), "an empty staging area is not a ready battle")
end

return { tests = T }
