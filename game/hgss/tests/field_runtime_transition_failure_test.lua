-- FieldRuntime treats a transition preparation failure as a terminal
-- presentation state. The first failing update promotes the transition
-- error after completing that tick; later updates do no simulation work
-- until the owning game flow boots a fresh runtime. There is no registry
-- warm-up slice: script readiness comes from published hashes, not a
-- background corpus pass.

local Assert = require("tests.support.Assert")
local S = require("gen4.script")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldState = require("game.hgss.src.field.FieldState")
local Registry = require("libs.script.src.Registry")
local ScriptComposition = require("libs.script.src.Composition")
local Scheduler = require("libs.script.src.Scheduler")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local HgssScriptComposition = require("libs.hgss.src.script.Composition")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

local T = {}

local function runtimeWithTransitionError(transitionError)
  local calls = { session = 0 }
  local runtime = setmetatable({
    scripts = {},
    session = {
      accumulator = 0,
      setBattleActive = function() end,
      updateFixed = function()
        calls.session = calls.session + 1
      end,
    },
    transition = {
      error = transitionError,
      phase = "idle",
      updateSourceFrame = function() end,
      warpContext = {
        sourceMapId = 61,
        sourceWarpId = 0,
        destinationMapId = 60,
        destinationWarpId = 0,
      },
      consumeCompleted = function()
        return nil
      end,
    },
    screenFade = {
      fadeDone = function()
        return true
      end,
      updateSourceFrame = function() end,
    },
    applicationHost = {
      error = function()
        return nil
      end,
    },
  }, FieldRuntime)
  return runtime, calls
end

local function presentationState(runtime)
  local state = setmetatable({
    runtime = runtime,
    presentationResources = {
      preparePcApplication = function()
        return false, "injected"
      end,
    },
    actorPresentation = { sync = function() end },
    _advanceStarterPreparation = function() end,
    _syncStarterPresentationInput = function() end,
    _advanceEntryCover = function() end,
    _sampleOverlayFps = function() end,
  }, FieldState)
  return state
end

function T.transition_failure_propagates_after_the_session_tick()
  local tostringCalls = 0
  local transitionError = setmetatable({}, {
    __tostring = function()
      tostringCalls = tostringCalls + 1
      return "destination preparation failed"
    end,
  })
  local runtime, calls = runtimeWithTransitionError(transitionError)

  local ok, err = pcall(function()
    runtime:update(1 / 30)
  end)
  Assert.isFalse(ok, "transition failures reach LÖVE's callback error handler")
  Assert.equal(tostring(err), "destination preparation failed\nsource map 61 warp 0 -> map 60 warp 0")
  Assert.equal(calls.session, 1, "the failing update completes its session tick")
  Assert.equal(tostringCalls, 1, "the transition failure is formatted once")
end

function T.pc_presentation_failure_cancels_its_script_task_before_freezing_runtime()
  local host = { active = false, cancellations = 0 }
  function host:open(_)
    self.active = true
    return {}
  end
  function host:activeHandle()
    return self.active and {} or nil
  end
  function host:isActive()
    return self.active
  end
  function host:status()
    return {}
  end
  function host:setPresentationReady(_, _)
    return false
  end
  function host:cancel(_)
    self.active = false
    self.cancellations = self.cancellations + 1
  end

  local registry = Registry.new()
  local composition = ScriptComposition.new(registry)
  local taskRegistry = HgssScriptComposition.registerTasks(TaskRegistry.new())
  local scheduler = Scheduler.new({
    semantics = RuntimeValues,
    services = { pcApplications = host },
    taskRegistry = taskRegistry,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  local scriptId = "test.pc_presentation_failure"
  registry:installBase(scriptId, S.script({ api = 1, id = scriptId, steps = { S.pcOpen({ app = "storage", mode = 0 }) } }), "generated")
  local composed = assert(composition:effective(scriptId), "the test script composes")
  scheduler:startInteraction({ type = "test", scriptId = scriptId }, composed, 100, true)
  Assert.isTrue(host.active, "the production PC task opened its child")
  Assert.notNil(scheduler:foregroundEnvironmentId(), "the script owns foreground input")

  local runtime = setmetatable({
    session = { scriptScheduler = scheduler },
    pcApplicationHost = host,
    update = function() end,
    saveCoordinator = {
      capture = function()
        if scheduler:foregroundEnvironmentId() ~= nil then
          return nil, "script active"
        end
        return { stable = true }
      end,
    },
  }, FieldRuntime)
  Assert.isNil(runtime:captureGameSave(), "an active script refuses save capture")
  local ok, failure = pcall(function()
    presentationState(runtime):update(0)
  end)

  Assert.isFalse(host.active, "the task cancellation releases the active child")
  Assert.equal(host.cancellations, 1, "the application child is cancelled exactly once")
  Assert.isNil(scheduler:foregroundEnvironmentId(), "the failed script releases foreground ownership")
  Assert.deepEqual(runtime:captureGameSave(), { stable = true }, "save capture recovers after task cleanup")
  Assert.isFalse(ok, "PC presentation failures reach LÖVE's callback error handler")
  Assert.equal(tostring(failure), "PC application presentation failed: injected")
end

return { tests = T }
