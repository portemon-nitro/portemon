-- Battle animation command decoding follows the pinned overlay interpreter.
-- Fixtures are synthetic u32 streams and exercise source cursor boundaries.

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

function T.dispatch_entries_name_pinned_handlers_and_reject_the_guard_overrun()
  local Sources = require("romdump.src.config.BattleAnimationSources")
  Assert.equal(Sources.handlerCount(), 88, "the table covers only its 88 actual entries")
  Assert.equal(Sources.handlerLabel(0), "ov07_0221C6EC", "opcode zero names its source handler")
  Assert.equal(Sources.handlerLabel(87), "ov07_0221D23C", "last opcode names its source handler")
  Assert.isNil(Sources.handlerLabel(88), "the permissive native guard does not extend the table")
end

function T.variable_width_callback_block_advances_to_the_following_instruction()
  local bytes = table.concat({
    u32(45), -- callback selector
    u32(1), -- selector
    u32(2), -- count
    u32(0x11111111),
    u32(0x22222222),
    u32(54), -- confirmed source no-op
  })
  local program = assert(compiler().compile({
    key = "synthetic-variable-block",
    stream = bytes,
    callbacks = { [1] = "test/callback" },
  }))
  Assert.equal(#program.instructions, 2, "counted words belong to one command")
  Assert.equal(program.instructions[1].op, "replace-parameters-and-call", "callback block carries observed semantics")
  Assert.deepEqual(program.instructions[1].values, { 0x11111111, 0x22222222 }, "counted words are decoded")
  Assert.equal(program.instructions[2].op, "noop", "cursor lands on the next opcode")
  Assert.isNil(program.instructions[2].nativeOpcode, "normalized instructions omit native dispatch IDs")
end

function T.truncated_counted_payload_and_opcode_88_fail_with_program_offset()
  local cases = {
    { key = "truncated-count", stream = u32(45) .. u32(1) },
    { key = "truncated-value", stream = u32(45) .. u32(0) .. u32(1) .. u32(2) },
    { key = "guard-overrun", stream = u32(88) },
  }
  for _, case in ipairs(cases) do
    local ok, err = pcall(compiler().compile, { key = case.key, stream = case.stream })
    Assert.isFalse(ok, case.key .. " must fail closed")
    Assert.isTrue(tostring(err):find(case.key, 1, true) ~= nil, case.key .. " reports program identity")
    Assert.isTrue(tostring(err):find("offset", 1, true) ~= nil, case.key .. " reports source offset")
  end
end

function T.noop_and_assertion_handlers_preserve_their_distinct_source_behavior()
  local noop = assert(compiler().compile({ key = "source-noop", stream = u32(54) }))
  Assert.equal(noop.instructions[1].op, "noop", "only the source-confirmed empty handler lowers as no-op")
  local assertion = assert(compiler().compile({ key = "source-assert", stream = u32(55) }))
  Assert.equal(assertion.instructions[1].op, "source-assertion")
  Assert.equal(assertion.instructions[1].target, 2, "a tripped assert service terminates past the stream end")
  Assert.equal(assertion.instructions[1].cursorRule, "invoke-assert-service; redispatch-current-word-if-it-returns")
  Assert.isFalse(assertion.instructions[1].op == noop.instructions[1].op, "assertion remains distinct from no-op")
end

function T.closure_traversal_closes_cycles_deterministically()
  local Compiler = compiler()
  local edges = {
    ["effect-a"] = { "effect-b", "shared-sound" },
    ["effect-b"] = { "effect-a", "shared-texture" },
    ["shared-sound"] = {},
    ["shared-texture"] = { "shared-sound" },
  }
  Assert.deepEqual(Compiler.traverseClosure({ "effect-a" }, edges), Compiler.traverseClosure({ "effect-a" }, edges))
  Assert.equal(#Compiler.traverseClosure({ "effect-a" }, edges), 4, "the cycle closes to four keys")
end

return { tests = T }
