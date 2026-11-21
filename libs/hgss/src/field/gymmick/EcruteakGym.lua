-- The Ecruteak Gym candles (src/field/gymmick/ecruteak.c). Four candle props
-- stand on the four medium trainer objects the gym's own map data declares
-- (obj_T27GYM0101_itako .. itako_4, files/fielddata/script/scr_seq/
-- event_T27GYM0101.h), so a candle's position IS its trainer's position: a
-- binding only remembers which trainer the engaged slot names, and the
-- presented candle follows that trainer's live world point on the same fixed
-- tick.
--
-- Extinguishing is the source task's own three phases: the delay counts the
-- timer past the source threshold, the shrink walks the candle through
-- FX32_ONE/2, /3 and /4, and the last shrink step hides the candle, commits
-- its saved state and replaces the trainer's billboard with the extinguished
-- sprite. The gym keeps its own black fog, which the map environment gets when
-- the saved union loads an Ecruteak mechanism (GymmickInit_Ecruteak).
--
-- The engaged and last-interacted trainer identities are the source script
-- environment's own attributes (SCRIPTENV_ENGAGED_TRAINER_0_EVENT and
-- SCRIPTENV_LAST_INTERACTED). This leaf reads them from the mechanism's
-- injected trainer context, so the candle mechanism never invents an
-- interaction the source did not perform.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldObjectActor = require("libs.hgss.src.actors.FieldObjectActor")

---@class EcruteakGymOptions
---@field state GymMechanismState the saved union this mechanism settles
---@field actors table<string, unknown> the live actor owner
---@field audio table<string, unknown> the source audio host
---@field mapId integer the gym's map whose medium objects carry the candles

---@class EcruteakGym.CandlePlacement
---@field index integer the one-based source candle index
---@field actorId string the medium trainer object the candle stands on
---@field x number
---@field y number
---@field z number
---@field scale number the source shrink scale
---@field culled boolean the source has hidden this candle

---@class EcruteakGym
---@field private _state GymMechanismState
---@field private _actors table<string, unknown>
---@field private _audio table<string, unknown>
---@field private _mapId integer
---@field private _bound { actorId: string, candleIndex: integer }|nil the followed trainer
---@field private _scales number[]
---@field private _task table<string, unknown>|nil the extinguish task
local EcruteakGym = {}
EcruteakGym.__index = EcruteakGym

-- src/field/gymmick/ecruteak.c::NUM_CANDLES and the four source medium
-- object ids the candle index maps onto (MortyGymTrainerObjectToCandleIdx).
EcruteakGym.CANDLE_COUNT = 4
EcruteakGym.MEDIUM_OBJECT_EVENT_IDS = { 2, 3, 4, 5 }

-- SPRITE_ITAKO_ (include/constants/sprites.h): the medium trainer's burnt
-- sprite, and the candle sound the source plays when the delay expires.
EcruteakGym.EXTINGUISHED_SPRITE_ID = 250
EcruteakGym.EXTINGUISH_SEQUENCE = "SEQ_SE_GS_ROUSOKU_KIERU"

-- The source delay gate: `if (taskData->delayTimer++ >= 30)`.
EcruteakGym.DELAY_TICKS = 30
-- The source shrink's own scale factors, and the factor at which the candle
-- is hidden, committed and its trainer's sprite replaced.
EcruteakGym.LAST_SCALE_FACTOR = 4

-- src/field/gymmick/ecruteak.c::GymmickInit_Ecruteak installs the gym's fog:
-- blend alpha, colour 0 (black) and the slope below, with every density table
-- entry -1, which disables fog at every depth. The port publishes the same
-- state as the fog-off preset it already draws with, keeping the source colour
-- and slope so the record states what the source set.
local FOG_TABLE_ENTRIES = 32
local fogTable = {}
for index = 1, FOG_TABLE_ENTRIES do
  fogTable[index] = -1
end
EcruteakGym.FOG = {
  enabled = false,
  color = 0,
  alpha = 0,
  offset = 0,
  slope = 0x0020,
  table = fogTable,
}

-- The source's own object -> candle map. The source treats an object outside
-- the quartet as its own assertion failure, so this answers nil and the caller
-- reports it.
---@param objectEventId integer
---@return integer|nil candleIndex one-based
function EcruteakGym.candleIndexForObjectEvent(objectEventId)
  for index, sourceObjectEventId in ipairs(EcruteakGym.MEDIUM_OBJECT_EVENT_IDS) do
    if sourceObjectEventId == objectEventId then
      return index
    end
  end
  return nil
end

---@param options EcruteakGymOptions
---@return EcruteakGym
function EcruteakGym.new(options)
  assert(type(options) == "table", "the ecruteak mechanism needs its collaborators")
  assert(options.state and options.state.ecruteakCandles, "the ecruteak mechanism owns the saved union")
  assert(options.actors and options.actors.getById, "the ecruteak mechanism needs the actor owner")
  assert(options.actors.setSprite, "the ecruteak mechanism replaces its trainers' billboards")
  assert(options.audio and options.audio.play, "the ecruteak mechanism needs the source audio host")
  assert(
    type(options.mapId) == "number" and options.mapId % 1 == 0,
    "the ecruteak mechanism binds one map's medium objects"
  )
  return setmetatable({
    _state = options.state,
    _actors = options.actors,
    _audio = options.audio,
    _mapId = options.mapId,
    _bound = nil,
    _scales = { 1, 1, 1, 1 },
    _task = nil,
  }, EcruteakGym)
end

---@param message string
---@param context table<string, unknown>
local function invalid(message, context)
  Errors.raise(FieldErrors.FIELD_GYM_MECHANISM_INVALID, message, context)
