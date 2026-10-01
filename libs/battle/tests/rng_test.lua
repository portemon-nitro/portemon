-- Native battle randomness: labeled draws from one explicit stream replay
-- independently recorded generator outputs with exact call counts. Discarded
-- draws still advance the stream, capture and restore resume the exact
-- sequence, and snapshot reads consume no draws, so interleavings and
-- operation budgets never change the stream for the same seed and labels.

local Assert = require("tests.support.Assert")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

-- Recorded outputs of the exact generator recurrence (state * 1103515245
-- + 24691 mod 2^32, upper 16 bits returned). Every literal below was fixed
-- before the battle stream exists and is checked against the established
-- generator owner inside the test.
local VECTORS = {
  {
    seed = 0,
    states = { 24691, 3917380458, 1383151765, 833674724 },
    draws = { 0, 59774, 21105, 12720 },
  },
  {
    seed = 1,
    states = { 1103539936, 2887849427, 3538875722, 532110581 },
    draws = { 16838, 44065, 53998, 8119 },
  },
  {
    seed = 4294967295,
    states = { 3191476742, 651944193, 3522395104, 1135238867 },
    draws = { 48698, 9947, 53747, 17322 },
  },
  {
    seed = 12345,
    states = { 3554428600, 3165031627, 2178034914 },
    draws = { 54236, 48294, 33234 },
  },
}

local LABELS = { "accuracy", "damage", "critical", "effect" }

function T.labeled_draws_match_recorded_vectors_with_exact_counts()
  local Lcrng = require("libs.mons.src.gen4.Lcrng")
  for _, vector in ipairs(VECTORS) do
    local reference = Lcrng.new(vector.seed)
    for index, expected in ipairs(vector.draws) do
      Assert.equal(reference:nextU16(), expected, "recorded outputs match the established generator")
    end
    Assert.equal(reference:capture().calls, #vector.draws, "reference draws advance the call count exactly")
  end

  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  local cause = { kind = "probe", combatant = 1, activation = 1 }

  local zero = BattleRng.new(VECTORS[1].seed)
  for index, expected in ipairs(VECTORS[1].draws) do
    Assert.equal(zero:nextU16(LABELS[index], cause), expected, "every label draws from the same recorded stream")
  end
  Assert.equal(VECTORS[1].draws[1], 0, "zero stays a valid stream state and output")
  Assert.deepEqual(zero:capture(), {
    algorithm = "gen4-lcrng",
    state = VECTORS[1].states[#VECTORS[1].states],
    calls = #VECTORS[1].draws,
  }, "snapshots record the stream identity, state, and exact call count")
  Assert.deepEqual(zero:capture(), zero:capture(), "snapshot reads are stable")
  Assert.equal(zero:nextU16("accuracy", cause), 36418, "snapshot reads consume no draws")

  local unit = BattleRng.new(VECTORS[2].seed)
  unit:nextU16("discarded_probe", cause)
  Assert.equal(unit:nextU16("accuracy", cause), VECTORS[2].draws[2], "discarded calls still advance the stream")

  local wrapped = BattleRng.new(VECTORS[3].seed)
  Assert.equal(wrapped:nextU16("accuracy", cause), VECTORS[3].draws[1], "maximum seeds wrap through 32-bit overflow")
  Assert.equal(wrapped:nextU16("damage", cause), VECTORS[3].draws[2], "overflowed state continues the recorded stream")
  local held = wrapped:capture()
  Assert.deepEqual(held, {
    algorithm = "gen4-lcrng",
    state = VECTORS[3].states[2],
    calls = 2,
  }, "snapshots capture the overflowed stream exactly")
  local resumed = BattleRng.restore(held)
  Assert.equal(
    resumed:nextU16("accuracy", cause),
    VECTORS[3].draws[3],
    "restored streams resume without repeating draws"
  )
  Assert.equal(resumed:nextU16("damage", cause), VECTORS[3].draws[4], "resumed streams keep the recorded tail")
  Assert.deepEqual(resumed:capture(), {
    algorithm = "gen4-lcrng",
    state = VECTORS[3].states[4],
    calls = 4,
  }, "resumed streams account every draw")

  local direct = BattleRng.new(VECTORS[4].seed)
  for index, expected in ipairs(VECTORS[4].draws) do
    Assert.equal(direct:nextU16(LABELS[index], cause), expected, "direct streams replay the recorded outputs")
  end
  local staged = BattleRng.new(VECTORS[4].seed)
  Assert.equal(staged:nextU16("accuracy", cause), VECTORS[4].draws[1], "staged streams open identically")
  local middle = BattleRng.restore(staged:capture())
  Assert.equal(middle:nextU16("damage", cause), VECTORS[4].draws[2], "capture boundaries never change the stream")
  local tail = BattleRng.restore(middle:capture())
  Assert.equal(tail:nextU16("critical", cause), VECTORS[4].draws[3], "restore boundaries never change the stream")
  Assert.deepEqual(tail:capture(), direct:capture(), "interleavings never change the stream")

  Assert.throws(function()
    BattleRng.new(4294967296)
  end, "streams reject states outside 32 bits")
  Assert.throws(function()
    BattleRng.restore({ algorithm = "gen4-lcrng", state = -1, calls = 0 })
  end, "snapshots reject states outside 32 bits")
  Assert.throws(function()
    BattleRng.restore({ algorithm = "gen4-lcrng", state = 1, calls = -1 })
  end, "snapshots reject negative call counts")
end

function T.rejected_draws_and_snapshots_leave_the_stream_untouched()
  local BattleRng =
    SessionFixture.requirePresent("libs.battle.src.gen4.BattleRng", "labeled native draws own the battle stream")
  Assert.throws(function()
    BattleRng.new(-1)
  end, "streams reject negative seeds")
  Assert.throws(function()
    BattleRng.new(1.5)
  end, "streams reject fractional seeds")
  Assert.throws(function()
    BattleRng.new("0")
  end, "streams reject non-numeric seeds")

  local stream = BattleRng.new(9)
  local before = stream:capture()
  Assert.throws(function()
    stream:nextU16("", { kind = "probe" })
  end, "draws name their call site")
  Assert.throws(function()
    stream:nextU16(7, { kind = "probe" })
  end, "draw labels stay strings")
  Assert.throws(function()
    stream:nextU16("accuracy")
  end, "draws carry their semantic cause")
  Assert.deepEqual(stream:capture(), before, "rejected draws never advance the stream")

  Assert.throws(function()
    BattleRng.restore({ algorithm = "other-stream", state = 1, calls = 0 })
  end, "snapshots carry the native stream identity")
  Assert.throws(function()
    BattleRng.restore({ algorithm = "gen4-lcrng", state = 1.5, calls = 0 })
  end, "snapshots reject fractional states")
  Assert.throws(function()
    BattleRng.restore({ algorithm = "gen4-lcrng", state = 1, calls = 1.5 })
  end, "snapshots reject fractional call counts")
  Assert.throws(function()
    BattleRng.restore("gen4-lcrng")
  end, "snapshots restore from records")
  local positioned = BattleRng.restore(before)
  Assert.deepEqual(positioned:capture(), before, "restore positions the stream exactly")
end

return { tests = T }
