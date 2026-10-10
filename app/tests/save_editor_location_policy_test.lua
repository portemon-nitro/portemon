-- Conservative editor placement admits only facts proven by its source owners.

local Assert = require("tests.support.Assert")
local FieldObjectMovement = require("libs.assets.src.field.FieldObjectMovement")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")

local T = { tests = {} }

local function policy()
  local loaded, value = pcall(require, "app.src.saveeditor.SaveEditorLocationPolicy")
  Assert.isTrue(loaded, "ordinary unique-surface ground must be classified by the editor placement policy")
  return value
end

local function facts(overrides)
  local result = {
    mapId = 12,
    fieldX = 32,
    fieldZ = 64,
    coverage = true,
    logicalMapMatch = true,
    collision = { blocked = false, behavior = 0 },
    surface = { surfaceId = 3, worldY = 0, terrainDependencyHash = "destination-window" },
    trigger = false,
    occupied = false,
    events = {},
    savedActors = {},
    mapBounds = { minX = 0, maxX = 100, minZ = 0, maxZ = 100 },
  }
  for key, value in pairs(overrides or {}) do
    result[key] = value
  end
  return result
end

local function event(overrides)
  local result = {
    mapId = 12,
    objectEventId = 7,
    movementType = "stationary",
    x = 10,
    z = 10,
    xRange = -1,
    yRange = -1,
    eventFlag = 0,
  }
  for key, value in pairs(overrides or {}) do
    result[key] = value
  end
  return result
end

local function actorAt(fieldX, fieldZ, sourceEvent, overrides)
  local result = {
    actorId = "object:7",
    mapId = 12,
    objectEventId = sourceEvent.objectEventId,
    sourceMovementType = sourceEvent.movementType,
    movementType = sourceEvent.movementType,
    fieldX = fieldX,
    fieldZ = fieldZ,
  }
  for key, value in pairs(overrides or {}) do
    result[key] = value
  end
  return result
end

function T.tests.classification_fails_closed_and_does_not_change_source_facts()
  local LocationPolicy = policy()
  local source = facts()
  local before = {
    collision = { blocked = source.collision.blocked, behavior = source.collision.behavior },
    surface = {
      surfaceId = source.surface.surfaceId,
      worldY = source.surface.worldY,
      terrainDependencyHash = source.surface.terrainDependencyHash,
    },
  }
  local allowed = LocationPolicy.classify(source)
  Assert.isTrue(allowed.selectable, "normal unoccupied ground with one resolved surface is selectable")
  Assert.deepEqual(source.collision, before.collision, "classification leaves copied collision facts unchanged")
  Assert.deepEqual(source.surface, before.surface, "classification leaves the sampled surface unchanged")

  for _, case in ipairs({
    { facts = facts({ coverage = false }), reason = "outside_map" },
    { facts = facts({ logicalMapMatch = false }), reason = "wrong_logical_map" },
    { facts = facts({ collision = { blocked = true, behavior = 0 } }), reason = "blocked" },
    { facts = facts({ collision = { blocked = false, behavior = 7 } }), reason = "special_terrain" },
    { facts = facts({ collision = { blocked = false, behavior = 255 } }), reason = "special_terrain" },
    { facts = facts({ surface = { rejection = "ambiguous_surface" } }), reason = "ambiguous_surface" },
    { facts = facts({ trigger = "warp" }), reason = "warp" },
    { facts = facts({ trigger = "coordinate_trigger" }), reason = "coordinate_trigger" },
  }) do
    local result = LocationPolicy.classify(case.facts)
    Assert.isFalse(result.selectable, case.reason .. " must not be a selectable editor destination")
    Assert.equal(result.reason, case.reason, "placement refusal names its physical cause")
  end

  local noSurface = facts()
  noSurface.surface = nil
  Assert.equal(LocationPolicy.classify(noSurface).reason, "no_surface")
end

function T.tests.only_normal_ground_and_tall_grass_are_allowed()
  local LocationPolicy = policy()

  for _, behavior in ipairs({ 0, MetatileBehavior.BEHAVIOR.TALL_GRASS }) do
    local result = LocationPolicy.classify(facts({
      collision = { blocked = false, behavior = behavior },
    }))
    Assert.isTrue(result.selectable, "the ordinary-placement allowlist includes supported ground behavior")
  end

  local result = LocationPolicy.classify(facts({
    collision = { blocked = true, behavior = 0 },
  }))
  Assert.isFalse(result.selectable, "blocked collision overrides an otherwise allowed behavior")
  Assert.equal(result.reason, "blocked")
end

function T.tests.exact_occupancy_decision_ignores_movement_speculation()
  local LocationPolicy = policy()
  local roamer = event({ movementType = "walk_back_and_forth", x = 50, z = 50, xRange = -1, yRange = 0 })
  local special = event({ movementType = "player", x = 90, z = 90 })
  local sourceEvent = event({ movementType = "stationary", x = 10, z = 10 })
  local active = actorAt(80, 80, sourceEvent, { action = { kind = "walk" } })
  local crowded = facts({
    fieldX = 20,
    fieldZ = 20,
    occupied = false,
    events = { roamer, special, sourceEvent },
    savedActors = { active },
  })
  Assert.isTrue(
    LocationPolicy.classify(crowded).selectable,
    "movement ranges, special profiles and in-flight actions never refuse an unoccupied tile"
  )

  local reserved = facts({
    fieldX = 20,
    fieldZ = 20,
    occupied = true,
    events = { roamer, special, sourceEvent },
    savedActors = { active },
  })
  local refused = LocationPolicy.classify(reserved)
  Assert.isFalse(refused.selectable, "a known occupied tile is never a selectable destination")
  Assert.equal(refused.reason, "possible_actor", "exact occupancy refuses with the actor reason")
