-- Runs the blocking source Apricorn tree animation and consumes its daily pick.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local ApricornTreeTask = {}
ApricornTreeTask.type = "apricorn_tree"
ApricornTreeTask.version = 1

local PLAYER_WAIT_FRAMES = 25
local TREE_WIGGLE_FRAMES = 16 * 2
local TREE_EXPEL_FRAMES = 8
local APRICORN_JUMP_FRAMES = 16
local TOTAL_FRAMES = PLAYER_WAIT_FRAMES + TREE_WIGGLE_FRAMES + TREE_EXPEL_FRAMES + APRICORN_JUMP_FRAMES

local function invalidState(state)
  local context = { state = state }
  ---@cast context Errors.Context
  return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "Apricorn tree task state is invalid", context)
end

---@param spec table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function ApricornTreeTask.create(spec, ctx)
  local actorId = spec.actorId
  if type(actorId) ~= "string" or actorId == "" then
    Errors.raise(ScriptErrors.SCRIPT_SCHEMA_INVALID, "Apricorn tree task requires an actor", {
      scriptId = ctx.instance.scriptId,
    })
  end
  local apricorn = assert(ctx.services.apricorn, "Apricorn service is unavailable")
  local tree = apricorn:treeForActor(actorId)
  return {
    actorId = actorId,
    treeIndex = tree.treeIndex,
    apricornKey = tree.apricornKey,
    tick = 0,
    available = apricorn:treeAvailable(tree.treeIndex),
    harvested = false,
    started = false,
  }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function ApricornTreeTask.poll(state, ctx)
  local apricorn = assert(ctx.services.apricorn, "Apricorn service is unavailable")
  local actorId = state.actorId
  if not state.available then
    return { complete = true, state = state, result = 0 }
  end
  if not state.started then
    apricorn:beginTreeAnimation(actorId, {
      treeIndex = state.treeIndex,
      apricornKey = state.apricornKey,
    })
    state.started = true
  end

  local tick = state.tick
  if tick < PLAYER_WAIT_FRAMES then
    -- The player-only child animation completes before the tree action starts.
  elseif tick < PLAYER_WAIT_FRAMES + TREE_WIGGLE_FRAMES then
    local frame = tick - PLAYER_WAIT_FRAMES
    apricorn:advanceTreeAnimation(actorId, "wiggle", frame, state.apricornKey)
    if frame == TREE_WIGGLE_FRAMES - 1 then
      state.harvested = apricorn:depleteTree(state.treeIndex)
      if not state.harvested then
        apricorn:finishTreeAnimation(actorId)
        return { complete = true, state = state, result = 0 }
      end
    end
  elseif tick < PLAYER_WAIT_FRAMES + TREE_WIGGLE_FRAMES + TREE_EXPEL_FRAMES then
    apricorn:advanceTreeAnimation(actorId, "expel", tick - PLAYER_WAIT_FRAMES - TREE_WIGGLE_FRAMES, state.apricornKey)
  elseif tick < TOTAL_FRAMES then
    apricorn:advanceTreeAnimation(
      actorId,
      "jump",
      tick - PLAYER_WAIT_FRAMES - TREE_WIGGLE_FRAMES - TREE_EXPEL_FRAMES,
      state.apricornKey
    )
  end

  state.tick = tick + 1
  if state.tick == TOTAL_FRAMES then
    apricorn:finishTreeAnimation(actorId)
    return { complete = true, state = state, result = 1 }
  end
  return { complete = false, state = state }
end

---@param state table<string, unknown>
---@param reason string
---@param ctx table<string, unknown>?
function ApricornTreeTask.cancel(state, reason, ctx)
  if ctx and ctx.services.apricorn and state.started then
    ctx.services.apricorn:finishTreeAnimation(state.actorId)
  end
  state.cancelled = reason
end

---@param state table<string, unknown>
---@return Errors.Error|nil
function ApricornTreeTask.validate(state)
  if
    type(state) ~= "table"
    or type(state.actorId) ~= "string"
    or type(state.treeIndex) ~= "number"
    or state.treeIndex % 1 ~= 0
    or state.treeIndex < 0
    or state.treeIndex > 30
    or type(state.apricornKey) ~= "string"
    or type(state.tick) ~= "number"
    or state.tick % 1 ~= 0
    or state.tick < 0
    or state.tick > TOTAL_FRAMES
    or type(state.available) ~= "boolean"
    or type(state.harvested) ~= "boolean"
    or type(state.started) ~= "boolean"
  then
    return invalidState(state)
  end
  return nil
end

return ApricornTreeTask
