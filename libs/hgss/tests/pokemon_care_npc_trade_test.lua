-- The NPC exchange and loan domain over its own owner boundary: the generated
-- trade records, the loan identity comparison, the source return-check ranking,
-- the one-use party receipts and the authored Kenya letter. The canonical mon
-- owner behind the seam records the exact operations this service asks for, so
-- the test proves receipts, ordering and detached values without re-proving mon
-- creation (the real ROM acceptance covers that path).

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local NpcTradeService = require("libs.hgss.src.field.NpcTradeService")

local T = {}

local function tradeRecord(overrides)
  local record = {
    offeredSpecies = "ONIX",
    requestedSpecies = "BELLSPROUT",
    personality = 9711,
    otId = 48926,
    ivs = { hp = 25, attack = 20, defense = 25, speed = 15, specialAttack = 15, specialDefense = 15 },
    contest = { cool = 1, beauty = 2, cute = 3, smart = 4, tough = 5 },
    heldItem = "PERSIM_BERRY",
    otGender = 0,
    language = "english",
    nickname = "Rocky",
    otName = "Rudy",
    unusedFlag = 0,
  }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  return record
end

-- The Kenya record sits at its own source trade identity; every other index is
-- an ordinary exchange record.
local function tradesFixture()
  local trades = {}
  for tradeId = 0, NpcTradeService.KENYA_TRADE_ID do
    trades[tradeId + 1] = tradeRecord()
  end
  trades[NpcTradeService.KENYA_TRADE_ID + 1] = tradeRecord({
    offeredSpecies = "SPEAROW",
    requestedSpecies = "SPEAROW",
    personality = 27486,
    otId = 1001,
    heldItem = "GRASS_MAIL",
    nickname = "Kenya",
    otName = "Webster",
  })
  return trades
end

local function catalogStub()
  return {
    iconSelection = function(_, mon)
      return mon.species .. "/f0"
    end,
  }
end

