-- The field's one ordered daily dispatcher over the calendar observation the
-- incoming-call owner already took, plus the source lottery behind it. The
-- daily order is src/field_time_events.c::FieldSystem_HandleDaysPassed, the
-- lottery arithmetic is src/sys_vars.c (Save_LCRNGAdvanceLotoID,
-- Save_VarsFlags_SetLotoId/GetLotoId/RollLotoId), the traversal is
-- src/scrcmd_lottery.c (ScrCmd_LotoIDGet/LotoIDSearch/LotoIDSet) and the
-- infection decay is src/pokemon.c::Party_UpdatePokerus.
--
-- The owner borrows canonical field state only: the script world's flags and
-- variables, the shared companion draw pair and daily identity, the canonical
-- party, the mart service and the incoming-call owner. It persists nothing of
-- its own; the calendar's saved day serial is the idempotence boundary, so one
-- observation applies one day of work and a retired report is never replayed.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local ScriptErrors = require("libs.script.src.errors")
local U32 = require("libs.codec.src.U32")

local VARS = FieldScriptSymbols.variablesByName

-- DAILY_FLAG_BASE / NUM_DAILY_FLAGS (include/constants/flags.h): the one
-- contiguous block src/script_manager.c::ClearDailyFlags memsets.
local DAILY_FLAG_BASE = 0xAA0
local DAILY_FLAG_COUNT = 192

-- Script variables hold unsigned halfwords, and MON_DATA_OT_ID is the low half
-- of the stored trainer identity.
local U16_MODULUS = 0x10000
-- Save_LCRNGAdvanceLotoID's linear step over the friend-group seed.
local LOTO_MULTIPLIER = 1103515245
local LOTO_INCREMENT = 12345
-- LotoId_CountDigitsMatched compares at most five trailing decimal digits.
local LOTO_DIGITS = 5

-- Party_UpdatePokerus: the low nibble counts the remaining infection days,
-- the high nibble keeps the strain, a cleared byte becomes the immune marker,
-- and a jump beyond four days always clears the days.
local POKERUS_DAY_MODULUS = 0x10
local POKERUS_IMMUNE = 0x10
local POKERUS_MAX_STEP = 4

-- Save_VarsFlags_RandomizeVar4041: LCRandom() % 98 + 2.
local VAR_4041_MODULUS = 98
local VAR_4041_MINIMUM = 2
-- Save_VarsFlags_UpdateBuenasPasswordSet: LCRandom() % 30, stepping past a
-- repeat of the set already stored.
local BUENAS_PASSWORD_MODULUS = 30

local SLOTS_PER_BOX = require("libs.mons.src.Boxes").SLOTS_PER_BOX

---@class FieldDailyEvents
---@field private _world table<string, unknown> the borrowed script event store
---@field private _state table<string, unknown> the borrowed durable companion state
---@field private _mons table<string, unknown> the live canonical mon service
---@field private _mart table<string, unknown> the live mart inventory/session service
---@field private _calls table<string, unknown> the field's incoming-call owner
---@field private _random table<string, unknown> the shared companion draw pair
---@field private _regrowApricorns fun(date: table<string, integer>) the field's Apricorn date pass
local FieldDailyEvents = {}
FieldDailyEvents.__index = FieldDailyEvents

---@class FieldDailyEvents.Options
---@field world table<string, unknown> the live script event store
---@field state table<string, unknown> the durable companion state carrying the daily identity
---@field mons table<string, unknown> the live mon service
---@field mart table<string, unknown> the live mart service
---@field calls table<string, unknown> the incoming-call owner carrying the errand wait
---@field random table<string, unknown> the shared companion draw pair
---@field regrowApricorns fun(date: table<string, integer>) the field's Apricorn regrowth pass

-- One required owner operation, resolved before the first mutation. A daily
-- day-tick that cannot perform its ordered work must terminate the field
-- operation instead of leaving a partially advanced runtime to be saved.
---@param owner table<string, unknown>|nil
---@param name string
---@param ownerName string
local function requireOperation(owner, name, ownerName)
  if type(owner) ~= "table" or type(owner[name]) ~= "function" then
    Errors.raise(
      FieldErrors.FIELD_DAILY_EVENTS_OWNER_INVALID,
      "the daily update requires " .. ownerName .. "." .. name,
      { owner = ownerName, operation = name }
    )
  end
