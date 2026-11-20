-- Owns source one-shot prop slots and the source elevator animation for one
-- active runtime map.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")

---@class FieldScriptPropAnimations
---@field private runtimeMap table<string, unknown>|nil
---@field private slots table<integer, table<string, unknown>>
---@field private elevator table<string, unknown>|nil
local FieldScriptPropAnimations = {}
FieldScriptPropAnimations.__index = FieldScriptPropAnimations

-- The source elevator prop (MAP_PROP_ELEVATOR in src/field/map_prop_anims.c)
-- is the building model whose member id the source prop id names.
local ELEVATOR_PROP_MEMBER = 0xD0
-- The source loads two one-shot animations and selects one by direction.
local ELEVATOR_DIRECTION_COUNT = 2

---@return FieldScriptPropAnimations
function FieldScriptPropAnimations.new()
  return setmetatable({ runtimeMap = nil, slots = {}, elevator = nil }, FieldScriptPropAnimations)
end

local function validSlot(slot)
  assert(type(slot) == "number" and slot % 1 == 0 and slot >= 0 and slot <= 255, "prop animation slot must be a byte")
end

local function requireSlot(self, slot)
  validSlot(slot)
  local record = self.slots[slot]
  assert(record ~= nil, "prop animation slot is not loaded: " .. tostring(slot))
  assert(record.runtimeMap == self.runtimeMap, "prop animation slot belongs to a stale map")
  return record
end

function FieldScriptPropAnimations:bindMap(runtimeMap)
  assert(type(runtimeMap) == "table", "prop animation map is required")
  self.slots = {}
  self.elevator = nil
  self.runtimeMap = runtimeMap
end

function FieldScriptPropAnimations:load(slot, fieldX, fieldZ)
  validSlot(slot)
  local runtimeMap = assert(self.runtimeMap, "prop animations are not bound to a map")
  -- Outdoor maps resolve props through the committed physical cells.
  local mapProps = runtimeMap.coverage or runtimeMap.mapProps
  assert(mapProps, "active map has no map-prop owner")
  assert(self.slots[slot] == nil, "prop animation slot is already loaded: " .. tostring(slot))
  local door = mapProps:doorAt(self.runtimeMap, fieldX, fieldZ)
  if door ~= nil then
    self.slots[slot] = { runtimeMap = self.runtimeMap, door = door, playback = nil, direction = nil }
    return
  end
  local prop = mapProps:scriptPropAt(self.runtimeMap, fieldX, fieldZ)
  assert(prop ~= nil and prop.instance ~= nil, "no animatable prop at field coordinate")
  self.slots[slot] = { runtimeMap = self.runtimeMap, prop = prop, playback = nil, direction = nil }
end

local function playbackFinished(record)
  if record.door ~= nil then
    -- nil: a static door has nothing to wait for.
    return record.door:isFinished() ~= false
  end
  return record.playback.player:isComplete()
end

-- A finished slot may be replayed in either direction without reloading.
function FieldScriptPropAnimations:play(slot, direction)
  local record = requireSlot(self, slot)
  assert(direction == "forward" or direction == "reverse", "prop animation direction is invalid")
  assert(record.playback == nil or playbackFinished(record), "prop animation slot is already playing")
  if record.door ~= nil then
    local sound = direction == "forward" and record.door:open() or record.door:close()
    record.playback = record.door
    record.sound = sound
  else
    local role = direction == "forward" and "door.open" or "door.close"
    local playback = record.prop:play(role, { loopMode = "once" })
    assert(playback ~= nil, "prop animation did not create a playback attachment")
    record.playback = playback
  end
  record.direction = direction
end

function FieldScriptPropAnimations:isFinished(slot)
  local record = requireSlot(self, slot)
  assert(record.playback ~= nil, "prop animation slot has no active playback")
  return playbackFinished(record)
end

function FieldScriptPropAnimations:takeSound(slot)
  local record = requireSlot(self, slot)
  local sound = record.sound
  record.sound = nil
  return sound
