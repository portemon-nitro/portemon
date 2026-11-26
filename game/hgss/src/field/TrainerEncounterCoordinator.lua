-- Native standard-trainer engagement for one field runtime. This owner keeps
-- the source engagement slots and the approach state machine, and answers the
-- trainer-script queries the common trainer scene reads.
--
-- Source: src/map_object_behavior.c (TrainerSight_*, CheckSeenByNpcTrainers,
-- TryGetSeenByNpcTrainers and the TrainerApproach_* state machine),
-- src/scrcmd_battle.c (168..222, 562), src/scrcmd_c.c (454, 574) and
-- src/talked_trainer_movement.c.
--
-- Owned facts:
--   * at most two engagement slots, each naming one source actor together with
--     the sight geometry and native encounter type its scene was started with;
--   * one running approach per slot, advanced one source tick at a time;
--   * the running trainer script's detached context, resolved from the object
--     actor the script's launch trigger names.
-- Everything else — actor motion, the approach scene, the battle — belongs to
-- the existing actor, script and battle owners. Nothing here is serialized:
-- the slots and the approaches live only as long as their script environment.

local Errors = require("libs.errors.src.Errors")
local FieldActorPlacement = require("libs.hgss.src.actors.FieldActorPlacement")
local HgssTrainerCatalog = require("libs.hgss.src.battle.HgssTrainerCatalog")
local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local ScriptErrors = require("libs.script.src.errors")
local TrainerBattleTrigger = require("libs.hgss.src.battle.TrainerBattleTrigger")

---@class TrainerEncounterCoordinator
---@field private _actors table<string, unknown>
---@field private _catalog fun(): HgssTrainerCatalog?
---@field private _playerOf fun(): table<string, unknown>?
---@field private _currentMap fun(): table<string, unknown>?
---@field private _world fun(): table<string, unknown>
---@field private _startScene fun(scriptId: string): boolean
---@field private _scriptActive fun(): boolean
---@field private _battleActive fun(): boolean
---@field private _doublesEligible fun(): boolean
---@field private _region fun(): string
---@field private _fieldReady fun(): boolean
---@field private _effects fun(): table<string, unknown>?
---@field private _slots table<integer, table<string, unknown>>?
---@field private _disposed boolean
local TrainerEncounterCoordinator = {}
TrainerEncounterCoordinator.__index = TrainerEncounterCoordinator

-- src/talked_trainer_movement.c: the source rewrites a talked-to trainer's
-- movement from its facing with these native movement selectors.
local MOVEMENT_SELECTOR_BY_FACING = {
  north = 14,
  south = 15,
  west = 16,
  east = 17,
}

-- src/map_object_behavior.c: the source approach waits thirty ticks after its
-- exclamation before it rechecks the distance, and eight more once it arrives.
local APPROACH_WAIT_TICKS = 30
local APPROACH_ARRIVED_TICKS = 8

-- MapObject_GetMovement selectors whose approach reveals the trainer before
-- facing the player (movement commands 0x33..0x36 of the source table).
local REVEAL_MOVEMENT_SELECTORS = { [51] = true, [52] = true, [53] = true, [54] = true }

---@param index unknown
---@return integer
local function checkSlotIndex(index)
  if type(index) ~= "number" or index % 1 ~= 0 or (index ~= 0 and index ~= 1) then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "a trainer engagement slot is 0 or 1", {
      slot = tostring(index),
    })
  end
  return index --[[@as integer]]
end

-- The cardinal direction that points from one tile to another, or nil when the
-- tiles do not share a row or column (GetDirectionTowards).
---@param fromX integer
---@param fromZ integer
---@param toX integer
---@param toZ integer
---@return string?
local function directionTowards(fromX, fromZ, toX, toZ)
  if fromX == toX and fromZ ~= toZ then
    return toZ > fromZ and "south" or "north"
  end
  if fromZ == toZ and fromX ~= toX then
    return toX > fromX and "east" or "west"
  end
  return nil
end

