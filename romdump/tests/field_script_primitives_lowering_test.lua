local Assert = require("tests.support.Assert")
local FieldHandlers = require("romdump.src.digest.script.lowering.FieldHandlers")
local ScriptCommands = require("romdump.src.reference.hgss.script_commands")

local T = {}

local function raw(value)
  return { raw = value }
end

local function instruction(opcode, operands)
  return { opcode = opcode, offset = 12, operands = operands or {} }
end

function T.lifecycle_map_query_and_prop_commands_have_source_dispositions()
  local expected = {
    [150] = { "native_wait", "overworld_restore" },
    [307] = { "continue_same_tick", "prop_animation_load" },
    [308] = { "native_wait", "prop_animation_wait" },
    [309] = { "continue_same_tick", "prop_animation_unload" },
    [310] = { "continue_same_tick", "prop_animation_play" },
    [311] = { "continue_same_tick", "prop_animation_play" },
    [436] = { "native_wait", "overworld_leave" },
    [446] = { "continue_same_tick", "current_map_id" },
  }
  for opcode, result in pairs(expected) do
    Assert.equal(ScriptCommands.byOpcode[opcode].classification, result[1])
    local operands
    if opcode == 307 then
      operands = { raw(2), raw(1), raw(5), raw(9), raw(7) }
    elseif opcode == 308 or opcode == 309 or opcode == 310 or opcode == 311 or opcode == 446 then
      operands = { raw(4) }
    end
    local node = assert(FieldHandlers[opcode])(instruction(opcode, operands))
    Assert.equal(node.op, result[2])
    Assert.isNil(node.command, "source opcode must not leak into semantic operations")
    if opcode == 307 then
      Assert.deepEqual(node.fieldX, { value = "scaled_coordinate", coordinate = 5, chunkOffset = 2 })
      Assert.deepEqual(node.fieldZ, { value = "scaled_coordinate", coordinate = 9, chunkOffset = 1 })
      Assert.equal(node.slot, 7)
    elseif opcode == 310 then
      Assert.equal(node.direction, "forward")
    elseif opcode == 311 then
      Assert.equal(node.direction, "reverse")
    end
  end
end

return { tests = T }
