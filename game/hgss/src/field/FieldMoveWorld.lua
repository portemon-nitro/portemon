-- Field-task world adapter: binds executable field-move plans to the
-- existing world owners. Borrows the actor manager, event state, map
-- source, player facade, profile, weather service, and reaction dispatch
-- as complete injected ports; missing ports fail construction, never
-- inference. Removal changes presence and collision together (flag path
-- where the source event defines one, sparse override otherwise);
-- pushes validate both destinations before motion; Flash illuminates
-- through weather while the chamber dispatches its source reaction.
-- Commit-time revalidation turns drift into reported failure, never
-- retargeting. Game-side module: never imports producer code.

local Errors = require("libs.errors.src.Errors")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local FieldMoveContext = require("game.hgss.src.field.FieldMoveContext")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")
local ScriptErrors = require("libs.script.src.errors")
local SurfaceResolver = require("libs.hgss.src.world.SurfaceResolver")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local FLASH_FLAG_ID = assert(FieldScriptSymbols.flagsByName.FLAG_SYS_FLASH, "flash flag identity required")

-- The lit-cave weather preset: the generated weather catalog rewrites
-- weather 11 to 12 on the flash flag (weather_flag_override), and the
-- existing flash script effect changes to the same preset. Cited here
-- once; gameplay carries no other weather literal.
local FLASH_LIT_WEATHER_ID = 12

local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")

-- Boulder pushes walk at the slow cadence through the existing calibration,
-- so actor and player motion share one tick count with scripted walks.
local PUSH_TICKS = MovementCalibration.actionTicks({ action = "walk", speed = "slow" })

-- Planned traversal steps ride the ordinary walk cadence through the
-- existing scripted-motion owner; exact DS cinematic timing is not claimed.
local TRAVERSE_TICKS = MovementCalibration.actionTicks({ action = "walk", speed = "normal" })

-- Closed traversal plan kinds produced by planTraversal. Only surf entry
-- and disembark change the avatar; falls and climbs hold their mode while
-- the segments run.
local SURF_ENTER = "surf_enter"
local DISEMBARK = "disembark"
local WATERFALL = "waterfall"
local WHIRLPOOL = "whirlpool"
local ROCK_CLIMB = "rock_climb"

local TERMINAL_AVATAR = {
  [SURF_ENTER] = "surfing",
  [DISEMBARK] = "walking",
}

-- Safety bound on planned path length: traversal paths run straight lines
-- that cannot revisit tiles, so this caps runaway searches, never honest
-- geography.
local MAX_TRAVERSAL_SEGMENTS = 64

local DIRECTION_DELTAS = {
  north = { fieldX = 0, fieldZ = -1 },
  south = { fieldX = 0, fieldZ = 1 },
  west = { fieldX = -1, fieldZ = 0 },
  east = { fieldX = 1, fieldZ = 0 },
}

---@class FieldMoveWorld
---@field private _actors table<string, unknown>
---@field private _events table<string, unknown>
---@field private _maps table<string, unknown>
---@field private _player table<string, unknown>
---@field private _profile table<string, unknown>
---@field private _weather table<string, unknown>
---@field private _reactions table<string, unknown>
local FieldMoveWorld = {}
FieldMoveWorld.__index = FieldMoveWorld

local function requirePort(ports, name, methods)
  local port = ports[name]
  assert(type(port) == "table", "field world requires the " .. name .. " port")
  for _, method in ipairs(methods or {}) do
    assert(type(port[method]) == "function", "field world port " .. name .. " must implement " .. method)
  end
  return port
end

---@param ports table<string, unknown> complete injected world ports
---@return FieldMoveWorld
function FieldMoveWorld.new(ports)
  assert(type(ports) == "table", "field world requires its ports")
  local world = setmetatable({
    _actors = requirePort(ports, "actors", {
      "getActor",
      "actorsOf",
      "getPosition",
      "getCollisionAt",
      "beginScriptedAction",
      "advanceScriptedAction",
      "commitScriptedAction",
      "cancelScriptedMovement",
      "isScriptedMoving",
      "removePresence",
      "syncEventStateChanges",
    }),
    _events = requirePort(ports, "events", { "setFlag", "isFlagSet" }),
    _maps = requirePort(ports, "maps", { "current", "runtimeMap" }),
    _player = requirePort(ports, "player", {
      "position",
      "facing",
      "beginScriptedAction",
      "advanceScriptedAction",
      "commitScriptedAction",
      "cancelScriptedMovement",
      "isScriptedMoving",
      "queueAvatarTransition",
      "applyAvatarTransitions",
    }),
    _profile = requirePort(ports, "profile", {}),
    _weather = requirePort(ports, "weather", { "change" }),
    _reactions = requirePort(ports, "reactions", { "dispatch" }),
  }, FieldMoveWorld)
  assert(type(world._profile.badges) == "number", "field world profile must carry its badge mask")
  assert(type(world._maps:current()) == "table", "field world maps must describe the live map")
  return world
