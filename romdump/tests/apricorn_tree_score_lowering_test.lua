-- Apricorn harvest score lowering follows the pinned HGSS command source.

local Assert = require("tests.support.Assert")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
local ScriptFixture = require("tests.support.ScriptFixture")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local T = {}

local function lowerScoreEvent(event)
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 515, args = { { value = event, width = 2 } } },
          { op = 2, args = {} },
        },
      },
    },
  })
  local member = assert(ScriptBinaryDecoder.parseMember(bytes, 0x123, "apricorn-score-fixture", {}))
  local script = assert(member.scripts[0])
  return SemanticLowering.lowerScript(script, member, { stdCatalog = SourceCatalog.catalog() })
end

function T.apricorn_harvest_score_event_is_explicitly_omitted_without_widening_support()
  local lowered = lowerScoreEvent(1)
  Assert.equal(lowered.items[1].op, "noop", "the known Apricorn harvest score event preserves command position")
  Assert.deepEqual(lowered.items[1].provenance.opcodes, { 515 }, "the no-op retains source attribution")

  local unsupported = lowerScoreEvent(2).items[1]
  Assert.equal(unsupported.op, "unsupported", "other special-stat operands remain unsupported")
  Assert.equal(unsupported.command, 515)
  Assert.deepEqual(unsupported.arguments, { 2 })
end

return { tests = T }