end

-- LotoId_CountDigitsMatched: matching trailing decimal digits including
-- leading zeros, compared on the source's own unsigned halfwords.
---@param lotoId integer
---@param otId integer
---@return integer
local function digitsMatched(lotoId, otId)
  local matched = 0
  for _ = 1, LOTO_DIGITS do
    if lotoId % 10 ~= otId % 10 then
      return matched
    end
    lotoId = math.floor(lotoId / 10)
    otId = math.floor(otId / 10)
    matched = matched + 1
  end
  return matched
end

-- GetMonData/GetBoxMonData MON_DATA_OT_ID, masked to the source's low half.
---@param mon table<string, unknown>
---@return integer
local function otIdOf(mon)
  local origin = assert(mon.origin, "admitted mons carry their origin record")
  local trainerId = assert(origin.trainerId, "a mon origin carries its trainer identity")
  return trainerId % U16_MODULUS
end

---@param opts FieldDailyEvents.Options
---@return FieldDailyEvents
function FieldDailyEvents.new(opts)
  assert(type(opts) == "table", "the daily dispatcher requires its options")
  assert(opts.world ~= nil, "the daily dispatcher requires the script event store")
  assert(opts.state ~= nil, "the daily dispatcher requires the companion state")
  assert(opts.mons ~= nil, "the daily dispatcher requires the mon service")
  assert(opts.mart ~= nil, "the daily dispatcher requires the mart service")
  assert(opts.calls ~= nil, "the daily dispatcher requires the incoming-call owner")
  assert(opts.random ~= nil, "the daily dispatcher requires the companion draw pair")
  assert(type(opts.regrowApricorns) == "function", "the daily dispatcher requires the Apricorn date pass")
  return setmetatable({
    _world = opts.world,
    _state = opts.state,
    _mons = opts.mons,
    _mart = opts.mart,
    _calls = opts.calls,
    _random = opts.random,
    _regrowApricorns = opts.regrowApricorns,
  }, FieldDailyEvents)
end

-- Applies one calendar observation to the field. Only a positive elapsed day
-- performs day work; a backward host adjustment and a same-day observation
-- apply nothing and draw nothing here, and the observation itself (including
-- the shared daily seed step) stays with the incoming-call owner.
---@param runtime table<string, unknown> the live field runtime
---@param sample table<string, integer> the one civil sample this update took
---@param report { dayAdvance: integer, minuteAdvance: integer, backward: boolean }
function FieldDailyEvents.apply(runtime, sample, report)
  assert(type(runtime) == "table", "the daily update reads its field runtime")
  assert(type(sample) == "table", "the daily update reads the observed civil sample")
  assert(type(report) == "table", "the daily update reads the calendar observation")
  local events = runtime.dailyEvents
  if type(events) ~= "table" then
    Errors.raise(
      FieldErrors.FIELD_DAILY_EVENTS_OWNER_INVALID,
      "the field runtime carries no daily dispatcher",
      { owner = "runtime", operation = "dailyEvents" }
    )
  end
  local days = report.dayAdvance
  assert(type(days) == "number" and days % 1 == 0 and days >= 0, "calendar observations report whole elapsed days")
  if report.backward == true or days == 0 then
    return
  end
  events --[[@as FieldDailyEvents]]:applyDay(sample, days)
end

-- Every owner operation one day application needs, resolved before the first
-- write: a daily tick that cannot perform its ordered work terminates the field
-- operation with nothing half applied.
function FieldDailyEvents:_requireOwners()
  requireOperation(self._world, "clearFlag", "world")
  requireOperation(self._world, "getVar", "world")
  requireOperation(self._world, "setVar", "world")
  requireOperation(self._state, "readDailyIdentity", "companion state")
  requireOperation(self._mons, "partyCount", "mon service")
  requireOperation(self._mons, "partyMon", "mon service")
  requireOperation(self._mons, "partyRevision", "mon service")
  requireOperation(self._mons, "preparePartyChanges", "mon service")
  requireOperation(self._calls, "advanceDays", "incoming calls")
  requireOperation(self._mart, "processDate", "mart service")
  requireOperation(self._random, "lc", "companion draw pair")
