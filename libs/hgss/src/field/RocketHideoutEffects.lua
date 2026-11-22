-- Rocket Hideout field effects: the source trap models, the alarm siren and the
-- powered prop projection (src/field/script_field_effects.c
-- Task_ShowTrapEffect/Task_ShowHideoutAlarm, overlay_03/shop_menu.c
-- ScrCmd_UpdateMapPropAnimsFromFlag96B and src/sys_vars.c map event keys).
--
-- One instance per live field with transient handles only. The trap and the
-- alarm are the source's blocking operations: they own their presented model,
-- their sound and the alarm overlay until the last clip and the siren finished,
-- and a cancellation releases them exactly once. The powered prop projection and
-- the map event key write settle in the same tick they are asked for. Nothing
-- here chooses a battle, writes a trap variable, changes the avatar or persists
-- a handle: the authored scripts own every one of those decisions, and the
-- field save coordinator refuses a capture while an effect owns the field.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")

---@class RocketHideoutTrapSource
---@field key string semantic trap kind the presented model factory selects
---@field sound string source sound the trap effect plays on its own

---@class RocketHideoutPowerProp
---@field memberId integer source map-prop member id the model list names
---@field intactClip integer source animation index of the undefeated prop
---@field defeatedClip integer source animation index of the defeated prop

---@class RocketHideoutEffectsOptions
---@field playerOf fun(): table<string, unknown> reads the live field player
---@field runtimeMapOf fun(): table<string, unknown>? reads the live runtime map
---@field audio table<string, unknown> the source audio host
---@field world table<string, unknown> source flag and variable store
---@field mapEventKeyVariableBase integer the numeric VAR_UNK_4036 the keys index
---@field electrodeFlagBase integer the numeric FLAG_UNK_96B the props index
---@field foregroundScript (fun(): string|nil)?

---@class RocketHideoutEffectModelFactory
---@field trap fun(kind: string): table<string, unknown>

---@class RocketHideoutEffects.TrapPresentation
---@field kind string
---@field x number
---@field y number
---@field z number
---@field rotationDegrees number
---@field model table<string, unknown>?

---@class RocketHideoutEffects.AlarmPresentation
---@field pulse integer zero-based source pulse under playback
---@field blend integer source blend level 0..12
---@field overlay table<string, unknown>? the presented source overlay handle

---@class RocketHideoutEffects.PowerPropSelection
---@field memberId integer source map-prop member id
---@field clipIndex integer selected source animation record

---@class RocketHideoutEffects.Presentation
---@field trap RocketHideoutEffects.TrapPresentation?
---@field alarm RocketHideoutEffects.AlarmPresentation?
---@field powerProps RocketHideoutEffects.PowerPropSelection[]?

---@class RocketHideoutEffects
---@field TRAPS RocketHideoutTrapSource[]
---@field POWER_PROPS RocketHideoutPowerProp[]
---@field private _playerOf fun(): table<string, unknown>
---@field private _runtimeMapOf fun(): table<string, unknown>?
---@field private _audio table<string, unknown>
---@field private _world table<string, unknown>
---@field private _mapEventKeyVariableBase integer
---@field private _electrodeFlagBase integer
---@field private _foregroundScript (fun(): string|nil)?
---@field private _ownerScript string?
---@field private _modelFactory RocketHideoutEffectModelFactory?
---@field private _trap table<string, unknown>?
---@field private _alarm table<string, unknown>?
---@field private _powerPropHandles table<integer, table<string, unknown>>
---@field private _powerPropSelection table<integer, integer>
---@field private _alarmOverlayFactory (fun(): table<string, unknown>)?
---@field private _alarmOverlay table<string, unknown>?
local RocketHideoutEffects = {}
RocketHideoutEffects.__index = RocketHideoutEffects

-- The three source trap kinds in their own selector order (sTrapEffects):
-- electric, poison and rock. Each selects its own archive model and the sound
-- its task plays by itself; the source scripts play their own trap sound too.
RocketHideoutEffects.TRAPS = {
  { key = "electric", sound = "SEQ_SE_GS_DENKI_TRAP" },
  { key = "poison", sound = "SEQ_SE_GS_DOKU_TRAP" },
  { key = "rock", sound = "SEQ_SE_GS_IWA_TRAP" },
}

