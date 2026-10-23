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
    Assert.equal(
      type(state.takeLoading),
      "function",
      "the boot wait exposes one exactly-once presentation transfer"
    )
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
      lowered:find("error", 1, true) ~= nil or lowered:find("retry", 1, true) ~= nil or lowered:find("try again", 1, true) ~= nil,
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
    Assert.isTrue(
      copy:find("Press R", 1, true) ~= nil,
      "the held card names its retry key, got: " .. copy
    )
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

return { tests = T }
