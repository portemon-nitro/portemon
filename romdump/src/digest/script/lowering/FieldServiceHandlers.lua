-- Field service, lifecycle, query, prop-animation, and heal lowerings.
-- They live here so their names never become more file-scoped locals
-- in the main field-handler chunk.

local Operands = require("romdump.src.digest.script.lowering.Operands")

---@class FieldServiceHandlers
local FieldServiceHandlers = {}

function FieldServiceHandlers.overworldLeave(_)
  return { op = "overworld_leave" }
end

function FieldServiceHandlers.currentMapId(ins)
  return { op = "current_map_id", result = Operands.varRef(ins.operands[1]) }
end

function FieldServiceHandlers.playerState(ins)
  return { op = "player_state", result = Operands.varRef(ins.operands[1]) }
end

function FieldServiceHandlers.timeOfDay(ins)
  return { op = "time_of_day", result = Operands.varRef(ins.operands[1]) }
end

function FieldServiceHandlers.weekday(ins)
  return { op = "weekday", result = Operands.varRef(ins.operands[1]) }
end

function FieldServiceHandlers.discardValue(ins)
  return { op = "discard_value", value = Operands.varRef(ins.operands[1]) }
end

function FieldServiceHandlers.trainerCardStars(ins)
  return { op = "trainer_card_stars", result = Operands.varRef(ins.operands[1]) }
end

function FieldServiceHandlers.propAnimationLoad(ins)
  local chunkX = Operands.operandValue(ins.operands[1])
  local chunkZ = Operands.operandValue(ins.operands[2])
  local localX = Operands.varRef(ins.operands[3])
  local localZ = Operands.varRef(ins.operands[4])
  assert(type(chunkX) == "number" and type(chunkZ) == "number", "prop animation chunks must be numeric")
  return {
    op = "prop_animation_load",
    fieldX = { value = "scaled_coordinate", coordinate = localX, chunkOffset = chunkX },
    fieldZ = { value = "scaled_coordinate", coordinate = localZ, chunkOffset = chunkZ },
    slot = Operands.operandValue(ins.operands[5]),
  }
end

function FieldServiceHandlers.propAnimationPlay(ins, direction)
  return { op = "prop_animation_play", slot = Operands.varRef(ins.operands[1]), direction = direction }
end

function FieldServiceHandlers.propAnimationPlayForward(ins)
  return FieldServiceHandlers.propAnimationPlay(ins, "forward")
end

function FieldServiceHandlers.propAnimationPlayReverse(ins)
  return FieldServiceHandlers.propAnimationPlay(ins, "reverse")
end

function FieldServiceHandlers.propAnimationWait(ins)
  return { op = "prop_animation_wait", slot = Operands.varRef(ins.operands[1]) }
end

function FieldServiceHandlers.propAnimationUnload(ins)
  return { op = "prop_animation_unload", slot = Operands.varRef(ins.operands[1]) }
end

function FieldServiceHandlers.pokemonCenterHeal(ins)
  return { op = "pokemon_center_heal", count = Operands.varRef(ins.operands[1]) }
end

function FieldServiceHandlers.martOpen(kind, selector)
  local step = { op = "mart_open", kind = kind }
  if selector ~= nil then
    step.selector = selector
  end
  return step
end

function FieldServiceHandlers.martSpecial(ins)
  return FieldServiceHandlers.martOpen("special", Operands.varRef(ins.operands[1]))
end

function FieldServiceHandlers.martDecoration(ins)
  return FieldServiceHandlers.martOpen("decoration", Operands.varRef(ins.operands[1]))
end

function FieldServiceHandlers.martSeal(ins)
  return FieldServiceHandlers.martOpen("seal", Operands.varRef(ins.operands[1]))
end

function FieldServiceHandlers.martAthlete()
  return FieldServiceHandlers.martOpen("athlete")
end

function FieldServiceHandlers.martDataCards()
  return FieldServiceHandlers.martOpen("data_cards")
end

function FieldServiceHandlers.martSell()
  return FieldServiceHandlers.martOpen("sell")
end

function FieldServiceHandlers.martBuy(ins)
  -- The source halfword is consumed but does not select stock.
  assert(ins.operands[1] ~= nil, "MartBuy consumes its source operand")
  return FieldServiceHandlers.martOpen("standard")
end

function FieldServiceHandlers.martAthleteAvailable(ins)
  return { op = "mart_query", kind = "athlete_available", result = Operands.varRef(ins.operands[1]) }
end

function FieldServiceHandlers.martCardPrefix(ins)
  return { op = "mart_query", kind = "card_prefix", result = Operands.varRef(ins.operands[1]) }
end

return FieldServiceHandlers
