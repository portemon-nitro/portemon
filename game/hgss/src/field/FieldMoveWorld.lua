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

return FieldMoveWorld
