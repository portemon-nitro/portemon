-- Application presentation dispatch: the production-built per-instance
-- presenter map routes each presentable application id to its concrete
-- renderer, faults on an unknown id instead of falling back to another
-- surface, and releases owned resources exactly once. Pokemon, Trainer
-- Card, and Bag are all explicitly mapped through the real
-- FieldPresentationResources composition; draws borrow the composed
-- resources and never acquire them.

local Assert = require("tests.support.Assert")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")

local T = {}

local TARGET_MODULE = "game.hgss.src.field.FieldPresentationResources"

local CONSTRUCTOR_MODULES = {
  "libs.assets.src.BagCache",
  "libs.assets.src.MartCache",
  "libs.assets.src.PartyCache",
  "libs.assets.src.PcCache",
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
    ["libs.hgss.src.presentation.BagHeroRenderer"] = {
      new = function(_)
        return releasable(calls, "hero")
      end,
    },
    ["libs.hgss.src.ui.BagRenderer"] = {
      new = function(_)
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
      new = function(_)
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
      new = function(_)
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
        return releasable(calls, "pcStorage")
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
          calls.iconImage = (calls.iconImage or 0) + 1
          return "borrowed-icon-image"
        end
        function provider:prepareKeys(_)
          calls.iconPrepareCalls = (calls.iconPrepareCalls or 0) + 1
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

function T.pokemon_naming_renderer_is_prepared_lazily_and_borrows_shared_mon_icons()
  local sink, calls = {}, {}
  local savedLove = rawget(_G, "love")
  rawset(_G, "love", { graphics = require("tests.support.FakeGraphics").new({}) })
  local ok, err = pcall(function()
    withProductionComposition(sink, calls, compositionRuntime(), function(resources)
      Assert.isNil(calls.namingConstructed, "ordinary field construction does not acquire naming chrome")
      Assert.isNil(calls.iconImage, "ordinary field construction does not acquire naming images")
      Assert.isNil(calls.iconQuadCount, "ordinary field construction does not acquire naming quads")

      calls.iconPageReady = false
      local ready, failure = resources:preparePokemonNamingSubject({ iconKey = "species:1:form:0" })
      Assert.isFalse(ready, "pending mon icon pages keep naming preparation pending")
      Assert.isNil(failure, "pending mon icon pages have no failure")
      Assert.isNil(calls.namingConstructed, "pending preparation creates no naming renderer")
      Assert.isNil(calls.iconQuadCount, "pending preparation creates no icon quads")

      calls.iconPageFailure = "page failed"
      ready, failure = resources:preparePokemonNamingSubject({ iconKey = "species:1:form:0" })
      Assert.isFalse(ready, "failed mon icon pages do not prepare naming")
      Assert.equal(failure, "page failed", "provider failure is returned unchanged")
      Assert.isNil(calls.namingConstructed, "failed preparation creates no naming renderer")
      Assert.isNil(calls.iconQuadCount, "failed preparation creates no icon quads")

      calls.iconPageReady = true
      ready, failure = resources:preparePokemonNamingSubject({ iconKey = "species:1:form:0" })
      Assert.isTrue(ready, "a ready icon page prepares naming")
      Assert.isNil(failure, "ready preparation has no failure")
      Assert.equal(calls.namingConstructed, 1, "first ready preparation creates naming renderer once")
      Assert.equal(calls.iconDimensions, "species:1:form:0", "the naming subject resolves through shared mon icons")
      resources:pokemonNamingRenderer()
      Assert.equal(calls.namingConstructed, 1, "the renderer accessor is a pure read")
      resources:preparePokemonNamingSubject({ iconKey = "species:1:form:0" })
      resources:preparePokemonNamingSubject({ iconKey = "species:2:form:0" })
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
        condition = { currentHp = 20, status = 0 },
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
      Assert.equal(#sink, 1, "the wait renders exactly one message")
      Assert.equal(sink[1][1], "text", "pending party icons render as text, never icon getters")
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
      resources:drawApplication(FieldApplicationIds.POKEMON, {
        child = {
          preparationState = "failed",
          preparationError = "boom",
          layout = { frame = frame },
          presentation = plan,
        },
      }, drawRuntime())
      Assert.equal(#sink, 2, "the failure renders exactly one message")
      Assert.equal(sink[1][1], "text", "failed party icons render as text, never icon getters")
      Assert.isTrue(
        tostring(sink[2][2]):find("boom", 1, true) ~= nil,
        "the failure message carries the preparation cause"
      )
      resources:dispose()
    end)
  end)
  rawset(_G, "love", savedLove)
  if not ok then
    error(err, 0)
  end
end

-- A pending producer wait status draws through the app-exit transition:
-- the wait text renders from the producer layout and the shutter is
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
      Assert.equal(#sink, 1, "the pending wait renders exactly one message")
      Assert.equal(sink[1][1], "text", "pending party icons render as text, never icon getters")
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

-- A failed producer wait status uses the same drawable contract: the
-- failure text stays visible beneath the same party transition plan and
-- disposal still releases preparation exactly once.
function T.failed_producer_wait_draws_through_the_app_exit_transition()
  local screen, cancelCount = waitingPartyChild(false, "icons unavailable")
  local waiting = screen:status()
  Assert.equal(waiting.preparationState, "failed", "the producer child under test actually failed")
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
      Assert.equal(#sink, 1, "the failed wait renders exactly one message")
      Assert.equal(sink[1][1], "text", "failed party icons render as text, never icon getters")
      Assert.isTrue(
        tostring(sink[1][2]):find("icons unavailable", 1, true) ~= nil,
        "the failure message carries the preparation cause"
      )
      Assert.equal(#graphics.rectangles, 2, "the outgoing shutter draws its two bars over the failed wait")
      local contentFrame = assert(waiting.presentation.panes[1].placement.frame, "the wait plan carries its frame")
      Assert.deepEqual(
        graphics.scissorIntersections[1].effective,
        { contentFrame.x, contentFrame.y, contentFrame.width, contentFrame.height },
        "the failed wait shutter stays inside its resolved content pane"
      )
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
    Assert.equal(#sink, 1, "the bag-hosted party wait renders exactly one message")
    Assert.equal(sink[1][1], "text", "pending party icons render as text, never icon getters")
    resources:drawApplication(FieldApplicationIds.BAG, {
      open = true,
      root = "bag",
      page = "party_give_target",
      child = { preparationState = "failed", preparationError = "boom", layout = { frame = frame } },
    }, drawRuntime())
    Assert.equal(#sink, 2, "the bag-hosted party failure renders exactly one message")
    Assert.equal(sink[1][1], "text", "failed party icons render as text, never icon getters")
    Assert.isTrue(
      tostring(sink[2][2]):find("boom", 1, true) ~= nil,
      "the failure message carries the preparation cause"
    )
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
      Assert.equal(calls.text, 1, "repeat disposal never releases the text renderer twice")
      Assert.equal(calls.renderer, 1, "repeat disposal never releases the field renderer twice")
      Assert.equal(calls.staticEffect, 2, "repeat disposal releases each static effect renderer once")
      Assert.equal(calls.terrain, 1, "repeat disposal never releases the terrain effect renderer twice")
      Assert.equal(calls.emote, 1, "repeat disposal never releases the emote renderer twice")
      Assert.equal(calls.pool, 2, "repeat disposal releases each asset pool once")
      Assert.equal(calls.queue, 1, "repeat disposal releases the owned image queue exactly once")
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

return { tests = T }
