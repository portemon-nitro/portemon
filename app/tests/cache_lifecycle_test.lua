-- Cold-cache application composition below the full journeys: the menu
-- lists validated display envelopes without deep validation or generated
-- caches, semantic incompatibility still rejects at load, game switches
-- retire the old epoch on one shared process pool, raw replacement waits
-- for source quiescence, and location planning reuses the committed
-- footprint while the halo stays a near 5x5 interest.

local Assert = require("tests.support.Assert")
local EncounterSave = require("libs.hgss.src.save.EncounterSave")
local PokedexSave = require("libs.hgss.src.save.PokedexSave")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local SaveFs = require("libs.storage.src.SaveFs")
local GameSave = require("libs.hgss.src.save.GameSave")
local BagSave = require("libs.hgss.src.save.BagSave")
local MartSave = require("libs.hgss.src.save.MartSave")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local MainMenuState = require("app.src.mainmenu.MainMenuState")
local FieldCoverage = require("libs.hgss.src.world.FieldCoverage")
local MonsSave = require("libs.mons.src.MonsSave")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local PhotoAlbum = require("libs.hgss.src.save.PhotoAlbum")
local CachePreparationState = require("app.src.launcher.CachePreparationState")
local VersionSelectState = require("app.src.launcher.VersionSelectState")
local FirstPlayCompletion = require("romdump.src.FirstPlayCompletion")

