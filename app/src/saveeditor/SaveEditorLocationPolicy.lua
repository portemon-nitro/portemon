-- Pure single-point placement policy for save-editor relocation.
--
-- The caller prepares one tile fact record (coverage, logical identity,
-- trigger, collision, exact occupancy, sampled surface) and this module maps
-- it to a placement decision. Actor occupancy is an exact prepared fact:
-- this policy never interprets movement profiles or wandering ranges.

local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")
local TransitionTrigger = require("libs.hgss.src.transition.TransitionTrigger")

local SaveEditorLocationPolicy = {}

-- Ice and sliding behavior values come from
-- pret/pokeheartgold/include/constants/metatile_behavior.h.
local FORCED_MOVEMENT_BEHAVIORS = {
  [32] = true, -- TILE_BEHAVIOR_ICE
  [64] = true, -- TILE_BEHAVIOR_SLIDE_EAST
  [65] = true, -- TILE_BEHAVIOR_SLIDE_WEST
  [66] = true, -- TILE_BEHAVIOR_SLIDE_NORTH
  [67] = true, -- TILE_BEHAVIOR_SLIDE_SOUTH
  [77] = true, -- TILE_BEHAVIOR_STOP_SLIDING
  [255] = true, -- TILE_BEHAVIOR_NONE
}

local function assertInteger(name, value)
  assert(type(value) == "number" and value % 1 == 0, name .. " must be an integer")
end

---@param collision {blocked: boolean, behavior: integer}
---@return "blocked"|"special_terrain"|nil
function SaveEditorLocationPolicy.terrainRejection(collision)
  assert(type(collision) == "table", "collision facts are required")
  assert(type(collision.blocked) == "boolean", "collision blocked state is required")
  assertInteger("collision behavior", collision.behavior)
  if collision.blocked then
    return "blocked"
  end

  local behavior = collision.behavior
  if
    MetatileBehavior.fieldAction(behavior)
    or MetatileBehavior.ledgeDirection(behavior)
    or TransitionTrigger.classify(behavior)
    or FORCED_MOVEMENT_BEHAVIORS[behavior]
  then
    return "special_terrain"
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
  local terrainRejection = SaveEditorLocationPolicy.terrainRejection(collision)
  if terrainRejection then
    return { selectable = false, reason = terrainRejection }
  end

  assert(type(facts.occupied) == "boolean", "exact actor occupancy facts are required")
  if facts.occupied then
    return { selectable = false, reason = "possible_actor" }
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
  return { selectable = true }
end

return SaveEditorLocationPolicy
