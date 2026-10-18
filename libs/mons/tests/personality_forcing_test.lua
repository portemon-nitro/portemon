-- Forced personality vectors: the exact retail ROM
-- ChangePersonalityToNatureGenderAndAbility convolution for the
-- non-generator branch (the Spiky-Ear Pichu and Pokewalker path), where
-- the input doubles as the trainer ID and no generator draws happen. The
-- expectations below pin the source arithmetic, not a reimplementation:
-- nature from pid mod 25, gender from the low byte against the ratio, and
-- ability from pid parity.

local Assert = require("tests.support.Assert")
local Personality = require("libs.mons.src.gen4.Personality")

local T = {}

local NAUGHTY = 4

-- The source enforces ability parity only when the gender nudge runs;
-- an already-conforming low byte keeps its incoming parity. The sweeps
-- below pin the universally forced properties (nature, gender,
-- determinism), while the pinned vector pins the full nudge path.
local function checkSpiky(pid, trainerId)
  Assert.equal(Personality.nature(pid), NAUGHTY, "the forced pid keeps its nature")
  Assert.equal(Personality.gender(127, pid), "female", "the forced pid reads female at the Pichu ratio")
  Assert.isTrue(pid >= 0 and pid <= 4294967295, "the forced pid stays an unsigned 32-bit value")
  Assert.equal(Personality.forcedNatureGenderAbility(trainerId, 127, NAUGHTY, "female", 0), pid, "forcing is deterministic")
end

function T.spiky_ear_parameters_hold_across_trainer_ids()
  for trainerId = 0, 2000 do
    checkSpiky(Personality.forcedNatureGenderAbility(trainerId, 127, NAUGHTY, "female", 0), trainerId)
  end
  for _, trainerId in ipairs({ 2271560481, 4294967295, 0x00FF00FF, 0xFF00FF00 }) do
    checkSpiky(Personality.forcedNatureGenderAbility(trainerId, 127, NAUGHTY, "female", 0), trainerId)
  end
end

function T.male_vectors_keep_their_gender_branch()
  for trainerId = 0, 500 do
    local pid = Personality.forcedNatureGenderAbility(trainerId, 31, 0, "male", 0)
    Assert.equal(Personality.nature(pid), 0, "the male vector keeps Hardy")
    Assert.equal(Personality.gender(31, pid), "male", "the male vector reads male at the starter ratio")
  end
end

-- Hand trace for trainer ID 0 under the Spiky parameters: the high word
-- folds to 0xFF000000 (remainder 5), the nature nudge lands on
-- 0xFEFFFFFF (low byte 255), the gender nudge subtracts 150 to low byte
-- 105, and the parity correction subtracts 25 more, leaving nature 4,
-- a female low byte of 80, and even parity.
function T.pinned_vector_runs_the_full_nudge_path()
  local pid = Personality.forcedNatureGenderAbility(0, 127, NAUGHTY, "female", 0)
  Assert.equal(pid, 4278189904, "the trainer-0 vector is pinned")
  Assert.equal(Personality.nature(pid), NAUGHTY)
  Assert.equal(Personality.gender(127, pid), "female")
  Assert.equal(pid % 2, 0)
end

function T.fixed_ratios_skip_gender_adjustment_but_keep_nature()
  for _, ratio in ipairs({ 0, 254, 255 }) do
    for trainerId = 0, 200 do
      local pid = Personality.forcedNatureGenderAbility(trainerId, ratio, 10, "female", 0)
      Assert.equal(Personality.nature(pid), 10, "fixed ratios still force the nature")
    end
  end
end

function T.mismatched_parity_and_bad_inputs_fail()
  for _, args in ipairs({
    { 1, 127, NAUGHTY, "female", 1 },
    { 1, 127, 3, "female", 0 },
    { 1, 127, NAUGHTY, "unknown", 0 },
    { 1, 300, NAUGHTY, "female", 0 },
  }) do
    local ok = pcall(Personality.forcedNatureGenderAbility, args[1], args[2], args[3], args[4], args[5])
    Assert.isFalse(ok, "out-of-contract forcing inputs must fail")
  end
end

return { tests = T }
