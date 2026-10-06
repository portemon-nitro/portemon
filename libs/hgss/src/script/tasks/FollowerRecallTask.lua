-- Blocking follower-recall task: the visible-follower choreography behind the
-- follower-recall script command. The task owns the serializable native
-- state machine: validate the active follower is currently visible and
-- unpause, wait and branch on committed tile geometry, serially walk the
-- south branch west then north, face north, apply eight cumulative
-- render-vector updates, then shrink the billboard through quartered scales
-- 1, 1/2, 1/3, 1/4, hide on the fourth scale update, hold the hidden tail,
-- and settle onto the player anchor with identity scale restored and one
-- pending transition armed for the next real follower walk. Movement,
-- placement, the render vector, recall scale, and visibility go through the
-- following-mon owner; the armed transition is consumed later by the next
-- actual follower walk, never started here. Task state carries plain
-- scalars/tables only, never actor or controller objects.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

---@class FollowerRecallFollowingMon
---@field isSourceActive fun(self: FollowerRecallFollowingMon): boolean
---@field isPartnerVisible fun(self: FollowerRecallFollowingMon): boolean
---@field setMovementPaused fun(self: FollowerRecallFollowingMon, paused: boolean)
---@field isMovementSettled fun(self: FollowerRecallFollowingMon): boolean
---@field settleMovement fun(self: FollowerRecallFollowingMon)
---@field classifyRecallGeometry fun(self: FollowerRecallFollowingMon): { mirror: boolean, nextState: integer }
---@field startRecallMovement fun(self: FollowerRecallFollowingMon, kind: string)
---@field setRecallPresentationOffset fun(self: FollowerRecallFollowingMon, offset: { x: number, y: number, z: number })
---@field clearRecallPresentationOffset fun(self: FollowerRecallFollowingMon)
---@field repositionRelativeToPlayer fun(self: FollowerRecallFollowingMon, offsetSelector: integer, directionRaw: integer)
---@field setRecallPresentationScale fun(self: FollowerRecallFollowingMon, scale: number)
---@field clearRecallPresentationScale fun(self: FollowerRecallFollowingMon)
---@field hideForRecall fun(self: FollowerRecallFollowingMon)
---@field showForRecall fun(self: FollowerRecallFollowingMon)
---@field armRecallTransition fun(self: FollowerRecallFollowingMon)

---@class FollowerRecallServices
---@field followingMon FollowerRecallFollowingMon

---@class FollowerRecallContext
---@field services FollowerRecallServices

local FollowerRecallTask = {}

FollowerRecallTask.type = "follower_recall"
FollowerRecallTask.version = 1

local VECTOR_STEPS = 8
local TAIL_TICKS = 20

