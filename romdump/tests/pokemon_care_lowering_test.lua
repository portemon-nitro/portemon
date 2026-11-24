-- The Day Care command family keeps its source operand widths and lowers to the
-- care service operations: every selector and buffer index is a ScriptGetVar
-- read, every result/cost/growth/species/action operand is a ScriptGetVarPointer
-- output, and the party-selection pair reuses the shared party-screen nodes with
-- the care context. Source reference: the retail ROM (src/scrcmd_daycare.c and
-- src/scrcmd_c.c::ScrCmd_ChoosePartyMonForDayCare).

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
local ScriptCommands = require("romdump.src.catalog.hgss.script_commands")
local ScriptFixture = require("tests.support.ScriptFixture")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local T = {}

local function sourceVar(id)
  return { value = "var", id = id }
end

local function lower(instructions)
  local bytes = ScriptFixture.member({
    scripts = {
      { offset = 0x20, instructions = instructions },
    },
  })
  local member = assert(ScriptBinaryDecoder.parseMember(bytes, 0x19F, "care-fixture", {}))
  local script = assert(member.scripts[0])
  return SemanticLowering.lowerScript(script, member, { stdCatalog = SourceCatalog.catalog() })
end

local function lowerOne(opcode, args)
  local lowered = lower({ { op = opcode, args = args or {} }, { op = 2, args = {} } })
  return lowered.items[1]
end

function T.care_queries_lower_to_their_source_operands()
  Assert.deepEqual(lowerOne(312), { op = "daycare_mon_nicknames", provenance = lowerOne(312).provenance })
  local state = lowerOne(313, { { value = 0x8004, width = 2 } })
  Assert.equal(state.op, "daycare_state")
  Assert.deepEqual(state.result, sourceVar(0x8004), "the state result stays a variable reference")
  local tail = lowerOne(372, { { value = 0x8001, width = 2 } })
  Assert.equal(tail.op, "daycare_tail_mon")
  Assert.deepEqual(tail.result, sourceVar(0x8001))
  local count = lowerOne(358, { { value = 0x8002, width = 2 } })
  Assert.equal(count.op, "count_alive_mons_and_pc")
  Assert.deepEqual(count.result, sourceVar(0x8002), "the combined party and PC count writes its output")
end

function T.withdraw_cost_and_growth_read_the_slot_after_the_output()
  local cost = lowerOne(367, { { value = 0x8004, width = 2 }, { value = 0x8001, width = 2 } })
  Assert.equal(cost.op, "daycare_withdraw_cost")
  Assert.deepEqual(cost.result, sourceVar(0x8004), "the cost output is the first operand")
  Assert.deepEqual(cost.slot, sourceVar(0x8001), "the Day Care slot is the second operand")
  local growth = lowerOne(371, { { value = 0x8004, width = 2 }, { value = 0x8001, width = 2 } })
  Assert.equal(growth.op, "daycare_growth")
  Assert.deepEqual(growth.result, sourceVar(0x8004))
  Assert.deepEqual(growth.slot, sourceVar(0x8001))
  local retrieve = lowerOne(361, { { value = 0x8002, width = 2 }, { value = 0x8001, width = 2 } })
  Assert.equal(retrieve.op, "daycare_retrieve_mon")
  Assert.deepEqual(retrieve.result, sourceVar(0x8002), "the species output is the first operand")
  Assert.deepEqual(retrieve.slot, sourceVar(0x8001))
end

function T.deposit_buffers_and_sanitize_keep_their_operand_order()
  local deposit = lowerOne(373, { { value = 0x8000, width = 2 } })
  Assert.equal(deposit.op, "daycare_deposit")
  Assert.deepEqual(deposit.slot, sourceVar(0x8000))
  local stats = lowerOne(385, {
    { value = 0x8000, width = 2 },
    { value = 0x8001, width = 2 },
    { value = 0x8002, width = 2 },
    { value = 0x8003, width = 2 },
  })
  Assert.equal(stats.op, "daycare_mon_stats")
  Assert.deepEqual(stats.nicknameBuffer, sourceVar(0x8000))
  Assert.deepEqual(stats.levelBuffer, sourceVar(0x8001))
  Assert.deepEqual(stats.genderBuffer, sourceVar(0x8002))
  Assert.deepEqual(stats.slot, sourceVar(0x8003), "the buffer indices precede the Day Care slot")
  local sanitize = lowerOne(690, { { value = 0x8000, width = 2 }, { value = 0x8004, width = 2 } })
  Assert.equal(sanitize.op, "daycare_sanitize_mon")
  Assert.deepEqual(sanitize.slot, sourceVar(0x8000))
  Assert.deepEqual(sanitize.result, sourceVar(0x8004), "the native result lands in the output variable")
  Assert.equal(lowerOne(715).op, "daycare_update_objects", "the yard update carries no operands")
