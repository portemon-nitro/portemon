-- The blocking mart task drives one owner-bound host handle per scheduler tick.

local Assert = require("tests.support.Assert")
local MartTask = require("libs.hgss.src.script.tasks.MartTask")

local T = {}

local function fixture()
  local token = { id = 1, owner = "owner-1" }
  local calls = { opens = {}, steps = 0, results = 0, closes = {} }
  local host = {
    open = function(_, ownerKey, descriptor)
      token.owner = ownerKey
      calls.opens[#calls.opens + 1] = { ownerKey = ownerKey, descriptor = descriptor }
      return token
    end,
    step = function(_, handle, events)
      Assert.isTrue(handle == token)
      Assert.deepEqual(events, { "confirm" })
      calls.steps = calls.steps + 1
    end,
    result = function(_, handle)
      Assert.isTrue(handle == token)
      calls.results = calls.results + 1
      return calls.steps == 2 and { kind = "close" } or nil
    end,
    close = function(_, handle)
      calls.closes[#calls.closes + 1] = handle
    end,
  }
  local ctx = {
    taskId = "task-1",
    instance = { instanceId = "owner-1" },
    input = { uiEvents = { "confirm" } },
    services = { mart = host },
  }
  return host, token, calls, ctx
end

function T.mart_task_opens_once_steps_once_per_poll_and_closes_after_terminal_result()
  local _, token, calls, ctx = fixture()
  local state = MartTask.create({ kind = "custom", stock = { key = "stock" } }, ctx)
  Assert.equal(#calls.opens, 0, "task creation does not publish a child before its first poll")

  local pending = MartTask.poll(state, ctx)
  Assert.isFalse(pending.complete)
  Assert.equal(calls.steps, 1)
  Assert.equal(#calls.opens, 1)
  Assert.equal(calls.opens[1].ownerKey, "owner-1:task-1")
  Assert.deepEqual(calls.opens[1].descriptor, { kind = "custom", stock = { key = "stock" } })

  local complete = MartTask.poll(state, ctx)
  Assert.isTrue(complete.complete)
  Assert.equal(calls.steps, 2)
  Assert.equal(calls.results, 2)
  Assert.equal(#calls.closes, 1)
  Assert.isTrue(calls.closes[1] == token)
  Assert.isTrue(complete.state.completed)
  Assert.isNil(complete.state.handle)
end

function T.mart_task_rejects_foreign_instance_and_cancels_only_its_handle()
  local _, token, calls, ctx = fixture()
  local state = MartTask.create({ kind = "standard" }, ctx)
  state = MartTask.poll(state, ctx).state
  local foreign = {
    instance = { instanceId = "owner-2" },
    input = { uiEvents = {} },
    services = ctx.services,
  }
  local ok = pcall(MartTask.poll, state, foreign)
  Assert.isFalse(ok, "a different script instance cannot poll the active handle")
  Assert.equal(calls.steps, 1)

  MartTask.cancel(state, "cancelled", ctx)
  Assert.equal(#calls.closes, 1)
  Assert.isTrue(calls.closes[1] == token)
end

function T.mart_task_rejects_invalid_descriptors_and_missing_host()
  local _, _, _, ctx = fixture()
  local invalid = pcall(MartTask.create, { kind = "standard", selector = 1 }, ctx)
  Assert.isFalse(invalid)
  local missing = pcall(MartTask.create, { kind = "standard" }, { instance = ctx.instance, services = {} })
  Assert.isFalse(missing)
end

return { tests = T }
