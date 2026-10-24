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

function T.startup_walker_requests_dedupe_by_pair_and_leave_other_pairs_pending()
  local service, provisioner = selectGame()
  local epoch = assert(provisioner.epoch, "the selection borrows an epoch")
  local gameHost = provisioner:gameHost()
  Assert.isTrue(
    type(gameHost.requestStartupWalker) == "function",
    "the selected game host demands its walking pair"
  )
  local pending, pendingErr = gameHost.requestStartupWalker(5, "required")
  Assert.isNil(pending, "an unbuilt pair observes no readiness")
  Assert.isNil(pendingErr, "an unbuilt pair observes no failure")
  local first = service:request(epoch, { requestKind = "startup-walker", pairIndex = 5, urgency = "required" })
  Assert.notNil(first, "the pair selector routes to the worker")
  local second = service:request(epoch, { requestKind = "startup-walker", pairIndex = 5, urgency = "near" })
  Assert.equal(second, first, "the same pair deduplicates to one worker request")
  local other = service:request(epoch, { requestKind = "startup-walker", pairIndex = 6, urgency = "required" })
  Assert.isTrue(other ~= first, "another pair stays its own worker request")
  service:update()
  local pairKeys = {}
  for _, command in ipairs(drainCommands(service)) do
    if command.op == "request" and command.requestKind == "startup-walker" then
      pairKeys[#pairKeys + 1] = command.pairIndex
    end
  end
  Assert.equal(#pairKeys, 2, "only the two demanded pairs leave the game thread")
  local seen = {}
  for _, pairIndex in ipairs(pairKeys) do
    seen[pairIndex] = true
  end
  Assert.isTrue(seen[5] == true and seen[6] == true, "the worker sees exactly the demanded pairs")
  local stillPending, _ = service:observe(epoch, { requestKind = "startup-walker", pairIndex = 6 })
  Assert.isNil(stillPending, "the second pair stays pending before its answer lands")
  service:injectReply({ op = "request-result", epoch = epoch, requestId = first, state = "ready" })
  service:update()
  local ready, failure = gameHost.requestStartupWalker(5, "required")
  Assert.isTrue(ready, "the pushed ready event lands in the matching pair observation")
  Assert.isNil(failure, "a ready pair carries no failure")
  local otherPending, _ = gameHost.requestStartupWalker(6, "required")
  Assert.isNil(otherPending, "the other pair stays pending after the first pair completes")
  provisioner:dispose()
  service:shutdown()
end

function T.startup_walker_requests_reject_indexes_outside_the_thirty_two_choices()
  local service, provisioner = selectGame()
  local gameHost = provisioner:gameHost()
  Assert.isTrue(
    type(gameHost.requestStartupWalker) == "function",
    "the selected game host demands its walking pair"
  )
  for _, badIndex in ipairs({ 0, 33, 2.5, "5" }) do
    local ok, _ = pcall(function()
      gameHost.requestStartupWalker(badIndex, "required")
    end)
    Assert.isFalse(ok, "pair index " .. tostring(badIndex) .. " never leaves the game thread")
  end
  service:update()
  for _, command in ipairs(drainCommands(service)) do
    Assert.isFalse(
      command.requestKind == "startup-walker",
      "a rejected pair index queues no worker request"
    )
  end
  provisioner:dispose()
  service:shutdown()
end

-- A warm selection reuses the one published ready pair instead of rolling a
-- fresh random index: with only pair 7 current and the random source forced
-- toward unavailable pair 23, the epoch must settle on 7 and never demand
-- 23 from the worker.
function T.warm_selection_reuses_the_published_ready_pair()
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
      if selector.pairIndex == 7 then
        return true, nil
      end
      return nil, nil
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
    StartupAssetCache.loadWalker = function(_, pairIndex)
      if pairIndex == 7 then
        return { pairIndex = 7 }
      end
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
    Assert.equal(App.pairIndex, 7, "the warm epoch settles on the published ready pair, not the forced random index")
    Assert.isTrue(#demands >= 1, "the warm epoch demands its selected pair from the worker")
    for _, demand in ipairs(demands) do
      Assert.equal(demand.pairIndex, 7, "no worker demand names the unavailable pair")
    end
    Assert.equal(
      getmetatable(App.state).__index,
      StartupTitleState,
      "the adopted ready pair completes the warm handoff"
    )
  end, debug.traceback)
  restore()
  if not ok then
    error(err, 0)
  end
end

-- Several published pairs resolve deterministically to the smallest index:
-- with pairs 3 and 7 current and the random source forced toward 23, the
-- epoch must settle on 3 and demand only 3 from the worker.
function T.multiple_published_pairs_resolve_to_the_smallest_index()
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
      demands[#demands + 1] = selector.pairIndex
    end
  end
  function service:observe(_, selector)
    if type(selector) == "table" and selector.requestKind == "startup-walker" then
      if selector.pairIndex == 3 then
        return true, nil
      end
      return nil, nil
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
    StartupAssetCache.loadWalker = function(_, pairIndex)
      if pairIndex == 3 or pairIndex == 7 then
        return { pairIndex = pairIndex }
      end
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
    Assert.equal(App.pairIndex, 3, "the epoch settles on the smallest published pair")
    Assert.isTrue(#demands >= 1, "the epoch demands its selected pair from the worker")
    for _, pairIndex in ipairs(demands) do
      Assert.equal(pairIndex, 3, "no worker demand names another pair")
    end
    Assert.equal(
      getmetatable(App.state).__index,
      StartupTitleState,
      "the adopted ready pair completes the handoff"
    )
  end, debug.traceback)
  restore()
  if not ok then
    error(err, 0)
  end
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
      demands[#demands + 1] = selector.pairIndex
    end
  end
  function service:observe(_, selector)
    if type(selector) == "table" and selector.requestKind == "startup-walker" then
      if selector.pairIndex == 23 then
        return true, nil
      end
      return nil, nil
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
    Assert.isTrue(#demands >= 1, "the fallback pair is demanded from the worker")
    local distinct = {}
    for _, pairIndex in ipairs(demands) do
      Assert.equal(pairIndex, 23, "no worker demand names another pair")
      distinct[pairIndex] = true
    end
    local distinctCount = 0
    for _ in pairs(distinct) do
      distinctCount = distinctCount + 1
    end
    Assert.equal(distinctCount, 1, "the fallback never precaches the other pairs")
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

return { tests = T }
