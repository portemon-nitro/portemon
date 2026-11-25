-- The Pokegear catalog compiler decodes source phonebook bytes and sprite
-- resource descriptors structurally: exact counts and sentinel termination
-- are required, duplicate semantic identities and dangling references fail
-- precisely, and malformed buffers never decode to plausible records.

local Assert = require("tests.support.Assert")

local T = {}

local function packU32(value)
  value = value % 4294967296
  local b0 = value % 256
  local b1 = math.floor(value / 256) % 256
  local b2 = math.floor(value / 65536) % 256
  local b3 = math.floor(value / 16777216) % 256
  return string.char(b0, b1, b2, b3)
end

local function packU16(value)
  value = value % 65536
  return string.char(value % 256, math.floor(value / 256) % 256)
end

-- One synthetic phonebook record in the native PhoneBookEntry layout:
-- id, type, unused byte, trainer class, trainer id, map id, gift
-- item, local phone-script selector, greeting set, rematch weekday,
-- rematch time of day, random-call group, and four sort bytes.
---@param fields table<string, integer|integer[]|nil>
---@return string
local function structRecord(fields)
  local weights = fields.sortWeights or { 0, 0, 0, 0 }
  local head = string.char(fields.id % 256, fields.type % 256, 0, fields.trainerClass % 256)
  local halves = packU16(fields.trainerId or 0)
    .. packU16(fields.mapId or 0)
    .. packU16(fields.gift or 0)
    .. packU16(fields.phoneScriptIfLocal or 0)
  local tail = string.char(
    fields.greetingMsgSet or 0,
    fields.rematchWeekday or 0,
    fields.rematchTimeOfDay or 0,
    fields.randomCallGroup or 0,
    weights[1] % 256,
    weights[2] % 256,
    weights[3] % 256,
    weights[4] % 256
  )
  return head .. halves .. tail
end

---@param trainerClass integer
---@param trainerId integer
---@param weights integer[]?
---@return string
local function phonebookRecord(trainerClass, trainerId, weights)
  return structRecord({
    id = 7,
    type = 1,
    trainerClass = trainerClass,
    trainerId = trainerId,
    mapId = 11,
    gift = 12,
    phoneScriptIfLocal = 13,
    greetingMsgSet = 3,
    rematchWeekday = 4,
    rematchTimeOfDay = 5,
    randomCallGroup = 6,
    sortWeights = weights or { 1, 2, 3, 4 },
  })
end

