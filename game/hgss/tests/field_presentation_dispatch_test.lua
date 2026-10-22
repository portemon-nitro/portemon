-- Application presentation dispatch: the production-built per-instance
-- presenter map routes each presentable application id to its concrete
-- renderer, faults on an unknown id instead of falling back to another
-- surface, and releases owned resources exactly once. Pokemon, Trainer
-- Card, and Bag are all explicitly mapped through the real
-- FieldPresentationResources composition; draws borrow the composed
-- resources and never acquire them.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FakeCache = require("tests.support.FakeCache")
local FakeGraphics = require("tests.support.FakeGraphics")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local FieldPresentationResources = require("game.hgss.src.field.FieldPresentationResources")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCache = require("libs.assets.src.MonCache")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PcApplicationHost = require("game.hgss.src.pc.PcApplicationHost")
local PcPresentationFixture = require("tests.support.PcPresentationFixture")
local PcStorageRenderer = require("libs.hgss.src.ui.PcStorageRenderer")
local PcStorageState = require("game.hgss.src.pc.StorageScreenState")
local PngWriter = require("libs.assets.src.PngWriter")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SharedImagePoolFake = require("tests.support.SharedImagePoolFake")

local T = {}

local TARGET_MODULE = "game.hgss.src.field.FieldPresentationResources"

local CONSTRUCTOR_MODULES = {
  "libs.assets.src.BagCache",
  "libs.assets.src.MartCache",
  "libs.assets.src.PartyCache",
  "libs.assets.src.PcCache",
  "libs.assets.src.SummaryCache",
  "libs.hgss.src.presentation.BagHeroRenderer",
  "libs.hgss.src.ui.BagRenderer",
  "libs.hgss.src.ui.MartRenderer",
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
  "libs.hgss.src.ui.NamingScreenRenderer",
  "libs.hgss.src.ui.PcStorageRenderer",
  "libs.hgss.src.ui.MailboxRenderer",
  "libs.hgss.src.ui.PhotoAlbumRenderer",
  "libs.hgss.src.presentation.MonIconAssetProvider",
  "libs.hgss.src.presentation.AssetPreparationQueue",
  "libs.hgss.src.presentation.ItemIconAssetProvider",
  "libs.hgss.src.presentation.FollowingMonTransitionRenderer",
  "game.hgss.src.field.SummaryPresentationResources",
}

local function releasable(calls, name)
  return {
    release = function(_)
      calls[name] = (calls[name] or 0) + 1
    end,
  }
end

local function disposable(calls, name)
  return {
    dispose = function(_)
      calls[name] = (calls[name] or 0) + 1
    end,
  }
end

