-- Whiteout task ownership of recovery and its canonical common-script child.

local Assert = require("tests.support.Assert")
local WhiteoutTask = require("libs.hgss.src.script.tasks.WhiteoutTask")

local T = {}

local function context(flow, childStatus)
  local resolved = {}
  local created = {}
  local child = {
    instanceId = "child-17",
    scriptId = "std.2013",
    status = childStatus or "running",
    endReason = "script_fault",
  }
  local scheduler = {
    resolveComposition = function(_, id)
      resolved[#resolved + 1] = id
      return { id = id }
    end,
    createCommonChild = function(_, composed, args)
      created[#created + 1] = { composed = composed, args = args }
      return child, 3, 1
    end,
    instance = function(_, instanceId)
      Assert.equal(instanceId, child.instanceId)
      return child
    end,
  }
  return {
    ctx = {
      input = {},
      scheduler = scheduler,
      services = {
        blackout = flow,
        travel = { lastHealSpawn = "spawn.cherrygrove" },
      },
    },
    resolved = resolved,
    created = created,
    child = child,
  }
end

local function incompleteFlow()
  local complete = false
  local flow = {
    start = function(_, spawn)
      Assert.equal(spawn, "spawn.cherrygrove")
      return "blackout-9"
    end,
    updateFixed = function() end,
    status = function()
      return { complete = complete }
    end,
    consumeResult = function()
      return "std.2013"
    end,
    complete = function()
      complete = true
    end,
  }
  return flow
end

T["common child starts only after recovery and task state stores identities"] = function()
  local flow = incompleteFlow()
  local h = context(flow)
  local state = WhiteoutTask.create({}, h.ctx)

  Assert.equal(state.phase, "flow")
  Assert.equal(state.runId, "blackout-9")
  local waiting = WhiteoutTask.poll(state, h.ctx)
  Assert.isFalse(waiting.complete)
  Assert.equal(#h.resolved, 0, "common script must not resolve before recovery completes")
  Assert.equal(#h.created, 0, "common child must not start before recovery completes")

  flow:complete()
  local queued = WhiteoutTask.poll(state, h.ctx)
  Assert.isFalse(queued.complete)
  Assert.deepEqual(h.resolved, { "std.2013" }, "flow chooses the canonical follow-up")
  Assert.equal(h.created[1].composed.id, "std.2013")
  Assert.deepEqual(h.created[1].args, {})
  Assert.equal(state.phase, "child")
  Assert.equal(state.childInstanceId, "child-17")
  Assert.isNil(state.child)
  Assert.isNil(state.flow)
  Assert.isNil(state.childSlot, "task state retains the child identity, not scheduler slots")
  Assert.isNil(state.parentSlot, "task state retains the child identity, not scheduler slots")
  Assert.isNil(WhiteoutTask.validate(state))
end

T["whiteout completes only after child succeeds"] = function()
  local flow = incompleteFlow()
  flow:complete()
  local h = context(flow)
  local state = WhiteoutTask.create({}, h.ctx)
  WhiteoutTask.poll(state, h.ctx)
  h.child.status = "completed"

  local result = WhiteoutTask.poll(state, h.ctx)
  Assert.isTrue(result.complete)
  Assert.equal(result.result.termination, "completed")
end

T["whiteout propagates child fault and cancellation"] = function()
  for _, status in ipairs({ "faulted", "cancelled" }) do
    local flow = incompleteFlow()
    flow:complete()
    local h = context(flow)
    local state = WhiteoutTask.create({}, h.ctx)
    WhiteoutTask.poll(state, h.ctx)
    h.child.status = status

    local result = WhiteoutTask.poll(state, h.ctx)
    Assert.isTrue(result.complete)
    Assert.equal(result.result.termination, status)
    if status == "faulted" then
      Assert.notNil(result.result.error)
    else
      Assert.isNil(result.result.error)
    end
  end
end

T["production task registry includes battle and whiteout"] = function()
  local Composition = require("libs.hgss.src.script.Composition")
  local TaskRegistry = require("libs.script.src.TaskRegistry")
  local registry = Composition.registerTasks(TaskRegistry.new())

  Assert.equal(assert(registry:resolve("whiteout", 1)).type, "whiteout")
  Assert.equal(assert(registry:resolve("battle", 1)).type, "battle")
end

return { tests = T }
