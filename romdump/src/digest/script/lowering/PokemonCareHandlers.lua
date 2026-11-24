-- Day Care command lowerings. The care family reads its operands exactly like
-- the source: the slot selectors and the buffer indices are ScriptGetVar
-- values, so they lower as value references, while the result and cost
-- variables are ScriptGetVarPointer outputs. The party-selection pair joins
-- the shared party-screen nodes: opcode 551 blocks on the care context with
-- the source initial slot, and 552 reads both the completed slot and the
-- source action (1 only for Summary). They live here so their names never
-- become more file-scoped locals in the main field-handler chunk, which sits
-- at LuaJIT's local budget.
--
-- Retail sources (tmp/refs/pokeheartgold): src/scrcmd_daycare.c for every
-- ScrCmd_*Daycare* command except the party-selection pair, and
-- src/scrcmd_c.c::ScrCmd_ChoosePartyMonForDayCare /
-- ScrCmd_GetDayCarePartySelection for the picker.

local Operands = require("romdump.src.digest.script.lowering.Operands")

---@class PokemonCareHandlers
local PokemonCareHandlers = {}

-- ScrCmd_BufferDaycareMonNicks: buffers the stored parents' nicknames and the
-- first parent's OT name; it returns FALSE, so the script continues in the
-- same tick.
function PokemonCareHandlers.monNicknames(_)
  return { op = "daycare_mon_nicknames" }
end

-- ScrCmd_GetDaycareState: the source state code lands in the output variable.
function PokemonCareHandlers.state(ins)
  return { op = "daycare_state", result = Operands.varRef(ins.operands[1]) }
end

-- ScrCmd_RetrieveDaycareMon: the species output variable comes first, the
-- Day Care slot second.
function PokemonCareHandlers.retrieveMon(ins)
  return {
    op = "daycare_retrieve_mon",
    result = Operands.varRef(ins.operands[1]),
    slot = Operands.varRef(ins.operands[2]),
  }
end

-- ScrCmd_BufferDaycareWithdrawCost: the cost output variable first, the Day
-- Care slot second.
function PokemonCareHandlers.withdrawCost(ins)
  return {
    op = "daycare_withdraw_cost",
    result = Operands.varRef(ins.operands[1]),
    slot = Operands.varRef(ins.operands[2]),
  }
end

-- ScrCmd_BufferDaycareMonGrowth: the growth output variable first, the Day
-- Care slot second.
function PokemonCareHandlers.growth(ins)
  return {
    op = "daycare_growth",
    result = Operands.varRef(ins.operands[1]),
    slot = Operands.varRef(ins.operands[2]),
  }
end

-- ScrCmd_GetTailDaycareMonSpeciesAndNick: the species output variable.
function PokemonCareHandlers.tailMon(ins)
  return { op = "daycare_tail_mon", result = Operands.varRef(ins.operands[1]) }
end

-- ScrCmd_PutMonInDaycare: the selected party slot.
function PokemonCareHandlers.deposit(ins)
  return { op = "daycare_deposit", slot = Operands.varRef(ins.operands[1]) }
end

-- ScrCmd_BufferDaycareMonStats: the nickname, level, and gender buffer
-- indices followed by the Day Care slot, all read through ScriptGetVar.
function PokemonCareHandlers.monStats(ins)
  return {
    op = "daycare_mon_stats",
    nicknameBuffer = Operands.varRef(ins.operands[1]),
    levelBuffer = Operands.varRef(ins.operands[2]),
    genderBuffer = Operands.varRef(ins.operands[3]),
    slot = Operands.varRef(ins.operands[4]),
  }
end

-- ScrCmd_ChoosePartyMonForDayCare runs the party screen's Day Care context
-- (PARTY_MENU_CONTEXT_18) and blocks on it; its single operand is the source
-- initial slot the menu stores in its own args record.
function PokemonCareHandlers.choosePartyMon(ins)
  return { op = "party_select", policy = "daycare_store", initialSlot = Operands.varRef(ins.operands[1]) }
end

-- ScrCmd_GetDayCarePartySelection reads the completed slot and the source
-- action out of the same selection, mapping the source cancellation slot 7 to
-- 255.
function PokemonCareHandlers.partySelection(ins)
  return {
    op = "party_select_result",
    result = Operands.varRef(ins.operands[1]),
    action = Operands.varRef(ins.operands[2]),
  }
end

-- ScrCmd_DaycareSanitizeMon: the party slot first, the result variable
-- second.
function PokemonCareHandlers.sanitizeMon(ins)
  return {
    op = "daycare_sanitize_mon",
    slot = Operands.varRef(ins.operands[1]),
    result = Operands.varRef(ins.operands[2]),
  }
end

-- ScrCmd_UpdateDaycareMonObjects carries no operands.
function PokemonCareHandlers.updateObjects(_)
  return { op = "daycare_update_objects" }
end

-- ScrCmd_ResetDaycareEgg carries no operands and answers no value.
function PokemonCareHandlers.resetEgg(_)
  return { op = "daycare_reset_egg" }
end

-- ScrCmd_GiveDaycareEgg carries no operands; the egg receipt is its own effect.
function PokemonCareHandlers.giveEgg(_)
  return { op = "daycare_give_egg" }
end

-- ScrCmd_GetDaycareCompatibility: the source category lands in the output
-- variable.
function PokemonCareHandlers.compatibility(ins)
  return { op = "daycare_compatibility", result = Operands.varRef(ins.operands[1]) }
end

-- ScrCmd_EggHatchAnim carries no operands and blocks the script on the hatch
-- application: the source task leaves the overworld, runs the scene, publishes
-- the receipt, optionally names the mon and restores the field before the next
-- command runs.
function PokemonCareHandlers.hatchAnim(_)
  return { op = "egg_hatch_anim" }
end

-- ScrCmd_GiveTogepiEgg carries no operands and continues in the same tick; the
-- source gift checks party room before the date lookup and any creation draw.
function PokemonCareHandlers.giveTogepiEgg(_)
  return { op = "give_togepi_egg" }
end

-- ScrCmd_MonIsFromTogepiEgg: the party slot comes first, the result variable
-- second, and the matcher answer lands in it in the same tick.
function PokemonCareHandlers.monIsFromTogepiEgg(ins)
  return {
    op = "mon_is_from_togepi_egg",
    slot = Operands.varRef(ins.operands[1]),
    result = Operands.varRef(ins.operands[2]),
  }
end

-- ScrCmd_CheckDaycareEgg: the pending-egg answer lands in the output variable.
function PokemonCareHandlers.checkEgg(ins)
  return { op = "daycare_check_egg", result = Operands.varRef(ins.operands[1]) }
end

return PokemonCareHandlers
