-- Translation-verifier unit tests: the classification checks that pin the
-- caller-signal fallthrough protocol (opcode 21) and the surrounding
-- stop/continue accounting on synthetic members. No ROM and no decomp
-- checkout required.

local Assert = require("tests.support.Assert")
local ScriptFixture = require("tests.support.ScriptFixture")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local Structurer = require("romdump.src.digest.script.Structurer")
local Verifier = require("romdump.src.digest.script.Verifier")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")
local ScriptIdentity = require("libs.assets.src.ScriptIdentity")

local T = {}

local CATALOG = {
  sounds = {},
  flags = {},
  vars = {},
  maps = {},
}

local function verify(bytes)
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  local steps = Structurer.structure(lowered, 0)
  local report = Verifier.verifyScript(steps, ir.scripts[0], ir, lowered.omissions)
  return steps, report
end

-- The catalog itself owns the same-tick fallthrough classification.
function T.opcode_21_is_continue_classified_in_the_catalog()
  Assert.equal(CommandCatalog.classification(21), CommandCatalog.CONTINUE)
  Assert.equal(CommandCatalog.name(21), "ScrCmd_RestartCurrentScript")
end

-- A signal followed by End remains a complete translation while the signal
-- itself is classified as ordinary same-tick fallthrough.
function T.signal_caller_fallthrough_verifies_as_complete_translation()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 21, args = {} },
          { op = 2, args = {} },
        },
      },
    },
  })
  local _, report = verify(bytes)
  Assert.isTrue(report.ok, report.problems[1] and report.problems[1].message or "signal_caller must verify")
  Assert.isTrue(report.complete)
end

-- The post-signal instructions of a context are ordinary covered source:
-- the verifier treats them as reachable fallthrough material and requires
-- them to stay covered, exactly like any other instruction.
function T.post_signal_instructions_stay_covered()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 21, args = {} },
          { op = 30, args = { { value = 3, width = 2 } } },
          { op = 2, args = {} },
        },
      },
    },
  })
  local _, report = verify(bytes)
  Assert.isTrue(report.ok, report.problems[1] and report.problems[1].message or "post-signal code must verify")
  Assert.isTrue(report.complete)
end

