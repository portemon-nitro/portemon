-- The source specialty-NPC query leaf: the fishing-competition size record, the
-- ribbon identity reads/names, the EV total, the Kenya Mail reference checks,
-- the stat judge, the Hidden Power type, the type-name buffer and the fossil
-- queries. Every algorithm comes from the pinned native sources named beside
-- it; the party, ribbons, held items, mail and the mailbox are the canonical
-- owners behind the mon service and the NPC trade service, the bag is the
-- canonical Bag service, the size record is the saved script variable
-- VAR_MAGIKARP_SIZE_RECORD, and the dex heights are the generated dex catalog.
--
-- The service owns no saved state: its one transient value is the source
-- judge's rotating stat position, which the retail FieldSystem keeps outside the
-- save file as well.

local Errors = require("libs.errors.src.Errors")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local MonsErrors = require("libs.mons.src.errors")
local ScriptErrors = require("libs.script.src.errors")

local FieldNpcServices = {}

-- VAR_MAGIKARP_SIZE_RECORD: the saved fishing-competition length record
-- (src/sys_vars.c::Save_VarsFlags_GetFishingCompetitionLengthRecord).
local SIZE_RECORD_VAR = assert(
  FieldScriptSymbols.variablesByName.VAR_MAGIKARP_SIZE_RECORD,
  "the size record variable resolves in the generated symbol catalog"
)
-- Script variables store u16 values.
local VAR_MODULUS = 0x10000

-- sBigMonSizeTable (src/scrcmd_size_record.c): the size multiplier, its divisor
-- and the cumulative u16 hash offset that selects the row.
local BIG_MON_SIZE_TABLE = {
  { 290, 1, 0 },
  { 300, 1, 10 },
  { 400, 2, 110 },
  { 500, 4, 310 },
  { 600, 20, 710 },
  { 700, 50, 2710 },
  { 800, 100, 7710 },
  { 900, 150, 17710 },
  { 1000, 150, 32710 },
  { 1100, 100, 47710 },
  { 1200, 50, 57710 },
  { 1300, 20, 62710 },
  { 1400, 5, 64710 },
  { 1500, 2, 65210 },
  { 1600, 1, 65410 },
  { 1700, 1, 65510 },
}

