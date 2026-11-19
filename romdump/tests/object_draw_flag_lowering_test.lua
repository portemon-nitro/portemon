-- MakeObjectVisible / MakeObjectInvisible lowering. Retail oracle
-- (src/scrcmd_c.c): ScrCmd_MakeObjectVisible clears the object's invisible
-- flag and ScrCmd_MakeObjectInvisible sets it.

local Assert = require("tests.support.Assert")
local FieldHandlers = require("romdump.src.digest.script.lowering.FieldHandlers")

local T = {}

local function lower(opcode)
  return assert(FieldHandlers[opcode], "handler must exist")({ opcode = opcode, offset = 0, operands = { { raw = 5 } } })
end

function T.make_object_visible_shows_the_object()
  local node = lower(374)
  Assert.equal(node.op, "set_object_hidden")
  Assert.isFalse(node.hidden)
end

function T.make_object_invisible_hides_the_object()
  local node = lower(375)
  Assert.equal(node.op, "set_object_hidden")
  Assert.isTrue(node.hidden)
end

return { tests = T }
