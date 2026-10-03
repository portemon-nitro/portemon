-- Strict persisted state for HGSS shop transactions. It stores only the
-- balances, ownership and statistics needed to reproduce mart behavior.

local Errors = require("libs.errors.src.Errors")
local GameSaveErrors = require("libs.hgss.src.save.GameSaveErrors")

local MartSave = {}
MartSave.SCHEMA = "g4-mart-save-v1"

local function invalid(message, context)
  Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, message, context or { bucket = "mart" })
end

local function integer(value, minimum, maximum)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value % 1 == 0
    and value >= minimum
    and value <= maximum
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
    sealCase = { loose = {}, capsules = capsules },
    statistics = { currencySpent = 0, premierBallsEarned = 0 },
  }
end

local function validateRecord(value, catalog)
  assert(
    type(catalog) == "table"
      and type(catalog.cards) == "table"
      and type(catalog.apricorns) == "table"
      and type(catalog.seals) == "table",
    "MartSave requires the generated semantic catalog"
  )
  if type(value) ~= "table" or value.schema ~= MartSave.SCHEMA then
    invalid("mart schema is invalid")
  end
  local allowed = {
    schema = true,
    athletePoints = true,
    dailyPurchasedMask = true,
    lastProcessedDay = true,
    ownedDataCardsMask = true,
    apricorns = true,
    sealCase = true,
    statistics = true,
  }
  for key in pairs(value) do
    if not allowed[key] then
      invalid("mart bucket contains an unknown field", { bucket = "mart", field = key })
    end
  end
  if not integer(value.athletePoints, 0, 99999) then
    invalid("athlete points are out of range")
  end
  if not integer(value.dailyPurchasedMask, 0, 4095) then
    invalid("daily purchase mask is out of range")
  end
  if not integer(value.lastProcessedDay, 0, 3652059) then
    invalid("processed day ordinal is out of range")
  end
  if not integer(value.ownedDataCardsMask, 0, 134217727) then
    invalid("Data Card mask is out of range")
  end
  local apricorns = validateCountMap(value.apricorns, catalog.apricorns, 99, "apricorns")
  local sealCase = value.sealCase
  if type(sealCase) ~= "table" then
    invalid("seal case is required")
  end
  for key in pairs(sealCase) do
    if key ~= "loose" and key ~= "capsules" then
      invalid("seal case contains an unknown field")
    end
  end
  local loose = validateCountMap(sealCase.loose, catalog.seals, 99, "seal case loose")
  local capsules = sealCase.capsules
  if type(capsules) ~= "table" then
    invalid("capsules must be an array")
  end
  for key in pairs(capsules) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > 12 then
      invalid("capsules must contain exactly 12 slots")
    end
  end
  local canonicalCapsules, equipped = {}, {}
  for index = 1, 12 do
    local capsule = capsules[index]
    if type(capsule) ~= "table" then
      invalid("capsules must contain exactly 12 arrays", { bucket = "mart", capsule = index })
    end
    local count = #capsule
    for key in pairs(capsule) do
      if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > count then
        invalid("capsule contents must be contiguous")
      end
    end
    if count > 8 then
      invalid("capsule exceeds eight seals", { bucket = "mart", capsule = index })
    end
    canonicalCapsules[index] = {}
    for slot = 1, count do
      local placed = capsule[slot]
      if
        type(placed) ~= "table"
        or catalog.seals[placed.key] == nil
        or not integer(placed.x, 0, 255)
        or not integer(placed.y, 0, 255)
      then
        invalid("capsule seal record is invalid", { bucket = "mart", capsule = index, slot = slot })
      end
      for key in pairs(placed) do
        if key ~= "key" and key ~= "x" and key ~= "y" then
          invalid("capsule seal contains an unknown field")
        end
      end
      local sealKey = placed.key
      equipped[sealKey] = (equipped[sealKey] or 0) + 1
      canonicalCapsules[index][slot] = { key = sealKey, x = placed.x, y = placed.y }
    end
  end
  for key, count in pairs(equipped) do
    if count + (loose[key] or 0) > 99 then
      invalid("loose and equipped seal count exceeds 99", { bucket = "mart", key = key })
    end
  end
  local statistics = value.statistics
  if type(statistics) ~= "table" then
    invalid("mart statistics are required")
  end
  for key in pairs(statistics) do
    if key ~= "currencySpent" and key ~= "premierBallsEarned" then
      invalid("mart statistics contain an unknown field")
    end
  end
  if not integer(statistics.currencySpent, 0, 999999999) or not integer(statistics.premierBallsEarned, 0, 999999) then
    invalid("mart statistics are out of range")
  end
  return {
    schema = MartSave.SCHEMA,
    athletePoints = value.athletePoints,
    dailyPurchasedMask = value.dailyPurchasedMask,
    lastProcessedDay = value.lastProcessedDay,
    ownedDataCardsMask = value.ownedDataCardsMask,
    apricorns = apricorns,
    sealCase = { loose = loose, capsules = canonicalCapsules },
    statistics = { currencySpent = statistics.currencySpent, premierBallsEarned = statistics.premierBallsEarned },
  }
end

function MartSave.validate(value, catalog)
  local ok, result = pcall(validateRecord, value, catalog)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return MartSave
