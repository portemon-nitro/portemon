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

-- The Summary and move-reminder family. ScrCmd_PokemonSummaryScreen reads the
-- page selector as a raw byte and its two values through ScriptGetVar;
-- ScrCmd_GetMoveSelection reads the mode as a raw byte and writes through
-- ScriptGetVarPointer. ScrCmd_OpenLearnForgetMove and
-- ScrCmd_GetLearnForgetMoveResult are the deletion picker and its result;
-- ScrCmd_MonHasRelearnableMoves writes first and reads the slot second;
-- ScrCmd_MoveRelearnerInit / ScrCmd_MoveTutorInit launch the shared
-- application, and ScrCmd_MoveRelearnerGetResult writes its 0/255 answer.
-- Retail sources: src/scrcmd_c.c and src/scrcmd_move_relearner.c.

-- ScrCmd_PokemonSummaryScreen: byte page selector, party slot, prospective
-- move.
function PokemonCareHandlers.pokemonSummaryScreen(ins)
  return {
    op = "pokemon_summary_screen",
    mode = Operands.operandValue(ins.operands[1]),
    slot = Operands.varRef(ins.operands[2]),
    moveToLearn = Operands.varRef(ins.operands[3]),
  }
end

-- ScrCmd_GetMoveSelection: byte result mode and the output variable.
function PokemonCareHandlers.getMoveSelection(ins)
  return {
    op = "get_move_selection",
    mode = Operands.operandValue(ins.operands[1]),
    result = Operands.varRef(ins.operands[2]),
  }
end

-- ScrCmd_OpenLearnForgetMove: the party slot whose Summary opens the deletion
-- picker.
function PokemonCareHandlers.openLearnForgetMove(ins)
  return { op = "open_learn_forget_move", slot = Operands.varRef(ins.operands[1]) }
end

-- ScrCmd_GetLearnForgetMoveResult: one output variable, 255 on cancellation.
function PokemonCareHandlers.getLearnForgetMoveResult(ins)
  return { op = "get_learn_forget_move_result", result = Operands.varRef(ins.operands[1]) }
end

-- ScrCmd_MonHasRelearnableMoves: the output variable comes first and the party
-- slot second.
function PokemonCareHandlers.monHasRelearnableMoves(ins)
  return {
    op = "mon_has_relearnable_moves",
    result = Operands.varRef(ins.operands[1]),
    slot = Operands.varRef(ins.operands[2]),
  }
end

-- ScrCmd_MoveRelearnerInit: the party slot whose level-up list opens.
function PokemonCareHandlers.moveRelearnerInit(ins)
  return { op = "move_relearner_init", slot = Operands.varRef(ins.operands[1]) }
end

-- ScrCmd_MoveTutorInit: the party slot and the single offered move.
function PokemonCareHandlers.moveTutorInit(ins)
  return {
    op = "move_tutor_init",
    slot = Operands.varRef(ins.operands[1]),
    move = Operands.varRef(ins.operands[2]),
  }
end

-- ScrCmd_MoveRelearnerGetResult: one output variable, 0 learned and 255
-- cancelled.
function PokemonCareHandlers.moveRelearnerGetResult(ins)
  return { op = "move_relearner_get_result", result = Operands.varRef(ins.operands[1]) }
end

-- The Frontier move tutor family (src/field/scrcmd_move_tutor.c). Every
-- selector, the page and the taught move are ScriptGetVar operands, while the
-- result variables are ScriptGetVarPointer outputs. ScrCmd_MoveTutorChooseMove
-- blocks the script on the generated list menu; the other four answer in the
-- same tick.

-- ScrCmd_GetTutorMoveListPageCount: party slot, tutor selector, result.
function PokemonCareHandlers.tutorMoveListPageCount(ins)
  return {
    op = "tutor_move_page_count",
    slot = Operands.varRef(ins.operands[1]),
    tutorNpc = Operands.varRef(ins.operands[2]),
    result = Operands.varRef(ins.operands[3]),
  }
end

-- ScrCmd_MoveTutorChooseMove: party slot, tutor selector, page, result.
function PokemonCareHandlers.moveTutorChooseMove(ins)
  return {
    op = "tutor_choose_move",
    slot = Operands.varRef(ins.operands[1]),
    tutorNpc = Operands.varRef(ins.operands[2]),
    page = Operands.varRef(ins.operands[3]),
    result = Operands.varRef(ins.operands[4]),
  }
