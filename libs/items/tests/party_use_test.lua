-- Shared restoration arithmetic: fixed, full, half, and quarter records
-- resolve to exact integer amounts with single-point maximums restoring
-- one point.

local Assert = require("tests.support.Assert")

local T = {}

---@return table the loaded restoration owner
local function restorationOwner()
  local ok, loaded = pcall(require, "libs.items.src.PartyUse")
  Assert.isTrue(ok, "the shared restoration arithmetic loads")
  assert(loaded ~= nil, "the restoration owner publishes its arithmetic")
  return loaded --[[@as table]]
end

function T.fixed_restoration_returns_its_generated_amount()
  local PartyUse = restorationOwner()
  Assert.equal(PartyUse.restoreAmount(52, { kind = "fixed", amount = 20 }), 20, "fixed amounts pass through")
  Assert.equal(PartyUse.restoreAmount(52, { kind = "fixed", amount = 200 }), 200, "fixed amounts may exceed the wound")
end

function T.full_half_and_quarter_restoration_scale_with_the_maximum()
  local PartyUse = restorationOwner()
  Assert.equal(PartyUse.restoreAmount(52, { kind = "full" }), 52, "full restoration names the maximum")
  Assert.equal(PartyUse.restoreAmount(52, { kind = "half" }), 26, "half restoration splits the maximum")
  Assert.equal(PartyUse.restoreAmount(52, { kind = "quarter" }), 13, "quarter restoration quarters the maximum")
end

function T.half_and_quarter_restoration_floor_odd_maxima()
  local PartyUse = restorationOwner()
  Assert.equal(PartyUse.restoreAmount(31, { kind = "half" }), 15, "odd halves floor")
  Assert.equal(PartyUse.restoreAmount(31, { kind = "quarter" }), 7, "odd quarters floor")
  Assert.equal(PartyUse.restoreAmount(3, { kind = "half" }), 1, "small halves floor")
  Assert.equal(PartyUse.restoreAmount(3, { kind = "quarter" }), 0, "small quarters floor to nothing")
end

function T.single_point_maximums_restore_one_point()
  local PartyUse = restorationOwner()
  Assert.equal(PartyUse.restoreAmount(1, { kind = "fixed", amount = 50 }), 1, "fixed yields to the single point")
  Assert.equal(PartyUse.restoreAmount(1, { kind = "full" }), 1, "full yields to the single point")
  Assert.equal(PartyUse.restoreAmount(1, { kind = "half" }), 1, "half yields to the single point")
  Assert.equal(PartyUse.restoreAmount(1, { kind = "quarter" }), 1, "quarter yields to the single point")
end

return { tests = T }
