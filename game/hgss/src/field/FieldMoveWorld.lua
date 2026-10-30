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
local FieldCameraZoom = require("libs.hgss.src.field.FieldCameraZoom")
local FieldMoveCutInBannerAssetCache = require("libs.assets.src.field.FieldMoveCutInBannerAssetCache")
local FieldMoveContext = require("game.hgss.src.field.FieldMoveContext")
local FieldWarpSequence = require("libs.hgss.src.field.FieldWarpSequence")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")
local ScriptErrors = require("libs.script.src.errors")
local SurfaceResolver = require("libs.hgss.src.world.SurfaceResolver")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local FLASH_FLAG_ID = assert(FieldScriptSymbols.flagsByName.FLAG_SYS_FLASH, "flash flag identity required")
local SAFARI_FLAG_ID = assert(FieldScriptSymbols.flagsByName.FLAG_SYS_SAFARI, "safari flag identity required")
local STRENGTH_FLAG_ID = assert(FieldScriptSymbols.flagsByName.FLAG_STRENGTH_ACTIVE, "strength flag identity required")

-- The lit-cave weather preset: the generated weather catalog rewrites
-- weather 11 to 12 on the flash flag (weather_flag_override), and the
-- existing flash script effect changes to the same preset. Cited here
-- once; gameplay carries no other weather literal.
local FLASH_LIT_WEATHER_ID = 12

local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")

-- Source Task_PushBoulder: the boulder takes one slow walk step (movement 8)
-- while the player walks on the spot at normal speed (movement 32); the task
-- ends when both settle, and the push sound plays as both start.
local PUSH_TICKS = MovementCalibration.actionTicks({ action = "walk", speed = "slow" })
local PUSH_PLAYER_TICKS = MovementCalibration.actionTicks({ action = "walk_in_place", speed = "normal" })
local SE_BOULDER_PUSH = "SEQ_SE_DP_UG_023"
local SE_ROCK_CLIMB_DEBRIS = "SEQ_SE_DP_UG_023"
local SE_WATER_FIELD_MOVE = "SEQ_SE_DP_FW463"

-- Source Task_Surf mounts after an 11-update wait and hops only once a
-- second 11-update wait has passed (timer incremented past 10 each time).
local SURF_MOUNT_WAIT_TICKS = 11

