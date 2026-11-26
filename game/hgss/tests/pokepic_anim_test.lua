-- The source picture animation stepper (pokepic.c runPokepicAnim): exact
-- per-tick frame selection over ten {next, duration} entries, with loop
-- entries and the -1 terminal. Hand-traced against the C control flow.

local Assert = require("tests.support.Assert")
local PokepicAnim = require("game.hgss.src.ending.PokepicAnim")

local T = { tests = {} }

local function script(entries)
  local steps = {}
  for index = 1, 10 do
    local entry = entries[index] or { -1, 0 }
    steps[index] = { next = entry[1], duration = entry[2], xOffset = 0 }
  end
  return steps
end

function T.tests.two_frames_then_end()
  -- Frame 0 for 2 ticks, frame 1 for 3 ticks, then done on frame 0.
  local anim = PokepicAnim.new(script({ { 0, 2 }, { 1, 3 }, { -1, 0 } }))
  Assert.equal(anim:update(), 0, "the head frame shows while its delay counts down")
  Assert.equal(anim:update(), 0, "the head frame holds its second tick")
  Assert.equal(anim:update(), 1, "the second frame shows after the head delay")
  Assert.equal(anim:update(), 1, "the second frame holds")
  Assert.equal(anim:update(), 1, "the second frame holds its last tick")
  Assert.equal(anim:update(), 1, "the delay expiry shows the last frame first")
  Assert.equal(anim:update(), 0, "the terminal lands back on frame 0")
  Assert.equal(anim:update(), -1, "a finished animation stays finished")
  Assert.equal(anim:update(), -1, "a finished animation never restarts")
end

function T.tests.loop_entries_count_down_before_jumping_back()
  -- Entry 2 loops back to entry 1 until its duration elapses: the head
  -- frame replays in full (including its own delay) before the loop
  -- falls through.
  local anim = PokepicAnim.new(script({ { 0, 1 }, { -3, 2 }, { -1, 0 } }))
  Assert.equal(anim:update(), 0, "the head frame shows first")
  Assert.equal(anim:update(), 0, "the loop replays the head frame")
  Assert.equal(anim:update(), 0, "the replayed head counts its own delay")
  Assert.equal(anim:update(), 0, "the loop falls through on frame 0")
  Assert.equal(anim:update(), -1, "a finished animation stays finished")
end

function T.tests.zero_duration_loops_fall_through()
  local anim = PokepicAnim.new(script({ { 0, 1 }, { -3, 0 }, { 1, 2 }, { -1, 0 } }))
  Assert.equal(anim:update(), 0, "the head frame shows first")
  Assert.equal(anim:update(), 1, "a zero-duration loop never replays its head")
end

return T
