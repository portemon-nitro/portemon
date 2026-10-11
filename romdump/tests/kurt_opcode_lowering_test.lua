-- Kurt's Apricorn script commands retain their source widths and lower to
-- semantic operations. Source reference: pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981.

local Assert = require("tests.support.Assert")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
local ScriptCommands = require("romdump.src.reference.hgss.script_commands")
local ScriptFixture = require("tests.support.ScriptFixture")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local T = {}

local KURT_WIDTHS = {
  [735] = { 2 },
  [736] = {},
  [737] = { 2 },
  [738] = { 2 },
  [739] = {},
}

local function command(opcode, operands)
  local args = {}
  for index, width in ipairs(assert(KURT_WIDTHS[opcode])) do
    args[index] = { value = operands[index], width = width }
  end
  return { op = opcode, args = args }
end

local function sourceVar(id)
  return { value = "var", id = id }
end

local function decodeAndLower(instructions)
  local bytes = ScriptFixture.member({
    scripts = {
      { offset = 0x20, instructions = instructions },
    },
  })
  local member = assert(ScriptBinaryDecoder.parseMember(bytes, 0x123, "kurt-apricorn-fixture", {}))
  local script = assert(member.scripts[0])
  local lowered = SemanticLowering.lowerScript(script, member, { stdCatalog = SourceCatalog.catalog() })
  return script, lowered
end

function T.kurt_commands_keep_retail_operand_widths_and_decode_following_commands()
  local instructions = {
    command(735, { 0x8001 }),
    command(736, {}),
    command(737, { 0x8002 }),
    command(738, { 0x8003 }),
    command(739, {}),
    { op = 41, args = { { value = 0x8004, width = 2 }, { value = 0x1234, width = 2 } } },
    { op = 2, args = {} },
  }
  local script = decodeAndLower(instructions)
  Assert.equal(#script.instructions, #instructions, "all five commands and the trailing assignment decode")
  for index, opcode in ipairs({ 735, 736, 737, 738, 739 }) do
    local entry = assert(ScriptCommands.byOpcode[opcode])
    Assert.deepEqual(entry.widths, KURT_WIDTHS[opcode], "opcode " .. opcode .. " keeps its source width")
    Assert.equal(script.instructions[index].size, 2 + 2 * #KURT_WIDTHS[opcode])
  end
  local marker = script.instructions[6]
  Assert.equal(marker.opcode, 41, "the assignment remains after the Kurt commands")
  Assert.deepEqual({ marker.operands[1].raw, marker.operands[2].raw }, { 0x8004, 0x1234 })
end

function T.kurt_commands_have_apricorn_timing_metadata_and_semantic_lowering()
  local expectedOps = {
    "apricorn_kurt_quantity",
    "apricorn_kurt_clear",
    "apricorn_kurt_ball",
    "apricorn_total",
    "apricorn_box_select",
  }
  for _, opcode in ipairs({ 735, 736, 737, 738, 739 }) do
    local entry = assert(ScriptCommands.byOpcode[opcode])
    Assert.equal(entry.disposition, "supported", "opcode " .. opcode .. " is implemented")
    Assert.equal(entry.feature, "apricorn", "opcode " .. opcode .. " belongs to the Apricorn feature")
    Assert.equal(
      entry.classification,
      opcode == 739 and "native_wait" or "continue_same_tick",
      "opcode " .. opcode .. " preserves source timing"
    )
    Assert.equal(entry.deferredReason, nil)
  end

  local _, lowered = decodeAndLower({
    command(735, { 0x8001 }),
    command(736, {}),
    command(737, { 0x8002 }),
    command(738, { 0x8003 }),
    command(739, {}),
    { op = 2, args = {} },
  })
  local items = lowered.items
  Assert.equal(#items, 6)
  Assert.deepEqual(items[1], { op = expectedOps[1], result = sourceVar(0x8001), provenance = items[1].provenance })
  Assert.deepEqual(items[2], { op = expectedOps[2], provenance = items[2].provenance })
  Assert.deepEqual(items[3], { op = expectedOps[3], result = sourceVar(0x8002), provenance = items[3].provenance })
  Assert.deepEqual(items[4], { op = expectedOps[4], result = sourceVar(0x8003), provenance = items[4].provenance })
  Assert.deepEqual(items[5], { op = expectedOps[5], provenance = items[5].provenance })
  Assert.equal(items[6].op, "stop")
end

return { tests = T }
