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
      return { dispose = function() disposals = disposals + 1 end }
    end,
    createMailbox = function() return {} end,
    createPhotoAlbum = function() return {} end,
  })
  Assert.throws(function()
    owner:open({ app = "storage", mode = 0 })
  end)
  Assert.equal(disposals, 1, "partial child setup releases the resource it created")
  Assert.isFalse(owner:isActive())
end

return { tests = T }
