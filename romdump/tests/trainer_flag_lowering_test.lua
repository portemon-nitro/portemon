-- Trainer flag source commands lower onto the existing numeric world-event
-- flags: the source trainer number resolves through the retail
-- TRAINER_FLAG_BASE offset, set/clear are same-tick writes, and the check
-- publishes comparison state for the following branch instead of writing a
-- result variable.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")
local ScriptFixture = require("tests.support.ScriptFixture")
local Structurer = require("romdump.src.digest.script.Structurer")
local Verifier = require("romdump.src.digest.script.Verifier")

local CATALOG = { sounds = {}, flags = {}, vars = {}, maps = {} }
-- Lower a hand-built instruction sequence: every instruction is
-- `{ opcode, operands, offset, label? }` with raw operand words, the same
-- shape the decoder produces.
local function lower(instructions)
  local built = {}
  for index, ins in ipairs(instructions) do
    built[index] = {
      opcode = ins[1],
      operands = ins[2],
      offset = ins[3] or (0x20 + index * 8),
      label = ins[4],
    }
  end
  local script = { label = "_ENTRY", instructions = built }
  local memberIr = { member = 5, scripts = { [0] = script }, movements = {} }
  local lowered = SemanticLowering.lowerScript(script, memberIr, { stdCatalog = SourceCatalog.catalog() })
  local steps = Structurer.structure(lowered, 0)
  local report = Verifier.verifyScript(steps, script, memberIr, lowered.omissions)
  return lowered, report
end

-- Translate and verify one synthetic script holding the given
-- `{ opcode, args }` instruction specs.
local function translate(instructions)
  local script = { offset = 0x20, instructions = {} }
  for _, ins in ipairs(instructions) do
    script.instructions[#script.instructions + 1] = { op = ins[1], args = ins[2] or {} }
  end
  local bytes = ScriptFixture.member({ scripts = { script } })
  local memberIr = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", {
    msgBank = 543,
    catalog = CATALOG,
  }))
  local source = assert(memberIr.scripts[0])
  local lowered = SemanticLowering.lowerScript(source, memberIr, { stdCatalog = SourceCatalog.catalog() })
  local steps = Structurer.structure(lowered, 0)
  return lowered, steps, Verifier.verifyScript(steps, source, memberIr, lowered.omissions)
end

local function trainerValue(trainer)
  return { value = "trainer_flag_id", trainer = trainer }
end
-- The first conditional node of a step tree: a folded condition keeps any
-- of the branch shapes the structurer derives from it.
---@param steps table[]
---@return table|nil
local function findConditional(steps)
  for _, step in ipairs(steps) do
    if step.op == "if_cond" or step.op == "goto_if" or step.op == "if" then
      if step.condition ~= nil then
        return step
      end
    end
    if step.op == "if" then
      local nested = findConditional(step.yes or {})
      if nested ~= nil then
        return nested
      end
      nested = findConditional(step.no or {})
      if nested ~= nil then
        return nested
      end
    end
  end
  return nil
end

local tests = {}

-- The three source commands are same-tick natives with no unresolved
-- mon-family disposition left behind.
function tests.trainer_flag_commands_are_same_tick_source_commands()
  for _, opcode in ipairs({ 36, 37, 38 }) do
    Assert.deepEqual(CommandCatalog.widths(opcode), { 2 }, "command " .. opcode .. " reads one 16-bit operand")
    Assert.equal(
      CommandCatalog.classification(opcode),
      CommandCatalog.CONTINUE,
      "command " .. opcode .. " returns from its native handler on the same tick"
    )
    Assert.isNil(CommandCatalog.disposition(opcode), "command " .. opcode .. " carries no unresolved disposition")
  end
end

