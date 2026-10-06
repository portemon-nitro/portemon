-- Save and resume tests: the serializable
-- scripts bucket of g4-field-save-v3. They pin relative-timing capture and
-- rebasing: no tick is duplicated or skipped across a
-- capture/restore boundary, completed-but-unconsumed tasks restore as
-- completed and are never polled again, resume_pending owners preserve their
-- delay, common child contexts and caller signals survive, and concrete task
-- or revision mismatches are attributed load errors. A
-- non-UI script saves and resumes with an identical per-tick node/task trace.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local S = require("gen4.script")
local Registry = require("libs.script.src.Registry")
local Composition = require("libs.script.src.Composition")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local Scheduler = require("libs.script.src.Scheduler")
local ScriptSave = require("libs.script.src.ScriptSave")
local ScriptTask = require("libs.script.src.ScriptTask")
local ScriptInstance = require("libs.script.src.ScriptInstance")
local ScriptEnvironment = require("libs.script.src.ScriptEnvironment")
local WaitTicksTask = require("libs.script.src.tasks.WaitTicksTask")
---@cast WaitTicksTask TaskImplementation
local ChildScriptTask = require("libs.script.src.tasks.ChildScriptTask")
---@cast ChildScriptTask TaskImplementation
local FakeServices = require("tests.support.script.FakeServices")
local Diagnostics = require("libs.script.src.Diagnostics")

local T = {}


---@class SaveHarness
---@field services FakeServices
---@field registry Registry
---@field composition Composition
---@field taskRegistry TaskRegistry
---@field scheduler Scheduler
---@field trace Diagnostics.TraceRecorder

---@param opts table|nil
---@return SaveHarness
local function harness(opts)
  opts = opts or {}
  local services = FakeServices.new(opts)
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = TaskRegistry.new()
  taskRegistry:register("wait_ticks", 1, WaitTicksTask)
  taskRegistry:register("child_script", 1, ChildScriptTask)
  local recorder = Diagnostics.newTraceRecorder()
  local scheduler = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = services,
    taskRegistry = taskRegistry,
    trace = function(record)
      recorder:record(record)
    end,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  return {
    services = services,
    registry = registry,
    composition = composition,
    taskRegistry = taskRegistry,
    scheduler = scheduler,
    trace = recorder,
  }
end

local function script(id, steps)
  return S.script({ api = 1, id = id, steps = steps })
end

local function startForeground(h, resource, tick)
  if h.registry:base(resource.id) == nil then
    h.registry:installBase(resource.id, resource, "generated")
  end
  local composed = assert(h.composition:effective(resource.id))
  return h.scheduler:createForeground(composed, nil, tick)
end

-- Capture the scripts bucket and restore it into a fresh scheduler attached
-- to the same services; returns the resumed scheduler and its recorder.
-- `scheduler` overrides the captured scheduler (a previously resumed one).
---@param h SaveHarness
---@param tick integer
---@param scheduler Scheduler|nil
---@return Scheduler, Diagnostics.TraceRecorder
local function saveAndResume(h, tick, scheduler)
  scheduler = scheduler or h.scheduler
  local bucket = ScriptSave.capture(scheduler, tick)
  local recorder = Diagnostics.newTraceRecorder()
  local resumed = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = h.services,
    taskRegistry = h.taskRegistry,
    trace = function(record)
      recorder:record(record)
    end,
    resolveComposition = function(id)
      return h.composition:effective(id)
    end,
  })
  ScriptSave.restore(bucket, resumed, tick)
  return resumed, recorder
end