-- The hideout alarm's own sound: the siren the wait state polls until it
-- finished (src/field/script_field_effects.c HIDEOUT_ALARM_STATE_WAIT_SIREN).
RocketHideoutEffects.ALARM_SOUND = "SEQ_SE_GS_AJITO_SIREN"

-- One source alpha pulse ramps the red overlay from blend 0 up to 12 and back
-- over 24 steps; the task runs two complete pulses before it waits for the
-- siren (Task_ShowHideoutAlarm: flashCount >= 1).
RocketHideoutEffects.ALARM_PULSE_STEPS = 24
RocketHideoutEffects.ALARM_PULSE_PEAK = 12
RocketHideoutEffects.ALARM_PULSES = 2

-- Save_VarsFlags_SetMapEventKey's own magic table (_020FE4A8 in src/sys_vars.c):
-- key 0..3 writes one of these into the matching VAR_UNK_4036 + key slot.
RocketHideoutEffects.MAP_EVENT_KEY_MAGIC = { 0x6208, 0xF229, 0x0382, 0x1228 }

-- The three powered Electrode props (sRocketHQElectrodePropModels in
-- overlay_03/shop_menu.c) and the two animation records their build models
-- declare: the intact prop plays its first record and the defeated prop its
-- second (CheckRocketHQElectrodeDefeated selects the record by FLAG_UNK_96B +
-- index).
RocketHideoutEffects.POWER_PROPS = {
  { memberId = 149, intactClip = 1, defeatedClip = 2 },
  { memberId = 152, intactClip = 1, defeatedClip = 2 },
  { memberId = 153, intactClip = 1, defeatedClip = 2 },
}

---@param options RocketHideoutEffectsOptions
---@return RocketHideoutEffects
function RocketHideoutEffects.new(options)
  assert(type(options) == "table", "the Rocket hideout effects need their collaborators")
  assert(type(options.playerOf) == "function", "the Rocket effects read the live field player through an accessor")
  assert(type(options.runtimeMapOf) == "function", "the Rocket effects read the live runtime map through an accessor")
  local audio = assert(options.audio, "the Rocket effects need the source audio host")
  assert(audio.play and audio.stop, "the Rocket effects need the source audio host")
  local world = assert(options.world, "the Rocket effects need the source flag and variable store")
  assert(type(world.isFlagSet) == "function" and type(world.setVar) == "function", "the world store answers flags")
  assert(
    type(options.mapEventKeyVariableBase) == "number",
    "the Rocket effects need the numeric map event key variable base"
  )
  assert(type(options.electrodeFlagBase) == "number", "the Rocket effects need the numeric electrode flag base")
  return setmetatable({
    _playerOf = options.playerOf,
    _runtimeMapOf = options.runtimeMapOf,
    _audio = audio,
    _world = world,
    _mapEventKeyVariableBase = options.mapEventKeyVariableBase,
    _electrodeFlagBase = options.electrodeFlagBase,
    _foregroundScript = options.foregroundScript,
    _ownerScript = nil,
    _modelFactory = nil,
    _trap = nil,
    _alarm = nil,
    _powerPropHandles = {},
    _powerPropSelection = {},
  }, RocketHideoutEffects)
end

-- The presented composition installs the source-model bridge once. A headless
-- composition never installs one: the effect then owns no visual at all and
-- every presentation call stays inert.
---@param factory RocketHideoutEffectModelFactory|nil
function RocketHideoutEffects:setModelFactory(factory)
  if factory ~= nil then
    assert(type(factory.trap) == "function", "the Rocket effect factory creates the source trap models")
  end
  self:_releaseTrapModel()
  self._modelFactory = factory
end

---@private
function RocketHideoutEffects:_releaseTrapModel()
  local trap = self._trap
  if trap == nil then
    return
  end
  local model = trap.model
  trap.model = nil
  if model ~= nil then
    model:dispose()
  end
end

---@return boolean
function RocketHideoutEffects:isRunning()
  return self._trap ~= nil or self._alarm ~= nil
end

