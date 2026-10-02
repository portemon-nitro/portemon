-- Pure conservative tile and actor policy for save-editor relocation.

local FieldObjectMovement = require("libs.assets.src.field.FieldObjectMovement")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")

local SaveEditorLocationPolicy = {}

local ALLOWED_BEHAVIORS = {
  [0] = true,
  [MetatileBehavior.BEHAVIOR.TALL_GRASS] = true,
}

local FIXED_KINDS = {
  stationary = true,
  look = true,
  rotate = true,
  spin = true,
}

local MOVING_KINDS = {
  wander = true,
  pattern = true,
  shuttle = true,
}

local function assertInteger(name, value)
  assert(type(value) == "number" and value % 1 == 0, name .. " must be an integer")
end

local function assertBounds(bounds)
  assert(type(bounds) == "table", "map bounds are required")
  assertInteger("mapBounds.minX", bounds.minX)
  assertInteger("mapBounds.maxX", bounds.maxX)
  assertInteger("mapBounds.minZ", bounds.minZ)
  assertInteger("mapBounds.maxZ", bounds.maxZ)
  assert(bounds.minX <= bounds.maxX, "mapBounds X extent is inverted")
  assert(bounds.minZ <= bounds.maxZ, "mapBounds Z extent is inverted")
end

local function assertEvent(event)
  assert(type(event) == "table", "object event must be a table")
  assertInteger("object event mapId", event.mapId)
  assertInteger("objectEventId", event.objectEventId)
  assert(type(event.movementType) == "string", "object event movementType is required")
  assertInteger("object event x", event.x)
  assertInteger("object event z", event.z)
  assertInteger("object event xRange", event.xRange)
  assertInteger("object event yRange", event.yRange)
  assert(event.xRange >= -1, "object event xRange must be at least -1")
  assert(event.yRange >= -1, "object event yRange must be at least -1")
end

local function withinAxis(value, origin, range, minimum, maximum)
  if range == -1 then
    return value >= minimum and value <= maximum
  end
  return math.abs(value - origin) <= range
end

local function occupies(event, movementType, fieldX, fieldZ, mapBounds)
  local profile = FieldObjectMovement.require(movementType)
  if profile.kind == "special" then
    return nil, "unsupported_actor"
  end
  if FIXED_KINDS[profile.kind] then
    if fieldX == event.x and fieldZ == event.z then
      return true
    end
    return false
  end
  if MOVING_KINDS[profile.kind] then
    return withinAxis(fieldX, event.x, event.xRange, mapBounds.minX, mapBounds.maxX)
      and withinAxis(fieldZ, event.z, event.yRange, mapBounds.minZ, mapBounds.maxZ)
  end
  return nil, "unsupported_actor"
end

