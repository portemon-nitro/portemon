-- Lossless migration from the opaque-status mon and bucket schemas to
-- the semantic-condition record. The legacy reader owns the only
-- old-to-current interpretation: it reads the legacy field sets strictly,
-- decodes the native status word into persistent condition records,
-- copies every other independent value exactly, and returns a detached
-- current candidate without rewriting its input. Generator state and call
-- counts survive; legacy buckets never carried boxes, so the upgrade
-- stages a fresh empty box set beside the migrated party. Anything
-- outside the recognized legacy shapes fails instead of being reinterpreted.

local Boxes = require("libs.mons.src.Boxes")
local Mon = require("libs.mons.src.Mon")
local MonsErrors = require("libs.mons.src.errors")
local StatusCodec = require("libs.mons.src.gen4.StatusCodec")

---@class MonStateMigration
local MonStateMigration = {}

MonStateMigration.LEGACY_MON_SCHEMA = "g4-mon-v1"
-- Recognized legacy bucket tags: the frozen legacy bucket shape carries
-- the mon tag, while retired production buckets carry the first bucket
-- tag. Both hold opaque-status mons and upgrade through the same path;
-- anything else is never reinterpreted as legacy.
MonStateMigration.LEGACY_BUCKET_SCHEMA = "g4-mon-v1"
MonStateMigration.RETIRED_BUCKET_SCHEMA = "g4-mons-save-v1"

-- The current bucket tag lives with its owner (MonsSave.SCHEMA); the
-- literal below names the same tag so this leaf reader never loads the
-- bucket owner back. MonsSave.restore asserts the tags agree.
local CURRENT_BUCKET_SCHEMA = "g4-mons-save-v3"

local LEGACY_TOP_FIELDS = {
  schema = true,
  species = true,
  form = true,
  personality = true,
  experience = true,
  friendship = true,
  ability = true,
  heldItem = true,
  markings = true,
  evs = true,
  contest = true,
  moves = true,
  ivs = true,
  isEgg = true,
  nickname = true,
  ribbons = true,
  fatefulEncounter = true,
  shinyLeaves = true,
  egg = true,
  met = true,
  origin = true,
  pokerus = true,
  mood = true,
  condition = true,
  capsule = true,
  mail = true,
}

local LEGACY_CONDITION_FIELDS = { status = true, currentHp = true }

local LEGACY_BUCKET_FIELDS = { schema = true, catalogFingerprint = true, rng = true, party = true }

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

-- Upgrades one legacy mon to the current schema. The optional context is
-- accepted for callers that already carry domain references; the transform
-- itself is pure and deterministic, so the context never changes the
-- result. Unsupported status combinations fail while decoding; an
-- unrelated schema is never reinterpreted as legacy.
---@param mon table<string, unknown>
---@param context table<string, unknown>?
---@return table<string, unknown>
function MonStateMigration.upgradeMon(mon, context)
  if context ~= nil then
    assert(type(context) == "table", "legacy upgrade context must be a record")
  end
  if type(mon) ~= "table" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "legacy upgrade requires a mon record", {})
  end
  assert(type(mon) == "table", "legacy mon validated above")
  if mon.schema ~= MonStateMigration.LEGACY_MON_SCHEMA then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "legacy upgrade expects a g4-mon-v1 record", {})
  end
  for key in pairs(mon) do
    if LEGACY_TOP_FIELDS[key] == nil then
      MonsErrors.raise(MonsErrors.RECORD_INVALID, "legacy mon carries unknown field " .. tostring(key), {})
    end
  end
  local condition = mon.condition
  if type(condition) ~= "table" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "legacy mon requires a condition record", {})
  end
  assert(type(condition) == "table", "legacy condition validated above")
  for key in pairs(condition) do
    if LEGACY_CONDITION_FIELDS[key] == nil then
      MonsErrors.raise(MonsErrors.RECORD_INVALID, "legacy condition carries unknown field " .. tostring(key), {})
    end
  end
  if condition.status == nil or condition.currentHp == nil then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "legacy condition must carry status and current health", {})
  end
  local effects = StatusCodec.decode(condition.status --[[@as integer]])
  local upgraded = {}
  for key, value in pairs(mon) do
    if key ~= "schema" and key ~= "condition" then
      upgraded[key] = copyValue(value)
    end
  end
  upgraded.schema = Mon.SCHEMA
  upgraded.condition = { currentHp = copyValue(condition.currentHp), effects = effects }
  return upgraded
end

-- Upgrades one legacy bucket to the current schema. Party order, generator
-- state, and call counts are preserved exactly; the input bucket is never
-- rewritten. Legacy buckets predate box storage, so the upgrade stages a
-- fresh empty box set. Supported legacy mon entries are upgraded through
-- upgradeMon; anything else fails at its owning shape.
---@param bucket table<string, unknown>
---@param context table<string, unknown>?
---@return table<string, unknown>
function MonStateMigration.upgradeBucket(bucket, context)
  if context ~= nil then
    assert(type(context) == "table", "legacy upgrade context must be a record")
  end
  if type(bucket) ~= "table" then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "legacy bucket upgrade requires a record", {})
  end
  assert(type(bucket) == "table", "legacy bucket validated above")
  if
    bucket.schema ~= MonStateMigration.LEGACY_BUCKET_SCHEMA
    and bucket.schema ~= MonStateMigration.RETIRED_BUCKET_SCHEMA
  then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "legacy bucket upgrade expects a recognized legacy bucket", {})
  end
  for key in pairs(bucket) do
    if LEGACY_BUCKET_FIELDS[key] == nil then
      MonsErrors.raise(MonsErrors.SAVE_INVALID, "legacy bucket carries unknown field " .. tostring(key), {})
    end
  end
  if type(bucket.catalogFingerprint) ~= "string" then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "legacy bucket requires a catalog fingerprint", {})
  end
  if type(bucket.rng) ~= "table" then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "legacy bucket requires a generator record", {})
  end
  local party = bucket.party
  if type(party) ~= "table" then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "legacy bucket requires a party snapshot", {})
  end
  assert(type(party) == "table", "legacy party validated above")
  if type(party.mons) ~= "table" then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "legacy bucket requires a party mon array", {})
  end
  assert(type(party.mons) == "table", "legacy party mons validated above")
  local mons = {}
  for index, mon in ipairs(party.mons) do
    mons[index] = MonStateMigration.upgradeMon(mon, context)
  end
  return {
    schema = CURRENT_BUCKET_SCHEMA,
    rng = copyValue(bucket.rng),
    party = { max = copyValue(party.max), mons = mons },
    boxes = Boxes.new():capture(),
  }
end

return MonStateMigration
