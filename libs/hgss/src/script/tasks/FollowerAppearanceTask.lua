-- Follower-appearance task: own the native-wait boundary while the HGSS
-- transition controller runs the source appearance lifecycle.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

---@class FollowerAppearanceFollowingMon
---@field isSourceActive fun(self: FollowerAppearanceFollowingMon): boolean
---@field repositionRelativeToPlayer fun(self: FollowerAppearanceFollowingMon, offsetSelector: integer, directionRaw: integer)

---@class FollowerAppearanceController
---@field startAppearance fun(self: FollowerAppearanceController, follower: FollowerAppearanceFollowingMon): boolean
---@field isAppearanceSettled fun(self: FollowerAppearanceController): boolean
---@field cancelAppearance fun(self: FollowerAppearanceController)

---@class FollowerAppearanceServices
---@field followingMon FollowerAppearanceFollowingMon
---@field followerTransition FollowerAppearanceController

---@class FollowerAppearanceContext
---@field services FollowerAppearanceServices

local FollowerAppearanceTask = {}

FollowerAppearanceTask.type = "follower_appearance"
FollowerAppearanceTask.version = 1

---@param spec table<string, unknown>
---@param ctx FollowerAppearanceContext
---@return table<string, unknown> state
function FollowerAppearanceTask.create(spec, ctx)
  assert(type(spec) == "table", "follower appearance requires a task spec")
  local followingMon = assert(ctx.services.followingMon, "follower appearance requires the following-mon service")
  if not followingMon:isSourceActive() then
    return { started = false }
  end

  local transition = assert(ctx.services.followerTransition, "follower appearance requires the transition controller")
  assert(transition:startAppearance(followingMon), "follower appearance start must be accepted")
  return { started = true }
end

---@param state table<string, unknown>
---@param ctx FollowerAppearanceContext
---@return table<string, unknown> result
function FollowerAppearanceTask.poll(state, ctx)
  assert(type(state.started) == "boolean", "follower appearance state requires its start mode")
  if not state.started then
    return { complete = true, state = state, result = nil }
  end
  local transition = assert(ctx.services.followerTransition, "follower appearance requires the transition controller")
  if transition:isAppearanceSettled() then
    return { complete = true, state = state, result = nil }
  end
  return { complete = false, state = state }
end

---@param state table<string, unknown>
---@param reason string
---@param ctx FollowerAppearanceContext
function FollowerAppearanceTask.cancel(state, reason, ctx)
  if state.started then
    local transition = assert(ctx.services.followerTransition, "follower appearance requires the transition controller")
    transition:cancelAppearance()
  end
  state.cancelled = reason
end

---@param state table<string, unknown>
---@return Errors.Error|nil
function FollowerAppearanceTask.validate(state)
  if type(state) ~= "table" or type(state.started) ~= "boolean" then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "follower appearance state must identify whether it started",
      context
    )
  end
  for key, value in pairs(state) do
    if key == "cancelled" then
      if type(value) ~= "string" then
        local context = { state = state }
        ---@cast context Errors.Context
        return Errors.new(
          ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
          "follower appearance cancellation must be a string",
          context
        )
      end
    elseif key ~= "started" then
      local context = { state = state }
      ---@cast context Errors.Context
      return Errors.new(
        ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
        "follower appearance state contains an unexpected field",
        context
      )
    end
  end
  return nil
end

return FollowerAppearanceTask