end

-- Validate live service reads into the copied read-only context record the
-- pure eligibility checks consume. Gameplay carries no producer data.
---@param sources table<string, unknown>
---@return table<string, unknown>
function FieldMoveWorld:captureContext(sources)
  return FieldMoveContext.capture(sources)
end

---@param plan table<string, unknown>
---@return table<string, unknown>
local function planTarget(plan)
  local target = assert(plan.target, "field plans carry their target")
  assert(type(target.actorId) == "string" and target.actorId ~= "", "field targets need an identity")
  return target
end

-- Revalidate a plan against the live world before commit: a removed
-- actor, an obstacle-kind change, or a map change reports stale or
-- not_here instead of affecting another object. Admission-time facing is
-- never rechecked: the player may have turned since the queue.
---@param plan table<string, unknown>
---@return table<string, unknown>? nil when valid, else a Decision
function FieldMoveWorld:validateTarget(plan)
  assert(type(plan) == "table", "validation requires a plan")
  local live = self._maps:current()
  assert(type(live.id) == "number", "live map needs its identity")
  if plan.mapId ~= nil and plan.mapId ~= live.id then
    return { kind = "stale" }
  end
  local target = plan.target
  if target == nil then
    return nil
  end
  local actor = self._actors:getActor(target.actorId)
  if actor == nil then
    return { kind = "stale" }
  end
  if target.obstacleKind ~= nil then
    local event = actor.sourceEvent
    local kind = event and event.obstacleKind or nil
    if kind ~= target.obstacleKind then
      return { kind = "not_here" }
    end
  end
  return nil
end

-- Name the obstacle actor ahead of the player, if any: same tile and same
-- elevation through live actors, without surface-identity inference.
-- Nil for empty tiles and non-obstacles.
---@return table<string, unknown>? { actorId, obstacleKind, mapId }
function FieldMoveWorld:resolveFacingTarget()
  local position = self._player:position()
  assert(type(position.fieldX) == "number" and type(position.fieldZ) == "number", "player needs its tile")
  local facing = self._player:facing()
  local delta = DIRECTION_DELTAS[facing]
  if delta == nil then
    return nil
  end
  local live = self._maps:current()
  local wantX, wantZ = position.fieldX + delta.fieldX, position.fieldZ + delta.fieldZ
  for _, actor in ipairs(self._actors:actorsOf(live.id)) do
    local at = actor:getFieldPosition()
    if at.fieldX == wantX and at.fieldZ == wantZ then
      local world = actor:getWorldPosition()
      if position.worldY == nil or world.y == nil or world.y == position.worldY then
        local event = actor.sourceEvent
        local obstacleKind = event and event.obstacleKind or nil
        if obstacleKind ~= nil then
          return { actorId = actor.actorId, obstacleKind = obstacleKind, mapId = live.id }
        end
      end
    end
  end
  return nil
end

-- Remove one obstacle's logical presence: flagged source events persist
-- through their presence flag, flag-less ones through the sparse recorded
-- override, and smash rocks destroy transiently (source respawns them on
-- re-entry, so neither flag nor override may persist). Presence,
-- collision, and presentation change together in the actor owner; hide is
-- never removal.
---@param target table<string, unknown> { actorId, obstacleKind?, mapId? }
function FieldMoveWorld:removeObstacle(target)
  assert(type(target) == "table", "removal requires its target")
  local actorId = target.actorId
  assert(type(actorId) == "string" and actorId ~= "", "removal needs a target identity")
  local actor = self._actors:getActor(actorId)
  if actor == nil then
    Errors.raise(ScriptErrors.SCRIPT_ACTOR_NOT_FOUND, "no live obstacle " .. actorId, { actor = actorId })
  end
  assert(type(actor) == "table", "live obstacle validated above")
  self._actors:cancelScriptedMovement(actorId)
  if target.obstacleKind == "smash_rock" then
    self._actors:removePresence(actorId, false)
    return
  end
  local event = actor.sourceEvent
  local flag = event and event.eventFlag or nil
  if type(flag) == "number" and flag ~= 0 then
    self._actors:removePresence(actorId, false)
    self._events:setFlag(flag)
    self._actors:syncEventStateChanges()
    return
  end
  self._actors:removePresence(actorId, true)
