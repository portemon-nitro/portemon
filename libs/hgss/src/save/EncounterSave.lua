-- Semantic encounter persistence: the versioned encounter bucket carrying
-- authoritative counters, the active radio/swarm context, and the roamer
-- records. Validation is strict and reference-based: malformed buckets and
-- missing selected species or maps fail with the exact reference, while
-- unrelated catalog growth stays compatible and whole encounter tables
-- never persist. A missing bucket restores to the defined source initial
-- state. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")

---@class EncounterSave
local EncounterSave = {}

EncounterSave.SCHEMA = "hgss-encounter-v1"
EncounterSave.STATE_VERSION = 1

local TOP_FIELDS = {
  schema = true,
  stateVersion = true,
  steps = true,
  repelSteps = true,
  swarm = true,
  radio = true,
  roamers = true,
}

local RECORD_FIELDS = {
  key = true,
  stateVersion = true,
  mon = true,
  location = true,
  lifecycle = true,
  revision = true,
}

local LIFECYCLES = {
  inactive = true,
  roaming = true,
  caught = true,
  defeated = true,
}

---@param message string
---@param context table<string, unknown>?
local function fail(message, context)
  Errors.raise("ENCOUNTER_SAVE_INVALID", message, context or {})
end

---@param value unknown
---@return unknown
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

---@return table<string, unknown> the defined source initial state
function EncounterSave.initial()
  return {
    schema = EncounterSave.SCHEMA,
    stateVersion = EncounterSave.STATE_VERSION,
    steps = 0,
    repelSteps = 0,
    swarm = false,
    radio = "none",
    roamers = {},
  }
end

---@param value unknown
---@param what string
local function checkCounter(value, what)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 then
    fail("encounter " .. what .. " must be a non-negative integer", {})
  end
end

---@param bucket unknown
---@return table<string, unknown> canonical detached shape without reference checks
local function checkShape(bucket)
  if type(bucket) ~= "table" then
    fail("encounter bucket must be a table", {})
  end
  assert(type(bucket) == "table", "shape validation reads the bucket record")
  for key in pairs(bucket) do
    if TOP_FIELDS[key] ~= true then
      fail("encounter bucket contains an unknown field", { field = key })
    end
  end
  if bucket.schema ~= EncounterSave.SCHEMA then
    fail("encounter schema must be " .. EncounterSave.SCHEMA, { schema = bucket.schema })
  end
  if bucket.stateVersion ~= EncounterSave.STATE_VERSION then
    fail("encounter state version must be " .. EncounterSave.STATE_VERSION, { stateVersion = bucket.stateVersion })
  end
  checkCounter(bucket.steps, "step counter")
  checkCounter(bucket.repelSteps, "repel counter")
  if type(bucket.swarm) ~= "boolean" then
    fail("encounter swarm state must be a boolean", {})
  end
  if type(bucket.radio) ~= "string" or bucket.radio == "" then
    fail("encounter radio state must be a non-empty string", {})
  end
  if type(bucket.roamers) ~= "table" then
    fail("encounter roamers must be a record", {})
  end
  assert(type(bucket.roamers) == "table", "shape validation reads the roamer map")
  for key, record in pairs(bucket.roamers) do
    if type(key) ~= "string" or key == "" then
      fail("encounter roamer keys must be non-empty strings", { roamer = key })
    end
    if type(record) ~= "table" then
      fail("encounter roamer " .. key .. " must be a record", { roamer = key })
    end
    assert(type(record) == "table", "shape validation reads roamer records")
    for field in pairs(record) do
      if RECORD_FIELDS[field] ~= true then
        fail("encounter roamer " .. key .. " contains an unknown field", { roamer = key, field = field })
      end
    end
    if record.key ~= key then
      fail("encounter roamer key must match its record", { roamer = key })
    end
    if record.stateVersion ~= EncounterSave.STATE_VERSION then
      fail("encounter roamer " .. key .. " carries an incompatible state version", {
        roamer = key,
        stateVersion = record.stateVersion,
      })
    end
    if type(record.mon) ~= "table" or type(record.mon.species) ~= "string" then
      fail("encounter roamer " .. key .. " carries no species", { roamer = key })
    end
    if type(record.lifecycle) ~= "string" or LIFECYCLES[record.lifecycle] ~= true then
      fail("encounter roamer " .. key .. " carries an unknown lifecycle", {
        roamer = key,
        lifecycle = record.lifecycle,
      })
    end
    if type(record.revision) ~= "number" or record.revision % 1 ~= 0 or record.revision < 0 then
      fail("encounter roamer " .. key .. " carries an invalid revision", {
        roamer = key,
        revision = record.revision,
      })
    end
  end
  return copyValue(bucket)
end

---@param bucket table<string, unknown>
---@param refs unknown
local function checkReferences(bucket, refs)
  if type(refs) ~= "table" or type(refs.species) ~= "table" or type(refs.maps) ~= "table" then
    fail("encounter validation requires species and map reference sets", {})
  end
  assert(type(refs) == "table", "reference validation reads the reference sets")
  local roamers = bucket.roamers
  assert(type(roamers) == "table", "reference validation reads the roamer map")
  for key, record in pairs(roamers) do
    assert(type(record) == "table" and type(key) == "string", "reference validation reads roamer records")
    local mon = record.mon
    assert(type(mon) == "table", "reference validation reads roamer mons")
    if refs.species[mon.species] ~= true then
      fail("encounter roamer " .. key .. " names a missing species", { roamer = key, species = mon.species })
    end
    if refs.maps[record.location] ~= true then
      fail("encounter roamer " .. key .. " names a missing location", { roamer = key, location = record.location })
    end
  end
end

-- Validates a bucket against the selected references, returning its
-- canonical detached record. Unrelated reference growth stays compatible;
-- missing selected references fail naming the reference.
---@param bucket unknown
---@param refs { species: table<string, boolean>, maps: table<integer, boolean> }
---@return table<string, unknown>
function EncounterSave.validate(bucket, refs)
  local shaped = checkShape(bucket)
  checkReferences(shaped, refs)
  return shaped
end

-- Captures a bucket from a state owner exposing the persistable encounter
-- fields. Only authoritative counters, context, and roamer records persist.
---@param state table<string, unknown>
---@return table<string, unknown>
function EncounterSave.capture(state)
  if type(state) ~= "table" or type(state.capture) ~= "function" then
    fail("encounter capture needs a roamer state", {})
  end
  assert(type(state) == "table", "capture reads the state owner")
  local captureFn = state.capture
  assert(type(captureFn) == "function", "capture reads the state owner")
  local capture = captureFn(state)
  if type(capture) ~= "table" then
    fail("encounter capture carries no state", {})
  end
  assert(type(capture) == "table", "capture reads the persistable fields")
  return checkShape({
    schema = EncounterSave.SCHEMA,
    stateVersion = EncounterSave.STATE_VERSION,
    steps = capture.steps,
    repelSteps = capture.repelSteps,
    swarm = capture.swarm,
    radio = capture.radio,
    roamers = capture.roamers,
  })
end

-- Restores a bucket for loading: a missing bucket yields the defined source
-- initial state, a present bucket validates exactly.
---@param bucket table<string, unknown>?
---@param refs { species: table<string, boolean>, maps: table<integer, boolean> }
---@return table<string, unknown>
function EncounterSave.restore(bucket, refs)
  if bucket == nil then
    return EncounterSave.initial()
  end
  return EncounterSave.validate(bucket, refs)
end

return EncounterSave