---@param opts table<string, unknown>
---@return TrainerEncounterCoordinator
function TrainerEncounterCoordinator.new(opts)
  assert(type(opts) == "table", "trainer engagement requires its field collaborators")
  for _, name in ipairs({
    "actors",
    "catalog",
    "playerOf",
    "currentMap",
    "world",
    "startScene",
    "scriptActive",
    "battleActive",
    "doublesEligible",
    "region",
    "fieldReady",
  }) do
    assert(opts[name] ~= nil, "trainer engagement requires " .. name)
  end
  return setmetatable({
    _actors = opts.actors,
    _catalog = opts.catalog,
    _playerOf = opts.playerOf,
    _currentMap = opts.currentMap,
    _world = opts.world,
    _startScene = opts.startScene,
    _scriptActive = opts.scriptActive,
    _battleActive = opts.battleActive,
    _doublesEligible = opts.doublesEligible,
    _region = opts.region,
    _fieldReady = opts.fieldReady,
    _effects = opts.effects or function()
      return nil
    end,
    _slots = nil,
    _disposed = false,
  }, TrainerEncounterCoordinator)
end

---@return integer? live map identity
function TrainerEncounterCoordinator:_liveMapId()
  local map = self._currentMap()
  return type(map) == "table" and map.mapId or nil
end

---@return HgssTrainerCatalog
function TrainerEncounterCoordinator:_requireCatalog()
  local owner = self._catalog()
  if owner == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "trainer engagement requires the trainer catalog", {})
  end
  return owner --[[@as HgssTrainerCatalog]]
end

---@param actorId string
---@return table<string, unknown>
function TrainerEncounterCoordinator:_requireActor(actorId)
  local actors = self._actors --[[@as table<string, unknown>]]
  local getActor = actors.getActor --[[@as fun(self: table, id: string): table<string, unknown>?]]
  local actor = getActor(actors, actorId)
  if actor == nil then
    Errors.raise(ScriptErrors.SCRIPT_ACTOR_NOT_FOUND, "the engagement actor is no longer on the map", {
      actor = actorId,
    })
  end
  return actor --[[@as table<string, unknown>]]
end

-- The live player an engagement runs beside. Engagement begins and ends with
-- the field player, so its absence is this owner's own broken state.
---@return table<string, unknown>
function TrainerEncounterCoordinator:_requirePlayer()
  local player = self._playerOf()
  if player == nil then
    Errors.raise(ScriptErrors.SCRIPT_ACTOR_NOT_FOUND, "trainer engagement requires the live player", {})
  end
  return assert(player, "an engagement always runs beside the live player")
end

-- The object actor id a trainer script's launch trigger names, or nil when the
-- trigger is not a script scope carrying one.
---@param trigger unknown
---@return string?
local function triggerActorId(trigger)
  if type(trigger) ~= "table" then
    return nil
  end
  local actorId = (trigger --[[@as table<string, unknown>]]).selfActor
  if type(actorId) ~= "string" then
    return nil
  end
  return actorId
end

---@param player table<string, unknown>
---@return { fieldX: integer, fieldZ: integer }
local function playerTile(player)
  return { fieldX = player.fieldX, fieldZ = player.fieldZ }
end

-- The produced trainer subject one source object carries, or nil for an object
-- that is not a trainer.
---@param actor table<string, unknown>
---@return table<string, unknown>?
local function trainerSubjectOf(actor)
  local event = actor.sourceEvent
  if type(event) ~= "table" then
    return nil
  end
  local subject = (event --[[@as table<string, unknown>]]).trainer
  return type(subject) == "table" and subject or nil
end

-- The running trainer script's own produced trainer subject. The launch trigger
-- names the object the script belongs to, and that object carries the native
-- trainer identity and its engagement-pair slot.
---@param self TrainerEncounterCoordinator
---@param trigger unknown
---@return table<string, unknown> subject, string actorId
function TrainerEncounterCoordinator:_scriptTrainer(trigger)
  local actorId = triggerActorId(trigger)
  if actorId == nil or actorId == "" then
    Errors.raise(ScriptErrors.SCRIPT_ACTOR_NOT_FOUND, "the trainer script names no object actor", {})
  end
  local scriptActorId = assert(actorId, "a started trainer script names its object actor")
  local subject = trainerSubjectOf(self:_requireActor(scriptActorId))
  if subject == nil then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the running script's object is not a trainer", {
      actor = scriptActorId,
    })
  end
  return assert(subject, "a running trainer script belongs to a trainer object"), scriptActorId
end

