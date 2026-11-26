-- The Day Care feature service: the single owner of deposit and withdrawal
-- custody over the saved parent slots, the source growth and price queries,
-- the deposit's own form sanitize, the two reserved yard objects, the one
-- committed-step feed with its source breeding and egg-cycle checks, and the
-- egg the Day-Care Man hands out. Custody moves between the live party and the
-- stored slots in one publication: the party roster and the saved parent slot
-- are staged together and published only while both are current, so a parent
-- is never in the party and in the Day Care at once.
--
-- Egg production keeps the source split between the two moments: a successful
-- step check stores only the pending personality (Save_Daycare_SetEggPID) and
-- raises the Day-Care call, while the offspring record -- species, form,
-- inherited individual values, and inherited moves -- is resolved only when
-- the script hands the egg over. Everything drawn there comes from the
-- injected source streams, so a query, a redraw, or a preview never advances
-- the game's random state.
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
-- The same owner carries the egg-to-mon half of the Day Care: the committed
-- step whose egg cycle completes converts the first Egg already at zero
-- friendship (HatchEggMon, before the field leaves for the hatch scene), and
-- the hatch application's receipt -- the source meeting memo, the default
-- species name, the Pokedex caught fact and the original-gift Elm call --
-- finishes exactly once before the field reopens. It also hands out the one
-- original Togepi gift egg and answers whether a mon descends from it.
--
-- Retail sources (tmp/refs/pokeheartgold): src/get_egg.c
-- (Save_Daycare_PutMonIn, DaycareMon_CopyFromPartySlot,
-- Save_Daycare_RetrieveMon, Daycare_LearnLevelUpMoves,
-- DaycareMon_BufferNickAndRetrievalPrice, Save_Daycare_BufferMonStats,
-- Save_Daycare_BufferTailMonNick), src/scrcmd_daycare.c
-- (ScrCmd_UpdateDaycareMonObjects, ScrCmd_DaycareSanitizeMon), and
-- src/pokemon.c (TryAppendBoxMonMove, DeleteBoxMonFirstMoveAndAppend).

local Breeding = require("libs.mons.src.gen4.Breeding")
local Experience = require("libs.mons.src.gen4.Experience")
local Party = require("libs.mons.src.Party")
local Personality = require("libs.mons.src.gen4.Personality")
local U32 = require("libs.codec.src.U32")
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
-- NUM_DAYCARE_MONS (include/constants/daycare.h).
local PARENT_SLOTS = 2
-- The source stores the cycle counter as an unsigned byte, so it wraps.
local CYCLE_COUNTER_RANGE = 256