-- Source movement ids per traversal gait: Surf, Stop Surfing, and Rock Climb
-- landings hop (52, near fast); Rock Climb walks fast between wall tiles
-- (16); Whirlpool walks slowest per tile (4).
local WHIRLPOOL_SPEED = "slower"
local CLIMB_WALK_SPEED = "fast"

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
---@field private _warps table<string, unknown>? borrowed maps service for return warps
---@field private _spawns table<string, unknown>? cited landing destinations for teleport returns
---@field private _party table<string, unknown>? borrowed party move lookup for unannounced field moves
---@field private _audio table<string, unknown>? borrowed effect player; absent hosts stay silent
---@field private _camera (fun(): FieldCamera)? live camera reader; the swap replaces the camera
---@field private _screen table<string, unknown>? borrowed script screen-fade owner for warp covers
---@field private _cry table<string, unknown>? borrowed lead-mon cry port; absent hosts stay silent
---@field private _travel table<string, unknown>? borrowed durable travel owner for special-spawn rewrites
---@field private _cutin table<string, unknown>? borrowed cut-in/landing presenter; absent hosts run the warp covers without presentation
---@field private _zoom FieldCameraZoom? the live warp zoom, bound to one camera
---@field private _fadeLease integer? the live warp fade's lease on the screen owner
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
      "partnerId",
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
    -- The return-warp service is optional at construction so existing
    -- environmental/traversal owners keep their exact port set; return
    -- execution asserts it before starting anything. The teleport
    -- landing destinations ride the same optionality: Dig-only owners
    -- never carry them, and teleport planning asserts the port before
    -- resolving anything.
    _warps = ports.warps,
    _spawns = ports.spawns,
    _audio = ports.audio,
    _party = ports.party,
    _camera = ports.camera,
    _screen = ports.screen,
    _cry = ports.cry,
    _travel = ports.travel,
    _cutin = ports.cutin,
    _zoom = nil,
    _fadeLease = nil,
  }, FieldMoveWorld)
  assert(type(world._profile.badges) == "number", "field world profile must carry its badge mask")
  assert(type(world._maps:current()) == "table", "field world maps must describe the live map")
  if world._warps ~= nil then
    assert(type(world._warps.startWarp) == "function", "warps port must start warps")
    assert(type(world._warps.warpDone) == "function", "warps port must observe warp completion")
    assert(type(world._warps.pendingError) == "function", "warps port must report warp failures")
    assert(type(world._warps.placement) == "function", "warps port must place destination maps")
  end
  if world._party ~= nil then
    assert(type(world._party.knowsMove) == "function", "party port must answer move knowledge")
    assert(type(world._party.leadSlot) == "function", "party port must answer the lead slot")
  end
  if world._audio ~= nil then
    assert(type(world._audio.play) == "function", "audio port must play effects")
  end
  if world._spawns ~= nil then
    assert(type(world._spawns.destinationFor) == "function", "spawns port must resolve cited landing destinations")
    assert(type(world._spawns.specialFor) == "function", "spawns port must resolve special spawn records")
  end
  if world._camera ~= nil then
    assert(type(world._camera) == "function", "camera port must read the live camera")
  end
  if world._screen ~= nil then
    assert(type(world._screen.startFade) == "function", "screen port must start fades")
    assert(type(world._screen.fadeDone) == "function", "screen port must observe fades")
    assert(type(world._screen.clearIfCurrent) == "function", "screen port must clear its fade lease")
  end
  if world._cry ~= nil then
    assert(type(world._cry.start) == "function", "cry port must start the lead cry")
    assert(type(world._cry.done) == "function", "cry port must observe the cry")
  end
  if world._travel ~= nil then
    assert(type(world._travel.setSpecialSpawn) == "function", "travel port must record special spawns")
  end
  if world._cutin ~= nil then
    for _, method in ipairs({
      "startCutIn",
      "cutInDone",
      "cancelCutIn",
      "startLanding",
      "landingClimbed",
      "landingDone",
      "cancelLanding",
    }) do
      assert(type(world._cutin[method]) == "function", "cutin port must implement " .. method)
    end
    -- The staged banner class is validated once at composition: a malformed
    -- generated class fails loudly here instead of presenting garbage mid-fly.
    local manifest = assert(world._cutin.manifest, "cutin port carries its staged banner class")
    assert(type(manifest) == "table", "staged banner classes are records")
    local valid, err = FieldMoveCutInBannerAssetCache.validateManifest(manifest)
    if not valid then
      error(err, 0)
    end
  end
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

-- Whether the follower performs a menu field move for one party slot: the
-- follower actor stands next to the player and the slot is the party lead
-- (the follower shows the first alive mon, Task_FieldDig/Task_FieldTeleport
-- compare FollowMon_IsNextToPlayer with the lead index). Without a party
-- port there is no lead to compare, so nothing performs.
---@param slot integer? the used zero-based party slot
---@return boolean
function FieldMoveWorld:isFollowerPerforming(slot)
  if type(slot) ~= "number" then
    return false
  end
  local party = self._party
  if party == nil then
    return false
  end
  if party:leadSlot() ~= slot then
    return false
  end
  local partnerId = self._actors:partnerId()
  if partnerId == nil then
    return false
  end
  local partner = self._actors:getPosition(partnerId)
  if partner == nil then
    return false
  end
  local player = self._player:position()
  assert(type(player.fieldX) == "number" and type(player.fieldZ) == "number", "follower checks need the player tile")
  return math.abs(partner.fieldX - player.fieldX) + math.abs(partner.fieldZ - player.fieldZ) == 1
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
-- walks on the spot facing it, both through the existing scripted-motion
-- owners; the player's tile changes only when the player later walks.
---@param plan table<string, unknown>
function FieldMoveWorld:beginPush(plan)
  assert(type(plan) == "table", "push begin requires a plan")
  local target = planTarget(plan)
  assert(DIRECTION_DELTAS[plan.direction] ~= nil, "push needs a cardinal direction")
  self._actors:beginScriptedAction(target.actorId, { action = "walk", direction = plan.direction, speed = "slow" })
  self._player:beginScriptedAction({ action = "walk_in_place", direction = plan.direction, speed = "normal" })
  self:playEffect(SE_BOULDER_PUSH)
end

