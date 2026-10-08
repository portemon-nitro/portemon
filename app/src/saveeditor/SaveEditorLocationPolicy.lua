-- Pure conservative tile and actor policy for save-editor relocation.

local FieldObjectMovement = require("libs.assets.src.field.FieldObjectMovement")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")

local SaveEditorLocationPolicy = {}

---@class SaveEditorLocationPolicyEvent
---@field mapId integer
---@field objectEventId integer
---@field movementType string
---@field x integer
---@field z integer
---@field xRange integer
---@field yRange integer

---@class SaveEditorLocationClassificationTask
---@field facts table<string, unknown>
---@field phase string?
---@field actorIndex integer?
---@field eventIndex integer?
---@field eventsByMapAndId table<integer, table<integer, SaveEditorLocationPolicyEvent>>?
---@field eventRejection string?
---@field ambiguousSourceActor boolean?
---@field done boolean
---@field result {selectable: boolean, reason: string?}?

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

local function baseResult(facts)
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
  return nil
end

local function finish(task, reason)
  task.done = true
  task.result = { selectable = reason == nil, reason = reason }
end

local function sameOccupancy(left, right)
  return left.movementType == right.movementType
    and left.x == right.x
    and left.z == right.z
    and left.xRange == right.xRange
    and left.yRange == right.yRange
end

---@param facts table<string, unknown>
---@return SaveEditorLocationClassificationTask
function SaveEditorLocationPolicy.beginClassification(facts)
  local result = baseResult(facts)
  if result ~= nil then
    return { done = true, result = result }
  end
  if facts.ambiguousSourceActor == true then
    return { done = true, result = { selectable = false, reason = "ambiguous_source_actor" } }
  end
  assertBounds(facts.mapBounds)
  assert(type(facts.events) == "table", "location facts need source object events")
  assert(type(facts.savedActors) == "table", "location facts need saved actors")
  return {
    facts = facts,
    phase = "busy_actors",
    actorIndex = 1,
    eventIndex = 1,
    eventsByMapAndId = {},
    done = false,
    result = nil,
  }
end

local function savedActorReason(task, actor)
  local facts = task.facts
  assertInteger("saved actor objectEventId", actor.objectEventId)
  assert(type(actor.actorId) == "string", "saved actor actorId is required")
  assert(type(actor.sourceMovementType) == "string", "saved actor sourceMovementType is required")
  assert(type(actor.movementType) == "string", "saved actor movementType is required")
  assertInteger("saved actor fieldX", actor.fieldX)
  assertInteger("saved actor fieldZ", actor.fieldZ)
  local sourceEvents = task.eventsByMapAndId[actor.mapId]
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
        local occupied, reason = occupies(sourceEvent, actor.movementType, facts.fieldX, facts.fieldZ, facts.mapBounds)
        if reason ~= nil then
          return reason
        end
        if occupied then
          return "possible_actor"
        end
      end
    end
  end
  return nil
end

---@param task SaveEditorLocationClassificationTask
---@param maxVisits integer
---@return integer visits, {selectable: boolean, reason: string?}?
function SaveEditorLocationPolicy.advanceClassification(task, maxVisits)
  assert(type(task) == "table" and type(task.done) == "boolean", "classification task is required")
  assertInteger("classification visit budget", maxVisits)
  assert(maxVisits >= 0, "classification visit budget must be non-negative")
  local facts = task.facts
  local visits = 0
  while not task.done do
    if task.phase == "busy_actors" then
      local actor = facts.savedActors[task.actorIndex]
      if actor == nil then
        task.phase = "events"
      else
        if visits >= maxVisits then
          break
        end
        assert(type(actor) == "table", "saved actor must be a table")
        assertInteger("saved actor mapId", actor.mapId)
        if actor.mapId == facts.mapId and actor.action ~= nil then
          finish(task, "actor_motion_active")
        else
          task.actorIndex = task.actorIndex + 1
        end
        visits = visits + 1
      end
    elseif task.phase == "events" then
      local event = facts.events[task.eventIndex]
      if event == nil then
        if task.ambiguousSourceActor then
          finish(task, "ambiguous_source_actor")
        elseif task.eventRejection ~= nil then
          finish(task, task.eventRejection)
        else
          task.phase = "saved_actors"
          task.actorIndex = 1
        end
      else
        if visits >= maxVisits then
          break
        end
        assertEvent(event)
        local eventsById = task.eventsByMapAndId[event.mapId]
        if eventsById == nil then
          eventsById = {}
          task.eventsByMapAndId[event.mapId] = eventsById
        end
        local previous = eventsById[event.objectEventId]
        if previous ~= nil then
          if not sameOccupancy(previous, event) then
            task.ambiguousSourceActor = true
          end
          task.eventIndex = task.eventIndex + 1
        else
          eventsById[event.objectEventId] = event
          local profile = FieldObjectMovement.require(event.movementType)
          if event.mapId == facts.mapId or profile.kind ~= "special" then
            local occupied, reason = occupies(event, event.movementType, facts.fieldX, facts.fieldZ, facts.mapBounds)
            if reason ~= nil then
              task.eventRejection = task.eventRejection or reason
            elseif occupied then
              task.eventRejection = task.eventRejection or "possible_actor"
            end
          end
          task.eventIndex = task.eventIndex + 1
        end
        visits = visits + 1
      end
    elseif task.phase == "saved_actors" then
      local actor = facts.savedActors[task.actorIndex]
      if actor == nil then
        finish(task, nil)
      else
        if visits >= maxVisits then
          break
        end
        local reason = savedActorReason(task, actor)
        if reason ~= nil then
          finish(task, reason)
        else
          task.actorIndex = task.actorIndex + 1
        end
        visits = visits + 1
      end
    else
      error("invalid classification task phase: " .. tostring(task.phase))
    end
  end
  return visits, task.done and task.result or nil
end

---@param facts table<string, unknown>
---@return {selectable: boolean, reason: string?}
function SaveEditorLocationPolicy.classify(facts)
  local task = SaveEditorLocationPolicy.beginClassification(facts)
  while not task.done do
    SaveEditorLocationPolicy.advanceClassification(task, 4096)
  end
  return assert(task.result)
end

return SaveEditorLocationPolicy
