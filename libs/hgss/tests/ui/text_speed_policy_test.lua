local Assert = require("tests.support.Assert")
local TextSpeedPolicy = require("libs.hgss.src.ui.TextSpeedPolicy")

local T = {}

function T.exposes_one_strict_policy_for_every_field_speed()
  Assert.deepEqual(TextSpeedPolicy.forSpeed("slow"), {
    interGlyphDelay = 8,
    glyphBudget = 1,
    abAcceleration = true,
    holdAdvanceTicks = 0,
  })
  Assert.deepEqual(TextSpeedPolicy.forSpeed("mid"), {
    interGlyphDelay = 4,
    glyphBudget = 1,
    abAcceleration = true,
    holdAdvanceTicks = 0,
  })
  Assert.deepEqual(TextSpeedPolicy.forSpeed("fast"), {
    interGlyphDelay = 1,
    glyphBudget = 1,
    abAcceleration = true,
    holdAdvanceTicks = 0,
  })
  Assert.deepEqual(TextSpeedPolicy.forSpeed("fastest"), {
    interGlyphDelay = 0,
    glyphBudget = 2,
    abAcceleration = false,
    holdAdvanceTicks = 15,
  })
end

-- Only the TURBO stop turns a held Action/Cancel into continuation edges; the
-- slower stops keep every page turn a fresh press so the reader's own cadence
-- always decides when the next page appears.
function T.only_turbo_auto_advances_while_the_source_is_held()
  Assert.isTrue(TextSpeedPolicy.forSpeed("fastest").holdAdvanceTicks > 0)
  for _, speed in ipairs({ "slow", "mid", "fast" }) do
    Assert.equal(TextSpeedPolicy.forSpeed(speed).holdAdvanceTicks, 0, speed .. " keeps fresh-press continuation")
  end
end

function T.rejects_unknown_speed()
  Assert.throws(function()
    TextSpeedPolicy.forSpeed("turbo")
  end)
end

return { tests = T }
