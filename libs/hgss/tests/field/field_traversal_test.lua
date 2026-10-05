-- FieldTraversal tests anchor normalized behavior categories and semantic
-- decisions without terrain, actors, progression, or host dependencies.

local Assert = require("tests.support.Assert")
local FieldTraversal = require("libs.hgss.src.world.FieldTraversal")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")

local T = {}
local BEHAVIOR = MetatileBehavior.BEHAVIOR

function T.metatile_behavior_names_cover_navigation_categories()
  Assert.isTrue(MetatileBehavior.isTallGrass(BEHAVIOR.TALL_GRASS))
  Assert.isTrue(MetatileBehavior.isVeryTallGrass(BEHAVIOR.VERY_TALL_GRASS))
  Assert.isTrue(MetatileBehavior.isSurfableWater(BEHAVIOR.RIVER_WATER))
  Assert.isTrue(MetatileBehavior.isSurfableWater(BEHAVIOR.SEA_WATER))
  Assert.equal(MetatileBehavior.fieldAction(BEHAVIOR.WATERFALL), "waterfall")
  Assert.equal(MetatileBehavior.fieldAction(BEHAVIOR.WHIRLPOOL), "whirlpool")
  Assert.equal(MetatileBehavior.fieldAction(BEHAVIOR.ROCK_CLIMB_EAST_WEST), "rock_climb")
  Assert.equal(MetatileBehavior.fieldAction(BEHAVIOR.ROCK_CLIMB_NORTH_SOUTH), "rock_climb")
  Assert.isFalse(MetatileBehavior.isSurfableWater(BEHAVIOR.TALL_GRASS))
end

function T.reaction_suppression_matches_the_three_retail_metatiles()
  for _, behavior in ipairs({ 46, 113, 114 }) do
    Assert.isTrue(MetatileBehavior.suppressesFollowerReaction(behavior), "suppressed behavior " .. behavior)
  end
  for _, behavior in ipairs({ 0, 2, 3, 45, 47, 112, 115 }) do
    Assert.isFalse(MetatileBehavior.suppressesFollowerReaction(behavior), "ordinary behavior " .. behavior)
  end
end

function T.source_behavior_values_and_directions_are_exact()
  local ledges = {
    { name = "JUMP_EAST", value = 56, direction = "east" },
    { name = "JUMP_WEST", value = 57, direction = "west" },
    { name = "JUMP_NORTH", value = 58, direction = "north" },
    { name = "JUMP_SOUTH", value = 59, direction = "south" },
  }
  for _, expected in ipairs(ledges) do
    Assert.equal(BEHAVIOR[expected.name], expected.value)
    Assert.equal(MetatileBehavior.ledgeDirection(expected.value), expected.direction)
  end
  Assert.equal(BEHAVIOR.ROCK_CLIMB_NORTH_SOUTH, 75)
  Assert.equal(BEHAVIOR.ROCK_CLIMB_EAST_WEST, 76)
  Assert.equal(MetatileBehavior.fieldAction(75), "rock_climb")
  Assert.equal(MetatileBehavior.fieldAction(76), "rock_climb")
end

function T.ledge_traversal_requires_the_source_direction()
  local ledges = {
    { behavior = 56, direction = "east" },
    { behavior = 57, direction = "west" },
    { behavior = 58, direction = "north" },
    { behavior = 59, direction = "south" },
  }
  for _, ledge in ipairs(ledges) do
    local matching = FieldTraversal.classify({ behavior = ledge.behavior, blocked = true }, ledge.direction)
    Assert.equal(matching.kind, "ledge_jump")
    local wrongDirection = ledge.direction == "east" and "north" or "east"
    local wrong = FieldTraversal.classify({ behavior = ledge.behavior, blocked = true }, wrongDirection)
    Assert.equal(wrong.kind, "blocked")
  end
end

function T.field_actions_are_semantic_even_when_permission_is_blocked()
  for _, behavior in ipairs({ BEHAVIOR.RIVER_WATER, BEHAVIOR.WATERFALL, BEHAVIOR.WHIRLPOOL }) do
    local decision = FieldTraversal.classify({ behavior = behavior, blocked = true }, "east")
    Assert.equal(decision.kind, "field_action")
  end
end

function T.ledge_direction_controls_the_traversal_kind()
  local matching = FieldTraversal.classify({ behavior = BEHAVIOR.JUMP_EAST, blocked = true }, "east")
  Assert.equal(matching.kind, "ledge_jump")
  local wrong = FieldTraversal.classify({ behavior = BEHAVIOR.JUMP_EAST, blocked = false }, "north")
  Assert.equal(wrong.kind, "blocked")
  local ordinary = FieldTraversal.classify({ behavior = 0, blocked = false }, "east")
  Assert.equal(ordinary.kind, "step")
end

function T.omitted_mode_preserves_walking_classification()
  for _, behavior in ipairs({ BEHAVIOR.RIVER_WATER, BEHAVIOR.SEA_WATER }) do
    local decision = FieldTraversal.classify({ behavior = behavior, blocked = false }, "south")
    Assert.equal(decision.kind, "field_action")
    Assert.equal(decision.action, "surf")
  end
end

function T.surfing_permits_connected_water_as_ordinary_steps()
  for _, behavior in ipairs({ BEHAVIOR.RIVER_WATER, BEHAVIOR.SEA_WATER }) do
    local decision = FieldTraversal.classify({ behavior = behavior, blocked = false }, "south", "surfing")
    Assert.equal(decision.kind, "step")
  end
end

function T.surfing_keeps_dedicated_actions_off_ordinary_steps()
  local expectations = {
    { behavior = BEHAVIOR.WATERFALL, action = "waterfall" },
    { behavior = BEHAVIOR.WHIRLPOOL, action = "whirlpool" },
    { behavior = BEHAVIOR.ROCK_CLIMB_NORTH_SOUTH, action = "rock_climb" },
    { behavior = BEHAVIOR.ROCK_CLIMB_EAST_WEST, action = "rock_climb" },
  }
  for _, expected in ipairs(expectations) do
    local decision = FieldTraversal.classify({ behavior = expected.behavior, blocked = false }, "south", "surfing")
    Assert.equal(decision.kind, "field_action")
    Assert.equal(decision.action, expected.action)
  end
end

function T.surfing_initiates_disembark_onto_walkable_shore()
  local decision = FieldTraversal.classify({ behavior = 0, blocked = false }, "north", "surfing")
  Assert.equal(decision.kind, "disembark")
end

function T.surfing_never_steps_onto_blocked_or_ledge_tiles()
  local blocked = FieldTraversal.classify({ behavior = 0, blocked = true }, "north", "surfing")
  Assert.equal(blocked.kind, "blocked")
  local ledge = FieldTraversal.classify({ behavior = BEHAVIOR.JUMP_NORTH, blocked = true }, "north", "surfing")
  Assert.equal(ledge.kind, "blocked")
  local waterBlocked = FieldTraversal.classify({ behavior = BEHAVIOR.SEA_WATER, blocked = true }, "north", "surfing")
  Assert.equal(waterBlocked.kind, "step")
end

function T.unknown_traversal_mode_fails_loudly()
  local err = Assert.throws(function()
    FieldTraversal.classify({ behavior = 0, blocked = false }, "north", "cycling")
  end)
  Assert.notNil(tostring(err):find("traversal mode", 1, true), "the failure must name the traversal mode")
end

return { tests = T }
