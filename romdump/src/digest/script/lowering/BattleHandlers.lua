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

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function BattleHandlers.trainerBattle(ins)
  return {
    op = "battle_launch",
    kind = "trainer",
    details = {
      trainer = Operands.varRef(ins.operands[1]),
      encounter = Operands.varRef(ins.operands[2]),
      args = { Operands.operandValue(ins.operands[3]), Operands.operandValue(ins.operands[4]) },
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
  return { op = "battle_result", result = Operands.varRef(ins.operands[1]) }
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
