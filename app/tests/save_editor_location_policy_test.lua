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

function T.tests.source_actor_profiles_produce_conservative_tile_extents()
  local LocationPolicy = policy()

  local fixed = event({ movementType = "look_around", x = 10, z = 10 })
  Assert.equal(FieldObjectMovement.require(fixed.movementType).kind, "look")
  local fixedActor = LocationPolicy.classify(facts({ fieldX = 10, fieldZ = 10, events = { fixed } }))
  Assert.equal(fixedActor.reason, "possible_actor", "look profile reserves its fixed source tile")
  Assert.isTrue(
    LocationPolicy.classify(facts({ fieldX = 11, fieldZ = 10, events = { fixed } })).selectable,
    "fixed look profile does not reserve its unused source range"
  )

  local rotating = event({ movementType = "rotate_clockwise", x = 20, z = 20 })
  local spinning = event({ movementType = "vs_seeker_spin", objectEventId = 8, x = 30, z = 30 })
  Assert.equal(FieldObjectMovement.require(rotating.movementType).kind, "rotate")
  Assert.equal(FieldObjectMovement.require(spinning.movementType).kind, "spin")
  for _, fixedProfile in ipairs({ rotating, spinning }) do
    Assert.equal(
      LocationPolicy.classify(facts({ fieldX = fixedProfile.x, fieldZ = fixedProfile.z, events = { fixedProfile } })).reason,
      "possible_actor",
      "rotate and spin profiles reserve their fixed source tile"
    )
    Assert.isTrue(
      LocationPolicy.classify(
        facts({ fieldX = fixedProfile.x + 1, fieldZ = fixedProfile.z, events = { fixedProfile } })
      ).selectable,
      "rotate and spin profiles do not reserve unused ranges"
    )
  end

  local bounded = event({ movementType = "wander_around", x = 40, z = 40, xRange = 2, yRange = 1 })
  Assert.equal(FieldObjectMovement.require(bounded.movementType).kind, "wander")
  Assert.equal(
    LocationPolicy.classify(facts({ fieldX = 42, fieldZ = 41, events = { bounded } })).reason,
    "possible_actor",
    "moving source ranges include their inclusive X and Z limits"
  )
  Assert.isTrue(
    LocationPolicy.classify(facts({ fieldX = 40, fieldZ = 42, events = { bounded } })).selectable,
    "the event yRange bounds field Z and does not create a zRange"
  )

  local unboundedX = event({ movementType = "walk_back_and_forth", x = 50, z = 50, xRange = -1, yRange = 0 })
  Assert.equal(FieldObjectMovement.require(unboundedX.movementType).kind, "shuttle")
  Assert.equal(
    LocationPolicy.classify(facts({ fieldX = 99, fieldZ = 50, events = { unboundedX } })).reason,
    "possible_actor",
    "a moving -1 X range extends to the supplied map bound"
  )
  Assert.isTrue(
    LocationPolicy.classify(facts({ fieldX = 50, fieldZ = 51, events = { unboundedX } })).selectable,
    "a bounded Z range remains bounded when X is unbounded"
  )

  local unboundedZ = event({ movementType = "walk_north_east_west_south", x = 60, z = 60, xRange = 0, yRange = -1 })
  Assert.equal(FieldObjectMovement.require(unboundedZ.movementType).kind, "pattern")
  Assert.equal(
    LocationPolicy.classify(facts({ fieldX = 60, fieldZ = 0, events = { unboundedZ } })).reason,
    "possible_actor",
    "a moving -1 yRange extends field Z to the supplied map bound"
  )

  local stationary = event({ movementType = "stationary", objectEventId = 9, x = 70, z = 70 })
  Assert.isTrue(
    LocationPolicy.classify(facts({ fieldX = 10, fieldZ = 70, events = { stationary } })).selectable,
    "stationary source range -1 does not blanket-disable its map"
  )
end

function T.tests.saved_actor_positions_and_changed_profiles_extend_source_mask()
  local LocationPolicy = policy()
  local sourceEvent = event({ movementType = "stationary", x = 10, z = 10 })
  local saved = actorAt(80, 80, sourceEvent, { movementType = "wander_around" })
  Assert.equal(FieldObjectMovement.require(saved.movementType).kind, "wander")

  local sourceTile = LocationPolicy.classify(facts({ fieldX = 10, fieldZ = 10, events = { sourceEvent } }))
  Assert.equal(sourceTile.reason, "possible_actor", "source position remains excluded after the actor moves")
  local movedTile = LocationPolicy.classify(facts({
    fieldX = 80,
    fieldZ = 80,
    events = { sourceEvent },
    savedActors = { saved },
  }))
  Assert.equal(movedTile.reason, "possible_actor", "saved moved actor position is excluded")
  Assert.equal(
    LocationPolicy.classify(facts({
      fieldX = 82,
      fieldZ = 80,
      events = { sourceEvent },
      savedActors = { saved },
    })).reason,
    "possible_actor",
    "changed saved movement profile contributes its current conservative range"
  )
  Assert.isTrue(
    LocationPolicy.classify(facts({ fieldX = 82, fieldZ = 80, events = { sourceEvent } })).selectable,
    "without a saved movement change the source profile remains stationary"
  )

  local active = actorAt(80, 80, sourceEvent, { action = { kind = "walk" } })
  Assert.equal(
    LocationPolicy.classify(facts({
      fieldX = 10,
      fieldZ = 10,
      events = { sourceEvent },
      savedActors = { active },
    })).reason,
    "actor_motion_active",
    "an in-flight saved actor action refuses every destination on its map"
  )
