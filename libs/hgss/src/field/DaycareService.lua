-- The Day Care feature service: the single owner of deposit and withdrawal
-- custody over the saved parent slots, the source growth and price queries,
-- the deposit's own form sanitize, the two reserved yard objects, and the one
-- committed-step feed. Custody moves between the live party and the stored
-- slots in one publication: the party roster and the saved parent slot are
-- staged together and published only while both are current, so a parent is
-- never in the party and in the Day Care at once.
--
-- The source keeps the stored parent as a BoxPokemon plus its authored Mail
-- and a u32 step counter (include/daycare.h). This owner mirrors that split:
-- the stored parent is a detached canonical mon record whose party-only
-- fields (current health, status effects, ball capsule) already sit at their
-- boxed-equivalent defaults and whose Mail and held stationery ride along
-- inside it. Growth and price are derived on every read and never written
-- back, so a query cannot advance custody. The fee itself belongs to the
-- caller's script: this owner reports the source price only.
--
-- Retail sources (tmp/refs/pokeheartgold): src/get_egg.c
-- (Save_Daycare_PutMonIn, DaycareMon_CopyFromPartySlot,
-- Save_Daycare_RetrieveMon, Daycare_LearnLevelUpMoves,
-- DaycareMon_BufferNickAndRetrievalPrice, Save_Daycare_BufferMonStats,
-- Save_Daycare_BufferTailMonNick), src/scrcmd_daycare.c
-- (ScrCmd_UpdateDaycareMonObjects, ScrCmd_DaycareSanitizeMon), and
-- src/pokemon.c (TryAppendBoxMonMove, DeleteBoxMonFirstMoveAndAppend).

local Experience = require("libs.mons.src.gen4.Experience")
local Personality = require("libs.mons.src.gen4.Personality")
local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

-- The two reserved source yard objects and their fixed tiles
-- (src/scrcmd_daycare.c::ScrCmd_UpdateDaycareMonObjects: x = 8, y = 5 then
-- x = 10, y = 9, direction 1, movement type 11).
local YARD_OBJECTS = {
  { numericId = 250, fieldX = 8, fieldZ = 5 },
  { numericId = 251, fieldX = 10, fieldZ = 9 },
}
local YARD_FACING = "south"
local YARD_MOVEMENT_TYPE = "look_north_south_east"

-- Halfword equality marker for the "move is already known" chance: the source
-- returns MOVE_APPEND_KNOWN and appends nothing.
local MOVE_SLOTS = 4

---@class DaycareService
---@field private _state DaycareState
---@field private _mons table<string, unknown> the live mon service
---@field private _bag table<string, unknown> the live Bag service behind the Orb return
---@field private _stats table<string, unknown> the live game-stats owner behind the deposit count
---@field private _actors table<string, unknown> the field actor manager behind the yard objects
---@field private _catalog MonCatalog
---@field private _currentMap fun(): table<string, unknown>|nil
local DaycareService = {}
DaycareService.__index = DaycareService

---@param message string
---@param context table<string, unknown>
local function fail(message, context)
  Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, message, context)
end

---@param value unknown
---@param what string
---@return integer
local function checkSlotIndex(value, what)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 then
    fail("day care " .. what .. " must be a zero-based slot index", { slot = value })
  end
  return value --[[@as integer]]
end

