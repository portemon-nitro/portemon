-- One selected walking pair travels the epoch cache host as a keyed demand:
-- the same pair deduplicates to one worker request, another pair stays its
-- own pending request, and only demanded pairs ever leave the game thread.

local Assert = require("tests.support.Assert")

local T = {}

local function newChannelHost()
  local function newChannel()
    local queue = {}
    local channel = {}
    function channel:push(value)
      queue[#queue + 1] = value
      return true
    end
    function channel:pop()
      if #queue == 0 then
        return nil
      end
      return table.remove(queue, 1)
    end
    function channel:demand(_)
      return table.remove(queue, 1)
    end
    function channel:count()
      return #queue
    end
    return channel
  end
  local threads = {}
  local function newThread(source)
    local thread = { source = source, starts = 0, waits = 0, alive = true }
    function thread:start(...)
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
  return { newChannel = newChannel, newThread = newThread, threads = threads }
end

local function selectGame()
  local CacheService = require("app.src.CacheService")
  local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
  local service = assert(CacheService.new({ thread = newChannelHost() }))
  local provisioner = DerivedAssetProvisioner.new({ versionId = "heartgold", service = service })
  return service, provisioner
end

local function drainCommands(service)
  local commands = {}
  local command = service._command:pop()
  while command ~= nil do
    commands[#commands + 1] = command
    command = service._command:pop()
  end
  return commands
end

function T.startup_walker_global_demand_dedupes_to_one_worker_request()
  local service, provisioner = selectGame()
  local epoch = assert(provisioner.epoch, "the selection borrows an epoch")
  local gameHost = provisioner:gameHost()
  Assert.isTrue(
    type(gameHost.requestStartupWalker) == "function",
    "the selected game host demands the shared walking visuals"
  )
  local pending, pendingErr = gameHost.requestStartupWalker("required")
  Assert.isNil(pending, "an unbuilt catalog observes no readiness")
  Assert.isNil(pendingErr, "an unbuilt catalog observes no failure")
  local first = service:request(epoch, { requestKind = "startup-walker", urgency = "required" })
  Assert.notNil(first, "the shared selector routes to the worker")
  local second = service:request(epoch, { requestKind = "startup-walker", urgency = "near" })
  Assert.equal(second, first, "the shared demand deduplicates to one worker request")
  service:update()
  local sharedDemands = 0
  for _, command in ipairs(drainCommands(service)) do
    if command.op == "request" and command.requestKind == "startup-walker" then
      sharedDemands = sharedDemands + 1
      Assert.isNil(command.pairIndex, "the worker demand carries no pair identity")
    end
  end
  Assert.equal(sharedDemands, 1, "only the one shared demand leaves the game thread")
  service:injectReply({ op = "request-result", epoch = epoch, requestId = first, state = "ready" })
  service:update()
  local ready, failure = gameHost.requestStartupWalker("required")
  Assert.isTrue(ready, "the pushed ready event lands in the shared observation")
  Assert.isNil(failure, "a ready catalog carries no failure")
  provisioner:dispose()
  service:shutdown()
end

function T.startup_walker_requests_reject_any_pair_selector()
  local service, provisioner = selectGame()
  for _, selector in ipairs({
    { requestKind = "startup-walker", pairIndex = 5, urgency = "required" },
    { requestKind = "startup-walker", pairIndex = 0, urgency = "required" },
    { requestKind = "startup-walker", pairIndex = 33, urgency = "required" },
  }) do
    local ok, _ = pcall(service.request, service, assert(provisioner.epoch), selector)
    Assert.isFalse(ok, "a pair selector never leaves the game thread")
  end
  local gameHost = provisioner:gameHost()
  local ok, _ = pcall(service.request, service, assert(provisioner.epoch), {
    requestKind = "startup-walker",
    urgency = "required",
  })
  Assert.isTrue(ok, "the selector-free demand routes to the worker")
  Assert.isTrue(type(gameHost.requestStartupWalker) == "function", "the game host keeps its shared demand")
  service:update()
  for _, command in ipairs(drainCommands(service)) do
    if command.requestKind == "startup-walker" then
      Assert.isNil(command.pairIndex, "a queued shared demand carries no pair identity")
    end
  end
  provisioner:dispose()
  service:shutdown()
end

-- With no published manifest at all the epoch keeps one random fallback
-- pair and demands exactly that pair: the scan never precaches all 32.
function T.no_published_manifest_falls_back_to_one_random_pair()
  local App = require("app.src.App")
  local StartupAssetCache = require("libs.assets.src.StartupAssetCache")
  local CacheFs = require("libs.storage.src.CacheFs")
  local LoadingModule = require("libs.hgss.src.ui.HgssLoadingPresentation")
  local FirstPlayCompletion = require("romdump.src.FirstPlayCompletion")
  local HgssGame = require("game.hgss.src.HgssGame")
  local StartupTitleState = require("app.src.launcher.StartupTitleState")
  local saved = {
    state = App.state,
    importer = App.importer,
    provisioner = App.provisioner,
    service = App.service,
    epoch = App.epoch,
    pairIndex = App.pairIndex,
    pendingQuiesce = App.pendingQuiesce,
    selectedVersionId = App.selectedVersionId,
    rebindVersionId = App._rebindVersionId,
    bootBlockedVersionId = App._bootBlockedVersionId,
    startupWarmup = App._startupWarmup,
    opts = App.opts,
    loadWalker = StartupAssetCache.loadWalker,
    forVersion = CacheFs.forVersion,
    loadingNew = LoadingModule.new,
    isCurrent = FirstPlayCompletion.isCurrent,
    firstPlayFactory = HgssGame.newFirstPlayCachePreparation,
    random = love.math.random,
  }
  local demands = {}
  local epochs = 0
  local service = {}
  function service:select(_)
    epochs = epochs + 1
    return epochs
  end
  function service:request(_, selector)
    if type(selector) == "table" and selector.requestKind == "startup-walker" then
      demands[#demands + 1] = { pairIndex = selector.pairIndex, urgency = selector.urgency }
    end
  end
  function service:observe(_, selector)
    if type(selector) == "table" and selector.requestKind == "startup-walker" then
      return true, nil
    end
    return nil, nil
  end
  function service:requestBootSource(_)
  end
  function service:bootSourceStatus(_)
    return "ready", nil
  end
  function service:update()
  end
  function service:retire(_)
  end
  function service:generationId(_)
    return "synthetic-test-generation"
  end
  local loading = {
    adopted = false,
    adoptions = 0,
    disposals = 0,
  }
  function loading:update()
  end
  function loading:resize()
  end
  function loading:draw()
  end
  function loading:dispose()
    self.disposals = self.disposals + 1
  end
  function loading:adoptGeneratedAssets()
    self.adoptions = self.adoptions + 1
    self.adopted = true
    return true
  end
  local function restore()
    if App.state ~= nil then
      App.setState(nil)
    end
    if App.provisioner ~= nil then
      App._retireSelection()
    end
    App.state = saved.state
    App.importer = saved.importer
    App.provisioner = saved.provisioner
    App.service = saved.service
    App.epoch = saved.epoch
    App.pairIndex = saved.pairIndex
    App.pendingQuiesce = saved.pendingQuiesce
    App.selectedVersionId = saved.selectedVersionId
    App._rebindVersionId = saved.rebindVersionId
    App._bootBlockedVersionId = saved.bootBlockedVersionId
    App._startupWarmup = saved.startupWarmup
    App.opts = saved.opts
    StartupAssetCache.loadWalker = saved.loadWalker
    CacheFs.forVersion = saved.forVersion
    LoadingModule.new = saved.loadingNew
    FirstPlayCompletion.isCurrent = saved.isCurrent
    HgssGame.newFirstPlayCachePreparation = saved.firstPlayFactory
    love.math.random = saved.random
  end
  local ok, err = xpcall(function()
    StartupAssetCache.loadWalker = function()
      return nil, "synthetic missing pair"
    end
    CacheFs.forVersion = function(_)
      return {}
    end
    LoadingModule.new = function()
      return loading
    end
    FirstPlayCompletion.isCurrent = function()
      return false
    end
    HgssGame.newFirstPlayCachePreparation = function(_)
      local preparation = {}
      function preparation:poll()
        return nil, nil
      end
      function preparation:dispose()
      end
      return preparation
    end
    love.math.random = function()
      return 23
    end
    App.state = nil
    App.importer = nil
    App.provisioner = nil
    App.service = service
    App.epoch = 0
    App.pairIndex = nil
    App.pendingQuiesce = nil
    App.selectedVersionId = nil
    App._rebindVersionId = nil
    App._bootBlockedVersionId = nil
    App._startupWarmup = nil
    App.opts = { dev = false }
    App._selectVersion("soulsilver")
    for _ = 1, 5 do
      App.update(0.016)
    end
    Assert.equal(App.pairIndex, 23, "the epoch keeps its one random fallback pair")
    Assert.isTrue(#demands >= 1, "the shared visuals are demanded from the worker")
    for _, demand in ipairs(demands) do
      Assert.isNil(demand.pairIndex, "the shared demand carries no pair identity")
      Assert.equal(demand.urgency, "required", "the shared demand stays required")
    end
    Assert.equal(
      getmetatable(App.state).__index,
      StartupTitleState,
      "the prepared fallback pair completes the handoff"
    )
  end, debug.traceback)
  restore()
  if not ok then
    error(err, 0)
  end
end

-- Each newly selected epoch draws one fresh pair independent of the
-- published catalog: the same warm catalog never biases the draw, the
-- worker demand carries no pair identity, and the draw happens once per
-- selection.
function T.new_epochs_draw_independent_pairs_without_cache_scan()
  local App = require("app.src.App")
  local StartupAssetCache = require("libs.assets.src.StartupAssetCache")
  local CacheFs = require("libs.storage.src.CacheFs")
  local LoadingModule = require("libs.hgss.src.ui.HgssLoadingPresentation")
  local FirstPlayCompletion = require("romdump.src.FirstPlayCompletion")
  local HgssGame = require("game.hgss.src.HgssGame")
  local saved = {
    state = App.state,
    importer = App.importer,
    provisioner = App.provisioner,
    service = App.service,
    epoch = App.epoch,
    pairIndex = App.pairIndex,
    pendingQuiesce = App.pendingQuiesce,
    selectedVersionId = App.selectedVersionId,
    rebindVersionId = App._rebindVersionId,
    bootBlockedVersionId = App._bootBlockedVersionId,
    startupWarmup = App._startupWarmup,
    opts = App.opts,
    loadWalker = StartupAssetCache.loadWalker,
    forVersion = CacheFs.forVersion,
    loadingNew = LoadingModule.new,
    isCurrent = FirstPlayCompletion.isCurrent,
    firstPlayFactory = HgssGame.newFirstPlayCachePreparation,
    random = love.math.random,
  }
  local demands = {}
  local epochs = 0
  local randomCalls = 0
  local randomValues = { 7, 25 }
  local scanCalls = 0
  local service = {}
  function service:select(_)
    epochs = epochs + 1
    return epochs
  end
  function service:request(_, selector)
    if type(selector) == "table" and selector.requestKind == "startup-walker" then
      demands[#demands + 1] = { pairIndex = selector.pairIndex, urgency = selector.urgency }
    end
  end
  function service:observe(_, selector)
    if type(selector) == "table" and selector.requestKind == "startup-walker" then
      return true, nil
    end
    return nil, nil
  end
  function service:requestBootSource(_)
  end
  function service:bootSourceStatus(_)
    return "ready", nil
  end
  function service:update()
  end
  function service:retire(_)
  end
  function service:generationId(_)
    return "synthetic-test-generation"
  end
  local loading = {}
  function loading:update()
  end
  function loading:resize()
  end
  function loading:draw()
  end
  function loading:dispose()
  end
  function loading:adoptGeneratedAssets()
    return true
  end
  local function restore()
    if App.state ~= nil then
      App.setState(nil)
    end
    if App.provisioner ~= nil then
      App._retireSelection()
    end
    App.state = saved.state
    App.importer = saved.importer
    App.provisioner = saved.provisioner
    App.service = saved.service
    App.epoch = saved.epoch
    App.pairIndex = saved.pairIndex
    App.pendingQuiesce = saved.pendingQuiesce
    App.selectedVersionId = saved.selectedVersionId
    App._rebindVersionId = saved.rebindVersionId
    App._bootBlockedVersionId = saved.bootBlockedVersionId
    App._startupWarmup = saved.startupWarmup
    App.opts = saved.opts
    StartupAssetCache.loadWalker = saved.loadWalker
    CacheFs.forVersion = saved.forVersion
    LoadingModule.new = saved.loadingNew
    FirstPlayCompletion.isCurrent = saved.isCurrent
    HgssGame.newFirstPlayCachePreparation = saved.firstPlayFactory
    love.math.random = saved.random
  end
  local ok, err = xpcall(function()
    StartupAssetCache.loadWalker = function(_, _)
      scanCalls = scanCalls + 1
      return nil, "synthetic catalog is never a selection signal"
    end
    CacheFs.forVersion = function(_)
      return {}
    end
    LoadingModule.new = function()
      return loading
    end
    FirstPlayCompletion.isCurrent = function()
      return false
    end
    HgssGame.newFirstPlayCachePreparation = function(_)
      local preparation = {}
      function preparation:poll()
        return nil, nil
      end
      function preparation:dispose()
      end
      return preparation
    end
    love.math.random = function(_, _)
      randomCalls = randomCalls + 1
      return assert(randomValues[randomCalls], "one random draw per epoch")
    end
    App.state = nil
    App.importer = nil
    App.provisioner = nil
    App.service = service
    App.epoch = 0
    App.pairIndex = nil
    App.pendingQuiesce = nil
    App.selectedVersionId = nil
    App._rebindVersionId = nil
    App._bootBlockedVersionId = nil
    App._startupWarmup = nil
    App.opts = { dev = false }
    App._selectVersion("heartgold")
    Assert.equal(App.pairIndex, 7, "the first epoch keeps its drawn pair")
    for _ = 1, 5 do
      App.update(0.016)
    end
    App._selectVersion("heartgold")
    Assert.equal(App.pairIndex, 25, "the next epoch draws again instead of reusing the catalog")
    for _ = 1, 5 do
      App.update(0.016)
    end
    Assert.equal(randomCalls, 2, "each epoch draws exactly once")
    Assert.equal(scanCalls, 0, "selection never scans the published catalog")
    Assert.isTrue(#demands >= 2, "both epochs demand the shared visuals")
    for _, demand in ipairs(demands) do
      Assert.isNil(demand.pairIndex, "the shared demand carries no pair identity")
      Assert.equal(demand.urgency, "required", "the shared demand stays required")
    end
  end, debug.traceback)
  restore()
  if not ok then
    error(err, 0)
  end
end

return { tests = T }
