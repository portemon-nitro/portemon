-- The Ecruteak Gym candles over the field's own owners: the four source medium
-- trainers carry their candles, a binding follows exactly the trainer the
-- engagement context names, and the extinguish task walks the source delay,
-- shrink scales, sprite replacement and the union's committed candle bit.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldObjectActor = require("libs.hgss.src.actors.FieldObjectActor")
local GymMechanismState = require("libs.hgss.src.field.GymMechanismState")
local EcruteakGym = require("libs.hgss.src.field.gymmick.EcruteakGym")

local T = {}

local MAP_ID = 80

-- The four source medium object plateaus, in the gym's own object order.
local MEDIUM_POSITIONS = {
  [2] = { fieldX = 4, fieldZ = 6, worldX = 4.5, worldY = 0, worldZ = 6.5 },
  [3] = { fieldX = 10, fieldZ = 6, worldX = 10.5, worldY = 0, worldZ = 6.5 },
  [4] = { fieldX = 4, fieldZ = 12, worldX = 4.5, worldY = 0, worldZ = 12.5 },
  [5] = { fieldX = 11, fieldZ = 19, worldX = 11.5, worldY = 0, worldZ = 19.5 },
}

local function newHost(options)
  options = options or {}
  local host = { effects = {}, sprites = {} }
  host.actorsById = {}
  for objectEventId, point in pairs(MEDIUM_POSITIONS) do
    if options.present == nil or options.present[objectEventId] ~= false then
      local actorId = FieldObjectActor.actorId(MAP_ID, objectEventId)
      host.actorsById[actorId] = {
        actorId = actorId,
        objectEventId = objectEventId,
        spriteId = 219,
        worldX = point.worldX,
        worldY = point.worldY,
        worldZ = point.worldZ,
        getWorldPosition = function(self)
          return { x = self.worldX, y = self.worldY, z = self.worldZ }
        end,
      }
    end
  end
  -- The gym's other source objects carry no candle.
  local bystanderId = FieldObjectActor.actorId(MAP_ID, 6)
  host.actorsById[bystanderId] = {
    actorId = bystanderId,
    objectEventId = 6,
    spriteId = 219,
    worldX = 9.5,
    worldY = 0,
    worldZ = 9.5,
    getWorldPosition = function()
      return { x = 9.5, y = 0, z = 9.5 }
    end,
  }
  host.actors = {
    getById = function(_, actorId)
      return host.actorsById[actorId]
    end,
    setSprite = function(_, actorId, spriteId)
      local actor = assert(host.actorsById[actorId], "the sprite swap names a live actor")
      actor.spriteId = spriteId
      host.sprites[#host.sprites + 1] = { actorId = actorId, spriteId = spriteId }
    end,
  }
  host.audio = {
    play = function(_, sound)
      host.effects[#host.effects + 1] = "play:" .. sound
    end,
  }
  host.state = GymMechanismState.restore({
    schema = GymMechanismState.SCHEMA,
    kind = options.kind or "ecruteak",
    data = options.data or { candles = { false, false, false, false } },
  })
  host.gym = EcruteakGym.new({
    state = host.state,
    actors = host.actors,
    audio = host.audio,
    mapId = MAP_ID,
  })
  return host
end

local function mediumActorId(objectEventId)
  return FieldObjectActor.actorId(MAP_ID, objectEventId)
end

-- Every candle placement, keyed by its source candle index.
local function placementsByIndex(host)
  local byIndex = {}
  for _, placement in ipairs(host.gym:candlePlacements()) do
    byIndex[placement.index] = placement
  end
  return byIndex
end

-- The source object -> candle mapping is the four medium objects in order.
function T.every_source_medium_object_carries_its_own_candle()
  Assert.equal(EcruteakGym.candleIndexForObjectEvent(2), 1)
  Assert.equal(EcruteakGym.candleIndexForObjectEvent(3), 2)
  Assert.equal(EcruteakGym.candleIndexForObjectEvent(4), 3)
  Assert.equal(EcruteakGym.candleIndexForObjectEvent(5), 4)
  Assert.isNil(EcruteakGym.candleIndexForObjectEvent(6), "the old man carries no candle")

  local host = newHost()
  local placements = placementsByIndex(host)
  Assert.equal(#host.gym:candlePlacements(), 4, "the gym presents one candle per medium trainer")
  for index = 1, 4 do
    local placement = assert(placements[index], "candle " .. index .. " is placed")
    Assert.equal(placement.actorId, mediumActorId(index + 1), "candle " .. index .. " stands on its own trainer")
    Assert.near(placement.scale, 1, 1e-9, "a fresh candle carries the source scale one")
    Assert.isFalse(placement.culled, "a fresh candle is not hidden")
  end
end

-- Binding follows the live trainer, so the presented candle moves with it every
-- tick; unbinding stops the follow and a map teardown leaves no stale trainer.
function T.binding_follows_the_engaged_trainer_and_never_leaves_a_stale_actor()
  local host = newHost()
  host.gym:bindCandle(mediumActorId(5))
  Assert.equal(host.gym:boundActorId(), mediumActorId(5))

  local actor = assert(host.actorsById[mediumActorId(5)])
  actor.worldX, actor.worldZ = 3.5, 4.5
  local moved = placementsByIndex(host)[4]
  Assert.near(moved.x, 3.5, 1e-9, "the bound candle follows its trainer in x")
  Assert.near(moved.z, 4.5, 1e-9, "the bound candle follows its trainer in z")

  host.gym:unbindCandle()
  Assert.isNil(host.gym:boundActorId(), "unbinding releases the followed trainer")
  host.gym:bindCandle(mediumActorId(5))
  host.gym:dispose()
  Assert.isNil(host.gym:boundActorId(), "a disposed mechanism never keeps a stale actor")
end

-- The source asserts on a trainer that does not carry one of the four candles.
function T.a_candle_command_needs_one_of_the_gyms_own_medium_trainers()
  local host = newHost()
  local ok, err = pcall(function()
    host.gym:bindCandle(FieldObjectActor.actorId(MAP_ID, 6))
  end)
  Assert.isFalse(ok, "the old man is not a candle trainer")
  Assert.isTrue(Errors.is(err), "the failure is a structured error")
  Assert.equal(err.code, "FIELD_GYM_MECHANISM_INVALID")
  Assert.equal(err.context.objectEventId, 6)

  local missing = pcall(function()
    host.gym:bindCandle(FieldObjectActor.actorId(MAP_ID, 42))
  end)
  Assert.isFalse(missing, "an actor the map does not carry fails too")
end

-- The source task: the timer past its threshold plays the candle sound, three
-- shrink steps walk 1/2, 1/3 and 1/4, and the last step hides the candle,
-- commits its saved bit and replaces the trainer's billboard.
function T.extinguishing_runs_the_source_delay_scales_sprite_and_settled_bit()
  local host = newHost()
  host.gym:beginExtinguish(mediumActorId(5))
  Assert.isFalse(host.gym:isExtinguishComplete(), "the task runs until its sprite step settled")

  for _ = 1, EcruteakGym.DELAY_TICKS do
    host.gym:updateFixed()
  end
  Assert.equal(#host.effects, 0, "the source delay is silent until its threshold")
  local delayed = placementsByIndex(host)[4]
  Assert.near(delayed.scale, 1, 1e-9, "the candle keeps its full scale through the delay")

  host.gym:updateFixed()
  Assert.deepEqual(host.effects, { "play:" .. EcruteakGym.EXTINGUISH_SEQUENCE })

  local scales = {}
  for _ = 1, 3 do
    host.gym:updateFixed()
    scales[#scales + 1] = placementsByIndex(host)[4].scale
  end
  Assert.near(scales[1], 1 / 2, 1e-9, "the first shrink step halves the candle")
  Assert.near(scales[2], 1 / 3, 1e-9, "the second shrink step takes a third")
  Assert.near(scales[3], 1 / 4, 1e-9, "the third shrink step takes a quarter")
  Assert.isFalse(placementsByIndex(host)[4].culled, "the candle is still drawn on the last scale")
  Assert.equal(#host.sprites, 0, "the trainer's billboard is untouched before the shrink ends")

  host.gym:updateFixed()
  Assert.deepEqual(host.state:ecruteakCandles(), { false, false, false, true }, "the settled bit names one candle")
  Assert.isTrue(placementsByIndex(host)[4].culled, "the extinguished candle is hidden")
  Assert.deepEqual(host.sprites, { { actorId = mediumActorId(5), spriteId = EcruteakGym.EXTINGUISHED_SPRITE_ID } })
  Assert.isFalse(host.gym:isExtinguishComplete(), "the source waits for the replaced billboard")

  host.gym:updateFixed()
  Assert.isTrue(host.gym:isExtinguishComplete())
end

-- A restored union hides exactly the candles it names, at full scale.
function T.a_restored_union_hides_only_its_settled_candles()
  local host = newHost({ data = { candles = { true, false, true, false } } })
  local placements = placementsByIndex(host)
  Assert.isTrue(placements[1].culled)
  Assert.isFalse(placements[2].culled)
  Assert.isTrue(placements[3].culled)
  Assert.isFalse(placements[4].culled)
  Assert.near(placements[1].scale, 1, 1e-9, "a restored candle keeps the scale its own record implies")
end

-- The gym's own fog state is the source's: black, with the density table
-- disabling fog at every depth.
function T.the_gym_fog_is_the_source_fog_state()
  Assert.isFalse(EcruteakGym.FOG.enabled)
  Assert.equal(EcruteakGym.FOG.color, 0, "the gym's fog colour is black")
  Assert.equal(#EcruteakGym.FOG.table, 32)
  for index, value in ipairs(EcruteakGym.FOG.table) do
    Assert.equal(value, -1, "density entry " .. index .. " disables fog")
  end
end

-- A trainer absent from the live map presents no candle instead of a prop at a
-- stale point.
function T.an_absent_trainer_presents_no_candle()
  local host = newHost({ present = { [3] = false } })
  local placements = placementsByIndex(host)
  Assert.isNil(placements[2], "a missing medium trainer has no candle")
  Assert.notNil(placements[1])
end

-- Cancelling the task returns the in-flight shrink to its settled scale and
-- never commits a partial state.
function T.cancelling_an_extinguish_restores_the_settled_scale()
  local host = newHost()
  host.gym:beginExtinguish(mediumActorId(5))
  for _ = 1, EcruteakGym.DELAY_TICKS + 2 do
    host.gym:updateFixed()
  end
  Assert.near(placementsByIndex(host)[4].scale, 1 / 2, 1e-9)
  host.gym:cancelExtinguish()
  Assert.isTrue(host.gym:isExtinguishComplete())
  Assert.near(placementsByIndex(host)[4].scale, 1, 1e-9, "the candle returns to its settled scale")
  Assert.deepEqual(host.state:ecruteakCandles(), { false, false, false, false }, "no candle was committed")
end

return { tests = T }
