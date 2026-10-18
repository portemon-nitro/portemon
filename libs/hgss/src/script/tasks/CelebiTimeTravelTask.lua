-- Celebi time-travel cutscene task: the visible source-ordered fade
-- timeline behind the shrine's CelebiTimeTravel command.
-- pret/pokeheartgold src/field/event_cutscene_celebi.c opens with a short
-- main-screen white fade-out and back in, holds a 30-tick model beat,
-- then runs a 180-tick (0xB4) camera swirl whose own white fade starts 80
-- ticks in and lasts 30 ticks, landing opaque white for the following
-- warp. The task mirrors that schedule through the shared screen
-- service: opening_out (white out) -> opening_in (white in) -> beat (30
-- clear polls) -> swirl (180 polls, closing white out at tick 80).
-- Completion needs the full swirl and a landed opaque cover together.
-- The runtime-owned scene captures and hides the follower; its presentation
-- renderer lazily realizes the original model from this task's source clock.
-- The task never advances the fade itself: the field runtime owns the
-- source-frame clock and the task only polls the backend state.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local CelebiTimeTravelTask = {}

CelebiTimeTravelTask.type = "celebi_time_travel"
CelebiTimeTravelTask.version = 1

-- Source counts from Task_CelebiTimeTravelCutscene: the opening palette
-- fades step 4 frames each, the model beat waits 30 ticks, the swirl
-- effect runs 180 ticks, and the closing white fade steps 30 frames
-- starting 80 swirl ticks in (it lands inside the swirl, so the swirl
-- owns the total). Every fade starts with speed 1.
CelebiTimeTravelTask.OPENING_FADE_STEPS = 4
CelebiTimeTravelTask.BEAT_TICKS = 30
CelebiTimeTravelTask.SWIRL_TICKS = 180
CelebiTimeTravelTask.CLOSING_START_TICK = 80
CelebiTimeTravelTask.CLOSING_FADE_STEPS = 30

---@return table<string, unknown> state
local function initialState()
  return { phase = "opening_out", elapsed = 0, fadeStarted = false, fadeLease = nil, sceneStarted = false }
end

-- Creation takes no input: the cutscene owns its fixed source schedule.
---@return table<string, unknown> state
function CelebiTimeTravelTask.create()
  return initialState()
end

---@class CelebiTimeTravelScreen
---@field startFade fun(self: CelebiTimeTravelScreen, spec: { direction: string, color: string, duration: integer, speed: integer, screenScope: "main"|"both" }): integer
---@field clearIfCurrent fun(self: CelebiTimeTravelScreen, lease: integer): boolean
---@field fadeDone fun(self: CelebiTimeTravelScreen): boolean
---@field isOpaque fun(self: CelebiTimeTravelScreen): boolean

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
  if
    type(screen) ~= "table"
    or type(screen.startFade) ~= "function"
    or type(screen.clearIfCurrent) ~= "function"
    or type(screen.fadeDone) ~= "function"
    or type(screen.isOpaque) ~= "function"
  then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the celebi cutscene requires the screen service", {
      scriptId = ctx.instance and ctx.instance.scriptId,
    })
  end
  local screenService = screen --[[@as CelebiTimeTravelScreen]]
  local scene = services.celebiCinematic
  if state.phase == "opening_out" or state.phase == "opening_in" then
    if state.fadeStarted then
      if not screenService:fadeDone() then
        return { complete = false, state = state }
      end
      if state.phase == "opening_out" then
        state.phase = "opening_in"
        assert(
          type(scene) == "table" and type(scene.beginModel) == "function",
          "the Celebi cutscene requires its scene service"
        )
        scene:beginModel()
        state.sceneStarted = true
      else
        assert(
          type(scene) == "table" and type(scene.setAnimationFrame) == "function",
          "Celebi scene service is missing"
        )
        scene:setAnimationFrame(1)
        state.phase = "beat"
      end
      state.elapsed = 0
      state.fadeStarted = false
      if state.phase == "beat" then
        return { complete = false, state = state }
      end
    end
    if not screenService:fadeDone() then
      return { complete = false, state = state }
    end
    local direction = state.phase == "opening_out" and "out" or "in"
    state.fadeLease = screenService:startFade({
      direction = direction,
      color = "white",
      duration = CelebiTimeTravelTask.OPENING_FADE_STEPS,
      speed = 1,
      screenScope = "main",
    })
    state.fadeStarted = true
    return { complete = false, state = state }
  end
  assert(state.phase == "beat" or state.phase == "swirl", "celebi time travel requires a known phase")
  assert(
    type(state.elapsed) == "number" and state.elapsed % 1 == 0 and state.elapsed >= 0,
    "celebi time travel requires a non-negative elapsed count"
  )
  if state.phase == "beat" then
    state.elapsed = state.elapsed + 1
    assert(type(scene) == "table" and type(scene.setAnimationFrame) == "function", "Celebi scene service is missing")
    scene:setAnimationFrame(1 + state.elapsed)
    if state.elapsed >= CelebiTimeTravelTask.BEAT_TICKS then
      assert(type(scene.beginSwirl) == "function", "Celebi scene swirl operation is missing")
      scene:beginSwirl()
      state.phase = "swirl"
      state.elapsed = 0
    end
    return { complete = false, state = state }
  end
  state.elapsed = math.min(state.elapsed + 1, CelebiTimeTravelTask.SWIRL_TICKS)
  assert(type(scene) == "table" and type(scene.setAnimationFrame) == "function", "Celebi scene service is missing")
  scene:setAnimationFrame(1 + CelebiTimeTravelTask.BEAT_TICKS + state.elapsed)
  assert(type(scene.setSwirlFrame) == "function", "Celebi scene swirl operation is missing")
  scene:setSwirlFrame(state.elapsed)
  if state.elapsed == CelebiTimeTravelTask.CLOSING_START_TICK and not state.fadeStarted then
    assert(screenService:fadeDone(), "closing white fade cannot overlap an active fade")
    state.fadeLease = screenService:startFade({
      direction = "out",
      color = "white",
      duration = CelebiTimeTravelTask.CLOSING_FADE_STEPS,
      speed = 1,
      screenScope = "both",
    })
    state.fadeStarted = true
  end
  if state.elapsed >= CelebiTimeTravelTask.SWIRL_TICKS then
    if not screenService:fadeDone() then
      return { complete = false, state = state }
    end
    assert(state.fadeStarted and screenService:isOpaque(), "celebi warp requires finished opaque white cover")
    assert(type(scene) == "table" and type(scene.finish) == "function", "Celebi scene service is missing")
    scene:finish()
    state.sceneStarted = false
    return { complete = true, state = state, result = nil }
  end
  return { complete = false, state = state }