---@class DaycareService
---@field private _state DaycareState
---@field private _mons table<string, unknown> the live mon service
---@field private _bag table<string, unknown> the live Bag service behind the Orb return
---@field private _stats table<string, unknown> the live game-stats owner behind the deposit count
---@field private _actors table<string, unknown> the field actor manager behind the yard objects
---@field private _catalog MonCatalog
---@field private _care table<string, unknown> the compiled source breeding tables
---@field private _profile table<string, unknown> the owner profile behind the receiving identity
---@field private _identity { language: string, game: string } the current language and game the gift matcher reads
---@field private _date fun(): { year: integer, month: integer, day: integer }
---@field private _lc fun(): integer the source linear draw shared with mon creation
---@field private _mt fun(): integer the source 32-bit draw shared with the companion feature
---@field private _phone { state: table<string, unknown>, eggTriggerKey: string, eggHatchedTriggerKey: string } the phone call owner
---@field private _events { state: table<string, unknown>, togepiFlagId: integer } the source flag owner for the hatched gift
---@field private _hatch { slot: integer, subject: table<string, unknown>, finalized: boolean }? the live hatch application's claim
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
  local care = assert(opts.care, "the Day Care service requires the compiled care catalog")
  assert(type(care.eggSpecies) == "table", "the Day Care service requires the source egg-species table")
  assert(type(care.eggMoves) == "table", "the Day Care service requires the source egg-move table")
  assert(type(care.incense) == "table", "the Day Care service requires the source incense pairs")
  local profile = assert(opts.profile, "the Day Care service requires the owner profile")
  local trainerId = assert(profile.trainerId, "the Day Care service requires the owner trainer identity")
  assert(
    type(trainerId) == "number" and trainerId % 1 == 0 and trainerId >= 0 and trainerId <= U32.MAX,
    "the Day Care service requires an unsigned 32-bit owner trainer identity"
  )
  local identity = assert(opts.identity, "the Day Care service requires the current language and game")
  assert(type(identity.language) == "string", "the Day Care service requires the current language")
  assert(type(identity.game) == "string", "the Day Care service requires the current game")
  local date = assert(opts.date, "the Day Care service requires the native date provider")
  assert(type(date) == "function", "the Day Care service requires the native date provider")
  local lc = assert(opts.lc, "the Day Care service requires the source linear draw")
  assert(type(lc) == "function", "the Day Care service requires the source linear draw")
  local mt = assert(opts.mt, "the Day Care service requires the source personality draw")
  assert(type(mt) == "function", "the Day Care service requires the source personality draw")
  local phone = assert(opts.phone, "the Day Care service requires the phone state owner")
  assert(type(phone.state) == "table", "the Day Care service requires the phone state owner")
  assert(type(phone.eggTriggerKey) == "string", "the Day Care service requires its call trigger key")
  assert(type(phone.eggHatchedTriggerKey) == "string", "the Day Care service requires its hatched-egg call key")
  local events = assert(opts.events, "the Day Care service requires the field event state")
  assert(type(events.state) == "table", "the Day Care service requires the field event state")
  assert(type(events.togepiFlagId) == "number", "the Day Care service requires the hatched-gift flag")
  return setmetatable({
    _state = state,
    _mons = mons,
    _bag = bag,
    _stats = stats,
    _actors = actors,
    _catalog = catalog,
    _care = care,
    _profile = profile,
    _identity = identity,
    _date = date,
    _lc = lc,
    _mt = mt,
    _phone = phone,
    _events = events,
    _hatch = nil,
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
  local unnamedNidoran = (mon.species == "NIDORAN_F" or mon.species == "NIDORAN_M") and mon.nickname == nil
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

---@param slot integer zero-based source slot of an occupied parent
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
  ---@cast parentPrep -nil
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
  ---@cast partyPrep -nil
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
  ---@cast staged -nil
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
  local partyPrep, partyReason = self._mons:preparePartyBatch(self._mons:partyRevision(), {}, { mon })
  if partyPrep == nil then
    fail("day care withdrawal lost its party revision: " .. tostring(partyReason), { slot = slot0 })
  end
  ---@cast partyPrep -nil
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
  ---@cast mon -nil
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
  ---@cast partyPrep -nil
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
      local descriptor = assert(self._catalog:followerSelection(mon), "a stored parent carries its follower visual")
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

-- The source compatibility score between the two stored parents
-- (Save_Daycare_CalcCompatibilityInternal).
---@return integer score (0, 20, 50 or 70)
function DaycareService:compatibility()
  return Breeding.compatibility(self:_storedParents(), self._catalog)
end

-- Save_Daycare_CalcCompatibility's converted category: 70 answers 0, 50
-- answers 1, 20 answers 2 and an incompatible pair answers 3.
---@return integer category
function DaycareService:compatibilityCategory()
  local score = self:compatibility()
  local category = Breeding.CATEGORY_BY_SCORE[score]
  assert(category ~= nil, "the compatibility score carries its source category")
  return category
end

-- Save_Daycare_HasEgg: a stored personality is the egg waiting for its
-- collection. A zero identity is nothing at all.
---@return boolean
function DaycareService:hasEgg()
  return self._state:pendingEggPid() ~= 0
end

-- Save_Daycare_ResetEggStats (ScrCmd_ResetDaycareEgg): the pending identity
-- and the cycle progress clear together, and the parents stay where they are.
function DaycareService:resetEgg()
  local state = self._state
  local prepared, reason = state:prepareEggReset(state:revision())
  assert(prepared ~= nil, "the day care egg reset stayed current: " .. tostring(reason))
  prepared.publish()
end

-- The two stored parents as one detached pair in source slot order.
---@return table[]
function DaycareService:_storedParents()
  if self._state:count() ~= PARENT_SLOTS then
    fail("day care has no parent pair", { parents = self._state:count() })
  end
  local first = self:_requireParent(0)
  local second = self:_requireParent(1)
  return { first, second }
end

-- Raise the source Day-Care call on the existing trigger owner. The successful
-- step check reports even when the produced identity is zero.
function DaycareService:_raiseEggCall()
  local phone = self._phone
  local state = phone.state
  assert(type(state.setTrigger) == "function", "the Day Care call needs the phone state owner")
  state:setTrigger(phone.eggTriggerKey, true)
end

-- Move the party's unhatched Eggs one completed cycle closer to hatching:
-- every Egg loses the source decrement (or one point when its friendship is
-- below it), and the first Egg already at zero friendship requests its hatch
-- and stops the walk, leaving later Eggs untouched. Answers the staged party
-- changes and the zero-based slot of the Egg that hatches.
---@param party table[]
---@return table<string, unknown>[] changes, integer? hatchSlot0
function DaycareService:_advanceEggFriendship(party)
  local decrement = Breeding.cycleDecrement(party)
  local changes = {}
  local hatchSlot0 = nil
  for slot0, mon in ipairs(party) do
    if mon.isEgg == true then
      local friendship = mon.friendship
      if friendship == 0 then
        hatchSlot0 = slot0 - 1
        break
      end
      mon.friendship = friendship >= decrement and friendship - decrement or friendship - 1
      changes[#changes + 1] = { slot = slot0 - 1, mon = mon }
    end
  end
  return changes, hatchSlot0
end

-- The one committed-step feed, in the source's own order (HandleDaycareStep):
-- every occupied parent advances its stored step counter once, the breeding
-- check runs when no egg waits and the second parent's low step byte reaches
-- 255, and the cycle counter then advances to its source threshold. Turns,
-- blocked pushes, scripted motion, warps, and modal activity never reach this
-- seam, and nothing else in the field advances these counters.
function DaycareService:noteCommittedStep()
  local state = self._state
  local advance = {}
  local occupied = state:count()
  if state:pendingEggPid() == 0 and occupied == 2 then
    -- The source advances the counters first and then reads the second
    -- parent's low step byte, so the check lands on the step that reaches 255.
    local steps = assert(state:steps(1), "the second parent carries its stored steps")
    if (steps + 1) % CYCLE_COUNTER_RANGE == 255 then
      local parents = self:_storedParents()
      local compatibility = Breeding.compatibility(parents, self._catalog)
      -- The source draws the compatibility value even for an incompatible
      -- pair, because the comparison evaluates it first.
      local draw = self._lc()
      if compatibility > math.floor(draw * 100 / 0xFFFF) then
        advance.pendingEggPid = Breeding.generateEggPid({ parents = parents, lc = self._lc, mt = self._mt })
        self:_raiseEggCall()
      end
    end
  end
  local counter = state:eggCycleCounter()
  local advanced = (counter + 1) % CYCLE_COUNTER_RANGE
  advance.eggCycleCounter = advanced
  local changes = {}
  local hatchSlot0 = nil
  if advanced == Breeding.cycleLengthFor(self._date()) then
    advance.eggCycleCounter = 0
    local party = {}
    for slot0 = 0, self._mons:partyCount() - 1 do
      party[slot0 + 1] = self._mons:partyMon(slot0)
    end
    changes, hatchSlot0 = self:_advanceEggFriendship(party)
    if hatchSlot0 ~= nil then
      -- HatchEggMon's first half runs as part of this same claim: the egg
      -- becomes the mon it carried in the publication that also advances the
      -- cycle progress, so no later step effect can observe an unhatched egg
      -- waiting in the party.
      local egg = assert(party[hatchSlot0 + 1], "the hatching slot carries its egg")
      local hatched = self._mons:buildHatchedMon(egg)
      changes[#changes + 1] = { slot = hatchSlot0, mon = hatched }
    end
  end
  local partyPrep = nil
  if #changes > 0 then
    local prepared, reason = self._mons:preparePartyChanges(self._mons:partyRevision(), changes)
    if prepared == nil then
      fail("day care egg cycle lost its party revision: " .. tostring(reason), {})
    end
    partyPrep = prepared
  end
  local prepared, reason = state:prepareStepAdvance(state:revision(), advance)
  assert(prepared ~= nil, "the day care step advance stayed current: " .. tostring(reason))
  if partyPrep ~= nil then
    assert(partyPrep.isCurrent(), "the day care egg cycle party candidate stayed current")
  end
  prepared.publish()
  if partyPrep ~= nil then
    partyPrep.publish()
  end
  if hatchSlot0 ~= nil then
    assert(self._hatch == nil, "one hatch application owns the Day Care at a time")
    self._hatch = {
      slot = hatchSlot0,
      subject = self:_hatchSubject(hatchSlot0),
      finalized = false,
    }
    return true
  end
  return false
end

-- The hatch application's immutable subject: the hatched record's own party
-- slot, species, form, personality, derived gender, and nickname fallback.
---@param slot0 integer
---@return table<string, unknown>
function DaycareService:_hatchSubject(slot0)
  local mon = assert(self._mons:partyMon(slot0), "the hatched record occupies its slot")
  local species = self._catalog:species(mon.species)
  return {
    slot = slot0,
    species = mon.species,
    speciesId = species.nativeId,
    form = mon.form,
    personality = mon.personality,
    gender = Personality.gender(species.genderRatio, mon.personality),
    nickname = self:_displayName(mon),
    -- The source picks the Manaphy scene by species alone; the shiny reroll
    -- during reconstruction is the part that also needs the Ranger receipt.
    variant = mon.species == "MANAPHY" and "manaphy" or "egg",
  }
end

-- The live hatch claim, or nil while no egg is waiting for its application.
---@return { slot: integer, subject: table<string, unknown> }?
function DaycareService:activeHatch()
  local hatch = self._hatch
  if hatch == nil then
    return nil
  end
  local subject = {}
  for key, value in pairs(hatch.subject) do
    subject[key] = value
  end
  return { slot = hatch.slot, subject = subject }
end

-- Source UPDATE_MON_INFO: the receipt of a committed hatch publishes exactly
-- once, before the optional naming screen and before the field reopens. The
-- meeting memo and the Pokedex receipt come from the mon service, and a mon
-- that descends from the original Togepi gift raises Elm's egg call and its
-- story flag. A hatch whose record was already finalized stays untouched.
function DaycareService:finishHatch()
  local hatch = self._hatch
  if hatch == nil then
    return
  end
  if hatch.finalized then
    return
  end
  hatch.finalized = true
  self._mons:finishHatch(hatch.slot)
  if self:isTogepiGift(self._mons:partyMon(hatch.slot)) then
    self:_raiseElmEggHatched()
  end
end

-- Source FieldSystem_TryTriggerElmEggHatchedCall: the matcher's own trigger and
-- story flag, with no registration or timer gate.
function DaycareService:_raiseElmEggHatched()
  local phone = self._phone
  local phoneState = phone.state
  assert(type(phoneState.setTrigger) == "function", "the hatched egg call needs the phone state owner")
  phoneState:setTrigger(phone.eggHatchedTriggerKey, true)
  local events = self._events
  assert(type(events.state.setFlag) == "function", "the hatched gift needs the field event state")
  events.state:setFlag(events.togepiFlagId)
end

-- Releases the live claim after the field is restored. The receipt was already
-- published, so a later hatch starts from a clean owner.
function DaycareService:releaseHatch()
  self._hatch = nil
end

-- Source MonIsFromTogepiEgg: the species family, the trainer identity, the
-- current language and game, and the recorded gift personality and gender must
-- all match. A migrated record without a recorded gift identity never matches.
---@param mon table<string, unknown>
---@return boolean
function DaycareService:isTogepiGift(mon)
  if type(mon) ~= "table" then
    return false
  end
  local species = mon.species
  if species ~= "TOGEPI" and species ~= "TOGETIC" and species ~= "TOGEKISS" then
    return false
  end
  local gift = self._state:togepiGift()
  if gift == nil then
    return false
  end
  local profile = self._profile
  if mon.origin.trainerId ~= profile.trainerId or mon.origin.trainerGender ~= profile.gender then
    return false
  end
  if mon.origin.language ~= self._identity.language or mon.origin.game ~= self._identity.game then
    return false
  end
  if mon.personality ~= gift.personality then
    return false
  end
  local gender = Personality.gender(self._catalog:species(species).genderRatio, mon.personality)
  return gift.gender == (gender == "female" and 1 or 0)
end

-- Source ScrCmd_GiveTogepiEgg: the full party refuses before the creation date
-- and any generator draw; otherwise the fixed level-one Togepi egg with
-- Extrasensory joins the party in the same publication that records the gift
-- personality and source gender code the hatch matcher later compares against.
---@return boolean whether the egg joined the party
function DaycareService:giveTogepiEgg()
  local mons = self._mons
  if mons:partyCount() >= Party.MAX then
    return false
  end
  local mon = mons:createTogepiEgg({})
  local partyPrep, partyReason = mons:preparePartyBatch(mons:partyRevision(), {}, { mon })
  if partyPrep == nil then
    fail("the original gift lost its party revision: " .. tostring(partyReason), {})
  end
  ---@cast partyPrep -nil
  local state = self._state
  local gender = Personality.gender(self._catalog:species("TOGEPI").genderRatio, mon.personality)
  local giftPrep, stateReason =
    state:prepareTogepiGift(state:revision(), mon.personality, gender == "female" and 1 or 0)
  if giftPrep == nil then
    fail("the original gift lost its Day Care state: " .. tostring(stateReason), {})
  end
  ---@cast giftPrep -nil
  assert(partyPrep.isCurrent(), "the original gift party candidate stayed current")
  assert(giftPrep.isCurrent(), "the original gift identity candidate stayed current")
  partyPrep.publish()
  giftPrep.publish()
  return true
end

-- Source GiveEggToPlayer (ScrCmd_GiveDaycareEgg): the stored personality
-- resolves the offspring species, the mother's form, the inherited individual
-- values and the inherited moves, and the finished level-one Egg joins the
-- party in the same publication that clears the pending identity and the cycle
-- progress. The parents stay in care, no Dex or hatch receipt is staged, and a
-- full party refuses before any draw.
---@return boolean whether the egg joined the party
function DaycareService:receiveEgg()
  local state = self._state
  local pendingEggPid = state:pendingEggPid()
  if pendingEggPid == 0 then
    fail("day care holds no egg to hand out", {})
  end
  local mons = self._mons
  if mons:partyCount() >= Party.MAX then
    return false
  end
  local parents = self:_storedParents()
  local offspring = Breeding.offspring({
    parents = parents,
    pendingEggPid = pendingEggPid,
    catalog = self._catalog,
    care = self._care,
  })
  local personality = Breeding.eggPersonality({
    pendingEggPid = pendingEggPid,
    parents = parents,
    trainerId = self._profile.trainerId,
  })
  local moves = Breeding.inheritedMoves({
    offspring = offspring,
    mother = parents[offspring.motherSlot],
    father = parents[offspring.fatherSlot],
    catalog = self._catalog,
    care = self._care,
  })
  local mon = mons:createBredEgg({
    species = offspring.species,
    form = offspring.form,
    personality = personality,
    moves = moves,
    parents = parents,
    locationOffset = 0,
  })
  local partyPrep, partyReason = mons:preparePartyBatch(mons:partyRevision(), {}, { mon })
  if partyPrep == nil then
    fail("day care egg receipt lost its party revision: " .. tostring(partyReason), {})
  end
  ---@cast partyPrep -nil
  local statePrep, stateReason = state:prepareEggReset(state:revision())
  if statePrep == nil then
    fail("day care egg receipt lost its stored state: " .. tostring(stateReason), {})
  end
  ---@cast statePrep -nil
  assert(partyPrep.isCurrent(), "the day care egg receipt party candidate stayed current")
  assert(statePrep.isCurrent(), "the day care egg receipt candidate stayed current")
  partyPrep.publish()
  statePrep.publish()
  return true
end

return DaycareService
