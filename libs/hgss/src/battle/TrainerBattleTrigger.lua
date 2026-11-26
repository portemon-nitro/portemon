-- Source trainer sight and engagement selection (src/map_object_behavior.c:
-- TrainerSight_FindPlayer, CheckSeenByNpcTrainers and TryGetSeenByNpcTrainers).
-- This module only plans: it decides which trainers see the player along their
-- own directional rays and which native engagement shape the scene opens with.
-- Actor motion, the approach scene and the battles belong to the field/script
-- owners, which consume the returned plan.
--
-- Facts shape (plain data from the actor/world owners):
--   facts = {
--     player = { fieldX: integer, fieldZ: integer, facing: string },
--     doublesEligible = boolean,
--     trainers = {
--       { id: string, fieldX: integer, fieldZ: integer, trainerId: integer,
--         partner: "first"|"second", sightType: integer, direction: string?,
--         range: integer, defeated: boolean? }, ...
--     },
--     -- Resolved only for candidates that actually reach the geometry:
--     sightBlocked = fun(trainer: table, direction: string, distance: integer): boolean,
--     isDouble = fun(trainerId: integer): boolean,
--   }
-- Sight is the source's own directional rule, never tile proximity: a trainer
-- of sight type 1 looks along its facing, a type 2 trainer looks in all four
-- directions, and types 0 and 3 never sight. The player must stand on that
-- exact row or column inside the trainer's range, and every tile between the
-- two must stay clear (the caller resolves collision through the one
-- sightBlocked resolver, which also verifies the player endpoint).
--
-- Selection follows TryGetSeenByNpcTrainers: the first sighted trainer in
-- source order decides the shape. A trainer whose own record marks a double
-- battle engages only with at least two usable party mons, and then engages
-- together with its pair partner as the native one-trainer double. Every other
-- trainer engages alone, or together with the next sighted trainer as two
-- independent opponents when the party can field a double.

---@class TrainerBattleTrigger
local TrainerBattleTrigger = {}

-- The source direction order DIR_NORTH..DIR_EAST: an all-direction sight tier
-- scans in this order.
TrainerBattleTrigger.DIRECTIONS = { "north", "south", "west", "east" }

-- The engagement shapes the approach scene reads through ScrCmd_GetTrainerEyeType.
TrainerBattleTrigger.ENCOUNTER_SINGLE = 0
TrainerBattleTrigger.ENCOUNTER_DOUBLE_PAIR = 1
TrainerBattleTrigger.ENCOUNTER_TWO_TRAINERS = 2

-- Source direction deltas: north decreases fieldZ.
local DIRECTION_DELTAS = {
  north = { x = 0, z = -1 },
  south = { x = 0, z = 1 },
  west = { x = -1, z = 0 },
  east = { x = 1, z = 0 },
}

local TRAINER_SIGHT_TYPES = { [1] = true, [2] = true }

---@param value unknown
---@return boolean
local function isTile(value)
  return type(value) == "number" and value % 1 == 0
end

---@param trainer unknown
---@param index integer
local function checkTrainer(trainer, index)
  assert(type(trainer) == "table", "trainer facts stay records")
  local entry = trainer --[[@as table<string, unknown>]]
  assert(type(entry.id) == "string" and entry.id ~= "", "trainer facts name their trainer")
  assert(isTile(entry.fieldX) and isTile(entry.fieldZ), "trainer facts carry integer tiles")
  assert(type(entry.trainerId) == "number" and entry.trainerId % 1 == 0, "trainer facts carry their native identity")
  assert(
    type(entry.range) == "number" and entry.range % 1 == 0 and entry.range >= 0,
    "trainer sight ranges stay integral"
  )
  assert(type(entry.sightType) == "number", "trainer facts carry their sight type")
  assert(index >= 1, "trainer order follows the facts array")
end

-- The distance along one direction when the player stands on that exact ray,
-- or nil when the player is off the row/column or outside the range
-- (TrainerSight_GetDistance{North,South,West,East}).
---@param trainer table<string, unknown>
---@param player table<string, unknown>
---@param direction string
---@return integer?
local function rayDistance(trainer, player, direction)
  local delta = DIRECTION_DELTAS[direction]
  if delta == nil then
    return nil
  end
  local fieldX = trainer.fieldX --[[@as integer]]
  local fieldZ = trainer.fieldZ --[[@as integer]]
  local targetX = player.fieldX --[[@as integer]]
  local targetZ = player.fieldZ --[[@as integer]]
  if delta.x ~= 0 then
    if fieldZ ~= targetZ then
      return nil
    end
    local distance = (targetX - fieldX) * delta.x
    if
      distance >= 1 and distance <= trainer.range --[[@as integer]]
    then
      return distance
    end
    return nil
  end
  if fieldX ~= targetX then
    return nil
  end
  local distance = (targetZ - fieldZ) * delta.z
  if
    distance >= 1 and distance <= trainer.range --[[@as integer]]
  then
    return distance
  end
  return nil
