-- Gym mechanism lowerings. The five gyms drive the port's closed native
-- mechanism union through one family of semantic nodes: the six init commands
-- install their own kind with no operands, the lift and the candle binding
-- commands carry none either, and the spider ride, the switch flip and the
-- candle's own selector read their operands as literal bytes (ScriptReadByte),
-- never as script variables. The winch's single operand is the output variable
-- the source boolean lands in (ScriptGetVarPointer), so it lowers as a value
-- reference. They live here so their names never become more file-scoped
-- locals in the main field-handler chunk.

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

-- ScrCmd_EcruteakGymInit: InitEcruteakGym installs GYMMICK_ECRUTEAK with four
-- unburnt candles and returns FALSE.
function StoryHandlers.ecruteakGymInit(_)
  return { op = "gym_init", kind = "ecruteak" }
end

-- ScrCmd_EcruteakGymBindCandleToTrainer reads the engaged trainer of slot 0
-- from the script environment and starts the source follow task; it returns
-- FALSE, so the following command runs in the same tick.
function StoryHandlers.ecruteakGymBindCandle(_)
  return { op = "gym_candle_bind" }
end

-- ScrCmd_EcruteakGymUnbindCandleFromTrainer ends that follow task and returns
-- FALSE.
function StoryHandlers.ecruteakGymUnbindCandle(_)
  return { op = "gym_candle_unbind" }
end

-- ScrCmd_EcruteakGymExtinguishCandle reads one literal selector byte: nonzero
-- names the last interacted actor, zero the engaged trainer of slot 0. It
-- starts the blocking shrink task and returns TRUE.
function StoryHandlers.ecruteakGymExtinguishCandle(ins)
  local useLastInteracted = Operands.operandValue(ins.operands[1])
  assert(isByte(useLastInteracted), "ecruteak candle selector must be a source byte")
  return { op = "gym_candle_extinguish", useLastInteracted = useLastInteracted }
end

-- ScrCmd_CianwoodGymInit: InitCianwoodGym installs GYMMICK_CIANWOOD and returns
-- FALSE.
function StoryHandlers.cianwoodGymInit(_)
  return { op = "gym_init", kind = "cianwood" }
end

-- ScrCmd_BlackthornGymInit: InitBlackthornGym installs GYMMICK_BLACKTHORN with
-- its three source platforms and returns FALSE. The platforms act on completed
-- player steps, so the command installs state and nothing else.
function StoryHandlers.blackthornGymInit(_)
  return { op = "gym_init", kind = "blackthorn" }
end

-- ScrCmd_CianwoodGymTurnWinch reads the output variable a halfword names, writes
-- the source boolean there and returns TRUE: the cutscene it may start runs as
-- the blocking mechanism task.
function StoryHandlers.cianwoodGymTurnWinch(ins)
  return { op = "gym_winch", result = Operands.varRef(ins.operands[1]) }
end

return StoryHandlers
