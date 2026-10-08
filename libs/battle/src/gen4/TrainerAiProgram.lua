-- Literal native trainer-AI program execution (pret/pokeheartgold
-- asm/overlay_10_trainer_ai.s ov10_02220AAC programs, ov10_0221C278
-- dispatcher, ov10_0222B0B4 handler table; src/battle/trainer_ai.c
-- ov10_0221BE20 scratch initialization).
--
-- WORDS holds the word stream shared by every program; ENTRY maps each
-- supported native flag bit to its program entry word index. run executes
-- one bit's program for the addressed move slot exactly as the dispatcher
-- does: commands run in word order, conditional commands adjust the
-- program counter relatively, random commands draw from the caller-owned
-- battle stream at the point they execute, and the slot program ends at
-- the shared terminator. Anything outside the transcribed opcode set, or
-- any required battle fact the evaluation state does not carry, fails
-- closed with structured missing behavior instead of answering
-- approximately. Score points follow signed 8-bit wrap with a zero floor,
-- matching the native move-points store.
--
-- The literals live in the program-data owner, shared readers in the
-- context owner, opcode execution in the command owner, and preview
-- arithmetic in the preview owner; this facade keeps the entrypoint,
-- the dispatch step, and the established aliases.

local BattleErrors = require("libs.battle.src.errors")
local Data = require("libs.battle.src.gen4.TrainerAiProgramData")
local Commands = require("libs.battle.src.gen4.TrainerAiCommands")

---@class TrainerAiProgram
local TrainerAiProgram = {}

-- The authoritative tables live in the program-data owner; these aliases
-- keep the established first-party spelling for entries, word numbering,
-- the word stream, and the ability/type names.
TrainerAiProgram.ENTRY = Data.ENTRY
TrainerAiProgram.BASE = Data.BASE
TrainerAiProgram.WORDS = Data.WORDS
TrainerAiProgram.ABILITY_IDS = Data.ABILITY_IDS
TrainerAiProgram.TYPE_IDS = Data.TYPE_IDS

---@param state TrainerAiProgramState command state under execution
---@param pc integer absolute word index of the command under execution
---@return integer|string next program counter, 'endslot', or 'abort'
local function dispatchAt(state, pc)
  local words = Data.WORDS
  local op = Commands.fetchOp(words, pc)
  local arity = Data.ARITY[op]
  if arity == nil then
    error(BattleErrors.missingBehavior("trainer programs dispatch their transcribed commands", {
      bit = state.bit,
      op = op,
    }))
  end
  return Commands.execute(state, op, pc)
end

--- Executes one supported program for the addressed move slot.
---@param state TrainerAiProgramState command state under execution
---@return string 'endslot' when the slot program completes, 'abort' when evaluation stops
function TrainerAiProgram.run(state)
  local entry = Data.ENTRY[state.bit]
  if entry == nil then
    error(BattleErrors.missingBehavior("trainer scoring names a transcribed native flag", {
      flag = state.bit,
    }))
  end
  local pc = entry
  while true do
    local outcome = dispatchAt(state, pc)
    if outcome == "endslot" or outcome == "abort" then
      return outcome
    end
    pc = outcome --[[@as integer]]
    if pc < Data.BASE or pc > 10606 then
      error(BattleErrors.missingBehavior("trainer programs stay inside their word stream", { pc = pc }))
    end
  end
end

return TrainerAiProgram
