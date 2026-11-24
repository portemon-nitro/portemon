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
  local presentation = { draws = 0, updates = 0, disposals = 0 }
  function presentation:update(dt)
    self.updates = self.updates + 1
    self.lastDt = dt
  end
  function presentation:resize(width, height)
    self.width, self.height = width, height
  end
  function presentation:draw(status)
    self.draws = self.draws + 1
    self.status = status
  end
  function presentation:dispose()
    self.disposals = self.disposals + 1
  end
  return presentation
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
  local script = {}
  local loading = fakeLoading()
  local state = bootWait(script, loading)
  state:draw()
  Assert.equal(loading.draws, 1, "the first visible frame paints the neutral loader")
  Assert.equal(script.calls or 0, 0, "drawing never polls or waits on the source gate")
  state:update(0.016)
  Assert.equal(loading.updates, 1, "the transferred animation advances while required work remains")
  state:dispose()
  Assert.equal(loading.disposals, 1)
end

function T.pending_source_keeps_the_neutral_loader_without_transfer()
  local script = { pending = true }
  local loading = fakeLoading()
  local state = bootWait(script, loading)
  state:update(0.016)
  state:update(0.016)
  Assert.equal(script.fired or 0, 0, "a pending source never transfers")
  Assert.deepEqual(script.requests, {}, "the launcher adds no decorative asset demand")
  Assert.isNil(loading.status, "pending work exposes no internal provisioning copy")
  state:dispose()
end

function T.ready_boot_source_transfers_without_a_decorative_walker_demand()
  local script = { bootReady = true }
  local loading = fakeLoading()
  local state = bootWait(script, loading)
  state:update(0.016)
  Assert.equal(script.fired, 1, "an admitted source transfers to the existing startup owner")
  Assert.deepEqual(script.requests, {}, "the neutral launcher never requires walking artwork")
  local transferred = state:takeLoading()
  Assert.isTrue(transferred == loading, "the exact owned loader transfers")
  Assert.throws(function()
    state:takeLoading()
  end, "the presentation detaches exactly once")
  state:dispose()
  Assert.equal(loading.disposals, 0, "the receiving startup owner now owns the loader")
  loading:dispose()
end

function T.blocked_or_failed_boot_source_returns_one_copied_failure_without_transfer()
  for _, status in ipairs({ "source-required", "failed" }) do
    local detail = {
      code = "ROM_SOURCE_REQUIRED",
      message = "the managed source needs repair",
      context = { path = "managed-source" },
    }
    local script = { sourceDetail = detail, bootFailure = detail }
    local loading = fakeLoading()
    local state = bootWait(script, loading)
    state:update(0.016)
    detail.message = "mutated after retirement"
    detail.context.path = "mutated"
    state:update(0.016)
    Assert.equal(script.fired or 0, 0, "a blocked or failed source never transfers")
    Assert.equal(#script.failures, 1, "the product route receives one terminal source failure")
    Assert.equal(script.failures[1].code, "ROM_SOURCE_REQUIRED")
    Assert.equal(script.failures[1].message, "the managed source needs repair", "the cause is copied before retirement")
    Assert.equal(script.failures[1].context.path, "managed-source", "nested context is detached")
    state:dispose()
    Assert.equal(loading.disposals, 1, "recovery releases the neutral loader exactly once")
  end
end

function T.cancelled_or_retired_selection_releases_loading_once_and_never_transfers()
  local script = { bootReady = true }
  local loading = fakeLoading()
  local state = bootWait(script, loading)
  state:keypressed("escape")
  Assert.equal(script.cancelled, 1, "escape returns to selection exactly once")
  Assert.equal(loading.disposals, 1, "cancellation releases the loader once")
  state:update(0.016)
  Assert.equal(script.fired or 0, 0, "a late ready reply never transfers a cancelled wait")
  state:dispose()
  Assert.equal(loading.disposals, 1, "disposal never releases twice")

  local retiredScript = { bootReady = true }
  local retiredLoading = fakeLoading()
  local retired = bootWait(retiredScript, retiredLoading, {
    isCurrent = function()
      return false
    end,
  })
  retired:update(0.016)
  Assert.equal(retiredScript.calls or 0, 0, "a retired epoch never polls the gate")
  Assert.equal(retiredScript.fired or 0, 0, "a retired epoch never transfers")
  retired:dispose()
  Assert.equal(retiredLoading.disposals, 1)
end

return { tests = T }