-- Run a scenario uninterruptedly and compare the resumed trace suffix with
-- the uninterrupted one.
---@param resource table
---@param from integer
---@param to integer
---@param saveAt integer
local function traceSuffixMatch(resource, from, to, saveAt)
  local h = harness()
  startForeground(h, resource, from)
  for tick = from, to do
    h.scheduler:step(tick, nil)
  end
  local full = {}
  for _, record in ipairs(h.trace:records()) do
    full[#full + 1] = record
  end

  local h2 = harness()
  startForeground(h2, resource, from)
  for tick = from, saveAt do
    h2.scheduler:step(tick, nil)
  end
  local resumed, recorder = saveAndResume(h2, saveAt)
  for tick = saveAt + 1, to do
    resumed:step(tick, nil)
  end

  local resumedRecords = recorder:records()
  local expectedCount = 0
  for _, record in ipairs(full) do
    if record.tick ~= nil and record.tick > saveAt then
      expectedCount = expectedCount + 1
    end
  end
  Assert.equal(#resumedRecords, expectedCount, "post-restore trace must match the uninterrupted suffix")
  local resumedIndex = 1
  for _, record in ipairs(full) do
    if record.tick ~= nil and record.tick > saveAt then
      local actual = resumedRecords[resumedIndex]
      Assert.equal(actual.kind, record.kind)
      Assert.equal(actual.tick, record.tick)
      for key, value in pairs(record) do
        if key ~= "tick" then
          Assert.equal(actual[key], value, "trace field " .. key .. " diverges")
        end
      end
      resumedIndex = resumedIndex + 1
    end
  end
end

T["current capture omits aggregate fingerprints"] = function()
  local h = harness()
  local h = harness()
  startForeground(
    h,
    script("test.nofp", {
      S.waitTicks({ ticks = 5 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  local bucket = ScriptSave.capture(h.scheduler, 100)
  Assert.equal(bucket.schema, ScriptSave.SCHEMA_NAME)
  Assert.keySet(
    bucket,
    "capturedAtSimulationTick,environments,instances,nextEnvironmentId,nextInstanceId,nextTaskId,schema,tasks"
  )
  Assert.isNil(ScriptSave.validate(bucket, {}))
end

T["predecessor fingerprints never gate restore"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.predfp", {
      S.waitTicks({ ticks = 5 }),
      S.setVar({ variable = "VAR_PRED", value = 1 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  local live = ScriptSave.capture(h.scheduler, 100)
  -- A v1 predecessor carrying fingerprints that disagree with the current
  -- registries migrates by dropping only those fields; the continuation
  -- restores concretely instead of failing an aggregate preflight.
  local predecessor = {}
  for key, value in pairs(live) do
    predecessor[key] = value
  end
  predecessor.schema = "g4-script-save-v1"
  predecessor.registryFingerprint = "stale-registry"
  predecessor.taskFingerprint = "stale-tasks"
  local migrated = ScriptSave.migrateV1(predecessor)
  Assert.equal(migrated.schema, ScriptSave.SCHEMA_NAME)
  Assert.isNil(migrated.registryFingerprint)
  Assert.isNil(migrated.taskFingerprint)
  local resumed = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = h.services,
    taskRegistry = h.taskRegistry,
    resolveComposition = function(id)
      return h.composition:effective(id)
    end,
  })
  ScriptSave.restore(migrated, resumed, 100)
  for tick = 101, 110 do
    resumed:step(tick, nil)
  end
  Assert.equal(h.services.world:getVar("VAR_PRED"), 1, "the migrated continuation runs to completion")
end
-- 1. Deterministic capture: two captures of identical state are deep-equal.
T["deterministic capture"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.cap", {
      S.waitTicks({ ticks = 5 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  h.scheduler:step(101, nil)
  local a = ScriptSave.capture(h.scheduler, 101)
  local b = ScriptSave.capture(h.scheduler, 101)
  Assert.deepEqual(a, b)
  Assert.equal(a.schema, ScriptSave.SCHEMA_NAME)
  Assert.isNil(a.registryFingerprint, "current captures carry no registry fingerprint")
  Assert.isNil(a.taskFingerprint, "current captures carry no task fingerprint")
end

-- 2. Save and resume during an active wait: the countdown continues with no
-- tick duplicated or skipped.
T["resume active wait"] = function()
  local resource = script("test.wait", {
    S.waitTicks({ ticks = 3 }),
    S.setVar({ variable = "VAR_A", value = 1 }),
    S.stop(),
  })
  traceSuffixMatch(resource, 100, 105, 102)
end

-- 3. Save immediately before a task poll: the restored task polls exactly
-- when the uninterrupted one would (first eligible poll).
T["save before poll"] = function()
  local resource = script("test.poll", {
    S.waitTicks({ ticks = 2 }),
    S.setVar({ variable = "VAR_A", value = 1 }),
    S.stop(),
  })
  traceSuffixMatch(resource, 100, 104, 101)
end

-- 4. Save after task completion but before owner continuation: the
-- completed-but-unconsumed task restores as completed and is never polled
-- again; the owner's resume delay survives.
T["save between completion and continuation"] = function()
  local resource = script("test.handoff", {
    S.waitTicks({ ticks = 1 }),
    S.setVar({ variable = "VAR_A", value = 1 }),
    S.stop(),
  })
  traceSuffixMatch(resource, 100, 103, 101)
end

-- 5. Save and resume a script with nested local calls: no extra
-- run merely because loading occurred.
T["resume nested local calls"] = function()
  local resource = script("test.nested", {
    S.waitTicks({ ticks = 2 }),
    S.call({ target = "sub" }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
    S.label({ name = "sub" }),
    S.call({ target = "inner" }),
    S.setVar({ variable = "VAR_SUB", value = 1 }),
    S.return_({}),
    S.label({ name = "inner" }),
    S.setVar({ variable = "VAR_INNER", value = 1 }),
    S.return_({}),
  })
  traceSuffixMatch(resource, 100, 108, 103)
end

-- 5b. Save while a callee frame with arguments is blocked: the resumed
-- callee reads and returns its own argument (frame args are serialized).
T["resume blocked callee with arguments"] = function()
  local h = harness()
  local resource = S.script({
    api = 1,
    id = "test.argresume",
    params = { value = "integer" },
    steps = {
      S.call({ target = "waiter", args = { value = 7 } }),
      S.setVar({ variable = "VAR_AFTER", value = S.var("VAR_RESULT") }),
      S.stop(),
      S.label({ name = "waiter" }),
      S.waitTicks({ ticks = 10 }),
      S.setVar({ variable = "VAR_RESULT", value = S.arg("value") }),
      S.return_({ value = S.arg("value") }),
    },
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  h.scheduler:step(101, nil)
  -- The callee frame is live (blocked on wait_ticks) at save time.
  local resumed, recorder = saveAndResume(h, 101)
  for tick = 102, 115 do
    resumed:step(tick, nil)
  end
  Assert.equal(h.services.world:getVar("VAR_RESULT"), 7)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 7, "the resumed callee returns its own serialized argument")
  Assert.notNil(recorder)
end

-- 6. Save and resume a blocked common child context with its caller signal:
-- the child continues, signals, and the parent resumes
-- one tick after the successful poll.
T["resume common child context"] = function()
  local h = harness()
  local common = script("common.greet", {
    S.waitTicks({ ticks = 2 }),
    S.setVar({ variable = "VAR_CHILD", value = 1 }),
    { op = "signal_caller" },
    S.stop(),
  })
  h.registry:installBase(common.id, common, "generated")
  local root = script("test.std", {
    S.callCommon({ target = "common.greet" }),
    S.setVar({ variable = "VAR_PARENT", value = 1 }),
    S.stop(),
  })
  startForeground(h, root, 100)
  h.scheduler:step(100, nil)
  h.scheduler:step(101, nil)
  local resumed, recorder = saveAndResume(h, 101)
  for tick = 102, 107 do
    resumed:step(tick, nil)
  end
  Assert.equal(h.services.world:getVar("VAR_CHILD"), 1)
  Assert.equal(h.services.world:getVar("VAR_PARENT"), 1)
  local expected = {
    "task_polled",
    "task_polled",
    "task_polled",
    "resume_promoted",
    "context_run",
    "context_completed",
    "task_polled",
    "resume_promoted",
    "context_run",
    "context_completed",
    "environment_torn_down",
  }
  local kinds = {}
  for _, record in ipairs(recorder:records()) do
    kinds[#kinds + 1] = record.kind
  end
  Assert.deepEqual(kinds, expected)
end

-- 7. Restore does not poll a completed task twice and does not skip the
-- native-to-bytecode delay: the resumed continuation lands exactly one tick
-- after the poll that completed at save time.
T["no double poll and no skipped delay"] = function()
  local h = harness()
  local resource = script("test.delay", {
    S.waitTicks({ ticks = 1 }),
    S.setVar({ variable = "VAR_A", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  h.scheduler:step(101, nil)
  local resumed, recorder = saveAndResume(h, 101)
  -- The completed task must not be polled again at 102; the owner promotes
  -- and runs exactly at 102.
  resumed:step(102, nil)
  Assert.equal(h.services.world:getVar("VAR_A"), 1)
  local kinds = {}
  for _, record in ipairs(recorder:records()) do
    kinds[#kinds + 1] = record.kind
  end
  Assert.deepEqual(kinds, { "resume_promoted", "context_run", "context_completed", "environment_torn_down" })
end

-- 8. Task version rejection on load.
T["task version rejection"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.version", {
      S.waitTicks({ ticks = 5 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  local bucket = ScriptSave.capture(h.scheduler, 100)
  bucket.tasks[1].taskVersion = 99
  local ok, err = pcall(
    ScriptSave.restore,
    bucket,
    Scheduler.new({
      semantics = require("libs.hgss.src.script.RuntimeValues"),
      services = h.services,
      taskRegistry = h.taskRegistry,
      resolveComposition = function(id)
        return h.composition:effective(id)
      end,
    }),
    100
  )
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err))
  ---@cast err Errors.Error
  Assert.equal(err.code, "SCRIPT_TASK_VERSION_UNSUPPORTED")
end

T["complete validation rejects task state before restore"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.validation", {
      S.waitTicks({ ticks = 5 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  local bucket = ScriptSave.capture(h.scheduler, 100)
  bucket.tasks[1].state.remainingTicks = -1

  local err = ScriptSave.validate(bucket, {
    resolveTask = function(taskType, version)
      return h.taskRegistry:resolve(taskType, version)
    end,
    resolveComposition = function(scriptId)
      return h.composition:effective(scriptId)
    end,
  })
  Assert.isTrue(Errors.is(err))
  local validationError = assert(err)
  Assert.equal(validationError.code, "SCRIPT_TASK_UNSERIALIZABLE")
end

T["complete validation rejects stale frame revision before restore"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.validation_revision", {
      S.waitTicks({ ticks = 5 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  local bucket = ScriptSave.capture(h.scheduler, 100)
  bucket.instances[1].frames[1].graphRevision = "stale-graph"

  local err = ScriptSave.validate(bucket, {
    resolveTask = function(taskType, version)
      return h.taskRegistry:resolve(taskType, version)
    end,
    resolveComposition = function(scriptId)
      return h.composition:effective(scriptId)
    end,
  })
  Assert.isTrue(Errors.is(err))
  local validationError = assert(err)
  Assert.equal(validationError.code, "SCRIPT_SAVE_REVISION_MISMATCH")
end

-- 9. Missing graph revision on load : the runtime does not
-- restart or redirect the active script.
T["missing graph revision"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.rev", {
      S.waitTicks({ ticks = 5 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  local bucket = ScriptSave.capture(h.scheduler, 100)
  bucket.instances[1].frames[1].chainRevision = "deadbeef"
  local ok, err = pcall(
    ScriptSave.restore,
    bucket,
    Scheduler.new({
      semantics = require("libs.hgss.src.script.RuntimeValues"),
      services = h.services,
      taskRegistry = h.taskRegistry,
      resolveComposition = function(id)
        return h.composition:effective(id)
      end,
    }),
    100
  )
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err))
  ---@cast err Errors.Error
  Assert.equal(err.code, "SCRIPT_SAVE_REVISION_MISMATCH")
end

-- 10. Registry content drift outside the saved continuation no longer blocks
-- restore: an unrelated script installed after capture changes the registry
-- without touching the saved frames, and the continuation still resumes.
T["unrelated registry change no longer blocks restore"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.mod", {
      S.waitTicks({ ticks = 5 }),
      S.setVar({ variable = "VAR_MOD", value = 1 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  local bucket = ScriptSave.capture(h.scheduler, 100)
  h.registry:installBase("test.unrelated", script("test.unrelated", { S.stop() }), "generated")
  local resumed = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = h.services,
    taskRegistry = h.taskRegistry,
    resolveComposition = function(id)
      return h.composition:effective(id)
    end,
  })
  ScriptSave.restore(bucket, resumed, 100)
  for tick = 101, 110 do
    resumed:step(tick, nil)
  end
  Assert.equal(h.services.world:getVar("VAR_MOD"), 1, "the continuation resumes despite registry drift")
end

-- 10b. The task-registry fingerprint is order-independent: registering the
-- same (type, version) pairs in a different order yields the same digest.
T["task fingerprint ignores registration order"] = function()
  local a = TaskRegistry.new()
  local b = TaskRegistry.new()
  a:register("wait_ticks", 1, WaitTicksTask)
  a:register("child_script", 1, ChildScriptTask)
  b:register("child_script", 1, ChildScriptTask)
  b:register("wait_ticks", 1, WaitTicksTask)
  Assert.equal(a:fingerprint(), b:fingerprint())
end

-- 10c. A snapshot-restored fingerprint memo is reused verbatim and is
-- invalidated by any later mutation, so save validation still sees the
-- recomputed digest after a change.
T["restored fingerprint memo is reused and invalidated on mutation"] = function()
  local h = harness()
  h.registry:installBase("test.memo", script("test.memo", { S.stop() }), "generated")
  local computed = h.registry:fingerprint()
  h.registry:restoreFingerprint(computed)
  Assert.equal(h.registry:fingerprint(), computed, "the restored memo is reused verbatim")
  h.registry:installBase("test.memo2", script("test.memo2", { S.stop() }), "generated")
  Assert.isTrue(h.registry:fingerprint() ~= computed, "a later mutation invalidates the restored memo")
end

-- 11. Capture refuses a running context: saves occur only at fixed-tick
-- phase boundaries.
T["capture requires phase boundary"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.boundary", {
      S.setVar({ variable = "VAR_A", value = 1 }),
      S.stop(),
    }),
    100
  )
  local instance = h.scheduler:instances()[1]
  instance.status = "running"
  local ok = pcall(ScriptSave.capture, h.scheduler, 100)
  Assert.isFalse(ok)
end

-- 14. The resumed trace suffix equals the uninterrupted suffix for a longer
-- script combining waits, calls, and branches.
T["trace suffix determinism"] = function()
  local resource = script("test.suffix", {
    S.setVar({ variable = "VAR_A", value = 1 }),
    S.waitTicks({ ticks = 2 }),
    S.call({ target = "sub" }),
    S.if_({
      condition = S.eq(S.var("VAR_A"), 1),
      yes = { S.setFlag({ flag = "FLAG_YES" }), S.stop() },
      no = { S.setFlag({ flag = "FLAG_NO" }), S.stop() },
    }),
    S.label({ name = "sub" }),
    S.waitTicks({ ticks = 1 }),
    S.setVar({ variable = "VAR_SUB", value = 1 }),
    S.return_({}),
  })
  traceSuffixMatch(resource, 100, 110, 104)
end

-- 3q. A save taken after a cross-script jump pins the target script's frame
-- identity: the resumed scheduler continues on the target graph and the
-- trace suffix matches the uninterrupted run.
T["cross-script jump saves and resumes"] = function()
  local h = harness()
  h.registry:installBase(
    "test.tail",
    script("test.tail", {
      S.label({ name = "_0050" }),
      S.setFlag({ flag = "FLAG_TAIL" }),
      S.waitTicks({ ticks = 1 }),
      S.setVar({ variable = "VAR_TAIL_DONE", value = 1 }),
      S.stop(),
    }),
    "generated"
  )
  local jumper = script("test.jumper", {
    S.gotoScript({ script = "test.tail", label = "_0050" }),
    S.setVar({ variable = "VAR_NEVER", value = 1 }),
    S.stop(),
  })
  startForeground(h, jumper, 100)
  h.scheduler:step(100, nil)
  Assert.isTrue(h.services.world:isFlagSet("FLAG_TAIL"))

  local resumed, recorder = saveAndResume(h, 100)
  resumed:step(101, nil)
  Assert.equal(h.services.world:getVar("VAR_TAIL_DONE"), 0, "successful poll must not continue same tick")
  resumed:step(102, nil)
  Assert.equal(h.services.world:getVar("VAR_TAIL_DONE"), 1)
  Assert.equal(h.services.world:getVar("VAR_NEVER"), 0)
  Assert.isTrue(#recorder:records() > 0)
end

-- 3r. A save pinned to a superseded cross-script target revision is
-- rejected.
T["cross-script jump pins the target revision"] = function()
  local h = harness()
  h.registry:installBase(
    "test.tail",
    script("test.tail", {
      S.label({ name = "_0050" }),
      S.waitTicks({ ticks = 1 }),
      S.setVar({ variable = "VAR_TAIL_DONE", value = 1 }),
      S.stop(),
    }),
    "generated"
  )
  local jumper = script("test.jumper", {
    S.gotoScript({ script = "test.tail", label = "_0050" }),
    S.stop(),
  })
  startForeground(h, jumper, 100)
  h.scheduler:step(100, nil)
  local bucket = ScriptSave.capture(h.scheduler, 100)

  -- Replace the target script and restore: the pinned revision is gone.
  -- An override-layer install bumps the registry version exactly like any
  -- other load-time mutation, so the pinned composition revision no longer
  -- matches.
  h.registry:installBase(
    "test.tail",
    script("test.tail", {
      S.label({ name = "_0050" }),
      S.setVar({ variable = "VAR_REPLACED", value = 2 }),
      S.stop(),
    }),
    "override"
  )
  local scheduler = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = h.services,
    taskRegistry = h.taskRegistry,
    resolveComposition = function(id)
      return h.composition:effective(id)
    end,
  })
  local ok, err = pcall(
    ScriptSave.restore,
bucket, scheduler,
    100)
  Assert.isFalse(ok)
  ---@cast err Errors.Error
  Assert.equal(err.code, "SCRIPT_SAVE_REVISION_MISMATCH")
end

-- 3s. A mirrored countdown variable resumes through a save: the task state
-- keeps the variable identity and the world store keeps the value, so the
-- restored task keeps decrementing in lockstep.
T["countdown mirror saves and resumes"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.mirror", {
      S.waitTicks({ ticks = 3, countdownVariable = "VAR_COUNTDOWN" }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  h.scheduler:step(101, nil)
  Assert.equal(h.services.world:getVar("VAR_COUNTDOWN"), 2)
  local resumed = saveAndResume(h, 101)
  resumed:step(102, nil)
  Assert.equal(h.services.world:getVar("VAR_COUNTDOWN"), 1)
  resumed:step(103, nil)
  Assert.equal(h.services.world:getVar("VAR_COUNTDOWN"), 0)
end

-- The production load boundary is a fresh boot: FieldRuntime restores a save
-- at simulation tick 0, while capture happens at a nonzero session tick. A
-- mid-wait save therefore holds a task created at a nonzero tick whose poll
-- deadline is a relative delay; restoring it must rebase the creation tick
-- together with the deadline, or the creation invariant ("a task never polls
-- in its creation tick") fails and the save cannot load.
T["mid-script save restores at the production load tick"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.restore0", {
      S.waitTicks({ ticks = 3 }),
      S.setVar({ variable = "VAR_A", value = 1 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  local bucket = ScriptSave.capture(h.scheduler, 100)
  Assert.isTrue(#bucket.tasks >= 1, "a mid-wait save holds a live task record")

  local resumed = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = h.services,
    taskRegistry = h.taskRegistry,
    resolveComposition = function(id)
      return h.composition:effective(id)
    end,
  })
  local ok, err = pcall(ScriptSave.restore, bucket, resumed, 0)
  Assert.isTrue(ok, "a mid-script save must restore into a fresh boot: " .. tostring(err))
  for tick = 1, 4 do
    resumed:step(tick, nil)
  end
  Assert.equal(h.services.world:getVar("VAR_A"), 1, "the resumed wait completes at the rebased tick")
end

-- The save-stability policy evidence: a save taken while a script waits on
-- transient audio (an awaited SE, then a music fade) restores into a fresh
-- boot whose audio service is empty. The persisted wait tasks poll the
-- fresh service, report completion immediately, and the script continues
-- exactly once -- no deadlock, no re-run, no fault -- so transient audio is
-- intentionally discarded on load and never needs to block capture.
T["mid-audio-wait saves resume against a fresh audio service"] = function()
  local SoundWaitTask = require("libs.hgss.src.script.tasks.SoundWaitTask")
  local MusicFadeTask = require("libs.hgss.src.script.tasks.MusicFadeTask")
  local freshAudio = function()
    return {
      playing = {},
      fadeActive = false,
      play = function(self, id)
        self.playing[id] = true
      end,
      isEffectPlaying = function(self, id)
        return self.playing[id] == true
      end,
      isEffectWaitComplete = function(self, id)
        return self.playing[id] ~= true
      end,
      fadeMusicOut = function(self)
        self.fadeActive = true
      end,
      isMusicFadeActive = function(self)
        return self.fadeActive
      end,
    }
  end
  local h = harness()
  h.taskRegistry:register(SoundWaitTask.type, SoundWaitTask.version, SoundWaitTask --[[@as TaskImplementation]])
  h.taskRegistry:register(MusicFadeTask.type, MusicFadeTask.version, MusicFadeTask --[[@as TaskImplementation]])
  h.services.audio = freshAudio()
  local resource = script("test.audiowait", {
    S.playSound({ sound = "SEQ_SE_DP_SELECT" }),
    S.waitSound({ sound = "SEQ_SE_DP_SELECT" }),
    S.fadeMusicOut({ target = 0, durationTicks = 5 }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  local instanceId = startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  h.scheduler:step(101, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "the script is mid-wait on the effect at save time")

  -- Resume 1: a fresh boot with an empty audio service. The awaited-SE task
  -- completes on its first eligible poll and the script continues.
  h.services.audio = freshAudio()
  local resumed = saveAndResume(h, 101)
  resumed:step(102, nil)
  resumed:step(103, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "the resumed script is blocked on its music fade")
  Assert.isTrue(h.services.audio.fadeActive, "the resumed script starts its fade against the fresh service")

  -- Resume 2: another fresh boot mid-fade-wait. The fade task completes on
  -- the empty service and the script continuation runs exactly once.
  h.services.audio = freshAudio()
  local resumed2 = saveAndResume(h, 104, resumed)
  resumed2:step(105, nil)
  resumed2:step(106, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1, "the resumed script completes its continuation once")
  Assert.isNil(h.services.events:eventFor("script.error", instanceId), "no wait faults on a fresh audio service")
end

-- The record-level counterpart of the production-load-tick test: capture
-- stores the creation tick as a relative offset (mirroring the poll
-- deadline), and restore rebases both from the load tick. A task captured at
-- its creation tick carries offset 0; a task captured mid-wait carries a
-- negative offset, and the restored poll/creation ordering still satisfies
-- the creation invariant.
T["task records rebase the creation tick with the poll deadline"] = function()
  local function makeTask(createdAtTick, pollAtTick)
    return ScriptTask.new({
      taskId = "t1",
      taskType = "wait_ticks",
      taskVersion = 1,
      ownerInstanceId = "i1",
      environmentId = "e1",
      createdAtTick = createdAtTick,
      pollAtTick = pollAtTick,
      state = {},
    })
  end

  local createdThisTick = makeTask(100, 101):capture(100)
  Assert.equal(createdThisTick.createdAtInTicks, 0)
  Assert.equal(createdThisTick.pollInTicks, 1)
  local restoredAtLoad = ScriptTask.restore(createdThisTick, 0)
  Assert.equal(restoredAtLoad.createdAtTick, 0)
  Assert.equal(restoredAtLoad.pollAtTick, 1)

  local midWait = makeTask(100, 101):capture(102)
  Assert.equal(midWait.createdAtInTicks, -2)
  Assert.equal(midWait.pollInTicks, 0)
  local restoredMidWait = ScriptTask.restore(midWait, 0)
  Assert.equal(restoredMidWait.createdAtTick, -2)
  Assert.equal(restoredMidWait.pollAtTick, 0)
  Assert.equal(restoredMidWait.pollAtTick >= restoredMidWait.createdAtTick + 1, true)
end

-- A task record without the creation offset (an older save shape) still
-- restores: the load tick is the creation-tick fallback, and the poll
-- deadline rebases exactly as before.
T["task records without a creation offset restore at the load boundary"] = function()
  local record = {
    taskId = "t1",
    taskType = "wait_ticks",
    taskVersion = 1,
    ownerInstanceId = "i1",
    environmentId = "e1",
    createdAtTick = 100,
    pollInTicks = 1,
    status = "active",
    state = {},
  }
  local restored = ScriptTask.restore(record, 0)
  Assert.equal(restored.createdAtTick, 0)
  Assert.equal(restored.pollAtTick, 1)
end

-- A corrupted creation offset is malformed data, not a plausible default:
-- the record-level validation rejects it before any restore arithmetic runs.
T["task records with a non-number creation offset are rejected"] = function()
  local record = {
    taskId = "t1",
    taskType = "wait_ticks",
    taskVersion = 1,
    ownerInstanceId = "i1",
    environmentId = "e1",
    createdAtInTicks = "3",
    pollInTicks = 1,
    status = "active",
    state = {},
  }
  local err = ScriptTask.validateRecord(record)
  Assert.isTrue(err ~= nil and err.code == "SCRIPT_TASK_UNSERIALIZABLE", "rejects a non-number creation offset")
end

-- The instance record carries the same relative creation offset, so a
-- restored instance's creation tick is rebased together with its ready
-- deadline instead of reading as a pre-restart absolute tick.
T["instance records rebase the creation tick with the ready deadline"] = function()
  local graph = { scriptId = "test.inst", revision = "r1" }
  local instance = ScriptInstance.new({
    instanceId = "i1",
    environmentId = "e1",
    contextSlot = 0,
    scriptId = "test.inst",
    revision = "r1",
    owner = {},
    mode = "foreground",
    createdAtTick = 100,
    readyAtTick = 100,
  })
  instance:pushFrame(instance:makeFrame(graph, "node1"))
  local record = instance:capture(101)
  Assert.equal(record.createdAtInTicks, -1)
  local restored = ScriptInstance.restore(record, 0, { r1 = graph })
  Assert.equal(restored.createdAtTick, -1)
  Assert.equal(restored.readyAtTick, 0)
end

-- The environment record carries the same relative creation offset, so a
-- restored environment's creation tick is rebased from the load tick instead
-- of reading as a pre-restart absolute tick. An environment captured at its
-- creation tick carries offset 0, restoring exactly at the load boundary;
-- restoring at the capture tick is the identity.
T["environment records rebase the creation tick"] = function()
  local createdThisTick = ScriptEnvironment.new({
    environmentId = "e1",
    mode = "foreground",
    createdAtTick = 100,
  }):capture(100)
  Assert.equal(createdThisTick.createdAtInTicks, 0)
  Assert.equal(createdThisTick.createdAtTick, 100, "the absolute tick stays as a diagnostic")
  local restoredAtLoad = ScriptEnvironment.restore(createdThisTick, 0)
  Assert.equal(restoredAtLoad.createdAtTick, 0)
  local restoredIdentity = ScriptEnvironment.restore(createdThisTick, 100)
  Assert.equal(restoredIdentity.createdAtTick, 100)

  local midSim = ScriptEnvironment.new({
    environmentId = "e2",
    mode = "background",
    createdAtTick = 100,
  }):capture(102)
  Assert.equal(midSim.createdAtInTicks, -2)
  local restoredMidSim = ScriptEnvironment.restore(midSim, 0)
  Assert.equal(restoredMidSim.createdAtTick, -2)
end

-- An environment record without the creation offset (an older save shape)
-- still restores: the load tick is the creation-tick fallback.
T["environment records without a creation offset restore at the load boundary"] = function()
  local record = {
    environmentId = "e1",
    mode = "foreground",
    createdAtTick = 100,
  }
  local restored = ScriptEnvironment.restore(record, 0)
  Assert.equal(restored.createdAtTick, 0)
end

-- Bucket validation is the complete load boundary. Beyond the
-- envelope and task records, the id counters, environment
-- records, instance records, and cross-record references must be validated
-- before any live scheduler state is constructed; a malformed record is a
-- load error, never a partial install.

local function expectValidationError(err, context)
  Assert.isTrue(
    err ~= nil and err.code == "SCRIPT_TASK_UNSERIALIZABLE",
    "expected "
      .. context
      .. " to fail validation with SCRIPT_TASK_UNSERIALIZABLE, got "
      .. tostring(err and err.code or err)
  )
end

local function freshScheduler(h)
  return Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = h.services,
    taskRegistry = h.taskRegistry,
    resolveComposition = function(id)
      return h.composition:effective(id)
    end,
  })
end

-- Capture a valid live bucket and run one corruption through the whole-bucket
-- validation.
---@param mutate fun(bucket: table)
---@param context string
local function expectCorruptBucketErrorWhole(mutate, context)
  local h = harness()
  startForeground(
    h,
    script("test.refs", {
      S.waitTicks({ ticks = 1 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  local bucket = ScriptSave.capture(h.scheduler, 100)
  mutate(bucket)
  expectValidationError(ScriptSave.validate(bucket, {}), context)
end

-- Representative malformed record shapes fail whole-bucket validation: a bad
-- id counter, an unknown mode, an out-of-range slot, a missing identity, a
-- malformed frame, a missing task environment, an unknown task status, and a
-- missing record array are all load errors, never implicit defaults.
T["validate rejects malformed record shapes"] = function()
  local cases = {
    {
      context = "a non-integer id counter",
      mutate = function(bucket)
        bucket.nextInstanceId = "3"
      end,
    },
    {
      context = "an environment record with an unknown mode",
      mutate = function(bucket)
        bucket.environments[1].mode = "banana"
      end,
    },
    {
      context = "an instance record with an out-of-range context slot",
      mutate = function(bucket)
        bucket.instances[1].contextSlot = 7
      end,
    },
    {
      context = "an instance record without a script identity",
      mutate = function(bucket)
        bucket.instances[1].scriptId = nil
      end,
    },
    {
      context = "an instance record with a malformed frame composition",
      mutate = function(bucket)
        bucket.instances[1].frames[1].composition = nil
      end,
    },
    {
      context = "a task record without an environment",
      mutate = function(bucket)
        bucket.tasks[1].environmentId = nil
      end,
    },
    {
      context = "a task record with an unknown status",
      mutate = function(bucket)
        bucket.tasks[1].status = "banana"
      end,
    },
    {
      context = "a bucket without tasks",
      mutate = function(bucket)
        bucket.tasks = nil
      end,
    },
  }
  for _, case in ipairs(cases) do
    expectCorruptBucketErrorWhole(case.mutate, case.context)
  end
end

-- Representative dangling and duplicate relationships fail whole-bucket
-- validation instead of restoring corrupted live state.
T["validate rejects dangling and duplicate relationships"] = function()
  local cases = {
    {
      context = "an instance referencing a missing environment",
      mutate = function(bucket)
        bucket.instances[1].environmentId = "e-missing"
      end,
    },
    {
      context = "a task referencing a missing owner instance",
      mutate = function(bucket)
        bucket.tasks[1].ownerInstanceId = "i-missing"
      end,
    },
    {
      context = "a task referencing a missing environment",
      mutate = function(bucket)
        bucket.tasks[1].environmentId = "e-missing"
      end,
    },
    {
      context = "an environment root referencing a missing instance",
      mutate = function(bucket)
        bucket.environments[1].rootInstanceId = "i-missing"
      end,
    },
    {
      context = "an environment context slot referencing a missing instance",
      mutate = function(bucket)
        bucket.environments[1].contextSlots[0] = "i-missing"
      end,
    },
    {
      context = "an environment lock referencing a missing owner",
      mutate = function(bucket)
        bucket.environments[1].locks = { player = { count = 1, owners = { ["i-missing"] = 1 } } }
      end,
    },
    {
      context = "an environment movement generation referencing a missing task",
      mutate = function(bucket)
        bucket.environments[1].movementTasksByGeneration[0]["t-missing"] = true
      end,
    },
    {
      context = "an instance referencing a missing task",
      mutate = function(bucket)
        bucket.instances[1].waitingTaskId = "t-missing"
      end,
    },
    {
      context = "a duplicate environment id",
      mutate = function(bucket)
        bucket.environments[#bucket.environments + 1] = {
          environmentId = bucket.environments[1].environmentId,
          mode = "background",
        }
      end,
    },
    {
      context = "a second foreground environment",
      mutate = function(bucket)
        bucket.environments[#bucket.environments + 1] = {
          environmentId = "e-extra",
          mode = "foreground",
          createdAtInTicks = 0,
        }
      end,
    },
  }
  for _, case in ipairs(cases) do
    expectCorruptBucketErrorWhole(case.mutate, case.context)
  end
end
-- Deep copy of plain save-bucket data for input-unchanged snapshots and
-- independent corruptions. Buckets hold only nested tables and scalars.
---@param value unknown
---@return unknown
local function deepCopyBucket(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, entry in pairs(value) do
    out[deepCopyBucket(key)] = deepCopyBucket(entry)
  end
  return out
end

-- A failed restore must install no partial objects and advance no id
-- counter.
---@param scheduler Scheduler
---@param context string
local function assertSchedulerEmpty(scheduler, context)
  Assert.equal(#scheduler:environments(), 0, context .. " installs no environment")
  Assert.isNil(scheduler:foregroundEnvironmentId(), context .. " installs no foreground")
  Assert.equal(#scheduler:liveInstances(), 0, context .. " installs no instance")
  Assert.equal(#scheduler:tasks(), 0, context .. " installs no task")
  local counters = scheduler:counters()
  Assert.equal(counters.nextEnvironmentId, 0, context .. " advances no environment counter")
  Assert.equal(counters.nextInstanceId, 0, context .. " advances no instance counter")
  Assert.equal(counters.nextTaskId, 0, context .. " advances no task counter")
end

-- A valid captured save covers the supported optional states at once: a
-- suspended caller below a blocked callee, absent optional environment
-- collections, and a completed-but-unconsumed task. Each invalid graph
-- (duplicate ids, dangling references, a second foreground environment) is
-- rejected with the existing load-error category, and validation never
-- mutates its input.
T["valid save with suspended caller and minimal optional fields passes validation without mutating input"] = function()
  local h = harness()
  local resource = script("test.suspended_valid", {
    S.waitTicks({ ticks = 2 }),
    S.call({ target = "sub" }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
    S.label({ name = "sub" }),
    S.waitTicks({ ticks = 10 }),
    S.setVar({ variable = "VAR_SUB", value = 1 }),
    S.return_({}),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  h.scheduler:step(101, nil)
  h.scheduler:step(102, nil)
  h.scheduler:step(103, nil)
  local bucket = ScriptSave.capture(h.scheduler, 103)
  local suspended = false
  for _, record in ipairs(bucket.instances) do
    if #record.frames > 1 then
      suspended = true
    end
  end
  Assert.isTrue(suspended, "capture must hold a suspended caller below the blocked callee")
  for _, record in ipairs(bucket.environments) do
    record.callerSignals = nil
    record.locks = nil
    record.movementTasksByGeneration = nil
    record.createdAtInTicks = nil
  end
  Assert.isNil(ScriptSave.validate(bucket, {}), "absent optional collections must stay valid")

  local handoff = harness()
  startForeground(
    handoff,
    script("test.handoff_valid", {
      S.waitTicks({ ticks = 1 }),
      S.setVar({ variable = "VAR_A", value = 1 }),
      S.stop(),
    }),
    100
  )
  handoff.scheduler:step(100, nil)
  handoff.scheduler:step(101, nil)
  local completedBucket =
    ScriptSave.capture(handoff.scheduler, 101)
  local completed = false
  for _, record in ipairs(completedBucket.tasks) do
    if record.status == "completed" then
      completed = true
    end
  end
  Assert.isTrue(completed, "capture must hold the completed-but-unconsumed task")
  Assert.isNil(ScriptSave.validate(completedBucket, {}), "a completed-but-unconsumed task must stay valid")

  local snapshot = deepCopyBucket(bucket)
  Assert.isNil(ScriptSave.validate(bucket, {}))
  Assert.deepEqual(bucket, snapshot, "validation must leave its input unchanged")

  local duplicate = deepCopyBucket(bucket)
  duplicate.environments[#duplicate.environments + 1] = {
    environmentId = duplicate.environments[1].environmentId,
    mode = "background",
  }
  expectValidationError(ScriptSave.validate(duplicate, {}), "a duplicate environment id")
  local dangling = deepCopyBucket(bucket)
  dangling.instances[1].environmentId = "e-missing"
  expectValidationError(ScriptSave.validate(dangling, {}), "an instance referencing a missing environment")
  local secondForeground = deepCopyBucket(bucket)
  secondForeground.environments[#secondForeground.environments + 1] = {
    environmentId = "e-extra",
    mode = "foreground",
    createdAtInTicks = 0,
  }
  expectValidationError(ScriptSave.validate(secondForeground, {}), "a second foreground environment")
end

-- Task/composition resolvers keep their order and failure identity: task
-- resolution runs before composition resolution with the recorded
-- arguments, a resolver-returned error object is returned unchanged, a
-- resolver or implementation throw escapes unchanged, and a structurally
-- invalid bucket never reaches a resolver.
T["task and composition resolvers keep order and failure identity"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.resolver_order", {
      S.waitTicks({ ticks = 5 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  local bucket = ScriptSave.capture(h.scheduler, 100)

  local calls = {}
  Assert.isNil(ScriptSave.validate(bucket, {
    resolveTask = function(taskType, version)
      calls[#calls + 1] = { kind = "task", taskType, version }
      return h.taskRegistry:resolve(taskType, version)
    end,
    resolveComposition = function(scriptId)
      calls[#calls + 1] = { kind = "composition", scriptId }
      return h.composition:effective(scriptId)
    end,
  }))
  Assert.equal(#calls, 2, "one task and one composition resolution")
  Assert.equal(calls[1].kind, "task", "task resolution runs first")
  Assert.equal(calls[1][1], bucket.tasks[1].taskType)
  Assert.equal(calls[1][2], bucket.tasks[1].taskVersion)
  Assert.equal(calls[2].kind, "composition", "composition resolution runs after tasks")
  Assert.equal(calls[2][1], bucket.instances[1].frames[1].chainScriptId)

  local unavailable = Errors.new("SCRIPT_TASK_VERSION_UNSUPPORTED", "custom unavailable", {})
  local returned = ScriptSave.validate(bucket, {
    resolveTask = function()
      return nil, unavailable
    end,
  })
  Assert.isTrue(returned == unavailable, "a resolver-returned error object must be returned unchanged")

  local stateFailure = Errors.new("SCRIPT_TASK_UNSERIALIZABLE", "custom state rejected", {})
  local stateReturned = ScriptSave.validate(bucket, {
    resolveTask = function()
      return {
        validate = function()
          return stateFailure
        end,
      }
    end,
  })
  Assert.isTrue(stateReturned == stateFailure, "an implementation state error must be returned unchanged")

  local taskSentinel = {}
  local taskOk, taskThrown = pcall(ScriptSave.validate, bucket, {
    resolveTask = function()
      error(taskSentinel)
    end,
  })
  Assert.isFalse(taskOk)
  Assert.isTrue(taskThrown == taskSentinel, "a task resolver throw must escape unchanged")
  local compositionSentinel = {}
  local compositionOk, compositionThrown = pcall(ScriptSave.validate, bucket, {
    resolveTask = function(taskType, version)
      return h.taskRegistry:resolve(taskType, version)
    end,
    resolveComposition = function()
      error(compositionSentinel)
    end,
  })
  Assert.isFalse(compositionOk)
  Assert.isTrue(compositionThrown == compositionSentinel, "a composition resolver throw must escape unchanged")

  local structural = deepCopyBucket(bucket)
  structural.instances[1].environmentId = "e-missing"
  local taskCalls = 0
  local compositionCalls = 0
  local structuralErr = ScriptSave.validate(structural, {
    resolveTask = function(taskType, version)
      taskCalls = taskCalls + 1
      return h.taskRegistry:resolve(taskType, version)
    end,
    resolveComposition = function(scriptId)
      compositionCalls = compositionCalls + 1
      return h.composition:effective(scriptId)
    end,
  })
  expectValidationError(structuralErr, "a structurally invalid bucket")
  Assert.equal(taskCalls, 0, "structural failure must prevent task resolution")
  Assert.equal(compositionCalls, 0, "structural failure must prevent composition resolution")
end

-- Restore stays atomic when a later task or composition check fails, and a
-- valid restore at another tick preserves live task ownership with no
-- early or duplicate poll of the completed task.
T["failed late validation restores nothing, valid restore preserves task ownership and timing"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.atomic_late", {
      S.waitTicks({ ticks = 1 }),
      S.setVar({ variable = "VAR_A", value = 1 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, nil)
  h.scheduler:step(101, nil)
  local bucket = ScriptSave.capture(h.scheduler, 101)
  local ownerInstanceId = bucket.tasks[1].ownerInstanceId

  local badTask = deepCopyBucket(bucket)
  badTask.tasks[1].state.remainingTicks = -1
  local taskScheduler = freshScheduler(h)
  local taskOk, taskErr = pcall(ScriptSave.restore, badTask, taskScheduler, 101)
  Assert.isFalse(taskOk)
  Assert.isTrue(Errors.is(taskErr))
  ---@cast taskErr Errors.Error
  Assert.equal(taskErr.code, "SCRIPT_TASK_UNSERIALIZABLE")
  assertSchedulerEmpty(taskScheduler, "a failed task check")

  local badComposition = deepCopyBucket(bucket)
  badComposition.instances[1].frames[1].graphRevision = "stale-graph"
  local compositionScheduler = freshScheduler(h)
  local compositionOk, compositionErr = pcall(ScriptSave.restore, badComposition, compositionScheduler, 101)
  Assert.isFalse(compositionOk)
  Assert.isTrue(Errors.is(compositionErr))
  ---@cast compositionErr Errors.Error
  Assert.equal(compositionErr.code, "SCRIPT_SAVE_REVISION_MISMATCH")
  assertSchedulerEmpty(compositionScheduler, "a failed composition check")

  local recorder = Diagnostics.newTraceRecorder()
  local resumed = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = h.services,
    taskRegistry = h.taskRegistry,
    trace = function(record)
      recorder:record(record)
    end,
    resolveComposition = function(id)
      return h.composition:effective(id)
    end,
  })
  local restoreOk, restoreErr = pcall(ScriptSave.restore, bucket, resumed, 0)
  Assert.isTrue(restoreOk, "a valid bucket must restore at another tick: " .. tostring(restoreErr))
  Assert.equal(#resumed:tasks(), 1, "the live task must survive the restore")
  Assert.equal(resumed:tasks()[1].ownerInstanceId, ownerInstanceId, "the restored task keeps its owner")
  local ownerLive = false
  for _, instance in ipairs(resumed:liveInstances()) do
    if instance.instanceId == ownerInstanceId then
      ownerLive = true
    end
  end
  Assert.isTrue(ownerLive, "the owning instance must survive the restore")
  resumed:step(1, nil)
  Assert.equal(h.services.world:getVar("VAR_A"), 1, "the restored continuation runs at the rebased tick")
  for _, record in ipairs(recorder:records()) do
    Assert.isTrue(record.kind ~= "task_polled", "the completed task must never be polled again")
  end
end

return { tests = T }
