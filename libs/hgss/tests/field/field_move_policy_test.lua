-- FieldMovePolicy contract tests: source-ordered eligibility over copied
-- context records. Every paired-failure case proves the first source reason
-- wins; the following mon alone never triggers the human-escort
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
    alphFlashRoom = false,
    alphEscapeRopeRoom = false,
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
    alphFlashSpot = false,
    alphEscapeRopeSpot = false,
    facingObstacle = nil,
    facingActor = nil,
    surfEdge = false,
    facingWaterfall = false,
    facingWhirlpool = false,
    climbTile = false,
    headbuttTree = false,
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
  Assert.equal(FieldMovePolicy.check("fly", context({ safari = true })).kind, "not_here")
  Assert.equal(FieldMovePolicy.check("fly", context({ palPark = true })).kind, "not_here")
  Assert.equal(
    FieldMovePolicy.check("fly", context({ rocketCostume = true, safari = true })).kind,
    "not_now",
    "the costume refusal precedes the zone refusal"
  )
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

function T.flash_needs_no_badge_live_flash_weather_or_the_alph_spot()
  local lit = context({ badges = noBadges(), weatherId = 11 })
  Assert.equal(FieldMovePolicy.check("flash", lit).kind, "ok")
  Assert.equal(FieldMovePolicy.check("flash", context({ badges = noBadges() })).kind, "not_here")
  local used = context({ badges = noBadges(), weatherId = 12 })
  Assert.equal(FieldMovePolicy.check("flash", used).kind, "not_here", "an illuminated cave is refused")
  Assert.equal(FieldMovePolicy.check("flash", context({ alphFlashSpot = true })).kind, "ok")
end

function T.teleport_needs_permission_then_escort_state()
  local closed = context({ fieldUse = fieldUse({ teleportAllowed = false }) })
  Assert.equal(FieldMovePolicy.check("teleport", closed).kind, "not_here")
  Assert.equal(FieldMovePolicy.check("teleport", context({ humanFollower = true })).kind, "have_follower")
  Assert.equal(FieldMovePolicy.check("teleport", context({ rocketCostume = true })).kind, "not_now")
  Assert.equal(FieldMovePolicy.check("teleport", context({ safari = true })).kind, "not_here")
  Assert.equal(FieldMovePolicy.check("teleport", context({ palPark = true })).kind, "not_here")
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

function T.headbutt_needs_a_facing_tree()
  Assert.equal(FieldMovePolicy.check("headbutt", context()).kind, "not_here")
  Assert.equal(FieldMovePolicy.check("headbutt", context({ headbuttTree = true })).kind, "ok")
end

function T.sweet_scent_and_chatter_checks_follow_the_source_restrictions()
  Assert.equal(FieldMovePolicy.check("sweet_scent", context({ palPark = true })).kind, "not_here")
  Assert.equal(FieldMovePolicy.check("sweet_scent", context({ safari = true })).kind, "ok")
  Assert.equal(FieldMovePolicy.check("sweet_scent", context()).kind, "ok")
  Assert.equal(FieldMovePolicy.check("chatter", context()).kind, "ok")
end

function T.escape_rope_orders_escort_costume_alph_spot_then_cave()
  local cave = context({ fieldUse = fieldUse({ cave = true }) })
  Assert.equal(FieldMovePolicy.checkEscapeRope(cave).kind, "ok")
  Assert.equal(FieldMovePolicy.checkEscapeRope(context()).kind, "not_here")
  local noEscape = context({ fieldUse = fieldUse({ cave = true, escapeAllowed = false }) })
  Assert.equal(FieldMovePolicy.checkEscapeRope(noEscape).kind, "not_here")
  Assert.equal(FieldMovePolicy.checkEscapeRope(context({ alphEscapeRopeSpot = true })).kind, "ok")
  local escorted = context({ humanFollower = true, alphEscapeRopeSpot = true })
  Assert.equal(FieldMovePolicy.checkEscapeRope(escorted).kind, "have_follower")
  local costume = context({ rocketCostume = true, alphEscapeRopeSpot = true })
  Assert.equal(FieldMovePolicy.checkEscapeRope(costume).kind, "not_now")
end

function T.bag_items_and_removed_moves_are_not_party_field_moves()
  for _, move in ipairs(FieldMovePolicy.MOVE_KEYS) do
    Assert.isTrue(move ~= "defog" and move ~= "escape_rope", move)
  end
  Assert.throws(function()
    FieldMovePolicy.check("defog", context())
  end)
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
