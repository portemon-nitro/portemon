-- Native command framing: every reached opcode consumes exactly its source
-- operand frame, so branch destinations and the following command stay
-- aligned. These probes use tiny synthetic streams through the real
-- producer; byte offsets are the observable boundary, not opcode names.

local Assert = require("tests.support.Assert")

local T = {}

local function compiler()
  return require("romdump.src.digest.battle.BattleAnimationCompiler")
end

local function u32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

local function compileStream(key, words)
  local parts = {}
  for _, word in ipairs(words) do
    parts[#parts + 1] = u32(word)
  end
  return compiler().compile({ key = key, stream = table.concat(parts) })
end

local function offsetsOf(program)
  local offsets = {}
  for _, offset in ipairs(program.sourceOffsets) do
    offsets[#offsets + 1] = offset
  end
  return offsets
end

function T.clearing_a_battler_plane_consumes_one_word()
  -- ClearBattlerBg reads a single unused word; the word after it is the
  -- next command, never a second operand.
  local program = assert(compileStream("battler-plane-clear-frame", { 32, 7, 0, 4 }))
  Assert.deepEqual(offsetsOf(program), { 0, 8 }, "the command after one operand starts at byte 8")
end

function T.clearing_shared_cells_consumes_no_word()
  -- ClearArgs touches no operand word; the very next word dispatches.
  local program = assert(compileStream("shared-cell-clear-frame", { 67, 0, 4 }))
  Assert.deepEqual(offsetsOf(program), { 0, 4 }, "the command after a wordless clear starts at byte 4")
end

function T.attacker_presence_branch_consumes_one_word()
  -- The attacker-active conditional reads one relative offset word, so a
  -- stream framed on that width decodes cleanly with the next command
  -- intact.
  local ok, program = pcall(compileStream, "attacker-presence-branch-frame", { 87, 1, 0, 4 })
  Assert.isTrue(ok, "one-word attacker branch framing decodes without a provenance failure")
  local decoded = assert(program)
  Assert.equal(
    #decoded.instructions,
    2,
    "the branch operand word never decodes as a phantom third command"
  )
  Assert.deepEqual(offsetsOf(decoded), { 0, 8 }, "the command after the branch operand starts at byte 8")
end

function T.variant_branches_derive_each_destination_from_its_own_word()
  -- The variant-bit conditional carries two independent relative
  -- destinations, each based at its own operand word.
  local function targetsFor(clearCount, setCount)
    local program = assert(compileStream("variant-branch-bases", { 13, clearCount, setCount, 0, 9 }))
    local branch = assert(program.instructions[1])
    return branch.alternateTarget, branch.branchTarget
  end
  local clearTarget, setTarget = targetsFor(2, 1)
  Assert.equal(clearTarget, 2, "the clear destination follows the first operand word")
  Assert.equal(setTarget, 2, "the set destination follows the second operand word")
  local movedClear, steadySet = targetsFor(3, 1)
  Assert.equal(movedClear, 3, "moving the first word moves only the clear destination")
  Assert.equal(steadySet, 2, "the set destination stays anchored to the second word")
end

function T.weather_selection_records_named_conditions_not_raw_masks()
  -- The weather conditional selects among clear, rain, sand, sun, hail,
  -- and any other condition by name; raw side masks never drive it.
  local program = assert(compileStream("weather-branch-arms", { 70, 6, 5, 4, 3, 2, 1, 0, 9 }))
  local branch = assert(program.instructions[1])
  Assert.equal(#branch.branchCases, 6, "the weather conditional keeps all six selections")
  for index, case in ipairs(branch.branchCases) do
    Assert.isNil(case.sideMask, "selection " .. index .. " carries no raw side mask")
    Assert.isTrue(
      case.condition == "clear"
        or case.condition == "rain"
        or case.condition == "sand"
        or case.condition == "sun"
        or case.condition == "hail"
        or case.condition == "other",
      "selection " .. index .. " names its weather condition"
    )
  end
end

return { tests = T }
