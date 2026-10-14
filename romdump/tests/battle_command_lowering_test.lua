-- Lowering coverage for the battle script contract: the ordinary trainer
-- and wild launches lower to real blocking battle_launch operations with
-- their pinned operand layout, the won check lowers to the same-tick
-- battle_result read, and every other battle-related opcode stays an
-- explicit unsupported node naming its owning application instead of
-- mapping to an ordinary battle or a success.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
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
    { index = 7, instructions = { { opcode = opcode, operands = raw, offset = 0 } } },
    { member = (opcode == 36 or opcode == 217) and 953 or 12, scripts = {}, movements = {} },
    { scriptIndex = 7, stdCatalog = SourceCatalog.catalog() }
  )
  Assert.equal(#lowered.items, 1, "opcode " .. opcode .. " lowers to one step")
  return lowered.items[1]
end

function T.trainer_battle_lowers_to_a_blocking_launch()
  local launch = lowerSingle(213, { 7, 3, 1, 0 })
  Assert.equal(launch.op, "battle_launch")
  Assert.equal(launch.kind, "trainer")
  Assert.equal(launch.details.trainer, 7, "the leading identity rides its operand")
  Assert.equal(launch.details.encounter, 3)
  Assert.equal(#launch.details.args, 2, "trailing operands survive opaquely")
  Assert.equal(CommandCatalog.disposition(213), "supported")
  Assert.equal(CommandCatalog.classification(213), "native_wait", "launches block like the source")
end

function T.trainer_variables_lower_to_references()
  local launch = lowerSingle(213, { 0x4007, 0x800C, 1, 0 })
  Assert.equal(launch.details.trainer.value, "var", "variable operands keep their reference")
  Assert.equal(launch.details.encounter.value, "var")
end

function T.wild_battle_lowers_to_a_blocking_launch()
  local launch = lowerSingle(589, { 25, 5, 0 })
  Assert.equal(launch.op, "battle_launch")
  Assert.equal(launch.kind, "wild")
  Assert.equal(launch.details.species, 25)
  Assert.equal(launch.details.level, 5)
  Assert.equal(CommandCatalog.disposition(589), "supported")
  Assert.equal(CommandCatalog.classification(589), "native_wait", "launches block like the source")
end

function T.battle_won_check_lowers_to_a_result_read()
  local read = lowerSingle(220, { 0x800D })
  Assert.equal(read.op, "battle_result")
  Assert.equal(read.result.value, "var", "the result variable rides the read")
  Assert.equal(CommandCatalog.disposition(220), "supported")
  Assert.equal(CommandCatalog.classification(220), "continue_same_tick", "result reads answer in the same tick")
end

function T.trainer_flag_check_folds_with_the_source_branch()
  local lowered = SemanticLowering.lowerScript({
    instructions = {
      { opcode = 38, operands = { "VAR_SPECIAL_x8004" }, offset = 20 },
      { opcode = 28, operands = { 1, "_defeated" }, offset = 24 },
      { opcode = 2, operands = {}, offset = 30, label = "_defeated" },
    },
  }, { member = 953, scripts = {}, movements = {} }, { stdCatalog = SourceCatalog.catalog() })
  Assert.equal(#lowered.items, 3)
  Assert.equal(lowered.items[1].op, "if_cond")
  Assert.equal(lowered.items[2].op, "label")
  Assert.equal(lowered.items[3].op, "stop")
  Assert.deepEqual(lowered.items[1].condition, {
    condition = "trainer_defeated",
    trainer = { value = "var", id = "VAR_SPECIAL_x8004" },
    expected = true,
  })
  Assert.deepEqual(lowered.items[1].provenance.opcodes, { 38, 28 })
end

function T.trainer_flag_write_uses_the_native_trainer_history_owner()
  local variable = lowerSingle(36, { "VAR_TEMP_x4012" })
  Assert.equal(variable.op, "set_trainer_flag")
  Assert.deepEqual(variable.trainer, { value = "var", id = "VAR_TEMP_x4012" })
  local literal = lowerSingle(36, { 8 })
  Assert.equal(literal.op, "set_trainer_flag")
  Assert.equal(literal.trainer, 8)
  Assert.equal(CommandCatalog.disposition(36), "supported")
  Assert.equal(CommandCatalog.classification(36), "continue_same_tick")
end

function T.trainer_double_battle_query_reads_the_native_trainer_id()
  local lowered = SemanticLowering.lowerScript(
    { index = 7, instructions = { { opcode = 217, operands = { "VAR_SPECIAL_RESULT" }, offset = 0 } } },
    { member = 953, scripts = {}, movements = {} },
    { scriptIndex = 7, stdCatalog = SourceCatalog.catalog() }
  )
  local read = lowered.items[1]
  Assert.equal(read.op, "set_var")
  Assert.deepEqual(read.variable, { value = "var", id = "VAR_SPECIAL_RESULT" })
  Assert.deepEqual(read.value, { value = "trainer_double_battle", trainer = 8 })
end

function T.trainer_message_parameters_lower_to_three_typed_variable_writes()
  local lowered = SemanticLowering.lowerScript({
    index = 7,
    instructions = { { opcode = 215, operands = { 0x8001, 0x8002, 0x8003 }, offset = 12 } },
  }, { member = 953, scripts = {}, movements = {} }, { scriptIndex = 7, stdCatalog = SourceCatalog.catalog() })
  Assert.equal(#lowered.items, 3)
  Assert.equal(CommandCatalog.disposition(215), "supported")
  Assert.equal(CommandCatalog.classification(215), "continue_same_tick")
  Assert.deepEqual(lowered.items[1].value, { value = "trainer_message_param", trainer = 8, partner = false, selector = 1 })
  Assert.deepEqual(lowered.items[2].value, { value = "trainer_message_param", trainer = 8, partner = false, selector = 2 })
  Assert.deepEqual(lowered.items[3].value, { value = "trainer_message_param", trainer = 8, partner = false, selector = 3 })
end

function T.trainer_message_parameters_decode_the_second_partner_identity()
  local lowered = SemanticLowering.lowerScript({
    index = 2007,
    instructions = { { opcode = 215, operands = { 0x8001, 0x8002, 0x8003 }, offset = 12 } },
  }, { member = 953, scripts = {}, movements = {} }, { scriptIndex = 2007, stdCatalog = SourceCatalog.catalog() })
  Assert.equal(lowered.items[1].value.trainer, 8)
  Assert.equal(lowered.items[1].value.partner, true)
end

function T.rematch_message_parameters_lower_to_source_specific_writes()
  local lowered = SemanticLowering.lowerScript({
    index = 7,
    instructions = { { opcode = 216, operands = { 0x8001, 0x8002, 0x8003 }, offset = 12 } },
  }, { member = 953, scripts = {}, movements = {} }, { scriptIndex = 7, stdCatalog = SourceCatalog.catalog() })
  Assert.equal(#lowered.items, 3)
  Assert.equal(CommandCatalog.disposition(216), "supported")
  Assert.equal(CommandCatalog.classification(216), "continue_same_tick")
  Assert.deepEqual(lowered.items[1].value, { value = "trainer_rematch_message_param", trainer = 8, partner = false, selector = 1 })
  Assert.deepEqual(lowered.items[2].value, { value = "trainer_rematch_message_param", trainer = 8, partner = false, selector = 2 })
  Assert.deepEqual(lowered.items[3].value, { value = "trainer_rematch_message_param", trainer = 8, partner = false, selector = 3 })
end

function T.trainer_message_resolves_native_trainer_and_selector_variables()
  local message = lowerSingle(214, { 0x8007, 0x8008 })
  Assert.equal(message.op, "message")
  Assert.deepEqual(message.message, {
    message = "trainer",
    trainer = { value = "var", id = 0x8007 },
    selector = { value = "var", id = 0x8008 },
  })
  Assert.isTrue(message.waitForPrint)
  Assert.equal(CommandCatalog.disposition(214), "supported")
  Assert.equal(CommandCatalog.classification(214), "native_wait")
end

function T.trainer_reaction_queues_the_last_talked_actor_movement()
  local lowered = lowerSingle(454, {})
  Assert.equal(lowered.op, "trainer_reaction_movement")
  Assert.deepEqual(lowered.actor, { ref = "actor", special = "last_talked" })
  Assert.equal(CommandCatalog.disposition(454), "supported")
  Assert.equal(CommandCatalog.classification(454), "continue_same_tick")
end

function T.trainer_encounter_music_reads_the_native_trainer_variable_and_yields()
  local cue = lowerSingle(218, { 0x8007 })
  Assert.equal(cue.op, "trainer_encounter_music")
  Assert.deepEqual(cue.trainer, { value = "var", id = 0x8007 })
  Assert.equal(CommandCatalog.disposition(218), "supported")
  Assert.equal(CommandCatalog.classification(218), "native_wait")
end

function T.unknown_battle_opcodes_never_map_to_ordinary_launches()
  for _, opcode in ipairs({ 168, 221, 225, 249, 562, 683, 754 }) do
    local step = lowerSingle(opcode, {})
    Assert.equal(step.op, "unsupported", "opcode " .. opcode .. " must not lower to a battle")
    Assert.isTrue(
      (step.reason or ""):find("deferred", 1, true) ~= nil,
      "opcode " .. opcode .. " names its owning application"
    )
    Assert.equal(CommandCatalog.disposition(opcode), "deferred")
  end
end

return { tests = T }