end

-- The direction and distance one trainer sights the player along, or nil when
-- it does not see the player at all (TrainerSight_FindPlayer).
---@param trainer table<string, unknown>
---@param player table<string, unknown>
---@param sightBlocked fun(trainer: table<string, unknown>, direction: string, distance: integer): boolean
---@return { direction: string, distance: integer }?
local function sightOf(trainer, player, sightBlocked)
  local sightType = trainer.sightType
  local directions
  if sightType == 1 then
    local facing = trainer.direction
    if type(facing) ~= "string" then
      return nil
    end
    directions = { facing }
  elseif sightType == 2 then
    directions = TrainerBattleTrigger.DIRECTIONS
  else
    return nil
  end
  for _, direction in ipairs(directions) do
    local distance = rayDistance(trainer, player, direction)
    if distance ~= nil and not sightBlocked(trainer, direction, distance) then
      return { direction = direction, distance = distance }
    end
  end
  return nil
end

---@param trainer table<string, unknown>
---@param sight { direction: string, distance: integer }
---@return table<string, unknown>
local function slotFor(trainer, sight)
  return {
    id = trainer.id,
    trainerId = trainer.trainerId,
    partner = trainer.partner,
    direction = sight.direction,
    distance = sight.distance,
  }
end

-- Plans this tick's native engagement, or nil when no eligible trainer sees the
-- player. See the module comment for the exact shape rules.
---@param facts { player: table<string, unknown>, doublesEligible: boolean?, trainers: table<string, unknown>[] }
---@return { encounterType: integer, slots: table<string, unknown>[] }? the engagement plan, or nil
function TrainerBattleTrigger.check(facts)
  assert(type(facts) == "table", "trainer sight reads its facts record")
  local player = facts.player --[[@as table<string, unknown>]]
  assert(type(player) == "table", "trainer sight reads the player tile")
  assert(isTile(player.fieldX) and isTile(player.fieldZ), "the player tile stays integral")
  assert(type(facts.trainers) == "table", "trainer sight reads the trainer list")
  local sightBlocked = facts.sightBlocked --[[@as fun(trainer: table<string, unknown>, direction: string, distance: integer): boolean]]
  assert(type(sightBlocked) == "function", "trainer sight resolves its occlusion through one resolver")
  local isDouble = facts.isDouble --[[@as fun(trainerId: integer): boolean]]
  assert(type(isDouble) == "function", "trainer sight resolves the double mark through one resolver")
  local doublesEligible = facts.doublesEligible == true

  local sighted = {} ---@type table<integer, { direction: string, distance: integer }?>
  local firstIndex = nil
  for index, trainer in ipairs(facts.trainers) do
    checkTrainer(trainer, index)
    local entry = trainer --[[@as table<string, unknown>]]
    if entry.defeated ~= true and TRAINER_SIGHT_TYPES[entry.sightType] == true then
      local sight = sightOf(entry, player, sightBlocked)
      if sight ~= nil then
        sighted[index] = sight
        firstIndex = firstIndex or index
      end
    end
  end
  if firstIndex == nil then
    return nil
  end
  local first = facts.trainers[firstIndex] --[[@as table<string, unknown>]]
  local firstSight = sighted[firstIndex] --[[@as { direction: string, distance: integer }]]
  local firstTrainerId = first.trainerId
  ---@cast firstTrainerId integer
  if isDouble(firstTrainerId) == true then
    if not doublesEligible then
      return nil
    end
    local partnerIndex = nil
    for index, trainer in ipairs(facts.trainers) do
      local entry = trainer --[[@as table<string, unknown>]]
      if
        index ~= firstIndex
        and entry.defeated ~= true
        and TRAINER_SIGHT_TYPES[entry.sightType] == true
        and entry.trainerId == first.trainerId
      then
        partnerIndex = index
        break
      end
    end
    assert(partnerIndex ~= nil, "a double-battle trainer engages with its own pair partner")
    local partner = facts.trainers[partnerIndex] --[[@as table<string, unknown>]]
    return {
      encounterType = TrainerBattleTrigger.ENCOUNTER_DOUBLE_PAIR,
      slots = { slotFor(first, firstSight), slotFor(partner, firstSight) },
    }
  end
  if doublesEligible then
    for index, trainer in ipairs(facts.trainers) do
      local sight = sighted[index]
      if index ~= firstIndex and sight ~= nil then
        local second = trainer --[[@as table<string, unknown>]]
        return {
          encounterType = TrainerBattleTrigger.ENCOUNTER_TWO_TRAINERS,
          slots = { slotFor(first, firstSight), slotFor(second, sight) },
        }
      end
    end
  end
  return {
    encounterType = TrainerBattleTrigger.ENCOUNTER_SINGLE,
    slots = { slotFor(first, firstSight) },
  }
end

return TrainerBattleTrigger
