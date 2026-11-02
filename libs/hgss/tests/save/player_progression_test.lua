-- PlayerProgression contract tests: durable badge operations over the
-- canonical shared profile. Badges are an open key-value set
-- (`profile.badges` maps a non-empty string key to true), so modded
-- regions with their own gym counts work without bit-field surgery. The
-- sixteen retail keys stay as the canonical order for migration and
-- native-index adapters, and every owned key counts equally. PlayerData
-- delegates validation to this owner.

local Assert = require("tests.support.Assert")
local PlayerProgression = require("libs.hgss.src.save.PlayerProgression")

local T = {}

local function profile(badges)
  return {
    name = "GOLD",
    gender = 0,
    trainerId = 0,
    money = 3000,
    badges = badges,
    runningShoes = false,
    runningShoesLock = false,
    rivalName = "Silver",
  }
end

function T.badge_order_covers_all_sixteen_retail_badges()
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
  local progression = PlayerProgression.new(profile({}))
  Assert.equal(progression:badgeCount(), 0)
  Assert.isFalse(progression:hasBadge("zephyr"))
  Assert.isFalse(progression:hasBadge("earth"))
end

function T.award_is_idempotent_and_counts_once()
  local progression = PlayerProgression.new(profile({}))
  progression:awardBadge("hive")
  Assert.isTrue(progression:hasBadge("hive"))
  Assert.equal(progression:badgeCount(), 1)
  progression:awardBadge("hive")
  Assert.isTrue(progression:hasBadge("hive"))
  Assert.equal(progression:badgeCount(), 1)
end

function T.awards_accumulate_across_regions()
  local owned = profile({})
  local progression = PlayerProgression.new(owned)
  progression:awardBadge("zephyr")
  progression:awardBadge("boulder")
  progression:awardBadge("earth")
  Assert.equal(progression:badgeCount(), 3)
  Assert.deepEqual(owned.badges, { zephyr = true, boulder = true, earth = true })
end

function T.all_sixteen_retail_keys_round_trip()
  local owned = profile({})
  local progression = PlayerProgression.new(owned)
  for _, badge in ipairs(PlayerProgression.BADGE_ORDER) do
    progression:awardBadge(badge)
  end
  Assert.equal(progression:badgeCount(), 16)
  Assert.equal(progression:hasBadge("zephyr"), true)
  Assert.equal(progression:hasBadge("earth"), true)
end

function T.modded_keys_are_first_class_badges()
  local progression = PlayerProgression.new(profile({}))
  Assert.isFalse(progression:hasBadge("mod:ember"))
  progression:awardBadge("mod:ember")
  Assert.isTrue(progression:hasBadge("mod:ember"))
  Assert.equal(progression:badgeCount(), 1)
end

function T.modded_keys_count_alongside_retail_keys()
  local progression = PlayerProgression.new(profile({}))
  progression:awardBadge("zephyr")
  progression:awardBadge("mod:ember")
  Assert.equal(progression:badgeCount(), 2)
end

function T.malformed_badge_keys_are_rejected()
  local progression = PlayerProgression.new(profile({}))
  Assert.throws(function()
    progression:hasBadge("")
  end)
  Assert.throws(function()
    progression:awardBadge("")
  end)
  Assert.throws(function()
    progression:hasBadge(0)
  end)
  Assert.throws(function()
    progression:awardBadge(nil)
  end)
end

function T.invalid_sets_are_rejected()
  Assert.throws(function()
    PlayerProgression.new(profile(0))
  end)
  Assert.throws(function()
    PlayerProgression.new(profile(0xFFFF))
  end)
  Assert.throws(function()
    PlayerProgression.new(profile({ "zephyr" }))
  end)
  Assert.throws(function()
    PlayerProgression.new(profile({ zephyr = false }))
  end)
  Assert.throws(function()
    PlayerProgression.new(profile({ zephyr = 1 }))
  end)
  Assert.throws(function()
    PlayerProgression.new(profile("zephyr"))
  end)
end

function T.native_indexes_follow_retail_order()
  Assert.equal(PlayerProgression.toNativeIndex("zephyr"), 0)
  Assert.equal(PlayerProgression.toNativeIndex("rising"), 7)
  Assert.equal(PlayerProgression.toNativeIndex("boulder"), 8)
  Assert.equal(PlayerProgression.toNativeIndex("earth"), 15)
  Assert.equal(PlayerProgression.fromNativeIndex(2), "plain")
  Assert.equal(PlayerProgression.fromNativeIndex(10), "thunder")
end

function T.borrowed_profile_is_shared_not_copied()
  local owned = profile({})
  local progression = PlayerProgression.new(owned)
  progression:awardBadge("fog")
  Assert.deepEqual(owned.badges, { fog = true })
end

function T.running_shoes_lock_toggles_on_the_shared_profile_only_with_the_shoes()
  local owned = profile({})
  local progression = PlayerProgression.new(owned)
  Assert.isFalse(progression:runningShoesLock())
  Assert.throws(function()
    progression:toggleRunningShoesLock()
  end)
  progression:awardRunningShoes()
  progression:toggleRunningShoesLock()
  Assert.isTrue(progression:runningShoesLock())
  Assert.isTrue(owned.runningShoesLock)
  progression:toggleRunningShoesLock()
  Assert.isFalse(progression:runningShoesLock())
end

function T.running_shoes_award_sets_the_shared_profile_flag_idempotently()
  local owned = profile({})
  local progression = PlayerProgression.new(owned)
  Assert.isFalse(progression:hasRunningShoes())
  progression:awardRunningShoes()
  Assert.isTrue(progression:hasRunningShoes())
  Assert.isTrue(owned.runningShoes)
  progression:awardRunningShoes()
  Assert.isTrue(owned.runningShoes)
  Assert.deepEqual(owned.badges, {}, "the award leaves badge state untouched")
end

return { tests = T }