end

-- One positive elapsed day in the source's own order.
---@param sample table<string, integer>
---@param days integer elapsed civil days
function FieldDailyEvents:applyDay(sample, days)
  assert(type(days) == "number" and days % 1 == 0 and days > 0, "a daily application covers whole elapsed days")
  self:_requireOwners()
  local world = self._world
  local random = self._random
  -- ClearDailyFlags.
  for offset = 0, DAILY_FLAG_COUNT - 1 do
    world:clearFlag(DAILY_FLAG_BASE + offset)
  end
  -- Save_FriendGroup_AdvanceSeeds already ran inside this one observation: the
  -- calendar stepped the saved daily seed once per elapsed day, so the daily
  -- lottery only reads the advanced identity here.
  local seed = self._state:readDailyIdentity().dailyGroupSeed
  assert(
    type(seed) == "number" and seed % 1 == 0 and seed >= 0 and seed <= U32.MAX,
    "the calendar persists an unsigned daily seed"
  )
  -- Party_UpdatePokerus.
  self:_decayPokerus(days)
  -- Save_LCRNGAdvanceLotoID: the source linear step, no linear draw.
  self:_writeLotoId(U32.add(U32.mul(seed, LOTO_MULTIPLIER), LOTO_INCREMENT))
  -- Save_VarsFlags_RandomizeVar4041.
  world:setVar(
    assert(VARS.VAR_UNK_4041, "the shared daily variable resolves in the symbol catalog"),
    random:lc("daily-var4041") % VAR_4041_MODULUS + VAR_4041_MINIMUM
  )
  -- FieldSystem_RegrowApricornTrees, through the field's own Apricorn date pass
  -- so presented trees follow the regrown saved state.
  self._regrowApricorns(sample)
  -- PhoneCallPersistentState_BlackBeltKenji_UpdateWaitDays: its overdue reroll
  -- is the second daily linear draw, between the shared variable and the
  -- password set.
  self._calls:advanceDays(days)
  -- PokeathlonSave_ResetDailyItemsBought, through the mart service's date
  -- processing that owns the daily purchase mask.
  self._mart:processDate(sample)
  -- Save_VarsFlags_UpdateBuenasPasswordSet: the third daily linear draw, which
  -- steps past a repeat of the stored set.
  local password = assert(VARS.VAR_BUENAS_PASSWORD_SET, "the password set variable resolves in the symbol catalog")
  local stored = world:getVar(password)
  local nextSet = random:lc("daily-password-set") % BUENAS_PASSWORD_MODULUS
  if nextSet == stored then
    nextSet = (nextSet + 1) % BUENAS_PASSWORD_MODULUS
  end
  world:setVar(password, nextSet)
end