end

function T.tests.represented_neighbor_actor_is_masked_without_blocking_on_its_action()
  local LocationPolicy = policy()
  local selectedEvent = event({ mapId = 12, movementType = "stationary", x = 10, z = 10 })
  local neighborEvent = event({ mapId = 13, objectEventId = 8, movementType = "stationary", x = 90, z = 90 })
  local neighborActor = actorAt(80, 80, neighborEvent, { mapId = 13, action = { kind = "walk" } })
  local sharedFacts = {
    mapId = 12,
    fieldX = 80,
    fieldZ = 80,
    coverage = true,
    logicalMapMatch = true,
    collision = { blocked = false, behavior = 0 },
    surface = { surfaceId = 3, worldY = 0, terrainDependencyHash = "destination-window" },
    trigger = false,
    events = { selectedEvent, neighborEvent },
    savedActors = { neighborActor },
    mapBounds = { minX = 0, maxX = 100, minZ = 0, maxZ = 100 },
  }
  Assert.equal(
    LocationPolicy.classify(sharedFacts).reason,
    "possible_actor",
    "a represented neighbor source position remains part of the physical occupancy mask"
  )

  sharedFacts.fieldX, sharedFacts.fieldZ = 20, 20
  Assert.isTrue(
    LocationPolicy.classify(sharedFacts).selectable,
    "a neighbor actor action does not block destinations on the selected map"
  )
end

function T.tests.unrepresented_saved_actor_only_blocks_its_saved_global_position()
  local LocationPolicy = policy()
  local selectedEvent = event({ mapId = 12, x = 10, z = 10 })
  local unrepresentedEvent = event({ mapId = 14, objectEventId = 9, x = 90, z = 90 })
  local unrepresentedActor = actorAt(80, 80, unrepresentedEvent, { mapId = 14 })
  local sharedFacts = facts({ events = { selectedEvent }, savedActors = { unrepresentedActor } })

  Assert.isTrue(
    LocationPolicy.classify(sharedFacts).selectable,
    "a saved actor without a represented source only reserves its known saved position"
  )
  sharedFacts.fieldX, sharedFacts.fieldZ = 80, 80
  Assert.equal(
    LocationPolicy.classify(sharedFacts).reason,
    "possible_actor",
    "an unrepresented actor's known global position remains excluded"
  )
end

function T.tests.special_actor_fails_closed_and_flag_visibility_does_not_shrink_source_mask()
  local LocationPolicy = policy()
  local special = event({ movementType = "player", x = 90, z = 90 })
  Assert.equal(FieldObjectMovement.require(special.movementType).kind, "special")
  local result = LocationPolicy.classify(facts({ fieldX = 0, fieldZ = 0, events = { special } }))
  Assert.equal(result.reason, "unsupported_actor", "unbounded special movement disables placement in its map")

  for _, eventFlag in ipairs({ 0, 123 }) do
    local sourceEvent = event({ movementType = "stationary", x = 15, z = 16, eventFlag = eventFlag })
    Assert.equal(
      LocationPolicy.classify(facts({ fieldX = 15, fieldZ = 16, events = { sourceEvent } })).reason,
      "possible_actor",
      "a source event remains in the obstacle mask independent of its progress flag"
    )
  end
end

function T.tests.conflicting_source_actor_identities_fail_closed_without_precedence()
  local LocationPolicy = policy()
  local first = event({ movementType = "stationary", x = 10, z = 10 })
  local conflicting = event({ movementType = "stationary", x = 11, z = 10 })
  local saved = actorAt(10, 10, first)
  local ok, result = pcall(function()
    return LocationPolicy.classify(facts({
      fieldX = 12,
      fieldZ = 12,
      events = { first, conflicting },
      savedActors = { saved },
    }))
  end)

  Assert.isTrue(ok, "conflicting external source identities must not escape as a raw assertion")
  Assert.isFalse(result.selectable, "an ambiguous actor identity cannot authorize placement")
  Assert.equal(result.reason, "ambiguous_source_actor", "the source ambiguity has a stable refusal reason")
end

function T.tests.staged_classification_bounds_each_actor_and_event_advance()
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
  local expected = LocationPolicy.classify(source)
  local task = LocationPolicy.beginClassification(source)
  local totalVisits = 0
  while not task.done do
    local visits = LocationPolicy.advanceClassification(task, 17)
    Assert.isTrue(visits <= 17, "one staged policy advance never visits more than its supplied budget")
    totalVisits = totalVisits + visits
  end
  Assert.isTrue(totalVisits >= #events + #actors * 2, "all retained policy passes charge their array visits")
  Assert.deepEqual(task.result, expected, "staged classification preserves the synchronous policy result")
end

return T