end

local function boulderRoute(self, plan)
  local target = planTarget(plan)
  local actor = self._actors:getActor(target.actorId)
  assert(type(actor) == "table", "push validates a live boulder")
  local position = self._actors:getPosition(target.actorId)
  assert(type(position.fieldX) == "number" and type(position.fieldZ) == "number", "boulder needs its tile")
  local delta = assert(DIRECTION_DELTAS[plan.direction], "push needs a cardinal direction")
  return {
    boulderFrom = { fieldX = position.fieldX, fieldZ = position.fieldZ },
    boulderTo = { fieldX = position.fieldX + delta.fieldX, fieldZ = position.fieldZ + delta.fieldZ },
  }
end

-- Uncovered tiles refuse as placement: no terrain surface means no push
-- destination. Decoder or data faults still propagate loudly.
---@param err unknown
---@return boolean
local function isUncoveredSurface(err)
  return Errors.is(err) and err.code == FieldErrors.TERRAIN_SURFACE_NOT_FOUND
end

-- Resolve the destination surface through the existing terrain owner:
-- uncovered tiles, walls, and elevation changes refuse as placement,
-- while decoder or data faults propagate loudly.
---@param runtimeMap table<string, unknown>
---@param route table<string, unknown>
---@param surfaceId integer
---@param worldY number
---@return table<string, unknown>? nil when blocked, else the surface sample
local function resolvePushSurface(runtimeMap, route, surfaceId, worldY)
  local terrain = assert(runtimeMap.terrain, "push validation requires terrain")
  assert(runtimeMap.coordinateOrigin, "push validation requires the map origin")
  local to = assert(route.boulderTo, "push route needs its destination")
  local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, to.fieldX, to.fieldZ)
  local ok, sample = pcall(function()
    return SurfaceResolver.new(terrain):resolve({
      localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
      currentY = worldY,
      currentSurfaceId = surfaceId,
    })
  end)
  if not ok then
    if FieldActorManager.isPlacementRejection(sample) or isUncoveredSurface(sample) then
      return nil
    end
    error(sample, 0)
  end
  return sample
end

-- Validate a Strength push before motion: the player stands adjacent on
-- the approach side, both destinations stay on the boulder's elevation,
-- and nothing occupies them. Walls, NPCs, second boulders, holes, and
-- elevation changes refuse with a source reason.
---@param plan table<string, unknown>
---@return table<string, unknown>? nil when valid, else a Decision
function FieldMoveWorld:validatePush(plan)
  assert(type(plan) == "table", "push validation requires a plan")
  assert(plan.direction ~= nil, "push validation requires a direction")
  local target = planTarget(plan)
  local actor = self._actors:getActor(target.actorId)
  if actor == nil then
    return { kind = "stale" }
  end
  local live = self._maps:current()
  if plan.mapId ~= nil and plan.mapId ~= live.id then
    return { kind = "stale" }
  end
  local route = boulderRoute(self, plan)
  local delta = assert(DIRECTION_DELTAS[plan.direction], "push needs a cardinal direction")
  local player = self._player:position()
  if
    player.fieldX ~= route.boulderFrom.fieldX - delta.fieldX
    or player.fieldZ ~= route.boulderFrom.fieldZ - delta.fieldZ
  then
    return { kind = "not_here" }
  end
  local boulderWorld = actor:getWorldPosition()
  local surfaceId = actor:getSurfaceId()
  if surfaceId == nil or boulderWorld.y == nil then
    return { kind = "not_here", reason = "push_blocked" }
  end
  local runtimeMap = self._maps:runtimeMap()
  local sample = resolvePushSurface(runtimeMap, route, surfaceId, boulderWorld.y)
  if sample == nil or sample.worldY ~= boulderWorld.y then
    return { kind = "not_here", reason = "push_blocked" }
  end
  local occupant = self._actors:getCollisionAt(live.id, {
    fieldX = route.boulderTo.fieldX,
    fieldZ = route.boulderTo.fieldZ,
    surfaceId = surfaceId,
  })
  if occupant ~= nil then
    return { kind = "not_here", reason = "push_blocked" }
  end
  if route.boulderTo.fieldX == player.fieldX and route.boulderTo.fieldZ == player.fieldZ then
    return { kind = "not_here", reason = "push_blocked" }
  end
  return nil