-- Hermetic completion answers for live-controller tests: the suites own
-- controller/threading contracts, not attestation currency, so ordinary
-- selections keep their established bootstrap paths while no real
-- attestation file is read or written. Tests that own currency set the
-- context fields before selecting.
local function stubFirstPlayCompletion(context)
  context.firstPlayCurrent = true
  context.firstPlayStored = true
  context.firstPlayPublished = {}
  local originalIsCurrent = FirstPlayCompletion.isCurrent
  local originalHasStored = FirstPlayCompletion.hasStored
  local originalPublish = FirstPlayCompletion.publish
  FirstPlayCompletion.isCurrent = function(_, _)
    return context.firstPlayCurrent
  end
  FirstPlayCompletion.hasStored = function()
    return context.firstPlayStored
  end
  FirstPlayCompletion.publish = function(versionId, generationId)
    context.firstPlayPublished[#context.firstPlayPublished + 1] = { versionId = versionId, generationId = generationId }
  end
  return { isCurrent = originalIsCurrent, hasStored = originalHasStored, publish = originalPublish }
end

local function restoreFirstPlayCompletion(originals)
  FirstPlayCompletion.isCurrent = originals.isCurrent
  FirstPlayCompletion.hasStored = originals.hasStored
  FirstPlayCompletion.publish = originals.publish
end

local T = {}

local VERSION = "heartgold"
local FakeStartupTitleState = require("tests.support.FakeStartupTitleState")

-- This suite owns App and provisioning transitions, while startup-title timing
-- and asset readiness have their own focused state tests. Model that state at
-- the App boundary and keep bootstrap readiness in the selected host.
local function stubStartupTitleHandoff()
  local StartupTitleState = require("app.src.launcher.StartupTitleState")
  local originalNew = StartupTitleState.new
  StartupTitleState.new = FakeStartupTitleState.new
  return function()
    StartupTitleState.new = originalNew
  end
end

local function record(saveId, overrides)
  local value = {
    schema = GameSave.SCHEMA,
    saveId = saveId,
    versionId = VERSION,
    playTimeSeconds = 61,
    mapId = 60,
    fieldX = 684,
    fieldZ = 393,
    worldY = 0,
    surfaceId = 0,
    terrainDependencyHash = "terrain-heartgold",
    facing = "south",
    playerData = {
      profile = {
        name = "GOLD",
        gender = 0,
        trainerId = 0,
        money = 3000,
        badges = 0,
        nationalDex = false,
        runningShoes = false,
        runningShoesLock = false,
        rivalName = "Silver",
      },
      options = { textFrame = 0, textSpeed = "mid" },
    },
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    world = { flags = {}, variables = {}, objects = {}, rng = { state = 1, calls = 0 } },
    scripts = {},
    bag = BagSave.empty(),
    fashionCase = require("libs.hgss.src.save.FashionCaseState").empty(),
    mart = MartSave.empty(),
    auxiliaryUi = { requested = "shown", state = "shown" },
    audio = {},
    mons = MonsSave.empty(7),
    mailbox = Mailbox.new():capture(),
    photoAlbum = PhotoAlbum.new():capture(),
    encounters = EncounterSave.initial(),
    pokedex = PokedexSave.initial(),
  }
  for key, override in pairs(overrides or {}) do
    value[key] = override
  end
  return value
end

local function countingStore(backend)
  local calls = { cacheReads = {} }
  local reader = backend.read
  local reading = backend
  function reading.read(_, path)
    if type(path) == "string" and path:sub(1, 6) ~= "saves/" then
      calls.cacheReads[#calls.cacheReads + 1] = path
    end
    return reader(backend, path)
  end
  local store = GameSaveStore.new(SaveFs.global(backend))
  return store, calls
end

function T.menu_listing_reads_display_envelopes_without_generated_caches()
  local backend = FakeCache.new()
  local store, calls = countingStore(backend)
  local saveId = store:reserve()
  store:publishFirst(record(saveId))

  Assert.isTrue(
    type(store.listMetadata) == "function",
    "menu listing reads display envelopes through GameSaveStore.listMetadata without generated caches"
  )
  local entries = store:listMetadata()
  Assert.equal(#entries, 1, "metadata listing preserves catalog ordering")
  local entry = entries[1]
  Assert.equal(entry.saveId, saveId)
  Assert.equal(entry.versionId, VERSION)
  Assert.equal(assert(entry.playerData and entry.playerData.profile).name, "GOLD")
  Assert.equal(entry.playTimeSeconds, 61)
  Assert.isNil(entry.error, "a valid envelope lists no error")
  Assert.deepEqual(calls.cacheReads, {}, "publication and metadata listing read no generated caches")

  local results = {}
  local renderer = {
    draw = function() end,
    dispose = function() end,
  }
  local menu = MainMenuState.new({
    saveStore = {
      listMetadata = function()
        return entries
      end,
    },
    readyVersions = { VERSION },
    width = 640,
    height = 480,
    renderer = renderer,
    onResult = function(result)
      results[#results + 1] = result
    end,
  })
  local card = menu:view().saves[1]
  Assert.equal(card.saveId, saveId)
  Assert.equal(card.playerName, "GOLD")
  Assert.isTrue(card.canContinue, "a displayed record stays continuable while the cache is cold")
  menu:keypressed("return")
  Assert.deepEqual(
    results,
    { { kind = "continue", saveId = saveId } },
    "Continue stays an intent, not a validity claim"
  )
end

function T.nested_script_drift_loads_while_envelope_corruption_still_rejects()
  local backend = FakeCache.new()
  local store = GameSaveStore.new(SaveFs.global(backend))
  local saveId = store:reserve()
  store:publishFirst(record(saveId))

  Assert.isTrue(
    type(store.listMetadata) == "function",
    "metadata listing keeps display data distinct from nested validity"
  )
  local before = store:listMetadata()
  Assert.equal(#before, 1)
  Assert.equal(before[1].saveId, saveId)
  Assert.isNil(before[1].error, "listing never marks a record corrupt for missing generated data")

  -- Nested script drift is owned by script restore, not by load: the
  -- envelope still routes, so the store returns the record untouched.
  local drifted = record(saveId)
  drifted.scripts = { registryFingerprint = "drifted-registry", taskFingerprint = "drifted-tasks" }
  store:save(drifted)
  local loaded = assert(store:load(saveId))
  Assert.equal(loaded.scripts.registryFingerprint, "drifted-registry")

  -- Envelope corruption still rejects with a structured error and rewrites
  -- neither the payload nor its display envelope.
  backend.files["saves/games/" .. saveId .. ".lua"] = "return { schema = 'not-a-save' }"
  local ok, failure = pcall(function()
    return store:load(saveId)
  end)
  Assert.isFalse(ok, "envelope corruption still rejects at load")
  Assert.isTrue(Errors.is(failure), "the rejection is a structured error")
  local after = store:listMetadata()
  Assert.equal(#after, 1)
  Assert.notNil(after[1].error, "a corrupt envelope lists its error, never a silent card")
end

-- Synthetic service behind the relocated controller: epochs are minted
-- locally, requests only record, and warmup authorization appends its
-- lifecycle event so menu ordering stays observable without threads.
local function newMenuService(events)
  local epoch = 0
  local service = {}
  function service:select(_)
    epoch = epoch + 1
    return epoch
  end
  function service:request(_, selector)
    if selector.requestKind == "milestone" and selector.name == "new-game-intro" then
      events[#events + 1] = "warmup:near-prefetch"
    end
  end
  function service:observe(_, _)
    return nil, nil
  end
  function service:enableSweep(_)
    events[#events + 1] = "provisioner:startBackgroundWarmup"
  end
  function service:update() end
  function service:retire(_) end
  return service
end

local function withAppStubs(fn)
  local App = require("app.src.App")
  local HgssGame = require("game.hgss.src.HgssGame")
  local MainMenuComposition = require("app.src.mainmenu.MainMenuComposition")
  local RomImporter = require("romdump.src.source.RomImporter")
  local Store = require("libs.hgss.src.save.GameSaveStore")
  local original = {
    state = App.state,
    importer = App.importer,
    provisioner = App.provisioner,
    service = App.service,
    epoch = App.epoch,
    pendingQuiesce = App.pendingQuiesce,
    opts = App.opts,
    saveDir = App.saveDir,
    gameNew = HgssGame.new,
    menuNew = MainMenuComposition.new,
    isReady = RomImporter.isReady,
    storeNew = Store.new,
    dimensions = love.graphics.getDimensions,
  }
  local HgssLoadingPresentation = require("libs.hgss.src.ui.HgssLoadingPresentation")
  local originalLoadingNew = HgssLoadingPresentation.new
  -- The boot wait adopts its selected pair through the themed presentation
  -- before it transfers: model an instantly drawable pair so selections
  -- exercise the real request/adopt/transfer path instead of stalling on
  -- generated art this stubbed service harness never builds.
  HgssLoadingPresentation.new = function(_)
    local presentation = {}
    function presentation:update() end
    function presentation:resize() end
    function presentation:draw() end
    function presentation:dispose() end
    function presentation:adoptGeneratedAssets()
      return true
    end
    return presentation
  end
  local context = {
    games = {},
    menus = {},
    importers = {},
    epochs = {},
    requests = {},
    retires = {},
    observations = {},
    barriers = {},
    imports = {},
    selectOptions = {},
    warmups = 0,
    quiesces = 0,
    updates = 0,
  }
  local epoch = 0
  local barrier = 0
  local service = {}
  function service:select(options)
    epoch = epoch + 1
    context.epochs[#context.epochs + 1] = epoch
    context.selectOptions[#context.selectOptions + 1] = options
    return epoch
  end
  function service:request(epochArg, selector)
    context.requests[#context.requests + 1] = { epoch = epochArg, selector = selector }
  end
  function service:observe(epochArg, selector)
    local key = selector.requestKind
      .. ":"
      .. tostring(selector.name or selector.mapId or selector.pageId)
      .. ":"
      .. tostring(selector.matrixMemberId)
      .. ":"
      .. tostring(selector.index)
    local _ = epochArg
    local scripted = context.observations[key]
    if scripted ~= nil then
      return scripted.ready, scripted.failure
    end
    -- The boot wait demands the selected walking pair as a required
    -- interest before it transfers: model the healthy worker answer so
    -- warm selections keep reaching their menu handoff in this harness.
    if selector.requestKind == "startup-walker" then
      return true, nil
    end
    if selector.requestKind == "milestone" and selector.name == "bootstrap" then
      return true, nil
    end
    return nil, nil
  end
  function service:enableSweep(_)
    context.warmups = context.warmups + 1
  end
  function service:offerSource(_, _, _)
    context.offers = (context.offers or 0) + 1
    return true
  end
  function service:requestBootSource(_)
    context.bootGates = (context.bootGates or 0) + 1
    return true
  end
  function service:bootSourceStatus(_)
    return context.bootStatus or "ready", context.bootDetail
  end
  function service:update()
    context.updates = context.updates + 1
  end
  function service:retire(epochArg)
    context.retires[#context.retires + 1] = epochArg
  end
  function service:quiesce(epochArg)
    barrier = barrier + 1
    context.quiesces = context.quiesces + 1
    context.barriers[barrier] = { epoch = epochArg, status = "pending" }
    return barrier
  end
  function service:barrierStatus(epochArg, barrierArg)
    local waiter = context.barriers[barrierArg]
    if waiter == nil or waiter.epoch ~= epochArg then
      return nil
    end
    return waiter.status
  end
  function service:generationId(_)
    return context.cannedGeneration
  end
  function service:importSource(epochArg, barrierArg)
    local waiter = context.barriers[barrierArg]
    if waiter == nil or waiter.epoch ~= epochArg or waiter.status ~= "ready" then
      return false, "unacknowledged"
    end
    context.barriers[barrierArg] = nil
    context.imports[#context.imports + 1] = { epoch = epochArg, barrier = barrierArg }
    return true
  end
  function service:shutdown()
    if context.shutdown then
      return
    end
    context.shutdown = true
    context.joins = (context.joins or 0) + 1
  end
  context.service = service
  App.opts = { dev = false }
  App.state = nil
  App.importer = nil
  App.provisioner = nil
  App.service = service
  App.epoch = 0
  App.saveDir = "test-save-dir"
  RomImporter.isReady = function(_)
    return true
  end
  context.cannedGeneration = "test-generation"
  local completionOriginals = stubFirstPlayCompletion(context)
  local restoreStartupTitle = stubStartupTitleHandoff()
  love.graphics.getDimensions = function()
    return 640, 480
  end
  rawset(Store, "new", function()
    return {
      list = function()
        return {}
      end,
    }
  end)
  HgssGame.new = function(_)
    local game = {
      disposed = 0,
      dispose = function(self)
        self.disposed = self.disposed + 1
      end,
    }
    context.games[#context.games + 1] = game
    return game
  end
  MainMenuComposition.new = function(options)
    local menu = { disposed = 0, options = options }
    function menu:dispose()
      self.disposed = self.disposed + 1
    end
    context.menus[#context.menus + 1] = menu
    return menu
  end
  local ok, err = pcall(fn, App, context)
  restoreStartupTitle()
  HgssGame.new = original.gameNew
  HgssLoadingPresentation.new = originalLoadingNew
  MainMenuComposition.new = original.menuNew
  RomImporter.isReady = original.isReady
  restoreFirstPlayCompletion(completionOriginals)
  rawset(Store, "new", original.storeNew)
  love.graphics.getDimensions = original.dimensions
  App.state = original.state
  App.importer = original.importer
  App.provisioner = original.provisioner
  App.service = original.service
  App.epoch = original.epoch
  App.pendingQuiesce = original.pendingQuiesce
  App.opts = original.opts
  App.saveDir = original.saveDir
  if not ok then
    error(err, 0)
  end
end

function T.menu_reselection_retires_the_old_epoch_on_the_shared_process_service()
  withAppStubs(function(App, context)
    local service = assert(App.service, "the application owns one process cache service")
    App._bootMainMenu({ VERSION })
    App.update(1 / 60)
    App.update(1 / 60)
    App._bootMainMenu({ VERSION })
    App.update(1 / 60)
    App.update(1 / 60)
    Assert.equal(App.service, service, "a switch reuses the service instead of spawning a second")
    Assert.deepEqual(context.epochs, { 1, 2 }, "returning to a game mints a new epoch even when the generation matches")
    Assert.deepEqual(context.retires, { 1 }, "the old epoch retires exactly once without joining workers")
    Assert.equal(#context.menus, 2)
    Assert.equal(context.menus[1].disposed, 1, "switching disposes the old menu owner")
    Assert.equal(context.warmups, 2, "each menu installation authorizes background completion once")
    Assert.isNil(context.shutdown, "switching never shuts down the process service")
  end)
end

function T.app_and_selected_provisioner_pump_the_shared_service_once_per_frame()
  withAppStubs(function(App, context)
    local Provisioner = require("app.src.DerivedAssetProvisioner")
    App.state = { update = function() end }
    App.provisioner = Provisioner.new({ versionId = VERSION, service = assert(App.service) })
    local before = context.updates

    App.update(1 / 60)

    Assert.equal(context.updates - before, 1, "App and its selected provisioner share one service pump")
    App.provisioner:dispose()
    App.provisioner = nil
    before = context.updates
    App.update(1 / 60)
    Assert.equal(context.updates - before, 1, "quiescence without a provisioner still pumps the service")
  end)
end

function T.replacement_rom_waits_for_source_quiescence_before_raw_mutation()
  withAppStubs(function(App, context)
    local RomImporter = require("romdump.src.source.RomImporter")
    local originalNew = RomImporter.new
    local importerCalls = { constructed = 0, filedropped = 0 }
    rawset(RomImporter, "new", function(_)
      importerCalls.constructed = importerCalls.constructed + 1
      return {
        state = "busy",
        isBusy = function()
          return true
        end,
        update = function() end,
        filedropped = function()
          importerCalls.filedropped = importerCalls.filedropped + 1
        end,
      }
    end)
    local disposals = 0
    App.provisioner = {
      update = function() end,
      dispose = function()
        disposals = disposals + 1
      end,
    }
    local updatesBefore = context.updates
    local ok, err = pcall(function()
      App.filedropped({ name = "replacement.zip" })
      Assert.isNil(App.importer, "raw replacement waits for source closure instead of mutating the dump")
      Assert.notNil(App.state, "quiescence waits through a visible preparation state")
      Assert.equal(disposals, 1, "the drop retires selected interest before the barrier")
      Assert.equal(context.quiesces, 1, "the drop stops admission before waiting")
      Assert.isNil(App.provisioner, "retired interest detaches while the barrier drains")
      local waiting = App.state
      App.update(1 / 60)
      Assert.isTrue(context.updates > updatesBefore, "input and progress keep pumping while source readers drain")
      Assert.isNil(App.importer, "pumping never starts the importer before closure")
      App.filedropped({ name = "second.zip" })
      Assert.equal(App.state, waiting, "a repeated drop while waiting never replaces the pending file")
      Assert.equal(context.quiesces, 1, "a repeated drop issues no second barrier")
      assert(context.barriers[1] ~= nil, "the drop holds one quiescence barrier")
      context.barriers[1].status = "ready"
      App.update(1 / 60)
      Assert.equal(importerCalls.constructed, 1, "the importer starts once the source is closed")
      Assert.equal(importerCalls.filedropped, 1, "the dropped file forwards to the importer once")
      App.update(1 / 60)
      Assert.equal(importerCalls.constructed, 1, "settling never starts a second import")
    end)
    rawset(RomImporter, "new", originalNew)
    App.state = nil
    App.importer = nil
    App.provisioner = nil
    App.pendingQuiesce = nil
    if not ok then
      error(err, 0)
    end
  end)
end

local function syntheticIndex()
  local cells = {}
  local function cell(x, z)
    return { x = x, z = z, file = "cells/" .. x .. "_" .. z .. ".lua" }
  end
  for offsetZ = -2, 2 do
    for offsetX = -2, 2 do
      local radius = math.max(math.abs(offsetX), math.abs(offsetZ))
      if radius <= 1 then
        if not (offsetX == 1 and offsetZ == 0) then
          cells[#cells + 1] = cell(10 + offsetX, 10 + offsetZ)
        end
      elseif not (offsetX == -2 and offsetZ == 2) then
        cells[#cells + 1] = cell(10 + offsetX, 10 + offsetZ)
      end
    end
  end
  return { matrices = { { matrixMemberId = 7, cells = cells } } }
end

local function keySet(descriptors)
  local keys = {}
  for _, descriptor in ipairs(descriptors) do
    keys[#keys + 1] = descriptor.x .. ":" .. descriptor.z
  end
  table.sort(keys)
  return keys
end

function T.location_requests_reuse_the_committed_footprint_and_keep_the_halo()
  local index = syntheticIndex()
  Assert.isTrue(
    type(FieldCoverage.descriptorsAt) == "function",
    "location planning reuses one authoritative committed-descriptor selector"
  )
  local committed = FieldCoverage.descriptorsAt(index, 7, 10, 10)
  Assert.deepEqual(
    keySet(committed),
    { "10:10", "10:11", "10:9", "11:11", "11:9", "9:10", "9:11", "9:9" },
    "the committed footprint is exactly the radius-1 selection with holes excluded"
  )
  local coverage = setmetatable({ index = index, matrixMemberId = 7 }, { __index = FieldCoverage })
  Assert.deepEqual(
    coverage:descriptorsFor(10, 10),
    committed,
    "coverage delegates to the same selector instead of duplicating spatial logic"
  )
  local halo = coverage:prefetchDescriptors(10, 10)
  local haloKeys = keySet(halo)
  Assert.equal(#haloKeys, 23, "the halo stays 5x5 with holes excluded")
  local haloSet = {}
  for _, key in ipairs(haloKeys) do
    haloSet[key] = true
  end
  for _, key in ipairs(keySet(committed)) do
    Assert.isTrue(haloSet[key] == true, "the halo contains the committed footprint")
  end

  local requests = {}
  local prefetching = setmetatable({
    index = index,
    matrixMemberId = 7,
    anchorX = 10,
    anchorZ = 10,
    cells = {},
    prefetched = {},
    prefetchQueue = {},
    pendingPrefetch = nil,
    derivedAssets = {
      -- The semantic host is dot-called (plain functions, no self), matching
      -- every production consumer of the host.
      requestCell = function(descriptor, urgency)
        requests[#requests + 1] = { descriptor = descriptor, urgency = urgency }
        return true
      end,
      ensureCell = function() end,
    },
  }, { __index = FieldCoverage })
  prefetching:queuePrefetch(10, 10)
  Assert.equal(#requests, 15, "only halo-exclusive cells ride prefetch")
  local committedKeys = {}
  for _, key in ipairs(keySet(committed)) do
    committedKeys[key] = true
  end
  for _, request in ipairs(requests) do
    local key = request.descriptor.x .. ":" .. request.descriptor.z
    Assert.isNil(committedKeys[key], "committed cells never ride prefetch")
    Assert.equal(request.urgency, "near", "halo prefetch rides near interest, never required")
  end
end

function T.provisioner_wraps_a_selected_service_with_string_urgencies_and_retires_it()
  local Provisioner = require("app.src.DerivedAssetProvisioner")
  local seen = { requests = {}, shutdowns = 0 }
  local scripted = { ready = true, failure = nil }
  local fakeService = {}
  function fakeService:select(options)
    seen.select = options
    return 7
  end
  function fakeService:request(epoch, selector)
    seen.requests[#seen.requests + 1] = { epoch = epoch, selector = selector }
  end
  function fakeService:observe(epoch, selector)
    seen.lastObserve = { epoch = epoch, selector = selector }
    return scripted.ready, scripted.failure
  end
  function fakeService:enableSweep(epoch)
    seen.warmups = (seen.warmups or 0) + 1
    seen.warmupEpoch = epoch
  end
  function fakeService:update()
    seen.updates = (seen.updates or 0) + 1
  end
  function fakeService:retire(epoch)
    seen.retired = epoch
  end
  function fakeService:shutdown()
    seen.shutdowns = seen.shutdowns + 1
  end
  local ok, err = pcall(function()
    local provisioner = Provisioner.new({ versionId = "heartgold", service = fakeService })
    local selectOptions = assert(seen.select)
    Assert.equal(selectOptions.versionId, "heartgold")
    Assert.isNil(
      selectOptions.sweepEnabled,
      "exhaustive intent travels as an explicit request, never a construction flag"
    )
    local host = provisioner:gameHost()
    Assert.isTrue(host.requestMilestone("bootstrap", "required"))
    local milestone = assert(seen.requests[#seen.requests]).selector
    Assert.deepEqual(milestone, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
    Assert.isTrue(host.requestField(60, "required"))
    local field = assert(seen.requests[#seen.requests]).selector
    Assert.deepEqual(field, { requestKind = "field", mapId = 60, urgency = "required" })
    local descriptor = { matrixMemberId = 0, index = 14 }
    Assert.isTrue(host.requestCell(descriptor, "near"))
    local cell = assert(seen.requests[#seen.requests]).selector
    Assert.equal(cell.matrixMemberId, 0)
    Assert.equal(cell.index, 14)
    Assert.equal(cell.urgency, "near")
    Assert.isTrue(host.requestMonPortraitPage(0, "required"))
    local page = assert(seen.requests[#seen.requests]).selector
    Assert.deepEqual(page, { requestKind = "portrait", pageId = 0, urgency = "required" })
    Assert.isTrue(host.requestIconPage(3, "required"))
    local iconPage = assert(seen.requests[#seen.requests]).selector
    Assert.deepEqual(iconPage, { requestKind = "icon-page", pageId = 3, urgency = "required" })
    local iconBadOk, _ = pcall(host.requestIconPage, -1, "required")
    Assert.isFalse(iconBadOk, "a negative icon page is rejected at the facade")
    scripted.ready, scripted.failure = nil, nil
    Assert.deepEqual(
      host.milestoneStatus("new-game-intro"),
      { state = "pending", ready = 0, total = nil },
      "the host forwards the milestone-local progress snapshot"
    )
    Assert.equal(seen.lastObserve.selector.name, "new-game-intro")
    Assert.isNil(host.startBackgroundWarmup, "warmup lifecycle stays off the semantic game host")
    Assert.isNil(host.enableSweep, "corpus authorization stays off the semantic game host")
    Assert.equal(type(provisioner.startBackgroundWarmup), "function", "the provisioner keeps its warmup seam")
    provisioner:startBackgroundWarmup()
    provisioner:startBackgroundWarmup()
    Assert.equal(seen.warmups, 2, "warmup authorization forwards without cache work")
    Assert.equal(seen.warmupEpoch, 7, "warmup authorization carries the borrowed epoch")
    Assert.equal(type(provisioner.update), "nil", "the provisioner does not own service pumping")
    provisioner:dispose()
    Assert.equal(seen.retired, 7, "disposal retires the borrowed epoch")
    Assert.equal(seen.shutdowns, 0, "disposal never shuts down the process service")
    local retiredOk, retiredErr = pcall(host.requestField, 60, "required")
    Assert.isFalse(retiredOk, "retired host calls reject")
    Assert.isTrue(Errors.is(retiredErr), "the rejection is a structured lifecycle error")
    Assert.equal(retiredErr.code, "DERIVED_ASSETS_RETIRED")
    local retiredProgressOk, retiredProgressErr = pcall(host.milestoneStatus, "new-game-intro")
    Assert.isFalse(retiredProgressOk, "retired progress observation rejects")
    Assert.isTrue(Errors.is(retiredProgressErr), "the progress rejection is a structured lifecycle error")
    Assert.equal(retiredProgressErr.code, "DERIVED_ASSETS_RETIRED")
  end)
  if not ok then
    error(err, 0)
  end
end

function T.menu_installation_starts_no_prefetch_or_warmup()
  local App = require("app.src.App")
  local MainMenuComposition = require("app.src.mainmenu.MainMenuComposition")
  local Provisioner = require("app.src.DerivedAssetProvisioner")
  local originalMenuNew = MainMenuComposition.new
  local originalSetState = App.setState
  local originalShowSelector = App._showVersionSelector
  local originalState = App.state
  local originalProvisioner = App.provisioner
  local originalOpts = App.opts
  App.opts = { dev = false }
  local events = {}
  local menu = { dispose = function() end }
  MainMenuComposition.new = function(_)
    events[#events + 1] = "menu:new"
    return menu
  end
  App.setState = function(next)
    events[#events + 1] = "app:setState"
    originalSetState(next)
  end
  local ok, err = pcall(function()
    local provisioner = Provisioner.new({ versionId = "heartgold", service = newMenuService(events) })
    local host = provisioner:gameHost()
    Assert.isNil(host.startBackgroundWarmup, "warmup lifecycle stays off the semantic game host")
    Assert.isNil(host.enableSweep, "corpus authorization stays off the semantic game host")
    App.provisioner = provisioner
    App.state = nil
    App._launchMenuWithProvisioner("heartgold")
  end)
  local launchedState = App.state
  local launchedEvents = {}
  for _, event in ipairs(events) do
    launchedEvents[#launchedEvents + 1] = event
  end
  MainMenuComposition.new = function()
    error("synthetic menu failure", 0)
  end
  local selectorShown = 0
  App._showVersionSelector = function()
    selectorShown = selectorShown + 1
  end
  App.state = nil
  local failOk, failErr
  local innerOk, innerErr = pcall(function()
    failOk, failErr = pcall(App._launchMenuWithProvisioner, "heartgold")
  end)
  local failedSelectorShown = selectorShown
  MainMenuComposition.new = originalMenuNew
  App.setState = originalSetState
  App._showVersionSelector = originalShowSelector
  App.state = originalState
  App.provisioner = originalProvisioner
  App.opts = originalOpts
  if not ok then
    error(err, 0)
  end
  if not innerOk then
    error(innerErr, 0)
  end
  Assert.equal(launchedState, menu, "the app-owned menu becomes the process state")
  Assert.deepEqual(
    launchedEvents,
    { "menu:new", "app:setState" },
    "menu installation enrolls no prefetch: the title entry already warmed up"
  )
  Assert.isFalse(failOk, "a failed game constructor still surfaces its error")
  Assert.isTrue(
    tostring(failErr):find("synthetic menu failure", 1, true) ~= nil,
    "the surfaced error is the menu failure"
  )
  Assert.equal(failedSelectorShown, 1, "a failed launch recovers to the version selector")
end

-- Menu installation performs no background authorization: the title entry
-- owns the owner-only warmup seam. The game host never carries the control.
function T.menu_installation_starts_no_background_warmup()
  local App = require("app.src.App")
  local MainMenuComposition = require("app.src.mainmenu.MainMenuComposition")
  local Provisioner = require("app.src.DerivedAssetProvisioner")
  local originalMenuNew = MainMenuComposition.new
  local originalSetState = App.setState
  local originalState = App.state
  local originalProvisioner = App.provisioner
  local originalOpts = App.opts
  App.opts = { dev = false }
  local events = {}
  local enabled = 0
  local service = newMenuService(events)
  local realEnable = service.enableSweep
  function service:enableSweep(epoch)
    enabled = enabled + 1
    realEnable(self, epoch)
  end
  local menu = { dispose = function() end }
  MainMenuComposition.new = function(_)
    events[#events + 1] = "menu:new"
    return menu
  end
  App.setState = function(next)
    events[#events + 1] = "app:setState"
    originalSetState(next)
  end
  local ok, err = pcall(function()
    local provisioner = Provisioner.new({ versionId = "heartgold", service = service })
    App.provisioner = provisioner
    App.state = nil
    App._launchMenuWithProvisioner("heartgold")
    Assert.equal(
      type(provisioner.startBackgroundWarmup),
      "function",
      "the provisioner keeps the owner-only warmup seam"
    )
  end)
  local launchedState = App.state
  MainMenuComposition.new = originalMenuNew
  App.setState = originalSetState
  App.state = originalState
  App.provisioner = originalProvisioner
  App.opts = originalOpts
  if not ok then
    error(err, 0)
  end
  Assert.equal(launchedState, menu, "the app-owned menu becomes the process state")
  Assert.deepEqual(
    events,
    { "menu:new", "app:setState" },
    "menu installation authorizes no background work: the title entry owns it"
  )
  Assert.equal(enabled, 0, "a successful menu install authorizes no background cursor")
end

-- Selection/import ownership through the real production composition: the
-- application, its provisioner, the generation session and the process pool
-- stay real while only thread transport, game launch, raw import, producer
-- fingerprinting and graphics text are controlled. A ready user-owned dump
-- is required so the real session can plan against genuine source data;
-- without one these scenarios skip instead of proving anything.
--
-- The harness selects the development identity so every scenario starts
-- from a genuinely cold generation even where the release corpus is warm:
-- no derived output exists yet for the working-tree digest, so bootstrap
-- waits through the visible preparation flow instead of launching at once.
-- Controlled worker threads never execute: dispatched jobs stay in their
-- worker slots until the test answers through the result channel, so pending
-- sweep interest, running work and the source-close barrier are fully
-- deterministic. The busy worker below stands in for any executing size
-- class behind the same barrier path.

---@return table controlled thread/channel host with dispatch traffic logs
local function newControlledThreadHost()
  local host = { dispatched = {}, channels = {}, threads = {}, demandCalls = 0 }
  ---@return table fresh channel with traffic logging
  local function newChannel()
    local values = {}
    local channel = { log = {} }
    function channel:push(value)
      values[#values + 1] = value
      channel.log[#channel.log + 1] = value
      if type(value) == "table" and value.jobKey ~= nil and value.status == nil then
        host.dispatched[#host.dispatched + 1] = value
      end
      return true
    end
    function channel:pop()
      if #values == 0 then
        return nil
      end
      return table.remove(values, 1)
    end
    function channel:demand(_)
      host.demandCalls = host.demandCalls + 1
      return channel:pop()
    end
    function channel:getCount()
      return #values
    end
    host.channels[#host.channels + 1] = channel
    return channel
  end
  local function spawnThread()
    local thread = { starts = 0, waits = 0, alive = true, threadError = nil }
    function thread:start()
      self.starts = self.starts + 1
    end
    function thread:wait()
      self.waits = self.waits + 1
    end
    function thread:getError()
      return self.threadError
    end
    function thread:isRunning()
      return self.starts > 0 and self.alive
    end
    host.threads[#host.threads + 1] = thread
    return thread
  end
  host.newChannel = newChannel
  host.newThread = function()
    return spawnThread()
  end
  return host
end

---@param App table application singleton under test
---@param harness table live-app harness holding the attached controller worker
---@param rounds integer
local function pumpApp(App, harness, rounds)
  local worker = harness.worker
  for _ = 1, rounds do
    App.update(1 / 60)
    if worker ~= nil then
      worker:step()
    end
  end
end

-- Attaches the real controller to the service channels the selection
-- opened: the service created its command/reply pair first, so the worker
-- consumes the same two channels the game thread observes.
---@param harness table live-app harness holding the controlled thread host
---@return table test-driven controller worker sharing the service channels
local function attachWorker(harness)
  local Worker = require("romdump.src.build.CacheControllerWorker").Worker
  local channels = harness.threadHost.channels
  assert(#channels >= 2, "the service owns its command/reply channels before the worker attaches")
  local worker = Worker.new(channels[1], channels[2])
  harness.worker = worker
  -- Threads spawned so far are controller-side: the compiler pool boots
  -- only once the attached worker handles selection. Pool worker identity
  -- is therefore a thread position minus this prefix, never the raw
  -- controlled-thread index.
  harness.controllerThreads = #harness.threadHost.threads
  return worker
end

-- Pool worker identities owned by the attached controller, skipping the
-- controller-side spawns that share the controlled host.
---@param harness table live-app harness holding the attached controller worker
---@return integer[] compiler worker identities in spawn order
local function compilerWorkerIds(harness)
  local base = harness.controllerThreads or 0
  local ids = {}
  for position = base + 1, #harness.threadHost.threads do
    ids[#ids + 1] = position - base
  end
  return ids
end

---@param harness table live-app harness holding the attached controller worker
---@return table compiler pool owned by the attached controller
local function controllerPool(harness)
  local worker = assert(harness.worker, "no attached controller worker owns a compiler pool")
  return assert(worker.pool, "the controller owns no compiler pool before selection")
end

---@param harness table live-app harness
---@return table result channel shared by every compiler worker
local function resultChannel(harness)
  -- The service owns the first two channels (command, reply); the pool
  -- result channel follows once the attached worker selects a generation.
  return assert(harness.threadHost.channels[3], "the pool must create a result channel first")
end

---@param harness table live-app harness
---@param workerId integer
---@return table input channel owned by that compiler worker
local function inputChannel(harness, workerId)
  return assert(harness.threadHost.channels[3 + workerId], "missing input channel for worker " .. tostring(workerId))
end

---@param harness table live-app harness
---@param workerId integer
---@return table|nil most recently dispatched job still awaiting its reply
local function lastDispatchedJob(harness, workerId)
  local log = inputChannel(harness, workerId).log
  for index = #log, 1, -1 do
    local message = log[index]
    if type(message) == "table" and message.jobKey ~= nil and message.status == nil then
      return message
    end
  end
  return nil
end

---@param harness table live-app harness
---@param workerId integer
---@param pool table process-owned compiler pool for status checks
local function failRunningOnWorker(harness, workerId, pool)
  local job = assert(lastDispatchedJob(harness, workerId), "worker has no dispatched job to fail")
  local state = pool:status(job.jobKey)
  if state ~= "running" and state ~= "prepared" then
    return
  end
  resultChannel(harness):push({
    status = "failed",
    workerId = workerId,
    epoch = job.epoch,
    generationId = job.generationId,
    kind = job.kind,
    key = job.key,
    jobKey = job.jobKey,
    stageName = job.stageName,
    error = "synthetic worker failure",
  })
end

---@param pool table process-owned compiler pool for status checks
---@param harness table live-app harness
local function failEveryRunningWorker(pool, harness)
  for _, workerId in ipairs(compilerWorkerIds(harness)) do
    if lastDispatchedJob(harness, workerId) ~= nil then
      failRunningOnWorker(harness, workerId, pool)
    end
  end
end

-- Answers every close barrier the pool has sent so far with a matching
-- token, exactly as a draining worker would.
---@param harness table live-app harness
local function ackCloseContexts(harness)
  local result = resultChannel(harness)
  for _, workerId in ipairs(compilerWorkerIds(harness)) do
    local token = nil
    local log = inputChannel(harness, workerId).log
    for index = #log, 1, -1 do
      local message = log[index]
      if type(message) == "table" and message.kind == "close-context" then
        token = message.closeToken
        break
      end
    end
    if token ~= nil then
      result:push({ status = "context-closed", workerId = workerId, closeToken = token })
    end
  end
end

-- Drives the source-close barrier to completion: failing terminal work
-- releases busy slots with a pending close, and each pump collects the next
-- acknowledgement round until the importer starts or the budget is spent.
---@param App table application singleton under test
---@param harness table live-app harness
---@param rounds integer
local function drainBarrier(App, harness, rounds)
  for _ = 1, rounds do
    if #harness.importers > 0 then
      return
    end
    failEveryRunningWorker(controllerPool(harness), harness)
    ackCloseContexts(harness)
    pumpApp(App, harness, 1)
  end
end

---@param host table borrowed selected session host
---@return integer first map identity the source supports
local function supportedFieldMapId(host)
  for mapId = 0, 1200 do
    local ok, ready, failure = pcall(host.requestField, mapId, "required")
    if ok and (ready or failure == nil) then
      return mapId
    end
  end
  error("no supported field map for the selection", 0)
end

---@param context table runner context for capability skips
---@param fn fun(App: table, harness: table)
local function withLiveApp(context, fn)
  local RomImporter = require("romdump.src.source.RomImporter")
  if not RomImporter.isReady(VERSION) then
    context:skip("no ready user-owned HGSS dump")
  end
  local App = require("app.src.App")
  local HgssGame = require("game.hgss.src.HgssGame")
  local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
  local realLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local original = {
    state = App.state,
    importer = App.importer,
    provisioner = App.provisioner,
    service = App.service,
    pendingQuiesce = App.pendingQuiesce,
    opts = App.opts,
    saveDir = App.saveDir,
    epoch = App.epoch,
    drawableWidth = App.drawableWidth,
    drawableHeight = App.drawableHeight,
    gameNew = HgssGame.new,
    importerNew = RomImporter.new,
    appBackend = ProducerFingerprint.appBackend,
    checkoutBackend = ProducerFingerprint.checkoutBackend,
    quit = realLove.event.quit,
    print = realLove.graphics.print,
  }
  if App.service ~= nil then
    pcall(function()
      App.service:shutdown()
    end)
  end
  App.opts = { dev = true }
  App.state = nil
  App.importer = nil
  App.provisioner = nil
  App.service = nil
  App.epoch = 0
  App.saveDir = "test-save-dir"
  App.drawableWidth, App.drawableHeight = 640, 480
  -- A fixed synthetic producer tree keeps the development digest
  -- deterministic and fast; selection ownership never depends on its bytes.
  ProducerFingerprint.appBackend = function()
    return {
      list = function()
        return {}
      end,
      read = function()
        error("the empty source fixture has no files")
      end,
      getInfo = function(path)
        if path == "romdump/src" then
          return { type = "directory" }
        end
        return nil
      end,
    }
  end
  ProducerFingerprint.checkoutBackend = function(_)
    return {
      list = function()
        return { "build/Compiler.lua" }
      end,
      read = function(_)
        return "selection ownership fixture"
      end,
      getInfo = function(path)
        if path == "romdump/src" then
          return { type = "directory" }
        end
        return nil
      end,
    }
  end
  local harness = { launches = {}, importers = {}, quitCodes = {}, prints = {}, threadHost = newControlledThreadHost() }
  local threadHost = harness.threadHost
  -- Live-controller tests own threading contracts, never attestation
  -- currency: stub the durable answers so no real file is read or
  -- written and ordinary selections keep their bootstrap paths.
  local completionOriginals = stubFirstPlayCompletion({})
  local restoreStartupTitle = stubStartupTitleHandoff()
  HgssGame.new = function(options)
    harness.launches[#harness.launches + 1] = options
    local game = { disposed = 0 }
    function game:dispose()
      self.disposed = self.disposed + 1
    end
    return game
  end
  RomImporter.new = function(options)
    local importer = { filedroppedCalls = 0, updates = 0, state = "waiting" }
    if type(options) == "table" then
      importer.onComplete = options.onComplete
    end
    function importer:isBusy()
      return false
    end
    function importer:update()
      self.updates = self.updates + 1
    end
    function importer:filedropped(_)
      self.filedroppedCalls = self.filedroppedCalls + 1
    end
    harness.importers[#harness.importers + 1] = importer
    return importer
  end
  realLove.event.quit = function(code)
    harness.quitCodes[#harness.quitCodes + 1] = code
  end
  realLove.graphics.print = function(text, _, _)
    harness.prints[#harness.prints + 1] = tostring(text)
  end
  rawset(
    _G,
    "love",
    setmetatable({
      thread = {
        newChannel = function()
          return threadHost.newChannel()
        end,
        newThread = function()
          return threadHost.newThread()
        end,
      },
      system = {
        getProcessorCount = function()
          return 5
        end,
      },
    }, { __index = realLove })
  )
  local ok, err = pcall(fn, App, harness)
  restoreStartupTitle()
  rawset(_G, "love", realLove)
  restoreFirstPlayCompletion(completionOriginals)
  HgssGame.new = original.gameNew
  RomImporter.new = original.importerNew
  ProducerFingerprint.appBackend = original.appBackend
  ProducerFingerprint.checkoutBackend = original.checkoutBackend
  realLove.event.quit = original.quit
  realLove.graphics.print = original.print
  App.state = original.state
  App.importer = original.importer
  App.provisioner = original.provisioner
  App.service = original.service
  App.pendingQuiesce = original.pendingQuiesce
  App.opts = original.opts
  App.saveDir = original.saveDir
  App.epoch = original.epoch
  App.drawableWidth = original.drawableWidth
  App.drawableHeight = original.drawableHeight
  if not ok then
    error(err, 0)
  end
end

---@param App table application singleton under test
---@param versionId string
---@return table attached provisioner
local function selectVersion(App, versionId)
  App._selectVersion(versionId)
  return assert(App.provisioner, "selection must attach a provisioner")
end

function T.drop_during_pending_work_retires_interest_before_source_closure(context)
  withLiveApp(context, function(App, harness)
    local provisioner = selectVersion(App, VERSION)
    attachWorker(harness)
    local host = provisioner:gameHost()
    local mapId = supportedFieldMapId(host)
    pumpApp(App, harness, 6)
    local before = controllerPool(harness):diagnostics()
    Assert.isTrue(before.counts.running > 0, "the selection must have physical work in flight")
    local dispatchedBeforeDrop = #harness.threadHost.dispatched
    Assert.isTrue(dispatchedBeforeDrop > 0, "pending work must have reached worker input")
    App.filedropped({})
    Assert.isNil(App.importer, "raw replacement must wait for source closure instead of mutating the dump")
    Assert.notNil(App.state, "the drop waits through a visible preparation state")
    Assert.equal(
      getmetatable(App.state).__index,
      CachePreparationState,
      "the drop waits through the preparation state while readers drain"
    )
    -- In-flight game input through the retained host must reject as retired
    -- instead of admitting new interest into the quiescing pool.
    local retiredOk, retiredErr = pcall(host.requestField, mapId, "required")
    Assert.isFalse(retiredOk, "the dropped selection must retire its host before the barrier")
    Assert.isTrue(Errors.is(retiredErr), "the retired rejection is a structured lifecycle error")
    Assert.equal(retiredErr.code, "DERIVED_ASSETS_RETIRED")
    pumpApp(App, harness, 3)
    Assert.equal(
      #harness.threadHost.dispatched,
      dispatchedBeforeDrop,
      "no admission occurs after quiesce while the UI keeps pumping"
    )
    Assert.isNil(App.importer, "pumping never starts the importer before source closure")
    drainBarrier(App, harness, 10)
    Assert.equal(#harness.importers, 1, "the importer starts exactly once after source closure")
    Assert.equal(harness.importers[1].filedroppedCalls, 1, "the dropped file forwards to the importer once")
  end)
end

function T.cancelled_selection_still_guards_raw_import_behind_source_closure(context)
  withLiveApp(context, function(App, harness)
    local provisioner = selectVersion(App, VERSION)
    attachWorker(harness)
    local host = provisioner:gameHost()
    supportedFieldMapId(host)
    pumpApp(App, harness, 6)
    local pool = controllerPool(harness)
    Assert.isTrue(pool:diagnostics().counts.running > 0, "cancelled work must stay physically charged")
    assert(App.state, "selection must install a preparation state"):keypressed("escape", nil, nil)
    Assert.isNil(App.provisioner, "cancellation detaches the selection back to the selector")
    Assert.equal(controllerPool(harness), pool, "cancellation preserves the process-owned pool")
    Assert.isTrue(pool:diagnostics().counts.running > 0, "cancelled physical work stays charged to the pool")
    Assert.equal(getmetatable(App.state).__index, VersionSelectState, "cancellation returns to the version selector")
    App.filedropped({})
    Assert.isNil(App.importer, "a selector drop waits for the source barrier with old readers outstanding")
    pumpApp(App, harness, 2)
    Assert.isNil(App.importer, "pumping never starts the importer before source closure")
    drainBarrier(App, harness, 10)
    Assert.equal(#harness.importers, 1, "raw import starts exactly once after the barrier")
    Assert.equal(harness.importers[1].filedroppedCalls, 1, "the dropped file forwards to the importer once")
    Assert.equal(pool:diagnostics().counts.ready, 0, "old terminal work never publishes through the barrier")
  end)
end

function T.cancelled_preparation_leaves_persisted_save_bytes_unchanged(context)
  withLiveApp(context, function(App, harness)
    local saveFs = SaveFs.global()
    local store = GameSaveStore.new(saveFs)
    local catalogBefore = saveFs:read(GameSaveStore.CATALOG_PATH)
    local saveId = store:reserve()
    store:publishFirst(record(saveId))
    local gamePath = "games/" .. saveId .. ".lua"
    local catalogSeeded = assert(saveFs:read(GameSaveStore.CATALOG_PATH), "seeding publishes a catalog")
    local gameSeeded = assert(saveFs:read(gamePath), "seeding publishes the save body")
    local provisioner = selectVersion(App, VERSION)
    attachWorker(harness)
    local host = provisioner:gameHost()
    supportedFieldMapId(host)
    pumpApp(App, harness, 6)
    assert(App.state, "selection must install a preparation state"):keypressed("escape", nil, nil)
    Assert.isNil(App.provisioner, "cancellation detaches the selection back to the selector")
    selectVersion(App, VERSION)
    pumpApp(App, harness, 4)
    Assert.equal(
      saveFs:read(GameSaveStore.CATALOG_PATH),
      catalogSeeded,
      "cancel and reselection rewrite no save catalog bytes"
    )
    Assert.equal(saveFs:read(gamePath), gameSeeded, "cancel and reselection rewrite no save body bytes")
    saveFs:remove(gamePath)
    if catalogBefore == nil then
      saveFs:remove(GameSaveStore.CATALOG_PATH)
    else
      saveFs:write(GameSaveStore.CATALOG_PATH, catalogBefore)
    end
  end)
end

function T.same_version_reselection_reuses_one_service_with_fresh_interest(context)
  withLiveApp(context, function(App, harness)
    -- One production route: a cold boot-menu entry remains at the boot
    -- source gate until its required source and selected pair are admitted.
    App._bootMainMenu({ VERSION })
    attachWorker(harness)
    pumpApp(App, harness, 4)
    Assert.equal(#harness.launches, 0, "a cold boot-menu entry must wait for preparation, not launch directly")
    Assert.equal(getmetatable(App.state).__index, CachePreparationState, "cold boot keeps its preparation owner")
    Assert.equal(App.state.kind, "boot-source", "cold boot waits at its source gate before the title handoff")
    local pool = controllerPool(harness)
    local firstEpoch = assert(App.epoch, "selection must mint an epoch")
    local firstHost = assert(App.provisioner, "selection must attach a provisioner"):gameHost()
    local mapId = supportedFieldMapId(firstHost)
    pumpApp(App, harness, 6)
    assert(App.state, "selection must install a preparation state"):keypressed("escape", nil, nil)
    local second = selectVersion(App, VERSION)
    pumpApp(App, harness, 4)
    Assert.equal(controllerPool(harness), pool, "reselection reuses the one process pool")
    Assert.isTrue(App.epoch > firstEpoch, "reselection mints a fresh epoch on the shared pool")
    Assert.equal(pool:diagnostics().selected.epoch, App.epoch, "the pool tracks the reselected epoch")
    -- The old interest is retired exactly once: its host rejects, repeated
    -- disposal is safe, and the new host serves fresh interest.
    local retiredOk, retiredErr = pcall(firstHost.requestField, mapId, "required")
    Assert.isFalse(retiredOk, "old interest retires when the selection moves on")
    Assert.isTrue(Errors.is(retiredErr), "the retired rejection is a structured lifecycle error")
    Assert.equal(retiredErr.code, "DERIVED_ASSETS_RETIRED")
    local secondHost = second:gameHost()
    local ready, failure = secondHost.requestField(mapId, "required")
    Assert.isFalse(ready, "fresh interest starts pending, never satisfied by old work")
    Assert.isNil(failure, "fresh interest carries no failure from the retired epoch")
    -- A late completion stamped with the retired epoch cannot satisfy the
    -- reselected interest waiting under the same job identity.
    local stale = nil
    local staleWorker = nil
    for _, workerId in ipairs(compilerWorkerIds(harness)) do
      stale = lastDispatchedJob(harness, workerId)
      if stale ~= nil then
        staleWorker = workerId
        break
      end
    end
    local answered = assert(stale, "the retired epoch must have dispatched work to answer late")
    resultChannel(harness):push({
      status = "prepared",
      workerId = assert(staleWorker, "a stale dispatch needs its worker"),
      epoch = firstEpoch,
      generationId = answered.generationId,
      kind = answered.kind,
      key = answered.key,
      jobKey = answered.jobKey,
      stageName = answered.stageName,
    })
    pumpApp(App, harness, 2)
    local state, _ = pool:status(answered.jobKey)
    Assert.isTrue(state ~= "ready", "late old-epoch output cannot publish for the new interest")
    Assert.equal(pool:diagnostics().counts.ready, 0, "no obsolete output publishes through reselection")
  end)
end

function T.worker_failure_surfaces_in_preparation_without_further_requests(context)
  withLiveApp(context, function(App, harness)
    local RomImporter = require("romdump.src.source.RomImporter")
    local provisioner = selectVersion(App, VERSION)
    attachWorker(harness)
    local host = provisioner:gameHost()
    supportedFieldMapId(host)
    pumpApp(App, harness, 6)
    Assert.isTrue(
      controllerPool(harness):diagnostics().counts.running > 0,
      "the preparation must have physical work in flight"
    )
    local dispatchedBeforeFailure = #harness.threadHost.dispatched
    -- A genuine worker death behind running work, observed through the
    -- controlled transport rather than a staged session error.
    local crashed = nil
    for _, workerId in ipairs(compilerWorkerIds(harness)) do
      if lastDispatchedJob(harness, workerId) ~= nil then
        crashed = workerId
        break
      end
    end
    Assert.notNil(crashed, "a busy worker is required to fail behind the preparation view")
    local crashedPosition = (harness.controllerThreads or 0) + assert(crashed)
    local thread = harness.threadHost.threads[crashedPosition]
    thread.alive = false
    thread.threadError = "synthetic worker crash"
    pumpApp(App, harness, 1)
    pumpApp(App, harness, 3)
    Assert.equal(
      #harness.threadHost.dispatched,
      dispatchedBeforeFailure,
      "no further producer requests occur after the infrastructure failure"
    )
    Assert.notNil(controllerPool(harness):diagnostics().error, "the pool records the infrastructure failure")
    local state = assert(App.state, "the preparation view stays installed through the failure")
    state:draw()
    local shown = false
    for _, text in ipairs(harness.prints) do
      if text:lower():find("fail", 1, true) ~= nil then
        shown = true
        break
      end
    end
    Assert.isTrue(shown, "the preparation view presents the failure instead of crashing")
    state:keypressed("escape", nil, nil)
    Assert.equal(
      getmetatable(App.state).__index,
      VersionSelectState,
      "cancellation after failure returns to the version selector"
    )
    Assert.isNil(App.importer, "cancellation after failure modifies no raw files")
    Assert.equal(#harness.importers, 0, "cancellation after failure starts no import")
    Assert.isTrue(RomImporter.isReady(VERSION), "the previous raw dump is untouched by the failed preparation")
  end)
end

function T.quit_after_cancelled_preparation_joins_owned_workers_once(context)
  withLiveApp(context, function(App, harness)
    local provisioner = selectVersion(App, VERSION)
    attachWorker(harness)
    local host = provisioner:gameHost()
    supportedFieldMapId(host)
    pumpApp(App, harness, 6)
    local pool = controllerPool(harness)
    Assert.isTrue(pool:diagnostics().counts.running > 0, "cancelled work must stay physically charged")
    assert(App.state, "selection must install a preparation state"):keypressed("escape", nil, nil)
    Assert.isNil(App.provisioner, "no provisioner remains after cancellation")
    -- A late prepared reply for the retired epoch is discarded, never
    -- published, even though its worker slot still matches. This settles
    -- before any other failure so the reply still finds its slot.
    local stale = nil
    local staleWorker = nil
    for _, workerId in ipairs(compilerWorkerIds(harness)) do
      stale = lastDispatchedJob(harness, workerId)
      if stale ~= nil then
        staleWorker = workerId
        break
      end
    end
    local answered = assert(stale, "retired work is required to answer late")
    resultChannel(harness):push({
      status = "prepared",
      workerId = assert(staleWorker, "a stale dispatch needs its worker"),
      epoch = answered.epoch,
      generationId = answered.generationId,
      kind = answered.kind,
      key = answered.key,
      jobKey = answered.jobKey,
      stageName = answered.stageName,
    })
    pumpApp(App, harness, 1)
    local staleState, _ = pool:status(answered.jobKey)
    Assert.equal(staleState, "cancelled", "late old-epoch output cannot publish after retirement")
    Assert.equal(pool:diagnostics().counts.ready, 0, "obsolete outputs never publish")
    -- Physical lifecycle keeps moving with no session attached: terminal
    -- work settles instead of lingering on the detached pool.
    failEveryRunningWorker(pool, harness)
    pumpApp(App, harness, 2)
    Assert.equal(
      pool:diagnostics().counts.running,
      0,
      "detached updates settle old physical work without reviving the session"
    )
    Assert.isNil(App.provisioner, "settling detached work never reattaches a session")
    App.quit()
    pumpApp(App, harness, 4)
    for _, thread in ipairs(harness.threadHost.threads) do
      Assert.equal(thread.waits, 1, "each owned thread joins exactly once")
    end
    Assert.isNil(App.service, "quit releases the process service")
    Assert.isNil(App.provisioner, "quit leaves no selection behind")
    App.quit()
    pumpApp(App, harness, 2)
    for _, thread in ipairs(harness.threadHost.threads) do
      Assert.equal(thread.waits, 1, "a repeated quit never rejoins owned threads")
    end
  end)
end

function T.selection_switch_to_another_version_reuses_the_service_with_a_fresh_epoch()
  withAppStubs(function(App, context)
    local service = assert(App.service, "the application owns one process cache service")
    App._selectVersion(VERSION)
    App.update(1 / 60)
    App.update(1 / 60)
    App._selectVersion("soulsilver")
    App.update(1 / 60)
    App.update(1 / 60)
    Assert.equal(App.service, service, "a switch reuses the service instead of spawning a second")
    Assert.deepEqual(context.epochs, { 1, 2 }, "switching versions mints a new epoch on the shared service")
    Assert.deepEqual(context.retires, { 1 }, "the old interest retires exactly once without joining workers")
    Assert.equal(#context.games, 0, "a ready selection installs the app menu without launching retail")
    Assert.equal(#context.menus, 2, "each selected version publishes its own menu")
  end)
end

function T.dropped_file_before_any_worker_starts_a_fresh_import()
  withAppStubs(function(App, _)
    local RomImporter = require("romdump.src.source.RomImporter")
    local ImportState = require("app.src.launcher.ImportState")
    local originalNew = RomImporter.new
    local calls = { constructed = 0, filedropped = 0 }
    rawset(RomImporter, "new", function(_)
      calls.constructed = calls.constructed + 1
      return {
        state = "waiting",
        isBusy = function()
          return false
        end,
        update = function() end,
        filedropped = function()
          calls.filedropped = calls.filedropped + 1
        end,
      }
    end)
    local ok, err = pcall(function()
      App.service = nil
      Assert.isNil(App.service, "no worker exists before the first selection")
      App.filedropped({ name = "first.nds" })
      Assert.equal(calls.constructed, 1, "a drop with no service starts an import immediately")
      Assert.equal(calls.filedropped, 1, "the dropped file forwards to the fresh importer")
      Assert.equal(getmetatable(App.state).__index, ImportState, "the drop enters through the import state")
    end)
    rawset(RomImporter, "new", originalNew)
    App.state = nil
    App.importer = nil
    if not ok then
      error(err, 0)
    end
  end)
end

function T.failed_source_closure_blocks_raw_mutation_and_stays_cancellable()
  withAppStubs(function(App, context)
    local RomImporter = require("romdump.src.source.RomImporter")
    local originalNew = RomImporter.new
    local constructed = 0
    rawset(RomImporter, "new", function(_)
      constructed = constructed + 1
      return {
        state = "waiting",
        isBusy = function()
          return false
        end,
        update = function() end,
        filedropped = function() end,
      }
    end)
    App.provisioner = {
      update = function() end,
      dispose = function() end,
    }
    local graphics = love.graphics
    local originalPrint = graphics.print
    local originalPrintf = graphics.printf
    local prints = {}
    graphics.print = function(text, _, _)
      prints[#prints + 1] = tostring(text)
    end
    graphics.printf = function(text, _, _, _)
      prints[#prints + 1] = tostring(text)
    end
    local ok, err = pcall(function()
      App.filedropped({ name = "replacement.zip" })
      assert(App.pendingQuiesce ~= nil, "the drop waits behind a quiescence barrier")
      local barrier = App.pendingQuiesce.barrier
      App.update(1 / 60)
      App.update(1 / 60)
      Assert.equal(constructed, 0, "no raw mutation begins before the barrier settles")
      context.barriers[barrier].status = "failed"
      App.update(1 / 60)
      Assert.equal(constructed, 0, "no raw mutation begins after an unsuccessful barrier")
      local waiting = assert(App.state, "the waiting view stays installed through the failure")
      waiting:draw()
      local shown = false
      for _, text in ipairs(prints) do
        if text:lower():find("fail", 1, true) ~= nil then
          shown = true
          break
        end
      end
      Assert.isTrue(shown, "the waiting view presents the barrier failure instead of importing")
      waiting:keypressed("escape", nil, nil)
      Assert.equal(
        getmetatable(App.state).__index,
        VersionSelectState,
        "cancellation after barrier failure returns to the version selector"
      )
      Assert.equal(constructed, 0, "cancelling the failed wait starts no import")
    end)
    graphics.print = originalPrint
    graphics.printf = originalPrintf
    rawset(RomImporter, "new", originalNew)
    App.state = nil
    App.importer = nil
    App.provisioner = nil
    App.pendingQuiesce = nil
    if not ok then
      error(err, 0)
    end
  end)
end

function T.repeated_dispose_and_quit_release_owned_resources_once()
  withAppStubs(function(App, context)
    App._selectVersion(VERSION)
    local provisioner = assert(App.provisioner, "selection must attach a provisioner")
    provisioner:dispose()
    provisioner:dispose()
    Assert.deepEqual(context.retires, { 1 }, "repeated disposal retires the epoch exactly once")
    App.quit()
    App.quit()
    Assert.equal(context.joins, 1, "repeated quit joins owned workers exactly once")
    Assert.isNil(App.service, "quit releases the process service")
    Assert.isNil(App.provisioner, "quit leaves no selection behind")
  end)
end

function T.selection_waits_behind_source_closure_then_selects_once()
  withAppStubs(function(App, context)
    App._selectVersion(VERSION)
    local epochBefore = assert(App.epoch, "selection must mint an epoch")
    App.filedropped({ name = "dropped.zip" })
    Assert.isNil(App.importer, "the drop waits for source closure instead of importing")
    local firstWait = assert(App.state, "the drop waits visibly")
    Assert.isNil(App.provisioner, "the drop retires selected interest before the barrier")
    -- A selection behind the outstanding barrier installs a second wait on
    -- the same barrier instead of selecting: no provisioner, no epoch, no
    -- second barrier.
    local pendingOk, pendingErr = pcall(App._selectVersion, VERSION)
    Assert.isTrue(
      pendingOk,
      "selection behind an outstanding barrier must wait instead of raising: " .. tostring(pendingErr)
    )
    Assert.isNil(App.provisioner, "the pending selection constructs no provisioner before closure")
    Assert.equal(App.epoch, epochBefore, "the pending selection mints no epoch before closure")
    Assert.equal(context.quiesces, 1, "the pending selection issues no second barrier")
    local secondWait = assert(App.state, "the pending selection waits visibly")
    Assert.isTrue(secondWait ~= firstWait, "the pending selection installs its own wait")
    Assert.equal(secondWait.kind, "quiescence", "the pending selection waits on source closure")
    -- Replacing the pending choice keeps only the later continuation: the
    -- replaced wait is disposed and can never fire late.
    local replaceOk, replaceErr = pcall(App._selectVersion, "soulsilver")
    Assert.isTrue(replaceOk, "a replacement selection must wait instead of raising: " .. tostring(replaceErr))
    Assert.isNil(App.provisioner, "the replacement constructs no provisioner before closure")
    Assert.equal(App.epoch, epochBefore, "the replacement mints no epoch before closure")
    Assert.equal(context.quiesces, 1, "the replacement issues no second barrier")
    local liveWait = assert(App.state, "the replacement waits visibly")
    Assert.isTrue(secondWait.dead, "the replaced wait can never fire late")
    -- The surviving selection still waits on bootstrap until the milestone
    -- is actually ready; the barrier acknowledgement alone must not launch.
    context.observations["milestone:bootstrap:nil:nil"] = { ready = nil, failure = nil }
    assert(context.barriers[1] ~= nil, "the drop holds one quiescence barrier")
    context.barriers[1].status = "ready"
    App.update(1 / 60)
    Assert.isTrue(liveWait.fired, "the live wait fires exactly once")
    Assert.isFalse(firstWait.fired, "the superseded drop wait never fires")
    Assert.isFalse(secondWait.fired, "the replaced wait never fires")
    local selected = assert(App.provisioner, "exactly one surviving selection attaches after closure")
    Assert.equal(App.epoch, epochBefore + 1, "the surviving selection mints exactly one fresh epoch")
    Assert.equal(
      context.selectOptions[#context.selectOptions].versionId,
      "soulsilver",
      "only the latest live choice selects"
    )
    Assert.equal(selected, App.provisioner, "no further selection replaces the survivor")
    Assert.equal(#context.imports, 0, "the cancelled dropped file is never imported")
    -- The surviving selection still passes its boot gate before waiting on
    -- bootstrap: the barrier acknowledgement alone must not launch.
    App.update(1 / 60)
    local survivorState = assert(App.state, "a cold surviving selection still waits visibly")
    Assert.equal(survivorState.kind, "startup-title", "the surviving selection enters the title handoff")
  end)
end

function T.only_the_live_pending_selection_fires_and_quit_joins_once()
  withAppStubs(function(App, context)
    App._selectVersion(VERSION)
    local epochBefore = assert(App.epoch, "selection must mint an epoch")
    App.filedropped({ name = "dropped.zip" })
    assert(App.state, "the drop waits visibly")
    local firstOk, firstErr = pcall(App._selectVersion, VERSION)
    Assert.isTrue(firstOk, "the first pending selection must wait instead of raising: " .. tostring(firstErr))
    local firstWait = assert(App.state, "the first pending selection waits visibly")
    local secondOk, secondErr = pcall(App._selectVersion, "soulsilver")
    Assert.isTrue(secondOk, "the replacement selection must wait instead of raising: " .. tostring(secondErr))
    local secondWait = assert(App.state, "the replacement waits visibly")
    Assert.isTrue(secondWait ~= firstWait, "the replacement installs its own wait")
    Assert.isTrue(firstWait.dead, "installing the replacement disposes the first wait")
    assert(context.barriers[1] ~= nil, "the drop holds one quiescence barrier")
    context.barriers[1].status = "ready"
    App.update(1 / 60)
    Assert.isTrue(firstWait.fired == false, "the disposed wait can never fire late")
    Assert.isTrue(secondWait.fired, "the live wait fires exactly once")
    Assert.equal(App.epoch, epochBefore + 1, "exactly one surviving selection mints one epoch")
    Assert.equal(
      context.selectOptions[#context.selectOptions].versionId,
      "soulsilver",
      "only the latest live choice executes"
    )
    Assert.equal(#context.imports, 0, "no import starts through the pending selections")
    -- A fresh barrier with a pending choice quits safely: nothing deferred
    -- may run and the owned service joins exactly once.
    local survivor = assert(App.provisioner, "the survivor attaches a provisioner")
    survivor:gameHost().requestMilestone("bootstrap", "required")
    App.update(1 / 60)
    App.filedropped({ name = "late.zip" })
    local lateWait = assert(App.state, "the late drop waits visibly")
    local lateOk, lateErr = pcall(App._selectVersion, VERSION)
    Assert.isTrue(lateOk, "the late pending selection must wait instead of raising: " .. tostring(lateErr))
    local latePending = assert(App.state, "the late pending selection waits visibly")
    Assert.isTrue(latePending ~= lateWait, "the late selection installs its own wait")
    local epochAtQuit = assert(App.epoch, "quitting never selects")
    App.quit()
    Assert.isTrue(latePending.dead, "quit disposes the pending continuation before shutdown")
    Assert.isTrue(lateWait.dead, "quit disposes every installed wait before shutdown")
    Assert.isNil(App.service, "quit releases the process service")
    Assert.isNil(App.provisioner, "quit leaves no selection behind")
    Assert.equal(#context.imports, 0, "quit executes no deferred import")
    Assert.equal(App.epoch, epochAtQuit, "quit executes no deferred selection")
    Assert.equal(context.joins, 1, "the owned service joins exactly once")
    App.quit()
    Assert.equal(context.joins, 1, "a repeated quit never rejoins the service")
  end)
end

-- The fixed icon-page dispatch reaches the selected session without a
-- parallel scheduler: unknown pages fail through the session cause and
-- unknown kinds never dispatch.
function T.icon_page_dispatch_reaches_the_selected_session()
  local Worker = require("romdump.src.build.CacheControllerWorker").Worker
  local control = {
    pop = function()
      return nil
    end,
  }
  local replies = {}
  local reply = {
    push = function(_, packet)
      replies[#replies + 1] = packet
    end,
  }
  local worker = Worker.new(control, reply)
  local seen = {}
  worker.session = {
    requestIconPage = function(_, pageId, urgency)
      seen[#seen + 1] = { pageId = pageId, urgency = urgency }
      return true
    end,
  }
  local ready = worker:_invoke({ requestKind = "icon-page", pageId = 3, urgency = "required" })
  Assert.isTrue(ready, "the selected session answers the icon dispatch")
  Assert.deepEqual(seen, { { pageId = 3, urgency = "required" } }, "icon dispatch carries its scalar selectors")
  local unknownOk, _ = pcall(function()
    return worker:_invoke({ requestKind = "sticker-page", pageId = 3, urgency = "required" })
  end)
  Assert.isFalse(unknownOk, "an unlisted kind never dispatches")
end

-- Boot-only source gate composition through the real service protocol: a
-- fake thread host carries FIFO channels, the real CacheService owns
-- epochs and boot observations, and scripted controller replies stand in
-- for the off-main worker. Synthetic first-play answers model the durable
-- attestation currency; no ROM bytes are opened or hashed here. These
-- scenarios prove the app refuses gameplay without source readiness while
-- a complete cache keeps its offline fast path; they stay red until the
-- launcher gates every selection on the boot check.
local function newBootGateChannelHost()
  local channels = {}
  local function newChannel()
    local queue = {}
    local channel = { log = {} }
    function channel:push(value)
      queue[#queue + 1] = value
      channel.log[#channel.log + 1] = value
      return true
    end
    function channel:pop()
      if #queue == 0 then
        return nil
      end
      return table.remove(queue, 1)
    end
    function channel:demand(_)
      if #queue == 0 then
        return nil
      end
      return table.remove(queue, 1)
    end
    function channel:getCount()
      return #queue
    end
    function channel:count()
      return #queue
    end
    channels[#channels + 1] = channel
    return channel
  end
  local threads = {}
  local function newThread(_)
    local thread = { starts = 0, waits = 0, alive = true }
    function thread:start(...)
      self.starts = self.starts + 1
      return true
    end
    function thread:wait()
      self.waits = self.waits + 1
      self.alive = false
      return true
    end
    function thread:isRunning()
      return self.alive
    end
    function thread:getError()
      return nil
    end
    threads[#threads + 1] = thread
    return thread
  end
  return { newChannel = newChannel, newThread = newThread, channels = channels, threads = threads }
end

---@param options table|nil { firstPlayCurrent: boolean?, firstPlayStored: boolean?, readyVersions: string[]? }
---@param fn fun(App: table, context: table)
local function withBootGateApp(options, fn)
  options = options or {}
  local App = require("app.src.App")
  local HgssGame = require("game.hgss.src.HgssGame")
  local MainMenuComposition = require("app.src.mainmenu.MainMenuComposition")
  local RomImporter = require("romdump.src.source.RomImporter")
  local HgssLoadingPresentation = require("libs.hgss.src.ui.HgssLoadingPresentation")
  local CacheService = require("app.src.CacheService")
  local graphics = love.graphics
  local original = {
    state = App.state,
    importer = App.importer,
    provisioner = App.provisioner,
    service = App.service,
    epoch = App.epoch,
    pendingQuiesce = App.pendingQuiesce,
    opts = App.opts,
    saveDir = App.saveDir,
    selectedVersionId = App.selectedVersionId,
    rebindVersionId = App._rebindVersionId,
    drawableWidth = App.drawableWidth,
    drawableHeight = App.drawableHeight,
    pixelRatio = App.pixelRatio,
    gameNew = HgssGame.new,
    preparationNew = HgssGame.newFirstPlayCachePreparation,
    menuNew = MainMenuComposition.new,
    loadingNew = HgssLoadingPresentation.new,
    isReady = RomImporter.isReady,
    getDimensions = graphics.getDimensions,
    getDPIScale = graphics.getDPIScale,
    getWidth = graphics.getWidth,
    setColor = graphics.setColor,
    print = graphics.print,
    printf = graphics.printf,
  }
  local readySet = {}
  for _, versionId in ipairs(options.readyVersions or { VERSION }) do
    readySet[versionId] = true
  end
  local host = newBootGateChannelHost()
  local service = CacheService.new({ thread = host })
  local context = {
    host = host,
    service = service,
    menus = {},
    games = {},
    preparations = 0,
    prepScript = { ready = false, failure = nil, polls = 0, disposals = 0 },
    prints = {},
    sweeps = 0,
    firstPlayPublished = {},
  }
  local completionOriginals = stubFirstPlayCompletion(context)
  local restoreStartupTitle = stubStartupTitleHandoff()
  context.firstPlayCurrent = options.firstPlayCurrent
  if context.firstPlayCurrent == nil then
    context.firstPlayCurrent = true
  end
  context.firstPlayStored = options.firstPlayStored
  if context.firstPlayStored == nil then
    context.firstPlayStored = true
  end
  App.opts = { dev = false }
  App.state = nil
  App.importer = nil
  App.provisioner = nil
  App.service = service
  App.epoch = 0
  App.pendingQuiesce = nil
  App.saveDir = "test-save-dir"
  App.selectedVersionId = nil
  App._rebindVersionId = nil
  App.drawableWidth, App.drawableHeight = 640, 480
  App.pixelRatio = 1
  RomImporter.isReady = function(versionId)
    return readySet[versionId] == true
  end
  -- The cold boot wait adopts its selected pair through the themed
  -- presentation, whose GPU acquisition needs generated fixtures this
  -- channel harness never builds: model an instantly drawable pair so the
  -- control-stream ordering stays under test instead of stalling on art.
  HgssLoadingPresentation.new = function(_)
    local presentation = {}
    function presentation:update() end
    function presentation:resize() end
    function presentation:draw() end
    function presentation:dispose() end
    function presentation:adoptGeneratedAssets()
      return true
    end
    return presentation
  end
  HgssGame.newFirstPlayCachePreparation = function(_)
    context.preparations = context.preparations + 1
    local preparation = {}
    function preparation:poll()
      context.prepScript.polls = context.prepScript.polls + 1
      if context.prepScript.failure ~= nil then
        return nil, context.prepScript.failure
      end
      if context.prepScript.ready then
        return true, nil
      end
      return nil, nil
    end
    function preparation:dispose()
      context.prepScript.disposals = context.prepScript.disposals + 1
    end
    return preparation
  end
  HgssGame.new = function(launchOptions)
    local game = { disposed = 0, launchOptions = launchOptions }
    function game:dispose()
      self.disposed = self.disposed + 1
    end
    context.games[#context.games + 1] = game
    return game
  end
  MainMenuComposition.new = function(menuOptions)
    local menu = { disposed = 0, options = menuOptions }
    function menu:dispose()
      self.disposed = self.disposed + 1
    end
    context.menus[#context.menus + 1] = menu
    return menu
  end
  local baseEnableSweep = service.enableSweep
  service.enableSweep = function(self, epoch)
    context.sweeps = context.sweeps + 1
    return baseEnableSweep(self, epoch)
  end
  graphics.getDimensions = function()
    return 640, 480
  end
  graphics.getDPIScale = function()
    return 1
  end
  graphics.getWidth = function()
    return 640
  end
  graphics.setColor = function() end
  graphics.print = function(text, _, _)
    context.prints[#context.prints + 1] = tostring(text)
  end
  graphics.printf = function(text, _, _, _)
    context.prints[#context.prints + 1] = tostring(text)
  end
  local ok, err = pcall(fn, App, context)
  restoreStartupTitle()
  HgssGame.new = original.gameNew
  HgssGame.newFirstPlayCachePreparation = original.preparationNew
  MainMenuComposition.new = original.menuNew
  HgssLoadingPresentation.new = original.loadingNew
  RomImporter.isReady = original.isReady
  restoreFirstPlayCompletion(completionOriginals)
  graphics.getDimensions = original.getDimensions
  graphics.getDPIScale = original.getDPIScale
  graphics.getWidth = original.getWidth
  graphics.setColor = original.setColor
  graphics.print = original.print
  graphics.printf = original.printf
  pcall(function()
    service:shutdown()
  end)
  App.state = original.state
  App.importer = original.importer
  App.provisioner = original.provisioner
  App.service = original.service
  App.epoch = original.epoch
  App.pendingQuiesce = original.pendingQuiesce
  App.opts = original.opts
  App.saveDir = original.saveDir
  App.selectedVersionId = original.selectedVersionId
  App._rebindVersionId = original.rebindVersionId
  App.drawableWidth = original.drawableWidth
  App.drawableHeight = original.drawableHeight
  App.pixelRatio = original.pixelRatio
  if not ok then
    error(err, 0)
  end
end

---@param App table application singleton under test
---@param rounds integer
local function pumpBootGate(App, rounds)
  for _ = 1, rounds do
    App.update(1 / 60)
  end
end

---@param context table boot-gate harness holding the fake channel host
---@return integer current length of the command-channel log
local function logMark(context)
  return #context.host.channels[1].log
end

---@param context table boot-gate harness holding the fake channel host
---@param mark integer log position to start after
---@return string[] control op names emitted after the mark
local function emittedOpsSince(context, mark)
  local ops = {}
  local log = context.host.channels[1].log
  for index = mark + 1, #log do
    local packet = log[index]
    if type(packet) == "table" and type(packet.op) == "string" then
      ops[#ops + 1] = packet.op
    end
  end
  return ops
end

---@param context table boot-gate harness holding the fake channel host
---@param mark integer log position to start after
---@param epoch integer selecting epoch the control must belong to
---@return string[] control op names emitted after the mark for the epoch
local function emittedOpsForEpochSince(context, mark, epoch)
  local ops = {}
  local log = context.host.channels[1].log
  for index = mark + 1, #log do
    local packet = log[index]
    if type(packet) == "table" and type(packet.op) == "string" and packet.epoch == epoch then
      ops[#ops + 1] = packet.op
    end
  end
  return ops
end

---@param context table boot-gate harness holding the fake channel host
---@param mark integer log position to start after
---@return integer number of ordinary cache demands emitted after the mark
local function emittedRequestsSince(context, mark)
  local count = 0
  local log = context.host.channels[1].log
  for index = mark + 1, #log do
    local packet = log[index]
    if type(packet) == "table" and packet.op == "request" then
      count = count + 1
    end
  end
  return count
end

---@param context table boot-gate harness holding the fake channel host
---@param epoch integer selecting epoch the demand must belong to
---@param name string milestone name
---@return integer? latest request identity for the milestone on the epoch
local function milestoneRequestId(context, epoch, name)
  local found = nil
  local log = context.host.channels[1].log
  for _, packet in ipairs(log) do
    if
      type(packet) == "table"
      and packet.op == "request"
      and packet.epoch == epoch
      and packet.requestKind == "milestone"
      and packet.name == name
    then
      found = packet.requestId
    end
  end
  return found
end

---@param context table boot-gate harness holding the fake channel host
---@param epoch integer selected source epoch
---@return integer? the shared startup-walker request identity
local function walkerRequestId(context, epoch)
  local found = nil
  local log = context.host.channels[1].log
  for _, packet in ipairs(log) do
    if
      type(packet) == "table"
      and packet.op == "request"
      and packet.epoch == epoch
      and packet.requestKind == "startup-walker"
    then
      found = packet.requestId
    end
  end
  return found
end

---@param context table boot-gate harness holding the fake channel host
---@param op string control op to find
---@return table? latest control packet with the op
local function latestControlPacket(context, op)
  local found = nil
  local log = context.host.channels[1].log
  for _, packet in ipairs(log) do
    if type(packet) == "table" and packet.op == op then
      found = packet
    end
  end
  return found
end

---@param context table boot-gate harness holding the fake channel host
---@return string lowercased concatenation of every drawn line
local function drawnText(context)
  return table.concat(context.prints, "\n"):lower()
end

-- A stored bounded-opening attestation with no full-corpus marker must not
-- enter the fast menu: the selection waits on its source gate, a missing
-- file keeps the blocked wait alive with an actionable instruction and
-- destroys nothing, and a current full-corpus marker with the same missing
-- file reaches the menu with zero ROM file activity.
function T.incomplete_cache_with_a_ready_first_play_closure_stays_in_the_boot_wait()
  withBootGateApp({ firstPlayCurrent = true, firstPlayStored = true }, function(App, context)
    local RomFs = require("romdump.src.source.RomFs")
    local RomSource = require("romdump.src.source.RomSource")
    local realOpen = RomFs.open
    local realFromPath = RomSource.fromPath
    local romOpens, pathOpens = 0, 0
    RomFs.open = function(...)
      romOpens = romOpens + 1
      return realOpen(...)
    end
    RomSource.fromPath = function(...)
      pathOpens = pathOpens + 1
      return realFromPath(...)
    end
    local ok, err = pcall(function()
      local mark = logMark(context)
      App._selectVersion(VERSION)
      local epoch = assert(App.epoch, "selection must borrow a controller epoch")
      pumpBootGate(App, 1)
      Assert.deepEqual(
        emittedOpsSince(context, mark),
        { "select", "check-boot-source" },
        "selection queues its source gate on the control stream before any cache demand"
      )
      Assert.equal(emittedRequestsSince(context, mark), 0, "no bounded-closure demand issues before the gate answers")
      local waiting = assert(App.state, "selection must wait visibly")
      Assert.equal(getmetatable(waiting).__index, CachePreparationState, "selection waits through preparation")
      Assert.equal(
        waiting.kind,
        "boot-source",
        "an incomplete cache waits on its source gate even when first play is ready"
      )
      Assert.equal(#context.menus, 0, "a missing source never installs the menu")
      Assert.equal(#context.games, 0, "a missing source never starts retail")
      Assert.equal(context.preparations, 0, "no first-play preparation starts before source readiness")
      context.service:injectReply({
        op = "boot-source-result",
        epoch = epoch,
        state = "source-required",
        detail = { code = "ROM_SOURCE_REQUIRED", message = "the original file is missing" },
      })
      pumpBootGate(App, 2)
      local blocked = assert(App.state, "the source wait stays installed")
      Assert.equal(blocked.kind, "boot-source", "the missing source keeps the boot wait alive")
      Assert.equal(#context.menus, 0, "the blocked boot never installs the menu")
      Assert.equal(#context.games, 0, "the blocked boot never starts retail")
      Assert.deepEqual(context.firstPlayPublished, {}, "the blocked boot fabricates no attestation")
      Assert.isNil(App.importer, "the blocked boot starts no import by itself")
      context.prints = {}
      blocked:draw()
      local shown = drawnText(context)
      Assert.isTrue(shown:find("gold", 1, true) ~= nil, "the blocked boot names the selected game")
      Assert.isTrue(
        shown:find(".nds", 1, true) ~= nil
          or shown:find(".zip", 1, true) ~= nil
          or shown:find("drop", 1, true) ~= nil
          or shown:find("import", 1, true) ~= nil,
        "the blocked boot tells the player how to supply the file"
      )
      blocked:keypressed("escape", nil, nil)
      App._selectVersion(VERSION)
      local second = assert(App.epoch, "reselection must borrow a fresh epoch")
      Assert.isTrue(second > epoch, "reselection mints a fresh epoch")
      context.service:injectReply({ op = "boot-source-result", epoch = second, state = "ready" })
      -- The admitted warm wait holds its transfer until the required
      -- selected pair answers: reply to the keyed walker demand before
      -- expecting the title bootstrap.
      pumpBootGate(App, 2)
      local walkerId = assert(
        walkerRequestId(context, second),
        "the admitted wait requests exactly the selected walking pair"
      )
      context.service:injectReply({ op = "request-result", epoch = second, requestId = walkerId, state = "ready" })
      pumpBootGate(App, 3)
      local bootstrapId = assert(
        milestoneRequestId(context, second, "bootstrap"),
        "the title requests ordinary bootstrap readiness"
      )
      context.service:injectReply({ op = "request-result", epoch = second, requestId = bootstrapId, state = "ready" })
      pumpBootGate(App, 2)
      Assert.equal(#context.menus, 1, "a complete cache reaches its menu without its original file")
      Assert.equal(romOpens, 0, "the offline boot opens no ROM source")
      Assert.equal(pathOpens, 0, "the offline boot reads no ROM file")
    end)
    RomFs.open = realOpen
    RomSource.fromPath = realFromPath
    if not ok then
      error(err, 0)
    end
  end)
end

-- A fresh ephemeral import admits first play exactly once through one
-- epoch: the validated offer precedes the source gate, title warmup runs
-- beside bootstrap readiness, and the menu remains usable while that
-- optional work is pending.
function T.fresh_import_offer_reaches_the_controller_before_the_boot_check_on_one_epoch()
  withBootGateApp({ firstPlayCurrent = false, firstPlayStored = false }, function(App, context)
    local GameVersion = require("romdump.src.source.GameVersion")
    local RomFs = require("romdump.src.source.RomFs")
    local RomSource = require("romdump.src.source.RomSource")
    local realOpen = RomFs.open
    local realFromPath = RomSource.fromPath
    local romOpens, pathOpens = 0, 0
    RomFs.open = function(...)
      romOpens = romOpens + 1
      return realOpen(...)
    end
    RomSource.fromPath = function(...)
      pathOpens = pathOpens + 1
      return realFromPath(...)
    end
    local ok, err = pcall(function()
      local info = GameVersion.info(VERSION)
      local buffer = love.data.newByteData("synthetic-fresh-import-bytes")
      local released = 0
      App.importer = {
        status = function()
          return {
            state = "complete",
            versionId = VERSION,
            displayName = "HeartGold",
            sourceName = "fresh.nds",
            progress = 1,
          }
        end,
        takeVerifiedSource = function()
          return {
            byteData = function()
              return buffer
            end,
            release = function()
              released = released + 1
            end,
          }
        end,
      }
      local mark = logMark(context)
      App._onImported(VERSION)
      local epoch = assert(App.epoch, "the import must borrow a controller epoch")
      Assert.isNil(App.importer, "the completed importer is released at the handoff")
      Assert.equal(released, 1, "the handoff releases the importer wrapper exactly once")
      pumpBootGate(App, 1)
      Assert.deepEqual(
        emittedOpsSince(context, mark),
        { "select", "offer-source", "check-boot-source" },
        "the fresh offer waits behind selection and ahead of the gate on one control stream"
      )
      local offer = assert(latestControlPacket(context, "offer-source"), "the fresh offer crosses to the controller")
      Assert.isTrue(offer.byteData == buffer, "the offer hands the identical buffer by reference")
      Assert.equal(offer.romSha1, info.sha1, "the offer carries the canonical ROM identity")
      local waiting = assert(App.state, "the fresh import waits visibly")
      Assert.equal(waiting.kind, "boot-source", "a fresh import waits on its source gate before first play")
      Assert.equal(context.preparations, 0, "first-play preparation never starts before the gate answers")
      context.service:injectReply({ op = "boot-source-result", epoch = epoch, state = "ready" })
      pumpBootGate(App, 1)
      local waiting = assert(App.state, "the fresh import holds its card while the pair is pending")
      Assert.equal(waiting.kind, "boot-source", "verification and worker readiness stay distinct facts")
      -- The pair demand is queued during the wait's update, after the
      -- service already flushed this frame: one more pump carries it onto
      -- the control stream while the card stays held without a reply.
      pumpBootGate(App, 1)
      local held = assert(App.state, "the cold card survives the demand flush")
      Assert.equal(held.kind, "boot-source", "the pair demand alone never completes the handoff")
      local walkerId = assert(
        walkerRequestId(context, epoch),
        "the cold wait requests exactly the selected walking pair"
      )
      context.service:injectReply({ op = "request-result", epoch = epoch, requestId = walkerId, state = "ready" })
      -- One pump absorbs the pair answer and transfers to the title, one
      -- queues its bootstrap demand, and one flushes that demand on stream.
      pumpBootGate(App, 3)
      Assert.equal(App.epoch, epoch, "readiness reuses the selected epoch")
      Assert.equal(context.preparations, 1, "readiness constructs first-play preparation exactly once")
      local title = assert(App.state, "readiness continues visibly")
      Assert.equal(title.kind, "startup-title", "readiness continues into the title handoff")
      Assert.equal(#context.menus, 0, "bootstrap remains the menu admission milestone")
      local bootstrapId = assert(
        milestoneRequestId(context, epoch, "bootstrap"),
        "the title requests bootstrap while first-play warmup remains optional"
      )
      context.service:injectReply({ op = "request-result", epoch = epoch, requestId = bootstrapId, state = "ready" })
      pumpBootGate(App, 2)
      Assert.equal(#context.menus, 1, "bootstrap installs the menu while first-play remains pending")
      Assert.equal(#context.firstPlayPublished, 0, "pending background work publishes no completion")
      context.prepScript.ready = true
      pumpBootGate(App, 1)
      Assert.equal(#context.firstPlayPublished, 1, "background success publishes its completion once")
      context.menus[1].options.onResult({ kind = "new_game" })
      local game = assert(App.state, "New Game enters retail")
      Assert.equal(#context.games, 1, "the menu routes New Game to exactly one retail entry")
      Assert.equal(context.sweeps, 1, "menu installation authorizes background completion exactly once")
      local status = context.service:bootSourceStatus(epoch)
      Assert.equal(status, "ready", "gameplay keeps the admitted readiness without re-prompting")
      pumpBootGate(App, 3)
      Assert.equal(App.state, game, "gameplay never raises a source prompt")
      Assert.equal(App.epoch, epoch, "gameplay keeps the admitted epoch")
      Assert.equal(context.sweeps, 1, "gameplay never reauthorizes the sweep")
      App._selectVersion(VERSION)
      local second = assert(App.epoch, "restart must borrow a fresh epoch")
      Assert.isTrue(second > epoch, "restart mints a fresh epoch")
      pumpBootGate(App, 1)
      local restarted = assert(App.state, "restart waits visibly")
      Assert.equal(restarted.kind, "boot-source", "an incomplete cache without its file blocks again")
      context.service:injectReply({
        op = "boot-source-result",
        epoch = second,
        state = "source-required",
        detail = { code = "ROM_SOURCE_REQUIRED", message = "the ephemeral file is gone" },
      })
      pumpBootGate(App, 2)
      Assert.equal(#context.menus, 1, "the restart never installs a second menu")
      Assert.equal(#context.games, 1, "the restart never starts retail")
      restarted:keypressed("escape", nil, nil)
      context.firstPlayCurrent = true
      context.firstPlayStored = true
      App._selectVersion(VERSION)
      local third = assert(App.epoch, "the attested boot must borrow a fresh epoch")
      context.service:injectReply({ op = "boot-source-result", epoch = third, state = "ready" })
      -- The admitted warm wait holds its transfer until the required
      -- selected pair answers: reply to the keyed walker demand before
      -- expecting the title bootstrap.
      pumpBootGate(App, 2)
      local thirdWalkerId = assert(
        walkerRequestId(context, third),
        "the attested wait requests exactly the selected walking pair"
      )
      context.service:injectReply(
        { op = "request-result", epoch = third, requestId = thirdWalkerId, state = "ready" }
      )
      pumpBootGate(App, 3)
      local bootstrapId = assert(
        milestoneRequestId(context, third, "bootstrap"),
        "attested readiness continues into the ordinary bootstrap check"
      )
      context.service:injectReply({ op = "request-result", epoch = third, requestId = bootstrapId, state = "ready" })
      pumpBootGate(App, 2)
      Assert.equal(#context.menus, 2, "a current attestation reaches its menu without the ROM")
      Assert.equal(romOpens, 0, "the attested boot opens no ROM source")
      Assert.equal(pathOpens, 0, "the attested boot reads no ROM file")
    end)
    RomFs.open = realOpen
    RomSource.fromPath = realFromPath
    if not ok then
      error(err, 0)
    end
  end)
end

-- Recovery from a blocked boot never switches the game, deletes progress,
-- or lets a stale epoch launch: a wrong ROM keeps the original selection
-- blocked, cancel returns to the selector without gameplay, a late reply
-- for the retired epoch is ignored, and the matching source resumes into
-- the menu without a destructive import.
function T.blocked_boot_refuses_a_wrong_version_and_ignores_stale_replies()
  withBootGateApp(
    { firstPlayCurrent = false, firstPlayStored = false, readyVersions = { "heartgold", "soulsilver" } },
    function(App, context)
      local GameVersion = require("romdump.src.source.GameVersion")
      App._selectVersion(VERSION)
      local first = assert(App.epoch, "selection must borrow a controller epoch")
      pumpBootGate(App, 1)
      local waiting = assert(App.state, "selection must wait visibly")
      Assert.equal(waiting.kind, "boot-source", "the incomplete selection waits on its source gate")
      context.service:injectReply({
        op = "boot-source-result",
        epoch = first,
        state = "source-required",
        detail = { code = "ROM_SOURCE_REQUIRED", message = "synthetic heartgold missing" },
      })
      pumpBootGate(App, 2)
      local blocked = assert(App.state, "the missing source keeps the wait alive")
      Assert.equal(blocked.kind, "boot-source", "the original game stays blocked")
      local wrongInfo = GameVersion.info("soulsilver")
      local wrongBuffer = love.data.newByteData("synthetic-wrong-version-bytes")
      App.importer = {
        status = function()
          return {
            state = "complete",
            versionId = "soulsilver",
            displayName = "SoulSilver",
            sourceName = "wrong.nds",
            progress = 1,
          }
        end,
        takeVerifiedSource = function()
          return {
            byteData = function()
              return wrongBuffer
            end,
            release = function() end,
          }
        end,
      }
      App._onImported("soulsilver")
      pumpBootGate(App, 1)
      Assert.equal(App.selectedVersionId, VERSION, "a wrong ROM never switches the blocked selection")
      Assert.equal(#context.menus, 0, "a wrong ROM never installs a menu")
      Assert.equal(#context.games, 0, "a wrong ROM never starts retail")
      local stillBlocked = assert(App.state, "the original game stays waiting")
      Assert.equal(stillBlocked.kind, "boot-source", "the wrong ROM keeps the original boot blocked")
      Assert.deepEqual(context.firstPlayPublished, {}, "the wrong ROM fabricates no attestation")
      Assert.equal(wrongInfo.sha1, GameVersion.info("soulsilver").sha1, "the wrong offer keeps its own identity")
      context.prints = {}
      stillBlocked:draw()
      local shown = drawnText(context)
      Assert.isTrue(
        shown:find("silver", 1, true) ~= nil
          or shown:find("mismatch", 1, true) ~= nil
          or shown:find("wrong", 1, true) ~= nil
          or shown:find("match", 1, true) ~= nil,
        "the blocked boot surfaces the version mismatch"
      )
      stillBlocked:keypressed("escape", nil, nil)
      Assert.equal(getmetatable(App.state).__index, VersionSelectState, "cancel returns to the version selector")
      Assert.equal(#context.menus, 0, "cancel never installs a menu")
      Assert.equal(#context.games, 0, "cancel never starts retail")
      local mark = logMark(context)
      App._selectVersion(VERSION)
      local second = assert(App.epoch, "reselection must borrow a fresh epoch")
      Assert.isTrue(second > first, "reselection mints a fresh epoch")
      context.service:injectReply({ op = "boot-source-result", epoch = first, state = "ready" })
      pumpBootGate(App, 2)
      Assert.equal(
        context.service:bootSourceStatus(second),
        "pending",
        "a stale ready reply never satisfies the new gate"
      )
      Assert.equal(#context.menus, 0, "the stale reply never installs a menu")
      Assert.deepEqual(
        emittedOpsForEpochSince(context, mark, second),
        { "select", "check-boot-source", "request" },
        "reselection queues a fresh gate without a late offer"
      )
      local info = GameVersion.info(VERSION)
      local buffer = love.data.newByteData("synthetic-heartgold-bytes")
      App.importer = {
        status = function()
          return {
            state = "complete",
            versionId = VERSION,
            displayName = "HeartGold",
            sourceName = "hg.nds",
            progress = 1,
          }
        end,
        takeVerifiedSource = function()
          return {
            byteData = function()
              return buffer
            end,
            release = function() end,
          }
        end,
      }
      local repairMark = logMark(context)
      App._onImported(VERSION)
      local third = assert(App.epoch, "the matching source must borrow a fresh epoch")
      Assert.isTrue(third > second, "the matching source mints a fresh epoch")
      pumpBootGate(App, 1)
      Assert.deepEqual(
        emittedOpsForEpochSince(context, repairMark, third),
        { "select", "offer-source", "check-boot-source" },
        "the matching source offer waits behind selection and ahead of the fresh gate"
      )
      local offer = assert(latestControlPacket(context, "offer-source"), "the matching offer crosses to the controller")
      Assert.isTrue(offer.byteData == buffer, "the matching offer hands the identical buffer by reference")
      Assert.equal(offer.romSha1, info.sha1, "the matching offer carries the canonical ROM identity")
      context.service:injectReply({ op = "boot-source-result", epoch = third, state = "ready" })
      context.prepScript.ready = true
      pumpBootGate(App, 2)
      -- A cold repair holds its card until the selected pair adopts: answer
      -- the keyed walker demand before expecting the title bootstrap.
      local walkerId = assert(
        walkerRequestId(context, third),
        "the matching source requests exactly the selected walking pair"
      )
      context.service:injectReply({ op = "request-result", epoch = third, requestId = walkerId, state = "ready" })
      pumpBootGate(App, 3)
      local bootstrapId = assert(
        milestoneRequestId(context, third, "bootstrap"),
        "the matching source reaches the title bootstrap request"
      )
      context.service:injectReply({ op = "request-result", epoch = third, requestId = bootstrapId, state = "ready" })
      pumpBootGate(App, 2)
      Assert.equal(#context.menus, 1, "the matching source resumes preparation into the menu")
      Assert.equal(#context.games, 0, "recovery installs the menu without launching retail by itself")
    end
  )
end

function T.terminal_walker_record_keeps_its_identity_across_epochs()
  local CacheService = require("app.src.CacheService")
  local host = newBootGateChannelHost()
  local service = CacheService.new({ thread = host })
  local first = assert(service:select({ versionId = VERSION }), "selection mints an epoch")
  local firstId = assert(
    service:request(first, { requestKind = "startup-walker", urgency = "required" }),
    "the first epoch registers its walker demand"
  )
  service:update()
  service:injectReply({
    op = "request-result",
    epoch = first,
    requestId = firstId,
    state = "failed",
    errorMessage = "synthetic walker failure",
  })
  service:update()
  local ready, failure = service:observe(first, { requestKind = "startup-walker" })
  Assert.equal(ready, false, "the terminal record never reports ready")
  Assert.notNil(failure, "the terminal record keeps its failure")
  local sameId = service:request(first, { requestKind = "startup-walker", urgency = "required" })
  Assert.equal(sameId, firstId, "the same epoch reuses the terminal request identity")
  service:injectReply({ op = "request-result", epoch = first, requestId = firstId, state = "ready" })
  service:update()
  local healed, healedFailure = service:observe(first, { requestKind = "startup-walker" })
  Assert.equal(healed, false, "a late ready packet never heals the terminal record")
  Assert.notNil(healedFailure, "the terminal failure survives the ignored packet")
  local second = assert(service:select({ versionId = VERSION }), "reselection mints a fresh epoch")
  Assert.isTrue(second ~= first, "the fresh epoch differs from the failed one")
  local secondId = assert(
    service:request(second, { requestKind = "startup-walker", urgency = "required" }),
    "the fresh epoch registers its own walker demand"
  )
  Assert.isTrue(secondId ~= firstId, "the fresh epoch owns a distinct request identity")
  service:injectReply({ op = "request-result", epoch = second, requestId = secondId, state = "ready" })
  service:update()
  local freshReady, freshFailure = service:observe(second, { requestKind = "startup-walker" })
  Assert.equal(freshReady, true, "the fresh epoch answers ready on its independent record")
  Assert.isNil(freshFailure, "the fresh epoch carries no failure")
  service:shutdown()
end

return { tests = T }
