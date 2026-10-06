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
local ItemCache = require("libs.assets.src.ItemCache")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MartCache = require("libs.assets.src.MartCache")
local MonCache = require("libs.assets.src.MonCache")
local MonCatalog = require("libs.mons.src.MonCatalog")

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
  local effects = {
    tall_grass = {},
    very_tall_grass = {},
    trainer_reveal = {},
    surf_attachment = { presentation = {} },
  }
  for selector = 1, 14 do
    effects["follower_reaction_" .. selector] = {}
  end
  return effects
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

  local weatherCalls, followerCalls = 0, 0
  local originals = {
    forVersion = CacheFs.forVersion,
    fontLoad = FieldFontLoader.load,
    weatherValidate = FieldWeatherCache.validateCatalog,
    followerValidate = FollowerInteractionCache.validateCatalog,
    monLoad = MonCache.loadCatalog,
    itemLoad = ItemCache.loadCatalog,
    itemNew = ItemCatalog.new,
    monNew = MonCatalog.new,
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
  rawset(MonCache, "loadCatalog", function()
    return { version = { language = "heartgold" } }
  end)
  rawset(ItemCache, "loadCatalog", function()
    return {}
  end)
  rawset(ItemCatalog, "new", function()
    return {}
  end)
  rawset(MonCatalog, "new", function()
    return {}
  end)
  rawset(MartCache, "loadCatalog", function()
    return {}
  end)
  rawset(FieldEntranceIndicatorRuntime, "load", function()
    return { effects = trustedEffects() }, {}
  end)
  rawset(FieldActorEmoteRuntime, "load", function()
    return { exclamation = {} }
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
  rawset(MonCache, "loadCatalog", originals.monLoad)
  rawset(ItemCache, "loadCatalog", originals.itemLoad)
  rawset(ItemCatalog, "new", originals.itemNew)
  rawset(MonCatalog, "new", originals.monNew)
  rawset(MartCache, "loadCatalog", originals.martLoad)
  rawset(FieldEntranceIndicatorRuntime, "load", originals.entranceLoad)
  rawset(FieldActorEmoteRuntime, "load", originals.emoteLoad)

  Assert.isTrue(ok, "trusted published catalogs must boot without validator proof: " .. tostring(phaseErr))
  Assert.equal(weatherCalls, 0, "the comprehensive weather validator must not run during trusted boot")
  Assert.equal(followerCalls, 0, "the comprehensive follower validator must not run during trusted boot")
  Assert.deepEqual(runtime.weatherCatalog, weatherCatalog, "the runtime retains the published weather catalog")
  Assert.deepEqual(
    runtime.followerInteractionCatalog,
    followerCatalog,
    "the runtime retains the published follower catalog"
  )
end

return { tests = T }
