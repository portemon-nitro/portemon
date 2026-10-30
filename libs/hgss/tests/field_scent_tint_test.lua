-- Honey/Sweet Scent screen tint: a solid colour blended over the world with
-- alpha stepping 0 to 10 sixteenths over 19 frames on the way in and 10 to 0
-- over 15 on the way out; each fade reports done one update after its
-- counter reaches the frame count.
-- Source basis: the retail ROM's Honey and Sweet Scent fade (tint 0x5D5F).

local Assert = require("tests.support.Assert")
local FieldScentTint = require("libs.hgss.src.transition.FieldScentTint")

local T = {}

local function runToDone(tint, limit)
  local frames = 0
  while not tint:isDone() do
    tint:updateSourceFrame()
    frames = frames + 1
    assert(frames <= limit, "the tint fade never finished")
  end
  return frames
end

function T.fade_in_ramps_alpha_to_ten_sixteenths_in_twenty_updates()
  local tint = FieldScentTint.new()
  Assert.isTrue(tint:isDone(), "an idle tint reports done")
  Assert.isNil(tint:presentationOverlay())
  tint:startIn()
  Assert.isFalse(tint:isDone())
  local overlay = assert(tint:presentationOverlay() or { a = 0 })
  Assert.equal(overlay.a, 0, "the fade starts clear")
  Assert.equal(runToDone(tint, 40), 20, "19 frames of ramp plus the completing update")
  local final = assert(tint:presentationOverlay())
  Assert.near(final.a, 10 / 16, 1e-9)
  Assert.near(final.r, 31 / 31, 1e-9)
  Assert.near(final.g, 10 / 31, 1e-9)
  Assert.near(final.b, 23 / 31, 1e-9)
  Assert.equal(final.screenScope, "main")
end

function T.fade_out_ramps_back_to_clear_in_sixteen_updates_and_releases_the_overlay()
  local tint = FieldScentTint.new()
  tint:startIn()
  runToDone(tint, 40)
  tint:startOut()
  Assert.near(assert(tint:presentationOverlay()).a, 10 / 16, 1e-9, "the fade out starts at the held alpha")
  Assert.equal(runToDone(tint, 40), 16)
  Assert.isNil(tint:presentationOverlay(), "a finished fade out releases the overlay")
end

function T.alpha_follows_the_integer_step_formula()
  local tint = FieldScentTint.new()
  tint:startIn()
  local seen = {}
  for _ = 1, 4 do
    tint:updateSourceFrame()
    local overlay = tint:presentationOverlay()
    seen[#seen + 1] = overlay and overlay.a * 16 or 0
  end
  -- cur = 10 * counter / 19 truncated, evaluated before the counter steps.
  Assert.deepEqual(seen, { 0, 0, 1, 1 })
end

function T.clear_drops_the_overlay_immediately()
  local tint = FieldScentTint.new()
  tint:startIn()
  runToDone(tint, 40)
  tint:clear()
  Assert.isNil(tint:presentationOverlay())
  Assert.isTrue(tint:isDone())
end

return { tests = T }