-- True when any party mon knows Waterfall. The auto descent keeps this gate:
-- field_control.c marks the surf step PLAYER_EVENT_USED_WATERFALL only when
-- GetIdxOfFirstPartyMonWithMove finds MOVE_WATERFALL (no badge is checked),
-- Field_PlayerAvatar_TryWaterfallUp answers only that southward surf step
-- into the fall, and Field_StartWaterfallTask runs the Task_Waterfall down
-- steps (sWaterfallDownSteps) with no announcement (player_avatar_actions.c).
---@return boolean
function FieldMoveWorld:partyKnowsWaterfall()
  return assert(self._party, "unannounced field moves require the party port"):knowsMove("WATERFALL")
end

-- Play one source effect through the borrowed audio port.
---@param sequence string
function FieldMoveWorld:playEffect(sequence)
  if self._audio ~= nil then
    self._audio:play(sequence)
  end
end

-- Advance both motions one tick. True once the calibrated push cadence
-- completes; progress rides the plan so task state stays serializable. The
-- player's on-the-spot walk settles on its own shorter lifetime.
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
    self._player:advanceScriptedAction(math.min(progress, PUSH_PLAYER_TICKS), PUSH_PLAYER_TICKS)
    if progress >= PUSH_PLAYER_TICKS then
      self._player:commitScriptedAction()
    end
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

local warpPort

-- Release in-flight motion for one plan. Tolerant: settled or absent
-- motion is a no-op, and a missing actor after removal is not a fault.
---@param plan table<string, unknown>
function FieldMoveWorld:cancelMotion(plan)
  if type(plan) ~= "table" then
    return
  end
  if plan.sequence ~= nil then
    FieldWarpSequence.cancel(plan.sequence, warpPort(self, plan))
  end
  local target = plan.target
  if type(target) == "table" and type(target.actorId) == "string" then
    self._actors:cancelScriptedMovement(target.actorId)
  end
  if self._player:isScriptedMoving() then
    self._player:cancelScriptedMovement()
  end
end

-- The map-lifetime Strength permission is FLAG_STRENGTH_ACTIVE, the flag the
-- retail scripts set and check; the world owns it for every path.
---@return boolean
function FieldMoveWorld:isStrengthActive()
  return self._events:isFlagSet(STRENGTH_FLAG_ID)
end

-- Commit a Strength enablement on a live map by setting the flag.
---@param plan table<string, unknown>
---@return boolean armed
function FieldMoveWorld:activateStrength(plan)
  assert(type(plan) == "table", "strength activation requires a plan")
  local live = self._maps:current()
  assert(type(live.id) == "number", "live map needs its identity")
  assert(plan.mapId == nil or plan.mapId == live.id, "strength enables on the live map")
  self._events:setFlag(STRENGTH_FLAG_ID)
  return true
end

-- Source map entry by warp or connection drops the permission.
function FieldMoveWorld:clearStrength()
  self._events:clearFlag(STRENGTH_FLAG_ID)
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

