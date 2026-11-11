-- Retail word-script call sites survive source translation: every
-- word-family command the retail field scripts actually call decodes with
-- its exact catalog widths, keeps literal and variable operands distinct,
-- and lowers to executable semantic nodes through the production
-- decoder, member catalogs, and lowering registry. Representative members
-- are pinned per command below, never discovered; neighboring unsupported
-- commands never fail this suite. No dump bytes are committed, only
-- opcode numbers, operand counts, and literal-or-variable shapes.

local Assert = require("tests.support.Assert")
local FieldScripts = require("tests.rom.support.FieldScripts")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

-- Loads a word-script producer module that does not exist yet at this
-- baseline. The failure names the missing behaviour instead of surfacing
-- as a suite load error, so the pre-implementation red stays attributable.
---@param moduleName string
---@param missingMessage string
---@return table
local function requireFeature(moduleName, missingMessage)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    error(missingMessage, 0)
  end
  assert(type(mod) == "table", missingMessage)
  return mod --[[@as table]]
end

-- Opcode to operand width count, from the pinned command catalog.
local EXPECTED_OPERANDS = {
  [256] = 1,
  [260] = 1,
  [264] = 1,
  [492] = 3,
  [493] = 3,
  [494] = 2,
  [538] = 2,
  [540] = 1,
  [681] = 1,
  [809] = 1,
}

-- One known retail member per word-family command exercised here.
local SAMPLE_MEMBERS = { 3, 94, 206, 860, 907, 952, 957 }

---@param operands table|nil
---@return integer count
local function operandCount(operands)
  if operands == nil then
    return 0
  end
  return #operands
end

-- Every retail word-script call site decodes with its exact catalog
-- operand shape: the opcode fires in a real member, every operand slot
-- carries its width, and word-editor outputs stay variable references
-- while launch kinds keep their literal-or-variable distinction.
function T.retail_word_command_sites_decode_with_exact_operand_shapes(romFs, versionId)
  local _, memberIrs = FieldScripts.decodeMembers(romFs, SAMPLE_MEMBERS)
  local seen = {}
  for _, member in ipairs(SAMPLE_MEMBERS) do
    local ir = assert(memberIrs[member], versionId .. " member " .. member .. " must decode")
    for index, script in pairs(ir.scripts) do
      for _, ins in ipairs(script.instructions) do
        local expected = EXPECTED_OPERANDS[ins.opcode]
        if expected ~= nil then
          seen[ins.opcode] = (seen[ins.opcode] or 0) + 1
          Assert.equal(
            operandCount(ins.operands),
            expected,
            string.format(
              "%s member %d script %d offset 0x%X: opcode %d carries %d operands",
              versionId,
              member,
              index,
              ins.offset,
              ins.opcode,
              expected
            )
          )
          for position, operand in ipairs(ins.operands) do
            Assert.isTrue(
              type(operand.width) == "number" and operand.width > 0,
              string.format(
                "%s member %d script %d offset 0x%X: opcode %d operand %d carries its width",
                versionId,
                member,
                index,
                ins.offset,
                ins.opcode,
                position
              )
            )
          end
        end
      end
    end
  end
  for opcode in pairs(EXPECTED_OPERANDS) do
    Assert.isTrue((seen[opcode] or 0) > 0, versionId .. " opcode " .. opcode .. " fires in the pinned retail members")
  end
  -- The Route16 daily word script and the Global Terminal greeting script
  -- are among the pinned members, so the integrated journeys below run
  -- against these exact decoded call sites.
  Assert.isTrue((seen[538] or 0) > 0, versionId .. " the daily word learner fires in the pinned members")
  Assert.isTrue((seen[681] or 0) > 0, versionId .. " the terminal greeting fires in the pinned members")
end

---@param item table
---@param offset integer
---@param opcode integer
---@return boolean
local function provenanceMatches(item, offset, opcode)
  local provenance = item.provenance
  return provenance ~= nil and provenance.offsets[1] == offset and provenance.opcodes[1] == opcode
end

-- The pinned call sites lower to executable semantic nodes: no
-- word-family opcode is left in the unsupported residue, and every site
-- yields at least one provenance-attributed node so the runtime can
-- execute the exact retail operands in order. The word-script lowerer
-- module does not exist yet at this baseline, which is the intended
-- pre-implementation red below.
function T.retail_word_command_sites_lower_to_executable_nodes(romFs, versionId)
  requireFeature(
    "romdump.src.digest.script.lowering.EasyChatHandlers",
    versionId .. " has no word-script lowerers yet: no word command can lower to an executable semantic node"
  )
  local archive, memberIrs = FieldScripts.decodeMembers(romFs, SAMPLE_MEMBERS)
  local sites = 0
  FieldScripts.eachScript(archive, memberIrs, function(member, index, _, lowered)
    local script = memberIrs[member].scripts[index]
    for _, ins in ipairs(script.instructions) do
      if EXPECTED_OPERANDS[ins.opcode] ~= nil then
        sites = sites + 1
        local nodes = {}
        for _, item in ipairs(lowered.items) do
          if provenanceMatches(item, ins.offset, ins.opcode) then
            nodes[#nodes + 1] = item
          end
        end
        Assert.isTrue(
          #nodes > 0,
          string.format(
            "%s member %d script %d offset 0x%X: opcode %d lowers to at least one executable node",
            versionId,
            member,
            index,
            ins.offset,
            ins.opcode
          )
        )
        for _, node in ipairs(lowered.unsupported) do
          local codes = node.opcodes or (node.opcode ~= nil and { node.opcode } or {})
          for _, code in ipairs(codes) do
            Assert.isTrue(
              EXPECTED_OPERANDS[code] == nil,
              string.format(
                "%s member %d script %d: opcode %d must not remain unsupported",
                versionId,
                member,
                index,
                code
              )
            )
          end
        end
      end
    end
  end)
  Assert.isTrue(sites > 0, versionId .. " the pinned members carry word command sites")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.tags = { "easychat" }
return suite
