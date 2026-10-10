-- Retail PC commands retain their reads, writes, and wait boundaries through lowering.
-- Source: pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36,
-- src/scrcmd_c.c and files/fielddata/script/scr_seq/scr_seq_0003.s.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local ScriptCommands = require("romdump.src.reference.hgss.script_commands")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")
local Verifier = require("romdump.src.digest.script.Verifier")

local T = {}

local function command(opcode, operands)
  local widths = assert(CommandCatalog.widths(opcode))
  local decodedOperands = {}
  for index, width in ipairs(widths) do
    decodedOperands[index] = { raw = operands[index], width = width }
  end
  return { opcode = opcode, operands = decodedOperands, offset = opcode * 4 }
end

local function lower(commands)
  local script = { instructions = commands }
  local member = { member = 3, scripts = {}, movements = {} }
  local lowered = SemanticLowering.lowerScript(script, member, { stdCatalog = SourceCatalog.catalog() })
  return script, member, lowered
end

function T.retail_pc_widths_and_execution_dispositions_are_catalogued()
  local expected = {
    [150] = { {}, "continue_same_tick" },
    [156] = { {}, "continue_same_tick" },
    [158] = { { 1 }, "native_wait" },
    [164] = { {}, "native_wait" },
    [308] = { { 1 }, "native_wait" },
    [309] = { { 1 }, "continue_same_tick" },
    [376] = { {}, "native_wait" },
    [377] = { { 2 }, "continue_same_tick" },
    [500] = { { 1 }, "continue_same_tick" },
    [501] = { { 1 }, "continue_same_tick" },
    [502] = { { 1 }, "continue_same_tick" },
    [616] = { { 2 }, "continue_same_tick" },
    [617] = { {}, "native_wait" },
    [706] = { { 2 }, "continue_same_tick" },
  }
  for opcode, shape in pairs(expected) do
    local entry = assert(ScriptCommands.byOpcode[opcode])
    Assert.deepEqual(entry.widths, shape[1], "opcode " .. opcode .. " consumes its source operands")
    Assert.equal(entry.classification, shape[2], "opcode " .. opcode .. " retains its source timing")
    Assert.equal(entry.feature, "pc", "opcode " .. opcode .. " belongs to the PC source feature")
    Assert.equal(entry.disposition, "supported", "opcode " .. opcode .. " has a closed semantic lowering")
  end
end

function T.pc_opcodes_lower_to_closed_semantics_and_verify_source_operands()
  local commands = {
    command(158, { 4 }),
    command(376, {}),
    command(617, {}),
    command(377, { 0x8001 }),
    command(616, { 0x8002 }),
    command(706, { 0x8003 }),
    command(156, {}),
    command(500, { 90 }),
    command(501, { 90 }),
    command(502, { 90 }),
    command(308, { 90 }),
    command(309, { 90 }),
    { opcode = 2, operands = {}, offset = 0x4000 },
  }
  local script, member, lowered = lower(commands)
  local items = lowered.items
  Assert.deepEqual({ items[1].op, items[1].app, items[1].mode }, { "pc_open", "storage", 4 })
  Assert.deepEqual({ items[2].op, items[2].app, items[2].mode }, { "pc_open", "mailbox", nil })
  Assert.deepEqual({ items[3].op, items[3].app, items[3].mode }, { "pc_open", "photoAlbum", nil })
  Assert.deepEqual(
    { items[4].op, items[4].kind, items[4].result },
    { "pc_count", "mailbox", { value = "var", id = 0x8001 } }
  )
  Assert.deepEqual(
    { items[5].op, items[5].kind, items[5].result },
    { "pc_count", "photos", { value = "var", id = 0x8002 } }
  )
  Assert.deepEqual({ items[6].op, items[6].result }, { "pc_hof_status", { value = "var", id = 0x8003 } })
  Assert.equal(items[7].op, "pc_capsules")
  for index, action in ipairs({ "start", "on", "off", "wait", "release" }) do
    local item = items[index + 7]
    Assert.deepEqual({ item.op, item.action, item.prop }, { "pc_terminal_effect", action, "pc_terminal" })
  end
  Assert.equal(items[13].op, "stop")
  local report = Verifier.verifyScript(items, script, member, lowered.omissions)
  Assert.isTrue(report.ok, "the verifier accepts every translated operand and timing boundary")
end

function T.wait_and_release_on_a_non_terminal_slot_are_prop_animation_operations()
  local script, member, lowered = lower({
    command(307, { 0, 0, 4, 11, 77 }),
    command(310, { 77 }),
    command(308, { 77 }),
    command(311, { 77 }),
    command(309, { 77 }),
    { opcode = 2, operands = {}, offset = 0x4000 },
  })
  local items = lowered.items
  Assert.equal(items[3].op, "prop_animation_wait")
  Assert.equal(items[3].slot, 77)
  Assert.equal(items[5].op, "prop_animation_unload")
  Assert.equal(items[5].slot, 77)
  local report = Verifier.verifyScript(items, script, member, lowered.omissions)
  Assert.isTrue(report.ok, "the verifier accepts map-prop wait and release on a script-loaded slot")
end

function T.restore_overworld_is_an_explicit_source_return_boundary()
  local script, member, lowered = lower({ command(150, {}), { opcode = 2, operands = {}, offset = 0x4000 } })
  Assert.equal(lowered.items[1].op, "restore_overworld")
  Assert.isTrue(Verifier.verifyScript(lowered.items, script, member, lowered.omissions).ok)
end

function T.pc_terminal_selector_mismatch_is_rejected_by_source_verification()
  local script, member, lowered = lower({ command(500, { 89 }), { opcode = 2, operands = {}, offset = 0x4000 } })
  local report = Verifier.verifyScript(lowered.items, script, member, lowered.omissions)
  Assert.isFalse(report.ok, "a different source model selector cannot be translated as the PC terminal")
end

return { tests = T }
