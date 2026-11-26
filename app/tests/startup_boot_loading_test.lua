-- Neutral boot loading and its single ownership transfer. Source readiness,
-- not decorative artwork or elapsed time, controls the handoff.

local Assert = require("tests.support.Assert")
local CachePreparationState = require("app.src.launcher.CachePreparationState")

local T = {}

local function bootService(script)
  script.calls = 0
  script.requests = {}
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
    script.requests[#script.requests + 1] = selector
  end
  return service
end

local function fakeLoading()
  local loading = { draws = 0, updates = 0, disposals = 0 }
  function loading:update(dt)
    self.updates = self.updates + 1
    self.lastDt = dt
  end
  function loading:resize(...)
    self.resizes = self.resizes or {}
    self.resizes[#self.resizes + 1] = { ... }
  end
  function loading:draw(status)
    self.draws = self.draws + 1
    self.status = status
  end
  function loading:dispose()
    self.disposals = self.disposals + 1
  end
  return loading
end

local function bootWait(script, loading, overrides)
  local options = {
    kind = "boot-source",
    epoch = 7,
    service = bootService(script),
    versionId = "heartgold",
    label = "HeartGold",
    loading = loading,
    isCurrent = function()
      return true
    end,
    onReady = function()
      script.fired = (script.fired or 0) + 1
    end,
    onFailure = function(detail)
      script.failures = script.failures or {}
      script.failures[#script.failures + 1] = detail
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

function T.neutral_loader_paints_before_any_controller_reply()
  local script = { pending = true }
  local loading = fakeLoading()
  local state = bootWait(script, loading)
  state:draw()
  Assert.equal(loading.draws, 1)
  Assert.equal(script.calls, 0, "drawing never polls or waits on the source gate")
  state:update(1 / 60)
  Assert.equal(loading.updates, 1)
  Assert.isTrue(state:isAwaitingOpening())
  state:dispose()
  Assert.equal(loading.disposals, 1)
end

function T.pending_source_keeps_the_neutral_loader_without_transfer()
  local script = { pending = true }
  local loading = fakeLoading()
  local state = bootWait(script, loading)
  state:update(1 / 60)
  state:update(1 / 60)
  Assert.equal(script.fired or 0, 0)
  Assert.deepEqual(script.requests, {})
  Assert.isNil(loading.status)
  Assert.isTrue(state:isAwaitingOpening())
  state:dispose()
end

function T.ready_boot_source_transfers_without_a_decorative_walker_demand()
  local script = { bootReady = true }
  local loading = fakeLoading()
  local state = bootWait(script, loading)
  state:update(1 / 60)
  Assert.equal(script.fired, 1)
  Assert.isFalse(state:isAwaitingOpening())
  Assert.deepEqual(script.requests, {})
  Assert.isTrue(state:takeLoading() == loading)
  Assert.throws(function()
    state:takeLoading()
  end)
  state:dispose()
  Assert.equal(loading.disposals, 0)
  loading:dispose()
end

function T.blocked_or_failed_boot_source_returns_one_copied_failure_without_transfer()
  for _, status in ipairs({ "source-required", "failed" }) do
    local detail =
      { code = "ROM_SOURCE_REQUIRED", message = "managed source needs repair", context = { path = "managed" } }
    local script = { sourceDetail = detail, bootFailure = detail }
    local loading = fakeLoading()
    local state = bootWait(script, loading)
    state:update(1 / 60)
    detail.message = "mutated"
    detail.context.path = "mutated"
    state:update(1 / 60)
    Assert.equal(script.fired or 0, 0)
    Assert.equal(#script.failures, 1)
    Assert.equal(script.failures[1].message, "managed source needs repair")
    Assert.equal(script.failures[1].context.path, "managed")
    Assert.isFalse(state:isAwaitingOpening())
    state:dispose()
    Assert.equal(loading.disposals, 1)
  end
end

function T.retired_selection_never_polls_or_transfers()
  local script = { bootReady = true }
  local loading = fakeLoading()
  local state = bootWait(script, loading, {
    isCurrent = function()
      return false
    end,
  })
  Assert.isFalse(state:isAwaitingOpening())
  state:update(1 / 60)
  Assert.equal(script.calls, 0)
  Assert.equal(script.fired or 0, 0)
  state:dispose()
  Assert.equal(loading.disposals, 1)
end

return { tests = T }
