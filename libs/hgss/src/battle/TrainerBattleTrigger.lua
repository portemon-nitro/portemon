-- Source trainer sight and approach planning. Given the player tile and the
-- known trainer placements, check reports which undefeated trainers engage
-- this tick; prepare turns an engagement into a trainer-battle launch
-- request. This module only plans: approach movement and the ensuing
-- script run belong to the field/script owners, which consume the returned
-- launch identity. Defeated trainers never re-engage, and trainers engaging
-- on the same tick stay simultaneous (the native double engagement) instead
-- of collapsing into one fight.
--
-- Facts shape (plain data from the actor/world owners):
--   facts = {
--     player = { fieldX: integer, fieldZ: integer },
--     trainers = {
--       { id: string, fieldX: integer, fieldZ: integer,
--         range: integer?, defeated: boolean? }, ...
--     },
--   }
-- Sight is the Chebyshev tile distance against the trainer's range (the
-- generated eye data supplies the range; trainers without one never
-- engage). Ordering follows the facts array.

---@class TrainerBattleTrigger
local TrainerBattleTrigger = {}

-- Trainers without an explicit sight range never engage: sight without a
-- range is missing data, not adjacent aggression.
TrainerBattleTrigger.DEFAULT_RANGE = nil

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
  if entry.range ~= nil then
    assert(
      type(entry.range) == "number" and entry.range % 1 == 0 and entry.range >= 0,
      "trainer sight ranges stay non-negative integers"
    )
  end
  if entry.defeated ~= nil then
    assert(type(entry.defeated) == "boolean", "trainer defeat flags stay boolean")
  end
  assert(index >= 1, "trainer order follows the facts array")
end

---@param trainer table<string, unknown>
---@param player table<string, unknown>
---@return boolean true when the trainer's sight reaches the player tile
local function engages(trainer, player)
  if trainer.defeated == true then
    return false
  end
  if trainer.range == nil then
    return false
  end
  local distance = math.max(math.abs(trainer.fieldX - player.fieldX), math.abs(trainer.fieldZ - player.fieldZ))
  return distance <= trainer.range
end

-- Reports the trainers engaging this tick, or nil when none do. Defeated
-- trainers and trainers without sight data never engage; every engaging
-- trainer is listed, so a simultaneous pair survives as a pair.
---@param facts { player: table<string, unknown>, trainers: table<string, unknown>[] }
---@return { trainers: table<string, unknown>[] }? the engagement, or nil
function TrainerBattleTrigger.check(facts)
  assert(type(facts) == "table", "trainer sight reads its facts record")
  assert(type(facts.player) == "table", "trainer sight reads the player tile")
  local player = facts.player --[[@as table<string, unknown>]]
  assert(isTile(player.fieldX) and isTile(player.fieldZ), "the player tile stays integral")
  assert(type(facts.trainers) == "table", "trainer sight reads the trainer list")
  local engaging = {}
  for index, trainer in ipairs(facts.trainers) do
    checkTrainer(trainer, index)
    local entry = trainer --[[@as table<string, unknown>]]
    if engages(entry, player) then
      engaging[#engaging + 1] = { id = entry.id, fieldX = entry.fieldX, fieldZ = entry.fieldZ }
    end
  end
  if #engaging == 0 then
    return nil
  end
  return { trainers = engaging }
end

-- Turns an engagement into a trainer-battle launch request. A lone trainer
-- launches its single battle; a simultaneous engagement launches one battle
-- carrying every engaging trainer, preserving the native double. The launch
-- identity comes from the caller (opts.launchId) or names the engaging
-- trainers; flags quoted here are the defeated markers the post-battle
-- script owns, never set by planning.
---@param sighting { trainers: table<string, unknown>[] }
---@param opts table<string, unknown>?
---@return { launch: table<string, unknown>, trainers: string[] }
function TrainerBattleTrigger.prepare(sighting, opts)
  assert(type(sighting) == "table" and type(sighting.trainers) == "table", "preparation consumes an engagement")
  assert(#sighting.trainers > 0, "preparation consumes a non-empty engagement")
  local options = opts or {}
  assert(type(options) == "table", "preparation options stay a record")
  local ids = {}
  for _, trainer in ipairs(sighting.trainers) do
    assert(type(trainer) == "table" and type(trainer.id) == "string", "engagements carry trainer identities")
    ids[#ids + 1] = trainer.id
  end
  local launchId = options.launchId
  if launchId == nil then
    launchId = "trainer:" .. table.concat(ids, "+")
  end
  assert(type(launchId) == "string" and launchId ~= "", "trainer launches carry their identity")
  local payload = {}
  if #ids == 1 then
    payload.trainer = ids[1]
  else
    payload.trainers = {}
    for _, id in ipairs(ids) do
      payload.trainers[#payload.trainers + 1] = { id = id }
    end
  end
  return {
    launch = { id = launchId, kind = "trainer", payload = payload },
    trainers = ids,
  }
end

return TrainerBattleTrigger
