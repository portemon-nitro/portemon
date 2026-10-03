-- Mart script commands keep their retail operand widths and read/write
-- distinctions through the real binary decoder and semantic lowerer.
-- Source references: pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36,
-- src/scrcmd_mart.c, src/scrcmd_c.c, and src/field_system.c.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
local ScriptCommands = require("romdump.src.reference.hgss.script_commands")
local ScriptFixture = require("tests.support.ScriptFixture")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")
local Structurer = require("romdump.src.digest.script.Structurer")
local Verifier = require("romdump.src.digest.script.Verifier")

local T = {}

local MART_WIDTHS = {
  [275] = { 2 },
  [276] = { 2 },
  [277] = { 2 },
  [278] = { 2 },
  [771] = {},
  [772] = {},
  [782] = {},
  [834] = { 2 },
  [835] = { 2 },
}

local function decodeAndLower(instructions)
  local bytes = ScriptFixture.member({
    scripts = {
      { offset = 0x20, instructions = instructions },
    },
  })
  local member = assert(ScriptBinaryDecoder.parseMember(bytes, 0x123, "mart-lowering-fixture", {}))
  local script = assert(member.scripts[0])
  local lowered = SemanticLowering.lowerScript(script, member, { stdCatalog = SourceCatalog.catalog() })
  return script, lowered, member
end

local function command(opcode, operands)
  local args = {}
  for index, width in ipairs(assert(MART_WIDTHS[opcode] or (opcode == 815 and { 2 } or nil))) do
    args[index] = { value = operands[index], width = width }
  end
  return { op = opcode, args = args }
end

local function sourceVar(id)
  return { value = "var", id = id }
end

