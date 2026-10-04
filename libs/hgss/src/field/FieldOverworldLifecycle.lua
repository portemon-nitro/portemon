-- Owns the blocking semantic presence of the HGSS field overworld.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")

---@class FieldOverworldLifecycle
---@field private state string
---@field private failure Errors.Error|nil
local FieldOverworldLifecycle = {}
FieldOverworldLifecycle.__index = FieldOverworldLifecycle

FieldOverworldLifecycle.PHASES = {
  PRESENT = "present",
  LEAVING = "leaving",
  ABSENT = "absent",
  RESTORING = "restoring",
  FAILED = "failed",
}

---@return FieldOverworldLifecycle
function FieldOverworldLifecycle.new()
  return setmetatable({ state = FieldOverworldLifecycle.PHASES.PRESENT, failure = nil }, FieldOverworldLifecycle)
end

local function invalid(message, phase)
  Errors.raise(FieldErrors.FIELD_OVERWORLD_LIFECYCLE_INVALID, message, { phase = phase })
end

function FieldOverworldLifecycle:requestLeave()
  if self.state ~= FieldOverworldLifecycle.PHASES.PRESENT then
    invalid("overworld leave requires present phase", self.state)
  end
  self.state = FieldOverworldLifecycle.PHASES.LEAVING
end

function FieldOverworldLifecycle:requestRestore()
  if self.state ~= FieldOverworldLifecycle.PHASES.ABSENT then
    invalid("overworld restore requires absent phase", self.state)
  end
  self.state = FieldOverworldLifecycle.PHASES.RESTORING
end

---@return string phase, Errors.Error|nil failure
function FieldOverworldLifecycle:phase()
  return self.state, self.failure
end

---@return boolean
function FieldOverworldLifecycle:isPresent()
  return self.state == FieldOverworldLifecycle.PHASES.PRESENT
end

-- One fixed boundary is the semantic equivalent of the retail task-owned
-- overlay handoff. The operation is deliberately independent of screen fades.
function FieldOverworldLifecycle:updateFixed()
  if self.state == FieldOverworldLifecycle.PHASES.LEAVING then
    self.state = FieldOverworldLifecycle.PHASES.ABSENT
  elseif self.state == FieldOverworldLifecycle.PHASES.RESTORING then
    self.state = FieldOverworldLifecycle.PHASES.PRESENT
  end
end

function FieldOverworldLifecycle:fail(err)
  assert(err ~= nil, "lifecycle failure requires an error")
  self.failure = err
  self.state = FieldOverworldLifecycle.PHASES.FAILED
end

function FieldOverworldLifecycle:dispose()
  self.state = FieldOverworldLifecycle.PHASES.FAILED
end

return FieldOverworldLifecycle
