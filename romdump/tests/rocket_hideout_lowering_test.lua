-- Lowering coverage for the Rocket hideout's own script commands and the
-- follower inhibit write: each command keeps its source operand class (a
-- ScriptGetVar value or a raw byte), its own-tick or blocking return, and its
-- typed semantic node. Nothing here names a source opcode at runtime.

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
    { member = 89, scripts = {}, movements = {} },
    { stdCatalog = SourceCatalog.catalog() }
  )
  Assert.equal(#lowered.items, 1, "opcode " .. opcode .. " lowers to one step")
  return lowered.items[1]
end

function T.the_trap_effect_reads_its_kind_through_a_value_reference()
  local trap = lowerSingle(708, { 1 })
  Assert.equal(trap.op, "rocket_trap_effect")
  Assert.equal(trap.kind, 1, "a literal species-free selector rides as its own value")
  Assert.equal(CommandCatalog.classification(708), "native_wait", "the trap effect blocks the script")

  local read = lowerSingle(708, { 0x4007 })
  Assert.equal(read.kind.value, "var", "a variable selector stays a reference the runtime evaluates")
  Assert.equal(read.kind.id, 0x4007)
end

function T.the_alarm_and_the_powered_prop_projection_carry_no_operands()
  local alarm = lowerSingle(709, {})
  Assert.equal(alarm.op, "rocket_alarm")
  Assert.equal(CommandCatalog.classification(709), "native_wait", "the alarm blocks the script")

  local power = lowerSingle(710, {})
  Assert.equal(power.op, "rocket_power_props")
  Assert.equal(CommandCatalog.classification(710), "continue_same_tick", "the projection settles in its own tick")
end

function T.the_map_event_key_is_a_key_reference_with_a_raw_action_byte()
  local write = lowerSingle(530, { 2, 1 })
  Assert.equal(write.op, "map_event_key")
  Assert.equal(write.slot, 2, "the key slot rides ScriptGetVar")
  Assert.equal(write.action, 1, "the action is a raw source byte")
  Assert.equal(CommandCatalog.classification(530), "continue_same_tick")

  local clear = lowerSingle(530, { 0, 0 })
  Assert.equal(clear.slot, 0)
  Assert.equal(clear.action, 0)
end

function T.the_costume_commands_keep_the_flag_and_their_operand_classes()
  local check = lowerSingle(619, { 0x800D })
  Assert.equal(check.op, "rocket_costume_check")
  Assert.equal(check.flag, "FLAG_SYS_ROCKET_COSTUME", "the source flag travels as its own symbol")
  Assert.equal(check.result.value, "var", "the check writes its output variable")
  Assert.equal(CommandCatalog.classification(619), "continue_same_tick")

  local set = lowerSingle(620, { 1 })
  Assert.equal(set.op, "rocket_costume_action")
  Assert.equal(set.mode, 1, "a set action is a raw selector byte")
  local clear = lowerSingle(620, { 0 })
  Assert.equal(clear.mode, 0, "a clear action is the zero selector")
  Assert.equal(CommandCatalog.classification(620), "continue_same_tick")
end

function T.the_follower_inhibit_write_reads_one_raw_byte()
  local inhibit = lowerSingle(783, { 1 })
  Assert.equal(inhibit.op, "follower_set_inhibited")
  Assert.equal(inhibit.inhibited, 1, "the source selector is a raw byte")
  Assert.equal(CommandCatalog.classification(783), "continue_same_tick")
  Assert.equal(CommandCatalog.disposition(783), "supported")
end

return { tests = T }
