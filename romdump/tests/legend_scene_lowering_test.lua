-- The legendary-story scene commands retain their source operand widths and
-- lower to the closed semantic operations the field's scene owner drives.
-- Source reference: the retail ROM.

local Assert = require("tests.support.Assert")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
local ScriptCommands = require("romdump.src.catalog.hgss.script_commands")
local ScriptFixture = require("tests.support.ScriptFixture")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local T = {}

local function sourceVar(id)
  return { value = "var", id = id }
end

local function decodeAndLower(instructions)
  local bytes = ScriptFixture.member({
    scripts = {
      { offset = 0x20, instructions = instructions },
    },
  })
  local member = assert(ScriptBinaryDecoder.parseMember(bytes, 0x19F, "legend-scene-fixture", {}))
  local script = assert(member.scripts[0])
  local lowered = SemanticLowering.lowerScript(script, member, { stdCatalog = SourceCatalog.catalog() })
  return lowered
end

local function unsupportedSteps(lowered)
  local found = {}
  for _, step in ipairs(lowered.items) do
    if step.op == "unsupported" then
      found[#found + 1] = step
    end
  end
  return found
end

function T.the_wing_command_reads_its_kind_through_the_variable_form()
  local lowered = decodeAndLower({
    { op = 774, args = { { value = 0x8004, width = 2 } } },
    { op = 2, args = {} },
  })
  Assert.equal(#unsupportedSteps(lowered), 0, "the wing effect has a semantic lowering")
  Assert.equal(lowered.items[1].op, "legend_wing")
  Assert.deepEqual(lowered.items[1].kind, sourceVar(0x8004), "the source kind stays a value reference")
end

function T.the_departure_names_both_source_objects()
  local lowered = decodeAndLower({
    { op = 775, args = { { value = 8, width = 2 }, { value = 10, width = 2 } } },
    { op = 2, args = {} },
  })
  Assert.equal(lowered.items[1].op, "lance_departure")
  Assert.equal(lowered.items[1].first, 8, "a literal first object id stays a literal")
  Assert.equal(lowered.items[1].second, 10, "a literal second object id stays a literal")
end

function T.the_cinematic_reads_one_raw_scene_halfword_and_the_sinjoh_commands_bind_their_operands()
  local lowered = decodeAndLower({
    { op = 773, args = { { value = 2, width = 2 } } },
    { op = 816, args = {} },
    { op = 817, args = { { value = 2, width = 1 } } },
    { op = 818, args = {} },
    { op = 819, args = {} },
    { op = 820, args = { { value = 3, width = 1 } } },
    { op = 2, args = {} },
  })
  Assert.equal(#unsupportedSteps(lowered), 0, "every Sinjoh scene command has a semantic lowering")
  Assert.equal(lowered.items[1].op, "legend_cinematic")
  Assert.equal(lowered.items[1].destination, 2, "the cinematic scene number is a raw source halfword")
  Assert.equal(lowered.items[2].op, "sinjoh_unown_circle")
  Assert.equal(lowered.items[3].op, "sinjoh_egg_cutscene")
  Assert.equal(lowered.items[3].choice, 2, "the egg cutscene reads its raw variant byte")
  Assert.equal(lowered.items[4].op, "gym_init")
  Assert.equal(lowered.items[4].kind, "sinjoh", "the stage init installs the closed Sinjoh union kind")
  Assert.equal(lowered.items[5].op, "gym_sinjoh_freeze")
  Assert.equal(lowered.items[6].op, "gym_sinjoh_choose")
  Assert.equal(lowered.items[6].choice, 3, "the chosen legend keeps its raw pedestal byte")
end

function T.the_catalog_declares_each_scene_command_with_its_source_timing()
  local expected = {
    [773] = { "yield_to_task", { 2 } },
    [774] = { "native_wait", { 2 } },
    [775] = { "native_wait", { 2, 2 } },
    [816] = { "native_wait", {} },
    [817] = { "native_wait", { 1 } },
    [818] = { "continue_same_tick", {} },
    [819] = { "continue_same_tick", {} },
    [820] = { "native_wait", { 1 } },
  }
  for opcode, spec in pairs(expected) do
    local entry = assert(ScriptCommands.byOpcode[opcode])
    Assert.equal(entry.disposition, "supported", "opcode " .. opcode .. " executes")
    Assert.equal(entry.classification, spec[1], "opcode " .. opcode .. " keeps its source timing")
    Assert.deepEqual(entry.widths, spec[2], "opcode " .. opcode .. " keeps its operand widths")
  end
end

return { metadata = {}, tests = T }