local function phonebookBytes(records)
  local out = { packU32(#records) }
  for _, record in ipairs(records) do
    out[#out + 1] = record
  end
  return table.concat(out)
end

function T.phone_catalog_records_native_name_and_class_sources()
  local PokegearCatalogCompiler = require("romdump.src.digest.ui.PokegearCatalogCompiler")
  local decoded = assert(PokegearCatalogCompiler.decodePhonebook(phonebookBytes({ phonebookRecord(5, 11) })))
  local contact = decoded.contacts[1]
  Assert.equal(contact.name.bank, contact.messageBank, "caller names use their message bank")
  Assert.equal(contact.name.entry, 0, "caller names use message entry zero")
  Assert.equal(contact.class.kind, "message", "trainer classes use a source message")
  Assert.equal(contact.class.bank, 730, "ordinary class text uses the source trainer-class bank")
  Assert.equal(contact.class.entry, contact.trainerClass, "ordinary class entry follows the native trainer-class byte")
  local mother = assert(PokegearCatalogCompiler.decodePhonebook(phonebookBytes({ phonebookRecord(200, 11) })))
  Assert.equal(mother.contacts[1].class.kind, "blank", "the native Mom trainer class has no class label")
end

function T.native_phone_script_definitions_cover_all_numbered_slots()
  local PokegearPhoneScriptSources = require("romdump.src.config.PokegearPhoneScriptSources")
  local definitions = PokegearPhoneScriptSources.definitions
  Assert.equal(#definitions, 455, "the source contains every numbered native phone script")
  Assert.equal(definitions[1].id, 1, "native script ids start at one after the empty slot")
  Assert.equal(definitions[1].male.bank, 716, "Elm's first script uses Elm's caller bank")
  Assert.equal(definitions[1].male.entry, 1, "Elm's first male message matches the source definition")
  Assert.equal(definitions[1].female.entry, 2, "Elm's first female message matches the source definition")
  Assert.equal(definitions[455].id, 455, "native script ids preserve the final source slot")
  for index, definition in ipairs(definitions) do
    Assert.equal(definition.id, index, "native script records remain contiguous")
    Assert.equal(definition.male.bank, definition.female.bank, "gendered script messages use one caller bank")
  end
end

function T.well_formed_phonebook_decodes_contacts_with_stable_keys()
  local PokegearCatalogCompiler = require("romdump.src.digest.ui.PokegearCatalogCompiler")
  local decoded, err = PokegearCatalogCompiler.decodePhonebook(
    phonebookBytes({ phonebookRecord(5, 11, { 30, 20, 10, 40 }), phonebookRecord(6, 12, { 1, 2, 3, 4 }) })
  )
  Assert.notNil(decoded, "a well-formed phonebook must decode: " .. tostring(err and err.message or err))
  Assert.equal(#decoded.contacts, 2, "every source record decodes to one contact")
  Assert.equal(#decoded.contactOrder, 2, "every contact joins the source order")
  local first, second = decoded.contacts[1], decoded.contacts[2]
  Assert.isTrue(first.key ~= second.key, "contacts carry distinct semantic keys")
  Assert.isTrue(first.key:find(".", 1, true) ~= nil, "contact keys are namespaced")
  Assert.deepEqual(first.sortWeights, { 30, 20, 10, 40 }, "all four sort bytes compile as sort weights")
  Assert.equal(decoded.contactOrder[1], first.key, "array position never becomes contact identity")
  Assert.equal(first.sourceIndex, 0, "the producer translation retains the native index")
end

function T.phonebook_count_mismatch_is_rejected()
  local PokegearCatalogCompiler = require("romdump.src.digest.ui.PokegearCatalogCompiler")
  local short = packU32(2) .. phonebookRecord(5, 11)
  local decoded, err = PokegearCatalogCompiler.decodePhonebook(short)
  Assert.isNil(decoded, "a count longer than the payload must not decode")
  Assert.notNil(err, "a count mismatch must carry an error")

  local trailing = phonebookBytes({ phonebookRecord(5, 11) }) .. "trailing-bytes!!"
  Assert.isNil(PokegearCatalogCompiler.decodePhonebook(trailing), "trailing bytes must not decode")
  Assert.isNil(PokegearCatalogCompiler.decodePhonebook(""), "an empty phonebook must not decode")
  Assert.isNil(PokegearCatalogCompiler.decodePhonebook(packU32(1)), "a count without records must not decode")
end

function T.duplicate_derived_contact_identities_are_rejected()
  local PokegearCatalogCompiler = require("romdump.src.digest.ui.PokegearCatalogCompiler")
  local decoded, err =
    PokegearCatalogCompiler.decodePhonebook(phonebookBytes({ phonebookRecord(5, 11), phonebookRecord(5, 11) }))
  Assert.isNil(decoded, "duplicate derived identities must not decode")
  Assert.notNil(err, "duplicate identities must carry an error")
end

-- The retail phonebook record follows the native PhoneBookEntry struct:
-- id, type, two class bytes, trainer id, map id, gift item, local
-- phone-script selector, greeting set, rematch weekday, rematch time of
-- day, random-call group, and four sort bytes. The decoder publishes
-- those struct names so runtime selection never re-derives them.
function T.phonebook_records_decode_to_native_struct_names()
  local PokegearCatalogCompiler = require("romdump.src.digest.ui.PokegearCatalogCompiler")
  local decoded, err = PokegearCatalogCompiler.decodePhonebook(phonebookBytes({
    structRecord({
      id = 0,
      type = 1,
      trainerClass = 200,
      trainerId = 0,
      mapId = 63,
      gift = 0,
      phoneScriptIfLocal = 23,
      greetingMsgSet = 255,
      rematchWeekday = 3,
      rematchTimeOfDay = 3,
      randomCallGroup = 0,
      sortWeights = { 1, 55, 30, 0 },
    }),
  }))
  Assert.notNil(decoded, "a struct-layout phonebook must decode: " .. tostring(err and err.message or err))
  assert(decoded ~= nil, "struct-layout phonebook decoded above")
  local contact = decoded.contacts[1]
  Assert.equal(contact.key, "hg.trainer.200.map.0.contact.0", "contact identity names its class, map, and index")
  Assert.equal(contact.trainerClass, 200, "the class byte names the trainer class")
  Assert.equal(contact.trainerId, 0, "the first halfword names the trainer identity")
  Assert.equal(contact.mapId, 63, "the second halfword names the map identity")
  Assert.equal(contact.gift, 0, "the third halfword names the gift item")
  Assert.equal(contact.phoneScriptIfLocal, 23, "the fourth halfword names the local phone-script selector")
  Assert.equal(contact.greetingMsgSet, 255, "the trailing set byte names the greeting set")
  Assert.equal(contact.rematchWeekday, 3, "rematch weekday follows the greeting set")
  Assert.equal(contact.rematchTimeOfDay, 3, "rematch time of day follows the weekday")
  Assert.equal(contact.randomCallGroup, 0, "the group byte names the random-call group")
  Assert.deepEqual(contact.sortWeights, { 1, 55, 30, 0 }, "all four sort bytes compile as sort weights")
end

-- Trainer contacts carry their own generic header tables: every row
-- stays a four-number gate tuple, and mutating the compiled rows never
-- touches the shared producer tables.
function T.trainer_contacts_carry_detached_generic_header_tables()
  local PokegearCatalogCompiler = require("romdump.src.digest.ui.PokegearCatalogCompiler")
  local PokegearSources = require("romdump.src.config.PokegearSources")
  local decoded, err = PokegearCatalogCompiler.decodePhonebook(phonebookBytes({
    structRecord({
      id = 10,
      type = 0,
      trainerClass = 2,
      trainerId = 8,
      mapId = 34,
      gift = 45,
      phoneScriptIfLocal = 29,
      greetingMsgSet = 0,
      rematchWeekday = 1,
      rematchTimeOfDay = 1,
      randomCallGroup = 1,
    }),
  }))
  Assert.notNil(decoded, "a trainer phonebook must decode: " .. tostring(err and err.message or err))
  assert(decoded ~= nil, "trainer phonebook decoded above")
  local contact = decoded.contacts[1]
  local headers = assert(contact.genericHeaders, "trainer contacts carry generic header tables")
  for _, direction in ipairs({ "outgoing", "incoming" }) do
    local rows = headers[direction]
    Assert.equal(#rows, 8, "the " .. direction .. " table carries eight rows")
    for index, row in ipairs(rows) do
      Assert.equal(#row, 4, direction .. " row " .. index .. " stays a four-field gate tuple")
    end
  end
  local producerRow = assert(PokegearSources.phoneGenericHeaders[10].outgoing[1], "the producer carries Joey's rows")
  local producerGate = producerRow[1]
  headers.outgoing[1][1] = 255
  Assert.equal(
    PokegearSources.phoneGenericHeaders[10].outgoing[1][1],
    producerGate,
    "a compiled-row mutation never reaches the producer table"
  )
end

local SENTINEL_U32 = 4294967294

local function resdatList(resourceType, records)
  local out = { packU32(resourceType) }
  for _, record in ipairs(records) do
    for _, word in ipairs(record) do
      out[#out + 1] = packU32(word)
    end
  end
  for _ = 1, 6 do
    out[#out + 1] = packU32(SENTINEL_U32)
  end
  return table.concat(out)
end

function T.resource_lists_require_sentinel_termination()
  local PokegearCatalogCompiler = require("romdump.src.digest.ui.PokegearCatalogCompiler")
  local parsed, err =
    PokegearCatalogCompiler.validateResdatList(resdatList(3, { { 143, 5, 1, 9, 0, 0 } }), "fixture-list")
  Assert.notNil(parsed, "a terminated resource list must validate: " .. tostring(err and err.message or err))
  Assert.equal(parsed.resourceType, 3, "the list keeps its resource type")
  Assert.equal(#parsed.records, 1, "the list keeps its records")

  local missing = packU32(3) .. packU32(143) .. packU32(5) .. packU32(1) .. packU32(9) .. packU32(0) .. packU32(0)
  Assert.isNil(
    PokegearCatalogCompiler.validateResdatList(missing, "fixture-list"),
    "a list without its sentinel must not validate"
  )

  local partial = resdatList(3, { { 143, 5, 1, 9, 0, 0 } })
  partial = partial:sub(1, #partial - 4) .. packU32(0)
  Assert.isNil(
    PokegearCatalogCompiler.validateResdatList(partial, "fixture-list"),
    "a partial sentinel must not validate"
  )
  Assert.isNil(PokegearCatalogCompiler.validateResdatList("short", "fixture-list"), "a short list must not validate")
end

local function resdatHeaders(records)
  local out = {}
  for _, record in ipairs(records) do
    for _, word in ipairs(record) do
      out[#out + 1] = packU32(word)
    end
  end
  for _ = 1, 8 do
    out[#out + 1] = packU32(SENTINEL_U32)
  end
  return table.concat(out)
end

function T.header_sets_validate_bindings_and_reject_bad_transfers()
  local PokegearCatalogCompiler = require("romdump.src.digest.ui.PokegearCatalogCompiler")
  local parsed, err =
    PokegearCatalogCompiler.validateResdatHeaders(resdatHeaders({ { 34, 35, 33, 32, 0, 0, 1, 7 } }), "fixture-headers")
  Assert.notNil(parsed, "a terminated header set must validate: " .. tostring(err and err.message or err))
  Assert.equal(#parsed, 1, "the header set keeps its records")
  Assert.equal(parsed[1].char, 34, "header records keep their character binding")

  Assert.isNil(
    PokegearCatalogCompiler.validateResdatHeaders(resdatHeaders({ { 34, 35, 33, 32, 0, 0, 99, 7 } }), "fixture-headers"),
    "an unsupported transfer mode must not validate"
  )
  Assert.isNil(
    PokegearCatalogCompiler.validateResdatHeaders(packU32(1), "fixture-headers"),
    "a misaligned header set must not validate"
  )
end

-- Map location and flypoint records keep their five identities distinct
-- across outdoor, indoor, fallback, and special roles, and every
-- flypoint reference resolves. Unknown versions fail loudly and records
-- detach from the producer tables.
function T.map_location_and_flypoint_records_cover_their_roles()
  local PokegearSources = require("romdump.src.config.PokegearSources")
  for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
    local locations = PokegearSources.mapLocationRecords(versionId)
    Assert.isTrue(#locations > 0, versionId .. " compiles a non-empty location table")
    local flypoints = PokegearSources.mapFlypointRecords(versionId)
    Assert.isTrue(#flypoints > 0, versionId .. " compiles a non-empty flypoint table")
    local flyKeys = {}
    for _, fly in ipairs(flypoints) do
      Assert.notNil(fly.key, "flypoints carry semantic keys")
      flyKeys[fly.key] = true
    end
    local roles = { outdoor = 0, indoor = 0, fallback = 0 }
    local specials = {}
    for _, entry in ipairs(locations) do
      for _, role in ipairs({ "fieldMap", "matrix", "location", "section", "flypoint" }) do
        Assert.notNil(entry[role], versionId .. " locations distinguish their " .. role .. " identity")
      end
      Assert.notNil(entry.key, "locations carry semantic keys")
      Assert.notNil(entry.region, "locations carry their region")
      if type(entry.flypoint) == "string" then
        Assert.isTrue(flyKeys[entry.flypoint] == true, "location flypoints reference the compiled table")
      end
      if entry.special ~= nil then
        specials[entry.special] = true
      elseif entry.explicitX == nil then
        roles.outdoor = roles.outdoor + 1
      elseif entry.explicitX == 0 and entry.explicitY == 0 then
        roles.fallback = roles.fallback + 1
      else
        roles.indoor = roles.indoor + 1
      end
    end
    Assert.isTrue(roles.outdoor > 0, "outdoor main-matrix maps project without header coordinates")
    Assert.isTrue(roles.indoor > 0, "indoor maps keep explicit header coordinates")
    Assert.isTrue(roles.fallback > 0, "zero-coordinate maps take the exterior fallback")
    for _, special in ipairs({ "mt-silver", "indigo", "sinjoh", "aqua" }) do
      Assert.isTrue(specials[special] == true, "the " .. special .. " special keeps its tabled coordinates")
    end
  end
  Assert.throws(function()
    PokegearSources.mapLocationRecords("platinum")
  end, "an unsupported version never compiles an empty map")
  local first = PokegearSources.mapLocationRecords("heartgold")
  first[1].matrix.x = -1
  local second = PokegearSources.mapLocationRecords("heartgold")
  Assert.isTrue(second[1].matrix.x ~= -1, "location records detach from the producer table")
end

-- Radio reception sets transcribe the native channel-selection source:
-- the exact sAlphMaps/sMahoganyMaps lists behind Radio_IsInSpecialMap
-- plus every header map with radioSignal false behind
-- MapHeader_CanReceiveRadioSignal. Counts, source order anchors, and
-- disjointness are pinned; unknown versions fail loudly and records
-- detach from the producer tables.
function T.radio_reception_sets_carry_the_source_channel_maps()
  local PokegearSources = require("romdump.src.config.PokegearSources")
  for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
    local reception = PokegearSources.radioReceptionRecords(versionId)
    Assert.equal(#reception.alph, 5, versionId .. " compiles the five listed Alph maps")
    Assert.equal(#reception.mahogany, 17, versionId .. " compiles the seventeen listed Mahogany maps")
    Assert.equal(#reception.forbidden, 34, versionId .. " compiles the thirty-four signal-free maps")
    Assert.equal(reception.alph[1], "MAP_RUINS_OF_ALPH_UNDERGROUND_HALL", "the Alph set opens in source order")
    Assert.equal(
      reception.alph[5],
      "MAP_RUINS_OF_ALPH_UNDERGROUND_HALL_SINJOH_EVENT_2",
      "the Alph set closes in source order"
    )
    Assert.equal(reception.mahogany[1], "MAP_MAHOGANY", "the Mahogany set opens in source order")
    Assert.equal(
      reception.mahogany[17],
      "MAP_LAKE_OF_RAGE_FISHING_GURU_HOUSE",
      "the Mahogany set closes in source order"
    )
    Assert.equal(reception.forbidden[1], "MAP_EVERYWHERE", "the forbidden set opens in map order")
    Assert.equal(reception.forbidden[34], "MAP_UNUSED", "the forbidden set closes in map order")
    local seen = {}
    for _, set in ipairs({ reception.alph, reception.mahogany, reception.forbidden }) do
      for _, symbol in ipairs(set) do
        Assert.isNil(seen[symbol], "no map belongs to two reception sets: " .. symbol)
        seen[symbol] = true
      end
    end
  end
  Assert.throws(function()
    PokegearSources.radioReceptionRecords("platinum")
  end, "an unsupported version never compiles an empty reception table")
  local first = PokegearSources.radioReceptionRecords("heartgold")
  first.alph[1] = "MAP_MUTATED"
  local second = PokegearSources.radioReceptionRecords("heartgold")
  Assert.isTrue(second.alph[1] ~= "MAP_MUTATED", "reception records detach from the producer tables")
end

-- The reception sets agree with the frozen header reference: every listed
-- symbol resolves to a real header map, and the forbidden set is exactly
-- the radioSignal-false set (the drift guard runs both directions). The
-- Mahogany list spans four map sections, pinning why section membership
-- could never reproduce the source lists.
function T.radio_reception_sets_agree_with_the_header_reference()
  local PokegearSources = require("romdump.src.config.PokegearSources")
  local maps = require("romdump.src.catalog.hgss.maps")
  local bySymbol, unlit = {}, {}
  for id = 0, maps.count - 1 do
    local record = assert(maps.byId[id], "header map " .. id .. " exists")
    bySymbol[record.symbol] = record
    if record.radioSignal == false then
      unlit[record.symbol] = true
    end
  end
  local reception = PokegearSources.radioReceptionRecords("heartgold")
  local sections = {}
  for _, set in ipairs({ reception.alph, reception.mahogany, reception.forbidden }) do
    for _, symbol in ipairs(set) do
      local record = bySymbol[symbol]
      Assert.notNil(record, "reception symbol resolves to a header map: " .. symbol)
    end
  end
  for _, symbol in ipairs(reception.mahogany) do
    sections[bySymbol[symbol].mapSection] = true
  end
  for _, section in ipairs({ "MAHOGANY_TOWN", "TEAM_ROCKET_HQ", "ROUTE_43", "LAKE_OF_RAGE" }) do
    Assert.isTrue(sections[section] == true, "the Mahogany set spans " .. section)
  end
  local forbiddenCount = 0
  for _ in pairs(unlit) do
    forbiddenCount = forbiddenCount + 1
  end
  Assert.equal(forbiddenCount, #reception.forbidden, "every signal-free header map is listed")
  local listed = {}
  for _, symbol in ipairs(reception.forbidden) do
    listed[symbol] = true
  end
  for symbol in pairs(unlit) do
    Assert.isTrue(listed[symbol] == true, "no signal-free header map is missing: " .. symbol)
  end
end

-- The per-contact phone message banks transcribe the source
-- sPhoneMessageGmm table behind GetPhoneMessageGmm: seventy-five banks
-- in phonebook-id order, every bank inside msg_0641..msg_0716, with
-- msg_0668 absent (no caller reads it). Anchors pin both ends plus the
-- first three callers; the bank-id helper returns the distinct sorted set
-- detached from the producer table.
function T.phone_message_banks_carry_the_source_contact_index()
  local PokegearSources = require("romdump.src.config.PokegearSources")
  local banks = PokegearSources.phoneMessageBanks
  Assert.equal(#banks, 75, "the phone index covers all seventy-five callers")
  Assert.equal(banks[1], 664, "contact 0 (mother) reads bank 664")
  Assert.equal(banks[2], 716, "contact 1 (elm) reads bank 716")
  Assert.equal(banks[3], 666, "contact 2 (oak) reads bank 666")
  Assert.equal(banks[75], 678, "contact 74 (ernest) reads bank 678")
  local seen = {}
  for _, bank in ipairs(banks) do
    Assert.isTrue(bank >= 641 and bank <= 716, "phone bank " .. bank .. " stays in the msg range")
    Assert.isTrue(bank ~= 668, "msg_0668 has no caller")
    seen[bank] = true
  end
  local distinct = PokegearSources.phoneMessageBankIds()
  Assert.equal(#distinct, 75, "every caller owns its own bank")
  for index = 2, #distinct do
    Assert.isTrue(distinct[index - 1] < distinct[index], "the bank helper stays sorted")
  end
  for _, bank in ipairs(distinct) do
    Assert.isTrue(seen[bank] == true, "the bank helper covers phone bank " .. bank)
  end
  distinct[1] = -1
  local fresh = PokegearSources.phoneMessageBankIds()
  Assert.isTrue(fresh[1] ~= -1, "the bank helper detaches from the producer table")
end

-- Compiled contacts carry their message bank beside their greeting
-- entry: the record id joins the phone index, and an id outside the
-- index is corrupt phonebook data, never an empty bank.
function T.compiled_contacts_carry_their_message_bank()
  local PokegearCatalogCompiler = require("romdump.src.digest.ui.PokegearCatalogCompiler")
  local decoded, err = PokegearCatalogCompiler.decodePhonebook(
    phonebookBytes({ phonebookRecord(5, 11, { 30, 20, 10, 40 }), phonebookRecord(6, 12, { 1, 2, 3, 4 }) })
  )
  Assert.notNil(decoded, "a well-formed phonebook must decode: " .. tostring(err and err.message or err))
  for _, contact in ipairs(decoded.contacts) do
    Assert.equal(contact.id, 7, "the fixture records carry phonebook number 7")
    Assert.equal(contact.messageBank, 660, "phonebook number 7 reads the day-care lady bank")
  end
  local wild = phonebookBytes({ phonebookRecord(5, 11) })
  wild = wild:sub(1, 4) .. string.char(200) .. wild:sub(6)
  local rejected, rejectErr = PokegearCatalogCompiler.decodePhonebook(wild)
  Assert.isNil(rejected, "a contact id outside the phone index must not decode")
  Assert.notNil(rejectErr, "an out-of-index contact id must carry an error")
  Assert.equal(rejectErr.code, "POKEGEAR_PHONEBOOK_INVALID", "the failure carries its attribution")
end

-- The retail trigger table behind GearPhoneRingManager
-- (sPhoneCallTriggers): one record per source slot carrying that slot's
-- caller, predefined script identity, and force-pickup flag.
function T.native_phone_trigger_table_names_every_source_slot_once()
  local PokegearSources = require("romdump.src.config.PokegearSources")
  local records = PokegearSources.phoneTriggerRecords("soulsilver")
  -- sPhoneCallTriggers order: script identity and force-pickup flag per
  -- slot (Oak, Day-Care Man, and the newest Baoba slots launch with
  -- PHONE_SCRIPT_NONE, i.e. no predefined script).
  local expected = {
    [0] = { callScriptID = 13, forcePickUp = false },
    [1] = { callScriptID = 7, forcePickUp = false },
    [2] = { callScriptID = 85, forcePickUp = true },
    [3] = { callScriptID = 93, forcePickUp = true },
    [4] = { forcePickUp = false },
    [5] = { forcePickUp = false },
    [6] = { forcePickUp = false },
    [7] = { callScriptID = 142, forcePickUp = true },
    [8] = { callScriptID = 143, forcePickUp = true },
    [9] = { callScriptID = 144, forcePickUp = true },
    [10] = { callScriptID = 145, forcePickUp = true },
    [11] = { callScriptID = 146, forcePickUp = true },
    [12] = { callScriptID = 27, forcePickUp = false },
  }
  local bySlot, keys = {}, {}
  for _, record in ipairs(records) do
    Assert.equal(bySlot[record.slot], nil, "slot " .. tostring(record.slot) .. " is compiled once")
    Assert.isTrue(type(record.key) == "string" and record.key ~= "", "every trigger record names its key")
    Assert.equal(keys[record.key], nil, "trigger keys stay unique: " .. record.key)
    Assert.isTrue(type(record.contact) == "string" and record.contact ~= "", "every trigger names its caller")
    bySlot[record.slot] = record
    keys[record.key] = true
  end
  for slot, want in pairs(expected) do
    local record = assert(bySlot[slot], "the trigger table carries source slot " .. tostring(slot))
    Assert.equal(record.callScriptID, want.callScriptID, "slot " .. slot .. " carries its source script identity")
    Assert.equal(record.forcePickUp, want.forcePickUp, "slot " .. slot .. " carries its source pickup flag")
  end
  -- Slots sharing a retail caller share one catalogue contact: Elm owns
  -- the egg and Pokerus calls, Baoba owns the arrangement calls.
  Assert.equal(bySlot[0].contact, bySlot[1].contact, "both Elm calls ring the same caller")
  for slot = 7, 11 do
    Assert.equal(bySlot[slot].contact, bySlot[6].contact, "every Baoba call rings the same caller")
  end
  Assert.equal(#records, 13, "the trigger table carries only its thirteen source slots")
end

-- Word-kind scripts stage a bank-entry reference plus a pick count:
-- the consumer formats bank entry (base + pick), so every word
-- definition must carry a parseable reference and a positive count.
function T.word_script_definitions_carry_parseable_word_references()
  local PokegearPhoneScriptSources = require("romdump.src.config.PokegearPhoneScriptSources")
  local seen = 0
  for _, definition in ipairs(PokegearPhoneScriptSources.definitions) do
    if definition.kind == "word" then
      seen = seen + 1
      Assert.isTrue(
        type(definition.param1) == "string" and definition.param1:match("^msg_(%d+)_(%d+)$") ~= nil,
        "word script " .. tostring(definition.id) .. " stages a bank entry reference"
      )
      Assert.isTrue(
        type(definition.param0) == "number" and definition.param0 > 0,
        "word script " .. tostring(definition.id) .. " draws a positive pick count"
      )
    end
  end
  Assert.isTrue(seen > 0, "the script table stages word picks")
end

-- The source rematch sets are projected keyed by the base trainer a
-- phonebook entry names, and a dump whose trainer archive cannot back a
-- referenced trainer fails the build instead of publishing a plausible row.
function T.rematch_sets_project_native_rows_and_validate_their_trainers()
  local PokegearCatalogCompiler = require("romdump.src.digest.ui.PokegearCatalogCompiler")
  local PokegearSources = require("romdump.src.config.PokegearSources")
  local trainerCount = 728
  local function romFsWithTrainers(count)
    return {
      openNarc = function(_, name)
        Assert.equal(name, "trainer_data", "rematch validation reads the trainer archive")
        if count == nil then
          return nil, "missing archive"
        end
        return {
          memberCount = function()
            return count
          end,
        }
      end,
    }
  end
  local compiled = assert(PokegearCatalogCompiler.compileRematchSets(romFsWithTrainers(trainerCount)))
  Assert.equal(compiled.trainerCount, trainerCount, "the projection reports its validated trainer count")
  for base, entries in pairs(compiled.rows) do
    Assert.isTrue(type(base) == "number" and base >= 1, "rematch rows are keyed by their base trainer")
    Assert.equal(#entries, 6, "every rematch row keeps its six source entries")
    Assert.equal(entries[1], base, "every rematch row opens with its own base trainer")
  end
  local joey = assert(compiled.rows[8], "the source set of the Route 30 youngster projects")
  Assert.deepEqual(
    joey,
    { 8, 8, 279, 280, 510, 0 },
    "the projected row preserves the source entry order and its none sentinel"
  )
  local projected = 0
  for _ in pairs(compiled.rows) do
    projected = projected + 1
  end
  Assert.equal(
    projected,
    #PokegearSources.trainerRematchSets,
    "every source rematch row projects exactly once"
  )

  local missing, missingErr = PokegearCatalogCompiler.compileRematchSets(romFsWithTrainers(nil))
  Assert.isNil(missing, "an unavailable trainer archive fails the projection")
  Assert.equal(
    assert(missingErr).code,
    PokegearCatalogCompiler.ERROR.SOURCE_UNAVAILABLE,
    "the missing archive is attributed"
  )
  local short, shortErr = PokegearCatalogCompiler.compileRematchSets(romFsWithTrainers(9))
  Assert.isNil(short, "a rematch row naming a trainer the dump lacks fails the projection")
  Assert.equal(
    assert(shortErr).code,
    PokegearCatalogCompiler.ERROR.REMATCH_INVALID,
    "the missing trainer is attributed to the rematch data"
  )
end

return { tests = T }
