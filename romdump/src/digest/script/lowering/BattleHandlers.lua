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
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

---@class FieldBattleHandlers
local BattleHandlers = {}

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function BattleHandlers.setTrainerFlag(ins)
  return { op = "set_trainer_flag", trainer = Operands.varRef(ins.operands[1]) }
end

---@param ins table<string, unknown> decoded instruction record
---@param memberIr table<string, unknown>
---@param _ table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function BattleHandlers.trainerNumber(ins, memberIr, _, ctx)
  local scriptIndex = ctx.scriptIndex
  assert(memberIr.member == 953, "GetTrainerNum requires the native trainer script member")
  assert(type(scriptIndex) == "number" and scriptIndex % 1 == 0 and scriptIndex >= 0, "trainer script index required")
  local standard = SourceCatalog.catalog().locate(3000 + scriptIndex)
  assert(
    standard ~= nil and standard.member == memberIr.member,
    "GetTrainerNum source member has no native trainer mapping"
  )
  return {
    op = "set_var",
    variable = Operands.varRef(ins.operands[1]),
    value = scriptIndex + 1,
  }
end

---@param ins table<string, unknown> decoded instruction record
---@param memberIr table<string, unknown>
---@param _ table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function BattleHandlers.trainerDoubleBattle(ins, memberIr, _, ctx)
  local scriptIndex = ctx.scriptIndex
  assert(memberIr.member == 953, "TrainerIsDoubleBattle requires the native trainer script member")
  assert(type(scriptIndex) == "number" and scriptIndex % 1 == 0 and scriptIndex >= 0, "trainer script index required")
  return {
    op = "set_var",
    variable = Operands.varRef(ins.operands[1]),
    value = { value = "trainer_double_battle", trainer = scriptIndex + 1 },
  }
end

---@param ins table<string, unknown> decoded instruction record
---@param memberIr table<string, unknown>
---@param _ table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function BattleHandlers.trainerMessageParams(ins, memberIr, _, ctx)
  local scriptIndex = ctx.scriptIndex
  assert(memberIr.member == 953, "trainer message selectors require the native trainer script member")
  assert(type(scriptIndex) == "number" and scriptIndex % 1 == 0 and scriptIndex >= 0, "trainer script index required")
  local secondPairBase = 2000
  local partner = scriptIndex >= secondPairBase
  local trainerId = partner and scriptIndex - secondPairBase + 1 or scriptIndex + 1
  local function messageParam(selector)
    return {
      op = "set_var",
      variable = Operands.varRef(ins.operands[selector]),
      value = { value = "trainer_message_param", trainer = trainerId, partner = partner, selector = selector },
    }
  end
  return {
    steps = { messageParam(1), messageParam(2), messageParam(3) },
  }
end

---@param ins table<string, unknown> decoded instruction record
---@param memberIr table<string, unknown>
---@param _ table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function BattleHandlers.trainerRematchMessageParams(ins, memberIr, _, ctx)
  local scriptIndex = ctx.scriptIndex
  assert(memberIr.member == 953, "rematch message selectors require the native trainer script member")
  assert(type(scriptIndex) == "number" and scriptIndex % 1 == 0 and scriptIndex >= 0, "trainer script index required")
  local secondPairBase = 2000
  local partner = scriptIndex >= secondPairBase
  local trainerId = partner and scriptIndex - secondPairBase + 1 or scriptIndex + 1
  local function messageParam(selector)
    return {
      op = "set_var",
      variable = Operands.varRef(ins.operands[selector]),
      value = { value = "trainer_rematch_message_param", trainer = trainerId, partner = partner, selector = selector },
    }
  end
  return {
    steps = { messageParam(1), messageParam(2), messageParam(3) },
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function BattleHandlers.trainerMessage(ins)
  return {
    op = "message",
    message = {
      message = "trainer",
      trainer = Operands.varRef(ins.operands[1]),
      selector = Operands.varRef(ins.operands[2]),
    },
    waitForPrint = true,
  }
end

---@return table<string, unknown>
function BattleHandlers.trainerReactionMovement()
  return { op = "trainer_reaction_movement", actor = { ref = "actor", special = "last_talked" } }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function BattleHandlers.actorMovementSelector(ins)
  local rawActor = Operands.operandValue(ins.operands[2])
  local actor
  if rawActor == "VAR_SPECIAL_LAST_TALKED" then
    actor = { ref = "actor", special = "last_talked" }
  elseif type(rawActor) == "string" and rawActor:match("^VAR_") then
    actor = { ref = "actor", mapIndex = { value = "var", id = rawActor } }
  else
    actor = { ref = "actor", mapIndex = rawActor }
  end
  return { op = "actor_movement_selector", actor = actor, result = Operands.varRef(ins.operands[1]) }
end

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

return BattleHandlers
