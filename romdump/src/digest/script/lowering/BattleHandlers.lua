-- Battle launch and result lowering. TrainerBattle and WildBattle become
-- blocking battle_launch operations carrying their pinned operand layout:
-- the leading identity operands ride value-or-variable references (the
-- source reads them through ScriptGetVar) while trailing operands are
-- preserved opaquely for the battle host, whose meanings stay unpinned.
-- CheckBattleWon becomes the same-tick battle_result read into its
-- result variable. No unknown battle opcode maps to an ordinary launch:
-- anything else stays an explicit unsupported node with its owning
-- application named in the command catalog.

local Operands = require("romdump.src.digest.script.lowering.Operands")

---@class FieldBattleHandlers
local BattleHandlers = {}

-- ScrCmd_TrainerBattle (src/scrcmd_battle.c): both opponent trainer numbers
-- are read through ScriptGetVar; the third raw byte enables the source's
-- BATTLE_TYPE_11 single-opponent branch and the fourth selects its follow-mon
-- send-out slot. The first opponent is the leading trainer, the second the
-- native double partner when it names a different trainer.
---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function BattleHandlers.trainerBattle(ins)
  return {
    op = "battle_launch",
    kind = "trainer",
    details = {
      trainer = Operands.varRef(ins.operands[1]),
      trainer2 = Operands.varRef(ins.operands[2]),
      healOnLoss = Operands.operandValue(ins.operands[3]),
      followSlot = Operands.operandValue(ins.operands[4]),
    },
  }
end

-- ScrCmd_MultiBattle (src/scrcmd_battle.c): the leading operand is the ally
-- trainer fighting beside the player, then the two opponent trainers, then the
-- follow-mon selector byte. The source passes a4 = 0 for this form.
---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function BattleHandlers.multiBattle(ins)
  return {
    op = "battle_launch",
    kind = "trainer",
    details = {
      partner = Operands.varRef(ins.operands[1]),
      trainer = Operands.varRef(ins.operands[2]),
      trainer2 = Operands.varRef(ins.operands[3]),
      followSlot = Operands.operandValue(ins.operands[4]),
    },
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function BattleHandlers.wildBattle(ins)
  return {
    op = "battle_launch",
    kind = "wild",
    details = {
      species = Operands.varRef(ins.operands[1]),
      level = Operands.varRef(ins.operands[2]),
      args = { Operands.operandValue(ins.operands[3]) },
    },
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function BattleHandlers.checkBattleWon(ins)
  -- ScrCmd_CheckBattleWon reads the source's native outcome query into its
  -- result variable and returns TRUE, so the script yields one tick after the
  -- write. The query reports not-won only for a native loss or draw; a win, a
  -- capture and either fleeing side read as won.
  return { op = "battle_result", context = "native_won", result = Operands.varRef(ins.operands[1]) }
end

-- ScrCmd_RocketTrapBattle reads its authored species and level through
-- ScriptGetVar and starts the ordinary wild battle application: the trap hazard
-- never selects a species of its own, and the trap's own sixteen variables stay
-- script-owned.
---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function BattleHandlers.rocketTrapBattle(ins)
  return {
    op = "battle_launch",
    kind = "wild",
    details = {
      species = Operands.varRef(ins.operands[1]),
      level = Operands.varRef(ins.operands[2]),
    },
  }
end

-- ScrCmd_StaticWildWonOrCaughtCheck (src/scrcmd_battle.c): the leading
-- operand is the output variable and the trailing raw byte selects the source
-- of the read - the battle-result variable when it is 1, the committed raw
-- outcome word otherwise. The command reports not-won for a win or a capture.
---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function BattleHandlers.staticWildWonOrCaughtCheck(ins)
  return {
    op = "battle_result",
    context = "static_wild_won_or_caught",
    result = Operands.varRef(ins.operands[1]),
    useResultVariable = Operands.operandValue(ins.operands[2]) == 1,
  }
end

-- ScrCmd_LatiCaughtCheck (src/scrcmd_battle.c): one output variable; it
-- reports caught only for the committed capture word.
---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function BattleHandlers.latiCaughtCheck(ins)
  return {
    op = "battle_result",
    context = "latis_caught",
    result = Operands.varRef(ins.operands[1]),
  }
end

-- ScrCmd_GetStaticEncounterOutcome (src/scrcmd_battle.c): one output variable
-- carrying the committed raw outcome word itself.
---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function BattleHandlers.getStaticEncounterOutcome(ins)
  -- Whole raw-word reads never come from the battle-result variable: the
  -- command reports the committed word.
  return {
    op = "battle_result",
    context = "static_encounter_outcome",
    result = Operands.varRef(ins.operands[1]),
  }
end

-- ScrCmd_FatefulWildBattle (src/scrcmd_battle.c): the same authored species
-- and level launch as ScrCmd_WildBattle, but the created foe carries the
-- source's fateful-encounter mark. Identity stays ordinary: no forced shiny.
---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function BattleHandlers.fatefulWildBattle(ins)
  return {
    op = "battle_launch",
    kind = "wild",
    details = {
      species = Operands.varRef(ins.operands[1]),
      level = Operands.varRef(ins.operands[2]),
      fateful = true,
    },
  }
end

-- Retail catching-tutorial (scrcmd_c.c ScrCmd_CatchingTutorial opcode 251,
-- SetupAndStartTutorialBattle via BattleSetup_New_Tutorial): the lesson
-- runs its fixed Marill/Rattata content with 20× balls behind the
-- tutorial marker, never live party or bag operands. The opcode carries
-- no operands, so the launch details stay empty and the field host
-- builds the lesson verbatim.
---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function BattleHandlers.catchingTutorial(ins)
  assert(#ins.operands == 0, "catching tutorials carry no operands")
  return {
    op = "battle_launch",
    kind = "tutorial",
    details = {},
  }
end

return BattleHandlers