-- A Rocket activation belongs to the script frame that started it: a capture
-- taken while that frame still owns the field would describe a field whose
-- effect has not finished returning control.
---@return boolean
function RocketHideoutEffects:isStableForSave()
  if self:isRunning() then
    return false
  end
  local owner = self._ownerScript
  if owner == nil then
    return true
  end
  local current = self._foregroundScript ~= nil and self._foregroundScript() or nil
  if current ~= owner then
    self._ownerScript = nil
    return true
  end
  return false
end

---@param kind unknown
---@return RocketHideoutTrapSource
local function requireTrap(kind)
  local source = type(kind) == "number" and RocketHideoutEffects.TRAPS[kind + 1] or nil
  if source == nil then
    Errors.raise(FieldErrors.FIELD_ROCKET_EFFECT_INVALID, "the trap effect selector is not a source trap kind", {
      kind = tostring(kind),
      trapCount = #RocketHideoutEffects.TRAPS,
    })
  end
  return source --[[@as RocketHideoutTrapSource]]
end

-- The source's own model anchor: the trap effect stands on the player avatar's
-- current position (PlayerAvatar_CopyPositionVector).
---@return RocketHideoutEffects.TrapPresentation
local function trapPresentation(self)
  local trap = assert(self._trap, "an active trap effect carries its record")
  local player = self._playerOf()
  assert(player ~= nil, "the trap effect needs the live field player")
  local runtimeMap = self._runtimeMapOf()
  assert(runtimeMap ~= nil, "the trap effect needs the live map")
  local point = FieldCoordinates.fieldToWorld(runtimeMap, player.fieldX, player.fieldZ, player.worldY)
  return {
    kind = trap.kind,
    x = point.x,
    y = point.y,
    z = point.z,
    rotationDegrees = 0,
    model = trap.model,
  }
end

---@return RocketHideoutEffects.AlarmPresentation
local function alarmPresentation(self)
  local alarm = assert(self._alarm, "an active alarm carries its record")
  return { pulse = alarm.pulse, blend = alarm.blend, overlay = self._alarmOverlay }
end

