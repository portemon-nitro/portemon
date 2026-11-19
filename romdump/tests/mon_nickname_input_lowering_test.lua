-- Opcode 173 lowers to the blocking mon nickname semantic operation.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")
local ScriptFixture = require("tests.support.ScriptFixture")
local Structurer = require("romdump.src.digest.script.Structurer")
local Verifier = require("romdump.src.digest.script.Verifier")

local function lower(operands)
  local widths = assert(CommandCatalog.widths(173))
  local raw = {}
  for index = 1, #widths do
    raw[index] = operands[index] or 0
  end
  return SemanticLowering.lowerScript(
    { instructions = { { opcode = 173, operands = raw, offset = 0x42 } } },
    { member = 12, scripts = {}, movements = {} },
    { stdCatalog = SourceCatalog.catalog() }
  )
end

local function verify(operands)
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 173, args = { { value = operands[1], width = 2 }, { value = operands[2], width = 2 } } },
          { op = 2, args = {} },
        },
      },
    },
  })
  local memberIr = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", {
    msgBank = 543,
    catalog = { sounds = {}, flags = {}, vars = {}, maps = {} },
  }))
  local script = memberIr.scripts[0]
  local lowered = SemanticLowering.lowerScript(script, memberIr, { stdCatalog = SourceCatalog.catalog() })
  local steps = Structurer.structure(lowered, 0)
  return Verifier.verifyScript(steps, script, memberIr, lowered.omissions)
end

-- Translate and verify one script of a synthetic member.
local function lowerScriptIndex(bytes, index)
  local memberIr = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", {
    msgBank = 543,
    catalog = { sounds = {}, flags = {}, vars = {}, maps = {} },
  }))
  local script = assert(memberIr.scripts[index])
  local lowered = SemanticLowering.lowerScript(script, memberIr, { stdCatalog = SourceCatalog.catalog() })
  local steps = Structurer.structure(lowered, index)
  return lowered, steps, Verifier.verifyScript(steps, script, memberIr, lowered.omissions)
end

local tests = {}

function tests.ordinary_opcode_173_is_a_verified_native_wait()
  Assert.deepEqual(CommandCatalog.widths(173), { 2, 2 })
  Assert.equal(CommandCatalog.classification(173), CommandCatalog.NATIVE_WAIT)
  Assert.isNil(CommandCatalog.disposition(173))

  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 173, args = { { value = 0, width = 2 }, { value = 0x800C, width = 2 } } },
          { op = 2, args = {} },
        },
      },
    },
  })
  local memberIr = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", {
    msgBank = 543,
    catalog = { sounds = {}, flags = {}, vars = {}, maps = {} },
  }))
  local script = memberIr.scripts[0]
  local lowered = SemanticLowering.lowerScript(script, memberIr, { stdCatalog = SourceCatalog.catalog() })
  local steps = Structurer.structure(lowered, 0)
  local report = Verifier.verifyScript(steps, script, memberIr, lowered.omissions)

  Assert.isTrue(report.ok, report.problems[1] and report.problems[1].message or "nickname input must verify")
  Assert.isTrue(report.complete)
  Assert.equal(steps[1].op, "pokemon_nickname_input")
end

function tests.opcode_lowers_with_value_slot_result_and_provenance()
  local lowered = lower({ 0, 0x800C })
  Assert.equal(#lowered.items, 1)
  local node = lowered.items[1]
  Assert.equal(node.op, "pokemon_nickname_input")
  Assert.equal(node.slot, 0)
  Assert.deepEqual(node.result, { value = "var", id = 0x800C })
  Assert.deepEqual(node.provenance.offsets, { 0x42 })
  Assert.deepEqual(node.provenance.opcodes, { 173 })
  Assert.equal(#lowered.unsupported, 0)
end

function tests.literal_bug_contest_slot_is_explicitly_unsupported()
  local lowered = lower({ 255, 0x800C })
  Assert.equal(#lowered.items, 1)
  local node = lowered.items[1]
  Assert.equal(node.op, "unsupported")
  Assert.equal(node.command, 173)
  Assert.equal(node.originalName, CommandCatalog.name(173))
  Assert.deepEqual(node.arguments, { 255, 0x800C })
  Assert.equal(node.sourceOffset, 0x42)
  Assert.isTrue(node.reason:find("Bug Contest", 1, true) ~= nil)
  Assert.deepEqual(node.provenance.offsets, { 0x42 })
  Assert.deepEqual(node.provenance.opcodes, { 173 })
  Assert.deepEqual(lowered.unsupported, { node })
  local report = verify({ 255, 0x800C })
  Assert.isFalse(report.complete, "literal Bug Contest target must make the script incomplete")
end

-- The ordinary party slot keeps its blocking naming task while the literal
-- Bug Contest target stays an explicit unsupported node: no synthetic party
-- nickname screen can be reached for the contest caught mon, and the
-- special case keeps its own source offset.
function tests.bug_contest_slot_stays_deferred_while_party_slots_keep_naming()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 173, args = { { value = 0, width = 2 }, { value = 0x800C, width = 2 } } },
          { op = 2, args = {} },
        },
      },
      {
        offset = 0x28,
        instructions = {
          { op = 173, args = { { value = 255, width = 2 }, { value = 0x800C, width = 2 } } },
          { op = 2, args = {} },
        },
      },
    },
  })

  local _, partySteps, partyReport = lowerScriptIndex(bytes, 0)
  Assert.equal(partySteps[1].op, "pokemon_nickname_input", "an ordinary slot keeps the blocking naming task")
  Assert.equal(partySteps[1].slot, 0)
  Assert.equal(partySteps[1].result.value, "var")
  Assert.isTrue(
    partyReport.ok,
    partyReport.problems[1] and partyReport.problems[1].message or "ordinary naming verifies"
  )
  Assert.isTrue(partyReport.complete)

  local contestLowered, contestSteps, contestReport = lowerScriptIndex(bytes, 1)
  for _, step in ipairs(contestSteps) do
    Assert.isTrue(step.op ~= "pokemon_nickname_input", "the contest caught mon never reaches the party naming task")
  end
  local node = contestLowered.items[1]
  Assert.equal(node.op, "unsupported")
  Assert.equal(node.command, 173)
  Assert.deepEqual(node.arguments, { 255, "VAR_0x800C" })
  Assert.equal(node.sourceOffset, 0x28)
  Assert.isTrue(node.reason:find("Bug Contest", 1, true) ~= nil, "the deferral names its missing owner")
  Assert.deepEqual(contestLowered.unsupported, { node })
  Assert.isFalse(contestReport.complete, "the deferred target keeps the script incomplete")
  Assert.equal(contestReport.unsupportedCount, 1)
end

return { tests = tests }
