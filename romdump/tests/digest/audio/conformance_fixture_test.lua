-- Reference-oriented SSEQ fixture coverage. Branch operands in this fixture
-- are encoded relative to the DATA payload, independently of the lowering
-- implementation's source-offset representation.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local SequenceLowering = require("romdump.src.digest.audio.SequenceLowering")
local SseqFixture = require("tests.support.SseqFixture")

local IDENTITY = { sequenceId = 0, symbol = "SEQ_FIXTURE" }

local T = {}

---@param e any
---@return Errors.Error
local function asError(e)
  return e
end

local function lowerRejects(bytes, code)
  local program, err = SequenceLowering.lower(bytes, IDENTITY)
  Assert.isNil(program, "expected lowering to fail with " .. code)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(asError(err).code, code)
  return asError(err)
end

function T.data_relative_branch_operands_reach_the_first_command()
  local bytes = SseqFixture.build({
    { op = "fe", mask = 3 },
    { op = "open_track", track = 1, target = { cmd = 4 } },
    { op = "call", target = { cmd = 4 } },
    { op = "jump", target = { cmd = 4 } },
    { op = "fin" },
  })
  local program, err = SequenceLowering.lower(bytes, { sequenceId = 0, symbol = "SEQ_FIXTURE" })
  Assert.notNil(program, "data-relative targets should lower: " .. tostring(err))
  program = assert(program)
  Assert.equal(program.entry, 1)
  Assert.equal(program.instructions[1].target, 3)
  Assert.equal(program.instructions[2].target, 3)
  Assert.equal(program.instructions[3].target, 3)
end

-- A reachable open_track whose destination the FE track mask does not
-- allocate is a build failure with provenance, never runtime allocation
-- state: the retail corpus always allocates its destinations up front.
function T.data_relative_open_track_outside_the_mask_is_rejected()
  local bytes = SseqFixture.build({
    { op = "fe", mask = 1 },
    { op = "open_track", track = 2, target = { cmd = 3 } },
    { op = "fin" },
  })
  local err = lowerRejects(bytes, "AUDIO_SEQUENCE_TRACK_NOT_ALLOCATED")
  Assert.equal(err.context.sequenceId, 0)
  Assert.equal(err.context.sequenceSymbol, "SEQ_FIXTURE")
  Assert.notNil(err.context.sourceOffset)
  Assert.equal(err.context.track, 2)
end

-- A reachable branch target that is not an instruction boundary is malformed
-- data with source provenance, never an index guess.
function T.malformed_reachable_branch_target_is_rejected_with_provenance()
  local bytes, layout = SseqFixture.build({
    { op = "wait", duration = 1 },
    { op = "jump", target = 0 },
    { op = "fin" },
  })
  local corrupted = SseqFixture.patchU24(bytes, layout.offsets[2] + 1, #bytes)
  local err = lowerRejects(corrupted, "AUDIO_SEQUENCE_BAD_TARGET")
  Assert.equal(err.context.sequenceId, 0)
  Assert.equal(err.context.sequenceSymbol, "SEQ_FIXTURE")
  Assert.notNil(err.context.sourceOffset)
  Assert.notNil(err.context.target)
  Assert.notNil(err.context.encodedTarget)
end

-- CALL shares its three-entry continuation stack with loop_begin: a call
-- made at saturation falls through as a nop without decoding its target, so
-- malformed bytes at that target cannot fail the build.
function T.saturated_call_keeps_fallthrough_without_decoding_its_target()
  local bytes = SseqFixture.build({
    { op = "u8", command = 0xD4, amount = 1 },
    { op = "u8", command = 0xD4, amount = 1 },
    { op = "u8", command = 0xD4, amount = 1 },
    { op = "call", target = { cmd = 6 } },
    { op = "fin" },
    { op = "raw", bytes = "\x60\x80" },
  })
  local program, err = SequenceLowering.lower(bytes, IDENTITY)
  Assert.notNil(program, "saturated call target stays undecoded: " .. tostring(err))
  program = assert(program)
  local names = {}
  for index, instruction in ipairs(program.instructions) do
    names[index] = instruction.op
  end
  Assert.deepEqual(names, { "loop_begin", "loop_begin", "loop_begin", "nop", "end" })
  Assert.isNil(program.instructions[4].target, "the saturated call carries no target")
end

-- Bytes outside the reachable program are never decoded: trailing garbage
-- after the final end cannot fail the build and never appears in the
-- program.
function T.malformed_unreachable_bytes_are_never_decoded()
  local bytes = SseqFixture.build({
    { op = "fin" },
  })
  local program, err = SequenceLowering.lower(bytes .. "\x60\x80", IDENTITY)
  Assert.notNil(program, "unreachable bytes stay undecoded: " .. tostring(err))
  program = assert(program)
  Assert.equal(#program.instructions, 1)
  Assert.equal(program.instructions[1].op, "end")
end

return { tests = T }