end

-- The candle index one actor identity stands for, exactly like the source's
-- object id scan. A missing actor or an object outside the quartet is the
-- source assertion, reported with the identity that failed it.
---@param actorId string
---@return integer candleIndex one-based
function EcruteakGym:candleIndexForActor(actorId)
  if type(actorId) ~= "string" or actorId == "" then
    invalid("an ecruteak candle command needs its source trainer actor", { actorId = tostring(actorId) })
  end
  local actor = self._actors:getById(actorId)
  if actor == nil then
    invalid("the ecruteak candle command names no live trainer actor", { actorId = actorId })
  end
  assert(actor ~= nil, "a candle trainer is a live actor")
  local candleIndex = EcruteakGym.candleIndexForObjectEvent(actor.objectEventId)
  if candleIndex == nil then
    invalid("the ecruteak candle command names an object the gym carries no candle for", {
      actorId = actorId,
      objectEventId = actor.objectEventId,
    })
  end
  return assert(candleIndex)
end

-- ScrCmd_EcruteakGymBindCandleToTrainer: follow one trainer with its candle
-- until the matching unbind. A second binding replaces the first, exactly like
-- the source overwriting its single local tracker.
---@param actorId string
function EcruteakGym:bindCandle(actorId)
  self._bound = { actorId = actorId, candleIndex = self:candleIndexForActor(actorId) }
end

-- ScrCmd_EcruteakGymUnbindCandleFromTrainer: the follow tracker ends. The
-- source destroys a task it created; an unbind with no binding is a no-op
-- rather than a fault, so a cancelled interaction cannot leak a stale trainer.
function EcruteakGym:unbindCandle()
  self._bound = nil
end

---@return string|nil actorId the trainer this mechanism currently follows
function EcruteakGym:boundActorId()
  local bound = self._bound
  return bound ~= nil and bound.actorId or nil
end

-- ScrCmd_EcruteakGymExtinguishCandle starts the source task for the trainer
-- the resolved selector names.
---@param actorId string
function EcruteakGym:beginExtinguish(actorId)
  assert(self._task == nil, "an ecruteak candle is already being extinguished")
  self._task = {
    actorId = actorId,
    candleIndex = self:candleIndexForActor(actorId),
    phase = "delay",
    delayTimer = 0,
    scaleFactor = 1,
  }
end

---@return boolean
function EcruteakGym:isExtinguishComplete()
  return self._task == nil or self._task.phase == "done"
end

-- One fixed tick of the source extinguish task (Task_ExtinguishCandle). Only
-- the source's own phases advance here; the settled state is committed at the
-- source's own shrink boundary.
function EcruteakGym:updateFixed()
  local task = self._task
  if task == nil or task.phase == "done" then
    return
  end
  if task.phase == "delay" then
    -- The source tests the timer before incrementing it: the sound and the
    -- first shrink start on the tick after the delay expired.
    if task.delayTimer >= EcruteakGym.DELAY_TICKS then
      self._audio:play(EcruteakGym.EXTINGUISH_SEQUENCE)
      task.phase = "shrink"
    end
    task.delayTimer = task.delayTimer + 1
    return
  end
  if task.phase == "shrink" then
    local candleIndex = assert(task.candleIndex)
    if task.scaleFactor >= EcruteakGym.LAST_SCALE_FACTOR then
      self._state:setEcruteakCandle(candleIndex, true)
      self._actors:setSprite(task.actorId, EcruteakGym.EXTINGUISHED_SPRITE_ID)
      task.phase = "sprite"
    else
      task.scaleFactor = task.scaleFactor + 1
    end
    self._scales[candleIndex] = 1 / task.scaleFactor
    return
  end
  -- CANDLE_STATE_WAIT_SPRITE. The source waits for the replaced billboard to
  -- become ready; this port acquires an actor's visual from the resident actor
  -- set synchronously, so the replacement is ready on the next fixed tick and
  -- there is no asynchronous billboard to wait for.
  task.phase = "done"
end

-- The four candle placements the presentation draws: a candle stands on its
-- own trainer's current world point and carries the source shrink scale and
-- cull state. A trainer absent from the live map presents no candle.
---@return EcruteakGym.CandlePlacement[]
function EcruteakGym:candlePlacements()
  local candles = self._state:ecruteakCandles()
  local placements = {}
  for index, objectEventId in ipairs(EcruteakGym.MEDIUM_OBJECT_EVENT_IDS) do
    local actorId = FieldObjectActor.actorId(self._mapId, objectEventId)
    local actor = self._actors:getById(actorId)
    local point = actor ~= nil and actor:getWorldPosition() or nil
    if point ~= nil and point.x ~= nil and point.y ~= nil and point.z ~= nil then
      placements[#placements + 1] = {
        index = index,
        actorId = actorId,
        x = point.x,
        y = point.y,
        z = point.z,
        scale = self._scales[index],
        culled = candles[index],
      }
    end
  end
  return placements
end

-- Abandon a running extinguish. The source's own task would keep running to
-- its shrink commit; a cancelled script leaves no task to poll here, so the
-- in-flight shrink returns to the candle's settled scale and the union keeps the
-- last state it committed.
function EcruteakGym:cancelExtinguish()
  local task = self._task
  if task == nil then
    return
  end
  self._scales[assert(task.candleIndex)] = 1
  self._task = nil
end

-- Release the live tracker and any running task: leaving the map never leaves
-- a stale trainer behind.
function EcruteakGym:dispose()
  self._bound = nil
  self._task = nil
end

return EcruteakGym
