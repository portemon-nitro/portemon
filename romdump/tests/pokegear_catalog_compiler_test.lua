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

-- One synthetic phonebook record in the source little-endian layout: four
-- bytes, four halfwords, eight bytes.
local function phonebookRecord(trainer, map, weights)
  weights = weights or { 1, 2, 3, 4 }
  local head = string.char(7, 1, 2, trainer % 256)
  local halves = packU16(map % 65536) .. packU16(11) .. packU16(12) .. packU16(13)
  local tail = string.char(3, 4, 5, weights[1] % 256, weights[2] % 256, weights[3] % 256, weights[4] % 256, 0)
  return head .. halves .. tail
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
  Assert.equal(contact.class.entry, contact.trainer, "ordinary class entry follows the native trainer-class byte")
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
  Assert.equal(first.sortWeights[1], 30, "source sort weights are preserved, not re-sorted")
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

return { tests = T }