-- Resolve a validated return destination from durable travel facts. Dig
-- exits to the recorded special spawn (the last entrance from the outside
-- or the spawn a Teleport, Fly or blackout wrote); with none recorded it is
-- not_now, never a guessed tile. Teleport resolves the recorded heal spawn
-- through the injected cited landing destinations and rewrites the special
-- spawn at the warp (GetSpecialSpawnWarpData); an unknown spawn key fails
-- loudly instead of warping somewhere convenient. Coordinates are
-- destination-global; the warp start converts them against the loaded map
-- origin. Teleport arrives facing south, a recorded special spawn arrives
-- facing its recorded direction.
---@param move string "dig" or "teleport"
---@param context table<string, unknown>
---@param travel table<string, unknown> a FieldTravelState capture
---@return table<string, unknown> destination record or Decision
function FieldMoveWorld:planReturn(move, context, travel)
  assert(move == "dig" or move == "teleport", "return planning covers dig and teleport")
  assert(type(context) == "table", "return planning requires its context")
  assert(type(travel) == "table", "return planning requires a travel record")
  assert(
    type(travel.lastHealSpawn) == "string" and travel.lastHealSpawn ~= "",
    "return planning requires a recorded heal spawn"
  )
  if move == "teleport" then
    local spawns = assert(self._spawns, "teleport planning requires the cited landing destinations")
    local spawnKey = travel.lastHealSpawn
    local destination = spawns:destinationFor(spawnKey)
    if destination == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_INVALID_REFERENCE,
        "teleport spawn has no cited landing destination: " .. tostring(spawnKey),
        { spawn = spawnKey }
      )
    end
    assert(type(destination) == "table", "landing destinations are records")
    assert(type(destination.map) == "string" and destination.map ~= "", "landing destinations name a map")
    assert(
      type(destination.fieldX) == "number" and type(destination.fieldZ) == "number",
      "landing destinations carry tiles"
    )
    return {
      map = destination.map,
      warp = 0,
      fieldX = destination.fieldX,
      fieldZ = destination.fieldZ,
      facing = "south",
      specialSpawnKey = spawnKey,
    }
  end
  local special = travel.specialSpawn
  if special == nil then
    return { kind = "not_now" }
  end
  assert(type(special) == "table", "recorded special spawns are records")
  assert(type(special.map) == "string" and special.map ~= "", "recorded special spawns name their map")
  assert(
    type(special.fieldX) == "number" and type(special.fieldZ) == "number",
    "recorded special spawns carry their tile"
  )
  assert(type(special.direction) == "string" and special.direction ~= "", "recorded special spawns carry facing")
  return {
    map = special.map,
    warp = 0,
    fieldX = special.fieldX,
    fieldZ = special.fieldZ,
    facing = special.direction,
  }
end

-- Resolve a semantic flypoint to the existing destination record shape:
-- the confirmed key resolves through the cited landing destinations,
-- never through raw coordinates or the last-heal spawn. An unknown key
-- fails loudly instead of warping somewhere convenient; the caller
-- starts arrival through the existing return-warp owner.
---@param flypointKey string the confirmed semantic flypoint
---@param context table<string, unknown> the initiating choice context
---@return table<string, unknown> destination record or Decision
function FieldMoveWorld:planFly(flypointKey, context)
  assert(type(flypointKey) == "string" and flypointKey ~= "", "fly planning names its semantic flypoint")
  assert(type(context) == "table", "fly planning requires its context")
  local spawns = assert(self._spawns, "fly planning requires the cited landing destinations")
  local destination = spawns:destinationFor(flypointKey)
  if destination == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "flypoint has no cited landing destination: " .. tostring(flypointKey),
      { flypoint = flypointKey }
    )
  end
  assert(type(destination) == "table", "landing destinations are records")
  assert(type(destination.map) == "string" and destination.map ~= "", "landing destinations name a map")
  assert(
    type(destination.fieldX) == "number" and type(destination.fieldZ) == "number",
    "landing destinations carry tiles"
  )
  return {
    map = destination.map,
    warp = 0,
    fieldX = destination.fieldX,
    fieldZ = destination.fieldZ,
    facing = "south",
    specialSpawnKey = flypointKey,
  }
end

-- Start the return warp exactly once through the borrowed maps service.
-- The destination resolves against the loaded map so global record
-- coordinates convert to the destination-local tiles the warp owns; a
-- repeat start is a programming error, never a second warp. Live service
-- failures are the caller's to convert; program errors propagate.
---@param plan table<string, unknown> a dig/teleport plan carrying destination
function FieldMoveWorld:beginReturnWarp(plan)
  assert(type(plan) == "table", "return warps start from a plan")
  assert(plan.warpStarted ~= true, "return warps start exactly once")
  local warps = assert(self._warps, "return warps need the maps service")
  local destination = assert(plan.destination, "return plans carry their destination")
  assert(type(destination.map) == "string" and destination.map ~= "", "return destinations name a map")
  -- Structural placement only: the destination build belongs to the transition.
  local placed, placement = pcall(warps.placement, warps, destination.map)
  if not placed then
    if Errors.is(placement) and placement.code == FieldErrors.FIELD_MAP_UNKNOWN then
      Errors.raise(
        ScriptErrors.SCRIPT_INVALID_REFERENCE,
        "return destination map is unavailable: " .. tostring(destination.map),
        { map = destination.map }
      )
    end
    error(placement, 0)
  end
  assert(type(destination.fieldX) == "number", "return destinations carry tiles")
  assert(type(destination.fieldZ) == "number", "return destinations carry tiles")
  -- The warp task sets the avatar to walking before the map change.
  self._player:queueAvatarTransition("walking")
  self._player:applyAvatarTransitions()
  warps:startWarp({
    map = destination.map,
    warp = destination.warp or 0,
    fieldX = destination.fieldX - placement.originX,
    fieldZ = destination.fieldZ - placement.originZ,
    facing = destination.facing,
  })
  plan.warpStarted = true
  -- Teleport and Fly rewrite the special spawn with the spawn they leave
  -- for (GetSpecialSpawnWarpData) as the warp begins.
  local spawnKey = destination.specialSpawnKey
  if spawnKey ~= nil then
    local spawns = assert(self._spawns, "special spawn rewrites need the spawn records")
    local travel = assert(self._travel, "special spawn rewrites need the travel owner")
    travel:setSpecialSpawn(assert(spawns:specialFor(spawnKey), "spawn has no special spawn record"))
  end
