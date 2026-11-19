-- Translation-verifier unit tests: the classification checks that pin the
-- caller-signal fallthrough protocol (opcode 21), the reachable/unsupported
-- accounting over a member's shared tails, the call-stack reasoning around
-- source Call/CallIf/Return, and the surrounding stop/continue accounting on
-- synthetic members. No ROM required.

local Assert = require("tests.support.Assert")
local ScriptFixture = require("tests.support.ScriptFixture")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local Structurer = require("romdump.src.digest.script.Structurer")
local Verifier = require("romdump.src.digest.script.Verifier")
local Coverage = require("romdump.src.digest.script.Coverage")
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

-- A source command the catalog decodes with no operands and no semantic
-- handler lowers: any script containing it carries one attributed
-- unsupported node at the command's own offset.
local UNSUPPORTED_OPCODE = 4

local SYNTHETIC_SOURCE = { repository = "synthetic", romSha1 = "synthetic" }

local function verify(bytes)
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  local steps = Structurer.structure(lowered, 0)
  local report = Verifier.verifyScript(steps, ir.scripts[0], ir, lowered.omissions)
  return steps, report
end

-- Lower and verify every script of one synthetic member. The result table is
-- keyed by script index and is also the Coverage.record input shape.
local function lowerMember(bytes, member)
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, member, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local results = {}
  for index, script in pairs(ir.scripts) do
    local lowered = SemanticLowering.lowerScript(script, ir, { stdCatalog = SourceCatalog.catalog() })
    local steps = Structurer.structure(lowered, index)
    results[index] = {
      script = script,
      steps = steps,
      report = Verifier.verifyScript(steps, script, ir, lowered.omissions),
    }
  end
  return ir, results
end