-- The ordered individual values the size hash, the stat judge and the Hidden
-- Power derivation all read (src/scrcmd_size_record.c::GetMonSizeHash,
-- src/field/scrcmd_pokemon_misc.c::ScrCmd_StatJudge). This is the source's own
-- stat order: HP, Attack, Defense, Speed, Sp. Atk, Sp. Def.
local IV_ORDER = { "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }

-- sStatJudgeBestStatMsgIdxs (src/field/scrcmd_pokemon_misc.c): the best-stat
-- message per stat index.
local STAT_JUDGE_BEST_MESSAGE = { 122, 123, 124, 127, 125, 126 }
-- The stat-judge rows and the stat names live in their own message banks
-- (msg_0096_D31R0201, msg_0443).
local STAT_JUDGE_MESSAGE_BANK = 96
local STAT_NAME_MESSAGE_BANK = 443
-- BufferTypeName reads msg_0735 (src/message_format.c).
local TYPE_NAME_MESSAGE_BANK = 735

-- ScrCmd_GetHiddenPowerType's species refusal list: these species never report
-- a type, so the command answers the source's refusal value instead.
local HIDDEN_POWER_REFUSED = {
  CATERPIE = true,
  METAPOD = true,
  WEEDLE = true,
  KAKUNA = true,
  MAGIKARP = true,
  DITTO = true,
  WOBBUFFET = true,
  SMEARGLE = true,
  WURMPLE = true,
  SILCOON = true,
  CASCOON = true,
  WYNAUT = true,
  BELDUM = true,
  KRICKETOT = true,
  BURMY = true,
  COMBEE = true,
}
-- ScrCmd_GetHiddenPowerType writes -1 into a u16 script variable, so the
-- operand the script compares is 0xFFFF.
local HIDDEN_POWER_REFUSED_VALUE = 0xFFFF

-- sFossilPokemonMap (src/scrcmd_fossils.c): the seven fossils the revival
-- service accepts, in the source's own order, and the species each restores.
local FOSSILS = {
  { item = "OLD_AMBER", species = "AERODACTYL" },
  { item = "HELIX_FOSSIL", species = "OMANYTE" },
  { item = "DOME_FOSSIL", species = "KABUTO" },
  { item = "ROOT_FOSSIL", species = "LILEEP" },
  { item = "CLAW_FOSSIL", species = "ANORITH" },
  { item = "ARMOR_FOSSIL", species = "SHIELDON" },
  { item = "SKULL_FOSSIL", species = "CRANIDOS" },
}

-- LengthConvertToImperial (include/dex_mon_measures.h): integer arithmetic in
-- the source's own order, so the displayed tenths of an inch match retail.
---@param metric integer
---@return integer
local function lengthConvertToImperial(metric)
  return math.floor((math.floor(metric * 1000 / 254) + 5) / 10)
end

-- TranslateBigMonSizeTableIndex: the last row whose cumulative offset is at
-- most the hash selects the multiplier.
---@param randValue integer
---@return integer one-based table row
local function bigMonSizeTableIndex(randValue)
  for index = 2, #BIG_MON_SIZE_TABLE - 1 do
    if randValue < BIG_MON_SIZE_TABLE[index][3] then
      return index - 1
    end
  end
  return #BIG_MON_SIZE_TABLE
end

-- GetMonSize: the dex height scaled by the row the hash selects, in the
-- source's own integer arithmetic.
---@param heightDm integer
---@param randValue integer
---@return integer
local function monSize(heightDm, randValue)
  local row = BIG_MON_SIZE_TABLE[bigMonSizeTableIndex(randValue)]
  assert(row ~= nil, "the size table answers every hash")
  local scale = row[1] + math.floor((randValue - row[3]) / row[2])
  return math.floor(heightDm * scale / 10)
end

-- GetMonSizeHash: the four-bit individual values mixed with the personality
-- bytes through the source's u16 xor/multiply sequence.
---@param mon table<string, unknown>
---@return integer
local function monSizeHash(mon)
  local ivs = assert(mon.ivs, "admitted mons carry their individual values")
  assert(type(ivs) == "table", "individual values are a record")
  local personality = assert(mon.personality, "admitted mons carry their personality")
  assert(type(personality) == "number", "personality is a saved integer")
  local function low(stat)
    return ivs[stat] % 16
  end
  local high = bit.band(
    bit.bxor(
      bit.band(bit.bxor(low("specialDefense"), low("specialAttack")) * low("speed"), 0xFFFF),
      -- The source truncates the personality to its low halfword before
      -- shifting, so only bits 8..15 of the whole value reach the hash.
      bit.band(bit.rshift(personality, 8), 0xFF)
    ),
    0xFFFF
  )
  local lowByte = bit.band(
    bit.bxor(bit.band(bit.bxor(low("attack"), low("defense")) * low("hp"), 0xFFFF), bit.band(personality, 0xFF)),
    0xFFFF
  )
  return bit.band(high + bit.lshift(lowByte, 8), 0xFFFF)
end

-- GetHiddenPowerPowerType: the low individual-value bits index sixteen native
-- types past mystery, and the second bits scale the power. The field command
-- only reports the type.
---@param mon table<string, unknown>
---@return integer native type identity
local function hiddenPowerType(mon)
  local ivs = assert(mon.ivs, "admitted mons carry their individual values")
  assert(type(ivs) == "table", "individual values are a record")
  local index = 0
  for position, stat in ipairs(IV_ORDER) do
    index = index + (ivs[stat] % 2) * (2 ^ (position - 1))
  end
  local nativeType = math.floor(index * 15 / 63) + 1
  if nativeType >= 9 then
    nativeType = nativeType + 1
  end
  return nativeType
end

---@param value unknown
---@param what string
---@return integer
local function checkSlot(value, what)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 5 then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, what .. " needs a party slot in 0..5", { slot = value })
  end
  return value --[[@as integer]]
end

---@param value unknown
---@return integer
local function checkRibbon(value)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the ribbon command names a source ribbon", {
      ribbon = value,
    })
  end
  return value --[[@as integer]]
end

-- FormatSizeRecord: the whole inch count is a left-aligned three-cell field and
-- the tenth is one cell.
---@param inches integer
---@return string whole, string fraction
local function formatSize(inches)
  return string.format("%-3d", math.floor(inches / 10)), tostring(inches % 10)
