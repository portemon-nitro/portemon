-- Exercises the script-owned Kurt selector lease and its single C01 commit.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local ApricornBoxHost = require("game.hgss.src.apricorn.ApricornBoxHost")

local T = {}

local function child(resultForUpdate)
  local state = { disposed = 0, updates = 0, events = nil }
  function state:updateFixed(events)
    self.updates = self.updates + 1
    self.events = events
  end
  function state:status()
    return { phase = "rows" }
  end
  function state:takeResult()
    return resultForUpdate
  end
  function state:cancelPointerCapture() end
  function state:dispose()
    self.disposed = self.disposed + 1
  end
  return state
end

local function setup(resultForUpdate, submitResult)
  local made = {}
  local submits = {}
  local service = {
    submitKurt = function(_, key, quantity)
      submits[#submits + 1] = { key, quantity }
      return submitResult
    end,
  }
  local host = ApricornBoxHost.new({
    makeApricornBox = function(mode)
      Assert.equal(mode, "kurt_select")
      local value = child(resultForUpdate)
      made[#made + 1] = value
      return value
    end,
    service = service,
  })
  return host, made, submits
end

function T.confirmed_selection_commits_once_and_close_releases_the_child()
  local host, made, submits = setup({
    kind = "closed",
    selected = { apricornKey = "WHT_APRICORN", quantity = 3 },
  }, true)
  local handle = host:open()
  host:setPresentationReady(handle, true)
  host:step(handle, { { type = "confirm" } })
  Assert.deepEqual(submits, { { "WHT_APRICORN", 3 } })
  Assert.equal(host:result(handle).kind, "closed")
  Assert.isNil(host:result(handle), "the host publishes the result once")
  host:close(handle)
  Assert.equal(made[1].disposed, 1)
  Assert.isFalse(host:isActive())
end

function T.cancel_does_not_submit_and_stale_order_disposes_before_faulting()
  local host, made, submits = setup({ kind = "closed" }, true)
  local handle = host:open()
  host:step(handle, {})
  Assert.deepEqual(submits, {})
  Assert.equal(host:result(handle).kind, "closed")
  host:close(handle)
  Assert.equal(made[1].disposed, 1)

  local staleHost, staleMade, staleSubmits = setup({
    kind = "closed",
    selected = { apricornKey = "WHT_APRICORN", quantity = 3 },
  }, false)
  local staleHandle = staleHost:open()
  local ok, err = pcall(function()
    staleHost:step(staleHandle, {})
  end)
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "SCRIPT_TASK_CALLBACK_FAULT")
  Assert.deepEqual(staleSubmits, { { "WHT_APRICORN", 3 } })
  Assert.equal(staleMade[1].disposed, 1)
  Assert.isFalse(staleHost:isActive())
end

return { tests = T }
