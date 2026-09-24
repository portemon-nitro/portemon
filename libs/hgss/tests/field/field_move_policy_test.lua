-- FieldMovePolicy contract tests: source-ordered eligibility over copied
-- context records. Every paired-failure case proves the first source reason
-- wins; the following Pokemon alone never triggers the human-escort
-- refusal; checks never mutate HP/PP state (contexts are value records).

local Assert = require("tests.support.Assert")
local FieldMovePolicy = require("libs.hgss.src.field.FieldMovePolicy")

local T = {}

local ALL_BADGES = 0xFFFF

local function fieldUse(overrides)
  local value = {
    flyAllowed = true,
    teleportAllowed = true,
    escapeAllowed = true,
    flashUsable = true,
    alphChamber = false,
    icePathB2F = false,
    cave = false,
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function context(overrides)
  local value = {
    badges = ALL_BADGES,
    unionOrColosseum = false,
    mapSymbol = "MAP_ROUTE_29",
    mapId = 200,
    avatarMode = "walking",
    humanFollower = false,
    followingMon = false,
    rocketCostume = false,
    safari = false,
    palPark = false,
    weatherId = 0,
    facingObstacle = nil,
    facingActor = nil,
    surfEdge = false,
    facingWaterfall = false,
    facingWhirlpool = false,
    climbTile = false,
    headbuttTree = false,
    foggy = false,
    chatterOpen = false,
    fieldUse = fieldUse(),
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function noBadges()
  return 0
end

function T.unknown_moves_are_rejected()
  Assert.throws(function()
    FieldMovePolicy.check("hyper_beam", context())
  end)
end

function T.union_rooms_reject_every_external_move_first()
  local blocked = context({ unionOrColosseum = true })
  for _, move in ipairs(FieldMovePolicy.MOVE_KEYS) do
    local decision = FieldMovePolicy.check(move, blocked)
    Assert.equal(decision.kind, "not_here", move)
  end
end

function T.cut_needs_the_hive_badge_before_the_tree()
  Assert.equal(FieldMovePolicy.check("cut", context({ badges = noBadges() })).kind, "need_badge")
  Assert.equal(
    FieldMovePolicy.check("cut", context({ badges = noBadges(), facingObstacle = "cut_tree" })).kind,
    "need_badge"
  )
  Assert.equal(FieldMovePolicy.check("cut", context()).kind, "not_here")
  Assert.equal(FieldMovePolicy.check("cut", context({ facingObstacle = "cut_tree" })).kind, "ok")
  Assert.equal(FieldMovePolicy.check("cut", context({ facingObstacle = "smash_rock" })).kind, "not_here")
end

function T.fly_checks_storm_permission_and_escort_in_order()
  Assert.equal(FieldMovePolicy.check("fly", context({ badges = noBadges() })).kind, "need_badge")
  local noFly = context({ fieldUse = fieldUse({ flyAllowed = false }) })
  Assert.equal(FieldMovePolicy.check("fly", noFly).kind, "not_here")
  Assert.equal(FieldMovePolicy.check("fly", context({ humanFollower = true })).kind, "have_follower")
  Assert.equal(FieldMovePolicy.check("fly", context({ rocketCostume = true })).kind, "not_now")
  Assert.equal(FieldMovePolicy.check("fly", context({ safari = true })).kind, "not_now")
  Assert.equal(FieldMovePolicy.check("fly", context({ palPark = true })).kind, "not_now")
  Assert.equal(FieldMovePolicy.check("fly", context()).kind, "ok")
end

function T.surf_checks_fog_surfing_edge_and_escort_in_order()
  Assert.equal(FieldMovePolicy.check("surf", context({ badges = noBadges() })).kind, "need_badge")
  Assert.equal(
    FieldMovePolicy.check("surf", context({ avatarMode = "surfing", surfEdge = true })).kind,
    "already_surfing"
  )
  Assert.equal(FieldMovePolicy.check("surf", context()).kind, "not_here")
  Assert.equal(FieldMovePolicy.check("surf", context({ surfEdge = true, humanFollower = true })).kind, "have_follower")
  Assert.equal(FieldMovePolicy.check("surf", context({ surfEdge = true })).kind, "ok")
end

function T.strength_needs_plain_then_boulder_with_ice_path_exception()
  Assert.equal(FieldMovePolicy.check("strength", context({ badges = noBadges() })).kind, "need_badge")
  Assert.equal(FieldMovePolicy.check("strength", context()).kind, "not_here")
  Assert.equal(FieldMovePolicy.check("strength", context({ facingObstacle = "strength_boulder" })).kind, "ok")
  local icePath = context({
    mapSymbol = "MAP_ICE_PATH_B2F",
    facingObstacle = "strength_boulder",
    fieldUse = fieldUse({ icePathB2F = true }),
  })
  Assert.equal(FieldMovePolicy.check("strength", icePath).kind, "not_here")
end

function T.rock_smash_needs_zephyr_then_breakable_rock()
  Assert.equal(FieldMovePolicy.check("rock_smash", context({ badges = noBadges() })).kind, "need_badge")
  Assert.equal(FieldMovePolicy.check("rock_smash", context()).kind, "not_here")
  Assert.equal(FieldMovePolicy.check("rock_smash", context({ facingObstacle = "smash_rock" })).kind, "ok")
end

function T.waterfall_checks_surfing_before_rising()
  local surfing = context({ avatarMode = "surfing", facingWaterfall = true })
  Assert.equal(FieldMovePolicy.check("waterfall", context({ facingWaterfall = true })).kind, "not_here")
  Assert.equal(
    FieldMovePolicy.check("waterfall", context({ avatarMode = "surfing", facingWaterfall = true, badges = 0 })).kind,
    "need_badge"
  )
  Assert.equal(FieldMovePolicy.check("waterfall", surfing).kind, "ok")
  Assert.equal(FieldMovePolicy.check("waterfall", context({ avatarMode = "surfing" })).kind, "not_here")
end

function T.rock_climb_checks_earth_tile_and_escort_in_order()
  Assert.equal(FieldMovePolicy.check("rock_climb", context({ badges = noBadges() })).kind, "need_badge")
  Assert.equal(FieldMovePolicy.check("rock_climb", context()).kind, "not_here")
  Assert.equal(
    FieldMovePolicy.check("rock_climb", context({ climbTile = true, humanFollower = true })).kind,
    "have_follower"
  )
  Assert.equal(FieldMovePolicy.check("rock_climb", context({ climbTile = true })).kind, "ok")
end

function T.whirlpool_checks_surfing_before_glacier()
  Assert.equal(FieldMovePolicy.check("whirlpool", context({ facingWhirlpool = true })).kind, "not_here")
  Assert.equal(
    FieldMovePolicy.check("whirlpool", context({ avatarMode = "surfing", facingWhirlpool = true, badges = 0 })).kind,
    "need_badge"
  )
  Assert.equal(
    FieldMovePolicy.check("whirlpool", context({ avatarMode = "surfing", facingWhirlpool = true })).kind,
    "ok"
  )
end

function T.flash_needs_no_badge_and_honors_the_alph_exception()
  local dark = context({ badges = noBadges(), fieldUse = fieldUse({ flashUsable = false }) })
  Assert.equal(FieldMovePolicy.check("flash", dark).kind, "not_here")
  local alph = context({ badges = noBadges(), fieldUse = fieldUse({ flashUsable = false, alphChamber = true }) })
  Assert.equal(FieldMovePolicy.check("flash", alph).kind, "ok")
  Assert.equal(FieldMovePolicy.check("flash", context({ badges = noBadges() })).kind, "ok")
end

function T.teleport_needs_permission_then_escort_state()
  local closed = context({ fieldUse = fieldUse({ teleportAllowed = false }) })
  Assert.equal(FieldMovePolicy.check("teleport", closed).kind, "not_here")
  Assert.equal(FieldMovePolicy.check("teleport", context({ humanFollower = true })).kind, "have_follower")
  Assert.equal(FieldMovePolicy.check("teleport", context({ safari = true })).kind, "not_now")
  Assert.equal(FieldMovePolicy.check("teleport", context()).kind, "ok")
end

function T.dig_needs_cave_and_escape_permission()
  Assert.equal(FieldMovePolicy.check("dig", context()).kind, "not_here")
  local cave = context({ fieldUse = fieldUse({ cave = true }) })
  Assert.equal(FieldMovePolicy.check("dig", cave).kind, "ok")
  local caveNoEscape = context({ fieldUse = fieldUse({ cave = true, escapeAllowed = false }) })
  Assert.equal(FieldMovePolicy.check("dig", caveNoEscape).kind, "not_here")
  Assert.equal(
    FieldMovePolicy.check("dig", context({ fieldUse = fieldUse({ cave = true }), humanFollower = true })).kind,
    "have_follower"
  )
end

function T.headbutt_reports_missing_encounters_only_after_physical_checks()
  Assert.equal(FieldMovePolicy.check("headbutt", context()).kind, "not_here")
  local decision = FieldMovePolicy.check("headbutt", context({ headbuttTree = true }))
  Assert.equal(decision.kind, "feature_unavailable")
end

function T.sweet_scent_and_chatter_are_recognized_but_unavailable()
  Assert.equal(FieldMovePolicy.check("sweet_scent", context({ palPark = true })).kind, "not_here")
  Assert.equal(FieldMovePolicy.check("sweet_scent", context()).kind, "feature_unavailable")
  Assert.equal(FieldMovePolicy.check("chatter", context()).kind, "not_here")
  Assert.equal(FieldMovePolicy.check("chatter", context({ chatterOpen = true })).kind, "feature_unavailable")
end

function T.defog_and_escape_rope_use_map_data()
  Assert.equal(FieldMovePolicy.check("defog", context()).kind, "not_here")
  Assert.equal(FieldMovePolicy.check("defog", context({ foggy = true })).kind, "ok")
  local cave = context({ fieldUse = fieldUse({ cave = true }) })
  Assert.equal(FieldMovePolicy.check("escape_rope", cave).kind, "ok")
  Assert.equal(FieldMovePolicy.check("escape_rope", context()).kind, "not_here")
end

function T.following_mon_alone_never_triggers_the_escort_refusal()
  local follower = context({ followingMon = true, surfEdge = true })
  Assert.equal(FieldMovePolicy.check("surf", follower).kind, "ok")
  local flyer = context({ followingMon = true })
  Assert.equal(FieldMovePolicy.check("fly", flyer).kind, "ok")
end

function T.checks_never_mutate_the_context_record()
  local before = context({ surfEdge = true, facingObstacle = "cut_tree" })
  FieldMovePolicy.check("cut", before)
  FieldMovePolicy.check("surf", before)
  Assert.isNil(before.facingWaterfall == true and true or nil)
  Assert.equal(before.badges, ALL_BADGES)
  Assert.equal(before.surfEdge, true)
end

return { tests = T }
