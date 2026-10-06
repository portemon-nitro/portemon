-- Script save and resume : the serializable `scripts`
-- bucket of the g4-field-save-v4 schema. Capture happens only at a fixed-tick
-- phase boundary (no context in `running` status); absolute scheduling ticks
-- become relative delays rebased at restore, so no tick is duplicated or
-- skipped. The bucket carries the id counters plus the environment,
-- instance, and task records; no aggregate registry fingerprint is stored
-- or compared. Restore resolves every saved task implementation and
-- frame revision concretely against the current scheduler, and the
-- scheduler reattaches every frame's graph through current compositions,
-- rejecting unknown revisions (SCRIPT_SAVE_REVISION_MISMATCH). Validation
-- is the complete load boundary: the whole bucket and every cross-record
-- reference are checked before any live scheduler state is constructed,
-- and restore stages every object and installs only after the entire
-- bucket has restored. Input edges are never serialized. Pure domain
-- module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local ScriptTask = require("libs.script.src.ScriptTask")
local ScriptEnvironment = require("libs.script.src.ScriptEnvironment")
local ScriptInstance = require("libs.script.src.ScriptInstance")

local ScriptSave = {}

ScriptSave.SCHEMA_NAME = "g4-script-save-v2"
ScriptSave.LEGACY_SCHEMA_NAME = "g4-script-save-v1"

-- True only when every saved continuation collection exists and is empty.
-- This is a shape query, not validation of the rest of the bucket.
---@param bucket unknown
---@return boolean
function ScriptSave.isQuiescent(bucket)
  return type(bucket) == "table"
    and type(bucket.environments) == "table"
    and next(bucket.environments) == nil
    and type(bucket.instances) == "table"
    and next(bucket.instances) == nil
    and type(bucket.tasks) == "table"
    and next(bucket.tasks) == nil
end

