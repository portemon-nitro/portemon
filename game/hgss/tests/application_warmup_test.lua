-- Field-owned idle application warmup: one speculative GPU realization per
-- host update, sequenced after active foreground preparation and held while
-- a transition cover owns the foreground; foreground demand promotes
-- pending idle work instead of redoing it, and a failed idle round never
-- fabricates readiness for a later required demand.

local Assert = require("tests.support.Assert")
local AssetNeedsRegistry = require("libs.hgss.src.field.AssetNeedsRegistry")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldPresentationResources = require("game.hgss.src.field.FieldPresentationResources")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldStatePresentationFixture = require("tests.support.FieldStatePresentationFixture")
local FieldTerrainEffectController = require("libs.hgss.src.world.FieldTerrainEffectController")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local InactiveMonNaming = require("tests.support.InactiveMonNaming")
local ItemFixture = require("libs.items.tests.item_fixture")
local MonCache = require("libs.assets.src.MonCache")
local MoveIconCache = require("libs.assets.src.MoveIconCache")
local MoveIconFixture = require("tests.support.MoveIconFixture")
local PokedexDexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SummaryAcceptanceFixture = require("tests.support.SummaryAcceptanceFixture")
local SummaryPresentationFixture = require("tests.support.SummaryPresentationFixture")

local T = {}

-- The stubbed presentation runtime every FieldState boot reads: mirrors the
-- field-state composition fixture so the booted aggregate below is the real
-- production composition, not a hand-assembled graph.
local function stubPresentationRuntime(cache)
  cache = cache or FieldStatePresentationFixture.cache()
  local effects = FieldStatePresentationFixture.terrainEffects(cache)
  return setmetatable({
    monNaming = InactiveMonNaming.new(),
    cacheFs = cache or FieldStatePresentationFixture.cache(),
    assetNeeds = AssetNeedsRegistry.new(),
    derivedAssets = FieldStatePresentationFixture.iconHost().derivedAssets,
    imageAssets = SummaryAcceptanceFixture.sizedImagePool(),
    uiManifest = FieldUiFixture.fieldStateManifest(),
    itemCatalog = ItemFixture.makeCatalog(),
    monCatalog = CatalogFixture.makeCatalog(),
    pokedexCatalog = PokedexDexFixture.buildPokedexCatalog(),
    bindPartyIconPreparation = function(_, _, _)
      return 1
    end,
    unbindPartyIconPreparation = function(_, _) end,
    bindBattlePresentation = function(self, factory)
      assert(type(factory) == "function", "battle presentation binding requires its factory function")
      assert(self.battlePresentation == nil, "one battle presentation binding owns the presented lifetime")
      self.battlePresentation = { id = 1, make = factory }
      return self.battlePresentation.id
    end,
    unbindBattlePresentation = function(self, binding)
      local current = self.battlePresentation
      if current ~= nil and current.id == binding then
        self.battlePresentation = nil
      end
    end,
    bindSummaryPreparation = function(self, acquire)
      assert(type(acquire) == "function", "summary preparation binding requires its acquire function")
      assert(self.summaryPreparation == nil, "one summary preparation binding owns the presented lifetime")
      self.summaryPreparation = { id = 1, acquire = acquire }
      return self.summaryPreparation.id
    end,
    unbindSummaryPreparation = function(self, binding)
      local current = self.summaryPreparation
      if current ~= nil and current.id == binding then
        self.summaryPreparation = nil
      end
    end,
    fieldEntranceIndicatorAsset = {
      model = { batches = {}, materials = {} },
      effects = {
        surf_attachment = {
          model = { batches = {}, materials = {} },
          presentation = { yawDegrees = { north = 180, south = 0, west = 270, east = 90 } },
        },
      },
    },
    fieldEmoteModels = {
      exclamation = { kind = "static", batches = {}, materials = {} },
    },
    fieldEffectAssets = { effects = effects },
    fieldTerrainEffectController = FieldTerrainEffectController.new({
      effects = effects,
      modelFactory = function()
        error("the terrain model factory is installed by presentation resources", 0)
      end,
    }),
    windowStyles = {
      resolve = function() end,
    },
    playerData = { options = { textFrame = 0 } },
    menuHost = {
      setScreenTopology = function() end,
      setPresentationMetrics = function() end,
    },
    actors = {
      visualRevision = function()
        return 0
      end,
      collectSpriteIds = function() end,
    },
    runtimeMap = {},
    playerVisual = { spriteId = 0 },
    resizePresentation = function() end,
    dispose = function() end,
  }, FieldRuntime)