end

---@class FieldNpcServices
---@field private _mons table<string, unknown> the live canonical mon service
---@field private _npcTrade table<string, unknown>? the NPC trade service behind the Kenya reference letter
---@field private _mailbox table<string, unknown>? the canonical mailbox behind the mailbox scan
---@field private _bag table<string, unknown>? the canonical Bag service behind the fossil queries
---@field private _world table<string, unknown> the live world store behind the saved size record
---@field private _dexHeight fun(species: string): integer? the generated dex height in decimetres
---@field private _resolveText fun(bankId: integer, messageId: integer): string the generated message text
---@field private _isMailItem fun(itemKey: string): boolean the mail-pocket test behind ItemIdIsMail
---@field private _ribbons (fun(): table[])? the generated ribbon entries in source order
---@field private _ribbonNameFor fun(entry: table<string, unknown>): string the generated ribbon name text
---@field private _judgePosition integer the rotating stat-judge position
FieldNpcServices.__index = FieldNpcServices

---@class FieldNpcServices.Options
---@field mons table<string, unknown> the live mon service
---@field npcTrade table<string, unknown>? the NPC trade service (Kenya Mail reference)
---@field mailbox table<string, unknown>? the canonical mailbox
---@field bag table<string, unknown>? the canonical Bag service (fossil queries)
---@field world table<string, unknown> the live world store
---@field dexHeight fun(species: string): integer? the generated dex height
---@field resolveText fun(bankId: integer, messageId: integer): string the message text resolver
---@field isMailItem fun(itemKey: string): boolean whether the item sits in the mail pocket
---@field ribbonEntries (fun(): table[])? the generated ribbon entries in source order
---@field ribbonNameFor fun(entry: table<string, unknown>): string the generated ribbon name text

---@param opts FieldNpcServices.Options
---@return FieldNpcServices
function FieldNpcServices.new(opts)
  assert(type(opts) == "table", "the NPC service requires its options")
  local mons = assert(opts.mons, "the NPC service requires the live mon service")
  assert(type(mons.partyMon) == "function", "the NPC service reads party records")
  local world = assert(opts.world, "the NPC service requires the world store")
  assert(type(world.getVar) == "function" and type(world.setVar) == "function", "the size record is a saved variable")
  local dexHeight = assert(opts.dexHeight, "the NPC service requires the generated dex heights")
  assert(type(dexHeight) == "function", "dex heights resolve by species")
  local resolveText = assert(opts.resolveText, "the NPC service requires the message resolver")
  assert(type(resolveText) == "function", "buffered names resolve display text")
  local isMailItem = assert(opts.isMailItem, "the NPC service requires the mail-pocket test")
  assert(type(isMailItem) == "function", "the mail test answers by item key")
  return setmetatable({
    _mons = mons,
    _npcTrade = opts.npcTrade,
    _mailbox = opts.mailbox,
    _bag = opts.bag,
    _world = world,
    _dexHeight = dexHeight,
    _resolveText = resolveText,
    _isMailItem = isMailItem,
    _ribbons = opts.ribbonEntries,
    _ribbonNameFor = opts.ribbonNameFor,
    _judgePosition = 0,
  }, FieldNpcServices)
end

---@param slot0 integer
---@return table<string, unknown>
function FieldNpcServices:_mon(slot0)
  local mon = self._mons:partyMon(slot0)
  if mon == nil then
    Errors.raise(MonsErrors.RECORD_INVALID, "the NPC query names an occupied party slot", { slot = slot0 })
  end
  assert(type(mon) == "table", "the party answers its record")
  return mon
end

---@param speciesKey string
---@return integer
function FieldNpcServices:_height(speciesKey)
  local height = self._dexHeight(speciesKey)
  if type(height) ~= "number" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the dex catalog carries the species height", {
      species = speciesKey,
    })
  end
  return height --[[@as integer]]
end

-- The saved record the fishing-competition NPC compares against.
---@return integer
function FieldNpcServices:sizeRecord()
  return self._world:getVar(SIZE_RECORD_VAR) % VAR_MODULUS
end

