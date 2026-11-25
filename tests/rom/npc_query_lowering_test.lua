-- ROM-gated specialty-NPC lowering coverage: the real retail scripts pin the
-- operand order and the pointer/value/byte distinctions of the size record, the
-- ribbon reads and names, the effort-value total, the Kenya Mail checks, the
-- stat judge and the Hidden Power type. Only literal member data is decoded;
-- neighbouring unsupported commands are irrelevant here.

local Assert = require("tests.support.Assert")
local FieldScripts = require("tests.rom.support.FieldScripts")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

-- Explicit retail sites: the fishing-competition gatehouse (member 940), the
-- Route 29 size poster (938), the ribbon NPCs (225/246), the Trainer House
-- effort reader (947), the Kenya checks (230/241), the stat judge (69) and the
-- Hidden Power reader (804).
local SAMPLE_MEMBERS = { 69, 225, 230, 241, 246, 804, 938, 940, 947 }

local EXPECTED = {
  size_record_compare = { "result", "slot" },
  size_record_update = { "slot" },
  buffer_mon_size = { "wholeBuffer", "fractionBuffer", "slot" },
  buffer_record_size = { "wholeBuffer", "fractionBuffer", "species" },
  mon_has_ribbon = { "result", "slot", "ribbon" },
  buffer_ribbon_name = { "buffer", "ribbon" },
  ev_total = { "result", "slot" },
  kenya_check = { "result", "slot", "exact" },
  kenya_check_party = { "result" },
  stat_judge = { "slot", "total", "message", "highest" },
  buffer_stat_name = { "buffer", "stat" },
  hidden_power_type = { "slot", "result" },
}

T["retail specialty-NPC commands lower to their source operands"] = function(romFs)
  local archive, memberIrs = FieldScripts.decodeMembers(romFs, SAMPLE_MEMBERS)
  local seen = {}
  local unsupported = {}
  FieldScripts.eachScript(archive, memberIrs, function(member, index, _, lowered)
    for _, step in ipairs(lowered.items) do
      local expected = EXPECTED[step.op]
      if expected ~= nil then
        seen[step.op] = (seen[step.op] or 0) + 1
        for _, field in ipairs(expected) do
          Assert.isTrue(
            step[field] ~= nil,
            string.format("member %d script %d: %s carries %s", member, index, step.op, field)
          )
        end
        Assert.isNil(step.command, "source opcode must not leak into semantic operations")
      end
    end
    for _, node in ipairs(lowered.unsupported) do
      local opcode = node.command
      if type(opcode) == "number" then
        unsupported[opcode] = (unsupported[opcode] or 0) + 1
      end
    end
  end)
  for op in pairs(EXPECTED) do
    if op ~= "buffer_ribbon_name" and op ~= "buffer_stat_name" then
      Assert.isTrue(seen[op] ~= nil and seen[op] > 0, "the retail corpus lowers at least one " .. op .. " node")
    end
  end
  for _, opcode in ipairs({ 390, 391, 392, 393, 426, 480, 483, 657, 670, 781 }) do
    Assert.isNil(
      unsupported[opcode],
      "opcode " .. opcode .. " is no longer unsupported in the retail corpus"
    )
  end
end

return RomSuite.fromFacts(T)
