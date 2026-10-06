-- Blocking follower-appearance task: the hidden-follower choreography behind
-- the follower-appearance script command. The task owns the serializable
-- native state machine: validate active/hidden and unpause, wait and branch
-- on committed tile geometry, serially walk the south branch west then
-- north, face north, apply eight cumulative render-vector updates, start the
-- generic visual transition once, hold a twenty-count tail, then settle onto
-- the player anchor before completing. Movement, placement, and the render
-- vector go through the following-mon owner; only the state-5 visual effect
-- goes through the generic transition controller. Task state carries plain
-- scalars/tables only, never actor or controller objects.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

---@class FollowerAppearanceFollowingMon
---@field isSourceActive fun(self: FollowerAppearanceFollowingMon): boolean
---@field isPartnerVisible fun(self: FollowerAppearanceFollowingMon): boolean
---@field setMovementPaused fun(self: FollowerAppearanceFollowingMon, paused: boolean)
---@field isMovementSettled fun(self: FollowerAppearanceFollowingMon): boolean
---@field settleMovement fun(self: FollowerAppearanceFollowingMon)
---@field classifyAppearanceGeometry fun(self: FollowerAppearanceFollowingMon): { mirror: boolean, nextState: integer }
---@field startAppearanceMovement fun(self: FollowerAppearanceFollowingMon, kind: string)
---@field setAppearancePresentationOffset fun(self: FollowerAppearanceFollowingMon, offset: { x: number, y: number, z: number })
---@field clearAppearancePresentationOffset fun(self: FollowerAppearanceFollowingMon)
---@field repositionRelativeToPlayer fun(self: FollowerAppearanceFollowingMon, offsetSelector: integer, directionRaw: integer)

---@class FollowerAppearanceTransition
---@field start fun(self: FollowerAppearanceTransition): boolean

---@class FollowerAppearanceServices
---@field followingMon FollowerAppearanceFollowingMon
---@field followerTransition FollowerAppearanceTransition

---@class FollowerAppearanceContext
---@field services FollowerAppearanceServices

local FollowerAppearanceTask = {}

FollowerAppearanceTask.type = "follower_appearance"
FollowerAppearanceTask.version = 2

local VECTOR_STEPS = 8
local TAIL_TICKS = 20

-- Per-step render-vector increments applied cumulatively as absolute offsets.
local VECTOR_Y = { 1, 2, 2, 3, 3, 2, 2, 0 }
local VECTOR_Z = { 4, 4, 4, 2, 2, 2, 0, 0 }

---@return table<string, unknown> state
local function initialState()
  return {
    state = 0,
    moveStep = 0,
    vectorIndex = 0,
    mirror = false,
    tailCount = 0,
    offset = { x = 0, y = 0, z = 0 },
  }
end

---@param spec table<string, unknown>
---@param _ FollowerAppearanceContext
---@return table<string, unknown> state
function FollowerAppearanceTask.create(spec, _)
  assert(type(spec) == "table", "follower appearance requires a task spec")
  return initialState()
end

---@param state table<string, unknown>
---@return table<string, unknown> result
local function incomplete(state)
  return { complete = false, state = state }
end

---@param state table<string, unknown>
---@return table<string, unknown> result
local function complete(state)
  return { complete = true, state = state, result = nil }
end