-- Party_UpdatePokerus: an infected slot either loses the elapsed days while it
-- covers them (four days at most) or loses its days outright, keeps its strain,
-- and turns the immune marker when nothing remains. One prepared party mutation
-- publishes every changed slot, and the pass draws nothing.
---@param days integer elapsed civil days
function FieldDailyEvents:_decayPokerus(days)
  local mons = self._mons
  local updates = {}
  for slot = 0, mons:partyCount() - 1 do
    local mon = mons:partyMon(slot)
    if type(mon) == "table" and mon.species ~= nil then
      local pokerus = assert(mon.pokerus, "admitted mons carry their infection byte")
      local infection = pokerus % POKERUS_DAY_MODULUS
      if infection ~= 0 then
        local nextPokerus
        if infection < days or days > POKERUS_MAX_STEP then
          nextPokerus = pokerus - infection
        else
          nextPokerus = pokerus - days
        end
        if nextPokerus == 0 then
          nextPokerus = POKERUS_IMMUNE
        end
        mon.pokerus = nextPokerus
        updates[#updates + 1] = { slot = slot, mon = mon }
      end
    end
  end
  if #updates == 0 then
    return
  end
  local preparation, reason = mons:preparePartyChanges(mons:partyRevision(), updates)
  if preparation == nil then
    Errors.raise(
      FieldErrors.FIELD_DAILY_EVENTS_OWNER_INVALID,
      "the daily infection update could not stage its party change",
      { owner = "mon service", operation = "preparePartyChanges", reason = reason }
    )
  end
  preparation --[[@as { publish: fun(self: table) }]].publish()
end

-- Save_VarsFlags_SetLotoId without BUGFIX_LOTO_NUMBER_HI: both halfword
-- assignments target VAR_LOTO_NUMBER_LO, so the high half overwrites the low
-- half and VAR_LOTO_NUMBER_HI keeps whatever it already held.
---@param id integer
function FieldDailyEvents:_writeLotoId(id)
  assert(type(id) == "number" and id % 1 == 0 and id >= 0 and id <= U32.MAX, "the lottery identity is a u32")
  local low = assert(VARS.VAR_LOTO_NUMBER_LO, "the low lottery variable resolves")
  self._world:setVar(low, id % U16_MODULUS)
  self._world:setVar(low, math.floor(id / U16_MODULUS))
end

-- Save_VarsFlags_GetVar4041: the shared daily variable the scripts read.
---@return integer
function FieldDailyEvents:var4041()
  return self._world:getVar(assert(VARS.VAR_UNK_4041, "the shared daily variable resolves in the symbol catalog"))
end

-- Save_VarsFlags_GetLotoId: the two saved halfwords as one identity. The retail
-- setter never writes the high half, so this reads back the untouched value.
---@return integer
function FieldDailyEvents:lotoId()
  local low = self._world:getVar(assert(VARS.VAR_LOTO_NUMBER_LO, "the low lottery variable resolves"))
  local high = self._world:getVar(assert(VARS.VAR_LOTO_NUMBER_HI, "the high lottery variable resolves"))
  return high * U16_MODULUS + low
end

-- Save_VarsFlags_RollLotoId: the low linear value first, then the high one, and
-- the same retail setter. Two draws, in that order.
function FieldDailyEvents:rollLotoId()
  local random = self._random
  local low = random:lc("lottery-id-lo")
  local high = random:lc("lottery-id-hi")
  self:_writeLotoId(high * U16_MODULUS + low)
end

-- ScrCmd_LotoIDSearch: the party first, then every box in source order, each
-- container keeping its first strictly greatest match. Eggs never match, and a
-- count of zero is no match at all. An equal party and box score chooses the
-- party.
---@param lotoId integer
---@return { position: integer, count: integer, kind: integer }
function FieldDailyEvents:searchLotoId(lotoId)
  if type(lotoId) ~= "number" or lotoId % 1 ~= 0 or lotoId < 0 or lotoId >= U16_MODULUS then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the lottery search reads an unsigned lottery identity", {
      lotoId = lotoId,
    })
  end
  local mons = self._mons
  local partyBest, partySlot = 0, 0
  for slot = 0, mons:partyCount() - 1 do
    local mon = mons:partyMon(slot)
    if type(mon) == "table" and mon.isEgg ~= true then
      local matched = digitsMatched(lotoId, otIdOf(mon))
      if matched ~= 0 and partyBest < matched then
        partyBest, partySlot = matched, slot
      end
    end
  end
  local boxBest, boxSlot = 0, 0
  for box = 0, mons:boxCount() - 1 do
    for slot = 0, SLOTS_PER_BOX - 1 do
      local mon = mons:boxMon(box, slot)
      if type(mon) == "table" and mon.species ~= nil and mon.isEgg ~= true then
        local matched = digitsMatched(lotoId, otIdOf(mon))
        if matched ~= 0 and boxBest < matched then
          boxBest, boxSlot = matched, box * SLOTS_PER_BOX + slot
        end
      end
    end
  end
  if partyBest == 0 and boxBest == 0 then
    return { position = 0, count = 0, kind = 0 }
  end
  if partyBest >= boxBest then
    return { position = partySlot, count = partyBest, kind = 0 }
  end
  return { position = boxSlot, count = boxBest, kind = 1 }
end

return FieldDailyEvents
