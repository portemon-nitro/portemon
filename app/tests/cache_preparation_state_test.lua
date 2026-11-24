-- Source-control waits for the app shell: verified boot admission and exact
-- source-reader quiescence. Only boot admission owns a transferable loader.

local Assert = require("tests.support.Assert")
local CachePreparationState = require("app.src.launcher.CachePreparationState")

local T = {}

local function fakeLoading()
  local loading = { updates = 0, draws = 0, disposals = 0 }
  function loading:update(dt)
    self.updates = self.updates + 1
    self.lastDt = dt
  end
  function loading:resize(width, height)
    self.width, self.height = width, height
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

local function bootWait(script, overrides)
  local service = {}
  function service:bootSourceStatus(epoch)
    script.calls = (script.calls or 0) + 1
    script.seenEpoch = epoch
    if script.failure ~= nil then
      return "failed", script.failure
    end
    if script.ready then
      return "ready"
    end
    if script.pending then
      return "pending"
    end
    return "source-required", script.detail
  end
  local options = onTransfer(script, {
    kind = "boot-source",
    epoch = 7,
    service = service,
    versionId = "heartgold",
    label = "HeartGold",
    loading = fakeLoading(),
    onFailure = function(detail)
      script.failures = script.failures or {}
      script.failures[#script.failures + 1] = detail
    end,
  })
  for key, value in pairs(overrides or {}) do
    options[key] = value
  end
  return CachePreparationState.new(options)
end

local function fakeRenderer()
  local font = {}
  function font:getWidth(text)
    return #tostring(text) * 6
  end
  function font:getHeight()
    return 12
  end
  return {
    fonts = { body = font, bold = font },
    drawButton = function() end,
    drawLoadingSquares = function() end,
  }
end

local function quiescenceWait(script, overrides)
  local service = {}
  function service:barrierStatus(epoch, barrier)
    script.calls = (script.calls or 0) + 1
    script.seenEpoch, script.seenBarrier = epoch, barrier
    return script.status or "pending"
  end
  local options = onTransfer(script, {
    kind = "quiescence",
    epoch = 7,
    service = service,
    barrier = 3,
    renderer = fakeRenderer(),
    width = 390,
    height = 844,
  })
  for key, value in pairs(overrides or {}) do
    options[key] = value
  end
  return CachePreparationState.new(options)
end

function T.boot_source_wait_transfers_exactly_once_on_readiness()
  local script = { ready = true }
  local state = bootWait(script)
  local loading = state.loading
  state:resize(360, 640)
  Assert.equal(loading.width, 360)
  Assert.equal(loading.height, 640)
  state:update(0.016)
  Assert.equal(script.fired, 1)
  Assert.isTrue(state:takeLoading() == loading)
  state:update(0.016)
  Assert.equal(script.fired, 1, "the transfer fires exactly once")
  state:dispose()
  Assert.equal(loading.disposals, 0, "the old wait never disposes transferred loading")
  loading:dispose()
end

function T.boot_source_wait_stays_pending_without_a_decorative_demand()
  local script = { pending = true }
  local state = bootWait(script)
  state:update(0.016)
  state:update(0.016)
  Assert.equal(script.fired or 0, 0)
  Assert.equal(state.sourceStatus, nil)
  Assert.equal(state.loading.updates, 2, "neutral animation continues while required work remains")
  state:dispose()
end

function T.boot_source_failure_returns_one_typed_detail_without_transfer()
  local detail = { code = "ROM_SOURCE_REQUIRED", message = "source needs repair", context = { source = "managed" } }
  local script = { detail = detail }
  local state = bootWait(script)
  state:update(0.016)
  detail.context.source = "mutated"
  state:update(0.016)
  Assert.equal(script.fired or 0, 0)
  Assert.equal(#script.failures, 1)
  Assert.equal(script.failures[1].code, detail.code)
  Assert.equal(script.failures[1].context.source, "managed")
  local loading = state.loading
  Assert.notNil(loading, "the wait retains its loader until the App recovery route retires it")
  state:dispose()
  Assert.equal(loading.disposals, 1)
end

function T.boot_source_cancel_never_publishes_a_stale_transfer()
  local script = {}
  local state = bootWait(script)
  local loading = state.loading
  state:update(0.016)
  state:keypressed("escape")
  state:keypressed("escape")
  Assert.equal(script.cancelled, 1)
  Assert.equal(loading.disposals, 1)
  script.ready = true
  state:update(0.016)
  Assert.equal(script.fired or 0, 0)
  state:dispose()
  Assert.equal(loading.disposals, 1)
end

function T.stale_wait_never_polls_or_transfers()
  local script = { ready = true }
  local state = bootWait(script, {
    isCurrent = function()
      return false
    end,
  })
  state:update(0.016)
  Assert.equal(script.calls or 0, 0)
  Assert.equal(script.fired or 0, 0)
  state:dispose()
end

function T.quiescence_wait_holds_until_the_exact_barrier_acknowledges()
  local script = {}
  local state = quiescenceWait(script)
  state:update(0.016)
  state:update(0.016)
  Assert.equal(script.fired or 0, 0)
  Assert.equal(script.seenEpoch, 7)
  Assert.equal(script.seenBarrier, 3)
  script.status = "ready"
  state:update(0.016)
  Assert.equal(script.fired, 1)
  state:update(0.016)
  Assert.equal(script.fired, 1)
end

function T.quiescence_touch_cancel_uses_the_shared_loading_action()
  local script = {}
  local safe = { x = 0, y = 0, width = 390, height = 844 }
  local state = quiescenceWait(script, { safeRect = safe })
  local x, y = safe.x + safe.width - 10 - 56, safe.y + safe.height - 10 - 22
  state:touchpressed("finger", x, y)
  state:touchreleased("finger", x, y)
  Assert.equal(script.cancelled, 1, "a touch-only user can abandon a queued import while source readers drain")
  state:dispose()
end

function T.quiescence_failure_latches_without_transfer()
  local script = { status = "failed" }
  local state = quiescenceWait(script)
  state:update(0.016)
  Assert.equal(script.fired or 0, 0)
  Assert.notNil(state.error)
  script.status = "ready"
  state:update(0.016)
  Assert.equal(script.fired or 0, 0)
end

function T.quiescence_cancel_returns_without_transfer()
  local script = {}
  local state = quiescenceWait(script)
  state:update(0.016)
  state:keypressed("escape")
  Assert.equal(script.cancelled, 1)
  script.status = "ready"
  state:update(0.016)
  Assert.equal(script.fired or 0, 0)
  state:dispose()
end

function T.stale_quiescence_wait_never_polls_or_transfers()
  local script = { status = "ready" }
  local state = quiescenceWait(script, {
    isCurrent = function()
      return false
    end,
  })
  state:update(0.016)
  Assert.equal(script.calls or 0, 0)
  Assert.equal(script.fired or 0, 0)
end

function T.quiescence_card_names_the_pending_file_before_the_barrier_admits()
  local script = {}
  local state = quiescenceWait(script, { pendingImportName = "heartgold.nds" })
  Assert.isNil(state:paintedReceipt(), "latching a filename is not proof that it rendered")
  local copy = {}
  local original = love.graphics.print
  local originalSetFont = love.graphics.setFont
  love.graphics.print = function(text)
    copy[#copy + 1] = tostring(text)
  end
  love.graphics.setFont = function() end
  local ok, err = pcall(state.draw, state)
  love.graphics.print = original
  love.graphics.setFont = originalSetFont
  assert(ok, err)
  Assert.equal(state:paintedReceipt(), "heartgold.nds")
  Assert.isTrue(table.concat(copy, "\n"):find("File received heartgold.nds", 1, true) ~= nil)
  state:dispose()
end

function T.retired_wait_kinds_are_rejected_at_construction()
  Assert.throws(function()
    CachePreparationState.new({
      kind = "bootstrap",
      epoch = 7,
      service = {},
      isCurrent = function()
        return true
      end,
      onReady = function() end,
      onCancel = function() end,
    })
  end, "bootstrap preparation is not a launcher wait")
  Assert.throws(function()
    CachePreparationState.new({
      kind = "boot-source",
      epoch = 7,
      service = {},
      versionId = "heartgold",
      loading = fakeLoading(),
      isCurrent = function()
        return true
      end,
      onReady = function() end,
      onCancel = function() end,
    })
  end, "the product boot path requires its failure route")
end

return { tests = T }
