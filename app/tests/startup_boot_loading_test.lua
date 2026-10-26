-- Boot-visible loading and its single ownership transfer. An ordinary warm
-- boot paints the animated themed stage on its very first draw, before the
-- boot-source gate answers, and keeps it visible while a missing source
-- blocks progress. A cold fresh import instead holds its compact card until
-- the selected walking pair is genuinely drawable, then detaches its one
-- owned presentation exactly once; cancellation or epoch retirement
-- releases that presentation exactly once and never transfers late.

local Assert = require("tests.support.Assert")
local CachePreparationState = require("app.src.launcher.CachePreparationState")

local LOADING_MODULE = "libs.hgss.src.ui.HgssLoadingPresentation"

local T = {}

---@param script table scripted gate/walker answers plus call records
---@return table service answering only the boot-source and pair seams
local function bootService(script)
  script.calls = 0
  script.pairRequests = {}
  script.pairUrgencies = {}
  local service = {}
  function service:bootSourceStatus(_)
    script.calls = script.calls + 1
    if script.bootFailure ~= nil then
      return "failed", script.bootFailure
    end
    if script.bootReady then
      return "ready"
    end
    if script.pending then
      return "pending"
    end
    return "source-required", script.sourceDetail
  end
  function service:request(_, selector)
    if type(selector) == "table" and selector.requestKind == "startup-walker" then
      script.pairRequests[#script.pairRequests + 1] = selector.pairIndex
      script.pairUrgencies[#script.pairUrgencies + 1] = selector.urgency
      return "walker-request"
    end
    return "other-request"
  end
  function service:observe(_, selector)
    if type(selector) == "table" and selector.requestKind == "startup-walker" then
      if script.walkerFailure ~= nil then
        return false, script.walkerFailure
      end
      return script.walkerReady == true, nil
    end
    return false, nil
  end
  return service
end

---@return table fake loading presentation recording draw/disposal counts
local function fakeLoading()
  local presentation = {
    draws = 0,
    disposals = 0,
    adoptions = 0,
    adopted = false,
    adoptResult = true,
    adoptError = nil,
  }
  function presentation:update() end
  function presentation:resize() end
  function presentation:draw()
    self.draws = self.draws + 1
  end
  function presentation:dispose()
    self.disposals = self.disposals + 1
  end
  function presentation:adoptGeneratedAssets()
    self.adoptions = self.adoptions + 1
    if self.adoptResult then
      self.adopted = true
      return true
    end
    return false, self.adoptError or "synthetic GPU acquisition failure"
  end
  return presentation
end

---@param presentation table the presenter the patched constructor hands out
---@param record table counts constructor calls and captures options
---@param fn fun() body running under the patched constructor
local function withPatchedLoading(presentation, record, fn)
  local Loading = require(LOADING_MODULE)
  local savedNew = Loading.new
  record.constructions = 0
  Loading.new = function(options)
    record.constructions = record.constructions + 1
    record.options = options
    return presentation
  end
  local ok, err = xpcall(fn, debug.traceback)
  Loading.new = savedNew
  if not ok then
    error(err, 0)
  end
end

---@param width number
---@param height number
---@param draw fun()
---@return string rendered text copy
local function captureCopy(width, height, draw)
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
    return width, height
  end
  lg.getWidth = function()
    return width
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

---@param script table
---@param overrides table?
---@return CachePreparationState
local function bootWait(script, overrides)
  local options = {
    kind = "boot-source",
    epoch = 7,
    service = bootService(script),
    versionId = "heartgold",
    pairIndex = 5,
    isCurrent = function()
      return true
    end,
    onReady = function()
      script.fired = (script.fired or 0) + 1
    end,
    onCancel = function()
      script.cancelled = (script.cancelled or 0) + 1
    end,
  }
  for key, value in pairs(overrides or {}) do
    options[key] = value
  end
  return CachePreparationState.new(options)
end

function T.warm_boot_draws_the_live_stage_before_the_gate_answers()
  local loading = fakeLoading()
  local record = {}
  withPatchedLoading(loading, record, function()
    local script = {}
    local state = bootWait(script)
    -- The first visible frame precedes every controller reply.
    local copy = captureCopy(800, 600, function()
      state:draw()
    end)
    Assert.equal(
      record.constructions,
      1,
      "warm boot installs its loading presentation at selection, before the gate answers"
    )
    Assert.equal(record.options.pairIndex, 5, "the installed stage carries the selected pair")
    Assert.equal(script.calls or 0, 0, "the first draw never waits on the boot-source gate")
    Assert.isTrue(loading.draws >= 1, "the first draw paints the animated stage")
    Assert.isTrue(
      copy:find("Preparing", 1, true) == nil,
      "no plaintext preparing headline is the first frame, got: " .. copy
    )
    state:dispose()
  end)
end

function T.blocked_boot_keeps_the_stage_visible_and_never_transfers()
  local loading = fakeLoading()
  local record = {}
  withPatchedLoading(loading, record, function()
    local script = { sourceDetail = { code = "ROM_SOURCE_REQUIRED", message = "the original file is missing" } }
    local state = bootWait(script)
    -- The remedy appears only after the gate confirms the block: the
    -- pre-reply frame stays themed with no provisioning words.
    local preCopy = captureCopy(800, 600, function()
      state:draw()
    end)
    Assert.isTrue(
      preCopy:lower():find("matching", 1, true) == nil,
      "the pre-reply frame names no missing-ROM remedy, got: " .. preCopy
    )
    state:update(0.016)
    state:update(0.016)
    local copy = captureCopy(800, 600, function()
      state:draw()
    end)
    Assert.isTrue(loading.draws >= 1, "the blocked boot still paints its animated stage")
    Assert.isTrue(
      copy:lower():find("matching", 1, true) ~= nil,
      "the blocked boot names the matching-ROM remedy, got: " .. copy
    )
    state:update(0.016)
    state:update(0.016)
    Assert.equal(script.fired or 0, 0, "a missing source never transfers to gameplay")
    Assert.isNil(state.error, "a missing source is a block, not a failure")
    Assert.equal(loading.disposals, 0, "the retained stage survives while blocked")
    state:dispose()
    Assert.equal(loading.disposals, 1, "retiring the blocked wait releases its stage once")
  end)
end

function T.cold_import_holds_its_card_until_the_selected_pair_is_drawable()
  local loading = fakeLoading()
  local record = {}
  withPatchedLoading(loading, record, function()
    local script = { bootReady = true, walkerReady = false }
    local state = bootWait(script, { freshImport = true })
    state:update(0.016)
    Assert.equal(script.fired or 0, 0, "the cold card holds while the selected pair is still pending")
    local seenPair = false
    for _, pairIndex in ipairs(script.pairRequests) do
      seenPair = seenPair or pairIndex == 5
    end
    Assert.isTrue(seenPair, "the cold wait demands exactly the selected pair")
    Assert.equal(type(state.takeLoading), "function", "the boot wait exposes one exactly-once presentation transfer")
    script.walkerReady = true
    loading.adoptResult = true
    state:update(0.016)
    Assert.equal(script.fired, 1, "the adopted pair completes the cold handoff")
    local transferred = state:takeLoading()
    Assert.isTrue(transferred == loading, "the transfer hands over the exact owned presentation")
    Assert.throws(function()
      state:takeLoading()
    end, "the presentation detaches exactly once")
    state:dispose()
    Assert.equal(loading.disposals, 0, "disposing after transfer never touches the detached art")
  end)
end

function T.failed_pair_adoption_releases_staged_art_and_holds_the_card()
  local loading = fakeLoading()
  loading.adoptResult = false
  loading.adoptError = "synthetic GPU acquisition failure"
  local record = {}
  withPatchedLoading(loading, record, function()
    local script = { bootReady = true, walkerReady = true }
    local state = bootWait(script, { freshImport = true })
    state:update(0.016)
    Assert.equal(script.fired or 0, 0, "a failed adoption never transfers to gameplay")
    Assert.throws(function()
      state:takeLoading()
    end, "nothing detaches before a successful adoption")
    local copy = captureCopy(800, 600, function()
      state:draw()
    end)
    local lowered = copy:lower()
    Assert.isTrue(
      lowered:find("error", 1, true) ~= nil
        or lowered:find("retry", 1, true) ~= nil
        or lowered:find("try again", 1, true) ~= nil,
      "the held card surfaces its error with a retry path, got: " .. copy
    )
    state:dispose()
    Assert.equal(loading.disposals, 1, "the failed wait releases its stage once")
  end)
end

function T.failed_gate_latches_an_error_without_freezing_the_stage()
  local loading = fakeLoading()
  local record = {}
  withPatchedLoading(loading, record, function()
    local script = { bootFailure = "synthetic controller failure" }
    local state = bootWait(script)
    state:update(0.016)
    Assert.equal(script.fired or 0, 0, "a failed gate never transfers to gameplay")
    Assert.notNil(state.error, "a genuine controller failure latches as a boot error")
    Assert.throws(function()
      state:takeLoading()
    end, "nothing detaches before an admitted gate")
    local drawsBefore = loading.draws
    captureCopy(800, 600, function()
      state:draw()
    end)
    Assert.isTrue(loading.draws > drawsBefore, "the failed boot keeps painting its animated stage")
    state:update(0.016)
    captureCopy(800, 600, function()
      state:draw()
    end)
    Assert.isTrue(loading.draws > drawsBefore + 1, "the stage keeps animating while the error is latched")
    state:dispose()
    Assert.equal(loading.disposals, 1, "retiring the failed wait releases its stage once")
  end)
end

function T.cold_retry_requests_the_pair_again_after_an_adoption_error()
  local loading = fakeLoading()
  loading.adoptResult = false
  local record = {}
  withPatchedLoading(loading, record, function()
    local script = { bootReady = true, walkerReady = true }
    local state = bootWait(script, { freshImport = true })
    state:update(0.016)
    Assert.equal(script.fired or 0, 0, "a failed adoption never transfers to gameplay")
    Assert.notNil(state.artFailure, "the failed adoption stays visible on the held card")
    local copy = captureCopy(800, 600, function()
      state:draw()
    end)
    Assert.isTrue(copy:find("Press R", 1, true) ~= nil, "the held card names its retry key, got: " .. copy)
    state:keypressed("r")
    Assert.isNil(state.artFailure, "retry clears the adoption failure without re-verifying the source")
    loading.adoptResult = true
    state:update(0.016)
    Assert.equal(script.fired, 1, "the retried adoption completes the cold handoff")
    Assert.isTrue(#script.pairRequests >= 2, "retry re-requests the selected pair")
    Assert.isTrue(state:takeLoading() == loading, "retry transfers the exact owned presentation")
    state:dispose()
  end)
end

function T.warm_boot_holds_transfer_until_the_selected_pair_is_adopted()
  local loading = fakeLoading()
  local record = {}
  withPatchedLoading(loading, record, function()
    local script = { bootReady = true, walkerReady = false }
    local state = bootWait(script)
    captureCopy(800, 600, function()
      state:draw()
    end)
    Assert.equal(record.constructions, 1, "warm boot installs its loading presentation at selection")
    Assert.equal(script.calls or 0, 0, "the first draw never waits on the boot-source gate")
    Assert.isTrue(loading.draws >= 1, "the first draw paints the animated stage")
    state:update(0.016)
    state:update(0.016)
    Assert.equal(script.fired or 0, 0, "the warm wait never transfers while the selected pair is still pending")
    Assert.isTrue(#script.pairRequests >= 1, "the warm wait demands the selected pair while it waits")
    for _, pairIndex in ipairs(script.pairRequests) do
      Assert.equal(pairIndex, 5, "the warm wait demands exactly the selected pair")
    end
    for _, urgency in ipairs(script.pairUrgencies) do
      Assert.equal(urgency, "required", "the selected pair is a required demand, never best-effort interest")
    end
    Assert.isFalse(loading.adopted, "nothing is adopted before the pair job answers")
    script.walkerReady = true
    loading.adoptResult = true
    state:update(0.016)
    Assert.equal(script.fired, 1, "the adopted pair completes the warm handoff")
    Assert.isTrue(loading.adopted, "both selected sprites are adopted before transfer")
    Assert.isTrue(loading.adoptions >= 1, "adoption runs against the generated pair art")
    local transferred = state:takeLoading()
    Assert.isTrue(transferred == loading, "the transfer hands over the exact owned presentation")
    Assert.throws(function()
      state:takeLoading()
    end, "the presentation detaches exactly once")
    state:dispose()
    Assert.equal(loading.disposals, 0, "disposing after transfer never touches the detached art")
  end)
end

function T.warm_pair_worker_error_holds_transfer_until_the_pair_recovers()
  local loading = fakeLoading()
  local record = {}
  withPatchedLoading(loading, record, function()
    local script = { bootReady = true, walkerFailure = "synthetic walker failure" }
    local state = bootWait(script)
    state:update(0.016)
    state:update(0.016)
    Assert.equal(script.fired or 0, 0, "a failed pair job never transfers to gameplay")
    Assert.throws(function()
      state:takeLoading()
    end, "nothing detaches after a failed pair job")
    local copy = captureCopy(800, 600, function()
      state:draw()
    end)
    local lowered = copy:lower()
    Assert.isTrue(
      lowered:find("escape", 1, true) ~= nil,
      "the terminal worker wait names its escape remedy, got: " .. copy
    )
    Assert.isTrue(
      lowered:find("press r", 1, true) == nil,
      "the terminal worker wait never promises a same-epoch retry, got: " .. copy
    )
    state:keypressed("r")
    state:update(0.016)
    Assert.equal(script.fired or 0, 0, "R never retries a terminal worker failure")
    Assert.notNil(state.artFailure, "the terminal worker failure stays latched after R")
    -- A terminal worker record cannot heal under the same request
    -- identity: the same wait never transfers even when the scripted
    -- worker later reports ready. Only a fresh selection epoch may try
    -- again, modelled here by a new wait on a new epoch.
    script.walkerFailure = nil
    script.walkerReady = true
    loading.adoptResult = true
    state:update(0.016)
    state:update(0.016)
    Assert.equal(script.fired or 0, 0, "the latched worker failure never heals into a transfer")
    Assert.notNil(state.artFailure, "the latched worker failure survives a later ready answer")
    state:keypressed("escape")
    Assert.equal(script.cancelled, 1, "escape still releases the terminal wait")
    local freshScript = { bootReady = true, walkerReady = true }
    local fresh = bootWait(freshScript)
    fresh:update(0.016)
    Assert.isTrue(#freshScript.pairRequests >= 1, "a fresh selection demands the pair anew")
    fresh:dispose()
    state:dispose()
  end)
end

function T.warm_pair_adoption_failure_holds_transfer_until_a_successful_retry()
  local loading = fakeLoading()
  loading.adoptResult = false
  local record = {}
  withPatchedLoading(loading, record, function()
    local script = { bootReady = true, walkerReady = true }
    local state = bootWait(script)
    state:update(0.016)
    Assert.equal(script.fired or 0, 0, "a failed warm adoption never transfers to gameplay")
    Assert.throws(function()
      state:takeLoading()
    end, "nothing detaches before a successful adoption")
    Assert.equal(loading.adoptions, 1, "the first ready answer attempts the adoption exactly once")
    local copy = captureCopy(800, 600, function()
      state:draw()
    end)
    Assert.isTrue(
      copy:find("Press R", 1, true) ~= nil,
      "the latched adoption failure names its retry key, got: " .. copy
    )
    -- The latch holds without another input: no automatic second attempt.
    state:update(0.016)
    state:update(0.016)
    Assert.equal(script.fired or 0, 0, "the latched adoption never transfers on its own")
    Assert.equal(loading.adoptions, 1, "no automatic adoption follows the latched failure")
    state:keypressed("r")
    loading.adoptResult = true
    state:update(0.016)
    Assert.equal(script.fired, 1, "the explicit retry completes the warm handoff")
    Assert.isTrue(loading.adopted, "the retry adopts both selected sprites")
    Assert.isTrue(state:takeLoading() == loading, "retry transfers the exact owned presentation")
    state:dispose()
    Assert.equal(loading.disposals, 0, "disposing after transfer never touches the detached art")
  end)
end

function T.warm_epoch_switch_after_admission_never_fires_the_retired_wait()
  local loading = fakeLoading()
  local record = {}
  withPatchedLoading(loading, record, function()
    local script = { bootReady = true, walkerReady = false }
    local live = true
    local state = bootWait(script, {
      isCurrent = function()
        return live
      end,
    })
    state:update(0.016)
    Assert.equal(script.fired or 0, 0, "the admitted wait holds while the selected pair is pending")
    Assert.isTrue(#script.pairRequests >= 1, "the live wait demands the selected pair")
    live = false
    script.walkerReady = true
    loading.adoptResult = true
    local demands = #script.pairRequests
    state:update(0.016)
    state:update(0.016)
    Assert.equal(script.fired or 0, 0, "a retired epoch never transfers when the pair answers late")
    Assert.equal(#script.pairRequests, demands, "a retired epoch issues no further pair demands")
    Assert.throws(function()
      state:takeLoading()
    end, "a retired wait detaches nothing")
    state:dispose()
    Assert.equal(loading.disposals, 1, "retiring the switched wait releases its stage once")
    state:dispose()
    Assert.equal(loading.disposals, 1, "disposal never releases twice")
  end)
end

function T.warm_pair_retry_issues_one_demand_per_update_without_transfer()
  local loading = fakeLoading()
  loading.adoptResult = false
  local record = {}
  withPatchedLoading(loading, record, function()
    local script = { bootReady = true, walkerReady = true }
    local state = bootWait(script)
    for _ = 1, 3 do
      state:update(0.016)
    end
    Assert.equal(script.fired or 0, 0, "a persistently failing adoption never transfers")
    Assert.equal(#script.pairRequests, 1, "the latched adoption issues no further pair demands")
    Assert.equal(loading.adoptions, 1, "the latched adoption attempts no automatic retry")
    for _, pairIndex in ipairs(script.pairRequests) do
      Assert.equal(pairIndex, 5, "every retry keeps the selected pair without a default species")
    end
    for _, urgency in ipairs(script.pairUrgencies) do
      Assert.equal(urgency, "required", "every retry keeps the required demand")
    end
    Assert.throws(function()
      state:takeLoading()
    end, "nothing detaches before a successful adoption")
    -- One explicit key authorizes exactly one more attempt, which latches
    -- again while the adopter keeps failing.
    state:keypressed("r")
    state:update(0.016)
    Assert.equal(#script.pairRequests, 2, "one explicit key re-issues the pair demand once")
    Assert.equal(loading.adoptions, 2, "one explicit key re-attempts the adoption once")
    Assert.equal(script.fired or 0, 0, "the renewed failure latches again without transfer")
    state:dispose()
    Assert.equal(loading.disposals, 1, "the failed wait releases its stage once")
  end)
end

function T.transferred_loading_detaches_exactly_once()
  local loading = fakeLoading()
  local record = {}
  withPatchedLoading(loading, record, function()
    local script = { bootReady = true, walkerReady = true }
    local state = bootWait(script)
    state:update(0.016)
    Assert.equal(script.fired, 1, "the admitted warm boot fires its transfer")
    Assert.isTrue(state:takeLoading() == loading, "the transfer hands over the owned presentation")
    Assert.throws(function()
      state:takeLoading()
    end, "a second transfer is invalid")
    state:dispose()
    Assert.equal(loading.disposals, 0, "the old wait never disposes transferred art")

    local idleScript = {}
    local idle = bootWait(idleScript)
    idle:dispose()
    Assert.equal(idleScript.fired or 0, 0, "disposing before readiness transfers nothing")
  end)
end

function T.cancelled_or_retired_selection_releases_loading_once_and_never_transfers()
  local loading = fakeLoading()
  local record = {}
  withPatchedLoading(loading, record, function()
    local script = {}
    local state = bootWait(script)
    Assert.equal(record.constructions, 1, "the wait owns its stage from selection")
    state:keypressed("escape")
    Assert.equal(script.cancelled, 1, "escape returns to the owning selection exactly once")
    Assert.equal(loading.disposals, 1, "cancellation releases the owned stage once")
    Assert.throws(function()
      state:takeLoading()
    end, "a cancelled wait detaches nothing")
    script.bootReady = true
    script.walkerReady = true
    state:update(0.016)
    Assert.equal(script.fired or 0, 0, "a cancelled wait never transfers when the gate answers late")
    state:dispose()
    Assert.equal(loading.disposals, 1, "disposal never releases twice")
  end)

  local retiredLoading = fakeLoading()
  local retiredRecord = {}
  withPatchedLoading(retiredLoading, retiredRecord, function()
    local script = { bootReady = true, walkerReady = true }
    local state = bootWait(script, {
      isCurrent = function()
        return false
      end,
    })
    state:update(0.016)
    Assert.equal(script.fired or 0, 0, "a retired epoch never transfers")
    Assert.equal(script.calls or 0, 0, "a retired epoch never polls the gate")
    state:dispose()
  end)
end

-- The full warm journey keeps exactly one pair alive: the production
-- selection settles on the published ready pair, the transfer adopts it
-- exactly once with no demand for any other pair, the identity survives
-- later updates, and switching edition releases the one presentation once.
function T.warm_journey_keeps_one_pair_alive_and_retires_it_once()
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
  local retires = 0
  local service = {}
  function service:select(_)
    epochs = epochs + 1
    return epochs
  end
  function service:request(_, selector)
    if type(selector) == "table" and selector.requestKind == "startup-walker" then
      demands[#demands + 1] = { epoch = epochs, pairIndex = selector.pairIndex, urgency = selector.urgency }
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
  function service:requestBootSource(_) end
  function service:bootSourceStatus(_)
    return "ready", nil
  end
  function service:update() end
  function service:retire(_)
    retires = retires + 1
  end
  function service:generationId(_)
    return "synthetic-test-generation"
  end
  local presentations = {}
  local function fakeLoading()
    local presentation = { adopted = false, adoptions = 0, disposals = 0 }
    function presentation:update() end
    function presentation:resize() end
    function presentation:draw() end
    function presentation:dispose()
      self.disposals = self.disposals + 1
    end
    function presentation:adoptGeneratedAssets()
      self.adoptions = self.adoptions + 1
      self.adopted = true
      return true
    end
    presentations[#presentations + 1] = presentation
    return presentation
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
      return fakeLoading()
    end
    FirstPlayCompletion.isCurrent = function()
      return false
    end
    HgssGame.newFirstPlayCachePreparation = function(_)
      local preparation = {}
      function preparation:poll()
        return nil, nil
      end
      function preparation:dispose() end
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
    Assert.equal(App.pairIndex, 7, "the warm epoch keeps the published ready pair")
    Assert.isTrue(#demands >= 1, "the warm journey demands its pair while it waits")
    for _, demand in ipairs(demands) do
      Assert.equal(demand.pairIndex, 7, "every demand names the one selected pair")
      Assert.equal(demand.urgency, "required", "the selected pair stays a required demand")
    end
    Assert.equal(getmetatable(App.state).__index, StartupTitleState, "the adopted pair transfers the warm journey")
    Assert.equal(presentations[1].adoptions, 1, "the selected pair is adopted exactly once")
    local chosen = App.pairIndex
    for _ = 1, 10 do
      App.update(0.016)
    end
    Assert.equal(App.pairIndex, chosen, "later updates never reselect the pair within the epoch")
    for _, demand in ipairs(demands) do
      Assert.equal(demand.pairIndex, chosen, "no second pair ever leaves the game thread")
    end
    App._selectVersion("soulsilver")
    for _ = 1, 3 do
      App.update(0.016)
    end
    Assert.equal(presentations[1].disposals, 1, "switching edition releases the retired presentation once")
    Assert.equal(App.pairIndex, 7, "the fresh epoch settles on the ready pair again")
    Assert.isTrue(retires >= 1, "switching edition retires the previous selection")
  end, debug.traceback)
  restore()
  if not ok then
    error(err, 0)
  end
end

-- The selected pair is demanded while the source gate is still blocked:
-- the worker compiles during the wait, but nothing is adopted and nothing
-- transfers until the gate admits the epoch.
function T.blocked_boot_demands_the_selected_pair_before_admission()
  local loading = fakeLoading()
  local record = {}
  withPatchedLoading(loading, record, function()
    local script = { sourceDetail = { code = "ROM_SOURCE_REQUIRED", message = "the original file is missing" } }
    local state = bootWait(script)
    state:update(0.016)
    state:update(0.016)
    Assert.isTrue(#script.pairRequests >= 1, "the blocked wait demands the selected pair early")
    for _, pairIndex in ipairs(script.pairRequests) do
      Assert.equal(pairIndex, 5, "the early demand names exactly the selected pair")
    end
    Assert.equal(script.fired or 0, 0, "the blocked gate never transfers")
    Assert.isFalse(loading.adopted, "nothing is adopted before the gate admits the epoch")
    Assert.throws(function()
      state:takeLoading()
    end, "nothing detaches before admission and adoption")
    state:dispose()
    Assert.equal(loading.disposals, 1, "retiring the blocked wait releases its stage once")
  end)
end

-- A pending gate shows themed animation with no provisioning words while it
-- demands the selected pair; nothing transfers while verification is open.
function T.pending_gate_shows_no_provisioning_copy_while_demanding_the_pair()
  local loading = fakeLoading()
  local record = {}
  withPatchedLoading(loading, record, function()
    local script = { pending = true }
    local state = bootWait(script)
    state:update(0.016)
    state:update(0.016)
    Assert.isTrue(#script.pairRequests >= 1, "the pending wait demands the selected pair early")
    for _, pairIndex in ipairs(script.pairRequests) do
      Assert.equal(pairIndex, 5, "the early demand names exactly the selected pair")
    end
    for _, urgency in ipairs(script.pairUrgencies) do
      Assert.equal(urgency, "required", "the pending demand stays a required demand")
    end
    Assert.equal(script.fired or 0, 0, "a pending gate never transfers")
    local copy = captureCopy(800, 600, function()
      state:draw()
    end)
    local lowered = copy:lower()
    Assert.isTrue(loading.draws >= 1, "the pending wait still paints its animated stage")
    Assert.isTrue(
      lowered:find("matching", 1, true) == nil,
      "a pending gate names no matching-ROM remedy, got: " .. copy
    )
    Assert.isTrue(lowered:find("drop", 1, true) == nil, "a pending gate offers no drop-file instruction, got: " .. copy)
    Assert.isTrue(lowered:find("provide", 1, true) == nil, "a pending gate shows no provisioning prompt, got: " .. copy)
    script.pending = nil
    script.sourceDetail = { code = "ROM_SOURCE_REQUIRED", message = "the original file is missing" }
    state:update(0.016)
    local confirmed = captureCopy(800, 600, function()
      state:draw()
    end)
    Assert.isTrue(
      confirmed:lower():find("matching", 1, true) ~= nil,
      "a confirmed source-required gate names its remedy, got: " .. confirmed
    )
    Assert.equal(script.fired or 0, 0, "the confirmed block still never transfers")
    state:dispose()
    Assert.equal(loading.disposals, 1, "retiring the pending wait releases its stage once")
  end)
end

-- Walker readiness while the gate is pending adopts both sprites into the
-- owned presentation without transferring; the later ready answer fires once.
function T.pending_walker_readiness_adopts_before_admission_without_transfer()
  local loading = fakeLoading()
  local record = {}
  withPatchedLoading(loading, record, function()
    local script = { pending = true, walkerReady = true }
    local state = bootWait(script)
    state:update(0.016)
    Assert.isTrue(loading.adopted, "both sprites adopt while verification is still pending")
    Assert.isTrue(loading.adoptions >= 1, "adoption runs against the generated pair art")
    Assert.equal(script.fired or 0, 0, "visible sprites never transfer before the gate admits")
    Assert.throws(function()
      state:takeLoading()
    end, "nothing detaches before admission even when sprites are visible")
    script.pending = nil
    script.bootReady = true
    state:update(0.016)
    Assert.equal(script.fired, 1, "the later ready answer transfers exactly once")
    Assert.isTrue(state:takeLoading() == loading, "the transfer hands over the early-adopted presentation")
    state:dispose()
    Assert.equal(loading.disposals, 0, "disposing after transfer never touches the adopted art")
  end)
end

-- A confirmed source-required gate with ready cached art may stage sprites
-- yet never transfers; a stale epoch with staged art never fires or leaks.
function T.confirmed_block_with_staged_art_never_transfers_and_releases_once()
  local loading = fakeLoading()
  local record = {}
  withPatchedLoading(loading, record, function()
    local script = { walkerReady = true, sourceDetail = { code = "ROM_SOURCE_REQUIRED" } }
    local state = bootWait(script)
    state:update(0.016)
    Assert.isTrue(loading.adopted, "ready cached art stages even behind a confirmed block")
    Assert.equal(script.fired or 0, 0, "a confirmed block never transfers even with ready art")
    Assert.throws(function()
      state:takeLoading()
    end, "a blocked wait detaches nothing even when sprites are staged")
    state:keypressed("escape")
    Assert.equal(script.cancelled, 1, "escape releases the blocked wait exactly once")
    Assert.equal(loading.disposals, 1, "cancellation releases the staged presentation once")
    Assert.equal(script.fired or 0, 0, "cancellation never transfers")
    state:dispose()
    Assert.equal(loading.disposals, 1, "disposal never releases twice")
  end)
  local retiredLoading = fakeLoading()
  local retiredRecord = {}
  withPatchedLoading(retiredLoading, retiredRecord, function()
    local live = true
    local script = { pending = true, walkerReady = true }
    local state = bootWait(script, {
      isCurrent = function()
        return live
      end,
    })
    state:update(0.016)
    Assert.isTrue(retiredLoading.adopted, "the live pending wait stages its sprites")
    Assert.equal(script.fired or 0, 0, "the pending wait transfers nothing")
    live = false
    script.pending = nil
    script.bootReady = true
    state:update(0.016)
    state:update(0.016)
    Assert.equal(script.fired or 0, 0, "a retired epoch never transfers even with staged art")
    Assert.throws(function()
      state:takeLoading()
    end, "a retired wait detaches nothing")
    state:dispose()
    Assert.equal(retiredLoading.disposals, 1, "retiring the stale wait releases its stage once")
  end)
end

return { tests = T }
