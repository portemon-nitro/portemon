-- Source-control waits own one transferable loader. Ordinary pre-movie input is
-- routed by App; quiescence remains a real operation with its own cancellation.

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
  local presentation = { draws = 0, updates = 0, disposals = 0, resizes = {} }
  function presentation:update(dt)
    self.updates = self.updates + 1
    self.lastDt = dt
  end
  function presentation:resize(...)
    self.resizes[#self.resizes + 1] = { ... }
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

function T.only_live_initial_boot_source_wait_reports_pre_opening()
  local script = { pending = true }
  local loading = fakeLoading()
  local state = bootWait(script, loading)
  Assert.equal(type(state.isAwaitingOpening), "function")
  Assert.isTrue(state:isAwaitingOpening())
  state:update(1 / 60)
  Assert.isTrue(state:isAwaitingOpening())
  state:resize(385, 287, { x = 18, y = 24, width = 349, height = 239 }, 3)
  Assert.deepEqual(loading.resizes[1], { 385, 287, { x = 18, y = 24, width = 349, height = 239 }, 3 })
  state:dispose()
  Assert.isFalse(state:isAwaitingOpening())

  local readyScript = { bootReady = true }
  local readyLoading = fakeLoading()
  local ready = bootWait(readyScript, readyLoading)
  ready:update(1 / 60)
  Assert.equal(readyScript.fired, 1)
  Assert.isFalse(ready:isAwaitingOpening(), "source readiness ends the pre-opening wait")
  Assert.isTrue(ready:takeLoading() == readyLoading)
  ready:dispose()
  Assert.equal(readyLoading.disposals, 0, "the receiving startup owner keeps the transferred loader")
  readyLoading:dispose()

  local retiredScript = { pending = true }
  local retired = bootWait(retiredScript, fakeLoading(), {
    isCurrent = function()
      return false
    end,
  })
  Assert.isFalse(retired:isAwaitingOpening())
  retired:update(1 / 60)
  Assert.equal(retiredScript.calls, 0)
  retired:dispose()
end

function T.neutral_loader_paints_without_polling_or_adding_decorative_demand()
  local script = { pending = true }
  local loading = fakeLoading()
  local state = bootWait(script, loading)
  state:draw()
  Assert.equal(loading.draws, 1)
  Assert.equal(script.calls, 0, "draw never polls the source gate")
  state:update(1 / 60)
  Assert.equal(loading.updates, 1)
  Assert.deepEqual(script.requests, {})
  Assert.isNil(loading.status, "pending work exposes no internal provisioning copy")
  state:dispose()
  Assert.equal(loading.disposals, 1)
end

function T.ordinary_pre_opening_input_is_not_a_leaf_cancel_action()
  local script = { pending = true }
  local state = bootWait(script, fakeLoading())
  state:keypressed("escape")
  state:keypressed("return")
  state:gamepadpressed({}, "a")
  Assert.equal(script.cancelled or 0, 0, "App owns the shared manual-selection route")
  Assert.isTrue(state:isAwaitingOpening())
  state:dispose()
end

function T.blocked_or_failed_source_returns_one_copied_failure_without_transfer()
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
    Assert.isFalse(state:isAwaitingOpening(), "terminal failure is no longer an interruptible pre-opening wait")
    state:dispose()
    Assert.equal(loading.disposals, 1)
  end
end

function T.quiescence_is_an_operation_and_keeps_its_exact_barrier_identity()
  local script = { calls = 0, status = "pending", cancelled = 0 }
  local service = {}
  function service:barrierStatus(epoch, barrier)
    script.calls = script.calls + 1
    script.epoch, script.barrier = epoch, barrier
    return script.status
  end
  local font = {}
  function font:getWidth(text)
    return #tostring(text) * 6
  end
  function font:getHeight()
    return 12
  end
  local renderer =
    { fonts = { body = font, bold = font }, drawButton = function() end, drawLoadingSquares = function() end }
  local state = CachePreparationState.new({
    kind = "quiescence",
    epoch = 7,
    barrier = 3,
    service = service,
    renderer = renderer,
    width = 390,
    height = 844,
    isCurrent = function()
      return true
    end,
    onReady = function()
      script.ready = true
    end,
    onCancel = function()
      script.cancelled = script.cancelled + 1
    end,
  })
  Assert.isFalse(state:isAwaitingOpening())
  state:update(1 / 60)
  Assert.equal(script.epoch, 7)
  Assert.equal(script.barrier, 3)
  Assert.isNil(script.ready)
  state:keypressed("escape")
  Assert.equal(script.cancelled, 1, "a real operation retains its admissible Cancel route")
  script.status = "ready"
  state:update(1 / 60)
  Assert.isNil(script.ready, "canceled view cannot transfer a late barrier acknowledgement")
  state:dispose()
end

return { tests = T }
