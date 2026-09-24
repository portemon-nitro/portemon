-- PlayerProgression contract tests: durable badge operations over the
-- canonical shared profile. The badge order, 16-bit mask discipline, and
-- idempotent award semantics live here; PlayerData delegates validation to
-- this owner.

local Assert = require("tests.support.Assert")
local PlayerProgression = require("libs.hgss.src.save.PlayerProgression")

local T = {}

local function profile(badges)
  return { name = "GOLD", gender = 0, trainerId = 0, money = 3000, badges = badges }
end

function T.badge_order_covers_all_sixteen_badges()
  Assert.deepEqual(PlayerProgression.BADGE_ORDER, {
    "zephyr",
    "hive",
    "plain",
    "fog",
    "storm",
    "mineral",
    "glacier",
    "rising",
    "boulder",
    "cascade",
    "thunder",
    "rainbow",
    "soul",
    "marsh",
    "volcano",
    "earth",
  })
end

function T.fresh_profile_has_no_badges()
  local progression = PlayerProgression.new(profile(0))
  Assert.equal(progression:badgeCount(), 0)
  Assert.isFalse(progression:hasBadge("zephyr"))
  Assert.isFalse(progression:hasBadge("earth"))
end

function T.award_is_idempotent_and_counts_once()
  local progression = PlayerProgression.new(profile(0))
  progression:awardBadge("hive")
  Assert.isTrue(progression:hasBadge("hive"))
  Assert.equal(progression:badgeCount(), 1)
  progression:awardBadge("hive")
  Assert.isTrue(progression:hasBadge("hive"))
  Assert.equal(progression:badgeCount(), 1)
end

function T.awards_accumulate_across_regions()
  local owned = profile(0)
  local progression = PlayerProgression.new(owned)
  progression:awardBadge("zephyr")
  progression:awardBadge("boulder")
  progression:awardBadge("earth")
  Assert.equal(progression:badgeCount(), 3)
  Assert.equal(owned.badges, 2 ^ 0 + 2 ^ 8 + 2 ^ 15)
end

function T.all_sixteen_bits_round_trip()
  local owned = profile(0)
  local progression = PlayerProgression.new(owned)
  for _, badge in ipairs(PlayerProgression.BADGE_ORDER) do
    progression:awardBadge(badge)
  end
  Assert.equal(progression:badgeCount(), 16)
  Assert.equal(owned.badges, 0xFFFF)
end

function T.unknown_badge_keys_are_rejected()
  local progression = PlayerProgression.new(profile(0))
  Assert.throws(function()
    progression:hasBadge("pallet")
  end)
  Assert.throws(function()
    progression:awardBadge("pallet")
  end)
end

function T.invalid_masks_are_rejected()
  Assert.throws(function()
    PlayerProgression.new(profile(-1))
  end)
  Assert.throws(function()
    PlayerProgression.new(profile(0x10000))
  end)
  Assert.throws(function()
    PlayerProgression.new(profile(1.5))
  end)
  Assert.throws(function()
    PlayerProgression.new(profile("0"))
  end)
end

function T.native_indexes_follow_semantic_order()
  Assert.equal(PlayerProgression.toNativeIndex("zephyr"), 0)
  Assert.equal(PlayerProgression.toNativeIndex("rising"), 7)
  Assert.equal(PlayerProgression.toNativeIndex("boulder"), 8)
  Assert.equal(PlayerProgression.toNativeIndex("earth"), 15)
  Assert.equal(PlayerProgression.fromNativeIndex(2), "plain")
  Assert.equal(PlayerProgression.fromNativeIndex(10), "thunder")
end

function T.borrowed_profile_is_shared_not_copied()
  local owned = profile(0)
  local progression = PlayerProgression.new(owned)
  progression:awardBadge("fog")
  Assert.equal(owned.badges, 2 ^ 3)
end

return { tests = T }
