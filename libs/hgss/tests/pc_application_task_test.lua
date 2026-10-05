-- PC application and terminal wait script tasks run through the real scheduler.

local Assert = require("tests.support.Assert")
local S = require("gen4.script")
local Registry = require("libs.script.src.Registry")
local Composition = require("libs.script.src.Composition")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local Scheduler = require("libs.script.src.Scheduler")
local HgssComposition = require("libs.hgss.src.script.Composition")
local PcApplicationTask = require("libs.hgss.src.script.tasks.PcApplicationTask")
local ScriptErrors = require("libs.script.src.errors")

local T = { tests = {} }

local function harness()
  local host = { nextHandle = 0, opens = {}, steps = {}, closes = 0, cancels = 0 }
  function host:open(request)
    self.nextHandle = self.nextHandle + 1
    self.opens[#self.opens + 1] = request
    self.handle = self.nextHandle
    return self.handle
  end
  function host:activeHandle()
    return self.handle
  end
  function host:step(handle, events)
    self.steps[#self.steps + 1] = { handle = handle, events = events }
  end
  function host:result(_)
    if self.closed then
      return { kind = "closed" }
    end
    return nil
  end
  function host:close(handle)
    Assert.equal(handle, self.handle)
    self.closes = self.closes + 1
    self.handle = nil
  end
  function host:cancel(_)
    self.cancels = self.cancels + 1
    self.handle = nil
  end

  local terminal = { ready = false, releases = 0 }
  function terminal:effectFinished()
    return self.ready
  end
  function terminal:releaseEffect()
    self.releases = self.releases + 1
  end

  local services = { pcApplications = host, pcTerminal = terminal }
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = HgssComposition.registerTasks(TaskRegistry.new())
  local scheduler = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = services,
    taskRegistry = taskRegistry,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  return { host = host, terminal = terminal, registry = registry, composition = composition, scheduler = scheduler }
end

local function start(h, id, steps)
  local resource = S.script({ api = 1, id = id, steps = steps })
  h.registry:installBase(id, resource, "generated")
  return h.scheduler:createForeground(assert(h.composition:effective(id)), nil, 100)
end

function T.tests.application_lifecycle_opens_steps_and_closes_child()
  local h = harness()
  local instanceId = start(h, "test.pc_application", {
    S.pcOpen({ app = "storage", mode = 2 }),
    S.stop(),
  })
  h.scheduler:step(100, {})
  Assert.deepEqual(h.host.opens, { { app = "storage", mode = 2 } })
  local instance = assert(h.scheduler:instance(instanceId))
  local task = assert(h.scheduler:tasks()[1])
  Assert.equal(task.ownerInstanceId, instance.instanceId)
  Assert.keySet(task.state, "app,completed,kind,mode", "serialized state contains no live host handle")
  Assert.equal(task.state.completed, false)
  h.host.closed = true
  h.scheduler:step(101, { uiEvents = { { type = "confirm" } } })
  Assert.equal(#h.host.steps, 1)
  Assert.deepEqual(h.host.steps[1].events, { { type = "confirm" } })
  Assert.equal(h.host.closes, 1)
end

function T.tests.task_state_validation_rejects_unknown_or_open_shapes()
  Assert.notNil(PcApplicationTask.validate({ kind = "application", app = "unknown", completed = false }))
  Assert.notNil(PcApplicationTask.validate({ kind = "application", app = "storage", mode = 4, completed = false }))
  Assert.notNil(PcApplicationTask.validate({ kind = "terminal_wait", completed = false, handle = {} }))
  Assert.isNil(PcApplicationTask.validate({ kind = "terminal_wait", completed = false }))
end

function T.tests.source_storage_mode_four_fails_as_unavailable_before_opening_a_child()
  local h = harness()
  local context = { services = { pcApplications = h.host, pcTerminal = h.terminal } }
  local ok, err = pcall(PcApplicationTask.create, {
    kind = "application",
    app = "storage",
    mode = 4,
  }, context)
  Assert.isFalse(ok)
  Assert.equal(err.code, ScriptErrors.FEATURE_UNAVAILABLE)
  Assert.equal(#h.host.opens, 0)
end

function T.tests.terminal_wait_polls_and_cancellation_releases_effect()
  local h = harness()
  local instanceId = start(h, "test.pc_terminal_wait", {
    S.pcTerminalEffect({ action = "wait", prop = "pc_terminal" }),
    S.stop(),
  })
  h.scheduler:step(100, {})
  h.scheduler:step(101, {})
  Assert.equal(h.terminal.releases, 0, "a pending wait leaves the effect owned")
  h.scheduler:cancelInstance(instanceId, "test cancellation")
  Assert.equal(h.terminal.releases, 1, "cancelling a pending wait releases the effect once")
end

function T.tests.completed_terminal_wait_does_not_release_effect()
  local h = harness()
  start(h, "test.pc_terminal_wait_complete", {
    S.pcTerminalEffect({ action = "wait", prop = "pc_terminal" }),
    S.stop(),
  })
  h.scheduler:step(100, {})
  h.terminal.ready = true
  h.scheduler:step(101, {})
  Assert.equal(h.terminal.releases, 0, "the following source release command owns normal release")
end

function T.tests.cancelling_open_application_cancels_host_child()
  local h = harness()
  local instanceId = start(h, "test.pc_application_cancel", {
    S.pcOpen({ app = "mailbox" }),
    S.stop(),
  })
  h.scheduler:step(100, {})
  h.scheduler:cancelInstance(instanceId, "test cancellation")
  Assert.equal(h.host.cancels, 1)
  Assert.equal(h.host.closes, 0)
end

return T
