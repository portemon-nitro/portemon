-- The source elevator animation (ScrCmd_ElevatorAnim ->
-- src/field/map_prop_anims.c::ElevatorAnimRun): a native blocking task that
-- loads the map elevator's one-shot animation, plays the source direction,
-- holds the script through the animation loop, then stops the motor sound,
-- plays the arrival chime, waits for its completion, releases the animation
-- and only then completes. The animation and sound owners are the shared map
-- prop and sound services; the serialized task state holds only source
-- operands and the phase, never a host handle.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local ElevatorAnimTask = {}
ElevatorAnimTask.type = "elevator_anim"
ElevatorAnimTask.version = 1

-- The pinned source sound identities (include/constants/sndseq.h).
local MOTOR_SEQUENCE = "SEQ_SE_DP_ELEBETA2"
local CHIME_SEQUENCE = "SEQ_SE_DP_PINPON"

-- Source direction 0/1 selects one of the two loaded one-shot animations.
local DIRECTIONS = { [0] = true, [1] = true }

local PHASES = { load = true, waitLoop = true, waitChime = true, complete = true }

-- The owner that accepted this task's animation load. Cancellation must release
-- the animation without the scheduler context, and the owner must never enter
-- the serialized state (a saved task carries no host references), so the lease
-- lives beside the state, keyed weakly by it.
local LEASES = setmetatable({}, { __mode = "k" })

local function animationOwner(ctx)
  return assert(ctx.services.propAnimations, "propAnimations service is unavailable")
end

local function audioOwner(ctx)
  return assert(ctx.services.audio, "audio service is unavailable")
end

-- Release the source-loaded animation exactly once, whatever phase owned it.
local function release(state)
  if state.released then
    return
  end
  local animations = LEASES[state]
  if animations == nil then
    return
  end
  animations:unloadAnimation()
  LEASES[state] = nil
  state.released = true
end

---@param spec { direction: unknown, length: unknown }
---@param ctx table<string, unknown>
---@return table<string, unknown> state
function ElevatorAnimTask.create(spec, ctx)
  local direction = spec.direction
  if DIRECTIONS[direction] ~= true then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "the elevator animation direction is outside the source pair",
      { direction = tostring(direction) }
    )
  end
  local length = spec.length
  if type(length) ~= "number" or length % 1 ~= 0 or length <= 0 or length > 0xFFFF then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "the elevator animation length is outside the source halfword domain",
      { length = tostring(length) }
    )
  end
  -- Acquisition happens before any playback claim: a map without the elevator
  -- prop faults here and the script never advances.
  local animations = animationOwner(ctx)
  animations:loadAnimation(length)
  local state = { phase = "load", direction = direction, length = length, released = false }
  LEASES[state] = animations
  return state
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown> result
function ElevatorAnimTask.poll(state, ctx)
  if state.phase == "complete" then
    return { complete = true, state = state, result = nil }
  end
  local audio = audioOwner(ctx)
  if state.phase == "load" then
    animationOwner(ctx):playAnimation(state.direction)
    audio:play(MOTOR_SEQUENCE)
    state.phase = "waitLoop"
    return { complete = false, state = state }
  end
  if state.phase == "waitLoop" then
    if not animationOwner(ctx):isAnimationLoopFinished() then
      return { complete = false, state = state }
    end
    audio:stop(MOTOR_SEQUENCE)
    audio:play(CHIME_SEQUENCE)
    state.phase = "waitChime"
    return { complete = false, state = state }
  end
  if not audio:isEffectWaitComplete(CHIME_SEQUENCE) then
    return { complete = false, state = state }
  end
  release(state)
  state.phase = "complete"
  return { complete = true, state = state, result = nil }
end

---@param state table<string, unknown>
---@param reason string?
function ElevatorAnimTask.cancel(state, reason)
  state.cancelled = reason
  release(state)
end

---@param state table<string, unknown>
---@return unknown|nil
function ElevatorAnimTask.validate(state)
  if
    type(state) ~= "table"
    or PHASES[state.phase] ~= true
    or DIRECTIONS[state.direction] ~= true
    or type(state.length) ~= "number"
    or state.length % 1 ~= 0
  then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "elevator animation state is invalid", context)
  end
  return nil
end

return ElevatorAnimTask