---@param state table<string, unknown>
---@param ctx FollowerAppearanceContext
---@return table<string, unknown> result
function FollowerAppearanceTask.poll(state, ctx)
  if state.cancelled ~= nil then
    return complete(state)
  end
  assert(type(state.state) == "number", "follower appearance state requires its machine state")
  local followingMon = assert(ctx.services.followingMon, "follower appearance requires the following-mon service")
  if state.state == 0 then
    if not followingMon:isSourceActive() then
      return complete(state)
    end
    if followingMon:isPartnerVisible() then
      return complete(state)
    end
    followingMon:setMovementPaused(false)
    state.state = 1
  end
  if state.state == 1 then
    if not followingMon:isMovementSettled() then
      return incomplete(state)
    end
    local geometry = followingMon:classifyAppearanceGeometry()
    assert(geometry.nextState == 2 or geometry.nextState == 3, "appearance geometry selects a known branch")
    state.mirror = geometry.mirror == true
    state.state = geometry.nextState
    return incomplete(state)
  end
  if state.state == 2 then
    if not followingMon:isMovementSettled() then
      return incomplete(state)
    end
    if state.moveStep == 0 then
      followingMon:startAppearanceMovement("walk_west")
      state.moveStep = 1
      return incomplete(state)
    end
    assert(state.moveStep == 1, "appearance walk pair issues west before north")
    followingMon:startAppearanceMovement("walk_north")
    state.state = 3
    return incomplete(state)
  end
  if state.state == 3 then
    if not followingMon:isMovementSettled() then
      return incomplete(state)
    end
    followingMon:startAppearanceMovement("face_north")
    state.state = 4
    return incomplete(state)
  end
  if state.state == 4 then
    local index = assert(state.vectorIndex, "appearance vector progress is required") + 1
    assert(index >= 1 and index <= VECTOR_STEPS, "appearance vector step is required")
    local offset = assert(state.offset, "appearance vector offset is required")
    offset.x = offset.x + (state.mirror == true and 2 or -2)
    offset.y = offset.y + VECTOR_Y[index]
    offset.z = offset.z - VECTOR_Z[index]
    state.vectorIndex = index
    followingMon:setAppearancePresentationOffset(offset)
    if index >= VECTOR_STEPS then
      state.state = 5
    end
    return incomplete(state)
  end
  if state.state == 5 then
    local transition = assert(ctx.services.followerTransition, "follower appearance requires the transition controller")
    assert(transition:start(), "follower appearance visual start must be accepted")
    state.state = 6
    return incomplete(state)
  end
  if state.state == 6 then
    local tailCount = assert(state.tailCount, "appearance tail count is required") + 1
    state.tailCount = tailCount
    if tailCount >= TAIL_TICKS then
      followingMon:clearAppearancePresentationOffset()
      state.offset = { x = 0, y = 0, z = 0 }
      followingMon:repositionRelativeToPlayer(4, 0)
      state.state = 7
    end
    return incomplete(state)
  end
  assert(state.state == 7, "follower appearance state is required")
  return complete(state)
end

-- Settle task-owned follower movement and clear the task-owned render
-- vector. A task that never left state 0 owns nothing and skips cleanup;
-- generic transition instances are never touched.
---@param state table<string, unknown>
---@param reason string
---@param ctx FollowerAppearanceContext?
function FollowerAppearanceTask.cancel(state, reason, ctx)
  if state.state ~= nil and state.state ~= 0 then
    local services = ctx ~= nil and ctx.services or nil
    local followingMon = services ~= nil and services.followingMon or nil
    if followingMon ~= nil then
      followingMon:settleMovement()
      followingMon:clearAppearancePresentationOffset()
    end
  end
  state.cancelled = reason
end

---@param value unknown
---@return boolean
local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

---@param value unknown
---@return boolean
local function isStateId(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 7
end

---@param state table<string, unknown>
---@return Errors.Error|nil
function FollowerAppearanceTask.validate(state)
  local function invalid(message)
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, message, context)
  end
  if type(state) ~= "table" then
    return invalid("follower appearance state must be a table")
  end
  if not isStateId(state.state) then
    return invalid("follower appearance state requires a machine state")
  end
  if type(state.moveStep) ~= "number" or state.moveStep % 1 ~= 0 or state.moveStep < 0 or state.moveStep > 1 then
    return invalid("follower appearance walk progress must be 0 or 1")
  end
  if
    type(state.vectorIndex) ~= "number"
    or state.vectorIndex % 1 ~= 0
    or state.vectorIndex < 0
    or state.vectorIndex > VECTOR_STEPS
  then
    return invalid("follower appearance vector progress must be within its sequence")
  end
  if type(state.mirror) ~= "boolean" then
    return invalid("follower appearance mirror flag must be a boolean")
  end
  if
    type(state.tailCount) ~= "number"
    or state.tailCount % 1 ~= 0
    or state.tailCount < 0
    or state.tailCount > TAIL_TICKS
  then
    return invalid("follower appearance tail count must be within its tail")
  end
  if
    type(state.offset) ~= "table"
    or not isFiniteNumber(state.offset.x)
    or not isFiniteNumber(state.offset.y)
    or not isFiniteNumber(state.offset.z)
  then
    return invalid("follower appearance offset requires finite x, y, z")
  end
  for key, value in pairs(state) do
    if key == "cancelled" then
      if type(value) ~= "string" then
        return invalid("follower appearance cancellation must be a string")
      end
    elseif
      key ~= "state"
      and key ~= "moveStep"
      and key ~= "vectorIndex"
      and key ~= "mirror"
      and key ~= "tailCount"
      and key ~= "offset"
    then
      return invalid("follower appearance state contains an unexpected field")
    end
  end
  for key in pairs(state.offset) do
    if key ~= "x" and key ~= "y" and key ~= "z" then
      return invalid("follower appearance offset contains an unexpected field")
    end
  end
  return nil
end

return FollowerAppearanceTask