-- One ray step's resolved cursor over the movement owner's own placement
-- resolution: the committed height, surface and cell identity carry from tile
-- to tile, exactly like a walking actor, so a sight ray never invents a second
-- terrain model. The endpoint table is the placement owner's own record.
---@param actor table<string, unknown> the trainer's live actor
---@return { actor: table<string, unknown>, advance: fun(endpoint: table<string, unknown>) }
local function newSightCursor(actor)
  local state = actor:numericState()
  ---@return table<string, unknown> the committed state the next step resolves from
  local function committedState()
    return state
  end
  local view = {
    sourceEvent = actor.sourceEvent,
    cellKey = actor.cellKey,
    numericState = committedState,
  }
  local cursor = { actor = view }
  ---@param endpoint table<string, unknown>
  local function advance(endpoint)
    state = {
      fieldX = endpoint.fieldX,
      fieldZ = endpoint.fieldZ,
      worldX = endpoint.worldX,
      worldY = endpoint.worldY,
      worldZ = endpoint.worldZ,
      hasWorldPosition = 1,
      surfaceId = endpoint.surfaceId,
      hasSurfaceId = endpoint.surfaceId ~= nil and 1 or 0,
      sourceSurfaceId = endpoint.sourceSurfaceId,
      hasSourceSurfaceId = endpoint.sourceSurfaceId ~= nil and 1 or 0,
      resident = endpoint.resident == true and 1 or 0,
    }
    view.cellKey = endpoint.cellKey
  end
  cursor.advance = advance
  return cursor
end

-- The source sight occlusion test with the retail endpoint condition: every
-- intermediate tile must be reachable and unoccupied, and the final reachable
-- surface must be the player's actual occupied surface (not merely a walkable
-- tile at the player's X/Z). The committed player surface/cell/height facts
-- are carried at the engagement boundary; the last ray step proves player
-- occupancy through the existing placement/collision semantics, including
-- cross-cell cases. A walkable lower-level ray to the player's X/Z while the
-- player stands above it on a separate surface does not sight.
---@param actorId string the sighting trainer's actor
---@param direction string
---@param distance integer
---@param playerFacts table<string, unknown>? committed player occupancy, nil when unavailable
---@return boolean blocked
function TrainerEncounterCoordinator:_sightBlocked(actorId, direction, distance, playerFacts)
  if distance <= 0 then
    return true
  end
  local map = self._currentMap()
  local mapId = self:_liveMapId()
  if type(map) ~= "table" or mapId == nil then
    return true
  end
  local actors = self._actors --[[@as table<string, unknown>]]
  local getActor = actors.getActor --[[@as fun(self: table, id: string): table<string, unknown>?]]
  local actor = getActor(actors, actorId)
  if type(actor) ~= "table" then
    return true
  end
  local getCollisionAt = actors.getCollisionAt --[[@as fun(self: table, id: integer, candidate: table): table?]]
  local cursor = newSightCursor(actor)
  local finalEndpoint = nil
  for step = 1, distance do
    -- The movement owner raises ordinary placement rejections (a step beyond
    -- the reachable height, a tile outside coverage) as structured errors.
    -- Those are exactly the tiles a walking actor cannot cross, so the sight
    -- line is blocked; any other failure is corrupt or ambiguous state and
    -- keeps its own attribution.
    local ok, endpoint, blocked =
      pcall(FieldActorPlacement.resolveAdjacentDestination, map, cursor.actor, direction, true, true)
    if not ok then
      if FieldActorPlacement.isPlacementRejection(endpoint) then
        return true
      end
      error(endpoint, 0)
    end
    if endpoint == nil or blocked then
      return true
    end
    if step < distance then
      local occupant = getCollisionAt(actors, mapId, {
        fieldX = endpoint.fieldX,
        fieldZ = endpoint.fieldZ,
        surfaceId = endpoint.surfaceId,
        cellKey = endpoint.cellKey,
        sourceSurfaceId = endpoint.sourceSurfaceId,
      })
      if occupant ~= nil then
        return true
      end
    else
      finalEndpoint = endpoint
    end
    cursor.advance(endpoint)
  end
  if finalEndpoint == nil or playerFacts == nil then
    return true
  end
  local playerCandidate = {
    fieldX = playerFacts.fieldX,
    fieldZ = playerFacts.fieldZ,
    surfaceId = playerFacts.surfaceId,
    cellKey = playerFacts.cellKey,
    sourceSurfaceId = playerFacts.sourceSurfaceId,
  }
  local finalCandidate = {
    fieldX = finalEndpoint.fieldX,
    fieldZ = finalEndpoint.fieldZ,
    surfaceId = finalEndpoint.surfaceId,
    cellKey = finalEndpoint.cellKey,
    sourceSurfaceId = finalEndpoint.sourceSurfaceId,
  }
  if playerCandidate.fieldX ~= finalCandidate.fieldX or playerCandidate.fieldZ ~= finalCandidate.fieldZ then
    return true
  end
  -- Production players always carry their committed surface identity, and the
  -- endpoint proof requires it. Headless fakes without any surface fact keep
  -- the legacy X/Z-only admission so unit coverage without a physical map
  -- still exercises the ray geometry.
  local hasPlayerSurface = playerCandidate.surfaceId ~= nil
    or playerCandidate.cellKey ~= nil
    or playerCandidate.sourceSurfaceId ~= nil
  local hasFinalSurface = finalCandidate.surfaceId ~= nil
    or finalCandidate.cellKey ~= nil
    or finalCandidate.sourceSurfaceId ~= nil
  if hasPlayerSurface and hasFinalSurface then
    if not FieldActorPlacement.samePhysicalCandidate(map, finalCandidate, playerCandidate) then
      return true
    end
  elseif hasPlayerSurface ~= hasFinalSurface then
    return true
  end
  return false