end

---@return FieldState state the real booted presentation composition
local function bootRealComposition()
  local originalNew = FieldRuntime.new
  FieldRuntime.new = function(_, _)
    return stubPresentationRuntime()
  end
  local game = { saveId = "save-00000001", versionId = "heartgold" }
  local options = {
    topologyProvider = function()
      return ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 640, height = 480 },
        touch = false,
        role = "world",
      })
    end,
  }
  local ok, state = pcall(FieldState.new, game, options)
  FieldRuntime.new = originalNew
  if not ok then
    error(state, 0)
  end
  return state
end

-- A real FieldState update shape with a recording presentation aggregate:
-- the update sequencing under test is production code; only the
-- not-yet-composed warmup seam and the host edges are stands-in.
---@param applicationHost table? active host double or nil for an idle field
---@param entryFade table? active transition-cover double or nil
---@return FieldState state
---@return table[] calls ordered preparation and warmup records
local function schedulingState(applicationHost, entryFade)
  local calls = {}
  local resources = {
    prepareBagApplication = function(_, application)
      calls[#calls + 1] = { "prepare", application }
      return true
    end,
    advanceApplicationWarmup = function(_, remaining)
      calls[#calls + 1] = { "warmup", remaining }
      return false
    end,
  }
  local runtime = {
    update = function() end,
    pcApplicationHost = nil,
    applicationHost = applicationHost,
    martHost = nil,
    kurtBoxHost = nil,
    monNaming = InactiveMonNaming.new(),
    starterChoice = nil,
    session = nil,
  }
  local state = setmetatable({
    runtime = runtime,
    actorPresentation = {
      sync = function()
        return true
      end,
    },
    presentationResources = resources,
    battleEnvelope = nil,
    _entryFade = entryFade,
    _entryAccumulator = 0,
    _gameplayHoldEngaged = false,
  }, FieldState)
  return state, calls
end

local function idleHost()
  return nil
end

---@param application table active application status the host publishes
---@return table host double carrying the status
local function activeHost(application)
  return {
    isActive = function()
      return true
    end,
    status = function()
      return { application = application }
    end,
    setPresentationReady = function() end,
  }
end

-- An unfinished transition cover: the reveal has not completed, so the
-- foreground is held while the cover owns it.
---@return table cover double the update advances without completing
local function heldCover()
  return {
    updateSourceFrame = function() end,
    status = function()
      return { completed = false }
    end,
  }
end

function T.presentation_aggregate_advertises_the_idle_application_slot()
  local state = bootRealComposition()
  local resources = assert(state.presentationResources, "FieldState owns a presentation resource aggregate")
  Assert.isTrue(
    type(resources.advanceApplicationWarmup) == "function",
    "field presentation advances its application warmup between foreground preparation and draw"
  )
  state:dispose()
end

-- Idle field work never builds the dex leaf as a side effect and never
-- issues dex producer demand: the aggregate runs its alternating Summary
-- turns with full and held allowances while the dex owner stays absent
-- and the semantic ledger stays empty.
function T.idle_field_work_leaves_the_pokedex_leaf_unbuilt_and_unrequested()
  local runtime = stubPresentationRuntime()
  local demands = {}
  local derived = assert(runtime.derivedAssets, "the presented runtime carries its semantic cache host")
  derived.requestPokedex = function(urgency)
    demands[#demands + 1] = urgency
    return false, nil
  end
  local resources = FieldPresentationResources.new(runtime)
  Assert.isNil(resources.pokedexResources, "a field that never opened the dex owns no dex leaf")
  Assert.isTrue(
    type(resources.advanceApplicationWarmup) == "function",
    "field presentation advances its application warmup between foreground preparation and draw"
  )
  for _ = 1, 4 do
    local used = resources:advanceApplicationWarmup(1)
    Assert.isTrue(used == true or used == false, "idle staging answers with its GPU admission")
  end
  Assert.isNil(resources.pokedexResources, "idle turns never construct the dex leaf")
  Assert.equal(#demands, 0, "idle turns issue no dex producer demand")
  for _ = 1, 4 do
    local used = resources:advanceApplicationWarmup(0)
    Assert.isTrue(used == true or used == false, "held staging answers with its GPU admission")
  end
  Assert.isNil(resources.pokedexResources, "held turns never construct the dex leaf")
  Assert.equal(#demands, 0, "held turns issue no dex producer demand")
  Assert.notNil(resources.summaryResources, "idle staging keeps its summary leaf")
  resources:dispose()
end

-- An idle host update spends its single speculative admission exactly once
-- and never blocks: the warmup seam answers synchronously.
function T.idle_update_advances_warmup_exactly_once_with_the_full_slot()
  Assert.isTrue(
    type(FieldPresentationResources.advanceApplicationWarmup) == "function",
    "field presentation advances its application warmup between foreground preparation and draw"
  )
  local state, calls = schedulingState(idleHost(), nil)
  state:update(0.016)
  Assert.deepEqual(calls, { { "warmup", 1 } }, "one idle update spends its single slot exactly once")
end

-- Active foreground preparation keeps its priority: the Bag leaf prepares
-- first, then the held warmup slot runs with zero admission so nothing
-- speculative is realized under the modal.
function T.active_application_preparation_precedes_the_held_warmup_slot()
  Assert.isTrue(
    type(FieldPresentationResources.advanceApplicationWarmup) == "function",
    "field presentation advances its application warmup between foreground preparation and draw"
  )
  local application = { presentation = { inputKey = "other" } }
  local state, calls = schedulingState(activeHost(application), nil)
  state:update(0.016)
  Assert.equal(#calls, 2, "one update prepares the foreground leaf then offers the warmup slot")
  Assert.isTrue(calls[1][1] == "prepare", "foreground preparation runs before the warmup slot")
  Assert.isTrue(calls[1][2] == application, "preparation receives the active application itself")
  Assert.deepEqual(calls[2], { "warmup", 0 }, "a modal foreground holds all speculative admission")
end

-- While the transition cover owns the foreground, no speculative admission
-- is spent: the slot stays offered with zero admission or stays unoffered,
-- never with a live GPU budget.
function T.transition_cover_holds_all_speculative_admission()
  Assert.isTrue(
    type(FieldPresentationResources.advanceApplicationWarmup) == "function",
    "field presentation advances its application warmup between foreground preparation and draw"
  )
  local state, calls = schedulingState(idleHost(), heldCover())
  state:update(0.016)
  for _, call in ipairs(calls) do
    if call[1] == "warmup" then
      Assert.equal(call[2], 0, "a held foreground spends no speculative GPU admission")
    end
  end
  Assert.isTrue(#calls <= 1, "a covered update offers at most the held slot")
end

---@param pageId integer zero-based generated portrait page
---@return table<string, unknown> generated portrait entry stub
local function portraitEntry(pageId)
  return {
    pageId = pageId,
    frames = { { x = 0, y = 0, width = 8, height = 8 } },
    width = 8,
    height = 8,
  }
end

---@param entries table<string, table<string, unknown>> controlled portrait manifest entries
---@return table<string, unknown> cache reader serving only the portrait manifest
local function portraitCache(entries)
  local cache = {}
  function cache:loadLua(path)
    if path == MoveIconCache.manifestPath() then
      return MoveIconFixture.manifest()
    end
    Assert.equal(path, MonCache.portraitManifestPath(), "portrait reads name the portrait manifest")
    return { entries = entries }
  end
  function cache:read(path)
    return "synthetic visual " .. path
  end
  return cache
end

---@param entries table<string, table<string, unknown>> controlled portrait manifest entries
---@param failures table<string, boolean>? armed failure switches
---@return table<string, unknown> owner collaborators over the controlled portrait manifest
local function warmComposition(entries, failures)
  local Resources = require("game.hgss.src.field.SummaryPresentationResources")
  local helper = SummaryAcceptanceFixture.preparationDoubles(failures)
  local family = SummaryPresentationFixture.manifest()
  local owner = Resources.new({
    cacheFs = portraitCache(entries),
    graphics = helper.graphics,
    text = helper.text,
    icons = helper.icons,
    imagePool = assert(helper.imagePool, "the doubles carry the shared image owner"),
    derivedAssets = helper.derivedAssets,
    manifest = family,
  })
  return { owner = owner, helper = helper }
end

---@param key string demand key
---@param selectors string[] roster portrait identities in slot order
---@return table<string, unknown> lease demand over the identities
local function warmDemand(key, selectors)
  local icons = {}
  for index, _ in ipairs(selectors) do
    icons[index] = "test-icon-" .. index
  end
  return {
    key = key,
    revision = 7,
    pictureEpoch = 1,
    portraitSelectors = selectors,
    iconKeys = icons,
    cryBanks = {},
    chrome = {
      "assets/generated/summary/syn-ball.png",
      "assets/generated/summary/syn-ribbon-syn_ds1_00.png",
    },
  }
end

---@param lease table<string, unknown> live preparation lease
---@param demand table<string, unknown> current demand
---@return table<string, unknown> terminal prepare outcome (never pending)
local function prepareToTerminal(lease, demand)
  local outcome = nil
  for _ = 1, 256 do
    local ok, result = pcall(lease.prepare, lease, demand)
    Assert.isTrue(ok, "preparation answers instead of raising: " .. tostring(result))
    outcome = result
    Assert.isTrue(type(outcome.kind) == "string", "prepare outcomes name their kind")
    if outcome.kind ~= "pending" then
      return outcome
    end
  end
  error("preparation never settles for demand " .. tostring(demand.key), 0)
end

-- Foreground demand takes over pending idle work instead of redoing it: the
-- portrait page compiles once across the idle rounds and the later required
-- demand. A failed idle round names its page and never fabricates readiness
-- for the later required demand, which still reports its own cause.
function T.foreground_demand_promotes_pending_idle_work_and_failures_still_surface()
  local selector = MonCache.portraitSelector("CHIKORITA", 0, "male", false)
  local setup = warmComposition({ [selector] = portraitEntry(3) }, {})
  local owner = setup.owner
  Assert.isTrue(
    type(owner.advanceWarmup) == "function",
    "the summary owner promotes pending idle work on foreground demand"
  )
  local settled = false
  for _ = 1, 256 do
    local used, failure = owner:advanceWarmup({ selector }, 1)
    Assert.isNil(failure, "idle staging reports no failure on synthetic portraits")
    if used == false then
      settled = true
      break
    end
  end
  Assert.isTrue(settled, "idle rounds finish the predicted portrait work")
  local compilations = #setup.helper.calls.portraitPages
  Assert.isTrue(compilations >= 1, "idle staging enrolls the portrait compilation")
  local lease = owner:acquire()
  local ready = prepareToTerminal(lease, warmDemand("promoted", { selector }))
  Assert.equal(ready.kind, "ready", "foreground demand resolves through its ordinary required path")
  Assert.equal(
    #setup.helper.calls.portraitPages,
    compilations,
    "foreground demand takes over pending work without a second CPU job"
  )
  lease:release()
  owner:release()
  local failing = warmComposition({ [selector] = portraitEntry(3) }, { portrait = true })
  Assert.isTrue(
    type(failing.owner.advanceWarmup) == "function",
    "idle staging reports its own failure without crashing the field"
  )
  local _, idleFailure = failing.owner:advanceWarmup({ selector }, 1)
  Assert.isTrue(
    type(idleFailure) == "string" and idleFailure ~= "",
    "the failed idle round names its portrait page"
  )
  local probe = failing.owner:acquire()
  local refused = prepareToTerminal(probe, warmDemand("promoted-fail", { selector }))
  Assert.equal(refused.kind, "failed", "a warmup attempt never fabricates readiness for a later demand")
  Assert.isTrue(
    type(refused.error) == "string" and refused.error ~= "",
    "the required failure carries its original cause"
  )
  probe:release()
  failing.owner:release()
end

-- A battle envelope double recording its idle warmup calls behind the
-- same idle checks the production scheduler applies.
local function battleSchedulingState(d02Used, sceneKey, ownsInput, entryFade)
  local calls = {}
  local resources = {
    prepareBagApplication = function(_, application)
      calls[#calls + 1] = { "prepare", application }
      return true
    end,
    advanceApplicationWarmup = function(_, remaining)
      calls[#calls + 1] = { "warmup", remaining }
      return d02Used
    end,
  }
  local envelopeCalls = {}
  local envelope = {
    updateFixed = function() end,
    ownsInput = function()
      return ownsInput == true
    end,
    advanceWarmup = function(_, key, allowance)
      envelopeCalls[#envelopeCalls + 1] = { key, allowance }
      return false, nil
    end,
  }
  local runtime = {
    update = function() end,
    pcApplicationHost = nil,
    applicationHost = nil,
    martHost = nil,
    kurtBoxHost = nil,
    monNaming = InactiveMonNaming.new(),
    starterChoice = nil,
    session = nil,
    battleCoordinator = {
      predictedSceneKey = function()
        return sceneKey
      end,
    },
  }
  local state = setmetatable({
    runtime = runtime,
    actorPresentation = {
      sync = function()
        return true
      end,
    },
    presentationResources = resources,
    battleEnvelope = envelope,
    _entryFade = entryFade,
    _entryAccumulator = 0,
    _gameplayHoldEngaged = false,
  }, FieldState)
  return state, calls, envelopeCalls
end

-- Battle prewarm spends only the leftover single admission after the
-- application warmup: an unused slot warms the predicted
-- scene once with the full allowance, while a consumed slot, a missing
-- prediction, a held foreground, or an active battle spends nothing.
function T.battle_envelope_consumes_only_the_leftover_shared_gpu_slot()
  local state, calls, envelopeCalls = battleSchedulingState(false, "general/plain/day", false, nil)
  state:update(0.016)
  Assert.deepEqual(calls, { { "warmup", 1 } }, "one idle update spends its single slot exactly once")
  Assert.deepEqual(
    envelopeCalls,
    { { "general/plain/day", 1 } },
    "the leftover slot warms the predicted battle scene once with the full allowance"
  )
  local heldState, heldCalls, heldEnvelope = battleSchedulingState(true, "general/plain/day", false, nil)
  heldState:update(0.016)
  Assert.deepEqual(heldCalls, { { "warmup", 1 } }, "the consumed update still reports its slot")
  Assert.deepEqual(heldEnvelope, {}, "a consumed slot leaves no admission for battle warmup")
  local nokeyState, _, nokeyEnvelope = battleSchedulingState(false, nil, false, nil)
  nokeyState:update(0.016)
  Assert.deepEqual(nokeyEnvelope, {}, "a missing prediction warms nothing")
  local ownedState, _, ownedEnvelope = battleSchedulingState(false, "general/plain/day", true, nil)
  ownedState:update(0.016)
  Assert.deepEqual(ownedEnvelope, {}, "an active battle hold spends no idle admission")
  local coveredState, coveredCalls, coveredEnvelope = battleSchedulingState(false, "general/plain/day", false, heldCover())
  coveredState:update(0.016)
  for _, call in ipairs(coveredCalls) do
    if call[1] == "warmup" then
      Assert.equal(call[2], 0, "a covered foreground holds all speculative admission")
    end
  end
  for _, call in ipairs(coveredEnvelope) do
    Assert.isFalse(call[2] == 1, "a covered field never grants the battle a GPU realization")
  end
end

return { tests = T }