-- The immutable presentation snapshot the field draws this tick. The effect
-- owns the anchor, the pulse phase and the model handle, so a renderer only
-- applies what the snapshot carries.
---@return RocketHideoutEffects.Presentation
function RocketHideoutEffects:presentation()
  local presentation = {} ---@type RocketHideoutEffects.Presentation
  if self._trap ~= nil then
    presentation.trap = trapPresentation(self)
  end
  if self._alarm ~= nil then
    presentation.alarm = alarmPresentation(self)
  end
  local selections = {}
  for index, source in ipairs(RocketHideoutEffects.POWER_PROPS) do
    local clipIndex = self._powerPropSelection[index]
    if clipIndex ~= nil then
      selections[#selections + 1] = { memberId = source.memberId, clipIndex = clipIndex }
    end
  end
  if #selections > 0 then
    presentation.powerProps = selections
  end
  return presentation
end

-- Begin the one blocking Rocket action this effect owner will drive: the trap
-- model plus its source sound, or the alarm overlay plus the siren.
---@param action string
---@param operands table<string, unknown>|nil
function RocketHideoutEffects:begin(action, operands)
  if self:isRunning() then
    Errors.raise(FieldErrors.FIELD_ROCKET_EFFECT_INVALID, "another Rocket effect already owns the field", {
      action = action,
    })
  end
  self._ownerScript = self._foregroundScript ~= nil and self._foregroundScript() or nil
  if action == "rocket_trap" then
    local source = requireTrap(operands ~= nil and operands.kind or nil)
    local model = nil
    if self._modelFactory ~= nil then
      model = self._modelFactory.trap(source.key)
    end
    if model ~= nil then
      model:start()
    end
    self._audio:play(source.sound)
    self._trap = { kind = source.key, sound = source.sound, model = model, phase = "active" }
    return
  end
  if action == "rocket_alarm" then
    self._audio:play(RocketHideoutEffects.ALARM_SOUND)
    self._alarm = { phase = "active", pulse = 0, step = 0, blend = 0, pulsed = 0 }
    if self._alarmOverlayFactory ~= nil then
      self._alarmOverlay = self._alarmOverlayFactory()
    end
    return
  end
  Errors.raise(FieldErrors.FIELD_ROCKET_EFFECT_INVALID, "unknown Rocket effect action", {
    action = tostring(action),
  })
end

-- Advance the presented source model one fixed tick. Only the model's own clip
-- clock moves here: the effect neither advances gameplay state on this path nor
-- decides completion, which the blocking task polls through `step`.
function RocketHideoutEffects:updatePresentation()
  local trap = self._trap
  if trap ~= nil and trap.model ~= nil then
    trap.model:updateFixed()
  end
end

-- One fixed tick of the owned activation: the trap waits for its model clips and
-- its sound, the alarm runs its two alpha pulses and then waits for the siren.
-- Answers "complete" when nothing is left to wait for.
---@return string status
function RocketHideoutEffects:step()
  local trap = self._trap
  if trap ~= nil then
    local model = trap.model
    local clipsDone = model == nil or model:isComplete() == true
    local soundDone = true
    if type(self._audio.isEffectWaitComplete) == "function" then
      soundDone = self._audio:isEffectWaitComplete(trap.sound) == true
    end
    if not clipsDone or not soundDone then
      return "active"
    end
    self:_releaseTrapModel()
    self._trap = nil
    return "complete"
  end
  local alarm = self._alarm
  if alarm == nil then
    return "complete"
  end
  if alarm.pulsed < RocketHideoutEffects.ALARM_PULSES then
    local step = alarm.step
    alarm.blend = step <= RocketHideoutEffects.ALARM_PULSE_PEAK and step
      or (RocketHideoutEffects.ALARM_PULSE_STEPS - step)
    alarm.step = step + 1
    if step >= RocketHideoutEffects.ALARM_PULSE_STEPS then
      alarm.step = 0
      alarm.pulsed = alarm.pulsed + 1
      alarm.pulse = math.min(alarm.pulsed, RocketHideoutEffects.ALARM_PULSES - 1)
      alarm.blend = 0
    end
    return "active"
  end
  local sirenDone = true
  if type(self._audio.isEffectWaitComplete) == "function" then
    sirenDone = self._audio:isEffectWaitComplete(RocketHideoutEffects.ALARM_SOUND) == true
  end
  if not sirenDone then
    return "active"
  end
  self:_releaseAlarm()
  return "complete"
end

---@private
function RocketHideoutEffects:_releaseAlarm()
  if self._alarm == nil then
    return
  end
  self._alarm = nil
  self._alarmOverlay = nil
end

-- The source boolean a blocking Rocket command answers, taken exactly once by
-- the task that completed it. Both source operations return TRUE and write no
-- variable, so there is never one to hand back.
---@return integer|nil
function RocketHideoutEffects:takeResult()
  return nil
end

-- Cancel the owned activation: the trap releases its model and its sound, the
-- alarm restores the overlay and stops the siren. A repeated cancellation is a
-- clean no-op.
---@param _ string? cancellation reason, kept for the shared task protocol
function RocketHideoutEffects:cancelRide(_)
  local trap = self._trap
  if trap ~= nil then
    self._audio:stop(trap.sound)
    self:_releaseTrapModel()
    self._trap = nil
  end
  if self._alarm ~= nil then
    self._audio:stop(RocketHideoutEffects.ALARM_SOUND)
    self:_releaseAlarm()
  end
  self._ownerScript = nil
end

-- ScrCmd_MapEventKeyAction's same-tick write: a nonzero action stores the key's
-- own magic value in its world variable, zero clears that variable. The key is
-- the script's resolved value and names one of the four source slots.
---@param key integer resolved source key
---@param action integer source raw action byte
function RocketHideoutEffects:writeMapEventKey(key, action)
  assert(type(action) == "number" and action % 1 == 0, "the map event key action is a source byte")
  local magic = RocketHideoutEffects.MAP_EVENT_KEY_MAGIC[key + 1]
  if magic == nil then
    Errors.raise(FieldErrors.FIELD_ROCKET_EFFECT_INVALID, "the map event key is outside the source table", {
      key = tostring(key),
      keyCount = #RocketHideoutEffects.MAP_EVENT_KEY_MAGIC,
    })
  end
  self._world:setVar(self._mapEventKeyVariableBase + key, action ~= 0 and magic or 0)
end

-- The source member id a generated model key names, or nil when the key is not
-- the generated placement identity.
---@param modelKey unknown
---@return integer?
local function sourceMemberId(modelKey)
  local memberId = type(modelKey) == "string" and modelKey:match("^%a+:(%d+):")
  return memberId and tonumber(memberId) or nil
end

---@param runtimeMap table<string, unknown>
---@param memberId integer
---@return table<string, unknown>? prop
local function powerProp(runtimeMap, memberId)
  local mapProps = runtimeMap.mapProps
  if mapProps == nil then
    return nil
  end
  for _, placement in ipairs(mapProps.placements or {}) do
    if sourceMemberId(placement.modelKey) == memberId then
      return mapProps:prop(placement.placementIndex)
    end
  end
  return nil
end

-- ScrCmd_UpdateMapPropAnimsFromFlag96B: each of the three powered props replays
-- the animation record its own flags select, in the same tick. The source
-- asserts every prop render object exists, so a map without the prop is an
-- attributed fault rather than a silent skip. A headless composition owns no
-- live model instance for the prop (the source's render objects arrive with the
-- presented scene), so the projection records the selected record and presents
-- nothing, exactly like every other presentation-less field effect.
function RocketHideoutEffects:syncPowerProps()
  local runtimeMap = self._runtimeMapOf()
  assert(runtimeMap ~= nil, "the powered prop projection needs the live map")
  for index, source in ipairs(RocketHideoutEffects.POWER_PROPS) do
    local defeated = self._world:isFlagSet(self._electrodeFlagBase + index - 1) == true
    local clipIndex = defeated and source.defeatedClip or source.intactClip
    local prop = powerProp(runtimeMap, source.memberId)
    if prop == nil then
      Errors.raise(FieldErrors.FIELD_ROCKET_EFFECT_INVALID, "the powered prop is missing from its map", {
        mapId = runtimeMap.mapId,
        memberId = source.memberId,
      })
    end
    -- The raise above owns the missing-prop fault, so the projection only ever
    -- reads a live handle past it.
    prop = assert(prop)
    -- A repeated projection of the same record changes nothing: the source only
    -- ever re-registers the selected record's animation.
    if self._powerPropSelection[index] == clipIndex then
      self:_applyPowerProp(index, prop, clipIndex, false)
    else
      self:_applyPowerProp(index, prop, clipIndex, true)
      self._powerPropSelection[index] = clipIndex
    end
  end
end

---@private
---@param index integer one-based powered prop under projection
---@param prop table<string, unknown> the live prop handle of its map placement
---@param clipIndex integer source animation record index under selection
---@param restart boolean whether the selection changed and must replay
function RocketHideoutEffects:_applyPowerProp(index, prop, clipIndex, restart)
  local instance = prop.instance
  if instance == nil then
    return
  end
  local clip = (instance.definition.animations or {})[clipIndex]
  if clip == nil then
    Errors.raise(FieldErrors.FIELD_ROCKET_EFFECT_INVALID, "the powered prop carries no source animation record", {
      memberId = RocketHideoutEffects.POWER_PROPS[index].memberId,
      clipIndex = clipIndex,
    })
  end
  if not restart then
    return
  end
  -- The raise above owns the missing-record fault, so playback only ever reads
  -- a selected record past it.
  clip = assert(clip)
  prop:stopAll()
  self._powerPropHandles[index] = prop:playAll(clip.name, { loopMode = "loop" })
end

-- Rebind the presented powered prop selection to a newly loaded map: the
-- previous map's props are gone, so nothing is replayed over them.
function RocketHideoutEffects:bindMap()
  self._powerPropHandles = {}
  self._powerPropSelection = {}
end

function RocketHideoutEffects:unbind()
  self:cancelRide("the field retired")
  self:_releaseAlarm()
  self._modelFactory = nil
  self._alarmOverlayFactory = nil
  self._alarmOverlay = nil
  self._powerPropHandles = {}
  self._powerPropSelection = {}
end

-- The presented alarm overlay factory the rendering composition installs once:
-- one call claims the source red-overlay handle the alarm pulses.
---@param factory (fun(): table<string, unknown>)|nil
function RocketHideoutEffects:setOverlayFactory(factory)
  assert(factory == nil or type(factory) == "function", "the alarm overlay factory is a function")
  self._alarmOverlayFactory = factory
end

return RocketHideoutEffects
