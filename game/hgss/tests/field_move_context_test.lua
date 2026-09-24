-- FieldMoveContext adapter tests: live service reads become a copied
-- read-only value record. Changed maps or actors produce changed contexts;
-- snapshots never alias the caller's tables.

local Assert = require("tests.support.Assert")
local FieldMoveContext = require("game.hgss.src.field.FieldMoveContext")

local T = {}

local function fieldUse(overrides)
  local value = {
    flyAllowed = true,
    teleportAllowed = true,
    escapeAllowed = true,
    flashUsable = false,
    alphChamber = false,
    icePathB2F = false,
    cave = false,
    unionOrColosseum = false,
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function sources(overrides)
  local value = {
    badges = 3,
    mapSymbol = "MAP_ROUTE_29",
    mapId = 200,
    fieldUse = fieldUse(),
    avatarMode = "walking",
    humanFollower = false,
    followingMon = true,
    rocketCostume = false,
    safari = false,
    palPark = false,
    weatherId = 0,
    facingActor = nil,
    surfEdge = false,
    facingWaterfall = false,
    facingWhirlpool = false,
    climbTile = false,
    headbuttTree = false,
    foggy = false,
    chatterOpen = false,
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

function T.capture_copies_every_fact_without_aliasing()
  local input = sources()
  local context = FieldMoveContext.capture(input)
  Assert.equal(context.badges, 3)
  Assert.equal(context.mapSymbol, "MAP_ROUTE_29")
  Assert.equal(context.mapId, 200)
  Assert.equal(context.avatarMode, "walking")
  Assert.isFalse(context.humanFollower)
  Assert.isTrue(context.followingMon)
  Assert.isNil(context.facingObstacle)
  Assert.isFalse(context.unionOrColosseum)
  input.badges = 0
  input.fieldUse.flyAllowed = false
  Assert.equal(context.badges, 3)
  Assert.isTrue(context.fieldUse.flyAllowed)
end

function T.facing_actor_resolves_the_obstacle_and_records_identity()
  local actor =
    { identity = "map:200:object:4", obstacleKind = "cut_tree", mapSymbol = "MAP_ROUTE_29", fieldX = 9, fieldZ = 3 }
  local context = FieldMoveContext.capture(sources({ facingActor = actor }))
  Assert.equal(context.facingObstacle, "cut_tree")
  Assert.deepEqual(context.facingActor, actor)
  actor.obstacleKind = "smash_rock"
  Assert.equal(context.facingObstacle, "cut_tree")
  Assert.equal(context.facingActor.obstacleKind, "cut_tree")
end

function T.changed_maps_produce_changed_contexts()
  local unionUse = fieldUse({ flyAllowed = false, unionOrColosseum = true })
  local context = FieldMoveContext.capture(sources({ mapSymbol = "MAP_UNION", mapId = 2, fieldUse = unionUse }))
  Assert.equal(context.mapSymbol, "MAP_UNION")
  Assert.isTrue(context.unionOrColosseum)
  Assert.isFalse(context.fieldUse.flyAllowed)
end

function T.malformed_sources_fail_loudly()
  Assert.throws(function()
    local broken = sources()
    broken.fieldUse = { flyAllowed = true }
    FieldMoveContext.capture(broken)
  end)
  Assert.throws(function()
    local broken = sources()
    broken.avatarMode = "flying"
    FieldMoveContext.capture(broken)
  end)
  Assert.throws(function()
    local broken = sources()
    broken.badges = -1
    FieldMoveContext.capture(broken)
  end)
end

return { tests = T }