local function actorReason(facts)
  assertBounds(facts.mapBounds)
  assert(type(facts.events) == "table", "location facts need source object events")
  assert(type(facts.savedActors) == "table", "location facts need saved actors")

  for _, actor in ipairs(facts.savedActors) do
    assert(type(actor) == "table", "saved actor must be a table")
    assertInteger("saved actor mapId", actor.mapId)
    if actor.mapId == facts.mapId and actor.action ~= nil then
      return "actor_motion_active"
    end
  end

  local eventsByMapAndId = {}
  for _, event in ipairs(facts.events) do
    assertEvent(event)
    local eventsById = eventsByMapAndId[event.mapId]
    if eventsById == nil then
      eventsById = {}
      eventsByMapAndId[event.mapId] = eventsById
    end
    assert(eventsById[event.objectEventId] == nil, "source object event identities must be unique per map")
    eventsById[event.objectEventId] = event
    local profile = FieldObjectMovement.require(event.movementType)
    if event.mapId == facts.mapId or profile.kind ~= "special" then
      local occupied, reason = occupies(event, event.movementType, facts.fieldX, facts.fieldZ, facts.mapBounds)
      if reason ~= nil then
        return reason
      end
      if occupied then
        return "possible_actor"
      end
    end
  end

  for _, actor in ipairs(facts.savedActors) do
    assertInteger("saved actor objectEventId", actor.objectEventId)
    assert(type(actor.actorId) == "string", "saved actor actorId is required")
    assert(type(actor.sourceMovementType) == "string", "saved actor sourceMovementType is required")
    assert(type(actor.movementType) == "string", "saved actor movementType is required")
    assertInteger("saved actor fieldX", actor.fieldX)
    assertInteger("saved actor fieldZ", actor.fieldZ)

    local sourceEvents = eventsByMapAndId[actor.mapId]
    local sourceEvent = sourceEvents and sourceEvents[actor.objectEventId]
    if sourceEvent == nil then
      local mapRepresented = actor.mapId == facts.mapId
        or sourceEvents ~= nil
        or (facts.representedMapIds ~= nil and facts.representedMapIds[actor.mapId] == true)
      assert(not mapRepresented, "saved actor source identity has no matching object event")
      if facts.fieldX == actor.fieldX and facts.fieldZ == actor.fieldZ then
        return "possible_actor"
      end
    else
      assert(sourceEvent.movementType == actor.sourceMovementType, "saved actor source movement identity changed")
      if facts.fieldX == actor.fieldX and facts.fieldZ == actor.fieldZ then
        return "possible_actor"
      end
      if actor.movementType ~= sourceEvent.movementType then
        local profile = FieldObjectMovement.require(actor.movementType)
        if actor.mapId == facts.mapId or profile.kind ~= "special" then
          local occupied, reason =
            occupies(sourceEvent, actor.movementType, facts.fieldX, facts.fieldZ, facts.mapBounds)
          if reason ~= nil then
            return reason
          end
          if occupied then
            return "possible_actor"
          end
        end
      end
    end
  end
  return nil
end

---@param facts table<string, unknown>
---@return {selectable: boolean, reason: string?}
function SaveEditorLocationPolicy.classify(facts)
  assert(type(facts) == "table", "location facts are required")
  assertInteger("mapId", facts.mapId)
  assertInteger("fieldX", facts.fieldX)
  assertInteger("fieldZ", facts.fieldZ)
  if facts.coverage ~= true then
    return { selectable = false, reason = "outside_map" }
  end
  if facts.logicalMapMatch ~= true then
    return { selectable = false, reason = "wrong_logical_map" }
  end
  if facts.trigger == "warp" then
    return { selectable = false, reason = "warp" }
  end
  if facts.trigger then
    return { selectable = false, reason = "coordinate_trigger" }
  end

  local collision = facts.collision
  assert(type(collision) == "table", "collision facts are required")
  assert(type(collision.blocked) == "boolean", "collision blocked state is required")
  assertInteger("collision behavior", collision.behavior)
  if collision.blocked then
    return { selectable = false, reason = "blocked" }
  end
  if not ALLOWED_BEHAVIORS[collision.behavior] then
    return { selectable = false, reason = "special_terrain" }
  end

  local surface = facts.surface
  if surface == nil then
    return { selectable = false, reason = "no_surface" }
  end
  assert(type(surface) == "table", "surface facts must be a table")
  if surface.rejection ~= nil then
    assert(
      surface.rejection == "no_surface" or surface.rejection == "ambiguous_surface",
      "unexpected surface rejection"
    )
    return { selectable = false, reason = surface.rejection }
  end
  if surface.surfaceId == nil then
    return { selectable = false, reason = "no_surface" }
  end
  assertInteger("surfaceId", surface.surfaceId)
  assert(type(surface.worldY) == "number", "surface worldY is required")
  assert(type(surface.terrainDependencyHash) == "string", "surface terrain dependency hash is required")

  local reason = actorReason(facts)
  if reason ~= nil then
    return { selectable = false, reason = reason }
  end
  return { selectable = true }
end

return SaveEditorLocationPolicy
