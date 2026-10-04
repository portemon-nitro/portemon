-- Persisted mons bucket. The normative g4-mons-save-v2 record carries the
-- catalog fingerprint, the exact generator state, and the party snapshot.
-- Capture copies live state into canonical records; restore rebuilds the
-- live party and generator against the current catalog. A bucket written
-- against different generated content fails with a fingerprint mismatch;
-- malformed buckets and failing mons fail with a save error that names the
-- zero-based mon slot. This module never touches the top-level save; the
-- game save injects it as a bucket validator.

local Errors = require("libs.errors.src.Errors")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local Mon = require("libs.mons.src.Mon")
local MonsErrors = require("libs.mons.src.errors")
local Party = require("libs.mons.src.Party")
local U32 = require("libs.codec.src.U32")
local Boxes = require("libs.mons.src.Boxes")

---@alias MonsSave.BoxesSnapshot { schema: string, boxCount: integer, activeBox: integer, bonusUnlocks: boolean[], boxes: table[] }
---@alias MonsSave.Bucket { schema: string, catalogFingerprint: string, rng: { state: integer, calls: integer }, party: table<string, unknown>, boxes: MonsSave.BoxesSnapshot }
---@alias MonsSave.Context { catalog: MonCatalog, charmap: table<string, unknown>, games: table<string, unknown>, languages: table<string, unknown>, items: table<string, unknown>, balls: table<string, unknown> }
---@class MonsSave
local MonsSave = {}

MonsSave.SCHEMA = "g4-mons-save-v2"
MonsSave.LEGACY_SCHEMA = "g4-mons-save-v1"

---@generic T
---@param value T
---@return T
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copyValue(item)
  end
  return out
end

---@param bucket MonsSave.Bucket
local function checkShape(bucket)
  if type(bucket) ~= "table" then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "mons bucket must be a record", {})
  end
  for key in pairs(bucket) do
    if key ~= "schema" and key ~= "catalogFingerprint" and key ~= "rng" and key ~= "party" and key ~= "boxes" then
      MonsErrors.raise(MonsErrors.SAVE_INVALID, "mons bucket carries unknown field " .. tostring(key), {})
    end
  end
  if bucket.schema ~= MonsSave.SCHEMA then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "mons bucket schema must be " .. MonsSave.SCHEMA, {})
  end
  if type(bucket.catalogFingerprint) ~= "string" or bucket.catalogFingerprint == "" then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "mons bucket requires a catalog fingerprint", {})
  end
  if type(bucket.rng) ~= "table" then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "mons bucket requires a generator record", {})
  end
  if type(bucket.party) ~= "table" then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "mons bucket requires a party snapshot", {})
  end
  if type(bucket.boxes) ~= "table" then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "mons bucket requires boxes", {})
  end
end

---@param fingerprint string
---@param seedU32 integer
---@param options { configuredCount?: integer }?
---@return MonsSave.Bucket
function MonsSave.empty(fingerprint, seedU32, options)
  assert(type(fingerprint) == "string" and fingerprint ~= "", "mons empty requires a catalog fingerprint")
  assert(
    type(seedU32) == "number" and seedU32 % 1 == 0 and seedU32 >= 0 and seedU32 <= U32.MAX,
    "mons empty requires an unsigned 32-bit seed"
  )
  local seed = seedU32
  if seed == 0 then
    seed = 1
  end
  return MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture(), fingerprint, nil, options)
end

---@param partySnapshot table<string, unknown>
---@param rngCapture { state: integer, calls: integer }
---@param fingerprint string
---@param boxesSnapshot table<string, unknown>?
---@param options { configuredCount?: integer }?
---@return MonsSave.Bucket
function MonsSave.capture(partySnapshot, rngCapture, fingerprint, boxesSnapshot, options)
  assert(type(partySnapshot) == "table", "mons capture requires a party snapshot")
  assert(type(rngCapture) == "table", "mons capture requires a generator capture")
  assert(type(fingerprint) == "string" and fingerprint ~= "", "mons capture requires a catalog fingerprint")
  local ok, failure = pcall(Lcrng.validate, rngCapture)
  if not ok then
    if Errors.is(failure) then
      MonsErrors.raise(MonsErrors.SAVE_INVALID, "mons bucket generator record is malformed", {})
    end
    error(failure, 0)
  end
  boxesSnapshot = boxesSnapshot or Boxes.new(nil, options):capture()
  Boxes.validate(boxesSnapshot)
  return {
    schema = MonsSave.SCHEMA,
    catalogFingerprint = fingerprint,
    rng = copyValue(rngCapture),
    party = copyValue(partySnapshot),
    boxes = copyValue(boxesSnapshot),
  }