-- The imperial readout of one record hash, in the source's tenths of an inch.
---@param mon table<string, unknown>
---@param hash integer
---@return integer
function FieldNpcServices:_imperialInches(mon, hash)
  local species = assert(mon.species, "admitted mons carry their species")
  return lengthConvertToImperial(monSize(self:_height(species --[[@as string]]), hash))
end

-- ScrCmd_SizeRecordCompare: an equal imperial height makes the source return
-- TRUE without writing the result variable, so the script yields one tick; a
-- taller record answers 2 and a shorter one 0.
---@param slot0 integer
---@return string "equal"|"larger"|"smaller"
function FieldNpcServices:sizeCompare(slot0)
  local mon = self:_mon(checkSlot(slot0, "the size record comparison"))
  local own = self:_imperialInches(mon, monSizeHash(mon))
  local record = self:_imperialInches(mon, self:sizeRecord())
  if own == record then
    return "equal"
  end
  return own > record and "larger" or "smaller"
end

-- ScrCmd_SizeRecordUpdate: the mon's own hash becomes the saved record.
---@param slot0 integer
function FieldNpcServices:sizeRecordUpdate(slot0)
  local mon = self:_mon(checkSlot(slot0, "the size record update"))
  self._world:setVar(SIZE_RECORD_VAR, monSizeHash(mon) % VAR_MODULUS)
end

-- ScrCmd_BufferMonSize: the named party mon's own size.
---@param slot0 integer
---@return { whole: string, fraction: string }
function FieldNpcServices:monSizeText(slot0)
  local mon = self:_mon(checkSlot(slot0, "the mon size buffer"))
  local whole, fraction = formatSize(self:_imperialInches(mon, monSizeHash(mon)))
  return { whole = whole, fraction = fraction }
end

-- ScrCmd_BufferRecordSize: the saved record's size for the named species. The
-- source operand is the native species identity its dex table is indexed by.
---@param nativeSpeciesId integer
---@return { whole: string, fraction: string }
function FieldNpcServices:recordSizeText(nativeSpeciesId)
  if type(nativeSpeciesId) ~= "number" or nativeSpeciesId % 1 ~= 0 then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the record size buffer names a species", {
      speciesId = nativeSpeciesId,
    })
  end
  local catalog = self._mons:catalog()
  local speciesKey = catalog:speciesKeyByNativeId(nativeSpeciesId)
  if type(speciesKey) ~= "string" then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the record size buffer names a known species", {
      speciesId = nativeSpeciesId,
    })
  end
  local whole, fraction = formatSize(lengthConvertToImperial(monSize(self:_height(speciesKey), self:sizeRecord())))
  return { whole = whole, fraction = fraction }
end

-- The generated ribbon entry for one source ribbon identity, in source order
-- (src/ribbon.c::sRibbonInfo).
---@param ribbonId integer
---@return table<string, unknown>
function FieldNpcServices:_ribbon(ribbonId)
  local provider = self._ribbons
  if type(provider) ~= "function" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the NPC service requires the generated ribbon table", {})
  end
  local entries = provider()
  if type(entries) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the NPC service requires the generated ribbon table", {})
  end
  local entry = entries[checkRibbon(ribbonId) + 1]
  if type(entry) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the ribbon command names a known source ribbon", {
      ribbon = ribbonId,
    })
  end
  return entry
end

-- ScrCmd_MonHasRibbon: the stored boxed bit the retail ribbon table binds to
-- this identity.
---@param slot0 integer
---@param ribbonId integer
---@return boolean
function FieldNpcServices:monHasRibbon(slot0, ribbonId)
  local mon = self:_mon(checkSlot(slot0, "the ribbon read"))
  local entry = self:_ribbon(ribbonId)
  local stored = assert(mon.ribbons, "admitted mons carry their ribbon fields")
  assert(type(stored) == "table", "ribbon fields are a record")
  local field = stored[assert(entry.bitGroup, "ribbon entries carry their bit group")]
  if type(field) ~= "number" then
    return false
  end
  local bitIndex = assert(entry.bit, "ribbon entries carry their bit")
  return math.floor(field / (2 ^ bitIndex)) % 2 == 1
end