local function diagnosticsMention(list, needle)
  for _, entry in ipairs(list) do
    if type(entry.message) == "string" and entry.message:find(needle, 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function firstProblem(report)
  return report.problems[1] and report.problems[1].message or "no verifier problem"
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

-- Reachable support accounting follows the source control graph: a shared
-- tail that only another script calls is decoded in its own member but is
-- not reachable from its own entry, so its unsupported command is no
-- reachable support debt; a script whose own entry reaches an unsupported
-- command keeps it counted, with its source offset, and stays incomplete.
-- Coverage derives its per-member and aggregate totals from those reports
-- without a negative supported count.
function T.unsupported_accounting_counts_only_reachable_commands()
  local bytes = ScriptFixture.member({
    scripts = {
      -- Shared tail: its own entry ends at Return; the region after it is a
      -- call target of the next script.
      {
        offset = 0x20,
        instructions = {
          { op = 50, args = {} },
          { op = 27, args = {} },
          { op = UNSUPPORTED_OPCODE, args = {} },
          { op = 2, args = {} },
        },
      },
      -- The caller: one call into the shared tail, then End.
      {
        offset = 0x28,
        instructions = {
          { op = 26, args = { { target = 0x24, width = 4 } } },
          { op = 2, args = {} },
        },
      },
      -- A third script whose own entry reaches the unsupported command.
      {
        offset = 0x32,
        instructions = {
          { op = UNSUPPORTED_OPCODE, args = {} },
          { op = 2, args = {} },
        },
      },
    },
  })
  local ir, results = lowerMember(bytes, 5)

  local tail = results[0]
  Assert.isTrue(tail.script.prelude == true, "a table entry landing on a return-only body is a prelude-shaped library")
  Assert.equal(tail.report.reachable, 2, "only the tail's own entry path is reachable")
  Assert.equal(tail.report.total - tail.report.reachable, 1, "the called region is unreachable from the tail entry")
  Assert.equal(tail.report.unsupportedCount, 0, "an unreachable unsupported command is not reachable support debt")
  Assert.isTrue(tail.report.ok, firstProblem(tail.report))
  Assert.isTrue(tail.report.complete, "the tail's own entry path is a complete translation")
  Assert.isTrue(
    diagnosticsMention(tail.report.warnings, "return without any call in the script"),
    "a prelude Return stays a tolerated warning"
  )
  Assert.isTrue(
    diagnosticsMention(tail.report.warnings, "unreachable instructions"),
    "unreachable source stays reported"
  )

  local caller = results[1]
  Assert.equal(caller.steps[1].op, "call", "the caller keeps its call into the shared tail")
  Assert.isTrue(caller.report.complete, firstProblem(caller.report))

  local direct = results[2]
  Assert.equal(direct.report.reachable, 1)
  Assert.equal(direct.report.unsupportedCount, 1, "a reachable unsupported command counts once")
  Assert.isFalse(direct.report.complete, "reachable unsupported commands keep the script incomplete")
  local diagnostic = direct.report.unsupported[1]
  Assert.notNil(diagnostic, "the reachable unsupported command keeps its diagnostic")
  Assert.equal(diagnostic.command, UNSUPPORTED_OPCODE)
  Assert.equal(diagnostic.sourceOffset, 0x32, "the diagnostic keeps its source offset")

  local record = Coverage.record(ir, results, SYNTHETIC_SOURCE)
  Assert.equal(record.totals.scripts, 3)
  Assert.equal(record.totals.reachableInstructions, 5)
  Assert.equal(record.totals.unsupportedInstructions, 1, "only the reachable unsupported command reaches the totals")
  Assert.equal(
    record.totals.supportedInstructions,
    record.totals.reachableInstructions - record.totals.unsupportedInstructions
  )
  Assert.isTrue(record.totals.supportedInstructions >= 0, "supported instructions never go negative")
  local statusById = {}
  for _, entry in ipairs(record.scripts) do
    statusById[entry.sourceId] = entry.status
  end
  Assert.equal(statusById["hgss.scr_seq.0005.000"], "complete", "the shared tail reports complete")
  Assert.equal(statusById["hgss.scr_seq.0005.001"], "complete", "the caller reports complete")
  Assert.equal(statusById["hgss.scr_seq.0005.002"], "partial", "the reachable unsupported script reports partial")

  local completeMember = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 50, args = {} },
          { op = 2, args = {} },
        },
      },
    },
  })
  local completeIr, completeResults = lowerMember(completeMember, 6)
  local aggregate = Coverage.aggregate({ record, Coverage.record(completeIr, completeResults, SYNTHETIC_SOURCE) })
  Assert.equal(aggregate.totals.scripts, 4)
  Assert.equal(aggregate.totals.reachableInstructions, 7)
  Assert.equal(aggregate.totals.unsupportedInstructions, 1)
  Assert.equal(
    aggregate.totals.supportedInstructions + aggregate.totals.unsupportedInstructions,
    aggregate.totals.reachableInstructions,
    "member totals add up to the reachable instruction count"
  )
end

-- A conditional call pushes a frame only on its taken edge: the fallthrough
-- path continues at the caller's stack height, so a valid CallIf script
-- verifies without a phantom open frame.
function T.call_if_false_branch_does_not_invent_a_stack_frame()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          -- 0x20: compare (6) -> 0x26
          { op = 17, args = { { value = 1, width = 2 }, { value = 2, width = 2 } } },
          -- 0x26: CallIf (7) -> 0x2D, target 0x33 (the subroutine entry)
          { op = 29, args = { { value = 1, width = 1 }, { target = 0x33, width = 4 } } },
          -- 0x2D: SetFlag (4) -> 0x31
          { op = 30, args = { { value = 3, width = 2 } } },
          -- 0x31: End (2) -> 0x33
          { op = 2, args = {} },
          -- 0x33: subroutine entry, WaitButton (2) -> 0x35
          { op = 50, args = {} },
          -- 0x35: Return (2) -> 0x37
          { op = 27, args = {} },
        },
      },
    },
  })
  local _, results = lowerMember(bytes, 5)
  local report = results[0].report
  Assert.isTrue(report.ok, firstProblem(report))
  Assert.isTrue(report.complete, "a valid CallIf script is a complete translation")
  Assert.equal(report.unsupportedCount, 0)
  Assert.isFalse(
    diagnosticsMention(report.warnings, "non-empty call stack"),
    "the false branch never inherits the taken call's frame"
  )
  Assert.equal(#report.balance.problems, 0, "no balance problem is invented for the false branch")
end

-- The false path of a CallIf does not push, so a Return reached there is a
-- return below an empty stack and remains an error instead of being
-- silently accepted through a phantom frame.
function T.call_if_false_branch_return_stays_below_an_empty_stack()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          -- 0x20: compare (6) -> 0x26
          { op = 17, args = { { value = 1, width = 2 }, { value = 2, width = 2 } } },
          -- 0x26: CallIf (7) -> 0x2D, target 0x2F
          { op = 29, args = { { value = 1, width = 1 }, { target = 0x2F, width = 4 } } },
          -- 0x2D: the false path returns with no frame of its own
          { op = 27, args = {} },
          -- 0x2F: subroutine entry, WaitButton (2) -> 0x31
          { op = 50, args = {} },
          -- 0x31: Return (2) -> 0x33
          { op = 27, args = {} },
        },
      },
    },
  })
  local _, results = lowerMember(bytes, 5)
  local report = results[0].report
  Assert.isFalse(report.ok, "a Return on the untaken call's fallthrough stays a control-flow error")
  Assert.isTrue(
    diagnosticsMention(report.problems, "return"),
    "the failure is attributed to the unbalanced return, not to an unrelated check"
  )
