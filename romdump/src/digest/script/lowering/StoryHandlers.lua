-- Gym and Rocket story lowerings. The five gyms drive the port's closed native
-- mechanism union through one family of semantic nodes: the six init commands
-- install their own kind with no operands, the lift and the candle binding
-- commands carry none either, and the spider ride, the switch flip and the
-- candle's own selector read their operands as literal bytes (ScriptReadByte),
-- never as script variables. The winch's single operand is the output variable
-- the source boolean lands in (ScriptGetVarPointer), so it lowers as a value
-- reference. They live here so their names never become more file-scoped
-- locals in the main field-handler chunk.
--
-- The Rocket hideout's own commands join the same leaf: the trap selector is
-- read through ScriptGetVar, the alarm and the powered-prop projection carry no
-- operands, the map event key is a ScriptGetVar key with a raw action byte, the
-- costume check writes the costume flag into an output variable while the
-- costume action reads a raw mode byte, and the follower inhibit reads a raw
-- byte too.

local Operands = require("romdump.src.digest.script.lowering.Operands")
local SummarySources = require("romdump.src.config.SummarySources")

---@class StoryHandlers
local StoryHandlers = {}

-- The Rocket costume's own source flag identity (Save_VarsFlags_Check/Set/
-- ClearRocketCostumeFlag read FLAG_SYS_ROCKET_COSTUME). The flag travels as the
-- symbol the world store resolves, never as a raw number.
StoryHandlers.ROCKET_COSTUME_FLAG = "FLAG_SYS_ROCKET_COSTUME"
local ROCKET_COSTUME_FLAG = StoryHandlers.ROCKET_COSTUME_FLAG

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

-- ScrCmd_PlayTrapEffect reads its kind through ScriptGetVar, loads that kind's
-- archive model, anchors it to the player and blocks until every clip and the
-- trap sound finished. The hazard itself only presents the effect: the authored
-- script owns the sound, the trap battle and the spent variable.
function StoryHandlers.playTrapEffect(ins)
  return { op = "rocket_trap_effect", kind = Operands.varRef(ins.operands[1]) }
end

-- ScrCmd_PlayHideoutAlarm takes no operands: it loads the source red overlay,
-- runs two alpha pulses and blocks until the siren stopped.
function StoryHandlers.playHideoutAlarm(_)
  return { op = "rocket_alarm" }
end

-- ScrCmd_UpdateMapPropAnimsFromFlag96B takes no operands and returns FALSE: the
-- three powered props replay the record their own flags select in that tick.
function StoryHandlers.updateMapPropAnimsFromFlag96B(_)
  return { op = "rocket_power_props" }
end

-- ScrCmd_MapEventKeyAction reads its key slot through ScriptGetVar and its
-- action as a raw byte; a nonzero action writes that slot's source magic value
-- into its own world variable, zero clears it. The node keeps the slot under its
-- own name: `key` is the compiler's node identity, never an operand.
function StoryHandlers.mapEventKeyAction(ins)
  local action = Operands.operandValue(ins.operands[2])
  assert(isByte(action), "map event key action must be a source byte")
  return { op = "map_event_key", slot = Operands.varRef(ins.operands[1]), action = action }
end

-- ScrCmd_RocketCostumeFlagCheck writes the Rocket costume flag into its output
-- variable and returns FALSE.
function StoryHandlers.rocketCostumeFlagCheck(ins)
  return { op = "rocket_costume_check", flag = ROCKET_COSTUME_FLAG, result = Operands.varRef(ins.operands[1]) }
end

-- ScrCmd_RocketCostumeFlagAction reads one raw byte where nonzero sets the
-- Rocket costume flag and zero clears it, and returns FALSE. The avatar stays
-- untouched: the authored avatar commands own the outfit.
function StoryHandlers.rocketCostumeFlagAction(ins)
  local mode = Operands.operandValue(ins.operands[1])
  assert(isByte(mode), "rocket costume selector must be a source byte")
  return { op = "rocket_costume_action", flag = ROCKET_COSTUME_FLAG, mode = mode }
end

-- ScrCmd_SetFollowMonInhibitState reads one raw byte and writes the durable
-- follower inhibit bit in the same tick.
function StoryHandlers.setFollowMonInhibitState(ins)
  local inhibited = Operands.operandValue(ins.operands[1])
  assert(isByte(inhibited), "follow-mon inhibit selector must be a source byte")
  return { op = "follower_set_inhibited", inhibited = inhibited }
end

-- ScrCmd_HOFCredits reads one RAW halfword (ScriptReadHalfword, never a script
-- variable) naming the Red battle's outcome for this ending, then runs the
-- game-clear task: the script stays blocked until the ending returned.
function StoryHandlers.hofCredits(ins)
  local vsRed = Operands.operandValue(ins.operands[1])
  assert(type(vsRed) == "number" and vsRed % 1 == 0 and vsRed >= 0, "HOFCredits reads one raw halfword")
  return { op = "hof_credits", vsRed = vsRed }
end

-- ScrCmd_HallOfFameAnim reads the non-Egg party count through ScriptGetVar and
-- starts the machine's own blocking ball effect (Task_HallOfFameBallAnim); the
-- script continues only after the balls' one-shot clip finished.
function StoryHandlers.hallOfFameAnim(ins)
  return { op = "hall_of_fame_anim", count = Operands.varRef(ins.operands[1]) }
end

-- ScrCmd_GiveRibbon reads the party slot and the source ribbon identity through
-- ScriptGetVar. The retail ribbon table maps that identity to the mon-data
-- field the source writes; the summary family already transcribes that same
-- table (SummarySources.ribbons, source order), so the lowering resolves the
-- identity once to its stored boxed ribbon bit instead of duplicating it.
function StoryHandlers.giveRibbon(ins)
  local ribbonId = Operands.operandValue(ins.operands[2])
  assert(isByte(ribbonId), "give ribbon names a source ribbon identity")
  local definition = SummarySources.ribbons[ribbonId + 1]
  assert(definition ~= nil, "give ribbon names a source ribbon outside the retail table")
  return {
    op = "give_ribbon",
    slot = Operands.varRef(ins.operands[1]),
    ribbonField = definition.bitGroup,
    ribbonBit = definition.bit,
  }
end

-- ScrCmd_GetHallOfFameEntryCount writes the source's newest recorded number
-- through ScriptGetVarPointer and returns TRUE, so it costs one source tick.
function StoryHandlers.hallOfFameEntryCount(ins)
  return { op = "pc_hof_count", result = Operands.varRef(ins.operands[1]) }
end

return StoryHandlers
