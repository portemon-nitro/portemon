local Assert = require("tests.support.Assert")
local PcApplicationHost = require("game.hgss.src.pc.PcApplicationHost")

local T = {}

local function child(calls)
  return {
    updateFixed = function(_, events)
      calls.steps = calls.steps + 1
      calls.events = events
    end,
    status = function()
      return { phase = "list" }
    end,
    takeResult = function()
      if calls.complete then
        calls.complete = false
        return { kind = "closed" }
      end
    end,
    cancelPointerCapture = function()
      calls.pointerCancel = calls.pointerCancel + 1
    end,
    dispose = function()
      calls.disposals = calls.disposals + 1
    end,
  }
end

local function host(calls)
  local factory = function(request)
    calls.request = request
    return child(calls)
  end
  return PcApplicationHost.new({
    createStorage = factory,
    createMailbox = factory,
    createPhotoAlbum = factory,
  })
end

local function calls()
  return { steps = 0, disposals = 0, pointerCancel = 0, complete = false }
end

function T.script_child_owns_one_event_batch_and_returns_once()
  local state = calls()
  local owner = host(state)
  local handle = owner:open({ app = "storage", mode = 2 })
  Assert.isTrue(owner:isActive())
  Assert.equal(state.request.mode, 2)
  owner:setPresentationReady(handle, true)
  local events = { { type = "confirm" } }
  owner:step(handle, events)
  Assert.equal(state.steps, 1)
  Assert.equal(state.events, events)
  Assert.isNil(owner:result(handle))
  state.complete = true
  owner:step(handle, {})
  Assert.deepEqual(owner:result(handle), { kind = "closed" })
  Assert.isNil(owner:result(handle), "the child return is consumed exactly once")
  owner:close(handle)
  owner:close(handle)
  owner:dispose()
  Assert.equal(state.disposals, 1, "one child lifetime is disposed once")
  Assert.equal(state.pointerCancel, 1, "closing releases pointer capture")
  Assert.isFalse(owner:isActive())
end

function T.presentation_readiness_suppresses_child_input_until_prepared()
  local state = calls()
  local owner = host(state)
  local handle = owner:open({ app = "storage", mode = 0 })
  local eventBatch = { { type = "confirm" } }
  owner:step(handle, eventBatch)
  Assert.equal(state.steps, 1, "the child remains on fixed ticks while hidden")
  Assert.deepEqual(state.events, {}, "unprepared child does not consume UI input")
  Assert.isTrue(owner:setPresentationReady(handle, true), "readiness transition is observable")
  owner:step(handle, eventBatch)
  Assert.equal(state.events, eventBatch, "ready child receives the current event batch")
  owner:cancel("test")
end

function T.unavailable_storage_mode_is_rejected_before_child_creation()
  local state = calls()
  local owner = host(state)
  Assert.throws(function()
    owner:open({ app = "storage", mode = 4 })
  end)
  Assert.isNil(state.request)
  Assert.isFalse(owner:isActive())
end

function T.concurrent_child_open_is_rejected_without_replacing_the_owner()
  local state = calls()
  local owner = host(state)
  local handle = owner:open({ app = "mailbox" })
  Assert.throws(function()
    owner:open({ app = "photoAlbum" })
  end)
  Assert.equal(owner:activeHandle(), handle)
  Assert.equal(state.disposals, 0)
  owner:cancel("test")
  Assert.equal(state.disposals, 1)
  Assert.isFalse(owner:isActive())
end

function T.invalid_child_factory_result_is_cleaned_up()
  local disposals = 0
  local owner = PcApplicationHost.new({
    createStorage = function()
      return {
        dispose = function()
          disposals = disposals + 1
        end,
      }
    end,
    createMailbox = function()
      return {}
    end,
    createPhotoAlbum = function()
      return {}
    end,
  })
  Assert.throws(function()
    owner:open({ app = "storage", mode = 0 })
  end)
  Assert.equal(disposals, 1, "partial child setup releases the resource it created")
  Assert.isFalse(owner:isActive())
end

local function gatedChild(calls)
  local child = child(calls)
  child.drawn = 0
  child.plan = { frames = {} }
  function child:draw(_)
    calls.draws = calls.draws + 1
  end
  function child:presentationPlan()
    return child.plan
  end
  return child
end

local function gatedHost(calls, activeChild)
  local factory = function(request)
    calls.request = request
    return activeChild
  end
  return PcApplicationHost.new({
    createStorage = factory,
    createMailbox = factory,
    createPhotoAlbum = factory,
  })
end

local function gatedCalls()
  local state = calls()
  state.draws = 0
  return state
end

-- Sibling applications keep their existing readiness gate: an unready
-- Mailbox or Photo Album child draws nothing, publishes no plan, and
-- receives no input until the host turns ready.
function T.unready_sibling_applications_draw_nothing_and_gate_input()
  for _, app in ipairs({ "mailbox", "photoAlbum" }) do
    local state = gatedCalls()
    local active = gatedChild(state)
    local owner = gatedHost(state, active)
    local request = { app = app }
    local handle = owner:open(request)
    Assert.equal(state.request.app, app)
    owner:draw({})
    Assert.equal(state.draws, 0, app .. " draws nothing while unready")
    Assert.isNil(owner:presentationPlan(), app .. " publishes no plan while unready")
    local events = { { type = "confirm" } }
    owner:step(handle, events)
    Assert.deepEqual(state.events, {}, app .. " receives no input while unready")
    owner:setPresentationReady(handle, true)
    owner:step(handle, events)
    Assert.equal(state.events, events, app .. " receives input once ready")
    owner:draw({})
    Assert.equal(state.draws, 1, app .. " draws once ready")
    Assert.isTrue(owner:presentationPlan() == active.plan, app .. " publishes its plan once ready")
    owner:cancel("test")
  end
end

-- The Storage input gate stays boolean: an unready Storage child ticks
-- without consuming input, and a ready one receives the event batch.
function T.unready_storage_gates_input_until_prepared()
  local state = gatedCalls()
  local active = gatedChild(state)
  local owner = gatedHost(state, active)
  local handle = owner:open({ app = "storage", mode = 0 })
  local events = { { type = "confirm" } }
  owner:step(handle, events)
  Assert.deepEqual(state.events, {}, "unready Storage receives no input")
  owner:setPresentationReady(handle, true)
  owner:step(handle, events)
  Assert.equal(state.events, events, "ready Storage receives the event batch")
  owner:cancel("test")
end

return { tests = T }
