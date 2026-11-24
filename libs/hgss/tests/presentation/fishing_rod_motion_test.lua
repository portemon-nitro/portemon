-- The rod animation steps the fishing sprite's per-facing sequence frame
-- exactly as PlayerDraw_UpdateFishing does: cast forward and hold, idle and
-- reel back to the first frame, a bite dipping to the tenth frame and back
-- with a 30-update pause, and the per-facing rod offset.

local Assert = require("tests.support.Assert")
local FishingRodMotion = require("libs.hgss.src.presentation.FishingRodMotion")

local T = {}

local function frames(motion, name, facing, count)
  local seen = {}
  for index = 1, count do
    motion:advance(name, facing)
    seen[index] = motion:frame()
  end
  return seen
end

function T.the_cast_plays_forward_and_holds_the_line_out()
  local motion = FishingRodMotion.new()
  local seen = frames(motion, "cast", "north", 17)
  Assert.equal(seen[1], 1)
  Assert.equal(seen[15], 15)
  Assert.equal(seen[17], 15, "the cast holds its last frame")
end

function T.idle_and_reel_draw_the_rod_back_and_hold_the_first_frame()
  for _, name in ipairs({ "idle", "reel" }) do
    local motion = FishingRodMotion.new()
    frames(motion, "cast", "north", 20)
    local seen = frames(motion, name, "north", 17)
    Assert.equal(seen[1], 14, name .. " starts from the last frame")
    Assert.equal(seen[15], 0)
    Assert.equal(seen[17], 0, name .. " holds the first frame")
  end
end

function T.a_bite_dips_rises_and_pauses()
  local motion = FishingRodMotion.new()
  local seen = frames(motion, "bite", "south", 42)
  Assert.deepEqual({ seen[1], seen[5], seen[6], seen[10] }, { 14, 10, 11, 15 }, "dip to ten, rise to fifteen")
  Assert.equal(seen[40], 15, "the rod rests through the pause")
  Assert.equal(seen[41], 14, "the next dip follows the 30-update pause")
end

function T.turning_restarts_the_motion()
  local motion = FishingRodMotion.new()
  frames(motion, "cast", "north", 8)
  motion:advance("cast", "east")
  Assert.equal(motion:frame(), 1, "a new facing restarts its sequence")
end

function T.the_rod_shifts_the_billboard_per_facing()
  local motion = FishingRodMotion.new()
  motion:advance("cast", "north")
  Assert.deepEqual({ motion:offset() }, { 0, 0 })
  frames(motion, "cast", "south", 7)
  Assert.deepEqual({ motion:offset() }, { 0, 0 }, "south pushes nothing before the line is half out")
  motion:advance("cast", "south")
  Assert.deepEqual({ motion:offset() }, { 0, 6 / 16 })
  frames(motion, "cast", "west", 7)
  Assert.deepEqual({ motion:offset() }, { 1 / 16, 0 })
  motion:advance("cast", "west")
  Assert.deepEqual({ motion:offset() }, { -5 / 16, 0 })
  frames(motion, "cast", "east", 7)
  Assert.deepEqual({ motion:offset() }, { -1 / 16, 0 })
  motion:advance("cast", "east")
  Assert.deepEqual({ motion:offset() }, { 5 / 16, 0 })
end

return { tests = T }
