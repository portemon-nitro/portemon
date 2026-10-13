-- Strict persisted state for HGSS shop transactions. It stores only the
-- balances, ownership and statistics needed to reproduce mart behavior.

local Errors = require("libs.errors.src.Errors")
local GameSaveErrors = require("libs.hgss.src.save.GameSaveErrors")

local MartSave = {}
MartSave.SCHEMA = "g4-mart-save-v2"
MartSave.LEGACY_V1_SCHEMA = "g4-mart-save-v1"

local function invalid(message, context)
  Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, message, context or { bucket = "mart" })
end

local function integer(value, minimum, maximum)
  return type(value) == "number" and value % 1 == 0 and value >= minimum and value <= maximum
end

local function validateCountMap(value, catalog, maximum, what)
  if type(value) ~= "table" then
    invalid(what .. " must be a map")
  end
  local out = {}
  for key, count in pairs(value) do
    if type(key) ~= "string" or catalog[key] == nil then
      invalid(what .. " contains an unknown key", { bucket = "mart", key = key })
    end
    if not integer(count, 0, maximum) then
      invalid(what .. " count is out of range", { bucket = "mart", key = key })
    end
    if count > 0 then
      out[key] = count
    end
  end
  return out
end

function MartSave.empty()
  local capsules = {}
  for index = 1, 12 do
    capsules[index] = {}
  end
  return {
    schema = MartSave.SCHEMA,
    athletePoints = 0,
    dailyPurchasedMask = 0,
    lastProcessedDay = 0,
    ownedDataCardsMask = 0,
    apricorns = {},
    apricornDayOrdinal = 0,
    apricornHarvestedMask = 0,
    kurtOrder = nil,
    sealCase = { loose = {}, capsules = capsules },
    statistics = { currencySpent = 0, premierBallsEarned = 0 },
  }
end

local function validateRecord(value, catalog, schema)
  assert(
    type(catalog) == "table" and type(catalog.apricorns) == "table" and type(catalog.seals) == "table",
    "MartSave requires the generated semantic catalog"
  )
  if type(value) ~= "table" or value.schema ~= schema then
    invalid("mart schema is invalid")
  end
  if
    not integer(value.athletePoints, 0, 99999)
    or not integer(value.dailyPurchasedMask, 0, 4095)
    or not integer(value.lastProcessedDay, 0, 3652059)
    or not integer(value.ownedDataCardsMask, 0, 134217727)
  then
    invalid("mart balances, masks, or day ordinal are out of range")
  end
  local current = schema == MartSave.SCHEMA
  local kurtOrder
  if current then
    if not integer(value.apricornDayOrdinal, 0, 3652059) or not integer(value.apricornHarvestedMask, 0, 2147483647) then
      invalid("Apricorn day ordinal or harvested mask is out of range")
    end
    local order = value.kurtOrder
    if order ~= nil then
      if
        type(order) ~= "table"
        or catalog.apricorns[order.apricornKey] == nil
        or not integer(order.quantity, 1, 99)
      then
        invalid("Kurt order is invalid")
      end
      kurtOrder = { apricornKey = order.apricornKey, quantity = order.quantity }
    end
  end
  local sealCase, statistics = value.sealCase, value.statistics
  if type(sealCase) ~= "table" or type(sealCase.capsules) ~= "table" or type(statistics) ~= "table" then
    invalid("seal case and statistics are required")
  end
  if not integer(statistics.currencySpent, 0, 999999999) or not integer(statistics.premierBallsEarned, 0, 999999) then
    invalid("mart statistics are out of range")
  end
  local loose = validateCountMap(sealCase.loose, catalog.seals, 99, "seal case loose")
  local capsules, equipped = {}, {}
  for index = 1, 12 do
    local capsule = sealCase.capsules[index]
    if type(capsule) ~= "table" or #capsule > 8 then
      invalid("capsule is missing or exceeds eight seals", { bucket = "mart", capsule = index })
    end
    capsules[index] = {}
    for slot, placed in ipairs(capsule) do
      if
        type(placed) ~= "table"
        or catalog.seals[placed.key] == nil
        or not integer(placed.x, 0, 255)
        or not integer(placed.y, 0, 255)
      then
        invalid("capsule seal record is invalid", { bucket = "mart", capsule = index, slot = slot })
      end
      equipped[placed.key] = (equipped[placed.key] or 0) + 1
      capsules[index][slot] = { key = placed.key, x = placed.x, y = placed.y }
    end
  end
  for key, count in pairs(equipped) do
    if count + (loose[key] or 0) > 99 then
      invalid("loose and equipped seal count exceeds 99", { bucket = "mart", key = key })
    end
  end
  return {
    schema = schema,
    athletePoints = value.athletePoints,
    dailyPurchasedMask = value.dailyPurchasedMask,
    lastProcessedDay = value.lastProcessedDay,
    ownedDataCardsMask = value.ownedDataCardsMask,
    apricorns = validateCountMap(value.apricorns, catalog.apricorns, 99, "apricorns"),
    apricornDayOrdinal = current and value.apricornDayOrdinal or nil,
    apricornHarvestedMask = current and value.apricornHarvestedMask or nil,
    kurtOrder = kurtOrder,
    sealCase = { loose = loose, capsules = capsules },
    statistics = { currencySpent = statistics.currencySpent, premierBallsEarned = statistics.premierBallsEarned },
  }
end

function MartSave.validate(value, catalog)
  local ok, result = pcall(validateRecord, value, catalog, MartSave.SCHEMA)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

function MartSave.migrateV1(value, catalog)
  local ok, result = pcall(validateRecord, value, catalog, MartSave.LEGACY_V1_SCHEMA)
  if not ok then
    if Errors.is(result) then
      return nil, result
    end
    error(result)
  end
  result.schema = MartSave.SCHEMA
  result.apricornDayOrdinal = 0
  result.apricornHarvestedMask = 0
  result.kurtOrder = nil
  return MartSave.validate(result, catalog)
end

return MartSave