end

-- Warp animation port: the sequence reaches the avatar, camera, screen
-- fade, effect player and cry only through these operations. Every owner
-- is borrowed and read live, because the map swap replaces the player and
-- the camera.
local WarpPort = {}
WarpPort.__index = WarpPort

function WarpPort:playEffect(sequence)
  self.world:playEffect(sequence)
end

function WarpPort:faceAvatar(direction)
  self.world._player:beginScriptedAction({ action = "face", direction = direction })
end

function WarpPort:zoomSet(mode, amount, duration)
  local world = self.world
  if world._zoom == nil then
    local camera = assert(world._camera, "warp zooms need the camera port")
    world._zoom = FieldCameraZoom.new(camera())
  end
  world._zoom:set(mode, amount, duration)
end

function WarpPort:zoomStep()
  self.world._zoom:step()
end

function WarpPort:zoomDone()
  return self.world._zoom:isDone()
end

function WarpPort:zoomRelease()
  local world = self.world
  if world._zoom ~= nil then
    world._zoom:release()
    world._zoom = nil
  end
end

-- Source fades run six steps at one frame each.
local FADE_STEPS = 6
local FADE_FRAMES_PER_STEP = 1

function WarpPort:fadeStart(direction, color)
  local world = self.world
  local screen = assert(world._screen, "warp covers need the screen port")
  world._fadeLease = screen:startFade({
    direction = direction,
    color = color,
    duration = FADE_STEPS,
    speed = FADE_FRAMES_PER_STEP,
    screenScope = "both",
  })
end

function WarpPort:fadeDone()
  return assert(self.world._screen, "warp covers need the screen port"):fadeDone()
end

function WarpPort:fadeClear()
  local world = self.world
  if world._fadeLease ~= nil then
    world._screen:clearIfCurrent(world._fadeLease)
    world._fadeLease = nil
  end
end

function WarpPort:startCry()
  local cry = self.world._cry
  if cry ~= nil then
    cry:start(assert(self.plan.slot, "warp cries need the departing party slot"))
  end
end

function WarpPort:cryDone()
  local cry = self.world._cry
  return cry == nil or cry:done()
end

-- Fly cut-in and landing presentation through the borrowed presenter. The
-- presenter owns the staged banner pixels and the takeoff/landing models:
-- the world only hands it the staged banner record selected per the banner
-- asset contract (the semantic banner key, never NARC/member ids) plus the
-- departing slot, and orders the waits around the warp-cover fades the
-- sequence owns. The presenter picks the solo or follower-riding cut-in
-- from its own follower reads (FieldTask_Fly states 1/5-6). Absent
-- presenters complete immediately, so presenter-less hosts keep the legacy
-- warp covers with no behavior change.
function WarpPort:startCutIn()
  local cutin = self.world._cutin
  if cutin == nil then
    return
  end
  local manifest = assert(cutin.manifest, "cut-in presentation needs its staged banner class")
  local asset = assert(manifest.assets[manifest.banner], "staged banner class carries its banner asset")
  cutin:startCutIn({
    slot = assert(self.plan.slot, "cut-ins name the departing party slot"),
    banner = {
      key = manifest.banner,
      image = asset.image,
      width = asset.width,
      height = asset.height,
      paletteSlot = manifest.paletteSlot,
    },
  })
end

function WarpPort:cutInDone()
  local cutin = self.world._cutin
  return cutin == nil or cutin:cutInDone()
end