-- ScrCmd_BufferRibbonName: BufferRibbonNameOrDesc reads the ribbon's own name
-- row, which the generated summary family already resolves to display text.
---@param ribbonId integer
---@return string
function FieldNpcServices:ribbonName(ribbonId)
  local entry = self:_ribbon(ribbonId)
  local nameFor = self._ribbonNameFor
  if type(nameFor) ~= "function" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the NPC service requires the ribbon names", {})
  end
  return nameFor(entry)
end

-- ScrCmd_GetEVTotal: the six effort values summed.
---@param slot0 integer
---@return integer
function FieldNpcServices:evTotal(slot0)
  local mon = self:_mon(checkSlot(slot0, "the effort-value total"))
  local evs = assert(mon.evs, "admitted mons carry their effort values")
  assert(type(evs) == "table", "effort values are a record")
  local total = 0
  for _, stat in ipairs(IV_ORDER) do
    total = total + assert(evs[stat], "every effort value is saved")
  end
  return total
end

-- ItemIdIsMail: the item sits in the mail pocket.
---@param mon table<string, unknown>
---@return boolean
function FieldNpcServices:_holdsMail(mon)
  local held = mon.heldItem
  if type(held) ~= "string" then
    return false
  end
  return self._isMailItem(held) == true
end

---@return table<string, unknown>
function FieldNpcServices:_npcTradeService()
  local npcTrade = self._npcTrade
  if type(npcTrade) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the Kenya check requires the NPC trade service", {})
  end
  return npcTrade
end

-- ScrCmd_KenyaCheck: a mon holding no Mail answers FALSE. A zero `exact`
-- selector stops there; otherwise the held letter is compared with the authored
-- Kenya letter, which pays the source's two individual-value draws.
---@param slot0 integer
---@param exact boolean
---@return boolean
function FieldNpcServices:kenyaCheck(slot0, exact)
  local mon = self:_mon(checkSlot(slot0, "the Kenya check"))
  if not self:_holdsMail(mon) then
    return false
  end
  if not exact then
    return true
  end
  local npcTrade = self:_npcTradeService()
  return npcTrade:mailMatches(npcTrade:createKenyaMail(), mon.mail) == true
end

-- ScrCmd_KenyaCheckPartyOrMailbox: the reference letter is authored once and
-- compared with every Mail-holding party member, then with the Mail each
-- saved mailbox slot holds. The canonical mailbox stores the Mail record per
-- slot, so a slot either holds authored Mail or is empty.
---@return boolean
function FieldNpcServices:kenyaCheckPartyOrMailbox()
  local npcTrade = self:_npcTradeService()
  local reference = npcTrade:createKenyaMail()
  for slot = 0, self._mons:partyCount() - 1 do
    local mon = self._mons:partyMon(slot)
    if type(mon) == "table" and self:_holdsMail(mon) and npcTrade:mailMatches(reference, mon.mail) == true then
      return true
    end
  end
  local mailbox = self._mailbox
  if type(mailbox) ~= "table" then
    return false
  end
  for slot = 0, mailbox:count() - 1 do
    local mail = mailbox:get(slot)
    if type(mail) == "table" and npcTrade:mailMatches(reference, mail) == true then
      return true
    end
  end
  return false
end

-- ScrCmd_StatJudge: the individual-value total, the highest individual value and
-- the best stat's own message row. The judge's rotating position walks to the
-- first stat (from its saved position) that reaches the maximum, and then past
-- it, so a mon with tied best stats reports each of them in turn.
---@param slot0 integer
---@return { total: integer, messageId: integer, highest: integer }
function FieldNpcServices:statJudge(slot0)
  local mon = self:_mon(checkSlot(slot0, "the stat judge"))
  local ivs = assert(mon.ivs, "admitted mons carry their individual values")
  assert(type(ivs) == "table", "individual values are a record")
  local total = 0
  local highest = 0
  for _, stat in ipairs(IV_ORDER) do
    local value = assert(ivs[stat], "every individual value is saved")
    total = total + value
    if value > highest then
      highest = value
    end
  end
  local offset = self._judgePosition
  local bestIndex = offset
  for _ = 1, 6 do
    if highest == ivs[IV_ORDER[offset + 1]] then
      bestIndex = offset
      self._judgePosition = (offset + 1) % 6
      break
    end
    offset = (offset + 1) % 6
  end
  local messageId = assert(STAT_JUDGE_BEST_MESSAGE[bestIndex + 1], "the judge message table covers every stat")
  return { total = total, messageId = messageId, highest = highest }