end

-- ScrCmd_TutorMoveTeachInSlot: party slot, move row, move identity.
function PokemonCareHandlers.tutorMoveTeachInSlot(ins)
  return {
    op = "tutor_move_teach",
    slot = Operands.varRef(ins.operands[1]),
    moveSlot = Operands.varRef(ins.operands[2]),
    move = Operands.varRef(ins.operands[3]),
  }
end

-- ScrCmd_TutorMoveGetPrice: the move identity, then the result variable.
function PokemonCareHandlers.tutorMoveGetPrice(ins)
  return {
    op = "tutor_move_price",
    move = Operands.varRef(ins.operands[1]),
    result = Operands.varRef(ins.operands[2]),
  }
end

-- ScrCmd_MonCanLearnHeadbuttFromTutor: the party slot, then the result
-- variable.
function PokemonCareHandlers.monCanLearnHeadbuttFromTutor(ins)
  return {
    op = "headbutt_tutor_eligible",
    slot = Operands.varRef(ins.operands[1]),
    result = Operands.varRef(ins.operands[2]),
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

-- ScrCmd_LoadNPCTrade reads its trade identity as a raw byte, so it lowers as
-- a literal and not as a variable reference.
function PokemonCareHandlers.loadNpcTrade(ins)
  return { op = "npc_trade_load", tradeId = Operands.operandValue(ins.operands[1]) }
end

-- ScrCmd_GetOfferedSpecies publishes the parked record's offered species.
function PokemonCareHandlers.offeredSpecies(ins)
  return { op = "npc_trade_offered_species", result = Operands.varRef(ins.operands[1]) }
end

-- ScrCmd_NPCTradeGetReqSpecies publishes the species the source script asks the
-- player for.
function PokemonCareHandlers.requestedSpecies(ins)
  return { op = "npc_trade_requested_species", result = Operands.varRef(ins.operands[1]) }
end

-- ScrCmd_GetNPCTradeUnusedFlag publishes the record's unused flag column.
function PokemonCareHandlers.unusedFlag(ins)
  return { op = "npc_trade_unused_flag", result = Operands.varRef(ins.operands[1]) }
end

-- ScrCmd_NPCTradeExec reads the party slot through ScriptGetVar and blocks the
-- script on the exchange application.
function PokemonCareHandlers.npcTradeExec(ins)
  return { op = "npc_trade_exec", slot = Operands.varRef(ins.operands[1]) }
end

-- ScrCmd_NPCTradeEnd carries no operands and releases the parked context.
function PokemonCareHandlers.npcTradeEnd(_)
  return { op = "npc_trade_end" }
end

-- ScrCmd_ChoosePartyMonForTrade runs the party screen's in-game-trade context
-- (PartyMenu_LaunchApp_InGameTrade) and blocks on it; inside that context a
-- record carrying a ball capsule asks the source removal question first.
function PokemonCareHandlers.choosePartyMonForTrade(_)
  return { op = "party_select", policy = "npc_trade" }
end

-- ScrCmd_GiveLoanMon reads the trade identity and level as raw bytes and the map
-- identity as a raw halfword; the loaned record is handed out in the same tick.
function PokemonCareHandlers.giveLoanMon(ins)
  return {
    op = "give_loan_mon",
    tradeId = Operands.operandValue(ins.operands[1]),
    level = Operands.operandValue(ins.operands[2]),
    mapId = Operands.operandValue(ins.operands[3]),
  }
end

-- ScrCmd_CheckReturnLoanMon reads the trade identity as a raw byte, the party
-- slot through ScriptGetVar, and writes the source priority code.
function PokemonCareHandlers.checkReturnLoanMon(ins)
  return {
    op = "check_return_loan_mon",
    tradeId = Operands.operandValue(ins.operands[1]),
    slot = Operands.varRef(ins.operands[2]),
    result = Operands.varRef(ins.operands[3]),
  }
end

-- ScrCmd_CheckDaycareEgg: the pending-egg answer lands in the output variable.
function PokemonCareHandlers.checkEgg(ins)
  return { op = "daycare_check_egg", result = Operands.varRef(ins.operands[1]) }
end

return PokemonCareHandlers