-- A multi-step group shares its source provenance across every canonical
-- step, release_all pairs its provenance-carrying node with exactly one
-- provenance-less yield, and the resulting program verifies complete.
function T.grouped_steps_share_provenance_while_synthesized_yields_carry_none()
  local instructions = {
    {
      opcode = 339,
      operands = { { raw = 2 }, { raw = 684 }, { raw = 393 }, { raw = 0 }, { raw = 0 } },
      offset = 0x20,
    },
    { opcode = 97, operands = {}, offset = 0x2A },
    { opcode = 2, operands = {}, offset = 0x2C },
  }
  local script = { label = "_ENTRY", instructions = instructions }
  local memberIr = { member = 5, scripts = { [0] = script }, movements = {} }
  local lowered = SemanticLowering.lowerScript(script, memberIr, { stdCatalog = SourceCatalog.catalog() })
  local ops = {}
  for _, item in ipairs(lowered.items) do
    ops[#ops + 1] = item.op
  end
  Assert.deepEqual(ops, { "set_object_position", "set_object_facing", "release_all", "yield_tick", "stop" })
  Assert.deepEqual(
    lowered.items[1].provenance,
    { offsets = { 0x20 }, opcodes = { 339 } },
    "the position step keeps the group source"
  )
  Assert.deepEqual(
    lowered.items[2].provenance,
    { offsets = { 0x20 }, opcodes = { 339 } },
    "the facing step keeps the group source"
  )
  Assert.deepEqual(lowered.items[3].provenance, { offsets = { 0x2A }, opcodes = { 97 } }, "release keeps its source")
  Assert.isNil(lowered.items[4].provenance, "the synthesized yield carries no source provenance")
  Assert.equal(#lowered.unsupported, 0)
  local steps = Structurer.structure(lowered, 0)
  local report = Verifier.verifyScript(steps, script, memberIr, lowered.omissions)
  Assert.isTrue(report.ok, report.problems[1] and report.problems[1].message or "group must verify")
  Assert.isTrue(report.complete)
end

-- An NPCMsg without its CloseMsg never becomes say: the primitive message
-- keeps its native print wait and the button wait stays explicit, with no
-- synthetic close and no missing provenance.
function T.unfolded_message_keeps_print_wait_without_synthetic_close()
  local instructions = {
    { opcode = 45, operands = { { raw = 31 } }, offset = 0x20 },
    { opcode = 50, operands = {}, offset = 0x23 },
    { opcode = 2, operands = {}, offset = 0x25 },
  }
  local script = { label = "_ENTRY", instructions = instructions }
  local memberIr = { member = 5, scripts = { [0] = script }, movements = {} }
  local lowered = SemanticLowering.lowerScript(script, memberIr, { stdCatalog = SourceCatalog.catalog() })
  local ops = {}
  for _, item in ipairs(lowered.items) do
    ops[#ops + 1] = item.op
  end
  Assert.deepEqual(ops, { "message", "wait_input", "stop" })
  Assert.equal(lowered.items[1].waitForPrint, true)
  Assert.deepEqual(lowered.items[1].provenance, { offsets = { 0x20 }, opcodes = { 45 } })
  Assert.deepEqual(lowered.items[2].provenance, { offsets = { 0x23 }, opcodes = { 50 } })
  Assert.equal(#lowered.unsupported, 0)
  local steps = Structurer.structure(lowered, 0)
  local report = Verifier.verifyScript(steps, script, memberIr, lowered.omissions)
  Assert.isTrue(report.ok, report.problems[1] and report.problems[1].message or "unfolded message must verify")
  Assert.isTrue(report.complete)
end

-- Cross-script branches keep their target script, entry label and source
-- timing: local jumps become script references, conditionals wrap the
-- reference, compared fallbacks ride the compare state, and a dangling
-- target stays one explicit unsupported diagnostic.
function T.cross_script_branches_keep_targets_labels_and_timing()
  local targetScript = {
    label = "_S1",
    instructions = {
      { opcode = 30, operands = { { raw = 3 } }, offset = 0x100 },
      { opcode = 2, operands = {}, offset = 0x104, label = "_INNER" },
    },
  }
  local expectedScript = ScriptIdentity.formatVanilla(5, 1)
  local function lower(instructions)
    local script = { label = "_S0", instructions = instructions }
    local memberIr = { member = 5, scripts = { [0] = script, [1] = targetScript }, movements = {} }
    local lowered = SemanticLowering.lowerScript(script, memberIr, { stdCatalog = SourceCatalog.catalog() })
    return script, memberIr, lowered
  end
  local function checkVerifies(script, memberIr, lowered, complete)
    local steps = Structurer.structure(lowered, 0)
    local report = Verifier.verifyScript(steps, script, memberIr, lowered.omissions)
    Assert.isTrue(report.ok, report.problems[1] and report.problems[1].message or "branch must verify")
    Assert.equal(report.complete, complete)
    return report
  end
  -- A jump to the other script body carries the script with no entry label.
  do
    local script, memberIr, lowered = lower({
      { opcode = 22, operands = { { raw = "_S1" } }, offset = 0x20 },
      { opcode = 2, operands = {}, offset = 0x26 },
    })
    Assert.deepEqual(lowered.items[1], {
      op = "goto_script",
      script = expectedScript,
      provenance = { offsets = { 0x20 }, opcodes = { 22 } },
    })
    Assert.equal(#lowered.unsupported, 0)
    checkVerifies(script, memberIr, lowered, true)
  end
  -- A call into the other script keeps its interior entry label.
  do
    local script, memberIr, lowered = lower({
      { opcode = 26, operands = { { raw = "_INNER" } }, offset = 0x20 },
      { opcode = 2, operands = {}, offset = 0x26 },
    })
    Assert.deepEqual(lowered.items[1], {
      op = "call",
      target = expectedScript,
      label = "_INNER",
      provenance = { offsets = { 0x20 }, opcodes = { 26 } },
    })
    Assert.equal(#lowered.unsupported, 0)
    checkVerifies(script, memberIr, lowered, true)
  end
  -- A folded conditional over the member boundary wraps the script call.
  do
    local script, memberIr, lowered = lower({
      { opcode = 17, operands = { { raw = 1 }, { raw = 2 } }, offset = 0x20 },
      { opcode = 29, operands = { { raw = 1 }, { raw = "_INNER" } }, offset = 0x26 },
      { opcode = 2, operands = {}, offset = 0x2D },
    })
    local head = lowered.items[1]
    Assert.equal(head.op, "if")
    Assert.equal(head.condition.operator, "eq")
    Assert.deepEqual(head.yes, { { op = "call", target = expectedScript, label = "_INNER" } })
    Assert.deepEqual(head.no, {})
    Assert.deepEqual(head.provenance, { offsets = { 0x20, 0x26 }, opcodes = { 17, 29 } })
    Assert.equal(#lowered.unsupported, 0)
    checkVerifies(script, memberIr, lowered, true)
  end
  -- An unfolded compared branch rides the same compare state across.
  do
    local script, memberIr, lowered = lower({
      { opcode = 28, operands = { { raw = 1 }, { raw = "_INNER" } }, offset = 0x20 },
      { opcode = 2, operands = {}, offset = 0x27 },
    })
    Assert.deepEqual(lowered.items[1], {
      op = "goto_compared",
      operator = "eq",
      script = expectedScript,
      label = "_INNER",
      provenance = { offsets = { 0x20 }, opcodes = { 28 } },
    })
    Assert.equal(#lowered.unsupported, 0)
    checkVerifies(script, memberIr, lowered, true)
  end
  -- A dangling target stays one explicit unsupported diagnostic.
  do
    local script, memberIr, lowered = lower({
      { opcode = 22, operands = { { raw = "_NOPE" } }, offset = 0x20 },
      { opcode = 2, operands = {}, offset = 0x26 },
    })
    Assert.equal(lowered.items[1].op, "unsupported")
    Assert.equal(lowered.items[1].reason, "branch target does not exist in this member")
    Assert.deepEqual(lowered.items[1].provenance, { offsets = { 0x20 }, opcodes = { 22 } })
    Assert.equal(#lowered.unsupported, 1)
    Assert.isTrue(lowered.unsupported[1] == lowered.items[1], "the diagnostic node is the emitted item")
    local report = checkVerifies(script, memberIr, lowered, false)
    Assert.equal(report.unsupportedCount, 1)
  end
end

return { tests = T }
