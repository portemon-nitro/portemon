-- Word editor screen lifetime: a pending lease commits one ready bundle
-- before any input is admitted, a failed preparation propagates its
-- original cause instead of a cancellation, disposal during preparation
-- releases exactly once and never commits late, and disposal stays
-- idempotent. The screen stays production; the editor core and the
-- resource lease are scripted doubles behind the documented per-open
-- seam, since the real siblings land in the same commit and their
-- composition is proven through the production factory journey.

local Assert = require("tests.support.Assert")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {
  metadata = {
    tags = { "easychat" },
  },
  tests = {},
}

-- Loads the word editor screen owner that does not exist yet at this
-- baseline. The failure names the missing behaviour instead of surfacing
-- as a suite load error, so the pre-implementation red stays attributable.
---@param moduleName string
---@param missingMessage string
---@return table
local function requireFeature(moduleName, missingMessage)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    error(missingMessage, 0)
  end
  assert(type(mod) == "table", missingMessage)
  return mod --[[@as table]]
end

-- Scripts the editor core behind the screen: it advances per fixed tick,
-- projects a detached composition view, publishes no result, and records
-- its disposal.
---@return table controller
local function scriptedController()
  local calls = { updateFixed = 0, disposed = false }
  local controller = {
    updateFixed = function()
      calls.updateFixed = calls.updateFixed + 1
    end,
    view = function()
      return { level = "composition" }
    end,
    takeResult = function()
      return nil
    end,
    cancelPointerCapture = function() end,
    dispose = function()
      calls.disposed = true
    end,
  }
  controller._calls = calls
  return controller
end

-- Scripts the per-open resource lease: each prepare call consumes the
-- next scripted step, and releases are counted for exactly-once
-- ownership.
---@param script string[] "pending", "ready", or "failed" per prepare call
---@return table lease
local function scriptedLease(script)
  local calls = 0
  local releases = 0
  local lease = {
    prepare = function()
      calls = calls + 1
      local step = script[math.min(calls, #script)]
      if step == "failed" then
        return { kind = "failed", error = "test image pool failure" }
      end
      if step == "ready" then
        return { kind = "ready", assets = { manifest = { layers = {}, sequences = {} }, images = {} } }
      end
      return { kind = "pending" }
    end,
    release = function()
      releases = releases + 1
    end,
  }
  lease._releases = function()
    return releases
  end
  return lease
end

---@return fun(): table measurement
local function testMeasurement()
  local topology = ScreenTopology.dualDisplay(
    { id = "world", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
    { id = "aux", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
  )
  local measured = { width = 512, height = 384, topology = topology, pixelRatio = 1, signature = "test" }
  return function()
    return measured
  end
end

---@param controller table
---@param lease table
---@return table screen
local function openScreen(controller, lease)
  local Screen = requireFeature(
    "game.hgss.src.easychat.EasyChatScreenState",
    "the shared word editor has no presentation owner yet: "
      .. "preparation cannot commit, fail, or release its per-open lease"
  )
  return Screen.new({
    controller = controller,
    lease = lease,
    measureDisplay = testMeasurement(),
    overrides = {},
    effect = function() end,
  })
end

-- A pending lease commits one ready bundle before input is admitted, and
-- disposal releases the lease exactly once even when repeated.
function T.tests.pending_prepare_commits_one_ready_bundle_and_dispose_releases_once()
  local controller = scriptedController()
  local lease = scriptedLease({ "pending", "pending", "ready" })
  local screen = openScreen(controller, lease)

  screen:updateFixed({})
  local pending = screen:status()
  Assert.isTrue(pending.preparing, "the screen reports preparing while the lease pends")
  Assert.isNil(pending.assets, "no assets publish before the whole bundle commits")

  for _ = 1, 12 do
    screen:updateFixed({})
  end
  local ready = screen:status()
  Assert.isFalse(ready.preparing, "the screen leaves preparing once the bundle commits")
  Assert.notNil(ready.assets, "the committed bundle publishes its assets")
  Assert.isNil(screen:takeResult(), "committing publishes no terminal result")

  screen:dispose()
  Assert.equal(lease._releases(), 1, "disposal releases the lease exactly once")
  Assert.isTrue(controller._calls.disposed, "disposal releases the editor core")
  screen:dispose()
  Assert.equal(lease._releases(), 1, "repeated disposal never releases twice")
end

-- A failed preparation propagates its original cause: the failure is an
-- attributed error, never a synthetic user cancellation, and the lease
-- still releases exactly once with no result published.
function T.tests.failed_prepare_propagates_the_original_error_and_releases()
  local controller = scriptedController()
  local lease = scriptedLease({ "pending", "failed" })
  local screen = openScreen(controller, lease)

  local failedAt = nil
  local failure = nil
  for _ = 1, 12 do
    local ok, err = pcall(screen.updateFixed, screen, {})
    if not ok then
      failedAt = _
      failure = err
      break
    end
  end
  Assert.notNil(failedAt, "a failed preparation surfaces instead of pending forever")
  Assert.isTrue(
    tostring(failure):find("test image pool failure", 1, true) ~= nil,
    "the original acquisition cause propagates: " .. tostring(failure)
  )
  Assert.isNil(screen:takeResult(), "a failed preparation publishes no result")
  Assert.equal(lease._releases(), 1, "a failed preparation still releases its lease exactly once")
  screen:dispose()
  Assert.equal(lease._releases(), 1, "disposal after failure never releases twice")
end

-- Disposal during preparation releases once and never commits late: a
-- bundle that turns ready after disposal publishes nothing.
function T.tests.dispose_during_pending_releases_once_and_never_commits()
  local controller = scriptedController()
  local script = { "pending" }
  local lease = scriptedLease(script)
  local screen = openScreen(controller, lease)

  for _ = 1, 3 do
    screen:updateFixed({})
  end
  Assert.isTrue(screen:status().preparing, "the screen still prepares before disposal")
  screen:dispose()
  Assert.equal(lease._releases(), 1, "disposal during preparation releases exactly once")

  script[1] = "ready"
  for _ = 1, 6 do
    screen:updateFixed({})
  end
  Assert.isNil(screen:takeResult(), "a late bundle publishes no result after disposal")
  Assert.equal(lease._releases(), 1, "a late bundle never leaks a second release")
end

return T
