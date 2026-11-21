-- Gym mechanism lowerings. The Violet and Azalea gyms drive the port's closed
-- native mechanism union through one family of semantic nodes: the two init
-- commands install their own kind with no operands, the lift has no operands,
-- and the spider ride and switch read their source operands as literal bytes
-- (ScriptReadByte), never as script variables. They live here so their names
-- never become more file-scoped locals in the main field-handler chunk.

local Operands = require("romdump.src.digest.script.lowering.Operands")

---@class StoryHandlers
local StoryHandlers = {}

---@param value unknown
---@return boolean
local function isByte(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 0xFF
end

-- ScrCmd_VioletGymInit: InitVioletGym installs GYMMICK_VIOLET and returns
-- FALSE, so the following command runs in the same tick.
function StoryHandlers.violetGymInit(_)
  return { op = "gym_init", kind = "violet" }
end

-- ScrCmd_VioletGymElevator: VioletGymmick_ElevatorAction starts the blocking
-- lift task and returns TRUE.
function StoryHandlers.violetGymElevator(_)
  return { op = "gym_elevator" }
end

-- ScrCmd_AzaleaGymInit: InitAzaleaGym installs GYMMICK_AZALEA and returns
-- FALSE.
function StoryHandlers.azaleaGymInit(_)
  return { op = "gym_init", kind = "azalea" }
end

-- ScrCmd_AzaleaGymSpinarak reads one literal endpoint selector, starts the
-- blocking ride task and returns TRUE. The selector names the endpoint the
-- spider currently stands on, not the spider slot.
function StoryHandlers.azaleaGymSpinarak(ins)
  local selector = Operands.operandValue(ins.operands[1])
  assert(isByte(selector), "azalea spider selector must be a source byte")
  return { op = "gym_spinarak", selector = selector }
end

-- ScrCmd_AzaleaGymSwitch reads one literal switch number, flips its bit and
-- blocks until the flip sound finished.
function StoryHandlers.azaleaGymSwitch(ins)
  local switchNumber = Operands.operandValue(ins.operands[1])
  assert(isByte(switchNumber), "azalea switch selector must be a source byte")
  return { op = "gym_switch", switchNumber = switchNumber }
end

return StoryHandlers