end

-- Begin the coordinated push: the boulder walks one tile while the player
-- steps into its vacated tile, both through the existing scripted-motion
-- owners on the fixed-tick cadence.
---@param plan table<string, unknown>
function FieldMoveWorld:beginPush(plan)
  assert(type(plan) == "table", "push begin requires a plan")
  local target = planTarget(plan)
  assert(DIRECTION_DELTAS[plan.direction] ~= nil, "push needs a cardinal direction")
  local opposite = { north = "south", south = "north", west = "east", east = "west" }
  self._actors:beginScriptedAction(target.actorId, { action = "walk", direction = plan.direction, speed = "slow" })
  self._player:beginScriptedAction({ action = "walk", direction = opposite[plan.direction], speed = "slow" })
end

-- Advance both motions one tick. True once the calibrated push cadence
-- completes; progress rides the plan so task state stays serializable.
---@param plan table<string, unknown>
---@return boolean settled
function FieldMoveWorld:advancePush(plan)
  assert(type(plan) == "table", "push advance requires a plan")
  local target = planTarget(plan)
  local progress = (plan.pushProgress or 0) + 1
  plan.pushProgress = progress
  if self._actors:isScriptedMoving(target.actorId) then
    self._actors:advanceScriptedAction(target.actorId, progress, PUSH_TICKS)
  end
  if self._player:isScriptedMoving() then
    self._player:advanceScriptedAction(progress, PUSH_TICKS)
  end
  return progress >= PUSH_TICKS
end

-- Commit both motions at the fixed boundary after revalidation.
---@param plan table<string, unknown>
function FieldMoveWorld:commitPush(plan)
  assert(type(plan) == "table", "push commit requires a plan")
  local target = planTarget(plan)
  self._actors:commitScriptedAction(target.actorId)
  self._player:commitScriptedAction()
end

-- Release in-flight motion for one plan. Tolerant: settled or absent
-- motion is a no-op, and a missing actor after removal is not a fault.
---@param plan table<string, unknown>
function FieldMoveWorld:cancelMotion(plan)
  if type(plan) ~= "table" then
    return
  end
  local target = plan.target
  if type(target) == "table" and type(target.actorId) == "string" then
    self._actors:cancelScriptedMovement(target.actorId)
  end
  if self._player:isScriptedMoving() then
    self._player:cancelScriptedMovement()
  end
end

-- Commit a Strength enablement: the map-lifetime permission itself lives
-- in the runtime; the world gates the commit on a live map.
---@param plan table<string, unknown>
---@return boolean armed
function FieldMoveWorld:activateStrength(plan)
  assert(type(plan) == "table", "strength activation requires a plan")
  local live = self._maps:current()
  assert(type(live.id) == "number", "live map needs its identity")
  assert(plan.mapId == nil or plan.mapId == live.id, "strength enables on the live map")
  return true
end

-- Commit Flash: the Alph chamber dispatches its exact compiled source
-- reaction instead of brightening; normal dark caves illuminate through
-- the weather owner and persist through the illumination flag.
---@param plan table<string, unknown>
function FieldMoveWorld:applyFlash(plan)
  assert(type(plan) == "table", "flash requires a plan")
  if plan.alphChamber then
    self._reactions:dispatch("alph_flash")
    return
  end
  self._events:setFlag(FLASH_FLAG_ID)
  self._weather:change(FLASH_LIT_WEATHER_ID)
end

-- Read one tile's permission cell through the resident collision owner.
-- Nil means the tile leaves readable coverage: callers refuse those paths
-- as unprepared connections instead of guessing geography.
---@param runtimeMap table<string, unknown>
---@param fieldX integer
---@param fieldZ integer
---@return table<string, unknown>?
local function readTraversalTile(runtimeMap, fieldX, fieldZ)
  local okLocal, localX, localZ = pcall(FieldCoordinates.fieldToLocal, runtimeMap, fieldX, fieldZ)
  if not okLocal then
    return nil
  end
  local collision = assert(runtimeMap.collision, "traversal planning requires collision")
  if collision.containsLocal ~= nil and not collision:containsLocal(localX, localZ) then
    return nil
  end
  if collision.getLocal == nil then
    return nil
  end
  local okCell, cell = pcall(collision.getLocal, collision, localX, localZ)
  if not okCell or type(cell) ~= "table" then
    return nil
  end
  return cell