-- Source `BufferIntegerAsString(..., digits, PRINTING_MODE_LEFT_ALIGN)`: the
-- number keeps its digits and the field fills the remaining width.
---@param value integer
---@param width integer
---@return string
local function paddedInteger(value, width)
  local text = tostring(value)
  if #text >= width then
    return text
  end
  return text .. string.rep(" ", width - #text)
end

---@param opts table<string, unknown>
---@return DaycareService
function DaycareService.new(opts)
  assert(type(opts) == "table", "the Day Care service requires its collaborators")
  local state = assert(opts.state, "the Day Care service requires its saved state")
  assert(type(state.capture) == "function", "the Day Care service requires its saved state")
  local mons = assert(opts.mons, "the Day Care service requires the mon service")
  assert(type(mons.partyMon) == "function", "the Day Care service requires the mon service")
  local catalog = assert(opts.catalog, "the Day Care service requires the mon catalog")
  assert(type(catalog.followerSelection) == "function", "the Day Care service requires the mon catalog")
  local currentMap = assert(opts.currentMap, "the Day Care service requires the live map accessor")
  assert(type(currentMap) == "function", "the Day Care service requires the live map accessor")
  local bag = assert(opts.bag, "the Day Care service requires the Bag service")
  assert(type(bag.prepareInventoryChanges) == "function", "the Day Care service requires the Bag service")
  local stats = assert(opts.stats, "the Day Care service requires the game-stats owner")
  assert(type(stats.prepareChanges) == "function", "the Day Care service requires the game-stats owner")
  local actors = assert(opts.actors, "the Day Care service requires the actor manager")
  assert(type(actors.installReservedObject) == "function", "the Day Care service requires the actor manager")
  return setmetatable({
    _state = state,
    _mons = mons,
    _bag = bag,
    _stats = stats,
    _actors = actors,
    _catalog = catalog,
    _currentMap = currentMap,
  }, DaycareService)
end

---@return DaycareState
function DaycareService:savedState()
  return self._state
end

-- The detached saved bucket the field capture publishes: only settled custody
-- state is serialized, never a live handle or a derived price.
---@return table<string, unknown>
function DaycareService:capture()
  return self._state:capture()
end

-- The source's own state answer (ScrCmd_GetDaycareState): egg waiting 1,
-- otherwise the parent count shifted into the one/two-parent states.
---@return integer
function DaycareService:state()
  return self._state:state()
end

-- The stored exp feed level and the stepped level, both derived and never
-- written back.
---@param slot0 integer
---@return integer level, integer[] curve, table<string, unknown> mon
function DaycareService:_storedLevel(slot0)
  local mon = assert(self._state:mon(slot0), "day care growth reads an occupied slot")
  local curve = self._catalog:growthCurve(self._catalog:species(mon.species).growthCurve)
  return Experience.level(curve, mon.experience), curve, mon
end

---@param mon table<string, unknown>
---@return string
function DaycareService:_displayName(mon)
  local Mon = require("libs.mons.src.Mon")
  return Mon.displayName(mon, self._catalog)
end

-- One stored parent's source gender symbol slot: a Nidoran whose name the
-- player never chose shows no symbol, exactly like the native buffer.
---@param mon table<string, unknown>
---@return string
function DaycareService:_genderSymbol(mon)
  local gender = Personality.gender(self._catalog:species(mon.species).genderRatio, mon.personality)
  if gender == "genderless" then
    return ""
  end
  local unnamedNidoran =
    (mon.species == "NIDORAN_F" or mon.species == "NIDORAN_M") and mon.nickname == nil
  if unnamedNidoran then
    return ""
  end
  return gender == "female" and "♀" or "♂"
end

-- Source Save_Daycare_BufferStoredMonNicks: parent nicknames in buffers 0 and
-- 1 and the first parent's OT name in buffer 2.
---@return table<integer, string> buffer index -> display text
function DaycareService:storedNicknames()
  local buffers = {}
  local first = self._state:mon(0)
  if first ~= nil then
    buffers[0] = self:_displayName(first)
    buffers[2] = first.origin.trainerName
  end
  local second = self._state:mon(1)
  if second ~= nil then
    buffers[1] = self:_displayName(second)
  end
  return buffers
end

-- Source Save_Daycare_BufferTailMonNick: the last occupied parent's species
-- and nickname, or numeric zero and no nickname when the Day Care is empty.
---@return { species: integer, nickname: string? }
function DaycareService:tailMon()
  local slot0 = self._state:tailSlot()
  if slot0 == nil then
    return { species = 0 }
  end
  local mon = assert(self._state:mon(slot0), "the tail slot holds its parent")
  return { species = self._catalog:species(mon.species).nativeId, nickname = self:_displayName(mon) }
end

-- Source DaycareMon_CalcLevelGrowth plus its buffer pair: the parent's level
-- growth under its stored steps, with the nickname and the three-digit
-- growth buffer. An empty slot answers zero growth and buffers nothing.
---@param slot0 integer
---@return { growth: integer, bufferedGrowth: string?, nickname: string? }
function DaycareService:growth(slot0)
  checkSlotIndex(slot0, "withdrawal growth")
  local steps = self._state:steps(slot0)
  if steps == nil then
    return { growth = 0 }
  end
  local level, curve, mon = self:_storedLevel(slot0)
  local updated = Experience.level(curve, mon.experience + steps)
  local growth = updated - level
  return { growth = growth, bufferedGrowth = paddedInteger(growth, 3), nickname = self:_displayName(mon) }
end

-- Source DaycareMon_BufferNickAndRetrievalPrice: the parent's nickname and the
-- source price (levelGrowth + 1) * 100, buffered five digits wide.
---@param slot0 integer
---@return { price: integer, bufferedPrice: string?, nickname: string? }
function DaycareService:withdrawCost(slot0)
  checkSlotIndex(slot0, "withdrawal price")
  local steps = self._state:steps(slot0)
  if steps == nil then
    return { price = 0 }
  end
  local growth = self:growth(slot0).growth
  local price = (growth + 1) * 100
  return {
    price = price,
    bufferedPrice = paddedInteger(price, 5),
    nickname = self:_displayName(assert(self._state:mon(slot0), "the priced slot holds its parent")),
  }
end

-- Source Save_Daycare_BufferMonStats: the parent's nickname, its stepped
-- level three digits wide, and its gender symbol.
---@param slot0 integer
---@return { nickname: string, level: string, gender: string }?
function DaycareService:monStats(slot0)
  checkSlotIndex(slot0, "parent statistics")
  local steps = self._state:steps(slot0)
  if steps == nil then
    return nil
  end
  local _, curve, mon = self:_storedLevel(slot0)
  local level = Experience.level(curve, mon.experience + steps)
  return {
    nickname = self:_displayName(mon),
    level = paddedInteger(level, 3),
    gender = self:_genderSymbol(mon),
  }
end

-- Source DaycareMon_CopyFromPartySlot: the stored parent takes the source
-- deposit shape -- mood zero, a Sky Shaymin back on its land form, and the
-- party-only state a BoxPokemon never keeps (current health, status effects,
-- and the ball capsule) at its boxed-equivalent default. The authored Mail
-- and every other stored field ride along.
---@param mon table<string, unknown>
---@return table<string, unknown>
function DaycareService:_storedCopy(mon)
  local stored = mon
  stored.mood = 0
  if stored.species == "SHAYMIN" then
    stored = self._mons:ordinaryFormMon(stored)
  end
  stored.condition = { currentHp = self._mons:derive(stored).maxHp, effects = {} }
  stored.capsule = { id = 0, seals = {} }
  return stored
end

---@param slot index zero-based source slot of an occupied parent
---@return table<string, unknown>
function DaycareService:_requireParent(slot)
  local mon = self._state:mon(slot)
  if mon == nil then
    fail("day care slot holds no parent", { slot = slot })
  end
  return mon --[[@as table<string, unknown>]]
end

-- One learning chance through the source TryAppendBoxMonMove: an already
-- known move appends nothing, a free slot appends at its base power points,
-- and a full move set drops its first move and appends the new one last. The
-- current move set is tested every chance, so a move dropped earlier in the
-- same withdrawal never masks a later one.
---@param moves table<string, unknown>[]
---@param moveKey string
function DaycareService:_learnChance(moves, moveKey)
  for _, entry in ipairs(moves) do
    if entry.move == moveKey then
      return
    end
  end
  local definition = self._catalog:move(moveKey)
  local appended = { move = moveKey, pp = definition.basePp, ppUps = 0 }
  if #moves < MOVE_SLOTS then
    moves[#moves + 1] = appended
    return
  end
  for index = 1, MOVE_SLOTS - 1 do
    moves[index] = moves[index + 1]
  end
  moves[MOVE_SLOTS] = appended
end

-- Source Daycare_LearnLevelUpMoves: every level crossed by the added steps
-- offers its learnset entries in source order, each chance testing the
-- current move set.
---@param mon table<string, unknown>
---@param curve integer[]
---@param firstLevel integer level the stored experience reached
function DaycareService:_learnCrossedMoves(mon, curve, firstLevel)
  local finalLevel = Experience.level(curve, mon.experience)
  if finalLevel <= firstLevel then
    return
  end
  local learnset = self._catalog:form(mon.species, mon.form).levelUpMoves
  local moves = {}
  for index, entry in ipairs(mon.moves) do
    moves[index] = entry
  end
  for level = firstLevel + 1, finalLevel do
    for _, entry in ipairs(learnset) do
      if entry.level == level then
        self:_learnChance(moves, entry.move)
      end
    end
  end
  mon.moves = moves
end

-- Deposits one party parent: the stored copy lands in the first free source
-- slot with a zero step counter, the live party compacts, and the deposit
-- statistic counts once. The roster and the parent slot publish together.
---@param partySlot0 integer
function DaycareService:deposit(partySlot0)
  checkSlotIndex(partySlot0, "deposit")
  local mons = self._mons
  if mons:partyMon(partySlot0) == nil then
    fail("day care deposit names an occupied party slot", { slot = partySlot0 })
  end
  local state = self._state
  local stored = self:_storedCopy(mons:partyMon(partySlot0))
  local parentPrep, parentReason = state:prepareDeposit(state:revision(), stored)
  if parentPrep == nil then
    fail("day care deposit was rejected: " .. tostring(parentReason), { slot = partySlot0 })
  end
  local roster = {}
  for slot = 0, mons:partyCount() - 1 do
    if slot ~= partySlot0 then
      roster[#roster + 1] = mons:partyMon(slot)
    end
  end
  local partyPrep, partyReason = mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { party = roster, boxUpdates = {} })
  if partyPrep == nil then
    fail("day care deposit lost its party revision: " .. tostring(partyReason), { slot = partySlot0 })
  end
  local statsPrep = self._stats:prepareChanges({ observations = { { kind = "daycare_deposit" } } })
  assert(parentPrep.isCurrent(), "the day care parent candidate stayed current")
  assert(partyPrep.isCurrent(), "the day care party candidate stayed current")
  assert(statsPrep.isCurrent(), "the day care statistic candidate stayed current")
  parentPrep.publish()
  partyPrep.publish()
  statsPrep.publish()
end

-- Withdraws one stored parent into the party: derived full health without a
-- status condition or ball capsule, the authored Mail restored, the stored
-- steps added to the stored experience under the level-100 ceiling with the
-- crossed-level moves learned, and the remaining slot compacted. The
-- withdrawal is not a new receipt: no Dex, caught-species, or hatch count is
-- staged, and the script owns the fee.
---@param slot0 integer
---@return { species: integer, nickname: string }
function DaycareService:withdraw(slot0)
  checkSlotIndex(slot0, "withdrawal")
  self:_requireParent(slot0)
  local state = self._state
  local staged, reason = state:prepareWithdraw(state:revision(), slot0)
  if staged == nil then
    fail("day care withdrawal was rejected: " .. tostring(reason), { slot = slot0 })
  end
  local mon = staged.mon
  mon.condition = { currentHp = self._mons:derive(mon).maxHp, effects = {} }
  mon.capsule = { id = 0, seals = {} }
  local curve = self._catalog:growthCurve(self._catalog:species(mon.species).growthCurve)
  local level = Experience.level(curve, mon.experience)
  -- The source skips the step feed entirely for a mon already at the
  -- ceiling; otherwise the steps join the experience under that ceiling.
  if level ~= 100 then
    local added = mon.experience + staged.steps
    local ceiling = Experience.expFor(curve, 100)
    mon.experience = added > ceiling and ceiling or added
    self:_learnCrossedMoves(mon, curve, level)
    mon.condition.currentHp = self._mons:derive(mon).maxHp
  end
  local partyPrep, partyReason = self._mons:preparePartyBatch(
    self._mons:partyRevision(),
    {},
    { mon }
  )
  if partyPrep == nil then
    fail("day care withdrawal lost its party revision: " .. tostring(partyReason), { slot = slot0 })
  end
  assert(staged.prepared.isCurrent(), "the day care withdrawal candidate stayed current")
  assert(partyPrep.isCurrent(), "the day care withdrawal party candidate stayed current")
  staged.prepared.publish()
  partyPrep.publish()
  return { species = self._catalog:species(mon.species).nativeId, nickname = self:_displayName(mon) }
end

-- Source ScrCmd_DaycareSanitizeMon: slot 0xFF answers zero without touching
-- anything; a held Griseous Orb returns to the Bag first, and a refused Bag
-- addition answers 255 with both the parent and the Bag unchanged; the parent
-- then takes its ordinary form for Giratina, Rotom, and Shaymin.
---@param partySlot0 integer
---@return integer native result (0 normal, 255 when the Orb cannot return)
function DaycareService:sanitizeMon(partySlot0)
  if partySlot0 == 0xFF then
    return 0
  end
  checkSlotIndex(partySlot0, "sanitize")
  local bag = assert(self._bag, "day care sanitize requires the Bag service")
  local mon = self._mons:partyMon(partySlot0)
  if mon == nil then
    fail("day care sanitize names an occupied party slot", { slot = partySlot0 })
  end
  if mon.heldItem ~= "NONE" then
    local definition = bag:catalog():item(mon.heldItem)
    if definition.heldFormEffect == "griseous_orb" then
      local bagPrep = bag:prepareInventoryChanges(bag:revision(), {
        { op = "add", item = mon.heldItem, quantity = 1 },
      })
      if bagPrep == nil then
        return 255
      end
      mon.heldItem = "NONE"
      local partyPrep = self:_sanitizeParty(partySlot0, mon)
      assert(bagPrep.isCurrent(), "the Orb return stayed current")
      assert(partyPrep.isCurrent(), "the sanitized parent stayed current")
      bagPrep.publish()
      partyPrep.publish()
      return 0
    end
  end
  if mon.form > 0 then
    local partyPrep = self:_sanitizeParty(partySlot0, mon)
    assert(partyPrep.isCurrent(), "the sanitized parent stayed current")
    partyPrep.publish()
  end
  return 0
end

-- Stages the sanitized parent update and answers its one-use candidate.
---@param partySlot0 integer
---@param mon table<string, unknown>
---@return table<string, unknown>
function DaycareService:_sanitizeParty(partySlot0, mon)
  local sanitized = self._mons:ordinaryFormMon(mon)
  local partyPrep, reason = self._mons:preparePartyChanges(self._mons:partyRevision(), {
    { slot = partySlot0, mon = sanitized },
  })
  if partyPrep == nil then
    fail("day care sanitize lost its party revision: " .. tostring(reason), { slot = partySlot0 })
  end
  return partyPrep
end

-- Replaces the two reserved yard objects from the stored parents
-- (src/scrcmd_daycare.c::ScrCmd_UpdateDaycareMonObjects): each occupied slot
-- paints its parent's following-mon visual at its fixed tile, and each empty
-- slot clears the object. Repeating the update replaces instead of adding, so
-- map re-entry never duplicates an actor.
function DaycareService:updateYardObjects()
  local actors = self._actors
  local map = self._currentMap()
  if map == nil then
    return
  end
  for index, slot in ipairs(YARD_OBJECTS) do
    local mon = self._state:mon(index - 1)
    if mon == nil then
      actors:clearReservedObject(slot.numericId)
    else
      local descriptor = self._catalog:followerSelection(mon)
      local visual = descriptor
      if descriptor.female ~= nil then
        local gender = Personality.gender(self._catalog:species(mon.species).genderRatio, mon.personality)
        if gender == "female" then
          visual = descriptor.female
        end
      end
      actors:installReservedObject({
        mapId = map.mapId,
        numericId = slot.numericId,
        sprite = descriptor,
        visualId = visual.visualId,
        fieldX = slot.fieldX,
        fieldZ = slot.fieldZ,
        facing = YARD_FACING,
        movementType = YARD_MOVEMENT_TYPE,
      })
    end
  end
end

-- The one committed-step feed: every occupied parent's stored step counter
-- advances exactly once per committed walking step. Turns, blocked pushes,
-- scripted motion, warps, and modal activity never reach this seam, and
-- nothing else in the field advances these counters.
function DaycareService:noteCommittedStep()
  local state = self._state
  if state:count() == 0 then
    return
  end
  local prepared, reason = state:prepareStepAdvance(state:revision())
  assert(prepared ~= nil, "the day care step advance stayed current: " .. tostring(reason))
  prepared.publish()
end

return DaycareService
