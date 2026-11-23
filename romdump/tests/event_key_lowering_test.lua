-- The save's own event-key selector and game-clear flag commands retain their
-- source operand widths and lower to semantic operations carrying the source
-- key's stored variable and magic word. Source reference: the retail ROM.

local Assert = require("tests.support.Assert")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
local ScriptCommands = require("romdump.src.catalog.hgss.script_commands")
local ScriptFixture = require("tests.support.ScriptFixture")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local T = {}

local function sourceVar(id)
  return { value = "var", id = id }
end

local function decodeAndLower(instructions)
  local bytes = ScriptFixture.member({
    scripts = {
      { offset = 0x20, instructions = instructions },
    },
  })
  local member = assert(ScriptBinaryDecoder.parseMember(bytes, 0x19F, "event-key-fixture", {}))
  local script = assert(member.scripts[0])
  local lowered = SemanticLowering.lowerScript(script, member, { stdCatalog = SourceCatalog.catalog() })
  return script, lowered
end

local function unsupportedSteps(lowered)
  local found = {}
  for _, step in ipairs(lowered.items) do
    if step.op == "unsupported" then
      found[#found + 1] = step
    end
  end
  return found
end

function T.the_event_key_check_keeps_its_source_operands_and_lowers_symbolically()
  local _, lowered = decodeAndLower({
    { op = 546, args = { { value = 0, width = 1 }, { value = 0x8004, width = 2 } } },
    { op = 2, args = {} },
  })
  Assert.equal(#unsupportedSteps(lowered), 0, "the event key selector has a semantic lowering")
  local step = lowered.items[1]
  Assert.equal(step.op, "check_event_key")
  Assert.equal(step.variable, "VAR_UNK_4043", "raw key 0 names the first stored event key")
  Assert.equal(step.magic, 0x06F2, "the first event key compares against its source magic word")
  Assert.deepEqual(step.result, sourceVar(0x8004), "the output operand stays a variable reference")
end

function T.the_second_event_key_selects_its_own_variable_and_magic_word()
  local _, lowered = decodeAndLower({
    { op = 546, args = { { value = 1, width = 1 }, { value = 0x8005, width = 2 } } },
    { op = 2, args = {} },
  })
  local step = lowered.items[1]
  Assert.equal(step.op, "check_event_key")
  Assert.equal(step.variable, "VAR_UNK_4044", "raw key 1 names the second stored event key")
  Assert.equal(step.magic, 0xAD7C, "the second event key compares against its source magic word")
end

function T.the_game_clear_commands_lower_to_their_own_flag_operations()
  local _, lowered = decodeAndLower({
    { op = 305, args = { { value = 0x8006, width = 2 } } },
    { op = 306, args = {} },
    { op = 2, args = {} },
  })
  Assert.equal(#unsupportedSteps(lowered), 0, "both game-clear commands have a semantic lowering")
  Assert.equal(lowered.items[1].op, "check_game_clear")
  Assert.equal(lowered.items[1].flag, "FLAG_GAME_CLEAR", "the query reads the save's own clear flag")
  Assert.deepEqual(lowered.items[1].result, sourceVar(0x8006), "the query writes its output variable")
  Assert.equal(lowered.items[2].op, "set_game_clear")
  Assert.equal(lowered.items[2].flag, "FLAG_GAME_CLEAR")
end

function T.the_catalog_declares_the_commands_in_their_own_tick()
  for _, opcode in ipairs({ 305, 306, 546 }) do
    local entry = assert(ScriptCommands.byOpcode[opcode])
    Assert.equal(entry.disposition, "supported", "opcode " .. opcode .. " executes")
    Assert.equal(entry.classification, "continue_same_tick", "opcode " .. opcode .. " settles in its own tick")
  end
  Assert.deepEqual(assert(ScriptCommands.byOpcode[546]).widths, { 1, 2 }, "the key is a byte and the output a word")
  Assert.deepEqual(assert(ScriptCommands.byOpcode[305]).widths, { 2 }, "the clear query names one output word")
  Assert.deepEqual(assert(ScriptCommands.byOpcode[306]).widths, {}, "the clear setter takes no operands")
end

return { tests = T }