end

-- Every produced trainer actor of the live map, in source object order. Only
-- the cheap source facts are carried here: the catalog's double mark and any
-- collision resolution are asked for by the selection module once a trainer
-- actually reaches the sight geometry.
---@param self TrainerEncounterCoordinator
---@return table<string, unknown>[]
function TrainerEncounterCoordinator:_trainerFacts()
  local actors = self._actors --[[@as table<string, unknown>]]
  local mapId = self:_liveMapId()
  if mapId == nil then
    return {}
  end
  local world = self:_world()
  local facts = {}
  local actorsOf = actors.actorsOf --[[@as fun(self: table, id: integer): table[] ]]
  local getPosition = actors.getPosition --[[@as fun(self: table, id: string): table<string, unknown>?]]
  local getFacing = actors.getFacing --[[@as fun(self: table, id: string): string?]]
  for _, actor in ipairs(actorsOf(actors, mapId)) do
    local subject = trainerSubjectOf(actor)
    if subject ~= nil and (subject.sightType == 1 or subject.sightType == 2) then
      local trainerId = subject.trainerId --[[@as integer]]
      if not world:isFlagSet(RuntimeValues.trainerFlagId(trainerId)) then
        local position = getPosition(actors, actor.actorId)
        if position ~= nil then
          facts[#facts + 1] = {
            id = actor.actorId,
            fieldX = position.fieldX,
            fieldZ = position.fieldZ,
            trainerId = trainerId,
            partner = subject.partner,
            sightType = subject.sightType,
            direction = getFacing(actors, actor.actorId),
            range = subject.sightRange,
            defeated = false,
          }
        end
      end
    end
  end
  return facts
end

-- The two resolvers the pure selection module asks for only once a trainer
-- reaches the geometry: the catalog's double mark by native trainer identity,
-- and this owner's one sight occlusion probe over the committed player
-- surface facts carried at the engagement boundary.
---@param playerFacts table<string, unknown>? committed player occupancy for the endpoint proof
---@return fun(trainerId: integer): boolean doubles
---@return fun(trainer: table<string, unknown>, direction: string, distance: integer): boolean sightBlocked
function TrainerEncounterCoordinator:_sightResolvers(playerFacts)
  local self_ = self
  local function doubles(trainerId)
    return HgssTrainerCatalog.isDouble(self_:_requireCatalog(), trainerId) == true
  end
  local function sightBlocked(trainer, direction, distance)
    return self_:_sightBlocked(assert(trainer.id), direction, distance, playerFacts)
  end
  return doubles, sightBlocked
end

---@return string? actorId of engagement slot 0, nil when nothing is engaged
function TrainerEncounterCoordinator:engagedActor()
  local slots = self._slots
  if slots == nil or slots[0] == nil then
    return nil
  end
  return slots[0].actorId --[[@as string]]
end

