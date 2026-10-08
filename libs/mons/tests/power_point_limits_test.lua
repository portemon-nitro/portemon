-- Power-point maxima follow the source multiply-before-truncate rule through
-- one domain helper. Non-multiple-of-five bases separate the correct
-- rounding from the old truncate-first allowance, and invalid calculation
-- inputs fail instead of repairing records.

local Assert = require("tests.support.Assert")
local Moves = require("libs.mons.src.gen4.Moves")

local T = {}

function T.custom_base_points_follow_multiply_before_truncate()
  local expected = { [0] = 7, 8, 9, 11 }
  for ups = 0, Moves.MAX_PP_UPS do
    Assert.equal(
      Moves.maxPp(7, ups),
      expected[ups],
      "base 7 with " .. ups .. " ups must multiply before truncating"
    )
  end
end

function T.ordinary_bases_keep_their_maxima()
  local expected = { [0] = 10, 12, 14, 16 }
  for ups = 0, Moves.MAX_PP_UPS do
    Assert.equal(
      Moves.maxPp(10, ups),
      expected[ups],
      "base 10 with " .. ups .. " ups keeps its ordinary maximum"
    )
  end
end

function T.invalid_calculation_inputs_fail_without_repair()
  Assert.throws(function()
    Moves.maxPp(7, Moves.MAX_PP_UPS + 1)
  end, "ups above the native allowance must fail")
  Assert.throws(function()
    Moves.maxPp(7, -1)
  end, "negative ups must fail")
  Assert.throws(function()
    Moves.maxPp(7, 1.5)
  end, "fractional ups must fail")
  Assert.throws(function()
    Moves.maxPp(-1, 0)
  end, "negative base points must fail")
  Assert.throws(function()
    Moves.maxPp(7.5, 0)
  end, "fractional base points must fail")
end

return { tests = T }
