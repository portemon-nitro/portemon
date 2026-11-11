-- Word-command lowering: the fourteen in-scope source commands become their
-- semantic operations. Evaluated operands stay symbolic through varRef,
-- literal halfword/byte operands normalize to raw numbers through
-- operandValue even when the value resembles a variable id, and output
-- operands ride the output variable reference. Display and greeting
-- commands keep their source timing: the immediate display becomes a
-- non-waiting instant message, the waiting display and opponent intro
-- become blocking messages, and the wrapper choice waits on the script
-- editor task. No node carries a native opcode.

local Operands = require("romdump.src.digest.script.lowering.Operands")
---@class EasyChatHandlers
local EasyChatHandlers = {}

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function EasyChatHandlers.fashionTitleWord(ins)
  return {
    op = "fashion_title_word",
    word = Operands.varRef(ins.operands[1]),
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function EasyChatHandlers.unionOwnChatMessage(ins)
  return {
    op = "union_own_chat_message",
    result = Operands.varRef(ins.operands[1]),
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function EasyChatHandlers.unionPartnerLanguage(ins)
  return {
    op = "union_partner_language",
    mode = Operands.operandValue(ins.operands[1]),
  }
end

---@param bank unknown literal sentence bank
---@param number unknown literal sentence number
---@param word1 unknown literal first word
---@param word2 unknown literal second word
---@return table<string, unknown> detached literal word message reference
local function easyChatMessage(bank, number, word1, word2)
  return {
    message = "easy_chat",
    bank = Operands.operandValue(bank),
    number = Operands.operandValue(number),
    words = { Operands.operandValue(word1), Operands.operandValue(word2) },
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function EasyChatHandlers.nonNpcMessageEasyChat(ins)
  return {
    op = "message",
    message = easyChatMessage(ins.operands[1], ins.operands[2], ins.operands[3], ins.operands[4]),
    waitForPrint = false,
    instant = true,
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function EasyChatHandlers.msgBoxEasyChat(ins)
  return {
    op = "message",
    message = easyChatMessage(ins.operands[1], ins.operands[2], ins.operands[3], ins.operands[4]),
    waitForPrint = true,
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function EasyChatHandlers.frontierOpponentIntro(ins)
  return {
    op = "frontier_intro_message",
    index = Operands.operandValue(ins.operands[1]),
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function EasyChatHandlers.promptEasyChatOneWord(ins)
  return {
    op = "easy_chat_edit",
    kind = Operands.varRef(ins.operands[1]),
    result = Operands.varRef(ins.operands[2]),
    word1 = Operands.varRef(ins.operands[3]),
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function EasyChatHandlers.promptEasyChat(ins)
  return {
    op = "easy_chat_edit",
    kind = 1,
    result = Operands.varRef(ins.operands[1]),
    word1 = Operands.varRef(ins.operands[2]),
    word2 = Operands.varRef(ins.operands[3]),
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function EasyChatHandlers.bufferEasyChatWord(ins)
  return {
    op = "easy_chat_buffer",
    slot = Operands.varRef(ins.operands[1]),
    word = Operands.varRef(ins.operands[2]),
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function EasyChatHandlers.unlockRandomTrendySaying(ins)
  return {
    op = "easy_chat_unlock_trendy",
    result = Operands.varRef(ins.operands[1]),
    slot = Operands.varRef(ins.operands[2]),
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function EasyChatHandlers.checkAllTrendySayingsUnlocked(ins)
  return {
    op = "easy_chat_all_trendy",
    result = Operands.varRef(ins.operands[1]),
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function EasyChatHandlers.checkEasyChatWordsMatchFixedPhrase(ins)
  return {
    op = "easy_chat_fixed_phrase",
    result = Operands.varRef(ins.operands[1]),
    word1 = Operands.varRef(ins.operands[2]),
    word2 = Operands.varRef(ins.operands[3]),
    word3 = Operands.varRef(ins.operands[4]),
    word4 = Operands.varRef(ins.operands[5]),
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function EasyChatHandlers.editBattleGreeting(ins)
  return {
    op = "easy_chat_greeting",
    result = Operands.varRef(ins.operands[1]),
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function EasyChatHandlers.showTrainerHouseIntroMessage(ins)
  return {
    op = "trainer_house_intro_message",
    index = Operands.varRef(ins.operands[1]),
  }
end

-- Primo password checks (opcodes 498 wallpaper, 499 egg): the first
-- source operand is the result, the next four are the checked words.
-- Inputs stay symbolic through varRef, so an aliased result variable
-- still evaluates before the runtime writes it.
---@param ins table<string, unknown> decoded instruction record
---@param kind string reward family
---@return table<string, unknown>
local function primoPasswordCheck(ins, kind)
  return {
    op = "primo_password",
    kind = kind,
    result = Operands.varRef(ins.operands[1]),
    word1 = Operands.varRef(ins.operands[2]),
    word2 = Operands.varRef(ins.operands[3]),
    word3 = Operands.varRef(ins.operands[4]),
    word4 = Operands.varRef(ins.operands[5]),
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function EasyChatHandlers.primoPasswordCheck1(ins)
  return primoPasswordCheck(ins, "wallpaper")
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function EasyChatHandlers.primoPasswordCheck2(ins)
  return primoPasswordCheck(ins, "egg")
end

return EasyChatHandlers