-- Native HGSS model-space vector increments behind state 4 (ov01_02205B14,
-- state 4 shifts these by 0xC into the map object's FX32 position vector).
-- Runtime presentation offsets are in world units (one unit per tile), and
-- 16 model units make one tile, so the task normalizes each increment by
-- 1/16 before it enters runtime presentation state. The tables stay
-- readable as native values; the conversion is owned here at this
-- source/runtime seam, never in the generic actor manager.
local MODEL_UNITS_PER_TILE = 16
local VECTOR_X_NATIVE = 2
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
---@param _ FollowerRecallContext
---@return table<string, unknown> state
function FollowerRecallTask.create(spec, _)
  assert(type(spec) == "table", "follower recall requires a task spec")
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
---@param ctx FollowerRecallContext
---@return table<string, unknown> result
function FollowerRecallTask.poll(state, ctx)
  if state.cancelled ~= nil then
    return complete(state)
  end
  assert(type(state.state) == "number", "follower recall state requires its machine state")
  local followingMon = assert(ctx.services.followingMon, "follower recall requires the following-mon service")
  if state.state == 0 then
    if not followingMon:isSourceActive() then
      return complete(state)
    end
    if not followingMon:isPartnerVisible() then
      return complete(state)
    end
    followingMon:setMovementPaused(false)
    state.state = 1
  end
  if state.state == 1 then
    if not followingMon:isMovementSettled() then
      return incomplete(state)
    end
    local geometry = followingMon:classifyRecallGeometry()
    assert(geometry.nextState == 2 or geometry.nextState == 3, "recall geometry selects a known branch")
    state.mirror = geometry.mirror == true
    state.state = geometry.nextState
    return incomplete(state)
  end
  if state.state == 2 then
    if not followingMon:isMovementSettled() then
      return incomplete(state)
    end
    if state.moveStep == 0 then
      followingMon:startRecallMovement("walk_west")
      state.moveStep = 1
      return incomplete(state)
    end
    assert(state.moveStep == 1, "recall walk pair issues west before north")
    followingMon:startRecallMovement("walk_north")
    state.state = 3
    return incomplete(state)
  end
  if state.state == 3 then
    if not followingMon:isMovementSettled() then
      return incomplete(state)
    end
    followingMon:startRecallMovement("face_north")
    state.state = 4
    return incomplete(state)
  end
  if state.state == 4 then
    local index = assert(state.vectorIndex, "recall vector progress is required") + 1
    assert(index >= 1 and index <= VECTOR_STEPS, "recall vector step is required")
    local offset = assert(state.offset, "recall vector offset is required")
    offset.x = offset.x + (state.mirror == true and VECTOR_X_NATIVE or -VECTOR_X_NATIVE) / MODEL_UNITS_PER_TILE
    offset.y = offset.y + VECTOR_Y[index] / MODEL_UNITS_PER_TILE
    offset.z = offset.z - VECTOR_Z[index] / MODEL_UNITS_PER_TILE
    state.vectorIndex = index
    followingMon:setRecallPresentationOffset(offset)
    if index >= VECTOR_STEPS then
      state.state = 5
    end
    return incomplete(state)
  end
  if state.state == 5 then
    state.tailCount = 0
    state.state = 6
    return incomplete(state)
  end
  if state.state == 6 then
    local tailCount = assert(state.tailCount, "recall tail count is required") + 1
    state.tailCount = tailCount
    if tailCount <= 4 then
      followingMon:setRecallPresentationScale(1 / tailCount)
      if tailCount == 4 then
        followingMon:hideForRecall()
      end
    end
    if tailCount >= TAIL_TICKS then
      followingMon:repositionRelativeToPlayer(4, 0)
      followingMon:clearRecallPresentationScale()
      followingMon:armRecallTransition()
      state.offset = { x = 0, y = 0, z = 0 }
      state.state = 7
    end
    return incomplete(state)
  end
  assert(state.state == 7, "follower recall state is required")
  return complete(state)
end

-- Settle task-owned follower movement and clear the task-owned render
-- vector and recall scale. A task that never left state 0 owns nothing and
-- skips cleanup. When the task itself already hid the follower but has not
-- committed terminal completion, the hide is restored. Committed terminal
-- state owns nothing further to clean: the armed transition belongs to the
-- next real walk. Shared transition instances are never touched.
---@param state table<string, unknown>
---@param reason string
---@param ctx FollowerRecallContext?
function FollowerRecallTask.cancel(state, reason, ctx)
  if state.state ~= nil and state.state ~= 0 and state.state ~= 7 then
    local services = ctx ~= nil and ctx.services or nil
    local followingMon = services ~= nil and services.followingMon or nil
    if followingMon ~= nil then
      followingMon:settleMovement()
      followingMon:clearRecallPresentationOffset()
      followingMon:clearRecallPresentationScale()
      if state.state == 6 and (state.tailCount or 0) >= 4 then
        followingMon:showForRecall()
      end
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
function FollowerRecallTask.validate(state)
  local function invalid(message)
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, message, context)
  end
  if type(state) ~= "table" then
    return invalid("follower recall state must be a table")
  end
  if not isStateId(state.state) then
    return invalid("follower recall state requires a machine state")
  end
  if type(state.moveStep) ~= "number" or state.moveStep % 1 ~= 0 or state.moveStep < 0 or state.moveStep > 1 then
    return invalid("follower recall walk progress must be 0 or 1")
  end
  if
    type(state.vectorIndex) ~= "number"
    or state.vectorIndex % 1 ~= 0
    or state.vectorIndex < 0
    or state.vectorIndex > VECTOR_STEPS
  then
    return invalid("follower recall vector progress must be within its sequence")
  end
  if type(state.mirror) ~= "boolean" then
    return invalid("follower recall mirror flag must be a boolean")
  end
  if
    type(state.tailCount) ~= "number"
    or state.tailCount % 1 ~= 0
    or state.tailCount < 0
    or state.tailCount > TAIL_TICKS
  then
    return invalid("follower recall tail count must be within its tail")
  end
  if
    type(state.offset) ~= "table"
    or not isFiniteNumber(state.offset.x)
    or not isFiniteNumber(state.offset.y)
    or not isFiniteNumber(state.offset.z)
  then
    return invalid("follower recall offset requires finite x, y, z")
  end
  for key, value in pairs(state) do
    if key == "cancelled" then
      if type(value) ~= "string" then
        return invalid("follower recall cancellation must be a string")
      end
    elseif
      key ~= "state"
      and key ~= "moveStep"
      and key ~= "vectorIndex"
      and key ~= "mirror"
      and key ~= "tailCount"
      and key ~= "offset"
    then
      return invalid("follower recall state contains an unexpected field")
    end
  end
  for key in pairs(state.offset) do
    if key ~= "x" and key ~= "y" and key ~= "z" then
      return invalid("follower recall offset contains an unexpected field")
    end
  end
  return nil
end

return FollowerRecallTask