end

function T.tests.missing_occupancy_facts_fail_closed()
  local LocationPolicy = policy()
  local unprepared = facts()
  unprepared.occupied = nil
  local ok, diagnosis = pcall(LocationPolicy.classify, unprepared)
  Assert.isFalse(ok, "a tile without exact occupancy facts is never admitted by default")
  Assert.isTrue(
    type(diagnosis) == "string" and diagnosis:find("occupancy", 1, true) ~= nil,
    "a missing occupancy fact fails with its cause"
  )
end

function T.tests.strict_placement_gates_keep_their_reasons_with_exact_occupancy()
  local LocationPolicy = policy()
  local function ground(overrides)
    local base = facts({ occupied = false })
    for key, value in pairs(overrides or {}) do
      base[key] = value
    end
    return base
  end

  Assert.isTrue(LocationPolicy.classify(ground()).selectable, "ordinary ground with no occupant stays selectable")
  Assert.isTrue(
    LocationPolicy.classify(
      ground({ collision = { blocked = false, behavior = MetatileBehavior.BEHAVIOR.TALL_GRASS } })
    ).selectable,
    "tall grass with no occupant stays selectable"
  )

  for _, case in ipairs({
    { facts = ground({ coverage = false }), reason = "outside_map" },
    { facts = ground({ logicalMapMatch = false }), reason = "wrong_logical_map" },
    { facts = ground({ trigger = "warp" }), reason = "warp" },
    { facts = ground({ trigger = "coordinate_trigger" }), reason = "coordinate_trigger" },
    { facts = ground({ collision = { blocked = true, behavior = 0 } }), reason = "blocked" },
    { facts = ground({ collision = { blocked = false, behavior = 7 } }), reason = "special_terrain" },
    { facts = ground({ surface = { rejection = "ambiguous_surface" } }), reason = "ambiguous_surface" },
  }) do
    local result = LocationPolicy.classify(case.facts)
    Assert.isFalse(result.selectable, case.reason .. " remains a hard placement refusal")
    Assert.equal(result.reason, case.reason, "placement refusal still names its physical cause")
  end
  local missing = ground()
  missing.surface = nil
  Assert.equal(LocationPolicy.classify(missing).reason, "no_surface", "a missing surface remains unplaceable")

  local occupied = LocationPolicy.classify(ground({ fieldX = 10, fieldZ = 10, occupied = true }))
  Assert.isFalse(occupied.selectable, "a known occupied tile is never a selectable destination")
  Assert.equal(occupied.reason, "possible_actor", "exact occupancy refuses with the actor reason")
end

function T.tests.only_exact_actor_positions_block_placement()
  local LocationPolicy = policy()
  local function ground(overrides)
    local base = facts({ occupied = false })
    for key, value in pairs(overrides or {}) do
      base[key] = value
    end
    return base
  end

  local exact = LocationPolicy.classify(ground({ fieldX = 10, fieldZ = 10, occupied = true }))
  Assert.equal(exact.reason, "possible_actor", "a known occupied tile refuses even on ordinary ground")

  local roamer = event({ movementType = "walk_back_and_forth", x = 50, z = 50, xRange = -1, yRange = 0 })
  Assert.isTrue(
    LocationPolicy.classify(ground({ fieldX = 99, fieldZ = 50, events = { roamer } })).selectable,
    "a free tile inside a wandering range is not reserved by speculation"
  )

  local special = event({ movementType = "player", x = 90, z = 90 })
  Assert.isTrue(
    LocationPolicy.classify(ground({ fieldX = 0, fieldZ = 0, events = { special } })).selectable,
    "an unusual movement profile never rejects a distant tile"
  )

  local sourceEvent = event({ movementType = "stationary", x = 10, z = 10 })
  local active = actorAt(80, 80, sourceEvent, { action = { kind = "walk" } })
  Assert.isTrue(
    LocationPolicy.classify(ground({ fieldX = 20, fieldZ = 20, events = { sourceEvent }, savedActors = { active } })).selectable,
    "an in-flight actor action never refuses an unrelated destination"
  )

  local hidden = event({ movementType = "stationary", x = 15, z = 16, eventFlag = 123 })
  Assert.equal(
    LocationPolicy.classify(ground({ fieldX = 15, fieldZ = 16, events = { hidden }, occupied = true })).reason,
    "possible_actor",
    "a hidden source tile remains reserved at its exact position"
  )
end

function T.tests.classification_is_a_single_synchronous_decision()
  local LocationPolicy = policy()
  local events = {}
  local actors = {}
  for index = 1, 300 do
    events[index] = event({ objectEventId = index, x = 0x1000 + index, z = 0x1000 })
    actors[index] = {
      actorId = "unrepresented:" .. index,
      mapId = 1000 + index,
      objectEventId = 1,
      sourceMovementType = "stationary",
      movementType = "stationary",
      fieldX = 0x2000 + index,
      fieldZ = 0x2000,
    }
  end
  local source = facts({ events = events, savedActors = actors })
  local first = LocationPolicy.classify(source)
  Assert.isTrue(first.selectable, "a large unrelated event collection never refuses an unoccupied tile")
  local second = LocationPolicy.classify(facts({ occupied = true, events = events, savedActors = actors }))
  Assert.equal(second.reason, "possible_actor", "exact occupancy decides without scanning event collections")
  Assert.deepEqual(source.events, events, "classification leaves borrowed event collections unchanged")
end

return T
