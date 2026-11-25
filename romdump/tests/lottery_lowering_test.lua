-- The lottery command family keeps its source operand widths and lowers to
-- semantic operations: LotoIDGet writes one result pointer, LotoIDSearch names
-- its three result pointers before reading its identity, LotoIDSet takes no
-- operand at all, BufferBoxMonNick reads a format-field byte and a boxed-mon
-- slot, and GetVar4041 writes one result pointer. Source reference: the retail
-- command table (src/data/fieldmap/script_cmd_table.h).

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
local ScriptCommands = require("romdump.src.catalog.hgss.script_commands")
local ScriptFixture = require("tests.support.ScriptFixture")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local T = {}

local LOTTERY_WIDTHS = {
  [503] = { 2 },
  [504] = { 2, 2, 2, 2 },
  [505] = {},
  [506] = { 1, 2 },
  [534] = { 2 },
}

---@param opcode integer
---@param operands integer[]
---@return table
local function command(opcode, operands)
  local args = {}
  for index, width in ipairs(assert(LOTTERY_WIDTHS[opcode])) do
    args[index] = { value = operands[index], width = width }
  end
  return { op = opcode, args = args }
end

---@param instructions table[]
---@return table lowered
local function decodeAndLower(instructions)
  local bytes = ScriptFixture.member({
    scripts = {
      { offset = 0x20, instructions = instructions },
    },
  })
  local member = assert(ScriptBinaryDecoder.parseMember(bytes, 0x123, "lottery-fixture", {}))
  local script = assert(member.scripts[0])
  return SemanticLowering.lowerScript(script, member, { stdCatalog = SourceCatalog.catalog() })
end

-- The catalog keeps every source width and marks each command same-tick; the
-- boxed-mon nickname buffer is a supported mon-family row rather than a
-- deferred one.
function T.lottery_commands_keep_their_source_widths_and_timing()
  for opcode, widths in pairs(LOTTERY_WIDTHS) do
    local entry = assert(ScriptCommands.byOpcode[opcode])
    Assert.deepEqual(entry.widths, widths, "opcode " .. opcode .. " keeps its source operands")
    Assert.equal(
      CommandCatalog.classification(opcode),
      CommandCatalog.CONTINUE,
      "opcode " .. opcode .. " settles in its own tick"
    )
    Assert.isTrue(CommandCatalog.SUPPORTED[opcode] == true, "opcode " .. opcode .. " is executable")
  end
  local nick = assert(ScriptCommands.byOpcode[506])
  Assert.equal(nick.feature, "mons", "the boxed-mon nickname buffer belongs to the mon family")
  Assert.equal(nick.disposition, "supported", "the boxed-mon nickname buffer is no longer deferred")
  Assert.isNil(nick.deferredReason, "a supported row carries no deferral category")
end

-- Every command decodes with its exact operand count and lowers to the named
-- semantic node, with the source pointers and value references preserved.
function T.lottery_commands_lower_to_their_source_operands()
  local lowered = decodeAndLower({
    command(503, { 0x8001 }),
    command(504, { 0x8002, 0x8003, 0x8004, 0x8005 }),
    command(505, {}),
    command(506, { 3, 0x8006 }),
    command(534, { 0x8007 }),
    { op = 2, args = {} },
  })
  Assert.equal(#lowered.unsupported, 0, "no lottery command stays unsupported")
  Assert.equal(#lowered.items, 6, "five lottery commands and the trailing source end lower")

  local get = lowered.items[1]
  Assert.equal(get.op, "loto_id_get", "LotoIDGet writes the saved identity")
  Assert.deepEqual(get.result, { value = "var", id = 0x8001 }, "the result pointer stays a variable reference")

  local search = lowered.items[2]
  Assert.equal(search.op, "loto_id_search", "LotoIDSearch writes the source triplet")
  Assert.deepEqual(search.position, { value = "var", id = 0x8002 }, "the slot pointer keeps its order")
  Assert.deepEqual(search.count, { value = "var", id = 0x8003 }, "the count pointer keeps its order")
  Assert.deepEqual(search.kind, { value = "var", id = 0x8004 }, "the kind pointer keeps its order")
  Assert.deepEqual(search.id, { value = "var", id = 0x8005 }, "the identity is read after the three pointers")

  Assert.equal(lowered.items[3].op, "loto_id_set", "LotoIDSet rolls the saved identity")

  local nick = lowered.items[4]
  Assert.equal(nick.op, "buffer_text", "the boxed-mon nickname buffers into a format field")
  Assert.equal(nick.slot, 3, "the format field is the raw source byte")
  Assert.deepEqual(
    nick.value,
    { text = "box_mon_nickname", boxSlot = { value = "var", id = 0x8006 } },
    "the boxed-mon slot is read through its variable"
  )

  local daily = lowered.items[5]
  Assert.equal(daily.op, "get_var_4041", "GetVar4041 writes the shared daily variable")
  Assert.deepEqual(daily.result, { value = "var", id = 0x8007 }, "the result pointer stays a variable reference")
end

return { tests = T }
