-- Source inventory audit for the dex script family: every in-scope
-- command carries membership in the independent source family table
-- and a supported disposition with its source timing and operand
-- widths in the authoritative catalog. Opaque numeric aliases resolve
-- to their pinned source names, the non-command table entry keeps its
-- independent identity, and the absent-parent picture-window and
-- Unown-circle commands stay out of the supported set.

local Assert = require("tests.support.Assert")
local MonScriptCommands = require("romdump.src.catalog.hgss.mon_script_commands")
local ScriptCommands = require("romdump.src.catalog.hgss.script_commands")

local T = {}

-- The seventeen in-scope source commands with their pinned source
-- names, family categories, timing, and operand widths.
local FAMILY = {
  [243] = {
    name = "ScrCmd_CountJohtoDexSeen",
    category = "pokedex",
    classification = "continue_same_tick",
    widths = { [1] = 2 },
  },
  [244] = {
    name = "ScrCmd_CountJohtoDexOwned",
    category = "pokedex",
    classification = "continue_same_tick",
    widths = { [1] = 2 },
  },
  [245] = {
    name = "ScrCmd_CountNationalDexSeen",
    category = "pokedex",
    classification = "continue_same_tick",
    widths = { [1] = 2 },
  },
  [246] = {
    name = "ScrCmd_CountNationalDexOwned",
    category = "pokedex",
    classification = "continue_same_tick",
    widths = { [1] = 2 },
  },
  [248] = {
    name = "ScrCmd_GetDexEvalResult",
    category = "pokedex",
    classification = "continue_same_tick",
    widths = { [1] = 1, [2] = 2, [3] = 2 },
  },
  [290] = {
    name = "ScrCmd_CheckPokedex",
    category = "pokedex",
    classification = "continue_same_tick",
    widths = { [1] = 2 },
  },
  [291] = { name = "ScrCmd_GivePokedex", category = "pokedex", classification = "continue_same_tick", widths = {} },
  [423] = {
    name = "ScrCmd_CheckJohtoDexComplete",
    category = "pokedex",
    classification = "continue_same_tick",
    widths = { [1] = 2 },
  },
  [424] = {
    name = "ScrCmd_CheckNationalDexComplete",
    category = "pokedex",
    classification = "continue_same_tick",
    widths = { [1] = 2 },
  },
  [476] = {
    name = "ScrCmd_EnablePokedexFormDetection",
    category = "pokedex",
    classification = "continue_same_tick",
    widths = {},
  },
  [477] = {
    name = "ScrCmd_NatDexFlagAction",
    category = "pokedex",
    classification = "continue_same_tick",
    widths = { [1] = 1, [2] = 2 },
  },
  [518] = { name = "ScrCmd_SetPartyDeoxysForm", category = "mon", classification = "native_wait", widths = { [1] = 2 } },
  [545] = {
    name = "ScrCmd_CountUnownLettersRegistered",
    category = "pokedex",
    classification = "continue_same_tick",
    widths = { [1] = 2 },
  },
  [675] = {
    name = "ScrCmd_UpdateRotomForm",
    category = "special_event",
    classification = "continue_same_tick",
    widths = { [1] = 2, [2] = 2, [3] = 2, [4] = 2 },
  },
  [687] = {
    name = "ScrCmd_SetMonSeenFlag",
    category = "mon",
    classification = "continue_same_tick",
    widths = { [1] = 2 },
  },
  [707] = {
    name = "ScrCmd_CheckMonSeen",
    category = "pokedex",
    classification = "continue_same_tick",
    widths = { [1] = 2, [2] = 2 },
  },
  [770] = {
    name = "ScrCmd_CheckSeenAllLetterUnown",
    category = "pokedex",
    classification = "native_wait",
    widths = { [1] = 2 },
  },
}

local function familyEntry(opcode)
  return MonScriptCommands.byOpcode[opcode]
end

function T.every_in_scope_command_has_independent_family_membership()
  for opcode, expected in pairs(FAMILY) do
    local entry = familyEntry(opcode)
    Assert.notNil(entry, "the independent inventory names opcode " .. opcode)
    assert(entry ~= nil, "the independent inventory names opcode " .. opcode)
    Assert.equal(entry.category, expected.category, "opcode " .. opcode .. " keeps its source family")
  end
end

function T.every_in_scope_command_is_supported_with_source_timing()
  for opcode, expected in pairs(FAMILY) do
    local tagged = assert(ScriptCommands.byOpcode[opcode], "the pinned catalog names opcode " .. opcode)
    Assert.equal(tagged.disposition, "supported", "opcode " .. opcode .. " is executable")
    Assert.equal(tagged.name, expected.name, "opcode " .. opcode .. " carries its pinned source name")
    Assert.equal(tagged.classification, expected.classification, "opcode " .. opcode .. " keeps its source timing")
    Assert.deepEqual(tagged.widths, expected.widths, "opcode " .. opcode .. " keeps its source operands")
    Assert.isNil(tagged.deferredReason, "opcode " .. opcode .. " is no longer deferred")
  end
end

function T.opaque_aliases_resolve_to_pinned_source_names()
  for _, opcode in ipairs({ 518, 545, 687 }) do
    local tagged = assert(ScriptCommands.byOpcode[opcode], "the pinned catalog names opcode " .. opcode)
    Assert.isTrue(
      tagged.name ~= "ScrCmd_" .. opcode,
      "opcode " .. opcode .. " no longer carries its opaque numeric alias"
    )
  end
  for _, opcode in ipairs({ 518, 687 }) do
    local entry = familyEntry(opcode)
    Assert.notNil(entry, "the independent inventory names opcode " .. opcode)
    assert(entry ~= nil, "the independent inventory names opcode " .. opcode)
    Assert.isTrue(
      entry.sourceMeaning ~= "retail command " .. opcode,
      "opcode " .. opcode .. " no longer carries its opaque family meaning"
    )
  end
end

function T.non_command_table_entry_keeps_its_independent_identity()
  local tagged = assert(ScriptCommands.byOpcode[149], "the pinned catalog names entry 149")
  Assert.equal(tagged.name, "UnsetPhoneCallTrigger", "entry 149 keeps its non-command identity")
  Assert.equal(tagged.disposition, "supported", "entry 149 stays supported on its own terms")
end

function T.absent_parent_commands_stay_out_of_the_supported_set()
  for _, opcode in ipairs({ 452, 816 }) do
    local tagged = assert(ScriptCommands.byOpcode[opcode], "the pinned catalog names opcode " .. opcode)
    Assert.isTrue(
      tagged.disposition ~= "supported",
      "opcode " .. opcode .. " stays unavailable until its parent application exists"
    )
  end
end

return { tests = T }