end

-- A terminal landing or shore step must be ordinary walkable ground: not
-- blocked, carrying no dedicated action and no ledge.
---@param cell table<string, unknown>
---@return boolean
local function isWalkableTerminal(cell)
  if cell.blocked then
    return false
  end
  if MetatileBehavior.fieldAction(cell.behavior) ~= nil then
    return false
  end
  if MetatileBehavior.ledgeDirection(cell.behavior) ~= nil then
    return false
  end
  return true
end

-- Resolve one path tile's surface: nearest-height continuity by default,
-- the nearest plate above for climb landings, the highest plate at or
-- below for falls terminals. Nil when no surface covers the tile; decoder
-- ambiguity propagates loudly instead of guessing a height.
---@param runtimeMap table<string, unknown>
---@param fieldX integer
---@param fieldZ integer
---@param currentY number
---@param intent string? "above", "below", or nil for continuity
---@return table<string, unknown>?
local function selectTraversalSurface(runtimeMap, fieldX, fieldZ, currentY, intent)
  local terrain = assert(runtimeMap.terrain, "traversal planning requires terrain")
  local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, fieldX, fieldZ)
  local centerX = localX + FieldCoordinates.TILE_CENTER_OFFSET
  local centerZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET
  if intent == nil then
    local ok, sample = pcall(function()
      return SurfaceResolver.new(terrain):resolve({ localX = centerX, localZ = centerZ, currentY = currentY })
    end)
    if not ok then
      return nil
    end
    return sample
  end
  local best, bestY = nil, nil
  for _, plate in ipairs(terrain:candidatesAt(centerX, centerZ)) do
    local okHeight, height = pcall(terrain.sampleHeight, terrain, plate.id, centerX, centerZ)
    if okHeight and type(height) == "number" then
      if intent == "above" and height > currentY + 1e-9 and (bestY == nil or height < bestY) then
        best, bestY = plate, height
      elseif intent == "below" and height <= currentY + 1e-9 and (bestY == nil or height > bestY) then
        best, bestY = plate, height
      end
    end
  end
  if best == nil then
    return nil
  end
  return terrain:sample(best.id, centerX, centerZ)
end

---@param runtimeMap table<string, unknown>
---@param mapId integer
---@param segment table<string, unknown>
local function appendTraversalSegment(runtimeMap, mapId, segment)
  local plate = assert(runtimeMap.terrain:plate(segment.surfaceId), "traversal segment surface is missing from terrain")
  segment.map = mapId
  segment.sourceCellKey = plate.cellKey
  segment.sourceSurfaceId = plate.sourceSurfaceId
  segment.durationTicks = TRAVERSE_TICKS
end

---@param mapId integer
---@param fieldX integer
---@param fieldZ integer
---@param surfaceId integer?
---@return boolean
local function traversalTileOccupied(self, mapId, fieldX, fieldZ, surfaceId)
  return self._actors:getCollisionAt(mapId, { fieldX = fieldX, fieldZ = fieldZ, surfaceId = surfaceId }) ~= nil
end

local function planSurfEntry(self, runtimeMap, mapId, position, facing, delta)
  local tileX, tileZ = position.fieldX + delta.fieldX, position.fieldZ + delta.fieldZ
  local cell = readTraversalTile(runtimeMap, tileX, tileZ)
  if cell == nil then
    return { kind = "not_here", reason = "connection_unprepared" }
  end
  if not MetatileBehavior.isSurfableWater(cell.behavior) then
    return { kind = "not_here" }
  end
  local sample = selectTraversalSurface(runtimeMap, tileX, tileZ, position.worldY, nil)
  if sample == nil then
    return { kind = "not_here" }
  end
  if traversalTileOccupied(self, mapId, tileX, tileZ, sample.surfaceId) then
    return { kind = "not_here", reason = "traversal_blocked" }
  end
  local segments = {}
  local segment = {
    fieldX = tileX,
    fieldZ = tileZ,
    worldY = sample.worldY,
    surfaceId = sample.surfaceId,
    behavior = cell.behavior,
    direction = facing,
    mode = "surfing",
  }
  appendTraversalSegment(runtimeMap, mapId, segment)
  segments[1] = segment
  return {
    kind = SURF_ENTER,
    segments = segments,
    sourceIdentity = { move = "surf", mapId = mapId, startFieldX = position.fieldX, startFieldZ = position.fieldZ },
  }