function WarpPort:cancelCutIn()
  local cutin = self.world._cutin
  if cutin ~= nil then
    cutin:cancelCutIn()
  end
end

function WarpPort:startLanding()
  local cutin = self.world._cutin
  if cutin ~= nil then
    cutin:startLanding()
  end
end

function WarpPort:landingClimbed()
  local cutin = self.world._cutin
  return cutin == nil or cutin:landingClimbed()
end

function WarpPort:landingDone()
  local cutin = self.world._cutin
  return cutin == nil or cutin:landingDone()
end

function WarpPort:cancelLanding()
  local cutin = self.world._cutin
  if cutin ~= nil then
    cutin:cancelLanding()
  end
end

function warpPort(world, plan)
  return setmetatable({ world = world, plan = plan }, WarpPort)
end

-- Advance a warp plan's departure animation one source tick: "running"
-- until the cover completes, then "warp".
---@param plan table<string, unknown>
---@return "running"|"warp"
function FieldMoveWorld:stepWarpDeparture(plan)
  assert(type(plan) == "table", "warp departure steps a plan")
  return FieldWarpSequence.stepDeparture(assert(plan.sequence, "warp plans carry their sequence"), warpPort(self, plan))
end

-- Advance a warp plan's arrival animation one source tick: "running"
-- until the screen, avatar and camera settle, then "done".
---@param plan table<string, unknown>
---@return "running"|"done"
function FieldMoveWorld:stepWarpArrival(plan)
  assert(type(plan) == "table", "warp arrival steps a plan")
  return FieldWarpSequence.stepArrival(assert(plan.sequence, "warp plans carry their sequence"), warpPort(self, plan))
end

-- The map change landed: the source warp tasks end any Safari Zone session
-- (FieldSystem_ClearSafariSysFlag). Teleport and Fly also re-randomize the
-- roamers there; no roamer owner exists to do so yet.
---@param plan table<string, unknown>
function FieldMoveWorld:settleWarp(plan)
  assert(type(plan) == "table", "warp settling needs a plan")
  self._events:clearFlag(SAFARI_FLAG_ID)
end

-- Observe a started return warp: true once the maps service settles it.
---@param plan table<string, unknown>
---@return boolean
function FieldMoveWorld:returnWarpDone(plan)
  assert(type(plan) == "table", "warp observation needs a plan")
  local warps = assert(self._warps, "return warps need the maps service")
  return warps:warpDone()
end

-- Surface the maps service failure for a settled return warp, if any.
---@param plan table<string, unknown>
---@return unknown|nil
function FieldMoveWorld:returnWarpError(plan)
  assert(type(plan) == "table", "warp errors read from a plan")
  local warps = assert(self._warps, "return warps need the maps service")
  return warps:pendingError()
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
    hop = true,
  }
  appendTraversalSegment(runtimeMap, mapId, segment)
  segments[1] = segment
  return {
    kind = SURF_ENTER,
    preTicks = SURF_MOUNT_WAIT_TICKS,
    postTicks = SURF_MOUNT_WAIT_TICKS,
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
    hop = true,
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

-- Source Task_Waterfall: the avatar crosses exactly two tiles straight up or
-- down, whatever the fall behavior's height. The facing tile must be the
-- fall; the far tile must be water or another fall tile and carry a surface
-- above (rising) or at or below (falling) the current height.
local function planWaterfall(self, runtimeMap, mapId, position, facing, delta, auto)
  if facing ~= "north" and facing ~= "south" then
    return { kind = "not_here" }
  end
  local viaX, viaZ = position.fieldX + delta.fieldX, position.fieldZ + delta.fieldZ
  local via = readTraversalTile(runtimeMap, viaX, viaZ)
  if via == nil then
    return { kind = "not_here", reason = "connection_unprepared" }
  end
  if via.behavior ~= MetatileBehavior.BEHAVIOR.WATERFALL then
    return { kind = "not_here" }
  end
  local x, z = viaX + delta.fieldX, viaZ + delta.fieldZ
  local far = readTraversalTile(runtimeMap, x, z)
  if far == nil then
    return { kind = "not_here", reason = "connection_unprepared" }
  end
  if not MetatileBehavior.isSurfableWater(far.behavior) and far.behavior ~= MetatileBehavior.BEHAVIOR.WATERFALL then
    return { kind = "not_here" }
  end
  local landing = selectTraversalSurface(runtimeMap, x, z, position.worldY, facing == "north" and "above" or "below")
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
    behavior = far.behavior,
    direction = facing,
    mode = "surfing",
    waterfall = true,
    viaFieldX = viaX,
    viaFieldZ = viaZ,
    viaBehavior = via.behavior,
  }
  appendTraversalSegment(runtimeMap, mapId, segment)
  return {
    kind = WATERFALL,
    -- The unannounced descent carries no announcement: WaterfallDown_StartCutIn
    -- skips the cut-in (and its follow-up SE_WATER_FIELD_MOVE) when the task
    -- runs without one (player_avatar_actions.c sWaterfallDownSteps), so only
    -- the announced climb plays the effect.
    effect = not auto and SE_WATER_FIELD_MOVE or nil,
    segments = { segment },
    sourceIdentity = { move = "waterfall", mapId = mapId, startFieldX = position.fieldX, startFieldZ = position.fieldZ },
  }
