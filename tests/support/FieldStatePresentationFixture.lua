-- Complete presentation cache for real FieldState construction tests: the
-- base field-UI font/frames plus the Trainer Card front, one minimal mon
-- icon class, the minimal item icon manifest/atlas and bag manifest/images
-- the eager bag presentation resources require, and the minimal field-actor
-- index/visual/atlas FieldState presentation loaders currently require.

local LuaWriter = require("libs.codec.src.LuaWriter")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local PngWriter = require("libs.assets.src.PngWriter")
local BagCache = require("libs.assets.src.BagCache")
local BagAssetSchema = require("libs.assets.src.BagAssetSchema")
local ItemCache = require("libs.assets.src.ItemCache")
local MonCache = require("libs.assets.src.MonCache")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local BagPresentationFixture = require("tests.support.BagPresentationFixture")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")

local FieldStatePresentationFixture = {}

local BAG_POCKETS = BagAssetSchema.POCKETS

---@param width integer
---@param height integer
---@return string
local function solidPng(width, height)
  local pixels = {}
  for _ = 1, width * height do
    pixels[#pixels + 1] = string.char(255, 255, 255, 255)
  end
  return PngWriter.encode(width, height, table.concat(pixels))
end

---@return CacheFs
function FieldStatePresentationFixture.cache()
  local cache = FieldUiFixture.cacheWithFontAndFrames()
  FieldUiFixture.writeStartMenuSelectorPngs(cache)
  cache:write(FieldUiFixture.TRAINER_CARD_PATH, FieldUiFixture.cardBytes())
  cache:writeLua(MonCache.iconManifestPath(), {
    schema = MonCache.ICON_MANIFEST_SCHEMA,
    version = { id = "heartgold", language = "english" },
    pages = {
      [0] = { pageId = 0, image = MonCache.iconPagePath(0), width = 256, height = 128 },
    },
    pageIds = { 0 },
    entries = {
      ["TEST/f0"] = {
        x = 0,
        y = 0,
        width = 32,
        height = 32,
        frames = { { x = 0, y = 0, width = 32, height = 32, duration = 1 } },
        pageId = 0,
      },
    },
    representative = { "TEST/f0" },
  })
  local pixels = {}
  for _ = 1, 64 * 64 do
    pixels[#pixels + 1] = string.char(255, 0, 0, 255)
  end
  cache:write(MonCache.iconPagePath(0), PngWriter.encode(64, 64, table.concat(pixels)))
  -- Minimal item icon manifest/atlas and bag manifest/images so the eager
  -- bag presentation resources resolve during FieldState construction.
  cache:writeLua(ItemCache.iconManifestPath(), {
    schema = ItemCache.ICON_MANIFEST_SCHEMA,
    atlas = ItemCache.iconImagePath(),
    entries = {
      POTION = { x = 0, y = 0, width = 32, height = 32 },
    },
    representative = { "POTION" },
  })
  cache:write(ItemCache.iconImagePath(), solidPng(64, 64))
  cache:writeLua(BagCache.manifestPath(), BagPresentationFixture.manifest())
  cache:write("assets/generated/bag/hero-male.png", solidPng(32, 32))
  cache:write("assets/generated/bag/hero-female.png", solidPng(32, 32))
  cache:write("assets/generated/bag/description-frame.png", solidPng(32, 32))
  cache:write("assets/generated/bag/hero-move-summary.png", solidPng(256, 192))
  for _, key in ipairs({
    "normal",
    "fighting",
    "flying",
    "poison",
    "ground",
    "rock",
    "bug",
    "ghost",
    "steel",
    "mystery",
    "fire",
    "water",
    "grass",
    "electric",
    "psychic",
    "ice",
    "dragon",
    "dark",
    "physical",
    "special",
    "status",
  }) do
    cache:write("assets/generated/bag/move-" .. key .. ".png", solidPng(64, 16))
  end
  for _, key in ipairs({
    "action-face",
    "quantity-increment-normal",
    "quantity-increment-pressed",
    "quantity-decrement-normal",
    "quantity-decrement-pressed",
    "quantity-confirm",
  }) do
    cache:write("assets/generated/bag/" .. key .. ".png", solidPng(64, 24))
  end
  for _, state in ipairs({ "action", "quantity", "confirmation" }) do
    for _, pocket in ipairs(BAG_POCKETS) do
      cache:write("assets/generated/bag/background-" .. state .. "-" .. pocket .. ".png", solidPng(32, 32))
    end
  end
  for _, pocket in ipairs(BAG_POCKETS) do
    for count = 0, 6 do
      cache:write("assets/generated/bag/background-browse-" .. pocket .. "-count-" .. count .. ".png", solidPng(32, 32))
    end
  end
  for _, pocket in ipairs(BAG_POCKETS) do
    cache:write("assets/generated/bag/tabs-" .. pocket .. ".png", solidPng(256, 32))
  end
  cache:write("assets/generated/bag/focus-tabs.png", solidPng(32, 32))
  cache:write("assets/generated/bag/focus-items.png", solidPng(32, 32))
  cache:write("assets/generated/bag/focus-cancel.png", solidPng(32, 32))
  cache:write("assets/generated/bag/focus-actions.png", solidPng(32, 32))
  cache:write("assets/generated/bag/registration-slot-1.png", solidPng(40, 16))
  cache:write("assets/generated/bag/registration-slot-2.png", solidPng(40, 16))
  cache:write(
    FieldActorCache.indexPath(),
    LuaWriter.encode({ schema = FieldActorCache.INDEX_SCHEMA, spriteIds = { 0 } })
  )
  cache:writeLua(FieldActorCache.visualPath(0), FieldActorFixture.visual(0))
  cache:write(FieldActorCache.atlasPath(0), FieldDialogueFixture.atlasBytes())
  return cache
end

-- The terrain-effect bundle the real terrain renderer acquires during the
-- boot: one synthetic triangle mesh per effect kind, written into the same
-- presentation cache the boot reads through.
---@param cache CacheFs
---@return table<string, table<string, unknown>>
function FieldStatePresentationFixture.terrainEffects(cache)
  cache:write(
    "test/terrain-grass.mesh",
    MeshWriter.encode({
      vertices = {
        {
          x = 0,
          y = 0,
          z = 0,
          u = 0,
          v = 0,
          nx = 0,
          ny = 1,
          nz = 0,
          r = 255,
          g = 255,
          b = 255,
          a = 255,
          colorSource = 0,
        },
        {
          x = 1,
          y = 0,
          z = 0,
          u = 1,
          v = 0,
          nx = 0,
          ny = 1,
          nz = 0,
          r = 255,
          g = 255,
          b = 255,
          a = 255,
          colorSource = 0,
        },
        {
          x = 0,
          y = 0,
          z = 1,
          u = 0,
          v = 1,
          nx = 0,
          ny = 1,
          nz = 0,
          r = 255,
          g = 255,
          b = 255,
          a = 255,
          colorSource = 0,
        },
      },
      indices = { 0, 1, 2 },
    })
  )
  local function effect()
    return {
      model = {
        dynamic = {
          nodes = {
            { name = "root", translation = { 0, 0, 0 }, rotation = { 0, 0, 0 }, scale = { 1, 1, 1 } },
          },
          batches = {
            {
              id = "grass",
              nodeIndex = 0,
              materialIndex = 0,
              geometry = "test/terrain-grass.mesh",
              alphaClass = "cutout",
              cullMode = "back",
              polygonAlpha = 31,
              polygonMode = "modulation",
              polygonId = 0,
              translucentDepthWrite = false,
              depthEqual = false,
              lightMask = 15,
              fogEnabled = false,
            },
          },
        },
        materials = { { id = 0, name = "grass", wrap = { x = "clamp", y = "clamp" } } },
        animations = {},
      },
      placementOffset = { x = 0, y = 0, z = 0 },
    }
  end
  return {
    tall_grass = effect(),
    very_tall_grass = effect(),
    trainer_reveal = effect(),
  }
end

-- Explicit headless semantic host for presentation fixtures: mirrors the
-- production derived-asset shapes, records every demand in the returned log,
-- and reports ready without compiling, decoding, or touching the GPU.
-- Fixtures boot from prepared caches where demanded artifacts are already
-- compiled, so ready mirrors successful reuse; demand stays visible in the
-- log instead of silently succeeding, so blanket enrollment would fail loudly.
---@return { derivedAssets: table<string, function>, demands: table<integer, table<string, unknown>> }
function FieldStatePresentationFixture.iconHost()
  local host = { demands = {} }
  local function note(kind, detail)
    host.demands[#host.demands + 1] = { kind = kind, detail = detail }
  end
  host.derivedAssets = {
    requestMilestone = function(name, _)
      note("milestone", name)
      return true
    end,
    milestoneStatus = function(name)
      note("milestone-status", name)
      return { state = "ready", ready = 1, total = 1, failure = nil }
    end,
    requestField = function(mapId, _)
      note("field", mapId)
      return true
    end,
    requestLogicalField = function(mapId, _)
      note("logical-field", mapId)
      return true
    end,
    ensureLogicalField = function(mapId)
      note("ensure-logical-field", mapId)
      return true
    end,
    ensureField = function(mapId)
      note("ensure-field", mapId)
      return true
    end,
    requestCell = function(descriptor, _)
      note("cell", descriptor)
      return true
    end,
    ensureCell = function(descriptor)
      note("ensure-cell", descriptor)
      return true
    end,
    requestMonPortraitPage = function(pageId, _)
      note("portrait", pageId)
      return true
    end,
    requestIconPage = function(pageId, urgency)
      assert(type(pageId) == "number", "icon demand carries its page")
      note("icon-page", { pageId = pageId, urgency = urgency })
      return true
    end,
    status = function()
      return { bootstrap = "ready" }
    end,
  }
  return host
end

return FieldStatePresentationFixture