-- One source field tick of engagement upkeep: advance the running approaches
-- and drop the slots once their script environment is gone (the scene
-- finished, was cancelled, or the field moved on without it).
function TrainerEncounterCoordinator:updateFixed()
  if self._disposed or self._slots == nil then
    return
  end
  local stale = false
  local mapId = self:_liveMapId()
  local actors = self._actors --[[@as table<string, unknown>]]
  local getActor = actors.getActor --[[@as fun(self: table, id: string): table<string, unknown>?]]
  for _, slot in pairs(self._slots) do
    if
      slot.mapId ~= mapId or getActor(actors, slot.actorId --[[@as string]]) == nil
    then
      stale = true
    elseif slot.approach ~= nil and slot.approach.done ~= true then
      self:_advanceApproach(slot)
    end
  end
  if stale or (not self._scriptActive() and not self._battleActive()) then
    self:_clearEngagement()
  end
end

-- The source sight admission, run once per field tick before movement. Returns
-- true when this tick started a trainer scene.
---@return boolean engaged
function TrainerEncounterCoordinator:tryEngage()
  if self._disposed or self._slots ~= nil then
    return false
  end
  if self._scriptActive() or self._battleActive() or not self._fieldReady() then
    return false
  end
  local map = self._currentMap()
  if type(map) ~= "table" or map.collision == nil then
    return false
  end
  local player = self._playerOf()
  if player == nil then
    return false
  end
  local position = playerTile(player)
  local playerFacts = {
    fieldX = position.fieldX,
    fieldZ = position.fieldZ,
    surfaceId = player.surfaceId,
    cellKey = player.committedSourceCellKey,
    sourceSurfaceId = player.committedSourceSurfaceId,
    worldY = player.worldY,
  }
  local doubles, sightBlocked = self:_sightResolvers(playerFacts)
  local plan = TrainerBattleTrigger.check({
    player = { fieldX = position.fieldX, fieldZ = position.fieldZ, facing = player.facing },
    trainers = self:_trainerFacts(),
    doublesEligible = self._doublesEligible(),
    isDouble = doubles,
    sightBlocked = sightBlocked,
  })
  if plan == nil then
    return false
  end
  local sceneScript = nil
  local slots = {}
  for index, engaged in ipairs(plan.slots) do
    local actor = self:_requireActor(engaged.id --[[@as string]])
    local subject = assert(trainerSubjectOf(actor), "an engaged object is a trainer")
    sceneScript = sceneScript or subject.approachScript
    slots[index - 1] = {
      actorId = engaged.id,
      mapId = self:_liveMapId(),
      trainerId = engaged.trainerId,
      partner = engaged.partner,
      encounterType = plan.encounterType,
      direction = engaged.direction,
      distance = engaged.distance,
      index = index - 1,
      approach = nil,
      motion = nil,
    }
  end
  self._slots = slots
  assert(type(sceneScript) == "string", "the produced trainer object carries its approach scene identity")
  if
    not self._startScene(sceneScript --[[@as string]])
  then
    self._slots = nil
    return false
  end
  return true
end

-- Drops the slots and every motion they own. The leader keeps the facing its
-- approach left it with; nothing here is serialized.
function TrainerEncounterCoordinator:_clearEngagement()
  local slots = self._slots
  if slots ~= nil then
    for _, slot in pairs(slots) do
      self:_cancelMotion(slot)
    end
  end
  self._slots = nil
end

-- Cancels one slot's in-flight scripted motion.
---@param slot table<string, unknown>
function TrainerEncounterCoordinator:_cancelMotion(slot)
  if slot.motion == nil then
    return
  end
  slot.motion = nil
  local actors = self._actors --[[@as table<string, unknown>]]
  local cancel = actors.cancelScriptedMovement --[[@as fun(self: table, id: string)]]
  cancel(actors, slot.actorId)
end

---@param index integer
---@return table<string, unknown>
function TrainerEncounterCoordinator:_slot(index)
  local slot = self._slots ~= nil and self._slots[index] or nil
  if slot == nil then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the trainer engagement slot holds no actor", {
      slot = index,
    })
  end
  return slot --[[@as table<string, unknown>]]
end

-- Starts one scripted action on the slot's actor; the approach pumps it.
---@param slot table<string, unknown>
---@param action table<string, unknown>
function TrainerEncounterCoordinator:_beginMotion(slot, action)
  slot.motion = { action = action, progress = 0, duration = MovementCalibration.actionTicks(action) }
