-- Owns source one-shot prop slots for one active runtime map.

---@class FieldScriptPropAnimations
---@field private runtimeMap table<string, unknown>|nil
---@field private slots table<integer, table<string, unknown>>
local FieldScriptPropAnimations = {}
FieldScriptPropAnimations.__index = FieldScriptPropAnimations

---@return FieldScriptPropAnimations
function FieldScriptPropAnimations.new()
  return setmetatable({ runtimeMap = nil, slots = {} }, FieldScriptPropAnimations)
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
  self.runtimeMap = runtimeMap
end

function FieldScriptPropAnimations:load(slot, fieldX, fieldZ)
  validSlot(slot)
  assert(self.runtimeMap and self.runtimeMap.mapProps, "active map has no map-prop owner")
  assert(self.slots[slot] == nil, "prop animation slot is already loaded: " .. tostring(slot))
  local mapProps = self.runtimeMap.mapProps
  local door = mapProps:doorAt(self.runtimeMap, fieldX, fieldZ)
  if door ~= nil then
    assert(door.instance ~= nil, "door prop has no animatable model instance")
    self.slots[slot] = { runtimeMap = self.runtimeMap, door = door, playback = nil, direction = nil }
    return
  end
  local prop = mapProps:scriptPropAt(self.runtimeMap, fieldX, fieldZ)
  assert(prop ~= nil and prop.instance ~= nil, "no animatable prop at field coordinate")
  self.slots[slot] = { runtimeMap = self.runtimeMap, prop = prop, playback = nil, direction = nil }
end

function FieldScriptPropAnimations:play(slot, direction)
  local record = requireSlot(self, slot)
  assert(direction == "forward" or direction == "reverse", "prop animation direction is invalid")
  assert(record.playback == nil, "prop animation slot is already playing")
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
  if record.door ~= nil then
    return record.door:isFinished()
  end
  return record.playback.player:isComplete()
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
  self.runtimeMap = nil
end

return FieldScriptPropAnimations