end

local function planDisembark(self, runtimeMap, mapId, position, facing, delta)
  local tileX, tileZ = position.fieldX + delta.fieldX, position.fieldZ + delta.fieldZ
  local cell = readTraversalTile(runtimeMap, tileX, tileZ)
  if cell == nil then
    return { kind = "not_here", reason = "connection_unprepared" }
  end
  if not isWalkableTerminal(cell) then
    return { kind = "not_here" }
  end
  local sample = selectTraversalSurface(runtimeMap, tileX, tileZ, position.worldY, nil)
  if sample == nil then
    return { kind = "not_here" }
  end
  if traversalTileOccupied(self, mapId, tileX, tileZ, sample.surfaceId) then
    return { kind = "not_here", reason = "traversal_blocked" }
  end
  local segments = {}
  local segment = {
    fieldX = tileX,
    fieldZ = tileZ,
    worldY = sample.worldY,
    surfaceId = sample.surfaceId,
    behavior = cell.behavior,
    direction = facing,
    mode = "surfing",
  }
  appendTraversalSegment(runtimeMap, mapId, segment)
  segments[1] = segment
  return {
    kind = DISEMBARK,
    segments = segments,
    sourceIdentity = {
      move = "disembark",
      mapId = mapId,
      startFieldX = position.fieldX,
      startFieldZ = position.fieldZ,
    },
  }
end