end

-- Advances the running action by one source tick. Returns true once it
-- finished during this tick.
---@param slot table<string, unknown>
---@return boolean finished
function TrainerEncounterCoordinator:_stepMotion(slot)
  local motion = assert(slot.motion, "the approach step runs an owned action")
  local actors = self._actors --[[@as table<string, unknown>]]
  local actorId = slot.actorId --[[@as string]]
  if motion.progress == 0 then
    local begin = actors.beginScriptedAction --[[@as fun(self: table, id: string, action: table)]]
    begin(actors, actorId, motion.action)
  end
  motion.progress = motion.progress + 1
  local advance = actors.advanceScriptedAction --[[@as fun(self: table, id: string, progress: integer, duration: integer)]]
  advance(actors, actorId, motion.progress, motion.duration)
  if motion.progress < motion.duration then
    return false
  end
  local commit = actors.commitScriptedAction --[[@as fun(self: table, id: string)]]
  commit(actors, actorId)
  slot.motion = nil
  return true
end

-- One source approach tick. Each phase answers true to continue inside the same
-- tick (the native state loop) or false when the tick is spent waiting.
---@param slot table<string, unknown>
---@return boolean more
function TrainerEncounterCoordinator:_approachTick(slot)
  local approach = assert(slot.approach, "the approach tick runs an owned approach")
  local actors = self._actors --[[@as table<string, unknown>]]
  local actorId = slot.actorId --[[@as string]]
  local isScriptedMoving = actors.isScriptedMoving --[[@as fun(self: table, id: string): boolean]]
  local phase = approach.phase
  if phase == "unpause" then
    if isScriptedMoving(actors, actorId) then
      return false
    end
    approach.phase = "face"
    return true
  end
  if phase == "face" then
    if isScriptedMoving(actors, actorId) then
      return false
    end
    if slot.motion == nil then
      local setFacing = actors.setFacing --[[@as fun(self: table, id: string, direction: string)]]
      setFacing(actors, actorId, slot.direction --[[@as string]])
      approach.phase = "wait_player"
      return true
    end
    return false
  end
  if phase == "wait_player" then
    local player = self:_requirePlayer()
    if player:presentationState().locomotionActive == true then
      return false
    end
    local actor = self:_requireActor(actorId)
    local selector = HgssTrainerCatalog.nativeMovement(self:_requireCatalog(), actor.movementType --[[@as string]])
    approach.reveal = selector ~= nil and REVEAL_MOVEMENT_SELECTORS[selector] == true
    approach.phase = approach.reveal and "reveal" or "face_anim"
    return true
  end
  if phase == "reveal" then
    if slot.motion == nil then
      self:_beginMotion(slot, { action = "reveal_trainer" })
      local effects = self._effects()
      if effects ~= nil then
        local getPosition = actors.getPosition --[[@as fun(self: table, id: string): table<string, unknown>]]
        local at = getPosition(actors, actorId)
        effects:emit({ kind = "trainer_reveal", fieldX = at.fieldX, fieldZ = at.fieldZ, worldY = at.worldY or 0 })
      end
      return false
    end
    if self:_stepMotion(slot) then
      approach.phase = "wait"
      return true
    end
    return false
  end
  if phase == "face_anim" then
    if slot.motion == nil then
      self:_beginMotion(slot, { action = "face", direction = slot.direction })
      return false
    end
    if self:_stepMotion(slot) then
      approach.phase = "exclaim"
      return true
    end
    return false
  end
  if phase == "exclaim" then
    if slot.motion == nil then
      self:_beginMotion(slot, { action = "emote", name = "exclamation" })
      return false
    end
    if self:_stepMotion(slot) then
      approach.phase = "wait"
      return true
    end
    return false
  end
  if phase == "wait" then
    approach.timer = (approach.timer or 0) + 1
    if approach.timer < APPROACH_WAIT_TICKS then
      return false
    end
    approach.timer = 0
    approach.phase = approach.remaining --[[@as integer]] <= 1 and "arrived" or "step"
    return true
  end
  if phase == "step" then
    if slot.motion == nil then
      self:_beginMotion(slot, { action = "walk", direction = slot.direction, speed = "normal" })
      return false
    end
    if self:_stepMotion(slot) then
      approach.remaining = approach.remaining --[[@as integer]] - 1
      approach.phase = "wait"
      return true
    end
    return false
  end
  if phase == "arrived" then
    approach.timer = (approach.timer or 0) + 1
    if approach.timer < APPROACH_ARRIVED_TICKS then
      return false
    end
    approach.timer = 0
    approach.phase = "turn_player"
    return true
  end
  if phase == "turn_player" then
    local player = self:_requirePlayer()
    local position = playerTile(player)
    local getPosition = actors.getPosition --[[@as fun(self: table, id: string): table<string, unknown>]]
    local at = getPosition(actors, actorId)
    local facing = directionTowards(position.fieldX, position.fieldZ, at.fieldX, at.fieldZ)
    if
      facing ~= nil
      and facing ~= player.facing
      and (slot.index == 0 or slot.encounterType == TrainerBattleTrigger.ENCOUNTER_TWO_TRAINERS)
    then
      player:turn(facing)
    end
    approach.phase = "reset"
    return true
  end
  if phase == "reset" then
    self:_cancelMotion(slot)
    local setMovementType = actors.setMovementType --[[@as fun(self: table, id: string, movementType: string)]]
    setMovementType(actors, actorId, "stationary")
    approach.phase = "done"
    approach.done = true
    return false
  end
  error("unknown trainer approach phase " .. tostring(phase), 0)