-- The trainer number is a ScriptGetVar operand: a literal stays literal and a
-- variable id stays a variable reference inside the trainer flag value.
function tests.set_and_clear_lower_to_the_trainer_flag_value_kind()
  local lowered = lower({
    { 36, { { raw = 3 } }, 0x2A },
    { 37, { { raw = 0x8008 } }, 0x2E },
  })
  Assert.deepEqual(lowered.items[1], {
    op = "set_flag",
    flag = trainerValue(3),
    provenance = { offsets = { 0x2A }, opcodes = { 36 } },
  })
  Assert.deepEqual(lowered.items[2], {
    op = "clear_flag",
    flag = trainerValue({ value = "var", id = 0x8008 }),
    provenance = { offsets = { 0x2E }, opcodes = { 37 } },
  })
  Assert.equal(#lowered.unsupported, 0, "a trainer flag operand is not an unsupported command")
  Assert.equal(#lowered.omissions, 0)
end

-- The check writes native comparison state: one operand, a comparison of the
-- trainer flag value against one, and no result variable of its own.
function tests.check_lowers_to_the_flag_comparison_without_a_result_variable()
  local lowered = lower({ { 38, { { raw = 3 } }, 0x31 } })
  Assert.equal(#lowered.items, 1)
  Assert.deepEqual(lowered.items[1], {
    op = "compare",
    left = { value = "flag_value", flag = trainerValue(3) },
    right = 1,
    provenance = { offsets = { 0x31 }, opcodes = { 38 } },
  })
  Assert.isNil(lowered.items[1].result, "the check writes native comparison state, not a variable")
  Assert.equal(#lowered.unsupported, 0)
end

-- The check's comparison state is what the following branch consumes, so the
-- pairwise fold keeps the source condition and verifies.
function tests.checked_branch_branches_on_the_trainer_flag_comparison()
  -- 0x20: CheckTrainerFlag 3 (4 bytes) -> 0x24
  -- 0x24: GoToIf eq -> 0x2B (7 bytes) -> 0x2B
  -- 0x2B: End (2 bytes)
  local _, steps, report = translate({
    { 38, { { value = 3, width = 2 } } },
    { 28, { { value = 1, width = 1 }, { target = 0x2B, width = 4 } } },
    { 2 },
  })
  Assert.isTrue(report.ok, report.problems[1] and report.problems[1].message or "the trainer flag branch must verify")
  Assert.isTrue(report.complete)
  local conditional = findConditional(steps)
  Assert.notNil(conditional, "the check and the branch rise to one conditional")
  Assert.deepEqual(conditional.condition, {
    condition = "compare",
    operator = "eq",
    left = { value = "flag_value", flag = trainerValue(3) },
    right = 1,
  })
  Assert.deepEqual(conditional.provenance.offsets, { 0x20, 0x24 }, "the fold keeps both source offsets")
  Assert.deepEqual(conditional.provenance.opcodes, { 38, 28 })
end

-- A variable-backed trainer number keeps the source indirection through the
-- branch fold instead of being read at compile time.
function tests.variable_trainer_number_survives_the_branch_fold()
  local lowered = lower({
    { 38, { { raw = 0x8008 } }, 0x20 },
    { 28, { { raw = 1 }, { raw = "_END" } }, 0x24 },
    { 2, {}, 0x2D, "_END" },
  })
  local conditional = lowered.items[1]
  Assert.equal(conditional.op, "if_cond")
  Assert.equal(conditional.condition.operator, "eq")
  Assert.equal(conditional.condition.right, 1)
  Assert.deepEqual(conditional.condition.left, {
    value = "flag_value",
    flag = trainerValue({ value = "var", id = 0x8008 }),
  })
end

-- The existing SetFlagVar/ClearFlagVar/SetVarFromFlag commands retain their
-- variable-reference identity through lowering; direct flags remain literal.
function tests.variable_backed_flag_commands_keep_source_operand_identity()
  local lowered, report = lower({
    { 30, { { raw = 0x8006 } }, 0x20 },
    { 31, { { raw = 0x8006 } }, 0x24 },
    { 33, { { raw = 0x8006 } }, 0x28 },
    { 34, { { raw = 0x8006 } }, 0x2C },
    { 35, { { raw = 0x8006 }, { raw = 0x8007 } }, 0x30 },
  })

  Assert.isTrue(report.ok, report.problems[1] and report.problems[1].message or "source flag operands must verify")
  Assert.isTrue(report.complete)
  Assert.deepEqual(lowered.items, {
    { op = "set_flag", flag = 0x8006, provenance = { offsets = { 0x20 }, opcodes = { 30 } } },
    { op = "clear_flag", flag = 0x8006, provenance = { offsets = { 0x24 }, opcodes = { 31 } } },
    {
      op = "set_flag",
      flag = { value = "var", id = 0x8006 },
      provenance = { offsets = { 0x28 }, opcodes = { 33 } },
    },
    {
      op = "clear_flag",
      flag = { value = "var", id = 0x8006 },
      provenance = { offsets = { 0x2C }, opcodes = { 34 } },
    },
    {
      op = "set_var",
      variable = { value = "var", id = 0x8007 },
      value = { value = "flag_value", flag = { value = "var", id = 0x8006 } },
      provenance = { offsets = { 0x30 }, opcodes = { 35 } },
    },
  })
  Assert.equal(#lowered.unsupported, 0)
end
return { tests = tests }