end

-- ScrCmd_StatJudge's message operand is a bank-96 row the script prints.
---@param messageId integer
---@return string
function FieldNpcServices:statJudgeMessageText(messageId)
  return self._resolveText(STAT_JUDGE_MESSAGE_BANK, messageId)
end

-- ScrCmd_BufferStatName: BufferStatName reads bank 443 at the stat id.
---@param statId integer
---@return string
function FieldNpcServices:statName(statId)
  if type(statId) ~= "number" or statId % 1 ~= 0 or statId < 0 then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the stat name names a source stat", { stat = statId })
  end
  return self._resolveText(STAT_NAME_MESSAGE_BANK, statId)
end

-- ScrCmd_BufferTypeName: BufferTypeName reads bank 735 at the native type id.
---@param typeId integer
---@return string
function FieldNpcServices:typeName(typeId)
  if type(typeId) ~= "number" or typeId % 1 ~= 0 or typeId < 0 then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the type name names a source type", { type = typeId })
  end
  return self._resolveText(TYPE_NAME_MESSAGE_BANK, typeId)
end

-- ScrCmd_GetHiddenPowerType: the refused species report the source's u16
-- sentinel; every other mon reports its derived native type identity.
---@param slot0 integer
---@return integer
function FieldNpcServices:hiddenPowerType(slot0)
  local mon = self:_mon(checkSlot(slot0, "the Hidden Power query"))
  local species = assert(mon.species, "admitted mons carry their species")
  if
    mon.isEgg ~= true and HIDDEN_POWER_REFUSED[
      species --[[@as string]]
    ] == true
  then
    return HIDDEN_POWER_REFUSED_VALUE
  end
  return hiddenPowerType(mon)
end

---@return table<string, unknown>
function FieldNpcServices:_bagService()
  local bag = self._bag
  if type(bag) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the fossil query requires the Bag service", {})
  end
  return bag
end

-- The generated identities of one fossil row: the item the bag holds and the
-- species its revival restores, both in their native numbering.
---@param fossil table<string, unknown>
---@return integer itemId, integer speciesId
function FieldNpcServices:_fossilIdentity(fossil)
  local catalog = self._mons:catalog()
  local item = catalog:item(assert(fossil.item, "fossil rows name their item"))
  local species = catalog:species(assert(fossil.species, "fossil rows name their species"))
  return assert(item.nativeId, "item identities carry their native id"),
    assert(species.nativeId, "species identities carry their native id")
end

-- ScrCmd_CountFossils: every accepted fossil the bag holds.
---@return integer
function FieldNpcServices:fossilCount()
  local bag = self:_bagService()
  local total = 0
  for _, fossil in ipairs(FOSSILS) do
    total = total + bag:quantity(assert(fossil.item, "fossil rows name their item"))
  end
  return total
end

-- ScrCmd_GetFossilMinimumAmount: the first fossil whose cumulative held count
-- reaches the needed amount answers with its native item identity and its own
-- row; an unreached amount leaves the source's zero pair.
---@param needed integer
---@return integer itemId, integer index
function FieldNpcServices:fossilForAmount(needed)
  if type(needed) ~= "number" or needed % 1 ~= 0 then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the fossil offer names an amount", { needed = needed })
  end
  local bag = self:_bagService()
  local total = 0
  for index, fossil in ipairs(FOSSILS) do
    total = total + bag:quantity(assert(fossil.item, "fossil rows name their item"))
    if total >= needed then
      local itemId = self:_fossilIdentity(fossil)
      return itemId, index - 1
    end
  end
  return 0, 0
end

-- ScrCmd_GetFossilPokemon: the native species a fossil item restores, or zero
-- for an identity the revival service does not accept.
---@param itemId integer
---@return integer
function FieldNpcServices:fossilSpecies(itemId)
  if type(itemId) ~= "number" or itemId % 1 ~= 0 then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the fossil identity names an item", { item = itemId })
  end
  for _, fossil in ipairs(FOSSILS) do
    local knownItem, speciesId = self:_fossilIdentity(fossil)
    if knownItem == itemId then
      return speciesId
    end
  end
  return 0
end

return FieldNpcServices
