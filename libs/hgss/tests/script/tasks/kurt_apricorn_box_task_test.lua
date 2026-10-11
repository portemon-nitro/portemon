-- The Kurt opcode blocks on one serializable script-owned selector task.

local Assert = require("tests.support.Assert")
local KurtApricornBoxTask = require("libs.hgss.src.script.tasks.KurtApricornBoxTask")

local T = {}

local function context(result, resultAfterSteps)
  local state = { opens = 0, steps = {}, results = {}, closes = 0, cancels = 0, active = nil }
  local host = {}
  function host:open()
    state.opens = state.opens + 1
    state.active = { id = state.opens }
    state.results[state.active] = result
    return state.active
  end
  function host:activeHandle()
    return state.active
  end
  function host:step(handle, events)
    state.steps[#state.steps + 1] = { handle, events }
    state.stepCount = (state.stepCount or 0) + 1
  end
  function host:result(handle)
    if (state.stepCount or 0) < (resultAfterSteps or 1) then
      return nil
    end
    local value = state.results[handle]
    state.results[handle] = nil
    return value
  end
  function host:close(handle)
    Assert.equal(handle, state.active)
    state.closes = state.closes + 1
    state.active = nil
  end
  function host:cancel()
    state.cancels = state.cancels + 1
    state.active = nil
  end
  return { services = { kurtBoxHost = host }, input = { uiEvents = { { type = "confirm" } } } }, state
end

function T.selection_completes_once_after_host_commits_and_closes()
  local ctx, host = context({
    kind = "closed",
    selected = { apricornKey = "RED_APRICORN", quantity = 2 },
  }, 2)
  local state = KurtApricornBoxTask.create({}, ctx)
  Assert.equal(KurtApricornBoxTask.type, "kurt_apricorn_box")
  Assert.deepEqual(state, { completed = false, orderCommitted = false })
  Assert.equal(host.opens, 1)
  Assert.isFalse(KurtApricornBoxTask.poll(state, ctx).complete)
  local result = KurtApricornBoxTask.poll(state, ctx)
  Assert.isTrue(result.complete)
  Assert.isTrue(state.completed)
  Assert.isTrue(state.orderCommitted)
  Assert.equal(host.closes, 1)
  Assert.isTrue(KurtApricornBoxTask.poll(state, ctx).complete)
  Assert.equal(host.opens, 1, "a completed task cannot reopen or submit again")
  Assert.equal(host.closes, 1)
end

function T.restore_reopens_only_an_incomplete_modal_and_cancel_releases_it()
  local ctx, host = context(nil, 100)
  local state = { completed = false, orderCommitted = false }
  Assert.isFalse(KurtApricornBoxTask.poll(state, ctx).complete)
  Assert.equal(host.opens, 1, "restored work without a volatile host handle reopens")
  KurtApricornBoxTask.cancel(state, "script cancelled", ctx)
  Assert.equal(host.cancels, 1)
  Assert.isTrue(state.completed)
end

return { tests = T }
