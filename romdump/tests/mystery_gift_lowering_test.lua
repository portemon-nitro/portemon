-- ScrCmd_MysteryGift (489) owns only its queue framing and the waiting-gift
-- query: this product distributes no Mystery Gifts, so BEGIN/END bracket an
-- absent queue and HAS_GIFT always answers false. The delivery variants still
-- need the distribution system and keep an explicit unsupported node, so the
-- source command is catalogued as partially executable.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
local ScriptFixture = require("tests.support.ScriptFixture")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local T = {}

local BEGIN_VARIANT, HAS_GIFT_VARIANT, RECEIVE_VARIANT, END_VARIANT = 0, 1, 4, 7

---@param instructions table[]
---@return table lowered script IR
local function lower(instructions)
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = instructions,
      },
    },
  })
  local member = assert(ScriptBinaryDecoder.parseMember(bytes, 0x123, "mystery-gift-fixture", {}))
  return SemanticLowering.lowerScript(assert(member.scripts[0]), member, { stdCatalog = SourceCatalog.catalog() })
end

local function giftInstruction(variant, extra)
  local args = { { value = variant, width = 2 } }
  for _, arg in ipairs(extra or {}) do
    args[#args + 1] = arg
  end
  return { op = 489, args = args }
end

function T.the_command_is_catalogued_as_partially_executable()
  Assert.equal(CommandCatalog.disposition(489), "partial", "the queue framing executes while delivery is unavailable")
  Assert.equal(CommandCatalog.classification(489), "continue_same_tick", "the queue commands consume no tick")
  Assert.equal(CommandCatalog.deferredReason(489), "mystery_gift", "the unimplemented part names its dependency")
  local note = CommandCatalog.deferredNote(489)
  Assert.isTrue(type(note) == "string" and note ~= "", "the deferral carries its source explanation")
end

function T.queue_framing_lowers_to_the_erasure_that_brackets_nothing()
  for _, variant in ipairs({ BEGIN_VARIANT, END_VARIANT }) do
    local lowered = lower({ giftInstruction(variant), { op = 2, args = {} } })
    local step = assert(lowered.items[1], "the queue framing lowers to one step")
    Assert.equal(step.op, "noop", "variant " .. variant .. " erases its absent queue bracket")
    Assert.deepEqual(step.provenance.opcodes, { 489 }, "the erasure retains its source attribution")
  end
end

function T.the_waiting_gift_query_writes_its_source_variable()
  local lowered = lower({
    giftInstruction(HAS_GIFT_VARIANT, { { value = 0x4000, width = 2 } }),
    { op = 2, args = {} },
  })
  local step = assert(lowered.items[1], "the waiting-gift query lowers to one step")
  Assert.equal(step.op, "mystery_gift_has_gift")
  Assert.deepEqual(step.result, { value = "var", id = 0x4000 }, "the query writes its source variable")
end

function T.delivery_variants_stay_explicitly_unsupported()
  local lowered = lower({ giftInstruction(RECEIVE_VARIANT), { op = 2, args = {} } })
  local step = assert(lowered.items[1], "the delivery command lowers to one step")
  Assert.equal(step.op, "unsupported")
  Assert.equal(step.command, 489)
  Assert.equal(step.originalName, "ScrCmd_MysteryGift")
  Assert.deepEqual(step.arguments, { RECEIVE_VARIANT })
  Assert.isTrue(
    tostring(step.reason):find("mystery_gift", 1, true) ~= nil,
    "the unsupported node names the distribution dependency"
  )
end

return { tests = T }
