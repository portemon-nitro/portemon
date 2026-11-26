-- The source NPC exchange and loan domain: the generated trade records, the
-- created offered record, the one-use party receipts, the loan return checks
-- and the authored Kenya letter. Every identity rule comes from
-- src/npc_trade.c, src/field_misc_events.c::MonIsInGameTradePokeInternal and
-- src/mail.c::CreateKenyaMail; the party, Dex and statistics are the canonical
-- owners behind the mon service, and the random owner is the field's saved
-- generation stream. Trade mon identity is the source's own record identity:
-- no port-only identifier takes part in a loan match.
--
-- The service owns no active trade and no saved state: the script instance
-- keeps its trade id, the blocking task keeps the detached subject pair, and
-- the receipt is committed once through the mon service.

local Errors = require("libs.errors.src.Errors")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Mail = require("libs.mons.src.gen4.Mail")
local MonsErrors = require("libs.mons.src.errors")

---@class NpcTradeService
---@field private _trades table<string, unknown>[] the generated source records in trade order
---@field private _mons HgssMonService the live canonical mon service
---@field private _catalog MonCatalog the live mon catalog
---@field private _identity { language: string, game: string } the current language and game
---@field private _languageId integer the current language's native identity
---@field private _gameId integer the current game's native identity
---@field private _mapSectionOf fun(mapId: integer): integer the source map-section lookup
---@field private _date fun(): MonDate today's meeting date
local NpcTradeService = {}
NpcTradeService.__index = NpcTradeService

-- NPC_TRADE_KENYA_SPEAROW: the loan whose letter the source authors, and the
-- species its record still matches after evolving.
NpcTradeService.KENYA_TRADE_ID = 7
NpcTradeService.KENYA_LEVEL = 20
-- MAP_ROUTE_35_GOLDENROD_GATEHOUSE: the map the reference letter's dummy Kenya
-- is created on.
NpcTradeService.KENYA_MAP_ID = 101
NpcTradeService.KENYA_SPECIES = "SPEAROW"
NpcTradeService.KENYA_EVOLVED_SPECIES = "FEAROW"

-- METLOC_LINK_TRADE (include/constants/map_sections.h) under the source gift
-- map-section base: MonSetTrainerMemo strategy 1 writes the link-trade
-- section and ignores the map argument.
NpcTradeService.LINK_TRADE_LOCATION = 4001

-- MAIL_GRASS: ItemToMailId(ITEM_GRASS_MAIL) with FIRST_MAIL_IDX at the grass
-- stationery.
NpcTradeService.KENYA_MAIL_TYPE = 0
-- CreateKenyaMail's three Easy Chat lines: bank 1 message 7 with
-- EC_WORD_LIFESTYLE_LETTER, bank 1 message 15 with EC_WORD_LIFESTYLE_ADVENTURE,
-- and bank 2 message 1 with EC_WORD_POKEMON(SPECIES_ZUBAT); every second field
-- is the source NULL.
NpcTradeService.KENYA_MAIL_LINES = {
  { template = "mail-template:1:7", words = { "1349", false } },
  { template = "mail-template:1:15", words = { "1371", false } },
  { template = "mail-template:2:1", words = { "41", false } },
}

-- NPCTrade_CanGiveUpLoanMon's priority codes.
NpcTradeService.RETURN_OK = 0
NpcTradeService.RETURN_WRONG_MON = 1
NpcTradeService.RETURN_HELD_ITEM = 2
NpcTradeService.RETURN_CAPSULE = 3
NpcTradeService.RETURN_PARTY_TOO_SMALL = 4

---@param value unknown
---@return table<string, unknown>
local function copy(value)
  if type(value) ~= "table" then
    return value --[[@as table<string, unknown>]]
  end
  local out = {}
  for key, child in pairs(value) do
    out[key] = copy(child)
  end
  return out
end

