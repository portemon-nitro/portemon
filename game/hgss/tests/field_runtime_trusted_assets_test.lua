-- Field asset trust: the runtime asset phase loads published generated catalogs
-- without rerunning their comprehensive validators. Producer compilation and
-- explicit audit remain the only owners of whole-payload validation.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldActorEmoteRuntime = require("game.hgss.src.field.FieldActorEmoteRuntime")
local FieldCameraCache = require("libs.assets.src.field.FieldCameraCache")
local FieldEntranceIndicatorRuntime = require("game.hgss.src.field.FieldEntranceIndicatorRuntime")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldWeatherCache = require("libs.assets.src.field.FieldWeatherCache")
local FollowerInteractionCache = require("libs.assets.src.field.FollowerInteractionCache")
local ItemAssetSchema = require("libs.assets.src.ItemAssetSchema")
local ItemCache = require("libs.assets.src.ItemCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MartCache = require("libs.assets.src.MartCache")
local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
local MonCache = require("libs.assets.src.MonCache")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")

local T = {}

local function structuralWorld()
  local record = {
    id = 60,
    symbol = "MAP_NEW_BARK",
    mapSection = "NEW BARK TOWN",
    mapSectionNativeId = 1,
    followMode = "ALLOW",
    worldOriginX = 0,
    worldOriginZ = 0,
    matrix = { memberId = 0 },
  }
  return {
    schema = MapAssetCache.WORLD_SCHEMA,
    maps = { record },
    byId = { [60] = 1 },
    bySymbol = { MAP_NEW_BARK = 60 },
    analysis = { mapHeaderCount = 1, excluded = {} },
  }
end

local function actorIndex()
  return {
    runtime = {
      avatars = {
        { id = "hero", gender = 0, states = { walking = 0 } },
        { id = "heroine", gender = 1, states = { walking = 97 } },
      },
      variableSprites = {},
    },
  }
end

local function trustedEffects()
  return {
    tall_grass = {},
    very_tall_grass = {},
    trainer_reveal = {},
    surf_attachment = { presentation = {} },
  }
end

function T.runtime_assets_phase_trusts_published_catalogs_without_revalidating()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(FieldActorCache.indexPath(), actorIndex())
  cache:writeLua(FieldUiAssetCache.manifestPath(), FieldUiFixture.manifest())
  cache:writeLua(MapAssetCache.worldPath(), structuralWorld())
  cache:writeLua(FieldCameraCache.profilesPath(), { schema = FieldCameraCache.SCHEMA, profiles = {} })
  local weatherCatalog = { schema = FieldWeatherCache.SCHEMA, presets = {}, rules = {} }
  cache:writeLua(FieldWeatherCache.catalogPath(), weatherCatalog)
  local followerCatalog = { schema = FollowerInteractionCache.SCHEMA, version = "heartgold" }
  cache:writeLua(FollowerInteractionCache.catalogPath(), followerCatalog)

  -- Real published roots at their real cache paths. They are built before
  -- the comprehensive validators below are replaced with throwing doubles,
  -- because fixture construction itself proves the canonical root contract.
  local monRoot = CatalogFixture.buildAssetRoot()
  local itemRoot = ItemFixture.buildAssetRoot()
  cache:writeLua(MonCache.catalogPath(), monRoot)
  cache:writeLua(ItemCache.catalogPath(), itemRoot)

  local weatherCalls, followerCalls = 0, 0
  local monValidatorCalls, itemValidatorCalls = 0, 0
  local originals = {
    forVersion = CacheFs.forVersion,
    fontLoad = FieldFontLoader.load,
    weatherValidate = FieldWeatherCache.validateCatalog,
    followerValidate = FollowerInteractionCache.validateCatalog,
    monValidate = MonAssetSchema.assertCatalog,
    itemValidate = ItemAssetSchema.assertCatalog,
    martLoad = MartCache.loadCatalog,
    entranceLoad = FieldEntranceIndicatorRuntime.load,
    emoteLoad = FieldActorEmoteRuntime.load,
  }
  rawset(CacheFs, "forVersion", function()
    return cache
  end)
  rawset(FieldFontLoader, "load", function()
    return { charmap = {} }
  end)
  rawset(FieldWeatherCache, "validateCatalog", function()
    weatherCalls = weatherCalls + 1
    error("published weather catalogs must not be revalidated at runtime", 0)
  end)
  rawset(FollowerInteractionCache, "validateCatalog", function()
    followerCalls = followerCalls + 1
    error("published follower catalogs must not be revalidated at runtime", 0)
  end)
  -- The cache loaders and catalog constructors under test stay real: the
  -- phase must prove the production loader-to-constructor chain reaches
  -- live catalogs without comprehensive validation.
  rawset(MonAssetSchema, "assertCatalog", function()
    monValidatorCalls = monValidatorCalls + 1
    error("published mon catalogs must not be revalidated at runtime", 0)
  end)
  rawset(ItemAssetSchema, "assertCatalog", function()
    itemValidatorCalls = itemValidatorCalls + 1
    error("published item catalogs must not be revalidated at runtime", 0)
  end)
  rawset(MartCache, "loadCatalog", function()
    return {}
  end)
  rawset(FieldEntranceIndicatorRuntime, "load", function()
    return { effects = trustedEffects() }, {}
  end)
  rawset(FieldActorEmoteRuntime, "load", function()
    return { exclamation = {} }, {}
  end)

  local runtime = setmetatable({
    versionId = "heartgold",
    presentation = false,
    derivedAssets = {},
  }, FieldRuntime)
  local ok, phaseErr = pcall(FieldRuntime._loadRuntimeAssets, runtime, {})
  rawset(CacheFs, "forVersion", originals.forVersion)
  rawset(FieldFontLoader, "load", originals.fontLoad)
  rawset(FieldWeatherCache, "validateCatalog", originals.weatherValidate)
  rawset(FollowerInteractionCache, "validateCatalog", originals.followerValidate)
  rawset(MonAssetSchema, "assertCatalog", originals.monValidate)
  rawset(ItemAssetSchema, "assertCatalog", originals.itemValidate)
  rawset(MartCache, "loadCatalog", originals.martLoad)
  rawset(FieldEntranceIndicatorRuntime, "load", originals.entranceLoad)
  rawset(FieldActorEmoteRuntime, "load", originals.emoteLoad)

  Assert.isTrue(ok, "trusted published catalogs must boot without validator proof: " .. tostring(phaseErr))
  Assert.equal(weatherCalls, 0, "the comprehensive weather validator must not run during trusted boot")
  Assert.equal(followerCalls, 0, "the comprehensive follower validator must not run during trusted boot")
  Assert.equal(monValidatorCalls, 0, "the comprehensive mon validator must not run during trusted boot")
  Assert.equal(itemValidatorCalls, 0, "the comprehensive item validator must not run during trusted boot")
  Assert.equal(
    runtime.monCatalog:species("CHIKORITA").nativeId,
    152,
    "the runtime keeps the live mon catalog behind the trusted load"
  )
  Assert.equal(
    runtime.itemCatalog:item("POKE_BALL").nativeId,
    4,
    "the runtime keeps the live item catalog behind the trusted load"
  )
  Assert.equal(runtime.monLanguage, "english", "the runtime keeps the published mon language")
  Assert.deepEqual(runtime.weatherCatalog, weatherCatalog, "the runtime retains the published weather catalog")
  Assert.deepEqual(
    runtime.followerInteractionCatalog,
    followerCatalog,
    "the runtime retains the published follower catalog"
  )
end

return { tests = T }