end

-- Source Task_Whirlpool: one slowest-walk step per tile until the avatar's
-- tile is no longer a whirlpool; the first non-whirlpool tile must be water.
local function planWhirlpool(self, runtimeMap, mapId, position, facing, delta)
  local want = MetatileBehavior.BEHAVIOR.WHIRLPOOL
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
    local terminal = cell.behavior ~= want
    if terminal and not MetatileBehavior.isSurfableWater(cell.behavior) then
      return { kind = "not_here" }
    end
    local sample
    if terminal then
      sample = selectTraversalSurface(runtimeMap, x, z, currentY, "below")
    else
      sample = selectTraversalSurface(runtimeMap, x, z, currentY, nil)
    end
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
      speed = WHIRLPOOL_SPEED,
    }
    appendTraversalSegment(runtimeMap, mapId, segment)
    segments[#segments + 1] = segment
    if terminal then
      return {
        kind = WHIRLPOOL,
        effect = SE_WATER_FIELD_MOVE,
        segments = segments,
        sourceIdentity = {
          move = "whirlpool",
          mapId = mapId,
          startFieldX = position.fieldX,
          startFieldZ = position.fieldZ,
        },
      }
    end
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
      -- Source Task_RockClimb: hop onto the wall, walk fast between wall
      -- tiles, hop onto the landing.
      for index, planned in ipairs(segments) do
        if index == 1 or index == #segments then
          planned.hop = true
        else
          planned.speed = CLIMB_WALK_SPEED
        end
      end
      return {
        kind = ROCK_CLIMB,
        effect = SE_ROCK_CLIMB_DEBRIS,
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
---@param request table<string, unknown> { move, auto? }
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
  elseif move == "waterfall" then
    return planWaterfall(self, runtimeMap, live.id, position, facing, delta, request.auto == true)
  elseif move == "whirlpool" then
    return planWhirlpool(self, runtimeMap, live.id, position, facing, delta)
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
  if segment.viaFieldX ~= nil then
    -- A two-tile crossing also revalidates the tile it passes over.
    local via = readTraversalTile(runtimeMap, segment.viaFieldX, segment.viaFieldZ)
    if via == nil then
      return { kind = "not_here", reason = "connection_unprepared" }
    end
    if via.behavior ~= segment.viaBehavior then
      return { kind = "not_here" }
    end
  end
  return nil
end

-- Begin the current segment's scripted traverse motion through the
-- existing motion owner, at the gait the plan chose. Marks the plan
-- in-flight so the runtime can tell a settled segment from one never
-- started; the plan's source effect sounds as its first segment starts.
---@param plan table<string, unknown>
function FieldMoveWorld:beginTraversalSegment(plan)
  assert(type(plan) == "table", "segment begin requires a plan")
  local segment = assert(plan.segments[plan.segmentIndex + 1], "traversal has no current segment")
  local action = {
    action = "traverse",
    direction = segment.direction,
    mode = segment.mode,
    surfaceId = segment.surfaceId,
  }
  if segment.waterfall then
    action.action = "waterfall"
  elseif segment.hop then
    action.hop = true
  else
    action.speed = assert(segment.speed, "traversal segment needs its gait")
  end
  self._player:beginScriptedAction(action)
  if plan.segmentIndex == 0 and plan.effect ~= nil then
    self:playEffect(plan.effect)
  end
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