---@class NpcTradeService.Options
---@field trades table<string, unknown>[] the generated source records
---@field mons HgssMonService the live mon service
---@field identity { language: string, game: string }
---@field mapSectionOf fun(mapId: integer): integer
---@field date fun(): MonDate
---@param opts NpcTradeService.Options
---@return NpcTradeService
function NpcTradeService.new(opts)
  assert(type(opts) == "table", "the NPC trade service requires its options")
  local trades = assert(opts.trades, "the NPC trade service requires its generated records")
  assert(type(trades) == "table", "the NPC trade service requires its generated records")
  local mons = assert(opts.mons, "the NPC trade service requires the live mon service")
  assert(type(mons) == "table", "the NPC trade service requires the live mon service")
  local identity = assert(opts.identity, "the NPC trade service requires the current identity")
  assert(type(identity) == "table", "the NPC trade service requires the current identity")
  assert(type(opts.mapSectionOf) == "function", "the NPC trade service resolves loan map sections")
  assert(type(opts.date) == "function", "the NPC trade service reads today's date")
  local languageId =
    assert(HgssMonService.LANGUAGES[identity.language], "the current language resolves for the trade records")
  assert(type(languageId) == "number", "the current language resolves to its native identity")
  local gameId = assert(HgssMonService.GAMES[identity.game], "the current game resolves for the trade records")
  assert(type(gameId) == "number", "the current game resolves to its native identity")
  return setmetatable({
    _trades = trades,
    _mons = mons,
    _catalog = mons:catalog(),
    _identity = identity,
    _languageId = languageId,
    _gameId = gameId,
    _mapSectionOf = opts.mapSectionOf,
    _date = opts.date,
  }, NpcTradeService)
end

-- One generated record by its source trade identity. The record is detached, so
-- a caller can never reach into the published catalog.
---@param tradeId integer
---@return table<string, unknown>
function NpcTradeService:tradeIdentity(tradeId)
  if type(tradeId) ~= "number" or tradeId % 1 ~= 0 or tradeId < 0 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "an NPC trade identity must be a non-negative integer", {
      tradeId = tradeId,
    })
  end
  local record = self._trades[tradeId + 1]
  if record == nil then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "the source carries no NPC trade record " .. tostring(tradeId), {
      tradeId = tradeId,
    })
  end
  assert(type(record) == "table", "the source trade record is a table")
  return copy(record)
end

---@param tradeId integer
---@return table<string, unknown> the generated record
local function recordFor(self, tradeId)
  return self:tradeIdentity(tradeId)
end

-- MonIsInGameTradePokeInternal: species (the Kenya loan still accepts its own
-- evolved form), OT id, personality, OT gender, language, met game, nickname
-- and OT name. Nothing else identifies the record.
---@param tradeId integer
---@param mon table<string, unknown>
---@return boolean
function NpcTradeService:isLoanMon(tradeId, mon)
  local record = recordFor(self, tradeId)
  assert(type(mon) == "table", "the loan identity check reads one mon record")
  local species = mon.species
  if tradeId == NpcTradeService.KENYA_TRADE_ID then
    if species ~= NpcTradeService.KENYA_SPECIES and species ~= NpcTradeService.KENYA_EVOLVED_SPECIES then
      return false
    end
  elseif species ~= record.offeredSpecies then
    return false
  end
  if mon.origin.trainerId ~= record.otId then
    return false
  end
  if mon.personality ~= record.personality then
    return false
  end
  if mon.origin.trainerGender ~= record.otGender then
    return false
  end
  if mon.origin.language ~= record.language then
    return false
  end
  if mon.origin.game ~= self._identity.game then
    return false
  end
  if mon.nickname ~= record.nickname then
    return false
  end
  if mon.origin.trainerName ~= record.otName then
    return false
  end
  return true
end

