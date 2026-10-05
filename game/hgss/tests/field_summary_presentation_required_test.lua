-- Field-lifetime Summary presentation through the real composition root:
-- construction installs exactly one preparation owner plus its runtime
-- binding or fails visibly, the presenter forwards the ready bundle
-- unchanged, disposal unbinds and releases exactly once, and Party and
-- move-picker round trips keep their parent/result contracts over the
-- installed binding. Every non-Summary constructor collaborator is
-- doubled; the Summary owner, renderer, manifest, and binding seam stay
-- real, so no fallback path can satisfy these scenarios.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeGraphics = require("tests.support.FakeGraphics")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local SummaryAcceptanceFixture = require("tests.support.SummaryAcceptanceFixture")

local T = {}

local FPR_MODULE = "game.hgss.src.field.FieldPresentationResources"

local CONSTRUCTOR_MODULES = {
  "libs.assets.src.BagCache",
  "libs.assets.src.MartCache",
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
  "libs.hgss.src.presentation.MonIconAssetProvider",
  "libs.hgss.src.presentation.AssetPreparationQueue",
  "libs.hgss.src.presentation.ItemIconAssetProvider",
}

---@return table<string, unknown> constructor double tolerating any borrowed use
local function genericInstance()
  local instance = {}
  setmetatable(instance, {
    __index = function(self, key)
      local function ignore(_)
        return nil
      end
      self[key] = ignore
      return ignore
    end,
  })
  return instance
end

---@param helper table<string, unknown> preparation doubles backing the real Summary owner
---@param opts table<string, string>? failure injection (summaryManifest = "invalid" serves a stale manifest shape)
---@return table<string, table<string, unknown>> module doubles
local function constructorDoubles(helper, opts)
  local summaryCache = nil
  if opts ~= nil and opts.summaryManifest == "invalid" then
    local realCache = require("libs.assets.src.SummaryCache")
    summaryCache = setmetatable({
      loadManifest = function(_)
        return { schema = "g4-summary-manifest-v1" }
      end,
    }, { __index = realCache })
  end
  local modules = {
    ["libs.assets.src.BagCache"] = {
      loadManifest = function(_)
        return { compiled = true }
      end,
    },
    ["libs.assets.src.MartCache"] = {
      loadManifest = function(_)
        return { compiled = true }
      end,
    },
    -- PartyCache stays real: the production composition reads the party
    -- manifest directly for its screen renderer and badge realization.
    -- The Summary preparation owner stays real, so its queue and icon
    -- collaborators keep production behavior instead of nil answers.
    ["libs.hgss.src.presentation.AssetPreparationQueue"] = {
      new = function(_)
        return helper.preparationQueue
      end,
    },
    ["libs.hgss.src.presentation.MonIconAssetProvider"] = {
      new = function(_)
        return helper.icons
      end,
    },
  }
  if summaryCache ~= nil then
    modules["libs.assets.src.SummaryCache"] = summaryCache
  end
  for _, name in ipairs(CONSTRUCTOR_MODULES) do
    if modules[name] == nil then
      modules[name] = {
        new = function(_)
          return genericInstance()
        end,
      }
    end
  end
  return modules
end