end

---@param bucket MonsSave.Bucket
---@param context MonsSave.Context
---@return boolean
function MonsSave.validate(bucket, context)
  assert(type(context) == "table", "mons validation requires a context")
  assert(context.catalog ~= nil, "mons validation requires a catalog")
  checkShape(bucket)
  local ok, failure = pcall(Lcrng.validate, bucket.rng)
  if not ok then
    if Errors.is(failure) then
      MonsErrors.raise(MonsErrors.SAVE_INVALID, "mons bucket generator record is malformed", {})
    end
    error(failure, 0)
  end
  if bucket.catalogFingerprint ~= context.catalog:fingerprint() then
    MonsErrors.raise(
      MonsErrors.SAVE_FINGERPRINT_MISMATCH,
      "mons bucket was written against different generated content",
      {}
    )
  end
  local partyOk, partyFailure = pcall(Party.validate, bucket.party, context)
  if not partyOk then
    if type(bucket.party) == "table" and type(bucket.party.mons) == "table" then
      for index, mon in ipairs(bucket.party.mons) do
        local monOk, monFailure = pcall(Mon.validate, mon, context)
        if not monOk then
          if Errors.is(monFailure) then
            MonsErrors.raise(MonsErrors.SAVE_INVALID, "mons bucket mon is malformed", { slot = index - 1 })
          end
          error(monFailure, 0)
        end
      end
    end
    error(partyFailure, 0)
  end
  local okBoxes, boxesFailure = pcall(Boxes.validate, bucket.boxes, context)
  if not okBoxes then
    error(boxesFailure, 0)
  end
  for _, box in ipairs(bucket.boxes.boxes) do
    for _, mon in ipairs(box.slots) do
      if mon ~= false then
        Mon.validate(mon, context)
      end
    end
  end
  return true
end

---@param bucket MonsSave.Bucket
---@param context MonsSave.Context
---@param options { configuredCount?: integer }?
---@return { party: Party, boxes: Boxes, rng: Gen4Lcrng }
function MonsSave.restore(bucket, context, options)
  assert(type(context) == "table", "mons restore requires a context")
  MonsSave.validate(bucket, context)
  local party = Party.restore(bucket.party, context)
  local boxes = Boxes.restore(bucket.boxes, options)
  local rng = Lcrng.restore(bucket.rng)
  return { party = party, boxes = boxes, rng = rng }
end

function MonsSave.migrateV1(bucket)
  if type(bucket) ~= "table" or bucket.schema ~= MonsSave.LEGACY_SCHEMA then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "legacy mons bucket schema is invalid", {})
  end
  for key in pairs(bucket) do
    if key ~= "schema" and key ~= "catalogFingerprint" and key ~= "rng" and key ~= "party" then
      MonsErrors.raise(MonsErrors.SAVE_INVALID, "legacy mons bucket has an unknown field", { field = key })
    end
  end
  if type(bucket.catalogFingerprint) ~= "string" or bucket.catalogFingerprint == "" or type(bucket.rng) ~= "table" then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "legacy mons bucket metadata is invalid", {})
  end
  local party = bucket.party
  if type(party) ~= "table" or party.max ~= Party.MAX or type(party.mons) ~= "table" then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "legacy party snapshot is invalid", {})
  end
  for key in pairs(party) do
    if key ~= "max" and key ~= "mons" then
      MonsErrors.raise(MonsErrors.SAVE_INVALID, "legacy party has an unknown field", {})
    end
  end
  local count = 0
  for key, mon in pairs(party.mons) do
    if
      type(key) ~= "number"
      or key % 1 ~= 0
      or key < 1
      or key > Party.MAX
      or type(mon) ~= "table"
      or mon.schema ~= Mon.LEGACY_SCHEMA
    then
      MonsErrors.raise(MonsErrors.SAVE_INVALID, "legacy party mon array is invalid", {})
    end
    count = math.max(count, key)
  end
  for index = 1, count do
    if party.mons[index] == nil then
      MonsErrors.raise(MonsErrors.SAVE_INVALID, "legacy party is sparse", {})
    end
  end
  local migrated = copyValue(bucket)
  migrated.schema = MonsSave.SCHEMA
  migrated.party = copyValue(bucket.party)
  for index, mon in ipairs(migrated.party.mons) do
    migrated.party.mons[index] = Mon.migrateV1(mon)
  end
  migrated.boxes = Boxes.new():capture()
  return migrated
end

return MonsSave
