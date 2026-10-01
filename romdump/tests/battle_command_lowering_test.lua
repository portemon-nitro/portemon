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
    { instructions = { { opcode = opcode, operands = raw, offset = 0 } } },
    { member = 12, scripts = {}, movements = {} },
    { stdCatalog = SourceCatalog.catalog() }
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
  Assert.equal(
    CommandCatalog.classification(220),
    "continue_same_tick",
    "result reads answer in the same tick"
  )
end

function T.unknown_battle_opcodes_never_map_to_ordinary_launches()
  for _, opcode in ipairs({ 36, 168, 214, 217, 218, 219, 221, 225, 249, 279, 562, 683, 754 }) do
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
