-- The Cianwood Gym winch (src/field/gymmick/cianwood.c). The gym's own script
-- asks the winch to turn once: the source answers false for a wrong gym, a
-- missing mechanism runtime or an already raised winch, and otherwise commits
-- the raised bit at that same point and runs the cutscene task - the camera
-- pans (50, 0, 58) world units over 24 frames each way, the winch's props
-- replay their one-shot records, the task waits for winch record 0 to finish
-- and the camera pans back over 24 frames.
--
-- The winch's props are the map scene's own placements: source prop 173 is the
-- water surface, source prop 174 the waterfall whose records the source binds
-- onto the water's render object, and source prop 175 the winch itself whose
-- record 0 the source waits for. The runtime replays 174's records on the
-- water target and 175's record 0 on the winch, restoring those same bindings
-- on their last frame when the raised bit reloads.
--
-- A composition without live map-prop instances (the headless field) presents
-- nothing: the props then have no instance to play on, so their playback is
-- inert while the camera path and the settled bit stay exact.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local AnimationPlayer = require("libs.hgss.src.presentation.AnimationPlayer")

---@class CianwoodGymOptions
---@field state GymMechanismState the saved union this mechanism settles
---@field camera table<string, unknown>|nil the field camera the pan drives
---@field runtimeMap table<string, unknown>|nil the live map whose props the winch animates

---@class CianwoodGym
---@field private _state GymMechanismState
---@field private _camera table<string, unknown>|nil
---@field private _runtimeMap table<string, unknown>|nil
---@field private _phase string? the running cutscene phase
---@field private _waterProp table<string, unknown>|nil
---@field private _winchProp table<string, unknown>|nil
---@field private _waterPlays table<string, unknown>[] the water prop's one-shot plays
---@field private _winchPlays table<string, unknown>[] the winch prop's one-shot plays
local CianwoodGym = {}
CianwoodGym.__index = CianwoodGym

-- The source props (include/constants/buildmodel.h): BUILD_MODEL_MSG_TN01 is
-- the water surface, BUILD_MODEL_MSG_TN02 the waterfall whose records the
-- source rebinds onto the water's render object, and BUILD_MODEL_MSG_TN03
-- the winch itself
-- (CianwoodGymmick_RebindAnims looks all three ids up by render object).
CianwoodGym.WATER_PROP_MEMBER_ID = 173
CianwoodGym.WINCH_PROP_MEMBER_ID = 175

-- The producer binds source 174's record slots onto source 173's definition
-- and marks source 175's record 0 with these stable target-owned clip ids.
-- Runtime playback selects those exact clips, never source names or a live
-- placement of 174.
local WATER_CLIP_PREFIX = "cianwood.water."
local WINCH_CLIP_PREFIX = "cianwood.winch.0."

-- The source camera path: the look-at target moves (50, 0, 58) native world
-- units away from the player over 24 frames each way. There are 16 native
-- units per tile, so the tile-space offset the field camera consumes is
-- (3.125, 0, 3.625).
CianwoodGym.PAN_OFFSET = { x = 50 / 16, y = 0, z = 58 / 16 }
CianwoodGym.PAN_TICKS = 24

-- The generated placement identity carries the source member id:
-- "<indoor|outdoor>:<source member id>:<descriptor sha1 prefix>"
-- (romdump/src/digest/map/BuildingModelCompiler.lua).
---@param modelKey unknown
---@return integer|nil
local function sourceMemberId(modelKey)
  local memberId = type(modelKey) == "string" and modelKey:match("^%a+:(%d+):")
  return memberId and tonumber(memberId) or nil
end