end

-- A plain Call's fallthrough is the caller's continuation, not a second
-- pushed frame: nested local calls verify without a phantom open frame, a
-- callee that Ends instead of Returning stays the documented warning, and a
-- Return in the continuation is reported as unbalanced.
function T.plain_call_continuation_keeps_the_caller_frame()
  local nested = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          -- 0x20: Call (6) -> 0x26, target 0x28
          { op = 26, args = { { target = 0x28, width = 4 } } },
          -- 0x26: End (2) -> 0x28
          { op = 2, args = {} },
          -- 0x28: Call (6) -> 0x2E, target 0x30
          { op = 26, args = { { target = 0x30, width = 4 } } },
          -- 0x2E: Return (2) -> 0x30
          { op = 27, args = {} },
          -- 0x30: WaitButton (2) -> 0x32
          { op = 50, args = {} },
          -- 0x32: Return (2) -> 0x34
          { op = 27, args = {} },
        },
      },
    },
  })
  do
    local _, results = lowerMember(nested, 5)
    local report = results[0].report
    local ops = {}
    for _, step in ipairs(results[0].steps) do
      ops[#ops + 1] = step.op
    end
    Assert.deepEqual(ops, { "call", "stop", "label", "call", "return", "label", "wait_input", "return" })
    Assert.isTrue(report.ok, firstProblem(report))
    Assert.isTrue(report.complete, "nested local calls keep every pushed frame balanced")
    Assert.isFalse(
      diagnosticsMention(report.warnings, "non-empty call stack"),
      "a call's fallthrough continuation is not a second pushed frame"
    )
  end

  -- A subroutine that Ends instead of Returning unwinds the source context:
  -- the open frame stays a warning, exactly as the source idiom allows.
  do
    local bytes = ScriptFixture.member({
      scripts = {
        {
          offset = 0x20,
          instructions = {
            { op = 26, args = { { target = 0x28, width = 4 } } },
            { op = 2, args = {} },
            { op = 50, args = {} },
            { op = 2, args = {} },
          },
        },
      },
    })
    local _, results = lowerMember(bytes, 5)
    local report = results[0].report
    Assert.isTrue(report.ok, firstProblem(report))
    Assert.isTrue(
      diagnosticsMention(report.warnings, "non-empty call stack"),
      "an End that unwinds an open call frame stays the documented warning"
    )
  end

  -- The instruction after a plain Call runs after the callee returns; it has
  -- no frame of its own, so a Return there is unbalanced.
  do
    local bytes = ScriptFixture.member({
      scripts = {
        {
          offset = 0x20,
          instructions = {
            { op = 26, args = { { target = 0x28, width = 4 } } },
            { op = 27, args = {} },
            { op = 50, args = {} },
            { op = 27, args = {} },
          },
        },
      },
    })
    local _, results = lowerMember(bytes, 5)
    local report = results[0].report
    Assert.isFalse(report.ok, "a Return in the call continuation has no pushed frame")
    Assert.isTrue(diagnosticsMention(report.problems, "return"), "the unbalanced return is attributed")
  end
end

return { tests = T }