local function drawReleaser(label, sink, calls, name)
  return {
    draw = function(_, ...)
      sink[#sink + 1] = { label, ... }
    end,
    release = function(_)
      calls[name] = (calls[name] or 0) + 1
    end,
  }
end

local function buildDoubles(sink, calls)
  local party = drawReleaser("party", sink, calls, "party")
  local card = drawReleaser("card", sink, calls, "card")
  local bag = drawReleaser("bag", sink, calls, "bag")
  return {
    ["libs.assets.src.MartCache"] = {
      loadManifest = function(_)
        return { compiled = true }
      end,
    },
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
    ["libs.assets.src.PcCache"] = {
      loadManifest = function(_)
        return { storage = {}, mailbox = {}, photoAlbum = {} }
      end,
    },
    ["libs.assets.src.SummaryCache"] = {
      loadManifest = function(_)
        return { summaryDispatchManifest = true }
      end,
    },
    -- The summary preparation owner stays a recording stub: dispatch
    -- coverage owns presenter routing, while the required owner itself
    -- is proven with real collaborators in the summary composition
    -- suite. The stub still installs exactly one owner plus one runtime
    -- binding, so construction never runs without the capability.
    ["game.hgss.src.field.SummaryPresentationResources"] = {
      new = function(opts)
        calls.summaryOwnerConstructed = (calls.summaryOwnerConstructed or 0) + 1
        calls.summaryOwnerManifest = opts and opts.manifest
        local owner = {}
        function owner:acquire()
          calls.summaryLeases = (calls.summaryLeases or 0) + 1
          return {
            release = function(_)
              calls.summaryLeaseReleases = (calls.summaryLeaseReleases or 0) + 1
            end,
          }
        end
        function owner:release()
          calls.summaryOwner = (calls.summaryOwner or 0) + 1
        end
        return owner
      end,
    },
    ["libs.hgss.src.presentation.BagHeroRenderer"] = {
      new = function(_)
        return releasable(calls, "hero")
      end,
    },
    ["libs.hgss.src.ui.BagRenderer"] = {
      new = function(opts)
        calls.bagOpts = opts
        -- Preparation recorder: the field update advances Bag leaves
        -- outside drawing, so the double tracks every prepared leaf while
        -- drawing stays a pure sink record like the other presenters.
        calls.bagPrepareLeaves = calls.bagPrepareLeaves or {}
        function bag:prepare(leaf)
          calls.bagPrepareLeaves[#calls.bagPrepareLeaves + 1] = leaf
          calls.bagPrepares = (calls.bagPrepares or 0) + 1
          if calls.bagPrepareReady == false then
            return false, calls.bagPrepareFailure
          end
          return true
        end
        return bag
      end,
    },
    ["libs.hgss.src.ui.MartRenderer"] = {
      new = function(_)
        return drawReleaser("mart", sink, calls, "mart")
      end,
    },
    ["libs.hgss.src.ui.FieldDialogueRenderer"] = {
      new = function(opts)
        calls.dialogueWindow = opts and opts.windowRenderer
        calls.dialogueImagePool = opts and opts.imagePool
        return releasable(calls, "dialogue")
      end,
    },
    ["libs.hgss.src.ui.FieldWindowRenderer"] = {
      new = function(_)
        calls.window = (calls.window or 0) + 1
        local instance = {}
        function instance:drawWindow(_, _, _) end
        function instance:framePalette(_)
          local palette = {}
          for slot = 0, 15 do
            palette[slot] = { r = slot, g = slot, b = slot }
          end
          return palette
        end
        function instance:drawStandardWindow(_, _) end
        function instance:standardFramePalette()
          return self:framePalette(0)
        end
        function instance:drawApplicationFrame(box, frameIndex)
          sink[#sink + 1] = { "frame", box, frameIndex }
        end
        function instance:release()
          calls.windowReleased = (calls.windowReleased or 0) + 1
        end
        calls.windowInstance = instance
        return instance
      end,
    },
    ["libs.hgss.src.ui.FieldMenuRenderer"] = {
      new = function(_)
        return {}
      end,
    },
    ["libs.hgss.src.ui.FieldSignpostRenderer"] = {
      new = function(opts)
        calls.signpostImagePool = opts and opts.imagePool
        return releasable(calls, "signpost")
      end,
    },
    ["libs.hgss.src.ui.FieldTextRenderer"] = {
      new = function(_)
        local text = releasable(calls, "text")
        text.fontDef = {
          palette = {
            [2] = { r = 1, g = 2, b = 3 },
            [3] = { r = 4, g = 5, b = 6 },
            [16] = { r = 7, g = 8, b = 9 },
          },
        }
        function text:drawText(content, x, y)
          sink[#sink + 1] = { "text", content, x, y }
        end
        function text:drawTextWithPalette(_, _, _, _) end
        function text:windowBackgroundColor()
          return 0, 0, 0, 1
        end
        return text
      end,
    },
    ["libs.hgss.src.presentation.FieldStaticEffectRenderer"] = {
      new = function(_)
        return disposable(calls, "staticEffect")
      end,
    },
    ["libs.hgss.src.presentation.FieldActorEmoteRenderer"] = {
      new = function(_)
        return disposable(calls, "emote")
      end,
    },
    ["libs.hgss.src.presentation.FieldTerrainEffectRenderer"] = {
      new = function(_)
        return disposable(calls, "terrain")
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
    ["libs.hgss.src.ui.StartMenuRenderer"] = {
      new = function(_)
        return releasable(calls, "menu")
      end,
    },
    ["libs.hgss.src.ui.TrainerCardRenderer"] = {
      new = function(opts)
        calls.cardImagePool = opts and opts.imagePool
        return card
      end,
    },
    ["libs.hgss.src.ui.PartyScreenRenderer"] = {
      new = function(_)
        return party
      end,
    },
    ["libs.hgss.src.ui.NamingScreenRenderer"] = {
      new = function(options)
        calls.namingConstructed = (calls.namingConstructed or 0) + 1
        calls.namingDrawSubject = options.drawSubject
        return {
          dispose = function(_)
            calls.namingDisposed = (calls.namingDisposed or 0) + 1
            calls.iconProviderReleasedDuringNamingDispose = calls.icons
            calls.namingImageReleased = (calls.namingImageReleased or 0) + 1
          end,
        }
      end,
    },
    ["libs.hgss.src.ui.PcStorageRenderer"] = {
      new = function(_)
        local renderer = releasable(calls, "pcStorage")
        -- Preparation recorder: the field update admits Storage visuals
        -- beside mon icons, so the double tracks every prepared view.
        calls.pcStorageViews = calls.pcStorageViews or {}
        function renderer:prepare(view)
          calls.pcStorageViews[#calls.pcStorageViews + 1] = view
          if calls.pcStoragePrepareReady == false then
            return false, calls.pcStoragePrepareFailure
          end
          return true
        end
        -- The double tracks the explicit install beside preparation: the
        -- real renderer stages on prepare and installs only on commit.
        calls.pcStorageCommits = calls.pcStorageCommits or {}
        function renderer:commitPrepared(view)
          calls.pcStorageCommits[#calls.pcStorageCommits + 1] = view
        end
        return renderer
      end,
    },
    ["libs.hgss.src.ui.MailboxRenderer"] = {
      new = function(_)
        return releasable(calls, "mailbox")
      end,
    },
    ["libs.hgss.src.ui.PhotoAlbumRenderer"] = {
      new = function(_)
        local renderer = releasable(calls, "photoAlbum")
        function renderer:advance(_, _)
          calls.photoAlbumAdvanced = (calls.photoAlbumAdvanced or 0) + 1
          return true, nil
        end
        function renderer:draw(_, _, _)
          calls.photoAlbumDrawn = (calls.photoAlbumDrawn or 0) + 1
        end
        return renderer
      end,
    },
    ["libs.hgss.src.presentation.MonIconAssetProvider"] = {
      new = function(_)
        local provider = releasable(calls, "icons")
        function provider:dimensions(iconKey)
          calls.iconDimensions = iconKey
          return { width = 32, height = 32 }
        end
        function provider:image()
          return "borrowed-icon-image"
        end
        -- Eager-shaped borrow: the lease surface records the raw draw
        -- through the injected graphics double, exactly like the
        -- retired direct image draw.
        function provider:handleFor(_)
          calls.iconImage = (calls.iconImage or 0) + 1
          local handle = { image = "borrowed-icon-image", kind = "rgba8" }
          function handle:drawQuad(graphics, quad, x, y, ...)
            graphics.draw(self.image, quad, x, y, ...)
          end
          return handle
        end
        function provider:prepareKeys(iconKeys)
          calls.iconPrepareCalls = (calls.iconPrepareCalls or 0) + 1
          calls.iconKeys = iconKeys
          local ready = calls.iconPageReady ~= false
          if ready then
            return true, nil
          end
          return false, calls.iconPageFailure
        end
        function provider:quadFor(iconKey, frameIndex)
          assert(calls.iconPageReady, "naming cannot request an icon quad before its page is ready")
          calls.iconQuadCount = (calls.iconQuadCount or 0) + 1
          calls.iconQuad = { iconKey = iconKey, frameIndex = frameIndex }
          return { key = iconKey, frameIndex = frameIndex }
        end
        return provider
      end,
    },
    ["libs.hgss.src.presentation.ItemIconAssetProvider"] = {
      new = function(_)
        return releasable(calls, "itemIcons")
      end,
    },
    ["libs.hgss.src.presentation.AssetPreparationQueue"] = {
      new = function(_)
        return releasable(calls, "queue")
      end,
    },
    ["libs.hgss.src.presentation.FollowingMonTransitionRenderer"] = {
      new = function(_)
        return disposable(calls, "transition")
      end,
    },
  }
end

-- The minimal production-shaped runtime the real presentation constructor
-- reads. Follower-transition composition stays disabled by leaving its
-- definition and controller nil, the same as a definition-less composition.
local function compositionRuntime()
  local runtime = {
    cacheFs = {},
    uiManifest = {
      namingScreen = {
        pokemonSubject = {
          frames = {
            { parts = { { iconFrame = 1 } } },
            { parts = { { iconFrame = 1 } } },
          },
        },
      },
    },
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
    -- The presentation composition borrows its session image owner for
    -- icons, Summary, and PC visuals: the injected pool keeps the
    -- composition honest without a second worker beside the doubles.
    imageAssets = SharedImagePoolFake.new(),
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
  -- The recording summary seam mirrors the production runtime binding:
  -- one live acquire callback with an identity, removed only by its own
  -- identity so a stale unbind can never drop a replacement owner.
  runtime.summaryBindCalls = {}
  runtime.summaryUnbindCalls = {}
  runtime.bindSummaryPreparation = function(_, acquire)
    assert(type(acquire) == "function", "summary preparation binding requires its acquire function")
    assert(runtime.summaryPreparation == nil, "one summary preparation binding owns the presented lifetime")
    runtime.summaryBindCalls[#runtime.summaryBindCalls + 1] = acquire
    runtime.summaryPreparation = { id = #runtime.summaryBindCalls, acquire = acquire }
    return runtime.summaryPreparation.id
  end
  runtime.unbindSummaryPreparation = function(_, binding)
    runtime.summaryUnbindCalls[#runtime.summaryUnbindCalls + 1] = binding
    local current = runtime.summaryPreparation
    if current ~= nil and current.id == binding then
      runtime.summaryPreparation = nil
    end
  end
  -- The recording pokedex seam mirrors the production runtime binding:
  -- one live acquire callback with an identity, removed only by its own
  -- identity so a stale unbind can never drop a replacement owner.
  runtime.pokedexBindCalls = {}
  runtime.pokedexUnbindCalls = {}
  runtime.bindPokedexPreparation = function(_, acquire)
    assert(type(acquire) == "function", "pokedex preparation binding requires its acquire function")
    assert(runtime.pokedexPreparation == nil, "one pokedex preparation binding owns the presented lifetime")
    runtime.pokedexBindCalls[#runtime.pokedexBindCalls + 1] = acquire
    runtime.pokedexPreparation = { id = #runtime.pokedexBindCalls, acquire = acquire }
    return runtime.pokedexPreparation.id
  end
  runtime.unbindPokedexPreparation = function(_, binding)
    runtime.pokedexUnbindCalls[#runtime.pokedexUnbindCalls + 1] = binding
    local current = runtime.pokedexPreparation
    if current ~= nil and current.id == binding then
      runtime.pokedexPreparation = nil
    end
  end
  return runtime
end

---@param viewport table?
---@return table
local function drawRuntime(viewport)
  return {
    viewport = viewport,
    fieldPixelScale = {
      resolvedScale = function(_)
        return 1
      end,
    },
  }
end

-- Installs recording constructor doubles, requires the real presentation
-- composition fresh, builds it through FieldPresentationResources.new, and
-- runs the callback against the production-built presenter map. Every
-- replaced module entry is restored even when the callback fails.
local function withProductionComposition(sink, calls, runtime, callback)
  local doubles = buildDoubles(sink, calls)
  local saved = {}
  for _, name in ipairs(CONSTRUCTOR_MODULES) do
    saved[name] = package.loaded[name]
    package.loaded[name] = doubles[name]
  end
  package.loaded[TARGET_MODULE] = nil
  local ok, err = pcall(function()
    local FieldPresentationResources = require(TARGET_MODULE)
    local resources = FieldPresentationResources.new(runtime)
    callback(resources)
  end)
  for _, name in ipairs(CONSTRUCTOR_MODULES) do
    package.loaded[name] = saved[name]
  end
  package.loaded[TARGET_MODULE] = nil
  if not ok then
    error(err, 0)
  end
end

function T.pokemon_routes_only_to_the_party_presenter()
  local sink, calls = {}, {}
  local savedLove = rawget(_G, "love")
  rawset(_G, "love", { graphics = require("tests.support.FakeGraphics").new({}) })
  local ok, err = pcall(function()
    withProductionComposition(sink, calls, compositionRuntime(), function(resources)
      local presentation = {
        presentation = {
          panes = {},
          content = {},
          inputKey = "party",
          render = function(borrowed, view, plan)
            assert(borrowed.partyScreenRenderer, "the party render borrows its renderer"):draw(
              view,
              plan,
              borrowed.icons
            )
          end,
          mapInput = function()
            return nil
          end,
          frames = {},
        },
      }
      resources:drawApplication(FieldApplicationIds.POKEMON, presentation, drawRuntime())
      Assert.equal(#sink, 1, "exactly one presenter draws")
      Assert.equal(sink[1][1], "party", "the Pokemon application draws through the party renderer")
      Assert.equal(sink[1][2], presentation, "the presenter receives the host application presentation")
      Assert.equal(sink[1][3], presentation.presentation, "the party presenter draws through the application plan")
      Assert.equal(sink[1][4], resources.monIconProvider, "the party presenter borrows the shared icon provider")
      Assert.isNil(calls.icons, "drawing never releases the borrowed icon provider")
      resources:dispose()
    end)
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

function T.script_party_draw_reuses_the_pokemon_presenter_without_stepping()
  local sink, calls = {}, {}
  local savedLove = rawget(_G, "love")
  rawset(_G, "love", { graphics = require("tests.support.FakeGraphics").new({}) })
  local ok, err = pcall(function()
    withProductionComposition(sink, calls, compositionRuntime(), function(resources)
      local plan = {
        panes = {},
        content = {},
        inputKey = "party",
        render = function(borrowed, view, drawing)
          assert(borrowed.partyScreenRenderer, "the party render borrows its renderer"):draw(
            view,
            drawing,
            borrowed.icons
          )
        end,
        mapInput = function()
          return nil
        end,
        frames = {},
      }
      local active = {
        status = function()
          return { presentation = plan }
        end,
      }
      resources:drawScriptParty(active)
      Assert.equal(#sink, 1, "an active script selection draws exactly once")
      Assert.equal(sink[1][1], "party", "script selection reuses the menu party renderer")
      local idle = {
        status = function()
          return nil
        end,
      }
      resources:drawScriptParty(idle)
      Assert.equal(#sink, 1, "an idle host draws nothing and fails nothing")
      resources:dispose()
    end)
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

function T.mon_naming_renderer_is_prepared_lazily_and_borrows_shared_mon_icons()
  local sink, calls = {}, {}
  local savedLove = rawget(_G, "love")
  rawset(_G, "love", { graphics = require("tests.support.FakeGraphics").new({}) })
  local ok, err = pcall(function()
    -- Naming chrome borrows the session image owner like production:
    -- the stub answers ready borrows without decoding.
    local runtime = compositionRuntime()
    local poolTokens = 0
    runtime.imageAssets = {
      request = function(_, _, _, _)
        poolTokens = poolTokens + 1
        return poolTokens
      end,
      poll = function(_)
        return "ready"
      end,
      acquire = function(_)
        return { image = { stubPoolImage = true } }
      end,
      release = function(_) end,
      cancel = function(_)
        return false
      end,
    }
    withProductionComposition(sink, calls, runtime, function(resources)
      Assert.isNil(calls.namingConstructed, "ordinary field construction does not acquire naming chrome")
      Assert.isNil(calls.iconImage, "ordinary field construction does not acquire naming images")
      Assert.isNil(calls.iconQuadCount, "ordinary field construction does not acquire naming quads")

      calls.iconPageReady = false
      local ready, failure = resources:prepareMonNamingSubject({ iconKey = "species:1:form:0" })
      Assert.isFalse(ready, "pending mon icon pages keep naming preparation pending")
      Assert.isNil(failure, "pending mon icon pages have no failure")
      Assert.isNil(calls.namingConstructed, "pending preparation creates no naming renderer")
      Assert.isNil(calls.iconQuadCount, "pending preparation creates no icon quads")

      calls.iconPageFailure = "page failed"
      ready, failure = resources:prepareMonNamingSubject({ iconKey = "species:1:form:0" })
      Assert.isFalse(ready, "failed mon icon pages do not prepare naming")
      Assert.equal(failure, "page failed", "provider failure is returned unchanged")
      Assert.isNil(calls.namingConstructed, "failed preparation creates no naming renderer")
      Assert.isNil(calls.iconQuadCount, "failed preparation creates no icon quads")

      calls.iconPageReady = true
      ready, failure = resources:prepareMonNamingSubject({ iconKey = "species:1:form:0" })
      Assert.isTrue(ready, "a ready icon page prepares naming")
      Assert.isNil(failure, "ready preparation has no failure")
      Assert.equal(calls.namingConstructed, 1, "first ready preparation creates naming renderer once")
      Assert.equal(calls.iconDimensions, "species:1:form:0", "the naming subject resolves through shared mon icons")
      resources:monNamingRenderer()
      Assert.equal(calls.namingConstructed, 1, "the renderer accessor is a pure read")
      resources:prepareMonNamingSubject({ iconKey = "species:1:form:0" })
      resources:prepareMonNamingSubject({ iconKey = "species:2:form:0" })
      Assert.equal(calls.namingConstructed, 1, "repeated and new icon demands reuse the renderer")
      Assert.equal(calls.iconQuadCount, 2, "each icon key prepares its borrowed semantic quad")
      local drawCalls = {}
      calls.namingDrawSubject({
        draw = function(image, quad, x, y, rotation, scaleX, scaleY)
          drawCalls[#drawCalls + 1] = { image, quad, x, y, rotation, scaleX, scaleY }
        end,
      }, { iconKey = "species:1:form:0" }, { x = 24, y = 8, frameIndex = 1 })
      Assert.equal(calls.iconImage, 1, "the semantic part draws the shared provider image")
      Assert.equal(#drawCalls, 1, "the naming subject draws one semantic placement")
      Assert.equal(drawCalls[1][1], "borrowed-icon-image", "the icon image comes from the shared provider")
      Assert.isNil(calls.icons, "using the naming renderer never releases the borrowed icon provider")

      resources:dispose()
      Assert.equal(calls.namingDisposed, 1, "field resources dispose their naming renderer once")
      Assert.equal(calls.namingImageReleased, 1, "naming disposal releases its owned image")
      Assert.isNil(
        calls.iconProviderReleasedDuringNamingDispose,
        "naming renderer disposal leaves its borrowed icon provider to the field owner"
      )
      Assert.equal(calls.icons, 1, "field resources release the borrowed icon provider once")
    end)
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

function T.unprepared_naming_renderer_is_not_disposed()
  local sink, calls = {}, {}
  withProductionComposition(sink, calls, compositionRuntime(), function(resources)
    Assert.isNil(calls.namingConstructed, "naming chrome remains uncreated without demand")
    resources:dispose()
    Assert.isNil(calls.namingDisposed, "disposal skips a renderer that was never created")
  end)
end

function T.trainer_card_routes_only_to_the_card_presenter()
  local PixelScale = require("libs.ui.src.PixelScale")
  local sink, calls = {}, {}
  local savedLove = rawget(_G, "love")
  rawset(_G, "love", { graphics = require("tests.support.FakeGraphics").new({}) })
  local ok, err = pcall(function()
    withProductionComposition(sink, calls, compositionRuntime(), function(resources)
      local presentation = {
        presentation = {
          panes = {
            {
              id = "content",
              placement = assert(
                PixelScale.placeFixed({ x = 0, y = 0, width = 256, height = 192 }, 256, 192),
                "the probe host must admit a card placement"
              ),
              interactive = true,
            },
          },
          content = {},
          inputKey = "trainer-card",
          render = function(borrowed, view, plan)
            assert(borrowed.trainerCardRenderer, "the card render borrows its renderer"):draw(
              view,
              assert(plan.panes[1] and plan.panes[1].placement, "the card pane carries its placement")
            )
          end,
          mapInput = function()
            return nil
          end,
          frames = {},
        },
      }
      resources:drawApplication(FieldApplicationIds.TRAINER_CARD, presentation, drawRuntime())
      Assert.equal(#sink, 1, "exactly one presenter draws")
      Assert.equal(sink[1][1], "card", "the Trainer Card application draws through the card renderer")
      Assert.equal(sink[1][2], presentation, "the presenter receives the host application presentation")
      Assert.equal(
        sink[1][3],
        presentation.presentation.panes[1].placement,
        "the card presenter draws through the planned pane placement"
      )
      Assert.isNil(calls.card, "drawing never releases the borrowed card renderer")
      resources:dispose()
    end)
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

function T.bag_routes_only_to_the_bag_presenter()
  local sink, calls = {}, {}
  local savedLove = rawget(_G, "love")
  rawset(_G, "love", { graphics = require("tests.support.FakeGraphics").new({}) })
  local ok, err = pcall(function()
    withProductionComposition(sink, calls, compositionRuntime(), function(resources)
      local presentation = {
        presentation = {
          panes = {},
          content = {},
          inputKey = "bag",
          render = function(borrowed, view, plan)
            assert(borrowed.bagRenderer, "the bag render borrows its renderer"):draw(view, plan, {
              icons = borrowed.icons,
            })
          end,
          mapInput = function()
            return nil
          end,
          frames = {},
        },
      }
      resources:drawApplication(FieldApplicationIds.BAG, presentation, drawRuntime())
      Assert.equal(#sink, 1, "exactly one presenter draws")
      Assert.equal(sink[1][1], "bag", "the Bag application draws through the bag renderer")
      Assert.equal(sink[1][2], presentation, "the presenter receives the host application presentation")
      Assert.equal(sink[1][3], presentation.presentation, "the bag presenter draws through the application plan")
      Assert.equal(
        sink[1][4].icons,
        resources.itemIconProvider,
        "the bag presenter borrows the shared item icon provider"
      )
      Assert.isNil(calls.itemIcons, "drawing never releases the borrowed item icon provider")
      resources:dispose()
    end)
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

function T.party_binding_installs_and_retires_with_presentation()
  local sink, calls = {}, {}
  local runtime = compositionRuntime()
  withProductionComposition(sink, calls, runtime, function(resources)
    Assert.equal(#runtime.bindCalls, 1, "presentation binds one party preparation pair before launch")
    Assert.isTrue(
      type(runtime.bindCalls[1].prepare) == "function" and type(runtime.bindCalls[1].cancel) == "function",
      "the binding carries the provider prepare/cancel closures"
    )
    resources:dispose()
    Assert.deepEqual(runtime.unbindCalls, { 1 }, "disposal unbinds the exact installed binding")
    resources:dispose()
    Assert.deepEqual(runtime.unbindCalls, { 1 }, "repeat disposal unbinds nothing again")
  end)
end

function T.summary_binding_installs_and_retires_with_presentation()
  local sink, calls = {}, {}
  local runtime = compositionRuntime()
  withProductionComposition(sink, calls, runtime, function(resources)
    Assert.equal(#runtime.summaryBindCalls, 1, "presentation binds one summary preparation owner before launch")
    Assert.isTrue(
      type(runtime.summaryBindCalls[1]) == "function",
      "the summary binding carries the owner acquire closure"
    )
    Assert.notNil(resources.summaryResources, "construction installs the summary preparation owner")
    Assert.notNil(resources._summaryBinding, "construction installs the runtime summary binding")
    Assert.equal(calls.summaryOwnerConstructed, 1, "construction builds the summary owner exactly once")
    resources:dispose()
    Assert.deepEqual(runtime.summaryUnbindCalls, { 1 }, "disposal unbinds the exact installed summary binding")
    Assert.equal(calls.summaryOwner, 1, "disposal releases the field summary owner exactly once")
    resources:dispose()
    Assert.deepEqual(runtime.summaryUnbindCalls, { 1 }, "repeat disposal unbinds nothing again")
    Assert.equal(calls.summaryOwner, 1, "repeat disposal releases nothing again")
  end)
end

-- Producer-backed party wait coverage: the child status in the tests below
-- comes from a real PartyScreenState instead of a hand-authored record,
-- so the transition draw proves the production wait contract. Only the
-- app-exit envelope (phase, step, brightness) is supplied by the test,
-- mirroring what the menu flow retains for an outgoing child.
---@param ready boolean
---@param failure string?
---@return table screen
---@return fun(): integer cancelCount
local function waitingPartyChild(ready, failure)
  local PartyScreenState = require("game.hgss.src.field.PartyScreenState")
  local PartyPresentationFixture = require("tests.support.PartyPresentationFixture")
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  local catalog = {
    species = function(_)
      return { name = "Chikorita", genderRatio = 127 }
    end,
    item = function(_, item)
      assert(item == "NONE")
      return { name = "None" }
    end,
    iconSelection = function(_, mon)
      return mon.species .. "/f" .. mon.form
    end,
  }
  local service = {
    partyCount = function(_)
      return 2
    end,
    partyRevision = function(_)
      return 1
    end,
    partyMon = function(_)
      return {
        species = "CHIKORITA",
        form = 0,
        isEgg = false,
        personality = 0,
        nickname = "CHIKO",
        heldItem = "NONE",
        moves = { { move = "TACKLE", pp = 35, ppUps = 0 } },
        condition = { currentHp = 20, effects = {} },
      }
    end,
    partyMonDerived = function(_)
      return { maxHp = 20, level = 5 }
    end,
    catalog = function(_)
      return catalog
    end,
    swapPartyMons = function(_, _, _) end,
  }
  local cancels = 0
  local screen = PartyScreenState.new({
    service = service,
    manifest = PartyPresentationFixture.manifest(),
    measureDisplay = function()
      return {
        width = 800,
        height = 600,
        topology = ScreenTopology.oneDisplay({
          id = "main",
          rect = { x = 0, y = 0, width = 800, height = 600 },
          role = "world",
          touch = false,
        }),
        pixelRatio = 1,
        signature = "party-wait-transition-test:800x600",
      }
    end,
    prepareIcons = function(_)
      return ready, failure
    end,
    cancelIconPreparation = function()
      cancels = cancels + 1
    end,
  })
  screen:updateFixed({})
  return screen, function()
    return cancels
  end
end

function T.party_wait_renders_without_icon_getters()
  local sink, calls = {}, {}
  local savedLove = rawget(_G, "love")
  local graphics = require("tests.support.FakeGraphics").new({})
  graphics.getDimensions = function()
    error("party transition uses its resolved pane placement")
  end
  rawset(_G, "love", { graphics = graphics })
  local ok, err = pcall(function()
    withProductionComposition(sink, calls, compositionRuntime(), function(resources)
      local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
      local frame = { x = 0, y = 0, width = 256, height = 192 }
      local placement = LayoutGeometry.centeredFit({ x = 48, y = 36, width = 256, height = 192 }, 256, 192)
      local plan = {
        inputKey = "party",
        panes = {
          { id = "content", placement = placement },
          {
            id = "detail",
            placement = LayoutGeometry.centeredFit({ x = 420, y = 180, width = 256, height = 192 }, 256, 192),
          },
        },
      }
      resources:drawApplication(FieldApplicationIds.POKEMON, {
        child = {
          preparationState = "pending",
          layout = { frame = frame },
          presentation = plan,
        },
        transition = { phase = "app_exit", step = 3, brightnessCoefficient = 7 },
      }, drawRuntime())
      Assert.equal(#sink, 0, "the pending wait prints no text")
      Assert.equal(#graphics.rectangles, 3, "the outgoing shutter and sub-pane brightness cover the Party wait")
      Assert.deepEqual(
        { graphics.rectangles[1].x, graphics.rectangles[1].y, graphics.rectangles[1].w, graphics.rectangles[1].h },
        { 0, 0, 256, 48 },
        "the Party wait uses the same source shutter geometry"
      )
      Assert.deepEqual(
        graphics.scissorIntersections[1].effective,
        { placement.frame.x, placement.frame.y, placement.frame.width, placement.frame.height },
        "the Party wait shutter stays inside its resolved content pane"
      )
      Assert.equal(graphics.rectangles[3].color[4], 7 / 16, "the detail pane keeps its exit brightness")
      local failed, failure = pcall(resources.drawApplication, resources, FieldApplicationIds.POKEMON, {
        child = {
          preparationState = "failed",
          preparationError = "boom",
          layout = { frame = frame },
          presentation = plan,
        },
      }, drawRuntime())
      Assert.isFalse(failed, "failed party icons raise instead of drawing")
      Assert.isTrue(tostring(failure):find("boom", 1, true) ~= nil, "the error carries the preparation cause")
      Assert.equal(#sink, 0, "a failed party wait prints no text")
      resources:dispose()
    end)
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

-- A pending producer wait status draws through the app-exit transition:
-- the wait draws no text and the shutter is
-- clipped to the real resolved party pane, without icon getters.
function T.pending_producer_wait_draws_through_the_app_exit_transition()
  local screen, cancelCount = waitingPartyChild(false, nil)
  local waiting = screen:status()
  Assert.equal(waiting.preparationState, "pending", "the producer child under test is actually waiting")
  local sink, calls = {}, {}
  local savedLove = rawget(_G, "love")
  local graphics = require("tests.support.FakeGraphics").new({})
  graphics.getDimensions = function()
    error("party transition uses its resolved pane placement")
  end
  rawset(_G, "love", { graphics = graphics })
  local ok, err = pcall(function()
    withProductionComposition(sink, calls, compositionRuntime(), function(resources)
      resources:drawApplication(FieldApplicationIds.POKEMON, {
        child = waiting,
        transition = { phase = "app_exit", step = 3, brightnessCoefficient = 7 },
      }, drawRuntime())
      Assert.equal(#sink, 0, "the pending wait prints no text")
      Assert.equal(#graphics.rectangles, 2, "the outgoing shutter draws its two bars over the pending wait")
      Assert.deepEqual(
        { graphics.rectangles[1].color[1], graphics.rectangles[1].color[2], graphics.rectangles[1].color[3] },
        { 0, 0, 0 },
        "the pending wait shutter is opaque black"
      )
      local contentFrame = assert(waiting.presentation.panes[1].placement.frame, "the wait plan carries its frame")
      Assert.deepEqual(
        graphics.scissorIntersections[1].effective,
        { contentFrame.x, contentFrame.y, contentFrame.width, contentFrame.height },
        "the pending wait shutter stays inside its resolved content pane"
      )
      resources:dispose()
    end)
  end)
  rawset(_G, "love", savedLove)
  screen:dispose()
  Assert.equal(cancelCount(), 1, "the waiting screen releases its preparation exactly once")
  if not ok then
    error(err, 0)
  end
end

-- A failed producer wait status raises its cause from the draw instead of
-- printing, and disposal still releases preparation exactly once.
function T.failed_producer_wait_raises_its_cause_when_drawn()
  local screen, cancelCount = waitingPartyChild(false, "icons unavailable")
  local failedStatus = screen:status()
  Assert.equal(failedStatus.preparationState, "failed", "the producer child under test actually failed")
  local sink, calls = {}, {}
  local savedLove = rawget(_G, "love")
  rawset(_G, "love", { graphics = require("tests.support.FakeGraphics").new({}) })
  local ok, err = pcall(function()
    withProductionComposition(sink, calls, compositionRuntime(), function(resources)
      local drew, failure = pcall(resources.drawApplication, resources, FieldApplicationIds.POKEMON, {
        child = failedStatus,
      }, drawRuntime())
      Assert.isFalse(drew, "a failed party wait raises when drawn")
      Assert.isTrue(tostring(failure):find("icons unavailable", 1, true) ~= nil, "the error carries the cause")
      Assert.equal(#sink, 0, "a failed party wait prints no text")
      resources:dispose()
    end)
  end)
  rawset(_G, "love", savedLove)
  screen:dispose()
  Assert.equal(cancelCount(), 1, "the failed screen releases its preparation exactly once")
  if not ok then
    error(err, 0)
  end
end

function T.menu_app_exit_uses_pane_local_shutter_and_brightness()
  local coefficients = { 0, 2, 5, 7, 10, 13, 16 }
  for step, coefficient in ipairs(coefficients) do
    local sourceStep = step - 1
    local sink, calls = {}, {}
    local savedLove = rawget(_G, "love")
    local graphics = require("tests.support.FakeGraphics").new({})
    graphics.getDimensions = function()
      error("menu transitions do not cover the host window")
    end
    rawset(_G, "love", { graphics = graphics })
    local ok, err = pcall(function()
      withProductionComposition(sink, calls, compositionRuntime(), function(resources)
        local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
        local function placement(x, y)
          return LayoutGeometry.centeredFit({ x = x, y = y, width = 256, height = 192 }, 256, 192)
        end
        local mainPlacement = placement(48, 36)
        local subPlacement = placement(420, 180)
        local plan = {
          panes = {
            { id = "content", placement = mainPlacement, interactive = true },
            { id = "detail", placement = subPlacement, interactive = false },
          },
          frames = {},
          content = {},
          inputKey = "party",
          render = function(_, _, _) end,
          mapInput = function(_, _, _) end,
        }
        resources:drawApplication(FieldApplicationIds.POKEMON, {
          child = { open = true, presentation = plan },
          transition = { phase = "app_exit", step = sourceStep, brightnessCoefficient = coefficient },
        }, drawRuntime())

        local edge = 16 * sourceStep
        Assert.equal(#graphics.rectangles, 3, "the exit draws two main shutter bars and one sub overlay")
        Assert.deepEqual(
          { graphics.rectangles[1].x, graphics.rectangles[1].y, graphics.rectangles[1].w, graphics.rectangles[1].h },
          { 0, 0, 256, edge },
          "the top shutter edge follows the source step"
        )
        Assert.deepEqual({
          graphics.rectangles[2].x,
          graphics.rectangles[2].y,
          graphics.rectangles[2].w,
          graphics.rectangles[2].h,
        }, { 0, 192 - edge, 256, edge }, "the bottom shutter edge follows the source step")
        Assert.deepEqual(
          { graphics.rectangles[1].color[1], graphics.rectangles[1].color[2], graphics.rectangles[1].color[3] },
          { 0, 0, 0 },
          "the main shutter is opaque black"
        )
        Assert.equal(graphics.rectangles[3].color[4], coefficient / 16, "the sub pane follows source brightness")
        Assert.equal(
          graphics.rectangles[1].h + graphics.rectangles[2].h,
          math.min(192, 32 * sourceStep),
          "the two shutter bars cover exactly the source distance"
        )

        local mainClip = graphics.scissorIntersections[1].effective
        local subClip = graphics.scissorIntersections[2].effective
        Assert.deepEqual(
          mainClip,
          { mainPlacement.frame.x, mainPlacement.frame.y, mainPlacement.frame.width, mainPlacement.frame.height },
          "the main shutter is clipped to its inset app pane"
        )
        Assert.deepEqual(
          subClip,
          { subPlacement.frame.x, subPlacement.frame.y, subPlacement.frame.width, subPlacement.frame.height },
          "the sub brightness is clipped to its separate app pane"
        )
        Assert.isTrue(
          mainClip[1] > 0 and mainClip[2] > 0 and mainClip[1] + mainClip[3] < 800,
          "the main shutter leaves the host matte outside its pane untouched"
        )
        Assert.isTrue(
          subClip[1] > mainClip[1] + mainClip[3] and subClip[2] > mainClip[2],
          "the sub overlay remains in its distinct host pane"
        )
        if sourceStep == 0 then
          Assert.equal(graphics.rectangles[1].h + graphics.rectangles[2].h, 0, "step zero leaves the aperture open")
          Assert.equal(graphics.rectangles[3].color[4], 0, "step zero leaves sub brightness unchanged")
        elseif sourceStep == 6 then
          Assert.equal(graphics.rectangles[1].h + graphics.rectangles[2].h, 192, "step six closes the full pane")
          Assert.equal(graphics.rectangles[1].y + graphics.rectangles[1].h, 96, "the top bar reaches center")
          Assert.equal(graphics.rectangles[2].y, 96, "the bottom bar meets the top bar at center")
        end
        resources:dispose()
      end)
    end)
    rawset(_G, "love", savedLove)
    if not ok then
      error(err, 0)
    end
  end
end

function T.menu_return_draws_brightness_inside_retained_panes_without_a_child()
  local savedLove = rawget(_G, "love")
  local cases = {
    { applicationId = FieldApplicationIds.BAG, inputKey = "bag", mainId = "interaction", subId = "hero" },
    { applicationId = FieldApplicationIds.POKEMON, inputKey = "party", mainId = "content", subId = "detail" },
  }
  for _, case in ipairs(cases) do
    local sink, calls = {}, {}
    local graphics = require("tests.support.FakeGraphics").new({})
    graphics.getDimensions = function()
      error("menu return does not cover the host window")
    end
    rawset(_G, "love", { graphics = graphics })
    local ok, err = pcall(function()
      withProductionComposition(sink, calls, compositionRuntime(), function(resources)
        local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
        local mainPlacement = LayoutGeometry.centeredFit({ x = 48, y = 36, width = 256, height = 192 }, 256, 192)
        local subPlacement = LayoutGeometry.centeredFit({ x = 420, y = 180, width = 256, height = 192 }, 256, 192)
        resources:drawApplication(case.applicationId, {
          transition = {
            phase = "menu_return",
            brightnessCoefficient = 9,
            inputKey = case.inputKey,
            panes = {
              { id = case.mainId, placement = mainPlacement },
              { id = case.subId, placement = subPlacement },
            },
          },
        }, drawRuntime())
        Assert.equal(#graphics.rectangles, 2, "menu return overlays both retained app panes")
        Assert.equal(graphics.rectangles[1].color[4], 9 / 16, "the main pane uses the return brightness")
        Assert.equal(graphics.rectangles[2].color[4], 9 / 16, "the sub pane uses the return brightness")
        Assert.deepEqual(
          graphics.scissorIntersections[1].effective,
          { mainPlacement.frame.x, mainPlacement.frame.y, mainPlacement.frame.width, mainPlacement.frame.height },
          "main return brightness stays inside its retained placement"
        )
        Assert.deepEqual(
          graphics.scissorIntersections[2].effective,
          { subPlacement.frame.x, subPlacement.frame.y, subPlacement.frame.width, subPlacement.frame.height },
          "sub return brightness stays inside its retained placement"
        )
        resources:dispose()
      end)
    end)
    rawset(_G, "love", savedLove)
    if not ok then
      error(err, 0)
    end
  end
end

function T.bag_flow_party_target_wait_renders_without_icon_getters()
  local sink, calls = {}, {}
  withProductionComposition(sink, calls, compositionRuntime(), function(resources)
    local frame = { x = 0, y = 0, width = 640, height = 480 }
    resources:drawApplication(FieldApplicationIds.BAG, {
      open = true,
      root = "bag",
      page = "party_give_target",
      child = { preparationState = "pending", layout = { frame = frame } },
    }, drawRuntime())
    Assert.equal(#sink, 0, "the bag-hosted party wait prints no text")
    local drew, failure = pcall(resources.drawApplication, resources, FieldApplicationIds.BAG, {
      open = true,
      root = "bag",
      page = "party_give_target",
      child = { preparationState = "failed", preparationError = "boom", layout = { frame = frame } },
    }, drawRuntime())
    Assert.isFalse(drew, "the bag-hosted party failure raises")
    Assert.isTrue(tostring(failure):find("boom", 1, true) ~= nil, "the error carries the preparation cause")
    Assert.equal(#sink, 0, "the bag-hosted party failure prints no text")
    resources:dispose()
  end)
end

function T.summary_wait_draws_no_text_while_pending_and_raises_its_failure()
  local sink, calls = {}, {}
  withProductionComposition(sink, calls, compositionRuntime(), function(resources)
    local frame = { x = 0, y = 0, width = 256, height = 192 }
    local plan = { inputKey = "summary", panes = {} }
    resources:drawApplication(FieldApplicationIds.POKEMON, {
      open = true,
      root = "party",
      page = "summary",
      child = { preparationState = "pending", layout = { frame = frame }, presentation = plan },
    }, drawRuntime())
    Assert.equal(#sink, 0, "a pending summary draws only the host cover, never a wait message")
    local drew, failure = pcall(resources.drawApplication, resources, FieldApplicationIds.POKEMON, {
      open = true,
      root = "party",
      page = "summary",
      child = {
        preparationState = "failed",
        preparationError = "boom",
        layout = { frame = frame },
        presentation = plan,
      },
    }, drawRuntime())
    Assert.isFalse(drew, "a failed summary raises")
    Assert.isTrue(tostring(failure):find("boom", 1, true) ~= nil, "the error carries the cause")
    Assert.equal(#sink, 0, "a failed summary prints no text")
    resources:dispose()
  end)
end

function T.bag_flow_party_target_routes_to_the_party_presenter()
  local sink, calls = {}, {}
  local savedLove = rawget(_G, "love")
  rawset(_G, "love", { graphics = require("tests.support.FakeGraphics").new({}) })
  local ok, err = pcall(function()
    withProductionComposition(sink, calls, compositionRuntime(), function(resources)
      local child = {
        preparationState = "ready",
        presentation = {
          panes = {},
          content = {},
          inputKey = "party",
          render = function(borrowed, view, plan)
            assert(borrowed.partyScreenRenderer, "the party render borrows its renderer"):draw(
              view,
              plan,
              borrowed.icons
            )
          end,
          mapInput = function()
            return nil
          end,
          frames = {},
        },
      }
      local presentation = { open = true, root = "bag", page = "party_give_target", child = child }
      resources:drawApplication(FieldApplicationIds.BAG, presentation, drawRuntime())
      Assert.equal(#sink, 1, "exactly one presenter draws")
      Assert.equal(sink[1][1], "party", "the bag-hosted party target draws through the party renderer")
      Assert.equal(sink[1][2], child, "the presenter receives the resolved party child status")
      Assert.equal(sink[1][3], child.presentation, "the presenter draws through the party plan")
      Assert.equal(sink[1][4], resources.monIconProvider, "the party target borrows the shared mon icon provider")
      Assert.isNil(calls.icons, "drawing never releases the borrowed icon provider")
      resources:dispose()
    end)
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

function T.pokemon_flow_bag_picker_routes_to_the_bag_presenter()
  local sink, calls = {}, {}
  local savedLove = rawget(_G, "love")
  rawset(_G, "love", { graphics = require("tests.support.FakeGraphics").new({}) })
  local ok, err = pcall(function()
    withProductionComposition(sink, calls, compositionRuntime(), function(resources)
      local child = {
        presentation = {
          panes = {},
          content = {},
          inputKey = "bag",
          render = function(borrowed, view, plan)
            assert(borrowed.bagRenderer, "the bag render borrows its renderer"):draw(view, plan, {
              icons = borrowed.icons,
            })
          end,
          mapInput = function()
            return nil
          end,
          frames = {},
        },
      }
      local presentation = { open = true, root = "party", page = "bag_pick_held", child = child }
      resources:drawApplication(FieldApplicationIds.POKEMON, presentation, drawRuntime())
      Assert.equal(#sink, 1, "exactly one presenter draws")
      Assert.equal(sink[1][1], "bag", "the party-hosted bag picker draws through the bag renderer")
      Assert.equal(sink[1][2], child, "the presenter receives the resolved bag child status")
      Assert.equal(sink[1][3], child.presentation, "the presenter draws through the bag plan")
      Assert.equal(sink[1][4].icons, resources.itemIconProvider, "the bag picker borrows the shared item icon provider")
      Assert.isNil(calls.itemIcons, "drawing never releases the borrowed item icon provider")
      resources:dispose()
    end)
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

function T.unknown_application_ids_fault_without_drawing()
  local sink, calls = {}, {}
  withProductionComposition(sink, calls, compositionRuntime(), function(resources)
    Assert.throws(function()
      resources:drawApplication("not-an-application", {}, drawRuntime())
    end)
    Assert.equal(#sink, 0, "a faulting dispatch must not fall through to any renderer")
    resources:dispose()
  end)
end

function T.draw_reuses_presenters_without_acquiring_resources()
  local sink, calls = {}, {}
  local savedLove = rawget(_G, "love")
  rawset(_G, "love", { graphics = require("tests.support.FakeGraphics").new({}) })
  local ok, err = pcall(function()
    withProductionComposition(sink, calls, compositionRuntime(), function(resources)
      local presentation = {
        presentation = {
          panes = {},
          content = {},
          inputKey = "party",
          render = function(borrowed, view, plan)
            assert(borrowed.partyScreenRenderer, "the party render borrows its renderer"):draw(
              view,
              plan,
              borrowed.icons
            )
          end,
          mapInput = function()
            return nil
          end,
          frames = {},
        },
      }
      resources:drawApplication(FieldApplicationIds.POKEMON, presentation, drawRuntime())
      local map = assert(resources.presenters, "dispatch owns one per-instance presenter map")
      resources:drawApplication(FieldApplicationIds.POKEMON, presentation, drawRuntime())
      Assert.equal(resources.presenters, map, "repeated draws must not rebuild the presenter map")
      Assert.equal(type(map[FieldApplicationIds.POKEMON]), "function", "the Pokemon presenter is explicitly mapped")
      Assert.equal(
        type(map[FieldApplicationIds.TRAINER_CARD]),
        "function",
        "the Trainer Card presenter is explicitly mapped"
      )
      Assert.equal(type(map[FieldApplicationIds.BAG]), "function", "the Bag presenter is explicitly mapped")
      Assert.equal(#sink, 2, "both draws reach the same borrowed renderer")
      Assert.isNil(calls.icons, "drawing never releases the borrowed icon provider")
      resources:dispose()
    end)
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

function T.dispose_releases_owned_resources_exactly_once()
  local sink, calls = {}, {}
  local savedLove = rawget(_G, "love")
  rawset(_G, "love", { graphics = require("tests.support.FakeGraphics").new({}) })
  local ok, err = pcall(function()
    withProductionComposition(sink, calls, compositionRuntime(), function(resources)
      local presentation = {
        presentation = {
          panes = {},
          content = {},
          inputKey = "party",
          render = function(borrowed, view, plan)
            assert(borrowed.partyScreenRenderer, "the party render borrows its renderer"):draw(
              view,
              plan,
              borrowed.icons
            )
          end,
          mapInput = function()
            return nil
          end,
          frames = {},
        },
      }
      resources:drawApplication(FieldApplicationIds.POKEMON, presentation, drawRuntime())
      resources:dispose()
      resources:dispose()
      Assert.equal(calls.menu, 1, "repeat disposal never releases a renderer twice")
      Assert.equal(calls.card, 1, "repeat disposal never releases the card renderer twice")
      Assert.equal(calls.icons, 1, "repeat disposal never releases the icon provider twice")
      Assert.equal(calls.bag, 1, "repeat disposal never releases the bag renderer twice")
      Assert.equal(calls.itemIcons, 1, "repeat disposal never releases the item icon provider twice")
      Assert.equal(calls.hero, 1, "repeat disposal never releases the hero model renderer twice")
      Assert.equal(calls.dialogue, 1, "repeat disposal never releases the dialogue renderer twice")
      Assert.equal(calls.signpost, 1, "repeat disposal never releases the signpost renderer twice")
      -- The field owns three text renderers sharing one constructor seam:
      -- the field text renderer plus the battle narration and menu
      -- renderers. Repeat disposal releases each exactly once.
      Assert.equal(calls.text, 3, "repeat disposal releases each owned text renderer exactly once")
      Assert.equal(calls.renderer, 1, "repeat disposal never releases the field renderer twice")
      Assert.equal(calls.staticEffect, 2, "repeat disposal releases each static effect renderer once")
      Assert.equal(calls.terrain, 1, "repeat disposal never releases the terrain effect renderer twice")
      Assert.equal(calls.emote, 1, "repeat disposal never releases the emote renderer twice")
      Assert.equal(calls.pool, 2, "repeat disposal releases each asset pool once")
      -- The composition borrows the session image owner instead of owning
      -- a worker: no owned image queue exists to release, and disposal
      -- never tears down the borrowed pool.
      Assert.isNil(calls.queue, "repeat disposal builds no image queue beside the runtime owner")
    end)
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

function T.pc_renderers_are_owned_prepared_and_drawn_through_field_resources()
  local sink, calls = {}, {}
  withProductionComposition(sink, calls, compositionRuntime(), function(resources)
    Assert.notNil(resources.storageRenderer, "PC Storage has its source renderer")
    Assert.notNil(resources.mailboxRenderer, "Mailbox has its source renderer")
    Assert.notNil(resources.photoAlbumRenderer, "Photo Album has its source renderer")
    local status = { app = "photoAlbum", presentation = { inputKey = "photo-album" } }
    local host = {
      draw = function(_, _)
        calls.pcChildDrawn = (calls.pcChildDrawn or 0) + 1
      end,
      presentationPlan = function()
        return nil
      end,
    }
    local ready = resources:preparePcApplication(status, { monCatalog = {} })
    Assert.isTrue(ready, "photo icon resources are prepared before the drawable pass")
    Assert.equal(calls.photoAlbumAdvanced, 1)
    resources:drawPcApplication(host, { monCatalog = {} })
    Assert.equal(calls.pcChildDrawn, 1, "Field presentation delegates to the active child owner")
    resources:dispose()
    resources:dispose()
    Assert.equal(calls.pcStorage, 1, "PC Storage renderer releases once")
    Assert.equal(calls.mailbox, 1, "Mailbox renderer releases once")
    Assert.equal(calls.photoAlbum, 1, "Photo Album renderer releases once")
  end)
end

function T.storage_icon_preparation_skips_empty_box_sentinels()
  local sink, calls = {}, {}
  withProductionComposition(sink, calls, compositionRuntime(), function(resources)
    local boxSlots = {}
    for slot = 1, 29 do
      boxSlots[slot] = false
    end
    boxSlots[30] = { iconKey = "species:1:form:0" }
    local prepared, ready = pcall(function()
      return resources:preparePcApplication({
        app = "storage",
        boxSlots = boxSlots,
        party = {},
        visualView = {},
      }, { monCatalog = {} })
    end)
    Assert.isTrue(prepared, "Storage icon preparation skips explicit empty slots: " .. tostring(ready))
    Assert.isTrue(ready, "Storage preparation completes when occupied mons follow empty sentinels")
    Assert.deepEqual(calls.iconKeys, { "species:1:form:0" }, "the final box mon's icon is prepared")
    resources:dispose()
  end)
end

function T.dispose_releases_the_borrowed_hero_model_renderer_exactly_once()
  local sink, calls = {}, {}
  withProductionComposition(sink, calls, compositionRuntime(), function(resources)
    resources:dispose()
    resources:dispose()
    Assert.equal(calls.hero, 1, "repeat disposal never releases the hero model renderer twice")
  end)
end

function T.bag_draw_borrows_shared_resources_without_releasing_them()
  local sink, calls = {}, {}
  local savedLove = rawget(_G, "love")
  rawset(_G, "love", { graphics = require("tests.support.FakeGraphics").new({}) })
  local ok, err = pcall(function()
    withProductionComposition(sink, calls, compositionRuntime(), function(resources)
      local presentation = {
        presentation = {
          panes = {},
          content = {},
          inputKey = "bag",
          render = function(borrowed, view, plan)
            assert(borrowed.bagRenderer, "the bag render borrows its renderer"):draw(view, plan, {
              icons = borrowed.icons,
            })
          end,
          mapInput = function()
            return nil
          end,
          frames = {},
        },
      }
      resources:drawApplication(FieldApplicationIds.BAG, presentation, drawRuntime())
      Assert.equal(#sink, 1, "exactly one presenter draws")
      Assert.isNil(calls.hero, "drawing never releases the borrowed hero model renderer")
      Assert.isNil(calls.bag, "drawing never releases the borrowed bag renderer")
      resources:dispose()
    end)
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

-- Construction acquires exactly one frame-strip atlas and lends it to the
-- dialogue renderer: the dialogue borrower never owns a second copy, the
-- selected index snapshots the player option, and repeat disposal releases
-- the shared owner exactly once.
function T.construction_shares_one_window_renderer_with_the_dialogue_renderer()
  local sink, calls = {}, {}
  withProductionComposition(sink, calls, compositionRuntime(), function(resources)
    Assert.equal(calls.window, 1, "exactly one frame-strip atlas is acquired")
    Assert.notNil(calls.dialogueWindow, "the dialogue renderer borrows the shared owner")
    Assert.isTrue(
      calls.dialogueWindow == calls.windowInstance,
      "dialogue borrows the resources-owned renderer, not a second copy"
    )
    resources:dispose()
    resources:dispose()
    Assert.equal(calls.dialogue, 1, "repeat disposal releases the dialogue borrower exactly once")
    Assert.equal(calls.windowReleased, 1, "repeat disposal releases the shared owner exactly once")
  end)
end

-- PC children are drawn by their own owners but share the application outer
-- frame, drawn after the child's content.
function T.pc_application_plans_are_framed_after_child_content()
  local PixelScale = require("libs.ui.src.PixelScale")
  local sink, calls = {}, {}
  local savedLove = rawget(_G, "love")
  rawset(_G, "love", { graphics = require("tests.support.FakeGraphics").new({}) })
  local ok, err = pcall(function()
    withProductionComposition(sink, calls, compositionRuntime(), function(resources)
      local placement = assert(PixelScale.placeFixed({ x = 0, y = 0, width = 640, height = 480 }, 272, 232))
      local contentBox = { x = 8, y = 24, width = 256, height = 192 }
      local host = {
        draw = function()
          sink[#sink + 1] = { "content" }
        end,
        presentationPlan = function()
          return { frames = { { placement = placement, contentBox = contentBox } } }
        end,
      }
      resources:drawPcApplication(host, { monCatalog = {} })
      Assert.equal(sink[1][1], "content", "the PC child draws before its frame")
      Assert.equal(sink[2][1], "frame", "the PC application receives the shared outer frame")
      Assert.deepEqual(sink[2][2], contentBox, "the frame wraps the plan content box")
      resources:dispose()
    end)
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

-- A framed plan paints application content before its selected border
-- through the shared owner, so opaque decoration may intentionally cover
-- edge pixels while masked padding reveals the content beneath.
function T.framed_plans_draw_application_content_before_selected_borders()
  local PixelScale = require("libs.ui.src.PixelScale")
  local sink, calls = {}, {}
  local savedLove = rawget(_G, "love")
  rawset(_G, "love", { graphics = require("tests.support.FakeGraphics").new({}) })
  local ok, err = pcall(function()
    withProductionComposition(sink, calls, compositionRuntime(), function(resources)
      local placement = assert(
        PixelScale.placeFixed({ x = 0, y = 0, width = 640, height = 480 }, 272, 232),
        "the probe host must admit the framed box"
      )
      local contentBox = { x = 8, y = 24, width = 256, height = 192 }
      local presentation = {
        presentation = {
          panes = {},
          content = {},
          inputKey = "party",
          render = function()
            sink[#sink + 1] = { "content" }
          end,
          mapInput = function()
            return nil
          end,
          frames = { { placement = placement, contentBox = contentBox } },
        },
      }
      resources:drawApplication(FieldApplicationIds.POKEMON, presentation, drawRuntime())
      Assert.equal(#sink, 2, "the content and the border each draw once")
      Assert.equal(sink[1][1], "content", "application content paints before its frame")
      Assert.equal(sink[2][1], "frame", "the outer border draws after application content")
      Assert.deepEqual(sink[2][2], contentBox, "the border wraps the published content box")
      Assert.equal(sink[2][3], 0, "the border uses the selected player frame index")
      resources:dispose()
    end)
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

function T.unframed_plans_draw_no_border()
  local sink, calls = {}, {}
  local savedLove = rawget(_G, "love")
  rawset(_G, "love", { graphics = require("tests.support.FakeGraphics").new({}) })
  local ok, err = pcall(function()
    withProductionComposition(sink, calls, compositionRuntime(), function(resources)
      local presentation = {
        presentation = {
          panes = {},
          content = {},
          inputKey = "party",
          render = function()
            sink[#sink + 1] = { "content" }
          end,
          mapInput = function()
            return nil
          end,
          frames = {},
        },
      }
      resources:drawApplication(FieldApplicationIds.POKEMON, presentation, drawRuntime())
      Assert.equal(#sink, 1, "only application content draws")
      Assert.equal(sink[1][1], "content", "an unframed plan draws no border")
      resources:dispose()
    end)
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

-- The Start Menu dispatch executes the resolved plan's render callback with
-- the borrowed renderer and never releases it: the plan owns geometry,
-- the resources own the GPU objects.
function T.start_menu_draw_executes_the_resolved_plan_with_borrowed_resources()
  local sink, calls = {}, {}
  local doubles = buildDoubles(sink, calls)
  doubles["libs.hgss.src.ui.StartMenuRenderer"] = {
    new = function(_)
      return {
        draw = function(_, presentation, placement)
          sink[#sink + 1] = { "menu", presentation, placement }
        end,
        release = function(_)
          calls.menu = (calls.menu or 0) + 1
        end,
      }
    end,
  }
  local saved = {}
  for _, name in ipairs(CONSTRUCTOR_MODULES) do
    saved[name] = package.loaded[name]
    package.loaded[name] = doubles[name]
  end
  package.loaded[TARGET_MODULE] = nil
  local PixelScale = require("libs.ui.src.PixelScale")
  local FakeGraphics = require("tests.support.FakeGraphics").new
  local ok, err = pcall(function()
    local FieldPresentationResources = require(TARGET_MODULE)
    local resources = FieldPresentationResources.new(compositionRuntime())
    local body = assert(
      PixelScale.placeFixed({ x = 0, y = 0, width = 640, height = 480 }, 256, 192),
      "the dispatch test host fits the canonical body"
    )
    local status = { selectedPosition = 0, actions = {} }
    status.presentation = {
      panes = { { id = "content", placement = body, interactive = true } },
      content = {},
      inputKey = "start-menu",
      render = function(borrowed, view, plan)
        assert(borrowed.startMenuRenderer, "the menu render borrows its renderer"):draw(
          view,
          assert(plan.panes[1], "the menu plan needs its body pane").placement
        )
      end,
      mapInput = function()
        return nil
      end,
      frames = {},
    }
    local graphics = FakeGraphics({})
    resources:drawStartMenu(status, graphics)
    Assert.equal(#sink, 1, "exactly the chosen render callback draws")
    Assert.equal(sink[1][1], "menu", "the menu draws through the owned renderer")
    Assert.equal(sink[1][2], status, "the renderer receives the wrapper snapshot")
    Assert.deepEqual(sink[1][3], body, "the renderer draws at the plan body placement")
    Assert.isNil(calls.menu, "drawing never releases the borrowed renderer")
    Assert.throws(function()
      resources:drawStartMenu({ selectedPosition = 0 })
    end, "drawing without a published plan fails instead of drawing stale content")
    resources:dispose()
  end)
  for _, name in ipairs(CONSTRUCTOR_MODULES) do
    package.loaded[name] = saved[name]
  end
  package.loaded[TARGET_MODULE] = nil
  if not ok then
    error(err, 0)
  end
end

-- The Bag renderer borrows the runtime-owned shared image owner instead of
-- triggering a second preparation worker: construction hands the runtime
-- pool to the Bag renderer, builds no additional queue, stages no state
-- visual by itself, and disposal never tears down the borrowed pool.
function T.bag_renderer_borrows_the_shared_image_owner_without_a_second_queue()
  local sink, calls = {}, {}
  local runtime = compositionRuntime()
  local pool = SharedImagePoolFake.new()
  local disposed = 0
  function pool:dispose()
    disposed = disposed + 1
  end
  runtime.imageAssets = pool
  withProductionComposition(sink, calls, runtime, function(resources)
    local bagOpts = assert(calls.bagOpts, "field entry constructs its Bag renderer")
    Assert.isTrue(bagOpts.imagePool == pool, "the Bag renderer borrows the runtime-owned shared image owner")
    Assert.isNil(calls.queue, "field entry builds no second preparation worker beside the runtime queue")
    Assert.equal(pool:stats().physicalImages, 0, "construction stages no state visual by itself")
    resources:dispose()
    Assert.equal(disposed, 0, "disposal never tears down the borrowed image owner")
  end)
end

-- The field update advances the active Bag leaf outside drawing: the leaf
-- picker unwraps an outer flow child, delegates Bag leaves to the shared
-- renderer, and leaves every other application untouched without drawing.
function T.bag_preparation_advances_the_active_leaf_without_drawing()
  local sink, calls = {}, {}
  withProductionComposition(sink, calls, compositionRuntime(), function(resources)
    Assert.isTrue(
      type(resources.prepareBagApplication) == "function",
      "the field update prepares Bag leaves outside draw"
    )
    local leaf = { presentation = { inputKey = "bag" } }
    local ready, failure = resources:prepareBagApplication(leaf)
    Assert.isTrue(ready, "the active Bag leaf prepares")
    Assert.isNil(failure, "the active Bag leaf prepares without failure")
    Assert.equal(calls.bagPrepares, 1, "the active Bag leaf delegates exactly once")
    Assert.isTrue(calls.bagPrepareLeaves[1] == leaf, "preparation receives the active leaf itself")
    -- An outer flow without its own plan resolves through its child: the
    -- Party host carries the Bag picker the same way production draws it.
    local inactive = { presentation = { inputKey = "bag-inactive" } }
    ready, failure = resources:prepareBagApplication({ child = inactive })
    Assert.isTrue(ready, "the inactive Bag leaf prepares")
    Assert.isNil(failure, "the inactive Bag leaf prepares without failure")
    Assert.equal(calls.bagPrepares, 2, "the unwrapped leaf delegates exactly once")
    Assert.isTrue(calls.bagPrepareLeaves[2] == inactive, "preparation receives the unwrapped child leaf")
    -- Any other application is a no-op: no delegation, no borrowed art,
    -- and no presenter draws through the preparation path.
    ready, failure = resources:prepareBagApplication({ presentation = { inputKey = "party" } })
    Assert.isTrue(ready, "an unrelated application stays ready")
    Assert.isNil(failure, "an unrelated application prepares without failure")
    Assert.equal(calls.bagPrepares, 2, "an unrelated application delegates nothing")
    Assert.equal(#sink, 0, "preparation draws nothing through any presenter")
    resources:dispose()
  end)
end

-- The script Mart sale prepares through the shared Bag presenter: the
-- sell status carries its own Bag plan, so the same leaf picker admits it
-- without drawing, while the buy surface stays out of Bag preparation.
function T.mart_sale_prepares_through_the_shared_bag_presenter()
  local sink, calls = {}, {}
  withProductionComposition(sink, calls, compositionRuntime(), function(resources)
    Assert.isTrue(
      type(resources.prepareBagApplication) == "function",
      "the Mart sale prepares its Bag leaf outside draw"
    )
    local sell = { martKind = "sell", presentation = { inputKey = "bag" } }
    local ready, failure = resources:prepareBagApplication(sell)
    Assert.isTrue(ready, "the Mart sale prepares")
    Assert.isNil(failure, "the Mart sale prepares without failure")
    Assert.equal(calls.bagPrepares, 1, "the Mart sale delegates exactly once")
    Assert.isTrue(calls.bagPrepareLeaves[1] == sell, "preparation receives the Mart sale status itself")
    ready, failure = resources:prepareBagApplication({ martKind = "buy", presentation = { inputKey = "mart" } })
    Assert.isTrue(ready, "the Mart buy surface stays ready")
    Assert.isNil(failure, "the Mart buy surface prepares without failure")
    Assert.equal(calls.bagPrepares, 1, "the Mart buy surface delegates nothing to the Bag renderer")
    Assert.equal(#sink, 0, "Mart preparation draws nothing through any presenter")
    resources:dispose()
  end)
end

-- Fixed field chrome borrows the session image owner instead of privately
-- uploading duplicates: dialogue, signpost, and Trainer Card construction
-- each receive the runtime-owned shared image owner, and disposal still
-- returns every borrowed renderer exactly once.
function T.fixed_chrome_borrows_the_session_image_pool()
  local sink, calls = {}, {}
  local runtime = compositionRuntime()
  withProductionComposition(sink, calls, runtime, function(resources)
    Assert.isTrue(
      calls.dialogueImagePool == runtime.imageAssets,
      "the dialogue renderer borrows the runtime-owned shared image owner"
    )
    Assert.isTrue(
      calls.signpostImagePool == runtime.imageAssets,
      "the signpost renderer borrows the runtime-owned shared image owner"
    )
    Assert.isTrue(
      calls.cardImagePool == runtime.imageAssets,
      "the Trainer Card renderer borrows the runtime-owned shared image owner"
    )
    resources:dispose()
    Assert.equal(calls.dialogue, 1, "disposal still releases the dialogue renderer once")
    Assert.equal(calls.signpost, 1, "disposal still releases the signpost renderer once")
    Assert.equal(calls.card, 1, "disposal still releases the card renderer once")
  end)
end

-- Storage readiness waits for both mon icons and visual leases: pending
-- visuals keep the host unready while icons are ready, pending icons keep
-- the host unready while visuals enroll independently, and preparation
-- admits the exact published view without drawing anything.
function T.storage_preparation_waits_for_visual_leases_beside_icon_readiness()
  local sink, calls = {}, {}
  withProductionComposition(sink, calls, compositionRuntime(), function(resources)
    Assert.isTrue(
      type(resources.preparePcApplication) == "function",
      "the host admits the PC application outside drawing"
    )
    local preparedViews = {}
    local visualsReady = false
    resources.storageRenderer.prepare = function(_, view)
      preparedViews[#preparedViews + 1] = view
      if visualsReady then
        return true
      end
      return false
    end
    local visualView = { mode = 0, wallpaperId = 0 }
    local status = { app = "storage", boxSlots = {}, party = {}, visualView = visualView }
    local ready, failure = resources:preparePcApplication(status, { monCatalog = {} })
    Assert.isFalse(ready, "pending Storage visuals keep the host unready")
    Assert.isNil(failure, "pending Storage visuals report no failure")
    Assert.equal(#preparedViews, 1, "visual enrollment runs beside icon preparation")
    Assert.isTrue(preparedViews[1] == visualView, "preparation admits the exact published view")
    visualsReady = true
    ready, failure = resources:preparePcApplication(status, { monCatalog = {} })
    Assert.isTrue(ready, "admitted visuals with ready icons turn the host ready")
    Assert.isNil(failure, "a ready host reports no failure")
    visualsReady = false
    calls.iconPageReady = false
    preparedViews = {}
    ready, failure = resources:preparePcApplication(status, { monCatalog = {} })
    Assert.isFalse(ready, "pending icons keep the host unready")
    Assert.isNil(failure, "pending icons report no failure")
    Assert.equal(#preparedViews, 1, "visual enrollment never waits behind icon readiness")
    Assert.equal(#sink, 0, "preparation draws nothing through any presenter")
    resources:dispose()
  end)
end

-- The held-item picker admits through the shared Bag presenter: a pending
-- picker leaf keeps the host unready without touching Storage wallpaper,
-- and closing the picker resumes ordinary Storage readiness.
function T.held_item_picker_preparation_delegates_to_the_bag_presenter()
  local sink, calls = {}, {}
  withProductionComposition(sink, calls, compositionRuntime(), function(resources)
    local storagePrepares = 0
    resources.storageRenderer.prepare = function(_)
      storagePrepares = storagePrepares + 1
      return true
    end
    local bagLeaf = { presentation = { inputKey = "bag" } }
    local status = {
      app = "storage",
      boxSlots = {},
      party = {},
      childKind = "heldItemPicker",
      bagChildStatus = bagLeaf,
      visualView = { mode = 2, wallpaperId = 0 },
    }
    calls.bagPrepareReady = false
    local ready, failure = resources:preparePcApplication(status, { monCatalog = {} })
    Assert.isFalse(ready, "a pending picker leaf keeps the host unready")
    Assert.isNil(failure, "a pending picker leaf reports no failure")
    Assert.equal(storagePrepares, 0, "the picker admits no Storage wallpaper")
    Assert.equal(calls.bagPrepares, 1, "the picker delegates to the shared Bag presenter")
    Assert.isTrue(
      calls.bagPrepareLeaves[#calls.bagPrepareLeaves] == bagLeaf,
      "preparation receives the live picker leaf"
    )
    calls.bagPrepareReady = nil
    ready, failure = resources:preparePcApplication(status, { monCatalog = {} })
    Assert.isTrue(ready, "an admitted picker leaf turns the host ready")
    Assert.isNil(failure, "an admitted picker leaf reports no failure")
    Assert.equal(storagePrepares, 0, "an admitted picker still admits no Storage wallpaper")
    local browsing = { app = "storage", boxSlots = {}, party = {}, visualView = { mode = 2, wallpaperId = 0 } }
    ready, failure = resources:preparePcApplication(browsing, { monCatalog = {} })
    Assert.isTrue(ready, "closing the picker resumes Storage readiness")
    Assert.isNil(failure, "resumed Storage reports no failure")
    Assert.equal(storagePrepares, 1, "the resumed view admits its visuals")
    Assert.equal(#sink, 0, "picker preparation draws nothing through any presenter")
    resources:dispose()
  end)
end

-- Production Storage replacement coverage below: the real host keeps
-- painting the admitted view while its replacement waits, and old icon
-- pages survive until the full replacement admits. These tests drive the
-- real application host, the real Storage child, the real Storage visual
-- renderer, and (for icons) the real mon icon page owner behind one
-- shared synchronous image owner, ticked in the field update order of
-- child step, resource preparation, then host readiness.
local function transitionMonService()
  local catalog = CatalogFixture.makeCatalog()
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(
      Party.new():capture(),
      Lcrng.new(0x12345678):capture(),
      nil,
      nil
    ),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
  local factory = CatalogFixture.makeFactory(0x87654321, catalog)
  Assert.isTrue(service:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  return service
end

-- The measured display behind the Storage transition tests. Tests that keep
-- the default exercise the wide topology; tests that resize assign an
-- injected measurement through setTransitionDisplay and restore the wide
-- default with clearTransitionDisplay when they finish.
local transitionDisplayOverride = nil

local function transitionMeasureDisplay()
  if transitionDisplayOverride ~= nil then
    return transitionDisplayOverride
  end
  return {
    width = 512,
    height = 192,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 512, height = 192 },
      role = "world",
      touch = true,
    }),
    pixelRatio = 1,
    signature = "pc-transition-test:wide",
  }
end

local function setTransitionDisplay(measurement)
  transitionDisplayOverride = assert(measurement, "the injected display measurement is a record")
end

local function clearTransitionDisplay()
  transitionDisplayOverride = nil
end

local function transitionDisplayFor(kind)
  if kind == "wide" then
    clearTransitionDisplay()
    return transitionMeasureDisplay()
  elseif kind == "tall" then
    return {
      width = 384,
      height = 512,
      topology = ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 384, height = 512 },
        role = "world",
        touch = true,
      }),
      pixelRatio = 1,
      signature = "pc-transition-test:tall",
    }
  elseif kind == "dual" then
    return {
      width = 512,
      height = 384,
      topology = ScreenTopology.dualDisplay(
        { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, role = "world", touch = false },
        { id = "sub", rect = { x = 256, y = 0, width = 256, height = 192 }, role = "auxiliary", touch = true }
      ),
      pixelRatio = 1,
      signature = "pc-transition-test:dual",
    }
  elseif kind == "blocked" then
    return {
      width = 256,
      height = 192,
      topology = ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 256, height = 192 },
        role = "world",
        touch = true,
        occupiedRegions = { { x = 0, y = 0, width = 256, height = 192 } },
      }),
      pixelRatio = 1,
      signature = "pc-transition-test:blocked",
    }
  end
  error("unknown transition display kind " .. tostring(kind), 0)
end

local function openTransitionStorage(mons, mode)
  return PcStorageState.new({
    mode = mode,
    mons = mons,
    bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() }),
    manifest = PcPresentationFixture.manifest(),
    measureDisplay = transitionMeasureDisplay,
    audio = { play = function() end },
    dexNumber = function() end,
    charmap = CatalogFixture.CHARMAP,
    icons = {},
    portraits = {},
    childFactories = {},
  })
end

-- One shared synchronous image owner behind Storage visuals and icon
-- pages, with per-path delay control: chosen generated paths stay pending
-- until their entry clears, modelling a cold worker job without blocking.
-- Acquired leases carry decoded dimensions so icon page bounds validate.
local function transitionImageOwner()
  local inner = SharedImagePoolFake.new()
  local pendingPaths = {}
  local tokenPaths = {}
  local pool = {}
  function pool:request(path, sampler, priority)
    local token = inner:request(path, sampler, priority)
    tokenPaths[token] = path
    return token
  end
  function pool:poll(token)
    if pendingPaths[tokenPaths[token]] then
      return "pending"
    end
    return inner:poll(token)
  end
  function pool:acquire(token)
    local lease = inner:acquire(token)
    lease.width = 256
    lease.height = 128
    lease.kind = "rgba8"
    local image = assert(lease.image, "shared leases carry their resolved image")
    function image:getWidth()
      return 256
    end
    function image:getHeight()
      return 128
    end
    return lease
  end
  function pool:release(lease)
    return inner:release(lease)
  end
  function pool:cancel(token)
    tokenPaths[token] = nil
    return inner:cancel(token)
  end
  function pool:prune()
    return inner:prune()
  end
  function pool:stats()
    return inner:stats()
  end
  return pool, inner, pendingPaths
end

local function transitionVisualPaths(manifest)
  local storage = manifest.storage
  local all = {
    storage.backgrounds.default,
    storage.ui.boxPane,
    storage.ui.infoPane,
    storage.ui.partyTray,
    storage.ui.markingPanel,
    storage.ui.wallpaperBar,
    storage.ui.arrows.left,
    storage.ui.arrows.right,
    storage.ui.cursors.browse,
    storage.ui.cursors.menu,
    storage.ui.cursors.carry,
  }
  for _, visual in pairs(storage.wallpapers) do
    all[#all + 1] = visual
  end
  for _, pair in pairs(storage.ui.markings) do
    all[#all + 1] = pair.clear
    all[#all + 1] = pair.set
  end
  for _, style in pairs(storage.ui.windowFrames) do
    for _, visual in pairs(style) do
      all[#all + 1] = visual
    end
  end
  return all
end

local function transitionRenderer(pool)
  local manifest = PcPresentationFixture.manifest()
  manifest.text = { banks = { [24] = {}, [25] = {} } }
  for bankId, bank in pairs(manifest.text.banks) do
    for messageId = 0, 100 do
      bank[messageId] = { { kind = "glyph", text = "b" .. bankId .. ":" .. messageId } }
    end
  end
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local image = PngWriter.encode(1, 1, string.char(255, 255, 255, 255))
  for _, visual in ipairs(transitionVisualPaths(manifest)) do
    cache:write(visual.image, image)
  end
  local graphics = FakeGraphics.new({})
  local text = {
    drawText = function() end,
    textWidth = function()
      return 0
    end,
    windowBackgroundColor = function()
      return { 1, 1, 1, 1 }
    end,
  }
  local renderer = PcStorageRenderer.new({
    graphics = graphics,
    cacheFs = cache,
    manifest = manifest,
    text = text,
    imagePool = pool,
  })
  return renderer, graphics, manifest
end

local function iconEntryForTest(pageId, x, y)
  return {
    x = x,
    y = y,
    width = 32,
    height = 32,
    frames = {
      { x = x, y = y, width = 32, height = 32, duration = 1 },
      { x = x + 32, y = y, width = 32, height = 32, duration = 1 },
    },
    pageId = pageId,
  }
end

-- The real mon icon page owner behind two demanded pages: the first
-- species on page zero, the second on page one. Demand is recorded per
-- call without changing behavior, so the suite can prove which icon keys
-- the composition holds while a replacement pends.
local function transitionIconProvider(pool, graphics)
  local manifest = {
    schema = MonCache.ICON_MANIFEST_SCHEMA,
    version = { id = "heartgold", language = "english" },
    pages = {
      [0] = { pageId = 0, image = MonCache.iconPagePath(0), width = 256, height = 128 },
      [1] = { pageId = 1, image = MonCache.iconPagePath(1), width = 256, height = 128 },
    },
    pageIds = { 0, 1 },
    entries = {
      ["CHIKORITA/f0"] = iconEntryForTest(0, 0, 0),
      ["TOTODILE/f0"] = iconEntryForTest(1, 64, 0),
    },
    representative = { "CHIKORITA/f0", "TOTODILE/f0" },
  }
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(MonCache.iconManifestPath(), manifest)
  cache:write(MonCache.iconPagePath(0), "page-zero-bytes")
  cache:write(MonCache.iconPagePath(1), "page-one-bytes")
  local provider = MonIconAssetProvider.new(cache, {
    graphics = graphics,
    imagePool = pool,
    derivedAssets = {
      requestIconPage = function(_)
        return true
      end,
    },
  })
  local demanded = {}
  local baselinePrepareKeys = provider.prepareKeys
  function provider:prepareKeys(keys)
    local snapshot = {}
    for _, key in ipairs(keys) do
      snapshot[#snapshot + 1] = key
    end
    demanded[#demanded + 1] = snapshot
    return baselinePrepareKeys(provider, keys)
  end
  return provider, demanded
end

local function hostForTransitionChild(child)
  return PcApplicationHost.new({
    createStorage = function()
      return child
    end,
    createMailbox = function()
      error("mailbox unused", 0)
    end,
    createPhotoAlbum = function()
      error("photo album unused", 0)
    end,
  })
end

local function transitionResources(renderer, icons)
  return {
    storageRenderer = renderer,
    icons = icons,
    windowRenderer = {
      drawWindow = function() end,
      drawStandardWindow = function() end,
    },
    applicationFrameIndex = 3,
  }
end

-- The real production preparation function over the composed owners:
-- untouched sibling collaborators stay inert dummies on the Storage
-- path, which borrows only the mon icon provider and Storage renderer.
-- Method lookups fall back to the production module, so the exercised
-- path is the real composition with only its sibling owners stubbed.
local function transitionPreparation(icons, renderer)
  return setmetatable({
    monIconProvider = icons,
    itemIconProvider = {},
    storageRenderer = renderer,
    mailboxRenderer = {},
    photoAlbumRenderer = {},
    textRenderer = {},
    windowRenderer = {},
    bagRenderer = {},
    heroRenderer = {},
    applicationFrameIndex = 3,
  }, { __index = FieldPresentationResources })
end

-- One field-update tick in production order: the host steps the child
-- with gated input, preparation admits resources, and the host takes the
-- resulting readiness for its input gate and draw route.
local function tickTransitionPc(host, handle, preparation, events)
  host:step(handle, events or {})
  local status = assert(host:status(), "the open child publishes its status")
  local ready, failure =
    FieldPresentationResources.preparePcApplication(preparation, status, { monCatalog = {} })
  host:setPresentationReady(handle, ready)
  return ready, failure, status
end

-- Scopes the host graphics namespace for one replacement test: draws
-- record through the injected fake while every other host capability
-- (filesystem shader sources, timer) keeps its real behavior.
local function scopeTransitionLove(graphics)
  local savedLove = rawget(_G, "love")
  local scopedLove = {}
  for key, value in pairs(savedLove) do
    scopedLove[key] = value
  end
  scopedLove.graphics = graphics
  rawset(_G, "love", scopedLove)
  return savedLove
end

local function drawsImageSinceTransition(graphics, mark, image)
  for index = mark + 1, #graphics.draws do
    if graphics.draws[index].image == image then
      return true
    end
  end
  return false
end

local function admitTransitionBox(host, handle, preparation, message)
  local ready, failure = false, nil
  for _ = 1, 200 do
    ready, failure = tickTransitionPc(host, handle, preparation, {})
    if ready then
      break
    end
    Assert.isNil(failure, message .. ": admission reports no failure while pending")
  end
  Assert.isTrue(ready, message .. ": the box admits before drawing")
  Assert.isNil(failure, message .. ": admission reports no failure")
end

-- A delayed wallpaper keeps the admitted Storage surface on the real host:
-- pending frames repaint the old wallpaper under the admitted plan with
-- input gated, and the new wallpaper appears only once every prerequisite
-- is ready, releasing just the retired leases.
function T.pending_wallpaper_replacement_keeps_drawing_the_admitted_view()
  local pool, inner, pendingPaths = transitionImageOwner()
  local renderer, graphics, manifest = transitionRenderer(pool)
  local icons = {
    prepareKeys = function()
      return true
    end,
  }
  local preparation = transitionPreparation(icons, renderer)
  local mons = transitionMonService()
  local child = openTransitionStorage(mons, 1)
  local host = hostForTransitionChild(child)
  local handle = host:open({ app = "storage", mode = 1 })
  local resources = transitionResources(renderer, nil)
  local savedLove = scopeTransitionLove(graphics)
  local ok, err = pcall(function()
    admitTransitionBox(host, handle, preparation, "first open")
    local uploadsAfterFirst = inner.uploads
    Assert.isTrue(uploadsAfterFirst > 0, "the open box borrows its visuals")
    local oldWallpaper = manifest.storage.wallpapers[0].image
    local oldImage = assert(renderer._images[oldWallpaper], "admission installs its wallpaper")
    local drawsBefore = #graphics.draws
    host:draw(resources)
    Assert.isTrue(
      drawsImageSinceTransition(graphics, drawsBefore, oldImage),
      "the admitted box paints its wallpaper"
    )
    local admittedPlan = host:presentationPlan()
    Assert.notNil(admittedPlan, "the admitted box publishes its plan")

    pendingPaths[manifest.storage.wallpapers[2].image] = true
    local ready, failure = tickTransitionPc(host, handle, preparation, { { type = "action", action = "wallpaper" } })
    Assert.isTrue(ready, "opening the chooser keeps the admitted view ready")
    Assert.isNil(failure, "opening the chooser reports no failure")
    ready, failure =
      tickTransitionPc(host, handle, preparation, { { type = "wallpaper_choice", id = 2 } })
    Assert.isTrue(ready, "highlighting a choice keeps the admitted view ready")
    Assert.isNil(failure, "highlighting a choice reports no failure")
    ready, failure = tickTransitionPc(host, handle, preparation, { { type = "submit" } })
    Assert.isFalse(ready, "a pending wallpaper keeps the host unready")
    Assert.isNil(failure, "a pending wallpaper reports no failure")
    local uploadsAtSubmit = inner.uploads

    for _ = 1, 3 do
      local focusBefore = child:status().focus
      ready, failure =
        tickTransitionPc(host, handle, preparation, { { type = "navigate", direction = "down" } })
      Assert.isFalse(ready, "the replacement stays pending")
      Assert.isNil(failure, "the replacement reports no failure")
      Assert.deepEqual(child:status().focus, focusBefore, "unadmitted input never reaches the child")
      Assert.equal(inner.uploads, uploadsAtSubmit, "pending pixels upload nothing new")
      drawsBefore = #graphics.draws
      host:draw(resources)
      Assert.isTrue(
        drawsImageSinceTransition(graphics, drawsBefore, oldImage),
        "pending frames keep painting the admitted wallpaper"
      )
      Assert.isTrue(host:presentationPlan() == admittedPlan, "pending frames keep the admitted plan")
    end

    pendingPaths[manifest.storage.wallpapers[2].image] = nil
    admitTransitionBox(host, handle, preparation, "wallpaper recovery")
    Assert.equal(inner.uploads, uploadsAtSubmit + 1, "admission uploads only the new wallpaper")
    local newWallpaper = manifest.storage.wallpapers[2].image
    local newImage = assert(renderer._images[newWallpaper], "admission installs the new wallpaper")
    drawsBefore = #graphics.draws
    host:draw(resources)
    Assert.isTrue(
      drawsImageSinceTransition(graphics, drawsBefore, newImage),
      "the admitted replacement paints its wallpaper"
    )
    Assert.isFalse(
      drawsImageSinceTransition(graphics, drawsBefore, oldImage),
      "the retired wallpaper paints no longer"
    )
    local focusBefore = child:status().focus
    tickTransitionPc(host, handle, preparation, { { type = "navigate", direction = "down" } })
    Assert.isTrue(
      child:status().focus.slot ~= focusBefore.slot,
      "admitted input reaches the child again"
    )
    host:close(handle)
    renderer:dispose()
    Assert.equal(inner:stats().outstandingLeases, 0, "closing returns every visual lease")
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

-- A warm wallpaper switch commits synchronously while the host stays
-- ready: the replacement installs before the next draw, and a later
-- pending replacement falls back to the newly admitted view, never the
-- retired one.
function T.warm_wallpaper_replacement_commits_before_drawing_the_new_view()
  local pool, inner, pendingPaths = transitionImageOwner()
  local renderer, graphics, manifest = transitionRenderer(pool)
  local icons = {
    prepareKeys = function()
      return true
    end,
  }
  local preparation = transitionPreparation(icons, renderer)
  local mons = transitionMonService()
  local child = openTransitionStorage(mons, 1)
  local host = hostForTransitionChild(child)
  local handle = host:open({ app = "storage", mode = 1 })
  local resources = transitionResources(renderer, nil)
  local savedLove = scopeTransitionLove(graphics)
  local ok, err = pcall(function()
    admitTransitionBox(host, handle, preparation, "first open")
    local oldWallpaper = manifest.storage.wallpapers[0].image
    local oldImage = assert(renderer._images[oldWallpaper], "admission installs its wallpaper")
    local drawsBefore = #graphics.draws
    host:draw(resources)
    Assert.isTrue(
      drawsImageSinceTransition(graphics, drawsBefore, oldImage),
      "the admitted box paints its wallpaper"
    )

    -- The replacement wallpaper stays unflagged, so every new path
    -- resolves in the same tick while the host is still ready.
    local ready, failure = tickTransitionPc(host, handle, preparation, { { type = "action", action = "wallpaper" } })
    Assert.isTrue(ready, "opening the chooser keeps the admitted view ready")
    Assert.isNil(failure, "opening the chooser reports no failure")
    ready, failure = tickTransitionPc(host, handle, preparation, { { type = "wallpaper_choice", id = 1 } })
    Assert.isTrue(ready, "highlighting a choice keeps the admitted view ready")
    Assert.isNil(failure, "highlighting a choice reports no failure")
    ready, failure = tickTransitionPc(host, handle, preparation, { { type = "submit" } })
    Assert.isTrue(ready, "a resident replacement admits without pending")
    Assert.isNil(failure, "a resident replacement reports no failure")
    local newWallpaper = manifest.storage.wallpapers[1].image
    Assert.notNil(
      renderer._images[newWallpaper],
      "the warm cutover installs the new wallpaper before drawing"
    )
    Assert.isNil(
      renderer._images[oldWallpaper],
      "the warm cutover retires the superseded wallpaper at once"
    )
    local newImage = assert(renderer._images[newWallpaper], "the new wallpaper resolves its lease")
    drawsBefore = #graphics.draws
    host:draw(resources)
    Assert.isTrue(
      drawsImageSinceTransition(graphics, drawsBefore, newImage),
      "the warm replacement paints its wallpaper"
    )
    Assert.isFalse(
      drawsImageSinceTransition(graphics, drawsBefore, oldImage),
      "the retired wallpaper paints no longer"
    )
    local admittedPair = child:presentationPlan(false)
    Assert.notNil(admittedPair, "the warm cutover records its admitted pair")

    -- A later pending replacement falls back to the newly admitted
    -- view, proving the admitted pair tracked the warm cutover.
    pendingPaths[manifest.storage.wallpapers[2].image] = true
    ready, failure = tickTransitionPc(host, handle, preparation, { { type = "action", action = "wallpaper" } })
    Assert.isTrue(ready, "reopening the chooser keeps the admitted view ready")
    Assert.isNil(failure, "reopening the chooser reports no failure")
    ready, failure = tickTransitionPc(host, handle, preparation, { { type = "wallpaper_choice", id = 2 } })
    Assert.isTrue(ready, "highlighting a choice keeps the admitted view ready")
    Assert.isNil(failure, "highlighting a choice reports no failure")
    ready, failure = tickTransitionPc(host, handle, preparation, { { type = "submit" } })
    Assert.isFalse(ready, "a pending wallpaper keeps the host unready")
    Assert.isNil(failure, "a pending wallpaper reports no failure")
    drawsBefore = #graphics.draws
    host:draw(resources)
    Assert.isTrue(
      drawsImageSinceTransition(graphics, drawsBefore, newImage),
      "pending frames keep painting the warm-admitted wallpaper"
    )
    Assert.isFalse(
      drawsImageSinceTransition(graphics, drawsBefore, oldImage),
      "pending frames never revive the retired wallpaper"
    )
    Assert.isTrue(host:presentationPlan() == child:presentationPlan(false), "pending frames serve the recorded pair route")
    host:close(handle)
    renderer:dispose()
    Assert.equal(inner:stats().outstandingLeases, 0, "closing returns every visual lease")
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

-- A delayed icon page cannot invalidate the admitted view: the old page
-- stays borrowed and painted while the new page and wallpaper resolve in
-- either order, and full admission retires only the undesired page with a
-- single visual commit.
function T.delayed_icon_page_keeps_the_admitted_view_and_its_icons_until_admission()
  local pool, inner, pendingPaths = transitionImageOwner()
  local renderer, graphics, manifest = transitionRenderer(pool)
  local icons, demanded = transitionIconProvider(pool, graphics)
  local preparation = transitionPreparation(icons, renderer)
  local mons = transitionMonService()
  local boxed = mons:partyMon(0)
  local stored = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 0, mon = boxed } } }))
  stored.publish()
  local child = openTransitionStorage(mons, 1)
  local host = hostForTransitionChild(child)
  local handle = host:open({ app = "storage", mode = 1 })
  local resources = transitionResources(renderer, icons)
  local savedLove = scopeTransitionLove(graphics)
  local ok, err = pcall(function()
    admitTransitionBox(host, handle, preparation, "first open")
    local oldWallpaper = manifest.storage.wallpapers[0].image
    local oldImage = assert(renderer._images[oldWallpaper], "admission installs its wallpaper")
    local oldPage = assert(icons:handleFor("CHIKORITA/f0"), "admission borrows the old icon page")
    local drawsBefore = #graphics.draws
    host:draw(resources)
    Assert.isTrue(
      drawsImageSinceTransition(graphics, drawsBefore, oldPage.image),
      "the admitted box paints its old icon page"
    )
    local admittedPlan = host:presentationPlan()
    Assert.notNil(admittedPlan, "the admitted box publishes its plan")

    -- The new view needs another icon page and another wallpaper while
    -- the wallpaper resolves last: the old page must survive the wait.
    pendingPaths[manifest.storage.wallpapers[2].image] = true
    local ready, failure = tickTransitionPc(host, handle, preparation, { { type = "action", action = "wallpaper" } })
    Assert.isTrue(ready, "opening the chooser keeps the admitted view ready")
    ready, failure =
      tickTransitionPc(host, handle, preparation, { { type = "wallpaper_choice", id = 2 } })
    Assert.isTrue(ready, "highlighting a choice keeps the admitted view ready")
    ready, failure = tickTransitionPc(host, handle, preparation, { { type = "submit" } })
    Assert.isFalse(ready, "a pending wallpaper keeps the host unready")
    Assert.isNil(failure, "a pending wallpaper reports no failure")
    local factory = CatalogFixture.makeFactory(0x22222222, mons:catalog())
    local partyTotodile = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))
    local boxTotodile = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))
    local partyChange = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 0, mon = partyTotodile } }))
    partyChange.publish()
    local boxChange = assert(mons:preparePcChanges({
      partyRevision = mons:partyRevision(),
      boxRevision = mons:boxRevision(),
    }, { boxUpdates = { { box = 0, slot = 0, mon = boxTotodile } } }))
    boxChange.publish()
    ready, failure = tickTransitionPc(host, handle, preparation, {})
    Assert.isFalse(ready, "the icon turnover keeps the host unready")
    Assert.isNil(failure, "the icon turnover reports no failure")

    for _ = 1, 5 do
      ready, failure = tickTransitionPc(host, handle, preparation, {})
      Assert.isFalse(ready, "the replacement stays pending")
      Assert.isNil(failure, "the replacement reports no failure")
      local demandedNow = demanded[#demanded]
      local holdsOld = false
      for _, key in ipairs(assert(demandedNow, "preparation demands icon keys while pending")) do
        if key == "CHIKORITA/f0" then
          holdsOld = true
        end
      end
      Assert.isTrue(holdsOld, "pending preparation keeps demanding the admitted icon page")
      Assert.notNil(icons:handleFor("CHIKORITA/f0"), "the admitted icon page stays borrowed")
      drawsBefore = #graphics.draws
      host:draw(resources)
      Assert.isTrue(
        drawsImageSinceTransition(graphics, drawsBefore, oldImage),
        "pending frames keep painting the admitted wallpaper"
      )
      Assert.isTrue(
        drawsImageSinceTransition(graphics, drawsBefore, oldPage.image),
        "pending frames keep painting the admitted icon page"
      )
      Assert.isTrue(host:presentationPlan() == admittedPlan, "pending frames keep the admitted plan")
    end

    pendingPaths[manifest.storage.wallpapers[2].image] = nil
    admitTransitionBox(host, handle, preparation, "icon and wallpaper recovery")
    local uploadsAtAdmission = inner.uploads
    local newImage = assert(
      renderer._images[manifest.storage.wallpapers[2].image],
      "admission installs the new wallpaper"
    )
    local newPage = assert(icons:handleFor("TOTODILE/f0"), "admission borrows the new icon page")
    drawsBefore = #graphics.draws
    host:draw(resources)
    Assert.isTrue(
      drawsImageSinceTransition(graphics, drawsBefore, newImage),
      "the admitted replacement paints its wallpaper"
    )
    Assert.isTrue(
      drawsImageSinceTransition(graphics, drawsBefore, newPage.image),
      "the admitted replacement paints its icon page"
    )
    local retired, _ = pcall(function()
      icons:handleFor("CHIKORITA/f0")
    end)
    Assert.isFalse(retired, "admission retires the undesired icon page")
    for _ = 1, 3 do
      ready, failure = tickTransitionPc(host, handle, preparation, {})
      Assert.isTrue(ready, "the admitted replacement stays ready")
      Assert.isNil(failure, "the admitted replacement reports no failure")
    end
    Assert.equal(inner.uploads, uploadsAtAdmission, "one admission performs no second commit")
    host:close(handle)
    renderer:dispose()
    icons:release()
    Assert.equal(inner:stats().outstandingLeases, 0, "closing returns every visual and icon lease")
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

-- The inverse order: a delayed icon page behind an already resolved
-- wallpaper keeps the admitted view drawable too, since the replacement
-- visuals stage without publishing until every prerequisite is ready.
function T.delayed_icon_page_behind_a_resolved_wallpaper_keeps_the_admitted_view()
  local pool, inner, pendingPaths = transitionImageOwner()
  local renderer, graphics, manifest = transitionRenderer(pool)
  local icons, _ = transitionIconProvider(pool, graphics)
  local preparation = transitionPreparation(icons, renderer)
  local mons = transitionMonService()
  local boxed = mons:partyMon(0)
  local stored = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 0, mon = boxed } } }))
  stored.publish()
  local child = openTransitionStorage(mons, 1)
  local host = hostForTransitionChild(child)
  local handle = host:open({ app = "storage", mode = 1 })
  local resources = transitionResources(renderer, icons)
  local savedLove = scopeTransitionLove(graphics)
  local ok, err = pcall(function()
    admitTransitionBox(host, handle, preparation, "first open")
    local oldWallpaper = manifest.storage.wallpapers[0].image
    local oldImage = assert(renderer._images[oldWallpaper], "admission installs its wallpaper")
    local oldPage = assert(icons:handleFor("CHIKORITA/f0"), "admission borrows the old icon page")
    local admittedPlan = host:presentationPlan()
    Assert.notNil(admittedPlan, "the admitted box publishes its plan")

    pendingPaths[MonCache.iconPagePath(1)] = true
    local ready, failure = tickTransitionPc(host, handle, preparation, { { type = "action", action = "wallpaper" } })
    Assert.isTrue(ready, "opening the chooser keeps the admitted view ready")
    ready, failure =
      tickTransitionPc(host, handle, preparation, { { type = "wallpaper_choice", id = 1 } })
    Assert.isTrue(ready, "highlighting a choice keeps the admitted view ready")
    local factory = CatalogFixture.makeFactory(0x33333333, mons:catalog())
    local partyTotodile = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))
    local boxTotodile = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))
    local partyChange = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 0, mon = partyTotodile } }))
    partyChange.publish()
    local boxChange = assert(mons:preparePcChanges({
      partyRevision = mons:partyRevision(),
      boxRevision = mons:boxRevision(),
    }, { boxUpdates = { { box = 0, slot = 0, mon = boxTotodile } } }))
    boxChange.publish()
    ready, failure = tickTransitionPc(host, handle, preparation, { { type = "submit" } })
    Assert.isFalse(ready, "a pending icon page keeps the host unready")
    Assert.isNil(failure, "a pending icon page reports no failure")

    for _ = 1, 3 do
      ready, failure = tickTransitionPc(host, handle, preparation, {})
      Assert.isFalse(ready, "the replacement stays pending")
      Assert.isNil(failure, "the replacement reports no failure")
      Assert.notNil(icons:handleFor("CHIKORITA/f0"), "the admitted icon page stays borrowed")
      local drawsBefore = #graphics.draws
      host:draw(resources)
      Assert.isTrue(
        drawsImageSinceTransition(graphics, drawsBefore, oldImage),
        "pending frames keep painting the admitted wallpaper"
      )
      Assert.isTrue(
        drawsImageSinceTransition(graphics, drawsBefore, oldPage.image),
        "pending frames keep painting the admitted icon page"
      )
      Assert.isTrue(host:presentationPlan() == admittedPlan, "pending frames keep the admitted plan")
    end

    pendingPaths[MonCache.iconPagePath(1)] = nil
    admitTransitionBox(host, handle, preparation, "icon recovery")
    local newImage = assert(
      renderer._images[manifest.storage.wallpapers[1].image],
      "admission installs the new wallpaper"
    )
    local newPage = assert(icons:handleFor("TOTODILE/f0"), "admission borrows the new icon page")
    local drawsBefore = #graphics.draws
    host:draw(resources)
    Assert.isTrue(
      drawsImageSinceTransition(graphics, drawsBefore, newImage),
      "the admitted replacement paints its wallpaper"
    )
    Assert.isTrue(
      drawsImageSinceTransition(graphics, drawsBefore, newPage.image),
      "the admitted replacement paints its icon page"
    )
    host:close(handle)
    renderer:dispose()
    icons:release()
    Assert.equal(inner:stats().outstandingLeases, 0, "closing returns every visual and icon lease")
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

-- A stalled wallpaper keeps the admitted Storage surface on the real host
-- while its panes and frames follow the current display: admitting on a
-- wide display, stalling the replacement, resizing tall, resolving, then
-- stalling again proves the fallback never uses out-of-date host-space
-- rectangles and always falls back to the most recently admitted view.
function T.pending_storage_replacement_reflows_its_admitted_frames_to_the_current_display()
  local pool, inner, pendingPaths = transitionImageOwner()
  local renderer, graphics, manifest = transitionRenderer(pool)
  local icons = {
    prepareKeys = function()
      return true
    end,
  }
  local preparation = transitionPreparation(icons, renderer)
  local mons = transitionMonService()
  local child = openTransitionStorage(mons, 1)
  local host = hostForTransitionChild(child)
  local handle = host:open({ app = "storage", mode = 1 })
  local resources = transitionResources(renderer, nil)
  local savedLove = scopeTransitionLove(graphics)
  local ok, err = pcall(function()
    local StorageInterface = require("game.hgss.src.pc.StorageInterface")
    local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
    local function referencePlan(view, measurement)
      local session = ApplicationPresentation.new(StorageInterface.defaults(manifest))
      local plan = session:resolve(measurement, view)
      session:dispose()
      return plan
    end
    local function assertFollowsCurrentTopology(plan, view, measurement, what)
      local expected = referencePlan(view, measurement)
      Assert.equal(#plan.panes, #expected.panes, what .. " keeps the current pane count")
      Assert.equal(#plan.frames, #expected.frames, what .. " keeps the current frame count")
      Assert.equal(plan.inputKey, expected.inputKey, what .. " keeps the current input key")
      for index, pane in ipairs(plan.panes) do
        local other = expected.panes[index]
        Assert.equal(pane.id, other.id, what .. " keeps the current pane order")
        Assert.equal(pane.interactive, other.interactive, what .. " keeps pane interaction")
        local frame, otherFrame = pane.placement.frame, other.placement.frame
        Assert.deepEqual(
          { frame.x, frame.y, frame.width, frame.height },
          { otherFrame.x, otherFrame.y, otherFrame.width, otherFrame.height },
          what .. " follows the current pane placement"
        )
      end
      for index, frame in ipairs(plan.frames) do
        local other = expected.frames[index]
        local placement, otherPlacement = frame.placement.frame, other.placement.frame
        Assert.deepEqual(
          { placement.x, placement.y, placement.width, placement.height },
          { otherPlacement.x, otherPlacement.y, otherPlacement.width, otherPlacement.height },
          what .. " follows the current frame placement"
        )
      end
    end

    admitTransitionBox(host, handle, preparation, "first open")
    local oldWallpaper = manifest.storage.wallpapers[0].image
    local oldImage = assert(renderer._images[oldWallpaper], "admission installs its wallpaper")
    local admittedView = assert(
      child:status().admittedParentView,
      "the first admission records its parent view"
    )
    local widePlan = assert(host:presentationPlan(), "the admitted box publishes its plan")
    local drawsBefore = #graphics.draws
    host:draw(resources)
    Assert.isTrue(
      drawsImageSinceTransition(graphics, drawsBefore, oldImage),
      "the admitted box paints its wallpaper"
    )

    -- Stage the replacement while its pixels stay held.
    pendingPaths[manifest.storage.wallpapers[2].image] = true
    local ready, failure = tickTransitionPc(host, handle, preparation, { { type = "action", action = "wallpaper" } })
    Assert.isTrue(ready, "opening the chooser keeps the admitted view ready")
    Assert.isNil(failure, "opening the chooser reports no failure")
    ready, failure =
      tickTransitionPc(host, handle, preparation, { { type = "wallpaper_choice", id = 2 } })
    Assert.isTrue(ready, "highlighting a choice keeps the admitted view ready")
    Assert.isNil(failure, "highlighting a choice reports no failure")
    ready, failure = tickTransitionPc(host, handle, preparation, { { type = "submit" } })
    Assert.isFalse(ready, "a pending wallpaper keeps the host unready")
    Assert.isNil(failure, "a pending wallpaper reports no failure")
    local uploadsAtSubmit = inner.uploads

    -- Resize tall while the replacement pends: the admitted view stays,
    -- but its panes and frames must follow the tall measurement.
    local tallMeasurement = transitionDisplayFor("tall")
    setTransitionDisplay(tallMeasurement)
    for _ = 1, 3 do
      local focusBefore = child:status().focus
      ready, failure = tickTransitionPc(host, handle, preparation, { { type = "navigate", direction = "down" } })
      Assert.isFalse(ready, "the replacement stays pending across the resize")
      Assert.isNil(failure, "the replacement reports no failure across the resize")
      Assert.deepEqual(child:status().focus, focusBefore, "unadmitted input never reaches the child")
      Assert.isTrue(
        child:status().admittedParentView == admittedView,
        "the resize keeps the admitted semantic view by identity"
      )
      Assert.equal(inner.uploads, uploadsAtSubmit, "reflow uploads no new pixels")
      local fallback = assert(host:presentationPlan(), "pending frames keep a fallback plan")
      Assert.isTrue(
        fallback == child:presentationPlan(false),
        "host frames and fallback panes share one reflowed plan"
      )
      assertFollowsCurrentTopology(fallback, admittedView, tallMeasurement, "the stalled fallback")
      drawsBefore = #graphics.draws
      host:draw(resources)
      Assert.isTrue(
        drawsImageSinceTransition(graphics, drawsBefore, oldImage),
        "pending tall frames keep painting the admitted wallpaper"
      )
    end
    local tallPlan = assert(host:presentationPlan(), "the tall fallback stays published")
    ready, failure = tickTransitionPc(host, handle, preparation, {})
    Assert.isFalse(ready, "the replacement stays pending on an idle tall tick")
    Assert.isNil(failure, "the idle tall tick reports no failure")
    Assert.isTrue(
      host:presentationPlan() == tallPlan,
      "a steady tall signature keeps the identical fallback plan"
    )

    -- Releasing the held pixels admits the replacement under the current
    -- tall plan immediately.
    pendingPaths[manifest.storage.wallpapers[2].image] = nil
    admitTransitionBox(host, handle, preparation, "wallpaper recovery")
    local newWallpaper = manifest.storage.wallpapers[2].image
    local newImage = assert(renderer._images[newWallpaper], "admission installs the new wallpaper")
    local recoveredPlan = assert(host:presentationPlan(), "the recovery publishes its plan")
    assertFollowsCurrentTopology(
      recoveredPlan,
      child:status().visualView,
      tallMeasurement,
      "the admitted replacement"
    )
    drawsBefore = #graphics.draws
    host:draw(resources)
    Assert.isTrue(
      drawsImageSinceTransition(graphics, drawsBefore, newImage),
      "the admitted replacement paints its wallpaper"
    )
    Assert.isFalse(
      drawsImageSinceTransition(graphics, drawsBefore, oldImage),
      "the retired wallpaper paints no longer"
    )
    local recoveredView = assert(
      child:status().admittedParentView,
      "the recovery records its newly admitted parent"
    )
    Assert.isTrue(
      recoveredView ~= admittedView,
      "the admitted parent tracks the latest cutover"
    )

    -- Another stalled replacement falls back to the newly admitted view
    -- under the restored wide topology, never the retired one.
    pendingPaths[manifest.storage.wallpapers[3].image] = true
    ready, failure = tickTransitionPc(host, handle, preparation, { { type = "action", action = "wallpaper" } })
    Assert.isTrue(ready, "reopening the chooser keeps the admitted view ready")
    ready, failure = tickTransitionPc(host, handle, preparation, { { type = "wallpaper_choice", id = 3 } })
    Assert.isTrue(ready, "highlighting a choice keeps the admitted view ready")
    ready, failure = tickTransitionPc(host, handle, preparation, { { type = "submit" } })
    Assert.isFalse(ready, "a second pending wallpaper keeps the host unready")
    Assert.isNil(failure, "a second pending wallpaper reports no failure")
    local wideMeasurement = transitionDisplayFor("wide")
    setTransitionDisplay(wideMeasurement)
    ready, failure = tickTransitionPc(host, handle, preparation, {})
    Assert.isFalse(ready, "the second replacement stays pending")
    Assert.isNil(failure, "the second replacement reports no failure")
    Assert.isTrue(
      child:status().admittedParentView == recoveredView,
      "the second stall keeps the newly admitted view"
    )
    local secondFallback = assert(host:presentationPlan(), "the second stall keeps a fallback plan")
    assertFollowsCurrentTopology(secondFallback, recoveredView, wideMeasurement, "the second fallback")
    drawsBefore = #graphics.draws
    host:draw(resources)
    Assert.isTrue(
      drawsImageSinceTransition(graphics, drawsBefore, newImage),
      "second-stall frames paint the newly admitted wallpaper"
    )
    Assert.isFalse(
      drawsImageSinceTransition(graphics, drawsBefore, oldImage),
      "second-stall frames never revive the retired wallpaper"
    )
    host:close(handle)
    renderer:dispose()
    Assert.equal(inner:stats().outstandingLeases, 0, "closing returns every visual lease")
  end)
  clearTransitionDisplay()
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

-- An unavailable display hides the admitted parent instead of painting
-- outside the host, and a supported topology brings the same admitted
-- view back under new placements while its icon pages stay borrowed.
function T.blocked_display_hides_the_admitted_parent_until_a_supported_topology_returns()
  local pool, inner, pendingPaths = transitionImageOwner()
  local renderer, graphics, manifest = transitionRenderer(pool)
  local icons, demanded = transitionIconProvider(pool, graphics)
  local preparation = transitionPreparation(icons, renderer)
  local mons = transitionMonService()
  local boxed = mons:partyMon(0)
  local stored = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 0, mon = boxed } } }))
  stored.publish()
  local child = openTransitionStorage(mons, 1)
  local host = hostForTransitionChild(child)
  local handle = host:open({ app = "storage", mode = 1 })
  local resources = transitionResources(renderer, icons)
  local savedLove = scopeTransitionLove(graphics)
  local ok, err = pcall(function()
    admitTransitionBox(host, handle, preparation, "first open")
    local oldWallpaper = manifest.storage.wallpapers[0].image
    local oldImage = assert(renderer._images[oldWallpaper], "admission installs its wallpaper")
    local oldPage = assert(icons:handleFor("CHIKORITA/f0"), "admission borrows the old icon page")
    local admittedView = assert(
      child:status().admittedParentView,
      "the first admission records its parent view"
    )
    Assert.notNil(host:presentationPlan(), "the admitted box publishes its plan")

    -- The replacement needs another icon page while the wallpaper it
    -- also needs already resolves: the old page must survive the wait.
    pendingPaths[MonCache.iconPagePath(1)] = true
    local ready, failure = tickTransitionPc(host, handle, preparation, { { type = "action", action = "wallpaper" } })
    Assert.isTrue(ready, "opening the chooser keeps the admitted view ready")
    ready, failure =
      tickTransitionPc(host, handle, preparation, { { type = "wallpaper_choice", id = 1 } })
    Assert.isTrue(ready, "highlighting a choice keeps the admitted view ready")
    local factory = CatalogFixture.makeFactory(0x44444444, mons:catalog())
    local partyTotodile = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))
    local boxTotodile = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))
    local partyChange = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 0, mon = partyTotodile } }))
    partyChange.publish()
    local boxChange = assert(mons:preparePcChanges({
      partyRevision = mons:partyRevision(),
      boxRevision = mons:boxRevision(),
    }, { boxUpdates = { { box = 0, slot = 0, mon = boxTotodile } } }))
    boxChange.publish()
    ready, failure = tickTransitionPc(host, handle, preparation, { { type = "submit" } })
    Assert.isFalse(ready, "a pending icon page keeps the host unready")
    Assert.isNil(failure, "a pending icon page reports no failure")
    local uploadsAtSubmit = inner.uploads

    -- A display with no drawable Storage placement publishes no panes or
    -- frames instead of reusing the old wide rectangles.
    setTransitionDisplay(transitionDisplayFor("blocked"))
    for _ = 1, 3 do
      ready, failure = tickTransitionPc(host, handle, preparation, {})
      Assert.isFalse(ready, "the replacement stays pending while blocked")
      Assert.isNil(failure, "the blocked wait reports no failure")
      Assert.isTrue(
        child:status().admittedParentView == admittedView,
        "the blocked display keeps the admitted semantic view"
      )
      local fallback = assert(host:presentationPlan(), "the blocked wait keeps a fallback plan")
      Assert.equal(#fallback.panes, 0, "an unavailable display publishes no panes")
      Assert.equal(#fallback.frames, 0, "an unavailable display publishes no outer frames")
      Assert.equal(
        fallback.inputKey,
        "pc-storage-inactive",
        "an unavailable display publishes the inactive plan"
      )
      Assert.equal(inner.uploads, uploadsAtSubmit, "the blocked wait uploads no new pixels")
      local demandedNow = demanded[#demanded]
      local holdsOld = false
      for _, key in ipairs(assert(demandedNow, "preparation demands icon keys while blocked")) do
        if key == "CHIKORITA/f0" then
          holdsOld = true
        end
      end
      Assert.isTrue(holdsOld, "blocked preparation keeps demanding the admitted icon page")
      Assert.notNil(icons:handleFor("CHIKORITA/f0"), "the admitted icon page stays borrowed")
      local drawsBefore = #graphics.draws
      host:draw(resources)
      Assert.isFalse(
        drawsImageSinceTransition(graphics, drawsBefore, oldImage),
        "blocked frames paint no out-of-host wallpaper"
      )
    end

    -- A supported topology brings the same admitted view back under new
    -- placements without admitting the pending child.
    local tallMeasurement = transitionDisplayFor("tall")
    setTransitionDisplay(tallMeasurement)
    ready, failure = tickTransitionPc(host, handle, preparation, {})
    Assert.isFalse(ready, "the replacement stays pending after the restore")
    Assert.isNil(failure, "the restore reports no failure")
    Assert.isTrue(
      child:status().admittedParentView == admittedView,
      "the restore keeps the admitted semantic view"
    )
    local restored = assert(host:presentationPlan(), "the restore publishes a fallback plan")
    Assert.isTrue(#restored.panes > 0, "the restored display places the admitted panes again")
    Assert.isTrue(
      restored.inputKey ~= "pc-storage-inactive",
      "the restored display leaves the inactive plan"
    )
    local drawsBefore = #graphics.draws
    host:draw(resources)
    Assert.isTrue(
      drawsImageSinceTransition(graphics, drawsBefore, oldImage),
      "restored frames paint the admitted wallpaper again"
    )
    Assert.isTrue(
      drawsImageSinceTransition(graphics, drawsBefore, oldPage.image),
      "restored frames paint the admitted icon page again"
    )

    pendingPaths[MonCache.iconPagePath(1)] = nil
    admitTransitionBox(host, handle, preparation, "icon recovery")
    local newImage = assert(
      renderer._images[manifest.storage.wallpapers[1].image],
      "admission installs the new wallpaper"
    )
    local newPage = assert(icons:handleFor("TOTODILE/f0"), "admission borrows the new icon page")
    drawsBefore = #graphics.draws
    host:draw(resources)
    Assert.isTrue(
      drawsImageSinceTransition(graphics, drawsBefore, newImage),
      "the admitted replacement paints its wallpaper"
    )
    Assert.isTrue(
      drawsImageSinceTransition(graphics, drawsBefore, newPage.image),
      "the admitted replacement paints its icon page"
    )
    host:close(handle)
    renderer:dispose()
    icons:release()
    Assert.equal(inner:stats().outstandingLeases, 0, "closing returns every visual and icon lease")
  end)
  clearTransitionDisplay()
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

return { tests = T }
