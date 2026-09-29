-- Script party draw routing: the script-owned host status reaches the
-- ordinary party presenter with its live plan exactly once while open,
-- and an empty or idle host draws nothing and fails nothing. Recording
-- constructor doubles stand in for GPU-backed renderers behind FakeGraphics;
-- the host, screen, manifest, and service are real. ROM-backed manifest.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GameVersion = require("romdump.src.source.GameVersion")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PartyCache = require("libs.assets.src.PartyCache")
local RomImporter = require("romdump.src.source.RomImporter")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local HOST_MODULE = "game.hgss.src.field.PartySelectionHost"
local TARGET_MODULE = "game.hgss.src.field.FieldPresentationResources"

local T = { metadata = { capabilities = { "rom_dump", "derived_assets" }, derivedAssets = { "party:global" } }, tests = {} }

local CONSTRUCTOR_MODULES = {
  "libs.assets.src.BagCache",
  "libs.assets.src.PartyCache",
  "libs.hgss.src.presentation.BagHeroRenderer",
  "libs.hgss.src.ui.BagRenderer",
  "libs.hgss.src.ui.FieldDialogueRenderer",
  "libs.hgss.src.ui.FieldMenuRenderer",
  "libs.hgss.src.ui.FieldSignpostRenderer",
  "libs.hgss.src.ui.FieldTextRenderer",
  "libs.hgss.src.presentation.FieldStaticEffectRenderer",
  "libs.hgss.src.presentation.FieldActorEmoteRenderer",
  "libs.hgss.src.presentation.FieldTerrainEffectRenderer",
  "libs.hgss.src.presentation.GpuAssetPool",
  "libs.hgss.src.presentation.FieldRenderer",
  "libs.hgss.src.ui.FieldWindowRenderer",
  "libs.hgss.src.ui.StartMenuRenderer",
  "libs.hgss.src.ui.TrainerCardRenderer",
  "libs.hgss.src.ui.PartyScreenRenderer",
  "libs.hgss.src.presentation.MonIconAssetProvider",
  "libs.hgss.src.presentation.AssetPreparationQueue",
  "libs.hgss.src.presentation.ItemIconAssetProvider",
  "libs.hgss.src.presentation.FollowingMonTransitionRenderer",
}

local function releasable(calls, name)
  return {
    release = function(_)
      calls[name] = (calls[name] or 0) + 1
    end,
  }
end

