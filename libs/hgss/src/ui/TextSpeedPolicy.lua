-- Owns the field text-printer timing policy shared by dialogue and typed
-- signpost text. Delays are the printer's internal blank-update counters.
-- holdAdvanceTicks is the held-source continuation cadence: a positive value
-- turns a held Action/Cancel into the page-and-close edges the reader would
-- otherwise press one at a time, and zero keeps every continuation a fresh
-- press.

local TextSpeedPolicy = {}

local POLICIES = {
  slow = { interGlyphDelay = 8, glyphBudget = 1, abAcceleration = true, holdAdvanceTicks = 0 },
  mid = { interGlyphDelay = 4, glyphBudget = 1, abAcceleration = true, holdAdvanceTicks = 0 },
  fast = { interGlyphDelay = 1, glyphBudget = 1, abAcceleration = true, holdAdvanceTicks = 0 },
  -- The TURBO stop: reveal is already instant, so holding the button is what
  -- carries the reader through the message's remaining pages.
  fastest = { interGlyphDelay = 0, glyphBudget = 2, abAcceleration = false, holdAdvanceTicks = 5 },
}

---@param textSpeed string
---@return { interGlyphDelay: integer, glyphBudget: integer, abAcceleration: boolean, holdAdvanceTicks: integer }
function TextSpeedPolicy.forSpeed(textSpeed)
  local policy = POLICIES[textSpeed]
  assert(policy ~= nil, "unknown text speed " .. tostring(textSpeed))
  return {
    interGlyphDelay = policy.interGlyphDelay,
    glyphBudget = policy.glyphBudget,
    abAcceleration = policy.abAcceleration,
    holdAdvanceTicks = policy.holdAdvanceTicks,
  }
end

return TextSpeedPolicy