---@param scheduler Scheduler
---@param tick integer
---@return table<string, unknown> bucket
function ScriptSave.capture(scheduler, tick)
  for _, instance in ipairs(scheduler:liveInstances()) do
    assert(
      instance.status ~= ScriptInstance.STATUSES.running,
      "capture requires a fixed-tick phase boundary (no running context)"
    )
  end
  local environments = {}
  for _, environment in ipairs(scheduler:environments()) do
    environments[#environments + 1] = environment:capture(tick)
  end
  local instances = {}
  for _, instance in ipairs(scheduler:liveInstances()) do
    instances[#instances + 1] = instance:capture(tick)
  end
  local tasks = {}
  for _, task in ipairs(scheduler:tasks()) do
    tasks[#tasks + 1] = task:capture(tick)
  end
  local counters = scheduler:counters()
  return {
    schema = ScriptSave.SCHEMA_NAME,
    capturedAtSimulationTick = tick,
    nextEnvironmentId = counters.nextEnvironmentId,
    nextInstanceId = counters.nextInstanceId,
    nextTaskId = counters.nextTaskId,
    environments = environments,
    instances = instances,
    tasks = tasks,
  }
end

local ENVIRONMENT_MODES = { foreground = true, background = true }
local INSTANCE_MODES = { foreground = true, background = true }

-- Structural failures raise SCRIPT_TASK_UNSERIALIZABLE; the single protected
-- boundary in ScriptSave.validate converts them back to the public error
-- result. Anything else escapes unchanged.
---@param message string
---@param context table<string, unknown>
---@noreturn
local function reject(message, context)
  Errors.raise(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, message, context)
end

---@param value unknown
---@return boolean
local function nonNegativeInteger(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0
end

-- Identity fields are nonempty strings. Returns the checked identity so
-- callers register the same value they validated.
---@param value unknown
---@param message string
---@param context table<string, unknown>
---@return string
local function checkIdentity(value, message, context)
  if type(value) ~= "string" or value == "" then
    reject(message, context)
  end
  return value
end

-- Optional scalar offsets stay valid when absent.
---@param value unknown
---@param message string
---@param context table<string, unknown>
local function checkOptionalNumber(value, message, context)
  if value ~= nil and type(value) ~= "number" then
    reject(message, context)
  end
end

-- Register an identity, rejecting the duplicate before it can overwrite a
-- live scheduler entry.
---@param seen table<string, boolean>
---@param id string
---@param message string
---@param context table<string, unknown>
local function registerIdentity(seen, id, message, context)
  if seen[id] then
    reject(message, context)
  end
  seen[id] = true
end

-- Validate one environment record; duplicate ids are rejected and the id is
-- registered. Cross-record references are checked after every record has
-- been seen. Failures raise through the protected boundary in
-- ScriptSave.validate.
---@param record unknown
---@param environmentIds table<string, boolean>
local function validateEnvironmentRecord(record, environmentIds)
  if type(record) ~= "table" then
    reject("environment record must be a table", {})
  end
  local environmentId = checkIdentity(record.environmentId, "environment id missing", {})
  registerIdentity(environmentIds, environmentId, "duplicate environment id", {
    environmentId = environmentId,
  })
  if not ENVIRONMENT_MODES[record.mode] then
    reject("unknown environment mode " .. tostring(record.mode), { environmentId = environmentId, mode = record.mode })
  end
  checkOptionalNumber(record.createdAtInTicks, "environment creation offset invalid", {
    environmentId = environmentId,
  })
  if record.movementGeneration ~= nil and not nonNegativeInteger(record.movementGeneration) then
    reject("environment movement generation invalid", { environmentId = environmentId })
  end
  if record.contextSlots ~= nil then
    if type(record.contextSlots) ~= "table" then
      reject("environment context slots must be a table", { environmentId = environmentId })
    end
    for slot, instanceId in pairs(record.contextSlots) do
      if not nonNegativeInteger(slot) or slot >= ScriptEnvironment.SLOT_COUNT then
        reject("environment context slot out of range", {
          environmentId = environmentId,
          slot = slot,
        })
      end
      if type(instanceId) ~= "string" then
        reject("environment context slot instance id invalid", {
          environmentId = environmentId,
          slot = slot,
        })
      end
    end
  end
  if record.rootInstanceId ~= nil and type(record.rootInstanceId) ~= "string" then
    reject("environment root instance id invalid", { environmentId = environmentId })
  end
  if record.movementTasksByGeneration ~= nil then
    if type(record.movementTasksByGeneration) ~= "table" then
      reject("environment movement tasks must be a table", { environmentId = environmentId })
    end
    for _, tasks in pairs(record.movementTasksByGeneration) do
      if type(tasks) ~= "table" then
        reject("environment movement generation entry must be a table", {
          environmentId = environmentId,
        })
      end
    end
  end
  if record.callerSignals ~= nil and type(record.callerSignals) ~= "table" then
    reject("environment caller signals must be a table", { environmentId = environmentId })
  end
  if record.locks ~= nil then
    if type(record.locks) ~= "table" then
      reject("environment locks must be a table", { environmentId = environmentId })
    end
    for key, entry in pairs(record.locks) do
      if type(entry) ~= "table" or not nonNegativeInteger(entry.count) or type(entry.owners) ~= "table" then
        reject("environment lock entry is malformed", {
          environmentId = environmentId,
          lock = key,
        })
      end
      for ownerId, n in pairs(entry.owners) do
        if type(ownerId) ~= "string" or not nonNegativeInteger(n) then
          reject("environment lock owner is malformed", {
            environmentId = environmentId,
            lock = key,
          })
        end
      end
    end
  end
end

-- Validate one instance record; duplicate ids are rejected and the id is
-- registered. Cross-record references are checked after every record has
-- been seen. Failures raise through the protected boundary in
-- ScriptSave.validate.
---@param record unknown
---@param instanceIds table<string, boolean>
local function validateInstanceRecord(record, instanceIds)
  if type(record) ~= "table" then
    reject("instance record must be a table", {})
  end
  local instanceId = checkIdentity(record.instanceId, "instance id missing", {})
  registerIdentity(instanceIds, instanceId, "duplicate instance id", { instanceId = instanceId })
  checkIdentity(record.environmentId, "instance environment id missing", { instanceId = instanceId })
  if not nonNegativeInteger(record.contextSlot) or record.contextSlot >= ScriptEnvironment.SLOT_COUNT then
    reject("instance context slot out of range", {
      instanceId = instanceId,
      contextSlot = record.contextSlot,
    })
  end
  if not INSTANCE_MODES[record.mode] then
    reject("unknown instance mode " .. tostring(record.mode), { instanceId = instanceId, mode = record.mode })
  end
  checkIdentity(record.scriptId, "instance script identity missing", { instanceId = instanceId })
  if type(record.revision) ~= "string" then
    reject("instance script revision missing", { instanceId = instanceId })
  end
  if not ScriptInstance.STATUSES[record.status] then
    reject("unknown instance status " .. tostring(record.status), { instanceId = instanceId, status = record.status })
  end
  if type(record.frames) ~= "table" then
    reject("instance frames must be a table", { instanceId = instanceId })
  end
  for _, frame in ipairs(record.frames) do
    -- A frame below the top is a suspended caller: its nodeId is nil while
    -- its continuation lives in the callee's returnNodeId, so only a
    -- present nodeId must be a string. The graph revision is the identity
    -- the scheduler reattaches through current compositions, and the
    -- composition entry index is the pre-pass's frame-chain position.
    if
      type(frame) ~= "table"
      or (frame.nodeId ~= nil and type(frame.nodeId) ~= "string")
      or type(frame.chainScriptId) ~= "string"
      or frame.chainScriptId == ""
      or type(frame.chainRevision) ~= "string"
      or type(frame.graphRevision) ~= "string"
      or type(frame.composition) ~= "table"
      or not nonNegativeInteger(frame.composition.entryIndex)
    then
      reject("instance frame record is malformed", { instanceId = instanceId })
    end
  end
  checkOptionalNumber(record.createdAtInTicks, "instance creation offset invalid", { instanceId = instanceId })
  checkOptionalNumber(record.readyInTicks, "instance ready delay invalid", { instanceId = instanceId })
  if record.waitingTaskId ~= nil and type(record.waitingTaskId) ~= "string" then
    reject("instance waiting task id invalid", { instanceId = instanceId })
  end
end

-- The whole-bucket checks: id counters, record shapes with identity
-- registration, then every cross-record reference against the completed id
-- sets. Structural failures raise through the protected boundary in
-- ScriptSave.validate.
---@param bucket table<string, unknown>
local function validateBucket(bucket)
  for _, counter in ipairs({ "nextEnvironmentId", "nextInstanceId", "nextTaskId" }) do
    if not nonNegativeInteger(bucket[counter]) then
      reject("scripts bucket " .. counter .. " must be a non-negative integer", {
        [counter] = bucket[counter],
      })
    end
  end

  if type(bucket.environments) ~= "table" then
    reject("scripts bucket environments must be a table", {})
  end
  local environmentIds = {}
  local foregroundCount = 0
  for _, record in ipairs(bucket.environments) do
    validateEnvironmentRecord(record, environmentIds)
    if record.mode == "foreground" then
      foregroundCount = foregroundCount + 1
    end
  end
  if foregroundCount > 1 then
    reject("scripts bucket has multiple foreground environments", { count = foregroundCount })
  end

  if type(bucket.instances) ~= "table" then
    reject("scripts bucket instances must be a table", {})
  end
  local instanceIds = {}
  for _, record in ipairs(bucket.instances) do
    validateInstanceRecord(record, instanceIds)
  end

  if type(bucket.tasks) ~= "table" then
    reject("scripts bucket tasks must be a table", {})
  end
  local taskIds = {}
  for _, record in ipairs(bucket.tasks) do
    local taskErr = ScriptTask.validateRecord(record)
    if taskErr ~= nil then
      error(taskErr, 0)
    end
    -- validateRecord guarantees a table record with a nonempty taskId here.
    local taskId = record.taskId --[[@as string]]
    registerIdentity(taskIds, taskId, "duplicate task id", { taskId = taskId })
  end

  for _, record in ipairs(bucket.instances) do
    if not environmentIds[record.environmentId] then
      reject("instance references a missing environment", {
        instanceId = record.instanceId,
        environmentId = record.environmentId,
      })
    end
    if record.waitingTaskId ~= nil and not taskIds[record.waitingTaskId] then
      reject("instance references a missing task", {
        instanceId = record.instanceId,
        taskId = record.waitingTaskId,
      })
    end
  end
  for _, record in ipairs(bucket.environments) do
    if record.rootInstanceId ~= nil and not instanceIds[record.rootInstanceId] then
      reject("environment references a missing root instance", {
        environmentId = record.environmentId,
        rootInstanceId = record.rootInstanceId,
      })
    end
    for _, instanceId in pairs(record.contextSlots or {}) do
      if not instanceIds[instanceId] then
        reject("environment context slot references a missing instance", {
          environmentId = record.environmentId,
          instanceId = instanceId,
        })
      end
    end
    for key, entry in pairs(record.locks or {}) do
      for ownerId in pairs(entry.owners or {}) do
        if not instanceIds[ownerId] then
          reject("environment lock references a missing owner", {
            environmentId = record.environmentId,
            lock = key,
            ownerId = ownerId,
          })
        end
      end
    end
    for _, tasks in pairs(record.movementTasksByGeneration or {}) do
      for taskId in pairs(tasks) do
        if not taskIds[taskId] then
          reject("environment movement generation references a missing task", {
            environmentId = record.environmentId,
            taskId = taskId,
          })
        end
      end
    end
  end
  for _, record in ipairs(bucket.tasks) do
    if not instanceIds[record.ownerInstanceId] then
      reject("task references a missing owner instance", {
        taskId = record.taskId,
        ownerInstanceId = record.ownerInstanceId,
      })
    end
    if not environmentIds[record.environmentId] then
      reject("task references a missing environment", {
        taskId = record.taskId,
        environmentId = record.environmentId,
      })
    end
  end
end

-- One protected structural boundary: run the private shape, identity, and
-- reference checks, converting only owned structural failures back to the
-- public error result. Task/composition resolver outcomes and unrelated
-- failures escape unchanged.
---@param validate fun()
---@return Errors.Error|nil
local function adaptStructural(validate)
  local ok, failure = pcall(validate)
  if ok then
    return nil
  end
  if Errors.is(failure) then
    ---@cast failure Errors.Error
    if failure.code == ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE then
      return failure
    end
  end
  error(failure, 0)
end

-- Validate the whole scripts bucket: the envelope, the id counters, every
-- environment/instance/task record, and the cross-record references. Returns
-- nil when valid, else an Errors object. Structural record failures raise
-- inside the protected boundary and are converted back to the error result;
-- the task/composition resolvers below run outside that boundary with their
-- order, arguments, and error identity preserved. Task-record shape
-- validation lives in ScriptTask.validateRecord; restore adds the
-- task-registry resolution and the scheduler adds the graph-revision checks
-- against current compositions.
---@param bucket unknown
---@param opts table<string, unknown>
---@return Errors.Error|nil
function ScriptSave.validate(bucket, opts)
  opts = opts or {}
  if type(bucket) ~= "table" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "scripts bucket must be a table", {})
  end
  if bucket.schema ~= ScriptSave.SCHEMA_NAME then
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "unknown scripts bucket schema " .. tostring(bucket.schema),
      { schema = bucket.schema }
    )
  end
  local structuralErr = adaptStructural(function()
    validateBucket(bucket)
  end)
  if structuralErr ~= nil then
    return structuralErr
  end
  if opts.resolveTask ~= nil then
    for _, taskRecord in ipairs(bucket.tasks) do
      local impl, resolveErr = opts.resolveTask(taskRecord.taskType, taskRecord.taskVersion)
      if impl == nil then
        return resolveErr
          or Errors.new(
            ScriptErrors.SCRIPT_TASK_VERSION_UNSUPPORTED,
            "saved task implementation is unavailable",
            { taskType = taskRecord.taskType, version = taskRecord.taskVersion }
          )
      end
      local stateErr = impl.validate(taskRecord.state)
      if stateErr ~= nil then
        return stateErr
      end
    end
  end
  if opts.resolveComposition ~= nil then
    for _, instanceRecord in ipairs(bucket.instances) do
      for _, frameRecord in ipairs(instanceRecord.frames) do
        local composed = opts.resolveComposition(frameRecord.chainScriptId)
        if composed == nil or composed.revision ~= frameRecord.chainRevision then
          return Errors.new(
            ScriptErrors.SCRIPT_SAVE_REVISION_MISMATCH,
            "save references an unknown composed script revision",
            {
              scriptId = frameRecord.chainScriptId,
              revision = frameRecord.chainRevision,
              composedRevision = composed and composed.revision or nil,
            }
          )
        end
        local entry = composed.entries[frameRecord.composition.entryIndex + 1]
        if entry == nil then
          return Errors.new(
            ScriptErrors.SCRIPT_SAVE_REVISION_MISMATCH,
            "save references an unknown composition entry",
            { scriptId = frameRecord.chainScriptId, entryIndex = frameRecord.composition.entryIndex + 1 }
          )
        end
        if entry.graph.revision ~= frameRecord.graphRevision then
          return Errors.new(
            ScriptErrors.SCRIPT_SAVE_REVISION_MISMATCH,
            "save references an unknown graph revision",
            { scriptId = frameRecord.chainScriptId, revision = frameRecord.graphRevision }
          )
        end
      end
    end
  end
  return nil
end

-- Restore a scripts bucket into an idle scheduler. `restoreTick` is the load
-- boundary: the caller resumes with the first step at restoreTick + 1, so
-- relative delays rebase exactly. The whole bucket is validated first
-- (raising SCRIPT_TASK_UNSERIALIZABLE on malformed records or dangling
-- cross-references), then task types and versions must resolve and each task
-- implementation must accept the serialized state; the scheduler stages
-- every restored object and installs it only after the whole bucket has
-- restored. Raises on unknown task types or versions, invalid task state,
-- or unknown graph revisions. A failure anywhere before publication leaves
-- the scheduler idle.
---@param bucket table<string, unknown>
---@param scheduler Scheduler
---@param restoreTick integer
function ScriptSave.restore(bucket, scheduler, restoreTick)
  local function resolveTask(taskType, version)
    return scheduler:resolveTask(taskType, version)
  end
  local function resolveComposition(scriptId)
    return scheduler:resolveComposition(scriptId)
  end
  local envelopeErr = ScriptSave.validate(bucket, {
    resolveTask = resolveTask,
    resolveComposition = resolveComposition,
  })
  if envelopeErr ~= nil then
    Errors.raise(envelopeErr.code, envelopeErr.message, envelopeErr.context)
  end

  scheduler:restoreScriptState(bucket, restoreTick)
end

-- Pure v1 -> v2 migration: copies capture tick, id counters, and every
-- environment, instance, and task record, and drops only the obsolete
-- registry/task-registry fingerprints. The fingerprint values are never
-- compared: any v1 bucket with usable continuation state migrates.
---@param bucket table<string, unknown> a v1 scripts bucket
---@return table<string, unknown> the fingerprint-free v2 bucket
function ScriptSave.migrateV1(bucket)
  if type(bucket) ~= "table" or bucket.schema ~= ScriptSave.LEGACY_SCHEMA_NAME then
    Errors.raise(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "legacy scripts bucket schema is invalid", {})
  end
  assert(type(bucket) == "table", "legacy scripts migration requires its declared schema")
  local migrated = {}
  for key, value in pairs(bucket) do
    if key ~= "registryFingerprint" and key ~= "taskFingerprint" then
      migrated[key] = value
    end
  end
  migrated.schema = ScriptSave.SCHEMA_NAME
  return migrated
end

return ScriptSave