local function planFalls(self, runtimeMap, mapId, position, facing, delta, move)
  local want = move == "waterfall" and MetatileBehavior.BEHAVIOR.WATERFALL or MetatileBehavior.BEHAVIOR.WHIRLPOOL
  local tileX, tileZ = position.fieldX + delta.fieldX, position.fieldZ + delta.fieldZ
  local first = readTraversalTile(runtimeMap, tileX, tileZ)
  if first == nil then
    return { kind = "not_here", reason = "connection_unprepared" }
  end
  if first.behavior ~= want then
    return { kind = "not_here" }
  end
  local segments = {}
  local currentY = position.worldY
  local x, z = tileX, tileZ
  for _ = 1, MAX_TRAVERSAL_SEGMENTS do
    local cell = readTraversalTile(runtimeMap, x, z)
    if cell == nil then
      return { kind = "not_here", reason = "connection_unprepared" }
    end
    if cell.behavior ~= want then
      if not MetatileBehavior.isSurfableWater(cell.behavior) then
        return { kind = "not_here" }
      end
      local landing = selectTraversalSurface(runtimeMap, x, z, currentY, "below")
      if landing == nil then
        return { kind = "not_here" }
      end
      if traversalTileOccupied(self, mapId, x, z, landing.surfaceId) then
        return { kind = "not_here", reason = "traversal_blocked" }
      end
      local segment = {
        fieldX = x,
        fieldZ = z,
        worldY = landing.worldY,
        surfaceId = landing.surfaceId,
        behavior = cell.behavior,
        direction = facing,
        mode = "surfing",
      }
      appendTraversalSegment(runtimeMap, mapId, segment)
      segments[#segments + 1] = segment
      return {
        kind = move == "waterfall" and WATERFALL or WHIRLPOOL,
        segments = segments,
        sourceIdentity = { move = move, mapId = mapId, startFieldX = position.fieldX, startFieldZ = position.fieldZ },
      }
    end
    local sample = selectTraversalSurface(runtimeMap, x, z, currentY, nil)
    if sample == nil then
      return { kind = "not_here" }
    end
    if traversalTileOccupied(self, mapId, x, z, sample.surfaceId) then
      return { kind = "not_here", reason = "traversal_blocked" }
    end
    local segment = {
      fieldX = x,
      fieldZ = z,
      worldY = sample.worldY,
      surfaceId = sample.surfaceId,
      behavior = cell.behavior,
      direction = facing,
      mode = "surfing",
    }
    appendTraversalSegment(runtimeMap, mapId, segment)
    segments[#segments + 1] = segment
    currentY = sample.worldY
    x, z = x + delta.fieldX, z + delta.fieldZ
  end
  return { kind = "not_here", reason = "traversal_path_unbounded" }
end

local function climbAxisMatches(behavior, facing)
  if behavior == MetatileBehavior.BEHAVIOR.ROCK_CLIMB_NORTH_SOUTH then
    return facing == "north" or facing == "south"
  end
  if behavior == MetatileBehavior.BEHAVIOR.ROCK_CLIMB_EAST_WEST then
    return facing == "east" or facing == "west"
  end
  return false
end

local function planClimb(self, runtimeMap, mapId, position, facing, delta)
  local tileX, tileZ = position.fieldX + delta.fieldX, position.fieldZ + delta.fieldZ
  local first = readTraversalTile(runtimeMap, tileX, tileZ)
  if first == nil then
    return { kind = "not_here", reason = "connection_unprepared" }
  end
  if not climbAxisMatches(first.behavior, facing) then
    return { kind = "not_here" }
  end
  local segments = {}
  local currentY = position.worldY
  local x, z = tileX, tileZ
  for _ = 1, MAX_TRAVERSAL_SEGMENTS do
    local cell = readTraversalTile(runtimeMap, x, z)
    if cell == nil then
      return { kind = "not_here", reason = "connection_unprepared" }
    end
    if
      cell.behavior ~= MetatileBehavior.BEHAVIOR.ROCK_CLIMB_NORTH_SOUTH
      and cell.behavior ~= MetatileBehavior.BEHAVIOR.ROCK_CLIMB_EAST_WEST
    then
      if not isWalkableTerminal(cell) then
        return { kind = "not_here" }
      end
      local landing = selectTraversalSurface(runtimeMap, x, z, currentY, "above")
      if landing == nil then
        return { kind = "not_here" }
      end
      if traversalTileOccupied(self, mapId, x, z, landing.surfaceId) then
        return { kind = "not_here", reason = "traversal_blocked" }
      end
      local segment = {
        fieldX = x,
        fieldZ = z,
        worldY = landing.worldY,
        surfaceId = landing.surfaceId,
        behavior = cell.behavior,
        direction = facing,
        mode = "walking",
      }
      appendTraversalSegment(runtimeMap, mapId, segment)
      segments[#segments + 1] = segment
      return {
        kind = ROCK_CLIMB,
        segments = segments,
        sourceIdentity = {
          move = "rock_climb",
          mapId = mapId,
          startFieldX = position.fieldX,
          startFieldZ = position.fieldZ,
        },
      }
    end
    local sample = selectTraversalSurface(runtimeMap, x, z, currentY, nil)
    if sample == nil then
      return { kind = "not_here" }
    end
    if traversalTileOccupied(self, mapId, x, z, sample.surfaceId) then
      return { kind = "not_here", reason = "traversal_blocked" }
    end
    local segment = {
      fieldX = x,
      fieldZ = z,
      worldY = sample.worldY,
      surfaceId = sample.surfaceId,
      behavior = cell.behavior,
      direction = facing,
      mode = "walking",
    }
    appendTraversalSegment(runtimeMap, mapId, segment)
    segments[#segments + 1] = segment
    currentY = sample.worldY
    x, z = x + delta.fieldX, z + delta.fieldZ
  end
  return { kind = "not_here", reason = "traversal_path_unbounded" }
end

-- Plan terrain-valid contiguous traversal for Surf entry, disembark,
-- Waterfall, Whirlpool, and Rock Climb. Paths run straight lines from the
-- live facing tile inside readable coverage and record every
-- destination's source cell/surface identity. Anything else refuses with
-- a Decision before any motion: wrong facing tile, occupied tiles,
-- missing landings, unbounded paths, and connections the residency never
-- prepared.
---@param request table<string, unknown> { move }
---@param context table<string, unknown>?
---@return table<string, unknown> traversal plan or Decision
function FieldMoveWorld:planTraversal(request, context)
  assert(type(request) == "table", "traversal planning requires a request")
  local move = assert(request.move, "traversal planning requires a move key")
  local live = self._maps:current()
  assert(type(live.id) == "number", "live map needs its identity")
  if context ~= nil and context.mapId ~= nil and context.mapId ~= live.id then
    return { kind = "stale" }
  end
  local runtimeMap = self._maps:runtimeMap()
  local facing = self._player:facing()
  local delta = assert(DIRECTION_DELTAS[facing], "traversal needs a cardinal facing")
  local position = self._player:position()
  assert(
    type(position.fieldX) == "number" and type(position.fieldZ) == "number",
    "traversal planning needs the player tile"
  )
  assert(type(position.worldY) == "number", "traversal planning needs the player height")
  if move == "surf" then
    return planSurfEntry(self, runtimeMap, live.id, position, facing, delta)
  elseif move == "disembark" then
    return planDisembark(self, runtimeMap, live.id, position, facing, delta)
  elseif move == "waterfall" or move == "whirlpool" then
    return planFalls(self, runtimeMap, live.id, position, facing, delta, move)
  elseif move == "rock_climb" then
    return planClimb(self, runtimeMap, live.id, position, facing, delta)
  end
  error("unknown traversal move " .. tostring(move), 0)
end

-- Revalidate the current segment before committing it: a map change
-- reports stale, an unreadable tile reports an unprepared connection, a
-- changed behavior or a fresh occupant reports not_here. Ordinary
-- walkable landings additionally recheck permission blocking; dedicated
-- action tiles stay behavior-gated like the original planning pass.
---@param plan table<string, unknown>
---@return table<string, unknown>? nil when valid, else a Decision
function FieldMoveWorld:validateTraversalSegment(plan)
  assert(type(plan) == "table", "segment validation requires a plan")
  local live = self._maps:current()
  if plan.mapId ~= nil and plan.mapId ~= live.id then
    return { kind = "stale" }
  end
  local segment = plan.segments[plan.segmentIndex + 1]
  if segment == nil then
    return { kind = "not_here" }
  end
  local runtimeMap = self._maps:runtimeMap()
  local cell = readTraversalTile(runtimeMap, segment.fieldX, segment.fieldZ)
  if cell == nil then
    return { kind = "not_here", reason = "connection_unprepared" }
  end
  if cell.behavior ~= segment.behavior then
    return { kind = "not_here" }
  end
  if cell.blocked and MetatileBehavior.fieldAction(cell.behavior) == nil then
    return { kind = "not_here" }
  end
  if traversalTileOccupied(self, live.id, segment.fieldX, segment.fieldZ, segment.surfaceId) then
    return { kind = "not_here", reason = "traversal_blocked" }
  end
  return nil
end

-- Begin the current segment's scripted traverse motion through the
-- existing motion owner. Marks the plan in-flight so the runtime can tell
-- a settled segment from one never started.
---@param plan table<string, unknown>
function FieldMoveWorld:beginTraversalSegment(plan)
  assert(type(plan) == "table", "segment begin requires a plan")
  local segment = assert(plan.segments[plan.segmentIndex + 1], "traversal has no current segment")
  self._player:beginScriptedAction({
    action = "traverse",
    direction = segment.direction,
    speed = "normal",
    mode = segment.mode,
    surfaceId = segment.surfaceId,
  })
  plan.motionActive = true
end

-- True once the in-flight segment motion settled through the motion
-- owner (the session tick advances and commits it; this only observes).
---@param plan table<string, unknown>
---@return boolean
function FieldMoveWorld:traversalMotionDone(plan)
  assert(type(plan) == "table", "segment progress requires a plan")
  return not self._player:isScriptedMoving()
end

-- Commit one settled segment: settle the scripted motion (idempotent when
-- the session tick already committed the tile) and advance past it. The
-- session's normal boundary/audio/zone hooks already ran on that commit.
---@param plan table<string, unknown>
function FieldMoveWorld:commitTraversalSegment(plan)
  assert(type(plan) == "table", "segment commit requires a plan")
  self._player:commitScriptedAction()
  plan.segmentIndex = plan.segmentIndex + 1
  plan.motionActive = false
end

-- Apply the terminal avatar transition once the final segment committed.
-- Only surf entry and disembark change the avatar; falls and climbs hold
-- their mode while segments run. Returns the applied terminal mode.
---@param plan table<string, unknown>
---@return string?
function FieldMoveWorld:commitTraversalMode(plan)
  assert(type(plan) == "table", "avatar commit requires a plan")
  local terminal = TERMINAL_AVATAR[plan.kind]
  if terminal == nil then
    return nil
  end
  self._player:queueAvatarTransition(terminal)
  self._player:applyAvatarTransitions()
  return terminal
end

return FieldMoveWorld
