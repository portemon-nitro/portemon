-- Shared builder for save-compatibility tests: paused script buckets captured
-- through the real scheduler (real registry, composition, task registry, and
-- runtime values) plus the validation options and idle schedulers those
-- buckets restore into. Suites never hand-assemble script buckets.

local S = require("gen4.script")
local Assert = require("tests.support.Assert")
local Registry = require("libs.script.src.Registry")
local Composition = require("libs.script.src.Composition")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local Scheduler = require("libs.script.src.Scheduler")
local ScriptSave = require("libs.script.src.ScriptSave")
local WaitTicksTask = require("libs.script.src.tasks.WaitTicksTask")
local ChildScriptTask = require("libs.script.src.tasks.ChildScriptTask")
local FakeServices = require("tests.support.script.FakeServices")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

local CompatibilityFixture = {}

---@param extra table<string, unknown>|nil
---@return table<string, unknown>
function CompatibilityFixture.rig(extra)
  extra = extra or {}
  local services = FakeServices.new()
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local tasks = TaskRegistry.new()
  if extra.dropWaitTicks ~= true then
    tasks:register("wait_ticks", extra.waitTicksVersion or 1, WaitTicksTask)
  end
  tasks:register("child_script", 1, ChildScriptTask)
  if extra.unusedTask == true then
    tasks:register("probe_idle", 1, WaitTicksTask)
  end
  local scheduler = Scheduler.new({
    semantics = RuntimeValues,
    services = services,
    taskRegistry = tasks,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  return {
    services = services,
    registry = registry,
    composition = composition,
    tasks = tasks,
    scheduler = scheduler,
  }
end

---@param scriptId string|nil
---@return table<string, unknown>
function CompatibilityFixture.mainScript(scriptId)
  return S.script({
    api = 1,
    id = scriptId or "probe.main",
    steps = { S.waitTicks({ ticks = 5 }), S.stop() },
  })
end

-- Capture a paused bucket through the real scheduler: one foreground
-- instance suspended on its waiting task after a single step.
---@param setup table<string, unknown>
---@return table<string, unknown>
function CompatibilityFixture.pausedBucket(setup)
  local resource = CompatibilityFixture.mainScript()
  setup.registry:installBase(resource.id, resource, "generated")
  local composed = assert(setup.composition:effective(resource.id))
  setup.scheduler:createForeground(composed, nil, 100)
  setup.scheduler:step(100, nil)
  local bucket = ScriptSave.capture(setup.scheduler, 100, {
    registryFingerprint = setup.registry:fingerprint(),
  })
  Assert.equal(#bucket.instances, 1, "the paused script must carry its live instance")
  Assert.equal(#bucket.tasks, 1, "the paused script must carry its waiting task")
  return bucket
end

-- Grow a setup past its captured bucket: one unused script plus one unused
-- task. Every live reference still resolves; only the provenance moves.
---@param setup table<string, unknown>
function CompatibilityFixture.growWithUnused(setup)
  local unused = S.script({ api = 1, id = "probe.unused", steps = { S.stop() } })
  setup.registry:installBase(unused.id, unused, "generated")
  setup.tasks:register("probe_idle", 1, WaitTicksTask)
end

---@param setup table<string, unknown>
---@return table<string, unknown>
function CompatibilityFixture.optionsFor(setup)
  return {
    expectedRegistryFingerprint = setup.registry:fingerprint(),
    expectedTaskFingerprint = setup.tasks:fingerprint(),
    resolveTask = function(taskType, version)
      return setup.tasks:resolve(taskType, version)
    end,
    resolveComposition = function(scriptId)
      return setup.composition:effective(scriptId)
    end,
  }
end

---@param setup table<string, unknown>
---@return table<string, unknown>
function CompatibilityFixture.idleScheduler(setup)
  return Scheduler.new({
    semantics = RuntimeValues,
    services = setup.services,
    taskRegistry = setup.tasks,
    resolveComposition = function(id)
      return setup.composition:effective(id)
    end,
  })
end

return CompatibilityFixture
