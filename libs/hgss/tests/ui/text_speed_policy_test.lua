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
  -- The turbo cadence itself is a tuned constant of the policy, not a second
  -- literal to keep in step here: what the strict contract owes is the reveal
  -- shape plus a positive held-source continuation.
  local turbo = TextSpeedPolicy.forSpeed("fastest")
  Assert.equal(turbo.interGlyphDelay, 0, "turbo reveals with no inter-glyph delay")
  Assert.equal(turbo.glyphBudget, 2, "turbo reveals two glyphs per update")
  Assert.isFalse(turbo.abAcceleration, "turbo needs no AB speed-up")
  Assert.isTrue(
    type(turbo.holdAdvanceTicks) == "number" and turbo.holdAdvanceTicks % 1 == 0 and turbo.holdAdvanceTicks > 0,
    "turbo carries a positive whole-tick held-source continuation cadence"
  )
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
