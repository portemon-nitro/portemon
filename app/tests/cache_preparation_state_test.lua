-- Retained source-control waits for the app shell. CachePreparationState
-- covers exactly the two pre-title barriers: the boot-source gate, which
-- holds selection until the verified source is admitted, and the
-- quiescence wait, which holds reselection until source readers drain.
-- Both transfer exactly once, latch failure visibly, and never fire after
-- cancellation or epoch retirement.

local Assert = require("tests.support.Assert")
local CachePreparationState = require("app.src.launcher.CachePreparationState")

local T = {}

-- A scripted process cache service answering the boot-source gate.
---@param script table { ready: boolean?, failure: unknown?, detail: unknown? }
local function bootService(script)
  local service = {}
  function service:bootSourceStatus(epoch)
    script.calls = (script.calls or 0) + 1
    script.epochs = script.epochs or {}
    script.epochs[#script.epochs + 1] = epoch
    if script.failure ~= nil then
      return "failed", script.failure
    end
    if script.ready then
      return "ready"
    end
    return "source-required", script.detail
  end
  -- Selected-pair demand seam: the wait requests its pair early, even
  -- while the source gate is still blocked, and only observes readiness
  -- once the gate admits. Fixtures answer through script.walkerReady.
  function service:request(_, selector)
    if type(selector) == "table" and selector.requestKind == "startup-walker" then
      script.pairDemands = (script.pairDemands or 0) + 1
      script.pairIndexes = script.pairIndexes or {}
      script.pairIndexes[#script.pairIndexes + 1] = selector.pairIndex
      return "walker-request"
    end
    return nil
  end
  function service:observe(_, selector)
    if type(selector) == "table" and selector.requestKind == "startup-walker" then
      return script.walkerReady == true, nil
    end
    return false, nil
  end
  return service
end

-- A scripted process cache service answering one quiescence barrier token.
---@param script table { status: string? }
local function quiescenceService(script)
  local service = {}
  function service:barrierStatus(epoch, barrier)
    script.calls = (script.calls or 0) + 1
    script.seenEpoch = epoch
    script.seenBarrier = barrier
    return script.status or "pending"
  end
  return service
end

---@param script table counter record for the transfer callbacks
---@param options table constructor options
local function onTransfer(script, options)
  script.fired = 0
  script.cancelled = 0
  options.isCurrent = options.isCurrent or function()
    return true
  end
  options.onReady = function()
    script.fired = script.fired + 1
  end
  options.onCancel = function()
    script.cancelled = script.cancelled + 1
  end
  return options
end

local LOADING_MODULE = "libs.hgss.src.ui.HgssLoadingPresentation"

local function fakeAdopter()
  local presentation = { adoptions = 0, disposals = 0, adoptResult = true }
  function presentation:update() end
  function presentation:resize() end
  function presentation:draw() end
  function presentation:dispose()
    self.disposals = self.disposals + 1
  end
  function presentation:adoptGeneratedAssets()
    self.adoptions = self.adoptions + 1
    if self.adoptResult then
      return true
    end
    return false, "synthetic adoption failure"
  end
  return presentation
end

---@param script table
---@param overrides table?
---@return CachePreparationState
local function bootWait(script, overrides)
  local options = onTransfer(script, {
    kind = "boot-source",
    epoch = 7,
    service = bootService(script),
    versionId = "heartgold",
  })
  for key, value in pairs(overrides or {}) do
    options[key] = value
  end
  return CachePreparationState.new(options)
end

---@param script table
---@param overrides table?
---@return CachePreparationState
local function quiescenceWait(script, overrides)
  local options = onTransfer(script, {
    kind = "quiescence",
    epoch = 7,
    service = quiescenceService(script),
    barrier = 3,
  })
  for key, value in pairs(overrides or {}) do
    options[key] = value
  end
  return CachePreparationState.new(options)
end

function T.boot_source_wait_transfers_exactly_once_on_readiness()
  local script = { ready = true }
  local state = bootWait(script)
  state:update(0.016)
  Assert.equal(script.fired, 1, "boot readiness transfers")
  state:update(0.016)
  state:update(0.016)
  Assert.equal(script.fired, 1, "the transfer fires exactly once")
  Assert.equal(script.cancelled, 0, "readiness never cancels")
end

function T.boot_source_wait_stays_blocked_while_the_source_is_required()
  local Loading = require("libs.hgss.src.ui.HgssLoadingPresentation")
  local savedNew = Loading.new
  local loading = fakeAdopter()
  Loading.new = function()
    return loading
  end
  local ok, err = xpcall(function()
    local script = { detail = { code = "ROM_SOURCE_REQUIRED", message = "the original file is missing" } }
    local state =
      bootWait(script, { mismatch = "Dropped SoulSilver does not match the expected HeartGold version.", pairIndex = 5 })
    state:update(0.016)
    state:update(0.016)
    Assert.equal(script.fired or 0, 0, "a missing source never transfers")
    Assert.isTrue((script.pairDemands or 0) >= 1, "the blocked wait still demands the selected pair early")
    Assert.isNil(state.error, "a missing source is a block, not a failure")
    Assert.equal(state.sourceDetail, script.detail, "the typed source reason stays visible on the wait")
    Assert.notNil(state.mismatch, "the wrong-version diagnostic stays on the blocked wait")
    script.ready = true
    script.walkerReady = true
    state:update(0.016)
    Assert.equal(script.fired, 1, "the admitted source transfers on the same wait")
  end, debug.traceback)
  Loading.new = savedNew
  if not ok then
    error(err, 0)
  end
end

function T.boot_source_failure_latches_without_transfer()
  local script = { failure = "cache boot failed in the fixture" }
  local state = bootWait(script)
  state:update(0.016)
  Assert.equal(script.fired or 0, 0, "a failed boot never transfers")
  Assert.notNil(state.error, "the boot failure surfaces on the wait")
  script.ready = true
  script.failure = nil
  state:update(0.016)
  Assert.equal(script.fired or 0, 0, "a latched failure never recovers into a transfer")
end

function T.boot_source_cancel_never_publishes_a_stale_transfer()
  local Loading = require("libs.hgss.src.ui.HgssLoadingPresentation")
  local savedNew = Loading.new
  local loading = fakeAdopter()
  Loading.new = function()
    return loading
  end
  local ok, err = xpcall(function()
    local script = {}
    local state = bootWait(script, { pairIndex = 5 })
    state:update(0.016)
    Assert.equal(script.fired or 0, 0, "the pending gate transfers nothing yet")
    Assert.isTrue((script.pairDemands or 0) >= 1, "the pending wait still demands the selected pair early")
    state:keypressed("escape")
    Assert.equal(script.cancelled, 1, "escape returns to the owning selection exactly once")
    state:keypressed("escape")
    Assert.equal(script.cancelled, 1, "a second escape never cancels twice")
    script.ready = true
    script.walkerReady = true
    state:update(0.016)
    Assert.equal(script.fired or 0, 0, "a cancelled wait never transfers even when the gate answers")
    state:dispose()
    state:update(0.016)
    Assert.equal(script.fired or 0, 0, "a disposed wait stays silent")
    Assert.equal(script.cancelled, 1, "disposal never re-cancels")
  end, debug.traceback)
  Loading.new = savedNew
  if not ok then
    error(err, 0)
  end
end

function T.stale_wait_never_polls_or_transfers()
  local script = { ready = true }
  local state = bootWait(script, {
    isCurrent = function()
      return false
    end,
  })
  state:update(0.016)
  Assert.equal(script.fired or 0, 0, "a retired epoch never transfers")
  Assert.equal(script.calls or 0, 0, "a retired epoch never polls the gate")
  state:update(0.016)
  Assert.equal(script.fired or 0, 0, "a retired epoch stays silent")
end

function T.quiescence_wait_holds_until_the_exact_barrier_acknowledges()
  local script = {}
  local state = quiescenceWait(script)
  state:update(0.016)
  state:update(0.016)
  Assert.equal(script.fired or 0, 0, "an unacknowledged barrier never transfers")
  Assert.equal(script.seenEpoch, 7, "the wait polls its exact selecting epoch")
  Assert.equal(script.seenBarrier, 3, "the wait polls its exact barrier token")
  script.status = "ready"
  state:update(0.016)
  Assert.equal(script.fired, 1, "the acknowledged barrier transfers")
  state:update(0.016)
  Assert.equal(script.fired, 1, "the transfer fires exactly once")
end

function T.quiescence_failure_latches_without_transfer()
  local script = { status = "failed" }
  local state = quiescenceWait(script)
  state:update(0.016)
  Assert.equal(script.fired or 0, 0, "a failed source closure never transfers")
  Assert.notNil(state.error, "the closure failure surfaces on the wait")
  script.status = "ready"
  state:update(0.016)
  Assert.equal(script.fired or 0, 0, "a latched closure failure never recovers into a transfer")
end

function T.quiescence_cancel_returns_without_transfer()
  local script = {}
  local state = quiescenceWait(script)
  state:update(0.016)
  Assert.equal(script.fired or 0, 0, "the draining wait transfers nothing yet")
  state:keypressed("escape")
  Assert.equal(script.cancelled, 1, "escape returns to the owning selection exactly once")
  script.status = "ready"
  state:update(0.016)
  Assert.equal(script.fired or 0, 0, "a cancelled wait never transfers even when the barrier answers")
  state:dispose()
  state:update(0.016)
  Assert.equal(script.fired or 0, 0, "a disposed wait stays silent")
end

function T.stale_quiescence_wait_never_polls_or_transfers()
  local script = { status = "ready" }
  local state = quiescenceWait(script, {
    isCurrent = function()
      return false
    end,
  })
  state:update(0.016)
  Assert.equal(script.fired or 0, 0, "a retired epoch never transfers")
  Assert.equal(script.calls or 0, 0, "a retired epoch never polls the barrier")
end

-- The launcher keeps exactly the two source-control waits above: any other
-- preparation kind is rejected at construction.
function T.retired_wait_kinds_are_rejected_at_construction()
  local function preparationStub()
    local preparation = {}
    function preparation:poll()
      return nil, nil
    end
    function preparation:dispose() end
    return preparation
  end
  local provisionerStub = {
    status = function()
      return {}
    end,
  }
  Assert.throws(function()
    CachePreparationState.new({
      kind = "bootstrap",
      epoch = 7,
      provisioner = provisionerStub,
      isCurrent = function()
        return true
      end,
      onReady = function() end,
      onCancel = function() end,
    })
  end, "bootstrap preparation is not a launcher wait")
  Assert.throws(function()
    CachePreparationState.new({
      kind = "first-play",
      epoch = 7,
      provisioner = provisionerStub,
      preparation = preparationStub(),
      isCurrent = function()
        return true
      end,
      onReady = function() end,
      onCancel = function() end,
    })
  end, "first-play preparation is not a launcher wait")
end

local function newChannelHost()
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
    channels[#channels + 1] = channel
    return channel
  end
  local function newThread(_)
    local thread = { starts = 0 }
    function thread:start()
      self.starts = self.starts + 1
      return true
    end
    function thread:wait()
      return true
    end
    function thread:isRunning()
      return true
    end
    function thread:getError()
      return nil
    end
    return thread
  end
  return { newChannel = newChannel, newThread = newThread, channels = channels }
end

local function walkerCommandId(host, epoch)
  local found = nil
  for _, packet in ipairs(host.channels[1].log) do
    if type(packet) == "table" and packet.op == "request" and packet.epoch == epoch then
      if packet.requestKind == "startup-walker" then
        found = packet.requestId
      end
    end
  end
  return found
end

local function captureWarmCopy(draw)
  local lg = love.graphics
  local savedDimensions, savedWidth = lg.getDimensions, lg.getWidth
  local savedColor, savedRect = lg.setColor, lg.rectangle
  local savedPrint, savedPrintf = lg.print, lg.printf
  local copy = {}
  lg.getDimensions = function()
    return 800, 600
  end
  lg.getWidth = function()
    return 800
  end
  lg.setColor = function() end
  lg.rectangle = function() end
  lg.print = function(value)
    copy[#copy + 1] = tostring(value)
  end
  lg.printf = function(value)
    copy[#copy + 1] = tostring(value)
  end
  local ok, err = xpcall(draw, debug.traceback)
  lg.getDimensions, lg.getWidth = savedDimensions, savedWidth
  lg.setColor, lg.rectangle = savedColor, savedRect
  lg.print, lg.printf = savedPrint, savedPrintf
  if not ok then
    error(err, 0)
  end
  return table.concat(copy, "\n")
end

function T.terminal_worker_failure_is_escape_only_until_a_fresh_selection()
  local CacheService = require("app.src.CacheService")
  local Loading = require(LOADING_MODULE)
  local savedNew = Loading.new
  local loading = fakeAdopter()
  Loading.new = function()
    return loading
  end
  local ok, err = xpcall(function()
    local host = newChannelHost()
    local service = CacheService.new({ thread = host })
    local epoch = assert(service:select({ versionId = "heartgold" }))
    assert(service:requestBootSource(epoch))
    service:injectReply({ op = "boot-source-result", epoch = epoch, state = "ready" })
    service:update()
    local script = { fired = 0, cancelled = 0 }
    local state = CachePreparationState.new({
      kind = "boot-source",
      epoch = epoch,
      service = service,
      versionId = "heartgold",
      pairIndex = 5,
      isCurrent = function()
        return true
      end,
      onReady = function()
        script.fired = script.fired + 1
      end,
      onCancel = function()
        script.cancelled = script.cancelled + 1
      end,
    })
    state:update(0.016)
    service:update()
    local walkerId = assert(walkerCommandId(host, epoch), "the wait demands the selected pair")
    service:injectReply({
      op = "request-result",
      epoch = epoch,
      requestId = walkerId,
      state = "failed",
      errorMessage = "synthetic walker failure",
    })
    service:update()
    state:update(0.016)
    Assert.equal(script.fired, 0, "a terminal worker failure never transfers")
    Assert.notNil(state.artFailure, "the worker failure stays visible")
    local copy = captureWarmCopy(function()
      state:draw()
    end)
    Assert.isTrue(copy:lower():find("escape", 1, true) ~= nil, "the terminal wait names escape")
    Assert.isTrue(copy:find("Press R", 1, true) == nil, "the terminal wait never promises a retry")
    local commandsBefore = #host.channels[1].log
    state:keypressed("r")
    state:update(0.016)
    state:update(0.016)
    service:update()
    Assert.equal(script.fired, 0, "R never retries a terminal worker request")
    Assert.notNil(state.artFailure, "R leaves the terminal failure latched")
    Assert.equal(#host.channels[1].log, commandsBefore, "R issues no identical selector again")
    Assert.equal(loading.adoptions, 0, "a worker failure never reaches local adoption")
    service:injectReply({ op = "request-result", epoch = epoch, requestId = walkerId, state = "ready" })
    service:update()
    state:update(0.016)
    Assert.equal(script.fired, 0, "a late ready packet never heals the terminal record")
    state:keypressed("escape")
    Assert.equal(script.cancelled, 1, "escape releases the terminal wait")
    local second = assert(service:select({ versionId = "heartgold" }))
    Assert.isTrue(second ~= epoch, "the fresh epoch differs from the failed one")
    assert(service:requestBootSource(second))
    service:injectReply({ op = "boot-source-result", epoch = second, state = "ready" })
    service:update()
    local freshLoading = fakeAdopter()
    Loading.new = function()
      return freshLoading
    end
    local freshScript = { fired = 0 }
    local fresh = CachePreparationState.new({
      kind = "boot-source",
      epoch = second,
      service = service,
      versionId = "heartgold",
      pairIndex = 5,
      isCurrent = function()
        return true
      end,
      onReady = function()
        freshScript.fired = freshScript.fired + 1
      end,
      onCancel = function() end,
    })
    fresh:update(0.016)
    service:update()
    local freshWalkerId = assert(walkerCommandId(host, second), "the fresh wait demands the pair anew")
    Assert.isTrue(freshWalkerId ~= walkerId, "the fresh epoch owns a distinct request identity")
    service:injectReply({ op = "request-result", epoch = second, requestId = freshWalkerId, state = "ready" })
    service:update()
    fresh:update(0.016)
    Assert.equal(freshScript.fired, 1, "the fresh epoch transfers on its independent answer")
    Assert.isTrue(fresh:takeLoading() == freshLoading, "the fresh wait transfers its own presentation")
    service:injectReply({ op = "request-result", epoch = epoch, requestId = walkerId, state = "ready" })
    service:update()
    fresh:update(0.016)
    Assert.equal(freshScript.fired, 1, "a stale packet never publishes a second transfer")
    fresh:dispose()
    state:dispose()
    service:shutdown()
  end, debug.traceback)
  Loading.new = savedNew
  if not ok then
    error(err, 0)
  end
end

function T.local_adoption_failure_needs_one_explicit_key_per_attempt()
  local CacheService = require("app.src.CacheService")
  local Loading = require(LOADING_MODULE)
  local savedNew = Loading.new
  local loading = fakeAdopter()
  loading.adoptResult = false
  Loading.new = function()
    return loading
  end
  local ok, err = xpcall(function()
    local host = newChannelHost()
    assert(type(host) == "table" and type(host.channels) == "table", "host shape")
    assert(type(host.newChannel) == "function", "host has newChannel")
    local service = CacheService.new({ thread = host })
    assert(#host.channels == 2, "service owns two channels, got " .. tostring(#host.channels))
    local epoch = assert(service:select({ versionId = "heartgold" }))
    assert(service:requestBootSource(epoch))
    service:injectReply({ op = "boot-source-result", epoch = epoch, state = "ready" })
    service:update()
    local script = { fired = 0 }
    local state = CachePreparationState.new({
      kind = "boot-source",
      epoch = epoch,
      service = service,
      versionId = "heartgold",
      pairIndex = 5,
      isCurrent = function()
        return true
      end,
      onReady = function()
        script.fired = script.fired + 1
      end,
      onCancel = function() end,
    })
    state:update(0.016)
    service:update()
    local walkerId = assert(walkerCommandId(host, epoch), "the wait demands the selected pair")
    service:injectReply({ op = "request-result", epoch = epoch, requestId = walkerId, state = "ready" })
    service:update()
    state:update(0.016)
    Assert.equal(script.fired, 0, "a failed adoption never transfers")
    Assert.equal(loading.adoptions, 1, "the first ready answer attempts adoption once")
    local copy = captureWarmCopy(function()
      state:draw()
    end)
    Assert.isTrue(copy:find("Press R", 1, true) ~= nil, "the adoption failure names its retry key")
    state:update(0.016)
    state:update(0.016)
    Assert.equal(loading.adoptions, 1, "no automatic adoption follows the latch")
    Assert.equal(script.fired, 0, "the latch never transfers on its own")
    state:keypressed("r")
    loading.adoptResult = true
    state:update(0.016)
    Assert.equal(loading.adoptions, 2, "one explicit key authorizes exactly one new attempt")
    Assert.equal(script.fired, 1, "the retried adoption transfers")
    Assert.isTrue(state:takeLoading() == loading, "the retry transfers the owned presentation")
    state:update(0.016)
    Assert.equal(script.fired, 1, "the transfer fires exactly once")
    state:dispose()
    service:shutdown()
  end, debug.traceback)
  Loading.new = savedNew
  if not ok then
    error(err, 0)
  end
end

function T.cold_terminal_worker_failure_forwards_escape_only_to_the_card()
  local CacheService = require("app.src.CacheService")
  local Loading = require(LOADING_MODULE)
  local savedNew = Loading.new
  local loading = fakeAdopter()
  Loading.new = function()
    return loading
  end
  local ok, err = xpcall(function()
    local host = newChannelHost()
    local service = CacheService.new({ thread = host })
    local epoch = assert(service:select({ versionId = "heartgold" }))
    assert(service:requestBootSource(epoch))
    service:injectReply({ op = "boot-source-result", epoch = epoch, state = "ready" })
    service:update()
    local script = { fired = 0 }
    local state = CachePreparationState.new({
      kind = "boot-source",
      epoch = epoch,
      service = service,
      versionId = "heartgold",
      pairIndex = 5,
      freshImport = true,
      importStatus = { state = "complete", progress = 1 },
      isCurrent = function()
        return true
      end,
      onReady = function()
        script.fired = script.fired + 1
      end,
      onCancel = function() end,
    })
    state:update(0.016)
    service:update()
    local walkerId = assert(walkerCommandId(host, epoch), "the cold card demands the selected pair")
    service:injectReply({
      op = "request-result",
      epoch = epoch,
      requestId = walkerId,
      state = "failed",
      errorMessage = "synthetic walker failure",
    })
    service:update()
    state:update(0.016)
    Assert.equal(script.fired, 0, "a terminal cold failure never transfers")
    local seen = {}
    local view = assert(state._importView, "a cold wait retains its card")
    local originalDraw = view.draw
    view.draw = function(self, statusOverride)
      seen.override = statusOverride
      return originalDraw(self, statusOverride)
    end
    local copy = captureWarmCopy(function()
      state:draw()
    end)
    view.draw = originalDraw
    Assert.notNil(seen.override, "the cold card receives its artwork status")
    Assert.equal(seen.override.stage, "artwork", "the cold failure rides the artwork stage")
    Assert.isFalse(seen.override.retryable == true, "a terminal failure forwards no retry flag")
    Assert.isTrue(copy:find("Press Esc", 1, true) ~= nil, "the cold terminal card names escape")
    Assert.isTrue(copy:find("Press R", 1, true) == nil, "the cold terminal card never promises a retry")
    state:keypressed("r")
    state:update(0.016)
    Assert.equal(script.fired, 0, "R never retries the cold terminal failure")
    state:dispose()
    service:shutdown()
  end, debug.traceback)
  Loading.new = savedNew
  if not ok then
    error(err, 0)
  end
end

function T.quiescence_card_names_the_pending_file_before_the_barrier_admits()
  local App = require("app.src.App")
  local RomSource = require("romdump.src.source.RomSource")
  local NdsRom = require("romdump.src.source.NdsRom")
  local RomBinding = require("romdump.src.source.RomBinding")
  local originalFromPath = RomSource.fromPath
  local originalFromDroppedFile = RomSource.fromDroppedFile
  local originalOpen = NdsRom.open
  local originalRecord = RomBinding.record
  local calls = {}
  RomSource.fromPath = function(...)
    calls[#calls + 1] = "path"
    return originalFromPath(...)
  end
  RomSource.fromDroppedFile = function(...)
    calls[#calls + 1] = "drop"
    return originalFromDroppedFile(...)
  end
  NdsRom.open = function(...)
    calls[#calls + 1] = "verify"
    return originalOpen(...)
  end
  RomBinding.record = function(...)
    calls[#calls + 1] = "record"
    return originalRecord(...)
  end
  local savedApp = {
    state = App.state,
    service = App.service,
    epoch = App.epoch,
    pendingQuiesce = App.pendingQuiesce,
    importer = App.importer,
    selectedVersionId = App.selectedVersionId,
    receipt = App._importReceipt,
    rebind = App._rebindVersionId,
    bootBlocked = App._bootBlockedVersionId,
    pairIndex = App.pairIndex,
  }
  local function restoreAll()
    RomSource.fromPath = originalFromPath
    RomSource.fromDroppedFile = originalFromDroppedFile
    NdsRom.open = originalOpen
    RomBinding.record = originalRecord
    App.state = savedApp.state
    App.service = savedApp.service
    App.epoch = savedApp.epoch
    App.pendingQuiesce = savedApp.pendingQuiesce
    App.importer = savedApp.importer
    App.selectedVersionId = savedApp.selectedVersionId
    App._importReceipt = savedApp.receipt
    App._rebindVersionId = savedApp.rebind
    App._bootBlockedVersionId = savedApp.bootBlocked
    App.pairIndex = savedApp.pairIndex
  end
  local function captureCopy(draw)
    local lg = love.graphics
    local saved = {
      getDimensions = lg.getDimensions,
      getWidth = lg.getWidth,
      setColor = lg.setColor,
      rectangle = lg.rectangle,
      print = lg.print,
      printf = lg.printf,
    }
    local copy = {}
    lg.getDimensions = function()
      return 800, 600
    end
    lg.getWidth = function()
      return 800
    end
    lg.setColor = function() end
    lg.rectangle = function() end
    lg.print = function(value)
      copy[#copy + 1] = tostring(value)
    end
    lg.printf = function(value)
      copy[#copy + 1] = tostring(value)
    end
    local ok, err = xpcall(draw, debug.traceback)
    lg.getDimensions = saved.getDimensions
    lg.getWidth = saved.getWidth
    lg.setColor = saved.setColor
    lg.rectangle = saved.rectangle
    lg.print = saved.print
    lg.printf = saved.printf
    if not ok then
      error(err, 0)
    end
    return table.concat(copy, "\n")
  end
  local function dropStub()
    return {
      getFilename = function()
        return "soulsilver.nds"
      end,
      open = function()
        return true
      end,
      read = function()
        return "not a real rom"
      end,
      close = function() end,
    }
  end
  local ok, err = xpcall(function()
    for _, kind in ipairs({ "path", "drop" }) do
      local script = { status = "pending", barrier = 7, imports = 0 }
      local service = {}
      function service:quiesce(_)
        return script.barrier
      end
      function service:barrierStatus(_, _)
        return script.status
      end
      function service:importSource(_, _)
        script.imports = script.imports + 1
        return true
      end
      function service:update() end
      App.state = nil
      App.service = service
      App.epoch = 3
      App.pendingQuiesce = nil
      App.importer = nil
      App.selectedVersionId = nil
      App._importReceipt = nil
      App._rebindVersionId = nil
      App._bootBlockedVersionId = nil
      App.pairIndex = nil
      calls = {}
      if kind == "path" then
        App._beginImportPath("/user/soulsilver.nds")
      else
        App.filedropped(dropStub())
      end
      Assert.equal(
        getmetatable(App.state),
        CachePreparationState,
        "the pending barrier holds a visible wait for a " .. kind
      )
      Assert.equal(App.state.kind, "quiescence", "the wait guards source closure")
      local waiting = captureCopy(function()
        App.state:draw()
      end)
      Assert.isTrue(
        waiting:find("soulsilver.nds", 1, true) ~= nil,
        "the waiting card names the pending file before admission, got: " .. waiting
      )
      Assert.equal(#calls, 0, "no source read runs while the barrier is pending")
      App.update(0.016)
      Assert.equal(
        getmetatable(App.state),
        CachePreparationState,
        "the unacknowledged barrier keeps the wait for a " .. kind
      )
      Assert.equal(#calls, 0, "the held wait still reads nothing")
      script.status = "ready"
      App.update(0.016)
      Assert.equal(#calls, 0, "admission alone never reads before the receipt is painted")
      local admitted = captureCopy(function()
        App.draw()
      end)
      Assert.isTrue(
        admitted:find("soulsilver.nds", 1, true) ~= nil,
        "the admitted receipt still names the file, got: " .. admitted
      )
      App.update(0.016)
      Assert.equal(#calls, 0, "the render thread never reads the " .. kind .. " source")
    end
    do
      local script = { status = "pending", barrier = 11, imports = 0 }
      local service = {}
      function service:quiesce(_)
        return script.barrier
      end
      function service:barrierStatus(_, _)
        return script.status
      end
      function service:importSource(_, _)
        script.imports = script.imports + 1
        return true
      end
      function service:update() end
      App.state = nil
      App.service = service
      App.epoch = 5
      App.pendingQuiesce = nil
      App.importer = nil
      App.selectedVersionId = nil
      App._importReceipt = nil
      App._rebindVersionId = nil
      App._bootBlockedVersionId = nil
      App.pairIndex = nil
      calls = {}
      App.filedropped(dropStub())
      Assert.equal(
        getmetatable(App.state),
        CachePreparationState,
        "the cancelled attempt starts behind its barrier"
      )
      App.state:keypressed("escape")
      App.update(0.016)
      Assert.isNil(App.pendingQuiesce, "escape releases the pending barrier")
      Assert.equal(#calls, 0, "a cancelled wait never starts its worker")
    end
  end, debug.traceback)
  restoreAll()
  if not ok then
    error(err, 0)
  end
end

return { tests = T }
