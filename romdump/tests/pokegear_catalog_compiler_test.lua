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
  local parsed, err = PokegearCatalogCompiler.validateResdatList(
    resdatList(3, { { 143, 5, 1, 9, 0, 0 } }),
    "fixture-list"
  )
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
  local parsed, err = PokegearCatalogCompiler.validateResdatHeaders(
    resdatHeaders({ { 34, 35, 33, 32, 0, 0, 1, 7 } }),
    "fixture-headers"
  )
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

return { tests = T }
