-- Lowering coverage for the dex script commands: each in-scope source
-- command decodes to exactly one semantic operation with the observed
-- source operand order, literal mode/action bytes normalize to their
-- semantic enums, evaluated operands keep variable reads symbolic, the
-- Rotom spare operand rides through for the runtime to evaluate and
-- discard, and an illegal national action fails with its source
-- context instead of lowering. A short mixed sequence preserves
-- command order, and semantic nodes never carry a native opcode.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local Errors = require("libs.errors.src.Errors")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local T = {}

local function lowerSingle(opcode, operands)
  local widths = CommandCatalog.widths(opcode) or {}
  local raw = {}
  for index = 1, #widths do
    raw[index] = operands[index] ~= nil and operands[index] or 0
  end
  local lowered = SemanticLowering.lowerScript(
    { instructions = { { opcode = opcode, operands = raw, offset = 0 } } },
    { member = 12, scripts = {}, movements = {} },
    { stdCatalog = SourceCatalog.catalog() }
  )
  Assert.equal(#lowered.items, 1, "opcode " .. opcode .. " lowers to one step")
  return lowered.items[1]
end

local function lowerSequence(entries)
  local instructions = {}
  for index, entry in ipairs(entries) do
    instructions[index] = { opcode = entry[1], operands = entry[2], offset = (index - 1) * 8 }
  end
  local lowered = SemanticLowering.lowerScript(
    { instructions = instructions },
    { member = 12, scripts = {}, movements = {} },
    { stdCatalog = SourceCatalog.catalog() }
  )
  return lowered.items
end

function T.dex_counts_lower_to_their_semantic_operation()
  local cases = {
    [243] = { mode = "johto", kind = "seen" },
    [244] = { mode = "johto", kind = "caught" },
    [245] = { mode = "national", kind = "seen" },
    [246] = { mode = "national", kind = "caught" },
  }
  for opcode, expected in pairs(cases) do
    local node = lowerSingle(opcode, { 0x800C })
    Assert.equal(node.op, "pokedex_count", "opcode " .. opcode .. " lowers to the count operation")
    Assert.equal(node.mode, expected.mode, "opcode " .. opcode .. " carries its dex mode")
    Assert.equal(node.kind, expected.kind, "opcode " .. opcode .. " carries its count kind")
    Assert.deepEqual(node.result, { value = "var", id = 0x800C }, "opcode " .. opcode .. " keeps the result reference")
    Assert.isNil(node.command, "opcode " .. opcode .. " leaves no native opcode in the node")
  end
end

function T.evaluation_and_completion_lower_with_source_order()
  local evaluate = lowerSingle(248, { 0, 0x8000, 0x8001 })
  Assert.equal(evaluate.op, "pokedex_evaluate", "the evaluation lowers to its operation")
  Assert.equal(evaluate.mode, "johto", "a zero mode byte reads johto")
  Assert.deepEqual(evaluate.result, { value = "var", id = 0x8000 }, "the message result keeps its position")
  Assert.deepEqual(evaluate.musicResult, { value = "var", id = 0x8001 }, "the music result keeps its position")

  local national = lowerSingle(248, { 1, 0x8000, 0x8001 })
  Assert.equal(national.mode, "national", "a nonzero mode byte reads national")

  local johtoComplete = lowerSingle(423, { 0x800C })
  Assert.equal(johtoComplete.op, "pokedex_complete", "the johto completion lowers to its operation")
  Assert.equal(johtoComplete.mode, "johto", "the johto completion carries its mode")
  local nationalComplete = lowerSingle(424, { 0x800C })
  Assert.equal(nationalComplete.op, "pokedex_complete", "the national completion lowers to its operation")
  Assert.equal(nationalComplete.mode, "national", "the national completion carries its mode")
end

function T.flag_grants_lower_to_their_semantic_operations()
  local check = lowerSingle(290, { 0x800C })
  Assert.equal(check.op, "has_pokedex", "the ownership query lowers to its operation")
  Assert.deepEqual(check.result, { value = "var", id = 0x800C }, "the ownership query keeps its result")

  local give = lowerSingle(291, {})
  Assert.equal(give.op, "give_pokedex", "the grant lowers to its operation")

  local forms = lowerSingle(476, {})
  Assert.equal(forms.op, "enable_pokedex_form_detection", "form detection lowers to its operation")

  local enable = lowerSingle(477, { 1, 0x800C })
  Assert.equal(enable.op, "national_pokedex", "the national action lowers to its operation")
  Assert.equal(enable.action, "enable", "a one action byte reads enable")
  local checkNational = lowerSingle(477, { 2, 0x800C })
  Assert.equal(checkNational.action, "check", "a two action byte reads check")
  Assert.deepEqual(checkNational.result, { value = "var", id = 0x800C }, "the national action keeps its result")
end

function T.invalid_national_action_fails_with_source_context()
  local ok, failure = pcall(lowerSingle, 477, { 9, 0x800C })
  Assert.isFalse(ok, "an unknown national action never lowers")
  Assert.isTrue(Errors.is(failure), "the failure uses the structured source-error path")
  local context = failure.context or {}
  local namesSource = context.command == 477 or context.opcode == 477 or context.offset == 0
  Assert.isTrue(namesSource, "the error names the offending source command")
end

function T.specialized_form_commands_lower_their_evaluated_operands()
  local deoxys = lowerSingle(518, { 0x8000 })
  Assert.equal(deoxys.op, "set_party_deoxys_form", "the Deoxys command lowers to its operation")
  Assert.deepEqual(deoxys.form, { value = "var", id = 0x8000 }, "the form operand stays a variable read")

  local rotom = lowerSingle(675, { 0x8000, 1, 0x8001, 2 })
  Assert.equal(rotom.op, "update_rotom_form", "the Rotom command lowers to its operation")
  Assert.deepEqual(rotom.slot, { value = "var", id = 0x8000 }, "the slot operand stays a variable read")
  Assert.equal(rotom.defaultMoveSlot, 1, "the default slot keeps its literal value")
  Assert.deepEqual(rotom.unused, { value = "var", id = 0x8001 }, "the spare operand rides through unevaluated")
  Assert.equal(rotom.form, 2, "the form operand keeps its literal value")
end

function T.synthetic_seen_and_query_lower_their_species_operand()
  local seen = lowerSingle(687, { 0x8000 })
  Assert.equal(seen.op, "observe_species", "the synthetic seen lowers to its operation")
  Assert.deepEqual(seen.species, { value = "var", id = 0x8000 }, "the species operand stays a variable read")

  local literalSeen = lowerSingle(687, { 25 })
  Assert.equal(literalSeen.species, 25, "a literal species operand rides through for the service")

  local query = lowerSingle(707, { 0x8000, 0x800C })
  Assert.equal(query.op, "has_seen_species", "the seen query lowers to its operation")
  Assert.deepEqual(query.species, { value = "var", id = 0x8000 }, "the query species stays a variable read")
  Assert.deepEqual(query.result, { value = "var", id = 0x800C }, "the query keeps its result")
end

function T.unown_commands_lower_to_their_caught_operations()
  local count = lowerSingle(545, { 0x800C })
  Assert.equal(count.op, "caught_unown_count", "the Unown count lowers to its operation")
  Assert.deepEqual(count.result, { value = "var", id = 0x800C }, "the Unown count keeps its result")

  local alphabet = lowerSingle(770, { 0x800C })
  Assert.equal(alphabet.op, "caught_all_unown_letters", "the alphabet check lowers to its operation")
  Assert.deepEqual(alphabet.result, { value = "var", id = 0x800C }, "the alphabet check keeps its result")
end

function T.mixed_dex_sequence_preserves_command_order()
  local items = lowerSequence({
    { 243, { 0x8000 } },
    { 291, {} },
    { 707, { 25, 0x8001 } },
  })
  Assert.equal(#items, 3, "the sequence lowers to three steps")
  Assert.equal(items[1].op, "pokedex_count", "the count keeps its position")
  Assert.equal(items[2].op, "give_pokedex", "the grant keeps its position")
  Assert.equal(items[3].op, "has_seen_species", "the query keeps its position")
  Assert.equal(items[3].species, 25, "the query keeps its literal species operand")
end

return { tests = T }
