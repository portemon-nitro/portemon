-- Strict mart persistence tests: semantic keys, masks, alternate counts,
-- capsule totals, statistics, and copy-on-validation.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local MartSave = require("libs.hgss.src.save.MartSave")

local T = {}

local function catalog()
  local cards = {}
  for index = 0, 26 do
    local key = "CARD_" .. index
    cards[key] = { itemKey = "DATA_CARD_" .. index, ownershipIndex = index }
  end
  return {
    cards = cards,
    apricorns = { RED_APRICORN = "red", BLUE_APRICORN = "blue" },
    seals = { SEAL_A = {}, SEAL_B = {} },
  }
end

local function empty()
  return {
    schema = "g4-mart-save-v1",
    athletePoints = 0,
    dailyPurchasedMask = 0,
    lastProcessedDay = 0,
    ownedDataCardsMask = 0,
    apricorns = {},
    sealCase = { loose = {}, capsules = { {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {} } },
    statistics = { currencySpent = 0, premierBallsEarned = 0 },
  }
end

local function rejects(value)
  local canonical, err = MartSave.validate(value, catalog())
  Assert.isNil(canonical)
  Assert.isTrue(Errors.is(err))
end

function T.empty_record_is_valid_and_canonical()
  local canonical = assert(MartSave.validate(empty(), catalog()))
  Assert.equal(canonical.schema, "g4-mart-save-v1")
  Assert.equal(canonical.athletePoints, 0)
  Assert.equal(canonical.dailyPurchasedMask, 0)
  Assert.equal(canonical.ownedDataCardsMask, 0)
  Assert.equal(#canonical.sealCase.capsules, 12)
  Assert.deepEqual(canonical.statistics, { currencySpent = 0, premierBallsEarned = 0 })
end

function T.valid_sparse_inventories_and_capsules_copy_without_aliasing()
  local input = empty()
  input.athletePoints = 99999
  input.dailyPurchasedMask = 4095
  input.lastProcessedDay = 730484
  input.ownedDataCardsMask = 134217727
  input.apricorns.RED_APRICORN = 99
  input.sealCase.loose.SEAL_A = 98
  input.sealCase.capsules[12] = { { key = "SEAL_A", x = 255, y = 0 } }
  input.statistics = { currencySpent = 999999999, premierBallsEarned = 999999 }

  local canonical = assert(MartSave.validate(input, catalog()))
  Assert.deepEqual(canonical, input)
  canonical.sealCase.capsules[12][1].x = 1
  Assert.equal(input.sealCase.capsules[12][1].x, 255, "validated state must not alias caller-owned input")
end

function T.rejects_missing_fields_and_unknown_semantic_keys()
  local missing = empty()
  missing.sealCase = nil
  rejects(missing)

  local unknownApricorn = empty()
  unknownApricorn.apricorns.NOPE = 1
  rejects(unknownApricorn)

  local unknownSeal = empty()
  unknownSeal.sealCase.loose.NOPE = 1
  rejects(unknownSeal)

  local unknownCapsule = empty()
  unknownCapsule.sealCase.capsules[1] = { { key = "NOPE", x = 0, y = 0 } }
  rejects(unknownCapsule)
end

function T.rejects_invalid_mask_day_count_and_statistics_ranges()
  for field, value in pairs({
    athletePoints = -1,
    dailyPurchasedMask = 4096,
    lastProcessedDay = -1,
    ownedDataCardsMask = 134217728,
  }) do
    local invalid = empty()
    invalid[field] = value
    rejects(invalid)
  end
  for field, value in pairs({ currencySpent = 1000000000, premierBallsEarned = 1000000 }) do
    local invalid = empty()
    invalid.statistics[field] = value
    rejects(invalid)
  end
end

function T.rejects_capsule_shape_coordinates_and_per_seal_total_over_99()
  local badArray = empty()
  badArray.sealCase.capsules[1] = { { key = "SEAL_A", x = 256, y = 0 } }
  rejects(badArray)

  local tooMany = empty()
  for index = 1, 9 do
    tooMany.sealCase.capsules[1][index] = { key = "SEAL_A", x = 0, y = 0 }
  end
  rejects(tooMany)

  local overLimit = empty()
  overLimit.sealCase.loose.SEAL_A = 99
  overLimit.sealCase.capsules[1][1] = { key = "SEAL_A", x = 0, y = 0 }
  rejects(overLimit)
end

return { tests = T }
