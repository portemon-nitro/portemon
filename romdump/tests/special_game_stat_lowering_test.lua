-- ScrCmd_AddSpecialGameStat (515) lowering: the source operand is the
-- immediate special-stat event, and the translator emits the semantic
-- game-score event that the runtime credits to the live game-stats owner.
-- The source weight table stays in that owner, so no amount crosses the
-- translator, and an event outside the source table stays an attributed
-- unsupported command instead of a scored one.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
local ScriptFixture = require("tests.support.ScriptFixture")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")
local Structurer = require("romdump.src.digest.script.Structurer")
local Verifier = require("romdump.src.digest.script.Verifier")

local T = {}

local CATALOG = { sounds = {}, flags = {}, vars = {}, maps = {} }

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
  local member = assert(ScriptBinaryDecoder.parseMember(bytes, 0x123, "score-fixture", { catalog = CATALOG }))
  local script = assert(member.scripts[0])
  local lowered = SemanticLowering.lowerScript(script, member, { stdCatalog = SourceCatalog.catalog() })
  local steps = Structurer.structure(lowered, 0)
  local report = Verifier.verifyScript(steps, script, member, lowered.omissions)
  return lowered, steps, report
end

-- Every source event of the command is a same-tick supported operation: the
-- node names the source event only, keeps its provenance, and the script
-- verifies complete.
function T.special_game_stat_events_lower_to_the_source_event_node()
  for _, event in ipairs({ 0, 1, 21, 26, 31, 39 }) do
    local lowered, steps, report = lowerScoreEvent(event)
    local node = lowered.items[1]
    Assert.equal(node.op, "game_score_event", "source event " .. event .. " lowers to the score event")
    Assert.equal(node.event, event, "the node carries the source event unchanged")
    Assert.isNil(node.points, "no score amount is supplied by the script")
    Assert.deepEqual(node.provenance.offsets, { 0x20 })
    Assert.deepEqual(node.provenance.opcodes, { 515 })
    Assert.equal(#lowered.unsupported, 0, "source event " .. event .. " is a supported command")
    Assert.equal(steps[1].op, "game_score_event")
    Assert.isTrue(report.ok, report.problems[1] and report.problems[1].message or "score event must verify")
    Assert.isTrue(report.complete)
  end
  Assert.equal(
    CommandCatalog.classification(515),
    CommandCatalog.CONTINUE,
    "the source command returns in the same tick"
  )
end

-- The source table has no entry outside 0..39: such an operand keeps its
-- command position as one attributed unsupported node and never falls back
-- to a valid event.
function T.out_of_range_special_game_stat_events_stay_attributed_unsupported()
  for _, event in ipairs({ 40, 0xFFFF }) do
    local lowered, steps, report = lowerScoreEvent(event)
    local node = lowered.items[1]
    Assert.equal(node.op, "unsupported", "event " .. event .. " is not a source event")
    Assert.equal(node.command, 515)
    Assert.equal(node.originalName, CommandCatalog.name(515))
    Assert.deepEqual(node.arguments, { event })
    Assert.equal(node.sourceOffset, 0x20)
    Assert.deepEqual(node.provenance.offsets, { 0x20 })
    Assert.deepEqual(node.provenance.opcodes, { 515 })
    Assert.deepEqual(lowered.unsupported, { node })
    Assert.equal(steps[1].op, "unsupported")
    Assert.isTrue(report.ok, report.problems[1] and report.problems[1].message or "report stays attributed")
    Assert.isFalse(report.complete)
    Assert.equal(report.unsupportedCount, 1)
  end
end

return { tests = T }