end

function T.party_selection_pair_uses_the_care_context_and_reads_both_outputs()
  local choose = lowerOne(551, { { value = 0x8004, width = 2 } })
  Assert.equal(choose.op, "party_select")
  Assert.equal(choose.policy, "daycare_store", "the care context names its own selection policy")
  Assert.deepEqual(choose.initialSlot, sourceVar(0x8004), "the source initial slot rides the launch")
  local result = lowerOne(552, { { value = 0x8000, width = 2 }, { value = 0x8004, width = 2 } })
  Assert.equal(result.op, "party_select_result")
  Assert.deepEqual(result.result, sourceVar(0x8000), "the completed slot is the first output")
  Assert.deepEqual(result.action, sourceVar(0x8004), "the source action is the second output")
end

function T.every_care_command_declares_its_supported_source_timing()
  local cases = {
    [312] = { classification = "continue_same_tick", widths = {} },
    [313] = { classification = "continue_same_tick", widths = { 2 } },
    [358] = { classification = "continue_same_tick", widths = { 2 } },
    [361] = { classification = "continue_same_tick", widths = { 2, 2 } },
    [365] = { classification = "continue_same_tick", widths = {} },
    [366] = { classification = "continue_same_tick", widths = {} },
    [367] = { classification = "continue_same_tick", widths = { 2, 2 } },
    [371] = { classification = "continue_same_tick", widths = { 2, 2 } },
    [372] = { classification = "continue_same_tick", widths = { 2 } },
    [373] = { classification = "continue_same_tick", widths = { 2 } },
    [385] = { classification = "continue_same_tick", widths = { 2, 2, 2, 2 } },
    [387] = { classification = "continue_same_tick", widths = { 2 } },
    [388] = { classification = "continue_same_tick", widths = { 2 } },
    [551] = { classification = "native_wait", widths = { 2 } },
    [552] = { classification = "continue_same_tick", widths = { 2, 2 } },
    [690] = { classification = "continue_same_tick", widths = { 2, 2 } },
    [715] = { classification = "continue_same_tick", widths = {} },
  }
  for opcode, expected in pairs(cases) do
    local entry = assert(ScriptCommands.byOpcode[opcode], "the catalog names opcode " .. opcode)
    Assert.equal(entry.disposition, "supported", "opcode " .. opcode .. " executes")
    Assert.isNil(entry.deferredReason, "opcode " .. opcode .. " keeps no deferral category")
    Assert.equal(CommandCatalog.classification(opcode), expected.classification, "opcode " .. opcode .. " keeps source timing")
    Assert.deepEqual(entry.widths, expected.widths, "opcode " .. opcode .. " keeps its operand widths")
  end
end

function T.egg_commands_lower_to_their_source_operations()
  Assert.deepEqual(lowerOne(365), { op = "daycare_reset_egg", provenance = lowerOne(365).provenance })
  Assert.deepEqual(lowerOne(366), { op = "daycare_give_egg", provenance = lowerOne(366).provenance })
  local compatibility = lowerOne(387, { { value = 0x8004, width = 2 } })
  Assert.equal(compatibility.op, "daycare_compatibility")
  Assert.deepEqual(compatibility.result, sourceVar(0x8004), "the category lands in the output variable")
  local check = lowerOne(388, { { value = 0x8004, width = 2 } })
  Assert.equal(check.op, "daycare_check_egg")
  Assert.deepEqual(check.result, sourceVar(0x8004), "the pending answer lands in the output variable")
end

-- Commands whose owner has not landed stay explicit unsupported nodes.
function T.egg_production_commands_stay_deferred()
  for _, opcode in ipairs({ 369 }) do
    local entry = assert(ScriptCommands.byOpcode[opcode], "the catalog names opcode " .. opcode)
    Assert.equal(entry.disposition, "deferred", "opcode " .. opcode .. " waits for its owner")
    local step = lowerOne(opcode, { { value = 0x8004, width = 2 } })
    Assert.equal(step.op, "unsupported", "opcode " .. opcode .. " stays explicit")
    Assert.equal(step.command, opcode)
  end
end

return { tests = T }
