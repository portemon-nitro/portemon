-- Follower-appearance task: cross the HGSS scheduler boundary, start the
-- controller choreography once for an active source follower, and poll its
-- semantic completion without retaining runtime objects in saved state.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FollowerAppearanceTask = require("libs.hgss.src.script.tasks.FollowerAppearanceTask")

local T = {}

local function context(sourceActive, settled, starts)
  local follower = {
    isSourceActive = function()
      return sourceActive
    end,
    repositionRelativeToPlayer = function() end,
  }
  return {
    services = {
      followingMon = follower,
      followerTransition = {
        startAppearance = function(_, actualFollower)
          Assert.equal(actualFollower, follower, "appearance uses the live following-mon service")
          starts.count = starts.count + 1
          return true
        end,
        isAppearanceSettled = function()
          return settled.value
        end,
      },
    },
  }
end

function T.active_appearance_starts_once_and_polls_until_settled()
  local starts = { count = 0 }
  local settled = { value = false }
  local ctx = context(true, settled, starts)
  local state = FollowerAppearanceTask.create({}, ctx)
  Assert.equal(starts.count, 1, "active appearance starts exactly once at task creation")
  Assert.isNil(FollowerAppearanceTask.validate(state), "active task state is serializable")
  Assert.isFalse(FollowerAppearanceTask.poll(state, ctx).complete, "the task waits for its controller")
  settled.value = true
  Assert.isTrue(FollowerAppearanceTask.poll(state, ctx).complete, "controller settlement completes the task")
  Assert.equal(starts.count, 1, "polling never restarts the choreography")
end

function T.inactive_appearance_completes_without_visual_work()
  local starts = { count = 0 }
  local ctx = context(false, { value = false }, starts)
  local state = FollowerAppearanceTask.create({}, ctx)
  Assert.equal(starts.count, 0, "inactive source follower starts no choreography")
  Assert.isNil(FollowerAppearanceTask.validate(state), "inactive task state is serializable")
  Assert.isTrue(FollowerAppearanceTask.poll(state, ctx).complete, "inactive source task completes immediately")
end

function T.validation_accepts_both_task_paths_and_rejects_malformed_state()
  Assert.isNil(FollowerAppearanceTask.validate({ started = false }), "no-start state is valid")
  Assert.isNil(FollowerAppearanceTask.validate({ started = true }), "active-start state is valid")
  Assert.isTrue(Errors.is(FollowerAppearanceTask.validate({ started = "yes" })), "started must be boolean")
  Assert.isTrue(Errors.is(FollowerAppearanceTask.validate({})), "missing started state is invalid")
  Assert.isTrue(Errors.is(FollowerAppearanceTask.validate("not-a-table")), "non-table state is invalid")
end

return { tests = T }
