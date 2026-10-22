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
  local script = { detail = { code = "ROM_SOURCE_REQUIRED", message = "the original file is missing" } }
  local state = bootWait(script, { mismatch = "Dropped SoulSilver does not match the expected HeartGold version." })
  state:update(0.016)
  state:update(0.016)
  Assert.equal(script.fired or 0, 0, "a missing source never transfers")
  Assert.isNil(state.error, "a missing source is a block, not a failure")
  Assert.equal(state.sourceDetail, script.detail, "the typed source reason stays visible on the wait")
  Assert.notNil(state.mismatch, "the wrong-version diagnostic stays on the blocked wait")
  script.ready = true
  state:update(0.016)
  Assert.equal(script.fired, 1, "the admitted source transfers on the same wait")
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
  local script = {}
  local state = bootWait(script)
  state:update(0.016)
  Assert.equal(script.fired or 0, 0, "the pending gate transfers nothing yet")
  state:keypressed("escape")
  Assert.equal(script.cancelled, 1, "escape returns to the owning selection exactly once")
  state:keypressed("escape")
  Assert.equal(script.cancelled, 1, "a second escape never cancels twice")
  script.ready = true
  state:update(0.016)
  Assert.equal(script.fired or 0, 0, "a cancelled wait never transfers even when the gate answers")
  state:dispose()
  state:update(0.016)
  Assert.equal(script.fired or 0, 0, "a disposed wait stays silent")
  Assert.equal(script.cancelled, 1, "disposal never re-cancels")
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

return { tests = T }
