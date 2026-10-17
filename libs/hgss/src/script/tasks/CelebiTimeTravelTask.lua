-- Celebi time-travel cutscene task: the source-timed wait behind the
-- shrine's CelebiTimeTravel command. pret/pokeheartgold
-- src/field/event_cutscene_celebi.c runs a white fade, a 30-tick model
-- beat, then a 180-tick (0xB4) camera swirl with a 30-tick white fade
-- starting 80 ticks in, and lands with the screen cover fully opaque
-- white (the following warp requires it). The 3D swirl, motion blur, and
-- legend models have no presentation owner in this engine, so the task
-- owns the source beat structure (30 + 180 polls) plus one white fade-out
-- through the screen service: completion needs the beats and the landed
-- fade together, exactly like the source waits for its swirl and its
-- palette fade. An in-flight fade lands before the cutscene fade starts
-- (two script screen fades must never overlap); a missing screen backend
-- is an attributed fault, never a silent timing-only wait, because the
-- downstream warp faults without its opaque cover anyway.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local CelebiTimeTravelTask = {}

CelebiTimeTravelTask.type = "celebi_time_travel"
CelebiTimeTravelTask.version = 1

-- Source beats from Task_CelebiTimeTravelCutscene: the model beat waits
-- 30 ticks before the swirl starts, and the swirl effect runs 180 ticks
-- (its white fade at +80 for 30 ticks finishes inside the swirl, so the
-- swirl owns the total). The single white-out below mirrors the source
-- closing fade (duration 30); the brief opening palette fade is
-- presentation-owned and carries no ticks here.
CelebiTimeTravelTask.BEAT_TICKS = 30
CelebiTimeTravelTask.SWIRL_TICKS = 180
CelebiTimeTravelTask.FADE_DURATION = 30

---@return table<string, unknown> state
local function initialState()
  return { phase = "beat", elapsed = 0, fadeStarted = false }
end

-- Creation takes no input: the cutscene owns its fixed source beats.
---@return table<string, unknown> state
function CelebiTimeTravelTask.create()
  return initialState()
end

---@class CelebiTimeTravelScreen
---@field startFade fun(self: CelebiTimeTravelScreen, spec: { direction: string, color: string, duration: integer, speed: integer })
---@field fadeDone fun(self: CelebiTimeTravelScreen): boolean

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown> result
function CelebiTimeTravelTask.poll(state, ctx)
  if state.cancelled ~= nil then
    return { complete = true, state = state, result = nil }
  end
  local services = ctx.services
  if type(services) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the celebi cutscene requires task services", {})
  end
  local screen = services.screen
  if type(screen) ~= "table" or type(screen.startFade) ~= "function" or type(screen.fadeDone) ~= "function" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the celebi cutscene requires the screen service", {
      scriptId = ctx.instance and ctx.instance.scriptId,
    })
  end
  local screenService = screen --[[@as CelebiTimeTravelScreen]]
  if not state.fadeStarted then
    if not screenService:fadeDone() then
      return { complete = false, state = state }
    end
    screenService:startFade({
      direction = "out",
      color = "white",
      duration = CelebiTimeTravelTask.FADE_DURATION,
      speed = 1,
    })
    state.fadeStarted = true
  end
  assert(state.phase == "beat" or state.phase == "swirl", "celebi time travel requires a known phase")
  assert(
    type(state.elapsed) == "number" and state.elapsed % 1 == 0 and state.elapsed >= 0,
    "celebi time travel requires a non-negative elapsed count"
  )
  local limit = state.phase == "beat" and CelebiTimeTravelTask.BEAT_TICKS or CelebiTimeTravelTask.SWIRL_TICKS
  local elapsed = math.min(state.elapsed + 1, limit)
  state.elapsed = elapsed
  if state.phase == "beat" then
    if elapsed >= CelebiTimeTravelTask.BEAT_TICKS then
      state.phase = "swirl"
      state.elapsed = 0
    end
    return { complete = false, state = state }
  end
  if elapsed >= CelebiTimeTravelTask.SWIRL_TICKS and screenService:fadeDone() then
    return { complete = true, state = state, result = nil }
  end
  return { complete = false, state = state }
end

---@param state table<string, unknown>
---@param reason string
function CelebiTimeTravelTask.cancel(state, reason)
  state.cancelled = reason
end

---@param state table<string, unknown>
---@return Errors.Error|nil
function CelebiTimeTravelTask.validate(state)
  local function invalid(message)
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, message, context)
  end
  if type(state) ~= "table" then
    return invalid("celebi time travel state must be a table")
  end
  if state.phase ~= "beat" and state.phase ~= "swirl" then
    return invalid("celebi time travel phase must be beat or swirl")
  end
  local limit = state.phase == "beat" and CelebiTimeTravelTask.BEAT_TICKS or CelebiTimeTravelTask.SWIRL_TICKS
  if type(state.elapsed) ~= "number" or state.elapsed % 1 ~= 0 or state.elapsed < 0 or state.elapsed > limit then
    return invalid("celebi time travel elapsed must stay within its phase")
  end
  if type(state.fadeStarted) ~= "boolean" then
    return invalid("celebi time travel fade progress must be a boolean")
  end
  for key, value in pairs(state) do
    if key == "cancelled" then
      if type(value) ~= "string" then
        return invalid("celebi time travel cancellation must be a string")
      end
    elseif key ~= "phase" and key ~= "elapsed" and key ~= "fadeStarted" then
      return invalid("celebi time travel state contains an unexpected field")
    end
  end
  return nil
end

return CelebiTimeTravelTask
