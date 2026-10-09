local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldOverworldLifecycle = require("libs.hgss.src.field.FieldOverworldLifecycle")
local FieldScriptPropAnimations = require("libs.hgss.src.field.FieldScriptPropAnimations")
local OverworldLifecycleTask = require("libs.hgss.src.script.tasks.OverworldLifecycleTask")
local PropAnimationWaitTask = require("libs.hgss.src.script.tasks.PropAnimationWaitTask")

local T = {}

function T.overworld_lifecycle_requires_one_fixed_boundary_per_transition()
  local lifecycle = FieldOverworldLifecycle.new()
  Assert.equal(lifecycle:phase(), "present")
  lifecycle:requestLeave()
  Assert.equal(lifecycle:phase(), "leaving")
  lifecycle:updateFixed()
  Assert.equal(lifecycle:phase(), "absent")
  lifecycle:requestRestore()
  Assert.equal(lifecycle:phase(), "restoring")
  lifecycle:updateFixed()
  Assert.isTrue(lifecycle:isPresent())
end

function T.overworld_lifecycle_rejects_invalid_transitions()
  local lifecycle = FieldOverworldLifecycle.new()
  local ok, err = pcall(lifecycle.requestRestore, lifecycle)
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, FieldErrors.FIELD_OVERWORLD_LIFECYCLE_INVALID)
  lifecycle:requestLeave()
  ok, err = pcall(lifecycle.requestLeave, lifecycle)
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err))
end

function T.prop_animation_slots_retain_playback_and_die_on_map_rebind()
  local owner = FieldScriptPropAnimations.new()
  local complete = false
  local playCount = 0
  local prop = {
    instance = {},
    play = function(_, role, opts)
      playCount = playCount + 1
      Assert.equal(role, "door.open")
      Assert.equal(opts.loopMode, "once")
      return { player = {
        isComplete = function()
          return complete
        end,
      } }
    end,
  }
  local firstMap = {
    mapProps = {
      doorAt = function()
        return nil
      end,
      scriptPropAt = function()
        return prop
      end,
    },
  }
  owner:bindMap(firstMap)
  owner:load(3, 5, 7)
  Assert.equal(playCount, 0, "load must not start playback")
  owner:play(3, "forward")
  Assert.isFalse(owner:isFinished(3))
  complete = true
  Assert.isTrue(owner:isFinished(3), "wait lookup observes the retained playback")
  owner:unload(3)
  local ok = pcall(owner.isFinished, owner, 3)
  Assert.isFalse(ok)

  owner:load(3, 5, 7)
  owner:bindMap({
    mapProps = {
      doorAt = function()
        return nil
      end,
      scriptPropAt = function()
        return prop
      end,
    },
  })
  ok = pcall(owner.play, owner, 3, "forward")
  Assert.isFalse(ok, "map rebinding invalidates loaded slots")
end

function T.prop_animation_slots_reject_bad_or_duplicate_references()
  local owner = FieldScriptPropAnimations.new()
  local prop = {
    instance = {},
    play = function()
      return { player = {
        isComplete = function()
          return false
        end,
      } }
    end,
  }
  owner:bindMap({
    mapProps = {
      doorAt = function()
        return nil
      end,
      scriptPropAt = function()
        return prop
      end,
    },
  })
  local ok = pcall(owner.load, owner, 256, 0, 0)
  Assert.isFalse(ok, "slot values stay in the source byte domain")
  owner:load(0, 0, 0)
  ok = pcall(owner.load, owner, 0, 0, 0)
  Assert.isFalse(ok, "loaded slot replacement requires an unload")
  ok = pcall(owner.play, owner, 0, "reverse")
  Assert.isTrue(ok)
  ok = pcall(owner.play, owner, 0, "forward")
  Assert.isFalse(ok, "a slot has at most one active playback")
end

function T.blocking_tasks_observe_the_shared_owners()
  local lifecycle = FieldOverworldLifecycle.new()
  local context = { services = { overworld = lifecycle } }
  local state = OverworldLifecycleTask.create({ action = "leave" }, context)
  Assert.isFalse(OverworldLifecycleTask.poll(state, context).complete)
  lifecycle:updateFixed()
  Assert.isTrue(OverworldLifecycleTask.poll(state, context).complete)

  local finished = false
  local waiterContext =
    { services = { propAnimations = {
      isFinished = function()
        return finished
      end,
    } } }
  local waitState = PropAnimationWaitTask.create({ slot = 7 }, waiterContext)
  Assert.isFalse(PropAnimationWaitTask.poll(waitState, waiterContext).complete)
  finished = true
  Assert.isTrue(PropAnimationWaitTask.poll(waitState, waiterContext).complete)
end

return { tests = T }