end

---@param state table<string, unknown>
---@param reason string
---@param ctx table<string, unknown>?
function CelebiTimeTravelTask.cancel(state, reason, ctx)
  if state.cancelled ~= nil then
    return
  end
  local services = ctx and ctx.services
  local scene = type(services) == "table" and services.celebiCinematic or nil
  local cleanupError = nil
  if state.sceneStarted then
    local ok, err = pcall(function()
      assert(type(scene) == "table" and type(scene.abort) == "function", "Celebi cancellation requires its scene owner")
      scene:abort()
    end)
    if not ok then
      cleanupError = err
    end
    state.sceneStarted = false
  end
  if state.fadeLease ~= nil then
    local screen = type(services) == "table" and services.screen or nil
    local ok, err = pcall(function()
      assert(
        type(screen) == "table" and type(screen.clearIfCurrent) == "function",
        "Celebi cancellation requires the screen fade owner"
      )
      screen:clearIfCurrent(state.fadeLease)
    end)
    if not ok and cleanupError == nil then
      cleanupError = err
    end
    state.fadeLease = nil
  end
  state.cancelled = reason
  if cleanupError ~= nil then
    error(cleanupError, 0)
  end
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
  if
    state.phase ~= "opening_out"
    and state.phase ~= "opening_in"
    and state.phase ~= "beat"
    and state.phase ~= "swirl"
  then
    return invalid("celebi time travel phase must be opening_out, opening_in, beat, or swirl")
  end
  local limit = CelebiTimeTravelTask.SWIRL_TICKS
  if state.phase == "opening_out" or state.phase == "opening_in" then
    limit = 0
  elseif state.phase == "beat" then
    limit = CelebiTimeTravelTask.BEAT_TICKS
  end
  if type(state.elapsed) ~= "number" or state.elapsed % 1 ~= 0 or state.elapsed < 0 or state.elapsed > limit then
    return invalid("celebi time travel elapsed must stay within its phase")
  end
  if type(state.fadeStarted) ~= "boolean" then
    return invalid("celebi time travel fade progress must be a boolean")
  end
  if type(state.sceneStarted) ~= "boolean" then
    return invalid("celebi time travel scene progress must be a boolean")
  end
  if
    state.fadeLease ~= nil and (type(state.fadeLease) ~= "number" or state.fadeLease % 1 ~= 0 or state.fadeLease <= 0)
  then
    return invalid("celebi time travel fade lease must be a positive integer")
  end
  for key, value in pairs(state) do
    if key == "cancelled" then
      if type(value) ~= "string" then
        return invalid("celebi time travel cancellation must be a string")
      end
    elseif
      key ~= "phase"
      and key ~= "elapsed"
      and key ~= "fadeStarted"
      and key ~= "fadeLease"
      and key ~= "sceneStarted"
    then
      return invalid("celebi time travel state contains an unexpected field")
    end
  end
  return nil
end

return CelebiTimeTravelTask