end

function FieldScriptPropAnimations:unload(slot)
  validSlot(slot)
  assert(self.slots[slot] ~= nil, "prop animation slot is not loaded: " .. tostring(slot))
  self.slots[slot] = nil
end

function FieldScriptPropAnimations:clear()
  self.slots = {}
  self.elevator = nil
  self.runtimeMap = nil
end

-- The live elevator prop of the bound map, or nil when the map carries none.
---@return table<string, unknown>|nil
local function elevatorProp(self)
  local runtimeMap = self.runtimeMap
  if runtimeMap == nil then
    return nil
  end
  local mapProps = runtimeMap.mapProps
  if mapProps == nil then
    return nil
  end
  for _, placement in ipairs(mapProps.placements) do
    local instance = mapProps.instances[placement.placementIndex]
    if instance ~= nil and instance.definition ~= nil and instance.definition.memberId == ELEVATOR_PROP_MEMBER then
      return mapProps:prop(placement.placementIndex)
    end
  end
  return nil
end

---@return table<string, unknown>
local function requireElevator(self)
  local record = self.elevator
  assert(record ~= nil, "no elevator animation is loaded")
  return record
end

-- Load the elevator's source one-shot animations. `length` is the source
-- command's frame count; the compiled model clip carries the animation's own
-- duration, so only the source halfword domain is validated here.
---@param length integer
function FieldScriptPropAnimations:loadAnimation(length)
  assert(
    type(length) == "number" and length % 1 == 0 and length > 0 and length <= 0xFFFF,
    "elevator animation length must be a source halfword"
  )
  assert(self.elevator == nil, "an elevator animation is already loaded")
  local runtimeMap = assert(self.runtimeMap, "prop animations are not bound to a map")
  local prop = elevatorProp(self)
  if prop == nil then
    Errors.raise(FieldErrors.FIELD_ELEVATOR_PROP_MISSING, "the active map has no elevator prop", {
      mapId = runtimeMap.mapId,
    })
  end
  local instance = assert(prop).instance --[[@as table<string, unknown>|nil]]
  assert(instance ~= nil, "the elevator prop has no live model instance")
  local definition = instance.definition --[[@as table<string, unknown>]]
  local clips = assert(definition.animations, "the elevator model carries compiled animations") --[[@as table[] ]]
  for index = 1, ELEVATOR_DIRECTION_COUNT do
    assert(clips[index] ~= nil, "the elevator model carries both source direction animations")
  end
  self.elevator = { runtimeMap = runtimeMap, prop = prop, clips = { clips[1], clips[2] }, active = nil }
end

-- Play the source direction's one-shot animation.
---@param direction integer source direction 0 or 1
function FieldScriptPropAnimations:playAnimation(direction)
  local record = requireElevator(self)
  assert(direction == 0 or direction == 1, "elevator animation direction must be the source pair")
  assert(record.active == nil, "the elevator animation is already playing")
  local clip = assert(record.clips[direction + 1])
  record.active = clip.name
  local handle = record.prop:play(clip.name, { loopMode = "once" })
  assert(handle ~= nil, "elevator prop animation did not create a playback attachment")
end

-- Whether the playing source animation reached its end.
---@return boolean
function FieldScriptPropAnimations:isAnimationLoopFinished()
  local record = requireElevator(self)
  local active = assert(record.active, "the elevator animation is not playing")
  return record.prop:isFinished(active) == true
end

-- Release the source-loaded elevator animation. A map rebind already released
-- the previous map's slot, so a later cancellation of the task that owned it
-- is a clean no-op rather than a release of nothing.
function FieldScriptPropAnimations:unloadAnimation()
  local record = self.elevator
  if record == nil then
    return
  end
  if record.active ~= nil then
    record.prop:stop(record.active)
  end
  self.elevator = nil
end

return FieldScriptPropAnimations