local function drawReleaser(label, sink, calls, name)
  return {
    drawPane = function(_, ...)
      sink[#sink + 1] = { label, ... }
    end,
    release = function(_)
      calls[name] = (calls[name] or 0) + 1
    end,
  }
end

local function buildDoubles(sink, calls)
  local party = drawReleaser("party", sink, calls, "party")
  return {
    ["libs.assets.src.BagCache"] = {
      loadManifest = function(_)
        return { compiled = true }
      end,
    },
    ["libs.assets.src.PartyCache"] = {
      loadManifest = function(_)
        return { compiled = true }
      end,
    },
    ["libs.hgss.src.presentation.BagHeroRenderer"] = {
      new = function(_)
        return releasable(calls, "hero")
      end,
    },
    ["libs.hgss.src.ui.BagRenderer"] = {
      new = function(_)
        return releasable(calls, "bagRenderer")
      end,
    },
    ["libs.hgss.src.ui.FieldDialogueRenderer"] = {
      new = function(_)
        return releasable(calls, "dialogue")
      end,
    },
    ["libs.hgss.src.ui.FieldMenuRenderer"] = {
      new = function(_)
        return {}
      end,
    },
    ["libs.hgss.src.ui.FieldSignpostRenderer"] = {
      new = function(_)
        return releasable(calls, "signpost")
      end,
    },
    ["libs.hgss.src.ui.FieldTextRenderer"] = {
      new = function(_)
        local instance = releasable(calls, "text")
        function instance:drawText(_, _, _) end
        function instance:drawTextWithPalette(_, _, _, _) end
        function instance:textWidth(_)
          return 0
        end
        function instance:windowBackgroundColor()
          return 0, 0, 0, 1
        end
        return instance
      end,
    },
    ["libs.hgss.src.presentation.FieldStaticEffectRenderer"] = {
      new = function(_)
        return { dispose = function(_) end }
      end,
    },
    ["libs.hgss.src.presentation.FieldActorEmoteRenderer"] = {
      new = function(_)
        return { dispose = function(_) end }
      end,
    },
    ["libs.hgss.src.presentation.FieldTerrainEffectRenderer"] = {
      new = function(_)
        return { dispose = function(_) end }
      end,
    },
    ["libs.hgss.src.presentation.GpuAssetPool"] = {
      new = function(_)
        return releasable(calls, "pool")
      end,
    },
    ["libs.hgss.src.presentation.FieldRenderer"] = {
      new = function(_)
        return releasable(calls, "renderer")
      end,
    },
    ["libs.hgss.src.ui.FieldWindowRenderer"] = {
      new = function(_)
        local instance = {}
        function instance:drawWindow(_, _, _) end
        function instance:framePalette(_)
          local palette = {}
          for slot = 0, 15 do
            palette[slot] = { r = slot, g = slot, b = slot }
          end
          return palette
        end
        function instance:drawApplicationFrame(_, _) end
        function instance:drawStandardWindow(_, _, _) end
        function instance:standardFramePalette()
          return {}
        end
        function instance:release() end
        return instance
      end,
    },
    ["libs.hgss.src.ui.StartMenuRenderer"] = {
      new = function(_)
        return releasable(calls, "menu")
      end,
    },
    ["libs.hgss.src.ui.TrainerCardRenderer"] = {
      new = function(_)
        return releasable(calls, "card")
      end,
    },
    ["libs.hgss.src.ui.PartyScreenRenderer"] = {
      new = function(_)
        return party
      end,
    },
    ["libs.hgss.src.presentation.MonIconAssetProvider"] = {
      new = function(_)
        return releasable(calls, "icons")
      end,
    },
    ["libs.hgss.src.presentation.AssetPreparationQueue"] = {
      new = function(_)
        return releasable(calls, "queue")
      end,
    },
    ["libs.hgss.src.presentation.ItemIconAssetProvider"] = {
      new = function(_)
        return releasable(calls, "itemIcons")
      end,
    },
    ["libs.hgss.src.presentation.FollowingMonTransitionRenderer"] = {
      new = function(_)
        return { dispose = function(_) end }
      end,
    },
  }
end

local function compositionRuntime()
  local runtime = {
    cacheFs = {},
    uiManifest = {},
    playerData = { options = { textFrame = 0 } },
    windowStyles = {},
    fieldEntranceIndicatorAsset = {
      model = {},
      effects = {
        surf_attachment = {
          presentation = {},
          model = {},
        },
      },
    },
    fieldEmoteModels = {},
    fieldEffectAssets = {},
    fieldTerrainEffectController = {
      setModelFactory = function(_, _) end,
    },
  }
  runtime.iconDemands = {}
  runtime.derivedAssets = {
    requestIconPage = function(pageId, urgency)
      runtime.iconDemands[#runtime.iconDemands + 1] = { pageId = pageId, urgency = urgency }
      return true
    end,
  }
  runtime.bindCalls = {}
  runtime.unbindCalls = {}
  runtime.bindPartyIconPreparation = function(_, prepare, cancel)
    runtime.bindCalls[#runtime.bindCalls + 1] = { prepare = prepare, cancel = cancel }
    return #runtime.bindCalls
  end
  runtime.unbindPartyIconPreparation = function(_, binding)
    runtime.unbindCalls[#runtime.unbindCalls + 1] = binding
  end
  return runtime
end

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cacheFs = CacheFs.forVersion(versionId)
      local marker = cacheFs:read(PartyCache.markerPath())
      if marker ~= nil and PartyCache.isReady(cacheFs, marker) then
        versions[#versions + 1] = versionId
      end
    end
  end
  return versions
end

local function openService()
  local catalog = CatalogFixture.makeCatalog()
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0xDDDDDDDD):capture(), catalog:fingerprint()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
end

local function give(service, species)
  Assert.isTrue(
    service:giveMon({
      species = species,
      level = 5,
      heldItem = "NONE",
      form = 0,
      location = 7,
      date = CatalogFixture.metDate(),
    }),
    "setup gift must enter the party"
  )
end

local function openHost(versionId, service)
  local Host = assert(require(HOST_MODULE))
  local cacheFs = CacheFs.forVersion(versionId)
  return Host.new({
    service = service,
    manifest = PartyCache.loadManifest(cacheFs),
    measureDisplay = function()
      return {
        width = 256,
        height = 192,
        topology = ScreenTopology.oneDisplay({
          id = "main",
          rect = { x = 0, y = 0, width = 256, height = 192 },
          role = "world",
          touch = true,
        }),
        pixelRatio = 1,
        signature = "stub:256x192",
      }
    end,
    uiManifest = FieldUiFixture.manifest(),
    prepareIcons = function(_)
      return true
    end,
    cancelIconPreparation = function() end,
  })
end

local function withResources(callback)
  local sink, calls = {}, {}
  local doubles = buildDoubles(sink, calls)
  local saved = {}
  for _, name in ipairs(CONSTRUCTOR_MODULES) do
    saved[name] = package.loaded[name]
    package.loaded[name] = doubles[name]
  end
  package.loaded[TARGET_MODULE] = nil
  local savedLove = rawget(_G, "love")
  rawset(_G, "love", { graphics = require("tests.support.FakeGraphics").new({}) })
  local ok, err = pcall(function()
    local Resources = require(TARGET_MODULE)
    local resources = Resources.new(compositionRuntime())
    callback(resources, sink, calls)
    resources:dispose()
  end)
  rawset(_G, "love", savedLove)
  for _, name in ipairs(CONSTRUCTOR_MODULES) do
    package.loaded[name] = saved[name]
  end
  package.loaded[TARGET_MODULE] = nil
  if not ok then
    error(err, 0)
  end
end

function T.tests.open_host_draws_once_through_the_party_presenter(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("party selection draw needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local service = openService()
    give(service, "CHIKORITA")
    give(service, "TOTODILE")
    local host = openHost(versionId, service)
    local handle = host:open({ focus = 0, allowCancel = true, policy = "occupied" })
    host:step(handle, { { type = "navigate", direction = "down" } })
    withResources(function(resources, sink)
      resources:drawScriptParty(host)
      Assert.isTrue(#sink >= 1, "an open selection draws")
      local partyDraws = {}
      for _, call in ipairs(sink) do
        if call[1] == "party" then
          partyDraws[#partyDraws + 1] = call
        end
      end
      Assert.equal(#partyDraws, 1, "exactly one party presenter draw")
      local status = host:status()
      Assert.equal(partyDraws[1][2].cursorNode, status.cursorNode, "the presenter draws the live cursor")
      Assert.equal(partyDraws[1][2].context, "pick", "the presenter draws the picking screen")
      Assert.equal(partyDraws[1][4], status.presentation.content, "the presenter draws the host plan content")
    end)
    host:close(handle)
  end
end

function T.tests.idle_and_empty_hosts_draw_nothing(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("party selection draw needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local service = openService()
    local host = openHost(versionId, service)
    withResources(function(resources, sink)
      resources:drawScriptParty(host)
      Assert.equal(#sink, 0, "an idle host draws nothing")
    end)
    local handle = host:open({ focus = 0, allowCancel = true, policy = "occupied" })
    withResources(function(resources, sink)
      resources:drawScriptParty(host)
      Assert.equal(#sink, 0, "the empty shell draws nothing and fails nothing")
    end)
    host:close(handle)
  end
end

return T