-- NPCTrade_CanGiveUpLoanMon: the identity check ranks first, then the ball
-- capsule, then a party that cannot spare the record, then the held item.
---@param tradeId integer
---@param slot0 integer
---@return integer source result code
function NpcTradeService:checkReturn(tradeId, slot0)
  local mons = self._mons
  local mon = mons:partyMon(slot0)
  if mon == nil then
    Errors.raise(MonsErrors.RECORD_INVALID, "the return check names an occupied party slot", { slot = slot0 })
  end
  assert(type(mon) == "table", "the return check reads the named party slot")
  if not self:isLoanMon(tradeId, mon) then
    return NpcTradeService.RETURN_WRONG_MON
  end
  local capsule = mon.capsule
  if type(capsule) == "table" and (capsule.id ~= 0 or #capsule.seals > 0) then
    return NpcTradeService.RETURN_CAPSULE
  end
  local living = 0
  for index = 0, mons:partyCount() - 1 do
    local candidate = mons:partyMon(index)
    if candidate.isEgg ~= true and candidate.condition.currentHp ~= 0 then
      living = living + 1
    end
  end
  if living < 2 then
    return NpcTradeService.RETURN_PARTY_TOO_SMALL
  end
  if mon.heldItem ~= "NONE" then
    return NpcTradeService.RETURN_HELD_ITEM
  end
  return NpcTradeService.RETURN_OK
end

-- The source authored Kenya letter: the loaned record's own OT identity, the
-- current language and game, the grass stationery and the three fixed Easy Chat
-- lines. The caller has already created the record; the letter never draws.
---@param mon table<string, unknown>
---@return table<string, unknown> detached canonical Mail
function NpcTradeService:kenyaMailFor(mon)
  assert(type(mon) == "table", "the Kenya letter reads its loaned record")
  local record = recordFor(self, NpcTradeService.KENYA_TRADE_ID)
  local mail = {
    schema = Mail.SCHEMA,
    type = NpcTradeService.KENYA_MAIL_TYPE,
    author = {
      -- CreateKenyaMail receives the OT id as a byte, so the author id keeps
      -- only its low byte while the mon keeps the full source value.
      trainerId = record.otId % 256,
      name = record.otName,
      gender = record.otGender,
      language = self._languageId,
      game = self._gameId,
    },
    icons = { self._catalog:iconSelection(mon), false, false },
    lines = copy(NpcTradeService.KENYA_MAIL_LINES),
  }
  return Mail.validate(mail)
end

-- NPCTrade_MakeKenyaMail: the reference letter is built from a dummy level-20
-- Kenya created on the Route 35 gatehouse, so an independent call pays that
-- creation's two individual-value draws. A loan that creates Kenya attaches the
-- letter to the record it already made instead. The dummy never enters a party.
---@return table<string, unknown> detached canonical Mail
function NpcTradeService:createKenyaMail()
  local mon = self._mons:createNpcTradeMon({
    identity = recordFor(self, NpcTradeService.KENYA_TRADE_ID),
    level = NpcTradeService.KENYA_LEVEL,
    location = self._mapSectionOf(NpcTradeService.KENYA_MAP_ID),
    date = self._date(),
  })
  return self:kenyaMailFor(mon)
end

-- Mail_Compare (src/mail.c): equal author identity, stationery type, form
-- flags, author name, the three mon icons and the three message lines. An
-- absent or unwritten letter never matches the authored reference.
---@param reference table<string, unknown> the authored reference letter
---@param mail table<string, unknown>? the letter a party mon or mailbox slot holds
---@return boolean
function NpcTradeService:mailMatches(reference, mail)
  if type(reference) ~= "table" or type(mail) ~= "table" or next(mail) == nil then
    return false
  end
  if reference.type ~= mail.type then
    return false
  end
  local leftAuthor, rightAuthor = reference.author, mail.author
  if type(leftAuthor) ~= "table" or type(rightAuthor) ~= "table" then
    return false
  end
  if
    leftAuthor.trainerId ~= rightAuthor.trainerId
    or leftAuthor.name ~= rightAuthor.name
    or leftAuthor.gender ~= rightAuthor.gender
    or leftAuthor.language ~= rightAuthor.language
    or leftAuthor.game ~= rightAuthor.game
  then
    return false
  end
  local leftIcons, rightIcons = reference.icons, mail.icons
  local leftLines, rightLines = reference.lines, mail.lines
  if type(leftIcons) ~= "table" or type(rightIcons) ~= "table" then
    return false
  end
  if type(leftLines) ~= "table" or type(rightLines) ~= "table" then
    return false
  end
  for index = 1, 3 do
    if leftIcons[index] ~= rightIcons[index] then
      return false
    end
    local leftLine, rightLine = leftLines[index], rightLines[index]
    if type(leftLine) ~= "table" or type(rightLine) ~= "table" then
      return false
    end
    if leftLine.template ~= rightLine.template then
      return false
    end
    local leftWords, rightWords = leftLine.words, rightLine.words
    if type(leftWords) ~= "table" or type(rightWords) ~= "table" or #leftWords ~= #rightWords then
      return false
    end
    for word = 1, #leftWords do
      if leftWords[word] ~= rightWords[word] then
        return false
      end
    end
  end
  return true
end

-- NPCTrade_MakeAndGiveLoanMon: the loaned record is created at the source level
-- with the map argument's section as its meeting memo, registered in the Dex,
-- appended to the party, and -- for the Kenya loan -- given its letter in the
-- same receipt. A full party refuses before any creation draw. No trade
-- sequence belongs to a loan.
---@param request { tradeId: integer, level: integer, mapId: integer }
---@return table<string, unknown> the detached received record
function NpcTradeService:giveLoan(request)
  assert(type(request) == "table", "the loan receipt requires its operands")
  local tradeId = request.tradeId
  local record = recordFor(self, tradeId)
  if self._mons:partyCount() >= 6 then
    Errors.raise(MonsErrors.RECORD_INVALID, "the loan receipt needs room in the party", { tradeId = tradeId })
  end
  local mon = self._mons:createNpcTradeMon({
    identity = record,
    level = request.level,
    location = self._mapSectionOf(request.mapId),
    date = self._date(),
  })
  if tradeId == NpcTradeService.KENYA_TRADE_ID then
    mon.mail = self:kenyaMailFor(mon)
  end
  if not self._mons:receiveMon(mon) then
    Errors.raise(MonsErrors.RECORD_INVALID, "the loan receipt needs room in the party", { tradeId = tradeId })
  end
  return copy(self._mons:partyMon(self._mons:partyCount() - 1))
end

-- NPCTrade_CreateTradeAnim's receipt half plus NPCTrade_ReceiveMonToSlot: the
-- offered record is created at the selected record's own level with the source
-- meeting memo, and the exchange replaces that slot with its Dex and score
-- receipt in one publication. A full party stays valid because the exchange
-- replaces the slot. The returned pair is the detached snapshot app71 presents.
---@param tradeId integer
---@param slot0 integer
---@return { outgoing: table<string, unknown>, incoming: table<string, unknown> }
function NpcTradeService:exchange(tradeId, slot0)
  local outgoing = self._mons:partyMon(slot0)
  if outgoing == nil then
    Errors.raise(MonsErrors.RECORD_INVALID, "the exchange names an occupied party slot", { slot = slot0 })
  end
  assert(type(outgoing) == "table", "the exchange reads the selected party slot")
  local level = self._mons:derive(outgoing).level
  local mon = self._mons:createNpcTradeMon({
    identity = recordFor(self, tradeId),
    level = level,
    location = NpcTradeService.LINK_TRADE_LOCATION,
    date = self._date(),
  })
  self._mons:exchangePartyMon(slot0, mon)
  return { outgoing = copy(outgoing), incoming = copy(mon) }
end

return NpcTradeService