function T.retail_mart_widths_decode_before_a_trailing_assignment()
  local instructions = {}
  for _, opcode in ipairs({ 275, 276, 277, 278, 771, 772, 782, 834, 835 }) do
    local entry = assert(ScriptCommands.byOpcode[opcode], "the command catalog names opcode " .. opcode)
    Assert.deepEqual(entry.widths, MART_WIDTHS[opcode], "opcode " .. opcode .. " preserves source operand widths")
    local operands = entry.widths[1] and { opcode == 275 and 0 or 0x8000 + opcode % 0x100 } or {}
    instructions[#instructions + 1] = command(opcode, operands)
  end
  Assert.deepEqual(assert(ScriptCommands.byOpcode[815]).widths, { 2 }, "815 consumes an immediate halfword")
  instructions[#instructions + 1] = command(815, { 0 })
  instructions[#instructions + 1] = { op = 41, args = { { value = 0x8009, width = 2 }, { value = 0x1234, width = 2 } } }
  instructions[#instructions + 1] = { op = 2, args = {} }

  local script = decodeAndLower(instructions)
  Assert.equal(#script.instructions, #instructions, "all source commands and the trailing marker decode")
  for index, opcode in ipairs({ 275, 276, 277, 278, 771, 772, 782, 834, 835 }) do
    local decoded = script.instructions[index]
    Assert.equal(decoded.opcode, opcode)
    Assert.equal(decoded.size, 2 + 2 * #MART_WIDTHS[opcode], "opcode " .. opcode .. " consumes its operands")
  end
  local marker = script.instructions[#script.instructions - 1]
  Assert.equal(marker.opcode, 41, "the sentinel assignment stays after every mart command")
  Assert.deepEqual({ marker.operands[1].raw, marker.operands[2].raw }, { 0x8009, 0x1234 })
end

function T.mart_command_metadata_matches_blocking_and_same_tick_behavior()
  for _, opcode in ipairs({ 275, 276, 277, 278, 771, 772, 782, 834, 835 }) do
    local entry = assert(ScriptCommands.byOpcode[opcode])
    Assert.equal(entry.disposition, "supported", "opcode " .. opcode .. " has a semantic implementation")
    Assert.equal(
      entry.classification,
      (opcode == 834 or opcode == 835) and "continue_same_tick" or "native_wait",
      "opcode " .. opcode .. " keeps its script timing classification"
    )
  end
end

function T.nine_mart_commands_lower_with_read_and_write_semantics()
  local instructions = {
    command(275, { 0 }),
    command(276, { 0x8004 }),
    command(277, { 0x8005 }),
    command(278, { 0x8006 }),
    command(771, {}),
    command(772, {}),
    command(782, {}),
    command(834, { 0x8007 }),
    command(835, { 0x8008 }),
    command(815, { 0 }),
    { op = 41, args = { { value = 0x8009, width = 2 }, { value = 0x1234, width = 2 } } },
    { op = 2, args = {} },
  }
  local script, lowered, member = decodeAndLower(instructions)
  local items = lowered.items
  Assert.equal(#items, 11, "815 zero is omitted while the nine mart operations, marker and stop remain")
  local expectedLaunches = {
    { kind = "standard" },
    { kind = "special", selector = sourceVar(0x8004) },
    { kind = "decoration", selector = sourceVar(0x8005) },
    { kind = "seal", selector = sourceVar(0x8006) },
    { kind = "athlete" },
    { kind = "data_cards" },
    { kind = "sell" },
  }
  for index, expected in ipairs(expectedLaunches) do
    local node = items[index]
    Assert.equal(node.op, "mart_open", "opcode " .. instructions[index].op .. " opens a mart")
    Assert.equal(node.kind, expected.kind)
    Assert.deepEqual(node.selector, expected.selector, "selectors are read values, never output refs")
  end
  Assert.deepEqual(items[8], { op = "mart_query", kind = "athlete_available", result = sourceVar(0x8007), provenance = items[8].provenance })
  Assert.deepEqual(items[9], { op = "mart_query", kind = "card_prefix", result = sourceVar(0x8008), provenance = items[9].provenance })
  Assert.equal(items[10].op, "set_var", "the trailing assignment remains executable after all queries")
  Assert.deepEqual(items[10].variable, sourceVar(0x8009))
  Assert.equal(items[10].value, 0x1234)
  Assert.equal(items[11].op, "stop", "the source end instruction remains after the marker")
  local report = Verifier.verifyScript(items, script, member, lowered.omissions)
  Assert.isTrue(report.ok, "source verification accepts the supported mart graph and guarded 815 omission")
end

function T.default_field_return_adaptation_accepts_only_immediate_zero()
  local zeroScript, zero, zeroMember = decodeAndLower({ command(815, { 0 }), { op = 2, args = {} } })
  Assert.equal(#zero.items, 1, "only the source end instruction remains after the audited no-op")
  Assert.equal(zero.items[1].op, "stop")
  Assert.equal(#zero.omissions, 1)
  Assert.equal(zero.omissions[1].opcode, 815)
  Assert.isTrue(Verifier.verifyScript(zero.items, zeroScript, zeroMember, zero.omissions).ok)

  local nonzeroScript, nonzero, nonzeroMember = decodeAndLower({ command(815, { 1 }), { op = 2, args = {} } })
  Assert.equal(#nonzero.items, 2, "nonzero return selectors remain explicit unsupported nodes")
  Assert.equal(nonzero.items[1].op, "unsupported")
  Assert.equal(nonzero.items[1].command, 815)
  Assert.equal(nonzero.items[1].arguments[1], 1)
  Assert.isTrue(Verifier.verifyScript(nonzero.items, nonzeroScript, nonzeroMember, nonzero.omissions).ok)
end

function T.branch_targets_on_omitted_default_return_keep_the_label()
  local target = 0x26
  local script, lowered = decodeAndLower({
    { op = 22, args = { { target = target, width = 4 } } },
    command(815, { 0 }),
    { op = 2, args = {} },
  })
  local structured = Structurer.structure(lowered, 0)
  Assert.equal(script.instructions[2].label, ("_%04X"):format(target))
  Assert.equal(structured[1].op, "goto")
  Assert.equal(structured[1].target, script.instructions[2].label)

  local nopScript, nopLowered = decodeAndLower({
    { op = 22, args = { { target = target, width = 4 } } },
    { op = 0, args = {} },
    { op = 2, args = {} },
  })
  local nopStructured = Structurer.structure(nopLowered, 0)
  Assert.equal(nopStructured[1].target, nopScript.instructions[2].label)
end

return { tests = T }
