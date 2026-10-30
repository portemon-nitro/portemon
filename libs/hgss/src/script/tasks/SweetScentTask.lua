-- sweet_scent task implementation: the source Honey/Sweet Scent state
-- machine, one state per poll. Weather refusal lives here in execution per
-- the retail ROM's Honey and Sweet Scent task (honey_sweet_scent.c), never in
-- the eligibility policy: unsuitable weather (rain, snow, mist) waits
-- 20 ticks and reports the faded outcome; otherwise the screen tint fades in
-- with the scent sound, 22 ticks pass (maps with wild encounters only), and
-- the encounter roll either reports a started battle or fades the tint out
-- and reports nothing. The host seam (services.sweetScent) owns the weather
-- check, the tint, and the encounter roll; the sound plays through the
-- script audio service. Source basis: the retail ROM's Honey and Sweet Scent
-- task. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local SweetScentTask = {}

SweetScentTask.type = "sweet_scent"
SweetScentTask.version = 1

-- Script-visible outcome codes.
SweetScentTask.OUTCOME_NOTHING = 0
SweetScentTask.OUTCOME_WEATHER = 1
SweetScentTask.OUTCOME_BATTLE = 2

local SCENT_SOUND = "SEQ_SE_DP_FW230"
local BAD_WEATHER_WAIT = 20
local ENCOUNTER_WAIT = 22

local function host(ctx)
  local services = assert(ctx.services, "sweet scent requires its services")
  local scent = services.sweetScent
  if scent == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "sweet scent requires its host service", {})
  end
  return scent --[[@as table<string, unknown>]]
end

---@param _ table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown> state
function SweetScentTask.create(_, ctx)
  host(ctx)
  return { phase = "check_weather", timer = 0 }
end

local function finish(state, outcome)
  return { complete = true, state = state, result = outcome }
end

local function running(state)
  return { complete = false, state = state }
end

local function startFadeOut(state, scent)
  scent:startTint("out")
  state.phase = "wait_fade_out"
  return running(state)
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function SweetScentTask.poll(state, ctx)
  assert(type(state) == "table", "sweet scent polls its state")
  if state.cancelled ~= nil then
    error("cancelled sweet scent tasks never poll again", 0)
  end
  local scent = host(ctx)
  local phase = state.phase
  if phase == "check_weather" then
    if scent:weatherSuitable() then
      state.phase = "fade_in"
    else
      state.phase = "wait_bad_weather"
      state.timer = BAD_WEATHER_WAIT
    end
    return running(state)
  end
  if phase == "wait_bad_weather" then
    state.timer = state.timer - 1
    if state.timer < 0 then
      return finish(state, SweetScentTask.OUTCOME_WEATHER)
    end
    return running(state)
  end
  if phase == "fade_in" then
    scent:startTint("in")
    assert(ctx.services.audio, "sweet scent plays its sound through the audio service"):play(SCENT_SOUND)
    state.phase = "wait_fade_in"
    return running(state)
  end
  if phase == "wait_fade_in" then
    if scent:tintDone() then
      state.timer = ENCOUNTER_WAIT
      state.phase = "wait_encounter"
    end
    return running(state)
  end
  if phase == "wait_encounter" then
    state.timer = state.timer - 1
    if not scent:hasWildEncounters() then
      return startFadeOut(state, scent)
    end
    if state.timer < 0 then
      if scent:encounter() then
        return finish(state, SweetScentTask.OUTCOME_BATTLE)
      end
      return startFadeOut(state, scent)
    end
    return running(state)
  end
  assert(phase == "wait_fade_out", "unknown sweet scent phase " .. tostring(phase))
  if scent:tintDone() then
    scent:clearTint()
    return finish(state, SweetScentTask.OUTCOME_NOTHING)
  end
  return running(state)
end

-- A cancelled scent releases its tint through the live host; without a
-- context it only marks serializable state.
---@param state table<string, unknown>
---@param reason string
---@param ctx table<string, unknown>?
function SweetScentTask.cancel(state, reason, ctx)
  assert(type(state) == "table", "sweet scent cancel requires its state")
  if ctx ~= nil and ctx.services ~= nil and ctx.services.sweetScent ~= nil then
    ctx.services.sweetScent:clearTint()
  end
  state.cancelled = reason
end

---@param state table<string, unknown>
---@return Errors.Error|nil
function SweetScentTask.validate(state)
  if type(state) ~= "table" then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "sweet scent state must be a table", context)
  end
  return nil
end

return SweetScentTask