end

---@param slot table<string, unknown>
function TrainerEncounterCoordinator:_advanceApproach(slot)
  local approach = assert(slot.approach, "advancing a trainer approach needs its state")
  while self:_approachTick(slot) do
    if approach.done == true then
      return
    end
  end
end

-- ScrCmd_GetTrainerPathToPlayer: starts the source approach for one slot in the
-- same tick the command runs.
---@param index unknown
function TrainerEncounterCoordinator:startApproach(index)
  local slot = self:_slot(checkSlotIndex(index))
  slot.approach = { phase = "unpause", remaining = slot.distance, timer = 0, done = false }
end

-- ScrCmd_TrainerStepTowardsPlayer: answers 0 while the approach runs and 1 once
-- it finished or none is live. A finished approach is dropped, exactly like the
-- deleted native task.
---@param index unknown
---@return integer
function TrainerEncounterCoordinator:stepApproach(index)
  local slot = self._slots ~= nil and self._slots[checkSlotIndex(index)] or nil
  if slot == nil or slot.approach == nil then
    return 1
  end
  if slot.approach.done == true then
    self:_cancelMotion(slot)
    slot.approach = nil
    return 1
  end
  return 0
end

-- ScrCmd_GetTrainerEyeType: the encounter type engagement slot 0 carries.
---@return integer
function TrainerEncounterCoordinator:encounterType()
  return self:_slot(0).encounterType --[[@as integer]]
end

-- ScrCmd_GetEyeTrainerNum: the native trainer number of one engagement slot.
---@param index unknown
---@return integer
function TrainerEncounterCoordinator:engagementTrainer(index)
  return self:_slot(checkSlotIndex(index)).trainerId --[[@as integer]]
end

-- ScrCmd_GetTrainerNum: the running trainer script's own native trainer number.
---@param trigger unknown
---@return integer
function TrainerEncounterCoordinator:activeTrainerNumber(trigger)
  local subject = self:_scriptTrainer(trigger)
  return subject.trainerId --[[@as integer]]
end

-- ScrCmd_TrainerMessage: the source field speech for one trainer/message kind
-- pair, or nil when the pair is absent (the source then prints its empty
-- message).
---@param trainerId unknown
---@param kind unknown
---@return table<string, unknown>? message location
function TrainerEncounterCoordinator:fieldMessage(trainerId, kind)
  return HgssTrainerCatalog.fieldMessage(self:_requireCatalog(), trainerId --[[@as integer]], kind --[[@as integer]])
end

