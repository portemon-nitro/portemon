-- MakeObjectVisible / MakeObjectInvisible lowering. Retail oracle: the object's
-- draw flag is named for its setter, so MakeObjectVisible sets the hidden bit
-- (the door transition's "MapObject_SetVisible(TRUE) sets the hidden flag")
-- and MakeObjectInvisible clears it.

local Assert = require("tests.support.Assert")
local FieldHandlers = require("romdump.src.digest.script.lowering.FieldHandlers")

local T = {}

local function lower(opcode)
  return assert(FieldHandlers[opcode], "handler must exist")({ opcode = opcode, offset = 0, operands = { { raw = 5 } } })
end

function T.make_object_visible_hides_the_object()
  local node = lower(375)
  Assert.equal(node.op, "set_object_hidden")
  Assert.isTrue(node.hidden)
end

function T.make_object_invisible_shows_the_object()
  local node = lower(374)
  Assert.equal(node.op, "set_object_hidden")
  Assert.isFalse(node.hidden)
end

return { tests = T }