-- A recording canonical mon owner: the service under test asks it for the
-- generated record, the party receipts, the levels and the party state.
local function monsDouble(state)
  local record = {
    party = state and state.party or {},
    created = {},
    received = {},
    exchanged = {},
    derived = 0,
    lastCreated = nil,
  }
  local service = {}
  function service:catalog()
    return catalogStub()
  end
  function service:partyCount()
    return #record.party
  end
  function service:partyMon(slot0)
    return record.party[slot0 + 1]
  end
  function service:derive(mon)
    record.derived = record.derived + 1
    return { level = assert(mon.level, "the fixture record carries its level") }
  end
  function service:createNpcTradeMon(request)
    record.created[#record.created + 1] = request
    local identity = assert(request.identity, "creation requires its identity")
    local mon = {
      species = identity.offeredSpecies,
      form = 0,
      level = request.level,
      personality = identity.personality,
      nickname = identity.nickname,
      heldItem = identity.heldItem,
      ivs = identity.ivs,
      contest = identity.contest,
      isEgg = false,
      capsule = { id = 0, seals = {} },
      mail = {},
      condition = { currentHp = 20, effects = {} },
      origin = {
        trainerId = identity.otId,
        trainerName = identity.otName,
        trainerGender = identity.otGender,
        language = identity.language,
        game = "heartgold",
      },
      met = { location = request.location, level = request.level, date = request.date },
    }
    record.lastCreated = mon
    return mon
  end
  function service:receiveMon(mon)
    record.received[#record.received + 1] = mon
    record.party[#record.party + 1] = mon
    return true
  end
  function service:exchangePartyMon(slot0, mon)
    record.exchanged[#record.exchanged + 1] = { slot = slot0, mon = mon }
    record.party[slot0 + 1] = mon
  end
  return service, record
end

local function serviceFor(mons, overrides)
  local opts = overrides or {}
  return NpcTradeService.new({
    trades = opts.trades or tradesFixture(),
    mons = mons,
    identity = { language = "english", game = "heartgold" },
    mapSectionOf = opts.mapSectionOf or function(mapId)
      return mapId == NpcTradeService.KENYA_MAP_ID and 183 or 130
    end,
    date = function()
      return { year = 2000, month = 1, day = 5 }
    end,
  })
end

function T.the_generated_record_is_detached_from_the_published_catalog()
  local trades = tradesFixture()
  local mons = monsDouble()
  local service = serviceFor(mons, { trades = trades })

  local identity = service:tradeIdentity(0)
  Assert.equal(identity.offeredSpecies, "ONIX", "the record keeps its offered species")
  Assert.deepEqual(identity.ivs, trades[1].ivs, "the record keeps its individual values")
  identity.ivs.hp = 0
  identity.nickname = "CHANGED"
  Assert.equal(service:tradeIdentity(0).ivs.hp, 25, "a caller cannot mutate the published record")
  Assert.equal(service:tradeIdentity(0).nickname, "Rocky", "a caller cannot rename the published record")

  for _, bad in ipairs({ -1, 1.5, 99, "zero" }) do
    local ok, err = pcall(NpcTradeService.tradeIdentity, service, bad)
    Assert.isFalse(ok, "an unknown source trade identity fails")
    Assert.equal(assert(Errors.is(err) and err.code), "MON_RECORD_INVALID", "the failure names the record identity")
  end
end

function T.the_loan_identity_requires_every_source_column()
  local mons = monsDouble()
  local service = serviceFor(mons)
  local kenya = service:tradeIdentity(NpcTradeService.KENYA_TRADE_ID)

  local function loanMon(overrides)
    local mon = {
      species = kenya.offeredSpecies,
      personality = kenya.personality,
      nickname = kenya.nickname,
      origin = {
        trainerId = kenya.otId,
        trainerName = kenya.otName,
        trainerGender = kenya.otGender,
        language = kenya.language,
        game = "heartgold",
      },
    }
    for key, value in pairs(overrides or {}) do
      if key == "origin" then
        for originKey, originValue in pairs(value) do
          mon.origin[originKey] = originValue
        end
      else
        mon[key] = value
      end
    end
    return mon
  end

  Assert.isTrue(service:isLoanMon(NpcTradeService.KENYA_TRADE_ID, loanMon()), "the untouched record is the loan")
  Assert.isTrue(
    service:isLoanMon(NpcTradeService.KENYA_TRADE_ID, loanMon({ species = "FEAROW" })),
    "the evolved Fearow still carries the Kenya loan"
  )
  Assert.isFalse(
    service:isLoanMon(NpcTradeService.KENYA_TRADE_ID, loanMon({ origin = { game = "soulsilver" } })),
    "the met game belongs to the identity"
  )
  Assert.isFalse(
    service:isLoanMon(NpcTradeService.KENYA_TRADE_ID, loanMon({ nickname = "KENYA" })),
    "the record nickname belongs to the identity"
  )
  Assert.isFalse(
    service:isLoanMon(NpcTradeService.KENYA_TRADE_ID, loanMon({ origin = { trainerName = "WEBSTER" } })),
    "the OT name belongs to the identity"
  )

  local shuckie = service:tradeIdentity(6)
  local shuckieMon = {
    species = shuckie.offeredSpecies,
    personality = shuckie.personality,
    nickname = shuckie.nickname,
    origin = {
      trainerId = shuckie.otId,
      trainerName = shuckie.otName,
      trainerGender = shuckie.otGender,
      language = shuckie.language,
      game = "heartgold",
    },
  }
  Assert.isTrue(service:isLoanMon(6, shuckieMon), "the Shuckle record matches its own loan")
  shuckieMon.species = "FEAROW"
  Assert.isFalse(service:isLoanMon(6, shuckieMon), "no other loan accepts an evolved form")
end

function T.the_return_check_ranks_identity_then_capsule_then_party_then_item()
  local party = {
    { species = "CHIKORITA", isEgg = false, heldItem = "NONE", capsule = { id = 0, seals = {} }, condition = { currentHp = 20 } },
    { species = "TOTODILE", isEgg = false, heldItem = "NONE", capsule = { id = 0, seals = {} }, condition = { currentHp = 20 } },
  }
  local mons = monsDouble({ party = party })
  local service = serviceFor(mons)
  local kenya = service:tradeIdentity(NpcTradeService.KENYA_TRADE_ID)
  local loan = {
    species = kenya.offeredSpecies,
    personality = kenya.personality,
    nickname = kenya.nickname,
    heldItem = "GRASS_MAIL",
    capsule = { id = 0, seals = {} },
    isEgg = false,
    condition = { currentHp = 20 },
    origin = {
      trainerId = kenya.otId,
      trainerName = kenya.otName,
      trainerGender = kenya.otGender,
      language = kenya.language,
      game = "heartgold",
    },
  }
  party[3] = loan
  Assert.equal(
    service:checkReturn(NpcTradeService.KENYA_TRADE_ID, 2),
    NpcTradeService.RETURN_HELD_ITEM,
    "the loan's own held item blocks the return"
  )
  loan.heldItem = "NONE"
  Assert.equal(
    service:checkReturn(NpcTradeService.KENYA_TRADE_ID, 2),
    NpcTradeService.RETURN_OK,
    "the clean loan returns"
  )

  loan.capsule = { id = 4, seals = {} }
  Assert.equal(
    service:checkReturn(NpcTradeService.KENYA_TRADE_ID, 2),
    NpcTradeService.RETURN_CAPSULE,
    "a ball capsule outranks the held item"
  )
  loan.capsule = { id = 0, seals = {} }
  loan.nickname = "KENYA"
  Assert.equal(
    service:checkReturn(NpcTradeService.KENYA_TRADE_ID, 2),
    NpcTradeService.RETURN_WRONG_MON,
    "a wrong identity outranks the capsule"
  )
  loan.nickname = kenya.nickname

  party[1].condition.currentHp = 0
  party[2].condition.currentHp = 0
  Assert.equal(
    service:checkReturn(NpcTradeService.KENYA_TRADE_ID, 2),
    NpcTradeService.RETURN_PARTY_TOO_SMALL,
    "a party without two living records outranks the held item"
  )
  loan.heldItem = "GRASS_MAIL"
  Assert.equal(
    service:checkReturn(NpcTradeService.KENYA_TRADE_ID, 2),
    NpcTradeService.RETURN_PARTY_TOO_SMALL,
    "the party check precedes the held-item check"
  )
  -- The source counts every living non-egg party record, the loan included, so
  -- a fainted companion plus an egg leaves only the loan itself.
  party[1].condition.currentHp = 0
  party[2].isEgg = true
  Assert.equal(
    service:checkReturn(NpcTradeService.KENYA_TRADE_ID, 2),
    NpcTradeService.RETURN_PARTY_TOO_SMALL,
    "an egg and a fainted companion leave fewer than two living records"
  )
end

function T.the_kenya_loan_attaches_the_authored_letter_in_its_receipt()
  local mons, record = monsDouble()
  local service = serviceFor(mons)

  local received = service:giveLoan({
    tradeId = NpcTradeService.KENYA_TRADE_ID,
    level = NpcTradeService.KENYA_LEVEL,
    mapId = NpcTradeService.KENYA_MAP_ID,
  })

  Assert.equal(#record.created, 1, "the loan creates exactly one record")
  local creation = record.created[1]
  Assert.equal(creation.level, NpcTradeService.KENYA_LEVEL, "the loan keeps its source level")
  Assert.equal(creation.location, 183, "the loan memo records the map operand's source section")
  Assert.deepEqual(creation.date, { year = 2000, month = 1, day = 5 }, "the loan memo dates today")
  Assert.equal(#record.received, 1, "the loan enters the party once")
  Assert.equal(received.species, "SPEAROW", "the receipt answers the created record")

  local mail = assert(received.mail, "the Kenya loan carries the source letter")
  Assert.equal(mail.schema, "g4-mail-v2", "the letter is a current Mail record")
  Assert.equal(mail.type, NpcTradeService.KENYA_MAIL_TYPE, "the letter uses the source stationery")
  Assert.equal(mail.author.trainerId, 1001 % 256, "the letter author id is the source byte truncation")
  Assert.equal(mail.author.name, "Webster", "the author is the loan's own OT name")
  Assert.equal(mail.author.gender, 0, "the author keeps the record's OT gender")
  Assert.equal(mail.author.language, 2, "the author keeps the current language")
  Assert.equal(mail.author.game, 7, "the author keeps the current game")
  Assert.deepEqual(mail.icons, { "SPEAROW/f0", false, false }, "only the first letter icon is the loan")
  Assert.deepEqual(mail.lines, NpcTradeService.KENYA_MAIL_LINES, "the three source lines travel")
  Assert.equal(received.origin.trainerId, 1001, "the record itself keeps the full source OT id")
end

function T.an_independent_reference_letter_pays_the_dummy_creation()
  local mons, record = monsDouble()
  local service = serviceFor(mons)

  local mail = service:createKenyaMail()
  Assert.equal(#record.created, 1, "the reference letter builds its own dummy Kenya")
  Assert.equal(#record.received, 0, "the dummy never enters the party")
  local creation = record.created[1]
  Assert.equal(creation.level, NpcTradeService.KENYA_LEVEL, "the dummy is the source level")
  Assert.equal(creation.location, 183, "the dummy is created on the source gatehouse map")
  Assert.equal(mail.schema, "g4-mail-v2", "the helper answers a current Mail record")

  local loanMons, loanRecord = monsDouble()
  local loanService = serviceFor(loanMons)
  local received = loanService:giveLoan({
    tradeId = NpcTradeService.KENYA_TRADE_ID,
    level = NpcTradeService.KENYA_LEVEL,
    mapId = NpcTradeService.KENYA_MAP_ID,
  })
  Assert.equal(#loanRecord.created, 1, "a loan creating Kenya pays no second dummy creation")
  Assert.deepEqual(received.mail, mail, "the independent letter is the same source letter")
end

function T.the_loan_receipt_refuses_a_full_party_before_creating_anything()
  local party = {}
  for slot = 1, 6 do
    party[slot] = { species = "CHIKORITA", isEgg = false, heldItem = "NONE", capsule = { id = 0, seals = {} }, condition = { currentHp = 20 } }
  end
  local mons, record = monsDouble({ party = party })
  local service = serviceFor(mons)
  local ok, err = pcall(NpcTradeService.giveLoan, service, {
    tradeId = 6,
    level = NpcTradeService.KENYA_LEVEL,
    mapId = 75,
  })
  Assert.isFalse(ok, "a full party refuses the loan")
  Assert.equal(assert(Errors.is(err) and err.code), "MON_RECORD_INVALID", "the failure names the record identity")
  Assert.equal(#record.created, 0, "the refusal happens before any creation draw")
  Assert.equal(#record.received, 0, "the refusal publishes nothing")
end

function T.the_exchange_publishes_the_link_trade_memo_at_the_outgoing_level()
  local outgoing = {
    species = "CHIKORITA",
    level = 23,
    personality = 1234,
    nickname = nil,
    isEgg = false,
    heldItem = "NONE",
    capsule = { id = 0, seals = {} },
    condition = { currentHp = 20 },
    origin = { trainerId = 7, trainerName = "RED", trainerGender = 0, language = "english", game = "heartgold" },
  }
  local mons, record = monsDouble({ party = { outgoing } })
  local service = serviceFor(mons)

  local subjects = service:exchange(2, 0)
  Assert.equal(#record.exchanged, 1, "the exchange publishes exactly one party replacement")
  Assert.equal(record.exchanged[1].slot, 0, "the selected slot is the one replaced")
  local creation = record.created[1]
  Assert.equal(creation.level, 23, "the offered record is created at the outgoing level")
  Assert.equal(
    creation.location,
    NpcTradeService.LINK_TRADE_LOCATION,
    "the exchange memo is the source link-trade section"
  )
  Assert.equal(#record.received, 0, "an exchange never appends to the party")

  Assert.equal(subjects.outgoing.personality, outgoing.personality, "the snapshot reports the sent record")
  Assert.equal(subjects.incoming.personality, record.created[1].identity.personality, "the snapshot reports the received record")
  subjects.outgoing.personality = 0
  Assert.equal(service._mons:partyMon(0).personality, record.lastCreated.personality, "the snapshots are detached")
end

return { tests = T }
