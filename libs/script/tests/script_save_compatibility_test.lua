-- Paused scripts survive unrelated registry growth while incompatible active
-- state keeps failing closed: a changed graph revision, a removed task type,
-- a changed task version, and corrupt task ownership each reject without
-- installing partial scheduler state.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local ScriptSave = require("libs.script.src.ScriptSave")
local CompatibilityFixture = require("tests.support.script.CompatibilityFixture")

local T = {}

local function rig(extra)
  return CompatibilityFixture.rig(extra)
end

local function pausedBucket(setup)
  return CompatibilityFixture.pausedBucket(setup)
end

local function optionsFor(setup)
  return CompatibilityFixture.optionsFor(setup)
end

local function idleScheduler(setup)
  return CompatibilityFixture.idleScheduler(setup)
end

function T.unrelated_registrations_keep_paused_scripts_loading()
  local setup = rig()
  local bucket = pausedBucket(setup)
  CompatibilityFixture.growWithUnused(setup)
  Assert.isTrue(
    setup.registry:fingerprint() ~= bucket.registryFingerprint,
    "the unused script must move the registry fingerprint"
  )
  Assert.isTrue(
    setup.tasks:fingerprint() ~= bucket.taskFingerprint,
    "the unused task must move the task fingerprint"
  )
  local err = ScriptSave.validate(bucket, optionsFor(setup))
  Assert.isNil(err, "a paused script must survive unrelated registrations")
  local resumed = idleScheduler(setup)
  ScriptSave.restore(bucket, resumed, 100, {
    expectedRegistryFingerprint = setup.registry:fingerprint(),
    expectedTaskFingerprint = setup.tasks:fingerprint(),
  })
  Assert.equal(#resumed:liveInstances(), 1, "the resumed scheduler must carry the paused instance")
  Assert.equal(#resumed:tasks(), 1, "the resumed scheduler must carry the waiting task")
end

function T.changed_graph_revision_rejects_without_partial_state()
  local setup = rig()
  local bucket = pausedBucket(setup)
  bucket.instances[1].frames[1].graphRevision = "stale-graph-revision"
  local err = assert(ScriptSave.validate(bucket, optionsFor(setup)))
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "SCRIPT_SAVE_REVISION_MISMATCH")
  Assert.equal(err.context.scriptId, "probe.main")
  Assert.equal(err.context.revision, "stale-graph-revision")
  local idle = idleScheduler(setup)
  local ok, failure = pcall(ScriptSave.restore, bucket, idle, 100, {})
  Assert.isFalse(ok, "the unknown graph revision must not restore")
  Assert.isTrue(Errors.is(failure))
  Assert.equal(failure.code, "SCRIPT_SAVE_REVISION_MISMATCH")
  Assert.deepEqual(idle:liveInstances(), {}, "a rejected restore must not install instances")
  Assert.equal(#idle:tasks(), 0, "a rejected restore must not install tasks")
end

function T.removed_task_type_rejects_without_partial_state()
  local setup = rig()
  local bucket = pausedBucket(setup)
  local missing = rig({ dropWaitTicks = true })
  local removed = CompatibilityFixture.mainScript()
  missing.registry:installBase(removed.id, removed, "generated")
  -- The task resolvers decide beneath the provenance gate: no expected
  -- fingerprints, so the missing implementation itself must fail the load.
  local err = assert(ScriptSave.validate(bucket, {
    resolveTask = function(taskType, version)
      return missing.tasks:resolve(taskType, version)
    end,
    resolveComposition = function(scriptId)
      return missing.composition:effective(scriptId)
    end,
  }))
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "SCRIPT_TASK_VERSION_UNSUPPORTED")
  Assert.equal(err.context.taskType, "wait_ticks")
  local idle = idleScheduler(missing)
  local ok, failure = pcall(ScriptSave.restore, bucket, idle, 100, {})
  Assert.isFalse(ok, "the removed task type must not restore")
  Assert.isTrue(Errors.is(failure))
  Assert.deepEqual(idle:liveInstances(), {}, "a rejected restore must not install instances")
  Assert.equal(#idle:tasks(), 0, "a rejected restore must not install tasks")
end

function T.changed_task_version_rejects_without_partial_state()
  local setup = rig()
  local bucket = pausedBucket(setup)
  local moved = rig({ waitTicksVersion = 2 })
  local movedScript = CompatibilityFixture.mainScript()
  moved.registry:installBase(movedScript.id, movedScript, "generated")
  -- As above, the resolvers decide beneath the provenance gate.
  local err = assert(ScriptSave.validate(bucket, {
    resolveTask = function(taskType, version)
      return moved.tasks:resolve(taskType, version)
    end,
    resolveComposition = function(scriptId)
      return moved.composition:effective(scriptId)
    end,
  }))
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "SCRIPT_TASK_VERSION_UNSUPPORTED")
  Assert.equal(err.context.taskType, "wait_ticks")
  Assert.equal(err.context.version, 1)
  local idle = idleScheduler(moved)
  local ok, failure = pcall(ScriptSave.restore, bucket, idle, 100, {})
  Assert.isFalse(ok, "the changed task version must not restore")
  Assert.isTrue(Errors.is(failure))
  Assert.deepEqual(idle:liveInstances(), {}, "a rejected restore must not install instances")
  Assert.equal(#idle:tasks(), 0, "a rejected restore must not install tasks")
end

function T.corrupt_task_ownership_rejects_without_partial_state()
  local setup = rig()
  local bucket = pausedBucket(setup)
  bucket.tasks[1].ownerInstanceId = "ghost-owner"
  local err = assert(ScriptSave.validate(bucket, optionsFor(setup)))
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "SCRIPT_TASK_UNSERIALIZABLE")
  Assert.equal(err.context.ownerInstanceId, "ghost-owner")
  local idle = idleScheduler(setup)
  local ok, failure = pcall(ScriptSave.restore, bucket, idle, 100, {})
  Assert.isFalse(ok, "the corrupt task ownership must not restore")
  Assert.isTrue(Errors.is(failure))
  Assert.equal(failure.code, "SCRIPT_TASK_UNSERIALIZABLE")
  Assert.deepEqual(idle:liveInstances(), {}, "a rejected restore must not install instances")
  Assert.equal(#idle:tasks(), 0, "a rejected restore must not install tasks")
end

return { tests = T }