-- ScrCmd_GetTrainerMsgParams/GetRematchMsgParams: the source's three ordered
-- message kinds for the running trainer script. The double pair answers its own
-- first/second slot variants, and the single-mon refusal kind is the third.
---@param trigger unknown
---@param rematch boolean
---@return { intro: integer, after: integer, shortIntro: integer }
function TrainerEncounterCoordinator:messageParams(trigger, rematch)
  local subject = self:_scriptTrainer(trigger)
  local isDouble = HgssTrainerCatalog.isDouble(self:_requireCatalog(), subject.trainerId --[[@as integer]])
  local second = subject.partner == "second"
  if rematch then
    if not isDouble then
      return { intro = 17, after = 0, shortIntro = 0 }
    end
    if not second then
      return { intro = 18, after = 0, shortIntro = 6 }
    end
    return { intro = 19, after = 0, shortIntro = 10 }
  end
  if not isDouble then
    return { intro = 0, after = 2, shortIntro = 0 }
  end
  if not second then
    return { intro = 3, after = 5, shortIntro = 6 }
  end
  return { intro = 7, after = 9, shortIntro = 10 }
end

-- ScrCmd_TrainerIsDoubleBattle: the running trainer record's own double mark.
---@param trigger unknown
---@return boolean
function TrainerEncounterCoordinator:isDoubleTrainer(trigger)
  local subject = self:_scriptTrainer(trigger)
  return HgssTrainerCatalog.isDouble(self:_requireCatalog(), subject.trainerId --[[@as integer]])
end

-- ScrCmd_EncounterMusic: the trainer class's eyes-meet sequence for the map's
-- native region.
---@param trainerId unknown
---@return string
function TrainerEncounterCoordinator:encounterMusic(trainerId)
  local sequence =
    HgssTrainerCatalog.encounterMusic(self:_requireCatalog(), trainerId --[[@as integer]], self._region())
  if sequence == nil then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the trainer carries no eyes-meet sequence", {
      trainer = tostring(trainerId),
    })
  end
  return sequence --[[@as string]]
end

-- ScrCmd_SetLastTalkedTrainerMovement: rewrites the talked-to trainer's live
-- movement from its facing, and its double-battle pair partner's with it.
---@param trigger unknown
function TrainerEncounterCoordinator:lastTalkedMovement(trigger)
  local actorId = triggerActorId(trigger)
  if actorId == nil or actorId == "" then
    return
  end
  local actors = self._actors --[[@as table<string, unknown>]]
  local getActor = actors.getActor --[[@as fun(self: table, id: string): table<string, unknown>?]]
  local actor = getActor(actors, actorId)
  if actor == nil then
    return
  end
  local facing = (actors.getFacing --[[@as fun(self: table, id: string): string]])(actors, actorId)
  local selector = MOVEMENT_SELECTOR_BY_FACING[facing]
  if selector == nil then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the talked-to trainer faces no cardinal direction", {
      actor = actorId,
      facing = tostring(facing),
    })
  end
  local movementType = HgssTrainerCatalog.movementType(self:_requireCatalog(), selector --[[@as integer]])
  if movementType == nil then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the trainer catalog carries no such movement selector", {
      selector = selector,
    })
  end
  local setMovementType = actors.setMovementType --[[@as fun(self: table, id: string, movementType: string)]]
  local subject = trainerSubjectOf(actor)
  if subject ~= nil then
    local mapId = self:_liveMapId()
    local actorsOf = actors.actorsOf --[[@as fun(self: table, id: integer): table[] ]]
    for _, peer in ipairs(mapId ~= nil and actorsOf(actors, mapId) or {}) do
      local peerSubject = trainerSubjectOf(peer)
      if
        peer.actorId ~= actorId
        and peerSubject ~= nil
        and peerSubject.trainerId == subject.trainerId
        and type(peerSubject.sightType) == "number"
        and (peerSubject.sightType == 1 or peerSubject.sightType == 2)
      then
        setMovementType(actors, peer.actorId, movementType --[[@as string]])
        break
      end
    end
  end
  setMovementType(actors, actorId, movementType --[[@as string]])
end

-- ScrCmd_GetObjectMovementType: the actor's current native movement selector.
---@param actorId string
---@return integer
function TrainerEncounterCoordinator:movementSelector(actorId)
  local actor = self:_requireActor(actorId)
  local selector = HgssTrainerCatalog.nativeMovement(self:_requireCatalog(), actor.movementType --[[@as string]])
  if selector == nil then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the actor's movement type has no native selector", {
      actor = actorId,
      movementType = tostring(actor.movementType),
    })
  end
  return selector --[[@as integer]]
end

function TrainerEncounterCoordinator:dispose()
  if self._disposed then
    return
  end
  self:_clearEngagement()
  self._disposed = true
end

return TrainerEncounterCoordinator
