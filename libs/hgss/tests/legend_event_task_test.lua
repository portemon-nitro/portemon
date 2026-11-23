-- The blocking legend-scene task: it holds the script while the scene runs,
-- starts the wing effect's map child through the existing common-child
-- mechanism instead of blocking it, and releases a cancelled scene exactly
-- once. Source reference: src/field/script_field_effects.c.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local LegendEventTask = require("libs.hgss.src.script.tasks.LegendEventTask")

local T = {}

local function fakeScene()
  local scene = { began = {}, statuses = {}, childRequests = 0, completed = 0, cancelled = nil }
  function scene:begin(action, operands)
    self.began[#self.began + 1] = { action = action, operands = operands }
  end
  function scene:step()
    return table.remove(self.statuses, 1) or "wait"
  end
  function scene:childScriptId()
    self.childRequests = self.childRequests + 1
    return self.childScriptIdValue
  end
  function scene:childComplete()
    self.childCompleted = (self.childCompleted or 0) + 1
  end
  function scene:takeResult()
    return nil
  end
  function scene:cancel(reason)
    self.cancelled = reason
  end
  return scene
end

local function fakeScheduler()
  local scheduler = { children = {}, created = {}, instances = {} }
  function scheduler:resolveComposition(scriptId)
    return { scriptId = scriptId }
  end
  function scheduler:createCommonChild(composed)
    local child = { instanceId = "child-1", scriptId = composed.scriptId, status = "running" }
    self.children[#self.children + 1] = child
    self.instances[child.instanceId] = child
    return child, 1, 0
  end
  function scheduler:instance(instanceId)
    return self.instances[instanceId]
  end
  return scheduler
end

local function context(scene, scheduler)
  local environment = { signals = {} }
  function environment:callerSignal()
    return self.signals[0] ~= false
  end
  return {
    services = { legendEvents = scene },
    scheduler = scheduler or fakeScheduler(),
    environment = environment,
    instance = { scriptId = "test.legend" },
    tick = 1,
    input = {},
  }
end

function T.the_task_holds_the_script_until_the_scene_completes()
  local scene = fakeScene()
  local ctx = context(scene)
  local state = LegendEventTask.create({ action = "wing", kind = 0 }, ctx)
  Assert.equal(scene.began[1].action, "wing")
  Assert.equal(scene.began[1].operands.kind, 0)
  Assert.isFalse(LegendEventTask.poll(state, ctx).complete, "a waiting scene keeps the script held")
  scene.statuses = { "complete" }
  local result = LegendEventTask.poll(state, ctx)
  Assert.isTrue(result.complete, "the task completes only when the scene returned")
  Assert.equal(state.phase, "complete")
end

function T.the_wing_child_runs_through_the_common_child_mechanism()
  local scene = fakeScene()
  scene.childScriptIdValue = "vanilla.hgss.scr_seq.0019.script_002"
  scene.statuses = { "child" }
  local ctx = context(scene)
  local state = LegendEventTask.create({ action = "wing", kind = 0 }, ctx)
  local result = LegendEventTask.poll(state, ctx)
  Assert.isFalse(result.complete, "the parent keeps waiting while its child runs")
  Assert.equal(#ctx.scheduler.children, 1, "the map child is started through the common-child mechanism")
  Assert.equal(ctx.scheduler.children[1].scriptId, "vanilla.hgss.scr_seq.0019.script_002")
  Assert.equal(state.phase, "child")
  -- The child is still running: the parent must not finish or step the scene.
  scene.statuses = { "complete" }
  Assert.isFalse(LegendEventTask.poll(state, ctx).complete, "the parent never finishes before its child")
  -- The child signals the caller: the scene resumes.
  ctx.environment.signals[0] = false
  local resumed = LegendEventTask.poll(state, ctx)
  Assert.isFalse(resumed.complete, "the parent resumes the scene after the child returned")
  Assert.equal(scene.childCompleted, 1, "the scene learns that its child returned")
  Assert.equal(state.phase, "wait")
  scene.statuses = { "complete" }
  Assert.isTrue(LegendEventTask.poll(state, ctx).complete, "the scene then finishes normally")
end

function T.a_faulted_child_faults_the_parent_scene()
  local scene = fakeScene()
  scene.childScriptIdValue = "vanilla.hgss.scr_seq.0019.script_002"
  scene.statuses = { "child" }
  local ctx = context(scene)
  local state = LegendEventTask.create({ action = "wing", kind = 0 }, ctx)
  LegendEventTask.poll(state, ctx)
  local child = ctx.scheduler.children[1]
  child.status = "faulted"
  child.endReason = "SCRIPT_INVALID_REFERENCE"
  local result = LegendEventTask.poll(state, ctx)
  Assert.isTrue(result.complete)
  Assert.isTrue(Errors.is(result.result.error), "a faulted child surfaces as an attributed parent fault")
end

function T.a_scene_without_a_child_bank_finishes_its_own_loop()
  local scene = fakeScene()
  scene.statuses = { "child", "complete" }
  local ctx = context(scene)
  local state = LegendEventTask.create({ action = "wing", kind = 0 }, ctx)
  LegendEventTask.poll(state, ctx)
  Assert.equal(#ctx.scheduler.children, 0, "an unresolved map bank starts no child")
  Assert.equal(state.phase, "wait")
end

function T.cancelling_the_task_releases_the_scene_exactly_once()
  local scene = fakeScene()
  local ctx = context(scene)
  local state = LegendEventTask.create({ action = "unown_circle" }, ctx)
  LegendEventTask.cancel(state, "cancelled", ctx)
  LegendEventTask.cancel(state, "again", ctx)
  Assert.equal(scene.cancelled, "the legend scene task was cancelled")
  Assert.equal(state.phase, "complete")
end

function T.an_active_scene_task_is_not_serializable()
  local scene = fakeScene()
  local ctx = context(scene)
  local state = LegendEventTask.create({ action = "egg_cutscene", choice = 1 }, ctx)
  local err = LegendEventTask.validate(state)
  Assert.isTrue(Errors.is(err), "a running scene cannot be restored")
  state.phase = "complete"
  Assert.isNil(LegendEventTask.validate(state), "a completed scene task is serializable")
end

return { metadata = {}, tests = T }