-- The live scripted-prop handle of one source prop, or nil when the map has no
-- such placement or no presentation loaded its instance.
---@param runtimeMap table<string, unknown>|nil
---@param memberId integer
---@return table<string, unknown>|nil
local function propFor(runtimeMap, memberId)
  if runtimeMap == nil then
    return nil
  end
  local mapProps = runtimeMap.coverage or runtimeMap.mapProps
  if mapProps == nil or mapProps.placements == nil then
    return nil
  end
  for _, placement in ipairs(mapProps.placements) do
    if sourceMemberId(placement.modelKey) == memberId then
      return mapProps:prop(placement.placementIndex)
    end
  end
  return nil
end

-- The one live instance a prop presents, or nil when the composition loaded no
-- presentation for it.
---@param prop table<string, unknown>|nil
---@return table<string, unknown>|nil instance
local function liveInstance(prop)
  if prop == nil then
    return nil
  end
  return prop.instance
end

-- The exact target-owned clips bound by the producer for one source record
-- set. A presented target without its binding is a generated-data fault; a
-- headless target simply has no clips to play.
---@param prop table<string, unknown>|nil
---@param prefix string
---@return table<string, unknown>[]
local function boundClips(prop, prefix)
  local instance = liveInstance(prop)
  if instance == nil then
    return {}
  end
  local clips = {}
  for _, clip in ipairs(instance.definition.animations or {}) do
    if clip.id:sub(1, #prefix) == prefix then
      clips[#clips + 1] = clip
    end
  end
  assert(#clips > 0, "the Cianwood prop is missing its producer-bound animation clips")
  return clips
end

-- Replay or settle exact target-owned clips. `SceneProp:play` routes through
-- ModelInstance:play, so one-shot options and bounded players obey the same
-- contract as every other model playback.
---@param prop table<string, unknown>|nil
---@param clips table<string, unknown>[]
---@param atEnd boolean?
---@return table<string, unknown>[]
local function playClips(prop, clips, atEnd)
  if liveInstance(prop) == nil then
    return {}
  end
  assert(prop):stopAll()
  local handles = {}
  for _, clip in ipairs(clips) do
    local opts
    if atEnd then
      opts = { player = AnimationPlayer.atEnd(clip) }
    else
      opts = { loopMode = "once" }
    end
    handles[#handles + 1] = assert(prop):play(clip.id, opts)
  end
  return handles
end

-- The source's GymmickInit_Cianwood settle: a raised winch restores the bound
-- records on their last frame, so a reloaded gym shows the winch where its
-- one-shot ended. The water target restores every 174 record, the winch
-- restores only its record 0, each paused there, matching
-- MapPropAnimationData_SetAnimationPaused(TRUE) with
-- MapPropAnimationData_GoToLastAnimationFrame.
---@param runtimeMap table<string, unknown>|nil
function CianwoodGym.restoreSettled(runtimeMap)
  local water = propFor(runtimeMap, CianwoodGym.WATER_PROP_MEMBER_ID)
  if water ~= nil and liveInstance(water) ~= nil then
    playClips(water, boundClips(water, WATER_CLIP_PREFIX), true)
  end
  local winch = propFor(runtimeMap, CianwoodGym.WINCH_PROP_MEMBER_ID)
  if winch ~= nil and liveInstance(winch) ~= nil then
    playClips(winch, boundClips(winch, WINCH_CLIP_PREFIX), true)
  end
end

---@param options CianwoodGymOptions
---@return CianwoodGym
function CianwoodGym.new(options)
  assert(type(options) == "table", "the cianwood winch needs its collaborators")
  assert(options.state and options.state.cianwoodWinchRaised, "the cianwood winch owns the saved union")
  return setmetatable({
    _state = options.state,
    _camera = options.camera,
    _runtimeMap = options.runtimeMap,
    _phase = nil,
    _waterProp = nil,
    _winchProp = nil,
    _waterPlays = {},
    _winchPlays = {},
  }, CianwoodGym)
end

-- CianwoodGymmick_ActivateWinch: the source's own refusal order - wrong gym,
-- then a missing mechanism runtime, then the already raised winch. An accepted
-- activation commits the raised bit at this point and starts the cutscene.
---@return boolean accepted
function CianwoodGym:activate()
  if self._state:kind() ~= "cianwood" then
    return false
  end
  if self._runtimeMap == nil then
    return false
  end
  if self._state:cianwoodWinchRaised() then
    return false
  end
  local camera = self._camera
  if camera == nil or camera.startTranslation == nil then
    Errors.raise(FieldErrors.FIELD_GYM_MECHANISM_INVALID, "the cianwood winch needs the field camera", {})
  end
  self._state:setCianwoodWinchRaised(true)
  self._waterProp = propFor(self._runtimeMap, CianwoodGym.WATER_PROP_MEMBER_ID)
  self._winchProp = propFor(self._runtimeMap, CianwoodGym.WINCH_PROP_MEMBER_ID)
  self._phase = "pan"
  return true
end

-- One fixed tick of the cutscene task
-- (Task_CianwoodGymmick_LiftWinchCutscene): one source state per tick, with
-- the source's distinct START_ANIM and PAN_BACK states preserved instead of
-- folding them into the preceding wait completions.
function CianwoodGym:updateFixed()
  local phase = self._phase
  if phase == nil or phase == "done" then
    return
  end
  local camera = assert(self._camera, "the running winch owns the field camera")
  if phase == "pan" then
    camera:startTranslation(CianwoodGym.PAN_OFFSET, CianwoodGym.PAN_TICKS)
    self._phase = "wait_pan"
    return
  end
  if phase == "wait_pan" then
    if not camera:isTranslationFinished() then
      return
    end
    self._phase = "start_anim"
    return
  end
  if phase == "start_anim" then
    self:_startWinchAnimation()
    self._phase = "wait_anim"
    return
  end
  if phase == "wait_anim" then
    if not self:_isWinchAnimationFinished() then
      return
    end
    self._phase = "pan_back"
    return
  end
  if phase == "pan_back" then
    local offset = CianwoodGym.PAN_OFFSET
    camera:startTranslation({ x = -offset.x, y = -offset.y, z = -offset.z }, CianwoodGym.PAN_TICKS)
    self._phase = "wait_return"
    return
  end
  if not camera:isTranslationFinished() then
    return
  end
  self._phase = "done"
end

---@return boolean
function CianwoodGym:isComplete()
  return self._phase == nil or self._phase == "done"
end

-- WINCH_STATE_START_ANIM: the producer-bound waterfall records and winch
-- record 0 restart from their first frame and play once.
function CianwoodGym:_startWinchAnimation()
  self._waterPlays = playClips(self._waterProp, boundClips(self._waterProp, WATER_CLIP_PREFIX))
  self._winchPlays = playClips(self._winchProp, boundClips(self._winchProp, WINCH_CLIP_PREFIX))
end

-- WINCH_STATE_WAIT_ANIM waits for prop 175's animation to finish, never for an
-- elapsed estimate; a prop with no live instance has no animation clock to wait
-- for.
---@return boolean
function CianwoodGym:_isWinchAnimationFinished()
  local winchProp = self._winchProp
  if liveInstance(winchProp) == nil then
    return true
  end
  return assert(winchProp):arePlaysFinished(self._winchPlays)
end

-- Cancel the cutscene: the source deletes its camera wrapper and leaves the
-- props where the task stopped, and the committed raised bit stays committed.
---@param _ string?
function CianwoodGym:cancel(_)
  if self._phase == nil or self._phase == "done" then
    return
  end
  local camera = self._camera
  if camera ~= nil and camera.abandonTranslation ~= nil then
    camera:abandonTranslation()
  end
  self._phase = "done"
end

-- Release the live play handles exactly once. A completed cutscene leaves the
-- records where they finished, exactly like the source's finished one-shot, so
-- only the tracking drops here.
function CianwoodGym:dispose()
  self._waterPlays = {}
  self._winchPlays = {}
end

return CianwoodGym