---@param versionId string ready game version behind the Summary family
---@param helper table<string, unknown> preparation doubles
---@return table<string, unknown> production-shaped presentation runtime
local function compositionRuntime(versionId, helper)
  local runtime = {
    cacheFs = CacheFs.forVersion(versionId),
    uiManifest = FieldUiFixture.manifest(),
    playerData = { options = { textFrame = 0 } },
    windowStyles = {},
    fieldEntranceIndicatorAsset = {
      model = {},
      effects = { surf_attachment = { presentation = {}, model = {} } },
    },
    fieldEmoteModels = {},
    fieldEffectAssets = {},
    fieldTerrainEffectController = {
      setModelFactory = function(_, _)
      end,
    },
    derivedAssets = helper.derivedAssets,
    bindSummaryCalls = 0,
    unbindSummaryCalls = {},
    bindPartyCalls = 0,
    unbindPartyCalls = {},
  }
  runtime.bindPartyIconPreparation = function(_, _, _)
    runtime.bindPartyCalls = runtime.bindPartyCalls + 1
    return runtime.bindPartyCalls
  end
  runtime.unbindPartyIconPreparation = function(_, binding)
    runtime.unbindPartyCalls[#runtime.unbindPartyCalls + 1] = binding
  end
  -- The recording Summary seam mirrors the production runtime binding:
  -- one live acquire callback with an identity, removed only by its own
  -- identity so a stale unbind can never drop a replacement owner.
  runtime.bindSummaryPreparation = function(_, acquire)
    assert(type(acquire) == "function", "summary preparation binding requires its acquire function")
    assert(runtime._summaryPreparation == nil, "one summary preparation binding owns the presented lifetime")
    runtime.bindSummaryCalls = runtime.bindSummaryCalls + 1
    runtime._summaryPreparation = { id = runtime.bindSummaryCalls, acquire = acquire }
    return runtime._summaryPreparation.id
  end
  runtime.unbindSummaryPreparation = function(_, binding)
    runtime.unbindSummaryCalls[#runtime.unbindSummaryCalls + 1] = binding
    local current = runtime._summaryPreparation
    if current ~= nil and current.id == binding then
      runtime._summaryPreparation = nil
    end
  end
  return runtime
end

---@return string ready game version whose Summary family is published
local function readyVersion()
  local versions = SummaryAcceptanceFixture.readySummaryVersions()
  Assert.isTrue(#versions >= 1, "the prepared cache publishes the Summary family")
  return versions[1]
end

-- Installs constructor doubles, swaps the host graphics namespace for a
-- recording fake (the real filesystem stays so cache reads keep working),
-- requires the real presentation composition fresh, and runs the callback.
-- Every replaced module entry and the graphics namespace are restored even
-- when construction or the callback fails.
---@param runtime table<string, unknown> production-shaped presentation runtime
---@param helper table<string, unknown> preparation doubles backing the real Summary owner
---@param callback fun(resources: table<string, unknown>)
---@param opts table<string, string>? failure injection passed to the doubles
local function withComposition(runtime, helper, callback, opts)
  local loveGlobal = assert(rawget(_G, "love"), "field presentation tests run under the host graphics owner")
  local savedGraphics = loveGlobal.graphics
  local modules = constructorDoubles(helper, opts)
  local names = {}
  for _, name in ipairs(CONSTRUCTOR_MODULES) do
    names[#names + 1] = name
  end
  if modules["libs.assets.src.SummaryCache"] ~= nil then
    names[#names + 1] = "libs.assets.src.SummaryCache"
  end
  local saved = {}
  for _, name in ipairs(names) do
    saved[name] = package.loaded[name]
    package.loaded[name] = modules[name]
  end
  package.loaded[FPR_MODULE] = nil
  loveGlobal.graphics = helper.graphics
  local ok, err = pcall(function()
    local FieldPresentationResources = require(FPR_MODULE)
    local resources = FieldPresentationResources.new(runtime)
    callback(resources)
  end)
  loveGlobal.graphics = savedGraphics
  for _, name in ipairs(names) do
    package.loaded[name] = saved[name]
  end
  package.loaded[FPR_MODULE] = nil
  if not ok then
    error(err, 0)
  end
end

---@param runtime table<string, unknown> recording presentation runtime
---@param counters table<string, integer> lease counters
---@return fun(): table<string, unknown> lease factory resolving the installed binding
local function acquireThroughBinding(runtime, counters)
  return function()
    local binding = assert(runtime._summaryPreparation, "summary opens require the presented preparation binding")
    local lease = assert(binding.acquire(), "the installed owner hands out per-open leases")
    counters.leases = counters.leases + 1
    local original = assert(lease.release, "leases release idempotently")
    local counted = false
    lease.release = function(self)
      if not counted then
        counted = true
        counters.releases = counters.releases + 1
      end
      return original(self)
    end
    return lease
  end
end

function T.required_construction_binds_once_and_dispose_unbinds_and_releases_once()
  local versionId = readyVersion()
  local helper = SummaryAcceptanceFixture.preparationDoubles({})
  local runtime = compositionRuntime(versionId, helper)
  withComposition(runtime, helper, function(resources)
    Assert.notNil(resources, "valid Summary setup constructs the field presentation")
    Assert.notNil(resources.summaryResources, "construction installs the Summary preparation owner")
    Assert.notNil(resources.summaryRenderer, "construction installs the Summary pane renderer")
    Assert.notNil(resources._summaryBinding, "construction installs the runtime preparation binding")
    Assert.equal(runtime.bindSummaryCalls, 1, "construction binds exactly one preparation owner")
    local bindingId = assert(resources._summaryBinding, "construction installs the runtime preparation binding")
    local owner = assert(resources.summaryResources, "construction installs the Summary preparation owner")
    local releases = 0
    local original = assert(owner.release, "the field owner releases idempotently")
    owner.release = function(self)
      releases = releases + 1
      return original(self)
    end
    resources:dispose()
    Assert.deepEqual(runtime.unbindSummaryCalls, { bindingId }, "disposal unbinds the installed binding identity")
    Assert.isNil(runtime._summaryPreparation, "disposal clears the runtime binding")
    Assert.equal(releases, 1, "disposal releases the field owner exactly once")
    resources:dispose()
    Assert.equal(#runtime.unbindSummaryCalls, 1, "repeat disposal unbinds nothing again")
    Assert.equal(releases, 1, "repeat disposal releases nothing again")
  end)
end

function T.missing_summary_manifest_fails_construction_without_leaving_a_binding()
  local versionId = readyVersion()
  local helper = SummaryAcceptanceFixture.preparationDoubles({})
  local runtime = compositionRuntime(versionId, helper)
  local constructed = nil
  local ok, err = pcall(
    withComposition,
    runtime,
    helper,
    function(resources)
      constructed = resources
    end,
    { summaryManifest = "invalid" }
  )
  Assert.isFalse(ok, "a stale Summary manifest fails field construction: " .. tostring(err))
  Assert.isNil(constructed, "a failed construction publishes no live field owner")
  Assert.equal(runtime.bindSummaryCalls, 0, "a failed construction installs no Summary binding")
  Assert.isNil(runtime._summaryPreparation, "a failed construction leaves no runtime binding behind")
end

function T.summary_construction_failure_releases_earlier_resources()
  local versionId = readyVersion()
  local helper = SummaryAcceptanceFixture.preparationDoubles({})
  local runtime = compositionRuntime(versionId, helper)
  local constructed = nil
  local ok, err = pcall(
    withComposition,
    runtime,
    helper,
    function(resources)
      constructed = resources
    end,
    { summaryManifest = "invalid" }
  )
  Assert.isFalse(ok, "a stale Summary manifest fails field construction: " .. tostring(err))
  Assert.isNil(constructed, "a failed construction publishes no live field owner")
  Assert.equal(runtime.bindPartyCalls, 1, "the party binding installs before the Summary block runs")
  Assert.deepEqual(runtime.unbindPartyCalls, { 1 }, "outer cleanup unbinds the earlier party binding")
  Assert.equal(runtime.bindSummaryCalls, 0, "a failed construction installs no Summary binding")
end

function T.stale_dispose_keeps_a_replacement_binding()
  local versionId = readyVersion()
  local helper = SummaryAcceptanceFixture.preparationDoubles({})
  local runtime = compositionRuntime(versionId, helper)
  withComposition(runtime, helper, function(resources)
    Assert.notNil(resources, "valid Summary setup constructs the field presentation")
    local bindingId = assert(resources._summaryBinding, "construction installs the runtime preparation binding")
    resources:dispose()
    Assert.deepEqual(runtime.unbindSummaryCalls, { bindingId }, "disposal unbinds the installed binding identity")
    runtime._summaryPreparation = { id = 9999, acquire = function()
      error("a stale owner never serves a replacement lease", 0)
    end }
    resources:dispose()
    Assert.equal(#runtime.unbindSummaryCalls, 1, "repeat disposal unbinds nothing again")
    Assert.notNil(runtime._summaryPreparation, "repeat disposal keeps the replacement binding")
    Assert.equal(
      runtime._summaryPreparation.id,
      9999,
      "repeat disposal leaves the replacement binding untouched"
    )
    runtime._summaryPreparation = nil
  end)
end

function T.missing_summary_binding_seam_fails_construction()
  local versionId = readyVersion()
  local helper = SummaryAcceptanceFixture.preparationDoubles({})
  local runtime = compositionRuntime(versionId, helper)
  runtime.bindSummaryPreparation = nil
  runtime.unbindSummaryPreparation = nil
  local constructed = nil
  local ok, err = pcall(withComposition, runtime, helper, function(resources)
    constructed = resources
  end)
  Assert.isFalse(ok, "a runtime without the Summary seam fails field construction: " .. tostring(err))
  Assert.isNil(constructed, "a failed construction publishes no live field owner")
end

function T.summary_draw_forwards_the_ready_bundle_unchanged()
  local versionId = readyVersion()
  local helper = SummaryAcceptanceFixture.preparationDoubles({})
  local runtime = compositionRuntime(versionId, helper)
  withComposition(runtime, helper, function(resources)
    Assert.notNil(resources, "valid Summary setup constructs the field presentation")
    local ready = { marker = "field-required-bundle-identity" }
    local forwarded = nil
    local mainPlacement = LayoutGeometry.centeredFit({ x = 48, y = 36, width = 256, height = 192 }, 256, 192)
    local subPlacement = LayoutGeometry.centeredFit({ x = 420, y = 180, width = 256, height = 192 }, 256, 192)
    local plan = {
      panes = {
        { id = "main", placement = mainPlacement, interactive = true },
        { id = "sub", placement = subPlacement, interactive = false },
      },
      frames = {},
      content = {},
      inputKey = "summary",
      render = function(borrowed, _, _)
        forwarded = borrowed
      end,
      mapInput = function()
        return nil
      end,
    }
    local status = { preparationState = "ready", resources = ready, presentation = plan }
    resources:drawApplication(FieldApplicationIds.POKEMON, { child = status }, {})
    local drawn = assert(forwarded, "the Summary branch reaches its render callback")
    Assert.isTrue(drawn.summaryBundle == ready, "the presenter forwards the exact ready bundle identity")
    Assert.isNil(drawn.summaryBundle.badgeImage, "no party badge substitute rides the Summary bundle")
    Assert.isNil(drawn.summaryBundle.partyManifest, "no party manifest graft rides the Summary bundle")
    resources:dispose()
  end)
end

function T.field_composition_carries_no_party_badge_substitute()
  local versionId = readyVersion()
  local helper = SummaryAcceptanceFixture.preparationDoubles({})
  local runtime = compositionRuntime(versionId, helper)
  withComposition(runtime, helper, function(resources)
    Assert.notNil(resources, "valid Summary setup constructs the field presentation")
    Assert.isNil(resources.summaryBadgeImages, "the field owns no Summary badge images")
    Assert.isNil(resources._summaryPartyManifest, "the field borrows no party manifest for Summary leaves")
    resources:dispose()
  end)
end

---@param class string host layout class under test
---@return table<string, unknown> measured display facts for the class
local function measurementFor(class)
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  if class == "dualDisplay" then
    return {
      width = 512,
      height = 384,
      topology = ScreenTopology.dualDisplay({
        id = "world",
        rect = { x = 0, y = 0, width = 256, height = 192 },
        role = "world",
        touch = false,
      }, {
        id = "aux",
        rect = { x = 256, y = 0, width = 256, height = 192 },
        role = "auxiliary",
        touch = true,
      }),
      pixelRatio = 1,
      signature = "field-summary-required:dual",
    }
  end
  return {
    width = 256,
    height = 192,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = "field-summary-required:nativeLike",
  }
end

---@param versionId string ready game version behind the Summary family
---@param summaryManifest table<string, unknown> validated Summary family
---@param runtime table<string, unknown> recording presentation runtime
---@param counters table<string, integer> lease counters
---@return table<string, unknown> rig driving the production party flow
local function openProductionPartyFlow(versionId, summaryManifest, runtime, counters)
  local PokemonMenuFlow = require("game.hgss.src.field.PokemonMenuFlow")
  local BagCursor = require("libs.hgss.src.items.BagCursor")
  local HgssBagService = require("libs.hgss.src.items.HgssBagService")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local PartyActions = require("libs.hgss.src.field.PartyActions")
  local PartyCache = require("libs.assets.src.PartyCache")
  local service = SummaryAcceptanceFixture.openService()
  SummaryAcceptanceFixture.gift(service, "CHIKORITA", 12)
  SummaryAcceptanceFixture.gift(service, "TOTODILE", 12)
  local context = SummaryAcceptanceFixture.displayContext(summaryManifest, service:partyCount())
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local flow = PokemonMenuFlow.new({
    root = "party",
    mons = service,
    bag = bag,
    bagCursor = BagCursor.new(),
    partyActions = PartyActions.new({ mons = service, bag = bag }),
    fieldMoves = {
      check = function(_)
        return { kind = "ok" }
      end,
    },
    assets = {
      bagManifest = {},
      partyManifest = PartyCache.loadManifest(CacheFs.forVersion(versionId)),
      summaryManifest = summaryManifest,
      uiManifest = FieldUiFixture.manifest(),
      monCatalog = service:catalog(),
      itemCatalog = bag:catalog(),
      heroGender = "male",
    },
    measureDisplay = function()
      return measurementFor("nativeLike")
    end,
    prepareIcons = function(_)
      return true, nil
    end,
    cancelIconPreparation = function()
    end,
    textPolicy = { interGlyphDelay = 0, glyphBudget = 512, abAcceleration = true },
    summaryContext = function()
      return context
    end,
    readSummaryNavigation = function()
      return nil
    end,
    acquireSummaryPreparation = acquireThroughBinding(runtime, counters),
  })
  return { flow = flow, service = service, bag = bag }
end

---@param rig table<string, unknown> production flow rig
---@return table<string, unknown> live child status
local function flowChild(rig)
  local flow = assert(rig.flow, "the rig carries its production flow")
  local status = flow:status()
  Assert.isTrue(status.open, "the production menu flow stays open")
  return assert(status.child, "the production flow carries its live child")
end

---@param rig table<string, unknown> production flow rig
local function waitPartyInteractive(rig)
  for _ = 1, 30 do
    if flowChild(rig).phase == "interactive" then
      return
    end
    rig.flow:updateFixed({})
  end
  error("the production party never turns interactive", 0)
end

function T.party_summary_round_trip_returns_to_the_displayed_member_over_the_binding()
  local versionId = readyVersion()
  local _, summaryManifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)
  local helper = SummaryAcceptanceFixture.preparationDoubles({})
  local runtime = compositionRuntime(versionId, helper)
  withComposition(runtime, helper, function(resources)
    Assert.notNil(resources, "valid Summary setup constructs the field presentation")
    Assert.isNil(resources.summaryBadgeImages, "the journey needs no party badge substitute")
    local counters = { leases = 0, releases = 0 }
    local rig = openProductionPartyFlow(versionId, summaryManifest, runtime, counters)
    local flow = rig.flow
    local partyRevision = rig.service:partyRevision()
    local bagRevision = rig.bag:revision()
    waitPartyInteractive(rig)
    flow:updateFixed({})
    flow:updateFixed({})
    flow:updateFixed({ { type = "confirm" } })
    local child = flowChild(rig)
    Assert.equal(child.state, "context", "confirming the focused member opens its context menu")
    local menu = assert(child.menu, "the context menu stays open")
    Assert.equal(menu[1].kind, "summary", "the source party menu lists the Summary first")
    flow:updateFixed({ { type = "navigate", direction = "down" } })
    flow:updateFixed({ { type = "navigate", direction = "up" } })
    flow:updateFixed({ { type = "confirm" } })
    local staged = flow:status()
    for _ = 1, 12 do
      if staged.transition ~= nil then
        break
      end
      flow:updateFixed({})
      staged = flow:status()
    end
    Assert.notNil(staged.transition, "opening the Summary stages its exit transition")
    local firstCoefficient = assert(
      staged.transition.brightnessCoefficient,
      "the Summary exit carries its brightness coefficient"
    )
    local exitCoefficients = { firstCoefficient }
    for _ = 1, 24 do
      flow:updateFixed({})
      local status = flow:status()
      if status.transition == nil then
        break
      end
      exitCoefficients[#exitCoefficients + 1] = assert(
        status.transition.brightnessCoefficient,
        "the Summary exit carries its brightness coefficient"
      )
    end
    Assert.deepEqual(
      exitCoefficients,
      { 0, 2, 5, 7, 10, 13, 16 },
      "the Summary exit fades both panes without the sibling shutter"
    )
    Assert.equal(flow:status().page, "summary", "the nested Summary owns the replacement")
    local entryCoefficients = {}
    for _ = 1, 40 do
      flow:updateFixed({})
      local nested = flowChild(rig)
      if nested.entryFade ~= nil then
        entryCoefficients[#entryCoefficients + 1] = nested.entryFade
      end
      if nested.wrapperPhase == "active" then
        break
      end
    end
    local active = flowChild(rig)
    Assert.equal(active.wrapperPhase, "active", "the nested Summary turns interactive")
    Assert.deepEqual(entryCoefficients, { 16, 14, 11, 9, 6, 3, 0 }, "the nested entry keeps its source recurrence")
    Assert.equal(counters.leases, 1, "the journey holds one preparation lease for its Summary")
    flow:updateFixed({ { type = "navigate", direction = "right" } })
    Assert.equal(flowChild(rig).group, "skills", "the nested Summary reaches its second native group")
    flow:updateFixed({ { type = "navigate", direction = "down" } })
    Assert.equal(flowChild(rig).slot, 1, "moving down displays the second mon")
    flow:updateFixed({ { type = "cancel" } })
    for _ = 1, 24 do
      if flow:status().page == "party_browse" then
        break
      end
      flow:updateFixed({})
    end
    Assert.equal(flow:status().page, "party_browse", "closing the Summary returns to the party")
    local resumed = flowChild(rig)
    for _ = 1, 12 do
      if resumed.cursorNode == 1 then
        break
      end
      flow:updateFixed({})
      resumed = flowChild(rig)
    end
    Assert.equal(resumed.cursorNode, 1, "the party resumes on the displayed member")
    Assert.isNil(flow:takeResult(), "returning reports no terminal result")
    Assert.equal(rig.service:partyRevision(), partyRevision, "the return journey mutates no mon")
    Assert.equal(rig.bag:revision(), bagRevision, "the return journey touches no bag transaction")
    Assert.equal(counters.leases, 1, "the journey opens exactly one Summary lease")
    Assert.equal(counters.releases, 1, "closing releases only the per-open Summary lease")
    Assert.notNil(runtime._summaryPreparation, "the field binding stays live for a later open")
    Assert.notNil(resources.summaryResources, "the field owner stays live for a later open")
    flow:dispose()
    resources:dispose()
  end)
end

---@param state table<string, unknown> open picker wrapper
---@param maxTicks integer empty fixed updates to run at most
local function settlePicker(state, maxTicks)
  for _ = 1, maxTicks do
    state:updateFixed({})
    if state:status().wrapperPhase == "active" then
      return
    end
  end
  error("the move picker never turns interactive", 0)
end

function T.machine_picker_round_trip_preserves_result_semantics_over_the_binding()
  local versionId = readyVersion()
  local _, summaryManifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)
  local helper = SummaryAcceptanceFixture.preparationDoubles({})
  local runtime = compositionRuntime(versionId, helper)
  withComposition(runtime, helper, function(resources)
    Assert.notNil(resources, "valid Summary setup constructs the field presentation")
    local SummaryScreenState = require("game.hgss.src.field.SummaryScreenState")
    local ScreenTopology = require("libs.ui.src.ScreenTopology")
    local counters = { leases = 0, releases = 0 }
    local service = SummaryAcceptanceFixture.openService()
    SummaryAcceptanceFixture.gift(service, "TOTODILE", 5)
    service:setMove(0, 0, "SCRATCH")
    service:setMove(0, 1, "CUT")
    local revision = service:partyRevision()
    local context = SummaryAcceptanceFixture.displayContext(summaryManifest, service:partyCount())
    local function openPicker(request)
      return SummaryScreenState.new({
        mons = service,
        manifest = summaryManifest,
        initialSlot = 0,
        measureDisplay = function()
          return {
            width = 512,
            height = 384,
            topology = ScreenTopology.oneDisplay({
              id = "main",
              rect = { x = 0, y = 0, width = 512, height = 384 },
              touch = false,
              role = "world",
            }),
            pixelRatio = 1,
            signature = "field-summary-required:picker",
          }
        end,
        mode = "move_pick",
        request = request,
        context = function()
          return context
        end,
        readNavigation = function()
          return nil
        end,
        acquirePreparation = acquireThroughBinding(runtime, counters),
      })
    end
    local refusing = openPicker({ context = "replace_machine", protected = { [2] = "hm" } })
    settlePicker(refusing, 40)
    Assert.equal(refusing:status().group, "skills", "the teaching picker opens on its move rows")
    refusing:updateFixed({ { type = "navigate", direction = "down" } })
    refusing:updateFixed({ { type = "confirm" } })
    local notice = refusing:status().notice
    Assert.equal(notice and notice.reason, "hm", "confirming the protected row raises its notice")
    Assert.isNil(refusing:takeResult(), "a protected HM row reports no terminal result")
    Assert.equal(service:partyRevision(), revision, "the notice publishes no revision")
    refusing:updateFixed({ { type = "cancel" } })
    Assert.isNil(refusing:status().notice, "acknowledging clears the notice")
    refusing:updateFixed({ { type = "navigate", direction = "up" } })
    refusing:updateFixed({ { type = "confirm" } })
    local picked = assert(refusing:takeResult(), "an ordinary row completes the pick")
    Assert.equal(picked.kind, "move_selected", "the pick selects")
    Assert.equal(picked.slot, 0, "the pick carries its member")
    Assert.equal(picked.moveSlot, 0, "the pick carries the chosen row")
    Assert.equal(picked.partyRevision, revision, "the pick carries the live revision")
    refusing:dispose()
    local cancelling = openPicker({ context = "replace_machine" })
    settlePicker(cancelling, 40)
    cancelling:updateFixed({ { type = "dismiss" } })
    local cancelled = assert(cancelling:takeResult(), "dismissal reports its result")
    Assert.equal(cancelled.kind, "cancelled", "cancellation stays explicit")
    Assert.equal(service:partyRevision(), revision, "cancellation publishes nothing")
    cancelling:dispose()
    Assert.equal(counters.leases, 2, "each picker holds its own lease")
    Assert.equal(counters.releases, 2, "each picker releases exactly its own lease")
    Assert.notNil(runtime._summaryPreparation, "the field binding stays live after both picks")
    Assert.notNil(resources.summaryResources, "the field owner stays live after both picks")
    resources:dispose()
  end)
end

return {
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = { "summary:global", "party:global" },
  },
  tests = T,
}
